require "uri"
require "cybertrain/params"

module Cybertrain
  # Decoding/encoding for query strings and x-www-form-urlencoded bodies:
  # "a=1&b[]=2&b[]=3&post[title]=hi&flag" -> a Params tree.
  module Query
    def self.parse(str)
      params = Params.new
      str.to_s.split("&").each do |pair|
        next if pair.empty?

        eq = pair.index("=")
        if eq.nil?
          raw_key = pair
          raw_value = ""
        else
          raw_key = pair[0, eq]
          raw_value = pair[(eq + 1)..-1].to_s
        end

        key = URI.decode_www_form_component(raw_key)
        value = URI.decode_www_form_component(raw_value)
        params.set_path(split_key(key), value)
      end
      params
    end

    # "post[tags][]" -> ["post", "tags", ""]; "id" -> ["id"]. A "[" with no
    # matching "]" (or any other malformed bracket run) is not a nesting
    # marker at all -- the whole string is returned as one plain key.
    def self.split_key(key)
      first_bracket = key.index("[")
      return [key] if first_bracket.nil?

      base = key[0, first_bracket]
      rest = key[first_bracket..-1].to_s
      parts = []

      while rest.length > 0
        return [key] unless rest[0] == "["

        close = rest.index("]")
        return [key] if close.nil?

        parts << rest[1, close - 1]
        rest = rest[(close + 1)..-1].to_s
      end

      [base] + parts
    end

    def self.encode(pairs)
      parts = []
      pairs.each do |k, v|
        parts << "#{URI.encode_www_form_component(k)}=#{URI.encode_www_form_component(v)}"
      end
      parts.join("&")
    end
  end
end
