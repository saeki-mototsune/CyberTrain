# `cybertrain build`: dist/ = the app binary with app/views embedded, plus
# public/. Also the command lists `cybertrain migration` runs. Plain Ruby:
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

      def self.migration_commands(name)
        ["spin run gen", "spin run #{name} -- migrate", "spin run gen"]
      end

      # Runs the build in root and assembles dist/. Returns the exit code.
      def self.run(root, name)
        steps = commands(name)
        ok = run_in(root, steps[0]) && run_in(root, steps[1])
        # Always put gen/views.rb back to the empty table, even after a failure.
        restored = run_in(root, steps[2])
        return 1 unless ok && restored

        written = assemble(root, name)
        puts ""
        puts "dist/#{name}       (production by default)"
        puts "dist/public/"
        puts "run:  cd dist && ./#{name} migrate && ./#{name}"
        written.size > 0 ? 0 : 1
      end

      def self.run_in(root, command)
        puts "run    #{command}"
        system("cd #{shell_quote(root)} && #{command}")
      end

      # Copies build/bin/<name> and public/ into dist/; storage/ and tmp/ are
      # created when missing and never emptied (a database and the secret
      # key can live there).
      def self.assemble(root, name)
        binary = "#{root}/build/bin/#{name}"
        raise InvalidArgument, "build/bin/#{name} is missing: `spin build #{name}` did not produce it" unless File.exist?(binary)

        Templates.mkdir_p("#{root}/dist")
        copy_command = "cp #{shell_quote(binary)} #{shell_quote("#{root}/dist/#{name}")}"
        raise InvalidArgument, "could not copy #{binary} to dist/" unless system(copy_command)

        rm_tree("#{root}/dist/public")
        if File.directory?("#{root}/public")
          public_command = "cp -R #{shell_quote("#{root}/public")} #{shell_quote("#{root}/dist/public")}"
          raise InvalidArgument, "could not copy public/ to dist/" unless system(public_command)
        else
          Dir.mkdir("#{root}/dist/public")
        end
        Templates.mkdir_p("#{root}/dist/storage")
        Templates.mkdir_p("#{root}/dist/tmp")
        ["dist/#{name}", "dist/public/", "dist/storage/", "dist/tmp/"]
      end

      def self.rm_tree(path)
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
