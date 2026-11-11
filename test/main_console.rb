require "tmpdir"
require "cybertrain/test"
require "cybertrain/main"

# Cybertrain::Main's console and dbconsole words. `console` reads the
# terminal, so the console cases run this same binary again as a child with
# a pipe on its standard input (MAIN_CONSOLE_CHILD=1 makes the child run
# `console` and exit): Console.run is only ever given STDIN and STDOUT here,
# never a StringIO (spikes/NOTES.md rule 19; test/console.rb drives it with
# StringIOs). `dbconsole` runs a fake sqlite3 from a temporary PATH, and
# none at all.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def resolver = ->(name, args, options) { "/" }

def run(argv)
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: resolver, views: no_views)
end

exit(run(["console"])) if ENV["MAIN_CONSOLE_CHILD"] == "1"

SELF = File.expand_path($0)
TMP = Dir.mktmpdir("cybertrain-main-console")
PATH_BEFORE = ENV["PATH"].to_s
ENV["CYBERTRAIN_ENV"] = "test"
ENV["CYBERTRAIN_DATABASE"] = "#{TMP}/console.sqlite3"

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit { rm_tree(TMP) }

# The child's output for `input` on its standard input, and its status.
def console_child(input)
  out = "#{TMP}/console.out"
  script = "printf '%s' \"$2\" | MAIN_CONSOLE_CHILD=1 \"$0\" > \"$1\" 2>&1"
  system("sh", "-c", script, SELF, out, input)
  status = $?.nil? ? -1 : $?.exitstatus
  "#{status}|#{File.read(out)}"
end

BANNER = "Cybertrain console (test). Type help for commands, exit to quit.\n"

test "console evaluates lines from the terminal until exit" do
  expected = "0|#{BANNER}>> 3\n>> n\n-\n7\n(1 row)\n>> "
  assert_equal expected, console_child("1 + 2\nsql \"SELECT 7 AS n\"\nexit\n")
end

test "console ends with status 0 at the end of its input" do
  assert_equal "0|#{BANNER}>> 3\n>> \n", console_child("1 + 2\n")
end

test "console and dbconsole are built-in words, not server words" do
  refute Cybertrain::Main.server?(["console"])
  refute Cybertrain::Main.server?(["dbconsole"])
  usage = Cybertrain::Main.usage("blog")
  assert_includes usage, "  ./blog console           evaluate expressions over the models (help inside)\n"
  assert_includes usage, "  ./blog dbconsole         open the sqlite3 shell on the database\n"
  message = assert_raises("ArgumentError") { Cybertrain::Main.command("console", "x") { |argv| 0 } }
  assert_equal "Main.command \"console\": console is a built-in command", message
  message = assert_raises("ArgumentError") { Cybertrain::Main.command("dbconsole", "x") { |argv| 0 } }
  assert_equal "Main.command \"dbconsole\": dbconsole is a built-in command", message
end

test "dbconsole runs sqlite3 on the database and passes its exit status through" do
  bin = "#{TMP}/bin"
  Dir.mkdir(bin)
  fake = "#{bin}/sqlite3"
  File.write(fake, "#!/bin/sh\nprintf '%s' \"$1\" > \"$0.args\"\nexit 3\n")
  File.chmod(0o755, fake)
  ENV["PATH"] = bin
  status = run(["dbconsole"])
  ENV["PATH"] = PATH_BEFORE
  assert_equal 3, status
  assert_equal "#{TMP}/console.sqlite3", File.read("#{fake}.args")
end

test "dbconsole answers 1 when a signal ends sqlite3" do
  bin = "#{TMP}/killed"
  Dir.mkdir(bin)
  fake = "#{bin}/sqlite3"
  File.write(fake, "#!/bin/sh\nkill -TERM $$\n")
  File.chmod(0o755, fake)
  ENV["PATH"] = "#{bin}:/bin:/usr/bin"
  status = run(["dbconsole"])
  ENV["PATH"] = PATH_BEFORE
  assert_equal 1, status
end

test "a database path starting with - reaches sqlite3 as ./-..." do
  assert_equal "./-odd.sqlite3", Cybertrain::Main.dbconsole_path("-odd.sqlite3")
  assert_equal "/a/b.sqlite3", Cybertrain::Main.dbconsole_path("/a/b.sqlite3")
  bin = "#{TMP}/dash"
  Dir.mkdir(bin)
  fake = "#{bin}/sqlite3"
  File.write(fake, "#!/bin/sh\nprintf '%s' \"$1\" > \"$0.args\"\n")
  File.chmod(0o755, fake)
  ENV["PATH"] = bin
  before = Cybertrain.config.database_path
  Cybertrain.config.database_path = "-dash.sqlite3"
  status = run(["dbconsole"])
  ENV["PATH"] = PATH_BEFORE
  Cybertrain.config.database_path = before
  assert_equal 0, status
  assert_equal "./-dash.sqlite3", File.read("#{fake}.args")
end

test "dbconsole reports an sqlite3 it cannot run, not a missing one" do
  bin = "#{TMP}/noexec"
  Dir.mkdir(bin)
  fake = "#{bin}/sqlite3"
  File.write(fake, "#!/bin/sh\nexit 0\n")
  File.chmod(0o644, fake)
  ENV["PATH"] = bin
  status = run(["dbconsole"])
  ENV["PATH"] = PATH_BEFORE
  assert_equal 1, status
end

test "dbconsole without sqlite3 says how to get it" do
  ENV["PATH"] = ""
  status = run(["dbconsole"])
  ENV["PATH"] = PATH_BEFORE
  assert_equal 1, status
end

Cybertrain::Test.run!
