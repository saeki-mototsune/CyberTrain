module Cybertrain
  module Dev
    # Polls file modification times for a set of Dir.glob patterns: the
    # development server's way of noticing that Ruby sources changed.
    #
    #   watcher = Cybertrain::Dev::Watcher.new(["app/**/*.rb", "config/**/*.rb"])
    #   watcher.changed?                       # => false until something changes
    #   watcher.start { |paths| rebuild(paths) }
    #
    # generated lists path prefixes ("gen/") of files the start block itself
    # rewrites: see #start. ignored lists exact paths the patterns match but
    # that never count as a change (gen/views.rb, which `cybertrain build`
    # rewrites and the development binary does not use).
    class Watcher
      def initialize(globs, interval = 0.5, generated = [], ignored = [])
        @globs = globs
        @interval = interval
        @generated = generated
        @ignored = ignored
        @previous = snapshot
        @running = false
        @thread = nil
      end

      # path => mtime in nanoseconds, for every file the patterns match.
      # Nanoseconds rather than whole seconds so that two saves within one
      # second still count as a change.
      def snapshot
        stamps = { "" => 0 }
        stamps.delete("") # a typed empty Hash (spikes/NOTES.md rule 9)
        @globs.each do |pattern|
          Dir.glob(pattern).each do |path|
            next if @ignored.include?(path)

            stamp = Watcher.mtime_stamp(path)
            stamps[path] = stamp if stamp >= 0
          end
        end
        stamps
      end

      # The paths added, modified or removed since the previous check,
      # sorted; the current state becomes the new baseline.
      def changed_paths
        current = snapshot
        before = @previous
        paths = []
        current.each_key do |path|
          paths << path if !before.key?(path) || before[path] != current[path]
        end
        before.each_key do |path|
          paths << path unless current.key?(path)
        end
        @previous = current
        paths.sort
      end

      def changed?
        !changed_paths.empty?
      end

      # Polls every interval seconds on a green thread and calls the block
      # with the changed paths. Files under a generated prefix that change
      # while the block runs (a rebuild rewrites gen/) are absorbed into the
      # baseline afterwards instead of triggering another round; any other
      # change made meanwhile (a developer saving a fix during a slow,
      # failing build) is reported by the next poll.
      def start(&block)
        return nil if @running

        @running = true
        @thread = spawn_poller(block)
        nil
      end

      # Stops polling; returns once the polling thread has finished.
      def stop
        @running = false
        thread = @thread
        thread.join unless thread.nil?
        @thread = nil
        nil
      end

      # -1 for anything that is not a regular file (or vanished meanwhile).
      def self.mtime_stamp(path)
        return -1 unless File.file?(path)

        t = File.mtime(path)
        t.to_i * 1_000_000_000 + t.nsec
      rescue StandardError
        -1
      end

      private

      def spawn_poller(block)
        Thread.new { poll(block) }
      end

      def poll(block)
        while @running
          sleep @interval
          break unless @running

          paths = changed_paths
          unless paths.empty?
            block.call(paths)
            absorb_generated
          end
        end
        nil
      end

      # The baseline keeps the stamps taken before the block ran, except for
      # generated paths, which take their current state (added, rewritten
      # or removed alike).
      def absorb_generated
        return nil if @generated.empty?

        current = snapshot
        before = @previous
        stamps = { "" => 0 }
        stamps.delete("") # a typed empty Hash (spikes/NOTES.md rule 9)
        before.each_key do |path|
          stamps[path] = before[path].to_i unless generated_path?(path)
        end
        current.each_key do |path|
          stamps[path] = current[path].to_i if generated_path?(path)
        end
        @previous = stamps
        nil
      end

      def generated_path?(path)
        @generated.each do |prefix|
          return true if path.start_with?(prefix)
        end
        false
      end
    end
  end
end
