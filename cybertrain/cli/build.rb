# `cybertrain build`: dist/ = the app binary with app/views embedded, plus
# public/. Also the command lists `cybertrain db` and `server` run. Plain Ruby:
# runs under CRuby (the gem) and compiles under Spinel (spin install).
require "cybertrain/app_name"
require "cybertrain/shell"

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
        # An empty name is run_in_app's "no spin.toml with a [package] name".
        # Any other name must be usable as a `spin build` target and a
        # build/bin/<name> path: the same predicate Application.new applies to
        # the dev rebuilder's target. The name reaches the shell through
        # quote_arg, so only what breaks that target or path is refused.
        return "" if name.empty?

        problem = AppName.problem(name)
        raise InvalidArgument, "spin.toml [package] name '#{name}' #{problem}" unless problem.empty?

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
      # command strings stay safe for a caller that skipped that, whatever the
      # spelling. An empty name cannot reach these from the CLI (run_in_app
      # refuses it first); a direct caller passing "" gets `spin build ''`.
      # gen is built in debug mode (Shell::TOOL_SPIN), the application in
      # release mode.
      def self.commands(name)
        ["#{Shell::TOOL_SPIN} run gen -- --embed-views", "spin build #{quote_arg(name)}", "#{Shell::TOOL_SPIN} run gen"]
      end

      # `cybertrain db ARGS`, through bin/db.rb (the app binary cannot compile
      # before the first migration has produced gen/models). bin/db.rb only
      # knows the migrations gen/migrations.rb lists, so gen runs first;
      # migrate and rollback rewrite db/schema.rb, which gen/models is
      # derived from, so gen runs again after them. Both tools are built in
      # debug mode (Shell::TOOL_SPIN).
      def self.db_commands(args)
        words = args.map { |arg| quote_arg(arg) }.join(" ")
        gen = "#{Shell::TOOL_SPIN} run gen"
        commands = [gen, "#{Shell::TOOL_SPIN} run db -- #{words}"]
        commands << gen if args[0] == "migrate" || args[0] == "rollback"
        commands
      end

      # `cybertrain migration`: the same as `cybertrain db migrate`.
      def self.migration_commands
        db_commands(["migrate"])
      end

      # A word sh reads as itself stays bare; anything else is single-quoted.
      def self.quote_arg(text)
        return text if !text.empty? && text.match(/\A[A-Za-z0-9_:.\/-]+\z/)

        Shell.quote(text)
      end

      # port is "" (the app's default, 3000) or a port? string. The gen step
      # and the run step; run_server puts incremental_command between them
      # when the binary is stale.
      def self.server_commands(name, port)
        target = quote_arg(name)
        run = port == "" ? "spin run #{target}" : "spin run #{target} -- #{quote_arg(port)}"
        ["#{Shell::TOOL_SPIN} run gen", run]
      end

      # The build the development rebuilder runs after an edit
      # (Dev::Rebuilder#command): Spinel compiles the C units apart and
      # reuses the objects in its cache, which a plain `spin run NAME` (every
      # unit at -O2) neither reads nor fills. spin then reads the binary as
      # up to date, so the `spin run NAME` after it only starts it.
      def self.incremental_command(name)
        "spin build #{quote_arg(name)} -- --incremental"
      end

      # Top-level entries of an application binary_stale? does not look in,
      # besides those whose name starts with "." (.git, .bundle, .venv):
      # build output, data, and trees that hold no source of the
      # application and can be very large.
      STALE_SKIPPED = ["build", "dist", "tmp", "storage", "public", "node_modules"]

      # True when root/build/bin/NAME is missing, or a *.rb file under root
      # (not under STALE_SKIPPED or a top-level dot directory, not through a
      # symlinked directory) is as new as it or newer: spin's own rule for
      # rebuilding an executable, close enough. "As new" counts because some
      # filesystems keep whole seconds, and an edit in the second of the
      # build would otherwise read as built.
      # Wrong either way costs only time: a stale verdict by mistake is one
      # incremental build `spin run` would have skipped; a fresh one by
      # mistake (a path dependency changed) leaves the build to `spin run`.
      # A directory that cannot be listed is passed over (a volume owned by
      # another user would otherwise make every start a build); a binary
      # that cannot be read counts as stale.
      def self.binary_stale?(root, name)
        binary = "#{root}/build/bin/#{name}"
        return true unless File.file?(binary)

        newer_ruby?(root, mtime_ns(binary), true)
      rescue StandardError
        true
      end

      # True when a *.rb file under dir is no older than since (nanoseconds).
      def self.newer_ruby?(dir, since, top)
        children = listing(dir)
        i = 0
        while i < children.size
          child = children[i]
          i += 1
          next if top && (STALE_SKIPPED.include?(child) || child.start_with?("."))

          path = "#{dir}/#{child}"
          if File.directory?(path)
            next if File.symlink?(path)
            return true if newer_ruby?(path, since, false)
          elsif child.end_with?(".rb") && File.file?(path)
            return true if mtime_ns(path) >= since
          end
        end
        false
      end

      # The entries of dir, or none when it cannot be listed.
      def self.listing(dir)
        Dir.children(dir)
      rescue StandardError
        Array.new(0) { "" }
      end

      def self.mtime_ns(path)
        time = File.mtime(path)
        time.to_i * 1_000_000_000 + time.nsec
      end

      # `cybertrain server`: gen, then, when the binary is stale, the
      # incremental build, then the server. Stops at the first step that
      # fails and returns 1; 0 when the server exits 0.
      def self.run_server(root, name, port, runner = Runner.new)
        steps = server_commands(name, port)
        return 1 unless runner.run_step(root, steps[0])
        return 1 if binary_stale?(root, name) && !runner.run_step(root, incremental_command(name))

        runner.run_step(root, steps[1]) ? 0 : 1
      end

      # All digits, 1 to 65535 (the app reads 0 as "no port").
      def self.port?(text)
        return false if text.empty? || text.size > 5
        return false unless text.bytes.all? { |b| b >= 48 && b <= 57 }

        text.to_i >= 1 && text.to_i <= 65535
      end

      # Runs one build step (a spin command) in root; true when it succeeds.
      # Build.run and Build.run_server take a Runner so tests can stand in
      # for spin.
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
        system("cd #{Shell.quote(root)} && #{command}")
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

        copy_command = "cp #{Shell.quote(binary)} #{Shell.quote(binary_tmp)}"
        raise InvalidArgument, "could not copy #{binary} to dist/" unless system(copy_command)

        File.rename(binary_tmp, "#{dist}/#{name}")

        if File.directory?("#{root}/#{DIST_PUBLIC}")
          public_command = "cp -R #{Shell.quote("#{root}/#{DIST_PUBLIC}")} #{Shell.quote(public_tmp)}"
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
    end
  end
end
