require "tmpdir"
require "cybertrain/cli"
require "cybertrain/generator/helper_scan"
require "cybertrain/test"

# `cybertrain generate helper`: an empty module under app/helpers and a test.
TMP = Dir.mktmpdir("cybertrain-cli-generate-helper")
Dir.chdir(TMP)

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }")

def generate(args)
  Dir.chdir("shop") { Cybertrain::CLI.run(["generate", "helper"] + args) }
end

test "generate helper prices writes an empty PricesHelper and a test" do
  assert_equal 0, generate(["prices"])
  source = File.read("shop/app/helpers/prices_helper.rb")
  assert source.start_with?("module PricesHelper\n")
  assert source.end_with?("end\n")
  refute File.exist?("shop/test/prices_helper.rb")
end

# The class form; the local template helper is render_helper_template, not
# render_inline (the framework's, which gen refuses an app to redefine).
test "the helper test is in the class form" do
  assert_equal <<~'RUBY', File.read("shop/test/helpers/prices_helper_test.rb")
    require "test_helper"

    # app/helpers/prices_helper.rb, through the app's ApplicationHelpers (gen/helpers.rb).
    class PricesHelperTest < ActiveSupport::TestCase
      test "PricesHelper is in the application's helpers" do
        assert_equal "ApplicationHelpers", Cybertrain::Views.helpers_builder.call(nil).class.name
        assert_equal "&lt;b&gt;", render_helper_template("<%= h '<b>' %>")
      end

      private

      # A template rendered with the application's helpers.
      def render_helper_template(source)
        template = Cybertrain::Template::Template.parse(source, "test/inline")
        env = { "__template_dir" => "test" }
        Cybertrain::Template::Interpreter.new(Cybertrain::Views.helpers_builder.call(nil)).render(template, env)
      end
    end
  RUBY
  refute File.read("shop/test/helpers/prices_helper_test.rb").include?("render_inline")
  refute File.exist?("shop/test/support/app_test.rb")
end

test "spin run gen's scan finds the generated module" do
  mods = Cybertrain::Gen::HelperScan.scan_dir("shop/app/helpers")
  assert_equal ["PricesHelper"], mods.map { |m| m.name }
  assert_equal 0, mods[0].defs.size
end

test "a namespaced helper is nested in its module" do
  assert_equal 0, generate(["admin/users"])
  assert_equal <<~'RUBY'.lines.first(2).join, File.read("shop/app/helpers/admin/users_helper.rb").lines.first(2).join
    module Admin
      module UsersHelper
  RUBY
  assert_includes File.read("shop/test/helpers/admin/users_helper_test.rb"), "class Admin::UsersHelperTest < ActiveSupport::TestCase\n"
end

test "an existing, different file is refused unless --force" do
  File.write("shop/app/helpers/prices_helper.rb", "module PricesHelper\n  def x = 1\nend\n")
  assert_equal 1, generate(["prices"])
  assert_equal "module PricesHelper\n  def x = 1\nend\n", File.read("shop/app/helpers/prices_helper.rb")
  assert_equal 0, generate(["prices", "--force"])
  assert File.read("shop/app/helpers/prices_helper.rb").start_with?("module PricesHelper\n  # Helpers here")
  assert_equal 0, generate(["prices"])
end

test "bad names and usage are rejected" do
  assert_equal 1, generate(["9lives"])
  assert_equal 1, generate([])
  assert_equal 1, generate(["a", "b"])
  assert_equal 1, Cybertrain::CLI.run(["generate", "helper", "prices"])
end

Cybertrain::Test.run!
