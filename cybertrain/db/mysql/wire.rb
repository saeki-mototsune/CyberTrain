# MySQL client/server protocol encodings: length-encoded integers and
# strings, little-endian fixed-width integers and NUL-terminated strings.
# Pure functions over byte Strings; framing is in packet.rb.
#
# Every offset is a byte offset (spikes/NOTES.md rule 27), every scan reads
# its parameter through a fresh local (rule 62), and bytes are made with
# `setbyte` on a buffer of the final size or by slicing, never by appending
# `n.chr` (rule 60 and the Test.binary note in cybertrain/test/client.rb).
require "cybertrain/db/error"

module Cybertrain
  module DB
    module MySQL
      # @api private
      module Wire
        # Length-encoded integer: 0..250 in one byte, then 0xFC + 2 bytes,
        # 0xFD + 3 bytes, 0xFE + 8 bytes (all little-endian). 0xFB is NULL
        # and 0xFF the error marker, so neither is a length.
        def self.lenenc_int(value)
          raise Cybertrain::DB::Error, "MySQL: cannot encode a negative length (#{value})" if value < 0
          return Wire.int_le(value, 1) if value < 251

          if value <= 0xFFFF
            out = Wire.int_le(0xFC, 1)
            out << Wire.int_le(value, 2)
          elsif value <= 0xFFFFFF
            out = Wire.int_le(0xFD, 1)
            out << Wire.int_le(value, 3)
          else
            out = Wire.int_le(0xFE, 1)
            out << Wire.int_le(value, 8)
          end
          out
        end

        # The integer at `pos` and the position after it.
        # @return [Array<Integer>] [value, next_pos]
        def self.read_lenenc_int(text, pos)
          s = text.to_s
          raise Cybertrain::DB::Error, "MySQL: packet ends before a length" if pos >= s.bytesize

          first = s.getbyte(pos)
          return [first, pos + 1] if first < 251

          if first == 0xFC
            [Wire.read_int_le(s, pos + 1, 2), pos + 3]
          elsif first == 0xFD
            [Wire.read_int_le(s, pos + 1, 3), pos + 4]
          elsif first == 0xFE
            # The top byte is checked first: a length past 2**63 - 1 would
            # wrap negative, and no packet carries one.
            raise Cybertrain::DB::Error, "MySQL: packet ends before a length" if pos + 9 > s.bytesize
            raise Cybertrain::DB::Error, "MySQL: length out of range" if s.getbyte(pos + 8) > 0x7F

            [Wire.read_int_le(s, pos + 1, 8), pos + 9]
          else
            raise Cybertrain::DB::Error, "MySQL: byte 0x#{first.to_s(16)} is not the start of a length"
          end
        end

        # `text` prefixed by its byte length.
        def self.lenenc_str(text)
          s = text.to_s
          out = Wire.lenenc_int(s.bytesize)
          out << Wire.bytes(s)
          out
        end

        # The string at `pos` (binary) and the position after it. 0xFB (NULL)
        # is an error here: use {.read_lenenc_str_or_nil} where a column can
        # be NULL.
        # @return [Array] [String, next_pos]
        def self.read_lenenc_str(text, pos)
          s = text.to_s
          got = Wire.read_lenenc_int(s, pos)
          start = got[1]
          stop = start + got[0]
          raise Cybertrain::DB::Error, "MySQL: packet ends inside a string" if stop > s.bytesize

          [s.byteslice(start, got[0]), stop]
        end

        # Like {.read_lenenc_str}, with nil for the 0xFB of a NULL value.
        # @return [Array] [String or nil, next_pos]
        def self.read_lenenc_str_or_nil(text, pos)
          s = text.to_s
          raise Cybertrain::DB::Error, "MySQL: packet ends before a string" if pos >= s.bytesize
          return [nil, pos + 1] if s.getbyte(pos) == 0xFB

          Wire.read_lenenc_str(s, pos)
        end

        # The low `bytes` (1..8) bytes of `value`, least significant first.
        # A negative value gives its two's complement.
        def self.int_le(value, bytes)
          out = Wire.zeros(bytes)
          i = 0
          while i < bytes
            out.setbyte(i, (value >> (8 * i)) & 0xFF)
            i += 1
          end
          out
        end

        # `count` zero bytes, tagged binary (ASCII-8BIT). Every buffer
        # that goes on the wire is binary: a UTF-8 String holding a byte
        # of 0x80 or more and a binary one holding another cannot be
        # appended to each other (Encoding::CompatibilityError, under CRuby
        # and under Spinel since 2026.11.27.7037; NOTES rule 27).
        def self.zeros(count)
          out = "0" * count
          out.force_encoding("BINARY")
          i = 0
          while i < count
            out.setbyte(i, 0)
            i += 1
          end
          out
        end

        # A binary-tagged copy of `text`'s bytes (a String bound or sent
        # as it is, a Blob's bytes, a user name), for appending to a wire
        # buffer.
        def self.bytes(text)
          out = String.new
          out << text.to_s
          out.force_encoding("BINARY")
          out
        end

        # The unsigned little-endian integer of `bytes` (1..8) bytes at `pos`.
        # Eight bytes are read as a signed 64-bit value, as MySQL's LONGLONG.
        def self.read_int_le(text, pos, bytes)
          s = text.to_s
          raise Cybertrain::DB::Error, "MySQL: packet ends inside an integer" if pos < 0 || pos + bytes > s.bytesize

          value = 0
          i = bytes - 1
          while i >= 0
            value = (value << 8) | s.getbyte(pos + i)
            i -= 1
          end
          value
        end

        # The string up to the next NUL at `pos` and the position after the
        # NUL.
        # @return [Array] [String, next_pos]
        def self.null_str(text, pos)
          s = text.to_s
          stop = pos
          size = s.bytesize
          stop += 1 while stop < size && s.getbyte(stop) != 0
          raise Cybertrain::DB::Error, "MySQL: string has no terminating NUL" if stop >= size

          [s.byteslice(pos, stop - pos), stop + 1]
        end
      end
    end
  end
end
