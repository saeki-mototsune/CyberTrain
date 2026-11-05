require "json"
require "cybertrain/middleware"
require "cybertrain/logger"
require "cybertrain/http/client_error"
require "cybertrain/http/parameter_filter"

module Cybertrain
  # Rails-style request log lines around the rest of the stack:
  #   Started GET "/posts?page=2" for 127.0.0.1
  #   Completed 200 in 3ms
  # with each filtered parameter's value in the query string written as
  # `[FILTERED]` (ParameterFilter, Config#filter_parameters).
  class RequestLogger < Middleware
    # stream_path: the stream endpoint's path (Config#stream_path), whose
    # `s` parameters are signed stream tokens and are logged as
    # `[FILTERED]` whatever Config#filter_parameters says; "" for none.
    def initialize(app, logger = Cybertrain.logger, stream_path = "")
      super(app)
      @logger = logger
      @stream_path = stream_path
    end

    def call(ctx)
      request = ctx.request
      target = log_field(request.path)
      # The values of filtered parameters (Config#filter_parameters) never
      # reach the log: replaced before the escaping, on the raw bytes.
      unless request.query_string.empty?
        query = request.query_string
        query = RequestLogger.filter_tokens(query) if !@stream_path.empty? && request.path == @stream_path
        target = "#{target}?#{log_field(ParameterFilter.filter_query(query))}"
      end
      @logger.info("Started #{log_field(request.method)} \"#{target}\" for #{request.remote_addr}")
      started = Time.now
      begin
        super
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        # Still two lines per request: the error path outside this
        # middleware (ErrorPages, Dev::ErrorPage or the Server) answers the
        # status ClientError.status_for gives the exception -- 400 for a client
        # fault, 500 otherwise (a name lookup, nothing is re-raised, so both
        # sites always agree) -- so log that status (as Rails does) and let
        # it propagate. JSON::ParserError named too (NOTES rule 33), or an
        # action's bad JSON.parse would leave the request without its
        # Completed line under Spinel.
        log_completed(ClientError.status_for(e), started)
        raise e
      end
      log_completed(ctx.response.status, started)
      nil
    end

    # The query with the value of every pair named exactly `s` replaced by
    # [FILTERED] (a substring filter would also take `sort=`). The name is
    # compared percent-decoded, so `%73=` is a token too: a token that a
    # client sent under an encoded name is still a valid token.
    def self.filter_tokens(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      out = +""
      start = 0
      # A byte scan, not split("&"): a query may hold invalid UTF-8, on which
      # String#split raises under CRuby (NOTES rule 52).
      while start <= n
        amp = s.byteindex("&", start)
        stop = amp.nil? ? n : amp
        eq = s.byteindex("=", start)
        if !eq.nil? && eq < stop && RequestLogger.token_name?(s, start, eq)
          out << s.byteslice(start, eq - start + 1).to_s
          out << "[FILTERED]"
        else
          out << s.byteslice(start, stop - start)
        end
        break if amp.nil?

        out << "&"
        start = amp + 1
      end
      out
    end

    # Whether bytes [from, stop) of s, percent-decoded (`+` as a space, any
    # case), are exactly `s`: one byte, or one escape for it.
    def self.token_name?(s, from, stop)
      len = stop - from
      return s.getbyte(from) == 115 || s.getbyte(from) == 83 if len == 1
      return false unless len == 3 && s.getbyte(from) == 37

      hi = ParameterFilter.hex_value(s.getbyte(from + 1))
      lo = ParameterFilter.hex_value(s.getbyte(from + 2))
      return false if hi < 0 || lo < 0

      b = hi * 16 + lo
      b == 115 || b == 83
    end

    private

    # Binary inspect escapes every control byte, including terminal escapes,
    # and quotes/backslashes. Strip only its surrounding quotes so normal
    # request log lines keep their existing format.
    def log_field(value)
      quoted = value.b.inspect
      quoted[1, quoted.size - 2]
    end

    def log_completed(status, started)
      elapsed = ((Time.now - started) * 1000).to_i
      @logger.info("Completed #{status} in #{elapsed}ms")
    end
  end
end
