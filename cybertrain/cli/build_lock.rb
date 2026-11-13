# Cybertrain::CLI::BuildLock -- tmp/cybertrain-build.lock, which keeps
# `cybertrain build` and the development server's rebuilds
# (Dev::Rebuilder) from writing build/bin/<name> at the same time. Plain
# Ruby: runs under CRuby (the gem) and compiles under Spinel (the CLI binary,
# and an application's development loop).
#
# The file holds the PID of the process that took it, as text, nothing else.
# Taking it is one exclusive create (O_CREAT | O_EXCL, spikes/NOTES.md rule
# 75): of two processes that find the lock free at the same moment, exactly
# one creates the file and the other gets EEXIST, where a check followed by
# a write let both believe they held it.
module Cybertrain
  module CLI
    class BuildLock
      RELATIVE_PATH = "tmp/cybertrain-build.lock"

      # A lock older than this is presumed abandoned (the build that held it
      # was SIGKILLed, or the machine rebooted) rather than genuinely
      # long-running: its PID may have been reused by an unrelated process
      # that would otherwise read as the holder forever. Long enough that no
      # real `cybertrain build` should ever hit it.
      STALE_AGE = 30 * 60

      attr_reader :lock_path, :owner_pid

      # The lock of the application in root, taken on behalf of pid.
      def initialize(root, pid = Process.pid)
        @lock_path = "#{root}/#{RELATIVE_PATH}"
        @owner_pid = pid.to_s
      end

      # True when this process now holds the lock. A lock that exists is
      # read: when it is stale (stale_lock?) it is removed and the exclusive
      # create is tried once more; failing again means another process took
      # the lock in between, so it counts as held. The tmp/ directory must
      # exist.
      def take
        return true if create_lock
        return false unless BuildLock.remove_if_stale(@lock_path)

        create_lock
      end

      # Removes the lock only while it still names this process: a lock
      # that another process took over (it judged this one stale) is theirs.
      def release
        File.delete(@lock_path) if recorded_pid == @owner_pid
        nil
      rescue StandardError
        nil
      end

      # The PID the lock records, "" when there is no lock or no PID in it.
      def recorded_pid
        BuildLock.read_pid(@lock_path)
      end

      # The exclusive create; false when the file already exists. The PID is
      # written after the create, so a reader can briefly see an empty lock,
      # which reads as held (stale_lock?).
      def create_lock
        f = File.open(@lock_path, File::WRONLY | File::CREAT | File::EXCL, 0o644)
        f.write(@owner_pid)
        f.close
        true
      rescue Errno::EEXIST
        false
      end

      # The stale-lock rule, the same for whoever takes the lock and for the
      # development server that only reads it: a lock older than STALE_AGE
      # is stale whatever it holds; otherwise one whose PID no longer runs
      # is. A lock recording no PID (or something else) cannot be told
      # stale before STALE_AGE, so it counts as held. A missing lock is not
      # stale.
      def self.stale_lock?(path)
        return false unless File.exist?(path)
        return true if real_seconds - File.mtime(path).to_i >= STALE_AGE

        pid = read_pid(path)
        return false unless digits?(pid)

        !process_alive?(pid.to_i)
      rescue StandardError
        false
      end

      # Deletes the lock at path when it is stale; true when the path is
      # free for an exclusive create to be tried (also when someone else
      # removed it first).
      def self.remove_if_stale(path)
        return false unless stale_lock?(path)

        begin
          File.delete(path)
        rescue StandardError
          nil
        end
        true
      end

      def self.read_pid(path)
        return "" unless File.exist?(path)

        File.read(path).strip
      rescue StandardError
        ""
      end

      # Signal 0 probes without delivering anything; EPERM means the process
      # exists but belongs to someone else.
      def self.process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # Seconds since the epoch on the real clock, never through Time.now,
      # which a test program may override (cybertrain/test/time_now.rb).
      def self.real_seconds
        Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond) / 1_000_000
      end

      # Non-empty and all ASCII digits.
      def self.digits?(text)
        return false if text.empty?

        text.bytes.all? { |b| b >= 48 && b <= 57 }
      end
    end
  end
end
