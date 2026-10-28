# Tests for GuidePages::Links (link rewriting on the generated pages), over
# the sources and repository files in fixtures/links.
# usage: ruby -Iscript/guide-pages.d/lib script/guide-pages.d/test/links_test.rb

require "minitest/autorun"
require "links"

class LinksTest < Minitest::Test
  ROOT = File.expand_path("fixtures/links", __dir__)
  BLOB = "https://github.com/saeki-mototsune/CyberTrain/blob/main/"
  TREE = "https://github.com/saeki-mototsune/CyberTrain/tree/main/"

  def setup
    @sources = GuidePages::Source.all(ROOT)
    @links = GuidePages::Links.new(sources: @sources, root: ROOT)
  end

  def src(name, lang = "en") = @sources.fetch(lang).fetch(name)
  def rewrite(href, from = src("a")) = @links.rewrite(href, from: from)

  def test_output_paths
    assert_equal "guide/a.html", GuidePages::Links.out_path(src("a"))
    assert_equal "tutorial.html", GuidePages::Links.out_path(src("tutorial"))
    assert_equal "ja/guide/a.html", GuidePages::Links.out_path(src("a", "ja"))
    assert_equal "", GuidePages::Links.lang_root("en")
    assert_equal "ja/", GuidePages::Links.lang_root("ja")
  end

  def test_guide_link
    assert_equal "../tutorial.html#validations", rewrite("tutorial.md#validations")
    assert_equal "guide/a.html#requirements", rewrite("a.md#requirements", src("tutorial"))
    assert_equal "a.html", rewrite("a.md")
    assert_equal [], @links.errors
  end

  def test_guide_anchor_checked
    assert_equal "a.html#sub-part", rewrite("a.md#sub-part")
    assert_equal [], @links.errors
    rewrite("tutorial.md#nope")
    assert_equal ["docs/guide/a.md: link tutorial.md#nope: no anchor #nope on docs/guide/tutorial.md"], @links.errors
  end

  def test_own_anchor_checked
    assert_equal "#requirements", rewrite("#requirements")
    assert_equal "#requirements", rewrite("#requirements", src("a", "ja")) # the English ids
    rewrite("#nope")
    assert_equal ["docs/guide/a.md: link #nope: no anchor #nope on docs/guide/a.md"], @links.errors
  end

  def test_missing_guide_source_error
    rewrite("missing.md")
    assert_equal ["docs/guide/a.md: link missing.md: no source docs/guide/missing.md"], @links.errors
  end

  def test_repo_file_to_github
    assert_equal "#{BLOB}docs/design.md#x", rewrite("../design.md#x")
    # A translation's links resolve from the English file's directory.
    assert_equal "#{BLOB}docs/design.md", rewrite("../design.md", src("a", "ja"))
    assert_equal [], @links.errors
  end

  def test_repo_dir_to_tree
    assert_equal "#{TREE}examples/blog", rewrite("../../examples/blog")
    assert_equal "#{TREE}examples/blog", rewrite("../../examples/blog/")
    assert_equal "#{BLOB}examples/blog/README.md", rewrite("../../examples/blog/README.md")
  end

  def test_missing_repo_path_error
    rewrite("../nope.md")
    rewrite("../../../outside")
    assert_equal ["docs/guide/a.md: link ../nope.md: docs/nope.md is not in the repository",
                  "docs/guide/a.md: link ../../../outside: ../outside is not in the repository"], @links.errors
  end

  def test_site_prefix
    assert_equal "../index.html", rewrite("site:index.html")
    assert_equal "playground.html#x", rewrite("site:playground.html#x", src("tutorial"))
    # api/ and assets/ exist once, at the site root.
    assert_equal "../../api/index.html", rewrite("site:api/index.html", src("a", "ja"))
    assert_equal "api/index.html", rewrite("site:api/index.html", src("tutorial"))
    assert_equal "../../assets/style.css", rewrite("site:assets/style.css", src("a", "ja"))
    assert_equal [], @links.errors
  end

  # A site: target must exist in site/, from the page's language root (api/
  # and assets/ from the site root); api/ is built by YARD, so not checked.
  def test_site_target_checked
    rewrite("site:nope.html")
    rewrite("site:playground.html", src("a", "ja")) # site/ja/playground.html is missing
    rewrite("site:assets/nope.css")
    rewrite("site:api/anything.html")
    assert_equal ["docs/guide/a.md: link site:nope.html: site/nope.html does not exist",
                  "docs/guide/ja/a.md: link site:playground.html: site/ja/playground.html does not exist",
                  "docs/guide/a.md: link site:assets/nope.css: site/assets/nope.css does not exist"], @links.errors
  end

  # A generated page is checked against the build's own output (not site/),
  # and its anchor against its heading ids.
  def test_site_target_generated_page
    assert_equal "../tutorial.html#validations", rewrite("site:tutorial.html#validations")
    assert_equal "a.html", rewrite("site:guide/a.html")
    assert_equal [], @links.errors
    rewrite("site:guide/nope.html")
    rewrite("site:tutorial.html#nope")
    assert_equal ["docs/guide/a.md: link site:guide/nope.html: guide/nope.html is not a generated page",
                  "docs/guide/a.md: link site:tutorial.html#nope: no anchor #nope on docs/guide/tutorial.md"], @links.errors
  end

  def test_absolute_unchanged
    %w[https://example.com/x http://example.com mailto:a@example.com //cdn.example.com/x].each do |href|
      assert_equal href, rewrite(href)
    end
    assert_equal [], @links.errors
  end

  def test_relative_links_across_depths
    ja = src("a", "ja")
    assert_equal "../tutorial.html", rewrite("tutorial.md", ja) # ja/tutorial.html
    assert_equal "../index.html", rewrite("site:index.html", ja) # ja/index.html
    assert_equal "../tutorial.html", rewrite("tutorial.md")
    assert_equal "a.html#requirements", rewrite("../guide/a.md#requirements")
  end

  def test_ids_for
    assert_equal %w[alpha requirements sub-part], @links.ids_for("a")
    assert_equal %w[tutorial validations], @links.ids_for("tutorial")
  end

  def test_duplicate_ids_rejected
    dup = GuidePages::Source.new("docs/guide/d.md", "# D\n\nI.\n\n## Setup\n\n### Notes\n\n## More\n\n### Notes\n")
    links = GuidePages::Links.new(sources: { "en" => { "d" => dup } }, root: ROOT)
    e = assert_raises(GuidePages::Error) { links.ids_for("d") }
    assert_equal "docs/guide/d.md: heading id #notes is used twice", e.message
  end

  # The h1's id (the slug of the English title) is an anchor too.
  def test_title_anchor
    assert_equal "a.html#alpha", rewrite("a.md#alpha", src("a", "ja"))
    assert_equal [], @links.errors
  end
end
