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
        s = mark.to_s # NOTES rule 62
        n = s.bytesize
        raise ArgumentError, "the boundary is empty" if n == 0
        raise ArgumentError, "the boundary is longer than #{MAX_BOUNDARY_BYTES} bytes" if n > MAX_BOUNDARY_BYTES

        i = 0
        while i < n
          b = s.getbyte(i)
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

      # A message read back, for tests: `"subject"` (RFC 2047 encoded words
      # decoded), `"text"` and `"html"` (each part decoded from its
      # transfer encoding, CRLF line endings kept). A message that is not
      # multipart is all `"text"` and `"html"` is "". `data` is the message
      # as sent after DATA, dot-stuffing undone (Test::ReceivedMessage's
      # `message_data`); a Date header or none makes no difference.
      # @example
      #   parts = Cybertrain::Mailer::Message.parse(mail.message_data)
      #   parts["html"]   # => "<p>Hello</p>\r\n"
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
        ctype = Message.header_in(head, "content-type")
        mark = Message.boundary_of(ctype)
        if mark.empty?
          out["text"] = Message.decode_body(body, Message.header_in(head, "content-transfer-encoding"))
          return out
        end
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
            decoded = Message.decode_body(part_body, Message.header_in(part_head, "content-transfer-encoding"))
            kind = Message.header_in(part_head, "content-type").downcase
            if kind.start_with?("text/html")
              out["html"] = decoded
            elsif kind.start_with?("text/plain")
              out["text"] = decoded
            end
          end
          i += 1
        end
        out
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
