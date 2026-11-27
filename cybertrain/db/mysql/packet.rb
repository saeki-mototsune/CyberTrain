# MySQL packet framing over a Cybertrain::Net stream (TCP or TLS): a 3-byte
# little-endian payload length, a 1-byte sequence number, the payload. A
# payload of 0xFFFFFF bytes or more is split, and one that is an exact
# multiple of 0xFFFFFF ends with an empty packet.
#
# Every wait is Net's: reads go through Net::Reader and writes through
# stream_write, each bounded by a Net::Timer, so a stalled server is a
# timeout (Net::TimeoutError, which leaves the stream unusable for the next
# packet) and not a parked worker. A stream that ends mid-packet, resets, or
# frames out of sequence is DB::ConnectionLost.
require "cybertrain/net/socket"
require "cybertrain/db/error"
require "cybertrain/db/mysql/wire"

module Cybertrain
  module DB
    module MySQL
      # @api private
      class PacketIO
        MAX_PAYLOAD = 0xFFFFFF
        # Up to this size header and payload go out in one write, so a small
        # packet is one TCP segment (a 4-byte write then a second one waits
        # for Nagle's timer).
        JOIN_LIMIT = 16_384

        # @param stream [Cybertrain::Net::Stream]
        # @param per_wait [Numeric] longest one wait may take, seconds
        # @param deadline [Numeric] longest one packet's read or write may take
        def initialize(stream, per_wait = 30, deadline = 120)
          @stream = stream
          @per_wait = per_wait
          @deadline = deadline
          @seq = 0
          @reader = Cybertrain::Net::Reader.new(stream, packet_timer)
        end

        # Starts the next command at sequence 0.
        def reset_sequence
          @seq = 0
          nil
        end

        # The next payload, split packets joined.
        # @return [String] binary
        def read_packet
          @reader.reader_timer = packet_timer
          first = read_frame
          return first if first.bytesize < MAX_PAYLOAD

          out = String.new
          out << first
          last_size = first.bytesize
          while last_size == MAX_PAYLOAD
            more = read_frame
            out << more
            last_size = more.bytesize
          end
          out
        end

        # Sends `payload` as one or more packets.
        def write_packet(payload)
          data = payload.to_s
          total = data.bytesize
          timer = packet_timer
          pos = 0
          while true
            size = total - pos
            size = MAX_PAYLOAD if size > MAX_PAYLOAD
            write_frame(data, pos, size, timer)
            pos += size
            break if size < MAX_PAYLOAD
          end
          nil
        end

        def packet_timer
          Cybertrain::Net::Timer.new(@stream.stream_label, @per_wait, @deadline)
        end

        # One packet's payload, its sequence number checked.
        def read_frame
          head = read_bytes(4)
          size = Wire.read_int_le(head, 0, 3)
          got = head.getbyte(3)
          if got != @seq
            raise Cybertrain::DB::ConnectionLost, "#{@stream.stream_label}: MySQL packet out of sequence (expected #{@seq}, got #{got})"
          end

          @seq = (@seq + 1) & 0xFF
          read_bytes(size)
        end

        # `count` bytes of the stream. The begin/rescue is here, away from a
        # yielding caller (NOTES rules 32, 45); the Net classes are named in
        # full (rule 70).
        def read_bytes(count)
          @reader.read_exact(count)
        rescue Cybertrain::Net::ProtocolError, Cybertrain::Net::ConnectError
          raise Cybertrain::DB::ConnectionLost, "#{@stream.stream_label}: the connection to MySQL was lost while reading"
        end

        def write_frame(data, pos, size, timer)
          head = Wire.int_le(size, 3)
          head << Wire.int_le(@seq, 1)
          @seq = (@seq + 1) & 0xFF
          if size <= JOIN_LIMIT
            head << data.byteslice(pos, size)
            send_bytes(head, timer)
          else
            send_bytes(head, timer)
            send_bytes(data.byteslice(pos, size), timer)
          end
          nil
        end

        def send_bytes(bytes, timer)
          @stream.stream_write(bytes, timer)
        rescue Cybertrain::Net::ConnectError
          raise Cybertrain::DB::ConnectionLost, "#{@stream.stream_label}: the connection to MySQL was lost while writing"
        end
      end
    end
  end
end
