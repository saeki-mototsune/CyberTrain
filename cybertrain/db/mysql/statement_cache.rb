# The prepared statements of one MySQL connection, by SQL text: an
# application runs the same few statements on every request, and
# COM_STMT_PREPARE is a round trip, so each SQL text is prepared once and
# its statement id kept for the life of the connection.
#
# Bounded: SQL built from request data (an IN list of varying length)
# would otherwise prepare without end, and the server refuses a prepare
# past max_prepared_stmt_count (16382 by default, counted over every
# session of the server). At LIMIT statements the one used least recently
# is closed (COM_STMT_CLOSE) before another is prepared, so a connection
# never holds more than LIMIT.
#
# The order of use is the Hash's insertion order: a hit moves its entry to
# the end (delete and store again), so the first key is always the least
# recently used one.
require "cybertrain/db/mysql/protocol"

module Cybertrain
  module DB
    module MySQL
      # @api private
      class StatementCache
        LIMIT = 256

        # @param protocol [Protocol] the connection's
        # @param limit [Integer] the most statements kept
        def initialize(protocol, limit = LIMIT)
          @protocol = protocol
          @limit = limit
          # SQL text => statement id (NOTES rule 9: seeded).
          @statement_ids = { "" => 0 }
          @statement_ids.delete("")
        end

        # The id of `sql`'s prepared statement, prepared now when it is not
        # kept yet (closing the least recently used one first when the
        # cache is full). A prepare the server refuses keeps nothing.
        # @return [Integer]
        # @raise [Cybertrain::DB::Error] what the prepare raised
        def cached_statement_id(sql)
          id = @statement_ids.fetch(sql, -1)
          if id >= 0
            @statement_ids.delete(sql)
            @statement_ids[sql] = id
            return id
          end

          evict_oldest if @statement_ids.size >= @limit
          fresh = @protocol.prepare(sql)
          @statement_ids[sql] = fresh
          fresh
        end

        # How many statements are kept.
        # @return [Integer]
        def cached_statement_count
          @statement_ids.size
        end

        # Forgets every statement without closing it: for a connection
        # being closed, whose statements the server drops with the session.
        # @return [nil]
        def forget_statements
          @statement_ids.clear
          nil
        end

        # Closes the least recently used statement.
        def evict_oldest
          oldest = @statement_ids.keys[0]
          id = @statement_ids.fetch(oldest, -1)
          @statement_ids.delete(oldest)
          @protocol.close_statement(id) if id >= 0
          nil
        end
      end
    end
  end
end
