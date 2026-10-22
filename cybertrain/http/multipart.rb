require "cybertrain/http/query"
require "cybertrain/http/uploaded_file"

module Cybertrain
  # The body of a multipart/form-data request is not well formed (no or an
  # invalid boundary, a part without its headers or its closing delimiter,
  # a Content-Disposition that is not form-data, a bad name, ...). A client
  # fault: ClientError answers 400 (listed in CLIENT_FAULTS). The four
  # Multipart classes are QueryInvalid subclasses with unique bare names,
  # because Class#name has no namespace under Spinel (NOTES rule 46).
  # @api public
  class MultipartMalformed < QueryInvalid
  end

  # More parts than the configured `max_multipart_parts`.
  # @api public
  class MultipartTooManyParts < QueryInvalid
  end

  # A file part past `max_upload_bytes`, or the text parts together past
  # Multipart::MAX_TEXT_BYTES.
  # @api public
  class MultipartPartTooLarge < QueryInvalid
  end

  # One part's header block past Multipart::MAX_HEADER_BYTES.
  # @api public
  class MultipartHeaderTooLarge < QueryInvalid
  end

  # The flat result of {Multipart.parse}: parallel typed Arrays, in the order
  # the parts arrived, not one Hash of mixed values (NOTES rules 46, 56). It
  # is named MultipartForm and not Multipart::Form because Class#name carries
  # no namespace under Spinel.
  # @api public
  class MultipartForm
    def initialize
      @text_names = Array.new(0) { "" }
      @text_values = Array.new(0) { "" }
      @file_names = Array.new(0) { "" }
      @files = Array.new(0) { UploadedFile.blank }
    end

    # @param name [String] the field name, valid UTF-8, brackets not yet split
    # @param value [String] the field's value, valid UTF-8
    # @return [nil]
    def add_text(name, value)
      @text_names << name
      @text_values << value
      nil
    end

    # @param name [String] the field name, valid UTF-8, brackets not yet split
    # @param upload [UploadedFile]
    # @return [nil]
    def add_file(name, upload)
      @file_names << name
      @files << upload
      nil
    end

    # The value of the LAST text part named exactly `name` (so `post[_method]`
    # is not `_method`), "" when there is none. What CsrfProtection and
    # MethodOverride read through Request#form_or_query_value.
    # @param name [String]
    # @return [String]
    def text_value(name)
      i = @text_names.length - 1
      while i >= 0
        return @text_values[i] if @text_names[i] == name
        i -= 1
      end
      ""
    end

    # @return [Integer] the number of text parts
    def text_count
      @text_names.length
    end

    # @param i [Integer]
    # @return [String]
    def text_name_at(i)
      @text_names[i]
    end

    # @param i [Integer]
    # @return [String]
    def text_value_at(i)
      @text_values[i]
    end

    # @return [Integer] the number of file parts kept (an unselected file
    #   input is dropped by the parser)
    def file_count
      @files.length
    end

    # @param i [Integer]
    # @return [String]
    def file_name_at(i)
      @file_names[i]
    end

    # @param i [Integer]
    # @return [UploadedFile]
    def file_at(i)
      @files[i]
    end
  end

  # A binary-safe multipart/form-data parser (RFC 7578 over RFC 2046), in the
  # HTTP layer so Request can use it before routing: CsrfProtection and
  # MethodOverride read their field from a multipart body too.
  #
  # Every offset is a byte offset (NOTES rule 27), and the whole parse runs
  # on ONE binary copy of the body (`body.b`), so CRuby's byteindex never
  # sees a UTF-8 String with a stray byte (rule 52). File data is never
  # compared with `==`, interpolated, matched with a regexp or checked with
  # valid_encoding? (rule 60): it is cut out with byteslice after the size
  # gates, which look at offsets only. Scanning is linear: every search
  # resumes where the last one stopped, and a hit that is only a look-alike
  # ("--BOUNDARYX" inside file data) moves the cursor on by one byte.
  #
  # The memory used is about three times the body per request in flight (the
  # raw body, the binary copy, the slices), and the body is bounded by
  # `max_body_bytes`.
  #
  # Error messages are fixed strings and numeric limits: never request bytes.
  # @api public
  module Multipart
    # The longest boundary taken (RFC 2046 says 70; this is tolerant, bounded).
    MAX_BOUNDARY_BYTES = 200
    # One part's header block.
    MAX_HEADER_BYTES = 8192
    # A field name.
    MAX_NAME_BYTES = 1024
    # A filename as sent, before UploadedFile.sanitize_filename.
    MAX_RAW_FILENAME_BYTES = 1024
    # The sum of all text values.
    MAX_TEXT_BYTES = 1_048_576
    # Bytes allowed before the first delimiter.
    MAX_PREAMBLE_BYTES = 1024
    # Spaces and tabs allowed after a delimiter (RFC 2046 transport padding).
    MAX_PADDING_BYTES = 16

    # Module-level ivars with literal defaults, the Request.inflater shape
    # (NOTES rule 18). Application#boot installs the configured limits.
    @max_upload_bytes = 5_242_880
    @max_parts = 128

    # Installs the limits from the Config. Called by Application#boot.
    # @param max_upload_bytes [Integer] the largest file part, in bytes
    # @param max_parts [Integer] the most parts (text and file) in one body
    # @return [nil]
    # @api private
    def self.configure(max_upload_bytes, max_parts)
      @max_upload_bytes = max_upload_bytes
      @max_parts = max_parts
      nil
    end

    # @return [Integer] the largest file part accepted, in bytes
    # @api private
    def self.max_upload_bytes
      @max_upload_bytes
    end

    # @return [Integer] the most parts accepted in one body
    # @api private
    def self.max_parts
      @max_parts
    end

    # The `boundary` parameter of a Content-Type header value (the parameter
    # name is case-insensitive; the value is a token or a quoted-string).
    # @example
    #   Multipart.boundary_from('multipart/form-data; boundary="xyz"') # => "xyz"
    # @param content_type_header [String] the whole header value
    # @return [String] "" when there is none, when it is given twice, or when
    #   it is not 1 to MAX_BOUNDARY_BYTES bytes of ASCII without CR, LF or NUL
    # @api public
    def self.boundary_from(content_type_header)
      found = Multipart.params_named(content_type_header, "boundary", false)
      return "" unless found.length == 1

      b = found[0]
      n = b.bytesize
      return "" if n < 1 || n > MAX_BOUNDARY_BYTES

      i = 0
      while i < n
        byte = b.getbyte(i)
        return "" if byte == 0 || byte == 10 || byte == 13 || byte >= 128
        i += 1
      end
      b
    end

    # Splits a multipart/form-data body into its text fields and files.
    # @param body [String] the raw request body
    # @param content_type_header [String] the Content-Type header value (it
    #   carries the boundary)
    # @return [MultipartForm]
    # @raise [MultipartMalformed] no valid boundary, or a malformed body
    # @raise [MultipartTooManyParts] more parts than the configured limit
    # @raise [MultipartHeaderTooLarge] a part's headers are over 8 KiB
    # @raise [MultipartPartTooLarge] a file over `max_upload_bytes`, or the
    #   text values over 1 MiB together
    # @raise [QueryMalformed] a text value that is not valid UTF-8
    # @api public
    def self.parse(body, content_type_header)
      boundary = Multipart.boundary_from(content_type_header)
      raise MultipartMalformed, "missing or invalid multipart boundary" if boundary.empty?

      data = body.b
      delim = +""
      delim << "--" << boundary
      sep = +""
      sep << "\r\n" << delim
      seplen = sep.bytesize
      form = MultipartForm.new
      pos = Multipart.first_delimiter_end(data, delim, sep)
      parts = 0
      text_total = 0
      done = false
      while !done
        if Multipart.close_at?(data, pos)
          done = true
        else
          head_at = Multipart.padding_end(data, pos)
          raise MultipartMalformed, "malformed multipart delimiter" if head_at < 0

          parts += 1
          raise MultipartTooManyParts, "too many multipart parts (limit #{@max_parts})" if parts > @max_parts

          hend = data.byteindex("\r\n\r\n", head_at)
          raise MultipartMalformed, "multipart part has no end of headers" if hend.nil?
          raise MultipartHeaderTooLarge, "multipart part headers too large (limit #{MAX_HEADER_BYTES} bytes)" if hend - head_at > MAX_HEADER_BYTES

          block = data.byteslice(head_at, hend - head_at)
          heads = Multipart.read_headers(block)
          disposition = heads[0]
          part_type = heads[1]
          Multipart.require_form_data(disposition)
          name = Multipart.part_name(disposition)
          filenames = Multipart.params_named(disposition, "filename", true)
          raise MultipartMalformed, "duplicate filename in multipart part" if filenames.length > 1

          is_file = filenames.length == 1
          raw_filename = is_file ? filenames[0] : ""
          raise MultipartMalformed, "multipart filename too long (limit #{MAX_RAW_FILENAME_BYTES} bytes)" if raw_filename.bytesize > MAX_RAW_FILENAME_BYTES

          start = hend + 4
          nxt = Multipart.find_delimiter(data, sep, start)
          raise MultipartMalformed, "unterminated multipart part" if nxt < 0

          # The size gates look at offsets only: nothing is sliced yet.
          len = nxt - start
          if is_file
            raise MultipartPartTooLarge, "uploaded file too large (limit #{@max_upload_bytes} bytes)" if len > @max_upload_bytes

            # A file input left empty sends filename="" and no bytes: dropped.
            unless raw_filename.empty? && len == 0
              chunk = data.byteslice(start, len)
              fname = UploadedFile.sanitize_filename(raw_filename)
              dtype = UploadedFile.sanitize_type(part_type)
              up = UploadedFile.new(fname, dtype, chunk)
              form.add_file(name, up)
            end
          else
            text_total += len
            raise MultipartPartTooLarge, "multipart text fields too large (limit #{MAX_TEXT_BYTES} bytes)" if text_total > MAX_TEXT_BYTES

            chunk = data.byteslice(start, len)
            value = Query.utf8!(chunk)
            form.add_text(name, value)
          end
          pos = nxt + seplen
        end
      end
      form
    end

    # Puts a parsed form into a Params tree: text fields through set_path (a
    # nested name such as post[title] builds the tree, the same as an
    # urlencoded body), files through set_upload_path. Called by the Router.
    # The names are used as they are: they are not percent-decoded (a
    # multipart name is raw text; Query.add_pair would decode "%5B").
    # @param params [Params] filled in place
    # @param form [MultipartForm]
    # @return [nil]
    # @raise [QueryTooMany] more fields than Query::MAX_PAIRS
    # @raise [QueryTooDeep] a name nested deeper than Query::MAX_DEPTH
    # @raise [MultipartMalformed] a file sent as `name[]` (several files per
    #   field are not supported)
    # @api public
    def self.fill(params, form)
      total = form.text_count + form.file_count
      raise QueryTooMany, "too many parameters (limit #{Query::MAX_PAIRS})" if total > Query::MAX_PAIRS

      i = 0
      while i < form.text_count
        path = Query.split_key(form.text_name_at(i))
        params.set_path(path, form.text_value_at(i))
        i += 1
      end
      i = 0
      while i < form.file_count
        path = Query.split_key(form.file_name_at(i))
        raise MultipartMalformed, "multiple files per field are not supported" if path[path.length - 1] == ""

        file = form.file_at(i)
        params.set_upload_path(path, file)
        i += 1
      end
      nil
    end

    # The offset just after the first delimiter: at offset 0, or right after
    # a CRLF within MAX_PREAMBLE_BYTES (the preamble is ignored).
    # @api private
    def self.first_delimiter_end(data, delim, sep)
      dl = delim.bytesize
      return dl if UploadedFile.bytes_at?(data, 0, delim) && Multipart.delimiter_tail?(data, dl)

      i = Multipart.find_delimiter(data, sep, 0)
      raise MultipartMalformed, "multipart body does not start with the boundary" if i < 0 || i > MAX_PREAMBLE_BYTES

      i + sep.bytesize
    end

    # The offset of the next "\r\n--boundary" at or after `from` that really
    # is a delimiter line (followed by "--", or by optional spaces and tabs
    # and a CRLF), or -1. A hit that is not (file data holding
    # "\r\n--BOUNDARYX") moves the cursor on by one byte, so the whole
    # search is linear.
    # @api private
    def self.find_delimiter(data, sep, from)
      seplen = sep.bytesize
      cursor = from
      while true
        i = data.byteindex(sep, cursor)
        return -1 if i.nil?
        return i if Multipart.delimiter_tail?(data, i + seplen)

        cursor = i + 1
      end
      -1
    end

    # Whether what follows a delimiter at `pos` closes the body ("--") or
    # ends the delimiter line (padding, then CRLF).
    # @api private
    def self.delimiter_tail?(data, pos)
      Multipart.close_at?(data, pos) || Multipart.padding_end(data, pos) >= 0
    end

    # Whether the two bytes at `pos` are "--".
    # @api private
    def self.close_at?(data, pos)
      return false if pos + 2 > data.bytesize

      data.getbyte(pos) == 45 && data.getbyte(pos + 1) == 45
    end

    # After skipping up to MAX_PADDING_BYTES spaces and tabs from `pos`, the
    # offset just past a CRLF, or -1 when no CRLF follows.
    # @api private
    def self.padding_end(data, pos)
      n = data.bytesize
      i = pos
      while i < n && i - pos < MAX_PADDING_BYTES
        b = data.getbyte(i)
        break unless b == 32 || b == 9
        i += 1
      end
      return -1 if i + 2 > n
      return i + 2 if data.getbyte(i) == 13 && data.getbyte(i + 1) == 10

      -1
    end

    # The Content-Disposition and Content-Type values of one part's header
    # block (without the final blank line), as [disposition, type], "" for a
    # header that is absent. The rules of HttpParser.parse_head's header loop,
    # applied to byte offsets: split on CRLF, no bare CR or LF, no NUL, a
    # colon after a non-empty name, no whitespace in a name (which also
    # rejects an obsolete folded line). Other headers are ignored, and
    # Content-Transfer-Encoding is not honoured.
    # @api private
    def self.read_headers(block)
      disposition = +""
      part_type = +""
      seen_disposition = false
      seen_type = false
      n = block.bytesize
      cur = 0
      while cur < n
        eol = block.byteindex("\r\n", cur)
        stop = eol.nil? ? n : eol
        len = stop - cur
        colon = -1
        j = 0
        while j < len
          b = block.getbyte(cur + j)
          raise MultipartMalformed, "malformed multipart header line" if b == 0 || b == 10 || b == 13
          if colon < 0
            raise MultipartMalformed, "malformed multipart header name" if b == 32 || b == 9
            colon = j if b == 58
          end
          j += 1
        end
        raise MultipartMalformed, "malformed multipart header line" if colon < 1

        if Multipart.ascii_ieq?(block, cur, colon, "content-disposition")
          raise MultipartMalformed, "duplicate Content-Disposition in multipart part" if seen_disposition
          seen_disposition = true
          disposition = Multipart.trim_ws(block.byteslice(cur + colon + 1, len - colon - 1))
        elsif Multipart.ascii_ieq?(block, cur, colon, "content-type")
          raise MultipartMalformed, "duplicate Content-Type in multipart part" if seen_type
          seen_type = true
          part_type = Multipart.trim_ws(block.byteslice(cur + colon + 1, len - colon - 1))
        end
        cur = stop + 2
      end
      [disposition, part_type]
    end

    # Raises unless the Content-Disposition's first token is form-data.
    # @api private
    def self.require_form_data(disposition)
      n = disposition.bytesize
      i = 0
      i += 1 while i < n && disposition.getbyte(i) != 59
      token = Multipart.trim_ws(disposition.byteslice(0, i))
      return nil if Multipart.ascii_ieq?(token, 0, token.bytesize, "form-data")

      raise MultipartMalformed, "multipart part is not form-data"
    end

    # The part's `name` parameter as valid UTF-8 text. Required, once, 1 to
    # MAX_NAME_BYTES bytes.
    # @api private
    def self.part_name(disposition)
      names = Multipart.params_named(disposition, "name", true)
      raise MultipartMalformed, "multipart part has no name" if names.length == 0
      raise MultipartMalformed, "duplicate name in multipart part" if names.length > 1

      raw = names[0]
      raise MultipartMalformed, "multipart part has an empty name" if raw.bytesize == 0
      raise MultipartMalformed, "multipart part name too long (limit #{MAX_NAME_BYTES} bytes)" if raw.bytesize > MAX_NAME_BYTES

      name = raw.dup.force_encoding("UTF-8")
      raise MultipartMalformed, "multipart part name is not valid UTF-8" unless name.valid_encoding?

      name
    end

    # The values of every parameter called `want` (case-insensitive) in a
    # header value such as `form-data; name="a"; filename="b"`, in order.
    # Each value is a token (up to the next ";", trailing whitespace dropped)
    # or a quoted-string in which only \" and \\ are escapes (so a Windows
    # path "C:\dir\f.png" keeps its backslashes, as old browsers sent it).
    # No percent-decoding, and `filename*` is a different name, so it is
    # ignored. A quoted-string with no closing quote raises MultipartMalformed
    # when `strict`; otherwise the scan stops there.
    # @api private
    def self.params_named(header, want, strict)
      found = Array.new(0) { "" }
      n = header.bytesize
      i = 0
      i += 1 while i < n && header.getbyte(i) != 59
      i += 1
      while i < n
        i += 1 while i < n && (header.getbyte(i) == 32 || header.getbyte(i) == 9)
        name_at = i
        i += 1 while i < n && header.getbyte(i) != 61 && header.getbyte(i) != 59
        if i >= n || header.getbyte(i) == 59
          i += 1
        else
          name_end = i
          name_end -= 1 while name_end > name_at && (header.getbyte(name_end - 1) == 32 || header.getbyte(name_end - 1) == 9)
          i += 1
          i += 1 while i < n && (header.getbyte(i) == 32 || header.getbyte(i) == 9)
          value = +""
          if i < n && header.getbyte(i) == 34
            i += 1
            run = i
            closed = false
            while i < n && !closed
              b = header.getbyte(i)
              if b == 92 && i + 1 < n && (header.getbyte(i + 1) == 34 || header.getbyte(i + 1) == 92)
                # Keep the run so far; the escaped character starts the next.
                value << header.byteslice(run, i - run)
                run = i + 1
                i += 2
              elsif b == 34
                value << header.byteslice(run, i - run)
                closed = true
                i += 1
              else
                i += 1
              end
            end
            unless closed
              raise MultipartMalformed, "unterminated quoted string in multipart header" if strict

              return found
            end
            i += 1 while i < n && header.getbyte(i) != 59
            i += 1
          else
            value_at = i
            i += 1 while i < n && header.getbyte(i) != 59
            value_end = i
            value_end -= 1 while value_end > value_at && (header.getbyte(value_end - 1) == 32 || header.getbyte(value_end - 1) == 9)
            value << header.byteslice(value_at, value_end - value_at)
            i += 1
          end
          # to_s: `value` is a +"" buffer appended to in a loop; stored as it is
          # it has no bytesize under Spinel 2026.09.12 (a growable buffer, rule 60).
          found << value.to_s if Multipart.ascii_ieq?(header, name_at, name_end - name_at, want)
        end
      end
      found
    end

    # Whether the `len` bytes of `s` at `off` are `want` (lowercase ASCII),
    # ignoring ASCII case. Byte compares: no downcase on text that may hold
    # invalid UTF-8.
    # @api private
    def self.ascii_ieq?(s, off, len, want)
      return false if len != want.bytesize

      i = 0
      while i < len
        b = s.getbyte(off + i)
        b += 32 if b >= 65 && b <= 90
        return false if b != want.getbyte(i)
        i += 1
      end
      true
    end

    # `s` without leading and trailing spaces and tabs.
    # @api private
    def self.trim_ws(s)
      a = 0
      z = s.bytesize
      a += 1 while a < z && (s.getbyte(a) == 32 || s.getbyte(a) == 9)
      z -= 1 while z > a && (s.getbyte(z - 1) == 32 || s.getbyte(z - 1) == 9)
      s.byteslice(a, z - a)
    end
  end
end
