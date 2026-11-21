# The development server's view of other processes: who a PID is (its
# parent, its command line, its working directory, its state), whether it is
# this application's child, build or supervisor, and the members of a
# process group. Read from /proc where there is one, from `ps` otherwise.
#
# Part of Cybertrain::CLI::DevServer (dev_server.rb requires this file and
# holds the startup, the loop and the stop). CRuby only.
module Cybertrain
  module CLI
    module DevServer
      # Ruby's options that take the next argument as their value (each
      # also takes it in the same word: -Idir, --disable=gems).
      RUBY_VALUE_OPTIONS = ["-C", "-E", "-I", "-r", "--encoding", "--external-encoding", "--internal-encoding",
                            "--enable", "--disable", "--dump"].freeze

      # The parent's PID, from /proc/PID/stat where it exists, else from
      # `ps -o ppid=`; nil when neither tells.
      # @return [Integer, nil]
      def self.parent_pid(pid)
        stat = proc_stat(pid)
        # After the parenthesised command name: the state, then the parent.
        text = stat.nil? || stat.rindex(")").nil? ? nil : stat[(stat.rindex(")") + 1)..].split[1]
        text = IO.popen(["ps", "-o", "ppid=", "-p", pid.to_s], in: File::NULL, err: File::NULL, &:read).strip if text.nil?
        text.match?(/\A[0-9]+\z/) ? text.to_i : nil
      rescue SystemCallError
        nil
      end

      # /proc/PID/stat's text, nil where it cannot be read.
      def self.proc_stat(pid)
        File.read("/proc/#{pid}/stat")
      rescue SystemCallError
        nil
      end

      # The live (not zombie) processes of group pgid, from
      # `ps -A -o pid=,pgid=,stat=` (Linux and macOS); nil when ps cannot
      # list them (busybox's ps rejects -A and -o and prints nothing on
      # stdout; or there is no ps), which is not a group with no member.
      # ps -A lists ps itself, so a run that exits 0 without a line of
      # three fields, the first two numbers, did not list either.
      # @return [Array<Integer>, nil]
      def self.group_pids(pgid)
        out = IO.popen(["ps", "-A", "-o", "pid=,pgid=,stat="], in: File::NULL, err: File::NULL, &:read)
        rows = out.lines.map(&:split).select { |row| row.size == 3 && row[0].match?(/\A[0-9]+\z/) && row[1].match?(/\A[0-9]+\z/) }
        return nil unless $?.success? && !rows.empty?

        rows.filter_map { |pid, group, stat| pid.to_i if group.to_i == pgid && !stat.start_with?("Z") }
      rescue SystemCallError
        nil
      end

      # Whether group pgid has a member left: from group_pids, or, when ps
      # cannot list (nil), from signal 0 to the group, which finds any
      # member (EPERM: one that is someone else's). That probe counts a
      # zombie too, whose id is still taken, so a KILL it lets through
      # reaches no other group.
      # @return [Boolean]
      def self.group_member?(pgid)
        pids = group_pids(pgid)
        return !pids.empty? unless pids.nil?

        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
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

      # The process's arguments, [] when they cannot be read: from
      # /proc/PID/cmdline where it exists (Linux), exactly, spaces included;
      # elsewhere from ps (ps_command_line).
      # @param pid [Integer]
      # @return [Array<String>]
      def self.command_line(pid)
        proc_args(pid) || ps_command_line(pid)
      end

      # The arguments in /proc/PID/cmdline, or nil where there is no /proc
      # (or no such process). [] when it cannot be read.
      # @return [Array<String>, nil]
      def self.proc_args(pid)
        path = "/proc/#{pid}/cmdline"
        return nil unless File.exist?(path)

        File.binread(path).force_encoding(Encoding.find("filesystem")).split("\0")
      rescue SystemCallError
        []
      end

      # The `ps -ww -o args=` line split at spaces (an argument with a
      # space in it comes out as two).
      # @param pid [Integer]
      # @return [Array<String>]
      def self.ps_command_line(pid)
        ps_line(pid).split
      end

      # The process's arguments joined by spaces, as `ps -ww -o args=`
      # prints them; "" when ps cannot tell. -ww, which procps and BSD ps
      # both take, keeps ps from cutting the line at $COLUMNS or at the
      # terminal's width.
      # @param pid [Integer]
      # @return [String]
      def self.ps_line(pid)
        IO.popen(["ps", "-ww", "-o", "args=", "-p", pid.to_s], in: File::NULL, err: File::NULL, &:read).strip
      rescue SystemCallError
        ""
      end

      # The process's working directory, or nil where the system does not
      # show it (only Linux's /proc is read).
      def self.process_cwd(pid)
        File.readlink("/proc/#{pid}/cwd")
      rescue SystemCallError, NotImplementedError
        nil
      end

      # The program a command line runs and its arguments: the first word,
      # or for a ruby interpreter the script it is given (after its options;
      # none with -e). [nil, []] when there is none.
      # @param args [Array<String>]
      # @return [Array(String, Array<String>)]
      def self.program(args)
        return [nil, []] if args.empty?
        return [args[0], args[1..]] unless File.basename(args[0]).match?(/\Aruby[0-9.]*\z/)

        index = 1
        while index < args.size
          arg = args[index]
          return [nil, []] if arg.start_with?("-e")

          if arg == "--"
            index += 1
            break
          elsif RUBY_VALUE_OPTIONS.include?(arg)
            index += 2
          elsif arg.start_with?("-") && arg != "-"
            index += 1
          else
            break
          end
        end
        index < args.size ? [args[index], args[(index + 1)..]] : [nil, []]
      end

      # Whether path, an argument of process pid, names root's relative
      # file: an absolute path is compared as it is; a relative one is
      # resolved against the process's working directory where that can be
      # read, and elsewhere must be written as the supervisor spawns it
      # (relative to root, from root).
      def self.names?(pid, path, root, relative)
        return File.expand_path(path) == File.join(root, relative) if path.start_with?("/")

        cwd = process_cwd(pid)
        cwd.nil? ? path == relative : File.expand_path(path, cwd) == File.join(root, relative)
      end

      # What makes a process this application's child: the program (a ruby interpreter's script,
      # or the executable itself) is this application's bin/NAME.rb or
      # build/bin/NAME, whole paths. An editor with the file open, another
      # application's bin/NAME.rb, or build/bin/NAMEx is not. Without /proc
      # the arguments come from ps, joined by spaces, which a directory may
      # hold too: the line must then be the one the supervisor spawns
      # (spawned_child_line?).
      # @param pid [Integer]
      # @param root [String] the application's directory, a real path
      # @param name [String]
      # @param load_path [Array<String>] the -I directories of `spin flags`
      # @return [Boolean]
      def self.application_child?(pid, root, name, load_path = [])
        args = proc_args(pid)
        return spawned_child_line?(ps_line(pid), name, load_path) if args.nil?

        program, = program(args)
        return false if program.nil?

        names?(pid, program, root, "bin/#{name}.rb") || names?(pid, program, root, "build/bin/#{name}")
      end

      # The CRuby child's arguments after the interpreter, but for the port:
      # Processes#child_command spawns `ruby` with these.
      # @param load_path [Array<String>] the -I directories of `spin flags`
      # @param name [String]
      # @return [Array<String>]
      def self.cruby_child_args(load_path, name)
        ["-E", "UTF-8"] + load_path.map { |dir| "-I#{dir}" } + ["-r", "cybertrain/preview", "bin/#{name}.rb"]
      end

      # Whether line, a command line as ps prints it, is one the supervisor
      # spawns from root: `build/bin/NAME PORT` whole, or a program
      # followed by cruby_child_args and the port. The program is whatever
      # came first (a version manager's shim runs ruby by its full path,
      # spaces and all); the -I directories, this application's own among
      # them, make it this application's.
      # @param line [String]
      # @param name [String]
      # @param load_path [Array<String>]
      # @return [Boolean]
      def self.spawned_child_line?(line, name, load_path)
        return true if line.match?(%r{\Abuild/bin/#{Regexp.escape(name)} [0-9]+\z})

        tail = cruby_child_args(load_path, name).join(" ")
        line.match?(/\A.+ #{Regexp.escape(tail)} [0-9]+\z/m)
      end

      # What makes a process this application's build: the program is spin (the one on PATH,
      # so by name) with exactly the arguments Processes#build_command
      # gives it, in this application's directory where /proc shows it.
      # @param pid [Integer] the group's leader
      # @return [Boolean]
      def self.application_build?(pid, root, name)
        program, rest = program(command_line(pid))
        return false if program.nil? || File.basename(program) != "spin"
        return false unless [["build", name], ["build", name, "--", "--incremental"]].include?(rest)

        in_root?(pid, root)
      end

      # A `cybertrain server` command line: a word named cybertrain...
      # (exe/cybertrain, or the gem's wrapper) followed by `server`.
      def self.supervisor?(args)
        args.each_cons(2).any? { |word, after| File.basename(word).start_with?("cybertrain") && after == "server" }
      end

      # Whether the process works in root, where the system shows it (only
      # Linux's /proc is read; elsewhere this answers true). A PID reused by
      # another application's `cybertrain server` or build is not this
      # application's.
      def self.in_root?(pid, root)
        cwd = process_cwd(pid)
        cwd.nil? || cwd == root
      end

      # Gone, or a zombie, without reaping it (a leftover is not this
      # process's child, and the build's leader must stay unreaped until
      # stop_group is done). The state comes from /proc/PID/stat where it
      # exists, else from ps. When neither tells (no ps, or a busybox ps that
      # rejects -p and prints nothing) a process that kill(0) still finds
      # is not known to have ended: answering "ended" would skip the
      # cleanup wait and the TERM, and KILL a build at once.
      def self.ended?(pid)
        return true unless alive?(pid)

        state = proc_state(pid)
        state = ps_state(pid) if state.nil?
        state.start_with?("Z") || state.start_with?("X")
      end

      # The state letter of /proc/PID/stat (after the parenthesised command
      # name, which may hold spaces and parentheses itself; Z a zombie, X
      # dead), "X" for a process that has gone since (ENOENT, ESRCH). nil,
      # so that the caller asks ps, where there is no /proc, where the file
      # cannot be read otherwise (EACCES or EPERM under hidepid or a
      # container's restricted /proc, for a process that may well run), or
      # where its text has no state letter after a ")".
      # @param proc_dir [String] the /proc to read (a test gives its own)
      # @return [String, nil]
      def self.proc_state(pid, proc_dir = "/proc")
        return nil unless File.directory?("#{proc_dir}/self")

        stat = File.read("#{proc_dir}/#{pid}/stat")
        close = stat.rindex(")")
        return nil if close.nil?

        stat[(close + 1)..].strip[0]
      rescue Errno::ENOENT, Errno::ESRCH
        "X"
      rescue SystemCallError
        nil
      end

      # The `ps -o stat=` letters; "" when ps cannot tell.
      def self.ps_state(pid)
        IO.popen(["ps", "-o", "stat=", "-p", pid.to_s], in: File::NULL, err: File::NULL, &:read).strip
      rescue SystemCallError
        ""
      end
    end
  end
end
