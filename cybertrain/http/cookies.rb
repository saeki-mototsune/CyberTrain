require "uri"
require "cybertrain/http/query"

module Cybertrain
  # Cookie header parsing and Set-Cookie serialization. Values round-trip
  # through the same www-form percent-encoding Query uses, so a value with
  # a space, "=" or ";" survives both directions. Unlike a query string, a
  # cookie that does not decode is NOT a client fault: SessionStore parses
  # every cookie on every request but reads only its own, so a foreign one
  # ("promo=50%off", set by another app on the parent domain) must not turn
  # every dynamic page into a 400. Its raw value is kept, as Rack does.
  #
  # Plain cookies besides the session (there is no `cookies` jar in
  # controllers, and no signed or encrypted cookie other than the session).
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
    # @return [String]
    # @api public
    def self.serialize(name, value, path: "/", max_age: -1, http_only: true, same_site: "Lax", secure: false,
                       partitioned: false)
      out = +"#{name}=#{URI.encode_www_form_component(value)}"
      out << "; Path=#{path}"
      out << "; HttpOnly" if http_only
      out << "; SameSite=#{same_site}"
      out << "; Max-Age=#{max_age}" if max_age >= 0
      out << "; Secure" if secure || partitioned || same_site == "None"
      out << "; Partitioned" if partitioned
      out
    end
  end
end
