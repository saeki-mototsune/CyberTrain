require "tmpdir"
require "cybertrain/test"
require "cybertrain/cli"
require_relative "support/file_tree"

# build/bin/gen and build/bin/db reused while what they are compiled from
# is unchanged (Cybertrain::CLI::ToolBinary, docs/design.md D12): how a
# line's require is read, the files a program reaches, when a binary is
# fresh, what a build records, and the steps of `cybertrain db`. Nothing
# is compiled: a stand-in runner writes the binary. CRuby-portable; the
# freshness tests call `spin flags`, so spin must be on PATH.

REPO = File.expand_path("..", __dir__)
ROOT = Dir.mktmpdir("cybertrain-cli-tool-binary")
APP = "#{ROOT}/app"
FRAMEWORK = "#{ROOT}/framework"

at_exit do
  Dir.chdir("/")
  FileTree.remove(ROOT)
end

def write(path, text)
  Cybertrain::CLI::Templates.mkdir_p(File.dirname(path))
  File.write(path, text)
end

# A framework stand-in (a package spin resolves by path) and an application
# depending on it, as `cybertrain new` and a scaffold leave one.
write("#{FRAMEWORK}/spin.toml", "[package]\nname = \"cybertrain\"\nversion = \"0.0.1\"\n")
write("#{FRAMEWORK}/cybertrain/core.rb", "require \"json\"\nrequire \"cybertrain/db\"\nmodule Cybertrain\nend\n")
write("#{FRAMEWORK}/cybertrain/db.rb", "module Cybertrain\nend\n")
write("#{FRAMEWORK}/cybertrain/migration.rb", "module Cybertrain\nend\n")
write("#{FRAMEWORK}/cybertrain/generator.rb", "module Cybertrain\nend\n")
write("#{APP}/spin.toml", "[package]\nname = \"shop\"\nversion = \"0.1.0\"\n\n[dependencies]\ncybertrain = { path = \"../framework\" }\n")
write("#{APP}/bin/db.rb", "require \"cybertrain/core\"\nrequire_relative \"../config/app\"\nrequire_relative \"../gen/migrations\"\n")
write("#{APP}/bin/gen.rb", "require \"cybertrain/generator\"\nrequire_relative \"../config/routes\"\nrequire_relative \"../db/schema\"\n")
write("#{APP}/config/app.rb", "# settings\n")
write("#{APP}/config/routes.rb", "# routes\n")
write("#{APP}/db/schema.rb", "# schema 1\n")
write("#{APP}/db/migrate/1_create_articles.rb", "# migration\n")
write("#{APP}/gen/migrations.rb", "require \"cybertrain/migration\"\nrequire_relative \"../db/migrate/1_create_articles\"\n")
write("#{APP}/app/models/article.rb", "class Article\nend\n")

TOOL = Cybertrain::CLI::ToolBinary

# Stands in for spin and the tools: records each step, and the build step
# writes the binary (`built` says whether one was on disk when it began);
# `edit` is a file written while the build runs. `fresh` is "" for the real
# answer, else "yes" or "no".
class StubRunner < Cybertrain::CLI::Build::Runner
  attr_reader :steps, :had_binary
  attr_accessor :fail_build, :edit, :fresh

  def initialize
    @steps = Array.new(0) { "" }
    @had_binary = false
    @fail_build = false
    @edit = ""
    @fresh = ""
  end

  def run_step(root, command)
    @steps << command
    ["gen", "db"].each do |tool|
      next unless command == "SPIN_DEBUG=1 spin build #{tool}"

      binary = "#{root}/build/bin/#{tool}"
      @had_binary = File.exist?(binary)
      return false if @fail_build

      unless @edit.empty?
        sleep 0.02
        File.write(@edit, File.read(@edit))
      end
      Cybertrain::CLI::Templates.mkdir_p("#{root}/build/bin")
      File.write(binary, "binary")
    end
    true
  end

  def tool_fresh?(root, tool)
    @steps << "fresh? #{tool}"
    return @fresh == "yes" unless @fresh.empty?

    Cybertrain::CLI::ToolBinary.fresh?(root, tool)
  end
end

# Waits past the filesystem's mtime granularity, then writes: the file is
# newer than anything written before.
def touch_later(path)
  sleep 0.02
  File.write(path, File.read(path))
end

def write_later(path, text)
  sleep 0.02
  write(path, text)
end

def build(tool)
  runner = StubRunner.new
  assert TOOL.build(APP, tool, runner)
  runner
end

# Each path from its last "/<top>/" on, sorted: the scratch tree's own
# spelling, whatever the temporary directory resolves to.
def under(top, files)
  out = Array.new(0) { "" }
  files.each do |path|
    at = path.rindex("/#{top}/")
    out << (at.nil? ? path : path[at + 1, path.size - at - 1].to_s)
  end
  out.sort
end

test "a require is followed when it is one plain string literal at the start of a line" do
  {
    "require \"cybertrain/core\"" => "Rcybertrain/core",
    "require 'json'" => "Rjson",
    "  require(\"a/b\")  " => "Ra/b",
    "require( 'a' )" => "Ra",
    "require_relative \"../config/app\"" => "L../config/app",
    "\trequire_relative('x.rb') # why\r" => "Lx.rb",
    "require \"a\" # require \"b\"" => "Ra",
    # A modifier is taken as true: one file too many is the safe side.
    "require \"a\" if RUBY_ENGINE == \"ruby\"" => "Ra",
    "require_relative \"a\" unless defined?(A)" => "La"
  }.each do |line, expected|
    assert_equal [line, expected], [line, TOOL.requirement(line)]
  end
end

test "a require that is not a plain literal is not known" do
  [
    "require File.join(__dir__, \"..\", \"app\", \"routes\", \"x\")",
    "require name",
    "require \"cybertrain/\#{name}\"",
    "require \"a\\nb\"",
    "require \"\"",
    "require \"a\" + suffix",
    "require \"a\"; require \"b\"",
    "require \"a\" if x; require \"b\"",
    "require \"a\" and other",
    "require(\"a\"",
    "require \"a",
    "require_relative select sleep",
    "x = 1; require \"b\"",
    "begin require \"b\" rescue nil end",
    "ok = require \"b\"",
    "Kernel.require \"b\"",
    "Kernel::require \"b\"",
    "x ? 1 : require(\"b\")",
    "puts(\"a\") && require_relative(\"b\")",
    # A quote left open with the word inside: not read as Ruby reads it.
    "x = /\"/; require \"b\""
  ].each do |line|
    assert_equal [line, "?"], [line, TOOL.requirement(line)]
  end
end

test "the word where it cannot be Kernel's require is nothing" do
  [
    "",
    "   ",
    "# require \"a\"",
    "x = 1 # require y",
    "puts \"add require \\\"\#{line}\\\" to bin/\#{name}.rb\"",
    "out << \"require \\\"cybertrain/assets\\\"\\n\\n\"",
    "raise Error, 'no inflater (require the gzip support)'",
    "return \"\" unless line.start_with?(\"require\")",
    "`require x`",
    "def require(key)",
    "  def self.require(key)",
    "params.require(:article).permit(:title)",
    "params&.require(:article)",
    "x = { require: true }",
    "require: true,",
    "send(:require, 1)",
    "list = %w[load open require",
    "require",
    "requires \"a\"",
    "required = true",
    "require_relatives x",
    "@require = 1",
    "$require = 1",
    "require? x",
    "undef_require \"a\"",
    "load \"b.rb\""
  ].each do |line|
    assert_equal [line, ""], [line, TOOL.requirement(line)]
  end
end

test "sources are the entry and what its requires reach, in every load path directory" do
  flags = TOOL.spin_flags_in(APP)
  assert_equal ["app", "framework"], TOOL.load_path(APP, flags).map { |dir| File.basename(dir) }.sort
  db = TOOL.sources_of(APP, "db", flags)
  assert db.known?
  assert_equal "", db.problem
  assert_equal "#{APP}/bin/db.rb", db.files[0]
  # json is the toolchain's: no file of a load path directory.
  assert_equal ["app/bin/db.rb", "app/config/app.rb", "app/db/migrate/1_create_articles.rb", "app/gen/migrations.rb"],
               under("app", db.files.select { |path| path.include?("/app/") })
  assert_equal ["framework/cybertrain/core.rb", "framework/cybertrain/db.rb", "framework/cybertrain/migration.rb"],
               under("framework", db.files.select { |path| path.include?("/framework/") })
  # db/schema.rb, which the migrator writes, is compiled into gen and not into db.
  gen = TOOL.sources_of(APP, "gen", flags)
  assert_equal ["app/bin/gen.rb", "app/config/routes.rb", "app/db/schema.rb"],
               under("app", gen.files.select { |path| path.include?("/app/") })
  assert_equal ["framework/cybertrain/generator.rb"], under("framework", gen.files.select { |path| path.include?("/framework/") })

  # A name two directories have counts in both; a file required twice, once.
  write("#{ROOT}/two/a/x.rb", "")
  write("#{ROOT}/two/b/x.rb", "require \"x\"\nrequire_relative \"x\"\n")
  write("#{ROOT}/two/main.rb", "require \"x\"\nrequire \"missing\"\nrequire_relative \"gone\"\n__END__\nrequire name\n")
  found = TOOL.sources("#{ROOT}/two/main.rb", ["#{ROOT}/two/a", "#{ROOT}/two/b"])
  assert found.known?
  assert_equal ["two/a/x.rb", "two/b/x.rb", "two/main.rb"], under("two", found.files)
end

test "sources are not known past a require that cannot be followed, a missing entry or a path outside the load path" do
  write("#{ROOT}/odd/main.rb", "require_relative \"a\"\n")
  write("#{ROOT}/odd/a.rb", "# one\n\nrequire File.join(__dir__, \"b\")\n")
  found = TOOL.sources("#{ROOT}/odd/main.rb", ["#{ROOT}/odd"])
  refute found.known?
  assert_equal "#{ROOT}/odd/a.rb:3: a require this check cannot follow", found.problem
  refute TOOL.sources("#{ROOT}/odd/none.rb", ["#{ROOT}/odd"]).known?
  write("#{ROOT}/odd/abs.rb", "require \"/etc/x\"\n")
  refute TOOL.sources("#{ROOT}/odd/abs.rb", ["#{ROOT}/odd"]).known?
  write("#{ROOT}/odd/dot.rb", "require \"./a\"\n")
  refute TOOL.sources("#{ROOT}/odd/dot.rb", ["#{ROOT}/odd"]).known?
end

test "the framework's gen and db programs are ones whose sources are known" do
  # What `cybertrain new` writes in bin/gen.rb and bin/db.rb, against this
  # checkout: a line of the framework that the check cannot follow would
  # cost every application the reuse.
  write("#{ROOT}/real/bin/gen.rb", "require \"cybertrain/generator\"\n")
  write("#{ROOT}/real/bin/db.rb", "require \"cybertrain\"\n")
  ["gen", "db"].each do |tool|
    found = TOOL.sources("#{ROOT}/real/bin/#{tool}.rb", [REPO])
    assert_equal "", found.problem
    assert found.files.size > 20, "#{tool}: #{found.files.size} files"
  end
end

test "a tool is fresh after its build until a file it is compiled from changes" do
  FileTree.remove("#{APP}/build")
  refute TOOL.fresh?(APP, "db")
  runner = build("db")
  assert_equal ["SPIN_DEBUG=1 spin build db"], runner.steps
  assert File.file?("#{APP}/build/bin/db.inputs")
  refute File.exist?("#{APP}/build/bin/db.inputs.tmp")
  assert TOOL.fresh?(APP, "db")
  refute TOOL.fresh?(APP, "gen")

  # What `cybertrain db migrate` writes after db is built: the schema, the
  # models, the test bundle. None is compiled into db.
  write_later("#{APP}/db/schema.rb", "# schema 2\n")
  write("#{APP}/gen/models/article.rb", "class Article\nend\n")
  write("#{APP}/gen/tests.rb", "# tests\n")
  write("#{APP}/gen/app.rb", "require_relative \"models/article\"\n")
  touch_later("#{APP}/app/models/article.rb")
  touch_later("#{APP}/bin/gen.rb")
  touch_later("#{FRAMEWORK}/cybertrain/generator.rb")
  write("#{APP}/storage/development.sqlite3", "db")
  assert TOOL.fresh?(APP, "db")

  # Each file db is compiled from, the application's and the framework's.
  ["#{APP}/bin/db.rb", "#{APP}/config/app.rb", "#{APP}/gen/migrations.rb", "#{APP}/db/migrate/1_create_articles.rb",
   "#{FRAMEWORK}/cybertrain/core.rb", "#{FRAMEWORK}/cybertrain/db.rb", "#{FRAMEWORK}/cybertrain/migration.rb"].each do |path|
    build("db")
    assert TOOL.fresh?(APP, "db"), path
    touch_later(path)
    refute TOOL.fresh?(APP, "db"), path
  end
  build("db")
  assert TOOL.fresh?(APP, "db")
end

test "gen is stale after a migration changed the schema, not after its own output" do
  build("gen")
  assert TOOL.fresh?(APP, "gen")
  write_later("#{APP}/gen/routes.rb", "# routes\n")
  write("#{APP}/gen/models/article.rb", "class Article\n  # again\nend\n")
  touch_later("#{APP}/bin/db.rb")
  assert TOOL.fresh?(APP, "gen")
  write_later("#{APP}/db/schema.rb", "# schema 3\n")
  refute TOOL.fresh?(APP, "gen")
  build("gen")
  assert TOOL.fresh?(APP, "gen")
  touch_later("#{APP}/config/routes.rb")
  refute TOOL.fresh?(APP, "gen")
end

test "a tool is stale when its record is missing or differs from what it would be built from now" do
  build("db")
  record = "#{APP}/build/bin/db.inputs"
  kept = File.read(record)
  assert_equal kept, TOOL.inputs_record(APP, "db", TOOL.spin_flags_in(APP), TOOL.sources_of(APP, "db", TOOL.spin_flags_in(APP)).files)
  assert kept.start_with?("build: SPIN_DEBUG=1 spin build db\nflags: ")
  assert_includes kept, "\nspin.toml:\n[package]\nname = \"shop\"\n"
  assert_includes kept, "\nspin.lock:\n"
  assert_includes kept, "\nsources:\n"

  # A new migration: gen/migrations.rb changes, and the list with it.
  write("#{APP}/db/migrate/2_add_body.rb", "# migration\n")
  assert_equal kept, TOOL.record_text(APP, "db")
  assert TOOL.fresh?(APP, "db")
  write_later("#{APP}/gen/migrations.rb", "require \"cybertrain/migration\"\nrequire_relative \"../db/migrate/1_create_articles\"\nrequire_relative \"../db/migrate/2_add_body\"\n")
  refute TOOL.fresh?(APP, "db")
  refute kept == TOOL.record_text(APP, "db")
  assert_includes TOOL.record_text(APP, "db"), "/db/migrate/2_add_body.rb\n"
  build("db")
  assert TOOL.fresh?(APP, "db")

  # A file a require names appears: the list differs, whatever its time.
  kept = File.read(record)
  write("#{FRAMEWORK}/json.rb", "# shadows the toolchain's\n")
  refute kept == TOOL.record_text(APP, "db")
  refute TOOL.fresh?(APP, "db")
  File.delete("#{FRAMEWORK}/json.rb")
  assert TOOL.fresh?(APP, "db")

  # spin.toml, as it is: a repointed dependency or another allocator.
  toml = File.read("#{APP}/spin.toml")
  File.write("#{APP}/spin.toml", "#{toml}# allocator = \"jemalloc\"\n")
  refute TOOL.fresh?(APP, "db")
  File.write("#{APP}/spin.toml", toml)
  assert TOOL.fresh?(APP, "db")

  # The record or the binary gone, or a record of another build.
  File.write(record, "build: spin build db\n")
  refute TOOL.fresh?(APP, "db")
  File.delete(record)
  refute TOOL.fresh?(APP, "db")
  build("db")
  File.delete("#{APP}/build/bin/db")
  refute TOOL.fresh?(APP, "db")
  build("db")
  assert TOOL.fresh?(APP, "db")
end

test "a build whose record no longer holds starts without the binary; a first build keeps what spin has" do
  FileTree.remove("#{APP}/build")
  write("#{APP}/build/bin/db", "built by hand")
  # No record: nothing says the binary is wrong, and spin decides.
  runner = build("db")
  assert runner.had_binary
  # A record and a changed source: spin would reuse a binary newer than
  # the edit (one the source was edited under), so the binary goes first.
  touch_later("#{APP}/config/app.rb")
  runner = build("db")
  refute runner.had_binary
  assert TOOL.fresh?(APP, "db")
end

test "a source edited while the tool was built is newer than the record" do
  runner = StubRunner.new
  runner.edit = "#{APP}/config/app.rb"
  assert TOOL.build(APP, "db", runner)
  refute TOOL.fresh?(APP, "db")
  build("db")
  assert TOOL.fresh?(APP, "db")
end

test "a failed build leaves no record, and neither does a program whose sources are not known" do
  build("db")
  touch_later("#{APP}/config/app.rb")
  runner = StubRunner.new
  runner.fail_build = true
  refute TOOL.build(APP, "db", runner)
  refute File.exist?("#{APP}/build/bin/db.inputs")
  refute File.exist?("#{APP}/build/bin/db.inputs.tmp")
  refute TOOL.fresh?(APP, "db")

  config = File.read("#{APP}/config/app.rb")
  File.write("#{APP}/config/app.rb", "require File.join(__dir__, \"extra\")\n")
  assert_equal "", TOOL.record_text(APP, "db")
  runner = build("db")
  assert_equal ["SPIN_DEBUG=1 spin build db"], runner.steps
  refute File.exist?("#{APP}/build/bin/db.inputs")
  refute File.exist?("#{APP}/build/bin/db.inputs.tmp")
  refute TOOL.fresh?(APP, "db")
  # Every run asks spin, which has the last word, as before the check.
  runner = build("db")
  assert runner.had_binary
  File.write("#{APP}/config/app.rb", config)
  build("db")
  assert TOOL.fresh?(APP, "db")
end

test "db commands generate first, and again after migrate and rollback" do
  runner = StubRunner.new
  runner.fresh = "yes"
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["migrate"], runner)
  assert_equal ["fresh? gen", "./build/bin/gen", "fresh? db", "./build/bin/db migrate", "fresh? gen", "./build/bin/gen"], runner.steps
  runner = StubRunner.new
  runner.fresh = "yes"
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["rollback", "2"], runner)
  assert_equal ["fresh? gen", "./build/bin/gen", "fresh? db", "./build/bin/db rollback 2", "fresh? gen", "./build/bin/gen"], runner.steps
  ["status", "schema:dump"].each do |command|
    runner = StubRunner.new
    runner.fresh = "yes"
    assert_equal 0, Cybertrain::CLI::Build.run_db(APP, [command], runner)
    assert_equal ["fresh? gen", "./build/bin/gen", "fresh? db", "./build/bin/db #{command}"], runner.steps
  end
  runner = StubRunner.new
  runner.fresh = "yes"
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["a b", ""], runner)
  assert_equal "./build/bin/db 'a b' ''", runner.steps[3]
end

test "a stale tool is built by spin in debug mode, then run; a failed build stops the command" do
  runner = StubRunner.new
  runner.fresh = "no"
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["status"], runner)
  assert_equal ["fresh? gen", "SPIN_DEBUG=1 spin build gen", "./build/bin/gen",
                "fresh? db", "SPIN_DEBUG=1 spin build db", "./build/bin/db status"], runner.steps
  runner = StubRunner.new
  runner.fresh = "no"
  runner.fail_build = true
  assert_equal 1, Cybertrain::CLI::Build.run_db(APP, ["migrate"], runner)
  assert_equal ["fresh? gen", "SPIN_DEBUG=1 spin build gen"], runner.steps
end

test "db status after db migrate builds nothing when the migration changed only what the tools write" do
  # The whole sequence with the real freshness check: the first command
  # builds both tools; its migration rewrites db/schema.rb (compiled into
  # gen, not into db) and gen then writes gen/**.
  FileTree.remove("#{APP}/build")
  runner = StubRunner.new
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["migrate"], runner)
  assert_equal ["fresh? gen", "SPIN_DEBUG=1 spin build gen", "./build/bin/gen",
                "fresh? db", "SPIN_DEBUG=1 spin build db", "./build/bin/db migrate",
                "fresh? gen", "./build/bin/gen"], runner.steps
  write_later("#{APP}/gen/models/article.rb", "class Article\n  # written by gen\nend\n")
  write("#{APP}/gen/tests.rb", "# tests, again\n")
  runner = StubRunner.new
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["status"], runner)
  assert_equal ["fresh? gen", "./build/bin/gen", "fresh? db", "./build/bin/db status"], runner.steps

  # A migration that changes the schema: gen is built again for the second
  # generation, db is not; the next command builds nothing.
  write_later("#{APP}/db/schema.rb", "# schema 4\n")
  runner = StubRunner.new
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["status"], runner)
  assert_equal ["fresh? gen", "SPIN_DEBUG=1 spin build gen", "./build/bin/gen", "fresh? db", "./build/bin/db status"], runner.steps

  # An edit to what db is compiled from: db is built again, gen is not.
  touch_later("#{APP}/config/app.rb")
  runner = StubRunner.new
  assert_equal 0, Cybertrain::CLI::Build.run_db(APP, ["status"], runner)
  assert_equal ["fresh? gen", "./build/bin/gen", "fresh? db", "SPIN_DEBUG=1 spin build db", "./build/bin/db status"], runner.steps
  refute runner.had_binary
end

Cybertrain::Test.run!
