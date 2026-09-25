# Cybertrain::Template::Lexer -- splits an ERB-syntax template into tokens.
#
#   <% code %>   <%= escaped output %>   <%== raw output %>   <%# comment %>
#
# A <% %> or <%# %> tag that stands alone on its line swallows its
# indentation and the newline after it (what Rails' ERB does), so control
# flow does not leave blank lines in the HTML. <%- strips the indentation
# before a tag and -%> the newline after it, for any tag kind. <%% is a
# literal "<%" in text and %%> a literal "%>" inside a tag.
require "cybertrain/template/ast"

module Cybertrain
  module Template
    class Token
      attr_reader :kind, :text, :line   # kind: :text :code :output :output_raw :comment

      def initialize(kind, text, line)
        @kind = kind
        @text = text
        @line = line
      end
    end

    module Lexer
      def self.tokenize(source, name)
        tokens = Array.new(0) { Token.new(:text, "", 0) }
        text = +""
        text_line = 1
        line = 1
        pos = 0
        n = source.length
        while pos < n
          open = source.index("<%", pos)
          if open.nil?
            text << source[pos, n - pos]
            break
          end
          chunk = source[pos, open - pos]
          text << chunk
          line += chunk.count("\n")
          if source[open + 2] == "%"
            text << "<%"
            pos = open + 3
            next
          end

          tag_line = line
          kind = :code
          start = open + 2
          trim_left = false
          c = source[start]
          if c == "="
            if source[start + 1] == "="
              kind = :output_raw
              start += 2
            else
              kind = :output
              start += 1
            end
          elsif c == "#"
            kind = :comment
            start += 1
          elsif c == "-"
            trim_left = true
            start += 1
          end

          # Find the closing %>, turning each %%> on the way into a literal %>.
          code = +""
          close = -1
          j = start
          while close < 0
            k = source.index("%>", j)
            raise SyntaxError, "#{name}:#{tag_line}: unterminated <% tag" if k.nil?
            if k > j && source[k - 1] == "%"
              code << source[j, k - 1 - j] << "%>"
              j = k + 2
            else
              code << source[j, k - j]
              close = k
            end
          end
          line += source[open, close - open].count("\n")
          pos = close + 2

          trim_right = code.end_with?("-")
          code = code[0, code.length - 1] if trim_right

          indent = indentation_before(source, open)
          after = newline_after(source, pos)
          alone = indent >= 0 && after >= 0
          if trim_left || ((kind == :code || kind == :comment) && alone)
            text = text[0, text.length - indent] if indent > 0
          end
          if trim_right || ((kind == :code || kind == :comment) && alone)
            if after >= 0 && after < n
              pos = after + 1
              line += 1
            end
          end

          tokens << Token.new(:text, text, text_line) unless text.empty?
          tokens << Token.new(kind, code.strip, tag_line)
          text = +""
          text_line = line
        end
        tokens << Token.new(:text, text, text_line) unless text.empty?
        tokens
      end

      # The number of spaces/tabs between the start of the line and the tag
      # at `open`, or -1 when something else precedes the tag on its line.
      def self.indentation_before(source, open)
        i = open - 1
        while i >= 0
          c = source[i]
          return open - 1 - i if c == "\n"
          return -1 unless c == " " || c == "\t"
          i -= 1
        end
        open
      end

      # The index of the newline ending the tag's line (source.length at the
      # end of the source), or -1 when more than whitespace follows the tag.
      def self.newline_after(source, pos)
        i = pos
        n = source.length
        while i < n
          c = source[i]
          return i if c == "\n"
          return -1 unless c == " " || c == "\t" || c == "\r"
          i += 1
        end
        n
      end

      # Rails 7.1 strict locals: a `<%# locals: (post:, title:) %>` comment on
      # line 1 declares the only locals a partial accepts.
      def self.strict_locals?(tokens)
        !locals_comment(tokens).empty?
      end

      def self.strict_locals(tokens, name)
        names = Array.new(0) { "" }
        comment = locals_comment(tokens)
        return names if comment.empty?

        spec = comment[7, comment.length - 7].strip
        unless spec.start_with?("(") && spec.end_with?(")")
          raise SyntaxError, "#{name}:1: bad strict locals comment (expected locals: (name:, ...))"
        end
        inner = spec[1, spec.length - 2].strip
        return names if inner.empty?

        inner.split(",").each do |entry|
          e = entry.strip
          unless e.end_with?(":") && identifier?(e[0, e.length - 1])
            raise SyntaxError, "#{name}:1: bad strict locals entry '#{e}' (expected name:)"
          end
          names << e[0, e.length - 1]
        end
        names
      end

      # The text of the line-1 "locals:" comment, or "" when there is none.
      def self.locals_comment(tokens)
        tokens.each do |t|
          return "" if t.line > 1
          return t.text if t.kind == :comment && t.text.start_with?("locals:")
        end
        ""
      end

      def self.identifier?(s)
        return false if s.empty?

        i = 0
        while i < s.length
          c = s[i]
          ok = (c >= "a" && c <= "z") || c == "_" || (i > 0 && c >= "0" && c <= "9")
          return false unless ok
          i += 1
        end
        true
      end
    end
  end
end
