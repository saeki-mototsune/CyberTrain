require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator"

# The class-form rewrite (spec 5.2, plan decisions 18 and 20): a file of
# test/ holding a Rails-shaped test class is copied into gen/test/ with
# each `test "name" do` turned into a method, setup / teardown blocks into
# per-class methods called from one setup / teardown on the class line,
# every line kept where it was and each method ending in nil (pre-flight
# ruling R8). Text only: CRuby-portable.
require_relative "fixtures/gen_app/config/routes"

FIXTURE = "test/fixtures/gen_app"
PROBE_SOURCE = "test/fixtures/test_rewrite/probe_test.rb"
PROBE_COPY = "test/fixtures/test_rewrite/gen/probe_test.rb"
PROBE_LOG = Array.new(0) { "" }

# The base of the probe's rewritten classes (ActiveSupport::TestCase's
# stand-in: setup and teardown answer nil).
class ProbeBase
  def setup
    PROBE_LOG << "base setup"
    nil
  end

  def teardown
    PROBE_LOG << "base teardown"
    nil
  end
end

require_relative "fixtures/test_rewrite/gen/probe_test"
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
  root = Dir.mktmpdir("cybertrain-gen-test")
  TEMP_ROOTS << root
  copy_tree(FIXTURE, root)
  # The fixture app's gen/test/data.rb (Task 8's fixtures) is left to a
  # gen that loads the schema, which this program does not: without it
  # the copies are the only files of gen/test.
  remove_tree("#{root}/gen/test")
  files.each do |rel, text|
    make_dirs(File.dirname("#{root}/#{rel}"))
    File.write("#{root}/#{rel}", text)
  end
  root
end

at_exit { TEMP_ROOTS.each { |root| remove_tree(root) if File.directory?(root) } }

# A double-quoted literal of s, written out by hand: String#inspect escapes
# non-ASCII characters when the locale is not UTF-8.
def literal(s)
  out = +"\""
  s.each_char do |ch|
    out << "\\" if ch == "\"" || ch == "\\"
    out << ch
  end
  out << "\""
  out
end

def two_tests(a, b)
  "class XTest < ActiveSupport::TestCase\n  test #{literal(a)} do\n  end\n\n  test #{literal(b)} do\n  end\nend\n"
end

def refusal_at(src, path)
  Cybertrain::Gen::TestScan.rewrite(src, path)
  ""
rescue ArgumentError => e
  e.message
end

def refusal(src)
  refusal_at(src, "test/x_test.rb")
end

test "method names follow Rails' rule" do
  assert_equal "test_shows_an_article", Cybertrain::Gen::TestScan.method_name("shows an article")
  assert_equal "test_a_b_c_", Cybertrain::Gen::TestScan.method_name("a-b.c?")
end

test "a class-form file is rewritten into methods with setup, teardown and lines kept" do
  src = <<~RUBY
    require "test_helper"

    class ArticlesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @article = articles(:one)
      end

      teardown do
        Cybertrain.config.http_allow_private = false
      end

      test "shows an article" do
        get article_path(@article)
      end

      private

      def title_of(article) = article.title.upcase
    end
  RUBY
  out = Cybertrain::Gen::TestScan.rewrite(src, "test/controllers/articles_controller_test.rb")
  lines = out.lines
  assert_equal src.lines.size, lines.size
  assert_equal "  def test_shows_an_article; begin\n", lines[11]
  assert_equal "  end; nil; end\n", lines[13]
  assert_equal "class ArticlesControllerTest < ActionDispatch::IntegrationTest; def setup; super; setup_articles_controller_test_1; nil; end; " \
               "def teardown; teardown_articles_controller_test_1; super; nil; end\n", lines[2]
  assert_equal ["  def setup_articles_controller_test_1; begin\n", "    @article = articles(:one)\n", "  end; nil; end\n"], lines[3, 3]
  assert_equal ["  def teardown_articles_controller_test_1; begin\n", "    Cybertrain.config.http_allow_private = false\n", "  end; nil; end\n"], lines[7, 3]
  assert_equal "  def title_of(article) = article.title.upcase\n", lines[17]
  assert_equal "\n", lines[0]
  refute out.include?("require \"test_helper\"")
end

test "several setup blocks run in order, teardown blocks in reverse" do
  src = "class T < ActiveSupport::TestCase\n  setup do\n    a\n  end\n  setup do\n    b\n  end\n  teardown do\n    c\n  end\n  teardown do\n    d\n  end\n\n  test \"x\" do\n  end\nend\n"
  out = Cybertrain::Gen::TestScan.rewrite(src, "test/t_test.rb")
  assert_includes out.lines[0], "def setup; super; setup_t_1; setup_t_2; nil; end; def teardown; teardown_t_2; teardown_t_1; super; nil; end"
  assert_equal "  def test_x; begin\n", out.lines[14]
  assert_equal "  end; nil; end\n", out.lines[15]
  assert_equal src.lines.size, out.lines.size
end

test "a test on one line, a class's own def setup and a class without blocks" do
  src = "class OneTest < ActiveSupport::TestCase\n  test \"x\" do assert true end\n  test \"y\" do; a; b; end\n  def setup\n    super\n    @user = 1\n  end\n\n  def teardown = super\nend\n" \
        "class Plain < ActiveSupport::TestCase\n  test \"z\" do\n  end\nend\n"
  lines = Cybertrain::Gen::TestScan.rewrite(src, "test/one_test.rb").lines
  assert_equal "class OneTest < ActiveSupport::TestCase\n", lines[0]
  assert_equal "  def test_x; begin; assert true; end; nil; end\n", lines[1]
  assert_equal "  def test_y; begin; a; b; end; nil; end\n", lines[2]
  assert_equal ["  def setup; begin\n", "    super\n", "    @user = 1\n", "  end; nil; end\n"], lines[3, 4]
  assert_equal "  def teardown; begin; super; end; nil; end\n", lines[8]
  assert_equal "class Plain < ActiveSupport::TestCase\n", lines[10]
  assert_equal "  def test_z; begin\n", lines[11]
  assert_equal src.lines.size, lines.size
end

test "names that collide after the method-name rule, non-ASCII and quoted names" do
  assert_equal "test/x_test.rb:5: test \"a-b\" has the same method name test_a_b as test \"a b\" (line 2)", refusal(two_tests("a b", "a-b"))
  assert_equal "test/x_test.rb:5: test \"ロシア\" has the same method name test____ as test \"日本語\" (line 2)", refusal(two_tests("日本語", "ロシア"))
  assert_equal "test________", Cybertrain::Gen::TestScan.method_name("日本語のテスト")
  assert_equal "test_it_s_here", Cybertrain::Gen::TestScan.method_name("it's here")
  assert_equal "", refusal(two_tests("it's here", "say \"hi\""))
  out = Cybertrain::Gen::TestScan.rewrite(two_tests("it's here", "say \"hi\""), "test/x_test.rb")
  assert_equal "  def test_say__hi_; begin\n", out.lines[4]
end

test "setup do beside def setup is refused naming both" do
  src = "class ThingTest < ActiveSupport::TestCase\n  setup do\n    a\n  end\n\n\n  def setup\n    super\n  end\nend\n"
  assert_equal "test/x_test.rb:7: ThingTest has both `setup do` (line 2) and `def setup`; use one", refusal(src)
end

test "a computed test name in a test class is refused" do
  src = "class XTest < ActiveSupport::TestCase\n  [1].each do |n|\n  end\n  test \"n#{"\#{1}"}\" do\n  end\nend\n"
  assert_equal "test/x_test.rb:4: a test name must be a string literal (no interpolation) in a test class", refusal(src)
end

test "the form is told apart by content and through an application base class" do
  root = temp_app("test/support/app_integration.rb" => "class ApplicationIntegrationTest < ActionDispatch::IntegrationTest\nend\n",
                  "test/x_test.rb" => "class XTest < ApplicationIntegrationTest\n  test \"a\" do\n  end\nend\n",
                  "test/legacy.rb" => "test \"old\" do\nend\nCybertrain::Test.run!\n")
  forms = Cybertrain::Gen::TestScan.scan(root).map { |f| [f.test_path, f.test_form] }
  assert_includes forms, ["test/x_test.rb", :class]
  assert_includes forms, ["test/legacy.rb", :top_level]
end

test "what the scan records for the bundle" do
  root = temp_app("test/test_helper.rb" => "ENV[\"CYBERTRAIN_ENV\"] ||= \"test\"\nclass ActiveSupport::TestCase\n  fixtures :all\nend\nTRAIL = []\n",
                  "test/models/post_test.rb" => "require \"test_helper\"\n\nclass PostTest < ActiveSupport::TestCase\n  test \"saves\" do\n  end\n\n  test \"it's valid\" do\n  end\nend\n",
                  "test/legacy.rb" => "def new_client = 1\ntest \"old\" do\nend\ntest name_of(1) do\nend\n")
  files = Cybertrain::Gen::TestScan.scan(root)
  assert_equal ["test/test_helper.rb", "test/legacy.rb", "test/models/post_test.rb"], files.map(&:test_path)
  helper = files[0]
  assert helper.support_file?
  assert_equal :top_level, helper.test_form
  assert_equal "", helper.copy_path
  assert_equal [["TRAIL", "constant", 5]], helper.test_helpers.map { |h| [h.helper_name, h.helper_kind, h.helper_line] }
  legacy = files[1]
  assert_equal [["old", "test_old", 2]], legacy.test_lines.map { |c| [c.case_name, c.case_method, c.case_line] }
  assert_equal [["new_client", "def", 1]], legacy.test_helpers.map { |h| [h.helper_name, h.helper_kind, h.helper_line] }
  post = files[2]
  refute post.support_file?
  assert_equal "gen/test/models/post_test.rb", post.copy_path
  assert_equal [["PostTest", "ActiveSupport::TestCase", 3]], post.test_classes.map { |c| [c.class_name, c.superclass_name, c.class_line] }
  assert_equal [["saves", "test_saves", 4], ["it's valid", "test_it_s_valid", 7]],
               post.test_classes[0].cases.map { |c| [c.case_name, c.case_method, c.case_line] }
end

test "a copied helper's relative require is rebased" do
  src = "ENV[\"CYBERTRAIN_ENV\"] ||= \"test\"\nrequire_relative \"../config/app\"\nrequire \"cybertrain/test_help\"\n"
  out = Cybertrain::Gen::TestScan.rewrite(src, "test/test_helper.rb")
  assert_equal "require_relative \"../../config/app\"\n", out.lines[1]
  assert_equal "require \"cybertrain/test_help\"\n", out.lines[2]
end

test "a require of a copied support file points at the copy" do
  root = temp_app("test/test_helper.rb" => "ENV[\"CYBERTRAIN_ENV\"] ||= \"test\"\nrequire_relative \"support/sign_in\"\nrequire_relative(\"support/plain.rb\")\n" \
                                           "class ApplicationTest < ActiveSupport::TestCase\nend\n",
                  "test/support/sign_in.rb" => "class SignInTest < ApplicationTest\n  def sign_in = nil\nend\n",
                  "test/support/plain.rb" => "module Plain\nend\n")
  copies = Cybertrain::Gen::TestScan.copies(root)
  assert_equal ["gen/test/test_helper.rb", "gen/test/support/sign_in.rb"], copies.keys
  lines = copies["gen/test/test_helper.rb"].lines
  assert_equal "require_relative \"support/sign_in\"\n", lines[1]
  assert_equal "require_relative(\"../../test/support/plain.rb\")\n", lines[2]
  assert_equal "# Generated by `spin run gen` from test/test_helper.rb. Do not edit.\n", lines[5]
  # Written out, each rebased target names a file that exists.
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert File.exist?("#{root}/gen/test/support/sign_in.rb")
  assert File.exist?("#{root}/gen/test/../../test/support/plain.rb")
end

test "a computed require_relative is refused" do
  src = "ENV[\"CYBERTRAIN_ENV\"] ||= \"test\"\n\nrequire_relative File.join(\"a\", \"b\")\n"
  msg = refusal_at(src, "test/test_helper.rb")
  assert msg.start_with?("test/test_helper.rb:3: "), msg
end

test "gen writes gen/test copies, removes stale ones and --check reports them" do
  root = temp_app("test/x_test.rb" => "class XTest < ActiveSupport::TestCase\n  test \"a\" do\n  end\nend\n",
                  "test/models/y_test.rb" => "class YTest < ActiveSupport::TestCase\nend\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert File.exist?("#{root}/gen/test/x_test.rb")
  assert_includes File.read("#{root}/gen/test/x_test.rb"), "  def test_a; begin\n"
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
  File.write("#{root}/test/x_test.rb", File.read("#{root}/test/x_test.rb").sub("\"a\"", "\"b\""))
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  File.delete("#{root}/test/x_test.rb")
  File.delete("#{root}/test/models/y_test.rb")
  Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen/test/x_test.rb")
  refute File.directory?("#{root}/gen/test")
end

def rewrite_lines(src)
  Cybertrain::Gen::TestScan.rewrite(src, "test/x_test.rb").lines
end

def scan_refusal(root)
  Cybertrain::Gen::TestScan.copies(root)
  ""
rescue ArgumentError => e
  e.message
end

test "the probe's rewritten copy is fresh" do
  copy = Cybertrain::Gen::TestScan.rewrite_in(File.read(PROBE_SOURCE), "test/probe_test.rb", ["ProbeBase"], Array.new(0) { "" })
  if File.read(PROBE_COPY) != copy
    File.write(PROBE_COPY, copy)
    flunk("fixture stale: #{PROBE_COPY} (rewritten; rebuild and rerun)")
  end
  assert_equal File.read(PROBE_SOURCE).lines.size, copy.lines.size
end

test "rewritten methods answer nil through rescue, ensure, a bare return and a hand-written test" do
  PROBE_LOG.clear
  t = ProbeTest.new
  assert_nil t.setup
  assert_nil t.test_rescued
  assert_nil t.test_bare_return
  assert_nil t.test_one_line
  assert_nil t.test_written
  assert_nil t.teardown
  assert_equal ["base setup", "setup", "setup ensure", "rescued", "one line", "written", "teardown", "base teardown"], PROBE_LOG
  PROBE_LOG.clear
  own = ProbeOwnTest.new
  assert_nil own.setup
  assert_nil own.teardown
  assert_equal ["base setup", "own setup", "own ensure", "own teardown"], PROBE_LOG
end

RETURN_REFUSED = "`return <value>` in a test, setup or teardown method is not supported (each answers nil, and gen cannot tell a return in a lambda or block from the method's own); use a bare `return`"

test "a return with a value in a test method is refused" do
  assert_equal "test/x_test.rb:3: #{RETURN_REFUSED}",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    return 5 if x\n  end\nend\n")
  assert_equal "test/x_test.rb:2: #{RETURN_REFUSED}", refusal("class XTest < ActiveSupport::TestCase\n  def setup = (return 1)\nend\n")
  assert_equal "", refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    return unless x\n    return nil\n    s = \"return 5\" # return 6\n  end\nend\n")
end

test "heredocs, =begin and multi-line strings inside a test keep their text" do
  src = "class XTest < ActiveSupport::TestCase\n  test \"gen\" do\n    src = <<-RUBY\nclass Foo\nend\n    RUBY\n" \
        "    assert_equal 2, src.lines.size\n  end\n\n  test \"second\" do\n  end\nend\n"
  lines = rewrite_lines(src)
  assert_equal ["class Foo\n", "end\n", "    RUBY\n"], lines[3, 3]
  assert_equal "  end; nil; end\n", lines[7]
  assert_equal "  def test_second; begin\n", lines[9]
  src = "class XTest < ActiveSupport::TestCase\n  test \"doc\" do\n=begin\nend\n=end\n    s = \"line\nend\"\n    t = %w[a\nend]\n" \
        "    u = <<~'TXT'.strip + <<~TXT\n      run \"inner\" do\n    TXT\n    end\n    TXT\n  end\nend\n"
  lines = rewrite_lines(src)
  assert_equal src.lines[2, 12], lines[2, 12]
  assert_equal "  end; nil; end\n", lines[14]
end

test "an unterminated heredoc or string and mixed tabs and spaces are refused" do
  assert_equal "test/x_test.rb:3: the heredoc <<~RUBY is not closed; gen cannot tell where this test class ends",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    s = <<~RUBY\n  end\nend\n")
  assert_equal "test/x_test.rb:3: the string opened here is not closed; gen cannot tell where this test class ends",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    s = \"abc\n  end\nend\n")
  assert_equal "test/x_test.rb:5: the indentation mixes tabs and spaces; indent this test class with one or the other",
               refusal("class XTest < ActiveSupport::TestCase\n\ttest \"a\" do\n\t\tx\n\tend\n  test \"b\" do\n  end\nend\n")
end

test "a nested helper class and a heredoc in a helper are left alone" do
  src = "class XTest < ActiveSupport::TestCase\n  class FakeClient\n    def setup\n      :configured\n    end\n  end\n\n  setup do\n  end\n\n" \
        "  def sample\n    <<~RUBY\n  end\n  end\n    RUBY\n  end\nend\n"
  lines = rewrite_lines(src)
  assert_equal src.lines[1, 5], lines[1, 5]
  assert_equal src.lines[10, 6], lines[10, 6]
  root = temp_app("test/x_test.rb" => src)
  assert_equal 0, Cybertrain::Gen::TestScan.scan(root).last.test_classes[0].cases.size
end

NESTED = "is nested in another class or module; define test classes at the top level of the file"

test "a nested test class and a test class inside a module are refused" do
  assert_equal "test/x_test.rb:3: InnerTest #{NESTED}",
               refusal("class OuterTest < ActiveSupport::TestCase\n\n  class InnerTest < ActiveSupport::TestCase\n  end\nend\n")
  assert_equal "test/x_test.rb:2: UsersControllerTest #{NESTED}",
               refusal("module Admin\n  class UsersControllerTest < ActionDispatch::IntegrationTest\n    test \"a\" do\n    end\n  end\nend\n")
  root = temp_app("test/admin_test.rb" => "module Admin\n  class UsersTest < ActiveSupport::TestCase\n  end\nend\n")
  assert_equal "test/admin_test.rb:2: UsersTest #{NESTED}", scan_refusal(root)
end

test "a test class opened twice is refused naming both places" do
  src = "class XTest < ActiveSupport::TestCase\n  test \"a\" do\n  end\nend\n\nclass XTest < ActiveSupport::TestCase\n  test \"a\" do\n  end\nend\n"
  assert_equal "test/x_test.rb:6: XTest is opened again; it is opened at test/x_test.rb:1 too (open a test class once)", refusal(src)
  root = temp_app("test/a_test.rb" => "class UserTest < ActiveSupport::TestCase\nend\n", "test/b_test.rb" => "\nclass UserTest\n  test \"b\" do\n  end\nend\n")
  assert_equal "test/b_test.rb:2: UserTest is opened again; it is opened at test/a_test.rb:1 too (open a test class once)", scan_refusal(root)
end

test "a hand-written test method beside a test block of the same name is refused" do
  src = "class XTest < ActiveSupport::TestCase\n  test \"x\" do\n  end\n\n  def test_x\n    flunk\n  end\nend\n"
  assert_equal "test/x_test.rb:5: def test_x has the same method name test_x as test \"x\" (line 2)", refusal(src)
  src = "class XTest < ActiveSupport::TestCase\n  def test_y = 1\n  def test_y = 2\nend\n"
  assert_equal "test/x_test.rb:3: def test_y has the same method name test_y as def test_y (line 2)", refusal(src)
  src = "class XTest < ActiveSupport::TestCase\n  def test_y\n  end\n\n  test \"y\" do\n  end\nend\n"
  assert_equal "test/x_test.rb:5: test \"y\" has the same method name test_y as def test_y (line 2)", refusal(src)
end

test "a hand-written test method is a case" do
  root = temp_app("test/x_test.rb" => "class XTest < ActiveSupport::TestCase\n  def test_written\n    assert true\n  end\n\n  def test_helper_arg(x) = x\nend\n")
  cases = Cybertrain::Gen::TestScan.scan(root).last.test_classes[0].cases
  assert_equal [["test_written", "test_written", 2]], cases.map { |c| [c.case_name, c.case_method, c.case_line] }
end

test "setup in a reopened framework class, brace and symbol forms are refused" do
  assert_equal "test/test_helper.rb:3: `setup do` in a reopened ActiveSupport::TestCase is not supported; " \
               "put it in an application base class (class ApplicationTest < ActiveSupport::TestCase with setup do ... end) and inherit from it",
               refusal_at("ENV[\"X\"] = \"1\"\nclass ActiveSupport::TestCase\n  setup do\n  end\nend\n", "test/test_helper.rb")
  assert_equal "test/x_test.rb:2: `teardown { ... }` is not supported in a test class; write `teardown do ... end`",
               refusal("class XTest < ActiveSupport::TestCase\n  teardown { reset }\nend\n")
  assert_equal "test/x_test.rb:2: `setup :name` is not supported in a test class; write `setup do ... end`",
               refusal("class XTest < ActiveSupport::TestCase\n  setup :sign_in\nend\n")
end

test "a class head with a body on its line is not taken for a closed class" do
  lines = rewrite_lines("class XTest < ActiveSupport::TestCase; include Foo\n  test \"a\" do\n  end\nend\n")
  assert_equal "  def test_a; begin\n", lines[1]
end

test "escapes in test names" do
  lines = rewrite_lines("class XTest < ActiveSupport::TestCase\n  test \"a\\sb\" do\n  end\nend\n")
  assert_equal "  def test_a_b; begin\n", lines[1]
  assert_equal "test/x_test.rb:2: the escape \\u in a test name is not supported; write the character itself",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"caf\\u00e9\" do\n  end\nend\n")
end

test "CRLF lines stay CRLF and a missing last newline is added before the footer" do
  lines = rewrite_lines("class XTest < ActiveSupport::TestCase\r\n  test \"a\" do\r\n  end\r\nend\r\n")
  assert_equal ["class XTest < ActiveSupport::TestCase\r\n", "  def test_a; begin\r\n", "  end; nil; end\r\n", "end\r\n"], lines
  root = temp_app("test/x_test.rb" => "class XTest < ActiveSupport::TestCase\nend")
  assert_equal "class XTest < ActiveSupport::TestCase\nend\n# Generated by `spin run gen` from test/x_test.rb. Do not edit.\n",
               Cybertrain::Gen::TestScan.copies(root)["gen/test/x_test.rb"]
end

test "a require from a nested support directory that leaves test/ is rebased" do
  root = temp_app("test/support/deep/x.rb" => "require_relative \"../../../lib/foo\"\nclass DeepTest < ActiveSupport::TestCase\nend\n")
  assert_equal "require_relative \"../../../../lib/foo\"\n", Cybertrain::Gen::TestScan.copies(root)["gen/test/support/deep/x.rb"].lines[0]
end

test "the sweep removes only gen's own copies and --check reports an orphan" do
  root = temp_app("test/x_test.rb" => "class XTest < ActiveSupport::TestCase\nend\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  File.write("#{root}/gen/test/data.rb", "# fixtures\n")
  File.write("#{root}/gen/test/mine.rb", "# written by hand\n")
  File.write("#{root}/gen/test/old_test.rb", "\n# Generated by `spin run gen` from test/old_test.rb. Do not edit.\n")
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  assert File.exist?("#{root}/gen/test/old_test.rb")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen/test/old_test.rb")
  assert File.exist?("#{root}/gen/test/data.rb")
  assert File.exist?("#{root}/gen/test/mine.rb")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
end

UNPLACED = "gen could not place this line as a test of the class; write `test \"...\" do` (or `setup do`, `teardown do`) " \
           "directly in the class body, not inside a condition, loop, string or heredoc"

test "which raw lines look like test declarations" do
  ["test \"a\" do", "test 'a' do", "test(\"a\") do", "test (x) do", "setup do", "setup{ x }", "teardown { y }", "setup :sign_in", "teardown(:x)",
   "  test \"n #{"\#{n}"}\" do", "test\"x\" do", "test\t\"x\" do"].each do |line|
    assert Cybertrain::Gen::TestScan.dsl_line?(line), line
  end
  ["test_helper", "tested \"a\"", "setup_x do", "@setup = 1", "setup = 1", "def setup", "# test \"a\" do", "testing do", "teardown"].each do |line|
    refute Cybertrain::Gen::TestScan.dsl_line?(line), line
  end
end

test "the safety net refuses a test declaration the rewrite did not place" do
  assert_equal "test/x_test.rb:3: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  if ENV[\"CI\"]\n    test \"ci only\" do\n    end\n  end\nend\n")
  assert_equal "test/x_test.rb:3: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  unless false\n    setup do\n    end\n  end\nend\n")
  assert_equal "test/x_test.rb:3: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  %w[a b].each do |n|\n    test \"x \#{n}\" do\n    end\n  end\nend\n")
  assert_equal "test/x_test.rb:4: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  def sample\n    <<~RUBY\n  test \"a\" do\n    RUBY\n  end\nend\n")
  assert_equal "test/x_test.rb:3: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  class FakeClient\n    test \"stray\" do\n    end\n  end\nend\n")
  assert_equal "test/x_test.rb:5: #{UNPLACED}", refusal("class XTest < ActiveSupport::TestCase\nend\n\n\ntest \"top\" do\nend\n")
end

GUESSED_REGEXP = "the `/` here reads as a regexp that does not close on this line; " \
                 "write division with a space after `/` (x / y) or keep the regexp on one line"

test "a division read as a regexp that runs on is refused, globals are not literals" do
  src = "class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    ratio = @total /count\n  end\n\n  test \"b\" do\n    assert_equal 2, a/b\n  end\nend\n"
  assert_equal "test/x_test.rb:3: #{GUESSED_REGEXP}", refusal(src)
  assert_equal "test/x_test.rb:3: #{GUESSED_REGEXP}", refusal(src.sub("@total /count", "x = 10 /2"))
  lines = rewrite_lines("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    x = $'\n  end\n\n  test \"b\" do\n    y = $' + $` + $\" + $/\n  end\nend\n")
  assert_equal "  def test_b; begin\n", lines[5]
  assert_equal "  end; nil; end\n", lines[7]
end

test "common shapes are not refused" do
  body = ["assert_equal 2, x / y", "assert_match /foo/, s", "s =~ /end/", "a = %w[a b].map(&:upcase)", "b = 10 % 3", "puts %(x end)",
          "c = (1 > 0) ? \"y\" : \"n\"", "d = [?#, ?\"]", "e = \"\#{h[\"k\"]} and \#{ { a: \"}\" }[:a] } end\"", "f = \"\#{x.map { |v| \"\#{v}\" }.join}\"",
          "g = \"%.2f\" % v", "h = { end: 1 }[:end]"]
  src = "class XTest < ActiveSupport::TestCase\n  test \"a\" do\n#{body.map { |l| "    #{l}\n" }.join}  end\n\n  test \"b\" do\n  end\nend\n"
  lines = rewrite_lines(src)
  assert_equal src.lines[2, body.size], lines[2, body.size]
  assert_equal "  end; nil; end\n", lines[2 + body.size]
  assert_equal "  def test_b; begin\n", lines[4 + body.size]
end

test "the body level comes from the test declarations" do
  lines = rewrite_lines("class XTest < ActiveSupport::TestCase\n    FOO = 1\n  test \"a\" do\n  end\nend\n")
  assert_equal "  def test_a; begin\n", lines[2]
end

REOPENED = "in a reopened ActiveSupport::TestCase is not supported; " \
           "put it in an application base class (class ApplicationTest < ActiveSupport::TestCase with setup do ... end) and inherit from it"

test "Rails' nested spelling of a reopened framework class is refused too" do
  assert_equal "test/test_helper.rb:4: `setup do` #{REOPENED}",
               refusal_at("module ActiveSupport\n  class TestCase\n    fixtures :all\n    setup do\n      @x = 1\n    end\n  end\nend\n", "test/test_helper.rb")
  assert_equal "test/test_helper.rb:3: `teardown` #{REOPENED.sub("ActiveSupport::TestCase is", "ActionDispatch::IntegrationTest is")}",
               refusal_at("module ActionDispatch\n  class IntegrationTest\n    teardown { reset! }\n  end\nend\n", "test/test_helper.rb")
  assert_equal "", refusal_at("module ActiveSupport\n  class TestCase\n    fixtures :all\n  end\nend\n", "test/test_helper.rb")
end

test "next, break or redo at a test body's own level is refused" do
  assert_equal "test/x_test.rb:3: `next` in a test, setup or teardown body is not supported (the block is now a method); use `return`",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    next if skip_it?\n    flunk\n  end\nend\n")
  assert_equal "", refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    [1].each do |x|\n      next if x\n    end\n  end\nend\n")
end

test "an end with a condition after it is refused" do
  assert_equal "test/x_test.rb:3: the `end` closing test \"a\" must stand alone (nothing but a comment after it)",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n  end if ENV[\"CI\"]\nend\n")
end

test "a return with a value in a lambda is still refused, saying why" do
  assert_equal "test/x_test.rb:3: #{RETURN_REFUSED}",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    f = -> { return 5 }\n  end\nend\n")
end

test "a test class opened after a semicolon is refused as nested" do
  assert_equal "test/x_test.rb:1: UsersTest #{NESTED}",
               refusal("module Admin; class UsersTest < ActiveSupport::TestCase\n  test \"a\" do\n  end\nend; end\n")
end

test "a heredoc terminator with trailing spaces does not end the heredoc" do
  src = "class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    s = <<~X\n    X  \n  end\n    X\n  end\nend\n"
  lines = rewrite_lines(src)
  assert_equal src.lines[2, 4], lines[2, 4]
  assert_equal "  end; nil; end\n", lines[6]
end

test "a second declaration on a converted line is refused" do
  assert_equal "test/x_test.rb:2: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do; assert true; end; test \"b\" do; raise \"never\"; end\nend\n")
  assert_equal "test/x_test.rb:2: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  setup do; @x = 1; end; test \"b\" do; raise \"never\"; end\nend\n")
  assert_equal "test/x_test.rb:3: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    x = 1; test \"b\" do\n    end\n  end\nend\n")
  assert_equal "test/x_test.rb:3: #{UNPLACED}",
               refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n  end; setup do\n  end\nend\n")
  assert_equal "", refusal("class XTest < ActiveSupport::TestCase\n  test \"a\" do\n    s = \"x; test 'b' do\"\n  end\nend\n")
end

test "a test with a tab or no space before its name is refused, not left at class level" do
  assert_equal "test/x_test.rb:2: #{UNPLACED}", refusal("class XTest < ActiveSupport::TestCase\n  test\"x\" do\n  end\nend\n")
  assert_equal "test/x_test.rb:2: #{UNPLACED}", refusal("class XTest < ActiveSupport::TestCase\n  test\t\"x\" do\n  end\nend\n")
end

test "declarations commented out by =begin or after __END__ are not refused" do
  assert_equal "", refusal("class XTest < ActiveSupport::TestCase\n=begin\n  test \"old\" do\n  end\n=end\nend\n__END__\n  test \"older\" do\n")
end

test "Rails' compact reopening of a framework class is refused too" do
  assert_equal "test/test_helper.rb:2: `setup do` #{REOPENED}",
               refusal_at("module ActiveSupport; class TestCase\n  setup do\n  end\nend; end\n", "test/test_helper.rb")
end

test "a test class at the margin inside a module at the margin is refused" do
  assert_equal "test/x_test.rb:2: UsersTest #{NESTED}",
               refusal("module Admin\nclass UsersTest < ActiveSupport::TestCase\n  test \"a\" do\n  end\nend\nend\n")
end

Cybertrain::Test.run!
