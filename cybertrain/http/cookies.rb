require "uri"
require "cybertrain/http/query"
require "cybertrain/http/request"

module Cybertrain
  # Cookie header parsing and Set-Cookie serialization. Values round-trip
  # through the same www-form percent-encoding Query uses, so a value with
  # a space, "=" or ";" survives both directions. Unlike a query string, a
  # cookie that does not decode is NOT a client fault: SessionStore parses
  # every cookie on every request but reads only its own, so a foreign one
  # ("promo=50%off", set by another app on the parent domain) must not turn
  # every dynamic page into a 400. Its raw value is kept, as Rack does.
  #
  # In a controller, `cookies` (Controller#cookies, a {CookieJar}) is the
  # way to read and write cookies, signed and encrypted ones included; it
  # writes through {.serialize} and {Response#replace_cookie}. This module
  # is the layer under it, for middleware and code without a controller.
  # @example
  #   theme = Cybertrain::Cookies.parse(request.cookie_header)["theme"]
  #   response.add_cookie(Cybertrain::Cookies.serialize("theme", "dark", max_age: 31_536_000))
  #   response.add_cookie(Cybertrain::Cookies.serialize("theme", "", max_age: 0))   # delete
  # @api public
  module Cookies
    # Query.decode, falling back to the raw text when it raises QueryMalformed:
    # a malformed escape or an invalid UTF-8 byte sequence (raw, or "%81"),
    # on both runtimes (Query.decode goes through decode_escapes, which
    # validates the text as UTF-8 first (Query.utf8!) and then decodes it
    # itself: Spinel's decoder is lenient, NOTES rule 28, and CRuby's byteindex
    # would raise IndexError on such text, rule 52). The raw value is kept on
    # QueryMalformed, never the half-decoded one. A plain non-yielding
    # method with one rescue clause by class: fine under Spinel (NOTES rules
    # 32, 47).
    def self.decode(value)
      # Nothing to decode (the session cookie and signed and encrypted
      # cookies are base64url, "-", "_" and hex):
      # the value as it is, which is also what an invalid byte sequence gets.
      return value if value.byteindex("%").nil? && value.byteindex("+").nil?

      Query.decode(value)
    rescue QueryMalformed
      value
    end

    # The cookies in a Cookie header, values decoded. The first of two
    # cookies with one name wins.
    # @param header [String] {Request#cookie_header}
    # @return [Hash{String => String}]
    # @api public
    def self.parse(header)
      cookies = {}
      header.to_s.split(";").each do |pair|
        trimmed = pair.strip
        next if trimmed.empty?

        eq = trimmed.index("=")
        next if eq.nil?

        name = trimmed[0, eq]
        next if cookies.key?(name)

        value = trimmed[(eq + 1)..-1].to_s
        cookies[name] = decode(value)
      end
      cookies
    end

    # RFC 6265 separators: a cookie name may not contain these, a space or
    # a tab, nor anything outside visible ASCII.
    NAME_SEPARATORS = "()<>@,;:\\\"/[]?={}"

    # Whether `name` is an RFC 6265 token: one or more visible ASCII
    # characters (0x21-0x7e) that are not separators.
    # @param name [String]
    # @return [Boolean]
    # @api public
    def self.token?(name)
      text = name.to_s # a fresh local for the byte reads (NOTES rule 62)
      return false if text.empty?

      i = 0
      n = text.bytesize
      while i < n
        b = text.getbyte(i)
        return false if b <= 32 || b >= 127
        return false if NAME_SEPARATORS.include?(text.byteslice(i, 1).to_s)

        i += 1
      end
      true
    end

    # Raises ArgumentError for a cookie name that is not a token, or an
    # attribute value (`Path`, `Domain`, `SameSite`) holding ";" (which would
    # start another attribute) or CR/LF; `same_site` must also be Lax,
    # Strict or None, in any case.
    def self.validate!(name, path, same_site)
      unless Cookies.token?(name)
        message = "cookie name #{name.to_s.inspect} is not an RFC 6265 token"
        raise ArgumentError, message
      end
      Cookies.check_attribute!("path", path)
      Cookies.check_attribute!("same_site", same_site)
      lowered = same_site.to_s.downcase
      return nil if lowered == "lax" || lowered == "strict" || lowered == "none"

      message = "cookie same_site must be Lax, Strict or None, not #{same_site.to_s.inspect}"
      raise ArgumentError, message
    end

    def self.check_attribute!(label, value)
      text = value.to_s
      return nil unless text.include?(";") || text.include?("\r") || text.include?("\n")

      message = "cookie #{label} must not contain ';', CR or LF"
      raise ArgumentError, message
    end

    # The cookie value as {serialize} writes it: as it is when every byte
    # is a letter, a digit or `* - . _`, percent-encoded otherwise.
    # @param text [String]
    # @return [String]
    # @api private
    def self.encoded_value(text)
      Query.plain?(text) ? text : URI.encode_www_form_component(text)
    end

    # The epoch second of {NO_EXPIRES}.
    NO_EXPIRES_EPOCH = -1

    # {serialize}'s default `expires:`, standing for "no Expires". Not nil:
    # under Spinel a parameter defaulting to nil that some caller gives a
    # plain Time is compiled as a Time, its `nil?` as false, and the
    # default call then reads a NULL Time and crashes (NOTES, the rule on
    # nil defaults; spikes/phase5/nil_default_time.rb).
    NO_EXPIRES = Time.at(NO_EXPIRES_EPOCH).utc

    # A Set-Cookie value for {Response#add_cookie}, the value
    # percent-encoded. `same_site` `"None"` and `partitioned` both require
    # `Secure` (browsers drop such a cookie without it), so either adds
    # `Secure` whatever `secure` says, and `Secure` is written once.
    # @param name [String]
    # @param value [String]
    # @param path [String]
    # @param max_age [Integer] seconds; `-1` leaves it out (a browser-session
    #   cookie), `0` deletes the cookie
    # @param http_only [Boolean]
    # @param same_site [String] `"Lax"`, `"Strict"` or `"None"`
    # @param secure [Boolean]
    # @param partitioned [Boolean] adds `Partitioned` (and `Secure`)
    # @param expires [Time, nil] adds `Expires=` with the time as an HTTP
    #   date ({Request.http_date}); nil (or leaving it out) writes none
    # @return [String]
    # @raise [ArgumentError] `name` is not an RFC 6265 token, `path` holds
    #   ";", CR or LF, or `same_site` is not Lax, Strict or None (any case)
    # @api public
    def self.serialize(name, value, path: "/", max_age: -1, http_only: true, same_site: "Lax", secure: false,
                       partitioned: false, expires: NO_EXPIRES)
      Cookies.validate!(name, path, same_site)
      # value.to_s: a String for Query.plain?'s byte reads (see Html.escape)
      out = +"#{name}=#{Cookies.encoded_value(value.to_s)}"
      out << "; Path=#{path}"
      out << "; HttpOnly" if http_only
      out << "; SameSite=#{same_site}"
      out << "; Max-Age=#{max_age}" if max_age >= 0
      out << "; Expires=#{Request.http_date(expires)}" unless expires.nil? || expires.to_i == NO_EXPIRES_EPOCH
      out << "; Secure" if secure || partitioned || same_site.downcase == "none"
      out << "; Partitioned" if partitioned
      out
    end
  end
end
