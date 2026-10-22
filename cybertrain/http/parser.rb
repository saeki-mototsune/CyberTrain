module Cybertrain
  # The parsed request line and headers of one HTTP/1.x request.
  class RequestHead
    # headers: names lowercased, values stripped, duplicates joined with ", "
    attr_reader :method, :target, :http_version, :headers

    def initialize(method, target, http_version, headers)
      @method = method
      @target = target
      @http_version = http_version
      @headers = headers
    end
  end

  # Parses the head (request line + header lines) of an HTTP/1.x request.
  # The Server scans its socket buffer for HEAD_END (byteindex) and hands
  # everything before it to parse_head. Percent-decoding of the target is
  # left to Query and the Router.
  class HttpParser
    class ParseError < StandardError
    end

    HEAD_END = "\r\n\r\n"
    SUPPORTED_VERSIONS = ["HTTP/1.1", "HTTP/1.0"]

    def self.parse_head(head)
      lines = head.split("\r\n")
      # RFC 9112 section 2.2: ignore empty lines before the request line
      # (e.g. a stray CRLF after a POST body on a keep-alive connection).
      first = 0
      first += 1 while first < lines.size && lines[first].empty?
      raise ParseError, "empty request" if first >= lines.size

      method, target, version = parse_request_line(lines[first])
      headers = {}
      i = first + 1
      while i < lines.size
        line = lines[i]
        i += 1
        next if line.empty?

        raise ParseError, "bare CR in header line: #{line}" if line.include?("\r")

        colon = line.index(":")
        raise ParseError, "malformed header line: #{line}" if colon.nil? || colon == 0

        # RFC 9112 section 5.1: no whitespace before the colon or inside the
        # name (a request-smuggling vector); this also rejects obs-fold lines.
        name = line[0, colon]
        if name.include?(" ") || name.include?("\t")
          raise ParseError, "invalid header name: #{line}"
        end
        name = name.downcase
        value = line[colon + 1, line.size - colon - 1].strip
        existing = headers[name]
        headers[name] = existing.nil? ? value : "#{existing}, #{value}"
      end
      RequestHead.new(method, target, version, headers)
    end

    def self.parse_request_line(line)
      parts = line.split(" ")
      raise ParseError, "malformed request line: #{line}" unless parts.size == 3

      version = parts[2]
      unless SUPPORTED_VERSIONS.include?(version)
        raise ParseError, "unsupported HTTP version: #{version}"
      end
      [parts[0], parts[1], version]
    end

    # True when text is one or more ASCII digits, false for "" (the
    # Content-Length readers, Request#content_length and Server#body_length,
    # treat an empty value as malformed). A while loop over getbyte: no
    # Array and no block per request, as `bytes.all?` would cost. Lives here,
    # not as Cast.digits? (which is true for ""): the HTTP layer requires
    # nothing outside cybertrain/http/ but params.rb and logger.rb
    # (script/check-http-layer).
    def self.digits?(text)
      n = text.bytesize
      return false if n == 0

      i = 0
      while i < n
        b = text.getbyte(i)
        return false if b < 48 || b > 57
        i += 1
      end
      true
    end
  end
end
