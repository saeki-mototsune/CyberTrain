module Cybertrain
  module Stream
    # One broadcast as a subscriber receives it. Distinctive accessor names
    # (spikes/NOTES.md rules 10/34/41: WebSocket::Message, a model's `id`).
    # @api public
    class Message
      # @return [Integer] the row id, increasing
      attr_reader :message_id
      # @return [String] the stream name
      attr_reader :message_stream
      # @return [String]
      attr_reader :message_payload

      def initialize(id, stream, payload)
        @message_id = id
        @message_stream = stream
        @message_payload = payload
      end
    end

    # One connection's subscription: the stream names it listens to and the
    # queue the hub pushes its messages onto. The connection's thread takes
    # them with #stream_pop. A queue that reaches max_backlog undelivered
    # messages drops the subscriber (#dropped?): the connection is closed
    # and the client reconnects, as Action Cable does with a client that
    # cannot keep up.
    # @api public
    class Subscriber
      def initialize(names, max_backlog)
        @names = Array.new(0) { "" }
        i = 0
        while i < names.size
          @names << names[i].to_s
          i += 1
        end
        @max_backlog = max_backlog
        @queue = Queue.new
        @dropped = false
      end

      # The names listened to (a copy).
      # @return [Array<String>]
      def stream_names
        out = Array.new(0) { "" }
        i = 0
        while i < @names.size
          out << @names[i]
          i += 1
        end
        out
      end

      # @param name [String]
      # @return [Boolean]
      def listens?(name)
        i = 0
        while i < @names.size
          return true if @names[i] == name

          i += 1
        end
        false
      end

      # The next message, waiting at most `timeout` seconds; nil when none
      # came, or once the subscriber is dropped.
      # (Queue#pop(timeout:) parks the green thread under Spinel too:
      # spikes/NOTES.md rule 80.)
      # @param timeout [Numeric] seconds
      # @return [Message, nil]
      # @api public
      def stream_pop(timeout)
        return nil if @dropped

        message = @queue.pop(timeout: timeout)
        return nil if @dropped

        message
      end

      # True once the backlog overflowed.
      # @return [Boolean]
      # @api public
      def dropped?
        @dropped
      end

      # Messages waiting.
      # @return [Integer]
      def backlog
        @queue.size
      end

      # The Hub calls these under its lock.
      def stream_offer(message)
        return nil if @dropped

        if @queue.size >= @max_backlog
          @dropped = true
          # wakes a pop that is waiting, which then sees dropped? (a nil
          # message is never delivered otherwise)
          @queue << Message.new(0, "", "")
        else
          @queue << message
        end
        nil
      end

      def add_stream_names(names)
        i = 0
        while i < names.size
          name = names[i].to_s
          @names << name unless listens?(name)
          i += 1
        end
        nil
      end

      def remove_stream_names(names)
        kept = Array.new(0) { "" }
        i = 0
        while i < @names.size
          name = @names[i]
          kept << name unless Stream.name_in?(names, name)
          i += 1
        end
        @names = kept
        nil
      end
    end

    # The in-process fan-out: the poller hands it each new row
    # (#deliver), and it pushes the message onto the queue of every
    # subscriber listening to that stream. One lock, taken when a
    # connection subscribes or leaves and once per delivered row, never per
    # request (spikes/NOTES.md rule 57).
    # @api public
    class Hub
      def initialize(max_backlog = 1000)
        @max_backlog = max_backlog
        @lock = Mutex.new
        # Seeded with the element type, then emptied (rules 9/64).
        @subscribers = Array.new(0) { Subscriber.new(Array.new(0) { "" }, 1) }
      end

      # @param names [Array<String>]
      # @return [Subscriber]
      # @api public
      def subscribe(names)
        sub = Subscriber.new(names, @max_backlog)
        @lock.synchronize { @subscribers << sub }
        sub
      end

      # @param sub [Subscriber]
      # @return [nil]
      # @api public
      def unsubscribe(sub)
        @lock.synchronize { hub_remove(sub) }
        nil
      end

      # Hands one message to every subscriber of `stream`.
      # @param id [Integer]
      # @param stream [String]
      # @param payload [String]
      # @return [Integer] how many subscribers it went to
      # @api public
      def deliver(id, stream, payload)
        message = Message.new(id, stream, payload)
        count = 0
        @lock.synchronize { count = hub_offer(message) }
        count
      end

      # Adds or removes names of a subscription (a WebSocket client's
      # `subscribe` / `unsubscribe`), under the lock deliver takes.
      def add_names(sub, names)
        @lock.synchronize { sub.add_stream_names(names) }
        nil
      end

      def remove_names(sub, names)
        @lock.synchronize { sub.remove_stream_names(names) }
        nil
      end

      # Subscribers in this process (the endpoint's connection count).
      # @return [Integer]
      # @api public
      def subscriber_count
        count = 0
        @lock.synchronize { count = @subscribers.size }
        count
      end

      private

      def hub_offer(message)
        count = 0
        stream = message.message_stream
        i = 0
        while i < @subscribers.size
          sub = @subscribers[i]
          if sub.listens?(stream)
            sub.stream_offer(message)
            count += 1
          end
          i += 1
        end
        count
      end

      # A fresh Array without `sub` (no delete_if block: the lock's block
      # stays one level deep).
      def hub_remove(sub)
        kept = Array.new(0) { Subscriber.new(Array.new(0) { "" }, 1) }
        i = 0
        while i < @subscribers.size
          other = @subscribers[i]
          kept << other unless other.equal?(sub)
          i += 1
        end
        @subscribers = kept
        nil
      end
    end
  end
end
