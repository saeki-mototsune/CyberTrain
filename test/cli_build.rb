require "tmpdir"
require "cybertrain/test"
require "cybertrain/cli"

# cybertrain build without spin: the command list and the dist/ assembly
# from a fake build/bin/<name>. CRuby-portable.

ROOT = Dir.mktmpdir("cybertrain-cli-build")
Dir.chdir(ROOT)

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
  rm_tree(ROOT)
end

def make_app
  File.write("spin.toml", "[package]\nname = \"blog\"\nversion = \"0.1.0\"\n\n[dependencies]\ncybertrain = { path = \"../cybertrain\" }\n")
  Dir.mkdir("build")
  Dir.mkdir("build/bin")
  File.write("build/bin/blog", "#!/bin/sh\necho built\n")
  File.chmod(0o755, "build/bin/blog")
  Dir.mkdir("public")
  Dir.mkdir("public/img")
  File.write("public/style.css", "body{}\n")
  File.write("public/img/logo.txt", "logo\n")
end

make_app

test "app_name reads [package] name from spin.toml" do
  assert_equal "blog", Cybertrain::CLI::Build.app_name(".")
  assert_equal "", Cybertrain::CLI::Build.app_name("no_such_dir")
end

test "build embeds the views, builds, then restores the empty table" do
  assert_equal ["spin run gen -- --embed-views", "spin build blog", "spin run gen"], Cybertrain::CLI::Build.commands("blog")
  assert_equal ["spin run gen", "spin run db -- migrate", "spin run gen"], Cybertrain::CLI::Build.migration_commands
  assert_equal "'a'\\''b'", Cybertrain::CLI::Build.shell_quote("a'b")
end

test "server generates first and passes an optional port" do
  assert_equal ["spin run gen", "spin run blog"], Cybertrain::CLI::Build.server_commands("blog", "")
  assert_equal ["spin run gen", "spin run blog -- 4000"], Cybertrain::CLI::Build.server_commands("blog", "4000")
  assert Cybertrain::CLI::Build.port?("4000")
  assert Cybertrain::CLI::Build.port?("65535")
  refute Cybertrain::CLI::Build.port?("65536")
  refute Cybertrain::CLI::Build.port?("")
  refute Cybertrain::CLI::Build.port?("80a")
  refute Cybertrain::CLI::Build.port?("-1")
  refute Cybertrain::CLI::Build.port?("000080000")
  refute Cybertrain::CLI::Build.port?("0")
end

test "server rejects a PORT that is not a number" do
  assert_equal 1, Cybertrain::CLI.run(["server", "abc"])
  assert_equal 1, Cybertrain::CLI.run(["server", "0"])
end

test "server rejects anything after PORT" do
  assert_equal 1, Cybertrain::CLI.run(["server", "4000", "extra"])
end

# Stands in for the three spin commands: records each one with whether the
# build lock was held while it ran, and fails the one named `failing`.
class FakeRunner < Cybertrain::CLI::Build::Runner
  attr_reader :log

  def initialize(failing)
    @failing = failing
    @log = Array.new(0) { "" }
  end

  def run_step(root, command)
    lock = File.exist?("#{root}/tmp/cybertrain-build.lock") ? "locked" : "unlocked"
    @log << "#{command} (#{lock})"
    command != @failing
  end
end

test "build runs the three steps under tmp/cybertrain-build.lock, then assembles dist/" do
  runner = FakeRunner.new("")
  assert_equal 0, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal ["spin run gen -- --embed-views (locked)", "spin build blog (locked)", "spin run gen (locked)"], runner.log
  refute File.exist?("tmp/cybertrain-build.lock")
  assert_equal "#!/bin/sh\necho built\n", File.read("dist/blog")
  assert File.directory?("dist/public")
  rm_tree("dist")
end

test "a failed spin build still restores gen/views.rb, skips assemble and exits 1" do
  runner = FakeRunner.new("spin build blog")
  assert_equal 1, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal ["spin run gen -- --embed-views (locked)", "spin build blog (locked)", "spin run gen (locked)"], runner.log
  refute File.exist?("dist")
  refute File.exist?("tmp/cybertrain-build.lock")
end

test "a failed restore exits 1, warns about gen/views.rb and releases the lock" do
  runner = FakeRunner.new("spin run gen")
  assert_equal 1, Cybertrain::CLI::Build.run(".", "blog", runner)
  assert_equal 3, runner.log.size
  refute File.exist?("dist")
  refute File.exist?("tmp/cybertrain-build.lock")
end

test "assemble copies the binary and public/ into dist/ and keeps storage/ and tmp/" do
  Dir.mkdir("dist")
  Dir.mkdir("dist/storage")
  File.write("dist/storage/production.sqlite3", "keep me")
  Dir.mkdir("dist/public")
  File.write("dist/public/stale.css", "old")
  # Leftovers of an interrupted earlier run.
  File.write("dist/.blog.tmp", "stale binary")
  Dir.mkdir("dist/.public.tmp")
  File.write("dist/.public.tmp/old.css", "stale")
  written = Cybertrain::CLI::Build.assemble(".", "blog")
  assert_equal ["dist/blog", "dist/public/", "dist/storage/", "dist/tmp/"], written
  assert_equal "#!/bin/sh\necho built\n", File.read("dist/blog")
  assert File.executable?("dist/blog")
  assert_equal "body{}\n", File.read("dist/public/style.css")
  assert_equal "logo\n", File.read("dist/public/img/logo.txt")
  refute File.exist?("dist/public/stale.css")
  refute File.exist?("dist/public/old.css")
  assert_equal "keep me", File.read("dist/storage/production.sqlite3")
  assert File.directory?("dist/tmp")
  refute File.exist?("dist/.blog.tmp")
  refute File.exist?("dist/.public.tmp")
  assert_equal "", Dir.children("dist").select { |child| child.start_with?(".") }.join(",")
end

test "assemble removes a symlink in dist/public without following it" do
  Dir.mkdir("outside")
  File.write("outside/keep.txt", "keep")
  File.symlink("#{ROOT}/outside", "dist/public/linked")
  Cybertrain::CLI::Build.assemble(".", "blog")
  assert_equal "keep", File.read("outside/keep.txt")
  refute File.exist?("dist/public/linked")
  assert_equal "", Dir.children("dist").select { |child| child.start_with?(".") }.join(",")
end

test "assemble fails clearly when the binary is missing" do
  File.delete("build/bin/blog")
  message = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::Build.assemble(".", "blog") }
  assert_equal "build/bin/blog is missing: `spin build blog` did not produce it", message
end

test "the CLI needs spin.toml for migration, db, server and build" do
  Dir.mkdir("elsewhere")
  Dir.chdir("elsewhere")
  assert_equal 1, Cybertrain::CLI.run(["migration"])
  assert_equal 1, Cybertrain::CLI.run(["db", "status"])
  assert_equal 1, Cybertrain::CLI.run(["server"])
  assert_equal 1, Cybertrain::CLI.run(["build"])
  Dir.chdir("..")
end

Cybertrain::Test.run!
