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

  # The h1's id (the slug of the English title) is an anchor too.
  def test_title_anchor
    assert_equal "a.html#alpha", rewrite("a.md#alpha", src("a", "ja"))
    assert_equal [], @links.errors
  end
end
