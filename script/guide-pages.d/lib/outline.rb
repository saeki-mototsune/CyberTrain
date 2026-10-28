# The Markdown outline parser for the guide pages: title, sections (with their
# step comment, code blocks, table rows and markers) and links, by a line scan
# in the style of script/check-docs-i18n. Standard library only, so that the
# translation checker can run with no gems.

require "cgi/escape"

module GuidePages
  class Error < StandardError; end

  STEP = /\A\s*<!--\s*step\s+(\S+)\s+#(\S+)(?:\s+stage:\s*(.*?))?\s*-->\s*\z/
  MARKER_COMMENT = /\A\s*<!--\s*(list|table):\s*(\S+(?:\s+\S+)*?)\s*-->\s*\z/
  # The marker is the kind; text after it (a callout's aria-label) is prose.
  ALERT = /\A>\s*\[!(WHY|RULE|COMPILE|EXAMPLE|NOTE)\](?:[ \t]+\S.*)?\s*\z/
  LINK_RE = /!?\[[^\]]*\]\(\s*<?([^\s)>]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)|<a\s[^>]*?href\s*=\s*["']([^"']+)["']/i
  REF_DEF = /\A {0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?\z/

  Step = Struct.new(:num, :id, :stage)
  Code = Struct.new(:lang, :place, :text)
  Section = Struct.new(:level, :text, :line, :step, :codes, :table_rows, :markers)

  class Outline
    attr_reader :title, :sections, :links

    # GFM heading anchor: markup and tags stripped, entities decoded (a
    # no-break space is a space), lowercased, only letters, digits, spaces,
    # "-" and "_" kept, spaces turned into "-".
    def self.slug(text)
      t = text.gsub(/!?\[([^\]]*)\]\([^)]*\)/, '\1')
      t = t.gsub(/<[^>]*>/, "").delete("`*~")
      t = CGI.unescapeHTML(t.gsub("&nbsp;", " ")).tr("\u00A0", " ").gsub(/&[A-Za-z][A-Za-z0-9]*;/, "")
      t.downcase.gsub(/[^\p{L}\p{N} _-]/, "").tr(" ", "-")
    end

    def self.parse(body) = new(body)

    def initialize(body)
      @sections = [Section.new(0, nil, 0, nil, [], 0, [])]
      @links = []
      titles = []
      pending_step = nil
      fence = nil
      quote_open = false
      body.each_line.with_index(1) do |raw, no|
        line = raw.chomp
        if fence
          if line =~ /\A\s*```\s*\z/
            @sections.last.codes << Code.new(fence[:lang], fence[:place], fence[:text])
            fence = nil
          else
            fence[:text] << line.sub(/\A#{fence[:indent]}/, "") << "\n"
          end
          next
        end
        if line =~ /\A(\s*)```(\S*)[ \t]*(.*?)\s*\z/
          place = $3.empty? ? nil : $3
          fence = { indent: $1, lang: $2, place: place, text: +"" }
          next
        end
        scan_links(line)
        if (m = line.match(STEP))
          pending_step = Step.new(m[1], m[2], m[3])
        elsif line =~ /\A# (.*)/
          titles << $1.strip
        elsif line =~ /\A(\#{2,6}) (.*)/
          step, pending_step = pending_step, nil
          @sections << Section.new($1.size, $2.strip, no, step, [], 0, [])
        elsif line.start_with?("|")
          @sections.last.table_rows += 1 unless line =~ /\A\|[\s:|-]+\|\s*\z/
        elsif (m = line.match(ALERT))
          @sections.last.markers << m[1] unless quote_open
        elsif (m = line.match(MARKER_COMMENT))
          @sections.last.markers << "#{m[1]}:#{m[2]}"
        elsif line.start_with?("<details")
          @sections.last.markers << "details"
        end
        quote_open = line.start_with?(">")
      end
      raise Error, "expected exactly one '# ' title, found #{titles.size}" unless titles.size == 1

      @title = titles.first
    end

    private

    def scan_links(line)
      if (m = line.match(REF_DEF))
        @links << m[1]
        return
      end
      line.scan(LINK_RE) { |inline, anchor| @links << (inline || anchor) }
    end
  end
end
