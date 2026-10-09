require "cybertrain/http/header_name"

module Cybertrain
  # The response a request builds up on its way through the stack; the
  # Server serializes it with #to_http. Headers keep the case they were set
  # with, and Set-Cookie values live in their own list because one response
  # may carry several.
  #
  # {Controller#response} in an action. {Controller#render},
  # {Controller#redirect_to} and {Controller#head} set the status and body;
  # use this object for headers and cookies. Content-Length is always
  # computed, and Content-Type defaults to `text/html; charset=utf-8`.
  # @example
  #   response.set_header("Cache-Control", "no-store")
  #   response.add_cookie(Cybertrain::Cookies.serialize("theme", "dark", max_age: 31_536_000))
  # @api public
  class Response
    STATUS_TEXT = {
      200 => "OK", 201 => "Created", 204 => "No Content",
      301 => "Moved Permanently", 302 => "Found", 303 => "See Other", 304 => "Not Modified",
      400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed",
      411 => "Length Required", 413 => "Payload Too Large", 422 => "Unprocessable Entity",
      500 => "Internal Server Error"
    }
    DEFAULT_CONTENT_TYPE = "text/html; charset=utf-8"

    # The status code, 200 until set. A code missing from STATUS_TEXT
    # (401, 409, ...) is sent with the reason phrase "Unknown".
    # @return [Integer]
    # @api public
    attr_accessor :status

    # The body, `""` until set.
    # @return [String]
    # @api public
    attr_accessor :body

    # The headers set so far, in the case they were set with; change them
    # through {#set_header} and {#drop_header}.
    # @return [Hash{String => String}]
    # @api public
    attr_reader :headers

    # The Set-Cookie values added so far.
    # @return [Array<String>]
    # @api public
    attr_reader :cookies

    def initialize
      @status = 200
      @body = ""
      @headers = {}
      @cookies = []
      @performed = false
    end

    # Starts the response over as a plain-text error: every header and
    # cookie an action had already set goes (a stale Location or
    # Content-Disposition: attachment would hide the error), then status,
    # text/plain and body ("" means the status text; plain_error). The one
    # sequence the Server, ErrorPages and Dev::ErrorPage share.
    def reset_to(status, body = "")
      @headers.clear
      @cookies.clear
      plain_error(status, body)
    end

    # The other reset policy, for a client fault the action raised (a
    # missing required parameter, a query past its limits): answer the
    # status in plain text, but only the two headers that would hide the
    # error go, Location and Content-Disposition (through drop_header, so
    # any spelling): the action may already have called redirect_to or set
    # an attachment before it raised. Every other header and cookie stays:
    # a before_action's CORS headers, Cache-Control: no-store or a session
    # cookie are deliberate, and a CORS client that lost
    # Access-Control-Allow-Origin would see an opaque network error instead
    # of the status. A header that hides an error in future (Refresh, a
    # stale Content-Encoding) is added here, in one place. reset_to is the
    # other policy: start over, for a failure the app never handled. Both
    # finish with plain_error; the caller marks the response performed!.
    def client_error!(status, body)
      drop_header("Location")
      drop_header("Content-Disposition")
      plain_error(status, body)
    end

    # Replaces any existing header of the same name, whatever its case,
    # keeping its position in the output. Raises ArgumentError when the name
    # or value contains CR or LF (header injection / response splitting).
    # @param name [String]
    # @param value [String]
    # @raise [ArgumentError] on a CR or LF
    # @api public
    def set_header(name, value)
      reject_crlf!(name, name)
      reject_crlf!(name, value)
      existing = header_key(name)
      if existing.nil? || existing == name
        @headers[name] = value
      else
        # Rebuilt in place (clear, then put back in order): `headers` is a
        # public reader, so a Hash a before_action or middleware kept must
        # stay the live one.
        names = []
        values = []
        @headers.each do |k, v|
          names << (k == existing ? name : k)
          values << v
        end
        @headers.clear
        names.each_with_index { |k, i| @headers[k] = k == name ? value : values[i] }
      end
    end

    # Removes the header of that name, whatever its case (every spelling
    # when several were stored); a missing one is not an error. Returns nil
    # (NOTES rules 10/34: one return type for the name). Edits @headers in
    # place: `headers` is a public reader, so a Hash a before_action or
    # middleware took earlier must still be the live one afterwards. The
    # matching keys are collected first (never delete while iterating) and
    # removed with Hash#delete; no block-taking Hash method is needed.
    # @param name [String]
    # @return [nil]
    # @api public
    def drop_header(name)
      gone = []
      @headers.keys.each { |k| gone << k if HeaderName.same?(k, name) }
      gone.each { |k| @headers.delete(k) }
      nil
    end

    # @param name [String] any case
    # @return [String, nil]
    # @api public
    def header(name)
      key = header_key(name)
      key.nil? ? nil : @headers[key]
    end

    # @param value [String] e.g. `"text/csv; charset=utf-8"`
    # @api public
    def content_type=(value)
      set_header("Content-Type", value)
    end

    # Adds a Set-Cookie header; build the value with {Cookies.serialize}.
    # Raises ArgumentError when the value contains CR or LF.
    # @param set_cookie_value [String]
    # @api public
    def add_cookie(set_cookie_value)
      reject_crlf!("Set-Cookie", set_cookie_value)
      @cookies << set_cookie_value
    end

    # Raises ArgumentError (leaving the response untouched) when location
    # contains CR or LF, e.g. a percent-decoded return_to param.
    def redirect(location, status = 302)
      set_header("Location", location)
      @status = status
      @performed = true
    end

    def performed?
      @performed
    end

    def performed!
      @performed = true
    end

    def status_text
      Response.status_text(@status)
    end

    # "Bad Request" for 400; "Unknown" for a status the table lacks.
    def self.status_text(status)
      STATUS_TEXT[status] || "Unknown"
    end

    # Content-Length is always computed from the body; a HEAD response
    # (head_only) keeps it but leaves the body out. Accepted deviation:
    # Content-Length and the default Content-Type are emitted for 204 and
    # 304 too, although RFC 9110 section 8.6 forbids Content-Length in a
    # 204.
    def to_http(head_only = false)
      out = +"HTTP/1.1 #{@status} #{status_text}\r\n"
      out << "Content-Type: #{DEFAULT_CONTENT_TYPE}\r\n" if header_key("content-type").nil?
      @headers.each do |name, value|
        next if HeaderName.same?(name, "content-length")

        out << name << ": " << value << "\r\n"
      end
      out << "Content-Length: #{@body.bytesize}\r\n"
      @cookies.each do |cookie|
        out << "Set-Cookie: " << cookie << "\r\n"
      end
      out << "\r\n"
      out << @body unless head_only
      out
    end

    private

    # The tail both reset policies share: status, text/plain content type
    # and the body ("" means the status text). Returns nil.
    def plain_error(status, body)
      @status = status
      self.content_type = "text/plain; charset=utf-8"
      @body = body == "" ? status_text : body
      nil
    end

    def reject_crlf!(name, text)
      if text.include?("\r") || text.include?("\n")
        raise ArgumentError, "header #{name} must not contain CR or LF"
      end
    end

    def header_key(name)
      @headers.each_key do |k|
        return k if HeaderName.same?(k, name)
      end
      nil
    end
  end
end
