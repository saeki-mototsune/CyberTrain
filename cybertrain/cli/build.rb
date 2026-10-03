# `cybertrain build`: dist/ = the app binary with app/views embedded, plus
# public/. Also the command lists `cybertrain db` and `server` run. Plain Ruby:
# runs under CRuby (the gem) and compiles under Spinel (spin install).
module Cybertrain
  module CLI
    module Build
      # The entries assemble() keeps in dist/ besides the binary: the copied
      # public/ and the storage/ and tmp/ directories. A package named like
      # one of them would collide with it (the binary renamed to dist/public
      # gets moved aside as dist/.public.old and deleted; a dist/storage
      # directory cannot be replaced by the binary), so `cybertrain build`
      # (require_dist_name!) and `cybertrain new` refuse these names;
      # app_name, which every command reads, does not: `cybertrain db` and
      # `server` work for an existing app named like one. assemble builds its
      # paths from these constants so the two cannot drift.
      DIST_PUBLIC = "public"
      DIST_STORAGE = "storage"
      DIST_TMP = "tmp"
      DIST_ENTRIES = [DIST_PUBLIC, DIST_STORAGE, DIST_TMP]

      # "" when name cannot collide with what assemble() puts in dist/, else
      # the reason. A leading "." covers assemble's scratch entries
      # (dist/.<name>.tmp, dist/.public.tmp, dist/.public.old) and "."/"..".
      # The entry names match case-insensitively: on a case-insensitive
      # filesystem (macOS's default APFS, one of the CI OSes; Windows) "Public"
      # and "TMP" are the same directory entry as public and tmp. Only a
      # different spelling of the whole name ("tmp2", "my_public") is another
      # entry. downcase is ASCII-safe here: the entries are ASCII.
      def self.dist_name_problem(name)
        return "" unless DIST_ENTRIES.include?(name.downcase) || name.start_with?(".")

        "collides with what `cybertrain build` keeps in dist/ (#{DIST_ENTRIES.join(", ")}) or its scratch entries: it cannot be one of those names (in any letter case) or start with '.'"
      end

      # The [package] name in root/spin.toml, or "" when there is none. The
      # name ends up in shell command strings and file paths, so it must be
      # a name `cybertrain new` could have produced.
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
        # The name reaches the shell through quote_arg, so any spelling is
        # safe there; only what breaks the build/bin/<name> path is refused
        # ("my-app" and "MyApp" are fine for `spin build`). "." and ".." name
        # build/bin/. and build/bin/.., which exist already (the latter is
        # build/) and only fail later, in assemble's cp. A leading "-" is
        # refused too: quote_arg leaves it bare ("-" is in its safe set), so
        # `spin build --release` would take the name as an option, not as the
        # package name.
        if name == "." || name == ".." || name.start_with?("-") || name.include?("/") || name.match?(/\s/)
          raise InvalidArgument, "spin.toml [package] name '#{name}' cannot be '.' or '..', start with '-', or contain '/' or whitespace"
        end

        name
      end

      # The build path's check, made once in CLI.build_app before the
      # toolchain is touched (Build.run does not repeat it): a name that
      # collides with a dist/ entry only matters to assemble. Returns nil.
      def self.require_dist_name!(name)
        problem = dist_name_problem(name)
        raise InvalidArgument, "spin.toml [package] name '#{name}' #{problem}" unless problem.empty?

        nil
      end

      # name goes through quote_arg too: app_name validates it, but the
      # command strings stay safe for a caller that skipped that. An empty
      # name would otherwise become an explicit "" argument to spin.
      def self.commands(name)
        require_name!(name)
        ["spin run gen -- --embed-views", "spin build #{quote_arg(name)}", "spin run gen"]
      end

      def self.require_name!(name)
        raise InvalidArgument, "no application name: run this inside a cybertrain application (spin.toml with a [package] name)" if name.empty?

        nil
      end

      # `cybertrain db ARGS`, through bin/db.rb (the app binary cannot compile
      # before the first migration has produced gen/models). bin/db.rb only
      # knows the migrations gen/migrations.rb lists, so gen runs first;
      # migrate and rollback rewrite db/schema.rb, which gen/models is
      # derived from, so gen runs again after them.
      def self.db_commands(args)
        words = args.map { |arg| quote_arg(arg) }.join(" ")
        commands = ["spin run gen", "spin run db -- #{words}"]
        commands << "spin run gen" if args[0] == "migrate" || args[0] == "rollback"
        commands
      end

      # `cybertrain migration`: the same as `cybertrain db migrate`.
      def self.migration_commands
        db_commands(["migrate"])
      end

      # A word sh reads as itself stays bare; anything else is single-quoted.
      def self.quote_arg(text)
        return text if !text.empty? && text.match(/\A[A-Za-z0-9_:.\/-]+\z/)

        shell_quote(text)
      end

      # port is "" (the app's default, 3000) or a port? string.
      def self.server_commands(name, port)
        require_name!(name)
        target = quote_arg(name)
        run = port == "" ? "spin run #{target}" : "spin run #{target} -- #{quote_arg(port)}"
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

      # Holds this process's PID while the steps run and dist/ is assembled:
      # the development server (Dev::Rebuilder) skips its rebuilds
      # meanwhile, since both write build/bin/<name>, and treats a lock
      # whose PID is gone (a killed build) as stale.
      def self.lock_path(root)
        "#{root}/tmp/cybertrain-build.lock"
      end

      # Runs the build in root and assembles dist/. Returns the exit code.
      # name must already have passed require_dist_name!: CLI.build_app checks
      # it once, before the toolchain is fetched.
      def self.run(root, name, runner = Runner.new)
        steps = commands(name)
        ok = false
        restored = false
        code = 1
        Templates.mkdir_p("#{root}/tmp")
        File.write(lock_path(root), Process.pid.to_s)
        begin
          begin
            ok = runner.run_step(root, steps[0]) && runner.run_step(root, steps[1])
          ensure
            # Always put gen/views.rb back to the empty table, even after a
            # failure or Ctrl-C.
            restored = runner.run_step(root, steps[2])
            puts "warning: gen/views.rb still holds the embedded views; run spin run gen" unless restored
          end
          if ok && restored
            assemble(root, name)
            code = 0
          end
        ensure
          # Released only once dist/ holds the new binary: assemble reads
          # build/bin/<name>, which a dev rebuild would be writing.
          File.delete(lock_path(root)) if File.exist?(lock_path(root))
        end
        return 1 unless code == 0

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
      # (writing over a running binary fails with ETXTBSY on Linux), and the
      # old dist/public/ steps aside to dist/.public.old between two renames
      # (rename cannot replace a non-empty directory), so dist/public/ is
      # missing only for that instant rather than for the whole copy.
      def self.assemble(root, name)
        binary = "#{root}/build/bin/#{name}"
        raise InvalidArgument, "build/bin/#{name} is missing: `spin build #{name}` did not produce it" unless File.exist?(binary)

        dist = "#{root}/dist"
        Templates.mkdir_p(dist)
        binary_tmp = "#{dist}/.#{name}.tmp"
        public_tmp = "#{dist}/.#{DIST_PUBLIC}.tmp"
        public_old = "#{dist}/.#{DIST_PUBLIC}.old"
        # Leftovers of an interrupted earlier run.
        rm_tree(binary_tmp)
        rm_tree(public_tmp)
        rm_tree(public_old)

        copy_command = "cp #{shell_quote(binary)} #{shell_quote(binary_tmp)}"
        raise InvalidArgument, "could not copy #{binary} to dist/" unless system(copy_command)

        File.rename(binary_tmp, "#{dist}/#{name}")

        if File.directory?("#{root}/#{DIST_PUBLIC}")
          public_command = "cp -R #{shell_quote("#{root}/#{DIST_PUBLIC}")} #{shell_quote(public_tmp)}"
          raise InvalidArgument, "could not copy #{DIST_PUBLIC}/ to dist/" unless system(public_command)
        else
          Dir.mkdir(public_tmp)
        end
        public_dir = "#{dist}/#{DIST_PUBLIC}"
        File.rename(public_dir, public_old) if File.exist?(public_dir) || File.symlink?(public_dir)
        File.rename(public_tmp, public_dir)
        rm_tree(public_old)

        Templates.mkdir_p("#{dist}/#{DIST_STORAGE}")
        Templates.mkdir_p("#{dist}/#{DIST_TMP}")
        ["dist/#{name}", "dist/#{DIST_PUBLIC}/", "dist/#{DIST_STORAGE}/", "dist/#{DIST_TMP}/"]
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
