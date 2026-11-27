require "cybertrain/cast"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/config"
require "cybertrain/migration"
require "cybertrain/relation"
require "cybertrain/test"

# Cybertrain::DB::Dialect and DB::Adapter on MySQL, against the server
# CYBERTRAIN_TEST_MYSQL_URL names (script/test-mysql runs this program):
# test/db_dialect_sqlite.rb's cases with MySQL's answers, each method run
# against real tables. The methods whose callers come with later tasks (the
# schema readers and the migrator's, Test::Database's, the services'
# statements) are checked here directly. The tables are hand-written MySQL
# DDL (the plan's Task 10 generates DDL); every table of the test database
# is dropped first.

DB = Cybertrain::DB
Dialect = Cybertrain::DB::Dialect

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"

# Every table of the test database dropped, then the blog's: posts,
# comments (a foreign key and its index) and a framework table.
def blog_db
  conn = DB::Connection.new(URL)
  Dialect.foreign_keys_off(conn)
  Dialect.table_names(conn).each do |name|
    quoted = Dialect.quote_ident(name)
    conn.exec_script("DROP TABLE #{quoted}")
  end
  Dialect.foreign_keys_on(conn)
  conn.exec_script(
    "CREATE TABLE posts (id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255) NOT NULL, views INT DEFAULT 0)" \
    "#{TABLE_OPTIONS}; " \
    "CREATE TABLE comments (id BIGINT AUTO_INCREMENT PRIMARY KEY, post_id BIGINT, body MEDIUMTEXT, " \
    "KEY index_comments_on_post_id (post_id), " \
    "CONSTRAINT fk_comments_post FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE)#{TABLE_OPTIONS}; " \
    "CREATE TABLE cybertrain_jobs (id BIGINT PRIMARY KEY, kind MEDIUMTEXT)#{TABLE_OPTIONS};"
  )
  conn
end

def checks(conn)
  Cybertrain::Cast.int(conn.execute("SELECT @@foreign_key_checks AS n")[0]["n"])
end

class AddViews < Cybertrain::Migration::Base
  def change
    add_column "posts", "score", :integer, null: false, default: "0"
  end
end

test "the adapter is mysql and connects to the configured URL" do
  assert_equal "mysql", DB::Adapter.adapter_name
  config = Cybertrain::Config.new
  config.database_url = "mysql://u:p@db.internal/app"
  assert_equal "mysql://u:p@db.internal/app", DB::Adapter.connect_target(config)
end

test "quote_ident wraps a name in backticks and doubles an embedded one" do
  assert_equal "`posts`", Dialect.quote_ident("posts")
  assert_equal "`a``b`", Dialect.quote_ident("a`b")
  assert_equal "`a\"b`", Dialect.quote_ident("a\"b")
  assert_equal Dialect.quote_ident("a`b"), Cybertrain::Relation.quote_ident("a`b")
  conn = blog_db
  conn.exec_script("CREATE TABLE `a``b` (`c``d` INT)#{TABLE_OPTIONS}")
  conn.execute("INSERT INTO #{Dialect.quote_ident("a`b")} (#{Dialect.quote_ident("c`d")}) VALUES (?)", [7])
  assert_equal 7, conn.execute("SELECT #{Dialect.quote_ident("c`d")} AS n FROM #{Dialect.quote_ident("a`b")}")[0]["n"]
  conn.close
end

test "upsert_tail is the row alias's ON DUPLICATE KEY UPDATE c = excluded.c, c = c without columns" do
  assert_equal " AS excluded ON DUPLICATE KEY UPDATE a = excluded.a, b = excluded.b",
               Dialect.upsert_tail(["name"], ["a", "b"])
  assert_equal " ON DUPLICATE KEY UPDATE `x` = `x`", Dialect.upsert_tail(["`x`", "`y`"], Array.new(0) { "" })
  assert_equal " AS excluded ON DUPLICATE KEY UPDATE `n` = `t`.`n` + 1",
               Dialect.bulk_writes_upsert_tail(["`k`"], ["`n` = `t`.`n` + 1"])
  assert_equal " ON DUPLICATE KEY UPDATE `id` = `id`", Dialect.bulk_writes_ignore_tail
  assert_equal "", Dialect.bulk_writes_returning_tail(["`id`", "`title`"])
  assert_equal false, Dialect.returning?
  conn = blog_db
  conn.exec_script("CREATE TABLE stats (`k` VARCHAR(10) PRIMARY KEY, `n` INT NOT NULL)#{TABLE_OPTIONS}")
  sql = "INSERT INTO stats (`k`, `n`) VALUES (?, ?)" + Dialect.bulk_writes_upsert_tail(["`k`"], ["`n` = stats.`n` + excluded.`n`"])
  conn.execute(sql, ["a", 2])
  conn.execute(sql, ["a", 3])
  assert_equal 5, conn.execute("SELECT n FROM stats")[0]["n"]
  conn.execute("INSERT INTO stats (`k`, `n`) VALUES (?, ?)" + Dialect.upsert_tail(["`k`"], Array.new(0) { "" }), ["a", 9])
  assert_equal 5, conn.execute("SELECT n FROM stats")[0]["n"]
  conn.close
end

test "LAST_INSERT_ID marks: 0 for an INSERT that made no id, else its first" do
  conn = blog_db
  conn.execute("INSERT INTO posts (id, title) VALUES (?, ?)", [40, "x"])
  assert_nil Dialect.bulk_writes_mark_insert_id(conn)
  conn.execute("INSERT INTO posts (title) VALUES (?), (?), (?)", ["a", "b", "c"])
  assert_equal 41, Dialect.bulk_writes_first_insert_id(conn)
  Dialect.bulk_writes_mark_insert_id(conn)
  conn.execute("INSERT INTO posts (id, title) VALUES (?, ?) ON DUPLICATE KEY UPDATE `id` = `id`", [41, "dup"])
  assert_equal 0, Dialect.bulk_writes_first_insert_id(conn)
  conn.close
end

test "table_names lists the tables of the connected database" do
  conn = blog_db
  assert_equal ["comments", "cybertrain_jobs", "posts"], Dialect.table_names(conn)
  assert_equal true, Dialect.table_exists?(conn, "posts")
  assert_equal false, Dialect.table_exists?(conn, "missing")
  assert_equal ["id", "title", "views"], Dialect.column_names(conn, "posts")
  assert_equal 0, Dialect.column_names(conn, "missing").size
  conn.close
end

test "health_query answers one row" do
  conn = blog_db
  assert_equal "SELECT 1 AS n", Dialect.health_query
  rows = conn.execute(Dialect.health_query)
  assert_equal 1, rows.size
  assert_equal 1, rows[0]["n"]
  conn.close
end

test "foreign_keys_off and foreign_keys_on toggle the session's checks" do
  conn = blog_db
  assert_equal 1, checks(conn)
  assert_nil Dialect.foreign_keys_off(conn)
  assert_equal 0, checks(conn)
  assert_equal false, Dialect.migrator_foreign_keys_enforced?(conn)
  assert_nil Dialect.foreign_keys_on(conn)
  assert_equal 1, checks(conn)
  assert_equal true, Dialect.migrator_foreign_keys_enforced?(conn)
  conn.close
end

test "reset_sequences sets AUTO_INCREMENT back so ids start again at 1" do
  conn = blog_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["a"])
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["b"])
  conn.execute("DELETE FROM posts")
  assert_nil Dialect.reset_sequences(conn, ["posts", "comments"])
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["c"])
  assert_equal 1, conn.last_insert_id
  conn.close
end

test "foreign_key_violation describes the first dangling row, and the migrator's check lists them" do
  conn = blog_db
  assert_equal "", Dialect.foreign_key_violation(conn)
  assert_equal "", Dialect.migrator_foreign_key_check(conn)
  Dialect.foreign_keys_off(conn)
  conn.execute("INSERT INTO comments (id, post_id, body) VALUES (5, 999, 'x')")
  conn.execute("INSERT INTO comments (id, post_id, body) VALUES (6, 998, 'y')")
  Dialect.foreign_keys_on(conn)
  assert_equal "comments row with id 5 has post_id 999, which names no row of posts", Dialect.foreign_key_violation(conn)
  assert_equal "comments row 5 -> posts, comments row 6 -> posts", Dialect.migrator_foreign_key_check(conn)
  conn.close
end

test "transactional_ddl? is false; ddl_statements and migrator_rebuild wait for MySQL's DDL" do
  assert_equal false, Dialect.transactional_ddl?
  migration = AddViews.new
  migration.change
  ops = migration.operations
  message = assert_raises("DB::Error") { Dialect.ddl_statements(ops[0]) }
  assert_includes message, "add_column: migrations on MySQL are not available yet"
  conn = blog_db
  assert_raises("DB::Error") { Dialect.migrator_rebuild(conn, ops[0], Cybertrain::Schema::Definition.new("1")) }
  conn.close
end

test "now_epoch_usec_sql reads the clock in UTC epoch microseconds" do
  conn = blog_db
  before = Time.now.to_i * 1_000_000
  now = Cybertrain::Cast.int(conn.execute("SELECT #{Dialect.now_epoch_usec_sql} AS n")[0]["n"])
  after = (Time.now.to_i + 1) * 1_000_000
  assert before - 1_000_000 <= now
  assert now <= after + 1_000_000
  conn.close
end

test "the relation pieces: a float total, a derived table's alias, LIKE's escape, no limit, a window of ids" do
  assert_equal "COALESCE(SUM(v), 0e0)", Dialect.relation_float_total("v")
  assert_equal " AS cybertrain_sub", Dialect.relation_subquery_alias
  assert_equal " ESCAPE '\\\\'", Dialect.relation_like_escape
  assert_equal "18446744073709551615", Dialect.relation_no_limit
  assert_equal "SELECT `id` FROM (SELECT `id` FROM t LIMIT 1) AS cybertrain_sub",
               Dialect.relation_window_ids("`id`", "SELECT `id` FROM t LIMIT 1")
  conn = blog_db
  assert_equal 0.0, conn.execute("SELECT #{Dialect.relation_float_total("views")} AS n FROM posts")[0]["n"]
  conn.execute("INSERT INTO posts (title, views) VALUES ('a', 2), ('b', 3)")
  assert_equal 5.0, conn.execute("SELECT #{Dialect.relation_float_total("views")} AS n FROM posts")[0]["n"]
  conn.close
end

test "the schema readers answer name/type/notnull/dflt_value/pk, indexes and foreign keys" do
  conn = blog_db
  columns = Dialect.schema_columns(conn, "posts")
  assert_equal ["id", "title", "views"], columns.map { |r| r["name"].to_s }
  assert_equal "varchar(255)", columns[1]["type"].to_s
  assert_equal 1, Cybertrain::Cast.int(columns[1]["notnull"])
  assert_equal 0, Cybertrain::Cast.int(columns[2]["notnull"])
  assert_equal "0", Cybertrain::Cast.str_or_nil(columns[2]["dflt_value"]).to_s
  assert_nil columns[1]["dflt_value"]
  assert_equal 1, Cybertrain::Cast.int(columns[0]["pk"])
  assert_equal 0, Cybertrain::Cast.int(columns[1]["pk"])
  indexes = Dialect.schema_index_rows(conn, "comments")
  assert_equal ["index_comments_on_post_id"], indexes.map { |r| r["name"].to_s }
  assert_equal 0, Cybertrain::Cast.int(indexes[0]["unique"])
  assert_equal "", Dialect.schema_index_sql(conn, "comments", "index_comments_on_post_id")
  assert_equal ["post_id"], Dialect.schema_index_columns(conn, "comments", "index_comments_on_post_id")
  keys = Dialect.schema_foreign_key_rows(conn, "comments")
  assert_equal 1, keys.size
  assert_equal "posts", keys[0]["table"].to_s
  assert_equal "post_id", keys[0]["from"].to_s
  assert_equal "CASCADE", keys[0]["on_delete"].to_s
  conn.close
end

test "Test::Database's clear empties a table; the mark is nothing on MySQL" do
  conn = blog_db
  conn.execute("INSERT INTO posts (title) VALUES ('a'), ('b')")
  assert_nil Dialect.test_database_clear_table(conn, "posts")
  assert_equal 0, conn.execute("SELECT COUNT(*) AS n FROM posts")[0]["n"]
  assert_nil Dialect.test_database_mark(conn, 7)
  conn.close
end

SERVICE_TABLES = "CREATE TABLE cybertrain_cache (`key` VARCHAR(255) PRIMARY KEY, value MEDIUMTEXT NOT NULL, " \
                 "expires_at BIGINT, updated_at BIGINT NOT NULL)#{TABLE_OPTIONS}; " \
                 "CREATE TABLE cybertrain_leases (name VARCHAR(255) PRIMARY KEY, holder VARCHAR(255) NOT NULL, " \
                 "expires_at BIGINT NOT NULL)#{TABLE_OPTIONS}; " \
                 "CREATE TABLE cybertrain_schedules (name VARCHAR(255) PRIMARY KEY, last_run_at BIGINT, " \
                 "next_run_at BIGINT NOT NULL, updated_at BIGINT NOT NULL)#{TABLE_OPTIONS}; " \
                 "CREATE TABLE cybertrain_feeds (name VARCHAR(255) PRIMARY KEY, process VARCHAR(255), connected INT, " \
                 "started_at BIGINT NOT NULL, last_activity_at BIGINT, restarts INT, updated_at BIGINT NOT NULL)" \
                 "#{TABLE_OPTIONS};"

def schedule(conn)
  row = conn.execute("SELECT last_run_at AS l, next_run_at AS n, updated_at AS u FROM cybertrain_schedules")[0]
  "#{row["l"].inspect} #{row["n"]} #{row["u"]}"
end

test "the timetable and feed statements: a row never moves backwards, a missing one is added once" do
  conn = blog_db
  conn.exec_script(SERVICE_TABLES)
  conn.execute(Dialect.timetable_insert_missing_sql, Cybertrain::Cast.binds("t", 100, 1))
  conn.execute(Dialect.timetable_insert_missing_sql, Cybertrain::Cast.binds("t", 999, 2))
  assert_equal "nil 100 1", schedule(conn)
  conn.execute(Dialect.timetable_write_sql, Cybertrain::Cast.binds("t", 50, 200, 3))
  assert_equal "50 200 3", schedule(conn)
  # An earlier last run, or the same one with an earlier next run: unchanged.
  conn.execute(Dialect.timetable_write_sql, Cybertrain::Cast.binds("t", 40, 300, 4))
  assert_equal "50 200 3", schedule(conn)
  conn.execute(Dialect.timetable_write_sql, Cybertrain::Cast.binds("t", 50, 150, 5))
  assert_equal "50 200 3", schedule(conn)
  conn.execute(Dialect.timetable_write_sql, Cybertrain::Cast.binds("t", 50, 250, 6))
  assert_equal "50 250 6", schedule(conn)
  conn.execute(Dialect.timetable_write_sql, Cybertrain::Cast.binds("t", 60, 100, 7))
  assert_equal "60 100 7", schedule(conn)
  conn.execute(Dialect.feed_table_write_sql, Cybertrain::Cast.binds("f", "p1", 1, 10, 0, 0, 11))
  conn.execute(Dialect.feed_table_write_sql, Cybertrain::Cast.binds("f", "p2", 0, 20, 21, 1, 22))
  row = conn.execute("SELECT process, connected, started_at, last_activity_at, restarts, updated_at FROM cybertrain_feeds")
  assert_equal 1, row.size
  assert_equal ["p2", 0, 20, 21, 1, 22], [row[0]["process"], row[0]["connected"], row[0]["started_at"],
                                          row[0]["last_activity_at"], row[0]["restarts"], row[0]["updated_at"]]
  conn.close
end

test "the cache and lease writes answer whether a row changed" do
  conn = blog_db
  conn.exec_script(SERVICE_TABLES)
  assert_equal true, Dialect.cache_write(conn, "k", "v", 0, 100, false)
  assert_equal false, Dialect.cache_write(conn, "k", "w", 0, 100, true)
  assert_equal "v", conn.execute("SELECT value FROM cybertrain_cache WHERE `key` = 'k'")[0]["value"]
  # An expired row is replaced by write(unless_exist: true).
  assert_equal true, Dialect.cache_write(conn, "old", "a", 50, 10, false)
  assert_equal true, Dialect.cache_write(conn, "old", "b", 0, 100, true)
  assert_equal "b", conn.execute("SELECT value FROM cybertrain_cache WHERE `key` = 'old'")[0]["value"]
  assert_equal 3, Dialect.cache_increment(conn, "n", 3, 0, 100)
  assert_equal 5, Dialect.cache_increment(conn, "n", 2, 0, 100)
  # Text that is not a number counts as 0; leading digits are read.
  Dialect.cache_write(conn, "t", "abc", 0, 100, false)
  assert_equal 4, Dialect.cache_increment(conn, "t", 4, 0, 100)
  Dialect.cache_write(conn, "d", " 12px", 0, 100, false)
  assert_equal 13, Dialect.cache_increment(conn, "d", 1, 0, 100)
  # An expired counter starts again at `by`.
  Dialect.cache_write(conn, "x", "40", 150, 100, false)
  assert_equal 2, Dialect.cache_increment(conn, "x", 2, 0, 200)
  assert_equal false, conn.in_transaction?
  assert_equal true, Dialect.cache_write(conn, "e", "x", 150, 100, false)
  assert_equal 1, Dialect.cache_prune(conn, 200, 1000)
  assert_equal 0, Dialect.cache_prune(conn, 200, 1000)
  assert_equal true, Dialect.lease_acquire(conn, "l", "a", 160, 100)
  assert_equal true, Dialect.lease_acquire(conn, "l", "a", 160, 105)
  assert_equal false, Dialect.lease_acquire(conn, "l", "b", 170, 110)
  assert_equal true, Dialect.lease_acquire(conn, "l", "b", 270, 200)
  assert_equal false, Dialect.lease_acquire(conn, "l", "a", 280, 210)
  conn.close
end

Cybertrain::Test.run!
