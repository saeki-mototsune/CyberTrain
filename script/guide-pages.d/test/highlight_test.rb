# Tests for GuidePages::Highlight (Rouge code figures).
# usage: ruby -Iscript/guide-pages.d/lib script/guide-pages.d/test/highlight_test.rb

require "minitest/autorun"
require "highlight"

class HighlightTest < Minitest::Test
  WORDS = { code_label: "Code: " }.freeze

  def fig(lang, place, text)
    GuidePages::Highlight.figure(lang, place, text, words: WORDS)
  end

  def code_of(html)
    html[%r{<code>(.*)</code></pre>}m, 1]
  end

  # The step-05 block of site/tutorial.html, byte for byte.
  def test_ruby_matches_tutorial
    src = <<~RUBY
      # app/models/article.rb -- only the first string field gets a default
      # presence validation; add anything past that yourself.
      class Article
        validates :title, presence: true
        validates :body, presence: true, length: { minimum: 10 }
      end
    RUBY
    expected = <<~HTML.chomp
      <span class="ln"><span class="c"># app/models/article.rb -- only the first string field gets a default</span></span>
      <span class="ln"><span class="c"># presence validation; add anything past that yourself.</span></span>
      <span class="ln"><span class="k">class</span> <span class="t">Article</span></span>
      <span class="ln">  validates <span class="y">:title</span>, <span class="y">presence:</span> <span class="k">true</span></span>
      <span class="ln">  validates <span class="y">:body</span>, <span class="y">presence:</span> <span class="k">true</span>, <span class="y">length:</span> { <span class="y">minimum:</span> 10 }</span>
      <span class="ln"><span class="k">end</span></span>
    HTML
    html = fig("ruby", "app/models/article.rb", src)
    assert_equal expected, code_of(html)
    assert_equal <<~HEAD.chomp, html.lines.first(3).join.chomp
      <figure class="code" data-lang="ruby">
      <figcaption><span class="code-path">app/<wbr>models/<wbr>article.rb</span><span class="code-lang">ruby</span></figcaption>
      <pre tabindex="0" role="region" aria-label="Code: app/models/article.rb"><code><span class="ln"><span class="c"># app/models/article.rb -- only the first string field gets a default</span></span>
    HEAD
    assert html.end_with?("</code></pre>\n</figure>")
  end

  def test_shell_lines_are_commands
    html = fig("shell", "terminal — blog/", "cybertrain db migrate    # spin run gen\n\nexport PATH=\"$HOME/bin:$PATH\"\n")
    assert_equal <<~HTML.chomp, code_of(html)
      <span class="ln cmd">cybertrain db migrate    <span class="c"># spin run gen</span></span>
      <span class="ln"></span>
      <span class="ln cmd">export PATH=<span class="s">"$HOME/bin:$PATH"</span></span>
    HTML
  end

  def test_console_splits_commands_and_output
    html = fig("console", nil, "$ cybertrain server\n=> Booting <x>\n")
    assert_equal <<~HTML.chomp, code_of(html)
      <span class="ln cmd">cybertrain server</span>
      <span class="ln out">=&gt; Booting &lt;x&gt;</span>
    HTML
  end

  # "/" followed by a non-space breaks; a "/" at the end of a word does not.
  def test_caption_wbr_in_path_with_free_text
    assert_includes fig("ruby", "app/models/article.rb (excerpt)", "x"), '<span class="code-path">app/<wbr>models/<wbr>article.rb (excerpt)</span>'
    assert_includes fig("shell", "terminal — any directory, then blog/", "x"), '<span class="code-path">terminal — any directory, then blog/</span>'
  end

  def test_caption_wbr
    assert_includes fig("ruby", "app/models/a.rb", "x"), '<span class="code-path">app/<wbr>models/<wbr>a.rb</span>'
    # free text (has whitespace) is not broken at slashes
    assert_includes fig("shell", "terminal — blog/", "ls"), '<span class="code-path">terminal — blog/</span>'
  end

  def test_no_place_uses_lang_in_aria
    html = fig("ruby", nil, "x = 1")
    assert_includes html, 'aria-label="Code: ruby"'
    assert_includes html, "<figcaption><span class=\"code-lang\">ruby</span></figcaption>"
  end

  def test_escapes_erb_once
    code = code_of(fig("erb", nil, '<%= link_to "a&b" %>'))
    assert_includes code, "&lt;%="
    assert_includes code, "a&amp;b"
    refute_includes code, "&amp;amp;"
    refute_includes code, "&amp;lt;"
    assert_includes code, '<span class="d">&lt;%=</span>'
  end

  def test_text_is_plain_and_escaped
    assert_equal '<span class="ln">a &amp; b</span>', code_of(fig("text", nil, "a & b\n"))
  end

  def test_lexer_known
    h = GuidePages::Highlight
    %w[text console ruby erb shell toml].each { |l| assert h.lexer?(l), l }
    refute h.lexer?("caddyfile")
    assert_equal '<span class="ln">a &lt; b</span>', h.figure("caddyfile", nil, "a < b", words: WORDS)[/<code>(.*)<\/code>/, 1]
  end
end
