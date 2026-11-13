# `cybertrain server` under CRuby: the supervisor of
# docs/superpowers/specs/2026-11-12-cruby-preview-design.md section 6. It
# owns the listening socket for its whole life and runs one child on it at
# a time: the application under CRuby right after a change, the compiled
# binary once the background build has made it. What to do on each event is
# Machine's (machine.rb); the processes, files and held connections are
# Processes' (processes.rb); this file is the startup, the loop that feeds
# the machine its events, and the stop.
#
# Startup: the application's name, the pinned Spinel (Toolchain.ensure!),
# the load path (the -I directories of `spin flags`), the framework's dev
# files (below), the leftovers of a supervisor that was killed
# (tmp/cybertrain-dev/supervisor.pid and child.pid), the address
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
# them never replaces them. A framework without a CRuby preview (an older
# one) is not refused: one line on STDERR names the reason and the compiled
# loop runs, as `cybertrain server --spinel` would (no_preview_reason).
#
# The loop is one thread: wait (on the child's STDERR, and on the listener
# while holding) for at most a tick, then Processes#poll, then the machine's
# on_tick. INT and TERM only set a flag; the loop then stops the machine
# (the build, the child, the hold), removes the files, closes the socket and
# returns 0, or 130 for INT.
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

module Cybertrain
  module CLI
    module DevServer
      # A refusal at startup: its message follows `error: `.
      Failure = Class.new(StandardError)

      # The supervisor's files in the application (P2).
      DEV_DIR = "tmp/cybertrain-dev"

      # The framework file whose absence means the framework predates the
      # CRuby preview (its supervised children read this contract).
      SUPERVISION = "cybertrain/dev/supervision.rb"

      # The driver's tick (P11): the longest the loop waits before it polls
      # the processes and gives the machine its on_tick.
      TICK = 0.05

      # A leftover child (P14) gets this long after TERM before KILL.
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
        return 1 unless ensure_toolchain

        load_path = load_path(spin_flags(root))
        reason = no_preview_reason(load_path)
        return fall_back(argv, reason) unless reason.nil?

        load_framework(load_path)
        refuse_second_supervisor(root)
        stop_leftover_child(root, name, $stdout)
        host, port = address(root, name, load_path)
        port = Integer(port_argument, 10) unless port_argument == ""
        listener = bind(host, port)
        serve(root, name, load_path, host, listener)
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

      # Why this application cannot have the CRuby preview, or nil. Each
      # reason here sends `cybertrain server` to the compiled loop rather
      # than refusing it (fall_back).
      # @param load_path [Array<String>] the -I directories of `spin flags`
      # @return [String, nil]
      def self.no_preview_reason(load_path)
        return "this application's framework has no CRuby preview" unless framework_file?(load_path, SUPERVISION)

        nil
      end

      # Whether one of the framework's directories holds path.
      def self.framework_file?(load_path, path)
        load_path.any? { |dir| File.file?(File.join(dir, path)) }
      end

      # One line on STDERR, then what `cybertrain server --spinel` runs;
      # its exit code.
      def self.fall_back(argv, reason)
        $stderr.puts "cybertrain: #{reason}; running the compiled loop (--spinel)"
        $stderr.flush
        compiled_loop(argv)
      end

      # exe/cybertrain hands `server ... --spinel` to CLI.run (P8).
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

      # P14: a supervisor.pid naming a live `cybertrain server` means one
      # already serves this application. A PID that is gone, or that now
      # names another program, is a leftover of a killed supervisor.
      def self.refuse_second_supervisor(root)
        pid = read_pid(File.join(root, DEV_DIR, "supervisor.pid"))
        return if pid.nil? || pid == Process.pid || !alive?(pid)
        return unless command_line(pid).match?(/cybertrain\S*\s+server(\s|\z)/)

        raise Failure, "a cybertrain server is already running here (pid #{pid})"
      end

      # P14: a child a killed supervisor left still holds the listener (and
      # may run jobs): when child.pid names a live process whose command
      # line is this application's (bin/NAME.rb or build/bin/NAME), TERM,
      # then KILL after LEFTOVER_GRACE. Any other process is left alone.
      # @param root [String] the application's directory
      # @param name [String] the package name
      # @param out [IO] where the line about it goes
      def self.stop_leftover_child(root, name, out)
        path = File.join(root, DEV_DIR, "child.pid")
        pid = read_pid(path)
        return if pid.nil?

        command = alive?(pid) ? command_line(pid) : ""
        if command.include?("bin/#{name}.rb") || command.include?("build/bin/#{name}")
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

      # P10: host and port as the application's config gives them, from
      # `bin/NAME.rb dev-address` under CRuby. An application that cannot
      # be loaded here cannot be previewed: --spinel still runs it compiled.
      def self.address(root, name, load_path)
        env = {}
        env["CYBERTRAIN_ENV"] = "development" if ENV["CYBERTRAIN_ENV"].to_s.empty?
        command = ["ruby", "-E", "UTF-8"] + load_path.map { |dir| "-I#{dir}" } +
                  ["-r", "cybertrain/preview", "bin/#{name}.rb", "dev-address"]
        out, err, status = Open3.capture3(env, *command, chdir: root, stdin_data: "")
        match = out.lines.map(&:strip).reject(&:empty?).last.to_s.match(/\A(\S+) (\d+)\z/)
        return [match[1], match[2].to_i] if status.success? && match

        text = [err, out].map(&:strip).reject(&:empty?).join("\n")
        raise Failure, "bin/#{name}.rb does not load under CRuby, so it cannot be previewed:\n#{text}\n" \
                       "`cybertrain server --spinel` runs it compiled, without the CRuby preview."
      rescue SystemCallError => e
        raise Failure, "could not run ruby for the CRuby preview: #{e.message}"
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
      # loop. Returns 0, or 130 when INT stopped it.
      def self.serve(root, name, load_path, host, listener)
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
          port = listener.addr[1]
          puts "=> Booting cybertrain #{Cybertrain::VERSION}"
          puts "=> preview: CRuby #{RUBY_VERSION}"
          puts "* Listening on http://#{host}:#{port}"
          $stdout.flush
          runner = new_runner(root: root, name: name, port: port, load_path: load_path,
                              listener: listener, out: $stdout, err: $stderr)
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
          machine&.stop
          if runner
            runner.close
          else
            File.delete(File.join(root, DEV_DIR, "supervisor.pid")) rescue nil
          end
          listener.close
          previous.each { |signal, handler| trap(signal, handler || "DEFAULT") }
        end
        stop == :INT ? 130 : 0
      end

      # [PORT] after "server": "" or a valid port string. --spinel never
      # reaches here (exe/cybertrain sends it to CLI.run).
      def self.parse(argv)
        port = argv.size > 1 ? argv[1] : ""
        raise Failure, "PORT must be a number" unless port == "" || Build.port?(port)
        raise Failure, "unexpected argument '#{argv[2]}'" if argv.size > 2

        port
      end

      # Whether pid names a running process. Signal 0 probes without
      # delivering anything; EPERM means it exists but is someone else's.
      # @param pid [Integer]
      # @return [Boolean]
      def self.alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def self.read_pid(path)
        text = File.read(path).strip
        text.match?(/\A[0-9]+\z/) ? text.to_i : nil
      rescue SystemCallError
        nil
      end

      # The process's command line, "" when it cannot be read. `ps` works
      # on Linux and macOS alike.
      def self.command_line(pid)
        IO.popen(["ps", "-o", "args=", "-p", pid.to_s], err: File::NULL, &:read).strip
      rescue SystemCallError
        ""
      end

      # Gone, or a zombie: a leftover is not this process's child, so its
      # parent (or init) reaps it.
      def self.ended?(pid)
        return true unless alive?(pid)

        stat = IO.popen(["ps", "-o", "stat=", "-p", pid.to_s], err: File::NULL, &:read).strip
        stat.empty? || stat.start_with?("Z")
      rescue SystemCallError
        true
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
