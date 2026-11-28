require "cybertrain/cast"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/config"
require "cybertrain/migration"
require "cybertrain/test"
require "cybertrain/test/database"
require "cybertrain/test/bundle/mysql"

# Test::Database and the bundle's test database on MySQL (docs/design.md
# D82 and D83), against the server CYBERTRAIN_TEST_MYSQL_URL names
# (script/test-mysql runs this program): what may be emptied (the
# environment "test", a name that ends in "_test", the table
# cybertrain_test_marker or an empty database, where it is created),
# Bundle.fresh_database, the clear and the fixture load, the ids from 1
# again, and a fixture's foreign key violation.
#
# It uses two databases of the server besides CYBERTRAIN_TEST_MYSQL_URL's
# own, its URL with the name swapped: cybertrain_tdb_test, which this
# program empties of its own tables first and then needs empty (the shared
# database holds the other programs' tables), and cybertrain_tdb, which is
# only refused and never written. This program creates no database:
# script/mysql-dev and CI's mysql-tests job create both when the server
# starts (only test/mysql/db_cli.rb creates and drops one, its own). The
# tests depend on their order (the third creates the tables the next three
# use): Cybertrain::Test.run! runs them in the order they are written. Only the bundle's runner and its boot, which need the whole
# framework, are left to the SQLite tests (test/test_bundle.rb).

DB = Cybertrain::DB
Dialect = Cybertrain::DB::Dialect
Database = Cybertrain::Test::Database
Bundle = Cybertrain::Test::Bundle

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# URL with its database name replaced by `name` (the parameters kept).
def url_for(name)
  q = URL.index("?")
  head = q.nil? ? URL : URL[0, q].to_s
  tail = q.nil? ? "" : URL[q, URL.size - q].to_s
  slash = head.rindex("/").to_i
  "#{head[0, slash]}/#{name}#{tail}"
end

TEST_URL = url_for("cybertrain_tdb_test")
OTHER_URL = url_for("cybertrain_tdb")
TEST_LABEL = DB::MySQL::Url.parse(TEST_URL).to_s
OTHER_LABEL = DB::MySQL::Url.parse(OTHER_URL).to_s
PASSWORD_PART = ":#{DB::MySQL::Url.parse(URL).url_password}@"
OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
NOT_CREATED = "not a database cybertrain test created (it has tables and no cybertrain_test_marker table); " \
              "empty it yourself or name another database"

# Every table this program makes in cybertrain_tdb_test.
OWN_TABLES = ["cybertrain_test_marker", "schema_migrations", "tdb_notes", "tdb_post_tags", "tdb_comments", "tdb_posts"]

CONFIG = Cybertrain.config
CONFIG.env = "test"
CONFIG.database_url = TEST_URL

class CreateTdbPosts < Cybertrain::Migration::Base
  def change
    create_table "tdb_posts" do |t|
      t.string "title", null: false
      t.timestamps
    end
    create_table "tdb_comments" do |t|
      t.references :tdb_post
      t.string "body"
    end
  end
end
Cybertrain::Migration.register("20261127000000", CreateTdbPosts.new)

TABLES = ["tdb_comments", "tdb_posts"]
FIXTURE_SQL = ["INSERT INTO tdb_posts (id, title, created_at, updated_at) VALUES (42, 'First', ?, ?)"]
FIXTURE_TIMESTAMPS = [2]
DANGLING = "INSERT INTO tdb_comments (id, tdb_post_id, body) VALUES (5, 999, 'dangling')"
DANGLING_MESSAGE = "fixtures: tdb_comments row with id 5 has tdb_post_id 999, which names no row of tdb_posts " \
                   "(a belongs_to label or id with no fixture in test/fixtures/tdb_posts.yml)"

def tables_of(conn)
  Dialect.table_names(conn)
end

def count_on(conn, table)
  Cybertrain::Cast.int(conn.execute("SELECT COUNT(*) AS n FROM #{table}")[0]["n"])
end

def count_rows(table)
  n = 0
  DB.with { |c| n = count_on(c, table) }
  n
end

def checks
  n = 0
  DB.with { |c| n = Cybertrain::Cast.int(c.execute("SELECT @@foreign_key_checks AS n")[0]["n"]) }
  n
end

def insert_id(sql)
  id = 0
  DB.with do |c|
    c.execute(sql)
    id = Cybertrain::Cast.int(c.execute("SELECT LAST_INSERT_ID() AS n")[0]["n"])
  end
  id
end

# cybertrain_tdb_test emptied of this program's tables; anything else left
# there is not this program's to drop.
setup_conn = DB::Connection.new(TEST_URL)
MySQLTestTables.drop(setup_conn, OWN_TABLES)
left = tables_of(setup_conn)
setup_conn.close
unless left.empty?
  puts "cybertrain_tdb_test holds tables this program did not make: #{left.join(", ")}"
  exit 1
end
# ... and emptied of them again at the end, for the next program that
# needs it empty (test/mysql/bundle_boot.rb boots on it).
at_exit do
  conn = DB::Connection.new(TEST_URL)
  MySQLTestTables.drop(conn, OWN_TABLES)
  conn.close
end

test "a database whose name does not end in _test is refused, by its URL without the password" do
  CONFIG.database_url = OTHER_URL
  assert_equal "cybertrain test refuses to empty #{OTHER_LABEL}: not a test database (its name does not end in _test)",
               Bundle.refusal
  CONFIG.database_url = TEST_URL
  assert_equal "", Bundle.refusal
  CONFIG.env = "development"
  assert_equal "cybertrain test refuses to empty #{TEST_LABEL}: not a test database (env development)", Bundle.refusal
  CONFIG.env = "test"
  CONFIG.database_url = ""
  assert_equal "cybertrain test refuses to empty the database: DATABASE_URL is not set (mysql://user:password@host:3306/name)",
               Bundle.refusal
  CONFIG.database_url = "mysql://u:secret@127.0.0.1/x_test?nope=1"
  refusal = Bundle.refusal
  assert_includes refusal, "cybertrain test refuses to empty the database: "
  refute refusal.include?("secret")
  CONFIG.database_url = TEST_URL
  DB.connect(OTHER_URL, size: 1)
  message = assert_raises { Database.clear!(TABLES) }
  assert_equal "Test::Database refuses to empty #{OTHER_LABEL}: not a test database (its name does not end in _test)", message
  refute message.include?(PASSWORD_PART)
  message = assert_raises { Database.load_fixtures!(FIXTURE_SQL, FIXTURE_TIMESTAMPS) }
  assert_includes message, "its name does not end in _test"
  DB.disconnect
end

test "a _test database with tables and no marker is refused, and nothing is changed" do
  conn = DB::Connection.new(TEST_URL)
  conn.exec_script("CREATE TABLE tdb_notes (id BIGINT AUTO_INCREMENT PRIMARY KEY, body VARCHAR(255))#{OPTIONS}")
  conn.execute("INSERT INTO tdb_notes (body) VALUES ('keep')")
  message = assert_raises(Cybertrain::Test::Bundle::Refused) { Bundle.fresh_database }
  assert_equal "cybertrain test refuses to empty #{TEST_LABEL}: #{NOT_CREATED}", message
  DB.connect(TEST_URL, size: 1)
  message = assert_raises { Database.clear_and_load!(["tdb_notes"], FIXTURE_SQL, FIXTURE_TIMESTAMPS) }
  assert_equal "Test::Database refuses to empty #{TEST_LABEL}: #{NOT_CREATED}", message
  refute message.include?(PASSWORD_PART)
  DB.disconnect
  assert_equal ["tdb_notes"], tables_of(conn)
  assert_equal 1, count_on(conn, "tdb_notes")
  conn.exec_script("DROP TABLE tdb_notes")
  conn.close
end

test "an empty database gets the marker first; the bundle drops the rest and migrates" do
  conn = DB::Connection.new(TEST_URL)
  assert_equal [], tables_of(conn)
  DB.connect(TEST_URL, size: 1)
  assert_nil Database.clear!(Array.new(0) { "" })
  DB.disconnect
  assert_equal ["cybertrain_test_marker"], tables_of(conn)
  assert_nil Bundle.fresh_database
  assert_equal ["cybertrain_test_marker", "schema_migrations", "tdb_comments", "tdb_posts"], tables_of(conn)
  # Again over a used database: its rows and a table of its own are gone.
  conn.execute("INSERT INTO tdb_posts (title, created_at, updated_at) VALUES ('old', NOW(6), NOW(6))")
  conn.exec_script("CREATE TABLE tdb_notes (id BIGINT AUTO_INCREMENT PRIMARY KEY)#{OPTIONS}")
  assert_nil Bundle.fresh_database
  assert_equal ["cybertrain_test_marker", "schema_migrations", "tdb_comments", "tdb_posts"], tables_of(conn)
  assert_equal 0, count_on(conn, "tdb_posts")
  assert_equal 1, count_on(conn, "schema_migrations")
  conn.close
end

test "after the clear and the fixture load, ids start again at 1" do
  DB.connect(TEST_URL, size: 1)
  post = insert_id("INSERT INTO tdb_posts (title, created_at, updated_at) VALUES ('p', NOW(6), NOW(6))")
  3.times { insert_id("INSERT INTO tdb_comments (tdb_post_id, body) VALUES (#{post}, 'c')") }
  assert_nil Database.clear_and_load!(TABLES, FIXTURE_SQL, FIXTURE_TIMESTAMPS)
  assert_equal 1, count_rows("tdb_posts")
  assert_equal 0, count_rows("tdb_comments")
  assert_equal 1, insert_id("INSERT INTO tdb_comments (tdb_post_id, body) VALUES (42, 'first')")
  # After the fixture's id 42, as SQLite's sqlite_sequence answers.
  assert_equal 43, insert_id("INSERT INTO tdb_posts (title, created_at, updated_at) VALUES ('next', NOW(6), NOW(6))")
  assert_nil Database.clear!(TABLES)
  assert_equal 1, insert_id("INSERT INTO tdb_posts (title, created_at, updated_at) VALUES ('first', NOW(6), NOW(6))")
  assert_equal 1, checks
  DB.disconnect
end

test "a fixture's foreign key violation is reported, and the fixtures are rolled back" do
  DB.connect(TEST_URL, size: 1)
  message = assert_raises { Database.clear_and_load!(TABLES, FIXTURE_SQL + [DANGLING], FIXTURE_TIMESTAMPS + [0]) }
  assert_equal DANGLING_MESSAGE, message
  assert_equal 0, count_rows("tdb_posts")
  assert_equal 0, count_rows("tdb_comments")
  assert_equal 1, checks
  message = assert_raises { Database.load_fixtures!(FIXTURE_SQL + ["INSERT INTO nope VALUES (1)"], FIXTURE_TIMESTAMPS + [0]) }
  assert_includes message, "nope"
  assert_equal 0, count_rows("tdb_posts")
  assert_equal 1, checks
  message = assert_raises { DB.transaction { |c| Database.clear!(TABLES) } }
  assert_equal "Test::Database cannot clear or load fixtures inside an open transaction (DB.transaction or a BEGIN)", message
  DB.disconnect
end

# An id-less join table (create_table ..., id: false) with a foreign key:
# the check after every fixture load reads it by its foreign key column,
# since it has no id to name the row by.
test "fixtures load beside an id-less table with a foreign key, and its dangling row is named by its column" do
  conn = DB::Connection.new(TEST_URL)
  conn.exec_script("CREATE TABLE tdb_post_tags (tdb_post_id BIGINT NOT NULL, tag VARCHAR(50) NOT NULL, " \
                   "CONSTRAINT fk_tdb_post_tags_post FOREIGN KEY (tdb_post_id) REFERENCES tdb_posts(id))#{OPTIONS}")
  conn.close
  tables = ["tdb_post_tags"] + TABLES
  tag = "INSERT INTO tdb_post_tags (tdb_post_id, tag) VALUES (42, 'ruby')"
  DB.connect(TEST_URL, size: 1)
  assert_nil Database.clear_and_load!(tables, FIXTURE_SQL + [tag], FIXTURE_TIMESTAMPS + [0])
  assert_equal 1, count_rows("tdb_post_tags")
  dangling = "INSERT INTO tdb_post_tags (tdb_post_id, tag) VALUES (999, 'gone')"
  message = assert_raises { Database.clear_and_load!(tables, FIXTURE_SQL + [dangling], FIXTURE_TIMESTAMPS + [0]) }
  assert_equal "fixtures: tdb_post_tags row with tdb_post_id 999, which names no row of tdb_posts " \
               "(a belongs_to label or id with no fixture in test/fixtures/tdb_posts.yml)", message
  assert_equal 0, count_rows("tdb_post_tags")
  assert_equal 1, checks
  DB.disconnect
  conn = DB::Connection.new(TEST_URL)
  MySQLTestTables.drop(conn, ["tdb_post_tags"])
  conn.close
end

Cybertrain::Test.run!
