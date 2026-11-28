require "cybertrain/cast"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/model"
require "cybertrain/migration"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/test"

# The review fixes of the MySQL dialect, its DDL and the Migrator
# (2026-11-27 review, area "dialect"), against the server
# CYBERTRAIN_TEST_MYSQL_URL names (script/test-mysql runs this program).
# Each test names the finding it pins:
#
# - Model.upsert answers what it answers on SQLite: 1 for a row inserted or
#   updated, 0 for a row an empty update left (the server's affected-row
#   count is 1 / 2 / 1);
# - upsert and upsert_all check their conflict target against the table's
#   unique keys, and a row that collides on another unique key raises
#   DB::UniqueViolation and writes nothing (SQLite's ON CONFLICT (target)
#   raises there too), where ON DUPLICATE KEY UPDATE alone updated the row
#   it collided with.

DB = Cybertrain::DB
Dialect = Cybertrain::DB::Dialect

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
OWN_TABLES = ["fx_users", "fx_claims", "fx_tags"]

DB.connect(URL, size: 1)

def run_sql(sql)
  DB.with { |c| c.exec_script(sql) }
  nil
end

def rows_of(sql)
  DB.with { |c| c.execute(sql, Cybertrain::Cast.empty_binds) }
end

# fx_users: an AUTO_INCREMENT id, unique email and unique username (two
# unique keys besides the id); fx_claims: a VARCHAR primary key, nothing
# else unique; fx_tags: an id and one unique name.
def reset_tables
  DB.with { |c| MySQLTestTables.drop(c, OWN_TABLES) }
  run_sql("CREATE TABLE fx_users (id BIGINT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255), " \
          "username VARCHAR(255), name VARCHAR(255), hits INT NOT NULL DEFAULT 0, " \
          "UNIQUE KEY fx_users_email (email), UNIQUE KEY fx_users_username (username))#{TABLE_OPTIONS}; " \
          "CREATE TABLE fx_claims (`key` VARCHAR(255) NOT NULL PRIMARY KEY, owner VARCHAR(255))#{TABLE_OPTIONS}; " \
          "CREATE TABLE fx_tags (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255), n INT NOT NULL DEFAULT 0, " \
          "UNIQUE KEY fx_tags_name (name))#{TABLE_OPTIONS}; " \
          "INSERT INTO fx_users (email, username, name) VALUES ('a@x', 'alice', 'Alice'), ('b@x', 'bob', 'Bob');")
  Dialect.forget_schema_cache
  nil
end

def upsert(table, attrs, conflict, update)
  Cybertrain::Model.upsert_into(table, attrs, conflict, update, Cybertrain::Model.no_column_types,
                                Cybertrain::Model.no_decimal_scales, Cybertrain::Model.no_encrypted_columns)
end

USER_TYPES = { "id" => :integer, "email" => :string, "username" => :string, "name" => :string, "hits" => :integer }

def upsert_all_users(rows, unique_by)
  Cybertrain::Model.insert_all_into("fx_users", rows, USER_TYPES, Cybertrain::Model.no_decimal_scales,
                                    Cybertrain::Model.no_encrypted_columns, nil, false, :update, unique_by, nil)
end

def users_text
  rows_of("SELECT id, email, username, name, hits FROM fx_users ORDER BY id").map do |r|
    "#{Cybertrain::Cast.str(r["email"])}:#{Cybertrain::Cast.str(r["username"])}:" \
      "#{Cybertrain::Cast.str(r["name"])}:#{Cybertrain::Cast.str(r["hits"])}"
  end.join(" ")
end

# ---- MJ1: Model.upsert answers SQLite's count ----------------------------

test "upsert answers 1 for an insert and an update, 0 for a row an empty update left" do
  reset_tables
  assert_equal 1, upsert("fx_claims", { key: "import-42", owner: "me" }, [:key], {})
  assert_equal 0, upsert("fx_claims", { key: "import-42", owner: "you" }, [:key], {})
  assert_equal "me", Cybertrain::Cast.str(rows_of("SELECT owner FROM fx_claims")[0]["owner"])
  assert_equal 1, upsert("fx_claims", { key: "import-42", owner: "you" }, [:key], { owner: "excluded.owner" })
  # The same values again: still 1, as SQLite counts a DO UPDATE.
  assert_equal 1, upsert("fx_claims", { key: "import-42", owner: "you" }, [:key], { owner: "excluded.owner" })
  assert_equal 1, upsert("fx_claims", { key: "import-43", owner: "me" }, [:key], { owner: "excluded.owner" })
  # On a table with an AUTO_INCREMENT id: a new row's id is not the mark.
  assert_equal 1, upsert("fx_tags", { name: "a" }, [:name], {})
  assert_equal 1, upsert("fx_tags", { name: "b" }, [:name], {})
  assert_equal 0, upsert("fx_tags", { name: "a" }, [:name], {})
  assert_equal 1, upsert("fx_tags", { name: "a", n: 5 }, [:name], { n: "fx_tags.n + excluded.n" })
  assert_equal 5, Cybertrain::Cast.int(rows_of("SELECT n FROM fx_tags WHERE name = 'a'")[0]["n"])
end

# ---- MJ2: the conflict target ---------------------------------------------

test "a conflict target that is no unique key is refused before anything is written" do
  reset_tables
  e = assert_raises("Cybertrain::DB::Error") { upsert("fx_users", { email: "c@x", name: "C" }, [:name], {}) }
  assert e.include?("upsert: name is not the primary key or a unique index of fx_users")
  # Part of a key is not the key.
  assert_raises("Cybertrain::DB::Error") { upsert("fx_users", { email: "c@x" }, [:email, :name], {}) }
  e = assert_raises("Cybertrain::DB::Error") { upsert_all_users([{ email: "c@x", name: "C" }], [:name]) }
  assert e.include?("is not the primary key or a unique index of fx_users")
  assert_equal "a@x:alice:Alice:0 b@x:bob:Bob:0", users_text
  # The primary key is a target, and a unique index named in another order.
  assert_equal 1, upsert("fx_users", { id: 1, name: "A1" }, [:id], { name: "excluded.name" })
  assert_equal "a@x:alice:A1:0 b@x:bob:Bob:0", users_text
end

test "a row that collides on another unique key raises UniqueViolation and changes no row" do
  reset_tables
  # SQLite: UNIQUE constraint failed: fx_users.username. ON DUPLICATE KEY
  # UPDATE alone gave bob's row the new email.
  assert_raises("Cybertrain::DB::UniqueViolation") do
    upsert_all_users([{ email: "new@x", username: "bob", name: "N" }], [:email])
  end
  assert_raises("Cybertrain::DB::UniqueViolation") do
    upsert("fx_users", { email: "new@x", username: "bob", name: "N" }, [:email], { name: "excluded.name" })
  end
  # An empty update (DO NOTHING) raises as well.
  assert_raises("Cybertrain::DB::UniqueViolation") do
    upsert("fx_users", { email: "new@x", username: "bob" }, [:email], {})
  end
  # A supplied id that another row has.
  assert_raises("Cybertrain::DB::UniqueViolation") do
    upsert("fx_users", { id: 2, email: "a@x", name: "N" }, [:email], { name: "excluded.name" })
  end
  assert_equal "a@x:alice:Alice:0 b@x:bob:Bob:0", users_text
  # The statement is rolled back whole: the new row before the collision
  # is not left behind.
  assert_raises("Cybertrain::DB::UniqueViolation") do
    upsert_all_users([{ email: "c@x", username: "carol", name: "C" }, { email: "d@x", username: "alice", name: "D" }],
                     [:email])
  end
  assert_equal "a@x:alice:Alice:0 b@x:bob:Bob:0", users_text
end

test "a collision on the target itself still takes the update where other unique keys exist" do
  reset_tables
  assert_equal 1, upsert("fx_users", { email: "a@x", username: "alice", hits: 1 }, [:email],
                         { hits: "fx_users.hits + excluded.hits" })
  assert_equal 0, upsert("fx_users", { email: "a@x", username: "alice" }, [:email], {})
  upsert_all_users([{ email: "b@x", username: "bob", name: "B2" }, { email: "c@x", username: "carol", name: "C" }],
                   [:email])
  assert_equal "a@x:alice:Alice:1 b@x:bob:B2:0 c@x:carol:C:0", users_text
  # A target given in another order than its index.
  run_sql("ALTER TABLE fx_tags ADD COLUMN kind VARCHAR(20) NOT NULL DEFAULT '', DROP INDEX fx_tags_name, " \
          "ADD UNIQUE KEY fx_tags_kind_name (kind, name)")
  Dialect.forget_schema_cache
  assert_equal 1, upsert("fx_tags", { name: "a", kind: "k", n: 1 }, [:name, :kind], { n: "fx_tags.n + excluded.n" })
  assert_equal 1, upsert("fx_tags", { name: "a", kind: "k", n: 1 }, [:name, :kind], { n: "fx_tags.n + excluded.n" })
  assert_equal 2, Cybertrain::Cast.int(rows_of("SELECT n FROM fx_tags WHERE name = 'a'")[0]["n"])
end

# ---- MJ3: change_column_null / change_column_default keep the column ------

# fx_events is a table the framework did not create: types the schema dump
# does not carry (BIGINT UNSIGNED, ENUM, TIMESTAMP), a column's own
# collation, a comment, ON UPDATE, an expression default.
def events_table
  conn = DB::Connection.new(URL)
  MySQLTestTables.drop(conn, ["fx_events", "fx_kids", "fx_parents", "schema_migrations"])
  conn.exec_script("CREATE TABLE fx_events (id BIGINT AUTO_INCREMENT PRIMARY KEY, counter BIGINT UNSIGNED, " \
                   "e ENUM('a','b c') DEFAULT 'a' COMMENT 'it''s', " \
                   "ci VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci, " \
                   "ts TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP, body MEDIUMTEXT, " \
                   "meta JSON DEFAULT (_utf8mb4'{}'), at DATETIME(6), n INT DEFAULT 3, " \
                   "INDEX fx_events_expr ((COALESCE(ci, 'a''b'))))#{TABLE_OPTIONS}; " \
                   "INSERT INTO fx_events (counter, e, ci, ts) VALUES (4294967296000, 'b c', 'X', '2026-01-01 00:00:00');")
  conn
end

def column_lines(conn, table)
  text = Cybertrain::Cast.str(conn.execute("SHOW CREATE TABLE #{Dialect.quote_ident(table)}")[0]["Create Table"])
  out = Array.new(0) { "" }
  text.split("\n").each { |line| out << line.strip if line.start_with?("  `") }
  out
end

class FxTighten < Cybertrain::Migration::Base
  def change
    change_column_null "fx_events", "counter", false
    change_column_null "fx_events", "e", false
    change_column_null "fx_events", "ci", false
    change_column_null "fx_events", "ts", false
    change_column_null "fx_events", "n", false, 0
    change_column_default "fx_events", "counter", to: "5"
    change_column_default "fx_events", "e", to: "'b c'"
    change_column_default "fx_events", "body", to: "'x'"
    change_column_default "fx_events", "meta", to: nil
    change_column_default "fx_events", "at", to: "CURRENT_TIMESTAMP(6)"
  end
end

class FxLoosen < Cybertrain::Migration::Base
  def change
    change_column_null "fx_events", "counter", true
    change_column_null "fx_events", "ci", true
  end
end

test "change_column_null and change_column_default change nothing else of the column" do
  conn = events_table
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  assert_equal 1, migrator.migrate([["20270201000000", FxTighten.new]])
  column_lines(conn, "fx_events").each { |line| puts "  #{line}" }
  assert_equal 4294967296000, Cybertrain::Cast.int(conn.execute("SELECT counter FROM fx_events")[0]["counter"])
  assert_equal 1, migrator.migrate([["20270201000000", FxTighten.new], ["20270201000100", FxLoosen.new]])
  lines = column_lines(conn, "fx_events")
  assert_includes lines, "`counter` bigint unsigned DEFAULT '5',"
  assert_includes lines, "`ci` varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci DEFAULT NULL,"
  conn.close
end

# ---- Unconfirmed 1 and 2: information_schema's escaped expressions --------

test "an expression default and an expression index read back as SQL the server takes" do
  conn = events_table
  defaults = Array.new(0) { "" }
  Dialect.schema_columns(conn, "fx_events").each do |r|
    name = Cybertrain::Cast.str(r["name"])
    defaults << "#{name}=#{Cybertrain::Cast.str(r["dflt_value"])}" if name == "meta" || name == "n"
  end
  assert_equal ["meta='{}'", "n=3"], defaults
  sql = Dialect.schema_index_sql(conn, "fx_events", "fx_events_expr")
  assert_equal "CREATE INDEX `fx_events_expr` ON `fx_events` ((coalesce(`ci`,'a''b')))", sql
  # Both are taken back as they read.
  conn.exec_script("DROP INDEX fx_events_expr ON fx_events")
  conn.exec_script(sql)
  conn.exec_script("ALTER TABLE fx_events ADD COLUMN meta2 JSON DEFAULT ('{}')")
  assert_equal 1, conn.execute("SELECT COUNT(*) AS n FROM fx_events WHERE meta2 = CAST('{}' AS JSON)")[0]["n"]
  conn.close
end

# ---- MN7: no foreign key switch or check around an in-place ALTER ---------

class FxNullN < Cybertrain::Migration::Base
  def change
    change_column_null "fx_events", "n", true
  end
end

test "a change_column_null runs with foreign keys on, and an old orphan elsewhere does not fail it" do
  conn = events_table
  conn.exec_script("CREATE TABLE fx_parents (id BIGINT AUTO_INCREMENT PRIMARY KEY)#{TABLE_OPTIONS}; " \
                   "CREATE TABLE fx_kids (id BIGINT AUTO_INCREMENT PRIMARY KEY, fx_parent_id BIGINT, " \
                   "FOREIGN KEY (fx_parent_id) REFERENCES fx_parents (id))#{TABLE_OPTIONS}; " \
                   "SET FOREIGN_KEY_CHECKS = 0; INSERT INTO fx_kids (fx_parent_id) VALUES (99); " \
                   "SET FOREIGN_KEY_CHECKS = 1;")
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  assert_equal 1, migrator.migrate([["20270201000200", FxNullN.new]])
  assert_equal 1, Cybertrain::Cast.int(conn.execute("SELECT @@foreign_key_checks AS n")[0]["n"])
  conn.close
end

# ---- Callers Major 6 / MN5: keys as long as SQLite's TEXT -----------------

test "a cache key, a rate-limit key and a concurrency key longer than 255 characters are stored" do
  conn = DB::Connection.new(URL)
  MySQLTestTables.drop(conn, ["cybertrain_cache", "cybertrain_jobs"])
  conn.exec_script(Dialect.cache_table_sql)
  conn.exec_script(Dialect.job_table_sql)
  long = "search/" + ("q=x&" * 300)
  other = long + "2"
  assert_equal true, Dialect.cache_write(conn, long, "v1", 0, 100, false)
  assert_equal true, Dialect.cache_write(conn, long, "v2", 0, 100, false)
  assert_equal false, Dialect.cache_write(conn, long, "v3", 0, 100, true)
  assert_equal true, Dialect.cache_write(conn, other, "w", 0, 100, true)
  live = "SELECT value FROM cybertrain_cache WHERE `key` = ? AND (expires_at IS NULL OR expires_at >= ?)"
  assert_equal "v2", Cybertrain::Cast.str(conn.execute(live, Cybertrain::Cast.binds(long, 100))[0]["value"])
  assert_equal "w", Cybertrain::Cast.str(conn.execute(live, Cybertrain::Cast.binds(other, 100))[0]["value"])
  limit_key = "rate-limit:sessions:create:" + ("a" * 300) + "@example.com:1700000000"
  assert_equal 1, Dialect.cache_increment(conn, limit_key, 1, 160, 100)
  assert_equal 2, Dialect.cache_increment(conn, limit_key, 1, 160, 100)
  conn.execute("DELETE FROM cybertrain_cache WHERE `key` >= 'rate-limit:' AND `key` < 'rate-limit;'")
  assert_equal 2, Cybertrain::Cast.int(conn.execute("SELECT COUNT(*) AS n FROM cybertrain_cache")[0]["n"])
  key = "https://example.com/" + ("p" * 400)
  conn.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, created_at, updated_at, concurrency_key) " \
               "VALUES (?, ?, ?, ?, ?, ?)", Cybertrain::Cast.binds("fetch", "{}", 1, 1, 1, key))
  count = conn.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state = 'queued' AND kind = ? " \
                       "AND concurrency_key = ?", Cybertrain::Cast.binds("fetch", key))
  assert_equal 1, Cybertrain::Cast.int(count[0]["n"])
  MySQLTestTables.drop(conn, ["cybertrain_cache", "cybertrain_jobs"])
  conn.close
end

# ---- MN1: a failing script says it may be partly applied ------------------

class FxScript < Cybertrain::Migration::Base
  def change
    execute "UPDATE fx_events SET n = 1; UPDATE fx_no_such_table SET n = 2"
    add_column "fx_events", "later", :integer
  end
end

test "a failing execute of several statements says it may be partly applied" do
  conn = events_table
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  message = assert_raises("DB::Error") { migrator.migrate([["20270201000300", FxScript.new]]) }
  assert message.start_with?("migration 20270201000300 failed at statement 1 of 2; statement 1 is a script of " \
                             "several statements, which may be partly applied: ")
  assert_equal 1, Cybertrain::Cast.int(conn.execute("SELECT n FROM fx_events")[0]["n"])
  conn.close
end

# ---- MN3: index names past MySQL's 64 characters --------------------------

class FxLongIndex < Cybertrain::Migration::Base
  def change
    create_table "fx_organization_memberships" do |t|
      t.integer "organization_id"
      t.integer "invited_by_user_id"
    end
    add_index "fx_organization_memberships", ["organization_id", "invited_by_user_id"]
  end
end

class FxDropLongIndex < Cybertrain::Migration::Base
  def up
    remove_index "fx_organization_memberships", ["organization_id", "invited_by_user_id"]
  end
end

def index_names(conn, table)
  rows = conn.execute("SELECT DISTINCT index_name AS name FROM information_schema.statistics " \
                      "WHERE table_schema = DATABASE() AND table_name = ? AND index_name <> 'PRIMARY' " \
                      "ORDER BY index_name", [table])
  rows.map { |r| Cybertrain::Cast.str(r["name"]) }
end

test "a derived index name longer than 64 characters is shortened the same way when it is dropped" do
  conn = events_table
  MySQLTestTables.drop(conn, ["fx_organization_memberships"])
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  assert_equal 1, migrator.migrate([["20270201000400", FxLongIndex.new]])
  names = index_names(conn, "fx_organization_memberships")
  puts "  #{names.join(", ")}"
  assert_equal 1, names.size
  assert_equal 64, names[0].size
  assert_equal 1, migrator.migrate([["20270201000400", FxLongIndex.new], ["20270201000500", FxDropLongIndex.new]])
  assert_equal 0, index_names(conn, "fx_organization_memberships").size
  MySQLTestTables.drop(conn, ["fx_organization_memberships"])
  conn.close
end

# ---- MN4: a NOT NULL column without a default on a table with rows ---------

class FxAddRequired < Cybertrain::Migration::Base
  def change
    add_column "fx_events", "required", :integer, null: false
  end
end

test "an add_column NOT NULL without a default is refused on a table with rows, as SQLite refuses it" do
  conn = events_table
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  message = assert_raises("DB::Error") { migrator.migrate([["20270201000600", FxAddRequired.new]]) }
  assert_includes message, "nothing was applied: Cannot add a NOT NULL column with default value NULL: " \
                           "fx_events.required on a table with rows"
  refute Dialect.column_names(conn, "fx_events").include?("required")
  conn.exec_script("DELETE FROM fx_events")
  assert_equal 1, migrator.migrate([["20270201000600", FxAddRequired.new]])
  assert Dialect.column_names(conn, "fx_events").include?("required")
  conn.close
end

# ---- MN6, MN8, MN9 ----------------------------------------------------------

test "the test marker table is not dumped" do
  conn = events_table
  conn.exec_script("CREATE TABLE IF NOT EXISTS cybertrain_test_marker (id INT)#{TABLE_OPTIONS}")
  names = DB::SchemaDumper.table_names(conn)
  refute names.include?("cybertrain_test_marker")
  assert names.include?("fx_events")
  conn.close
end

test "reset_sequences starts the ids of a cleared table at 1 again" do
  reset_tables
  conn = DB::Connection.new(URL)
  conn.exec_script("INSERT INTO fx_tags (name) VALUES ('a'), ('b'); DELETE FROM fx_tags;")
  Dialect.reset_sequences(conn, ["fx_tags", "fx_claims", "fx_users"])
  conn.exec_script("INSERT INTO fx_tags (name) VALUES ('c')")
  assert_equal 1, Cybertrain::Cast.int(conn.execute("SELECT id FROM fx_tags")[0]["id"])
  assert_nil Dialect.reset_sequences(conn, Array.new(0) { "" })
  conn.close
end

test "a row of a table whose id is not an integer is named by its foreign key value" do
  conn = events_table
  conn.exec_script("CREATE TABLE fx_parents (id BIGINT AUTO_INCREMENT PRIMARY KEY)#{TABLE_OPTIONS}; " \
                   "CREATE TABLE fx_kids (id VARCHAR(36) PRIMARY KEY, fx_parent_id BIGINT, " \
                   "FOREIGN KEY (fx_parent_id) REFERENCES fx_parents (id))#{TABLE_OPTIONS}; " \
                   "SET FOREIGN_KEY_CHECKS = 0; INSERT INTO fx_kids VALUES ('9f8a-uuid', 99); " \
                   "SET FOREIGN_KEY_CHECKS = 1;")
  assert_includes Dialect.migrator_foreign_key_check(conn), "fx_kids row with fx_parent_id 99 -> fx_parents"
  MySQLTestTables.drop(conn, ["fx_kids", "fx_parents"])
  conn.close
end

# ---- the dump of a text or json default is DDL MySQL takes ----------------

class FxNotes < Cybertrain::Migration::Base
  def change
    create_table "fx_notes" do |t|
      t.text "notes", default: "'none'"
      t.json "meta", default: "'{}'"
      t.string "title", default: "'it''s'"
    end
  end
end

test "a text or json default dumps as an expression create_table_sql writes back" do
  conn = events_table
  MySQLTestTables.drop(conn, ["fx_notes"])
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrator.migrate([["20270201000700", FxNotes.new]])
  table = DB::SchemaDumper.dump(conn).table("fx_notes")
  assert !table.nil?
  defaults = Array.new(0) { "" }
  table.columns.each { |c| defaults << "#{c.name}=#{c.default}" }
  # As SQLite's dump has them: the text column's default is written back
  # as the expression MySQL takes (DEFAULT ('none')).
  assert_equal ["notes='none'", "meta='{}'", "title='it''s'"], defaults
  sql = DB::MySQL::DDL.create_table_sql(table)
  conn.exec_script("DROP TABLE fx_notes")
  conn.exec_script(sql)
  conn.exec_script("INSERT INTO fx_notes () VALUES ()")
  row = conn.execute("SELECT notes, title FROM fx_notes")[0]
  assert_equal "none", Cybertrain::Cast.str(row["notes"])
  assert_equal "it's", Cybertrain::Cast.str(row["title"])
  MySQLTestTables.drop(conn, ["fx_notes"])
  conn.close
end

# ---- requests of the callers area -------------------------------------------

test "stream_message_state: -1 while the inserting transaction is open, then 1 committed, 0 rolled back" do
  writer = DB::Connection.new(URL)
  poller = DB::Connection.new(URL)
  MySQLTestTables.drop(writer, ["cybertrain_messages"])
  writer.exec_script(Dialect.stream_table_sql)
  assert_equal false, Dialect.stream_ids_in_commit_order?
  writer.begin!
  writer.execute("INSERT INTO cybertrain_messages (stream, payload, created_at) VALUES (?, ?, ?)",
                 Cybertrain::Cast.binds("s", "a", 1))
  kept = writer.last_insert_id
  assert_equal(-1, Dialect.stream_message_state(poller, kept))
  writer.commit!
  assert_equal 1, Dialect.stream_message_state(poller, kept)
  writer.begin!
  writer.execute("INSERT INTO cybertrain_messages (stream, payload, created_at) VALUES (?, ?, ?)",
                 Cybertrain::Cast.binds("s", "b", 1))
  lost = writer.last_insert_id
  assert_equal(-1, Dialect.stream_message_state(poller, lost))
  writer.rollback!
  assert_equal 0, Dialect.stream_message_state(poller, lost)
  MySQLTestTables.drop(writer, ["cybertrain_messages"])
  writer.close
  poller.close
end

test "Cache.increment reads a stored number past BIGINT as SQLite's CAST does, without error 1292" do
  conn = DB::Connection.new(URL)
  MySQLTestTables.drop(conn, ["cybertrain_cache"])
  conn.exec_script(Dialect.cache_table_sql)
  Dialect.cache_write(conn, "c", " 0042abc", 0, 100, false)
  assert_equal 43, Dialect.cache_increment(conn, "c", 1, 0, 100)
  Dialect.cache_write(conn, "n", "-9999999999999999999999999", 0, 100, false)
  Dialect.cache_write(conn, "p", "9" * 25, 0, 100, false)
  # Saturated to the BIGINT top, plus the counter's offset: past Cache's
  # counter range, MySQL's out-of-range error (Cache.increment's doc), not
  # a "Truncated incorrect INTEGER value".
  message = assert_raises("Cybertrain::DB::Error") { Dialect.cache_increment(conn, "p", 1, 0, 100) }
  assert_includes message, "(MySQL 1690,"
  index = conn.execute("SELECT COUNT(*) AS n FROM information_schema.statistics WHERE table_schema = DATABASE() " \
                       "AND table_name = 'cybertrain_cache' AND index_name = 'index_cybertrain_cache_on_expires_at'")
  assert_equal 1, Cybertrain::Cast.int(index[0]["n"])
  MySQLTestTables.drop(conn, ["cybertrain_cache"])
  conn.close
end

TAG_TYPES = { "id" => :integer, "name" => :string, "n" => :integer }

test "insert_all's returning: reads its rows back where the server's ids are 2 apart" do
  reset_tables
  DB.with { |c| c.execute("SET SESSION auto_increment_increment = 2") }
  rows = Cybertrain::Model.insert_all_into("fx_tags", [{ name: "x" }, { name: "y" }, { name: "z" }], TAG_TYPES,
                                           Cybertrain::Model.no_decimal_scales, Cybertrain::Model.no_encrypted_columns,
                                           [:id, :name], false, :raise, nil, nil)
  DB.with { |c| c.execute("SET SESSION auto_increment_increment = 1") }
  assert_equal ["x", "y", "z"], rows.map { |r| Cybertrain::Cast.str(r["name"]) }
  ids = rows.map { |r| Cybertrain::Cast.int(r["id"]) }
  assert_equal 2, ids[1] - ids[0]
  assert_equal 2, ids[2] - ids[1]
end

Cybertrain::Test.run!
