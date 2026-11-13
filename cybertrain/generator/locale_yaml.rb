# The reader of the YAML subset of spec section 8, which gen uses for
# config/locales/**/*.yml (Gen::LocaleYaml.parse(text, path) ->
# Array<LocaleEntry>, one entry per leaf key, in file order). Hand-written:
# ruling F1 of the phase 4b pre-flight dropped Psych, and spike item 6a
# measured this reader on rails-i18n's en.yml and ja.yml.
#
# What it reads: a leading `---`, a BOM, CRLF, comments, nested block
# mappings, plain / single-quoted ('' escape) / double-quoted (\n \t \" \\
# \/ \uXXXX escapes) scalars on one line, `|` and `>` block scalars with
# `-` / `+` chomping, block sequences of scalars (also at the parent key's
# indentation, as rails-i18n writes them), flow `[a, b]` of scalars, and
# `~` / `null` / an empty value as "". Every scalar is kept as its text
# (D4: `3` -> "3", `no` -> "no", `:year` -> ":year"); entry_null tells a
# `~` / `null` / `Null` / `NULL` / empty value from a quoted "". The top-level key must be a
# locale unless parse's locale_root is false (test/fixtures/*.yml, whose
# top-level keys are fixture labels).
#
# Refused, as ArgumentError "path:line: problem": tabs in indentation,
# anchors and aliases, tags, a second document, flow mappings, a duplicate
# key, an unterminated quoted string, a top-level key that is not a locale,
# a sequence item that is not a scalar, quoted keys, text after a closed
# quote or flow sequence, a bad \u escape, a block scalar header other than
# | or > with - or +. Multi-line plain and quoted scalars are outside the
# subset: a continuation line is refused as "expected a key followed by
# ":"; multi-line scalars are not supported, use | or >".
#
# Spinel rules followed: 58 (each message is built into a local before
# raise), 62 (the text is read through a fresh local), 10/34/41 (every
# method name here is new, or has one return type).
module Cybertrain
  module Gen
    # One dictionary key: a String (entry_text) or a sequence of Strings
    # (entry_list, entry_is_list true). entry_null is true when the value
    # was `~`, `null` or nothing at all (entry_text is "" then, as it is for
    # a quoted "").
    class LocaleEntry
      attr_reader :entry_key, :entry_text, :entry_list, :entry_is_list, :entry_file, :entry_line, :entry_null

      def initialize(key, text, list, is_list, file, line, null = false)
        @entry_key = key
        @entry_text = text
        @entry_list = list
        @entry_is_list = is_list
        @entry_file = file
        @entry_line = line
        @entry_null = null
      end
    end

    module LocaleYaml
      # The entries of one dictionary file, in file order. With
      # locale_root false any plain key may be at the top (a fixture file's
      # labels).
      def self.parse(text, path, locale_root = true)
        mappings = { "" => 0 }
        mappings.delete("")
        LocaleYaml.parse_recording(text, path, mappings, locale_root)
      end

      # parse, also filling `mappings` with each key that holds a nested
      # mapping ("ja.posts") => its line: LocaleScan names that line when
      # another file gives the key a value (plan decision D4).
      def self.parse_recording(text, path, mappings, locale_root = true)
        # File.read answers the locale's encoding (US-ASCII under LANG=C):
        # the text is read as UTF-8, as http/query.rb does.
        raw = text.to_s
        s = raw.encoding.to_s == "UTF-8" ? raw : raw.dup.force_encoding("UTF-8")
        s = s.byteslice(3, s.bytesize - 3).to_s if s.start_with?("\uFEFF")
        s = s.gsub("\r\n", "\n")
        lines = s.split("\n", -1)
        # The text after the final newline is not a line (|+ keeps blanks).
        lines.pop if !lines.empty? && lines[lines.size - 1].empty?
        out = []
        prefixes = []
        indents = []
        seen = {}
        started = false
        i = 0
        while i < lines.size
          line = lines[i]
          number = i + 1
          i += 1
          next if LocaleYaml.blank_line?(line)

          if line.start_with?("---") && (line.size == 3 || line[3] == " ")
            if started
              message = "#{path}:#{number}: only one document per file"
              raise ArgumentError, message
            end
            rest = LocaleYaml.strip_comment(line[3, line.size - 3].to_s).strip
            unless rest.empty?
              message = "#{path}:#{number}: nothing may follow --- on its line"
              raise ArgumentError, message
            end
            next
          end
          indent = LocaleYaml.indent_of(line, path, number)
          content = line[indent, line.size - indent].to_s
          if content.start_with?("-")
            message = "#{path}:#{number}: a sequence must be the value of a key"
            raise ArgumentError, message
          end
          started = true
          while !indents.empty? && indents[indents.size - 1] >= indent
            indents.pop
            prefixes.pop
          end
          if content.start_with?("'") || content.start_with?("\"")
            message = "#{path}:#{number}: quoted keys are not supported"
            raise ArgumentError, message
          end
          colon = LocaleYaml.key_colon(content)
          if colon < 0
            message = "#{path}:#{number}: expected a key followed by \":\"; multi-line scalars are not supported, use | or >"
            raise ArgumentError, message
          end
          name = content[0, colon].to_s.strip
          if prefixes.empty? && locale_root && !LocaleYaml.locale_name?(name)
            message = "#{path}:#{number}: the top-level key must be a locale such as en or pt-BR (got #{name.inspect})"
            raise ArgumentError, message
          end
          full = prefixes.empty? ? name : "#{prefixes[prefixes.size - 1]}.#{name}"
          if seen.key?(full)
            message = "#{path}:#{number}: duplicate key #{name.inspect}"
            raise ArgumentError, message
          end
          seen[full] = true
          rest = LocaleYaml.strip_comment(content[colon + 1, content.size - colon - 1].to_s).strip
          if rest.empty?
            # A nested mapping, a block sequence, or an empty value.
            j = LocaleYaml.next_content(lines, i)
            next_indent = j < lines.size ? LocaleYaml.indent_of(lines[j], path, j + 1) : -1
            next_text = j < lines.size ? lines[j][next_indent, lines[j].size - next_indent].to_s : ""
            if j < lines.size && next_indent >= indent && next_text.start_with?("-") && (next_text.size == 1 || next_text[1] == " ")
              items = []
              while j < lines.size && LocaleYaml.indent_of(lines[j], path, j + 1) == next_indent
                item = lines[j][next_indent, lines[j].size - next_indent].to_s
                break unless item.start_with?("-") && (item.size == 1 || item[1] == " ")

                items << LocaleYaml.item_text(item[1, item.size - 1].to_s.strip, path, j + 1)
                j = LocaleYaml.next_content(lines, j + 1)
              end
              out << LocaleEntry.new(full, "", items, true, path, number)
              i = j
            elsif j < lines.size && next_indent > indent
              prefixes << full
              mappings[full] = number
              indents << indent
            else
              out << LocaleEntry.new(full, "", [], false, path, number, true)
            end
          elsif rest.start_with?("|") || rest.start_with?(">")
            unless rest == "|" || rest == ">" || rest.size == 2 && (rest[1] == "-" || rest[1] == "+")
              message = "#{path}:#{number}: unsupported block scalar header #{rest.inspect}"
              raise ArgumentError, message
            end
            j = i
            body = []
            while j < lines.size && (LocaleYaml.blank_text?(lines[j]) || LocaleYaml.indent_of(lines[j], path, j + 1) > indent)
              body << lines[j]
              j += 1
            end
            out << LocaleEntry.new(full, LocaleYaml.block_text(rest, body), [], false, path, number)
            i = j
          elsif rest.start_with?("[")
            out << LocaleEntry.new(full, "", LocaleYaml.flow_items(rest, path, number), true, path, number)
          else
            out << LocaleEntry.new(full, LocaleYaml.scalar_text(rest, path, number), [], false, path, number, LocaleYaml.null_word?(rest))
          end
        end
        out
      end

      def self.blank_text?(line) = line.strip.empty?

      # YAML's plain null words (`~`, `null`, `Null`, `NULL`): entry_null
      # is true for them. Their entry_text is unchanged (`NULL` stays
      # "NULL" in a dictionary; `~` and `null` are "").
      def self.null_word?(text) = %w[~ null Null NULL].include?(text)

      def self.blank_line?(line)
        t = line.strip
        t.empty? || t.start_with?("#")
      end

      # The index of the first line at or after j with content.
      def self.next_content(lines, j)
        k = j
        k += 1 while k < lines.size && LocaleYaml.blank_line?(lines[k])
        k
      end

      def self.indent_of(line, path, number)
        n = 0
        n += 1 while n < line.size && line[n] == " "
        if n < line.size && line[n] == "\t"
          message = "#{path}:#{number}: tabs are not allowed in indentation"
          raise ArgumentError, message
        end
        n
      end

      def self.locale_name?(name) = name.match?(/\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})*\z/)

      # The index of the ":" ending a plain key (followed by a space or the
      # end of the line), or -1.
      def self.key_colon(content)
        k = 0
        while k < content.size
          return k if content[k] == ":" && (k + 1 == content.size || content[k + 1] == " ")

          k += 1
        end
        -1
      end

      # The text before a ` #` comment, outside quotes.
      def self.strip_comment(text)
        quote = ""
        k = 0
        while k < text.size
          c = text[k]
          if quote.empty?
            if c == "'" || c == "\""
              quote = c
            elsif c == "#" && (k == 0 || text[k - 1] == " ")
              return text[0, k].to_s
            end
          elsif c == "\\" && quote == "\""
            k += 1
          elsif c == quote
            quote = ""
          end
          k += 1
        end
        text
      end

      def self.item_text(text, path, number)
        nested = text.start_with?("[") || text.start_with?("{") || text.start_with?("|") || text.start_with?(">") || text == "-" || text.start_with?("- ")
        if nested || !text.start_with?("'") && !text.start_with?("\"") && !text.start_with?(":") && LocaleYaml.key_colon(text) > 0
          message = "#{path}:#{number}: sequences may hold only scalars"
          raise ArgumentError, message
        end
        LocaleYaml.scalar_text(text, path, number)
      end

      def self.scalar_text(text, path, number)
        t = text.strip
        if t.start_with?("&") || t.start_with?("*")
          message = "#{path}:#{number}: anchors and aliases are not supported"
          raise ArgumentError, message
        end
        if t.start_with?("!")
          message = "#{path}:#{number}: tags are not supported"
          raise ArgumentError, message
        end
        if t.start_with?("{")
          message = "#{path}:#{number}: flow mappings are not supported; flow sequences may hold only scalars"
          raise ArgumentError, message
        end
        return LocaleYaml.single_quoted(t, path, number) if t.start_with?("'")
        return LocaleYaml.double_quoted(t, path, number) if t.start_with?("\"")
        return "" if t == "~" || t == "null" || t.empty?

        t
      end

      def self.single_quoted(t, path, number)
        out = +""
        k = 1
        while k < t.size
          c = t[k]
          if c == "'"
            if k + 1 < t.size && t[k + 1] == "'"
              out << "'"
              k += 2
              next
            end
            LocaleYaml.nothing_after(t, k + 1, "a quoted string", path, number)
            return out
          end
          out << c
          k += 1
        end
        message = "#{path}:#{number}: unterminated quoted string"
        raise ArgumentError, message
      end

      def self.double_quoted(t, path, number)
        out = +""
        k = 1
        while k < t.size
          c = t[k]
          if c == "\""
            LocaleYaml.nothing_after(t, k + 1, "a quoted string", path, number)
            return out
          end

          if c == "\\" && k + 1 < t.size
            e = t[k + 1]
            k += 2
            case e
            when "n" then out << "\n"
            when "t" then out << "\t"
            when "\"" then out << "\""
            when "\\" then out << "\\"
            when "/" then out << "/"
            when "u"
              code = LocaleYaml.hex4(t, k, path, number)
              k += 4
              if code >= 0xD800 && code <= 0xDBFF
                low = t[k, 2] == "\\u" ? LocaleYaml.hex4(t, k + 2, path, number) : 0
                if low < 0xDC00 || low > 0xDFFF
                  message = "#{path}:#{number}: invalid \\u escape"
                  raise ArgumentError, message
                end
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                k += 6
              elsif code >= 0xDC00 && code <= 0xDFFF
                message = "#{path}:#{number}: invalid \\u escape"
                raise ArgumentError, message
              end
              out << code.chr(Encoding::UTF_8)
            else
              message = "#{path}:#{number}: unknown escape \\#{e}"
              raise ArgumentError, message
            end
            next
          end
          out << c
          k += 1
        end
        message = "#{path}:#{number}: unterminated quoted string"
        raise ArgumentError, message
      end

      # The four hex digits at t[k, 4] as an Integer, else the refusal.
      def self.hex4(t, k, path, number)
        digits = t[k, 4].to_s
        unless digits.size == 4 && digits.match?(/\A[0-9a-fA-F]{4}\z/)
          message = "#{path}:#{number}: invalid \\u escape"
          raise ArgumentError, message
        end
        digits.to_i(16)
      end

      # Refuses anything but blanks in t from index k, after a closed quote or bracket.
      def self.nothing_after(t, k, what, path, number)
        return if t[k, t.size - k].to_s.strip.empty?

        message = "#{path}:#{number}: unexpected text after #{what}"
        raise ArgumentError, message
      end

      # The index of the first unquoted "]" in t, -1 if none, -2 if a nested [ or { comes first.
      def self.flow_close(t)
        quote = ""
        k = 1
        while k < t.size
          c = t[k]
          if quote.empty?
            return k if c == "]"
            return -2 if c == "[" || c == "{"

            quote = c if c == "'" || c == "\""
          elsif c == "\\" && quote == "\""
            k += 1
          elsif c == quote
            quote = ""
          end
          k += 1
        end
        -1
      end

      # `[a, 'b', "c"]`: scalars only.
      def self.flow_items(t, path, number)
        close = LocaleYaml.flow_close(t)
        if close == -2
          message = "#{path}:#{number}: flow mappings are not supported; flow sequences may hold only scalars"
          raise ArgumentError, message
        end
        if close < 0
          message = "#{path}:#{number}: unterminated flow sequence"
          raise ArgumentError, message
        end
        LocaleYaml.nothing_after(t, close + 1, "a flow sequence", path, number)
        inner = t[1, close - 1].to_s
        items = []
        return items if inner.strip.empty?

        part = +""
        quote = ""
        k = 0
        while k < inner.size
          c = inner[k]
          if quote.empty? && c == ","
            items << LocaleYaml.flow_item(part, path, number)
            part = +""
          else
            if quote.empty? && (c == "'" || c == "\"")
              quote = c
            elsif c == quote
              quote = ""
            end
            part << c
          end
          k += 1
        end
        items << LocaleYaml.flow_item(part, path, number)
        items
      end

      def self.flow_item(part, path, number)
        t = part.strip
        if t.start_with?("[") || t.start_with?("{")
          message = "#{path}:#{number}: flow mappings are not supported; flow sequences may hold only scalars"
          raise ArgumentError, message
        end
        LocaleYaml.scalar_text(t, path, number)
      end

      # A `|` or `>` block scalar's text from its header and its lines.
      def self.block_text(header, body)
        chomp = header.include?("-") ? "strip" : (header.include?("+") ? "keep" : "clip")
        width = -1
        body.each do |l|
          next if l.strip.empty?

          n = 0
          n += 1 while n < l.size && l[n] == " "
          width = n if width < 0 || n < width
        end
        texts = body.map { |l| l.strip.empty? ? "" : l[width, l.size - width].to_s }
        trailing = 0
        trailing += 1 while trailing < texts.size && texts[texts.size - 1 - trailing].empty?
        kept = texts[0, texts.size - trailing]
        out = +""
        if header.start_with?(">")
          k = 0
          while k < kept.size
            line = kept[k]
            if k > 0
              prev = kept[k - 1]
              if line.empty?
                out << "\n"
              elsif !prev.empty? && !line.start_with?(" ") && !prev.start_with?(" ")
                out << " "
              elsif !prev.empty?
                out << "\n"
              end
            end
            out << line
            k += 1
          end
        else
          out << kept.join("\n")
        end
        return out if chomp == "strip" || kept.empty?
        return "#{out}\n" if chomp == "clip"

        "#{out}#{"\n" * (trailing + 1)}"
      end
    end
  end
end
