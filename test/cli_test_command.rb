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
  if File.directory?(path)
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

def build_binary
  write("#{APP}/build/test/tests", "binary\n")
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
  assert_equal ["ready", "spin run gen", "stale?", "spinel gen/tests.rb $(spin flags) -I gen/test -I test -o build/test/tests",
                "run test/models -n /title/"], runner.steps
  assert File.directory?("#{APP}/build/test")
  assert_equal [], runner.said
end

test "no compile when nothing is newer than the binary" do
  runner = StubRunner.new(false, 0)
  assert_equal 0, Cybertrain::CLI::TestCommand.run(APP, ["-n", "test_a"], runner)
  assert_equal ["ready", "spin run gen", "stale?", "run -n test_a"], runner.steps
end

test "gen's refusal is printed and exits 1 without a compile or a run" do
  reason = "test/b.rb:3: new_client is also defined at test/a.rb:5; move shared helpers to test/support/ or into a test class"
  write("#{APP}/gen/tests.rb", "# gen/tests.rb: a header\n# Do not edit.\nabort(\"#{reason}\")\n")
  assert_equal reason, Cybertrain::CLI::TestCommand.refusal(APP)
  runner = StubRunner.new(true, 0)
  assert_equal 1, Cybertrain::CLI::TestCommand.run(APP, Array.new(0) { "" }, runner)
  assert_equal ["ready", "spin run gen"], runner.steps
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

test "the framework roots are the -I directories of spin flags other than the application" do
  flags = "--strict-require -I /src/cybertrain -I #{APP} -I /src/other\n"
  assert_equal ["/src/cybertrain", "/src/other"], Cybertrain::CLI::TestCommand.framework_roots(APP, flags)
  assert_equal [FRAMEWORK], Cybertrain::CLI::TestCommand.framework_roots(APP, `cd #{APP} && spin flags`)
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
