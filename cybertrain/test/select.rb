# assert_select (spec section 9.2): Rails' selector subset and options over
# the last rendered HTML (Cybertrain::Test.last_html: the last
# `render_inline` or integration-test response), read by
# Cybertrain::Test::HtmlReader.
#
#   render_inline(CardComponent.new(title: "Hello"))
#   assert_select "div.card > h2", text: "Hello"
#   assert_select "li", 2
#   assert_select "table", false
#
# Selectors: a tag (or `*`), `#id`, `.class`, `[attr]`, `[attr="v"]`
# (single quotes or none too), compounds of them, the descendant (` `) and
# child (`>`) combinators, and a list (`h1, h2`). Every other form is
# refused with `assert_select: <feature> is not supported (selector: "...")`
# rather than matching nothing: pseudo-classes and pseudo-elements, the
# sibling combinators `+` and `~`, attribute operators other than `=`,
# namespaces, CSS escapes, `?` substitution values and the nested block
# form. A test that has neither requested a page nor called render_inline
# fails ("No response yet"), never searching an earlier test's HTML.
#
# A byte scanner (spikes/NOTES.md rule 62): Selector.parse reads its
# parameter through a fresh local.
require "cybertrain/test"
require "cybertrain/test/html_reader"

module Cybertrain
  module Test
    # Rails' selector subset (spec section 9.2), parsed for
    # {Selector.matching_nodes}.
    # @api public
    module Selector
      # One compound selector (`a.btn[href="/x"]`) and how it relates to
      # the compound before it in its chain.
      # @api private
      class Compound
        attr_reader :sel_tag, :sel_ids, :sel_classes, :sel_attr_names, :sel_attr_values, :sel_attr_valued
        attr_accessor :sel_combinator

        def initialize
          # "" or "*" for any tag; otherwise lower-cased.
          @sel_tag = ""
          @sel_ids = Array.new(0) { "" }
          @sel_classes = Array.new(0) { "" }
          @sel_attr_names = Array.new(0) { "" }
          @sel_attr_values = Array.new(0) { "" }
          @sel_attr_valued = Array.new(0) { false }
          # " " (descendant) or ">" (child) of the compound before it; ""
          # for the first of a chain.
          @sel_combinator = ""
        end

        def sel_tag=(tag)
          @sel_tag = tag
        end

        # Whether the compound names nothing yet.
        def sel_empty?
          @sel_tag == "" && @sel_ids.empty? && @sel_classes.empty? && @sel_attr_names.empty?
        end

        # Whether `node` matches every part of this compound.
        # @param node [HtmlNode]
        # @return [Boolean]
        def sel_match?(node)
          return false unless @sel_tag == "" || @sel_tag == "*" || @sel_tag == node.node_tag

          k = 0
          while k < @sel_ids.length
            return false unless node.node_attr?("id") && node.node_attr("id") == @sel_ids[k]

            k += 1
          end
          k = 0
          while k < @sel_classes.length
            return false unless Selector.class_list?(node.node_attr("class"), @sel_classes[k])

            k += 1
          end
          k = 0
          while k < @sel_attr_names.length
            return false unless node.node_attr?(@sel_attr_names[k])
            return false if @sel_attr_valued[k] && node.node_attr(@sel_attr_names[k]) != @sel_attr_values[k]

            k += 1
          end
          true
        end
      end

      # The selector `text` as a list of chains, each an Array of compounds
      # whose `sel_combinator` says how it relates to the one before.
      # @param text [String]
      # @return [Array<Array<Compound>>]
      # @raise [AssertionFailed] `assert_select: <feature> is not supported
      #   (selector: "...")` for a form outside the subset, or
      #   `assert_select: invalid selector "..."`
      # @api public
      def self.parse(text)
        s = text.to_s
        chains = Array.new(0) { Array.new(0) { Compound.new } }
        chain = Array.new(0) { Compound.new }
        current = Compound.new
        pending = ""
        n = s.bytesize
        i = 0
        while i < n
          c = s.getbyte(i)
          if HtmlReader.html_space?(c) || c == 62 || c == 44 || c == 43 || c == 126
            # Whitespace and the combinators between compounds.
            combinator = " "
            while i < n
              c = s.getbyte(i)
              if HtmlReader.html_space?(c)
                i += 1
              elsif c == 62 || c == 44 || c == 43 || c == 126
                refuse_selector(s, "sibling combinators (+ and ~) are") if c == 43 || c == 126
                invalid_selector(s) unless combinator == " "
                combinator = c == 62 ? ">" : ","
                i += 1
              else
                break
              end
            end
            # A combinator with nothing after it.
            invalid_selector(s) if i >= n && combinator != " "
            if combinator == ","
              invalid_selector(s) if current.sel_empty?
              chain << current
              chains << chain
              chain = Array.new(0) { Compound.new }
              current = Compound.new
              pending = ""
            elsif current.sel_empty?
              # Leading whitespace, or `>` with nothing before it.
              invalid_selector(s) if combinator == ">" || (i < n && !chain.empty?)
            elsif i < n
              chain << current
              current = Compound.new
              pending = combinator
            end
            next
          end
          current.sel_combinator = pending if current.sel_empty?
          if c == 35 || c == 46 # # .
            j = ident_end(s, i + 1)
            invalid_selector(s) if j == i + 1
            word = s.byteslice(i + 1, j - i - 1)
            if c == 35
              current.sel_ids << word
            else
              current.sel_classes << word
            end
            i = j
          elsif c == 91 # [
            i = selector_attribute(s, i + 1, current)
          elsif c == 58 # :
            refuse_selector(s, "pseudo-classes are")
          elsif c == 124 # |
            refuse_selector(s, "namespaces are")
          elsif c == 92 # \
            refuse_selector(s, "CSS escapes (\\) are")
          elsif c == 63 # ?
            refuse_selector(s, "substitution values (?) are")
          elsif c == 42 # *
            invalid_selector(s) unless current.sel_empty?
            current.sel_tag = "*"
            i += 1
          else
            j = ident_end(s, i)
            invalid_selector(s) if j == i || !current.sel_empty?
            current.sel_tag = s.byteslice(i, j - i).downcase
            i = j
          end
        end
        invalid_selector(s) if current.sel_empty?
        chain << current
        chains << chain
        chains
      end

      # Reads `[name]` / `[name=value]` from just after the `[`; answers the
      # byte after the `]`.
      # @api private
      def self.selector_attribute(text, from, current)
        s = text.to_s
        n = s.bytesize
        i = from
        i += 1 while i < n && HtmlReader.html_space?(s.getbyte(i))
        j = ident_end(s, i)
        invalid_selector(s) if j == i
        name = s.byteslice(i, j - i).downcase
        i = j
        i += 1 while i < n && HtmlReader.html_space?(s.getbyte(i))
        invalid_selector(s) if i >= n
        c = s.getbyte(i)
        refuse_selector(s, "CSS escapes (\\) are") if c == 92
        if c == 93 # ]
          current.sel_attr_names << name
          current.sel_attr_values << ""
          current.sel_attr_valued << false
          return i + 1
        end
        if c == 94 || c == 42 || c == 126 || c == 36 || c == 124 || c == 33 # ^ * ~ $ | !
          refuse_selector(s, "attribute operators other than = are") if i + 1 < n && s.getbyte(i + 1) == 61
          refuse_selector(s, "namespaces are") if c == 124
          invalid_selector(s)
        end
        invalid_selector(s) unless c == 61
        i += 1
        i += 1 while i < n && HtmlReader.html_space?(s.getbyte(i))
        invalid_selector(s) if i >= n
        q = s.getbyte(i)
        value = +""
        if q == 34 || q == 39
          i += 1
          run = i
          while i < n && s.getbyte(i) != q
            # A CSS escape (`\41`, `\"`) is refused, not read: a value
            # holding one quote is written in the other.
            refuse_selector(s, "CSS escapes (\\) are") if s.getbyte(i) == 92
            i += 1
          end
          invalid_selector(s) if i >= n
          value << s.byteslice(run, i - run)
          i += 1
        else
          j = i
          while j < n && !HtmlReader.html_space?(s.getbyte(j)) && s.getbyte(j) != 93
            refuse_selector(s, "CSS escapes (\\) are") if s.getbyte(j) == 92
            j += 1
          end
          refuse_selector(s, "substitution values (?) are") if s.byteslice(i, j - i) == "?"
          invalid_selector(s) if j == i
          value << s.byteslice(i, j - i)
          i = j
        end
        i += 1 while i < n && HtmlReader.html_space?(s.getbyte(i))
        invalid_selector(s) if i >= n
        # `[a="v" i]` (a case flag) and anything else before the `]`.
        refuse_selector(s, "attribute flags are") if flag_at?(s, i)
        invalid_selector(s) unless s.getbyte(i) == 93
        current.sel_attr_names << name
        current.sel_attr_values << value
        current.sel_attr_valued << true
        i + 1
      end

      # Whether a case flag (`i` or `s`, then optional spaces and `]`)
      # starts at byte i: `[a="v" i]`.
      # @api private
      def self.flag_at?(text, i)
        s = text.to_s
        n = s.bytesize
        c = s.getbyte(i)
        return false unless c == 105 || c == 73 || c == 115 || c == 83

        j = i + 1
        j += 1 while j < n && HtmlReader.html_space?(s.getbyte(j))
        j < n && s.getbyte(j) == 93
      end

      # The byte after the identifier starting at `from`: letters, digits,
      # `-`, `_` and any non-ASCII byte.
      # @api private
      def self.ident_end(text, from)
        s = text.to_s
        n = s.bytesize
        j = from
        while j < n
          c = s.getbyte(j)
          break unless HtmlReader.ascii_letter?(c) || (c >= 48 && c <= 57) || c == 45 || c == 95 || c >= 128

          j += 1
        end
        j
      end

      # Whether the space-separated `list` holds `name`.
      # @api private
      def self.class_list?(list, name)
        s = list.to_s
        want = name.to_s
        n = s.bytesize
        i = 0
        while i < n
          i += 1 while i < n && HtmlReader.html_space?(s.getbyte(i))
          j = i
          j += 1 while j < n && !HtmlReader.html_space?(s.getbyte(j))
          return true if j > i && s.byteslice(i, j - i) == want

          i = j
        end
        false
      end

      # @api private
      def self.refuse_selector(selector, feature)
        message = "assert_select: #{feature} not supported (selector: #{selector.inspect})"
        raise AssertionFailed, message
      end

      # @api private
      def self.invalid_selector(selector)
        message = "assert_select: invalid selector #{selector.inspect}"
        raise AssertionFailed, message
      end

      # The elements of `nodes` (HtmlReader.parse's answer) that match any
      # chain, in document order, each once.
      # @param nodes [Array<HtmlNode>]
      # @param chains [Array<Array<Compound>>] from {parse}
      # @return [Array<HtmlNode>]
      # @api public
      def self.matching_nodes(nodes, chains)
        found = Array.new(0) { HtmlNode.new("", 0, -1, 0) }
        # One memo per chain, kept across the elements: whether element
        # `at` matches chain[0..k] depends on nothing else, so each
        # (k, at) pair is worked out once (0 not yet, 1 yes, 2 no) and a
        # descendant chain that fails near the root costs depth x length,
        # not depth to the power of its length.
        memos = Array.new(0) { Array.new(0) { 0 } }
        chains.each { |chain| memos << Array.new(chain.length * nodes.length) { 0 } }
        nodes.each do |node|
          hit = false
          c = 0
          while c < chains.length
            chain = chains[c]
            hit = true if !hit && chain_match?(nodes, chain, chain.length - 1, node.node_index, memos[c])
            c += 1
          end
          found << node if hit
        end
        found
      end

      # Whether node `at` matches chain[k] and its ancestors match the
      # compounds before it; `memo` holds the answers already worked out
      # ({matching_nodes}).
      # @api private
      def self.chain_match?(nodes, chain, k, at, memo)
        slot = k * nodes.length + at
        known = memo[slot]
        return known == 1 if known > 0

        result = chain_step?(nodes, chain, k, at, memo)
        memo[slot] = result ? 1 : 2
        result
      end

      # {chain_match?} without the memo lookup.
      # @api private
      def self.chain_step?(nodes, chain, k, at, memo)
        return false unless chain[k].sel_match?(nodes[at])
        return true if k == 0

        parent = nodes[at].node_parent_index
        if chain[k].sel_combinator == ">"
          return false if parent < 0

          return chain_match?(nodes, chain, k - 1, parent, memo)
        end
        while parent >= 0
          return true if chain_match?(nodes, chain, k - 1, parent, memo)

          parent = nodes[parent].node_parent_index
        end
        false
      end
    end

    # The elements of `html` matching `selector`.
    # @param selector [String]
    # @param html [String]
    # @return [Array<HtmlNode>]
    # @raise [AssertionFailed] for an unsupported selector or HTML the
    #   reader refuses (with the byte offset and the excerpt)
    # @api public
    def self.select_nodes(selector, html)
      chains = Selector.parse(selector)
      nodes = Array.new(0) { HtmlNode.new("", 0, -1, 0) }
      problem = ""
      begin
        nodes = HtmlReader.parse(html)
      rescue HtmlReader::Malformed => e
        problem = e.message
      end
      unless problem == ""
        text = "assert_select: the HTML could not be read: #{problem}\n#{html_excerpt(html)}"
        fail_with(text)
      end
      Selector.matching_nodes(nodes, chains)
    end

    # The failure's excerpt: the first 500 characters of `html`.
    # @api private
    def self.html_excerpt(html)
      "HTML (first 500 characters):\n#{html.to_s[0, 500]}"
    end

    # `text` with runs of whitespace made one space and the ends stripped:
    # what `text:` is compared with (Rails' default).
    # @param text [String]
    # @return [String]
    # @api public
    def self.squished_text(text)
      s = text.to_s
      out = +""
      n = s.bytesize
      i = 0
      while i < n
        i += 1 while i < n && HtmlReader.html_space?(s.getbyte(i))
        j = i
        j += 1 while j < n && !HtmlReader.html_space?(s.getbyte(j))
        if j > i
          out << " " unless out.empty?
          out << s.byteslice(i, j - i)
        end
        i = j
      end
      out
    end

    # What `assert_select` fails with when the running test has neither
    # requested a page nor called `render_inline` (Rails' "No response
    # yet"): an empty or earlier test's page is never searched.
    NOTHING_RENDERED = "assert_select: No response yet. Request a page or call render_inline first."

    # Fails unless the running test has rendered or requested something
    # ({last_html?}).
    # @return [nil]
    # @api private
    def self.check_rendered
      return nil if last_html?

      text = NOTHING_RENDERED
      fail_with(text)
      nil
    end

    # A count option as an Integer, -1 when not given.
    # @raise [ArgumentError] when it is negative
    # @api private
    def self.select_bound(name, value)
      return -1 if value.nil?

      n = value.to_i
      if n < 0
        message = "assert_select: #{name}: must be 0 or more, got #{n}"
        raise ArgumentError, message
      end
      n
    end

    # A Regexp cannot be matched against text that is not valid UTF-8:
    # the assertion fails, naming the element, rather than raising.
    # @return [nil]
    # @api private
    def self.check_valid_text(node, text)
      return nil if text.valid_encoding?

      message = "assert_select: the text of <#{node.node_tag}> at byte #{node.node_start} is not valid UTF-8; a Regexp cannot match it"
      fail_with(message)
      nil
    end

    # `assert_select`'s count check (pre-flight R17: the one check every
    # form calls). `count`, `minimum` and `maximum` are -1 when not given;
    # `text_label` is "" or the text option's inspect.
    # @return [nil]
    # @api private
    def self.check_select(selector, found, count, minimum, maximum, text_label, html)
      count_assertion
      low = minimum
      high = maximum
      if count >= 0
        low = count
        high = count
      end
      low = 1 if low < 0 && high < 0
      return nil if (low < 0 || found >= low) && (high < 0 || found <= high)

      expected = ""
      if low == high
        expected = "exactly #{low} #{low == 1 ? "element" : "elements"}"
      elsif high < 0
        expected = "at least #{low} #{low == 1 ? "element" : "elements"}"
      elsif low < 0
        expected = "at most #{high} #{high == 1 ? "element" : "elements"}"
      else
        expected = "between #{low} and #{high} elements"
      end
      with = text_label == "" ? "" : " with text #{text_label}"
      text = "Expected #{expected} matching #{selector.inspect}#{with}, found #{found}.\n#{html_excerpt(html)}"
      fail_with(text)
      nil
    end
  end
end

# Checks the last rendered HTML (`render_inline`'s, or the last response
# of an integration test) for elements matching `selector`, and answers
# them. With no option at least one must match. The second argument may be
# Rails' positional form: a String or Regexp (the text), an Integer (the
# count), a Range (`2..3`: at least 2, at most 3), `true` (at least one) or
# `false` (none). `text:` is a String,
# compared with each element's text after collapsing whitespace and
# stripping, or a Regexp matched against that text; only the elements
# whose text matches are counted and answered.
#
# The nested block form (`assert_select "ul" do ... end`) is not supported;
# `cybertrain test` refuses it at gen, and here it fails.
# @example
#   get articles_path
#   assert_select "ul#articles > li", count: 2
#   assert_select "h1", "Articles"
#   assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
# @param selector [String] see cybertrain/test/select.rb for the subset
# @param equality [String, Regexp, Integer, Range, true, false, nil]
# @param count [Integer, nil] exactly this many
# @param minimum [Integer, nil] at least
# @param maximum [Integer, nil] at most
# @param text [String, Regexp, nil]
# @return [Array<Cybertrain::Test::HtmlNode>] the matching elements
# @raise [Cybertrain::Test::AssertionFailed] with the selector, what was
#   expected and found, and the first 500 characters of the HTML
# @api public
def assert_select(selector, equality = nil, count: nil, minimum: nil, maximum: nil, text: nil)
  if block_given?
    message = "assert_select: the nested block form is not supported (selector: #{selector.inspect})"
    Cybertrain::Test.fail_with(message)
  end
  want_text = text
  want_count = Cybertrain::Test.select_bound("count", count)
  want_min = Cybertrain::Test.select_bound("minimum", minimum)
  want_max = Cybertrain::Test.select_bound("maximum", maximum)
  if want_min >= 0 && want_max >= 0 && want_min > want_max
    message = "assert_select: minimum: #{want_min} is above maximum: #{want_max}"
    raise ArgumentError, message
  end
  # Rails takes the count positionally or as options, not both.
  counted = want_count >= 0 || want_min >= 0 || want_max >= 0
  case equality
  when nil then nil
  when String, Regexp
    unless text.nil?
      message = "assert_select: give the text once, as the second argument or as text:"
      raise ArgumentError, message
    end
    want_text = equality
  when Integer, true, false
    if counted
      message = "assert_select: give the count once, as the second argument (#{equality.inspect}) or as count:, minimum: and maximum:"
      raise ArgumentError, message
    end
    case equality
    when Integer then want_count = Cybertrain::Test.select_bound("count", equality)
    when true then want_min = 1
    else want_count = 0
    end
  when Range
    if counted
      message = "assert_select: give the count once, as the second argument (#{equality.inspect}) or as count:, minimum: and maximum:"
      raise ArgumentError, message
    end
    # Rails' `assert_select "li", 2..3`: at least the first, at most the
    # last (one less for `...`).
    want_min = Cybertrain::Test.select_bound("count", equality.first)
    high = equality.last.to_i
    high -= 1 if equality.exclude_end?
    want_max = Cybertrain::Test.select_bound("count", high)
    if want_min > want_max
      message = "assert_select: minimum: #{want_min} is above maximum: #{want_max}"
      raise ArgumentError, message
    end
  else
    message = "assert_select: the second argument must be a String, a Regexp, an Integer, a Range, true or false"
    raise ArgumentError, message
  end
  # An unsupported selector is named before anything else.
  Cybertrain::Test::Selector.parse(selector)
  Cybertrain::Test.check_rendered
  html = Cybertrain::Test.last_html
  nodes = Cybertrain::Test.select_nodes(selector, html)
  label = ""
  found = Array.new(0) { Cybertrain::Test::HtmlNode.new("", 0, -1, 0) }
  case want_text
  when nil
    found = nodes
  when Regexp
    label = want_text.inspect
    nodes.each do |node|
      seen = Cybertrain::Test.squished_text(node.node_text)
      Cybertrain::Test.check_valid_text(node, seen)
      found << node if seen.match?(want_text)
    end
  else
    wanted = want_text.to_s
    label = wanted.inspect
    nodes.each { |node| found << node if Cybertrain::Test.squished_text(node.node_text) == wanted }
  end
  Cybertrain::Test.check_select(selector, found.length, want_count, want_min, want_max, label, html)
  found
end
