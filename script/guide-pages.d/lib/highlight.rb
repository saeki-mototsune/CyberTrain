# Code figures for the guide pages: Rouge tokens -> the site's own markup,
# <figure class="code"> as in site/tutorial.html, one span.ln per line.
# Called by the renderer for each fenced block:
#   GuidePages::Highlight.figure(lang, place, text, words: {code_label: "Code: "})
#
# Rouge token -> span class, as site/tutorial.html colours its code
# (anything else is left unwrapped):
#   Comment.Preproc (ERB delimiters)                   d
#   Comment*                                           c
#   Keyword*, Name.Builtin.Pseudo (true/false/nil),
#     any name `self`, `require`, `require_relative`   k
#   Literal.String.Symbol, Name.Label (`foo:`)         y
#   Literal.String* (other), and the whole of an
#     interpolated string, "#{...}" included           s
#   Name.Constant, Name.Class                          t
#   Name.Variable*                                     v
#   Name.Tag (HTML tags in ERB), Generic.Heading       h
# HTML attribute names and TOML table headers stay plain.
# Shell and console: only comments and strings (with the $VARs inside them)
# are classed; the command text stays plain. A shell line is span.ln.cmd, a
# console "$ " line is span.ln.cmd and any other console line span.ln.out.
# A language with no Rouge lexer renders as plain lines (lexer? says false).
# Whitespace at the edge of a token is kept outside its span.

require "rouge"

module GuidePages
  module Highlight
    PLAIN = %w[text console].freeze

    module_function

    def lexer?(lang)
      PLAIN.include?(lang) || !Rouge::Lexer.find_fancy(lang).nil?
    end

    def figure(lang, place, text, words:)
      text = text.chomp
      label = esc("#{words[:code_label]}#{place || lang}", quotes: true)
      path = place ? %(<span class="code-path">#{caption(place)}</span>) : ""
      %(<figure class="code" data-lang="#{esc(lang, quotes: true)}">\n) +
        %(<figcaption>#{path}<span class="code-lang">#{esc(lang)}</span></figcaption>\n) +
        %(<pre tabindex="0" role="region" aria-label="#{label}"><code>#{lines(lang, text).join("\n")}</code></pre>\n</figure>)
    end

    # A path may break after each "/" that a word follows ("a/b", not "blog/").
    def caption(place)
      esc(place).gsub(%r{/(?=\S)}, "/<wbr>")
    end

    def lines(lang, text)
      case lang
      when "text" then text.split("\n", -1).map { |l| %(<span class="ln">#{esc(l)}</span>) }
      when "console" then text.split("\n", -1).map { |l| console_line(l) }
      when "shell", "sh", "bash", "zsh" then text.split("\n", -1).map { |l| shell_line(l) }
      else
        segs = split_lines(tokens(lang, text))
        segs.map! { |l| table_header(lang, l) }
        segs.map { |l| %(<span class="ln">#{render(l)}</span>) }
      end
    end

    def shell_line(line)
      return %(<span class="ln"></span>) if line.strip.empty?
      %(<span class="ln cmd">#{render(split_lines(tokens("shell", line)).first || [])}</span>)
    end

    def console_line(line)
      return %(<span class="ln cmd">#{render(split_lines(tokens("shell", line[2..])).first || [])}</span>) if line.start_with?("$ ")
      %(<span class="ln out">#{esc(line)}</span>)
    end

    # [[class_or_nil, text], ...] for the whole text.
    def tokens(lang, text)
      lexer = Rouge::Lexer.find_fancy(lang)
      return [[nil, text]] unless lexer # no lexer (e.g. caddyfile): plain, the caller warns via lexer?
      shell = lexer.tag == "shell"
      quote = false
      interpol = 0
      lexer.lex(text).flat_map do |tok, val|
        q = tok.qualname
        if q == "Literal.String.Interpol"
          # "#{" opens, "}" closes; everything in between is part of the string.
          interpol += 1 if val == "\#{"
          interpol -= 1 if val == "}" && interpol > 0
          [["s", val]]
        elsif interpol > 0
          [["s", val]]
        elsif shell
          # Inside quotes everything (including $VAR) is string; elsewhere only comments.
          quote = !quote if q.start_with?("Literal.String") && (val == '"' || val == "'")
          [[q.start_with?("Literal.String") || quote ? "s" : (q.start_with?("Comment") ? "c" : nil), val]]
        elsif q == "Literal.String.Symbol" && (m = val.match(/\A(\w+:)(\s+)(:.*)\z/m))
          # Rouge lexes `with: :x` as one symbol; the page has two, around the space.
          [["y", m[1]], [nil, m[2]], ["y", m[3]]]
        else
          [[klass(q, val), val]]
        end
      end
    end

    KEYWORD_NAMES = %w[self require require_relative].freeze

    def klass(q, val = nil)
      return "k" if q.start_with?("Name") && KEYWORD_NAMES.include?(val)

      case q
      when /\AComment\.Preproc/ then "d"
      when /\AComment/ then "c"
      when /\AKeyword/, "Name.Builtin.Pseudo" then "k"
      when "Literal.String.Symbol", "Name.Label" then "y"
      when /\ALiteral\.String/ then "s"
      when "Name.Constant", "Name.Class" then "t"
      when /\AName\.Variable/ then "v"
      when "Name.Tag", "Generic.Heading" then "h"
      end
    end

    # Cut the token stream at "\n" into one segment list per line.
    def split_lines(toks)
      out = [[]]
      toks.each do |cls, val|
        parts = val.split("\n", -1)
        parts.each_with_index do |part, i|
          out << [] if i > 0
          out.last << [cls, part] unless part.empty?
        end
      end
      out
    end

    # `[table]` / `[[table]]` lines of TOML are plain (Rouge makes the
    # brackets keywords).
    def table_header(lang, segs)
      return segs unless lang == "toml"
      text = segs.map(&:last).join
      text.match?(/\A\s*\[.*\]\s*\z/) ? [[nil, text]] : segs
    end

    def render(segs)
      merged = segs.each_with_object([]) do |(cls, val), acc|
        if acc.last && acc.last[0] == cls then acc.last[1] += val else acc << [cls, val.dup] end
      end
      merged.map do |cls, val|
        next esc(val) unless cls
        lead = val[/\A\s*/]
        trail = val[/\s*\z/]
        core = val.strip
        next esc(val) if core.empty?
        %(#{esc(lead)}<span class="#{cls}">#{esc(core)}</span>#{esc(trail)})
      end.join
    end

    def esc(s, quotes: false)
      s = s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      quotes ? s.gsub('"', "&quot;") : s
    end
  end
end
