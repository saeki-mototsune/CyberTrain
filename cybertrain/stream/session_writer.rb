require "cybertrain/http/body_writer"
require "cybertrain/stream"

module Cybertrain
  module Stream
    # What the SSE and the WebSocket session share: the subscription's
    # settings and the replay of what a reconnecting client missed.
    class SessionWriter < BodyWriter
      def initialize(hub, names, json, after, ping_interval, max_connections)
        @hub = hub
        @names = names
        @json = json
        @after = after
        @head = -1
        @ping_interval = ping_interval
        @max_connections = max_connections
      end

      # One message to the client; the subclasses override it.
      def write_message(sink, msg)
        nil
      end

      # The replay of what the client missed, for a session that has already
      # subscribed (write_body) and read the head before that (@head,
      # Stream.replay_start). Subscribed first, then the replay, then the
      # boundary, max(after, the last replayed id) (`after` itself when the
      # replay found nothing): a row broadcast while the replay ran is either
      # in the replay or queued, and skip_through! drops the queued copy of a
      # replayed one.
      def replay_backlog(sink, sub, names)
        last = Stream.replay_start(@after, @head)
        return nil if last < 0

        # By chunks, each written before the next query; the boundary
        # never passes a row that was not sent.
        cursor = sub.boundary
        while !sink.closed?
          backlog = Stream.replay(names, last)
          i = 0
          while i < backlog.size
            msg = backlog[i]
            write_message(sink, msg)
            last = msg.message_id
            i += 1
          end
          break if backlog.size < Stream::REPLAY_CHUNK || last >= cursor
        end
        sub.skip_through!(last)
        nil
      end
    end
  end
end
