# `cybertrain server` under CRuby: the supervisor of the CRuby preview
# (docs/design.md D87). It
# owns the listening socket for its whole life and runs one child on it at
# a time: the application under CRuby right after a change, the compiled
# binary once the background build has made it. What to do on each event is
# Machine's (machine.rb); the processes, files and held connections are
# Processes' (processes.rb); who another process is (its parent, command
# line, state, whether it is this application's) is in process_table.rb,
# and running a program with its output bounded and its group owned in
# owned_run.rb, both as functions of this module; this file is the startup,
# the loop that feeds the machine its events, and the stop.
#
# Startup: the application's name, the pinned Spinel (Toolchain.ensure!),
# the load path (the -I directories of `spin flags`), the framework's dev
# files (below), the leftovers of a supervisor that was killed
# (tmp/cybertrain-dev/supervisor.pid, child.pid and build.pid), the address
# (`bin/NAME.rb dev-address` under CRuby; a port argument overrides the
# port), the socket, the banner, then the first round. Each refusal prints
# `error: ...` and returns 1 before a child is started.
#
# The framework's dev files (cybertrain/dev/supervision.rb, state_file.rb,
# watcher.rb, watched.rb) come from the application's framework, never from
# the gem, which ships none of them: once `spin flags` has named the
# framework, its -I directories go on $LOAD_PATH ahead of the gem's own, and
# only then are those files (and processes.rb and watch.rb, which build on
# them) required. The supervisor and its children then share one
# definition of the state file's format and of the environment a child
# reads: the child's framework is the authority. The supervisor's own files
# are required relative to this one, so a framework that carries copies of
# them never replaces them.
#
# An application that cannot have the preview is not refused: one line on
# STDERR, `preview unavailable: <reason>; running the compiled loop`, then
# the compiled loop runs, as `cybertrain server --spinel` would. The
# reasons, checked in this order, the first that holds being the one named
# (no_preview_reason): CYBERTRAIN_ENV is set to something other than
# development (a child outside development is not supervised and would
# bind the port the supervisor holds); the framework has no
# cybertrain/preview.rb (a release older than the preview); it has no
# cybertrain/dev/supervision.rb (the children's contract); the `ruby` on
# PATH, which runs the children, is missing, cannot be started, does not
# answer within RUBY_PROBE_TIMEOUT, or cannot load fiddle (the preview's
# FFI shim needs it). The framework is checked before the Ruby: a newer
# framework is the fix there, whatever the Ruby.
#
# The loop is one thread: wait (on the child's STDERR, and on the listener
# while holding) for at most a tick, then Processes#poll, then the machine's
# on_tick. INT, TERM and HUP (a closed terminal) only set a flag; the loop
# then stops the machine (the build, the child, the hold), removes the
# files, closes the socket and returns 0 (TERM and HUP, a stop that was
# asked for), or 130 for INT. gen, which a round runs on this thread, is a
# process group the runner owns and watches the flag while it waits
# (owned_run): a stop stops it within the stop grace and the round starts
# nothing. The start-up probes (dev-address, and gen when the first answer
# fails) run the same way before the flag exists; INT, TERM or HUP then
# raises in them, their group is stopped, and the process ends by that
# signal, as during the probe of the children's Ruby (bounded_run).
#
# Children stay in the supervisor's process group, as `spin run NAME` does
# under today's loop: a Ctrl-C in the terminal reaches the child too, and it
# may die of it before the loop has seen the flag. Such a death is part of
# stopping: once the flag is set no event reaches the machine (Gate).
#
# Required only by exe/cybertrain, never by cybertrain/cli.rb (which Spinel
# compiles for the native CLI). CRuby only.
require "fileutils"
require "open3"
require "socket"
require "cybertrain/version"
require "cybertrain/cli"
require_relative "dev_server/machine"
require_relative "dev_server/process_table"
require_relative "dev_server/owned_run"

module Cybertrain
  module CLI
    module DevServer
      # A refusal at startup: its message follows `error: `.
      Failure = Class.new(StandardError)

      # The supervisor's files in the application.
      DEV_DIR = "tmp/cybertrain-dev"

      # The framework's files the preview needs, in the order they are
      # checked: the FFI shim the CRuby child is started with (-r
      # cybertrain/preview), then the contract a supervised child reads.
      PREVIEW = "cybertrain/preview.rb"
      SUPERVISION = "cybertrain/dev/supervision.rb"

      # The reasons given when the children's Ruby cannot run the preview
      # (child_ruby): it cannot load fiddle, or there is no `ruby` on PATH.
      NO_FIDDLE = "Ruby cannot load fiddle (cybertrain doctor has the details)"
      NO_RUBY = "no ruby on PATH"

      # How long the probe of the children's Ruby (child_ruby) may take. A
      # Ruby starts and loads fiddle in about 0.1 s, a version manager's
      # shim adds a fraction of a second; one still running after this (a
      # shim stuck on a prompt or a lock) is killed, and the server runs
      # the compiled loop, which needs no ruby.
      RUBY_PROBE_TIMEOUT = 10

      # What the banner says when the children's Ruby does not answer.
      UNKNOWN_VERSION = "(unknown version)"

      # The driver's tick: the longest the loop waits before it polls
      # the processes and gives the machine its on_tick.
      TICK = 0.05

      # A leftover child gets this long after TERM before KILL.
      LEFTOVER_GRACE = 5

      # Cybertrain::PortInUse's reasons, restated: that class lives in the
      # framework (cybertrain/http/server.rb), which the gem does not ship.
      # test/cruby/dev_server.rb compares them with the framework's.
      PORT_IN_USE = "is already in use (stop the other server or set PORT)"
      PORT_DENIED = "cannot be bound: permission denied (ports below 1024 need root or a capability)"

      # The runner's events on their way to the machine, until a stop is
      # asked: then a child that dies (of the same Ctrl-C, or of the stop
      # itself) or a build that ends is part of stopping, and nothing is
      # passed on.
      class Gate
        # @param machine [Machine]
        # @param stopping [Proc] true once a stop was asked
        def initialize(machine, &stopping)
          @machine = machine
          @stopping = stopping
        end

        def on_change(paths)
          @machine.on_change(paths) unless @stopping.call
        end

        def on_child_ready(kind, generation)
          @machine.on_child_ready(kind, generation) unless @stopping.call
        end

        def on_child_exit(kind, generation, info)
          @machine.on_child_exit(kind, generation, info) unless @stopping.call
        end

        def on_build_done(generation, ok, output)
          @machine.on_build_done(generation, ok, output) unless @stopping.call
        end
      end

      # `cybertrain server [PORT]` (exe/cybertrain calls this when --spinel
      # is absent). Returns the exit code.
      # @param argv [Array<String>] the command line, "server" first
      # @return [Integer]
      def self.run(argv)
        port_argument = parse(argv)
        root = File.realpath(Dir.pwd)
        name = Build.app_name(root)
        raise Failure, "no spin.toml with a [package] name here; run this inside a cybertrain application" if name == ""
        # As CLI.run_in_app does for the other commands: this entry point
        # does not pass through it.
        problem = FrameworkVersion.problem(root, Cybertrain::VERSION)
        raise Failure, problem unless problem == ""
        return 1 unless ensure_toolchain

        load_path = load_path(spin_flags(root))
        ruby_version = nil
        reason = no_preview_reason(load_path) do
          ruby_version, problem = child_ruby
          problem
        end
        return fall_back(argv, reason) unless reason.nil?

        load_framework(load_path)
        refuse_second_supervisor(root)
        stop_leftover_child(root, name, $stdout, load_path)
        stop_leftover_build(root, name, $stdout)
        host, port = address(root, name, load_path)
        port = Integer(port_argument, 10) unless port_argument == ""
        listener = bind(host, port)
        serve(root, name, load_path, host, listener, ruby_version)
      rescue Failure, InvalidArgument => e
        puts "error: #{e.message}"
        1
      end

      # The -I directories of `spin flags`, in order. spin prints a
      # directory as it is, unquoted, even with a space in it (checked with
      # spin 2026.11.04): a directory runs to the next flag, a word that
      # starts with "-" after a space.
      # @param flags_output [String]
      # @return [Array<String>]
      def self.load_path(flags_output)
        flags = flags_output.strip.split(/\s+(?=-)/)
        flags.select { |flag| flag.start_with?("-I") }.map { |flag| flag.delete_prefix("-I").strip }.reject(&:empty?)
      end

      # Why this application cannot have the CRuby preview, or nil: the
      # first of the header comment's reasons that holds. Each sends
      # `cybertrain server` to the compiled loop rather than refusing it
      # (fall_back). The block answers what keeps the children's Ruby from
      # running the preview (child_ruby's second value), nil when nothing
      # does; it runs only once the framework has passed, since it starts a
      # process.
      # @param load_path [Array<String>] the -I directories of `spin flags`
      # @yieldreturn [String, nil]
      # @return [String, nil]
      def self.no_preview_reason(load_path)
        env = ENV["CYBERTRAIN_ENV"].to_s
        return "CYBERTRAIN_ENV is #{env}, and the preview serves development only" unless env.empty? || env == "development"

        [PREVIEW, SUPERVISION].each do |path|
          next if framework_file?(load_path, path)

          return "this application's cybertrain (#{framework_dir(load_path)}) has no #{path}"
        end
        yield
      end

      # Whether one of the framework's directories holds path (the children
      # are given all of them, so any one will do).
      def self.framework_file?(load_path, path)
        load_path.any? { |dir| File.file?(File.join(dir, path)) }
      end

      # The framework's directory as `spin flags` names it: the first -I
      # directory with a cybertrain/ in it (an application has none).
      # @return [String]
      def self.framework_dir(load_path)
        found = load_path.find { |dir| File.directory?(File.join(dir, "cybertrain")) }
        found || "not among the -I directories of `spin flags`"
      end

      # One line on STDERR, then what `cybertrain server --spinel` runs;
      # its exit code.
      def self.fall_back(argv, reason)
        $stderr.puts "preview unavailable: #{reason}; running the compiled loop"
        $stderr.flush
        compiled_loop(argv)
      end

      # exe/cybertrain hands `server ... --spinel` to CLI.run.
      def self.compiled_loop(argv)
        CLI.run(argv + ["--spinel"])
      end

      # The application's framework ahead of the gem on $LOAD_PATH, then
      # the files that need its dev files (see the header comment).
      # @param load_path [Array<String>] the -I directories of `spin flags`
      def self.load_framework(load_path)
        $LOAD_PATH.unshift(*load_path)
        $LOAD_PATH.uniq!
        require_relative "dev_server/processes"
        nil
      end

      # The pinned Spinel on PATH (a test stands in for it).
      def self.ensure_toolchain
        Toolchain.ensure!
      end

      # What `spin flags` prints in root.
      # @raise [Failure] when spin fails
      def self.spin_flags(root)
        output, status = Open3.capture2e("spin", "flags", chdir: root)
        raise Failure, "`spin flags` failed:\n#{output}" unless status.success?

        output
      rescue SystemCallError => e
        raise Failure, "`spin flags` could not run: #{e.message}"
      end

      # A supervisor.pid naming a live `cybertrain server` means one
      # already serves this application. A PID that is gone, or that now
      # names another program, is a leftover of a killed supervisor.
      def self.refuse_second_supervisor(root)
        pid = read_pid(File.join(root, DEV_DIR, "supervisor.pid"))
        return if pid.nil? || pid == Process.pid || !alive?(pid)
        return unless supervisor?(command_line(pid)) && in_root?(pid, root)

        raise Failure, "a cybertrain server is already running here (pid #{pid})"
      end

      # A child a killed supervisor left still holds the listener (and
      # may run jobs): when child.pid names a live process that is this
      # application's child (application_child?), TERM, then KILL after
      # LEFTOVER_GRACE. Any other process is left alone. A child of the live
      # supervisor named by supervisor.pid is not a leftover: that
      # supervisor is running (started by a command line supervisor? does
      # not know), and this start is refused (refuse_if_supervised).
      # @param root [String] the application's directory
      # @param name [String] the package name
      # @param out [IO] where the line about it goes
      # @param load_path [Array<String>] the -I directories of `spin flags`
      def self.stop_leftover_child(root, name, out, load_path = [])
        path = File.join(root, DEV_DIR, "child.pid")
        pid = read_pid(path)
        return if pid.nil?

        if alive?(pid) && application_child?(pid, root, name, load_path)
          refuse_if_supervised(pid, root)
          out.puts "=> stopping a child left by an earlier cybertrain server (pid #{pid})"
          out.flush
          signal(pid, :TERM)
          deadline = monotonic + LEFTOVER_GRACE
          sleep 0.05 until ended?(pid) || monotonic >= deadline
          unless ended?(pid)
            signal(pid, :KILL)
            sleep 0.05 until ended?(pid) || monotonic >= deadline + 1
          end
        end
        File.delete(path) if File.exist?(path)
        nil
      end

      # A build a killed supervisor left (its process group, in build.pid)
      # may still be writing build/: when the group's leader is this
      # application's build (application_build?), the group is stopped
      # (stop_group) before this supervisor starts one of its own. Any other
      # process is left alone, and a build of the live supervisor named by
      # supervisor.pid refuses this start (refuse_if_supervised).
      #
      # Running or ended, that build was never stamped (Processes'
      # stamp_binary): build/bin/NAME goes back to its launch, which is
      # build.pid's own time (written at the launch), when it is newer. A
      # save made while it ran is then newer than the binary, and the first
      # build of this session compiles it.
      # @param root [String] the application's directory
      # @param name [String] the package name
      # @param out [IO] where the line about it goes
      def self.stop_leftover_build(root, name, out)
        path = File.join(root, DEV_DIR, "build.pid")
        return unless File.exist?(path)

        pgid = read_pid(path)
        if pgid && alive?(pgid) && !ended?(pgid) && application_build?(pgid, root, name)
          refuse_if_supervised(pgid, root)
          out.puts "=> stopping a build left by an earlier cybertrain server (pid #{pgid})"
          out.flush
          stop_group(pgid, LEFTOVER_GRACE) { ended?(pgid) }
          deadline = monotonic + 1
          sleep 0.05 until !group_member?(pgid) || monotonic >= deadline
        end
        stamp_leftover_binary(root, name, path)
        File.delete(path) if File.exist?(path)
        nil
      end

      # build/bin/NAME set back to build.pid's time when it is newer: the
      # rule of Processes#stamp_binary, for a build no runner saw end.
      def self.stamp_leftover_binary(root, name, pid_file)
        launched = File.mtime(pid_file)
        binary = File.join(root, "build", "bin", name)
        File.utime(launched, launched, binary) if File.file?(binary) && File.mtime(binary) > launched
        nil
      rescue SystemCallError
        nil
      end

      # A process a live `cybertrain server` of this application started
      # (its parent is the PID in supervisor.pid) is that server's, not a
      # leftover: refused like a second supervisor (refuse_second_supervisor
      # knows a supervisor by its command line, which a version selector
      # such as `cybertrain _0.4.0_ server` or a wrapper script hides).
      # @raise [Failure]
      def self.refuse_if_supervised(pid, root)
        supervisor = read_pid(File.join(root, DEV_DIR, "supervisor.pid"))
        return if supervisor.nil? || supervisor == Process.pid || !alive?(supervisor)
        return unless parent_pid(pid) == supervisor

        raise Failure, "a cybertrain server is already running here (pid #{supervisor})"
      end

      # How long a build's leader (spin) gets to end after its children
      # were sent TERM: spin then removes its compiler's stderr file
      # ($TMPDIR/spin-compile-PID.err) and exits, which took about 25 ms
      # here (2026-11-13, spin 2026.11.04). TERM to spin itself ends it
      # without that cleanup.
      BUILD_CLEANUP = 0.5

      # Stops the process group pgid, a build: TERM to every member but the
      # leader, so that spin sees its step fail and cleans up; once the
      # leader has ended (the block) or after BUILD_CLEANUP, TERM to the
      # group and, by the end of grace, KILL to whatever is left (a compiler
      # the leader did not wait for). The block must not reap the leader:
      # until it is reaped, its zombie keeps the group's id from being given
      # to another process, and the KILL goes to the group last.
      # @param pgid [Integer] the group, whose leader is the build's spin
      # @param grace [Numeric] the whole time before KILL
      # @yieldreturn [Boolean] whether the leader has ended (a zombie counts)
      def self.stop_group(pgid, grace)
        started = monotonic
        (group_pids(pgid) || []).each { |pid| signal(pid, :TERM) unless pid == pgid }
        sleep 0.01 until yield || monotonic - started >= [BUILD_CLEANUP, grace].min
        unless yield
          signal(-pgid, :TERM)
          sleep 0.01 until yield || monotonic - started >= grace
        end
        # Not to a group with no member left: a leftover's leader is not
        # this process's child, so nothing keeps its id from going to
        # another group once it is reaped.
        signal(-pgid, :KILL) if group_member?(pgid)
        nil
      end

      # Host and port as the application's config gives them, from
      # `bin/NAME.rb dev-address` under CRuby. bin/NAME.rb requires gen/,
      # which may be stale here (a model renamed while no server ran, gen/
      # not committed): when the first answer fails and `cybertrain build`
      # does not hold its lock, gen runs once and the application is asked
      # again. An application that still cannot be loaded here cannot be
      # previewed: --spinel still runs it compiled.
      def self.address(root, name, load_path)
        found, text = ask_address(root, name, load_path)
        return found unless found.nil?

        unless Processes.build_locked?(root)
          gen_out, _, gen_status = owned_run(child_env, ruby_prefix(load_path) + ["bin/gen.rb"], root, probe_grace, true, NEVER)
          if gen_status.success?
            found, text = ask_address(root, name, load_path)
            return found unless found.nil?
          else
            text = "#{text}\nbin/gen.rb failed too:\n#{gen_out.strip}"
          end
        end
        raise Failure, "bin/#{name}.rb does not load under CRuby, so it cannot be previewed:\n#{text}\n" \
                       "`cybertrain server --spinel` runs it compiled, without the CRuby preview."
      rescue SystemCallError => e
        raise Failure, "could not run ruby for the CRuby preview: #{e.message}"
      end

      # One `dev-address`: [[host, port], ""], or [nil, what it printed].
      def self.ask_address(root, name, load_path)
        command = ["ruby"] + cruby_child_args(load_path, name) + ["dev-address"]
        out, err, status = owned_run(child_env, command, root, probe_grace, false, NEVER)
        match = out.lines.map(&:strip).reject(&:empty?).last.to_s.match(/\A(\S+) (\d+)\z/)
        return [[match[1], match[2].to_i], ""] if status.success? && match

        [nil, [err, out].map(&:strip).reject(&:empty?).join("\n")]
      end

      # How long a start-up probe (gen, dev-address) gets after TERM before
      # KILL: a stopped child's grace.
      def self.probe_grace
        Processes::STOP_GRACE
      end

      # What every child, gen and dev-address add to the environment:
      # development unless CYBERTRAIN_ENV is set (no_preview_reason sends
      # any other value to the compiled loop).
      # @return [Hash{String => String}]
      def self.child_env
        env = {}
        env["CYBERTRAIN_ENV"] = "development" if ENV["CYBERTRAIN_ENV"].to_s.empty?
        env
      end

      # `ruby -E UTF-8 -I<dir>...`: `-E UTF-8` whatever the
      # locale, since the application's sources and templates are UTF-8, as
      # the compiled binary takes them.
      # @param load_path [Array<String>] the -I directories of `spin flags`
      # @return [Array<String>]
      def self.ruby_prefix(load_path)
        ["ruby", "-E", "UTF-8"] + load_path.map { |dir| "-I#{dir}" }
      end

      # The supervisor's socket, held for its whole life.
      def self.bind(host, port)
        TCPServer.new(host, port)
      rescue Errno::EADDRINUSE
        raise Failure, "port #{port} on #{host} #{PORT_IN_USE}"
      rescue Errno::EACCES
        raise Failure, "port #{port} on #{host} #{PORT_DENIED}"
      rescue SocketError, SystemCallError => e
        raise Failure, "cannot listen on #{host} port #{port}: #{e.message}"
      end

      # The runner the loop drives (a test may hand in another).
      def self.new_runner(**options)
        Processes.new(**options)
      end

      # From the bound socket to the stop: the banner, the first round, the
      # loop. Returns 0 (TERM, HUP), or 130 when INT stopped it.
      # @param ruby_version [String] the children's Ruby, for the banner
      def self.serve(root, name, load_path, host, listener, ruby_version = child_ruby[0])
        stop = nil
        previous = {}
        machine = nil
        runner = nil
        begin
          dev = File.join(root, DEV_DIR)
          FileUtils.mkdir_p(dev)
          File.write(File.join(dev, "supervisor.pid"), Process.pid.to_s)
          previous[:INT] = trap(:INT) { stop ||= :INT }
          previous[:TERM] = trap(:TERM) { stop ||= :TERM }
          # A closed terminal: the same stop as TERM, files and build
          # included, rather than death by the default action.
          previous[:HUP] = trap(:HUP) { stop ||= :HUP }
          port = listener.addr[1]
          puts "=> Booting cybertrain #{Cybertrain::VERSION}"
          puts "=> preview: CRuby #{ruby_version}"
          puts "* Listening on http://#{host}:#{port}"
          $stdout.flush
          runner = new_runner(root: root, name: name, port: port, load_path: load_path,
                              listener: listener, out: $stdout, err: $stderr, stopping: -> { !stop.nil? })
          runner.watch
          machine = Machine.new(runner)
          gate = Gate.new(machine) { !stop.nil? }
          machine.start
          runner.start_watching
          until stop
            runner.wait_for_activity(TICK)
            break if stop

            runner.poll(gate)
            break if stop

            machine.on_tick
          end
        ensure
          every_step(
            -> { machine&.stop },
            # A stop that raised may have left the build or the child: each
            # is stopped on its own (a no-op once the machine's stop did
            # it), before close removes the PID files that name them.
            -> { runner&.cancel_build },
            -> { runner&.stop_child },
            lambda do
              if runner
                runner.close
              else
                File.delete(File.join(root, DEV_DIR, "supervisor.pid")) rescue nil
              end
            end,
            -> { listener.close },
            -> { previous.each { |signal, handler| trap(signal, handler || "DEFAULT") } }
          )
        end
        stop == :INT ? 130 : 0
      end

      # Runs every step, even after one raises (a stop that fails must
      # still remove the files and close the socket), then raises the first
      # error.
      # @param steps [Array<Proc>]
      def self.every_step(*steps)
        error = nil
        steps.each do |step|
          step.call
        rescue Exception => e # Interrupt included: re-raised below, after the rest
          error ||= e
        end
        raise error unless error.nil?

        nil
      end

      # What the children's Ruby is, asked once at start in one run of the
      # `ruby` on PATH: under a version manager it can be another CRuby
      # than the one running this supervisor. Its version (for the banner)
      # and what keeps it from running the preview (no_preview_reason): nil
      # when it loads fiddle; NO_RUBY when there is no `ruby` on PATH; a
      # line saying it cannot be started, and why, when there is one that
      # cannot (not executable, its #! interpreter missing or not
      # executable, or no pipe to ask it through); a line naming the bound
      # when it has not answered within timeout seconds (it is killed, with
      # whatever it started); NO_FIDDLE when it does not load fiddle, or
      # fails. The version is UNKNOWN_VERSION unless the Ruby answered.
      # @param timeout [Numeric] RUBY_PROBE_TIMEOUT (a test shortens it)
      # @return [Array(String, String|nil)]
      def self.child_ruby(timeout = RUBY_PROBE_TIMEOUT)
        script = "print RUBY_VERSION; print(begin; require 'fiddle'; ' fiddle'; rescue LoadError, StandardError; ''; end)"
        out, status = bounded_run(["ruby", "-e", script], timeout)
        return [UNKNOWN_VERSION, NO_RUBY] if status == :missing
        return [UNKNOWN_VERSION, "the ruby on PATH cannot be started (#{out})"] if status == :failed
        return [UNKNOWN_VERSION, "the ruby on PATH did not answer within #{timeout} s"] if status == :timeout

        version, fiddle = out.split
        return [UNKNOWN_VERSION, NO_FIDDLE] unless status.is_a?(Process::Status) && status.success? && version

        [version, fiddle == "fiddle" ? nil : NO_FIDDLE]
      end

      # [PORT] after "server": "" or a valid port string. --spinel never
      # reaches here (exe/cybertrain sends it to CLI.run).
      def self.parse(argv)
        port = argv.size > 1 ? argv[1] : ""
        raise Failure, "PORT must be a number" unless port == "" || Build.port?(port)
        raise Failure, "unexpected argument '#{argv[2]}'" if argv.size > 2

        port
      end

      def self.signal(pid, name)
        Process.kill(name, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def self.monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
