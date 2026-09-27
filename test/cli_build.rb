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
end

test "server rejects a PORT that is not a number" do
  assert_equal 1, Cybertrain::CLI.run(["server", "abc"])
end

test "assemble copies the binary and public/ into dist/ and keeps storage/ and tmp/" do
  Dir.mkdir("dist")
  Dir.mkdir("dist/storage")
  File.write("dist/storage/production.sqlite3", "keep me")
  Dir.mkdir("dist/public")
  File.write("dist/public/stale.css", "old")
  written = Cybertrain::CLI::Build.assemble(".", "blog")
  assert_equal ["dist/blog", "dist/public/", "dist/storage/", "dist/tmp/"], written
  assert_equal "#!/bin/sh\necho built\n", File.read("dist/blog")
  assert File.executable?("dist/blog")
  assert_equal "body{}\n", File.read("dist/public/style.css")
  assert_equal "logo\n", File.read("dist/public/img/logo.txt")
  refute File.exist?("dist/public/stale.css")
  assert_equal "keep me", File.read("dist/storage/production.sqlite3")
  assert File.directory?("dist/tmp")
end

test "assemble removes a symlink in dist/public without following it" do
  Dir.mkdir("outside")
  File.write("outside/keep.txt", "keep")
  File.symlink("#{ROOT}/outside", "dist/public/linked")
  Cybertrain::CLI::Build.assemble(".", "blog")
  assert_equal "keep", File.read("outside/keep.txt")
  refute File.exist?("dist/public/linked")
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
