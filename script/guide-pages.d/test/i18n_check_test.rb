# Tests for GuidePages::I18nCheck (script/check-guide-i18n). Each test copies
# the passing pair in fixtures/i18n/pass into a temporary root, breaks one
# thing, and expects the matching difference.
# usage: ruby -Iscript/guide-pages.d/lib script/guide-pages.d/test/i18n_check_test.rb

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "i18n_check"

class I18nCheckTest < Minitest::Test
  PASS = File.expand_path("fixtures/i18n/pass", __dir__)
  EN = "docs/guide/a.md"
  JA = "docs/guide/ja/a.md"

  def setup
    @root = Dir.mktmpdir
    FileUtils.cp_r(File.join(PASS, "."), @root)
  end

  def teardown = FileUtils.remove_entry(@root)

  def path(file) = File.join(@root, file)
  def read(file) = File.read(path(file), encoding: "UTF-8")

  # Replaces the one occurrence of from with to in file.
  def edit(file, from, to)
    text = read(file)
    assert_includes text, from
    File.write(path(file), text.sub(from) { to })
  end

  def run_check(langs: %w[ja]) = GuidePages::I18nCheck.run(@root, langs: langs)

  # Changes the translation and keeps its hash right.
  def edit_ja(from, to)
    edit(JA, from, to)
  end

  def assert_problem(pattern, problems = run_check)
    assert problems.any? { |p| p.start_with?("#{JA}: ") && p.match?(pattern) }, "expected #{pattern.inspect} in #{problems.inspect}"
  end

  def test_passing_pair
    assert_equal [], run_check
  end

  def test_missing_translation
    FileUtils.rm(path(JA))
    assert_equal ["docs/guide/ja/a.md: missing translation of docs/guide/a.md"], run_check
  end

  def test_orphan_translation
    FileUtils.cp(path(JA), path("docs/guide/ja/z.md"))
    assert_equal ["docs/guide/ja/z.md: no English source docs/guide/z.md"], run_check
  end

  def test_other_languages_are_checked_too
    assert_equal ["docs/guide/fr/a.md: missing translation of docs/guide/a.md"], run_check(langs: %w[fr])
  end

  def test_stale_sha
    edit(EN, "The alpha page.", "The alpha page, changed.")
    problems = run_check
    assert_problem(/English changed/, problems)
    assert_problem(/git log -p docs\/guide\/a\.md/, problems)
  end

  def test_missing_sha
    edit_ja(/source_sha256: \h+\n/.match(read(JA))[0], "")
    assert_problem(/source_sha256 is missing/)
  end

  def test_front_keys_differ
    edit_ja("crumb: アルファ\n", "")
    assert_problem(/front matter keys differ \(missing crumb\)/)
    edit_ja("nav: a\n", "nav: a\ntoc_title: x\n")
    assert_problem(/extra toc_title/)
  end

  # meta rows are translated, but there are as many as in the English.
  def test_meta_row_count_must_equal
    edit(EN, "nav: a\n", "nav: a\nmeta:\n  - term: A\n    text: a\n  - term: B\n    text: b\n")
    edit(JA, "nav: a\n", "nav: a\nmeta:\n  - term: エー\n    text: あ\n  - term: ビー\n    text: い\n")
    GuidePages::I18nCheck.update_sha(JA, root: @root)
    assert_equal [], run_check
    edit(JA, "  - term: ビー\n    text: い\n", "")
    assert_problem(/front matter meta has 1 rows, the English has 2/)
  end

  def test_front_values_may_be_translated_but_not_path
    edit_ja("path: guide/a.html", "path: guide/ja.html")
    assert_problem(/front matter path must equal/)
  end

  def test_og_image_and_nav_must_equal
    edit_ja("nav: a", "nav: b")
    edit_ja("og_image: assets/og.png", "og_image: assets/ja.png")
    assert_problem(/front matter nav must equal/)
    assert_problem(/front matter og_image must equal/)
  end

  def test_heading_levels_differ
    edit_ja("## 比較", "### 比較")
    assert_problem(/headings differ/)
  end

  def test_heading_count_differs
    edit_ja("## 比較", "")
    assert_problem(/headings differ/)
  end

  def test_step_id_differs
    edit_ja("#validations", "#validation")
    assert_problem(/step comments differ/)
  end

  def test_step_stage_is_translated
    assert_equal [], run_check # the stage differs in the fixture
  end

  def test_markers_differ
    edit_ja("[!WHY]", "[!NOTE]")
    assert_problem(/convention markers differ/)
  end

  def test_code_differs_beyond_comments
    assert_equal [], run_check # the fixture's comments are translated
    edit_ja("presence: true # 必須", "presence: false # 必須")
    assert_problem(/code block 1 \(ruby\) differs at line 1/)
  end

  def test_raw_html_figure_commands_compared
    fig = ->(caption, cmd, comment) {
      %(<figure class="code" data-lang="shell" markdown="0">\n<figcaption>#{caption}</figcaption>\n) +
        %(<pre aria-label="#{caption}"><code><span class="ln cmd">#{cmd}   <span class="c"># #{comment}</span></span></code></pre>\n</figure>\n\n)
    }
    edit(EN, "## Compare\n", "## Compare\n\n#{fig.("terminal", "cybertrain new blog", "first time")}")
    edit(JA, "## 比較\n", "## 比較\n\n#{fig.("ターミナル", "cybertrain new blog", "初回")}")
    GuidePages::I18nCheck.update_sha(JA, root: @root)
    assert_equal [], run_check # caption and comment are translated
    edit(JA, "cybertrain new blog", "cybertrain new blogs")
    assert_problem(/section "Compare", code block 1 \(shell\) differs at line 1/)
  end

  def test_code_count_differs
    edit_ja("```console\n$ cybertrain run\n```\n", "")
    assert_problem(/English has 1 code blocks, translation has 0/)
  end

  def test_code_place_differs
    edit_ja("```ruby app/models/user.rb", "```ruby app/models/account.rb")
    assert_problem(/place "app\/models\/user.rb" in English/)
  end

  def test_free_text_place_may_be_translated
    edit(EN, "```console\n", "```console terminal — any directory\n")
    edit(JA, "```console\n", "```console ターミナル — 任意のディレクトリ\n")
    GuidePages::I18nCheck.update_sha(JA, root: @root)
    assert_equal [], run_check
    edit(JA, "```console ターミナル — 任意のディレクトリ\n", "```console\n")
    assert_problem(/place "terminal .* any directory" in English, nil in translation/)
  end

  def test_code_language_differs
    edit_ja("```console", "```sh")
    assert_problem(/language "console" in English, "sh" in translation/)
  end

  def test_table_rows_differ
    edit_ja("| c | d |\n", "")
    assert_problem(/English has 3 table rows, translation has 2/)
  end

  def test_link_target_differs
    edit_ja("(b.html#top)", "(b.html#bottom)")
    assert_problem(/link targets differ/)
  end

  def test_link_text_may_differ
    edit_ja("[ローカル]", "[別の文章]")
    assert_equal [], run_check
  end

  def test_unparseable_translation_is_reported_with_its_file
    edit_ja("# アルファ\n", "")
    assert_problem(/title/)
  end

  def test_update_sha_writes_hash
    edit(EN, "The alpha page.", "The alpha page, changed.")
    refute_empty run_check
    sha = GuidePages::I18nCheck.update_sha(path(JA), root: @root)
    assert_match(/\A\h{64}\z/, sha)
    assert_equal sha, Digest::SHA256.file(path(EN)).hexdigest
    assert_equal [], run_check
    assert_equal 1, read(JA).scan("source_sha256:").size
  end

  def test_update_sha_adds_the_key_first
    edit_ja(/source_sha256: \h+\n/.match(read(JA))[0], "")
    sha = GuidePages::I18nCheck.update_sha(JA, root: @root)
    assert_match(/\A---\nsource_sha256: #{sha}\npath: /, read(JA))
    assert_equal [], run_check
  end
end
