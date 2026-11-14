# Cybertrain::Test::SentryReceiver -- a Sentry stand-in for tests: an
# HttpReceiver on 127.0.0.1 that takes the envelopes the Sentry sender
# (cybertrain/error_reporter/sentry.rb) POSTs and answers each as Sentry
# does, `200 {"id":"..."}`. Point `Cybertrain.config.sentry_dsn` at
# {SentryReceiver#dsn} (with `http_allow_private`) and read what arrived
# with {SentryReceiver#received_events}. It needs nothing beyond the
# receivers' base and the core's JSON reading, so it works in an
# application on `cybertrain/core` too.
require "json"
require "cybertrain/cast"
require "cybertrain/test/http_receiver"

module Cybertrain
  module Test
    # One envelope as the receiver read it: the request's path, its
    # `X-Sentry-Auth` and `Content-Type`, and the envelope's text.
    # @api public
    class SentryEnvelope
      # The request's path: `/api/<project id>/envelope/`, after the DSN's
      # path when it has one.
      # @return [String]
      # @api public
      attr_reader :sentry_path

      # The `X-Sentry-Auth` header.
      # @return [String]
      # @api public
      attr_reader :sentry_auth

      # The `Content-Type` header (`application/x-sentry-envelope`).
      # @return [String]
      # @api public
      attr_reader :sentry_content_type

      # The envelope as sent: the envelope header, the item header and the
      # event, one JSON object per line.
      # @return [String]
      # @api public
      attr_reader :sentry_body

      # @param path [String]
      # @param auth [String]
      # @param content_type [String]
      # @param body [String]
      # @api private
      def initialize(path, auth, content_type, body)
        @sentry_path = path
        @sentry_auth = auth
        @sentry_content_type = content_type
        @sentry_body = body
      end

      # A field of the event (the envelope's third line) by its dotted
      # path: `"exception.values.0.type"`, an Array's elements by their
      # index. In an object, the longest run of the path's remaining parts
      # that is a key is taken first, so a key with dots in it (a job
      # report's `extra`, `"job.attempt"`) is read whole:
      # `"extra.job.attempt"`. A String is itself, a number or a boolean
      # its JSON text; `""` when the field is absent, null, an object or an
      # array.
      # @example
      #   env.sentry_field("tags.request_id")   # => "4f1c..."
      #   env.sentry_field("extra.job.attempt") # => "2"
      # @param path [String]
      # @return [String]
      # @api public
      def sentry_field(path)
        SentryEnvelope.json_field(SentryEnvelope.envelope_line(@sentry_body, 2), path)
      end

      # A field of the envelope header (its first line): `"event_id"`,
      # `"sent_at"`, `"dsn"`; read as {#sentry_field} reads the event.
      # @param name [String]
      # @return [String]
      # @api public
      def sentry_header_field(name)
        SentryEnvelope.json_field(SentryEnvelope.envelope_line(@sentry_body, 0), name)
      end

      # The `index`th line of `text` (0 for the first), "" past the end.
      # @api private
      def self.envelope_line(text, index)
        s = text.to_s # NOTES rule 62
        start = 0
        line = 0
        while line < index
          stop = s.byteindex("\n", start)
          return "" if stop.nil?

          start = stop + 1
          line += 1
        end
        stop = s.byteindex("\n", start)
        stop = s.bytesize if stop.nil?
        s.byteslice(start, stop - start).to_s
      end

      # The value at the dotted `path` in the JSON object `text`, as
      # {#sentry_field} answers it.
      # @api private
      def self.json_field(text, path)
        value = Cast.parse_json(text.to_s)
        parts = path.to_s.split(".")
        i = 0
        while i < parts.size
          part = parts[i].to_s
          step = 1
          case value
          when Time then return ""
          when Hash
            # The longest dotted key that is there, down to one part.
            step = parts.size - i
            key = parts[i, step].join(".")
            while step > 1 && value[key].nil?
              step -= 1
              key = parts[i, step].join(".")
            end
            value = value[key]
          when Array
            return "" unless SentryEnvelope.index?(part)

            value = value[part.to_i]
          else return ""
          end
          i += step
        end
        case value
        when nil then ""
        when Time then ""
        when Hash then ""
        when Array then ""
        else Cast.str(value)
        end
      end

      # Whether `text` is an Array index: 1 to 6 decimal digits.
      # @api private
      def self.index?(text)
        s = text.to_s
        n = s.bytesize
        return false if n == 0 || n > 6

        i = 0
        while i < n
          b = s.getbyte(i)
          return false if b < 48 || b > 57

          i += 1
        end
        true
      end
    end

    # A receiver for the Sentry sender: accepts up to `max` envelopes (50
    # by default), one connection each, and answers each with `status`
    # (200: `{"id":"..."}`, as Sentry does; another status, such as 429,
    # tests a Sentry that refuses).
    # @example
    #   require "cybertrain/test/sentry_receiver"
    #
    #   test "a failed charge is reported" do
    #     sentry = Cybertrain::Test::SentryReceiver.new
    #     sentry.start
    #     Cybertrain.config.sentry_dsn = sentry.dsn
    #     Cybertrain.config.http_allow_private = true
    #     post "/orders", params: { "card" => "declined" }
    #     env = sentry.received_events(1)[0]
    #     assert_equal "PaymentError", env.sentry_field("exception.values.0.type")
    #   end
    # @api public
    class SentryReceiver < HttpReceiver
      # The body of every 200 answer.
      REPLY = "{\"id\":\"00000000000000000000000000000000\"}"

      # @param status [Integer] the answer to every envelope
      # @param max [Integer] how many envelopes (connections) to accept
      # @param accept_window [Numeric] seconds to wait for each connection
      # @api public
      def initialize(status: 200, max: 50, accept_window: 10.0)
        super(status: status, headers: SentryReceiver.reply_headers, body: REPLY, max: max,
              accept_window: accept_window)
      end

      # The answer's headers: the body is JSON.
      # @api private
      def self.reply_headers
        h = HttpReceiver.no_headers
        h["Content-Type"] = "application/json"
        h
      end

      # A DSN that sends to this receiver, once started:
      # `"http://public@127.0.0.1:<port><prefix>/<project>"`.
      # @param project [String] the project id (digits)
      # @param prefix [String] a path before it (`"/sentry"`), or ""
      # @return [String]
      # @api public
      def dsn(project = "1", prefix = "")
        "http://public@127.0.0.1:#{@port}#{prefix}/#{project}"
      end

      # The envelopes that arrived, waiting at most `wait` seconds for
      # `count` of them; fewer when the time ran out.
      # @param count [Integer]
      # @param wait [Numeric]
      # @return [Array<SentryEnvelope>]
      # @api public
      def received_events(count, wait = 5.0)
        out = Array.new(0) { SentryEnvelope.new("", "", "", "") }
        received_requests(count, wait).each do |req|
          path = req.http_path
          auth = req.http_header("X-Sentry-Auth")
          type = req.http_header("Content-Type")
          body = req.http_body
          # The bytes as read are binary under CRuby (the preview); the
          # envelope is UTF-8 JSON text, so compare it as such (the
          # compiled String is the same bytes either way).
          unless body.encoding.to_s == "UTF-8"
            body = body.dup
            body.force_encoding("UTF-8")
          end
          out << SentryEnvelope.new(path, auth, type, body)
        end
        out
      end
    end
  end
end
