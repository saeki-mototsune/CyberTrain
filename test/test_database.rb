require "stringio"
require "tmpdir"
require "cybertrain"
require "cybertrain/test_help"
require "cybertrain/db/sqlite_ddl"

# Steps 1 and 2 of a bundled test (spec sections 5.3, 6 and 7, plan
# decision D8): Test::Database.clear! empties the application's tables, the
# framework's and sqlite_sequence; load_fixtures! runs the generated
# inserts of test/fixtures/gen_app/gen/test/data.rb (from its
# test/fixtures/posts.yml and comments.yml) with foreign keys off and the
# timestamps from the Clock; the accessors find the rows; and neither step
# touches a database that is not a test one. Registered through
# Test.before_each_bundled, as gen/tests.rb registers them, so every test
# here starts from the fixtures. One SQLite file; it links SQLite through
# FFI, so the snapshot comes from the compiled binary (NOTES rule 23).
require_relative "fixtures/gen_app/db/schema"
require_relative "fixtures/gen_app/gen/models/comment"
require_relative "fixtures/gen_app/gen/models/post"
require_relative "fixtures/gen_app/gen/concerns/models/concerns/visible"
require_relative "fixtures/gen_app/app/models/comment"
require_relative "fixtures/gen_app/app/models/post"
require_relative "fixtures/gen_app/gen/test/data"

DB = Cybertrain::DB
Database = Cybertrain::Test::Database

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)
CONFIG = Cybertrain.config
CONFIG.env = "test"
CONFIG.secret_key_base = "d" * 64
CONFIG.encryption_key = "8f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

DIR = Dir.mktmpdir("cybertrain-test-database")
DB_PATH = "#{DIR}/test.sqlite3"
at_exit do
  Dir.children(DIR).each { |f| File.delete("#{DIR}/#{f}") }
  Dir.rmdir(DIR)
end
ENV["CYBERTRAIN_TEST_DATABASE"] = DB_PATH
DB.connect(DB_PATH)
DB.with do |c|
  Cybertrain::Schema.current.tables.each { |t| c.exec_script(Cybertrain::DB::SqliteDDL.create_table(t)) }
end

Cybertrain::Job.register("noop") { |run| nil }

def count_rows(table)
  n = 0
  DB.with { |c| n = Cybertrain::Cast.int(c.execute("SELECT COUNT(*) AS n FROM #{table}")[0]["n"]) }
  n
end

def foreign_keys_on
  on = 0
  DB.with { |c| on = Cybertrain::Cast.int(c.execute("PRAGMA foreign_keys")[0]["foreign_keys"]) }
  on
end

def clear_and_load
  Database.clear!(Gen::TestData::TABLES)
  Database.load_fixtures!(Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS)
  nil
end

# gen/tests.rb's registration, in a method (rule 82).
def bundled_hook = -> { clear_and_load }
Cybertrain::Test.before_each_bundled(bundled_hook)

test "the clear empties application and framework tables and resets ids" do
  Post.create(title: "extra", body: "long enough body")
  Cybertrain::Cache.write("k", "v")
  Cybertrain::Job.enqueue("noop", "{}")
  Cybertrain::Stream.broadcast_append_to("s", target: "t", html: "x")
  assert_equal 1, count_rows("cybertrain_jobs")
  Database.clear!(Gen::TestData::TABLES)
  assert_equal 0, Post.count
  assert_equal 0, Comment.count
  %w[cybertrain_jobs cybertrain_cache cybertrain_messages].each { |t| assert_equal 0, count_rows(t) }
  assert_equal 0, count_rows("sqlite_sequence")
  assert_equal 1, Post.create(title: "first", body: "long enough body").id
  assert_equal 1, foreign_keys_on
end

test "fixtures load with foreign keys off and timestamps from the Clock" do
  travel_to(Time.utc(2026, 11, 2)) { clear_and_load }
  assert_equal Time.utc(2026, 11, 2), posts(:one).updated_at
  assert_equal Time.utc(2026, 11, 1, 9), posts(:one).created_at
  assert_equal Time.utc(2026, 11, 2), posts(:two).created_at
  assert_equal 42, posts(:two).id
  assert_equal 980_190_962, posts(:one).id
  # comments.yml is inserted before posts.yml: foreign keys were off.
  greeting = comments(:greeting)
  assert_equal 980_190_962, greeting.post_id
  assert_equal "First post", greeting.post.title
  assert_equal true, greeting.approved
  assert_equal Date.new(2026, 11, 2), greeting.seen_on
  assert_equal 4.5, posts(:one).price
  assert_equal Date.new(2026, 11, 1), posts(:one).published_on
  assert_equal 1, foreign_keys_on
end

test "the accessors answer the same record in the class form" do
  assert_equal 42, ActiveSupport::TestCase.new.posts(:two).id
  assert_equal "Ann", Gen::TestFixtures.comments("greeting").commenter
end

test "posts(:missing) raises FixtureNotFound" do
  assert_equal "No fixture named 'missing' found for fixture set 'posts'",
               assert_raises("FixtureNotFound") { posts(:missing) }
  assert_equal "No fixture named 'one' found for fixture set 'comments'",
               assert_raises(Cybertrain::Test::FixtureNotFound) { comments(:one) }
end

test "a test's rows are gone after the next clear" do
  Post.create(title: "temp", body: "long enough body")
  assert_equal 3, Post.count
  clear_and_load
  assert_equal 2, Post.count
  Post.create(title: "left for the next test", body: "long enough body")
end

test "before each test the bundled hook cleared and loaded" do
  assert_equal 2, Post.count
  assert_equal 0, Post.where(title: "left for the next test").count
  assert_equal 1, Comment.count
end

test "a failing insert rolls the load back and turns foreign keys on again" do
  Database.clear!(Gen::TestData::TABLES)
  message = assert_raises { Database.load_fixtures!(["INSERT INTO \"posts\" (\"id\", \"title\", \"created_at\", \"updated_at\") VALUES (7, 'x', ?, ?)", "INSERT INTO nope VALUES (1)"], [2, 0]) }
  assert_includes message, "nope"
  assert_equal 0, Post.count
  assert_equal 1, foreign_keys_on
end

test "clear_and_load! is one transaction: a failing insert keeps the previous rows" do
  Post.create(title: "kept", body: "long enough body")
  message = assert_raises { Database.clear_and_load!(Gen::TestData::TABLES, ["INSERT INTO nope VALUES (1)"], [0]) }
  assert_includes message, "nope"
  assert_equal 3, Post.count
  assert_equal 1, foreign_keys_on
  travel_to(Time.utc(2026, 11, 3)) { Database.clear_and_load!(Gen::TestData::TABLES, Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS) }
  assert_equal 2, Post.count
  assert_equal Time.utc(2026, 11, 3), posts(:one).updated_at
  assert_equal 0, Post.where(title: "kept").count
end

test "only a test database is emptied" do
  assert_equal "", Database.refusal("test", "storage/test.sqlite3")
  assert_equal "", Database.refusal("test", "/srv/app/storage/test.sqlite3")
  assert_equal "", Database.refusal("test", ":memory:")
  assert_equal "", Database.refusal("test", DB_PATH)
  assert_equal "Test::Database refuses to empty storage/test.sqlite3: not a test database (env development)",
               Database.refusal("development", "storage/test.sqlite3")
  assert_equal "Test::Database refuses to empty storage/development.sqlite3: not a test database (env test)",
               Database.refusal("test", "storage/development.sqlite3")
  assert_equal "Test::Database refuses to empty storage/production.sqlite3: not a test database (env production)",
               Database.refusal("production", "storage/production.sqlite3")
  assert_equal "Test::Database refuses to empty /srv/app/storage/test.sqlite3.bak: not a test database (env test)",
               Database.refusal("test", "/srv/app/storage/test.sqlite3.bak")
end

test "the clear and the load refuse a connected database that is not a test one" do
  CONFIG.env = "development"
  message = assert_raises { Database.clear!(Gen::TestData::TABLES) }
  CONFIG.env = "test"
  assert_equal "Test::Database refuses to empty #{DB_PATH}: not a test database (env development)", message
  assert_equal 2, Post.count
  ENV.delete("CYBERTRAIN_TEST_DATABASE")
  message = assert_raises { Database.load_fixtures!(Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS) }
  combined = assert_raises { Database.clear_and_load!(Gen::TestData::TABLES, Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS) }
  ENV["CYBERTRAIN_TEST_DATABASE"] = DB_PATH
  assert_equal "Test::Database refuses to empty #{DB_PATH}: not a test database (env test)", message
  assert_equal message, combined
  assert_equal 2, Post.count
end

Cybertrain::Test.run!
