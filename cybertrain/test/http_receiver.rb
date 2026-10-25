# Cybertrain::Test::HttpReceiver -- a small HTTP server on 127.0.0.1 that
# records the requests an application sent (a webhook, an API call through
# Cybertrain::HttpClient) and answers each with a canned response. See
# cybertrain/test/receiver.rb for how every wait is bounded.
require "cybertrain/test/receiver"

module Cybertrain
  module Test
    # One request as the receiver read it.
    # Method names carry an `http_` prefix: a framework class that defines
    # `body` or `headers` next to another one returning a different type
    # confuses Spinel's inference (spikes/NOTES.md rules 10, 34).
    # @api public
    class ReceivedRequest
      # @return [String] "GET", "POST", ...
      # @api public
      attr_reader :http_method

      # @return [String] the request target as sent: path and query
      # @api public
      attr_reader :http_target

      # @return [Hash{String => String}] lowercased names; repeated headers
      #   joined with ", "
      # @api public
      attr_reader :http_headers

      # @return [String] the body (a chunked body decoded), "" for none
      # @api public
      attr_reader :http_body

      def initialize(method, target, headers, body)
        @http_method = method
        @http_target = target
        @http_headers = headers
        @http_body = body
      end

      # A header's value by name (any case), "" when it was not sent.
      # @param name [String]
      # @return [String]
      # @api public
      def http_header(name)
        value = @http_headers[name.to_s.downcase]
        value.nil? ? "" : value.to_s
      end

      # The target without its query string.
      # @return [String]
      # @api public
      def http_path
        at = @http_target.byteindex("?")
        at.nil? ? @http_target : @http_target.byteslice(0, at)
      end
    end

    # A receiver for outbound HTTP calls in a test: `start` binds a port on
    # 127.0.0.1, the application calls it, {#received_request} returns what arrived.
    # It accepts `max` connections (1 by default), reads one request from
    # each (Content-Length or chunked body) and answers it with the canned
    # response and `Connection: close`.
    #
    # Cybertrain::HttpClient refuses loopback addresses unless the test sets
    # `allow_private: true` (or `Cybertrain.config.http_allow_private = true`).
    # @example
    #   require "cybertrain/test/http_receiver"
    #
    #   test "the signup posts a webhook" do
    #     hook = Cybertrain::Test::HttpReceiver.new(status: 202, body: "queued")
    #     hook.start
    #     Cybertrain.config.http_allow_private = true
    #     Notifier.deliver_signup(hook.url("/hooks/signup"), "ann@example.com")  # the code under test
    #     req = hook.received_request          # waits at most 5 s; nil if nothing came
    #     hook.stop
    #     assert_equal "POST", req.http_method
    #     assert_equal "/hooks/signup", req.http_target
    #     assert_equal "application/json", req.http_header("Content-Type")
    #   end
    # @api public
    class HttpReceiver < Receiver
      REASONS = {
        200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
        301 => "Moved Permanently", 302 => "Found", 304 => "Not Modified",
        400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
        409 => "Conflict", 422 => "Unprocessable Content", 429 => "Too Many Requests",
        500 => "Internal Server Error", 502 => "Bad Gateway", 503 => "Service Unavailable"
      }

      # The largest body the receiver reads.
      MAX_BODY_BYTES = 10_485_760

      # A typed empty Hash for the `headers:` default (spikes/NOTES.md rule 9).
      def self.no_headers
        h = { "" => "" }
        h.delete("")
        h
      end

      # @param status [Integer] the canned response's status
      # @param headers [Hash{String => String}] extra response headers
      # @param body [String] the canned response's body
      # @param chunked [Boolean] send the body with Transfer-Encoding: chunked
      # @param max [Integer] how many connections (one request each) to accept
      # @param accept_window [Numeric] seconds to wait for each connection
      #   before the receiver gives up and closes its port
      # @param read_timeout [Numeric] seconds of silence that end a connection
      # @api public
      def initialize(status: 200, headers: HttpReceiver.no_headers, body: "ok", chunked: false, max: 1,
                     accept_window: 10.0, read_timeout: 5.0)
        super(max, accept_window, read_timeout)
        @reply_status = 200
        @reply_headers = HttpReceiver.no_headers
        @reply_body = ""
        @reply_chunked = false
        @requests = Array.new(0) { ReceivedRequest.new("", "", HttpReceiver.no_headers, "") }
        @lock = Mutex.new
        @body_failed = false
        respond_with(status: status, headers: headers, body: body, chunked: chunked)
      end

      # Changes the canned response for the requests still to come.
      # @param status [Integer]
      # @param headers [Hash{String => String}]
      # @param body [String]
      # @param chunked [Boolean]
      # @return [nil]
      # @api public
      def respond_with(status: 200, headers: HttpReceiver.no_headers, body: "ok", chunked: false)
        @reply_status = status.to_i
        copy = HttpReceiver.no_headers
        headers.each_key { |k| copy[k.to_s] = headers[k].to_s }
        @reply_headers = copy
        @reply_body = body.to_s
        @reply_chunked = chunked ? true : false
        nil
      end

      # "http://127.0.0.1:<port><path>", once started.
      # @param path [String]
      # @return [String]
      # @api public
      def url(path = "/")
        "http://127.0.0.1:#{@port}#{path}"
      end

      # The first request, waiting for it at most `wait` seconds.
      # @param wait [Numeric]
      # @return [ReceivedRequest, nil] nil when none arrived in time
      # @api public
      def received_request(wait = 5.0)
        return nil unless await_count(1, wait)

        @requests[0]
      end

      # The requests that arrived, waiting at most `wait` seconds for
      # `count` of them (0: the receiver's `max`). Fewer when the time ran
      # out.
      # @param count [Integer]
      # @param wait [Numeric]
      # @return [Array<ReceivedRequest>]
      # @api public
      def received_requests(count = 0, wait = 5.0)
        await_count(count > 0 ? count : @max, wait)
        out = Array.new(0) { ReceivedRequest.new("", "", HttpReceiver.no_headers, "") }
        n = received_count
        i = 0
        while i < n
          out << @requests[i]
          i += 1
        end
        out
      end

      def received_count
        n = 0
        @lock.synchronize { n = @requests.size }
        n
      end

      # One connection: the head, the body (Content-Length or chunked),
      # then the canned response. A request that does not frame is dropped
      # without an answer (the client sees the connection close). The base
      # class's constants are spelled with its name (spikes/NOTES.md rule 74).
      def serve_connection(sock)
        return nil unless marker_ready?(sock, "\r\n\r\n", Receiver::MAX_LINE_BYTES)

        head = cut_to("\r\n\r\n")
        line_end = head.byteindex("\r\n")
        line_end = head.bytesize if line_end.nil?
        request_line = head.byteslice(0, line_end)
        parts = request_line.split(" ")
        return nil if parts.size != 3

        verb = parts[0].to_s
        headers = HttpReceiver.parse_headers(head, line_end)
        @body_failed = false
        body = rx_read_body(sock, headers)
        return nil if @body_failed

        received = ReceivedRequest.new(verb, parts[1].to_s, headers, body)
        # The reply is built before the request is published: a test thread
        # woken by the append may call respond_with for the NEXT request
        # before this one is answered.
        response = canned_response(verb == "HEAD")
        @lock.synchronize { @requests << received }
        sock.write(response)
        nil
      end

      # The header lines after the request line: names lowercased, values
      # trimmed, repeated names joined with ", ".
      def self.parse_headers(head, line_end)
        headers = HttpReceiver.no_headers
        pos = line_end + 2
        while pos < head.bytesize
          stop = head.byteindex("\r\n", pos)
          stop = head.bytesize if stop.nil?
          line = head.byteslice(pos, stop - pos)
          colon = line.byteindex(":")
          unless colon.nil?
            name = line.byteslice(0, colon).strip.downcase
            value = line.byteslice(colon + 1, line.bytesize - colon - 1).strip
            seen = headers[name]
            if seen.nil?
              headers[name] = value
            else
              joined = String.new
              joined << seen.to_s << ", " << value
              headers[name] = joined
            end
          end
          pos = stop + 2
        end
        headers
      end

      # The body; sets @body_failed when it does not frame or does not
      # arrive.
      def rx_read_body(sock, headers)
        coding = headers["transfer-encoding"]
        return rx_read_chunked(sock) if !coding.nil? && !coding.to_s.downcase.index("chunked").nil?

        length_text = headers["content-length"]
        return "" if length_text.nil?

        length = HttpReceiver.rx_number(length_text.to_s, 10)
        return frame_failed if length < 0 || length > MAX_BODY_BYTES
        return frame_failed unless bytes_ready?(sock, length)

        cut_bytes(length)
      end

      def rx_read_chunked(sock)
        body = String.new
        while true
          return frame_failed unless marker_ready?(sock, "\r\n", Receiver::MAX_LINE_BYTES)

          size_line = cut_to("\r\n")
          semi = size_line.byteindex(";")
          hex = semi.nil? ? size_line.strip : size_line.byteslice(0, semi).strip
          size = HttpReceiver.rx_number(hex, 16)
          return frame_failed if size < 0
          return rx_read_trailers(sock, body) if size == 0
          return frame_failed if body.bytesize + size > MAX_BODY_BYTES
          return frame_failed unless bytes_ready?(sock, size + 2)

          body << cut_bytes(size)
          cut_bytes(2)
        end
        body
      end

      # Trailer lines, up to the empty line that ends the message.
      def rx_read_trailers(sock, body)
        while true
          return frame_failed unless marker_ready?(sock, "\r\n", Receiver::MAX_LINE_BYTES)
          return body if cut_to("\r\n").empty?
        end
        body
      end

      def frame_failed
        @body_failed = true
        ""
      end

      # A decimal (`base` 10) or hex (16) number of at most 8 places; -1 for
      # anything else. A byte scan rather than a Regexp or to_i(16), the
      # String read through a local (spikes/NOTES.md rule 62).
      def self.rx_number(text, base)
        s = text.to_s
        return -1 if s.empty? || s.bytesize > 8

        value = 0
        i = 0
        while i < s.bytesize
          b = s.getbyte(i)
          d = -1
          if b >= 48 && b <= 57
            d = b - 48
          elsif base == 16 && b >= 97 && b <= 102
            d = b - 87
          elsif base == 16 && b >= 65 && b <= 70
            d = b - 55
          end
          return -1 if d < 0

          value = value * base + d
          i += 1
        end
        value
      end

      # `n` in lowercase hex, without a prefix ("1f"), a new String.
      def self.rx_hex(n)
        digits = "0123456789abcdef"
        return "0" if n <= 0

        places = Array.new(0) { 0 }
        rest = n
        while rest > 0
          places << rest % 16
          rest /= 16
        end
        out = String.new
        i = places.size - 1
        while i >= 0
          out << digits.byteslice(places[i], 1)
          i -= 1
        end
        out
      end

      # The canned response, Connection: close. A chunked body goes in two
      # chunks when it has more than one byte, so a client's chunk loop is
      # exercised. Every piece is appended here, directly (a buffer filled
      # partly through helpers loses their bytes: spikes/NOTES.md rule 66).
      def canned_response(head_only)
        out = String.new
        status = @reply_status
        reason = REASONS[status]
        out << "HTTP/1.1 " << status.to_s << " " << (reason.nil? ? "Status" : reason.to_s) << "\r\n"
        @reply_headers.each_key { |k| out << k << ": " << @reply_headers[k].to_s << "\r\n" }
        out << "Connection: close\r\n"
        if status == 204 || status == 304 || (status >= 100 && status < 200)
          out << "\r\n"
          return out
        end

        body = @reply_body
        total = body.bytesize
        if @reply_chunked
          out << "Transfer-Encoding: chunked\r\n\r\n"
          return out if head_only

          half = total / 2
          out << HttpReceiver.rx_hex(half) << "\r\n" << body.byteslice(0, half) << "\r\n" if half > 0
          out << HttpReceiver.rx_hex(total - half) << "\r\n" << body.byteslice(half, total - half) << "\r\n" if total - half > 0
          out << "0\r\n\r\n"
          return out
        end

        out << "Content-Length: " << total.to_s << "\r\n\r\n"
        out << body unless head_only
        out
      end
    end
  end
end
