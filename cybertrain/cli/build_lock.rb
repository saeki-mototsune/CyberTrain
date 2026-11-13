# Cybertrain::CLI::BuildLock -- tmp/cybertrain-build.lock, which keeps
# `cybertrain build` and the development server's rebuilds
# (Dev::Rebuilder) from writing build/bin/<name> at the same time. Plain
# Ruby: runs under CRuby (the gem) and compiles under Spinel (the CLI binary,
# and an application's development loop).
#
# The lock is the kernel's (spikes/NOTES.md rule 111): an exclusive flock(2)
# on the file, held through the descriptor the holder keeps open for the
# whole build. The kernel drops it when that descriptor closes, the holder's
# death included, so a lock is never stale and nothing has to judge or
# remove an abandoned one: whoever comes next gets it at once. flock is per
# open file description, so two opens in one process conflict as two
# processes do (Linux and macOS alike; file systems where flock is not
# shared between machines, such as some NFS setups, are out of scope: tmp/
# is local).
#
# The file also holds the holder's PID as text, for messages and for
# readers that only look at it. It is informational: a PID left by a holder
# that died does not hold anything. The holder deletes the file when it
# releases, while still holding the flock, and only if the path still names
# the file it locked. A taker that opened the file just before then locks a
# file no longer at the path; it sees that the path names another file (or
# none), and starts again on the path.
module Cybertrain
  module CLI
    class BuildLock
      RELATIVE_PATH = "tmp/cybertrain-build.lock"

      # Starting again after the file was unlinked under a taker: once is
      # enough unless holders come and go in a tight loop.
      TAKE_TRIES = 3

      # A reader (held?) holds a shared flock for an instant; a taker that
      # meets it tries again shortly before reading the lock as held.
      BUSY_TRIES = 3
      BUSY_WAIT = 0.05

      attr_reader :lock_path, :owner_pid

      # The lock of the application in root, taken on behalf of pid (the PID
      # written into the file; the flock belongs to this process).
      def initialize(root, pid = Process.pid)
        @lock_path = "#{root}/#{RELATIVE_PATH}"
        @owner_pid = pid.to_s
        @file = nil
      end

      # True when this object now holds the lock; false when another holds
      # it. The tmp/ directory must exist. Raises when the PID cannot be
      # written, after removing the file it created and dropping the flock.
      def take
        return true if holding?

        tries = 0
        while tries < TAKE_TRIES
          tries += 1
          f = File.open(@lock_path, File::RDWR | File::CREAT, 0o644)
          before_lock
          unless lock_exclusive(f)
            f.close
            return false
          end
          if same_file?(f)
            fill_lock(f)
            @file = f
            return true
          end
          # The file was unlinked by a holder releasing it: lock the path's.
          f.close
        end
        false
      end

      def holding?
        !@file.nil?
      end

      # Deletes the file while the flock is still held, if the path still
      # names it, then closes the descriptor, which drops the flock.
      def release
        f = @file
        return nil if f.nil?

        @file = nil
        discard(f)
        nil
      end

      # True while some process (or another BuildLock of this one) holds the
      # lock: a shared flock cannot be had. Takes it, if it can, only for
      # that instant, and never removes the file.
      def held?
        return true if holding?
        return false unless File.exist?(@lock_path)

        f = File.open(@lock_path, File::RDONLY)
        free = false
        begin
          free = f.flock(File::LOCK_SH | File::LOCK_NB) != false
        ensure
          f.close
        end
        !free
      rescue StandardError
        false
      end

      # The PID the lock file records, "" when there is no file or no PID in
      # it. Only meaningful while held?.
      def recorded_pid
        return "" unless File.exist?(@lock_path)

        File.read(@lock_path).strip
      rescue StandardError
        ""
      end

      def lock_exclusive(f)
        tries = 0
        while tries < BUSY_TRIES
          return true if f.flock(File::LOCK_EX | File::LOCK_NB) != false

          tries += 1
          sleep BUSY_WAIT if tries < BUSY_TRIES
        end
        false
      end

      # Whether the path still names the file f has open.
      def same_file?(f)
        there = File.stat(@lock_path)
        descriptor_id(f) == "#{there.dev}:#{there.ino}"
      rescue StandardError
        false
      end

      # The device and inode of the file f has open, from fstat(2). Under
      # Spinel File#stat stats the path instead, and IO.for_fd's handle is a
      # dup of the descriptor that stats it but must be closed here, or it
      # would keep the flock alive after f closes (rule 111). Under CRuby
      # File#stat is fstat, and closing an IO.for_fd would close f's own
      # descriptor.
      def descriptor_id(f)
        if RUBY_ENGINE == "ruby"
          st = f.stat
          return "#{st.dev}:#{st.ino}"
        end

        io = IO.for_fd(f.fileno, autoclose: false)
        id = ""
        begin
          st = io.stat
          id = "#{st.dev}:#{st.ino}"
        ensure
          io.close
        end
        id
      end

      # Writes the PID into the locked file. Should that fail (a full disk),
      # the file is removed while still locked and the descriptor closed
      # before the error goes on: a half-written lock left behind would
      # mislead every reader of the PID.
      def fill_lock(f)
        done = false
        begin
          write_owner(f)
          done = true
        ensure
          discard(f) unless done
        end
        nil
      end

      def write_owner(f)
        f.truncate(0)
        f.write(@owner_pid)
        f.flush
        nil
      end

      def discard(f)
        begin
          before_release_delete
          File.delete(@lock_path) if same_file?(f)
        rescue StandardError
          nil
        end
        # A close that fails (the flush of a write that already failed) has
        # still released the descriptor, and with it the flock; its error
        # must not replace the one that brought us here.
        begin
          close_file(f)
        rescue StandardError
          nil
        end
        nil
      end

      def close_file(f)
        f.close
        nil
      end

      # Hooks for the tests that play another process's move between two
      # steps: after the open and before the flock, and before the delete.
      def before_lock
        nil
      end

      def before_release_delete
        nil
      end
    end
  end
end
