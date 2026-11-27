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
require "cybertrain/db/mysql/result"

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
        # @param deadline [Numeric] longest one frame's read or write may take
        def initialize(stream, per_wait = 30, deadline = 120)
          @stream = stream
          @read_wait = per_wait
          @write_wait = per_wait
          @deadline = deadline
          @seq = 0
          @reader = Cybertrain::Net::Reader.new(stream, frame_timer(per_wait))
          # Frames read since #mark_idle, and whether the last loss came
          # before any of them (#lost_unanswered?).
          @frames_read = 0
          @lost_unanswered = false
        end

        # Starts counting the frames read from here on: the connection
        # was idle (in the pool) until now. See #lost_unanswered?.
        def mark_idle
          @frames_read = 0
          @lost_unanswered = false
          nil
        end

        # Whether the last DB::ConnectionLost raised here came before the
        # server answered anything since #mark_idle: the write of the
        # command failed, or the stream ended (or reset) before one byte of
        # an answer arrived, or the first thing read was the server's
        # unprompted ERR (sequence 0: 4031 on wait_timeout), which it sends
        # before it closes an idle session. Never for a timeout (the
        # server may be running the command; Net::TimeoutError is not
        # caught here), a frame out of sequence, or anything after the
        # first answer byte.
        #
        # What it cannot tell apart: a server that read the command, ran
        # it to the end and lost the session (crashed, or a KILL that
        # landed after a commit) before its first answer byte. That
        # command has run, and a retry runs it again; see Connection's
        # #run_command for where that risk is taken.
        # @return [Boolean]
        def lost_unanswered?
          @lost_unanswered
        end

        # The waits from here on: `read_wait` for each wait of a read,
        # `write_wait` for each wait of a write, `deadline` for one frame
        # (at most 16 MB). Each frame starts a fresh Timer, so a long
        # result whose bytes keep coming is never cut off by one deadline
        # over the whole exchange: what bounds a stalled server is the
        # per-wait timeout. The connection sets them from the URL once
        # authenticated (connect_timeout bounds the handshake).
        def use_timeouts(read_wait, write_wait, deadline)
          @read_wait = read_wait
          @write_wait = write_wait
          @deadline = deadline
          nil
        end

        # The stream the packets go over (TCP, or TLS after the switch).
        def packet_stream
          @stream
        end

        # Starts the next command at sequence 0.
        def reset_sequence
          @seq = 0
          nil
        end

        # The sequence number the next packet carries.
        def packet_sequence
          @seq
        end

        # Continues another PacketIO's exchange: the switch to TLS
        # (auth.rb) carries the sequence over to the PacketIO on the TLS
        # stream.
        def resume_sequence(seq)
          @seq = seq & 0xFF
          nil
        end

        # The next payload, split packets joined.
        # @return [String] binary
        def read_packet
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
          data = Wire.bytes(payload)
          total = data.bytesize
          pos = 0
          while true
            size = total - pos
            size = MAX_PAYLOAD if size > MAX_PAYLOAD
            write_frame(data, pos, size, frame_timer(@write_wait))
            pos += size
            break if size < MAX_PAYLOAD
          end
          nil
        end

        def frame_timer(per_wait)
          Cybertrain::Net::Timer.new(@stream.stream_label, per_wait, @deadline)
        end

        # One packet's payload, its sequence number checked.
        def read_frame
          @reader.reader_timer = frame_timer(@read_wait)
          head = read_bytes(4)
          size = Wire.read_int_le(head, 0, 3)
          got = head.getbyte(3)
          out_of_sequence(size, got) if got != @seq

          @seq = (@seq + 1) & 0xFF
          @frames_read += 1
          read_bytes(size)
        end

        # A frame whose sequence number is not the one expected. The server
        # sends an ERR unprompted, with sequence 0, before it closes a
        # session (4031, disconnected for inactivity); the next command
        # reads it where its answer (sequence 1) should be. Its message is
        # the one raised, so the cause is not lost. Anything else is the
        # stream out of step.
        def out_of_sequence(size, got)
          if got == 0 && size >= 3 && size < 0x10000
            payload = read_bytes(size)
            if payload.getbyte(0) == 0xFF
              @lost_unanswered = @frames_read == 0
              raise Cybertrain::DB::ConnectionLost, Decode.server_error_text(payload)
            end
          end
          raise Cybertrain::DB::ConnectionLost, "#{@stream.stream_label}: MySQL packet out of sequence (expected #{@seq}, got #{got})"
        end

        # `count` bytes of the stream. The begin/rescue is here, away from a
        # yielding caller (NOTES rules 32, 45); the Net classes are named in
        # full (rule 70).
        # A loss before any frame since #mark_idle with nothing buffered
        # (not part of a frame header) is one #lost_unanswered? reports.
        def read_bytes(count)
          @reader.read_exact(count)
        rescue Cybertrain::Net::ProtocolError, Cybertrain::Net::ConnectError
          @lost_unanswered = @frames_read == 0 && @reader.buffered == 0
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
          # A command not written whole is never run by the server.
          @lost_unanswered = @frames_read == 0
          raise Cybertrain::DB::ConnectionLost, "#{@stream.stream_label}: the connection to MySQL was lost while writing"
        end
      end
    end
  end
end
