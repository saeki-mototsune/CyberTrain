# Cybertrain::DB::Connection for MySQL: one session with a MySQL 8.0 server,
# over the pure-Ruby protocol beside this file (packet, auth, protocol,
# result) on Cybertrain::Net, so every wait is a green-thread wait on a
# socket and never an OS worker parked in a C call.
#
# Its public methods are the SQLite Connection's (cybertrain/db/sqlite/
# connection.rb), with the same names and return types, so that the pool,
# DB.transaction and everything above them run unchanged; the SQLite-only
# ones (journal_mode) are not here. What differs:
#
# - The target is a URL (cybertrain/db/mysql/url.rb), not a path.
#   `create:` is accepted and ignored: creating the database is `db
#   create`'s, never a connection's.
# - Right after connecting, one exec_script sets the session: time zone
#   UTC, the strict sql_mode, and utf8mb4 with the utf8mb4_0900_bin
#   collation (SESSION_SETTINGS). The isolation level stays REPEATABLE READ.
# - #execute and #execute_models prepare each statement (the binary
#   protocol, binds sent as values, never spliced into the SQL) and keep it
#   in a StatementCache of 256 per connection. A statement the server
#   cannot prepare (BEGIN, LOCK TABLES: error 1295) and that has no binds
#   goes through COM_QUERY instead. #exec_script uses COM_QUERY with
#   multi-statements.
# - #execute_models answers a DATETIME or TIMESTAMP column as a UTC Time
#   with its microseconds, as the SQLite Connection does (made from the
#   value's epoch microseconds, D42); #execute answers it as the text
#   SQLite stores, "YYYY-MM-DD HH:MM:SS.ffffff".
# - Errors carry the server's message, code and SQLSTATE, then the
#   statement as SQLite's do: "Duplicate entry '1' for key 'posts.PRIMARY'
#   (MySQL 1062, 23000) (sql: INSERT ...)". A server ERR leaves the
#   connection usable. Anything else part way through an exchange (a packet
#   that does not decode, a timeout, a TLS failure, the stream ending)
#   leaves the stream out of step: the connection closes itself and raises
#   DB::ConnectionLost, and the Pool opens a new one on the next checkout.
# - Whether a transaction is open is the server's word (SERVER_STATUS_IN_TRANS
#   in the status flags of every OK packet). The "transaction gone" rules
#   are the SQLite Connection's (#refuse_if_transaction_gone): MySQL rolls
#   a whole transaction back on a deadlock, and a DDL statement commits the
#   open transaction implicitly, after which nothing nested in it may run
#   as if it were still open.
#
# No message holds the password: the URL's parts are named by host:port
# only (Url#server_label), and Url#to_s / #inspect leave it out.
require "cybertrain/cast"
require "cybertrain/db/blob"
require "cybertrain/db/error"
require "cybertrain/net/socket"
require "cybertrain/db/mysql/wire"
require "cybertrain/db/mysql/packet"
require "cybertrain/db/mysql/url"
require "cybertrain/db/mysql/handshake"
require "cybertrain/db/mysql/auth"
require "cybertrain/db/mysql/result"
require "cybertrain/db/mysql/protocol"
require "cybertrain/db/mysql/statement_cache"

module Cybertrain
  module DB
    module MySQL
      # The TlsUpgrade a Connection hands Auth.handshake: wraps the TCP
      # stream in TLS through Net.tls_connector (cybertrain/net/tls: the
      # certificate and the host name verified, CA from SSL_CERT_FILE /
      # SSL_CERT_DIR) and keeps the PacketIO over it. Until the switch,
      # #upgraded_io is the plain PacketIO, so the connection takes its
      # PacketIO from here either way.
      # @api private
      class TlsSwitch < TlsUpgrade
        def initialize(tcp, host, seconds, plain)
          @tcp = tcp
          @tls_host = host
          @seconds = seconds
          @switched_io = plain
        end

        def mysql_tls_upgrade(io)
          timer = Cybertrain::Net::Timer.new(@tcp.stream_label, @seconds, @seconds)
          stream = Cybertrain::Net.tls_connector.tls_wrap(@tcp, @tls_host, timer)
          @switched_io = PacketIO.new(stream, @seconds, @seconds)
          @switched_io
        end

        # The PacketIO the session goes on over: TLS after the switch, the
        # plain one before (and for ssl_mode=disabled).
        def upgraded_io
          @switched_io
        end
      end
    end

    # One MySQL session. Not thread-safe on its own: threads share
    # connections through Cybertrain::DB::Pool, which hands each one to a
    # single thread at a time.
    class Connection
      # The most `?` one statement may carry: COM_STMT_PREPARE counts the
      # parameters in two bytes.
      VARIABLE_LIMIT = 65_535

      # The session settings, sent once in one exec_script right after
      # authentication (docs/superpowers/plans/2026-11-27-mysql-adapter.md,
      # Global Constraints): DATETIME and TIMESTAMP values in UTC whatever
      # the server's own zone; strict modes, so a bad value or a zero date
      # is an error and not a silent warning; utf8mb4 with a binary,
      # NO PAD collation (case- and trailing-space-sensitive, as SQLite
      # compares). The isolation level stays the server's REPEATABLE READ.
      SESSION_SETTINGS = "SET NAMES utf8mb4 COLLATE utf8mb4_0900_bin, time_zone = '+00:00', " \
                         "sql_mode = 'STRICT_ALL_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO,ONLY_FULL_GROUP_BY'"

      # The longest one 16 MB frame may take once connected (seconds): only
      # the per-wait timeouts (read_timeout, write_timeout) bound a session,
      # so a long result whose bytes keep coming is never cut off.
      FRAME_DEADLINE = MySQL::Url::MAX_TIMEOUT

      # MySQL's ER_UNSUPPORTED_PS: the statement cannot be prepared.
      UNSUPPORTED_PS = 1295

      # Never: a MySQL database lives in its server, and every connection
      # to the URL sees it. The Pool asks (SQLite answers true for
      # ":memory:"), so it may hold its full size and reopen a closed slot.
      # @return [Boolean]
      def self.private_database?(_target)
        false
      end

      # Connects to the server the URL names, authenticates and sets the
      # session.
      # @param target [String] mysql://USER[:PASSWORD]@HOST[:PORT][/DATABASE][?...]
      # @param create [Boolean] ignored (the SQLite Connection's parameter)
      # @raise [Cybertrain::DB::Error] for a bad URL, a refused login or
      #   session setting; DB::ConnectionLost when the server cannot be
      #   reached (refused, unreachable, timed out, TLS failed)
      def initialize(target, create: true)
        @closed = true
        @transaction_depth = 0
        # True once MySQL rolled back a transaction on its own while a
        # statement failed (a deadlock), until the application ends it
        # with COMMIT or ROLLBACK (#note_lost_transaction).
        @transaction_lost = false
        @statements_run = 0
        @changes = 0
        @last_insert_id = 0
        url = Connection.parse_target(target)
        io = Connection.open_session(url)
        @stream = io.packet_stream
        @protocol = MySQL::Protocol.new(io)
        @statements = MySQL::StatementCache.new(@protocol)
        @closed = false
        # The session is set before the caller sees the connection; a
        # failure closes it, as nobody else could (a rescue, not an
        # ensure: NOTES rule 50).
        begin
          exec_script(SESSION_SETTINGS)
        rescue StandardError => e
          close
          raise e
        end
      end

      # The URL, its faults as DB::Error (the message names the part at
      # fault, never the password).
      def self.parse_target(target)
        MySQL::Url.parse(target.to_s)
      rescue ArgumentError => e
        raise Error, e.message
      end

      # TCP, the handshake and authentication (TLS for ssl_mode=verify):
      # the PacketIO the session runs on, its timeouts set from the URL.
      # Each wait of the connect and the handshake is bounded by
      # connect_timeout; a Net failure is ConnectionLost.
      def self.open_session(url)
        label = url.server_label
        seconds = url.connect_timeout
        timer = Cybertrain::Net::Timer.new(label, seconds, seconds)
        endpoint = Cybertrain::Net.resolve(url.url_host, url.port, label)
        tcp = Cybertrain::Net::TcpStream.connect_to(endpoint, url.port, label, timer)
        io = Connection.authenticate(tcp, url)
        io.use_timeouts(url.read_timeout, url.write_timeout, FRAME_DEADLINE)
        io
      rescue Cybertrain::Net::Error => e
        raise ConnectionLost, e.message
      end

      # The handshake and the login over `tcp`, which is closed when they
      # fail (the TLS stream with it, after the switch).
      def self.authenticate(tcp, url)
        seconds = url.connect_timeout
        plain = MySQL::PacketIO.new(tcp, seconds, seconds)
        switch = MySQL::TlsSwitch.new(tcp, url.url_host, seconds, plain)
        begin
          handshake = MySQL::Handshake.parse(plain.read_packet)
          MySQL::Auth.handshake(plain, url, handshake, switch)
        rescue StandardError => e
          Connection.close_quietly(switch.upgraded_io.packet_stream)
          raise e
        end
        switch.upgraded_io
      end

      def self.close_quietly(stream)
        stream.stream_close
        nil
      rescue StandardError
        nil
      end

      # Runs one statement with positional `?` binds and returns its rows as
      # Hashes keyed by column name (an empty Array for DDL/DML).
      # @param sql [String]
      # @param binds [Array<Object>] one value per `?` (build them with
      #   {Cast.binds}): nil, true / false (1 / 0), Integer, Float, Time (UTC
      #   text), Date, DB::Blob (its bytes), anything else as its to_s
      # @return [Array<Hash{String => Object}>]
      # @raise [Cybertrain::DB::Error] when the statement fails, or the
      #   connection is closed
      # @api public
      def execute(sql, binds = [])
        run_statement(sql, binds, false)
      end

      # execute for the ORM: a DATETIME or TIMESTAMP column comes back as a
      # UTC Time (with microseconds; Cast.time_or_nil takes it as is)
      # instead of its text; a value that does not read as one (a zero
      # date) stays text. Relation reads its rows through this; execute
      # keeps returning the text.
      def execute_models(sql, binds = [])
        run_statement(sql, binds, true)
      end

      def run_statement(sql, binds, epoch)
        raise Error, "connection closed (sql: #{sql})" if @closed
        rows = []
        # A ROLLBACK of a transaction MySQL already rolled back: nothing
        # left to do (see #exec_script).
        return rows if refuse_if_transaction_gone(sql)

        @statements_run += 1
        result = run_command(sql, Connection.wire_binds(binds), false)
        names = result.names
        datetimes = result.datetime_columns
        columns = names.size
        result.result_rows.each do |values|
          row = {}
          column = 0
          while column < columns
            value = values[column]
            if epoch && datetimes[column]
              case value
              when String
                us = Connection.epoch_us(value)
                if us >= 0
                  row[names[column]] = Time.at(us / 1_000_000, us % 1_000_000).utc
                else
                  row[names[column]] = value
                end
              else
                row[names[column]] = value
              end
            else
              row[names[column]] = value
            end
            column += 1
          end
          rows << row
        end
        rows
      end

      # Runs a semicolon-separated script (schema DDL, SET); no binds, no
      # rows. COM_QUERY with multi-statements: the script stops at the
      # first statement that fails, as SQLite's exec does.
      def exec_script(sql)
        raise Error, "connection closed (sql: #{sql})" if @closed
        # A ROLLBACK of a transaction MySQL already rolled back has nothing
        # left to do: it would succeed as a no-op, but the statements the
        # application meant to roll back were never in it.
        return nil if refuse_if_transaction_gone(sql)

        run_command(sql, Connection.no_binds, true)
        nil
      end

      # The rows the last INSERT, UPDATE or DELETE changed (matched, for an
      # UPDATE: the session counts found rows, as SQLite does).
      def changes
        raise Error, "connection closed (changes)" if @closed
        @changes
      end

      # The AUTO_INCREMENT id of the last INSERT that made one.
      def last_insert_id
        raise Error, "connection closed (last_insert_id)" if @closed
        @last_insert_id
      end

      # The most `?` binds one statement may carry (65535).
      # @return [Integer]
      # @raise [Cybertrain::DB::Error] when the connection is closed
      # @api public
      def variable_limit
        raise Error, "connection closed (variable_limit)" if @closed
        VARIABLE_LIMIT
      end

      # How many statements #execute and #execute_models have run on this
      # connection (exec_script's are not counted).
      # @return [Integer]
      # @api public
      def statements_run
        @statements_run
      end

      # Whether a transaction is open on this connection, however it was
      # opened ({#begin!}, a `transaction` block or a BEGIN run as SQL): the
      # server's status flags of its last answer.
      # @return [Boolean]
      # @raise [Cybertrain::DB::Error] when the connection is closed
      # @api public
      def in_transaction?
        raise Error, "connection closed (in_transaction?)" if @closed
        @protocol.server_in_transaction?
      end

      # BEGIN / COMMIT around the block, ROLLBACK and re-raise when it
      # raises; a nested call joins the outer transaction. The SQLite
      # Connection's method, with the same caveats (do not break or return
      # out of the block; it returns nil).
      def transaction
        begin!
        begin
          yield
        rescue StandardError => e
          rollback!
          raise e
        end
        commit!
        nil
      end

      # Opens a transaction, or one more nesting level of the open one.
      # `immediate:` is the SQLite Connection's parameter: MySQL takes its
      # row locks statement by statement, so both forms send BEGIN.
      # @param immediate [Boolean] ignored on MySQL
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the connection is closed, when the
      #   enclosing transaction is gone (MySQL rolled it back, or a statement
      #   committed it), or when the BEGIN fails
      # @api public
      def begin!(immediate: false)
        raise Error, "connection closed (transaction)" if @closed

        # A depth above 0 while the server has no transaction open means
        # the enclosing one is gone (a deadlock rolled it back, a DDL
        # statement committed it) and the application went on. Nesting into
        # it would run this block without a transaction; raising is the
        # only honest answer. Pool#check_in resets the depth.
        if @transaction_depth > 0 && !@protocol.server_in_transaction?
          raise Error, "transaction: the enclosing transaction is no longer open (MySQL rolled it back " \
                       "after an error, or a statement committed it); nothing nested in it can be committed"
        end
        if @transaction_depth > 0
          @transaction_depth += 1
          return nil
        end
        refuse_if_transaction_gone("BEGIN")

        run_command("BEGIN", Connection.no_binds, true)
        @transaction_depth = 1
        nil
      end

      # Ends one level opened by {#begin!}. A nested level only counts down;
      # the outermost one COMMITs. A failed COMMIT is rolled back before its
      # error is re-raised.
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the connection is closed, when no
      #   transaction is open, when the server no longer has it open (rolled
      #   back after an error, or committed by a DDL statement), or when the
      #   COMMIT fails
      # @api public
      def commit!
        raise Error, "connection closed (commit!)" if @closed
        raise Error, "commit!: no transaction is open on this connection" if @transaction_depth == 0
        if @transaction_depth > 1
          @transaction_depth -= 1
          return nil
        end

        @transaction_depth = 0
        # MySQL answers a COMMIT with nothing open with OK: after a
        # deadlock rolled the transaction back (and the block rescued it),
        # or a DDL statement committed it, the caller would be told its
        # writes were committed. SQLite refuses that COMMIT ("cannot commit
        # - no transaction is active"); so is it refused here, a DB::Error
        # with the statement, after the bookkeeping is reset.
        if @transaction_lost || !@protocol.server_in_transaction?
          abandon_transaction!
          raise Error, Connection.transaction_gone_message("COMMIT")
        end
        begin
          run_command("COMMIT", Connection.no_binds, true)
        rescue Error => e
          abandon_transaction!
          raise e
        end
        nil
      end

      # Ends one level opened by {#begin!} after an error: the outermost
      # level ROLLBACKs, a nested one only counts down. Never raises.
      # @return [nil]
      # @api public
      def rollback!
        if @transaction_depth > 1
          @transaction_depth -= 1
          return nil
        end
        abandon_transaction!
        nil
      end

      # Rolls back whatever was left open and resets the depth; never raises.
      # Returns what happened, for Pool#check_in's log line:
      #   :clean       -- nothing was open (or the connection is closed);
      #   :rolled_back -- a ROLLBACK was sent and the server has no
      #                   transaction open any more;
      #   :failed      -- the ROLLBACK did not end the transaction, or the
      #                   connection was lost sending it: the Pool closes
      #                   it and opens a new one on the next checkout.
      def abandon_transaction!
        @transaction_depth = 0
        @transaction_lost = false
        return :clean if @closed
        return :clean unless @protocol.server_in_transaction?

        send_rollback
        return :failed if @closed

        @protocol.server_in_transaction? ? :failed : :rolled_back
      end

      # Ends the session (COM_QUIT) and closes the stream. The server drops
      # the session's prepared statements and rolls back what it left open.
      def close
        return nil if @closed

        @closed = true
        @statements.forget_statements
        @protocol.quit
        Connection.close_quietly(@stream)
        nil
      end

      def closed?
        @closed
      end

      # epoch microseconds of "YYYY-MM-DD HH:MM:SS.ffffff" read as UTC (the
      # text result.rb decodes every DATETIME and TIMESTAMP to), or -1 for
      # text of another shape or a zero date.
      # @return [Integer]
      def self.epoch_us(text)
        s = text.to_s # NOTES rule 62
        return -1 unless s.bytesize == 26

        year = Connection.digits(s, 0, 4)
        month = Connection.digits(s, 5, 2)
        day = Connection.digits(s, 8, 2)
        hour = Connection.digits(s, 11, 2)
        minute = Connection.digits(s, 14, 2)
        second = Connection.digits(s, 17, 2)
        micro = Connection.digits(s, 20, 6)
        return -1 if year < 1 || month < 1 || month > 12 || day < 1 || day > 31
        return -1 if hour < 0 || minute < 0 || second < 0 || micro < 0

        days = Connection.days_from_civil(year, month, day)
        ((days * 86_400) + (hour * 3600) + (minute * 60) + second) * 1_000_000 + micro
      end

      # The number `count` decimal digits at `pos` spell, or -1.
      def self.digits(s, pos, count)
        value = 0
        i = 0
        while i < count
          b = s.getbyte(pos + i)
          return -1 if b < 48 || b > 57

          value = value * 10 + (b - 48)
          i += 1
        end
        value
      end

      # Days since 1970-01-01 of a proleptic Gregorian date, year 1 or later
      # (Howard Hinnant's days_from_civil).
      def self.days_from_civil(year, month, day)
        y = month <= 2 ? year - 1 : year
        era = y / 400
        yoe = y - era * 400
        mp = month > 2 ? month - 3 : month + 9
        doy = (153 * mp + 2) / 5 + day - 1
        doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        era * 146_097 + doe - 719_468
      end

      # An empty bind list of the type #wire_binds answers.
      def self.no_binds
        out = [nil, 0, 0.0, "", Blob.new("")]
        out.clear
        out
      end

      # The binds as the binary protocol sends them (Protocol.bind_block):
      # nil, Integer, Float, String and DB::Blob as they are; true and false
      # as 1 and 0; a Time as its UTC text (Cast.sql_datetime); anything
      # else, a Date included, as its to_s. As the SQLite Connection binds.
      def self.wire_binds(binds)
        out = Connection.no_binds
        binds.each do |value|
          case value
          when nil then out << nil
          when true then out << 1
          when false then out << 0
          when Integer then out << value
          when Float then out << value
          when String then out << value
          when Blob then out << value
          when Time then out << Cast.sql_datetime(value)
          else out << value.to_s
          end
        end
        out
      end

      private

      # Runs one command: a prepared statement (`script` false) or
      # COM_QUERY (true). Keeps changes and last_insert_id from an OK
      # answer. Every error leaves with the statement appended, in its own
      # class; one that leaves the stream out of step closes the connection
      # first and is ConnectionLost (see the header). The rescue clauses
      # name each class in full (NOTES rule 70) and tell the errors apart
      # (rule 47).
      def run_command(sql, binds, script)
        in_transaction = @protocol.server_in_transaction?
        begin
          result = script ? @protocol.query(sql) : prepared_result(sql, binds)
        rescue Cybertrain::DB::ConnectionLost => e
          lose_connection
          raise ConnectionLost, Connection.with_sql(e.message, sql)
        rescue Cybertrain::Net::Error => e
          lose_connection
          raise ConnectionLost, Connection.with_sql(e.message, sql)
        rescue Cybertrain::DB::UniqueViolation => e
          note_lost_transaction(in_transaction, sql)
          raise UniqueViolation, Connection.with_sql(e.message, sql)
        rescue Cybertrain::DB::ForeignKeyViolation => e
          note_lost_transaction(in_transaction, sql)
          raise ForeignKeyViolation, Connection.with_sql(e.message, sql)
        rescue Cybertrain::DB::Deadlock => e
          note_lost_transaction(in_transaction, sql)
          raise Deadlock, Connection.with_sql(e.message, sql)
        rescue Cybertrain::DB::LockTimeout => e
          note_lost_transaction(in_transaction, sql)
          raise LockTimeout, Connection.with_sql(e.message, sql)
        rescue Cybertrain::DB::Error => e
          if @protocol.exchange_pending?
            lose_connection
            raise ConnectionLost, Connection.with_sql(e.message, sql)
          end
          note_lost_transaction(in_transaction, sql)
          raise Error, Connection.with_sql(e.message, sql)
        rescue StandardError => e
          # Not the driver's own error (a bug, a runtime fault): the stream
          # is unusable if it struck part way through an answer.
          raise e unless @protocol.exchange_pending?

          lose_connection
          raise ConnectionLost, Connection.with_sql("#{e.class.name}: #{e.message}", sql)
        end
        if result.names.empty?
          @changes = result.affected_rows
          @last_insert_id = result.last_insert_id if result.last_insert_id > 0
        end
        result
      end

      # A prepared statement's result, or COM_QUERY's for a statement the
      # server cannot prepare and that has no binds.
      def prepared_result(sql, binds)
        id = prepared_id(sql, binds.empty?)
        return @protocol.query(sql) if id < 0

        @protocol.execute_statement(id, binds)
      end

      # The cached statement id of sql, or -1 when the server refused to
      # prepare it as unsupported (1295) and it may run as a query instead.
      def prepared_id(sql, may_query)
        @statements.cached_statement_id(sql)
      rescue Cybertrain::DB::Error => e
        raise e unless may_query && @protocol.last_error_code == UNSUPPORTED_PS && !@protocol.exchange_pending?

        -1
      end

      def self.with_sql(message, sql)
        "#{message} (sql: #{sql})"
      end

      # The stream is out of step or gone: closed, never used again. The
      # server rolls back what the session left open.
      def lose_connection
        @closed = true
        @statements.forget_statements
        Connection.close_quietly(@stream)
        nil
      end

      # ROLLBACK for #abandon_transaction!, which must not raise. A lost
      # connection is closed.
      def send_rollback
        @protocol.query("ROLLBACK")
        nil
      rescue Cybertrain::DB::ConnectionLost, Cybertrain::Net::Error
        lose_connection
      rescue Cybertrain::DB::Error
        lose_connection if @protocol.exchange_pending?
        nil
      end

      # Raises instead of running sql when the application's transaction is
      # gone, as the SQLite Connection does (saeki-mototsune/CyberTrain#158):
      #
      # * @transaction_lost: a statement that started inside a transaction
      #   failed and the server rolled the transaction back
      #   (#note_lost_transaction). COMMIT and ROLLBACK end the lost
      #   transaction and are let through; true is returned for a ROLLBACK,
      #   which has nothing left to do.
      # * a depth above 0 while the server has no transaction open: the
      #   transaction #begin! opened is gone, however it went.
      #
      # #abandon_transaction! clears both. Returns false when sql may run.
      def refuse_if_transaction_gone(sql)
        if @transaction_lost
          if Connection.ends_transaction?(sql)
            @transaction_lost = false
            return Connection.rollback_statement?(sql)
          end
          raise Error, Connection.transaction_gone_message(sql)
        end
        return false if @transaction_depth == 0
        return false if @protocol.server_in_transaction?

        raise Error, Connection.transaction_gone_message(sql)
      end

      # After sql failed with a server error: a statement that started
      # inside a transaction may have taken the transaction with it (a
      # deadlock rolls the whole of it back; most errors undo only their
      # own statement). The ERR packet carries no status flags, so a
      # COM_PING asks (errors are rare; a ping is one round trip). A failed
      # COMMIT or ROLLBACK is the application ending the transaction itself
      # and marks nothing; so does a ping that fails (the connection is
      # then lost and closed by the next command).
      def note_lost_transaction(in_transaction, sql)
        return nil unless in_transaction
        return nil if Connection.ends_transaction?(sql)
        return nil unless @protocol.ping
        return nil if @protocol.server_in_transaction?

        @transaction_lost = true
        nil
      end

      def self.transaction_gone_message(sql)
        "the enclosing transaction is no longer open (MySQL rolled it back after an error, or a statement " \
          "committed it); the statement was not run (sql: #{sql})"
      end

      # The statements around a transaction are recognised by a small lexer
      # that reads SQL the way MySQL tokenizes it: whitespace, `#` and
      # `-- ` comments to the end of the line and `/* ... */` comments
      # separate tokens; a ";" inside a comment or a quoted string or name
      # does not end a statement; keywords are case-insensitive. Only the
      # first statement's leading keywords are read.

      # Whether the first statement of sql is COMMIT or ROLLBACK, each
      # optionally followed by WORK and nothing else: the statements that
      # end a transaction (ROLLBACK [WORK] TO a savepoint does not, nor
      # does anything longer).
      def self.ends_transaction?(sql)
        words = Connection.statement_words(sql)
        Connection.bare_keyword?(words, "COMMIT") || Connection.bare_keyword?(words, "ROLLBACK")
      end

      # A ROLLBACK and nothing else (comments, empty statements and a
      # trailing ";" allowed). A script that goes on after its ROLLBACK
      # runs, so what follows is never dropped silently.
      def self.rollback_statement?(sql)
        Connection.bare_keyword?(Connection.statement_words(sql), "ROLLBACK") && !Connection.statement_follows?(sql)
      end

      # words is exactly [keyword] or [keyword, "WORK"].
      def self.bare_keyword?(words, keyword)
        return false if words.empty? || words[0] != keyword
        return true if words.size == 1

        words.size == 2 && words[1] == "WORK"
      end

      # Every word of the first statement, upcased, up to its ";" or the end
      # of sql. Empty when the statement holds anything but words.
      def self.statement_words(sql)
        s = sql.to_s
        words = Array.new(0) { "" }
        n = s.bytesize
        i = Connection.skip_blank(s, 0)
        while i < n && s.getbyte(i) != 59 # ;
          return Array.new(0) { "" } unless Connection.word_byte?(s.getbyte(i))

          start = i
          i += 1 while i < n && Connection.word_byte?(s.getbyte(i))
          words << s.byteslice(start, i - start).to_s.upcase
          i = Connection.skip_blank(s, i)
        end
        words
      end

      # Whether a statement follows the first one: anything but whitespace,
      # comments and empty statements after the first ";" outside a comment
      # or a quoted string or name.
      def self.statement_follows?(sql)
        s = sql.to_s
        n = s.bytesize
        i = 0
        while i < n
          i = Connection.skip_blank(s, i)
          break if i >= n

          c = s.getbyte(i)
          if c == 59 # ;
            i = Connection.skip_blank(s, i + 1)
            i = Connection.skip_blank(s, i + 1) while i < n && s.getbyte(i) == 59
            return i < n
          elsif c == 39 || c == 34 || c == 96 # ' " `
            i = Connection.skip_quoted(s, i, c)
          else
            i += 1
          end
        end
        false
      end

      # The index after whitespace and comments from i (s.bytesize at the
      # end): `#` to the end of the line, `--` followed by a blank (MySQL's
      # rule: `--x` is not a comment) to the end of the line, `/* */`.
      def self.skip_blank(s, i)
        n = s.bytesize
        while i < n
          c = s.getbyte(i)
          if c == 32 || (c >= 9 && c <= 13)
            i += 1
          elsif c == 35 || (c == 45 && i + 1 < n && s.getbyte(i + 1) == 45 && (i + 2 >= n || Connection.blank_byte?(s.getbyte(i + 2))))
            i += 1
            i += 1 while i < n && s.getbyte(i) != 10
          elsif c == 47 && i + 1 < n && s.getbyte(i + 1) == 42 # /*
            i += 2
            i += 1 while i + 1 < n && !(s.getbyte(i) == 42 && s.getbyte(i + 1) == 47)
            i = i + 1 < n ? i + 2 : n
          else
            return i
          end
        end
        n
      end

      def self.blank_byte?(c)
        c == 32 || (c >= 0 && c <= 31)
      end

      # The index after the quoted token that opens at i and closes with
      # close: a doubled close quote is part of it, and in a ' or " string a
      # backslash escapes the next byte.
      def self.skip_quoted(s, i, close)
        n = s.bytesize
        i += 1
        while i < n
          c = s.getbyte(i)
          if c == 92 && close != 96 # \
            i += 2
          elsif c == close
            return i + 1 unless i + 1 < n && s.getbyte(i + 1) == close

            i += 2
          else
            i += 1
          end
        end
        n
      end

      def self.word_byte?(c)
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
      end
    end
  end
end
