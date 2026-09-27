# `cybertrain build`: dist/ = the app binary with app/views embedded, plus
# public/. Also the command lists `cybertrain migration` and `server` run. Plain Ruby:
# runs under CRuby (the gem) and compiles under Spinel (spin install).
module Cybertrain
  module CLI
    module Build
      # The [package] name in root/spin.toml, or "" when there is none.
      def self.app_name(root)
        path = "#{root}/spin.toml"
        return "" unless File.exist?(path)

        name = ""
        in_package = false
        File.read(path).each_line do |line|
          text = line.strip
          in_package = text == "[package]" if text.start_with?("[")
          next unless in_package && text.start_with?("name")

          match = text.match(/\Aname\s*=\s*"([^"]*)"/)
          unless match.nil?
            name = match[1]
            break
          end
        end
        name
      end

      def self.commands(name)
        ["spin run gen -- --embed-views", "spin build #{name}", "spin run gen"]
      end

      # Through bin/db.rb: the app binary cannot compile before the first
      # migration has produced gen/models.
      def self.migration_commands
        ["spin run gen", "spin run db -- migrate", "spin run gen"]
      end

      # port is "" (the app's default, 3000) or a port? string.
      def self.server_commands(name, port)
        run = port == "" ? "spin run #{name}" : "spin run #{name} -- #{port}"
        ["spin run gen", run]
      end

      # All digits, 1 to 65535 (the app reads 0 as "no port").
      def self.port?(text)
        return false if text.empty? || text.size > 5
        return false unless text.bytes.all? { |b| b >= 48 && b <= 57 }

        text.to_i >= 1 && text.to_i <= 65535
      end

      # Runs one build step (a spin command) in root; true when it succeeds.
      # Build.run takes a Runner so tests can stand in for spin.
      class Runner
        def run_step(root, command)
          Build.run_in(root, command)
        end
      end

      # Exists while the steps run: the development server (Dev::Rebuilder)
      # skips its rebuilds meanwhile, since both write build/bin/<name>.
      def self.lock_path(root)
        "#{root}/tmp/cybertrain-build.lock"
      end

      # Runs the build in root and assembles dist/. Returns the exit code.
      def self.run(root, name, runner = Runner.new)
        steps = commands(name)
        ok = false
        restored = false
        Templates.mkdir_p("#{root}/tmp")
        File.write(lock_path(root), "")
        begin
          ok = runner.run_step(root, steps[0]) && runner.run_step(root, steps[1])
        ensure
          # Always put gen/views.rb back to the empty table, even after a
          # failure or Ctrl-C; the lock is released only once that has run.
          begin
            restored = runner.run_step(root, steps[2])
            puts "warning: gen/views.rb still holds the embedded views; run spin run gen" unless restored
          ensure
            File.delete(lock_path(root)) if File.exist?(lock_path(root))
          end
        end
        return 1 unless ok && restored

        assemble(root, name)
        puts ""
        puts "dist/#{name}       (production by default)"
        puts "dist/public/"
        puts "run:  cd dist && ./#{name} migrate && ./#{name}"
        0
      end

      def self.run_in(root, command)
        puts "run    #{command}"
        system("cd #{shell_quote(root)} && #{command}")
      end

      # Copies build/bin/<name> and public/ into dist/; storage/ and tmp/ are
      # created when missing and never emptied (a database and the secret
      # key can live there). Each copy lands in a dist/.*.tmp entry first and
      # is renamed into place: a running dist/<name> keeps its old file
      # (writing over a running binary fails with ETXTBSY on Linux) and
      # dist/public/ is never missing in between.
      def self.assemble(root, name)
        binary = "#{root}/build/bin/#{name}"
        raise InvalidArgument, "build/bin/#{name} is missing: `spin build #{name}` did not produce it" unless File.exist?(binary)

        dist = "#{root}/dist"
        Templates.mkdir_p(dist)
        binary_tmp = "#{dist}/.#{name}.tmp"
        public_tmp = "#{dist}/.public.tmp"
        # Leftovers of an interrupted earlier run.
        rm_tree(binary_tmp)
        rm_tree(public_tmp)

        copy_command = "cp #{shell_quote(binary)} #{shell_quote(binary_tmp)}"
        raise InvalidArgument, "could not copy #{binary} to dist/" unless system(copy_command)

        File.rename(binary_tmp, "#{dist}/#{name}")

        if File.directory?("#{root}/public")
          public_command = "cp -R #{shell_quote("#{root}/public")} #{shell_quote(public_tmp)}"
          raise InvalidArgument, "could not copy public/ to dist/" unless system(public_command)
        else
          Dir.mkdir(public_tmp)
        end
        rm_tree("#{dist}/public")
        File.rename(public_tmp, "#{dist}/public")

        Templates.mkdir_p("#{dist}/storage")
        Templates.mkdir_p("#{dist}/tmp")
        ["dist/#{name}", "dist/public/", "dist/storage/", "dist/tmp/"]
      end

      # A symlink is removed itself, never followed: its target may be
      # dist/storage/ or outside dist/.
      def self.rm_tree(path)
        if File.symlink?(path)
          File.delete(path)
          return nil
        end
        return nil unless File.exist?(path)

        if File.directory?(path)
          Dir.children(path).each { |child| rm_tree("#{path}/#{child}") }
          Dir.rmdir(path)
        else
          File.delete(path)
        end
        nil
      end

      def self.shell_quote(text)
        "'#{text.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
