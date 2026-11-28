# Cybertrain::Mailer::Attachment and Attachments -- the files a mail
# carries (docs/design.md D98): `attachments["report.pdf"] = bytes` in a
# mailer action, `attachments.inline["logo.png"] = bytes` for an image the
# HTML part shows with `cid:logo.png`. Mailer::Message.build_mime writes
# them as base64 parts of a multipart/mixed (and multipart/related)
# message. Required by cybertrain/mailer.rb; needs nothing else.
require "base64"

module Cybertrain
  class Mailer
    # One attached file: its name, its MIME type, its bytes (any, binary
    # included), and whether it is inline (shown inside the HTML part,
    # Content-Disposition: inline with a Content-ID) or a download.
    # @api public
    class Attachment
      # The most bytes a file name may take (a Content-Disposition
      # parameter, RFC 2231-encoded when it is not plain ASCII, stays under
      # the 998-byte line limit).
      MAX_NAME_BYTES = 255

      # The MIME type for a file name's extension (lowercased);
      # DEFAULT_TYPE for one the table lacks. A mailer that needs another
      # type gives it: `attachments.attach("x.ics", data, mime_type: "text/calendar")`.
      TYPES = {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" => "image/jpeg",
        "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "txt" => "text/plain",
        "csv" => "text/csv",
        "html" => "text/html",
        "htm" => "text/html",
        "ics" => "text/calendar",
        "json" => "application/json",
        "xml" => "application/xml",
        "zip" => "application/zip",
        "gz" => "application/gzip",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt" => "application/vnd.oasis.opendocument.text",
        "ods" => "application/vnd.oasis.opendocument.spreadsheet",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4"
      }
      DEFAULT_TYPE = "application/octet-stream"

      # @return [String] the file name the recipient sees
      # @api public
      attr_reader :attachment_filename
      # @return [String] "application/pdf"
      # @api public
      attr_reader :attachment_mime_type
      # @return [String] the file's bytes
      # @api public
      attr_reader :attachment_content

      # Checks the name and the type; the content is any bytes.
      # @param filename [String] UTF-8, 1 to 255 bytes, no control
      #   characters, `/` or `\`; an inline one only letters, digits and
      #   `._-+` (it is also its Content-ID)
      # @param content [String] the bytes
      # @param mime_type [String] "" for the type of the name's extension
      # @param inline [Boolean]
      # @raise [ArgumentError] for a name or type refused
      # @api public
      def initialize(filename, content, mime_type = "", inline = false)
        name = filename.to_s
        Attachment.check_filename(name, inline)
        type = mime_type.to_s
        type = Attachment.type_for(name) if type.empty?
        Attachment.check_mime_type(type)
        @attachment_filename = name
        @attachment_content = content.to_s
        @attachment_mime_type = type
        @attachment_inline = inline
      end

      # @return [Boolean] true for `attachments.inline[...]`
      # @api public
      def attachment_inline?
        @attachment_inline
      end

      # What the HTML part names an inline file by: "cid:logo.png" (its
      # Content-ID is `<logo.png>`). Rails' `attachments["logo.png"].url`.
      # @example
      #   @logo = attachments["logo.png"].url   # then <img src="<%= @logo %>"> in the view
      # @return [String]
      # @api public
      def url
        "cid:#{@attachment_filename}"
      end

      # The type of `name`'s extension ({TYPES}), {DEFAULT_TYPE} for any other.
      # @return [String]
      def self.type_for(name)
        dot = name.rindex(".")
        return DEFAULT_TYPE if dot.nil?

        ext = name[dot + 1, name.size - dot - 1].to_s.downcase
        found = TYPES[ext]
        found.nil? ? DEFAULT_TYPE : found
      end

      # Raises ArgumentError for a name a header cannot carry or a mail
      # client would read as a path.
      def self.check_filename(name, inline)
        n = name.bytesize
        raise ArgumentError, "an attachment needs a file name" if n == 0
        raise ArgumentError, "the attachment's file name is longer than #{MAX_NAME_BYTES} bytes" if n > MAX_NAME_BYTES
        raise ArgumentError, "the attachment's file name is not valid UTF-8" unless Mailer.utf8?(name)
        raise ArgumentError, "the attachment's file name may not be . or .." if name == "." || name == ".."

        i = 0
        while i < n
          b = name.getbyte(i)
          raise ArgumentError, "the attachment's file name contains a control character" if b < 32 || b == 127
          raise ArgumentError, "the attachment's file name contains / or \\" if b == 47 || b == 92
          if inline && !Attachment.cid_byte?(b)
            raise ArgumentError, "an inline attachment's file name is its Content-ID: use letters, digits and ._-+ only"
          end

          i += 1
        end
        nil
      end

      # A-Z a-z 0-9 . _ - +
      def self.cid_byte?(b)
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 46 || b == 95 || b == 45 || b == 43
      end

      # "type/subtype" of RFC 2045 token characters (no parameters).
      def self.check_mime_type(type)
        slash = type.index("/")
        ok = !slash.nil? && slash > 0 && slash < type.size - 1 && type.count("/") == 1
        i = 0
        n = type.bytesize
        while ok && i < n
          b = type.getbyte(i)
          ok = false unless b == 47 || Attachment.token_byte?(b)
          i += 1
        end
        raise ArgumentError, "the attachment's MIME type must be type/subtype (got #{Mailer.printable(type, 80).inspect})" unless ok

        nil
      end

      # An RFC 2045 token character: printable ASCII but space and tspecials.
      def self.token_byte?(b)
        return false if b <= 32 || b >= 127

        b != 40 && b != 41 && b != 60 && b != 62 && b != 64 && b != 44 && b != 59 && b != 58 && b != 92 &&
          b != 34 && b != 47 && b != 91 && b != 93 && b != 63 && b != 61
      end

      # An empty list typed Array<Attachment> (spikes/NOTES.md rule 9).
      # @return [Array<Attachment>]
      def self.none
        Array.new(0) { Attachment.new("x", "") }
      end
    end

    # The files of a deliver_later payload (cybertrain/mailer/later.rb)
    # as one line per file, `<a|i> <name> <type>
    # <content>`, the name and content base64 (strict) so neither a space
    # nor a newline, nor bytes that are not UTF-8, reach the JSON payload.
    # @param attachments [Array<Attachment>]
    # @return [String]
    def self.encode_attachments(attachments)
      out = String.new
      attachments.each do |a|
        out << (a.attachment_inline? ? "i" : "a") << " "
        out << Base64.strict_encode64(a.attachment_filename) << " "
        out << a.attachment_mime_type << " "
        out << Base64.strict_encode64(a.attachment_content) << "\n"
      end
      out
    end

    # {.encode_attachments}'s text read back; each file is checked again,
    # so a payload changed in the database raises ArgumentError.
    # @param text [String]
    # @return [Array<Attachment>]
    def self.decode_attachments(text)
      out = Attachment.none
      text.split("\n").each do |line|
        next if line.empty?

        # -1 keeps an empty last field: the content of an empty file.
        fields = line.split(" ", -1)
        raise ArgumentError, "the mail job's attachments field is malformed" unless fields.size == 4

        name = Base64.strict_decode64(fields[1]).force_encoding("UTF-8")
        content = Base64.strict_decode64(fields[3])
        out << Attachment.new(name, content, fields[2], fields[0] == "i")
      end
      out
    end

    # A mailer's `attachments` (Mailer::Base#attachments): `[]=` adds a
    # file, `[]` reads one back, `inline` adds inline ones. A second file
    # of the same name replaces the first, as in Rails.
    # @api public
    class Attachments
      def initialize
        @attachment_list = Attachment.none
      end

      # Attaches `content` as `filename`, its type from the extension
      # ({Attachment::TYPES}).
      # @example
      #   attachments["invoice.pdf"] = File.binread("tmp/invoice.pdf")
      # @param filename [String]
      # @param content [String] the bytes
      # @return [String] content
      # @raise [ArgumentError] for a file name refused
      # @api public
      def []=(filename, content)
        attach(filename, content)
        content
      end

      # Attaches a file with an explicit MIME type (Rails' Hash form,
      # `attachments["x"] = { mime_type:, content: }`, as a method: one
      # parameter type per method).
      # @example
      #   attachments.attach("event.ics", ics, mime_type: "text/calendar")
      # @param filename [String]
      # @param content [String]
      # @param mime_type [String] "" for the extension's
      # @param inline [Boolean]
      # @return [Attachment]
      # @raise [ArgumentError] for a file name or type refused
      # @api public
      def attach(filename, content, mime_type: "", inline: false)
        found = Attachment.new(filename.to_s, content.to_s, mime_type.to_s, inline)
        kept = Attachment.none
        @attachment_list.each { |a| kept << a unless a.attachment_filename == found.attachment_filename }
        kept << found
        @attachment_list = kept
        found
      end

      # The file attached as `filename`, nil when there is none.
      # @return [Attachment, nil]
      # @api public
      def [](filename)
        name = filename.to_s
        @attachment_list.each { |a| return a if a.attachment_filename == name }
        nil
      end

      # Adds inline files: `attachments.inline["logo.png"] = bytes`.
      # @return [InlineAttachments]
      # @api public
      def inline
        InlineAttachments.new(self)
      end

      # @return [Array<Attachment>] in the order they were added
      # @api public
      def attachment_list
        @attachment_list
      end
    end

    # `attachments.inline`: its `[]=` adds an inline file to the mailer's
    # Attachments.
    # @api public
    class InlineAttachments
      def initialize(owner)
        @owner = owner
      end

      # @example
      #   attachments.inline["logo.png"] = File.binread("app/assets/images/logo.png")
      # @return [String] content
      # @raise [ArgumentError] for a file name refused (an inline name is
      #   its Content-ID: letters, digits and `._-+`)
      # @api public
      def []=(filename, content)
        @owner.attach(filename, content, inline: true)
        content
      end
    end
  end
end
