# Tests for GuidePages::Render (Markdown conventions -> the markup of
# site/tutorial.html) and GuidePages::WORDS. Sources are built in memory;
# links resolve against the repository files in fixtures/links.
# usage: ruby -Iscript/guide-pages.d/lib script/guide-pages.d/test/render_test.rb

require "minitest/autorun"
require "render"

class RenderTest < Minitest::Test
  ROOT = File.expand_path("fixtures/links", __dir__)

  def source(text, file = "docs/guide/x.md") = GuidePages::Source.new(file, text)

  # Renders text as docs/guide/x.md (or its translation, with english).
  def render(text, lang: "en", english: nil)
    en = english ? source(english) : nil
    src = lang == "en" ? source(text) : source(text, "docs/guide/#{lang}/x.md")
    en ||= src
    sources = { "en" => { "x" => en } }
    sources[lang] = { "x" => src } unless lang == "en"
    @links = GuidePages::Links.new(sources: sources, root: ROOT)
    GuidePages::Render.page(src, english: en, links: @links, words: GuidePages::WORDS.fetch(lang))
  end

  def body(md, **kw) = render("# T\n\nIntro.\n\n## S\n\n#{md}\n\n## Last\n", **kw).sections_html

  def test_h1_and_intro
    page = render("# Getting started: the&nbsp;blog\n\nMirrors Rails' own [Getting Started](https://guides.rubyonrails.org/x) guide.\n\n## A\n")
    assert_equal "Getting started: the&nbsp;blog", page.h1
    assert_equal %(Mirrors Rails' own <a href="https://guides.rubyonrails.org/x" rel="noopener">Getting Started</a> guide.), page.intro_html
  end

  def test_h1_id_from_english
    assert_equal "how-it-works", render("# How it works\n\nIntro.\n\n## A\n").h1_id
    page = render("# 仕組み\n\n導入。\n\n## A\n", lang: "ja", english: "# How it works\n\nIntro.\n\n## A\n")
    assert_equal ["how-it-works", "仕組み"], [page.h1_id, page.h1]
  end

  def test_content_before_title_rejected
    e = assert_raises(GuidePages::Error) { render("Stray.\n\n# T\n\nIntro.\n\n## A\n") }
    assert_match(/docs\/guide\/x\.md: .*before the # title/, e.message)
  end

  def test_sub_heading_count_must_match_english
    english = "# T\n\nIntro.\n\n## A\n\n### One\n\n### Two\n"
    e = assert_raises(GuidePages::Error) { render("# T\n\nI.\n\n## A\n\n### Un\n", lang: "ja", english: english) }
    assert_match(/1 sub-headings, the English has 2/, e.message)
    assert_raises(GuidePages::Error) { render("# T\n\nI.\n\n## A\n\n### Un\n\n### Deux\n\n### Trois\n", lang: "ja", english: english) }
  end

  def test_step_section_markup
    page = render(<<~MD)
      # T

      Intro.

      <!-- step 05 #validations stage: You write · `app/models/` -->
      ## Add model validations

      Text.

      ## Last
    MD
    assert_includes page.sections_html, <<~HTML
      \x20 <section class="step" id="validations" aria-labelledby="h-validations">
      \x20   <p class="stage"><span class="stage-k">You are here<span class="sr-only">:</span></span>You write <span aria-hidden="true">&middot;</span> <code>app/models/</code></p>
      \x20   <h2 id="h-validations"><span class="step-num" aria-hidden="true">05</span>Add model validations</h2>
      \x20   <p>Text.</p>
      \x20 </section>
    HTML
  end

  def test_auto_numbered_sections
    page = render("# T\n\nIntro.\n\n## Differences from Rails\n\nA.\n\n## Querying beyond `where`\n\nB.\n")
    assert_includes page.sections_html, %(<section class="step" id="differences-from-rails" aria-labelledby="h-differences-from-rails">)
    assert_includes page.sections_html, %(<h2 id="h-querying-beyond-where"><span class="step-num" aria-hidden="true">02</span>Querying beyond <code>where</code></h2>)
    assert_equal [["01", "differences-from-rails", "Differences from Rails", false],
                  ["02", "querying-beyond-where", "Querying beyond <code>where</code>", false]],
                 page.toc.map { |t| [t.num, t.id, t.title_html, t.extra] }
  end

  def test_last_step_class
    html = render("# T\n\nIntro.\n\n## A\n\n## B\n").sections_html
    assert_includes html, %(<section class="step" id="a")
    assert_includes html, %(<section class="step step-last" id="b")
    assert_equal 1, html.scan("step-last").size
  end

  def test_plus_step_toc_extra
    page = render(<<~MD)
      # T

      Intro.

      <!-- step 15 #ship -->
      ## Build

      <!-- step + #things-to-know -->
      ## Things to know

      <!-- step → #where-next -->
      ## Where next
    MD
    assert_equal [["15", false], ["+", true], ["→", true]], page.toc.map { |t| [t.num, t.extra] }
    assert_includes page.sections_html, %(<span class="step-num" aria-hidden="true">+</span>Things to know</h2>)
    assert_includes page.sections_html, %(<span class="step-num" aria-hidden="true">&rarr;</span>Where next</h2>)
  end

  def test_malformed_step_comment
    e = assert_raises(GuidePages::Error) { render("# T\n\n<!-- step 05 validations -->\n## A\n") }
    assert_match(/docs\/guide\/x\.md: malformed step comment/, e.message)
  end

  def test_why_box
    assert_includes body("> [!WHY]\n> Because it's `x`."),
                    %(    <p class="why"><span class="why-k">Why</span><span class="why-t">Because it's <code>x</code>.</span></p>\n)
  end

  def test_rule_callout
    html = body(<<~MD)
      > [!RULE] Spinel rule: new_action
      > ### `new_action`, not `new`
      > A method named `new` would shadow it.

      > [!EXAMPLE]
      > ### Deleting an article
      > Body:
      >
      > ```ruby app/models/article.rb (excerpt)
      > before_destroy { }
      > ```
    MD
    assert_includes html, <<~HTML
      \x20   <aside class="callout" aria-label="Spinel rule: new_action">
      \x20     <p class="callout-k">Spinel rule</p>
      \x20     <h3><code>new_action</code>, not <code>new</code></h3>
      \x20     <p>A method named <code>new</code> would shadow it.</p>
      \x20   </aside>
    HTML
    assert_includes html, %(    <aside class="callout" aria-label="From the finished example: Deleting an article">\n      <p class="callout-k">From the finished example</p>\n      <h3>Deleting an article</h3>\n      <p>Body:</p>\n      <figure class="code" data-lang="ruby">\n<figcaption>)
    assert_includes html, %(aria-label="Code: app/models/article.rb (excerpt)")
  end

  def test_compile_callout_and_ja_separator
    html = body("> [!COMPILE]\n> ### スニペット\n> 本文。", lang: "ja",
                english: "# T\n\nIntro.\n\n## S\n\n> [!COMPILE]\n> ### Snippets\n> Body.\n\n## Last\n")
    assert_includes html, %(<aside class="callout" aria-label="コンパイルする前に：スニペット">\n      <p class="callout-k">コンパイルする前に</p>)
  end

  def test_callout_needs_title
    e = assert_raises(GuidePages::Error) { body("> [!RULE]\n> Body.") }
    assert_match(/RULE.*### title/, e.message)
  end

  def test_note
    assert_includes body("> [!NOTE]\n> See the [playground](site:playground.html)."),
                    %(    <p class="note">See the <a href="../playground.html">playground</a>.</p>\n)
  end

  def test_details_ci
    html = body(<<~MD)
      <details><summary>How CyberTrain installs Spinel — What happens the first time a command needs `spin`</summary>

      First `para`.

      ```shell terminal — any directory
      export PATH="$HOME/bin:$PATH"
      ```

      </details>
    MD
    assert_includes html, <<~HTML
      \x20   <details class="ci">
      \x20     <summary><span class="ci-t">How CyberTrain installs Spinel</span><span class="ci-d">What happens the first time a command needs <code>spin</code></span></summary>
      \x20     <div class="ci-body">
      \x20   <p>First <code>para</code>.</p>
      \x20   <figure class="code" data-lang="shell">
      <figcaption><span class="code-path">terminal — any directory</span><span class="code-lang">shell</span></figcaption>
    HTML
    assert_includes html, %(</code></pre>\n</figure>\n      </div>\n    </details>\n)
  end

  def test_checklist_class
    html = body("<!-- list: checklist -->\n- one `a`\n- two\n\n<!-- list: points know -->\n- three\n")
    assert_includes html, %(    <ul class="checklist">\n      <li>one <code>a</code></li>\n      <li>two</li>\n    </ul>\n)
    assert_includes html, %(    <ul class="points know">\n      <li>three</li>\n    </ul>\n)
    refute_includes html, "<!--"
  end

  def test_unknown_list_class
    assert_raises(GuidePages::Error) { body("<!-- list: fancy -->\n- one\n") }
  end

  def test_next_list
    html = body(<<~MD)
      <!-- list: next-list -->
      - [**`examples/blog`**](../../examples/blog) — The finished app, with its tests.
      - [**API reference**](site:api/index.html) — Every class and method.
    MD
    assert_includes html, <<~HTML
      \x20   <ul class="next-list">
      \x20     <li><a href="https://github.com/saeki-mototsune/CyberTrain/tree/main/examples/blog" rel="noopener"><span class="next-t"><code>examples/blog</code></span><span class="next-d">The finished app, with its tests.</span></a></li>
      \x20     <li><a href="../api/index.html"><span class="next-t">API reference</span><span class="next-d">Every class and method.</span></a></li>
      \x20   </ul>
    HTML
  end

  def test_cmp_table
    html = body(<<~MD)
      <!-- table: cmp -->
      | Rails | CyberTrain |
      |---|---|
      | `rails console` | No console — Spinel has no `eval` |
      | Many adapters | SQLite only |
      <!-- table-foot: Not exhaustive. -->
    MD
    assert_includes html, %(    <div class="cmp-wrap cmp-doc">\n      <table class="cmp cmp-full">\n        <caption class="sr-only">Differences between Rails and CyberTrain (full table from the README)</caption>\n        <thead><tr><th scope="col" class="cmp-rails">Rails</th><th scope="col" class="cmp-ct"><svg class="cmp-mark" aria-hidden="true")
    assert_includes html, %(</svg><span>CyberTrain</span></th></tr></thead>\n        <tbody>\n)
    assert_includes html, %(          <tr><td data-label="Rails"><code>rails console</code></td><td data-label="CyberTrain">No console — Spinel has no <code>eval</code></td></tr>\n)
    assert_includes html, %(        </tbody>\n      </table>\n      <p class="cmp-foot">Not exhaustive.</p>\n    </div>\n)
  end

  def test_sub_heading_ids
    html = body("### Run the tests\n\nText.")
    assert_includes html, %(    <h3 class="sub" id="run-the-tests">Run the tests</h3>\n)
  end

  def test_translated_ids_follow_english
    english = "# T\n\nIntro.\n\n<!-- step 05 #validations -->\n## Add validations\n\n### Run the tests\n\n## Differences from Rails\n"
    page = render("# T\n\n導入。\n\n<!-- step 05 #validations -->\n## 検証を追加\n\n### テストを実行\n\n## Rails との違い\n",
                  lang: "ja", english: english)
    assert_includes page.sections_html, %(<section class="step" id="validations")
    assert_includes page.sections_html, %(<h3 class="sub" id="run-the-tests">テストを実行</h3>)
    assert_includes page.sections_html, %(<section class="step step-last" id="differences-from-rails" aria-labelledby="h-differences-from-rails">)
    assert_includes page.sections_html, %(<h2 id="h-differences-from-rails"><span class="step-num" aria-hidden="true">01</span>Rails との違い</h2>)
    assert_equal %w[validations differences-from-rails], page.toc.map(&:id)
  end

  def test_words_from_lang
    html = render("# T\n\n導入。\n\n<!-- step 00 #req stage: 準備 · Ruby -->\n## 必要なもの\n\n> [!WHY]\n> 理由。\n",
                  lang: "ja", english: "# T\n\nIntro.\n\n<!-- step 00 #req stage: Setup · Ruby -->\n## Requirements\n\n> [!WHY]\n> Reason.\n").sections_html
    assert_includes html, %(<span class="stage-k">現在地<span class="sr-only">:</span></span>準備 <span aria-hidden="true">&middot;</span> Ruby</p>)
    assert_includes html, %(<span class="why-k">なぜ</span><span class="why-t">理由。</span>)
    fr = body("> [!RULE]\n> ### Titre", lang: "fr", english: "# T\n\nIntro.\n\n## S\n\n> [!RULE]\n> ### Title\n\n## Last\n")
    assert_includes fr, %(aria-label="Règle Spinel&nbsp;: Titre")
  end

  def test_words_complete
    keys = GuidePages::WORDS.fetch("en").keys
    %i[why rule compile example here code_label contents skip guides lang_label aria_sep].each { |k| assert_includes keys, k }
    GuidePages::LANGS.each { |l| assert_equal keys.sort, GuidePages::WORDS.fetch(l).keys.sort, l }
    assert_equal "Code : ", GuidePages::WORDS["fr"][:code_label]
  end

  def test_external_and_raw_links
    html = body(%(See [Kamal](https://kamal-deploy.org) and <a href="../design.md">design</a>.))
    assert_includes html, %(<a href="https://kamal-deploy.org" rel="noopener">Kamal</a>)
    assert_includes html, %(<a href="https://github.com/saeki-mototsune/CyberTrain/blob/main/docs/design.md" rel="noopener">design</a>)
  end

  def test_link_errors_collected
    body("[x](missing.md)")
    assert_equal ["docs/guide/x.md: link missing.md: no source docs/guide/missing.md"], @links.errors
  end

  def test_raw_html_passes_through
    raw = <<~HTML.chomp
      <ul class="ship-grid">
        <li class="ship-bin"><code>dist/blog</code><span>the compiled framework &amp; views</span></li>
        <li><code>dist/public/</code><span>static assets</span></li>
      </ul>
    HTML
    assert_includes body(raw), raw.sub("<ul", "    <ul")
  end

  def test_text_is_kept_as_written
    html = body(%(It's "quoted" -- and... `a "b" <c>` &rsquo; &amp; <b>x</b>))
    assert_includes html, %(<p>It's "quoted" -- and... <code>a "b" &lt;c&gt;</code> &rsquo; &amp; <b>x</b></p>)
  end
end
