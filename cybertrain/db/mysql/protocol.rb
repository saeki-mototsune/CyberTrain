# MySQL commands after authentication, over a PacketIO: COM_QUERY (the
# text protocol, multi-statements included), COM_STMT_PREPARE /
# COM_STMT_EXECUTE / COM_STMT_CLOSE (the binary protocol), COM_PING and
# COM_QUIT. Each command starts at sequence 0 and reads the server's whole
# answer, so the connection is in step for the next one; result.rb decodes
# the packets and maps ERR packets to the DB::Error classes.
#
# The client's capabilities (auth.rb) include CLIENT_DEPRECATE_EOF,
# MULTI_STATEMENTS, MULTI_RESULTS and PS_MULTI_RESULTS: column
# definitions are not followed by an EOF packet, a result set ends with an
# OK packet whose header is 0xFE, and SERVER_MORE_RESULTS_EXISTS in an OK's
# status says another result follows. A multi-statement query answers its
# last result; an ERR part way raises, and the server sends nothing after
# it.
require "cybertrain/net/socket"
require "cybertrain/db/error"
require "cybertrain/db/blob"
require "cybertrain/db/mysql/wire"
require "cybertrain/db/mysql/packet"
require "cybertrain/db/mysql/result"

module Cybertrain
  module DB
    module MySQL
      # @api private
      class Protocol
        COM_QUIT = 0x01
        COM_QUERY = 0x03
        COM_PING = 0x0E
        COM_STMT_PREPARE = 0x16
        COM_STMT_EXECUTE = 0x17
        COM_STMT_CLOSE = 0x19
        SERVER_MORE_RESULTS_EXISTS = 0x0008

        # Parameter types of COM_STMT_EXECUTE, each sent with a second byte
        # of flags (0x80 is unsigned; every bind is signed).
        BIND_LONGLONG = 0x08
        BIND_DOUBLE = 0x05
        BIND_NULL = 0x06
        BIND_VAR_STRING = 0xFD
        BIND_BLOB = 0xFC

        # @param io [PacketIO] an authenticated connection
        def initialize(io)
          @io = io
          @more_results = false
          # statement id => parameter count, for the statements prepared
          # and not closed (NOTES rule 9: seeded).
          @param_counts = { 0 => 0 }
          @param_counts.delete(0)
        end

        # Runs `sql` with COM_QUERY.
        # @return [Result] the last statement's result
        # @raise [Cybertrain::DB::Error] the first ERR, mapped (result.rb)
        def query(sql)
          start_command(COM_QUERY, sql.to_s)
          read_results(false)
        end

        # Prepares `sql` with COM_STMT_PREPARE.
        # @return [Integer] the statement id
        def prepare(sql)
          start_command(COM_STMT_PREPARE, sql.to_s)
          packet = @io.read_packet
          raise Cybertrain::DB::Error, "MySQL: the server sent an empty packet to COM_STMT_PREPARE" if packet.empty?

          Decode.raise_server_error(packet) if packet.getbyte(0) == 0xFF
          raise Cybertrain::DB::Error, "MySQL: unexpected answer to COM_STMT_PREPARE" if packet.getbyte(0) != 0 || packet.bytesize < 12

          id = Wire.read_int_le(packet, 1, 4)
          columns = Wire.read_int_le(packet, 5, 2)
          params = Wire.read_int_le(packet, 7, 2)
          # The parameter and column definitions: not needed, as each
          # execute's answer carries its own column definitions.
          skip = 0
          while skip < params + columns
            @io.read_packet
            skip += 1
          end
          @param_counts[id] = params
          id
        end

        # How many `?` the prepared statement `id` has.
        def param_count(id)
          raise Cybertrain::DB::Error, "MySQL: statement #{id} is not prepared on this connection" unless @param_counts.key?(id)

          @param_counts[id]
        end

        # Runs the prepared statement `id` with COM_STMT_EXECUTE: flags 0
        # (no cursor), iteration count 1, then for a statement with
        # parameters the NULL bitmap, new-params-bound 1, a type (2 bytes)
        # per parameter and the non-NULL values. Binds: Integer as LONGLONG,
        # Float as DOUBLE, String as VAR_STRING and DB::Blob as BLOB (their
        # bytes as they are), nil as a NULL bit.
        #
        # `execute_statement`, not `execute`: Connection#execute answers
        # Array<Hash> (NOTES rules 10, 34).
        # @param binds [Array<Integer, Float, String, DB::Blob, nil>]
        # @return [Result]
        def execute_statement(id, binds)
          count = param_count(id)
          if binds.size != count
            raise Cybertrain::DB::Error, "MySQL: statement #{id} takes #{count} parameters, #{binds.size} given"
          end

          body = Wire.int_le(id, 4)
          body << Wire.int_le(0, 1)
          body << Wire.int_le(1, 4)
          body << Protocol.bind_block(binds) if count > 0
          start_command(COM_STMT_EXECUTE, body)
          read_results(true)
        end

        # The NULL bitmap, new-params-bound, the types and the values.
        def self.bind_block(binds)
          count = binds.size
          bitmap = "0" * ((count + 7) / 8)
          i = 0
          while i < bitmap.bytesize
            bitmap.setbyte(i, 0)
            i += 1
          end
          types = String.new
          values = String.new
          i = 0
          while i < count
            value = binds[i]
            case value
            when nil
              bitmap.setbyte(i / 8, bitmap.getbyte(i / 8) | (1 << (i % 8)))
              types << Wire.int_le(BIND_NULL, 1)
            when Integer
              types << Wire.int_le(BIND_LONGLONG, 1)
              values << Wire.int_le(value, 8)
            when Float
              types << Wire.int_le(BIND_DOUBLE, 1)
              values << [value].pack("E")
            when String
              types << Wire.int_le(BIND_VAR_STRING, 1)
              values << Wire.lenenc_str(value)
            when Cybertrain::DB::Blob
              types << Wire.int_le(BIND_BLOB, 1)
              values << Wire.lenenc_str(value.blob_bytes)
            else
              raise Cybertrain::DB::Error, "MySQL: cannot bind a #{value.class.name} (Integer, Float, String, DB::Blob or nil)"
            end
            types << Wire.int_le(0, 1)
            i += 1
          end
          out = String.new
          out << bitmap
          out << Wire.int_le(1, 1)
          out << types
          out << values
          out
        end

        # Deallocates the prepared statement `id` (COM_STMT_CLOSE; the
        # server does not answer).
        # @return [nil]
        def close_statement(id)
          start_command(COM_STMT_CLOSE, Wire.int_le(id, 4))
          @param_counts.delete(id)
          nil
        end

        # COM_PING: true when the server answers OK, false when the
        # connection is lost or the server does not answer in time.
        # @return [Boolean]
        def ping
          start_command(COM_PING, "")
          packet = @io.read_packet
          Decode.raise_server_error(packet) if !packet.empty? && packet.getbyte(0) == 0xFF
          !packet.empty? && packet.getbyte(0) == 0
        rescue Cybertrain::DB::ConnectionLost, Cybertrain::Net::TimeoutError
          false
        end

        # COM_QUIT: the server closes the connection without answering. A
        # connection already gone is not an error here. The stream is the
        # caller's to close.
        # @return [nil]
        def quit
          start_command(COM_QUIT, "")
          nil
        rescue Cybertrain::DB::ConnectionLost, Cybertrain::Net::TimeoutError
          nil
        end

        def start_command(command, body)
          @io.reset_sequence
          payload = Wire.int_le(command, 1)
          payload << body
          @io.write_packet(payload)
          nil
        end

        # Every result of the command, the last one answered. `binary`:
        # rows in the binary protocol (COM_STMT_EXECUTE).
        def read_results(binary)
          overflow = String.new
          result = read_result(binary, overflow)
          result = read_result(binary, overflow) while @more_results
          unless overflow.empty?
            raise Cybertrain::DB::Error, "MySQL: column #{overflow} holds a BIGINT UNSIGNED value past 2**63 - 1, which an Integer cannot hold"
          end

          result
        end

        # One result: an OK packet, or a result set (column count, column
        # definitions, rows, the 0xFE OK). Sets @more_results from the
        # status flags.
        def read_result(binary, overflow)
          @more_results = false
          packet = @io.read_packet
          raise Cybertrain::DB::Error, "MySQL: the server sent an empty packet" if packet.empty?

          first = packet.getbyte(0)
          if first == 0x00
            ok = Decode.ok_fields(packet)
            @more_results = (ok[2] & SERVER_MORE_RESULTS_EXISTS) != 0
            return Result.from_ok(ok[0], ok[1])
          end
          Decode.raise_server_error(packet) if first == 0xFF
          raise Cybertrain::DB::Error, "MySQL: the server asked for LOCAL INFILE, which is not supported" if first == 0xFB

          count = Wire.read_lenenc_int(packet, 0)[0]
          columns = Decode.no_columns
          while columns.size < count
            columns << Decode.column_definition(@io.read_packet)
          end
          rows = Decode.no_rows
          while true
            row = @io.read_packet
            if Decode.end_of_rows?(row)
              @more_results = (Decode.ok_fields(row)[2] & SERVER_MORE_RESULTS_EXISTS) != 0
              break
            end
            Decode.raise_server_error(row) if !row.empty? && row.getbyte(0) == 0xFF
            if binary
              rows << Decode.binary_row(row, columns, overflow)
            else
              rows << Decode.text_row(row, columns, overflow)
            end
          end
          Result.from_rows(columns, rows)
        end
      end
    end
  end
end
