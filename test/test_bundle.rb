# The bundle's runner and boot (spec section 8, plan decisions 5, 10, 11
# and 19): Cybertrain::Test::Bundle.run! over a hand-written table in the
# shape gen/tests.rb hands over (two class-form classes and two
# top-level-form files), with its output captured; and Bundle.boot's
# refusal of a database that is not the test one. Application#boot links
# SQLite through FFI, so this runs compiled only (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/test_help"
require "cybertrain/test/bundle"

# One migration, as gen/migrations.rb registers them: boot migrates it
# quietly (no progress lines in the output).
class CreateNotes < Cybertrain::Migration::Base
  def change
    create_table "notes" do |t|
      t.string "title"
    end
  end
end
Cybertrain::Migration.register("20261112000000", CreateNotes.new)

OLD_RUNS = [0]
ZONES_SEEN = Array.new(0) { "" }

# The classes as gen's rewrite writes them (each method ends in nil).
class ArticleTest < ActiveSupport::TestCase
  def test_title_must_be_present
    begin
      assert true
    end
    nil
  end

  def test_counts
    begin
      assert_equal 1, 0
    end
    nil
  end
end

class FailingSetupTest < ActiveSupport::TestCase
  def setup
    begin
      super
      raise "boom"
    end
    nil
  end

  def test_never_runs
    begin
      flunk("the body ran")
    end
    nil
  end
end

class ZoneTest < ActiveSupport::TestCase
  def test_moves_the_zone
    begin
      Cybertrain::Clock.zone = Cybertrain::TimeZone.find("America/New_York")
    end
    nil
  end

  def test_reads_the_zone
    begin
      ZONES_SEEN << Cybertrain::Clock.zone.zone_name
    end
    nil
  end
end

# gen's Gen::Tests table and run_case, written by hand.
FILES = ["test/models/article_test.rb", "test/legacy.rb"].freeze
CASE_FILE = ["test/models/article_test.rb", "test/models/article_test.rb", "test/failing_test.rb", "test/zone_test.rb", "test/zone_test.rb"].freeze
CASE_LINE = [4, 9, 6, 2, 6].freeze
CASE_CLASS = %w[ArticleTest ArticleTest FailingSetupTest ZoneTest ZoneTest].freeze
CASE_NAME = ["title must be present", "counts", "never runs", "moves the zone", "reads the zone"].freeze
CASE_METHOD = %w[test_title_must_be_present test_counts test_never_runs test_moves_the_zone test_reads_the_zone].freeze

def run_bundle_case(i)
  case i
  when 0
    t = ArticleTest.new
    if Cybertrain::Test.before_case(t)
      Cybertrain::Test.run_body(t) { t.test_title_must_be_present }
    end
    Cybertrain::Test.after_case(t)
  when 1
    t = ArticleTest.new
    if Cybertrain::Test.before_case(t)
      Cybertrain::Test.run_body(t) { t.test_counts }
    end
    Cybertrain::Test.after_case(t)
  when 2
    t = FailingSetupTest.new
    if Cybertrain::Test.before_case(t)
      Cybertrain::Test.run_body(t) { t.test_never_runs }
    end
    Cybertrain::Test.after_case(t)
  when 3
    t = ZoneTest.new
    if Cybertrain::Test.before_case(t)
      Cybertrain::Test.run_body(t) { t.test_moves_the_zone }
    end
    Cybertrain::Test.after_case(t)
  when 4
    t = ZoneTest.new
    if Cybertrain::Test.before_case(t)
      Cybertrain::Test.run_body(t) { t.test_reads_the_zone }
    end
    Cybertrain::Test.after_case(t)
  end
  nil
end

def bundle_dispatch = ->(i) { run_bundle_case(i) }

def use_files(files)
  Cybertrain::Test::Bundle.use_table(files, CASE_FILE, CASE_LINE, CASE_CLASS, CASE_NAME, CASE_METHOD)
end

# Bundle.run! over files with argv: its lines, then "exit <status>".
def bundle_lines(files, argv)
  use_files(files)
  Cybertrain::Test::Bundle.capture_output(true)
  status = Cybertrain::Test::Bundle.run!(argv, bundle_dispatch)
  Cybertrain::Test::Bundle.capture_output(false)
  out = Array.new(0) { "" }
  Cybertrain::Test::Bundle.captured_output.each { |line| out << line }
  out << "exit #{status}"
  out
end

def bundle_run(argv)
  bundle_lines(FILES, argv)
end

# ---- boot ----

def bundle_config(env, path)
  c = Cybertrain::Config.new
  c.env = env
  c.database_path = path
  c.secret_key_base = "test-bundle-secret"
  c.views_root = "tmp/test_bundle/views"
  c.public_root = "tmp/test_bundle/public"
  c.log_level = :none
  Cybertrain.config = c
  c
end

def bundle_boot
  Cybertrain::Test::Bundle.boot(Cybertrain::Router.new, ->(name, args, options) { "/" })
end

def boot_refusal
  bundle_boot
  ""
rescue ArgumentError => e
  e.message
end

def make_dir(dir)
  Dir.mkdir(dir) unless File.directory?(dir)
  nil
end

def sqlite_file?(path)
  File.exist?(path) && File.read(path).start_with?("SQLite format 3")
end

test "the output has headings, file:line on failures and pluralised totals" do
  expected = ["test/models/article_test.rb",
              "  ok   ArticleTest: title must be present",
              "  FAIL ArticleTest: counts (test/models/article_test.rb:9)",
              "         Expected: 1",
              "           Actual: 0",
              "test/legacy.rb",
              "  ok   old style",
              "",
              "3 tests, 3 assertions, 1 failure",
              "exit 1"]
  assert_equal expected, bundle_run([])
end

test "-n exact name, method name and /text/ keep only those tests" do
  counts = ["test/models/article_test.rb",
            "  FAIL ArticleTest: counts (test/models/article_test.rb:9)",
            "         Expected: 1",
            "           Actual: 0",
            "",
            "1 test, 1 assertion, 1 failure",
            "exit 1"]
  assert_equal counts, bundle_run(["-n", "counts"])
  assert_equal counts, bundle_run(["-n", "test_counts"])
  assert_equal counts, bundle_run(["-n", "/count/"])
  old = ["test/legacy.rb", "  ok   old style", "", "1 test, 1 assertion, 0 failures", "exit 0"]
  assert_equal old, bundle_run(["-n", "test_old_style"])
  assert_equal old, bundle_run(["-n", "/old_st/"])
  # A later -n replaces an earlier one.
  assert_equal old, bundle_run(["-n", "/t/", "-n", "/old/"])
  assert_equal "3 tests, 3 assertions, 1 failure", bundle_run(["-n", "/t/"])[-2]
end

test "a file filter and -n combine" do
  assert_equal "1 test, 1 assertion, 0 failures", bundle_run(["test/legacy.rb", "-n", "old style"])[-2]
  assert_equal ["", "0 tests, 0 assertions, 0 failures", "exit 0"], bundle_run(["test/legacy.rb", "-n", "counts"])
  assert_equal "2 tests, 2 assertions, 1 failure", bundle_run(["./test/models/article_test.rb"])[-2]
  assert_equal "2 tests, 2 assertions, 1 failure", bundle_run(["test/models"])[-2]
  assert_equal "3 tests, 3 assertions, 1 failure", bundle_run(["test/", "test/legacy.rb"])[-2]
end

test "0 tests is not a failure" do
  assert_equal ["", "0 tests, 0 assertions, 0 failures", "exit 0"], bundle_run(["-n", "nothing"])
end

test "bad arguments print the usage and the reason, run nothing and answer 2" do
  before = OLD_RUNS[0]
  usage = Cybertrain::Test::Args::USAGE
  assert_equal [usage, "unknown option --seed", "exit 2"], bundle_run(["--seed", "1"])
  assert_equal [usage, "-n needs a name or /text/", "exit 2"], bundle_run(["-n"])
  assert_equal [usage, "no test file at test/modles", "exit 2"], bundle_run(["test/modles"])
  assert_equal before, OLD_RUNS[0]
end

test "an error outside the body names the step, and a computed name has no line" do
  lines = bundle_lines(["test/failing_test.rb", "test/computed.rb"], [])
  expected = ["test/failing_test.rb",
              "  ERR  FailingSetupTest: never runs (test/failing_test.rb:6)",
              "         in setup: RuntimeError: boom",
              "test/computed.rb",
              "  ERR  computed 2 (test/computed.rb)",
              "         ArgumentError: no line",
              "",
              "2 tests, 0 assertions, 2 failures",
              "exit 1"]
  assert_equal expected, lines
end

test "Cybertrain::Test.run! does nothing inside the bundle" do
  before = OLD_RUNS[0]
  refute Cybertrain::Test.bundled?
  Cybertrain::Test.bundled!
  assert Cybertrain::Test.bundled?
  Cybertrain::Test.run!
  # The registered case did not run; the bundle runs it exactly once.
  assert_equal before, OLD_RUNS[0]
  assert_equal "exit 0", bundle_run(["test/legacy.rb"])[-1]
  assert_equal before + 1, OLD_RUNS[0]
  Cybertrain::Test.bundled = false
end

test "boot refuses a database that is not the test one" do
  make_dir("storage")
  path = "storage/development.sqlite3"
  existed = File.exist?(path)
  File.write(path, "keep me") unless existed
  bytes = File.read(path)
  bundle_config("development", path)
  assert_equal "cybertrain test refuses to delete storage/development.sqlite3: not a test database (env development)", boot_refusal
  assert_equal bytes, File.read(path)
  bundle_config("test", path)
  assert_equal "cybertrain test refuses to delete storage/development.sqlite3: not a test database (env test)", boot_refusal
  assert_equal bytes, File.read(path)
  bundle_config("development", "storage/test.sqlite3")
  assert_equal "cybertrain test refuses to delete storage/test.sqlite3: not a test database (env development)", boot_refusal
  File.delete(path) unless existed
  Dir.rmdir("storage") if Dir.children("storage").empty?
  refute Cybertrain::DB.connected?
end

test "CYBERTRAIN_TEST_DATABASE is honoured" do
  make_dir("tmp")
  make_dir("tmp/test_bundle")
  named = "tmp/test_bundle/named.sqlite3"
  other = "tmp/test_bundle/other.sqlite3"
  ENV["CYBERTRAIN_TEST_DATABASE"] = named
  File.write(named, "not a database yet")
  File.write("#{named}-wal", "stale")
  File.write(other, "keep me")
  # Another path than the one named is still refused.
  bundle_config("test", other)
  assert_equal "cybertrain test refuses to delete #{other}: not a test database (env test)", boot_refusal
  assert_equal "keep me", File.read(other)
  c = bundle_config("test", named)
  app = bundle_boot
  assert sqlite_file?(named)
  tables = Cybertrain::DB.with { |conn| conn.execute("SELECT name FROM sqlite_master WHERE name = 'notes'") }
  assert_equal 1, tables.length
  refute File.exist?("#{named}-wal") && File.read("#{named}-wal") == "stale"
  assert app.booted?
  assert Cybertrain::Test.app.booted?
  # Forgery protection is off for the bundle's tests (Rails' test default).
  refute c.csrf
  app.shutdown
  Cybertrain::Runtime.reset!
  # ... unless config/app.rb set it.
  c = bundle_config("test", named)
  c.csrf = true
  app = bundle_boot
  assert c.csrf
  app.shutdown
  Cybertrain::Runtime.reset!
  ENV.delete("CYBERTRAIN_TEST_DATABASE")
end

test "every test starts in the configured time zone" do
  ENV["CYBERTRAIN_TEST_DATABASE"] = "tmp/test_bundle/zone.sqlite3"
  c = bundle_config("test", "tmp/test_bundle/zone.sqlite3")
  c.time_zone = "Asia/Tokyo"
  app = bundle_boot
  ZONES_SEEN.clear
  assert_equal "exit 0", bundle_lines(["test/zone_test.rb"], [])[-1]
  assert_equal ["Asia/Tokyo"], ZONES_SEEN
  app.shutdown
  Cybertrain::Runtime.reset!
  ENV.delete("CYBERTRAIN_TEST_DATABASE")
end

# The top-level-form files, as gen/tests.rb begins and requires them (the
# cases they register belong to the bundle: run! below leaves them alone).
Cybertrain::Test.begin_file("test/legacy.rb", ["old style"], [3])

test "old style" do
  OLD_RUNS[0] += 1
  assert true
end

Cybertrain::Test.begin_file("test/computed.rb", Array.new(0) { "" }, Array.new(0) { 0 })

test "computed #{1 + 1}" do
  raise ArgumentError, "no line"
end

Cybertrain::Test.run!
