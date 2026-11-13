require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator"

# gen/tests.rb (spec sections 5.2 and 8, plan decisions 5, 10, 14 and 19):
# the one program `cybertrain test` compiles, as gen writes it. The
# emitted text, its requires and the bundle's refusals (pre-flight ruling
# B2: a refused bundle is a gen/tests.rb that only aborts, and gen itself
# still succeeds). Text only: CRuby-portable.
require_relative "fixtures/gen_app/config/routes"

FIXTURE = "test/fixtures/gen_app"
TEMP_ROOTS = Array.new(0) { "" }

def copy_tree(from, to)
  Dir.mkdir(to) unless File.directory?(to)
  Dir.children(from).sort.each do |entry|
    if File.directory?("#{from}/#{entry}")
      copy_tree("#{from}/#{entry}", "#{to}/#{entry}")
    else
      File.write("#{to}/#{entry}", File.read("#{from}/#{entry}"))
    end
  end
  nil
end

def remove_tree(dir)
  Dir.children(dir).each do |entry|
    path = "#{dir}/#{entry}"
    if File.directory?(path)
      remove_tree(path)
    else
      File.delete(path)
    end
  end
  Dir.rmdir(dir)
  nil
end

def make_dirs(dir)
  return nil if File.directory?(dir)

  make_dirs(File.dirname(dir))
  Dir.mkdir(dir)
  nil
end

# A copy of the fixture app with `files` (path => text) written into it.
def temp_app(files)
  root = Dir.mktmpdir("cybertrain-gen-tests")
  TEMP_ROOTS << root
  copy_tree(FIXTURE, root)
  # Without the fixture app's own test/ (Task 8's fixtures) and what gen
  # writes from it, the tree holds only the test files written here.
  remove_tree("#{root}/test")
  remove_tree("#{root}/gen/test")
  File.delete("#{root}/gen/tests.rb")
  files.each do |rel, text|
    make_dirs(File.dirname("#{root}/#{rel}"))
    File.write("#{root}/#{rel}", text)
  end
  root
end

at_exit { TEMP_ROOTS.each { |root| remove_tree(root) if File.directory?(root) } }

def emitted(root, data = false)
  Cybertrain::Gen::TestsEmitter.emit(root, Cybertrain::Gen::TestScan.scan(root), data)
end

def bundle_refusal(root)
  Cybertrain::Gen::TestsEmitter.refusal(root, Cybertrain::Gen::TestScan.scan(root))
end

HELPER = "require \"cybertrain/test_help\"\n\nclass ActiveSupport::TestCase\n  fixtures :all\nend\n"
ARTICLE_TEST = <<~RUBY
  require "test_helper"

  class ArticleTest < ActiveSupport::TestCase
    test "title must be present" do
      assert true
    end

    test "counts" do
      assert_equal 1, 0
    end
  end
RUBY
LEGACY = "# The old form.\n\ntest \"old style\" do\n  assert true\nend\n\nCybertrain::Test.run!\n"

def app_with_tests(extra = {})
  files = { "test/test_helper.rb" => HELPER,
            "test/support/helpers.rb" => "def sign_in = nil\n",
            "test/models/article_test.rb" => ARTICLE_TEST,
            "test/legacy.rb" => LEGACY }
  extra.each { |k, v| files[k] = v }
  temp_app(files)
end

test "the emitted program requires in order and has one arm per class-form test" do
  src = emitted(app_with_tests)
  arm = "      when 0\n        t = ArticleTest.new\n        if Cybertrain::Test.before_case(t)\n" \
        "          Cybertrain::Test.run_body(t) { t.test_title_must_be_present }\n        end\n" \
        "        Cybertrain::Test.after_case(t)\n"
  assert_includes src, arm
  assert_includes src, "      when 1\n        t = ArticleTest.new\n"
  assert_includes src, "{ t.test_counts }"
  refute src.include?("when 2")
  refute src.include?("require \"test_helper\"")
  assert_includes src, "Cybertrain::Test.begin_file(\"test/legacy.rb\", [\"old style\"], [3])\n"
  assert_includes src, "Cybertrain::Test.begin_file(\"test/models/article_test.rb\", Array.new(0) { \"\" }, Array.new(0) { 0 })\n"
  order = ["ENV[\"CYBERTRAIN_ENV\"] = \"test\"\n", "require \"cybertrain\"\n", "require \"cybertrain/test_help\"\n",
           "require \"cybertrain/test/bundle\"\n", "require_relative \"../config/app\"\n",
           "Cybertrain::Test::Bundle.check_database!\n", "require_relative \"app\"\n",
           "require_relative \"migrations\"\n", "Cybertrain::Test.bundled!\n",
           "class ActionDispatch::IntegrationTest\n  include ::Gen::UrlHelpers\nend\n", "require_relative \"../test/test_helper\"\n",
           "require_relative \"../test/support/helpers\"\n", "Cybertrain::Test.begin_file(\"test/legacy.rb\"",
           "require_relative \"../test/legacy\"\n", "Cybertrain::Test.begin_file(\"test/models/article_test.rb\"",
           "require_relative \"test/models/article_test\"\n", "module Gen\n  module Tests\n",
           "Cybertrain::Test::Bundle.use_table(", "Cybertrain::Test::Bundle.check_args!(ARGV)\n",
           "Cybertrain::Test::Bundle.boot!(Gen::Routes.build(Cybertrain::Router.new), Gen::Routes.url_resolver)\n",
           "exit(Cybertrain::Test::Bundle.run!(ARGV, Gen::Tests.dispatcher))\n"]
  at = -1
  order.each do |line|
    found = src.index(line)
    assert !found.nil?, "missing: #{line}"
    assert found > at, "out of order: #{line}"
    at = found
  end
  assert_includes src, "    FILES = [\"test/legacy.rb\", \"test/models/article_test.rb\"].freeze\n"
  assert_includes src, "    CASE_FILE = [\"test/models/article_test.rb\", \"test/models/article_test.rb\"].freeze\n"
  assert_includes src, "    CASE_LINE = [4, 8].freeze\n"
  assert_includes src, "    CASE_CLASS = [\"ArticleTest\", \"ArticleTest\"].freeze\n"
  assert_includes src, "    CASE_NAME = [\"title must be present\", \"counts\"].freeze\n"
  assert_includes src, "    CASE_METHOD = [\"test_title_must_be_present\", \"test_counts\"].freeze\n"
  # The dispatch lambda is made in a method (rule 82), and no fixtures
  # hook is registered until gen/test/data.rb exists.
  assert_includes src, "    def self.dispatcher = ->(i) { run_case(i) }\n"
  refute src.include?("fixtures_hook")
  refute src.include?("test/data")
end

test "with the fixtures' file, the bundle requires it and registers the clear and load" do
  src = emitted(app_with_tests, true)
  assert_includes src, "require_relative \"migrations\"\nrequire_relative \"test/data\"\nCybertrain::Test.bundled!\n"
  assert_includes src, "        Cybertrain::Test::Database.clear_and_load!(Gen::TestData::TABLES, Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS)\n"
  assert_includes src, "Gen::Routes.url_resolver)\nCybertrain::Test.before_each_bundled(Gen::Tests.fixtures_hook)\nexit("
end

test "an application with no class-form test has an empty table" do
  src = emitted(temp_app("test/legacy.rb" => LEGACY))
  assert_includes src, "    CASE_FILE = Array.new(0) { \"\" }.freeze\n"
  assert_includes src, "    CASE_LINE = Array.new(0) { 0 }.freeze\n"
  assert_includes src, "    def self.run_case(i)\n      nil\n    end\n"
  refute src.include?("case i")
end

test "test names are written as literals that never interpolate" do
  src = emitted(temp_app("test/odd.rb" => <<~'RUBY'))
    test 'say "hi" #{x}' do
    end

    test "plain" do
    end
  RUBY
  assert_includes src, "Cybertrain::Test.begin_file(\"test/odd.rb\", [\"say \\\"hi\\\" \\\#{x}\", \"plain\"], [1, 4])\n"
end

test "the bundle forces the test environment" do
  src = emitted(app_with_tests)
  assert src.lines.include?("ENV[\"CYBERTRAIN_ENV\"] = \"test\"\n")
  refute src.include?("||=")
  assert_includes src, "ENV.delete(\"CYBERTRAIN_DATABASE\")\n"
  assert_includes src, "ENV[\"CYBERTRAIN_DATABASE\"] = ENV[\"CYBERTRAIN_TEST_DATABASE\"].to_s unless ENV[\"CYBERTRAIN_TEST_DATABASE\"].to_s.empty?\n"
  assert src.index("ENV.delete") < src.index("require \"cybertrain\"")
end

test "the bundle hands the shell's CYBERTRAIN_ENV and CYBERTRAIN_DATABASE to the database guard" do
  src = emitted(app_with_tests)
  captured = "cybertrain_shell_env = ENV[\"CYBERTRAIN_ENV\"].to_s\ncybertrain_shell_database = ENV[\"CYBERTRAIN_DATABASE\"].to_s\n"
  assert_includes src, captured
  assert src.index(captured) < src.index("ENV[\"CYBERTRAIN_ENV\"] = \"test\"")
  handed = "Cybertrain::Test::Database.use_shell_database(cybertrain_shell_env, cybertrain_shell_database)\n"
  assert_includes src, handed
  assert src.index("require \"cybertrain/test/bundle\"") < src.index(handed)
  assert src.index(handed) < src.index("Cybertrain::Test::Bundle.check_database!")
end

test "a duplicate top-level helper is refused naming both files" do
  a = "# a\n\n\n\ndef new_client\n  nil\nend\n"
  b = "# b\n\ndef new_client\n  nil\nend\n"
  root = temp_app("test/a_test.rb" => a, "test/b_test.rb" => b)
  assert_equal "test/b_test.rb:3: new_client is also defined at test/a_test.rb:5; move shared helpers to test/support/ or into a test class",
               bundle_refusal(root)
  root = temp_app("test/a_test.rb" => "CLOCK = [1]\n", "test/b_test.rb" => "\nCLOCK = [1]\n")
  assert_equal "test/b_test.rb:2: CLOCK is also defined at test/a_test.rb:1; move shared helpers to test/support/ or into a test class",
               bundle_refusal(root)
  # Support files are bundled too; one file defining a name twice is not a
  # duplicate between files.
  root = temp_app("test/support/clients.rb" => "def new_client = nil\n", "test/a_test.rb" => "def other = 1\ndef other = 2\n",
                  "test/b_test.rb" => "\n\ndef new_client = nil\n")
  assert_equal "test/b_test.rb:3: new_client is also defined at test/support/clients.rb:1; move shared helpers to test/support/ or into a test class",
               bundle_refusal(root)
  root = temp_app("test/a_test.rb" => "def other = 1\ndef other = 2\n", "test/b_test.rb" => "def new_client = nil\n")
  assert_equal "", bundle_refusal(root)
end

test "a refused bundle is a program that only aborts, and gen still succeeds" do
  root = temp_app("test/a_test.rb" => "def new_client = nil\n", "test/b_test.rb" => "def new_client = nil\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  text = File.read("#{root}/gen/tests.rb")
  assert_equal Cybertrain::Gen::TestsEmitter::HEADER +
               "abort(\"test/b_test.rb:1: new_client is also defined at test/a_test.rb:1; move shared helpers to test/support/ or into a test class\")\n",
               text
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
end

test "a test file the class-form rewrite refuses refuses the bundle, and gen still succeeds" do
  root = app_with_tests
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  copy = File.read("#{root}/gen/test/models/article_test.rb")
  File.delete("#{root}/gen/routes.rb")
  broken = "require \"test_helper\"\n\nclass ArticleTest < ActiveSupport::TestCase\n  test \"a\" do\n    assert true\n  end\n\n  test \"a\" do\n  end\nend\n"
  File.write("#{root}/test/models/article_test.rb", broken)
  write_file = "#{root}/test/models/other_test.rb"
  File.write(write_file, "class OtherTest < ActiveSupport::TestCase\n  test \"b\" do\n  end\nend\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  reason = "test/models/article_test.rb:8: test \"a\" has the same method name test_a as test \"a\" (line 4)"
  assert_equal "#{Cybertrain::Gen::TestsEmitter::HEADER}abort(\"#{reason.gsub("\"", "\\\"")}\")\n", File.read("#{root}/gen/tests.rb")
  # The application's other outputs are written as usual; gen/test's copies
  # are left as they were (none written, none swept).
  assert File.exist?("#{root}/gen/routes.rb")
  assert_equal copy, File.read("#{root}/gen/test/models/article_test.rb")
  refute File.exist?("#{root}/gen/test/models/other_test.rb")
  # Fresh while gen would write the same refused program.
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
  # Fixed: the bundle and the copies are written again.
  File.write("#{root}/test/models/article_test.rb", ARTICLE_TEST)
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert File.read("#{root}/gen/tests.rb").include?("{ t.test_counts }")
  assert File.exist?("#{root}/gen/test/models/other_test.rb")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
end

test "assert_select with a block and render_inline with a block are refused" do
  select = "test \"list\" do\n  get \"/\"\n  assert_select \"li\", count: 2\n  assert_select \"ul\" do\n    assert_select \"li\"\n  end\nend\n"
  root = temp_app("test/x_test.rb" => select)
  assert_equal "test/x_test.rb:4: assert_select: the nested block form is not supported (selector: \"ul\")", bundle_refusal(root)
  root = temp_app("test/x_test.rb" => "test \"list\" do\n  assert_select(\"ul > li\", text: \"a\") { |li| li }\nend\n")
  assert_equal "test/x_test.rb:2: assert_select: the nested block form is not supported (selector: \"ul > li\")", bundle_refusal(root)
  inline = "class CardTest < ActiveSupport::TestCase\n  test \"card\" do\n    render_inline(Card.new(title: \"t\")) do\n      \"x\"\n    end\n  end\nend\n"
  root = temp_app("test/components/card_test.rb" => inline)
  assert_equal "test/components/card_test.rb:3: render_inline: pass the content as content:, not a block", bundle_refusal(root)
  root = temp_app("test/support/views.rb" => "def card = render_inline(Card.new) { \"x\" }\n")
  assert_equal "test/support/views.rb:1: render_inline: pass the content as content:, not a block", bundle_refusal(root)
  # Not refused: no block, a string or comment that mentions one, or a
  # block passed to something else on the line.
  ok = "test \"fine\" do\n  assert_select \"li\", count: 2\n  render_inline(Card.new(title: \"t\"))\n  " \
       "x = \"assert_select \\\"ul\\\" do\"\n  # assert_select \"ul\" do\n  [1].each { |n| assert_select(\"li\", count: n) }\nend\n"
  root = temp_app("test/x_test.rb" => ok)
  assert_equal "", bundle_refusal(root)
  root = temp_app("test/x_test.rb" => select)
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert_includes File.read("#{root}/gen/tests.rb"), "abort(\"test/x_test.rb:4: assert_select: the nested block form is not supported (selector: \\\"ul\\\")\")\n"
end

test "an assert_select or render_inline call over several lines is read to its end" do
  # The block follows arguments that go on over lines: refused.
  root = temp_app("test/x_test.rb" => "test \"list\" do\n  assert_select \"ul\",\n    count: 2 do\n    assert_select \"li\"\n  end\nend\n")
  assert_equal "test/x_test.rb:2: assert_select: the nested block form is not supported (selector: \"ul\")", bundle_refusal(root)
  root = temp_app("test/x_test.rb" => "test \"list\" do\n  assert_select(\"ul\",\n    count: 2) do\n    assert_select \"li\"\n  end\nend\n")
  assert_equal "test/x_test.rb:2: assert_select: the nested block form is not supported (selector: \"ul\")", bundle_refusal(root)
  root = temp_app("test/x_test.rb" => "test \"list\" do\n  assert_select(\n    \"ul\", count: 2\n  ) { |ul| ul }\nend\n")
  assert_equal "test/x_test.rb:2: assert_select: the nested block form is not supported (selector: \"ul\")", bundle_refusal(root)
  root = temp_app("test/x_test.rb" => "test \"card\" do\n  render_inline(Card.new(title: \"t\",\n                         body: \"b\")) do\n    \"x\"\n  end\nend\n")
  assert_equal "test/x_test.rb:2: render_inline: pass the content as content:, not a block", bundle_refusal(root)
  # The same calls without a block: not refused.
  plain = "test \"list\" do\n  assert_select \"ul\",\n    count: 2\n  assert_select(\"li\",\n    text: \"a\")\n  " \
          "render_inline(Card.new(title: \"t\",\n                         body: \"b\"))\n  [1].each do |n|\n    assert_select \"li\", count: n\n  end\nend\n"
  root = temp_app("test/x_test.rb" => plain)
  assert_equal "", bundle_refusal(root)
  # Arguments that never close: gen cannot tell, so it refuses.
  root = temp_app("test/x_test.rb" => "def helper\n  assert_select(\"ul\",\n")
  assert_equal "test/x_test.rb:2: assert_select: gen cannot tell where this call's arguments end; close them before the end of the file",
               bundle_refusal(root)
end

test "a top-level test, setup or teardown in the helper or a support file is refused" do
  root = temp_app("test/test_helper.rb" => "require \"cybertrain/test_help\"\n\nsetup do\n  nil\nend\n", "test/legacy.rb" => LEGACY)
  assert_equal "test/test_helper.rb:3: a top-level test, setup or teardown in the helper or test/support/ never runs in the bundle; " \
               "put it in a test file or in a test class", bundle_refusal(root)
  root = temp_app("test/support/more.rb" => "# more\ntest \"lost\" do\nend\n")
  assert_equal "test/support/more.rb:2: a top-level test, setup or teardown in the helper or test/support/ never runs in the bundle; " \
               "put it in a test file or in a test class", bundle_refusal(root)
  # In a class of a support file, or as a helper method: fine.
  root = temp_app("test/support/base.rb" => "class BaseTest < ActiveSupport::TestCase\n  setup do\n    @a = 1\n  end\nend\n\ndef setup_data = nil\n")
  assert_equal "", bundle_refusal(root)
end

test "a non-test configuration is refused before any test or support file is loaded" do
  src = emitted(app_with_tests)
  lines = src.lines
  guard = lines.index("Cybertrain::Test::Bundle.check_database!\n")
  assert_equal "require_relative \"../config/app\"\n", lines[guard - 1]
  lines.each_with_index do |line, k|
    next unless line.start_with?("require_relative") && !line.include?("../config/app")

    assert k > guard, "loaded before the guard: #{line}"
  end
end

test "the generated helper with an application base class loads" do
  helper = "require_relative \"../config/app\"\nrequire \"cybertrain/test_help\"\n\n" \
           "class ApplicationIntegrationTest < ActionDispatch::IntegrationTest; end\n"
  root = app_with_tests("config/app.rb" => "Cybertrain.configure { |c| c.log_level = :none }\n",
                        "test/test_helper.rb" => helper,
                        "test/controllers/pages_test.rb" => "class PagesTest < ApplicationIntegrationTest\n  test \"a\" do\n  end\nend\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  src = File.read("#{root}/gen/tests.rb")
  assert_includes src, "require_relative \"test/test_helper\"\n"
  assert_includes src, "require_relative \"test/controllers/pages_test\"\n"
  checked = 0
  sources = { "gen/tests.rb" => src }
  Dir.glob("#{root}/gen/test/**/*.rb").each { |f| sources[f.delete_prefix("#{root}/")] = File.read(f) }
  sources.each do |rel, text|
    text.each_line do |line|
      next unless line.lstrip.start_with?("require_relative")

      target = line[/require_relative\(?\s*"([^"]+)"/, 1]
      target += ".rb" unless target.end_with?(".rb")
      assert File.exist?(File.join(root, File.dirname(rel), target)), "#{rel}: #{line.strip} does not resolve"
      checked += 1
    end
  end
  assert checked >= 8, "only #{checked} requires checked"
end

test "gen/tests.rb goes when test/ goes" do
  root = temp_app("test/legacy.rb" => LEGACY)
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert File.exist?("#{root}/gen/tests.rb")
  File.delete("#{root}/test/legacy.rb")
  Dir.rmdir("#{root}/test")
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen/tests.rb")
  root = temp_app({})
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen/tests.rb")
end

test "an app's own top-level render_inline is refused: it would replace the framework's" do
  # The helper test the helper generator wrote before render_helper_template.
  old_helper = "require \"cybertrain/test\"\n\n# app/helpers/prices_helper.rb\ndef render_inline(source)\n  source\nend\n"
  root = temp_app("test/prices_helper.rb" => old_helper)
  assert_equal "test/prices_helper.rb:4: render_inline is the framework's (component and partial tests); " \
               "rename this one render_helper_template, or regenerate the helper test", bundle_refusal(root)
  root = temp_app("test/support/views.rb" => "def render_inline(c) = c\n")
  assert_equal "test/support/views.rb:1: render_inline is the framework's (component and partial tests); " \
               "rename this one render_helper_template, or regenerate the helper test", bundle_refusal(root)
  # The renamed helper, a call, and a method inside a class are fine.
  fine = "def render_helper_template(source) = source\n\nclass X\n  def render_inline(c) = c\nend\n\ntest \"t\" do\n  render_inline(Card.new)\nend\n"
  root = temp_app("test/prices_helper.rb" => fine)
  assert_equal "", bundle_refusal(root)
end

Cybertrain::Test.run!
