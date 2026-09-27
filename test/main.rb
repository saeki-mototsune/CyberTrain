require "tmpdir"
require "cybertrain/test"
require "cybertrain/main"

# Cybertrain::Main.run dispatches bin/<name>.rb's argv. The server branch
# is not exercised here (it would listen); Application covers it. The db
# and migrate branches go through DB::CLI.run with its default root "."
# (Main passes none), so this program runs from a fresh temp directory
# instead of the framework's own root, where migrate would otherwise find
# the repository's own db/ and dump a schema into it. The database is
# SQLite's in-memory ":memory:", which DB::CLI passes through unchanged.
# It also links SQLite through FFI, so its snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).
TMP = Dir.mktmpdir("cybertrain-main")
Dir.chdir(TMP)

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

# Test.run! exits the process, so the temp tree is removed at exit.
at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def resolver = ->(name, args) { "/" }

def run(argv)
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: resolver, views: no_views)
end

test "server_args keeps only a port" do
  assert_equal 0, Cybertrain::Main.server_args([]).size
  assert_equal 0, Cybertrain::Main.server_args(["server"]).size
  assert_equal ["3000"], Cybertrain::Main.server_args(["3000"])
  assert_equal ["3000"], Cybertrain::Main.server_args(["server", "3000"])
end

test "server? recognises the bare, named and port forms" do
  assert Cybertrain::Main.server?([])
  assert Cybertrain::Main.server?(["server"])
  assert Cybertrain::Main.server?(["3000"])
  assert Cybertrain::Main.server?(["server", "3000"])
  refute Cybertrain::Main.server?(["migrate"])
  refute Cybertrain::Main.server?(["frobnicate"])
end

test "help prints the usage for this app and exits 0" do
  assert_equal 0, run(["help"])
  assert_equal 0, run(["--help"])
  assert_equal 0, run(["-h"])
end

test "an unknown word prints the usage and exits 1" do
  assert_equal 1, run(["frobnicate"])
end

test "db passes its arguments to DB::CLI" do
  ENV["CYBERTRAIN_DATABASE"] = ":memory:"
  assert_equal 0, run(["db", "create"])
  assert_equal 0, run(["db", "status"])
  assert_equal 1, run(["db", "rollback", "x"])
  assert_equal 1, run(["db"])
end

test "migrate is db migrate" do
  ENV["CYBERTRAIN_DATABASE"] = ":memory:"
  assert_equal 0, run(["migrate"])
end

Cybertrain::Test.run!
