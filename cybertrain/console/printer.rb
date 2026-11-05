require "cybertrain/errors"
require "cybertrain/html"
require "cybertrain/model"
require "cybertrain/pagination"
require "cybertrain/relation"

module Cybertrain
  module Console
    # Text a console command prints as it is (the `sql` table, `tables`,
    # `help`), not quoted the way a String value is. A distinctive reader
    # name (spikes/NOTES.md rules 10/34).
    class Text
      attr_reader :console_text

      def initialize(console_text)
        @console_text = console_text
      end
    end

    # How the console shows a value (spec: docs/superpowers/specs, phase 1,
    # section 7):
    #
    #   record    #<Article id: 1, title: "x", created_at: 2026-11-05 10:00:00 UTC>
    #   Array     one element per line, then "N records" (or "N elements")
    #   Relation  #<ArticleRelation SELECT ...> and its count
    #   scalar    as `inspect` shows it
    #
    # A value inside a record or a list is cut after MAX_VALUE_BYTES bytes
    # with "…", so a long text or a blob column does not flood the screen.
    module Printer
      MAX_VALUE_BYTES = 80
      ELLIPSIS = "…"

      # The text for one value, without a trailing newline.
      # @param value [Object]
      # @return [String]
      def self.format(value)
        case value
        when Text then value.console_text
        when Cybertrain::Model then record_text(value)
        # Time before Array: a Time in a polymorphic slot also matches Array
        # (NOTES rule 8).
        when Time then value.to_s
        when Array then list_text(value)
        when Cybertrain::Relation then relation_text(value)
        else inline(value)
        end
      end

      # A value on one line, as `inspect` would write it, cut at
      # MAX_VALUE_BYTES.
      def self.inline(value)
        case value
        when nil then "nil"
        when true then "true"
        when false then "false"
        when SafeString then string_text(value.to_s)
        when String then string_text(value)
        when Integer then value.to_s
        when Float then value.to_s
        when Symbol then ":#{value}"
        when Time then value.to_s
        when Array then cut("[#{value.map { |v| inline(v) }.join(", ")}]")
        when Hash then cut(hash_text(value))
        when Cybertrain::Errors then cut("#<Errors #{inline(value.full_messages)}>")
        when Cybertrain::Page then "#<Page number: #{value.number}, per: #{value.per}, next: #{value.next?}>"
        when Cybertrain::Model then cut(record_text(value))
        when Cybertrain::Relation then cut("#<#{value.class.name} #{value.to_sql}>")
        else "#<#{value.class.name}>"
        end
      end

      # `"text"`, the first MAX_VALUE_BYTES bytes only (then "…"); a binary
      # String (a BLOB cell or a binary attribute) as "<N bytes>".
      def self.string_text(s)
        text = s.to_s
        return Printer.bytes_text(text) if Printer.binary_string?(text)
        return text.inspect if text.bytesize <= MAX_VALUE_BYTES

        "#{head_bytes(text).inspect}#{ELLIPSIS}"
      end

      # `text` cut after MAX_VALUE_BYTES bytes, with "…".
      def self.cut(text)
        s = text.to_s
        return s if s.bytesize <= MAX_VALUE_BYTES

        "#{head_bytes(s)}#{ELLIPSIS}"
      end

      # The first MAX_VALUE_BYTES bytes of `s`, backed off to the start of a
      # UTF-8 character (a continuation byte is 0b10xxxxxx).
      def self.head_bytes(text)
        s = text.to_s
        n = MAX_VALUE_BYTES
        n -= 1 while n > 0 && s.getbyte(n) >= 128 && s.getbyte(n) < 192
        s.byteslice(0, n).to_s
      end

      def self.hash_text(h)
        parts = Array.new(0) { "" }
        h.each { |k, v| parts << "#{inline(k)} => #{inline(v)}" }
        "{#{parts.join(", ")}}"
      end

      # Every column, `id` first, each value inline.
      def self.record_text(rec)
        parts = Array.new(0) { "" }
        rec.attributes.each { |k, v| parts << "#{k}: #{inline(v)}" }
        "#<#{rec.class.name} #{parts.join(", ")}>"
      end

      def self.list_text(items)
        return "[]" if items.empty?

        records = true
        out = +""
        items.each do |item|
          out << format(item) << "\n"
          case item
          when Cybertrain::Model then nil
          else records = false
          end
        end
        n = items.size
        noun = records ? "record" : "element"
        out << "#{n} #{noun}#{n == 1 ? "" : "s"}"
        out
      end

      def self.relation_text(rel)
        text = +"#<#{rel.class.name} #{rel.to_sql}"
        binds = rel.binds
        text << " binds: " << inline(binds) unless binds.empty?
        text << ">\n"
        n = rel.count
        text << "#{n} record#{n == 1 ? "" : "s"}"
        text
      end

      # Rows of `sql` as a text table: a header, a rule, a line per row and
      # the row count. NULL for nil; a BLOB cell (a binary String) as
      # "<N bytes>"; a text cell's control bytes escaped ({escape_controls});
      # every cell cut at MAX_VALUE_BYTES.
      def self.rows_table(rows)
        return "(0 rows)" if rows.empty?

        names = rows[0].keys
        cells = Array.new(0) { Array.new(0) { "" } }
        widths = names.map { |n| n.size }
        rows.each do |row|
          line = Array.new(0) { "" }
          names.each_with_index do |name, i|
            text = cell_text(row[name])
            widths[i] = text.size if text.size > widths[i]
            line << text
          end
          cells << line
        end
        out = +""
        out << table_line(names, widths) << "\n"
        out << widths.map { |w| "-" * w }.join("-+-") << "\n"
        cells.each { |line| out << table_line(line, widths) << "\n" }
        out << "(#{rows.size} row#{rows.size == 1 ? "" : "s"})"
        out
      end

      def self.table_line(texts, widths)
        padded = Array.new(0) { "" }
        i = 0
        while i < texts.size
          padded << texts[i].ljust(widths[i])
          i += 1
        end
        padded.join(" | ").rstrip
      end

      # Bytes read from a BLOB come back tagged binary (the :binstr bridge);
      # text is UTF-8.
      def self.binary_string?(s)
        s.encoding.to_s == "ASCII-8BIT"
      end

      def self.bytes_text(s)
        "<#{s.bytesize} bytes>"
      end

      # A cell's text. A String cell's control bytes are escaped (`\e`,
      # `\n`, `\t`, `\r`, else `\xNN`), so an escape sequence in the
      # data never reaches the operator's terminal and a newline never
      # breaks the table; the rest of the text is shown as it is.
      def self.cell_text(v)
        case v
        when nil then "NULL"
        when String
          return Printer.bytes_text(v) if Printer.binary_string?(v)

          cut(Printer.escape_controls(v))
        else cut(inline(v))
        end
      end

      # `s` with its control bytes (0..31 and 127) escaped; `s` itself
      # when it has none. The console assumes a UTF-8 terminal, where the
      # C1 range (U+0080..U+009F, two bytes each in UTF-8) is not parsed as
      # 8-bit control sequences, so those are left as they are. A TEXT cell
      # with a NUL ends at the NUL before it gets here (Connection#read_row
      # reads TEXT through a NUL-terminated bridge; BLOBs keep every byte).
      def self.escape_controls(s)
        n = s.bytesize
        i = 0
        found = false
        while i < n
          b = s.getbyte(i)
          if b < 32 || b == 127
            found = true
            break
          end
          i += 1
        end
        return s unless found

        out = +""
        s.each_char do |c|
          b = c.getbyte(0)
          if c.bytesize == 1 && (b < 32 || b == 127)
            out << Printer.control_escape(b)
          else
            out << c
          end
        end
        out
      end

      def self.control_escape(b)
        case b
        when 9 then "\\t"
        when 10 then "\\n"
        when 13 then "\\r"
        when 27 then "\\e"
        else "\\x#{b.to_s(16).upcase.rjust(2, "0")}"
        end
      end
    end
  end
end
