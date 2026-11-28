require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/config"
require "cybertrain/migration"
require "cybertrain/relation"
require "cybertrain/test"

# Cybertrain::DB::Dialect and DB::Adapter on SQLite: each method answers the
# SQL the framework sent before the Dialect existed, or the same result.
# SQLite is FFI, so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Dialect = Cybertrain::DB::Dialect

def blog_db
  conn = DB::Connection.new(":memory:")
  conn.exec_script(
    "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, views INTEGER DEFAULT 0); " \
    "CREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER REFERENCES posts(id), body TEXT); " \
    "CREATE INDEX index_comments_on_post_id ON comments (post_id); " \
    "CREATE TABLE cybertrain_jobs (id INTEGER PRIMARY KEY, kind TEXT);"
  )
  conn
end

def pragma_foreign_keys(conn)
  Cybertrain::Cast.int(conn.execute("PRAGMA foreign_keys")[0]["foreign_keys"])
end

class AddViews < Cybertrain::Migration::Base
  def change
    add_column "posts", "score", :integer, null: false, default: "0"
    add_index "posts", ["title"]
  end
end

test "the adapter is sqlite and connects to the configured database path" do
  assert_equal "sqlite", DB::Adapter.adapter_name
  config = Cybertrain::Config.new
  config.database_path = "storage/dialect.sqlite3"
  assert_equal "storage/dialect.sqlite3", DB::Adapter.connect_target(config)
end

test "quote_ident wraps a name in backticks and doubles an embedded one" do
  assert_equal "`posts`", Dialect.quote_ident("posts")
  assert_equal "`a``b`", Dialect.quote_ident("a`b")
  assert_equal "`a\"b`", Dialect.quote_ident("a\"b")
  assert_equal Dialect.quote_ident("a`b"), Cybertrain::Relation.quote_ident("a`b")
end

test "upsert_tail is ON CONFLICT ... DO UPDATE SET c = excluded.c, DO NOTHING without columns" do
  assert_equal " ON CONFLICT (name) DO UPDATE SET a = excluded.a, b = excluded.b",
               Dialect.upsert_tail(["name"], ["a", "b"])
  assert_equal " ON CONFLICT (`x`, `y`) DO NOTHING", Dialect.upsert_tail(["`x`", "`y`"], Array.new(0) { "" })
  assert_equal " ON CONFLICT (`k`) DO UPDATE SET `n` = `n` + 1",
               Dialect.bulk_writes_upsert_tail(["`k`"], ["`n` = `n` + 1"])
  assert_equal " ON CONFLICT DO NOTHING", Dialect.bulk_writes_ignore_tail
  assert_equal " RETURNING `id`, `title`", Dialect.bulk_writes_returning_tail(["`id`", "`title`"])
  assert_equal true, Dialect.returning?
end

test "table_names lists the tables, not SQLite's own" do
  conn = blog_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["a"])
  raw = conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map { |r| r["name"].to_s }
  assert_includes raw, "sqlite_sequence"
  assert_equal ["comments", "cybertrain_jobs", "posts"], Dialect.table_names(conn)
  assert_equal true, Dialect.table_exists?(conn, "posts")
  assert_equal false, Dialect.table_exists?(conn, "missing")
  assert_equal ["id", "title", "views"], Dialect.column_names(conn, "posts")
  assert_equal 0, Dialect.column_names(conn, "missing").size
  conn.close
end

test "health_query is the schema page read" do
  conn = blog_db
  assert_equal "SELECT count(*) AS n FROM sqlite_master", Dialect.health_query
  rows = conn.execute(Dialect.health_query)
  assert_equal 1, rows.size
  # posts, comments and their index, cybertrain_jobs, sqlite_sequence
  assert_equal 5, Cybertrain::Cast.int(rows[0]["n"])
  conn.close
end

test "foreign_keys_off and foreign_keys_on toggle enforcement" do
  conn = blog_db
  assert_equal 1, pragma_foreign_keys(conn)
  assert_nil Dialect.foreign_keys_off(conn)
  assert_equal 0, pragma_foreign_keys(conn)
  assert_equal false, Dialect.migrator_foreign_keys_enforced?(conn)
  assert_nil Dialect.foreign_keys_on(conn)
  assert_equal 1, pragma_foreign_keys(conn)
  assert_equal true, Dialect.migrator_foreign_keys_enforced?(conn)
  conn.close
end

test "reset_sequences empties sqlite_sequence so ids start again at 1" do
  conn = blog_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["a"])
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["b"])
  conn.execute("DELETE FROM posts")
  assert_nil Dialect.reset_sequences(conn, ["posts"])
  assert_equal 0, conn.execute("SELECT seq FROM sqlite_sequence").size
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["c"])
  assert_equal 1, conn.last_insert_id
  fresh = DB::Connection.new(":memory:")
  assert_nil Dialect.reset_sequences(fresh, ["posts"])
  fresh.close
  conn.close
end

test "foreign_key_violation describes the first dangling row, and the migrator's check lists them" do
  conn = blog_db
  assert_equal "", Dialect.foreign_key_violation(conn)
  assert_equal "", Dialect.migrator_foreign_key_check(conn)
  Dialect.foreign_keys_off(conn)
  conn.execute("INSERT INTO comments (id, post_id, body) VALUES (5, 999, 'x')")
  Dialect.foreign_keys_on(conn)
  assert_equal "comments row with id 5 has post_id 999, which names no row of posts", Dialect.foreign_key_violation(conn)
  assert_equal "comments row 5 -> posts", Dialect.migrator_foreign_key_check(conn)
  conn.close
end

test "transactional_ddl? is true and ddl_statements is SqliteDDL's" do
  assert_equal true, Dialect.transactional_ddl?
  migration = AddViews.new
  migration.change
  ops = migration.operations
  assert_equal ["ALTER TABLE posts ADD COLUMN score INTEGER NOT NULL DEFAULT 0"], Dialect.ddl_statements(ops[0])
  assert_equal ["CREATE INDEX index_posts_on_title ON posts(title)"], Dialect.ddl_statements(ops[1])
end

test "now_epoch_usec_sql reads the clock in epoch microseconds" do
  conn = blog_db
  before = Time.now.to_i * 1_000_000
  now = Cybertrain::Cast.int(conn.execute("SELECT #{Dialect.now_epoch_usec_sql} AS n")[0]["n"])
  after = (Time.now.to_i + 1) * 1_000_000
  assert before - 1_000_000 <= now
  assert now <= after + 1_000_000
  conn.close
end

test "the aggregate float total is TOTAL" do
  assert_equal "TOTAL(v)", Dialect.relation_float_total("v")
  assert_equal "TOTAL(DISTINCT `views`)", Dialect.relation_float_total("DISTINCT `views`")
end

test "the schema readers answer SQLite's table_info, index_list, index_info and foreign_key_list rows" do
  conn = blog_db
  columns = Dialect.schema_columns(conn, "posts")
  assert_equal ["id", "title", "views"], columns.map { |r| r["name"].to_s }
  assert_equal "TEXT", columns[1]["type"].to_s
  assert_equal 1, Cybertrain::Cast.int(columns[1]["notnull"])
  assert_equal "0", Cybertrain::Cast.str_or_nil(columns[2]["dflt_value"]).to_s
  assert_equal 1, Cybertrain::Cast.int(columns[0]["pk"])
  indexes = Dialect.schema_index_rows(conn, "comments")
  assert_equal ["index_comments_on_post_id"], indexes.map { |r| r["name"].to_s }
  assert_equal 0, Cybertrain::Cast.int(indexes[0]["unique"])
  assert_equal "CREATE INDEX index_comments_on_post_id ON comments (post_id)",
               Dialect.schema_index_sql(conn, "comments", "index_comments_on_post_id")
  assert_equal "", Dialect.schema_index_sql(conn, "comments", "missing")
  assert_equal ["post_id"], Dialect.schema_index_columns(conn, "comments", "index_comments_on_post_id")
  keys = Dialect.schema_foreign_key_rows(conn, "comments")
  assert_equal 1, keys.size
  assert_equal "posts", keys[0]["table"].to_s
  assert_equal "post_id", keys[0]["from"].to_s
  assert_equal "NO ACTION", keys[0]["on_delete"].to_s
  conn.close
end

test "the service statements are the ones the services sent" do
  assert_equal "INSERT INTO cybertrain_schedules (name, last_run_at, next_run_at, updated_at) " \
               "VALUES (?, NULL, ?, ?) ON CONFLICT(name) DO NOTHING", Dialect.timetable_insert_missing_sql
  assert_equal "INSERT INTO cybertrain_schedules (name, last_run_at, next_run_at, updated_at) " \
               "VALUES (?, NULLIF(?, 0), ?, ?) " \
               "ON CONFLICT(name) DO UPDATE SET last_run_at = excluded.last_run_at, " \
               "next_run_at = excluded.next_run_at, updated_at = excluded.updated_at " \
               "WHERE COALESCE(excluded.last_run_at, 0) > COALESCE(cybertrain_schedules.last_run_at, 0) " \
               "OR (COALESCE(excluded.last_run_at, 0) = COALESCE(cybertrain_schedules.last_run_at, 0) " \
               "AND excluded.next_run_at >= cybertrain_schedules.next_run_at)", Dialect.timetable_write_sql
end

test "the cache and lease writes answer whether a row changed" do
  conn = DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE cybertrain_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, " \
                   "expires_at INTEGER, updated_at INTEGER NOT NULL); " \
                   "CREATE TABLE cybertrain_leases (name TEXT PRIMARY KEY, holder TEXT NOT NULL, expires_at INTEGER NOT NULL);")
  assert_equal true, Dialect.cache_write(conn, "k", "v", 0, 100, false)
  assert_equal false, Dialect.cache_write(conn, "k", "w", 0, 100, true)
  assert_equal 3, Dialect.cache_increment(conn, "n", 3, 0, 100)
  assert_equal 5, Dialect.cache_increment(conn, "n", 2, 0, 100)
  assert_equal true, Dialect.cache_write(conn, "e", "x", 150, 100, false)
  assert_equal 1, Dialect.cache_prune(conn, 200, 1000)
  assert_equal 0, Dialect.cache_prune(conn, 200, 1000)
  assert_equal true, Dialect.lease_acquire(conn, "l", "a", 160, 100)
  assert_equal false, Dialect.lease_acquire(conn, "l", "b", 170, 110)
  assert_equal true, Dialect.lease_acquire(conn, "l", "b", 270, 200)
  conn.close
end

Cybertrain::Test.run!
