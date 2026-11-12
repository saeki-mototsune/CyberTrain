# The whole fixture chain in a bundle (spec sections 5.3, 6 and 7): a
# program in gen/tests.rb's shape (Bundle.boot on a new test database,
# Gen::Tests.fixtures_hook registered through before_each_bundled,
# Bundle.run! over a class-form table and a top-level-form file) with
# test/fixtures/gen_app's generated gen/test/data.rb. The first test
# inserts and updates rows; the next one sees exactly the fixture rows,
# with the sequence restarted; posts(:one) answers in both forms. Links
# SQLite through FFI, so this runs compiled only (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/test_help"
require "cybertrain/test/bundle"
require "cybertrain/db/sqlite_ddl"
require_relative "fixtures/gen_app/db/schema"
require_relative "fixtures/gen_app/gen/models/comment"
require_relative "fixtures/gen_app/gen/models/post"
require_relative "fixtures/gen_app/gen/concerns/models/concerns/visible"
require_relative "fixtures/gen_app/app/models/comment"
require_relative "fixtures/gen_app/app/models/post"
require_relative "fixtures/gen_app/gen/test/data"

# The fixture app's tables, migrated by Bundle.boot as gen/migrations.rb
# would register them.
class CreateGenAppTables < Cybertrain::Migration::Base
  def change
    Cybertrain::Schema.current.tables.each { |t| execute(Cybertrain::DB::SqliteDDL.create_table(t)) }
    nil
  end
end
Cybertrain::Migration.register("20261112000001", CreateGenAppTables.new)

SEEN = Array.new(0) { "" }

# The rewritten class form (each method ends in nil).
class PostFixturesTest < ActiveSupport::TestCase
  def test_writes_rows
    begin
      post = posts(:one)
      post.title = "Changed"
      assert post.save
      extra = Post.create(title: "Extra", body: "long enough body")
      SEEN << "extra id #{extra.id}"
      Comment.create(post_id: extra.id, commenter: "Bo", body: "Hi", extras: "{}", seen_on: Date.new(2026, 11, 5))
      assert_equal 3, Post.count
      assert_equal 2, Comment.count
    end
    nil
  end

  def test_sees_only_the_fixtures
    begin
      assert_equal [42, 980_190_962], Post.all.to_a.map(&:id).sort
      assert_equal "First post", posts(:one).title
      assert_equal 1, Comment.count
      assert_equal 980_190_962, comments(:greeting).post_id
      again = Post.create(title: "Extra", body: "long enough body")
      SEEN << "extra id #{again.id}"
    end
    nil
  end
end

def fixtures_case(i)
  case i
  when 0
    t = PostFixturesTest.new
    if Cybertrain::Test.before_case(t)
      Cybertrain::Test.run_body(t) { t.test_writes_rows }
    end
    Cybertrain::Test.after_case(t)
  when 1
    t = PostFixturesTest.new
    if Cybertrain::Test.before_case(t)
      Cybertrain::Test.run_body(t) { t.test_sees_only_the_fixtures }
    end
    Cybertrain::Test.after_case(t)
  end
  nil
end

def fixtures_dispatch = ->(i) { fixtures_case(i) }

# gen/tests.rb's hook, made in a method (rule 82).
def fixtures_hook
  -> {
    Cybertrain::Test::Database.clear_and_load!(Gen::TestData::TABLES, Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS)
    nil
  }
end

Dir.mkdir("tmp") unless File.directory?("tmp")
Dir.mkdir("tmp/test_bundle_fixtures") unless File.directory?("tmp/test_bundle_fixtures")
DB_PATH = "tmp/test_bundle_fixtures/test.sqlite3"
ENV["CYBERTRAIN_TEST_DATABASE"] = DB_PATH
CONFIG = Cybertrain::Config.new
CONFIG.env = "test"
CONFIG.database_path = DB_PATH
CONFIG.secret_key_base = "test-bundle-fixtures-secret"
CONFIG.encryption_key = "8f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
CONFIG.views_root = "tmp/test_bundle_fixtures/views"
CONFIG.public_root = "tmp/test_bundle_fixtures/public"
CONFIG.log_level = :none
Cybertrain.config = CONFIG
APP = Cybertrain::Test::Bundle.boot(Cybertrain::Router.new, ->(name, args, options) { "/" })
Cybertrain::Test.before_each_bundled(fixtures_hook)

test "two bundled tests in a row: the second sees exactly the fixtures, ids restarted, in both forms" do
  Cybertrain::Test::Bundle.use_table(["test/models/post_test.rb", "test/legacy.rb"],
                                     ["test/models/post_test.rb", "test/models/post_test.rb"], [4, 15],
                                     %w[PostFixturesTest PostFixturesTest], ["writes rows", "sees only the fixtures"],
                                     %w[test_writes_rows test_sees_only_the_fixtures])
  Cybertrain::Test::Bundle.capture_output(true)
  status = Cybertrain::Test::Bundle.run!([], fixtures_dispatch)
  Cybertrain::Test::Bundle.capture_output(false)
  expected = ["test/models/post_test.rb",
              "  ok   PostFixturesTest: writes rows",
              "  ok   PostFixturesTest: sees only the fixtures",
              "test/legacy.rb",
              "  ok   top-level form reads posts(:one)",
              "",
              "3 tests, 8 assertions, 0 failures"]
  assert_equal expected, Cybertrain::Test::Bundle.captured_output
  assert_equal 0, status
  # Both extra posts took the id after the fixtures' highest: the
  # sequence was emptied before the second test's fixtures went in.
  assert_equal ["extra id 980190963", "extra id 980190963", "top-level title First post, 2 posts"], SEEN
end

# The top-level-form file, as gen/tests.rb begins and requires it (its
# case belongs to the bundle: run! below leaves it alone).
Cybertrain::Test.begin_file("test/legacy.rb", ["top-level form reads posts(:one)"], [3])

test "top-level form reads posts(:one)" do
  assert_equal 980_190_962, posts(:one).id
  SEEN << "top-level title #{posts(:one).title}, #{Post.count} posts"
end

Cybertrain::Test.run!
APP.shutdown
File.delete(DB_PATH) if File.exist?(DB_PATH)
