require "cybertrain/cast"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/model"
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

Cybertrain::Test.run!
