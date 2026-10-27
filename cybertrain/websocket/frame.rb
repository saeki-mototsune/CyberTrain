# Cybertrain::WebSocket::Frame -- the socket-free half of an RFC 6455
# client: frame encoding and decoding, the Sec-WebSocket-Accept key,
# fragment assembly, close payloads and the error classes.
#
# Nothing here reads or writes a socket. The client feeds it bytes and gets
# headers, payloads and messages back. Everything works on bytes (getbyte /
# setbyte), never on characters, so a binary payload and a multi-byte UTF-8
# one are treated alike.
require "digest"
require "base64"

module Cybertrain
  module WebSocket
    # The base of every error a WebSocket client raises. The message names
    # the host and port, never the path or the query.
    # @api public
    class Error < StandardError
    end

    # Connecting, a TLS step, the handshake or a write took too long.
    # @api public
    class TimeoutError < Error
    end

    # The connection could not be made: refused, unreachable, unresolvable.
    # @api public
    class RefusedError < Error
    end

    # The TLS handshake or certificate check failed.
    # @api public
    class TLSError < Error
    end

    # The destination is not a public address and private ones are not allowed.
    # @api public
    class BlockedAddressError < Error
    end

    # The server did not answer the upgrade request with a valid 101.
    # @api public
    class HandshakeError < Error
    end

    # The peer broke the framing rules of RFC 6455.
    # @api public
    class ProtocolError < Error
    end

    # A message grew past `max_message` bytes.
    # @api public
    class TooLargeError < Error
    end

    # The connection is closed: by a close frame (with its code and reason)
    # or by the stream ending (code 1006).
    # @api public
    class ClosedError < Error
      # @return [Integer] the close code (1006 when no close frame arrived)
      # @api public
      attr_reader :close_code
      # @return [String] the close reason, possibly empty
      # @api public
      attr_reader :close_reason

      # @param message [String]
      # @param code [Integer]
      # @param reason [String]
      def initialize(message = "closed", code = 1006, reason = "")
        super(message)
        @close_code = code
        @close_reason = reason
      end
    end

    # A complete data message.
    # @api public
    class Message
      # @return [Symbol] :text or :binary
      # @api public
      attr_reader :ws_opcode
      # @return [String] the payload bytes
      # @api public
      attr_reader :ws_data

      # @param opcode [Symbol] :text or :binary
      # @param data [String]
      def initialize(opcode, data)
        @ws_opcode = opcode
        @ws_data = data
      end
    end

    # Frame encoding and decoding (RFC 6455 section 5).
    # @api public
    module Frame
      OP_CONTINUATION = 0
      OP_TEXT = 1
      OP_BINARY = 2
      OP_CLOSE = 8
      OP_PING = 9
      OP_PONG = 10
      GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

      # The fixed fields of a frame header, as read by Frame.parse_header.
      # `frame_header_size` is 0 when the bytes given were too few.
      # @api public
      class Header
        attr_reader :frame_fin, :frame_rsv, :frame_opcode, :frame_masked,
                    :frame_length, :frame_header_size, :frame_mask_key

        def initialize(fin, rsv, opcode, masked, length, header_size, mask_key)
          @frame_fin = fin
          @frame_rsv = rsv
          @frame_opcode = opcode
          @frame_masked = masked
          @frame_length = length
          @frame_header_size = header_size
          @frame_mask_key = mask_key
        end
      end

      # Collects the fragments of one data message.
      # @api public
      class Assembler
        def initialize(max_message)
          @max_message = max_message
          @opcode = 0
          @buffer = String.new
          @active = false
        end

        # Adds one data frame's payload (already unmasked).
        # @param opcode [Integer] OP_TEXT, OP_BINARY or OP_CONTINUATION
        # @param fin [Boolean]
        # @param payload [String]
        # @return [Boolean] true when the message is complete
        # @raise [TooLargeError] when the total passes max_message
        def add(opcode, fin, payload)
          if opcode != OP_CONTINUATION
            @opcode = opcode
            @buffer = String.new
          end
          if @buffer.bytesize + payload.bytesize > @max_message
            reset
            raise TooLargeError, "message larger than #{@max_message} bytes"
          end
          @buffer << payload.b
          if fin
            @active = false
          else
            @active = true
          end
          fin
        end

        # @return [Boolean] whether a fragmented message is in progress
        def assembling?
          @active
        end

        # Takes the completed message and resets.
        # @return [Message]
        def take_message
          sym = @opcode == OP_TEXT ? :text : :binary
          # .b: under Spinel a String.new buffer is not tagged binary, and a
          # payload with a byte >= 0x80 then compares unequal to the same
          # bytes tagged binary. A local first (NOTES rule 58).
          data = @buffer.b
          msg = Message.new(sym, data)
          reset
          msg
        end

        private

        def reset
          @opcode = 0
          @buffer = String.new
          @active = false
        end
      end

      # The Sec-WebSocket-Accept value for a Sec-WebSocket-Key.
      # @param key [String]
      # @return [String]
      # @api public
      def self.accept_key(key)
        Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
      end

      # One FIN frame. A 4-byte `mask_key` masks the payload; "" does not.
      # @param opcode [Integer]
      # @param payload [String]
      # @param mask_key [String] 4 bytes, or ""
      # @return [String] binary
      # @api public
      def self.encode(opcode, payload, mask_key)
        data = payload.b
        n = data.bytesize
        masked = mask_key.bytesize == 4
        ext = n <= 125 ? 0 : (n <= 65535 ? 2 : 8)
        head = 2 + ext + (masked ? 4 : 0)
        out = ("\0" * (head + n)).b
        out.setbyte(0, 0x80 | opcode)
        mask_bit = masked ? 0x80 : 0
        if ext == 0
          out.setbyte(1, mask_bit | n)
        elsif ext == 2
          out.setbyte(1, mask_bit | 126)
          out.setbyte(2, (n >> 8) & 0xff)
          out.setbyte(3, n & 0xff)
        else
          out.setbyte(1, mask_bit | 127)
          i = 0
          while i < 8
            out.setbyte(2 + i, (n >> (8 * (7 - i))) & 0xff)
            i += 1
          end
        end
        pos = 2 + ext
        if masked
          i = 0
          while i < 4
            out.setbyte(pos + i, mask_key.getbyte(i))
            i += 1
          end
          pos += 4
          i = 0
          while i < n
            out.setbyte(pos + i, data.getbyte(i) ^ mask_key.getbyte(i % 4))
            i += 1
          end
        else
          i = 0
          while i < n
            out.setbyte(pos + i, data.getbyte(i))
            i += 1
          end
        end
        out
      end

      # Reads a header from the start of `bytes`. When there are too few
      # bytes the Header has frame_header_size 0 (never nil).
      # @param bytes [String]
      # @return [Header]
      # @raise [ProtocolError] on a 64-bit length with the top bit set
      # @api public
      def self.parse_header(bytes)
        have = bytes.bytesize
        return Header.new(false, 0, 0, false, 0, 0, "") if have < 2
        b0 = bytes.getbyte(0)
        b1 = bytes.getbyte(1)
        masked = (b1 & 0x80) != 0
        len7 = b1 & 0x7f
        ext = len7 == 126 ? 2 : (len7 == 127 ? 8 : 0)
        if ext == 8 && have > 2 && (bytes.getbyte(2) & 0x80) != 0
          raise ProtocolError, "64-bit frame length with the top bit set"
        end
        size = 2 + ext + (masked ? 4 : 0)
        return Header.new(false, 0, 0, false, 0, 0, "") if have < size
        length = len7
        if ext > 0
          length = 0
          i = 0
          while i < ext
            length = (length << 8) | bytes.getbyte(2 + i)
            i += 1
          end
        end
        key = masked ? bytes.byteslice(2 + ext, 4) : ""
        Header.new((b0 & 0x80) != 0, (b0 >> 4) & 0x7, b0 & 0x0f, masked, length, size, key)
      end

      # XOR with the 4-byte key; "" returns the payload unchanged.
      # @param payload [String]
      # @param mask_key [String]
      # @return [String] binary
      # @api public
      def self.unmask(payload, mask_key)
        n = payload.bytesize
        out = ("\0" * n).b
        klen = mask_key.bytesize
        i = 0
        while i < n
          b = payload.getbyte(i)
          b ^= mask_key.getbyte(i % klen) if klen == 4
          out.setbyte(i, b)
          i += 1
        end
        out
      end

      # Raises ProtocolError for a header a conforming peer would not send.
      # @param header [Header]
      # @param assembling [Boolean] a fragmented message is in progress
      # @param from_server [Boolean] the frame arrived at a client
      # @return [nil]
      # @raise [ProtocolError]
      # @api public
      def self.check_header(header, assembling, from_server)
        op = header.frame_opcode
        if from_server && header.frame_masked
          raise ProtocolError, "masked frame from the server"
        end
        if !from_server && !header.frame_masked
          raise ProtocolError, "unmasked frame from the client"
        end
        raise ProtocolError, "reserved bits set" if header.frame_rsv != 0
        known = op == OP_CONTINUATION || op == OP_TEXT || op == OP_BINARY ||
                op == OP_CLOSE || op == OP_PING || op == OP_PONG
        raise ProtocolError, "unknown opcode #{op}" unless known
        if op >= 8
          raise ProtocolError, "control frame too long" if header.frame_length > 125
          raise ProtocolError, "fragmented control frame" unless header.frame_fin
        elsif op == OP_CONTINUATION
          raise ProtocolError, "continuation without a message" unless assembling
        elsif assembling
          raise ProtocolError, "new data frame inside a fragmented message"
        end
        nil
      end

      # @param code [Integer]
      # @param reason [String]
      # @return [String] 2-byte big-endian code followed by the reason
      # @api public
      def self.close_payload(code, reason)
        r = reason.b
        out = ("\0" * (2 + r.bytesize)).b
        out.setbyte(0, (code >> 8) & 0xff)
        out.setbyte(1, code & 0xff)
        i = 0
        while i < r.bytesize
          out.setbyte(2 + i, r.getbyte(i))
          i += 1
        end
        out
      end

      # @param payload [String]
      # @return [Integer] the code; 1005 when the payload is empty
      # @raise [ProtocolError] for a 1-byte payload, or a code a peer may
      #   not send (RFC 6455 7.4: below 1000, the reserved 1004, 1005, 1006
      #   and 1015, the unassigned 1015..2999, or above 4999)
      # @api public
      def self.close_code(payload)
        n = payload.bytesize
        return 1005 if n == 0
        raise ProtocolError, "close payload of 1 byte" if n == 1

        code = (payload.getbyte(0) << 8) | payload.getbyte(1)
        valid = (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) ||
                (code >= 3000 && code <= 4999)
        raise ProtocolError, "invalid close code #{code}" unless valid

        code
      end

      # The reason: bytes after the code, at most 123, without control
      # characters (bytes 0..31 and 127), since it comes from the peer.
      # @param payload [String]
      # @return [String]
      # @api public
      def self.close_reason(payload)
        n = payload.bytesize
        return "" if n <= 2
        n = 125 if n > 125
        out = ("\0" * (n - 2)).b
        used = 0
        i = 2
        while i < n
          b = payload.getbyte(i)
          if b > 31 && b != 127
            out.setbyte(used, b)
            used += 1
          end
          i += 1
        end
        out.byteslice(0, used)
      end
    end
  end
end
