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
  test_source = File.read("shop/test/prices_helper.rb")
  assert_includes test_source, "require_relative \"../gen/app\"\n"
  assert_includes test_source, "test \"PricesHelper is in the application's helpers\" do\n"
  assert_includes test_source, "Cybertrain::Test.run!\n"
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
  assert File.exist?("shop/test/admin_users_helper.rb")
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
