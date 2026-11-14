require "cybertrain/http/header_name"
require "cybertrain/http/body_writer"
require "cybertrain/logger"

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
  # `X-Content-Type-Options: nosniff` and `X-Frame-Options: SAMEORIGIN` are
  # added to every response that does not set them itself: to allow framing
  # (an embeddable widget) or change the value, set the header with
  # {#set_header}; the response's own value is sent and nothing is doubled.
  # @example
  #   response.set_header("Cache-Control", "no-store")
  #   response.add_cookie(Cybertrain::Cookies.serialize("theme", "dark", max_age: 31_536_000))
  # @api public
  class Response
    # The reason phrase of each status the framework, its generators and an
    # application built on them answer (RFC 9110 section 15), sent on the
    # status line by #to_http. Browsers ignore the phrase, but curl and the
    # logs show it, so a code missing here would be written as "Unknown"
    # (`HTTP/1.1 202 Unknown`). The phrases are RFC 9110's (413 "Content Too
    # Large", 422 "Unprocessable Content"). A new code goes here and, as a
    # Symbol, into Controller::STATUS_SYMBOLS; the two tables list the same
    # codes, plus five older names that are extra Symbols (`:payload_too_large`,
    # `:request_entity_too_large`, `:unprocessable_entity`,
    # `:request_uri_too_long`, `:requested_range_not_satisfiable`).
    STATUS_TEXT = {
      100 => "Continue", 101 => "Switching Protocols", 102 => "Processing", 103 => "Early Hints",
      200 => "OK", 201 => "Created", 202 => "Accepted", 203 => "Non-Authoritative Information",
      204 => "No Content", 205 => "Reset Content", 206 => "Partial Content",
      207 => "Multi-Status", 208 => "Already Reported", 226 => "IM Used",
      300 => "Multiple Choices", 301 => "Moved Permanently", 302 => "Found", 303 => "See Other",
      304 => "Not Modified", 305 => "Use Proxy", 307 => "Temporary Redirect", 308 => "Permanent Redirect",
      400 => "Bad Request", 401 => "Unauthorized", 402 => "Payment Required", 403 => "Forbidden",
      404 => "Not Found", 405 => "Method Not Allowed", 406 => "Not Acceptable",
      407 => "Proxy Authentication Required", 408 => "Request Timeout", 409 => "Conflict",
      410 => "Gone", 411 => "Length Required", 412 => "Precondition Failed",
      413 => "Content Too Large", 414 => "URI Too Long", 415 => "Unsupported Media Type",
      416 => "Range Not Satisfiable", 417 => "Expectation Failed", 421 => "Misdirected Request",
      422 => "Unprocessable Content", 423 => "Locked", 424 => "Failed Dependency",
      425 => "Too Early", 426 => "Upgrade Required", 428 => "Precondition Required",
      429 => "Too Many Requests", 431 => "Request Header Fields Too Large",
      451 => "Unavailable For Legal Reasons",
      500 => "Internal Server Error", 501 => "Not Implemented", 502 => "Bad Gateway",
      503 => "Service Unavailable", 504 => "Gateway Timeout", 505 => "HTTP Version Not Supported",
      506 => "Variant Also Negotiates", 507 => "Insufficient Storage", 508 => "Loop Detected",
      510 => "Not Extended", 511 => "Network Authentication Required"
    }
    DEFAULT_CONTENT_TYPE = "text/html; charset=utf-8"
    # Sent on every response unless the response already carries a header of
    # that name, in any case (docs/design.md D14). To differ, set the header
    # on the response: `response.set_header("X-Frame-Options", "DENY")`.
    DEFAULT_NOSNIFF = "nosniff"
    DEFAULT_FRAME_OPTIONS = "SAMEORIGIN"

    # The Permissions-Policy every response carries unless it sets its own
    # (spec C-11): camera, microphone and geolocation off. Application#boot
    # installs Config#permissions_policy here; "" sends none.
    @default_permissions_policy = "camera=(), microphone=(), geolocation=()"

    # @return [String] the default Permissions-Policy, "" for none
    # @api public
    def self.default_permissions_policy
      @default_permissions_policy
    end

    # @param value [String] e.g. `"camera=(), geolocation=(self)"`, or "" for none
    # @raise [ArgumentError] on a CR or LF, changing nothing
    # @api public
    def self.default_permissions_policy=(value)
      text = value.to_s
      if text.include?("\r") || text.include?("\n")
        msg = "header Permissions-Policy must not contain CR or LF"
        raise ArgumentError, msg
      end
      @default_permissions_policy = text
    end

    # The status code, 200 until set. The status line carries the reason
    # phrase STATUS_TEXT gives the code; a code the table lacks (418, a
    # non-standard code) is sent with the phrase "Unknown".
    # @return [Integer]
    # @api public
    attr_accessor :status

    # The body, `""` until set.
    # @return [String]
    # @api public
    attr_reader :body

    # Sets the body. A body replaces a stream: an action that called
    # Controller#stream and then render or head answers with the body, so
    # the writer is dropped, as {#redirect} and an error reset drop it.
    # @param text [String]
    # @api public
    def body=(text)
      @body_writer = nil
      @upgrade = false
      @body = text
    end

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
      # Seeded with a String pair, then emptied (NOTES rule 9): a bare `{}`
      # is a Hash of untyped keys, which hands every key to HeaderName boxed
      # (NOTES rule 62).
      @headers = { "" => "" }
      @headers.delete("")
      @cookies = []
      @performed = false
      # Set by Controller#stream (or a middleware such as Stream::Endpoint);
      # nil for an ordinary response.
      @body_writer = nil
      @upgrade = false
      # The log Scope the writer runs under (see #body_scope).
      @body_scope = Logger::NO_SCOPE
    end

    # The writer of a streaming response (docs/design.md D36), nil for an
    # ordinary one.
    # @return [BodyWriter, nil]
    # @api public
    attr_reader :body_writer

    # Makes this a streaming response: the Server sends the head without a
    # Content-Length, then runs the writer on the connection's thread
    # ({BodyWriter#write_body}) and closes the connection when it returns.
    # @param writer [BodyWriter]
    # @api public
    def body_writer=(writer)
      @body_writer = writer
      @body_scope = Logger.current_scope
    end

    # The thread's log Scope when the writer was set ({#body_writer=},
    # {#upgrade!}): the request's, whose id and tags the lines logged while
    # the body is written carry (spec section 12.2: the request lasts until
    # its body is written). The Server swaps it in around the writer
    # ({BodyWriter.write_scoped}) and back after it.
    # @return [Logger::Scope]
    # @api private
    attr_reader :body_scope

    # @return [Boolean] true when a {BodyWriter} is set
    # @api public
    def streaming?
      !@body_writer.nil?
    end

    # Marks a 101 Switching Protocols answer (the WebSocket handshake): the
    # Server writes the status line, the headers set on the response and
    # nothing else (no default headers, no body framing), then hands the
    # socket to the writer through {Sink#socket}.
    # @param writer [BodyWriter]
    def upgrade!(writer)
      @status = 101
      @upgrade = true
      @body_writer = writer
      @body_scope = Logger.current_scope
      @performed = true
      nil
    end

    # @return [Boolean] whether #upgrade! was called
    def upgrade?
      @upgrade
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
        respell_header(existing, name, value)
      end
    end

    # Removes the header of that name, whatever its case (every spelling
    # when several were stored); a missing one is not an error. Returns nil
    # (NOTES rules 10/34: one return type for the name). Edits @headers in
    # place: `headers` is a public reader, so a Hash a before_action or
    # middleware took earlier must still be the live one afterwards. The
    # matching keys are collected first (never delete while iterating) and
    # removed with Hash#delete. `each_key`, not `keys.each`: where @headers
    # is boxed, `keys` dispatches over the program's own `keys` methods (a
    # model's Errors#keys) and not to Hash#keys (NOTES rules 51 and 62).
    # @param name [String]
    # @return [nil]
    # @api public
    def drop_header(name)
      gone = Array.new(0) { "" }
      @headers.each_key { |k| gone << k if HeaderName.same?(k, name) }
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

    # Adds a Set-Cookie header in place of any earlier one for the cookie
    # `name` (a value starting `"name="`), so a cookie written twice in one
    # request is sent once, with its last value ({CookieJar} writes through
    # this). Raises ArgumentError, changing nothing, when the value contains
    # CR or LF. The list is edited in place (`cookies` is a public reader).
    # @param name [String]
    # @param set_cookie [String] built with {Cookies.serialize}
    # @return [nil]
    # @api public
    def replace_cookie(name, set_cookie)
      reject_crlf!("Set-Cookie", set_cookie)
      prefix = "#{name}="
      kept = Array.new(0) { "" }
      @cookies.each { |c| kept << c unless c.start_with?(prefix) }
      @cookies.clear
      kept.each { |c| @cookies << c }
      @cookies << set_cookie
      nil
    end

    # Raises ArgumentError (leaving the response untouched) when location
    # contains CR or LF, e.g. a percent-decoded return_to param. Returns nil:
    # `redirect` is also the routes DSL's Mapper#redirect, and one name keeps
    # one return type across the program (NAME_HOMES in
    # script/check-reserved-names; spikes/NOTES.md rules 10, 34).
    def redirect(location, status = 302)
      set_header("Location", location) # raises on CR/LF: the stream stays
      @body_writer = nil
      @upgrade = false
      @status = status
      @performed = true
      nil
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

    # "Bad Request" for 400; "Unknown" for a status STATUS_TEXT lacks.
    def self.status_text(status)
      STATUS_TEXT[status] || "Unknown"
    end

    # Content-Length is always computed from the body; a HEAD response
    # (head_only) keeps it but leaves the body out. The default
    # Content-Type, X-Content-Type-Options and X-Frame-Options are added
    # when the response has no header of that name (D14); every response
    # the Server writes, error answers and HEAD included, goes through this
    # method. Permissions-Policy is one of those defaults too
    # (Response.default_permissions_policy). A 304 carries neither Content-Length nor Content-Type (RFC
    # 9110 15.4.5), and no body either, even when one was set (`render
    # plain: "x", status: :not_modified`): bytes after a 304's head would be
    # read as the start of the next response on a keep-alive connection.
    # Accepted deviation: Content-Length and the default
    # Content-Type are emitted for 204 too, although RFC 9110 section 8.6
    # forbids Content-Length in a 204.
    def to_http(head_only = false)
      out = +"HTTP/1.1 #{@status} #{status_text}\r\n"
      # A 304 describes no body: no Content-Type and no Content-Length
      # (RFC 9110 15.4.5), as Rails sends it.
      not_modified = @status == 304
      out << "Content-Type: #{DEFAULT_CONTENT_TYPE}\r\n" if !not_modified && header_key("content-type").nil?
      @headers.each do |name, value|
        next if HeaderName.same?(name, "content-length")
        next if not_modified && HeaderName.same?(name, "content-type")

        out << name << ": " << value << "\r\n"
      end
      out << "X-Content-Type-Options: #{DEFAULT_NOSNIFF}\r\n" if header_key("x-content-type-options").nil?
      out << "X-Frame-Options: #{DEFAULT_FRAME_OPTIONS}\r\n" if header_key("x-frame-options").nil?
      add_permissions_policy(out)
      out << "Content-Length: #{@body.bytesize}\r\n" unless not_modified
      @cookies.each do |cookie|
        out << "Set-Cookie: " << cookie << "\r\n"
      end
      out << "\r\n"
      out << @body unless head_only || not_modified
      out
    end

    # The head of a streaming response, ending with the blank line: what
    # #to_http writes minus Content-Length (a streaming body has none), plus
    # `Transfer-Encoding: chunked` when `chunked`. An upgrade (#upgrade!)
    # gets only the status line, its own headers and its cookies.
    # @param chunked [Boolean]
    # @return [String]
    def to_http_head(chunked)
      out = +"HTTP/1.1 #{@status} #{status_text}\r\n"
      upgrade = @upgrade
      out << "Content-Type: #{DEFAULT_CONTENT_TYPE}\r\n" if !upgrade && header_key("content-type").nil?
      @headers.each do |name, value|
        next if HeaderName.same?(name, "content-length") || HeaderName.same?(name, "transfer-encoding")

        out << name << ": " << value << "\r\n"
      end
      unless upgrade
        out << "X-Content-Type-Options: #{DEFAULT_NOSNIFF}\r\n" if header_key("x-content-type-options").nil?
        out << "X-Frame-Options: #{DEFAULT_FRAME_OPTIONS}\r\n" if header_key("x-frame-options").nil?
        add_permissions_policy(out)
      end
      out << "Transfer-Encoding: chunked\r\n" if chunked
      @cookies.each do |cookie|
        out << "Set-Cookie: " << cookie << "\r\n"
      end
      out << "\r\n"
      out
    end

    private

    # The default Permissions-Policy line, unless the response set the
    # header or the default is "".
    def add_permissions_policy(out)
      policy = Response.default_permissions_policy
      out << "Permissions-Policy: " << policy << "\r\n" if !policy.empty? && header_key("permissions-policy").nil?
      nil
    end

    # The tail both reset policies share: status, text/plain content type
    # and the body ("" means the status text). Returns nil.
    def plain_error(status, body)
      # An error after Controller#stream (or an upgrade) is an ordinary
      # response: no writer runs and nothing is sent chunked.
      @body_writer = nil
      @upgrade = false
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

    # set_header's rare case: the header is there under another spelling
    # (`existing`). Rebuilt in place (clear, then put back in order):
    # `headers` is a public reader, so a Hash a before_action or middleware
    # kept must stay the live one. A method of its own because of its
    # blocks: Spinel allocates a heap cell per captured local on entry to
    # the method that holds a block, and set_header runs on every response
    # (docs/performance-next.md 9).
    def respell_header(existing, name, value)
      names = []
      values = []
      @headers.each do |k, v|
        names << (k == existing ? name : k)
        values << v
      end
      @headers.clear
      names.each_with_index { |k, i| @headers[k] = k == name ? value : values[i] }
    end

    def header_key(name)
      @headers.each_key do |k|
        return k if HeaderName.same?(k, name)
      end
      nil
    end
  end
end
