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

    # The one place request text is percent-decoded (query strings, form
    # bodies and the Cookie header), so malformed input is the same client
    # fault everywhere. A plain method with one begin/rescue and no block
    # (NOTES rule 32 is about yielding methods).
    def self.decode(text)
      URI.decode_www_form_component(text)
    rescue ArgumentError
      # The client's fault (a 400 through ClientError), not the app's. The
      # decoder's message is not repeated: it embeds the raw text, newlines
      # included, and would let a form body forge log lines (Logger writes
      # the line as is) and echo itself into the dev page's 400 body.
      raise Malformed, "malformed percent-encoding in request parameters"
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

      key = decode(raw_key)
      value = decode(raw_value)
      params.set_path(split_key(key), value)
      nil
    end

    # "post[tags][]" -> ["post", "tags", ""]; "id" -> ["id"]. A "[" with no
    # matching "]" (or any other malformed bracket run) is not a nesting
    # marker at all -- the whole string is returned as one plain key, however
    # many pairs precede the malformed tail -- unless the key already holds
    # more than MAX_DEPTH well-formed pairs before it: that is TooDeep
    # whatever follows (the key is refused as soon as the (MAX_DEPTH + 1)th
    # pair is seen, so a malformed tail after it is never looked at).
    #
    # Two cursor passes. The first only counts the pairs and checks the shape,
    # allocating nothing, and stops at the (MAX_DEPTH + 1)th pair, so it scans
    # at most MAX_DEPTH + 1 pairs however long the key is. That bound matters
    # beyond the Strings: `key[pos]` and `key.index("]", pos)` take character
    # offsets, which a UTF-8 string resolves with an O(pos) scan once it has a
    # non-ASCII character, so an unbounded pass over a key like "k" + e-acute
    # + "[][][]..." (a megabyte of pairs, parsed up to three times per
    # request) was quadratic. The second pass slices only a key that passed,
    # so it is at most MAX_DEPTH pairs too.
    def self.split_key(key)
      first_bracket = key.index("[")
      return [key] if first_bracket.nil?

      len = key.length
      count = 0
      pos = first_bracket
      while pos < len
        return [key] unless key[pos] == "["

        close = key.index("]", pos)
        return [key] if close.nil?

        count += 1
        raise TooDeep, "parameter nesting too deep (limit #{MAX_DEPTH})" if count > MAX_DEPTH

        pos = close + 1
      end

      parts = [key[0, first_bracket]]
      pos = first_bracket
      while pos < len
        close = key.index("]", pos)
        break if close.nil? # cannot happen: the first pass saw every "]"

        parts << key[pos + 1, close - pos - 1].to_s
        pos = close + 1
      end
      parts
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
