# frozen_string_literal: true

module Play
  # In front of Play::App (config.ru). Every answer the control plane gives,
  # whoever makes it (a route, Sinatra's own 400, 404 or 500, the host
  # check's 403, the 413 below), leaves with HEADERS: the entry origin's
  # security headers (spec §5.13, §6.3). And no request body gets in: no
  # route takes one, and Rack would parse a form body before any route ran,
  # a multipart one into a temp file. A request declares a body with a
  # Content-Length above zero or a Transfer-Encoding (Puma decodes a chunked
  # body and passes its length); a browser's empty form POST sends
  # Content-Length: 0 and passes.
  class Guard
    NO_BODY = "No request body is accepted.\n"

    def initialize(app, headers:)
      @app = app
      @headers = headers
    end

    def call(env)
      status, headers, body = body?(env) ? [413, { "content-type" => "text/plain;charset=utf-8" }, [NO_BODY]] : @app.call(env)
      [status, headers.merge(@headers), body]
    end

    private

    def body?(env)
      env["CONTENT_LENGTH"].to_i.positive? || env.key?("HTTP_TRANSFER_ENCODING")
    end
  end
end
