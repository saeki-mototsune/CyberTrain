require "tmpdir"
require "cybertrain/test"
require "cybertrain/main"
require_relative "support/log_capture"

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

def resolver = ->(name, args, options) { "/#{name}" }

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

# A partial under the development views root (app/views beside the
# program's working directory), rendered by a command as a mail body or a
# broadcast would be.
Dir.mkdir("app")
Dir.mkdir("app/views")
File.write("app/views/_greeting.html.erb", "<%# locals: (name:) %>Hi <%= name %>, <%= home_path %>")

Cybertrain::Main.command("greet", "render a partial") do |argv|
  SEEN << Cybertrain::Views.render_partial("greeting", name: argv[0]).to_s
  0
end

# Production: the embedded templates, parsed when a command renders them.
# Saved and restored in a plain method, whatever the command does.
def run_embedded(argv, sources)
  saved = Cybertrain.config.env
  Cybertrain.config.env = "production"
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: resolver, views: sources)
ensure
  Cybertrain.config.env = saved.to_s
end

EMBEDDED = {
  "_hello.html.erb" => "<%# locals: (name:) %>Hello <%= name %>, <%= home_path %>",
  "_broken.html.erb" => "<% if %>"
}

Cybertrain::Main.command("embedded_greet", "render an embedded partial") do |argv|
  SEEN << Cybertrain::Views.render_partial("hello", name: argv[0]).to_s
  0
end

Cybertrain::Main.command("embedded_broken", "render a partial that does not parse") do |argv|
  SEEN << Cybertrain::Views.render_partial("broken").to_s
  0
end

# The zone and the date a command sees (Time.zone and Date.current), as a
# command that stamps "today's" report would.
Cybertrain::Main.command("today", "record Time.zone and Date.current") do |argv|
  d = Date.current
  SEEN << "zone=#{Time.zone.zone_name} today=#{d.year}-#{d.month}-#{d.day}"
  0
end

# A command that logs one line, as a report command would.
Cybertrain::Main.command("log_line", "log one line") do |argv|
  Cybertrain.logger.info("from a command")
  0
end

# Runs `argv` with config.log_format = :json, then puts the text format
# back (a plain method's ensure: pre-flight ruling G4).
def run_in_json(argv)
  Cybertrain.config.log_format = :json
  run(argv)
ensure
  Cybertrain.config.log_format = :text
  Cybertrain::Logger.json_lines = false
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

test "a command can render a partial, path helpers included" do
  base = SEEN.size
  assert_equal 0, run(["greet", "Ann"])
  assert_equal "Hi Ann, /home_path", SEEN[base]
end

test "in production a command parses embedded templates only when it renders them" do
  base = SEEN.size
  # A template that does not parse stops a server at boot, not a command
  # that renders nothing, nor one that renders another template.
  assert_equal 3, run_embedded(["status", "3"], EMBEDDED)
  assert_equal 0, run_embedded(["embedded_greet", "Bo"], EMBEDDED)
  assert_equal "Hello Bo, /home_path", SEEN[base]
  msg = assert_raises("SyntaxError") { run_embedded(["embedded_broken"], EMBEDDED) }
  assert_includes msg, "_broken.html.erb:1"
  refute Cybertrain::DB.connected?
end

test "a registered command runs in the configured time zone" do
  base = SEEN.size
  Cybertrain.config.time_zone = "Asia/Tokyo"
  # 23:30 UTC on 1 January is 08:30 on 2 January in Tokyo.
  travel_to(Time.utc(2026, 1, 1, 23, 30)) { assert_equal 0, run(["today"]) }
  Cybertrain.config.time_zone = "UTC"
  assert_equal "zone=Asia/Tokyo today=2026-1-2", SEEN[base]
  travel_to(Time.utc(2026, 1, 1, 23, 30)) { assert_equal 0, run(["today"]) }
  assert_equal "zone=UTC today=2026-1-1", SEEN[base + 1]
end

test "jobs installs the configured time zone too" do
  Cybertrain.config.time_zone = "Asia/Tokyo"
  assert_equal 0, run(["jobs", "list"])
  Cybertrain.config.time_zone = "UTC"
  assert_equal "Asia/Tokyo", Time.zone.zone_name
  Cybertrain::Clock.zone = Cybertrain::TimeZone::UTC
end

test "an unknown time zone is refused before a command, jobs or console runs" do
  base = SEEN.size
  Cybertrain.config.time_zone = "Mars/Olympus_Mons"
  assert_equal 1, run(["user", "z@example.com"])
  assert_equal 1, run(["jobs", "list"])
  assert_equal 1, run(["console"])
  Cybertrain.config.time_zone = "UTC"
  assert_equal base, SEEN.size
  assert_equal "UTC", Time.zone.zone_name
  refute Cybertrain::DB.connected?
end

test "a command logs in the configured format" do
  status = -1
  log = capture_log { travel_to(Time.utc(2026, 11, 11, 12)) { status = run_in_json(["log_line"]) } }
  assert_equal 0, status
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","tags":[],"message":"from a command"}\n), log
  refute Cybertrain::Logger.json_lines
  text = capture_log { travel_to(Time.utc(2026, 11, 11, 12)) { status = run(["log_line"]) } }
  assert_equal "2026-11-11T12:00:00.000Z INFO from a command\n", text
end

test "a command logs at the configured level" do
  Cybertrain.config.log_level = :warn
  quiet = capture_log { run(["log_line"]) }
  Cybertrain.config.log_level = :info
  assert_equal "", quiet
  assert_logged capture_log { run(["log_line"]) }, "INFO", "from a command"
end

test "an unknown log level or format is refused before a command, jobs or console runs" do
  base = SEEN.size
  Cybertrain.config.log_level = :verbose
  assert_equal 1, run(["user", "y@example.com"])
  assert_equal 1, run(["jobs", "list"])
  assert_equal 1, run(["console"])
  Cybertrain.config.log_level = :info
  Cybertrain.config.log_format = :xml
  assert_equal 1, run(["user", "y@example.com"])
  Cybertrain.config.log_format = :text
  assert_equal base, SEEN.size
  refute Cybertrain::Logger.json_lines
  refute Cybertrain::DB.connected?
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
