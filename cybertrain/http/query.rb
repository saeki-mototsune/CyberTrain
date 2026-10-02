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

    # Raised for request parameters the server will not take: past a limit
    # above (LimitExceeded: TooDeep, TooMany) or not decodable (Malformed).
    # StandardErrors on purpose: ClientError turns them into a 400 at info
    # level instead of a 500 at error level, so a scanner's junk does not
    # fill the error log or kill the connection thread. Not called Rejected:
    # Cybertrain::Rejected is the Server's own status-carrying error, and
    # Class#name carries no namespace under Spinel (NOTES rule 46), so the
    # two would be indistinguishable in a log line.
    class Invalid < StandardError
    end

    class LimitExceeded < Invalid
    end

    class TooDeep < LimitExceeded
    end

    class TooMany < LimitExceeded
    end

    # A percent-escape that does not decode ("%zz", a lone "%"). CRuby's
    # decoder raises ArgumentError for it; Spinel's decodes it leniently
    # (test/query.rb), so under Spinel this is never raised.
    class Malformed < Invalid
    end

    # A cursor scan, like split_key: the pairs are cut out one at a time and
    # TooMany is raised as soon as the (MAX_PAIRS + 1)th non-empty pair
    # starts, so a hostile body costs O(MAX_PAIRS) work however long it is.
    # (`split("&")` would first materialise every pair of a 10 MB body of
    # "&", three times per request.) Empty pairs ("a=1&&b=2", a trailing
    # "&") are skipped and not counted, as before.
    def self.parse(str)
      params = Params.new
      s = str.to_s
      len = s.length
      count = 0
      pos = 0
      while pos < len
        amp = s.index("&", pos)
        stop = amp.nil? ? len : amp
        if stop > pos
          count += 1
          raise TooMany, "too many parameters (limit #{MAX_PAIRS})" if count > MAX_PAIRS

          add_pair(params, s[pos, stop - pos])
        end
        pos = stop + 1
      end
      params
    end

    # One non-empty "k=v" (or bare "k") pair into the tree.
    def self.add_pair(params, pair)
      eq = pair.index("=")
      if eq.nil?
        raw_key = pair
        raw_value = ""
      else
        raw_key = pair[0, eq]
        raw_value = pair[(eq + 1)..-1].to_s
      end

      key = ""
      value = ""
      begin
        key = URI.decode_www_form_component(raw_key)
        value = URI.decode_www_form_component(raw_value)
      rescue ArgumentError => e
        # The client's fault (a 400 through ClientError), not the app's.
        raise Malformed, "malformed percent-encoding in request parameters: #{e.message}"
      end
      params.set_path(split_key(key), value)
      nil
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
