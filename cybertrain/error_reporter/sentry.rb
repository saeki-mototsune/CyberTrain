# cybertrain/error_reporter/sentry -- the Sentry sender (spec section
# 13.4): `require "cybertrain/error_reporter/sentry"` in bin/NAME.rb (or
# `require "cybertrain"`, which loads it) installs
# Cybertrain::ErrorReporter::SentrySender as the reporter's sender, and
# CYBERTRAIN_SENTRY_DSN ({Config#sentry_dsn}) turns it on. Unset, it sends
# nothing, and the reporter queues nothing for it.
#
# Its own line, not the core's: it needs Cybertrain::HttpClient and the TLS
# layer, which an application that sends no report need not compile. An
# Application whose DSN is set while this file is not linked refuses to
# boot (Application#validate_boot, through Sender#sender_name).
#
# One Sentry envelope per event, POSTed on the reporter's delivery thread
# to the DSN's `<scheme>://<host>[/<path>]/api/<project id>/envelope/` with
# `X-Sentry-Auth`, through HttpClient (`timeout: 3, deadline: 5`); a DSN on
# a private address needs Config#http_allow_private, as any HttpClient call
# does. `error_sample_rate` is the share sent (subscribers see every
# event). A send that fails (an exception, a non-2xx answer) is logged at
# warn, `error report not sent: ...`, and not retried. Sentry and GlitchTip
# both accept the envelope.
require "json"
require "securerandom"
require "cybertrain/version"
require "cybertrain/config"
require "cybertrain/cast"
require "cybertrain/clock"
require "cybertrain/crypto"
require "cybertrain/logger"
require "cybertrain/error_reporter"
require "cybertrain/sentry_dsn"
require "cybertrain/http_client"
require "cybertrain/net/tls"

module Cybertrain
  class ErrorReporter
    # Sends each event to the Sentry (or GlitchTip) project of
    # {Config#sentry_dsn}. Installed by requiring this file.
    # @api public
    class SentrySender < Sender
      # The envelope's content type.
      CONTENT_TYPE = "application/x-sentry-envelope"

      # @api public
      def initialize
        # The DSN last parsed, by its text: parsed again only when the
        # setting changes (a test points it at a receiver). Read and written
        # on the delivery thread only.
        @dsn_text = ""
        @dsn = SentryDsn.new("", "", "")
      end

      # Whether a DSN is set.
      # @return [Boolean]
      # @api public
      def sends?
        !Cybertrain.config.sentry_dsn.to_s.empty?
      end

      # The line this sender comes from (Application#validate_boot asks).
      # @return [String] `"sentry"`
      # @api public
      def sender_name
        "sentry"
      end

      # Sends one event, unless the sample rate leaves it out; true when
      # Sentry accepted it (a 2xx answer). Never raises: a failure is logged
      # at warn and answers false.
      # @param event [ErrorEvent]
      # @return [Boolean]
      # @api public
      def deliver_event(event)
        text = Cybertrain.config.sentry_dsn.to_s
        return false if text.empty?

        rate = Cybertrain.config.error_sample_rate.to_f
        return false if rate < 1.0 && !SentrySender.sampled?(rate, SentrySender.sample_draw)

        post_event(text, event)
      end

      # Whether an event with this draw is sent at this rate: `draw <
      # rate`, the draw in 0.0...1.0 (so 0.0 sends nothing and 1.0
      # everything).
      # @param rate [Float] {Config#error_sample_rate}
      # @param draw [Float]
      # @return [Boolean]
      # @api public
      def self.sampled?(rate, draw)
        draw < rate
      end

      # A draw in 0.0...1.0 from 4 random bytes.
      # @return [Float]
      # @api private
      def self.sample_draw
        raw = SecureRandom.random_bytes(4)
        n = (raw.getbyte(0).to_i << 24) | (raw.getbyte(1).to_i << 16) | (raw.getbyte(2).to_i << 8) | raw.getbyte(3).to_i
        n / 4_294_967_296.0
      end

      # The `X-Sentry-Auth` header's value for this public key.
      # @param key [String]
      # @return [String]
      # @api public
      def self.auth_header(key)
        "Sentry sentry_version=7, sentry_key=#{key}, sentry_client=cybertrain/#{Cybertrain::VERSION}"
      end

      # The envelope of one event: three lines, the envelope header
      # (`event_id`, `sent_at`, `dsn`), the item header (`type` event, its
      # `length` in bytes) and the event, each a JSON object.
      # @param event [ErrorEvent]
      # @param dsn_text [String]
      # @param event_id [String] 32 hex digits
      # @return [String]
      # @api public
      def self.envelope(event, dsn_text, event_id)
        body = SentrySender.event_json(event, event_id)
        sent_at = Cast.iso8601(Clock.now)
        out = +"{\"event_id\":"
        out << Logger.json_quote(event_id)
        out << ",\"sent_at\":"
        out << Logger.json_quote(sent_at)
        out << ",\"dsn\":"
        out << Logger.json_quote(dsn_text)
        out << "}\n{\"type\":\"event\",\"content_type\":\"application/json\",\"length\":"
        out << body.bytesize.to_s
        out << "}\n"
        out << body
        out << "\n"
        out
      end

      # The event as Sentry's JSON: `event_id`, `timestamp`, `platform`,
      # `level`, `environment`, then `release`, `transaction` (the
      # `where`), `tags.request_id` and `request` (`method`, `url`: the
      # path) when not empty, `exception.values[0]` (`type`, `value`,
      # `mechanism`, `stacktrace` when there is a backtrace) and `extra`
      # (the context).
      # @param event [ErrorEvent]
      # @param event_id [String]
      # @return [String]
      # @api private
      def self.event_json(event, event_id)
        out = +"{\"event_id\":"
        out << Logger.json_quote(event_id)
        out << ",\"timestamp\":"
        out << Logger.json_quote(Cast.iso8601(event.error_occurred_at))
        out << ",\"platform\":\"ruby\",\"level\":\"error\",\"environment\":"
        out << Logger.json_quote(event.error_environment)
        release = event.error_release
        unless release.empty?
          out << ",\"release\":"
          out << Logger.json_quote(release)
        end
        where = event.error_where
        unless where.empty?
          out << ",\"transaction\":"
          out << Logger.json_quote(where)
        end
        out << ",\"exception\":{\"values\":[{\"type\":"
        out << Logger.json_quote(event.error_class)
        out << ",\"value\":"
        out << Logger.json_quote(event.error_message)
        out << ",\"mechanism\":{\"type\":\"generic\",\"handled\":"
        out << (event.error_handled ? "true" : "false")
        out << "}"
        trace = event.error_backtrace
        unless trace.empty?
          out << ",\"stacktrace\":{\"frames\":"
          out << SentrySender.frames_json(trace)
          out << "}"
        end
        out << "}]}"
        request_id = event.error_request_id
        unless request_id.empty?
          out << ",\"tags\":{\"request_id\":"
          out << Logger.json_quote(request_id)
          out << "}"
        end
        verb = event.error_request_method
        unless verb.empty?
          out << ",\"request\":{\"method\":"
          out << Logger.json_quote(verb)
          out << ",\"url\":"
          out << Logger.json_quote(event.error_request_path)
          out << "}"
        end
        out << ",\"extra\":{"
        first = true
        event.error_context.each do |k, v|
          out << "," unless first
          out << Logger.json_quote(k)
          out << ":"
          out << Logger.json_quote(v)
          first = false
        end
        out << "}}"
        out
      end

      # A backtrace as Sentry's `stacktrace.frames`, oldest first: each
      # `file:line:in 'method'` (or `` file:line:in `method' ``) as
      # `{"filename":...,"lineno":...,"function":...}`, a line that does
      # not read so as `{"filename":"<the line>"}`.
      # @param backtrace [Array<String>] newest first, as Exception#backtrace
      # @return [String]
      # @api public
      def self.frames_json(backtrace)
        out = +"["
        i = backtrace.size - 1
        while i >= 0
          out << "," if i < backtrace.size - 1
          out << SentrySender.frame_json(backtrace[i].to_s)
          i -= 1
        end
        out << "]"
        out
      end

      # One frame (see {frames_json}).
      # @api private
      def self.frame_json(line)
        s = line.to_s # NOTES rule 62
        at = s.byteindex(":in ")
        return SentrySender.bare_frame(s) if at.nil?

        place = s.byteslice(0, at).to_s
        colon = SentrySender.last_colon(place)
        return SentrySender.bare_frame(s) if colon <= 0

        file = place.byteslice(0, colon).to_s
        number = place.byteslice(colon + 1, place.bytesize - colon - 1).to_s
        return SentrySender.bare_frame(s) unless SentrySender.lineno_digits?(number)

        rest = s.byteslice(at + 4, s.bytesize - at - 4).to_s
        n = rest.bytesize
        return SentrySender.bare_frame(s) if n < 2

        quote = rest.getbyte(0)
        return SentrySender.bare_frame(s) unless (quote == 39 || quote == 96) && rest.getbyte(n - 1) == 39

        function = rest.byteslice(1, n - 2).to_s
        out = +"{\"filename\":"
        out << Logger.json_quote(file)
        out << ",\"lineno\":"
        out << number
        out << ",\"function\":"
        out << Logger.json_quote(function)
        out << "}"
        out
      end

      # A frame that did not read: the whole line as its filename.
      # @api private
      def self.bare_frame(line)
        out = +"{\"filename\":"
        out << Logger.json_quote(line)
        out << "}"
        out
      end

      # The byte index of the last ":" in `text`, -1 when there is none.
      # @api private
      def self.last_colon(text)
        s = text.to_s # NOTES rule 62
        i = s.bytesize - 1
        while i >= 0
          return i if s.getbyte(i) == 58

          i -= 1
        end
        -1
      end

      # Whether `text` is 1 to 9 decimal digits (a frame's line number).
      # @api private
      def self.lineno_digits?(text)
        s = text.to_s
        n = s.bytesize
        return false if n == 0 || n > 9

        i = 0
        while i < n
          b = s.getbyte(i)
          return false if b < 48 || b > 57

          i += 1
        end
        true
      end

      private

      # The parsed DSN of `text`, parsed once per text (raises
      # ArgumentError for a DSN that does not read: one assigned after
      # boot's check).
      def dsn_for(text)
        unless text == @dsn_text
          parsed = SentryDsn.from_text(text)
          @dsn = parsed
          @dsn_text = text
        end
        @dsn
      end

      # The POST, in a plain rescuing method: a non-2xx answer and every
      # failure are logged at warn, never retried, and answer false.
      def post_event(text, event)
        dsn = dsn_for(text)
        event_id = Crypto.random_token(16)
        body = SentrySender.envelope(event, text, event_id)
        headers = { "X-Sentry-Auth" => SentrySender.auth_header(dsn.dsn_public_key) }
        client = HttpClient.new(timeout: 3, deadline: 5)
        res = client.post(dsn.dsn_endpoint, body, content_type: CONTENT_TYPE, headers: headers)
        status = res.status
        return true if status >= 200 && status <= 299

        line = "error report not sent: Sentry answered #{status}"
        Cybertrain.logger.warn(line)
        false
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        not_sent(e)
      rescue NotImplementedError, SystemStackError, ScriptError => e
        not_sent(e)
      end

      def not_sent(error)
        text = ErrorReporter.failure_text(error)
        line = "error report not sent: #{text}"
        Cybertrain.logger.warn(line)
        false
      end
    end
  end
end

Cybertrain.error.sender = Cybertrain::ErrorReporter::SentrySender.new
