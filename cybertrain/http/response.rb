module Cybertrain
  # The response a request builds up on its way through the stack; the
  # Server serializes it with #to_http. Headers keep the case they were set
  # with, and Set-Cookie values live in their own list because one response
  # may carry several.
  class Response
    STATUS_TEXT = {
      200 => "OK", 201 => "Created", 204 => "No Content",
      301 => "Moved Permanently", 302 => "Found", 303 => "See Other", 304 => "Not Modified",
      400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed",
      411 => "Length Required", 413 => "Payload Too Large", 422 => "Unprocessable Entity",
      500 => "Internal Server Error"
    }
    DEFAULT_CONTENT_TYPE = "text/html; charset=utf-8"

    attr_accessor :status, :body
    attr_reader :headers, :cookies

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
    # text/plain and body ("" means the status text). The one sequence the
    # Server, ErrorPages and Dev::ErrorPage share.
    def reset_to(status, body = "")
      @headers.clear
      @cookies.clear
      @status = status
      self.content_type = "text/plain; charset=utf-8"
      @body = body == "" ? status_text : body
      nil
    end

    # Replaces any existing header of the same name, whatever its case,
    # keeping its position in the output. Raises ArgumentError when the name
    # or value contains CR or LF (header injection / response splitting).
    def set_header(name, value)
      reject_crlf!(name, name)
      reject_crlf!(name, value)
      existing = header_key(name)
      if existing.nil? || existing == name
        @headers[name] = value
      else
        rebuilt = {}
        @headers.each do |k, v|
          if k == existing
            rebuilt[name] = value
          else
            rebuilt[k] = v
          end
        end
        @headers = rebuilt
      end
    end

    def header(name)
      key = header_key(name)
      key.nil? ? nil : @headers[key]
    end

    def content_type=(value)
      set_header("Content-Type", value)
    end

    # Raises ArgumentError when the value contains CR or LF.
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
        next if name.downcase == "content-length"

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

    def reject_crlf!(name, text)
      if text.include?("\r") || text.include?("\n")
        raise ArgumentError, "header #{name} must not contain CR or LF"
      end
    end

    def header_key(name)
      wanted = name.downcase
      @headers.each_key do |k|
        return k if k.downcase == wanted
      end
      nil
    end
  end
end
