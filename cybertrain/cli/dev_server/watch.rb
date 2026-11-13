require "cybertrain/dev/watcher"
require "cybertrain/dev/watched"

module Cybertrain
  module CLI
    module DevServer
      # The supervisor's file watch: Dev::Watcher over Dev::WATCHED (minus
      # Dev::IGNORED) in the application's root, whatever the current
      # directory, polled on a thread of its own. Its block hands the
      # changed paths to the driver loop (#take) and returns only once the
      # driver has run that round (#delivered), so the watcher absorbs the
      # gen/ files the round's gen rewrote, as the compiled loop does
      # (generated: ["gen/"]).
      #
      # #pending? is what the machine's change_pending? asks between a build
      # and its handover (P16): a change queued for the driver, one the
      # watcher has seen and not yet queued, or a file that differs from the
      # watcher's baseline right now, before the watcher's next poll. gen/ is
      # left out of that last comparison: its files are rewritten by the
      # supervisor's own gen, outside a round the watcher saw, and a
      # difference that the watcher then absorbs would leave the machine
      # waiting for a change that never comes.
      #
      # One lock guards the baseline and the queue; one condition variable
      # wakes the polling thread for #delivered and #close, so that #close
      # returns at once whatever the interval.
      class Watch < Dev::Watcher
        GENERATED = "gen/"

        def initialize(root, interval)
          @root = root
          @lock = Mutex.new
          @signal = ConditionVariable.new
          @queue = []
          @in_flight = false
          @queued = 0
          @taken = 0
          @done = 0
          @closing = false
          super(Dev::WATCHED, interval, [GENERATED], Dev::IGNORED)
        end

        # Dev::Watcher#snapshot, with the patterns read in root: the paths
        # stay relative to it ("app/models/article.rb"), as the log line and
        # the generated prefix expect.
        def snapshot
          stamps = {}
          @globs.each do |pattern|
            Dir.glob(pattern, base: @root).each do |path|
              next if @ignored.include?(path) || Dev::Watcher.scratch_path?(path)

              stamp = Dev::Watcher.mtime_stamp(File.join(@root, path))
              stamps[path] = stamp if stamp >= 0
            end
          end
          stamps
        end

        # Under the lock, so that between the new baseline and the queue
        # #pending? still sees the change (as in flight).
        def changed_paths
          @lock.synchronize do
            paths = super
            @in_flight = true unless paths.empty?
            paths
          end
        end

        # Starts polling; changes go to the driver through #take.
        def start_watching
          start { |paths| hand(paths) }
        end

        # The paths queued since the last call, sorted, or nil.
        # @return [Array<String>, nil]
        def take
          @lock.synchronize do
            return nil if @queue.empty?

            paths = @queue.uniq.sort
            @queue = []
            @taken = @queued
            paths
          end
        end

        # The round for the paths #take gave has run: the watcher's block
        # returns, and the watcher absorbs the generated files.
        def delivered
          @lock.synchronize do
            @done = @taken
            @signal.broadcast
          end
          nil
        end

        # See the class comment.
        # @return [Boolean]
        def pending?
          @lock.synchronize do
            return true if @in_flight || !@queue.empty?

            source_stamps(snapshot) != source_stamps(@previous)
          end
        end

        # The generated files as they are now become the baseline: gen ran
        # outside a round the watcher handed over (the first round, or one
        # put off by the build lock).
        def settle
          absorb_generated
        end

        # Stops polling, releasing a block that waits on the driver; returns
        # once the polling thread has finished.
        def close
          @lock.synchronize do
            @closing = true
            @signal.broadcast
          end
          stop
        end

        private

        # Dev::Watcher#poll, waiting on the condition variable rather than
        # sleeping, so that #close wakes it.
        def poll(block)
          loop do
            @lock.synchronize { @signal.wait(@lock, @interval) unless @closing }
            break if closing?

            paths = changed_paths
            next if paths.empty?

            block.call(paths)
            absorb_generated
          end
          nil
        end

        def closing?
          @lock.synchronize { @closing }
        end

        def absorb_generated
          @lock.synchronize { super }
        end

        # Queues the paths and waits until the driver has run their round
        # (or the watch closes).
        def hand(paths)
          @lock.synchronize do
            @queue.concat(paths)
            @in_flight = false
            @queued += 1
            mine = @queued
            @signal.wait(@lock) until @done >= mine || @closing
          end
          nil
        end

        def source_stamps(stamps)
          stamps.reject { |path, _stamp| path.start_with?(GENERATED) }
        end
      end
    end
  end
end
