# frozen_string_literal: true

module Play
  # In front of Play::App (Play::App.for builds both). Every answer the
  # control plane gives, whoever makes it (a route, Sinatra's own 400, 404
  # or 500, the host check's 403, the 413 below), leaves with HEADERS: the
  # entry origin's security headers (spec §5.13, §6.3). And nothing a visitor
  # wrote is parsed: no route reads a parameter or a body, but Sinatra would
  # parse both before any route ran (a deep or long query raised, a
  # multipart body went into a temp file). So the app gets each request with
  # an empty query string, and a request that declares a body (a
  # Content-Length above zero or a Transfer-Encoding; Puma decodes a chunked
  # body and passes its length) gets 413. A browser's empty form POST sends
  # Content-Length: 0 and passes.
  class Guard
    NO_BODY = "No request body is accepted.\n"

    def initialize(app, headers:)
      @app = app
      @headers = headers
    end

    def call(env)
      status, headers, body = body?(env) ? refusal : @app.call(env.merge("QUERY_STRING" => ""))
      [status, headers.merge(@headers), body]
    end

    private

    def body?(env)
      env["CONTENT_LENGTH"].to_i.positive? || env.key?("HTTP_TRANSFER_ENCODING")
    end

    def refusal
      [413, { "content-type" => "text/plain;charset=utf-8" }, [NO_BODY]]
    end
  end
end
