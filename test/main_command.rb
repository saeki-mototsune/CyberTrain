require "tmpdir"
require "cybertrain/test"
require "cybertrain/main"

# Cybertrain::Main.command: an application's own subcommands on its binary.
# The blocks below are registered at top level, as bin/<name>.rb does
# before Main.run. Each command runs against Cybertrain.config's database,
# here a file in a fresh temp directory (the program chdirs there, as
# test/main.rb does, so `migrate` finds no db/ to dump a schema into). It
# links SQLite through FFI, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
TMP = Dir.mktmpdir("cybertrain-main-command")
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

# What the blocks saw, read back by the tests (a constant: NOTES rule 64).
# Each run of "user" appends three lines.
SEEN = Array.new(0) { "" }

Cybertrain.config.database_path = "commands.sqlite3"

Cybertrain::Main.command("user", "create a user: EMAIL") do |argv|
  SEEN << "args=#{argv.join(",")}"
  SEEN << "connected=#{Cybertrain::DB.connected?} size=#{Cybertrain::DB.pool.size}"
  Cybertrain::DB.with do |c|
    c.execute("CREATE TABLE IF NOT EXISTS users (email TEXT)")
    c.execute("INSERT INTO users (email) VALUES (?)", [argv[0]])
  end
  rows = Cybertrain::DB.with { |c| c.execute("SELECT email FROM users") }
  SEEN << "users=#{rows.size}"
  0
end

Cybertrain::Main.command("status", "exit with ARG as the status") do |argv|
  argv[0].to_i
end

Cybertrain::Main.command("broken", "run SQL that fails") do |argv|
  Cybertrain::DB.with { |c| c.execute("SELECT * FROM no_such_table") }
  0
end

Cybertrain::Main.command("backup", "raise a DB::Error itself") do |argv|
  raise Cybertrain::DB::Error, "nothing to back up" if argv.empty?
  0
end

def refusal(word)
  Cybertrain::Main.command(word, "never registered") { |argv| 0 }
  "registered"
rescue ArgumentError => e
  e.message
end

test "a registered command runs with the arguments after its name" do
  base = SEEN.size
  assert_equal 0, run(["user", "a@example.com"])
  assert_equal "args=a@example.com", SEEN[base]
  assert_equal 0, run(["user", "b@example.com", "extra"])
  assert_equal "args=b@example.com,extra", SEEN[base + 3]
end

test "the database is connected with a pool of one, then disconnected" do
  base = SEEN.size
  assert_equal 0, run(["user", "c@example.com"])
  assert_equal "connected=true size=1", SEEN[base + 1]
  assert_equal "users=3", SEEN[base + 2]
  refute Cybertrain::DB.connected?
end

test "the block's value is the exit status" do
  assert_equal 0, run(["status", "0"])
  assert_equal 3, run(["status", "3"])
end

test "a DB::Error becomes an error line and exit 1" do
  assert_equal 1, run(["broken"])
  assert_equal 1, run(["backup"])
  assert_equal 0, run(["backup", "out.sqlite3"])
  refute Cybertrain::DB.connected?
end

test "a database that cannot be opened is a DB::Error too" do
  Cybertrain.config.database_path = "no/such/dir/x.sqlite3"
  assert_equal 1, run(["user", "d@example.com"])
  Cybertrain.config.database_path = "commands.sqlite3"
end

test "server? is false for a registered name" do
  refute Cybertrain::Main.server?(["user"])
  refute Cybertrain::Main.server?(["status", "3000"])
  assert Cybertrain::Main.server?([])
  assert Cybertrain::Main.server?(["3000"])
  assert Cybertrain::Main.server?(["server", "3000"])
end

test "help lists the registered commands after the built-in ones" do
  assert_equal 0, run(["help"])
  text = Cybertrain::Main.usage("blog")
  assert text.index("  ./blog user              create a user: EMAIL\n").to_i > 0
  assert text.index("./blog db COMMAND").to_i < text.index("./blog user").to_i
  assert text.index("./blog backup").to_i < text.index("./blog help").to_i
end

test "built-in, numeric, empty and taken names are refused" do
  assert_equal "Main.command \"db\": db is a built-in command", refusal("db")
  assert_equal "Main.command \"help\": help is a built-in command", refusal("help")
  assert_equal "Main.command \"8080\": a number is the server's port argument", refusal("8080")
  assert_equal "Main.command \"\": the name is empty", refusal("")
  assert_equal "Main.command \"user\": already registered", refusal("user")
end

test "the built-ins still work next to registered commands" do
  assert_equal 0, run(["migrate"])
  assert_equal 0, run(["db", "status"])
  assert_equal 1, run(["frobnicate"])
end

Cybertrain::Test.run!
