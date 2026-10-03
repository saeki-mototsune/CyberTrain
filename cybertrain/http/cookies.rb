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
  module Cookies
    # Query.decode, falling back to the raw text when it raises QueryMalformed
    # (on both runtimes: Query.decode checks the escapes itself, because
    # Spinel's decoder is lenient, NOTES rule 28). A plain non-yielding
    # method with one rescue clause by class: fine under Spinel (NOTES rules
    # 32, 47).
    def self.decode(value)
      Query.decode(value)
    rescue QueryMalformed
      value
    end

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

    def self.serialize(name, value, path: "/", max_age: -1, http_only: true, same_site: "Lax", secure: false)
      out = +"#{name}=#{URI.encode_www_form_component(value)}"
      out << "; Path=#{path}"
      out << "; HttpOnly" if http_only
      out << "; SameSite=#{same_site}"
      out << "; Max-Age=#{max_age}" if max_age >= 0
      out << "; Secure" if secure
      out
    end
  end
end
