# Tests for GuidePages::Build (script/guide-pages): the pages, their shell
# (layout.html.erb) and the api/file.*.html redirects, built from the English
# and Japanese sources in fixtures/pages into a temporary directory.
# usage: ruby -Iscript/guide-pages.d/lib script/guide-pages.d/test/build_test.rb

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "build"

class BuildTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/pages", __dir__)
  BASE = "https://saeki-mototsune.github.io/CyberTrain/"

  def setup
    @root = Dir.mktmpdir
    FileUtils.cp_r(File.join(FIXTURE, "."), @root)
    @out = File.join(@root, "out")
  end

  def teardown = FileUtils.remove_entry(@root)

  def build = GuidePages::Build.run(root: @root, out: @out)

  def built
    errors = build
    assert_empty errors
  end

  def page(path) = File.read(File.join(@out, path), encoding: "UTF-8")

  def write(file, text) = File.write(File.join(@root, "docs/guide", file), text)

  def test_writes_pages_per_lang
    built
    files = Dir.glob("**/*", base: @out).select { |f| File.file?(File.join(@out, f)) }.sort
    assert_equal %w[api/file.install.html api/file.walkthrough.html guide/install.html
                    ja/guide/install.html ja/tutorial.html tutorial.html], files
    html = page("ja/guide/install.html")
    assert_match %r{\A<!doctype html>\n<html lang="ja">\n}, html
    assert_includes html, "<title>cybertrain のインストール · CyberTrain</title>"
    assert_includes html, %(<h1 id="installing-cybertrain">cybertrain のインストール</h1>)
    assert_includes html, %(<p class="doc-intro">インストール方法。</p>)
    assert_includes html, %(<a class="skip" href="#main">本文へスキップ</a>)
    assert_includes html, %(<a href="../tutorial.html#install">チュートリアル</a>)
  end

  def test_front_path_overrides
    built
    refute File.exist?(File.join(@out, "guide/tutorial.html"))
    html = page("tutorial.html")
    assert_includes html, "<title>Getting started: the blog · CyberTrain</title>"
    assert_includes html, %(<meta name="description" content="Build a blog with CyberTrain.">)
    assert_includes html, %(<span>Tutorial</span></p>)
    assert_includes html, %(<li><a href="tutorial.html" aria-current="page">Tutorial</a></li>)
    assert_includes html, %(<li class="nav-wide-only"><a href="guide/index.html">Guides</a></li>)
    assert_includes html, %(<div><dt>You need</dt><dd>Ruby 3.2+ <a class="meta-link" href="#requirements">Step 00</a></dd></div>)
    # Defaults: title, description and crumb from the page itself; nav guides.
    html = page("guide/install.html")
    assert_includes html, "<title>Installing cybertrain · CyberTrain</title>"
    assert_includes html, %(<meta name="description" content="How to install it, &amp; more.">)
    assert_includes html, %(<span>Installing cybertrain</span></p>)
    assert_includes html, %(<li class="nav-wide-only"><a href="../guide/index.html" aria-current="page">Guides</a></li>)
    assert_includes html, %(<li><a href="../tutorial.html">Tutorial</a></li>)
    refute_includes html, "doc-meta"
  end

  def test_hreflang_and_lang_menu
    built
    html = page("ja/guide/install.html")
    alternates = html.scan(/<link rel="alternate" hreflang="([^"]+)" href="([^"]+)">/)
    assert_equal [["en", "#{BASE}guide/install.html"], ["ja", "#{BASE}ja/guide/install.html"],
                  ["zh-Hans", "#{BASE}zh/guide/install.html"], ["ru", "#{BASE}ru/guide/install.html"],
                  ["fr", "#{BASE}fr/guide/install.html"], ["x-default", "#{BASE}guide/install.html"]], alternates
    assert_includes html, %(<summary aria-label="言語: 日本語">JA</summary>)
    menu = html.scan(/<li><a href="([^"]+)" hreflang="([^"]+)" lang="[^"]+"( aria-current="true")?>/)
    assert_equal 10, menu.size # the header menu and the footer list
    assert_equal [["../../guide/install.html", "en", nil], ["../../ja/guide/install.html", "ja", %( aria-current="true")],
                  ["../../zh/guide/install.html", "zh-Hans", nil], ["../../ru/guide/install.html", "ru", nil],
                  ["../../fr/guide/install.html", "fr", nil]], menu.first(5)
    assert_equal menu.first(5), menu.last(5)
    en = page("tutorial.html")
    assert_includes en, %(<li><a href="tutorial.html" hreflang="en" lang="en" aria-current="true">English</a></li>)
    assert_includes en, %(<li><a href="ja/tutorial.html" hreflang="ja" lang="ja">日本語</a></li>)
  end

  def test_canonical_and_og
    built
    html = page("ja/tutorial.html")
    assert_includes html, %(<link rel="canonical" href="#{BASE}ja/tutorial.html">)
    assert_includes html, %(<meta property="og:url" content="#{BASE}ja/tutorial.html">)
    assert_includes html, %(<meta property="og:image" content="#{BASE}assets/og/ja/tutorial.png">)
    assert_includes html, %(<meta property="og:image:alt" content="CyberTrain をはじめよう">)
    assert_includes html, %(<meta property="og:title" content="CyberTrain をはじめよう">)
    assert_includes html, %(<meta property="og:description" content="CyberTrain でブログを作ります。">)
    assert_includes html, %(<meta property="og:locale" content="ja_JP">)
    assert_equal %w[en_US zh_CN ru_RU fr_FR], html.scan(/og:locale:alternate" content="([^"]+)"/).flatten
    # Defaults: og_image index.png, og_title and og_description from title and description.
    html = page("guide/install.html")
    assert_includes html, %(<meta property="og:image" content="#{BASE}assets/og/en/index.png">)
    assert_includes html, %(<meta property="og:title" content="Installing cybertrain">)
    assert_includes html, %(<meta property="og:description" content="How to install it, &amp; more.">)
    assert_includes html, %(<meta property="og:locale" content="en_US">)
  end

  def test_asset_depth
    built
    assert_includes page("tutorial.html"), %(<link rel="stylesheet" href="assets/style.css">)
    assert_includes page("tutorial.html"), %(<li class="nav-roomy-only"><a href="api/index.html">API</a></li>)
    assert_includes page("ja/tutorial.html"), %(<link rel="stylesheet" href="../assets/style.css">)
    assert_includes page("ja/tutorial.html"), %(<a class="brand" href="index.html" aria-label="CyberTrain ホーム">)
    html = page("guide/install.html")
    assert_includes html, %(<link rel="stylesheet" href="../assets/style.css">)
    assert_includes html, %(<script src="../assets/site.js" defer></script>)
    assert_includes html, %(<a href="../index.html">home</a>)
    html = page("ja/guide/install.html")
    assert_includes html, %(<link rel="stylesheet" href="../../assets/style.css">)
    assert_includes html, %(<li class="nav-roomy-only"><a href="../../api/index.html">API</a></li>)
    assert_includes html, %(<a class="brand" href="../index.html" aria-label="CyberTrain ホーム">)
    assert_includes html, %(<a href="../index.html">ホーム</a>)
  end

  def test_toc_from_sections
    built
    html = page("tutorial.html")
    assert_includes html, %(<div class="wrap doc">\n  <nav class="toc" aria-label="Tutorial steps">)
    assert_includes html, %(<span class="toc-title">Steps 00&ndash;01</span>)
    assert_equal [[nil, "requirements", "00", "Requirements"], [nil, "install", "01", "Install the CLI"],
                  [%( class="toc-x"), "things-to-know", "+", "Things to know"]],
                 html.scan(%r{<li( class="toc-x")?><a href="#([^"]+)"><span class="toc-n">([^<]+)</span>(.*?)</a></li>})
    html = page("ja/guide/install.html")
    assert_includes html, %(<nav class="toc" aria-label="目次">)
    assert_includes html, %(<span class="toc-title">目次</span>)
    assert_includes html, %(<li><a href="#differences-from-rails"><span class="toc-n">02</span>Rails との違い</a></li>)
  end

  # A page with no ## section (the Guides index) has no contents list at all,
  # not an empty one, and doc-plain instead of the .doc grid, whose first
  # column is the list's.
  def test_no_toc_without_sections
    write("x.md", "# X\n\nI.\n\n<!-- list: next-list -->\n- [**Install**](install.md) — How\n")
    built
    html = page("guide/x.html")
    refute_includes html, %(<nav class="toc")
    assert_includes html, %(<div class="wrap doc-plain">\n  <article class="doc-body">)
  end

  def test_redirects_written
    built
    assert_equal %(<!doctype html><meta charset="utf-8"><title>Moved</title><link rel="canonical" href="#{BASE}guide/install.html"><meta http-equiv="refresh" content="0; url=../guide/install.html"><p>Moved to <a href="../guide/install.html">../guide/install.html</a>.</p>\n),
                 page("api/file.install.html")
    assert_includes page("api/file.walkthrough.html"), %(content="0; url=../tutorial.html")
    refute File.exist?(File.join(@out, "api/file.tutorial.html"))
  end

  def test_errors_write_nothing
    write("install.md", File.read(File.join(FIXTURE, "docs/guide/install.md")).sub("tutorial.md#install", "tutorial.md#nowhere"))
    write("broken.md", "---\nfoo: 1\n---\n# B\n\nIntro.\n\n## A\n")
    errors = build
    assert_includes errors, "docs/guide/broken.md: unknown front matter key \"foo\""
    assert_includes errors, "docs/guide/install.md: link tutorial.md#nowhere: no anchor #nowhere on docs/guide/tutorial.md"
    refute Dir.exist?(@out)
  end

  def test_missing_h1_error
    write("install.md", "Intro.\n\n## Requirements\n\n## Differences from Rails\n")
    errors = build
    assert_includes errors, "docs/guide/install.md: expected exactly one '# ' title, found 0"
    refute Dir.exist?(@out)
  end

  def test_unknown_fence_lang_error
    write("extra.md", "# Extra\n\nIntro.\n\n## A\n\n```klingon\nx\n```\n")
    errors = build
    assert_equal [%(docs/guide/extra.md: code fence language "klingon" has no Rouge lexer)], errors
    refute Dir.exist?(@out)
  end

  def crumb(path) = page(path)[%r{<p class="crumb">(.*?)</p>}, 1]

  def test_crumbs
    write("index.md", "# Guides\n\nAll of them.\n\n## List\n")
    built
    sep = %(<span aria-hidden="true"> / </span>)
    assert_equal %(<a href="index.html">CyberTrain</a>#{sep}<span>Tutorial</span>), crumb("tutorial.html")
    assert_equal %(<a href="../index.html">CyberTrain</a>#{sep}<a href="../guide/index.html">Guides</a>#{sep}<span>Installing cybertrain</span>),
                 crumb("guide/install.html")
    assert_equal %(<a href="../index.html">CyberTrain</a>#{sep}<a href="../guide/index.html">ガイド</a>#{sep}<span>cybertrain のインストール</span>),
                 crumb("ja/guide/install.html")
    assert_equal %(<a href="../index.html">CyberTrain</a>#{sep}<span>Guides</span>), crumb("guide/index.html")
  end

  def test_translations_of_a_failed_english_source_skipped
    write("install.md", "---\nfoo: 1\n---\n# Installing cybertrain\n\nIntro.\n\n## Requirements\n\n## Differences from Rails\n")
    errors = build
    assert_includes errors, %(docs/guide/install.md: unknown front matter key "foo")
    refute errors.any? { |e| e.start_with?("docs/guide/ja/install.md") }, errors.inspect
  end

  # path is tutorial.html or guide/<name>.html: nothing else of the site
  # can be overwritten, nothing outside --out written.
  def test_path_allowed
    write("x.md", "---\npath: guide/x.html\n---\n# X\n\nI.\n\n## A\n")
    built
    assert File.exist?(File.join(@out, "guide/x.html"))
  end

  def test_path_rejected
    write("x.md", "---\npath: index.html\n---\n# X\n\nI.\n\n## A\n")
    write("y.md", "---\npath: ../escape.html\n---\n# Y\n\nI.\n\n## A\n")
    write("z.md", "---\npath: guide/install.html\n---\n# Z\n\nI.\n\n## A\n")
    errors = build
    assert_includes errors, %(docs/guide/x.md: path must be tutorial.html or guide/x.html, not "index.html")
    assert_includes errors, %(docs/guide/y.md: path must be tutorial.html or guide/y.html, not "../escape.html")
    assert_includes errors, %(docs/guide/z.md: path must be tutorial.html or guide/z.html, not "guide/install.html")
    refute Dir.exist?(@out)
    refute File.exist?(File.join(@root, "escape.html"))
  end

  # Checked on every page, not only when a link points at one of them.
  def test_duplicate_heading_id
    write("x.md", "# X\n\nI.\n\n## A\n\n## A\n")
    assert_includes build, "docs/guide/x.md: heading id #a is used twice"
  end

  def test_missing_site_target
    write("x.md", "# X\n\nSee [deploy](site:deploy.html).\n\n## A\n")
    assert_equal ["docs/guide/x.md: link site:deploy.html: site/deploy.html does not exist"], build
  end

  def test_invalid_nav = (write("x.md", "---\nnav: home\n---\n# X\n\nI.\n\n## A\n"); assert_includes build, %(docs/guide/x.md: nav must be one of tutorial, guides, not "home"))
  def test_duplicate_output_path = (write("x.md", "---\npath: tutorial.html\n---\n# X\n\nI.\n\n## A\n"); assert_includes build, "docs/guide/x.md: output tutorial.html is also written by another source")
  def test_translation_without_english = (write("ja/x.md", "# X\n\nI.\n\n## A\n"); assert_equal ["docs/guide/ja/x.md: no English source docs/guide/x.md"], build)
  def test_malformed_meta = (write("x.md", "---\nmeta:\n  - term: T\n---\n# X\n\nI.\n\n## A\n"); assert_equal ["docs/guide/x.md: meta must be a list of {term, text}"], build)
end
