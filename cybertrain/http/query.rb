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

  # Request text that does not decode: a percent-escape ("%zz", a lone "%")
  # or an invalid UTF-8 byte sequence ("\x81", or "%81" once decoded) in a
  # query string or form body (Cookies keep such a value raw instead).
  # Query finds the escape with its own byte scanner, not the decoder's
  # ArgumentError (CRuby only: Spinel decodes it leniently, to a NUL byte,
  # NOTES rule 28), and the bytes with String#valid_encoding? (NOTES rule 52),
  # so both are raised the same way on both runtimes. A StandardError under
  # QueryInvalid, NOT an ArgumentError (the class the decoder used to raise
  # under CRuby): app code that rescued ArgumentError around Query.parse,
  # Query.decode or request.form_params must rescue Cybertrain::QueryInvalid
  # instead (README "Differences from Rails"). The hierarchy stays as it is:
  # an ArgumentError superclass for a user class is unverified under Spinel.
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
    #
    # "Always on a character boundary" holds only for a String that is valid
    # in its encoding: after an invalid byte ("a=1&\x81b=2") CRuby's
    # String#byteindex raises IndexError ("offset 4 does not land on
    # character boundary"), which ClientError does not list (a 500, not the
    # 400 for malformed parameters), while Spinel's does not check and just
    # returns the match. So the text is validated ONCE, first thing, and an
    # invalid byte sequence is QueryMalformed (Rails: BadRequest). There is
    # no `rescue IndexError` on purpose: it would be CRuby-only behaviour
    # (NOTES rule 52). A binary (ASCII-8BIT) String is always valid, so the
    # CRuby socket buffer passes; its bytes are checked after decoding
    # (decode_valid). The segments cut out below inherit the valid
    # encoding, so add_pair and the decoder do not check them again.
    # Empty segments are still skipped, not parsed, so "a=1&&b=2" and a
    # trailing "&" give the same Params as before.
    def self.parse(str)
      params = Params.new
      s = str.to_s
      check_valid!(s)
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
    # fault in every parameter: a malformed percent-escape or an invalid
    # UTF-8 byte sequence (raw, or percent-encoded: "%81") is QueryMalformed.
    # The escapes are refused by the decoding loop itself, with one clear
    # message and the same behaviour on both runtimes, which Spinel could not
    # give otherwise (its decoder never raises, NOTES rule 28, and would put
    # NUL bytes into params while CRuby answered 400); there is no pre-scan
    # (valid_escapes? is the router's check, for its own policy). There is no
    # rescue around the library decoder either: the loop hands it only runs
    # of well-formed "%XX", which it never refuses.
    #
    # The library decoder is never handed the whole text: under Spinel
    # URI.decode_www_form_component is quadratic on a String that holds a
    # non-ASCII character (e-acute + 50 000 "a" took 517 ms, + 100 000 2.4 s,
    # + 200 000 8.5 s; 400 000 "a" + "%41%C3%A9", which is ASCII up to the
    # escapes, 11 ms; linear under CRuby, NOTES rule 49), so one 1.6 MB
    # non-ASCII key or form value hung the binary for minutes. It is decoded
    # by byte chunks in decode_valid (below), shared with the router.
    def self.decode(text)
      decode_escapes(text, true)
    end

    # Validates `text` (once) and decodes it. The entry point for text that
    # has not been through Query.parse: decode, Cookies and Router.split_path.
    # An invalid byte sequence is QueryMalformed before any byte offset is
    # used, because those offsets are only character boundaries in a valid
    # String (see parse, NOTES rule 52). With plus_is_space a "+" is a space
    # (query strings, forms, cookies); without it a "+" stays a plus (a path
    # segment). A malformed escape is QueryMalformed too (decode_valid).
    def self.decode_escapes(text, plus_is_space)
      check_valid!(text)
      decode_valid(text, plus_is_space)
    end

    # The one chunked decoding loop. The caller guarantees
    # text.valid_encoding? (Query.parse checked the whole body, decode_escapes
    # checks its text), so the offsets below are character boundaries. It
    # refuses a malformed escape whatever its caller checked: a "%" counts as
    # an escape only when two hex digits follow it, otherwise QueryMalformed
    # is raised right there. The RESULT is checked once, at the end: a
    # percent-encoded invalid sequence ("%81", "%C3") decodes to bytes that
    # are not UTF-8, and under CRuby a binary input with a raw invalid byte
    # and no escapes comes out as an invalid UTF-8 String (utf8_text). Two
    # entry points over one loop (decode_escapes, add_pair), and no block, so
    # it is a plain method (NOTES rule 32).
    #
    # The stretches between the specials are copied with byteslice, the
    # decoder sees only each maximal run of consecutive "%XX" escapes, which
    # is pure ASCII and as short as the run (a percent-encoded multibyte
    # character is one run, so it still decodes as a unit), and a "+" is
    # appended as " " right here: a gsub over the whole text would be one
    # more library String op that nothing has measured on a 10 MB non-ASCII
    # value under Spinel (does a String-pattern gsub scan by character
    # offset? rules 27/49 are why the rest of this loop does not ask). Text
    # with neither special is copied whole by the final append.
    # Offsets are bytes, as in parse and split_key (NOTES rule 27): each is a
    # "%", a "+", or just after two hex digits of an escape that was checked
    # here, so always on a character boundary of a valid String. The next "%"
    # and the next "+" are each searched for once per use (a run holds only
    # "%" and hex digits, so the cached "+" offset is never behind `pos` after
    # it), so the whole decode is O(bytes). -1 means none, a typed sentinel
    # rather than nil (NOTES rule 11).
    def self.decode_valid(text, plus_is_space)
      pct = next_byte(text, "%", 0)
      plus = plus_is_space ? next_byte(text, "+", 0) : -1
      n = text.bytesize
      out = +""
      pos = 0
      while pct >= 0 || plus >= 0
        if pct >= 0 && (plus < 0 || pct < plus)
          out << utf8_text(text.byteslice(pos, pct - pos).to_s)
          j = pct
          while j + 2 < n && text.getbyte(j) == 37 && hex_byte?(text.getbyte(j + 1).to_i) && hex_byte?(text.getbyte(j + 2).to_i)
            j += 3
          end
          # The run ended at a "%" that is not followed by two hex digits
          # (fewer than two bytes left, or a non-hex byte: "%4", "%zz",
          # "%+1ab"). Walking past it as if it were an escape put `pos` ahead
          # of the cached "+" offset ("%+1ab": plus 1, pos 3), so the next
          # byteslice got a negative length, returned nil and utf8_text
          # raised FrozenError; with fewer than two bytes left it consumed
          # nothing and looped forever on ("%4", false). A plain raise, no
          # rescue (NOTES rule 32).
          raise QueryMalformed, "malformed percent-encoding in request parameters" if j < n && text.getbyte(j) == 37
          out << URI.decode_www_form_component(text.byteslice(pct, j - pct).to_s)
          pos = j
          pct = next_byte(text, "%", pos)
        else
          out << utf8_text(text.byteslice(pos, plus - pos).to_s)
          out << " "
          pos = plus + 1
          plus = next_byte(text, "+", pos)
        end
      end
      out << utf8_text(text.byteslice(pos, n - pos).to_s)
      check_valid!(out)
      out
    end

    # QueryMalformed unless `text` is valid in its encoding (nil otherwise).
    # The one fixed message, never the raw text. Under CRuby a binary
    # (ASCII-8BIT) String is always valid; under Spinel every String is
    # UTF-8, so there this is the real check (valid_encoding? agrees with
    # CRuby, NOTES rule 52).
    def self.check_valid!(text)
      raise QueryMalformed, "invalid byte sequence in request parameters" unless text.valid_encoding?

      nil
    end

    # The byte offset of the next `needle` (one ASCII character) at or after
    # `from`, or -1: byteindex's nil as a typed Integer (NOTES rule 11).
    def self.next_byte(text, needle, from)
      i = text.byteindex(needle, from)
      i.nil? ? -1 : i
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
    # so it is on a character boundary as long as `text` is valid in its
    # encoding, and ONLY then: on "%41\x81" CRuby's byteindex raises
    # IndexError for the offset of the stray byte, so the caller validates
    # first (check_valid!; Router.split_path does, before it asks).
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

    # One non-empty "k=v" (or bare "k") pair into the tree. The segment was
    # cut out of a body that Query.parse validated, so it is valid UTF-8 and
    # goes straight to decode_valid (no second check on the input; each
    # decoded result is still checked there).
    def self.add_pair(params, pair)
      eq = pair.index("=")
      if eq.nil?
        raw_key = pair
        raw_value = ""
      else
        raw_key = pair[0, eq]
        raw_value = pair[(eq + 1)..-1].to_s
      end

      key = decode_valid(raw_key, true)
      value = decode_valid(raw_value, true)
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
    # "]" is ASCII, so each offset is 0 or on one of them. The key is valid
    # UTF-8 (parse and decode_valid guarantee it; byteindex refuses an offset
    # inside a character of an invalid String, NOTES rule 52), so each such
    # offset is a character boundary: a multibyte part is never split.
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
