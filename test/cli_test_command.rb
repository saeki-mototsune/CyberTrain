require "tmpdir"
require "cybertrain/test"
require "cybertrain/cli"

# `cybertrain test` without a compile: the arguments, checked before any
# step; the steps in order (gen, the compile only when stale, the run);
# gen's refusal; staleness against the application, the framework and the
# toolchain; the compile command. CRuby-portable; the staleness tests call
# `spin flags`, so spin must be on PATH.

ROOT = Dir.mktmpdir("cybertrain-cli-test-command")
APP = "#{ROOT}/app"
FRAMEWORK = "#{ROOT}/framework"

def rm_tree(path)
  if File.symlink?(path)
    File.delete(path)
  elsif File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(ROOT)
end

def write(path, text)
  Cybertrain::CLI::Templates.mkdir_p(File.dirname(path))
  File.write(path, text)
end

# A framework stand-in (a package spin resolves by path) and an
# application depending on it.
write("#{FRAMEWORK}/spin.toml", "[package]\nname = \"cybertrain\"\nversion = \"0.0.1\"\n")
write("#{FRAMEWORK}/cybertrain.rb", "require \"cybertrain/core\"\n")
write("#{FRAMEWORK}/cybertrain/core.rb", "module Cybertrain\nend\n")
write("#{APP}/spin.toml", "[package]\nname = \"shop\"\nversion = \"0.1.0\"\n\n[dependencies]\ncybertrain = { path = \"../framework\" }\n")
write("#{APP}/app/models/article.rb", "class Article\nend\n")
write("#{APP}/test/test_helper.rb", "require \"cybertrain/test_help\"\n")
write("#{APP}/test/models/article_test.rb", "require \"test_helper\"\n")
write("#{APP}/test/fixtures/articles.yml", "one:\n  title: x\n")
write("#{APP}/test/legacy.rb", "test \"a\" do\nend\n")

# Records the steps instead of running them; `stale` answers stale?,
# `status` is the test run's exit status.
class StubRunner < Cybertrain::CLI::TestCommand::Runner
  attr_reader :steps, :said

  def initialize(stale, status)
    @stale = stale
    @status = status
    @steps = Array.new(0) { "" }
    @said = Array.new(0) { "" }
  end

  def ready?
    @steps << "ready"
    true
  end

  def run_step(root, command)
    @steps << command
    true
  end

  def stale?(root)
    @steps << "stale?"
    @stale
  end

  def run_tests(root, argv)
    @steps << "run #{argv.join(" ")}"
    @status
  end

  def say(text)
    @said << text
    nil
  end
end

def files = Cybertrain::TestFiles.list(APP)

def parse(argv) = Cybertrain::Test::Args.parse(argv, files, APP)

# Waits past the filesystem's mtime granularity, then writes: the file is
# newer than anything written before.
def touch_later(path)
  sleep 0.02
  File.write(path, File.read(path))
end

def record_now = Cybertrain::CLI::TestCommand.inputs_record(APP, `cd #{APP} && spin flags`)

# A binary and the record a compile leaves beside it.
def build_binary
  write("#{APP}/build/test/tests", "binary\n")
  write("#{APP}/build/test/tests.inputs", record_now)
end

test "file, directory and option arguments" do
  assert_equal ["test/legacy.rb", "test/models/article_test.rb"], files
  assert_equal ["test/models/article_test.rb"], parse(["./test/models/article_test.rb"]).arg_files
  assert_equal ["test/models/article_test.rb"], parse(["#{APP}/test/models/article_test.rb"]).arg_files
  assert_equal ["test/models/article_test.rb"], parse(["test/models"]).arg_files
  assert_equal "", parse(["test/models", "-n", "/title/"]).arg_error
  assert_equal "no test file at test/modles", parse(["test/modles"]).arg_error
  assert_equal "-n needs a name or /text/", parse(["-n"]).arg_error
  assert_equal "unknown option --seed", parse(["--seed", "1"]).arg_error
end

test "-n /TEXT/ with a regexp character, FILE:LINE and -- are answered for what they are" do
  assert_equal "-n /^test_create/: the text between the slashes is a plain substring of the test name, not a regexp " \
               "(^ would be looked for as itself); write the text to look for (-n /test_create/)",
               parse(["-n", "/^test_create/"]).arg_error
  assert_equal "-n /a.*b|c$/: the text between the slashes is a plain substring of the test name, not a regexp " \
               "(* would be looked for as itself); write the text to look for (-n /a.bc/)",
               parse(["-n", "/a.*b|c$/"]).arg_error
  assert_equal "-n /^$/: the text between the slashes is a plain substring of the test name, not a regexp " \
               "(^ would be looked for as itself); write the text to look for",
               parse(["-n", "/^$/"]).arg_error
  # Taken as themselves: test names hold them.
  assert_equal "v1.2 (draft)?", parse(["-n", "/v1.2 (draft)?/"]).arg_pattern
  assert_equal "line filters are not supported; give the file, and -n for the name", parse(["test/models/article_test.rb:14"]).arg_error
  assert_equal "line filters are not supported; give the file, and -n for the name", parse(["./test/legacy.rb:1"]).arg_error
  assert_equal "no test file at test/nope.rb:3", parse(["test/nope.rb:3"]).arg_error
  # `--` ends the options: what follows is a file or directory.
  assert_equal "", parse(["--", "test/legacy.rb"]).arg_error
  assert_equal ["test/legacy.rb"], parse(["-n", "a", "--", "test/legacy.rb"]).arg_files
  assert_equal "no test file at -n", parse(["--", "-n", "a"]).arg_error
  # filtered? (the bundle prints that nothing matched only under a filter).
  refute parse(Array.new(0) { "" }).filtered?
  assert parse(["test/legacy.rb"]).filtered?
  assert parse(["-n", "a"]).filtered?
  assert parse(["-n", "/a/"]).filtered?
end

test "a test's method name: ASCII as Rails' rule, any other character as _u<hex>_" do
  args = Cybertrain::Test::Args
  assert_equal "test_shows_an_article", args.method_for("shows an article")
  assert_equal "test_a_b_c_", args.method_for("a-b.c?")
  assert_equal "test__u30ed__u30b0__u30a4__u30f3__u3067__u304d__u308b_", args.method_for("ログインできる")
  assert_equal "test__u30ed__u30b0__u30a2__u30a6__u30c8__u3059__u308b_", args.method_for("ログアウトする")
  assert_equal "test_caf_ue9__x", args.method_for("café x")
  assert_equal "test__ue9__", args.method_for("é!")
  assert_equal "test__u1f600_", args.method_for("😀")
  # A byte that starts no well-formed sequence stands for itself.
  assert_equal "test_a_uff__ue3_b", args.method_for("a\xFF\xE3b")
  # The closing `_` keeps an escape from running into what follows.
  refute args.method_for("\u0E9A") == args.method_for("éa")
  assert_equal "test__ue9_a", args.method_for("éa")
  assert_equal "test__ue9a_", args.method_for("ບ")
  refute args.method_for("x_u3042") == args.method_for("xあ")
  # The literal text of an escape, underscore included, is the same name
  # (ASCII is kept as written); in one class gen refuses the pair.
  assert_equal args.method_for("x_u3042_"), args.method_for("xあ")
end

test "bad arguments print the usage and the reason, exit 2 and run no step" do
  runner = StubRunner.new(true, 0)
  assert_equal 2, Cybertrain::CLI::TestCommand.run(APP, ["--seed", "1"], runner)
  assert_equal ["usage: cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]\nunknown option --seed"], runner.said
  assert_equal [], runner.steps
  runner = StubRunner.new(true, 0)
  assert_equal 2, Cybertrain::CLI::TestCommand.run(APP, ["test/modles"], runner)
  assert_equal ["usage: cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]\nno test file at test/modles"], runner.said
  assert_equal [], runner.steps
end

test "gen, the compile when stale, then the run with the arguments and its status" do
  runner = StubRunner.new(true, 1)
  assert_equal 1, Cybertrain::CLI::TestCommand.run(APP, ["test/models", "-n", "/title/"], runner)
  assert_equal ["ready", "SPIN_DEBUG=1 spin run gen", "stale?", "spinel gen/tests.rb $(spin flags) -I gen/test -I test -o build/test/tests",
                "run test/models -n /title/"], runner.steps
  assert File.directory?("#{APP}/build/test")
  assert_equal [], runner.said
  # The compile replaced the binary (the stub wrote none) and recorded its inputs.
  refute File.exist?("#{APP}/build/test/tests")
  assert_equal record_now, File.read("#{APP}/build/test/tests.inputs")
  refute File.exist?("#{APP}/build/test/tests.inputs.tmp")
end

# Fails the compile step only.
class FailingCompile < StubRunner
  def run_step(root, command)
    @steps << command
    !command.start_with?("spinel ")
  end
end

test "a failed compile exits 1, runs nothing and leaves no binary or record" do
  build_binary
  runner = FailingCompile.new(true, 0)
  assert_equal 1, Cybertrain::CLI::TestCommand.run(APP, Array.new(0) { "" }, runner)
  refute runner.steps.include?("run ")
  refute File.exist?("#{APP}/build/test/tests")
  refute File.exist?("#{APP}/build/test/tests.inputs")
  refute File.exist?("#{APP}/build/test/tests.inputs.tmp")
end

# The CLI passes root "."; an absolute file argument means the same as to
# the bundle, which parses against Dir.pwd.
test "from the application's directory, absolute and ./ file arguments" do
  Dir.chdir(APP)
  ["#{APP}/test/models/article_test.rb", "./test/models/article_test.rb", "#{APP}/test/models/"].each do |arg|
    runner = StubRunner.new(false, 0)
    assert_equal 0, Cybertrain::CLI::TestCommand.run(".", [arg], runner)
    assert_equal ["ready", "SPIN_DEBUG=1 spin run gen", "stale?", "run #{arg}"], runner.steps
    assert_equal [], runner.said
  end
  Dir.chdir(ROOT)
end

test "no compile when nothing is newer than the binary" do
  runner = StubRunner.new(false, 0)
  assert_equal 0, Cybertrain::CLI::TestCommand.run(APP, ["-n", "test_a"], runner)
  assert_equal ["ready", "SPIN_DEBUG=1 spin run gen", "stale?", "run -n test_a"], runner.steps
end

test "gen's refusal is printed and exits 1 without a compile or a run" do
  reason = "test/b.rb:3: new_client is also defined at test/a.rb:5; move shared helpers to test/support/ or into a test class"
  write("#{APP}/gen/tests.rb", "# gen/tests.rb: a header\n# Do not edit.\nabort(\"#{reason}\")\n")
  assert_equal reason, Cybertrain::CLI::TestCommand.refusal(APP)
  runner = StubRunner.new(true, 0)
  assert_equal 1, Cybertrain::CLI::TestCommand.run(APP, Array.new(0) { "" }, runner)
  assert_equal ["ready", "SPIN_DEBUG=1 spin run gen"], runner.steps
  assert_equal [reason], runner.said

  write("#{APP}/gen/tests.rb", '# header' + "\n" + 'abort("a:1: \"x\" \\\\ \#{y}\nz")' + "\n")
  assert_equal 'a:1: "x" \\ #{y}' + "\n" + "z", Cybertrain::CLI::TestCommand.refusal(APP)
  write("#{APP}/gen/tests.rb", "# header\nENV[\"CYBERTRAIN_ENV\"] = \"test\"\nabort(\"later\")\n")
  assert_equal "", Cybertrain::CLI::TestCommand.refusal(APP)
  File.delete("#{APP}/gen/tests.rb")
  assert_equal "", Cybertrain::CLI::TestCommand.refusal(APP)
end

test "an application without test files has 0 tests and runs no step" do
  empty = "#{ROOT}/empty"
  write("#{empty}/spin.toml", "[package]\nname = \"empty\"\n")
  runner = StubRunner.new(true, 0)
  assert_equal 0, Cybertrain::CLI::TestCommand.run(empty, Array.new(0) { "" }, runner)
  assert_equal ["0 tests, 0 assertions, 0 failures"], runner.said
  assert_equal [], runner.steps
end

test "stale? after an edit to a test, a model, a fixture or the framework, not after a run" do
  binary = "#{APP}/build/test/tests"
  rm_tree(binary)
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  ["test/models/article_test.rb", "app/models/article.rb", "test/fixtures/articles.yml"].each do |rel|
    build_binary
    refute Cybertrain::CLI::TestCommand.stale?(APP, binary)
    touch_later("#{APP}/#{rel}")
    assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  end
  ["#{FRAMEWORK}/cybertrain/core.rb", "#{FRAMEWORK}/cybertrain.rb"].each do |path|
    build_binary
    refute Cybertrain::CLI::TestCommand.stale?(APP, binary)
    touch_later(path)
    assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  end
  # What a run writes is no input: the database, logs, scratch files, the
  # binary's own directory, a release.
  build_binary
  sleep 0.02
  write("#{APP}/storage/test.sqlite3", "db")
  write("#{APP}/tmp/cache.rb", "x")
  write("#{APP}/build/test/other.rb", "x")
  write("#{APP}/dist/x.rb", "x")
  write("#{APP}/.github/workflows/ci.yml", "x")
  write("#{APP}/app/assets/application.css", "x")
  refute Cybertrain::CLI::TestCommand.stale?(APP, binary)
end

test "stale? when the record of the binary's inputs is missing or differs" do
  binary = "#{APP}/build/test/tests"
  record = "#{binary}.inputs"
  build_binary
  refute Cybertrain::CLI::TestCommand.stale?(APP, binary)
  File.delete(record)
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  write(record, "#{record_now}x\n")
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)

  # A file under test/ that a test requires, deleted: no mtime is newer,
  # the record's list of test/**/*.rb differs.
  write("#{APP}/test/lib/shared.rb", "SHARED = 1\n")
  build_binary
  refute Cybertrain::CLI::TestCommand.stale?(APP, binary)
  File.delete("#{APP}/test/lib/shared.rb")
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  Dir.rmdir("#{APP}/test/lib")

  # Files older than the binary that change what it is built from: a
  # dependency pointed elsewhere (spin.toml, spin.lock), another framework
  # version, another framework checkout.
  build_binary
  toml = File.read("#{APP}/spin.toml")
  File.write("#{APP}/spin.toml", "#{toml}# repointed\n")
  File.utime(Time.at(0), Time.at(0), "#{APP}/spin.toml")
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  File.write("#{APP}/spin.toml", toml)
  refute Cybertrain::CLI::TestCommand.stale?(APP, binary)
  write("#{APP}/spin.lock", "[lock.cybertrain]\nref = \"abc\"\n")
  File.utime(Time.at(0), Time.at(0), "#{APP}/spin.lock")
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  File.delete("#{APP}/spin.lock")
  write("#{FRAMEWORK}/cybertrain/version.rb", "VERSION = \"0.0.2\"\n")
  File.utime(Time.at(0), Time.at(0), "#{FRAMEWORK}/cybertrain/version.rb")
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  build_binary
  refute Cybertrain::CLI::TestCommand.stale?(APP, binary)
  other = "#{ROOT}/framework2"
  write("#{other}/spin.toml", "[package]\nname = \"cybertrain\"\nversion = \"0.0.1\"\n")
  write("#{other}/cybertrain.rb", "")
  File.write("#{APP}/spin.toml", toml.sub("../framework", "../framework2"))
  File.utime(Time.at(0), Time.at(0), "#{APP}/spin.toml")
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
  File.write("#{APP}/spin.toml", toml)
end

test "stale? after a source edited while the binary compiled" do
  binary = "#{APP}/build/test/tests"
  # The record is written when the compile starts, the binary at its end.
  write("#{binary}.inputs", record_now)
  touch_later("#{APP}/app/models/article.rb")
  sleep 0.02
  write(binary, "binary\n")
  assert Cybertrain::CLI::TestCommand.stale?(APP, binary)
end

test "the framework roots are the -I directories of spin flags other than the application" do
  flags = "--strict-require -I /src/cybertrain -I #{APP} -I /src/other\n"
  assert_equal ["/src/cybertrain", "/src/other"], Cybertrain::CLI::TestCommand.framework_roots(APP, flags)
  # spin prints real paths (on macOS the temporary directory is under the
  # /var symlink).
  assert_equal [File.realpath(FRAMEWORK)], Cybertrain::CLI::TestCommand.framework_roots(APP, `cd #{APP} && spin flags`)
end

# LINK is a symlink to ROOT: LINK/app is the application spelled through it,
# as /var/... is /private/var/... on macOS.
LINK = "#{ROOT}/link"
system("ln -s #{ROOT} #{LINK}")

test "a path through a symlink means the same as its real spelling" do
  assert File.directory?("#{LINK}/app/test")
  real_model = "#{File.realpath(APP)}/test/models/article_test.rb"
  # Only the argument through the link, from the application's directory.
  Dir.chdir(APP)
  runner = StubRunner.new(false, 0)
  assert_equal 0, Cybertrain::CLI::TestCommand.run(".", ["#{LINK}/app/test/models/article_test.rb"], runner)
  assert_equal [], runner.said
  # Only the root through the link.
  runner = StubRunner.new(false, 0)
  assert_equal 0, Cybertrain::CLI::TestCommand.run("#{LINK}/app", [real_model], runner)
  assert_equal [], runner.said
  # Both, a directory.
  runner = StubRunner.new(false, 0)
  assert_equal 0, Cybertrain::CLI::TestCommand.run("#{LINK}/app", ["#{LINK}/app/test/models/"], runner)
  assert_equal [], runner.said
  # The bundle's parser (root Dir.pwd) agrees.
  assert_equal ["test/models/article_test.rb"], Cybertrain::Test::Args.parse(["#{LINK}/app/test/models/article_test.rb"], files, APP).arg_files
  assert_equal ["test/models/article_test.rb"], Cybertrain::Test::Args.parse([real_model], files, "#{LINK}/app").arg_files
  # A path that does not exist keeps the spelling typed.
  assert_equal "no test file at #{LINK}/app/test/modles", Cybertrain::Test::Args.parse(["#{LINK}/app/test/modles"], files, APP).arg_error
  # The application's own -I is not a framework root, whichever spelling.
  assert_equal [File.realpath(FRAMEWORK)], Cybertrain::CLI::TestCommand.framework_roots("#{LINK}/app", `cd #{LINK}/app && spin flags`)
  assert_equal [File.realpath(FRAMEWORK)], Cybertrain::CLI::TestCommand.framework_roots("#{LINK}/app", "-I #{LINK}/framework -I #{APP}")
  Dir.chdir(ROOT)
end

test "the compile command" do
  assert_equal "spinel gen/tests.rb $(spin flags) -I gen/test -I test -o build/test/tests",
               Cybertrain::CLI::TestCommand.compile_command(APP)
end

test "the run passes each argument as one word and answers the binary's status" do
  write("#{APP}/build/test/tests", "#!/bin/sh\nprintf '%s|' \"$@\" > args.txt\nexit 3\n")
  File.chmod(0o755, "#{APP}/build/test/tests")
  argv = ["test/models", "-n", "it's a \"name\" $HOME"]
  assert_equal 3, Cybertrain::CLI::TestCommand::Runner.new.run_tests(APP, argv)
  assert_equal "test/models|-n|it's a \"name\" $HOME|", File.read("#{APP}/args.txt")
end

test "cybertrain test outside an application" do
  Dir.chdir(ROOT)
  assert_equal 1, Cybertrain::CLI.run(["test"])
end

Cybertrain::Test.run!
