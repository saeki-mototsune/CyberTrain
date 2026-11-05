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
        when Cybertrain::Model then record(value)
        # Time before Array: a Time in a polymorphic slot also matches Array
        # (NOTES rule 8).
        when Time then value.to_s
        when Array then list(value)
        when Cybertrain::Relation then relation(value)
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
        when SafeString then string(value.to_s)
        when String then string(value)
        when Integer then value.to_s
        when Float then value.to_s
        when Symbol then ":#{value}"
        when Time then value.to_s
        when Array then cut("[#{value.map { |v| inline(v) }.join(", ")}]")
        when Hash then cut(hash(value))
        when Cybertrain::Errors then cut("#<Errors #{inline(value.full_messages)}>")
        when Cybertrain::Page then "#<Page number: #{value.number}, per: #{value.per}, next: #{value.next?}>"
        when Cybertrain::Model then cut(record(value))
        when Cybertrain::Relation then cut("#<#{value.class.name} #{value.to_sql}>")
        else "#<#{value.class.name}>"
        end
      end

      # `"text"`, the first MAX_VALUE_BYTES bytes only (then "…").
      def self.string(s)
        text = s.to_s
        return text.inspect if text.bytesize <= MAX_VALUE_BYTES

        "#{head(text).inspect}#{ELLIPSIS}"
      end

      # `text` cut after MAX_VALUE_BYTES bytes, with "…".
      def self.cut(text)
        s = text.to_s
        return s if s.bytesize <= MAX_VALUE_BYTES

        "#{head(s)}#{ELLIPSIS}"
      end

      # The first MAX_VALUE_BYTES bytes of `s`, backed off to the start of a
      # UTF-8 character (a continuation byte is 0b10xxxxxx).
      def self.head(text)
        s = text.to_s
        n = MAX_VALUE_BYTES
        n -= 1 while n > 0 && s.getbyte(n) >= 128 && s.getbyte(n) < 192
        s.byteslice(0, n).to_s
      end

      def self.hash(h)
        parts = Array.new(0) { "" }
        h.each { |k, v| parts << "#{inline(k)} => #{inline(v)}" }
        "{#{parts.join(", ")}}"
      end

      # Every column, `id` first, each value inline.
      def self.record(rec)
        parts = Array.new(0) { "" }
        rec.attributes.each { |k, v| parts << "#{k}: #{inline(v)}" }
        "#<#{rec.class.name} #{parts.join(", ")}>"
      end

      def self.list(items)
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

      def self.relation(rel)
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
      # "<N bytes>"; every cell cut at MAX_VALUE_BYTES.
      def self.table(rows)
        return "(0 rows)" if rows.empty?

        names = rows[0].keys
        cells = Array.new(0) { Array.new(0) { "" } }
        widths = names.map { |n| n.size }
        rows.each do |row|
          line = Array.new(0) { "" }
          names.each_with_index do |name, i|
            text = cell(row[name])
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

      def self.cell(v)
        case v
        when nil then "NULL"
        when String
          return "<#{v.bytesize} bytes>" if v.encoding.to_s == "ASCII-8BIT"

          cut(v)
        else cut(inline(v))
        end
      end
    end
  end
end
