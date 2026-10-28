# Tests for GuidePages::Outline and GuidePages::Source (the stdlib-only parser).
# usage: ruby -Iscript/guide-pages.d/lib script/guide-pages.d/test/outline_test.rb

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "outline"
require "source"

class OutlineTest < Minitest::Test
  ROOT = File.expand_path("fixtures/basic", __dir__)

  def source(name = "a") = GuidePages::Source.load("docs/guide/#{name}.md", root: ROOT)
  def outline = GuidePages::Outline.parse(source.body)
  def section(text) = outline.sections.find { |s| s.text == text }

  def test_parses_title_and_sections
    o = outline
    assert_equal "Alpha", o.title
    assert_equal [[0, nil], [2, "Validations"], [3, "Sub section"], [2, "Compare"], [2, "Querying beyond `where`"]],
                 o.sections.map { |s| [s.level, s.text] }
  end

  def test_links_across_line_breaks
    body = "# T\n\nSee [one\ncontinued](a.md#x) and\n[two](b.md) <a\nhref=\"c.md\">c</a>.\n\n```\n[no\n](z)\n```\n\n[ref]: d.md\n"
    assert_equal %w[a.md#x b.md c.md d.md], GuidePages::Outline.parse(body).links
  end

  def test_ignores_headings_in_fences
    refute_includes outline.sections.map(&:text), "not a heading"
  end

  def test_step_comment
    step = section("Validations").step
    assert_equal ["05", "validations", "You write · `app/models/`"],
                 [step.num, step.id, step.stage]
    assert_nil section("Compare").step
  end

  def test_markers_in_order
    assert_equal ["WHY"], section("Validations").markers
    assert_equal ["NOTE", "list:checklist"], section("Sub section").markers
    assert_equal ["table:cmp", "details", "RULE"], section("Compare").markers
  end

  # The callout kinds, with the optional aria-label after the marker; the
  # marker is the kind alone, so a translated label does not change it.
  def test_alert_kinds_and_label
    o = GuidePages::Outline.parse(<<~MD)
      # T

      > [!RULE] Views are a closed grammar
      > ### Views

      > [!COMPILE]
      > ### Before

      > [!EXAMPLE] Deleting an article
      > ### Deleting
    MD
    assert_equal %w[RULE COMPILE EXAMPLE], o.sections[0].markers
  end

  def test_list_marker_with_two_classes
    o = GuidePages::Outline.parse("# T\n\n<!-- list: points know -->\n- a\n")
    assert_equal ["list:points know"], o.sections[0].markers
  end

  def test_codes_with_place
    codes = section("Validations").codes
    assert_equal [["ruby", "app/models/article.rb"], ["shell", nil]], codes.map { |c| [c.lang, c.place] }
    assert_includes codes[0].text, "class Article; end"
    assert_equal "bundle install\n", codes[1].text
  end

  def test_table_rows
    assert_equal 3, section("Compare").table_rows
    assert_equal 0, section("Validations").table_rows
  end

  def test_links_in_order
    assert_equal ["b.md#top", "https://example.com/x", "c.md"], outline.links
  end

  def test_slug_matches_readme_anchors
    slug = GuidePages::Outline.method(:slug)
    assert_equal "differences-from-rails", slug.("Differences from Rails")
    assert_equal "requirements", slug.("Requirements")
    assert_equal "try-it-in-the-browser", slug.("Try it in the browser")
    assert_equal "querying-beyond-where", slug.("Querying beyond `where`")
    assert_equal "operations-backups-vacuum-health-check", slug.("Operations: backups, VACUUM, health check")
    assert_equal "link-text-b", slug.("[Link text](x.md) <b>b</b>")
  end

  def test_slug_decodes_entities
    slug = GuidePages::Outline.method(:slug)
    assert_equal "getting-started-the-blog", slug.("Getting started: the&nbsp;blog")
    assert_equal "getting-started-the-blog", slug.("Getting started: the\u00A0blog")
    assert_equal "a--b", slug.("a &amp; b")
    assert_equal "where-next", slug.("Where&rarr; next")
  end

  def test_requires_single_title
    assert_raises(GuidePages::Error) { GuidePages::Outline.parse("## only\n") }
    assert_raises(GuidePages::Error) { GuidePages::Outline.parse("# a\n\n# b\n") }
  end

  def test_rejects_unclosed_fence
    e = assert_raises(GuidePages::Error) { GuidePages::Outline.parse("# a\n\n```ruby\nx\n```\n\n```sh\ny\n") }
    assert_equal "code fence opened at line 7 is not closed", e.message
  end

  def with_file(content)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "docs/guide"))
      File.binwrite(File.join(root, "docs/guide/x.md"), content)
      yield root
    end
  end

  def test_rejects_unclosed_front_matter
    with_file("---\ntitle: x\n\n# X\n") do |root|
      e = assert_raises(GuidePages::Error) { GuidePages::Source.load("docs/guide/x.md", root: root) }
      assert_match(/\Adocs\/guide\/x\.md: .*front matter/, e.message)
    end
  end

  def test_rejects_unknown_front_key
    with_file("---\ntitel: x\n---\n# X\n") do |root|
      e = assert_raises(GuidePages::Error) { GuidePages::Source.load("docs/guide/x.md", root: root) }
      assert_match(/titel/, e.message)
    end
  end

  def test_rejects_non_hash_front_matter
    with_file("---\n- a\n---\n# X\n") do |root|
      assert_raises(GuidePages::Error) { GuidePages::Source.load("docs/guide/x.md", root: root) }
    end
  end

  def test_strips_bom_and_crlf
    with_file("\xEF\xBB\xBF---\r\ntitle: T\r\n---\r\n# X\r\n\r\nbody\r\n") do |root|
      s = GuidePages::Source.load(File.join(root, "docs/guide/x.md"), root: root)
      assert_equal({ "title" => "T" }, s.front)
      assert_equal "# X\n\nbody\n", s.body
      assert_equal "docs/guide/x.md", s.file
      assert_equal ["x", "en"], [s.name, s.lang]
    end
  end

  def test_lang_and_name
    s = GuidePages::Source.load("docs/guide/ja/a.md", root: ROOT)
    assert_equal ["a", "ja", "docs/guide/ja/a.md"], [s.name, s.lang, s.file]
    assert_equal "abc", s.front["source_sha256"]
  end

  def test_all_skips_readme
    all = GuidePages::Source.all(ROOT)
    assert_equal %w[a b], all["en"].keys.sort
    assert_equal %w[a], all["ja"].keys
    refute all.key?("zh")
  end
end
