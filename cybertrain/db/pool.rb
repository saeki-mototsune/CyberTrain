require "cybertrain/db/connection"

module Cybertrain
  module DB
    # A fixed set of Connections shared by the server's threads. `with` blocks
    # (parking the green thread) until a connection is free.
    #
    # Every ":memory:" connection is its own private database, so a
    # ":memory:" pool always holds exactly one connection (and `size`
    # reports 1) whatever size was asked for: otherwise tables created
    # through one `with` would be missing from the next.
    class Pool
      attr_reader :size

      def initialize(path, size = 4)
        @size = path == ":memory:" ? 1 : size
        @connections = []
        @available = SizedQueue.new(@size)
        @size.times do
          conn = Connection.new(path)
          @connections << conn
          @available << conn
        end
      end

      def with
        conn = @available.pop
        begin
          yield conn
        ensure
          @available << conn
        end
      end

      def close_all
        @connections.each(&:close)
      end
    end
  end
end
