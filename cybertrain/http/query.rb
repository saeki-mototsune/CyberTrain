require "uri"
require "cybertrain/params"

module Cybertrain
  # Raised for request parameters the server will not take: past one of
  # Query's limits (QueryLimitExceeded: QueryTooDeep, QueryTooMany) or not
  # decodable (QueryMalformed). StandardErrors on purpose: ClientError turns
  # them into a 400 at info level instead of a 500 at error level, so a
  # scanner's junk does not fill the error log or kill the connection
  # thread. In Cybertrain (like Rejected, RecordNotFound, MissingTemplate)
  # and prefixed Query, not Query::Invalid / Query::TooMany: Class#name
  # carries no namespace under Spinel (NOTES rule 46), so a bare "Invalid" or
  # "TooMany" there is indistinguishable from an app's own Billing::Invalid or
  # RateLimiter::TooMany. The bare names here are unique, which is what lets
  # ClientError tell a framework client fault from an app class by name alone.
  # Not called Rejected: Cybertrain::Rejected is the Server's own
  # status-carrying error.
  class QueryInvalid < StandardError
  end

  class QueryLimitExceeded < QueryInvalid
  end

  class QueryTooDeep < QueryLimitExceeded
  end

  class QueryTooMany < QueryLimitExceeded
  end

  # A percent-escape that does not decode ("%zz", a lone "%") in a query
  # string or form body (Cookies keep such a value raw instead). Query.decode
  # finds it with its own byte scanner, not the decoder's ArgumentError
  # (CRuby only: Spinel decodes it leniently, to a NUL byte, NOTES rule 28),
  # so it is raised the same way on both runtimes.
  class QueryMalformed < QueryInvalid
  end

  # Decoding/encoding for query strings and x-www-form-urlencoded bodies:
  # "a=1&b[]=2&b[]=3&post[title]=hi&flag" -> a Params tree.
  module Query
    # Hard limits, taken from Rack. Every request is parsed before any auth or
    # CSRF check (MethodOverride, Router), so a hostile query string or form
    # body must cost bounded work and bounded stack.
    MAX_DEPTH = 32   # bracket pairs in one key: "a[b][c]" is depth 2
    MAX_PAIRS = 4096 # "&"-delimited segments in one parse, empty ones included

    # A cursor scan, like split_key: the segments are cut out one at a time
    # and QueryTooMany is raised as soon as the (MAX_PAIRS + 1)th segment starts,
    # so a hostile body costs O(MAX_PAIRS) calls however long it is.
    # (`split("&")` would first materialise every pair of a 10 MB body of
    # "&", three times per request.) EVERY segment counts, an empty one
    # ("a=1&&b=2") included: a body of one e-acute and 200 000 "&" that
    # skipped its empty segments uncounted never reached QueryTooMany.
    # Counting them caps the calls at MAX_PAIRS + 1, but each call must also
    # be cheap, or the cap is only on the count: `s.index("&", pos)` and
    # `s[pos, n]` take character offsets, an O(pos) scan once the string has a
    # non-ASCII character (always, under Spinel, which indexes by character),
    # so 4000 segments of 2.5 KB after one e-acute scanned ~5 MB each (18 s on
    # CRuby for a 10 MB body). So the offsets here are bytes: byteindex,
    # byteslice and bytesize are O(1) to position and O(segment) to cut, and
    # Server#serve already frames its socket buffer with them under Spinel
    # (NOTES rule 27). Every offset is 0 or just after an ASCII "&", so it is
    # always on a character boundary and a multibyte value is never split.
    # `str` may be ASCII-8BIT (a socket buffer under CRuby) or UTF-8 (Spinel);
    # the byte methods give the same answers on both. add_pair then works on
    # one segment only, so the whole parse is O(body) + O(MAX_PAIRS).
    # Empty segments are still skipped, not parsed, so "a=1&&b=2" and a
    # trailing "&" give the same Params as before.
    def self.parse(str)
      params = Params.new
      s = str.to_s
      len = s.bytesize
      count = 0
      pos = 0
      while pos < len
        amp = s.byteindex("&", pos)
        stop = amp.nil? ? len : amp
        count += 1
        raise QueryTooMany, "too many parameters (limit #{MAX_PAIRS})" if count > MAX_PAIRS

        add_pair(params, s.byteslice(pos, stop - pos).to_s) if stop > pos
        pos = stop + 1
      end
      params
    end

    # The one place request text is percent-decoded (query strings and form
    # bodies; Cookies.decode wraps it, because a cookie the app does not own
    # must not fail the request), so malformed input is the same client
    # fault in every parameter. The escapes are checked first, by
    # valid_escapes?, because that is the only check Spinel has: its decoder
    # never raises (NOTES rule 28), so relying on the ArgumentError alone
    # would put NUL bytes into params there while CRuby answered 400. The
    # rescue stays as a second net for anything else the decoder refuses.
    # A plain method with one begin/rescue and no block (NOTES rule 32 is
    # about yielding methods).
    #
    # The library decoder is never handed the whole text: under Spinel
    # URI.decode_www_form_component is quadratic on a String that holds a
    # non-ASCII character (e-acute + 50 000 "a" took 517 ms, + 100 000 2.4 s,
    # + 200 000 8.5 s; 400 000 "a" + "%41%C3%A9", which is ASCII up to the
    # escapes, 11 ms; linear under CRuby, NOTES rule 49), so one 1.6 MB
    # non-ASCII key or form value hung the binary for minutes. So the text is
    # decoded by byte chunks: the stretches between escapes are copied with
    # byteslice, and the decoder sees only each maximal run of consecutive
    # "%XX" escapes, which is pure ASCII and as short as the run (a percent-
    # encoded multibyte character is one run, so it still decodes as a unit).
    # "+" is turned into a space first (gsub with a String pattern: the
    # pattern is compiled elsewhere, router.rb), which also leaves nothing
    # for the decoder to do but the escapes. Text without "%" is returned
    # as it is.
    # Offsets are bytes, as in parse and split_key (NOTES rule 27): each is a
    # "%" or just after two hex digits of a valid escape (valid_escapes?
    # guarantees two bytes follow every "%", so `j + 2 < n` below never
    # drops a final escape: "%41" has n = 3, j = 0), so always on a character
    # boundary. O(bytes) overall.
    def self.decode(text)
      raise QueryMalformed, "malformed percent-encoding in request parameters" unless valid_escapes?(text)

      plus = text.index("+").nil? ? text : text.gsub("+", " ")
      i = plus.byteindex("%")
      return utf8_text(plus.dup) if i.nil?

      n = plus.bytesize
      out = +""
      pos = 0
      while !i.nil?
        out << utf8_text(plus.byteslice(pos, i - pos).to_s)
        j = i
        while j + 2 < n && plus.getbyte(j) == 37
          j += 3
        end
        out << URI.decode_www_form_component(plus.byteslice(i, j - i).to_s)
        pos = j
        i = plus.byteindex("%", pos)
      end
      out << utf8_text(plus.byteslice(pos, n - pos).to_s)
      out
    rescue ArgumentError
      # The client's fault (a 400 through ClientError), not the app's. The
      # decoder's message is not repeated: it embeds the raw text, newlines
      # included, and would let a form body forge log lines (Logger writes
      # the line as is) and echo itself into the dev page's 400 body.
      raise QueryMalformed, "malformed percent-encoding in request parameters"
    end

    # `s` tagged as UTF-8, in place (a no-op for the Spinel runtime, whose
    # Strings are all UTF-8). The decoder always answered UTF-8, but a
    # socket buffer under CRuby is ASCII-8BIT (NOTES rule 27), and the pieces
    # decode copies out of it would then not mix with the decoder's UTF-8 in
    # `out` (Encoding::CompatibilityError on "e-acute%41"-style text). Only
    # ever called on a fresh String (byteslice or dup), never on the caller's.
    def self.utf8_text(s)
      s.force_encoding("UTF-8")
    end

    # True when every "%" in `text` is followed by two hex digits. A byte
    # scan, so it answers the same on CRuby and Spinel (the decoder does not,
    # NOTES rule 28) and costs O(bytes) whatever the encoding; it jumps from
    # one "%" to the next with byteindex, so text without escapes is one C
    # scan. Every offset it uses is a "%" or just after two ASCII hex digits,
    # so it is always on a character boundary. Router.split_path asks too.
    def self.valid_escapes?(text)
      n = text.bytesize
      i = text.byteindex("%")
      while !i.nil?
        return false if i + 2 >= n
        return false unless hex_byte?(text.getbyte(i + 1).to_i) && hex_byte?(text.getbyte(i + 2).to_i)

        i = text.byteindex("%", i + 3)
      end
      true
    end

    # 0-9, A-F, a-f as a byte value.
    def self.hex_byte?(b)
      (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
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
    # more than MAX_DEPTH well-formed pairs before it: that is QueryTooDeep
    # whatever follows (the key is refused as soon as the (MAX_DEPTH + 1)th
    # pair is seen, so a malformed tail after it is never looked at).
    #
    # One cursor loop that cuts each pair out as it validates it, so it runs
    # at most MAX_DEPTH + 1 times however long the key is, and allocates only
    # the (at most MAX_DEPTH + 1) parts. The offsets are bytes (getbyte,
    # byteindex, byteslice, bytesize; parse does the same, NOTES rule 27):
    # `key[pos]` and `key.index("]", pos)` take character offsets, which a
    # UTF-8 string resolves with an O(pos) scan once it holds one non-ASCII
    # character, so a key like e-acute + ("[" + 300 000 "a" + "]") * 32 cost
    # 0.47 s per parse, three times per request, for 32 pairs. Every "[" and
    # "]" is ASCII, so each offset is 0 or on one of them and always on a
    # character boundary: a multibyte part is never split.
    def self.split_key(key)
      first_bracket = key.byteindex("[")
      return [key] if first_bracket.nil?

      len = key.bytesize
      parts = [key.byteslice(0, first_bracket).to_s]
      pos = first_bracket
      while pos < len
        return [key] unless key.getbyte(pos) == 91 # "["

        close = key.byteindex("]", pos)
        return [key] if close.nil?

        raise QueryTooDeep, "parameter nesting too deep (limit #{MAX_DEPTH})" if parts.length > MAX_DEPTH

        parts << key.byteslice(pos + 1, close - pos - 1).to_s
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
