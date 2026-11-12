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
  assert_equal "  def test_shows_an_article\n", lines[11]
  assert_equal "  nil; end\n", lines[13]
  assert_equal "class ArticlesControllerTest < ActionDispatch::IntegrationTest; def setup; super; setup_articles_controller_test_1; nil; end; " \
               "def teardown; teardown_articles_controller_test_1; super; nil; end\n", lines[2]
  assert_equal ["  def setup_articles_controller_test_1\n", "    @article = articles(:one)\n", "  nil; end\n"], lines[3, 3]
  assert_equal ["  def teardown_articles_controller_test_1\n", "    Cybertrain.config.http_allow_private = false\n", "  nil; end\n"], lines[7, 3]
  assert_equal "  def title_of(article) = article.title.upcase\n", lines[17]
  assert_equal "\n", lines[0]
  refute out.include?("require \"test_helper\"")
end

test "several setup blocks run in order, teardown blocks in reverse" do
  src = "class T < ActiveSupport::TestCase\n  setup do\n    a\n  end\n  setup do\n    b\n  end\n  teardown do\n    c\n  end\n  teardown do\n    d\n  end\n\n  test \"x\" do\n  end\nend\n"
  out = Cybertrain::Gen::TestScan.rewrite(src, "test/t_test.rb")
  assert_includes out.lines[0], "def setup; super; setup_t_1; setup_t_2; nil; end; def teardown; teardown_t_2; teardown_t_1; super; nil; end"
  assert_equal "  def test_x\n", out.lines[14]
  assert_equal "  nil; end\n", out.lines[15]
  assert_equal src.lines.size, out.lines.size
end

test "a test on one line, a class's own def setup and a class without blocks" do
  src = "class OneTest < ActiveSupport::TestCase\n  test \"x\" do assert true end\n  test \"y\" do; a; b; end\n  def setup\n    super\n    @user = 1\n  end\n\n  def teardown = super\nend\n" \
        "class Plain < ActiveSupport::TestCase\n  test \"z\" do\n  end\nend\n"
  lines = Cybertrain::Gen::TestScan.rewrite(src, "test/one_test.rb").lines
  assert_equal "class OneTest < ActiveSupport::TestCase\n", lines[0]
  assert_equal "  def test_x; assert true; nil; end\n", lines[1]
  assert_equal "  def test_y; a; b; nil; end\n", lines[2]
  assert_equal ["  def setup\n", "    super\n", "    @user = 1\n", "  nil; end\n"], lines[3, 4]
  assert_equal "  def teardown; super; nil; end\n", lines[8]
  assert_equal "class Plain < ActiveSupport::TestCase\n", lines[10]
  assert_equal "  def test_z\n", lines[11]
  assert_equal src.lines.size, lines.size
end

test "names that collide after the method-name rule, non-ASCII and quoted names" do
  assert_equal "test/x_test.rb:5: test \"a-b\" has the same method name test_a_b as test \"a b\" (line 2)", refusal(two_tests("a b", "a-b"))
  assert_equal "test/x_test.rb:5: test \"ロシア\" has the same method name test____ as test \"日本語\" (line 2)", refusal(two_tests("日本語", "ロシア"))
  assert_equal "test________", Cybertrain::Gen::TestScan.method_name("日本語のテスト")
  assert_equal "test_it_s_here", Cybertrain::Gen::TestScan.method_name("it's here")
  assert_equal "", refusal(two_tests("it's here", "say \"hi\""))
  out = Cybertrain::Gen::TestScan.rewrite(two_tests("it's here", "say \"hi\""), "test/x_test.rb")
  assert_equal "  def test_say__hi_\n", out.lines[4]
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
  assert File.exist?("#{root}/test/support/sign_in.rb")
  assert_equal "gen/test/support/sign_in", Cybertrain::Gen::TestScan.normalize("gen/test/support/sign_in")
  assert_equal "require_relative(\"../../test/support/plain.rb\")\n", lines[2]
  assert_equal "# Generated by `spin run gen` from test/test_helper.rb. Do not edit.\n", lines[5]
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
  assert_includes File.read("#{root}/gen/test/x_test.rb"), "  def test_a\n"
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
  File.write("#{root}/test/x_test.rb", File.read("#{root}/test/x_test.rb").sub("\"a\"", "\"b\""))
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  File.delete("#{root}/test/x_test.rb")
  File.delete("#{root}/test/models/y_test.rb")
  Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen/test/x_test.rb")
  refute File.directory?("#{root}/gen/test")
end

Cybertrain::Test.run!
