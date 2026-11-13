require "fileutils"
require "open3"
require "socket"
require "io/nonblock"
# The supervisor's own files, relative to this one; the framework's dev
# files by name, from the application's framework, which DevServer.run has
# put ahead of the gem on $LOAD_PATH (dev_server.rb's header comment).
require_relative "../build"
require_relative "../dev_server"
require_relative "holding"
require_relative "watch"
require "cybertrain/dev/supervision"
require "cybertrain/dev/state_file"

module Cybertrain
  module CLI
    module DevServer
      # The runner Machine expects (its header comment is the contract), with
      # real processes: gen under CRuby, one child at a time on the
      # supervisor's listener (the application under CRuby, or the compiled
      # binary), the Spinel build in a process group of its own, the hold
      # page, the state file, and the file watch. #poll is one tick of the
      # driver: it turns what happened since the last tick into the
      # machine's events.
      #
      # Events go to the machine only for the child process this runner owns
      # right now, identified by its PID: a child it stopped itself is
      # forgotten before it is signalled, and reaped by its own PID, so its
      # end is never seen by #poll. The machine knows children by kind and
      # generation only, and after a failed binary starts a CRuby child at
      # the same generation, so the late exit of an old process would read
      # as the new one's death. The same holds for the build: a cancelled
      # build is never reported. After the machine's stop (which cancels the
      # build and stops the child) nothing is owned and nothing is reported.
      #
      # The files (docs/superpowers/specs/2026-11-12-cruby-preview-design.md
      # section 6), all under tmp/cybertrain-dev/: state (the only channel
      # to the child), ready and failure (the child's answers), child.pid
      # and supervisor.pid (so that the next `cybertrain server` can find
      # what a killed supervisor left). #close removes them; ffi/ (the
      # preview's compiled libraries) stays.
      #
      # The children's commands come from #child_command, #gen_command and
      # #build_command, which a test overrides with stand-in scripts. CRuby
      # only, never compiled by Spinel.
      class Processes
        FILES = ["state", "ready", "failure", "child.pid", "supervisor.pid"].freeze

        # The bounds (P11): a child must write its ready file within
        # READY_TIMEOUT seconds; a stopped child gets STOP_GRACE seconds after
        # TERM before KILL; the file watch polls every WATCH_INTERVAL.
        READY_TIMEOUT = 30
        STOP_GRACE = 10
        WATCH_INTERVAL = 0.1

        # How much of a child's STDERR is kept for the page about its death.
        STDERR_LINES = 40

        # Which children's STDERR goes through a pipe the supervisor copies
        # (and keeps the tail of). A kind left out writes straight to the
        # supervisor's STDERR, and its death is known from the failure file
        # and the exit status alone. Both kinds are piped because the pipe
        # does not delay either (measured 2026-11-13 on examples/blog, a line
        # written to $stderr while a request is handled, 20 requests each):
        # the line reached the supervisor's STDERR before the response had
        # been read, at worst 1.1 ms before it from the CRuby child and
        # 0.6 ms before it from the compiled binary, whose runtime leaves C's
        # stderr unbuffered.
        PIPED_STDERR = [:cruby, :binary].freeze

        # Dev::Rebuilder's rule, restated (that file pulls in framework files
        # the gem does not ship): a lock older than this is abandoned.
        STALE_LOCK_AGE = 30 * 60

        # What spinel says to a flag it does not know
        # (Dev::Rebuilder::UNSUPPORTED_INCREMENTAL).
        UNSUPPORTED_INCREMENTAL = "unknown option '--incremental'"

        BUILD_LOG = "tmp/rebuild.log"

        # The process this runner owns: what it is, the STDERR pipe it reads
        # (nil when not piped), and the last lines that came through it.
        Child = Struct.new(:pid, :kind, :generation, :started, :stderr, :partial, :tail, :ready)
        Job = Struct.new(:pid, :generation, :incremental)

        attr_accessor :ready_timeout, :stop_grace, :watch_interval
        attr_reader :root, :name, :port, :out, :err

        # @param root [String] the application's directory, absolute
        # @param name [String] the spin.toml package name (bin/NAME.rb)
        # @param port [Integer] the port the children are given
        # @param load_path [Array<String>] the -I directories of `spin flags`
        # @param listener [TCPServer] the supervisor's socket, inherited by every child
        # @param out [IO] the supervisor's log lines (and the children's STDOUT when it is an IO)
        # @param err [IO] where the children's STDERR is copied as it arrives
        def initialize(root:, name:, port:, load_path:, listener:, out:, err:)
          @root = root
          @name = name
          @port = port
          @load_path = load_path
          @listener = listener
          @out = out
          @err = err
          @ready_timeout = READY_TIMEOUT
          @stop_grace = STOP_GRACE
          @watch_interval = WATCH_INTERVAL
          @child = nil
          @spawn_failure = nil
          @build = nil
          @incremental = true
          @hold = nil
          @desk = Holding::Desk.new
          @watch = nil
        end

        # --- the commands ----------------------------------------------------

        # `-E UTF-8` whatever the locale: the application's sources and
        # templates are UTF-8, as the compiled binary takes them.
        def ruby_prefix
          ["ruby", "-E", "UTF-8"] + @load_path.map { |dir| "-I#{dir}" }
        end

        # The CRuby child or the compiled binary; the port is the only argument.
        def child_command(kind)
          return ["build/bin/#{@name}", @port.to_s] if kind == :binary

          ruby_prefix + ["-r", "cybertrain/preview", "bin/#{@name}.rb", @port.to_s]
        end

        def gen_command
          ruby_prefix + ["bin/gen.rb"]
        end

        # gen has already run under CRuby: spin only compiles.
        def build_command(incremental)
          command = ["spin", "build", @name]
          incremental ? command + ["--", "--incremental"] : command
        end

        # Whether this kind of child's STDERR goes through the copied pipe.
        def pipe_stderr?(kind)
          PIPED_STDERR.include?(kind)
        end

        # --- files ---------------------------------------------------------------

        def dev_dir
          File.join(@root, DEV_DIR)
        end

        def dev_path(file)
          File.join(dev_dir, file)
        end

        # The PID of the child this runner owns, or nil.
        def child_pid
          @child&.pid
        end

        # The PID of the build in progress, or nil.
        def build_pid
          @build&.pid
        end

        # --- the runner (Machine's contract) ----------------------------------

        def run_gen
          output, status = Open3.capture2e(child_env, *gen_command, chdir: @root)
          # The rewritten gen/ files are not a change: this round made them.
          @watch&.settle
          ok = status.success?
          unless ok
            @err.write("=> gen failed:\n#{output}")
            @err.flush
          end
          [ok, output]
        end

        def start_child(kind, generation)
          stop_child
          FileUtils.mkdir_p(dev_dir)
          ["ready", "failure"].each { |file| delete_file(dev_path(file)) }
          reader, writer = IO.pipe if pipe_stderr?(kind)
          # The listener and the pipe are shared with the child as open file
          # descriptions: CRuby makes both non-blocking (accept_nonblock
          # while holding does it to the listener), and a compiled child
          # would then see EAGAIN from accept and write.
          @listener.nonblock = false
          writer.nonblock = false if writer
          options = { chdir: @root, in: :in, out: child_out, err: writer || unpiped_err,
                      @listener.fileno => @listener.fileno }
          pid = Process.spawn(supervised_env(generation), *child_command(kind), options)
          writer&.close
          @child = Child.new(pid, kind, generation, now, reader, +"", [], false)
          write_file(dev_path("child.pid"), pid.to_s)
          nil
        rescue SystemCallError => e
          # A command that cannot be started at all dies at once, as far as
          # the machine can tell: the next #poll reports it.
          [reader, writer].each { |io| io.close if io && !io.closed? }
          @child = nil
          @spawn_failure = [kind, generation, "could not start #{child_command(kind).first}: #{e.message}"]
          nil
        end

        # TERM, then KILL after the grace; returns once the child is gone.
        # The child is forgotten first, so no event is ever delivered for it.
        def stop_child
          @spawn_failure = nil
          child = @child
          return nil if child.nil?

          @child = nil
          signal(child.pid, :TERM)
          deadline = now + @stop_grace
          status = nil
          loop do
            status = reap(child.pid)
            break if status || now >= deadline

            # A child blocked on a full STDERR pipe would never exit.
            pause(child, 0.01)
          end
          unless status
            signal(child.pid, :KILL)
            wait_pid(child.pid)
          end
          finish(child)
          nil
        end

        def start_build(generation)
          cancel_build
          @build = Job.new(spawn_build, generation, @incremental)
          nil
        end

        # The whole process group: spin, spinel and the C compiler. The build
        # is forgotten, so its end is never reported.
        def cancel_build
          build = @build
          return nil if build.nil?

          @build = nil
          signal(-build.pid, :KILL)
          wait_pid(build.pid)
          nil
        end

        def hold(title, text)
          @hold = [title, text]
          nil
        end

        # Holding ends: the connections still waiting get the page they
        # asked under, and from now on the listener is the child's.
        def release_hold
          @desk.flush(holding_page) unless @hold.nil?
          @hold = nil
          nil
        end

        def holding?
          !@hold.nil?
        end

        def write_state(generation, serving, build, output)
          FileUtils.mkdir_p(dev_dir)
          write_file(dev_path("state"), Dev::StateFile.format(generation, serving, build, output))
        end

        # A terminal that was closed (HUP) answers writes with EIO: the line
        # is lost, and the stop that follows must not be.
        def log(line)
          @out.puts(line)
          @out.flush
          nil
        rescue IOError, SystemCallError
          nil
        end

        # Dev::Rebuilder#build_in_progress?, restated: a lock older than
        # STALE_LOCK_AGE is stale; a lock without a PID (or with something
        # else than digits) counts; a lock whose PID is gone is stale. A
        # stale lock is removed.
        def build_locked?
          path = Build.lock_path(@root)
          return false unless File.exist?(path)

          if Time.now - File.mtime(path) >= STALE_LOCK_AGE
            delete_file(path)
            return false
          end

          pid = File.read(path).strip
          return true if pid.empty? || !pid.match?(/\A[0-9]+\z/)
          return true if DevServer.alive?(pid.to_i)

          delete_file(path)
          false
        rescue SystemCallError
          # The lock vanished between the checks: the build has finished.
          false
        end

        # P16: a change queued for the machine, or seen by the watcher and
        # not yet queued, or a watched file that differs from the watcher's
        # baseline right now (Watch#pending?).
        def change_pending?
          @watch.nil? ? false : @watch.pending?
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # --- the driver ------------------------------------------------------

        # The file watch, created (and its baseline taken) on first use;
        # #start_watching starts its polling.
        def watch
          @watch ||= Watch.new(@root, @watch_interval)
        end

        def start_watching
          watch.settle
          watch.start_watching
        end

        # Blocks until the child writes to STDERR, a connection arrives while
        # holding, or timeout seconds pass.
        def wait_for_activity(timeout)
          ios = []
          ios << @child.stderr if @child&.stderr && !@child.stderr.closed?
          if holding?
            ios << @listener
            ios.concat(@desk.ios)
          end
          ios.empty? ? sleep(timeout) : IO.select(ios, nil, nil, timeout)
          nil
        rescue IOError
          nil
        end

        # One tick: a queued change, the child's STDERR, readiness, exit and
        # the ready bound, the build's end, and the held connections.
        def poll(machine)
          paths = @watch&.take
          unless paths.nil?
            begin
              machine.on_change(paths)
            ensure
              @watch.delivered
            end
          end
          poll_spawn_failure(machine)
          poll_child(machine)
          poll_build(machine)
          if holding?
            @desk.accept(@listener)
            @desk.serve(holding_page)
          else
            @desk.drain
          end
          nil
        end

        # Stops the file watch, closes held connections and removes the
        # files of P2 (the build and the child are the machine's to stop).
        def close
          @watch&.close
          @desk.close
          FILES.each { |file| delete_file(dev_path(file)) }
          delete_file(dev_path("state.tmp"))
          nil
        end

        private

        def child_env
          env = {}
          env["CYBERTRAIN_ENV"] = "development" if ENV["CYBERTRAIN_ENV"].to_s.empty?
          env
        end

        # The five variables of Dev::Supervision (P9).
        def supervised_env(generation)
          child_env.merge(
            Dev::Supervision::LISTEN_FD => @listener.fileno.to_s,
            Dev::Supervision::READY_FILE => dev_path("ready"),
            Dev::Supervision::STATE_FILE => dev_path("state"),
            Dev::Supervision::FAILURE_FILE => dev_path("failure"),
            Dev::Supervision::GENERATION => generation.to_s
          )
        end

        # A child's STDOUT is the supervisor's terminal; a test's StringIO
        # has no descriptor to give it.
        def child_out
          @out.is_a?(IO) ? @out : File::NULL
        end

        def unpiped_err
          @err.is_a?(IO) ? @err : File::NULL
        end

        def spawn_build
          FileUtils.mkdir_p(File.join(@root, "tmp"))
          Process.spawn(child_env, *build_command(@incremental),
                        chdir: @root, in: File::NULL, [:out, :err] => [File.join(@root, BUILD_LOG), "w"],
                        pgroup: true)
        end

        def poll_spawn_failure(machine)
          failure = @spawn_failure
          return if failure.nil?

          @spawn_failure = nil
          machine.on_child_exit(*failure)
        end

        def poll_child(machine)
          child = @child
          return if child.nil?

          copy_stderr(child)
          if !child.ready && ready?(child)
            child.ready = true
            machine.on_child_ready(child.kind, child.generation)
            return unless @child.equal?(child)
          end
          status = reap(child.pid)
          if status
            @child = nil
            finish(child)
            machine.on_child_exit(child.kind, child.generation, exit_info(child, status))
          elsif !child.ready && now - child.started >= @ready_timeout
            stop_child
            machine.on_child_exit(child.kind, child.generation, "did not become ready in #{seconds(@ready_timeout)} s")
          end
        end

        def poll_build(machine)
          build = @build
          return if build.nil?

          status = reap(build.pid)
          return unless status

          ok = status != :gone && status.success?
          output = read_build_log
          if !ok && build.incremental && output.include?(UNSUPPORTED_INCREMENTAL)
            # The toolchain predates --incremental: build again without it,
            # and keep to that for the rest of the process.
            @incremental = false
            @build = Job.new(spawn_build, build.generation, false)
            return
          end
          @build = nil
          machine.on_build_done(build.generation, ok, output)
        end

        def ready?(child)
          File.read(dev_path("ready")).strip == child.generation.to_s
        rescue SystemCallError
          false
        end

        # Waits up to seconds for the child's STDERR, copying what comes.
        def pause(child, seconds)
          io = child.stderr
          if io.nil? || io.closed?
            sleep seconds
          else
            IO.select([io], nil, nil, seconds)
            copy_stderr(child)
          end
        rescue IOError
          nil
        end

        # Copies what the child has written to STDERR so far and keeps the
        # last STDERR_LINES lines.
        def copy_stderr(child)
          io = child.stderr
          return if io.nil? || io.closed?

          loop do
            chunk = io.read_nonblock(65_536, exception: false)
            if chunk.nil?
              io.close
              break
            end
            break if chunk == :wait_readable

            @err.write(chunk)
            @err.flush
            keep_tail(child, chunk)
          end
        rescue IOError, SystemCallError
          io.close unless io.closed?
        end

        def keep_tail(child, chunk)
          text = child.partial + chunk.dup.force_encoding(Encoding::UTF_8).scrub
          lines = text.split("\n", -1)
          child.partial = lines.pop.to_s
          child.tail.concat(lines)
          child.tail.shift(child.tail.size - STDERR_LINES) if child.tail.size > STDERR_LINES
        end

        # The child is gone: the rest of its STDERR, then its pipe and its
        # PID file.
        def finish(child)
          copy_stderr(child)
          child.stderr.close if child.stderr && !child.stderr.closed?
          delete_file(dev_path("child.pid"))
        end

        # What is known about a dead child, in this order: the failure file
        # (or else the tail of its STDERR), then how it ended.
        def exit_info(child, status)
          failure = begin
            File.read(dev_path("failure")).strip
          rescue SystemCallError
            ""
          end
          tail = child.tail + (child.partial.empty? ? [] : [child.partial])
          known = failure.empty? ? tail.join("\n").strip : failure
          ended = if status == :gone
                    "exited"
                  elsif status.signaled?
                    "signal #{status.termsig} (#{Signal.signame(status.termsig)})"
                  else
                    "exit status #{status.exitstatus}"
                  end
          known.empty? ? ended : "#{known}\n#{ended}"
        end

        def holding_page
          title, text = @hold || ["", ""]
          Holding.page(title, text, waiting_for)
        end

        def waiting_for
          if build_locked?
            "`cybertrain build` to finish (tmp/cybertrain-build.lock)"
          elsif @build
            "a saved change, or the Spinel build in progress (it takes the port when it succeeds; see tmp/rebuild.log)"
          else
            "a saved change"
          end
        end

        def read_build_log
          File.read(File.join(@root, BUILD_LOG)).force_encoding(Encoding::UTF_8).scrub
        rescue SystemCallError
          ""
        end

        # 0.3 as "0.3", 30.0 as "30".
        def seconds(value)
          value == value.to_i ? value.to_i.to_s : value.to_s
        end

        # The status of a process that has ended, nil while it runs, or
        # :gone when it was reaped elsewhere (its end is unknown).
        def reap(pid)
          found, status = Process.waitpid2(pid, Process::WNOHANG)
          found ? status : nil
        rescue Errno::ECHILD
          :gone
        end

        def wait_pid(pid)
          Process.waitpid2(pid)[1]
        rescue Errno::ECHILD
          nil
        end

        def signal(pid, name)
          Process.kill(name, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        # Written whole beside path and renamed into place: the child's
        # reader depends on the rename.
        def write_file(path, text)
          tmp = "#{path}.tmp"
          File.write(tmp, text)
          File.rename(tmp, path)
          nil
        end

        def delete_file(path)
          File.delete(path) if File.exist?(path)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
