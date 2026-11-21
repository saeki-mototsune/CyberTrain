# Running a program for the development server with its output bounded and
# its process group owned, so that a stop or a timeout reaches everything it
# started: owned_run (gen and dev-address) and bounded_run (the probe of the
# children's Ruby).
#
# Part of Cybertrain::CLI::DevServer (dev_server.rb requires this file and
# holds the startup, the loop and the stop). CRuby only.
module Cybertrain
  module CLI
    module DevServer
      # The stop predicate of a run that only an exception stops: the
      # start-up probes, which run before `serve` traps INT, TERM and HUP.
      NEVER = -> { false }

      # How much of an owned run's STDOUT, and of its STDERR, is kept: the
      # last 256 KiB, the end being where a failure says what went wrong.
      # gen's output goes whole to the log and to the holding page; a
      # runaway writer cannot fill the supervisor's memory (the STDERR tail
      # kept of a child is of the same order, STDERR_LINES lines of
      # TAIL_LINE_CHARS).
      OWNED_OUTPUT = 256 * 1024

      # How much of its STDOUT bounded_run keeps; the rest is read and
      # dropped, so that the program never blocks on a full pipe.
      BOUNDED_OUTPUT = 64 * 1024

      # How often bounded_run looks for its program's exit while the pipe
      # is open.
      BOUNDED_POLL = 0.05

      # Runs command in root, STDIN empty, in a process group of its own, and
      # waits for it in slices of TICK, reading its STDOUT and STDERR as they
      # come (a full pipe never blocks it): [STDOUT, STDERR, status] once it has
      # exited, with merge its STDERR in its STDOUT, in order, and STDERR ""
      # (each UTF-8, the last OWNED_OUTPUT bytes). The run is owned, so that a
      # stop reaches it: when stopping answers true between two slices, or when
      # this method is left by an exception (INT, TERM or HUP, which CRuby
      # raises here until `serve` traps them; the process then ends by that
      # signal, as it does in bounded_run), the whole group gets TERM, the
      # leader grace seconds to end, KILL to whatever of the group is left, and
      # the leader is reaped; status is then :stopped. What the command left
      # running in its group is KILLed as soon as its exit is seen. A command
      # that cannot be started raises SystemCallError.
      # @param env [Hash{String => String}]
      # @param command [Array<String>]
      # @param root [String] the directory it runs in
      # @param grace [Numeric] seconds between TERM and KILL on a stop
      # @param merge [Boolean] STDERR into STDOUT
      # @param stopping [Proc] true once the supervisor is stopping
      # @return [Array(String, String, Process::Status|Symbol)]
      def self.owned_run(env, command, root, grace, merge, stopping)
        out = +""
        err = +""
        pid = nil
        status = nil
        out_reader, out_writer = IO.pipe
        readers = { out_reader => out }
        err_writer = out_writer
        unless merge
          err_reader, err_writer = IO.pipe
          readers[err_reader] = err
        end
        begin
          pid = Process.spawn(env, *command, chdir: root, in: File::NULL, out: out_writer, err: err_writer, pgroup: true)
        ensure
          [out_writer, err_writer].each { |io| io.close unless io.closed? }
        end
        loop do
          _, status = Process.waitpid2(pid, Process::WNOHANG)
          unless status.nil?
            # What it left running in its group goes first, so that
            # nothing writes on while the pipes are read. What it wrote
            # is in the pipes by now and stays readable; their end is not
            # waited for.
            signal(-pid, :KILL)
            readers.each { |io, sink| nil while owned_read(io, sink).is_a?(String) }
            break
          end
          if stopping.call
            status = :stopped
            break
          end
          open = readers.keys.reject(&:closed?)
          next sleep(TICK) if open.empty?

          ready, = IO.select(open, nil, nil, TICK)
          ready&.each { |io| owned_read(io, readers[io]) }
        end
        [owned_text(out), owned_text(err), status]
      ensure
        readers&.each_key { |io| io.close unless io.closed? }
        if pid
          if status.is_a?(Process::Status)
            signal(-pid, :KILL)
          else
            stop_owned(pid, grace)
          end
        end
      end

      # One read from an owned run's pipe, without blocking, appended to
      # sink: nil at the pipe's end (the pipe is closed), :wait_readable
      # when nothing is there yet, otherwise what was read.
      def self.owned_read(io, sink)
        return nil if io.closed?

        chunk = io.read_nonblock(65_536, exception: false)
        if chunk.nil?
          io.close
        elsif chunk.is_a?(String)
          sink << chunk
          # Trimmed now and then rather than on every read.
          sink.replace(sink.byteslice(-OWNED_OUTPUT, OWNED_OUTPUT)) if sink.bytesize > 2 * OWNED_OUTPUT
        end
        chunk
      end

      # sink's last OWNED_OUTPUT bytes as UTF-8 text (the pipes give bytes;
      # a character cut by the bound or not UTF-8 is replaced).
      def self.owned_text(sink)
        text = sink.bytesize > OWNED_OUTPUT ? sink.byteslice(-OWNED_OUTPUT, OWNED_OUTPUT) : sink
        text.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # Stops the process group of an owned run whose leader pid has not
      # been reaped: TERM to the group, up to grace seconds for the leader
      # to end (ended?: a zombie counts, and until it is reaped the group's
      # id is not given to another group), KILL to the group, then the
      # leader is reaped. Unlike stop_group (a build), there is no step
      # for a leader that cleans up after its children: gen and
      # dev-address are one Ruby each. The KILL and the reap run however
      # the wait ends: before `serve` traps the signals, a second Ctrl-C
      # raises out of it, and the group, which the terminal's signals do
      # not reach, would outlive the supervisor (Thread.handle_interrupt
      # does not hold back CRuby's signal exceptions).
      def self.stop_owned(pid, grace)
        signal(-pid, :TERM)
        deadline = monotonic + grace
        begin
          sleep 0.01 until ended?(pid) || monotonic >= deadline
        ensure
          signal(-pid, :KILL)
          wait_quietly(pid)
        end
        nil
      end

      # Runs command (STDIN empty, STDERR dropped) in a process group of
      # its own, for timeout seconds at most: [its STDOUT (the first
      # BOUNDED_OUTPUT bytes), its status] as soon as it has exited, what
      # it wrote being in the pipe by then (a process it left in the
      # background may hold the pipe open: its end is not waited for);
      # ["", :missing] when there is no such program; [why, :failed] when
      # it cannot be started otherwise (spawn_failure), or no pipe can be
      # made; [what it printed, :timeout] when it takes longer. Its group
      # is killed whenever this ends: after its exit (what it left
      # running), at the bound, and on a Ctrl-C, which the group, apart
      # from the terminal's, does not get, or a TERM or HUP, which CRuby
      # raises as a SignalException here until `serve` traps them (the
      # process then still ends by that signal).
      # @param command [Array<String>]
      # @param timeout [Numeric]
      # @return [Array(String, Process::Status|Symbol)]
      def self.bounded_run(command, timeout)
        pid = nil
        status = nil
        begin
          reader, writer = IO.pipe
        rescue SystemCallError => e
          return [errno_text(e), :failed]
        end
        begin
          pid = Process.spawn(*command, in: File::NULL, out: writer, err: File::NULL, pgroup: true)
        rescue SystemCallError => e
          return spawn_failure(command[0], e)
        ensure
          writer.close
        end
        out = +""
        deadline = monotonic + timeout
        loop do
          # Once the program has exited, what it wrote is in the pipe:
          # that is read without waiting for the pipe's end, which
          # something it left running in the background can hold open
          # until the deadline.
          _, status = Process.waitpid2(pid, Process::WNOHANG) if status.nil?
          unless status.nil?
            nil while bounded_read(reader, out).is_a?(String) && monotonic < deadline
            break
          end
          left = deadline - monotonic
          break if left <= 0
          # Short waits, so that the program's exit is seen while the pipe
          # stays open.
          next if IO.select([reader], nil, nil, [left, BOUNDED_POLL].min).nil?
          break if bounded_read(reader, out).nil?
        end
        loop do
          break if status

          _, status = Process.waitpid2(pid, Process::WNOHANG)
          break if status || monotonic >= deadline

          sleep 0.01
        end
        [out, status || :timeout]
      ensure
        reader&.close
        # The whole group, also after the program itself ended: what it
        # started in the background must not outlive the probe. The
        # group's id is not given to another group while one of its
        # members runs, and a group with none left answers ESRCH.
        signal(-pid, :KILL) if pid
        wait_quietly(pid) if pid && status.nil?
      end

      # One read from bounded_run's pipe, without blocking, kept within
      # BOUNDED_OUTPUT: nil at the pipe's end, :wait_readable when nothing
      # is there yet, otherwise what was read.
      def self.bounded_read(reader, out)
        chunk = reader.read_nonblock(65_536, exception: false)
        out << chunk.byteslice(0, BOUNDED_OUTPUT - out.bytesize) if chunk.is_a?(String) && out.bytesize < BOUNDED_OUTPUT
        chunk
      end

      # bounded_run's answer when program could not be started: :missing
      # only when PATH holds no file of that name. A file that is there
      # gets ["FILE: why", :failed]: CRuby passes over one that is not
      # executable and answers ENOENT, as it does for a script whose #!
      # interpreter is missing; EACCES is an interpreter (or a mount) that
      # cannot be executed.
      # @return [Array(String, Symbol)]
      def self.spawn_failure(program, error)
        found = on_path(program)
        return ["", :missing] if error.is_a?(Errno::ENOENT) && found.nil?

        why = errno_text(error)
        if error.is_a?(Errno::ENOENT)
          why = File.executable?(found) ? "its #! interpreter is missing (#{why})" : "it is not executable"
        end
        ["#{found || program}: #{why}", :failed]
      end

      # The file PATH gives for program: the first executable one, else
      # the first one; nil when there is none.
      def self.on_path(program)
        return (File.file?(program) ? program : nil) if program.include?("/")

        files = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir.empty? ? "." : dir, program) }
                           .select { |path| File.file?(path) }
        files.find { |path| File.executable?(path) } || files.first
      end

      # "Permission denied", without the " - ruby" CRuby adds.
      def self.errno_text(error)
        error.message.sub(/ - .*\z/m, "")
      end

      def self.wait_quietly(pid)
        Process.waitpid(pid)
      rescue SystemCallError
        nil
      end
    end
  end
end
