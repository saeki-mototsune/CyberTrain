# What a MySQL command answers, decoded: column definitions, rows in the
# text protocol (COM_QUERY) and the binary protocol (COM_STMT_EXECUTE), OK
# packets, and ERR packets mapped to the DB::Error classes. protocol.rb
# sends the commands and reads the packets; everything here is pure
# functions over packet payloads.
#
# Values by column type (both protocols give the same Ruby value):
#
# - TINY, SHORT, LONG, LONGLONG, INT24, YEAR: Integer. A BIGINT UNSIGNED
#   past 2**63 - 1 has no Integer (Spinel's Integer is 64-bit, NOTES rule
#   25): the result is read to its end, so the connection stays in step,
#   and then refused with a DB::Error naming the column.
# - FLOAT, DOUBLE, DECIMAL, NEWDECIMAL: Float (docs/design.md D73). A
#   binary FLOAT is the shortest decimal that is the same single-precision
#   value, which is what the text protocol sends (1.1, not
#   1.100000023841858).
# - DATE: "YYYY-MM-DD". DATETIME, TIMESTAMP: "YYYY-MM-DD HH:MM:SS.ffffff",
#   always six fraction digits, as Cast.sql_datetime writes and SQLite's
#   `execute` answers. A zero date decodes as zeros ("0000-00-00").
# - TIME: the text protocol's own form ("-838:59:59", with the column's
#   fraction digits).
# - Everything else (CHAR, VARCHAR, TEXT, JSON, ENUM, SET, BLOB, BINARY,
#   BIT, GEOMETRY): String, the bytes as sent. A column whose character
#   set is not binary (63), and JSON, is UTF-8; a binary one stays binary,
#   NUL and invalid UTF-8 included.
# - NULL: nil.
#
# Every offset is a byte offset and every scan reads its payload through a
# fresh `to_s` local (NOTES rules 27, 62).
require "cybertrain/db/error"
require "cybertrain/db/mysql/wire"

module Cybertrain
  module DB
    module MySQL
      # One column definition (Protocol::ColumnDefinition41). Readers are
      # prefixed: `name` and `type` are not plain method names here
      # (NOTES rules 10, 34, 66).
      # @api private
      class Column
        attr_reader :column_name, :column_type_code, :column_flags, :column_decimals, :column_charset

        def initialize(name, type, flags, decimals, charset)
          @column_name = name
          @column_type_code = type
          @column_flags = flags
          @column_decimals = decimals
          @column_charset = charset
        end

        def unsigned?
          (@column_flags & Decode::UNSIGNED_FLAG) != 0
        end

        # A String column read as bytes (BLOB, BINARY, VARBINARY, BIT,
        # GEOMETRY): a string type with character set 63. Dates, times,
        # numbers and JSON report 63 too and are text.
        def binary_bytes?
          return false unless @column_charset == Decode::BINARY_CHARSET

          type = @column_type_code
          type == Decode::TYPE_VARCHAR || type == Decode::TYPE_BIT || type >= Decode::TYPE_TINY_BLOB
        end
      end

      # The answer to one command: the last result of a multi-statement
      # query. A result set has names, types and rows; a statement without
      # one (INSERT, UPDATE, DDL) has affected_rows and last_insert_id.
      #
      # `result_rows`, not `rows`: Relation#rows answers Array<Hash>, and
      # one method name answers one type (NOTES rules 10, 34).
      # @api private
      class Result
        # @return [Array<String>] column names, UTF-8
        attr_reader :names
        # @return [Array<Integer>] MySQL column types (Decode::TYPE_*)
        attr_reader :types
        # @return [Array<Array<Integer, Float, String, nil>>]
        attr_reader :result_rows
        # @return [Integer]
        attr_reader :affected_rows
        # @return [Integer]
        attr_reader :last_insert_id
        # @return [Array<Boolean>] true for a DATETIME or TIMESTAMP column
        attr_reader :datetime_columns

        def initialize(names, types, rows, affected_rows, last_insert_id, datetime_columns)
          @names = names
          @types = types
          @result_rows = rows
          @affected_rows = affected_rows
          @last_insert_id = last_insert_id
          @datetime_columns = datetime_columns
        end

        # A Result for an OK packet: no columns, no rows.
        def self.from_ok(affected_rows, last_insert_id)
          Result.new(Decode.no_names, Decode.no_types, Decode.no_rows, affected_rows, last_insert_id, Decode.no_flags)
        end

        # A Result for a result set.
        # @param columns [Array<Column>]
        def self.from_rows(columns, rows)
          names = Decode.no_names
          types = Decode.no_types
          flags = Decode.no_flags
          i = 0
          while i < columns.size
            column = columns[i]
            names << column.column_name
            types << column.column_type_code
            flags << Decode.datetime_type?(column.column_type_code)
            i += 1
          end
          Result.new(names, types, rows, 0, 0, flags)
        end
      end

      # @api private
      module Decode
        TYPE_DECIMAL = 0
        TYPE_TINY = 1
        TYPE_SHORT = 2
        TYPE_LONG = 3
        TYPE_FLOAT = 4
        TYPE_DOUBLE = 5
        TYPE_NULL = 6
        TYPE_TIMESTAMP = 7
        TYPE_LONGLONG = 8
        TYPE_INT24 = 9
        TYPE_DATE = 10
        TYPE_TIME = 11
        TYPE_DATETIME = 12
        TYPE_YEAR = 13
        TYPE_VARCHAR = 15
        TYPE_BIT = 16
        TYPE_JSON = 245
        TYPE_NEWDECIMAL = 246
        TYPE_TINY_BLOB = 249
        TYPE_BLOB = 252
        TYPE_VAR_STRING = 253
        TYPE_STRING = 254

        UNSIGNED_FLAG = 0x20
        BINARY_CHARSET = 63
        LONGLONG_MAX = "9223372036854775807"

        # Server ERR codes that mean the session is gone: 1053 server
        # shutdown, 4031 disconnected for inactivity (wait_timeout), and
        # 1927 connection killed, which is MariaDB's code (MySQL 8.0 sends
        # no ERR to a killed session, it closes the stream: kept for a
        # server that speaks the protocol and sends it). A stream that ends
        # or resets is ConnectionLost in PacketIO already (what a client
        # library calls 2006 / 2013).
        CONNECTION_LOST_CODES = [1053, 1927, 4031].freeze
        FOREIGN_KEY_CODES = [1451, 1452, 1216, 1217].freeze

        # Typed empty containers (NOTES rule 9).
        def self.no_names
          Array.new(0) { "" }
        end

        def self.no_types
          Array.new(0) { 0 }
        end

        def self.no_flags
          Array.new(0) { false }
        end

        def self.no_columns
          Array.new(0) { Column.new("", 0, 0, 0, 0) }
        end

        # A row: seeded with each type a value can have, then cleared.
        def self.new_row
          row = [nil, 0, 0.0, ""]
          row.clear
          row
        end

        def self.no_rows
          rows = [Decode.new_row]
          rows.clear
          rows
        end

        def self.datetime_type?(type)
          type == TYPE_DATETIME || type == TYPE_TIMESTAMP
        end

        # Protocol::ColumnDefinition41: catalog, schema, table, org_table,
        # name, org_name (length-encoded strings), the length of the fixed
        # fields (0x0c), charset (2), column length (4), type (1), flags
        # (2), decimals (1).
        # @return [Column]
        def self.column_definition(payload)
          s = payload.to_s
          pos = 0
          skip = 0
          while skip < 4
            pos = Wire.read_lenenc_str(s, pos)[1]
            skip += 1
          end
          got = Wire.read_lenenc_str(s, pos)
          name = Decode.utf8(got[0])
          pos = Wire.read_lenenc_str(s, got[1])[1]
          pos = Wire.read_lenenc_int(s, pos)[1]
          raise Cybertrain::DB::Error, "MySQL: a column definition ends early" if pos + 10 > s.bytesize

          charset = Wire.read_int_le(s, pos, 2)
          type = Wire.read_int_le(s, pos + 6, 1)
          flags = Wire.read_int_le(s, pos + 7, 2)
          decimals = Wire.read_int_le(s, pos + 9, 1)
          Column.new(name, type, flags, decimals, charset)
        end

        # An OK packet (header 0x00, or 0xFE where it ends a result set):
        # affected rows and last insert id (length-encoded), status flags.
        # @return [Array<Integer>] [affected_rows, last_insert_id, status]
        def self.ok_fields(payload)
          s = payload.to_s
          affected = Wire.read_lenenc_int(s, 1)
          insert_id = Wire.read_lenenc_int(s, affected[1])
          pos = insert_id[1]
          status = pos + 2 <= s.bytesize ? Wire.read_int_le(s, pos, 2) : 0
          [affected[0], insert_id[0], status]
        end

        # Whether `payload` ends a result set: under CLIENT_DEPRECATE_EOF an
        # OK packet with the 0xFE header. A text row can start with 0xFE
        # only as the length of a value of 16 MB or more, so a payload that
        # short is the terminator.
        def self.end_of_rows?(payload)
          s = payload.to_s
          s.bytesize > 0 && s.bytesize < 0xFFFFFF && s.getbyte(0) == 0xFE
        end

        # Raises the DB::Error for an ERR packet: 0xFF, code (2), "#",
        # SQLSTATE (5), message. The message is the server's, then the code
        # and state: "Duplicate entry '1' for key 't.PRIMARY' (MySQL 1062,
        # 23000)". A packet without the "#" marker has state HY000.
        def self.raise_server_error(payload)
          s = payload.to_s
          raise Cybertrain::DB::Error, "MySQL: the server sent a short error packet" if s.bytesize < 3

          code = Decode.error_code(s)
          message = Decode.server_error_text(s)
          raise Cybertrain::DB::UniqueViolation, message if code == 1062
          raise Cybertrain::DB::ForeignKeyViolation, message if FOREIGN_KEY_CODES.include?(code)
          raise Cybertrain::DB::Deadlock, message if code == 1213
          raise Cybertrain::DB::LockTimeout, message if code == 1205
          raise Cybertrain::DB::ConnectionLost, message if CONNECTION_LOST_CODES.include?(code)

          raise Cybertrain::DB::Error, message
        end

        # An ERR packet's code (0 for a packet too short to hold one).
        def self.error_code(payload)
          s = payload.to_s
          return 0 if s.bytesize < 3

          Wire.read_int_le(s, 1, 2)
        end

        # An ERR packet's message as {raise_server_error} raises it: the
        # server's text, then "(MySQL CODE, SQLSTATE)".
        def self.server_error_text(payload)
          s = payload.to_s
          return "MySQL: the server sent a short error packet" if s.bytesize < 3

          parts = Decode.error_parts(s)
          state = parts[1].empty? ? "HY000" : parts[1]
          "#{parts[2]} (MySQL #{parts[0]}, #{state})"
        end

        # An ERR packet's [code, SQLSTATE ("" when the packet has none, as
        # before the handshake), text marked UTF-8], for a payload of 3
        # bytes or more. The one reader of the ERR layout: a statement's
        # error and a login's (Handshake.error_text) are read the same way.
        # @return [Array<String>] the code as its decimal text
        def self.error_parts(s)
          state = ""
          start = 3
          if s.bytesize >= 9 && s.getbyte(3) == 35 # "#"
            state = Decode.utf8(s.byteslice(4, 5))
            start = 9
          end
          [Decode.error_code(s).to_s, state, Decode.utf8(s.byteslice(start, s.bytesize - start))]
        end

        # A copy of `bytes` marked UTF-8 (a socket's bytes are binary, and
        # appending binary non-ASCII to a UTF-8 String raises; NOTES rule 27).
        def self.utf8(bytes)
          out = String.new
          out << bytes.to_s
          out.force_encoding("UTF-8")
          out
        end

        # One text-protocol row: a length-encoded string (or 0xFB, NULL)
        # per column, converted by the column's type. A BIGINT UNSIGNED
        # past 2**63 - 1 is nil here and its column's name goes to
        # `overflow` (protocol.rb refuses the result once it has been read).
        def self.text_row(payload, columns, overflow)
          s = payload.to_s
          row = Decode.new_row
          pos = 0
          i = 0
          while i < columns.size
            got = Wire.read_lenenc_str_or_nil(s, pos)
            pos = got[1]
            value = got[0]
            if value.nil?
              row << nil
            else
              Decode.add_text_value(row, value, columns[i], overflow)
            end
            i += 1
          end
          row
        end

        def self.add_text_value(row, value, column, overflow)
          text = value.to_s
          type = column.column_type_code
          if Decode.integer_type?(type)
            if type == TYPE_LONGLONG && column.unsigned? && Decode.past_longlong?(text)
              overflow << "'#{column.column_name}'" if overflow.empty?
              row << nil
            else
              row << text.to_i
            end
          elsif Decode.float_type?(type)
            row << text.to_f
          elsif Decode.datetime_type?(type)
            row << Decode.datetime_six(text)
          elsif column.binary_bytes?
            row << text
          else
            row << Decode.utf8(text)
          end
          nil
        end

        def self.integer_type?(type)
          type == TYPE_TINY || type == TYPE_SHORT || type == TYPE_LONG || type == TYPE_LONGLONG ||
            type == TYPE_INT24 || type == TYPE_YEAR
        end

        def self.float_type?(type)
          type == TYPE_FLOAT || type == TYPE_DOUBLE || type == TYPE_DECIMAL || type == TYPE_NEWDECIMAL
        end

        # Unsigned decimal digits greater than 2**63 - 1. Compared as text:
        # `to_i` raises past it (NOTES rule 25).
        def self.past_longlong?(digits)
          s = digits.to_s
          return true if s.bytesize > LONGLONG_MAX.bytesize
          return false if s.bytesize < LONGLONG_MAX.bytesize

          s > LONGLONG_MAX
        end

        # "YYYY-MM-DD HH:MM:SS" with the fraction the column has (none for
        # DATETIME, up to six digits) made six digits long.
        def self.datetime_six(text)
          s = text.to_s
          out = String.new
          out << s
          if s.bytesize == 19
            out << ".000000"
          elsif s.bytesize > 20 && s.bytesize < 26
            out << ("0" * (26 - s.bytesize))
          end
          Decode.utf8(out)
        end

        # One binary-protocol row: 0x00, the NULL bitmap ((columns + 9) / 8
        # bytes; column i is bit i + 2), then each non-NULL value in the
        # binary form of its type.
        def self.binary_row(payload, columns, overflow)
          s = payload.to_s
          count = columns.size
          raise Cybertrain::DB::Error, "MySQL: a binary row does not start with 0x00" if s.empty? || s.getbyte(0) != 0

          pos = 1 + (count + 9) / 8
          raise Cybertrain::DB::Error, "MySQL: a binary row ends inside its NULL bitmap" if pos > s.bytesize

          row = Decode.new_row
          i = 0
          while i < count
            bit = i + 2
            if (s.getbyte(1 + bit / 8) >> (bit % 8)) & 1 == 1
              row << nil
            else
              pos = Decode.add_binary(row, s, pos, columns[i], overflow)
            end
            i += 1
          end
          row
        end

        # Appends the value at `pos` and answers the position after it.
        def self.add_binary(row, payload, pos, column, overflow)
          s = payload.to_s
          type = column.column_type_code
          unsigned = column.unsigned?
          if type == TYPE_TINY
            row << Decode.fixed_int(s, pos, 1, unsigned)
            return pos + 1
          end
          if type == TYPE_SHORT || type == TYPE_YEAR
            row << Decode.fixed_int(s, pos, 2, unsigned)
            return pos + 2
          end
          if type == TYPE_LONG || type == TYPE_INT24
            row << Decode.fixed_int(s, pos, 4, unsigned)
            return pos + 4
          end
          if type == TYPE_LONGLONG
            raise Cybertrain::DB::Error, "MySQL: a binary row ends inside a BIGINT" if pos + 8 > s.bytesize

            top = s.getbyte(pos + 7)
            if unsigned && top >= 0x80
              overflow << "'#{column.column_name}'" if overflow.empty?
              row << nil
            else
              top -= 256 if top >= 0x80
              row << ((top << 56) + Wire.read_int_le(s, pos, 7))
            end
            return pos + 8
          end
          if type == TYPE_FLOAT
            raise Cybertrain::DB::Error, "MySQL: a binary row ends inside a FLOAT" if pos + 4 > s.bytesize

            row << Decode.single_float(s.byteslice(pos, 4))
            return pos + 4
          end
          if type == TYPE_DOUBLE
            raise Cybertrain::DB::Error, "MySQL: a binary row ends inside a DOUBLE" if pos + 8 > s.bytesize

            row << s.byteslice(pos, 8).unpack1("E")
            return pos + 8
          end
          if type == TYPE_DATE || type == TYPE_DATETIME || type == TYPE_TIMESTAMP
            size = Wire.read_int_le(s, pos, 1)
            raise Cybertrain::DB::Error, "MySQL: a binary row ends inside a date" if pos + 1 + size > s.bytesize

            row << Decode.binary_date(s, pos + 1, size, type == TYPE_DATE)
            return pos + 1 + size
          end
          if type == TYPE_TIME
            size = Wire.read_int_le(s, pos, 1)
            raise Cybertrain::DB::Error, "MySQL: a binary row ends inside a time" if pos + 1 + size > s.bytesize

            row << Decode.binary_time(s, pos + 1, size, column.column_decimals)
            return pos + 1 + size
          end

          got = Wire.read_lenenc_str(s, pos)
          Decode.add_text_value(row, got[0], column, overflow)
          got[1]
        end

        # A little-endian integer of `bytes` bytes (1, 2 or 4), signed
        # unless the column is UNSIGNED.
        def self.fixed_int(payload, pos, bytes, unsigned)
          value = Wire.read_int_le(payload, pos, bytes)
          return value if unsigned

          half = 1 << (8 * bytes - 1)
          value >= half ? value - 2 * half : value
        end

        # The shortest decimal (6 to 9 significant digits) that is the same
        # single-precision value: MySQL's own text for a FLOAT.
        def self.single_float(bytes)
          raw = bytes.to_s
          value = raw.unpack1("e")
          digits = 6
          while digits <= 9
            candidate = format("%.#{digits}g", value).to_f
            return candidate if [candidate].pack("e").unpack1("e") == value

            digits += 1
          end
          value
        end

        # DATE, DATETIME, TIMESTAMP: `size` (0, 4, 7 or 11) bytes of year
        # (2), month, day, hour, minute, second, microseconds (4).
        def self.binary_date(payload, pos, size, date_only)
          s = payload.to_s
          year = 0
          month = 0
          day = 0
          hour = 0
          minute = 0
          second = 0
          micro = 0
          if size >= 4
            year = Wire.read_int_le(s, pos, 2)
            month = s.getbyte(pos + 2)
            day = s.getbyte(pos + 3)
          end
          if size >= 7
            hour = s.getbyte(pos + 4)
            minute = s.getbyte(pos + 5)
            second = s.getbyte(pos + 6)
          end
          micro = Wire.read_int_le(s, pos + 7, 4) if size >= 11
          return format("%04d-%02d-%02d", year, month, day) if date_only

          format("%04d-%02d-%02d %02d:%02d:%02d.%06d", year, month, day, hour, minute, second, micro)
        end

        # TIME: `size` (0, 8 or 12) bytes of sign (1), days (4), hour,
        # minute, second, microseconds (4). Written as the text protocol
        # writes it: hours past 24 for the days, `decimals` fraction digits.
        def self.binary_time(payload, pos, size, decimals)
          s = payload.to_s
          negative = false
          hours = 0
          minute = 0
          second = 0
          micro = 0
          if size >= 8
            negative = s.getbyte(pos) == 1
            hours = Wire.read_int_le(s, pos + 1, 4) * 24 + s.getbyte(pos + 5)
            minute = s.getbyte(pos + 6)
            second = s.getbyte(pos + 7)
          end
          micro = Wire.read_int_le(s, pos + 8, 4) if size >= 12
          out = String.new
          out << "-" if negative
          out << format("%02d:%02d:%02d", hours, minute, second)
          digits = decimals
          digits = (micro == 0 ? 0 : 6) if digits > 6
          if digits > 0
            out << "."
            out << format("%06d", micro).byteslice(0, digits)
          end
          Decode.utf8(out)
        end
      end
    end
  end
end
