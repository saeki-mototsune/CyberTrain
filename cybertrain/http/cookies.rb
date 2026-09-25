require "uri"

module Cybertrain
  # Cookie header parsing and Set-Cookie serialization. Values round-trip
  # through the same www-form percent-encoding Query uses, so a value with
  # a space, "=" or ";" survives both directions.
  module Cookies
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
        cookies[name] = URI.decode_www_form_component(value)
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
