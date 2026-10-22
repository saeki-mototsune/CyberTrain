# Cybertrain::UploadedFile -- one file from a multipart/form-data request.
#
# Loads standalone (it needs only `digest`), so Params and the multipart
# parser in cybertrain/http/ can refer to it without pulling in the rest of
# the framework (script/check-http-layer).
#
# Everything the client sends about a file is untrusted: the filename and the
# part Content-Type are kept for display only. What the bytes are is decided
# by {UploadedFile#detected_content_type}, which looks at the magic numbers
# and never decodes the file, so there is no image-parser attack surface here.
#
# All of the byte work below is byte loops over getbyte/byteslice. Under
# Spinel a String is a character string (NOTES rule 27), a String built by
# appending `n.chr` stays tagged UTF-8 and is invalid for bytes >= 0x80, and
# regexps are avoided on anything that can hold arbitrary bytes (rule 49), so
# results are only ever built by appending byteslices of the input or of a
# literal table into a `+""` buffer.
require "digest"

module Cybertrain
  # An uploaded file, immutable once built. Get one from
  # `params.nested(:post).upload(:cover)`; it is never put in `permit`'s
  # result, so mass assignment cannot attach a file.
  #
  # The names `UploadedFile`, `Multipart` and `BlobStore` are reserved: an app
  # class must not reuse them (class names are global under Spinel).
  # @example in a controller
  #   file = params.nested(:post).upload(:cover)
  #   if file && !file.empty? && file.image?
  #     File.binwrite("tmp/cover", file.body_bytes)
  #   end
  # @api public
  class UploadedFile
    # The only detected types that may be shown inline in a browser. SVG and
    # HTML are never detected, so they can never be on this list.
    INLINE_SAFE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    # The longest display name kept, in bytes (a file system limit).
    MAX_FILENAME_BYTES = 255
    # What a type is reported as when no signature matches.
    UNKNOWN_TYPE = "application/octet-stream"
    # What an unusable filename becomes.
    FALLBACK_FILENAME = "upload"
    UPPER_HEX = "0123456789ABCDEF"

    # @param name [String] the sanitized display name (the parser has already
    #   applied {UploadedFile.sanitize_filename})
    # @param declared [String] the client's part Content-Type media type,
    #   lowercased, "" when absent or invalid (UNTRUSTED)
    # @param data [String] the file's bytes (ASCII-8BIT)
    def initialize(name, declared, data)
      @original_filename = name
      @declared_content_type = declared
      @body_bytes = data
      @detected = ""   # lazy; "" sentinel (NOTES rules 7/11)
      @sha256 = ""     # lazy
    end

    # The sentinel for "no file": empty name, type and body. Params#upload
    # style code compares with `empty?`, not nil (NOTES rules 7/11).
    # @return [UploadedFile]
    # @api public
    def self.blank
      name = ""
      declared = ""
      data = "".b
      UploadedFile.new(name, declared, data)
    end

    # The client's filename, sanitized. For display only: it is NEVER a path.
    # @return [String]
    # @api public
    def original_filename
      @original_filename
    end

    # The client's part Content-Type (media type only, lowercased, "" when
    # absent). Informational only: the client chooses it, so decisions use
    # {#detected_content_type}.
    # @return [String]
    # @api public
    def declared_content_type
      @declared_content_type
    end

    # The file's bytes, as an ASCII-8BIT String. Compare with `a.b == b.b`,
    # `bytesize` or {#sha256_hex}, not `==` on the raw value (NOTES rule 27).
    # @return [String]
    # @api public
    def body_bytes
      @body_bytes
    end

    # @return [Integer] the size in bytes
    # @api public
    def byte_size
      @body_bytes.bytesize
    end

    # @return [Boolean] true for a zero-byte file (and for {UploadedFile.blank})
    # @api public
    def empty?
      @body_bytes.bytesize == 0
    end

    # The type decided from the file's own bytes (see {UploadedFile.sniff}),
    # computed once. "application/octet-stream" when nothing matches.
    # @return [String]
    # @api public
    def detected_content_type
      d = @detected
      return d unless d.empty?

      d = UploadedFile.sniff(@body_bytes)
      @detected = d
      d
    end

    # @return [Boolean] true when the detected type is one of
    #   {INLINE_SAFE_TYPES}: PNG, JPEG, GIF or WebP
    # @api public
    def image?
      UploadedFile.inline_safe?(detected_content_type)
    end

    # The lowercase hex SHA-256 of the bytes, computed once.
    # @return [String] 64 hex characters
    # @api public
    def sha256_hex
      h = @sha256
      return h unless h.empty?

      h = Digest::SHA256.hexdigest(@body_bytes)
      @sha256 = h
      h
    end

    # Name and size only. Never the bytes: this is what ends up in logs and
    # in `Params#inspect`.
    # @return [String]
    # @api public
    def inspect
      "#<Cybertrain::UploadedFile #{@original_filename.inspect} #{@body_bytes.bytesize} bytes>"
    end

    # Same as {#inspect}.
    # @return [String]
    # @api public
    def to_s
      inspect
    end

    # The type of a file from its leading bytes. Only PNG, JPEG, GIF, WebP and
    # PDF are recognised; SVG, HTML, XML and scripts are never reported as
    # such (they come back as "application/octet-stream"), so a sniffed type
    # cannot be turned into an executable one. Input shorter than a signature
    # simply does not match.
    # @param data [String] the bytes (any encoding; only getbyte is used)
    # @return [String] a media type
    # @api public
    def self.sniff(data)
      n = data.bytesize
      # 89 50 4E 47 0D 0A 1A 0A, as integers: no binary literal to build.
      return "image/png" if n >= 8 && data.getbyte(0) == 0x89 && data.getbyte(1) == 0x50 && data.getbyte(2) == 0x4E && data.getbyte(3) == 0x47 && data.getbyte(4) == 0x0D && data.getbyte(5) == 0x0A && data.getbyte(6) == 0x1A && data.getbyte(7) == 0x0A
      return "image/jpeg" if n >= 3 && data.getbyte(0) == 0xFF && data.getbyte(1) == 0xD8 && data.getbyte(2) == 0xFF
      return "image/gif" if n >= 6 && (UploadedFile.bytes_at?(data, 0, "GIF87a") || UploadedFile.bytes_at?(data, 0, "GIF89a"))
      return "image/webp" if n >= 12 && UploadedFile.bytes_at?(data, 0, "RIFF") && UploadedFile.bytes_at?(data, 8, "WEBP")
      return "application/pdf" if n >= 5 && UploadedFile.bytes_at?(data, 0, "%PDF-")

      UNKNOWN_TYPE
    end

    # Whether `data` has the bytes of the ASCII/binary literal `want` at
    # `offset`. A byte loop: `==` on binary data is not reliable under
    # Spinel (NOTES rule 27). The caller has checked the length.
    # @api private
    def self.bytes_at?(data, offset, want)
      i = 0
      n = want.bytesize
      while i < n
        return false if data.getbyte(offset + i) != want.getbyte(i)
        i += 1
      end
      true
    end

    # Exact match against {INLINE_SAFE_TYPES} (no parameters, no case folding).
    # @param type [String]
    # @return [Boolean]
    # @api public
    def self.inline_safe?(type)
      INLINE_SAFE_TYPES.include?(type)
    end

    # A display filename from whatever the client sent. The result is never
    # a path and holds nothing that is dangerous in a header or a page:
    #
    # - everything up to the last "/" or "\" is dropped (a traversal prefix
    #   or a Windows path);
    # - control bytes, DEL and the characters `" < > : * ? |` are dropped;
    # - bidi controls and zero-width characters (U+200B-U+200F, U+202A-U+202E,
    #   U+2066-U+2069, U+FEFF) are dropped, so a name cannot display reversed;
    # - leading and trailing dots and spaces are stripped;
    # - it is cut to 255 bytes on a character boundary;
    # - a result that is empty or not valid UTF-8 becomes "upload".
    # @param raw [String]
    # @return [String]
    # @api public
    def self.sanitize_filename(raw)
      s = raw.dup.force_encoding("UTF-8")
      n = s.bytesize
      # 1. Everything after the last separator.
      start = 0
      i = 0
      while i < n
        b = s.getbyte(i)
        start = i + 1 if b == 0x2F || b == 0x5C
        i += 1
      end
      # 2. Copy runs of kept bytes; skip the dropped ones.
      out = +""
      run = start
      i = start
      while i < n
        skip = UploadedFile.dropped_length(s, i, n)
        if skip == 0
          i += 1
        else
          out << s.byteslice(run, i - run) if i > run
          i += skip
          run = i
        end
      end
      out << s.byteslice(run, i - run) if i > run
      # 3. Strip leading and trailing dots and spaces. 4. Cut to the limit.
      out = UploadedFile.trim_dots(out)
      if out.bytesize > MAX_FILENAME_BYTES
        cut = MAX_FILENAME_BYTES
        cut -= 1 while cut > 0 && (out.getbyte(cut) & 0xC0) == 0x80
        out = UploadedFile.trim_dots(out.byteslice(0, cut))
      end
      out.force_encoding("UTF-8")
      return FALLBACK_FILENAME if out.bytesize == 0 || !out.valid_encoding?

      out
    end

    # How many bytes at `i` are a dropped character: 0 when the byte is kept,
    # else the length of the byte or UTF-8 sequence to skip.
    # @api private
    def self.dropped_length(s, i, n)
      b = s.getbyte(i)
      return 1 if b < 0x20 || b == 0x7F
      # " < > : * ? |
      return 1 if b == 0x22 || b == 0x3C || b == 0x3E || b == 0x3A || b == 0x2A || b == 0x3F || b == 0x7C
      if b == 0xE2 && i + 2 < n
        b1 = s.getbyte(i + 1)
        b2 = s.getbyte(i + 2)
        return 3 if b1 == 0x80 && ((b2 >= 0x8B && b2 <= 0x8F) || (b2 >= 0xAA && b2 <= 0xAE))
        return 3 if b1 == 0x81 && b2 >= 0xA6 && b2 <= 0xA9
      elsif b == 0xEF && i + 2 < n
        return 3 if s.getbyte(i + 1) == 0xBB && s.getbyte(i + 2) == 0xBF
      end
      0
    end

    # `s` without leading and trailing "." and " " bytes.
    # @api private
    def self.trim_dots(s)
      n = s.bytesize
      first = 0
      while first < n && (s.getbyte(first) == 0x2E || s.getbyte(first) == 0x20)
        first += 1
      end
      last = n
      while last > first && (s.getbyte(last - 1) == 0x2E || s.getbyte(last - 1) == 0x20)
        last -= 1
      end
      return s if first == 0 && last == n

      s.byteslice(first, last - first)
    end

    # The media type of a part's Content-Type header, or "" when it is not a
    # plain `type/subtype`: parameters (after ";") are cut, surrounding
    # whitespace is trimmed, the rest is lowercased, and it must be 1 to 127
    # bytes of `[a-z0-9!#$&^_.+-]` around exactly one "/" with something on
    # both sides. Informational only (see {#declared_content_type}).
    # @param raw [String]
    # @return [String]
    # @api public
    def self.sanitize_type(raw)
      n = raw.bytesize
      i = 0
      while i < n && (raw.getbyte(i) == 0x20 || raw.getbyte(i) == 0x09)
        i += 1
      end
      first = i
      slashes = 0
      slash_at = -1
      last = first   # one past the last byte that is not trailing whitespace
      while i < n
        b = raw.getbyte(i)
        break if b == 0x3B
        if b == 0x20 || b == 0x09
          i += 1
          next
        end
        if b >= 0x41 && b <= 0x5A
          b += 32
        end
        if b == 0x2F
          slashes += 1
          slash_at = i
        elsif !UploadedFile.type_byte?(b)
          return ""
        end
        i += 1
        last = i
      end
      len = last - first
      return "" if len < 3 || len > 127 || slashes != 1
      return "" if slash_at == first || slash_at == last - 1
      # Whitespace inside the type ("image /png") is a malformed value.
      j = first
      while j < last
        bj = raw.getbyte(j)
        return "" if bj == 0x20 || bj == 0x09
        j += 1
      end
      raw.byteslice(first, len).downcase
    end

    # A byte allowed in a media type besides "/".
    # @api private
    def self.type_byte?(b)
      return true if (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
      # ! # $ & ^ _ . + -
      b == 0x21 || b == 0x23 || b == 0x24 || b == 0x26 || b == 0x5E || b == 0x5F || b == 0x2E || b == 0x2B || b == 0x2D
    end

    # A Content-Disposition header value for a download, ASCII only (the
    # response is assembled with a binary body, and CRuby refuses to join a
    # non-ASCII UTF-8 header to it):
    #
    #     attachment; filename="caf__.png"; filename*=UTF-8''caf%C3%A9.png
    #
    # `filename` is a fallback with every byte outside `[A-Za-z0-9._ -]`
    # replaced by "_" (so a quote, backslash, CR or LF can never reach the
    # header); `filename*` is the RFC 5987 percent form of the real name.
    # @param disposition [String] "inline" or "attachment"; anything else
    #   means "attachment"
    # @param filename [String]
    # @return [String]
    # @api public
    def self.content_disposition(disposition, filename)
      kind = disposition == "inline" ? "inline" : "attachment"
      out = +""
      out << kind
      out << "; filename=\""
      n = filename.bytesize
      i = 0
      while i < n
        b = filename.getbyte(i)
        if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2E || b == 0x5F || b == 0x20 || b == 0x2D
          out << filename.byteslice(i, 1)
        else
          out << "_"
        end
        i += 1
      end
      out << "\"; filename*=UTF-8''"
      i = 0
      while i < n
        b = filename.getbyte(i)
        if UploadedFile.attr_char?(b)
          out << filename.byteslice(i, 1)
        else
          out << "%"
          out << UPPER_HEX.byteslice((b >> 4) & 0xF, 1)
          out << UPPER_HEX.byteslice(b & 0xF, 1)
        end
        i += 1
      end
      out
    end

    # An RFC 5987 attr-char: ALPHA / DIGIT / ! # $ & + . ^ _ ` | ~ -
    # @api private
    def self.attr_char?(b)
      return true if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
      b == 0x21 || b == 0x23 || b == 0x24 || b == 0x26 || b == 0x2B || b == 0x2E || b == 0x5E || b == 0x5F || b == 0x60 || b == 0x7C || b == 0x7E || b == 0x2D
    end
  end
end
