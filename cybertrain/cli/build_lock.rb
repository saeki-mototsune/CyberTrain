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
#
# Removing the lock is the other half. Whoever removes it (a taker
# reclaiming a stale lock, the development server dropping one, the holder
# releasing its own) first takes the breaker, <lock>.break, with the same
# exclusive create, then reads the lock again and deletes it only if it is
# still what justified the removal (stale, or naming the holder), then drops
# the breaker. Without it, two takers that both judged one stale lock stale
# could each delete it in turn, the second deleting the fresh lock the first
# had just created, and a holder whose lock had gone stale could delete the
# lock that replaced it. Creating the lock needs no breaker: O_EXCL already
# lets only one creator win.
#
# A breaker older than BREAKER_STALE_AGE is broken (deleted and taken
# again), so a process killed inside the few system calls it holds the
# breaker for cannot wedge the lock. What remains: a breaker holder that
# stalls inside that section for longer than BREAKER_STALE_AGE (stopped,
# swapped out) can have its breaker broken and then act on a re-read that
# has since gone out of date; and two processes that break the same
# abandoned breaker at once can both enter. Both need a process to die or
# stall for seconds inside a section that otherwise lasts microseconds.
module Cybertrain
  module CLI
    class BuildLock
      RELATIVE_PATH = "tmp/cybertrain-build.lock"

      # A lock older than this is presumed abandoned (the build that held it
      # was SIGKILLed, or the machine rebooted) rather than genuinely
      # long-running: its PID may have been reused by an unrelated process
      # that would otherwise read as the holder forever. Long enough that no
      # real `cybertrain build` should ever hit it; a build touches its lock
      # before each step (touch_lock), so only one step lasting this long
      # would.
      STALE_AGE = 30 * 60

      # A breaker older than this was left by a process that died holding
      # it: the section it guards is a read, a kill(0), a delete. Seconds
      # are whole (mtime), so a breaker is broken after 9 to 10 seconds.
      BREAKER_STALE_AGE = 10

      # How often, and how far apart in seconds, a remover tries a breaker
      # someone else holds before giving up for now.
      BREAKER_TRIES = 5
      BREAKER_WAIT = 0.1

      attr_reader :lock_path, :owner_pid

      # The lock of the application in root, taken on behalf of pid.
      def initialize(root, pid = Process.pid)
        @lock_path = "#{root}/#{RELATIVE_PATH}"
        @owner_pid = pid.to_s
      end

      def breaker_path
        "#{@lock_path}.break"
      end

      # True when this process now holds the lock. A lock that exists and is
      # stale is reclaimed (reclaim_stale) and the exclusive create is tried
      # once more; failing again means another process took the lock in
      # between, so it counts as held. The tmp/ directory must exist.
      def take
        return true if create_lock
        return false unless reclaim_stale

        create_lock
      end

      # True when the lock path is free for an exclusive create: a stale
      # lock was removed, or the lock was already gone. The stale verdict is
      # made again under the breaker, and only that one counts.
      def reclaim_stale
        return true unless File.exist?(@lock_path)
        return false unless stale?

        before_breaker
        return false unless take_breaker

        free = false
        begin
          if !File.exist?(@lock_path)
            free = true
          elsif stale?
            File.delete(@lock_path)
            free = true
          end
        ensure
          drop_breaker
        end
        free
      end

      # Removes the lock only while it still names this process, under the
      # breaker: a lock another process took over (it judged this one stale)
      # is theirs. When the breaker stays busy the lock is left; it names
      # this process, so it reads as stale once the process has exited.
      def release
        return nil unless recorded_pid == @owner_pid
        return nil unless take_breaker

        begin
          before_release_delete
          File.delete(@lock_path) if recorded_pid == @owner_pid
        ensure
          drop_breaker
        end
        nil
      rescue StandardError
        nil
      end

      # Moves the lock's mtime to now while it still names this process, so
      # that a build longer than STALE_AGE in all is not read as abandoned.
      # Touching a lock another process has just taken would only delay its
      # own staleness.
      def touch_lock
        return nil unless recorded_pid == @owner_pid

        now = Time.at(BuildLock.real_seconds)
        File.utime(now, now, @lock_path)
        nil
      rescue StandardError
        nil
      end

      # The PID the lock records, "" when there is no lock or no PID in it.
      def recorded_pid
        BuildLock.read_pid(@lock_path)
      end

      # The stale-lock rule, the same for whoever takes the lock and for the
      # development server that only reads it: a lock older than STALE_AGE
      # is stale whatever it holds; otherwise one whose PID no longer runs
      # is. A lock recording no PID (or something else) cannot be told
      # stale before STALE_AGE, so it counts as held. A missing lock is not
      # stale.
      def stale?
        return false unless File.exist?(@lock_path)
        return true if BuildLock.age(@lock_path) >= STALE_AGE

        pid = recorded_pid
        return false unless BuildLock.digits?(pid)

        !BuildLock.process_alive?(pid.to_i)
      rescue StandardError
        false
      end

      # The exclusive create; false when the file already exists. The PID is
      # written after the create, so a reader can briefly see an empty lock,
      # which reads as held (stale?).
      def create_lock
        f = File.open(@lock_path, File::WRONLY | File::CREAT | File::EXCL, 0o644)
        fill_lock(f)
        true
      rescue Errno::EEXIST
        false
      end

      # Writes the PID into the lock just created and closes it. Should the
      # write or the close fail (a full disk), the descriptor is closed all
      # the same and the incomplete lock removed before the error goes on:
      # an empty lock would refuse every build for STALE_AGE. No one else
      # can have replaced it meanwhile, as an empty lock is not stale.
      def fill_lock(f)
        done = false
        begin
          begin
            write_owner(f)
          ensure
            f.close
          end
          done = true
        ensure
          File.delete(@lock_path) if !done && File.exist?(@lock_path)
        end
        nil
      end

      def write_owner(f)
        f.write(@owner_pid)
        nil
      end

      # True when this process now holds the breaker. One held by someone
      # else is tried again a few times, and broken once it is older than
      # BREAKER_STALE_AGE.
      def take_breaker
        tries = 0
        while tries < BREAKER_TRIES
          return true if create_breaker

          tries += 1
          if BuildLock.age(breaker_path) >= BREAKER_STALE_AGE
            remove_breaker
          elsif tries < BREAKER_TRIES
            sleep BREAKER_WAIT
          end
        end
        false
      end

      def remove_breaker
        File.delete(breaker_path)
        nil
      rescue StandardError
        nil
      end

      def create_breaker
        f = File.open(breaker_path, File::WRONLY | File::CREAT | File::EXCL, 0o644)
        begin
          f.write(@owner_pid)
        ensure
          f.close
        end
        true
      rescue Errno::EEXIST
        false
      end

      # Deletes the breaker this process holds. One that names another
      # process was broken and taken while this one stalled; it is theirs.
      def drop_breaker
        File.delete(breaker_path) if BuildLock.read_pid(breaker_path) == @owner_pid
        nil
      rescue StandardError
        nil
      end

      # Hooks between a step and the next, for the tests that play another
      # process's move there.
      def before_breaker
        nil
      end

      def before_release_delete
        nil
      end

      # Seconds since path was last modified; 0 when it cannot be read (a
      # file that vanished is not old).
      def self.age(path)
        real_seconds - File.mtime(path).to_i
      rescue StandardError
        0
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
