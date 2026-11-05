module Cybertrain
  module Stream
    # The one thread per process that turns rows of `cybertrain_messages`
    # into deliveries: every {Config#stream_poll_ms} ms it reads
    # `SELECT MAX(id)` (one B-tree descent on the primary key) and, when that
    # passed the last id it delivered, the new rows, which it hands to
    # {Stream.hub}. Every minute it also deletes the rows older than
    # {Config#stream_retention} seconds; the one place that prunes. Started
    # by Application#serve before it binds the port (so no subscription can
    # come before the start position) and stopped with the server; the
    # endpoint answers 503 while it is not running. It
    # starts at the current MAX(id): a message is delivered live only to
    # the subscribers present when it is polled; a reconnecting client asks
    # for what it missed (Stream.replay).
    # @api public
    module Poller
      PRUNE_INTERVAL = 60

      LOCK = Mutex.new
      @running = false
      @generation = 0
      @last_id = 0
      @last_prune = 0

      # Starts the thread unless it runs; true when it started it.
      # @param config [Config]
      # @return [Boolean]
      # @api public
      def self.start!(config = Cybertrain.config)
        started = false
        generation = 0
        LOCK.synchronize do
          unless @running
            @running = true
            @generation += 1
            generation = @generation
            started = true
          end
        end
        return false unless started

        @last_id = Stream.max_id
        @last_prune = Time.now.to_i
        Poller.spawn_loop(config.stream_poll_ms, config.stream_retention, generation)
        true
      end

      # Asks the thread to end; it does after its current tick.
      # @return [nil]
      # @api public
      def self.stop!
        LOCK.synchronize { @running = false }
        nil
      end

      # @return [Boolean]
      # @api public
      def self.running?
        @running
      end

      # The last message id handed to the hub.
      # @return [Integer]
      def self.last_id
        @last_id
      end

      # What start! does to the position, for a test that ticks by hand:
      # the next run_once delivers only rows written after this call. The
      # hub is the one the test ticks (accepted for symmetry with run_once;
      # it holds no position of its own).
      # @param hub [Hub]
      # @return [nil]
      def self.reset!(hub)
        @last_id = Stream.max_id
        nil
      end

      # Moves last_id up to `id` (never down); Hub#deliver_polled calls it
      # under the hub's lock.
      def self.advance(id)
        @last_id = id if id > @last_id
        nil
      end

      # Sets where the next tick starts (tests).
      def self.last_id=(id)
        @last_id = id
      end

      # One tick: delivers the rows above last_id to `hub`, in id order.
      # The thread calls it; tests call it instead of waiting. last_id is
      # "the highest row already delivered": it moves to a row's id inside
      # Hub#deliver_polled, under the hub's lock and after the row went to
      # the subscribers, so a subscription taken while a row is in flight
      # gets a boundary below it and receives it.
      # @param hub [Hub]
      # @return [Integer] how many rows it delivered
      # @api public
      def self.run_once(hub)
        last = @last_id
        return 0 if Stream.max_id <= last

        rows = Stream.messages_after(last, 1000)
        i = 0
        while i < rows.size
          msg = rows[i]
          hub.deliver_polled(msg.message_id, msg.message_stream, msg.message_payload)
          i += 1
        end
        rows.size
      end

      # Through a method, so the closure captures the parameters
      # (spikes/NOTES.md rule 21).
      def self.spawn_loop(poll_ms, retention, generation)
        Thread.new { Poller.run_loop(poll_ms, retention, generation) }
      end

      def self.run_loop(poll_ms, retention, generation)
        pause = poll_ms / 1000.0
        while @running && @generation == generation
          Poller.tick(retention)
          sleep pause
        end
        nil
      end

      # run_once and the minute's prune, with the rescue in a plain method
      # (rules 32/45); JSON::NestingError first (rule 61), the full DB error
      # name (rule 70). A database that is gone is logged and polled again.
      def self.tick(retention)
        Poller.run_once(Stream.hub)
        now = Time.now.to_i
        if now - @last_prune >= PRUNE_INTERVAL
          @last_prune = now
          Stream.prune(now - retention)
        end
        nil
      rescue Cybertrain::DB::Error, JSON::NestingError, JSON::ParserError, StandardError => e
        Cybertrain.logger.error("stream poller: #{e.class.name}: #{e.message}")
        nil
      end
    end
  end
end
