# Cybertrain::Mailer::Message -- the text of a multipart/alternative
# message (a plain-text part, then an HTML part), and its reverse for tests.
# Required by cybertrain/mailer.rb, whose address, subject and body checks
# and header builders it uses.
require "base64"

module Cybertrain
  class Mailer
    # Builds the multipart/alternative message {Mailer#deliver} sends when
    # it is given `html:`, and reads one back ({.parse}, which
    # Test::ReceivedMessage#message_parts uses).
    # @api public
    module Message
      # The longest boundary RFC 2046 5.1.1 allows.
      MAX_BOUNDARY_BYTES = 70

      # The message: headers (From, To, Subject, MIME-Version,
      # Content-Type), a blank line, then two parts, `text` as
      # `text/plain` and `html` as `text/html`, both `charset=UTF-8` and
      # `Content-Transfer-Encoding: base64` (lines of 76 characters, CRLF),
      # and the closing boundary. Every line ends CRLF; there is no Date
      # header (the mailer adds it when it sends) and no dot-stuffing.
      #
      # The boundary cannot occur inside a part: a boundary line starts
      # with "--", and a base64 body is made of A-Z, a-z, 0-9, "+", "/" and
      # "=" only, so none of its lines can start with "-"; the part headers
      # are fixed text. That holds for any boundary, whatever the bodies
      # contain (a lone "." line, "--" lines, the boundary itself).
      #
      # Every value is checked as {Mailer#deliver} checks it: bare ASCII
      # addresses, a subject without CR, LF or NUL (a non-ASCII subject is
      # RFC 2047-encoded), bodies of valid UTF-8 without NUL (their line
      # endings made CRLF before encoding, RFC 2045 6.8's canonical form).
      # @example
      #   Cybertrain::Mailer::Message.build("app@example.com", "bob@example.org", "Hi",
      #                                     "Hello\n", "<p>Hello</p>", "=_b1")
      # @param from [String] the sender address
      # @param to [String] one address, or several separated by commas
      # @param subject [String] UTF-8
      # @param text [String] the plain-text part, UTF-8
      # @param html [String] the HTML part, UTF-8
      # @param boundary [String] 1 to 70 characters of RFC 2046's bchars
      #   other than space (letters, digits, `'()+_,-./:=?`)
      # @return [String]
      # @raise [ArgumentError] for an address, subject, body or boundary refused
      # @api public
      def self.build(from, to, subject, text, html, boundary)
        sender = from.to_s
        Mailer.check_address(sender, "from")
        recipients = Mailer.split_recipients(to.to_s)
        title = subject.to_s
        Mailer.check_subject(title)
        plain = Mailer.normalize_body(text.to_s)
        markup = Mailer.normalize_body(html.to_s)
        mark = boundary.to_s
        Message.check_boundary(mark)
        to_header = Mailer.to_header(recipients)
        subject_header = Mailer.subject_header(title)
        out = String.new
        out << "From: " << sender << "\r\n"
        out << to_header
        out << subject_header
        out << "MIME-Version: 1.0\r\n"
        # Folded before the parameter: no header line past 78 characters
        # (RFC 5322 2.1.1) with the mailer's 45-character boundary.
        out << "Content-Type: multipart/alternative;\r\n boundary=\"" << mark << "\"\r\n"
        out << "\r\n"
        Message.append_part(out, mark, "text/plain", plain)
        Message.append_part(out, mark, "text/html", markup)
        out << "--" << mark << "--\r\n"
        out
      end

      # One part: the boundary line, its headers, a blank line and the body
      # in base64 lines.
      def self.append_part(out, mark, content_type, body)
        encoded = Mailer.base64_lines(body)
        out << "--" << mark << "\r\n"
        out << "Content-Type: " << content_type << "; charset=UTF-8\r\n"
        out << "Content-Transfer-Encoding: base64\r\n"
        out << "\r\n"
        out << encoded
        nil
      end

      # Raises ArgumentError unless `mark` is 1 to MAX_BOUNDARY_BYTES of
      # letters, digits and `'()+_,-./:=?` (no quote, CR or LF: it goes
      # into a quoted header value).
      def self.check_boundary(mark)
        n = mark.bytesize
        raise ArgumentError, "the boundary is empty" if n == 0
        raise ArgumentError, "the boundary is longer than #{MAX_BOUNDARY_BYTES} bytes" if n > MAX_BOUNDARY_BYTES

        i = 0
        while i < n
          b = mark.getbyte(i)
          raise ArgumentError, "the boundary contains a character RFC 2046 does not allow" unless Message.boundary_byte?(b)

          i += 1
        end
        nil
      end

      # A-Z a-z 0-9 ' ( ) + _ , - . / : = ?
      def self.boundary_byte?(b)
        return true if (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)

        b == 39 || b == 40 || b == 41 || b == 43 || b == 95 || b == 44 || b == 45 || b == 46 || b == 47 ||
          b == 58 || b == 61 || b == 63
      end

      # The message with attachments (docs/design.md D98): the headers of
      # {.build}, then a multipart/mixed body whose first part is the text
      # (text/plain), or the text and the HTML (multipart/alternative, as
      # {.build} writes it), and the other parts the files of
      # `attachments` that are not inline, each base64 with its
      # Content-Type and a Content-Disposition naming it. Inline files go
      # with the HTML part into a multipart/related (each with
      # `Content-ID: <name>`, which the HTML names as `cid:name`); without
      # an HTML part they are attached as the others are. With no
      # attachments the message is {.build}'s, byte for byte, when there is
      # HTML. The nested parts' boundaries are `boundary` with `a_` and
      # `r_` in front (so it may be at most 68 characters here), so no
      # boundary is the start of another's delimiter line.
      # @param from [String] the sender address
      # @param to [String] one address, or several separated by commas
      # @param subject [String] UTF-8
      # @param text [String] the plain-text part, UTF-8
      # @param html [String] the HTML part, UTF-8; "" for none
      # @param attachments [Array<Attachment>]
      # @param boundary [String] as for {.build}
      # @return [String]
      # @raise [ArgumentError] for an address, subject, body or boundary refused
      # @api public
      def self.build_mime(from, to, subject, text, html, attachments, boundary)
        markup = html.to_s
        return Message.build(from, to, subject, text, markup, boundary) if attachments.empty?

        sender = from.to_s
        Mailer.check_address(sender, "from")
        recipients = Mailer.split_recipients(to.to_s)
        title = subject.to_s
        Mailer.check_subject(title)
        plain = Mailer.normalize_body(text.to_s)
        normalized = markup.empty? ? "" : Mailer.normalize_body(markup)
        mark = boundary.to_s
        Message.check_boundary(mark)
        Message.check_boundary("a_#{mark}")
        inline = Attachment.none
        files = Attachment.none
        attachments.each do |a|
          if a.attachment_inline? && !normalized.empty?
            inline << a
          else
            files << a
          end
        end
        out = String.new
        out << "From: " << sender << "\r\n"
        out << Mailer.to_header(recipients)
        out << Mailer.subject_header(title)
        out << "MIME-Version: 1.0\r\n"
        out << "Content-Type: multipart/mixed;\r\n boundary=\"" << mark << "\"\r\n"
        out << "\r\n"
        out << "--" << mark << "\r\n"
        if normalized.empty?
          out << Message.text_entity("text/plain", plain)
        else
          out << Message.alternative_entity("a_#{mark}", plain, Message.html_entity("r_#{mark}", normalized, inline))
        end
        files.each do |a|
          out << "--" << mark << "\r\n"
          out << Message.attachment_entity(a, false)
        end
        out << "--" << mark << "--\r\n"
        out
      end

      # A text part's headers and body: `content_type; charset=UTF-8`, base64.
      def self.text_entity(content_type, body)
        out = String.new
        out << "Content-Type: " << content_type << "; charset=UTF-8\r\n"
        out << "Content-Transfer-Encoding: base64\r\n"
        out << "\r\n"
        out << Mailer.base64_lines(body)
        out
      end

      # multipart/alternative of the text part and `html_part` (an entity).
      def self.alternative_entity(mark, plain, html_part)
        out = String.new
        out << "Content-Type: multipart/alternative;\r\n boundary=\"" << mark << "\"\r\n"
        out << "\r\n"
        out << "--" << mark << "\r\n"
        out << Message.text_entity("text/plain", plain)
        out << "--" << mark << "\r\n"
        out << html_part
        out << "--" << mark << "--\r\n"
        out
      end

      # The HTML part, or with inline files a multipart/related of the HTML
      # part and those files.
      def self.html_entity(mark, markup, inline)
        return Message.text_entity("text/html", markup) if inline.empty?

        Message.check_boundary(mark)
        out = String.new
        out << "Content-Type: multipart/related;\r\n boundary=\"" << mark << "\"; type=\"text/html\"\r\n"
        out << "\r\n"
        out << "--" << mark << "\r\n"
        out << Message.text_entity("text/html", markup)
        inline.each do |a|
          out << "--" << mark << "\r\n"
          out << Message.attachment_entity(a, true)
        end
        out << "--" << mark << "--\r\n"
        out
      end

      # One file: its Content-Type with the name, base64, its disposition
      # (attachment, or with `inline` inline with a Content-ID), then the bytes.
      def self.attachment_entity(a, inline)
        name = a.attachment_filename
        out = String.new
        out << "Content-Type: " << a.attachment_mime_type << ";\r\n " << Message.name_param("name", name) << "\r\n"
        out << "Content-Transfer-Encoding: base64\r\n"
        out << "Content-Disposition: " << (inline ? "inline" : "attachment") << ";\r\n "
        out << Message.name_param("filename", name) << "\r\n"
        out << "Content-ID: <" << name << ">\r\n" if inline
        out << "\r\n"
        out << Mailer.base64_lines(a.attachment_content)
        out
      end

      # `key="value"` for a name of printable ASCII without `"` or `\`,
      # else RFC 2231's `key*=UTF-8''percent-encoded`.
      def self.name_param(key, value)
        plain = true
        n = value.bytesize
        i = 0
        while i < n
          b = value.getbyte(i)
          plain = false if b < 32 || b > 126 || b == 34 || b == 92
          i += 1
        end
        out = String.new
        if plain
          out << key << "=\"" << value << "\""
          return out
        end
        out << key << "*=UTF-8''"
        hex = "0123456789ABCDEF"
        i = 0
        while i < n
          b = value.getbyte(i)
          if Message.attr_char?(b)
            out << b.chr
          else
            out << "%" << hex[b >> 4, 1].to_s << hex[b & 15, 1].to_s
          end
          i += 1
        end
        out
      end

      # RFC 2231's attribute-char: ALPHA, DIGIT and !#$&+-.^_`|~.
      def self.attr_char?(b)
        return true if (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)

        b == 33 || b == 35 || b == 36 || b == 38 || b == 43 || b == 45 || b == 46 || b == 94 || b == 95 ||
          b == 96 || b == 124 || b == 126
      end

      # A message read back, for tests: `"subject"` (RFC 2047 encoded words
      # decoded), `"text"` and `"html"` (each part decoded from its
      # transfer encoding, CRLF line endings kept), and for each attached
      # file `"attachment:<file name>"` with its bytes (an inline one too),
      # found at any depth of nested multiparts. A message that is not
      # multipart is all `"text"` and `"html"` is "". `data` is the message
      # as sent after DATA, dot-stuffing undone (Test::ReceivedMessage's
      # `message_data`); a Date header or none makes no difference.
      # @example
      #   parts = Cybertrain::Mailer::Message.parse(mail.message_data)
      #   parts["html"]   # => "<p>Hello</p>\r\n"
      #   parts["attachment:report.pdf"]   # => the PDF's bytes
      # @param data [String]
      # @return [Hash{String => String}]
      # @api public
      def self.parse(data)
        s = data.to_s
        out = { "subject" => "", "text" => "", "html" => "" }
        stop = s.byteindex("\r\n\r\n")
        head = stop.nil? ? s : s.byteslice(0, stop)
        body = stop.nil? ? "" : s.byteslice(stop + 4, s.bytesize - stop - 4)
        out["subject"] = Message.decode_words(Message.header_in(head, "subject"))
        mark = Message.boundary_of(Message.header_in(head, "content-type"))
        if mark.empty?
          out["text"] = Message.decode_body(body, Message.header_in(head, "content-transfer-encoding"))
          return out
        end
        Message.parse_parts(body, mark, out, 0)
        out
      end

      # The parts of one multipart body into `out`, a nested multipart's
      # parts too (up to 8 levels).
      def self.parse_parts(body, mark, out, depth)
        return nil if depth > 8

        delimiter = String.new
        delimiter << "--" << mark
        pieces = body.split(delimiter)
        i = 1
        while i < pieces.size
          piece = pieces[i]
          break if piece.start_with?("--")

          piece = piece.byteslice(2, piece.bytesize - 2) if piece.start_with?("\r\n")
          at = piece.byteindex("\r\n\r\n")
          unless at.nil?
            part_head = piece.byteslice(0, at)
            part_body = piece.byteslice(at + 4, piece.bytesize - at - 4)
            Message.parse_part(part_head, part_body, out, depth)
          end
          i += 1
        end
        nil
      end

      # One part: a nested multipart, a file (it has a file name), or the
      # text or HTML part.
      def self.parse_part(part_head, part_body, out, depth)
        ctype = Message.header_in(part_head, "content-type")
        inner = Message.boundary_of(ctype)
        unless inner.empty?
          Message.parse_parts(part_body, inner, out, depth + 1)
          return nil
        end
        encoding = Message.header_in(part_head, "content-transfer-encoding")
        filename = Message.param_of(Message.header_in(part_head, "content-disposition"), "filename")
        filename = Message.param_of(ctype, "name") if filename.empty?
        unless filename.empty?
          bytes = encoding.downcase == "base64" ? Base64.decode64(part_body) : part_body.dup
          out["attachment:#{filename}"] = bytes
          return nil
        end
        decoded = Message.decode_body(part_body, encoding)
        kind = ctype.downcase
        if kind.start_with?("text/html")
          out["html"] = decoded
        elsif kind.start_with?("text/plain")
          out["text"] = decoded
        end
        nil
      end

      # A header parameter's value: `key="v"`, `key=v` or RFC 2231's
      # `key*=UTF-8''...` decoded; "" when the header has none.
      def self.param_of(value, key)
        value.split(";").each do |raw|
          item = raw.strip
          if item.start_with?("#{key}*=")
            rest = item.byteslice(key.bytesize + 2, item.bytesize - key.bytesize - 2).to_s
            quote = rest.index("''")
            rest = rest.byteslice(quote + 2, rest.bytesize - quote - 2).to_s unless quote.nil?
            return Message.percent_decode(rest)
          end
          next unless item.start_with?("#{key}=")

          rest = item.byteslice(key.bytesize + 1, item.bytesize - key.bytesize - 1).to_s
          rest = rest.byteslice(1, rest.bytesize - 2).to_s if rest.start_with?("\"") && rest.end_with?("\"") && rest.bytesize >= 2
          return rest
        end
        ""
      end

      # %XX escapes decoded, as UTF-8.
      def self.percent_decode(text)
        out = String.new
        n = text.bytesize
        i = 0
        while i < n
          b = text.getbyte(i)
          if b == 37 && i + 2 < n
            out << text.byteslice(i + 1, 2).to_i(16).chr
            i += 3
          else
            out << b.chr
            i += 1
          end
        end
        out.force_encoding("UTF-8")
      end

      # The unfolded value of the first header `wanted` (lowercase) in
      # `head`, "" when there is none.
      def self.header_in(head, wanted)
        pos = 0
        stop = head.bytesize
        found = false
        value = String.new
        while pos < stop
          eol = head.byteindex("\r\n", pos)
          eol = stop if eol.nil?
          line = head.byteslice(pos, eol - pos)
          pos = eol + 2
          continued = line.start_with?(" ") || line.start_with?("\t")
          if found
            break unless continued

            value << " " << line.strip
          elsif !continued
            colon = line.byteindex(":")
            if !colon.nil? && line.byteslice(0, colon).downcase == wanted
              found = true
              value << line.byteslice(colon + 1, line.bytesize - colon - 1).strip
            end
          end
        end
        value
      end

      # The `boundary="..."` (or unquoted) parameter of a multipart
      # Content-Type, "" for any other type.
      def self.boundary_of(ctype)
        return "" unless ctype.downcase.start_with?("multipart/")

        at = ctype.index("boundary=")
        return "" if at.nil?

        rest = ctype.byteslice(at + 9, ctype.bytesize - at - 9)
        if rest.start_with?("\"")
          close = rest.index("\"", 1)
          return "" if close.nil?

          return rest.byteslice(1, close - 1)
        end
        semi = rest.index(";")
        semi.nil? ? rest.strip : rest.byteslice(0, semi).strip
      end

      # A body as UTF-8: base64 decoded, anything else as it is.
      def self.decode_body(body, encoding)
        return body.dup.force_encoding("UTF-8") unless encoding.downcase == "base64"

        Base64.decode64(body).force_encoding("UTF-8")
      end

      # A header value with its `=?UTF-8?B?...?=` words decoded (the space
      # between two encoded words dropped, RFC 2047 6.2).
      def self.decode_words(value)
        return value if value.index("=?").nil?

        words = value.split(" ")
        out = String.new
        previous_encoded = false
        i = 0
        while i < words.size
          word = words[i]
          encoded = word.start_with?("=?UTF-8?B?") && word.end_with?("?=") && word.bytesize >= 12
          out << " " if i > 0 && !(encoded && previous_encoded)
          if encoded
            out << Base64.decode64(word.byteslice(10, word.bytesize - 12))
          else
            out << word
          end
          previous_encoded = encoded
          i += 1
        end
        out.force_encoding("UTF-8")
      end
    end
  end
end
