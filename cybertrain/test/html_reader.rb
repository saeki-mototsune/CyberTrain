# Cybertrain::Test::HtmlReader -- the test-only reader of the HTML the
# framework writes, behind `assert_select` (spec section 9.2) and
# `assert_turbo_stream`.
#
#   nodes = Cybertrain::Test::HtmlReader.parse(%(<ul><li class="a">x</li></ul>))
#   nodes[1].node_tag          # => "li"
#   nodes[1].node_attr("class") # => "a"
#   nodes[1].node_text         # => "x"
#
# It reads well-formed HTML: start and end tags, void elements, quoted,
# unquoted and boolean attributes, character references in text and in
# attribute values, comments, the doctype and processing instructions
# skipped, `script` / `style` content raw, `textarea` / `title` content text
# (references decoded, no tags). Tag and attribute names are lower-cased.
# It is not a repairing HTML5 parser: a mismatched, unexpected or missing
# end tag, an unterminated tag, comment or quoted value, and a self-closing
# `<div/>` (which HTML would leave open) raise Malformed with the 0-based
# byte offset, so an assertion fails rather than matching against a tree
# the browser would not build. `<x/>` closes itself for void elements and
# inside `svg` / `math`.
#
# A byte scanner (spikes/NOTES.md rule 62): every scanning method reads its
# String parameter through a fresh local (`s = html.to_s`).
require "cybertrain/test"

module Cybertrain
  module Test
    # One element of a document HtmlReader.parse read.
    # @api public
    class HtmlNode
      # The lower-cased tag name (`"div"`).
      # @return [String]
      # @api public
      attr_reader :node_tag

      # The position of this element in the document order Array
      # HtmlReader.parse answers.
      # @return [Integer]
      # @api public
      attr_reader :node_index

      # The position of the parent element in that Array; -1 for an element
      # at the top of the document.
      # @return [Integer]
      # @api public
      attr_reader :node_parent_index

      # The child elements, in document order (text is not a node).
      # @return [Array<HtmlNode>]
      # @api public
      attr_reader :node_children

      # @api private
      def initialize(tag, index, parent_index, start)
        @node_tag = tag
        @node_index = index
        @node_parent_index = parent_index
        @node_start = start
        @node_html = ""
        @node_text = +""
        @attr_names = Array.new(0) { "" }
        @attr_values = Array.new(0) { "" }
        # Seeded with the element type (rule 9); the block never runs.
        @node_children = Array.new(0) { HtmlNode.new("", 0, -1, 0) }
      end

      # The attribute's value, references decoded; "" when the element has
      # no such attribute (see {node_attr?}). The name is lower-cased.
      # @param name [String]
      # @return [String]
      # @api public
      def node_attr(name)
        k = attr_position(name)
        return "" if k < 0

        @attr_values[k]
      end

      # Whether the element has the attribute (a boolean one included).
      # @param name [String]
      # @return [Boolean]
      # @api public
      def node_attr?(name)
        attr_position(name) >= 0
      end

      # The attribute names, lower-cased, in source order.
      # @return [Array<String>]
      # @api public
      def node_attr_names
        @attr_names
      end

      # The text of every descendant, references decoded, as written
      # (`script` / `style` content included, raw); `assert_select`'s
      # `text:` compares it after collapsing whitespace.
      # @return [String]
      # @api public
      def node_text
        @node_text
      end

      # The element's source, from its `<` to the end of its end tag.
      # @return [String]
      # @api public
      def node_html
        @node_html
      end

      # The element's byte offset in the source.
      # @return [Integer]
      # @api private
      def node_start
        @node_start
      end

      # @api private
      def add_node_attr(name, value)
        # The first of a repeated attribute wins, as in HTML.
        return nil if attr_position(name) >= 0

        @attr_names << name
        @attr_values << value
        nil
      end

      # @api private
      def add_node_text(text)
        @node_text << text
        nil
      end

      # @api private
      def add_node_child(node)
        @node_children << node
        nil
      end

      # @api private
      def close_node(html)
        @node_html = html
        nil
      end

      private

      def attr_position(name)
        want = name.to_s.downcase
        k = 0
        while k < @attr_names.length
          return k if @attr_names[k] == want

          k += 1
        end
        -1
      end
    end

    # The reader: HtmlReader.parse(html) answers every element in document
    # order. See the file's comment for what it reads and refuses.
    # @api public
    module HtmlReader
      # What parse raises on HTML it does not read: the message names the
      # problem and the 0-based byte offset of its `<`.
      # @api public
      class Malformed < StandardError
      end

      # The elements that never have content or an end tag.
      VOID = %w[area base br col embed hr img input link meta source track wbr].freeze

      # Content up to the matching end tag, as is.
      RAW_TEXT = %w[script style].freeze

      # Content up to the matching end tag, references decoded, no tags.
      ESCAPABLE_RAW_TEXT = %w[textarea title].freeze

      # Subtrees in which `<x/>` closes the element (foreign content).
      FOREIGN = %w[svg math].freeze

      # The named character references decoded (the framework writes the
      # first five; the rest are the ones templates commonly write by hand).
      # Any other `&name;` stays as written.
      NAMED = {
        "amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " ",
        "copy" => "©", "reg" => "®", "trade" => "™", "hellip" => "…", "mdash" => "—",
        "ndash" => "–", "laquo" => "«", "raquo" => "»", "lsquo" => "‘", "rsquo" => "’",
        "ldquo" => "“", "rdquo" => "”", "times" => "×", "middot" => "·", "bull" => "•",
        "rarr" => "→", "larr" => "←", "uarr" => "↑", "darr" => "↓", "deg" => "°",
        "euro" => "€", "yen" => "¥", "pound" => "£", "sect" => "§", "para" => "¶"
      }.freeze

      # Every element of `html`, in document order; each knows its parent's
      # position (HtmlNode#node_parent_index) and its children.
      # @param html [String]
      # @return [Array<HtmlNode>]
      # @raise [Malformed] on a mismatched, unexpected or missing end tag,
      #   an unterminated tag, comment or quoted value, or `<div/>`
      # @api public
      def self.parse(html)
        s = html.to_s
        nodes = Array.new(0) { HtmlNode.new("", 0, -1, 0) }
        stack = Array.new(0) { 0 }
        n = s.bytesize
        i = 0
        run = 0
        while i < n
          b = s.getbyte(i)
          if b != 60 # <
            i += 1
            next
          end
          kind = tag_kind(s, i)
          if kind == 0
            i += 1
            next
          end
          add_node_texts(nodes, stack, decode_references(s.byteslice(run, i - run))) if i > run
          case kind
          when 1 # comment
            close = byte_after(s, i + 4, "-->")
            if close < 0
              message = "unterminated comment at byte #{i}"
              raise Malformed, message
            end
            i = close
          when 2 # <!doctype ...>, <?...?>, other <!...>
            j = i + 2
            j += 1 while j < n && s.getbyte(j) != 62
            if j >= n
              message = "unterminated declaration at byte #{i}"
              raise Malformed, message
            end
            i = j + 1
          when 3 # end tag
            i = read_end_tag(s, i, nodes, stack)
          else # start tag
            i = read_start_tag(s, i, nodes, stack)
          end
          run = i
        end
        add_node_texts(nodes, stack, decode_references(s.byteslice(run, n - run))) if n > run
        unless stack.empty?
          top = nodes[stack[stack.length - 1]]
          message = "missing end tag </#{top.node_tag}> for <#{top.node_tag}> opened at byte #{top.node_start}"
          raise Malformed, message
        end
        nodes
      end

      # What starts at the `<` at byte i: 0 text (a `<` not followed by a
      # letter, `/` + letter, `!` or `?`), 1 a comment, 2 a declaration or
      # processing instruction, 3 an end tag, 4 a start tag.
      # @api private
      def self.tag_kind(html, i)
        s = html.to_s
        n = s.bytesize
        return 0 if i + 1 >= n

        c = s.getbyte(i + 1)
        return 4 if ascii_letter?(c)
        return 3 if c == 47 && i + 2 < n && ascii_letter?(s.getbyte(i + 2))
        if c == 33 # !
          return 1 if i + 3 < n && s.getbyte(i + 2) == 45 && s.getbyte(i + 3) == 45

          return 2
        end
        return 2 if c == 63 # ?

        0
      end

      # The byte offset just after the first `marker` at or after byte
      # `from`; -1 when there is none.
      # @api private
      def self.byte_after(html, from, marker)
        s = html.to_s
        m = marker.to_s
        n = s.bytesize
        len = m.bytesize
        j = from
        while j + len <= n
          return j + len if s.byteslice(j, len) == m

          j += 1
        end
        -1
      end

      # Reads the start tag whose `<` is at byte i, adds its element, and
      # answers the byte after it (after the content, for raw text).
      # @api private
      def self.read_start_tag(html, i, nodes, stack)
        s = html.to_s
        n = s.bytesize
        j = i + 1
        j += 1 while j < n && !tag_name_end?(s.getbyte(j))
        tag = s.byteslice(i + 1, j - i - 1).downcase
        parent = stack.empty? ? -1 : stack[stack.length - 1]
        node = HtmlNode.new(tag, nodes.length, parent, i)
        nodes << node
        nodes[parent].add_node_child(node) if parent >= 0
        self_closing = false
        done = false
        while !done
          j += 1 while j < n && html_space?(s.getbyte(j))
          if j >= n
            message = "unterminated tag <#{tag} at byte #{i}"
            raise Malformed, message
          end
          c = s.getbyte(j)
          if c == 62 # >
            j += 1
            done = true
          elsif c == 47 && j + 1 < n && s.getbyte(j + 1) == 62 # />
            self_closing = true
            j += 2
            done = true
          elsif c == 47
            j += 1
          else
            j = tag_attribute(s, j, i, tag, node)
          end
        end
        if VOID.include?(tag)
          node.close_node(s.byteslice(i, j - i))
          return j
        end
        if self_closing
          unless FOREIGN.include?(tag) || in_foreign?(nodes, stack)
            message = "self-closing <#{tag}/> at byte #{i}: only void elements (and svg / math content) close themselves; write <#{tag}></#{tag}>"
            raise Malformed, message
          end
          node.close_node(s.byteslice(i, j - i))
          return j
        end
        raw = RAW_TEXT.include?(tag)
        if raw || ESCAPABLE_RAW_TEXT.include?(tag)
          close = raw_end(s, j, tag)
          if close < 0
            message = "missing end tag </#{tag}> for <#{tag}> opened at byte #{i}"
            raise Malformed, message
          end
          body = s.byteslice(j, close - j)
          text = raw ? body : decode_references(body)
          stack << node.node_index
          add_node_texts(nodes, stack, text)
          stack.pop
          k = close + 2 + tag.bytesize
          k += 1 while k < n && s.getbyte(k) != 62
          k += 1
          node.close_node(s.byteslice(i, k - i))
          return k
        end
        stack << node.node_index
        j
      end

      # Reads one attribute starting at byte j of the tag at `at`; answers
      # the byte after it.
      # @api private
      def self.tag_attribute(html, j, at, tag, node)
        s = html.to_s
        n = s.bytesize
        k = j
        k += 1 while k < n && !attr_name_end?(s.getbyte(k))
        k += 1 if k == j # a stray `=`: kept as a name, as HTML does
        name = s.byteslice(j, k - j).downcase
        m = k
        m += 1 while m < n && html_space?(s.getbyte(m))
        if m >= n || s.getbyte(m) != 61 # no `=`: a boolean attribute
          node.add_node_attr(name, "")
          return k
        end
        m += 1
        m += 1 while m < n && html_space?(s.getbyte(m))
        if m >= n
          message = "unterminated tag <#{tag} at byte #{at}"
          raise Malformed, message
        end
        q = s.getbyte(m)
        if q == 34 || q == 39
          e = m + 1
          e += 1 while e < n && s.getbyte(e) != q
          if e >= n
            message = "unterminated attribute value (#{name}) in <#{tag} at byte #{at}"
            raise Malformed, message
          end
          node.add_node_attr(name, decode_references(s.byteslice(m + 1, e - m - 1)))
          return e + 1
        end
        e = m
        e += 1 while e < n && !html_space?(s.getbyte(e)) && s.getbyte(e) != 62
        node.add_node_attr(name, decode_references(s.byteslice(m, e - m)))
        e
      end

      # Reads the end tag whose `<` is at byte i; answers the byte after it.
      # @api private
      def self.read_end_tag(html, i, nodes, stack)
        s = html.to_s
        n = s.bytesize
        j = i + 2
        j += 1 while j < n && !tag_name_end?(s.getbyte(j))
        tag = s.byteslice(i + 2, j - i - 2).downcase
        j += 1 while j < n && s.getbyte(j) != 62
        if j >= n
          message = "unterminated end tag </#{tag} at byte #{i}"
          raise Malformed, message
        end
        j += 1
        # `</br>` and the like: nothing to close (HTML reads `</br>` as <br>).
        return j if VOID.include?(tag)

        if stack.empty?
          message = "unexpected end tag </#{tag}> at byte #{i} (open: none)"
          raise Malformed, message
        end
        top = nodes[stack[stack.length - 1]]
        unless top.node_tag == tag
          message = "mismatched end tag </#{tag}> at byte #{i} (open: <#{top.node_tag}>)"
          raise Malformed, message
        end
        stack.pop
        top.close_node(s.byteslice(top.node_start, j - top.node_start))
        j
      end

      # The byte of the `</tag` ending raw or escapable raw text that starts
      # at `from` (the name in any case, then whitespace, `/` or `>`); -1
      # when there is none.
      # @api private
      def self.raw_end(html, from, tag)
        s = html.to_s
        t = tag.to_s
        n = s.bytesize
        len = t.bytesize
        j = from
        while j + 1 + len < n
          if s.getbyte(j) == 60 && s.getbyte(j + 1) == 47 && s.byteslice(j + 2, len).downcase == t
            after = s.getbyte(j + 2 + len)
            return j if after == 62 || after == 47 || html_space?(after)
          end
          j += 1
        end
        -1
      end

      # Whether an open element is svg or math (foreign content).
      # @api private
      def self.in_foreign?(nodes, stack)
        k = 0
        while k < stack.length
          return true if FOREIGN.include?(nodes[stack[k]].node_tag)

          k += 1
        end
        false
      end

      # Appends text to every open element (each one's descendant text).
      # @api private
      def self.add_node_texts(nodes, stack, text)
        return nil if text.empty?

        k = 0
        while k < stack.length
          nodes[stack[k]].add_node_text(text)
          k += 1
        end
        nil
      end

      # `text` with its character references decoded: the named ones in
      # NAMED, `&#NN;` and `&#xHH;` (an invalid code point becomes U+FFFD).
      # Anything else after `&` stays as written.
      # @param text [String]
      # @return [String]
      # @api public
      def self.decode_references(text)
        s = text.to_s
        return s if s.index("&").nil?

        out = +""
        n = s.bytesize
        i = 0
        run = 0
        while i < n
          if s.getbyte(i) != 38 # &
            i += 1
            next
          end
          semi = i + 1
          semi += 1 while semi < n && semi - i <= 32 && reference_byte?(s.getbyte(semi))
          if semi >= n || s.getbyte(semi) != 59 || semi == i + 1 # no `;` close by
            i += 1
            next
          end
          name = s.byteslice(i + 1, semi - i - 1)
          value = reference_text(name)
          if value.empty?
            i += 1
            next
          end
          out << s.byteslice(run, i - run) if i > run
          out << value
          i = semi + 1
          run = i
        end
        out << s.byteslice(run, n - run) if n > run
        out
      end

      # The text of one reference's name (`amp`, `#39`, `#x27`), or "" for
      # a name it does not know.
      # @api private
      def self.reference_text(name)
        s = name.to_s
        if s.getbyte(0) == 35 # #
          code = -1
          if s.bytesize > 2 && (s.getbyte(1) == 120 || s.getbyte(1) == 88)
            code = reference_number(s, 2, 16)
          elsif s.bytesize > 1
            code = reference_number(s, 1, 10)
          end
          return "" if code < 0
          return "\uFFFD" if code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)

          return code.chr(Encoding::UTF_8)
        end
        return "" unless NAMED.key?(s)

        NAMED[s]
      end

      # The number in `text` from byte `from` in `base` (10 or 16); -1 when
      # a byte is not a digit of it or the number is too long.
      # @api private
      def self.reference_number(text, from, base)
        s = text.to_s
        return -1 if s.bytesize - from > 8

        value = 0
        k = from
        while k < s.bytesize
          c = s.getbyte(k)
          d = -1
          if c >= 48 && c <= 57
            d = c - 48
          elsif base == 16 && c >= 97 && c <= 102
            d = c - 87
          elsif base == 16 && c >= 65 && c <= 70
            d = c - 55
          end
          return -1 if d < 0

          value = value * base + d
          k += 1
        end
        value
      end

      # @api private
      def self.ascii_letter?(c)
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
      end

      # Whitespace in HTML: space, tab, LF, FF, CR.
      # @api private
      def self.html_space?(c)
        c == 32 || c == 9 || c == 10 || c == 12 || c == 13
      end

      # @api private
      def self.tag_name_end?(c)
        html_space?(c) || c == 47 || c == 62
      end

      # @api private
      def self.attr_name_end?(c)
        html_space?(c) || c == 47 || c == 62 || c == 61
      end

      # @api private
      def self.reference_byte?(c)
        ascii_letter?(c) || (c >= 48 && c <= 57) || c == 35
      end
    end
  end
end
