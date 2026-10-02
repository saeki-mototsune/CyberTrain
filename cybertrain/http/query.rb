require "uri"
require "cybertrain/params"

module Cybertrain
  # Decoding/encoding for query strings and x-www-form-urlencoded bodies:
  # "a=1&b[]=2&b[]=3&post[title]=hi&flag" -> a Params tree.
  module Query
    # Hard limits, taken from Rack. Every request is parsed before any auth or
    # CSRF check (MethodOverride, Router), so a hostile query string or form
    # body must cost bounded work and bounded stack.
    MAX_DEPTH = 32   # bracket pairs in one key: "a[b][c]" is depth 2
    MAX_PAIRS = 4096 # non-empty "k=v" pairs in one parse

    # Raised for input that exceeds a limit above. A StandardError on purpose:
    # the error pages (and Server#respond for a bare app) turn it into a 400
    # instead of letting it kill the connection thread. Not called Rejected:
    # Cybertrain::Rejected is the Server's own status-carrying error, and
    # Class#name carries no namespace under Spinel (NOTES rule 46), so the
    # two would be indistinguishable in a log line.
    class LimitExceeded < StandardError
    end

    class TooDeep < LimitExceeded
    end

    class TooMany < LimitExceeded
    end

    def self.parse(str)
      params = Params.new
      pairs = str.to_s.split("&")
      count = 0
      pairs.each do |pair|
        next if pair.empty?

        count = count + 1
        raise TooMany, "too many parameters (limit #{MAX_PAIRS})" if count > MAX_PAIRS

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
    # marker at all -- the whole string is returned as one plain key, however
    # many pairs precede the malformed tail. A well-formed key with more than
    # MAX_DEPTH bracket pairs raises TooDeep, once the scan is complete.
    #
    # Scans with a cursor into key instead of re-slicing the remainder after
    # every pair, so the work is linear in the key length either way.
    def self.split_key(key)
      first_bracket = key.index("[")
      return [key] if first_bracket.nil?

      base = key[0, first_bracket]
      parts = []
      pos = first_bracket

      while pos < key.length
        return [key] unless key[pos] == "["

        close = key.index("]", pos)
        return [key] if close.nil?

        parts << key[pos + 1, close - pos - 1].to_s
        pos = close + 1
      end
      raise TooDeep, "parameter nesting too deep (limit #{MAX_DEPTH})" if parts.length > MAX_DEPTH

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
