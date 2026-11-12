module Cybertrain
  module Gen
    # A source file seen as code (TestScan reads class-form test files
    # through it): `codes` holds one String per line of `text.lines`, of
    # the same length character for character, with the inside of every
    # string, symbol, regexp, %-literal and heredoc body, every comment,
    # every =begin ... =end block and everything after __END__ turned into
    # spaces (the delimiters of an inline literal are kept). So a line that
    # merely looks like `end` or `test "x" do` inside a heredoc is blank
    # here, and a block's `end` can be searched for by indentation among
    # real code only. `code_start[i]` is false for a line that begins
    # inside such a construct. `error_line` (1-based; 0 when the file reads
    # through) is where a construct opened that never closes, and
    # `error_text` says which ("the heredoc <<~RUBY is not closed").
    #
    # A lexical approximation of Ruby's grammar, not a parser: a `/` or a
    # `%` is a literal's opener where an operand is expected (after an
    # operator, an opening bracket, a keyword, at the start of a line, or
    # after a method name and a space with no space after it), as Ruby
    # itself guesses; `<<~X`, `<<-X` and `<<X` (X uppercase or quoted) open
    # heredocs.
    class CodeView
      attr_reader :codes, :code_start, :error_line, :error_text

      KEYWORDS = %w[if unless when and or not return elsif while until puts p in then do].freeze
      OPERATORS = "(,=[{;|&!:+-*<>?~%^".freeze
      PERCENT_LETTERS = "qQwWiIrsx".freeze

      def initialize(text)
        @codes = Array.new(0) { "" }
        @code_start = Array.new(0) { false }
        @error_line = 0
        @error_text = ""
        # The open literals, innermost last: kind 1 a string-like literal
        # (closer, opener for nesting, depth, interpolating), kind 2 the
        # code of an interpolation `#{` inside one (depth counts braces).
        @kinds = Array.new(0) { 0 }
        @closes = Array.new(0) { "" }
        @opens = Array.new(0) { "" }
        @depths = Array.new(0) { 0 }
        @interps = Array.new(0) { false }
        @opened_at = Array.new(0) { 0 }
        # Heredocs announced on a line, read from the next one on.
        @tags = Array.new(0) { "" }
        @indented = Array.new(0) { false }
        @tag_lines = Array.new(0) { 0 }
        @tag_texts = Array.new(0) { "" }
        scan_text(text)
      end

      def self.blank(raw)
        out = +""
        raw.each_char { |ch| out << (ch == "\n" || ch == "\r" ? ch : " ") }
        out
      end

      private

      def scan_text(text)
        in_doc = 0
        ended = false
        heredoc_reading = false
        text.lines.each_with_index do |raw, n|
          if ended || in_doc > 0
            in_doc = 0 if in_doc > 0 && raw.start_with?("=end")
            blank_line(raw)
            next
          end
          if heredoc_reading && !@tags.empty?
            tag = @tags[0]
            done = @indented[0] ? raw.strip == tag : raw.chomp == tag
            if done
              @tags.shift
              @indented.shift
              @tag_lines.shift
              @tag_texts.shift
            end
            blank_line(raw)
            next
          end
          if @kinds.empty? && raw.start_with?("=begin")
            in_doc = n + 1
            blank_line(raw)
            next
          end
          if @kinds.empty? && raw.chomp == "__END__"
            ended = true
            blank_line(raw)
            next
          end
          @code_start << @kinds.empty?
          @codes << read_line(raw, n + 1)
          heredoc_reading = !@tags.empty?
        end
        if in_doc > 0
          fail_at(in_doc, "=begin is not closed")
        elsif !@tags.empty?
          fail_at(@tag_lines[0], "the heredoc #{@tag_texts[0]} is not closed")
        elsif !@kinds.empty?
          fail_at(@opened_at[0], "the string opened here is not closed")
        end
        nil
      end

      def fail_at(line, text)
        @error_line = line
        @error_text = text
        nil
      end

      def blank_line(raw)
        @code_start << false
        @codes << CodeView.blank(raw)
        nil
      end

      def push(kind, close, open, interp, line)
        @kinds << kind
        @closes << close
        @opens << open
        @depths << 0
        @interps << interp
        @opened_at << line
        nil
      end

      def pop
        @kinds.pop
        @closes.pop
        @opens.pop
        @depths.pop
        @interps.pop
        @opened_at.pop
        nil
      end

      # One line in its code form; the open literals carry over.
      def read_line(raw, number)
        cs = raw.chars
        out = Array.new(0) { "" }
        i = 0
        while i < cs.size
          ch = cs[i].to_s
          nxt = cs[i + 1].to_s
          if ch == "\n" || ch == "\r"
            out << ch
            i += 1
            next
          end
          if !@kinds.empty? && @kinds.last == 1
            i = string_char(cs, out, i, ch, nxt)
            next
          end
          if ch == "#"
            while i < cs.size && cs[i] != "\n" && cs[i] != "\r"
              out << " "
              i += 1
            end
            next
          end
          if !@kinds.empty? && @kinds.last == 2 && (ch == "{" || ch == "}")
            if ch == "{"
              @depths[@depths.size - 1] += 1
              out << ch
            elsif @depths.last.zero?
              pop
              out << " "
            else
              @depths[@depths.size - 1] -= 1
              out << ch
            end
            i += 1
            next
          end
          if ch == "\"" || ch == "'" || ch == "`"
            push(1, ch, ch, ch != "'", number)
            out << ch
            i += 1
            next
          end
          if ch == "%"
            used = percent_literal(cs, out, i, number)
            if used > 0
              i += used
              next
            end
          end
          if ch == "/" && operand_expected?(out, nxt)
            push(1, "/", "/", true, number)
            out << ch
            i += 1
            next
          end
          if ch == "<" && nxt == "<"
            used = heredoc_opener(cs, out, i, number)
            if used > 0
              i += used
              next
            end
            out << "<"
            out << "<"
            i += 2
            next
          end
          if ch == "?" && (nxt == "\"" || nxt == "'" || nxt == "`" || nxt == "#") && after_space?(out)
            out << ch
            out << " "
            i += 2
            next
          end
          out << ch
          i += 1
        end
        out.join
      end

      # A character inside a string-like literal; answers the next index.
      def string_char(cs, out, i, ch, nxt)
        if ch == "\\"
          out << " "
          if nxt != "" && nxt != "\n" && nxt != "\r"
            out << " "
            return i + 2
          end
          return i + 1
        end
        if @interps.last && ch == "#" && nxt == "{"
          push(2, "}", "{", false, @opened_at.last)
          out << " "
          out << " "
          return i + 2
        end
        if @opens.last != @closes.last && ch == @opens.last
          @depths[@depths.size - 1] += 1
          out << " "
          return i + 1
        end
        if ch == @closes.last
          if @depths.last.positive?
            @depths[@depths.size - 1] -= 1
            out << " "
          else
            pop
            out << ch
          end
          return i + 1
        end
        out << " "
        i + 1
      end

      # %w[...], %q(...), %(...): opened as a literal (its opening chars
      # kept); answers the characters used, 0 when `%` is an operator.
      def percent_literal(cs, out, i, number)
        letter = cs[i + 1].to_s
        delim = cs[i + 2].to_s
        used = 3
        if letter.empty? || !PERCENT_LETTERS.include?(letter) || !delimiter?(delim)
          delim = letter
          letter = ""
          used = 2
          return 0 unless delimiter?(delim) && "([{<|!/^".include?(delim) && operand_expected?(out, cs[i + 2].to_s)
        end
        close = closer(delim)
        push(1, close, delim, letter.empty? || "QWIrx".include?(letter), number)
        out << "%"
        out << letter unless letter.empty?
        out << delim
        used
      end

      def delimiter?(ch)
        return false if ch.empty? || ch == " " || ch == "\n" || ch == "\r" || ch == "\t"

        !word_char?(ch)
      end

      def closer(delim)
        return ")" if delim == "("
        return "]" if delim == "["
        return "}" if delim == "{"
        return ">" if delim == "<"

        delim
      end

      # `<<~TAG`, `<<-TAG`, `<<TAG` (uppercase) or a quoted tag: queued,
      # its chars kept; answers the characters used, 0 for an operator.
      def heredoc_opener(cs, out, i, number)
        j = i + 2
        dashed = cs[j] == "~" || cs[j] == "-"
        j += 1 if dashed
        first = cs[j].to_s
        tag = +""
        if first == "\"" || first == "'" || first == "`"
          k = j + 1
          while k < cs.size && cs[k] != first && cs[k] != "\n"
            tag << cs[k].to_s
            k += 1
          end
          return 0 if k >= cs.size || cs[k] != first || tag.empty?

          k += 1
        else
          return 0 unless word_start?(first)
          return 0 unless dashed || (first >= "A" && first <= "Z" && (after_space?(out) || out.empty? || OPERATORS.include?(last_code(out))))

          k = j
          while k < cs.size && word_char?(cs[k].to_s)
            tag << cs[k].to_s
            k += 1
          end
        end
        @tags << tag
        @indented << dashed
        @tag_lines << number
        opener = +""
        (i...k).each { |m| opener << cs[m].to_s }
        @tag_texts << opener
        (i...k).each { |m| out << cs[m].to_s }
        k - i
      end

      # Whether a `/` or `%` here opens a literal: an operand is expected
      # after what the line holds so far (`nxt` is the character after it).
      def operand_expected?(out, nxt)
        prev = last_code(out)
        return true if prev.empty? || OPERATORS.include?(prev)
        return false unless word_char?(prev)

        return true if KEYWORDS.include?(last_word(out))

        after_space?(out) && nxt != " " && nxt != "=" && nxt != ""
      end

      def last_code(out)
        k = out.size - 1
        k -= 1 while k >= 0 && (out[k] == " " || out[k] == "\t")
        k >= 0 ? out[k].to_s : ""
      end

      def last_word(out)
        k = out.size - 1
        k -= 1 while k >= 0 && (out[k] == " " || out[k] == "\t")
        word = +""
        while k >= 0 && word_char?(out[k].to_s)
          word = "#{out[k]}#{word}"
          k -= 1
        end
        word
      end

      def after_space?(out)
        !out.empty? && (out.last == " " || out.last == "\t" || out.last == "(" || out.last == ",")
      end

      def word_start?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch == "_"
      end

      def word_char?(ch)
        word_start?(ch) || (ch >= "0" && ch <= "9")
      end
    end
  end
end
