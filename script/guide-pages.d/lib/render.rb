# Renders a guide source's body to the markup of the former hand-written
# site/tutorial.html (`git show 2a73b58:site/tutorial.html`), applying
# the Markdown conventions of the guide pages (spec "Markdown conventions"):
#   # Title, then a paragraph          h1 and the doc-intro (Page#h1, #intro_html)
#   <!-- step NUM #id stage: … -->     section.step with that number, id and p.stage
#   ## Heading (no step comment)       section.step numbered 01, 02 …, id from the English heading
#   ### Heading                        h3.sub, id from the English heading at the same position
#   > [!WHY] / > [!NOTE]               p.why / p.note, one paragraph
#   > [!RULE|COMPILE|EXAMPLE] [label]  aside.callout; its first block is "### Title";
#                                      aria-label is label, or "<kind>: <title>"
#   <details><summary>T — D</summary>  details.ci (ci-t, ci-d, ci-body)
#   ```LANG [PLACE]                    figure.code (GuidePages::Highlight)
#   <!-- list: KIND -->                ul.KIND; next-list items are [**T**](url) — D
#   | a | b | (no table comment)       the table inside div.table-scroll (scrolls sideways)
#   <!-- table: cmp --> …              the comparison table (cmp-wrap cmp-doc), unwrapped;
#   <!-- table-foot: text -->            optional, after the table: p.cmp-foot
# Links go through GuidePages::Links. Images must have absolute URLs (a
# relative one is an error until images are copied to the site). Other raw
# HTML passes through. Text is kept as written: no smart quotes or
# typographic symbols, entities as typed.
#
#   page = GuidePages::Render.page(source, english: en_source, links: links, words: GuidePages::WORDS["ja"])
#   page.h1, page.h1_id, page.intro_html, page.sections_html, page.toc  # toc: [TocEntry(num, id, title_html, extra)]

require "kramdown"
require "kramdown-parser-gfm"
require_relative "outline"
require_relative "source"
require_relative "highlight"
require_relative "links"
require_relative "words"

module GuidePages
  module Render
    # h1_id: the slug of the English title, the same in every language.
    Page = Struct.new(:h1, :h1_id, :intro_html, :sections_html, :toc)
    # extra: an unnumbered step ("+", "→"), shown apart in the contents list.
    TocEntry = Struct.new(:num, :id, :title_html, :extra)

    OPTIONS = {
      input: "GFM", parse_block_html: true, hard_wrap: false, auto_ids: false,
      entity_output: :as_input, gfm_quirks: [:paragraph_end, :no_auto_typographic],
      remove_line_breaks_for_cjk: true,
    }.freeze

    LIST_KINDS = ["checklist", "points", "points know", "next-list"].freeze
    TABLE_KINDS = ["cmp"].freeze
    CALLOUTS = { "RULE" => :rule, "COMPILE" => :compile, "EXAMPLE" => :example }.freeze
    MARKER = /\A\[!(WHY|NOTE|RULE|COMPILE|EXAMPLE)\][ \t]*\n?/
    TABLE_FOOT = /\A\s*<!--\s*table-foot:\s*(.*?)\s*-->\s*\z/
    DETAILS = %r{\A((?:>[ \t]?)*[ \t]*)<details><summary>(.*)</summary>\s*\z}
    # The header mark of the tutorial's comparison table.
    CMP_MARK = '<svg class="cmp-mark" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 104 104">' \
               '<path fill="currentColor" fill-rule="evenodd" d="M94 44.14L94 30L76 12L28 12L10 30L10 44.14ZM84 34.14L20 34.14L32.14 22L71.86 22ZM94 56L10 56L24 70L80 70ZM14.93 80L7.93 80L7.93 85L9.93 85L2.93 92L10 92L17 85L87 85L94 92L101.07 92L94.07 85L96.07 85L96.07 80L89.07 80L82.07 73L75 73L82 80L22 80L29 73L21.93 73Z"/>' \
               '<path fill="#C8A96A" d="M94 47.07L10 47.07L10 53.07L94 53.07Z"/></svg>'

    # GFM, but a fence's info string may carry a PLACE after the language.
    class Parser < Kramdown::Parser::GFM
      FENCED_CODEBLOCK_MATCH = /^[ ]{0,3}(([~`]){3,})[ \t]*(([^\s`]+)[^\n`]*?)?[ \t]*\n(.*?)^[ ]{0,3}\1\2*[ \t]*\n/m
    end

    module_function

    def page(source, english:, links:, words:)
      summaries = []
      text = preprocess(source.body, summaries)
      root, = Parser.parse(text, OPTIONS)
      outline = Outline.parse(english.body)
      en = outline.sections.drop(1)
      Converter.build(root, Kramdown::Options.merge(OPTIONS), source: source, links: links, words: words,
                      summaries: summaries, title: outline.title,
                      h2: en.select { |s| s.level == 2 }, sub: en.reject { |s| s.level == 2 }).page
    end

    # Inline Markdown of the front matter (a meta row's text), links rewritten
    # as on source's page.
    def inline(text, source:, links:, words:)
      root, = Parser.parse("", OPTIONS)
      Converter.build(root, Kramdown::Options.merge(OPTIONS), source: source, links: links, words: words,
                      summaries: [], title: nil, h2: [], sub: []).inline_md(text)
    end

    # Line-level fixes before kramdown, outside fences: a convention
    # <details><summary> line becomes a marked <details> (the summary is kept
    # aside), and the list/table comments get the blank lines kramdown needs
    # to see the block next to them.
    def preprocess(body, summaries)
      fence = nil # the opener's run of ` or ~
      body.each_line.map do |raw|
        line = raw.chomp
        quoted = line.sub(/\A[>\s]*/, "")
        if fence
          fence = nil if Outline.fence_close?(quoted, fence)
          next raw
        end
        if (m = quoted.match(FENCE_OPEN))
          fence = m[2]
          next raw
        end

        prefix = line[/\A(?:>[ \t]?)*/]
        rest = line.delete_prefix(prefix)
        if (m = line.match(DETAILS))
          summaries << m[2]
          %(#{m[1]}<details data-guide-ci="#{summaries.size - 1}">\n)
        elsif rest.match?(MARKER_COMMENT)
          "#{raw}#{prefix.rstrip}\n"
        elsif rest.match?(TABLE_FOOT)
          "#{prefix.rstrip}\n#{raw}"
        else
          raw
        end
      end.join
    end

    class Converter < Kramdown::Converter::Html
      QUOTES = { lsquo: "'", rsquo: "'", ldquo: '"', rdquo: '"' }.freeze

      def self.build(root, options, **ctx) = new(root, options).tap { |c| c.setup(**ctx) }

      def setup(source:, links:, words:, summaries:, title:, h2:, sub:)
        @source, @links, @words, @summaries, @en_h2, @en_sub = source, links, words, summaries, h2, sub
        @en_title = title
        @sub_index = 0
        @quote = 0
      end

      def page
        mark_blocks(@root)
        h1 = intro = nil
        pre = []
        sections = []
        pending_step = nil
        @root.children.each do |el|
          if el.type == :header && el.options[:level] == 1 && !h1
            h1 = inner(el, 0)
          elsif el.type == :xml_comment && el.value.match?(/\A<!--\s*step\b/)
            m = el.value.match(STEP) or fail!("malformed step comment #{el.value}")
            pending_step = Step.new(m[1], m[2], m[3])
          elsif el.type == :header && el.options[:level] == 2
            sections << { step: pending_step, header: el, body: [] }
            pending_step = nil
          elsif pending_step && el.type != :blank
            fail!("a step comment must come right before a ## heading: #{el.value || el.type}")
          elsif !sections.empty?
            sections.last[:body] << el
          elsif h1 && !intro && pre.empty? && el.type == :p
            intro = inner(el, 0)
          elsif h1 && el.type != :blank
            pre << el
          elsif el.type != :blank
            fail!("#{el.value || el.type} before the # title")
          end
        end
        fail!("found #{sections.size} ## sections, the English has #{@en_h2.size}") if sections.size != @en_h2.size

        toc = []
        auto = 0
        html = sections.each_with_index.map do |sec, i|
          step = sec[:step]
          num = step ? step.num : format("%02d", auto += 1)
          id = @en_h2[i].step ? @en_h2[i].step.id : Outline.slug(@en_h2[i].text)
          title = inner(sec[:header], 0)
          toc << TocEntry.new(num, id, title, !num.match?(/\A\d+\z/))
          section(id, num, step&.stage, title, sec[:body], last: i == sections.size - 1)
        end
        lead = children_html(@root, pre, 2)
        if @sub_index != @en_sub.size
          fail!("found #{@sub_index} sub-headings, the English has #{@en_sub.size}")
        end
        Page.new(h1, Outline.slug(@en_title), intro, lead + html.join("\n"), toc)
      end

      def section(id, num, stage, title, body, last:)
        out = +%(  <section class="step#{" step-last" if last}" id="#{id}" aria-labelledby="h-#{id}">\n)
        if stage
          here = %(<span class="stage-k">#{esc(@words[:here])}<span class="sr-only">#{esc(@words[:here_sep])}</span></span>)
          dot = %( <span aria-hidden="true">&middot;</span> )
          out << %(    <p class="stage">#{here}#{inline_md(stage).gsub(/ (?:·|&middot;) /, dot)}</p>\n)
        end
        out << %(    <h2 id="h-#{id}"><span class="step-num" aria-hidden="true">#{esc(num).gsub("→", "&rarr;")}</span>#{title}</h2>\n)
        out << children_html(@root, body, 4)
        out << "  </section>\n"
      end

      # --- conventions -----------------------------------------------------

      def convert_blank(_el, _indent) = ""

      def convert_smart_quote(el, _indent) = QUOTES.fetch(el.value)

      def convert_header(el, indent)
        return format_as_block_html("h#{el.options[:level]}", el.attr, inner(el, indent), indent) if @quote > 0

        en = @en_sub[@sub_index] or fail!("more sub-headings than the English (at #{plain(el).inspect})")
        @sub_index += 1
        level = el.options[:level]
        attr = { "id" => Outline.slug(en.text) }
        attr = { "class" => "sub" }.merge(attr) if level == 3
        format_as_block_html("h#{level}", attr, inner(el, indent), indent)
      end

      def convert_codeblock(el, indent)
        lang, place = el.options[:lang].to_s.split(/\s+/, 2)
        lang = "text" if lang.nil? || lang.empty?
        fail!("code fence language #{lang.inspect} has no Rouge lexer") unless Highlight.lexer?(lang)

        "#{" " * indent}#{Highlight.figure(lang, place, el.value, words: @words)}\n"
      end

      def convert_blockquote(el, indent)
        @quote += 1
        kind, label = take_marker(el)
        case kind
        when nil then super
        when "WHY", "NOTE"
          blocks = el.children.reject { |c| c.type == :blank }
          fail!("[!#{kind}] must hold one paragraph") unless blocks.size == 1 && blocks[0].type == :p
          body = inner(blocks[0], indent)
          if kind == "WHY"
            %(#{" " * indent}<p class="why"><span class="why-k">#{esc(@words[:why])}</span><span class="why-t">#{body}</span></p>\n)
          else
            %(#{" " * indent}<p class="note">#{body}</p>\n)
          end
        else callout(el, kind, label, indent)
        end
      ensure
        @quote -= 1
      end

      def callout(el, kind, label, indent)
        blocks = el.children.reject { |c| c.type == :blank }
        head = blocks.first
        fail!("[!#{kind}] must start with a ### title") unless head&.type == :header && head.options[:level] == 3

        word = @words.fetch(CALLOUTS.fetch(kind))
        label = "#{word}#{@words[:aria_sep]}#{plain(head)}" if label.empty?
        sp = " " * indent
        out = +%(#{sp}<aside class="callout" aria-label="#{esc(label, attr: true)}">\n)
        out << %(#{sp}  <p class="callout-k">#{esc(word)}</p>\n)
        out << %(#{sp}  <h3>#{inner(head, indent)}</h3>\n)
        out << children_html(el, blocks.drop(1), indent + 2)
        out << "#{sp}</aside>\n"
      end

      # Removes the [!KIND] marker from the quote's first paragraph; for a
      # callout that paragraph is the marker line, and the rest is its label.
      def take_marker(el)
        first = el.children.find { |c| c.type != :blank }
        text = first&.type == :p && first.children.first
        return nil unless text&.type == :text && (m = text.value.match(MARKER))

        text.value = text.value[m[0].size..]
        first.children.shift if text.value.empty?
        return [m[1], nil] unless CALLOUTS.key?(m[1])

        el.children.delete(first)
        [m[1], first.children.map { |c| plain(c) }.join.strip]
      end

      def convert_html_element(el, indent)
        if el.value == "details" && el.attr.key?("data-guide-ci")
          return details(el, @summaries.fetch(Integer(el.attr["data-guide-ci"])), indent)
        end

        el.attr.replace(link_attrs(el.attr)) if el.value == "a" && el.attr["href"]
        check_image(el.attr["src"]) if el.value == "img"
        super
      end

      def convert_img(el, indent)
        check_image(el.attr["src"])
        super
      end

      def check_image(src)
        return if src.to_s.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|//)}i)

        fail!("image #{src}: images are not supported yet")
      end

      def details(el, summary, indent)
        title, desc = inline_md(summary).split(/ (?:—|&mdash;) /, 2)
        sp = " " * indent
        out = +%(#{sp}<details class="ci">\n)
        out << %(#{sp}  <summary><span class="ci-t">#{title}</span>#{%(<span class="ci-d">#{desc}</span>) if desc}</summary>\n)
        out << %(#{sp}  <div class="ci-body">\n)
        out << children_html(el, el.children, indent)
        out << %(#{sp}  </div>\n#{sp}</details>\n)
      end

      def convert_a(el, indent)
        format_as_span_html("a", link_attrs(el.attr), inner(el, indent))
      end

      def convert_ul(el, indent)
        kind = el.options[:list_kind]
        return super unless kind

        el.attr["class"] = kind
        return super unless kind == "next-list"

        items = el.children.reject { |c| c.type == :blank }.map { |li| next_item(li, indent + 2) }
        format_as_indented_block_html("ul", el.attr, items.join, indent)
      end

      def next_item(li, indent)
        kids = li.children.first&.type == :p ? li.children.first.children.dup : []
        a = kids.shift
        fail!("a next-list item must be [**Title**](url) — description") unless a&.type == :a

        title = a.children.size == 1 && a.children[0].type == :strong ? a.children[0] : a
        desc = Kramdown::Element.new(:p, nil, nil)
        desc.children = kids
        desc_html = inner(desc, indent).sub(/\A\s*(?:—|&mdash;)\s*/, "")
        %(#{" " * indent}<li>#{format_as_span_html("a", link_attrs(a.attr), %(<span class="next-t">#{inner(title, indent)}</span><span class="next-d">#{desc_html}</span>))}</li>\n)
      end

      # In a table cell GFM reads `\|` as `|`, inside a code span too (the
      # backslash is how a cell holds a pipe at all); kramdown keeps it in a
      # code span, so the page would show the backslash.
      def convert_codespan(el, indent)
        return super unless @in_table
        super(Kramdown::Element.new(:codespan, el.value.gsub("\\|", "|"), el.attr, el.options), indent)
      end

      def convert_table(el, indent)
        @in_table = true
        sp = " " * indent
        # A plain table scrolls sideways in its wrapper on a narrow screen; the
        # tab stop lets a keyboard reach and scroll it (WCAG 2.1.1).
        return %(#{sp}<div class="table-scroll" tabindex="0">\n#{super(el, indent + 2)}#{sp}</div>\n) unless el.options[:table_kind] == "cmp"

        head = el.children.find { |c| c.type == :thead }&.children&.first
        fail!("a cmp table needs two header cells") unless head && head.children.size == 2

        labels = head.children.map { |td| plain(td).strip }
        th = head.children.map { |td| inner(td, indent) }
        out = +%(#{sp}<div class="cmp-wrap cmp-doc">\n#{sp}  <table class="cmp cmp-full">\n)
        out << %(#{sp}    <caption class="sr-only">#{esc(@words[:cmp_caption])}</caption>\n)
        out << %(#{sp}    <thead><tr><th scope="col" class="cmp-rails">#{th[0]}</th><th scope="col" class="cmp-ct">#{CMP_MARK}<span>#{th[1]}</span></th></tr></thead>\n)
        out << %(#{sp}    <tbody>\n)
        el.children.select { |c| c.type == :tbody }.flat_map(&:children).each do |tr|
          cells = tr.children.each_with_index.map { |td, i| %(<td data-label="#{esc(labels[i] || "", attr: true)}">#{inner(td, indent)}</td>) }
          out << %(#{sp}      <tr>#{cells.join}</tr>\n)
        end
        out << %(#{sp}    </tbody>\n#{sp}  </table>\n)
        out << %(#{sp}  <p class="cmp-foot">#{inline_md(el.options[:foot])}</p>\n) if el.options[:foot]
        out << "#{sp}</div>\n"
      ensure
        @in_table = false
      end

      # --- helpers ---------------------------------------------------------

      # Attaches the list/table marker comments to their blocks, everywhere
      # in the tree, and drops the comments.
      def mark_blocks(el)
        kids = el.children
        kids.each_with_index do |c, i|
          next unless c.type == :xml_comment

          if (m = c.value.match(MARKER_COMMENT))
            target = kids[(i + 1)..].find { |k| k.type != :blank }
            if m[1] == "list"
              fail!("unknown list kind #{m[2].inspect}") unless LIST_KINDS.include?(m[2])
              fail!("<!-- list: #{m[2]} --> must come before a list") unless target&.type == :ul || target&.type == :ol
              target.options[:list_kind] = m[2]
            else
              fail!("unknown table kind #{m[2].inspect}") unless TABLE_KINDS.include?(m[2])
              fail!("<!-- table: #{m[2]} --> must come before a table") unless target&.type == :table
              target.options[:table_kind] = m[2]
            end
            c.options[:drop] = true
          elsif (m = c.value.match(TABLE_FOOT))
            target = kids[0...i].reverse.find { |k| k.type != :blank }
            fail!("<!-- table-foot: --> must come after a table") unless target&.type == :table
            target.options[:foot] = m[1]
            c.options[:drop] = true
          end
        end
        kids.reject! { |c| c.options[:drop] }
        kids.each { |c| mark_blocks(c) }
      end

      def link_attrs(attr)
        attr = attr.dup
        attr["href"] = @links.rewrite(attr["href"], from: @source)
        attr["rel"] ||= "noopener" if attr["href"].match?(%r{\A(?:https?:)?//}i)
        attr
      end

      # Converts the given children of el at indent (not one level deeper).
      def children_html(el, kids, indent)
        @stack.push(el)
        kids.map { |c| convert(c, indent) }.join
      ensure
        @stack.pop
      end

      # Inline Markdown outside the tree (stage, summary, table foot).
      def inline_md(text)
        root, = Parser.parse(text, @options)
        p = root.children.find { |c| c.type == :p }
        p ? inner(p, 0) : ""
      end

      # The text of el as a screen reader gets it (for aria-label, data-label).
      def plain(el)
        case el.type
        when :text, :codespan then el.value
        when :entity then el.value.char
        when :smart_quote then QUOTES.fetch(el.value)
        else el.children.map { |c| plain(c) }.join
        end
      end

      # UI words and labels; no-break spaces written as on the pages.
      def esc(text, attr: false)
        s = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
        s = s.gsub('"', "&quot;") if attr
        s.gsub(" ", "&nbsp;")
      end

      def fail!(message) = raise(Error, "#{@source.file}: #{message}")
    end
  end
end
