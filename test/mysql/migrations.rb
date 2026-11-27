require "cybertrain/cast"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/schema/dumper"
require "cybertrain/test"
require_relative "support/tables"
require_relative "../../examples/blog/db/migrate/20260925174942_create_articles"
require_relative "../../examples/blog/db/migrate/20260925174943_create_comments"
require_relative "../../examples/blog/db/migrate/20261112102827_create_users"
require_relative "../../examples/blog/db/migrate/20261112102828_create_sessions"
require_relative "../../examples/blog/db/migrate/20261112174320_add_cover_to_articles"

# The Migrator, MySQL's DDL (cybertrain/db/mysql/ddl.rb) and SchemaDumper on
# MySQL, against the server CYBERTRAIN_TEST_MYSQL_URL names
# (script/test-mysql runs this program): examples/blog/db/migrate applied
# and dumped back into examples/blog/db/schema.rb's text, rolled back and
# reported by status; a version that fails at its second statement
# (reported, not recorded: MySQL's DDL commits as it runs); the column,
# index and foreign key operations, and the ones SQLite rebuilds a table
# for, which MySQL does with one ALTER TABLE.
#
# What SchemaDumper cannot dump as it does from SQLite, from the same
# migrations (the dump of the blog's has none of them):
# - a string with `limit: 255` dumps without it: VARCHAR(255) is also what
#   a string without a limit is on MySQL;
# - a decimal with precision 10 and scale 0 dumps as a plain decimal
#   (MySQL's DECIMAL is DECIMAL(10,0)); one with a precision and no scale
#   dumps with scale 0;
# - an integer column named `*_id` is a BIGINT (a reference's type) and
#   dumps as a plain integer, a `t.bigint "*_id"` included;
# - a default on a text, json or binary column is an expression on MySQL
#   (`DEFAULT ('{}')`) and dumps as MySQL spells the expression
#   (`(_utf8mb4'{}')`); so does any expression default (CURRENT_TIMESTAMP(6));
#   a decimal's default dumps with its scale ("0.00" for "0");
# - an expression index dumps with MySQL's text of the expression, each
#   key part in its parentheses (`(lower(`email`))` for `LOWER(email)`);
# - a foreign key with no index on its column (`references ..., index:
#   false`) gets one from MySQL, named after the column, which is dumped;
# - a partial index (`where:`) does not exist: gen refuses it, and so does
#   the DDL ("partial indexes (where:) are not supported on MySQL").
# The tables are this program's own (MySQLTestTables.drop, by name);
# the dump is compared over the blog's tables only, since the database may
# hold other programs' tables.

DB = Cybertrain::DB
Dialect = Cybertrain::DB::Dialect

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

BLOG_TABLES = ["articles", "comments", "sessions", "users"]
OWN_TABLES = ["articles", "comments", "sessions", "users", "schema_migrations", "mig_parents", "mig_children",
              "mig_items"]

def fresh_db
  conn = DB::Connection.new(URL)
  MySQLTestTables.drop(conn, OWN_TABLES)
  conn
end

def blog_migrations
  [["20260925174942", CreateArticles.new], ["20260925174943", CreateComments.new],
   ["20261112102827", CreateUsers.new], ["20261112102828", CreateSessions.new],
   ["20261112174320", AddCoverToArticles.new]]
end

# The dump of `tables` alone, as db/schema.rb's text.
def dump_of(conn, tables)
  full = DB::SchemaDumper.dump(conn)
  only = Cybertrain::Schema::Definition.new(full.version)
  full.tables.each { |t| only.tables << t if tables.include?(t.name) }
  Cybertrain::Schema::Dumper.to_ruby(only)
end

def show_create(conn, table)
  Cybertrain::Cast.str(conn.execute("SHOW CREATE TABLE #{Dialect.quote_ident(table)}")[0]["Create Table"])
end

def versions(conn)
  conn.execute("SELECT version FROM schema_migrations ORDER BY version").map { |r| Cybertrain::Cast.str(r["version"]) }
end

def print_status(migrator, migrations)
  migrator.status(migrations).each { |row| puts "  #{row[0]} #{row[1]} #{row[2]}" }
  nil
end

test "examples/blog/db/migrate applied on MySQL dumps examples/blog/db/schema.rb" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  assert_equal 5, migrator.migrate(blog_migrations)
  assert_equal File.read("examples/blog/db/schema.rb"), dump_of(conn, BLOG_TABLES)
  conn.close
end

test "the CREATE TABLE has the BIGINT id, BIGINT references and the table options" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrator.migrate(blog_migrations)
  comments = show_create(conn, "comments")
  assert_includes comments, "`id` bigint NOT NULL AUTO_INCREMENT"
  assert_includes comments, "`article_id` bigint NOT NULL"
  assert_includes comments, "`body` mediumtext"
  assert_includes comments, "`created_at` datetime(6) NOT NULL"
  assert_includes comments, "KEY `index_comments_on_article_id` (`article_id`)"
  assert_includes comments, "FOREIGN KEY (`article_id`) REFERENCES `articles` (`id`)"
  assert_includes comments, "ENGINE=InnoDB"
  assert_includes comments, "DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
  users = show_create(conn, "users")
  assert_includes users, "`admin` tinyint(1) NOT NULL DEFAULT '0'"
  assert_includes users, "`email_address` varchar(255) COLLATE utf8mb4_0900_bin NOT NULL"
  assert_includes users, "UNIQUE KEY `index_users_on_email_address` (`email_address`)"
  conn.close
end

test "rollback and status, step by step" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrations = blog_migrations
  migrator.migrate(migrations)
  print_status(migrator, migrations)
  assert_equal 2, migrator.rollback(migrations, 2)
  print_status(migrator, migrations)
  assert_equal ["20260925174942", "20260925174943", "20261112102827"], versions(conn)
  refute Dialect.table_exists?(conn, "sessions")
  assert_equal ["id", "title", "body", "created_at", "updated_at"], Dialect.column_names(conn, "articles")
  assert_equal 2, migrator.migrate(migrations)
  print_status(migrator, migrations)
  assert_equal File.read("examples/blog/db/schema.rb"), dump_of(conn, BLOG_TABLES)
  conn.close
end

class CreateMigParents < Cybertrain::Migration::Base
  def change
    create_table "mig_parents" do |t|
      t.string "name", null: false
    end
  end
end

# Its second statement fails (the column exists by then); the first stays.
class AddTwiceToMigParents < Cybertrain::Migration::Base
  def change
    add_column "mig_parents", "rank", :integer
    add_column "mig_parents", "rank", :integer
    add_column "mig_parents", "score", :integer
  end
end

test "a version failing at its second statement says what was applied and is not recorded" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrations = [["20270101000000", CreateMigParents.new], ["20270101000100", AddTwiceToMigParents.new]]
  message = assert_raises("DB::Error") { migrator.migrate(migrations) }
  assert_equal "migration 20270101000100 failed at statement 2 of 3; statements 1..1 were applied and cannot be " \
               "rolled back (MySQL DDL commits implicitly): Duplicate column name 'rank' (MySQL 1060, 42S21) " \
               "(sql: ALTER TABLE `mig_parents` ADD COLUMN `rank` INT)", message
  assert_equal ["20270101000000"], versions(conn)
  assert_equal ["id", "name", "rank"], Dialect.column_names(conn, "mig_parents")
  conn.close
end

class CreateMigItems < Cybertrain::Migration::Base
  def change
    create_table "mig_items" do |t|
      t.string "title", null: false, limit: 80
      t.text "body"
      t.decimal "price", precision: 10, scale: 2
      t.float "ratio"
      t.date "due_on"
      t.json "meta"
      t.binary "data"
      t.bigint "views", null: false, default: "0"
      t.string "state", null: false, default: "'draft'"
    end
  end
end

class ReshapeMigItems < Cybertrain::Migration::Base
  def up
    add_column "mig_items", "subtitle", :string
    rename_column "mig_items", "body", "content"
    remove_column "mig_items", "ratio"
    add_index "mig_items", ["title"], unique: true
    add_index "mig_items", ["state", "due_on"]
  end

  def down
    remove_index "mig_items", ["state", "due_on"]
    remove_index "mig_items", ["title"]
    add_column "mig_items", "ratio", :float
    rename_column "mig_items", "content", "body"
    remove_column "mig_items", "subtitle"
  end
end

class PartialIndexOnMigItems < Cybertrain::Migration::Base
  def change
    add_index "mig_items", ["state"], where: "state = 'draft'"
  end
end

test "add, remove and rename a column; unique and multi-column indexes; a partial index is refused" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrations = [["20270201000000", CreateMigItems.new], ["20270201000100", ReshapeMigItems.new]]
  migrator.migrate(migrations)
  puts dump_of(conn, ["mig_items"])
  assert_equal ["id", "title", "content", "price", "due_on", "meta", "data", "views", "state", "subtitle"],
               Dialect.column_names(conn, "mig_items")
  conn.execute("INSERT INTO mig_items (title) VALUES ('a')")
  assert_raises("DB::UniqueViolation") { conn.execute("INSERT INTO mig_items (title) VALUES ('a')") }
  assert_equal "draft", Cybertrain::Cast.str(conn.execute("SELECT state FROM mig_items")[0]["state"])
  assert_equal 1, migrator.rollback(migrations, 1)
  assert_equal ["id", "title", "body", "price", "due_on", "meta", "data", "views", "state", "ratio"],
               Dialect.column_names(conn, "mig_items")
  assert_equal Array.new(0) { "" }, Dialect.schema_index_rows(conn, "mig_items").map { |r| Cybertrain::Cast.str(r["name"]) }
  partial = [["20270201000200", PartialIndexOnMigItems.new]]
  message = assert_raises("DB::Error") { migrator.migrate(partial) }
  assert_equal "partial indexes (where:) are not supported on MySQL", message
  assert_equal ["20270201000000"], versions(conn)
  conn.close
end

class LowerTitleOnMigItems < Cybertrain::Migration::Base
  def change
    create_table "mig_items" do |t|
      t.string "title", null: false
    end
    execute "CREATE INDEX index_mig_items_on_lower_title ON mig_items ((LOWER(title)), id)"
  end
end

test "an expression index dumps with MySQL's text of its expression" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrator.migrate([["20270201000300", LowerTitleOnMigItems.new]])
  puts dump_of(conn, ["mig_items"])
  assert_equal "CREATE INDEX `index_mig_items_on_lower_title` ON `mig_items` ((lower(`title`)), `id`)",
               Dialect.schema_index_sql(conn, "mig_items", "index_mig_items_on_lower_title")
  # The dumped key declares the index again.
  table = DB::SchemaDumper.dump(conn).table("mig_items")
  conn.exec_script("DROP TABLE mig_items")
  conn.exec_script(DB::MySQL::DDL.create_table_sql(table))
  assert_equal ["index_mig_items_on_lower_title"],
               Dialect.schema_index_rows(conn, "mig_items").map { |r| Cybertrain::Cast.str(r["name"]) }
  conn.close
end

class CreateMigChildren < Cybertrain::Migration::Base
  def change
    create_table "mig_children" do |t|
      t.references :mig_parent, on_delete: :cascade
      t.string "label"
    end
  end
end

class AddOwnerToMigChildren < Cybertrain::Migration::Base
  def up
    add_reference "mig_children", :owner, null: true, foreign_key: false
    add_foreign_key "mig_children", "mig_parents", column: "owner_id", on_delete: :nullify
  end

  def down
    remove_foreign_key "mig_children", "mig_parents", column: "owner_id"
    remove_column "mig_children", "owner_id"
  end
end

test "foreign keys: ON DELETE CASCADE in create_table, SET NULL added to a table, both dumped" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrations = [["20270301000000", CreateMigParents.new], ["20270301000100", CreateMigChildren.new],
                ["20270301000200", AddOwnerToMigChildren.new]]
  migrator.migrate(migrations)
  puts dump_of(conn, ["mig_parents", "mig_children"])
  conn.execute("INSERT INTO mig_parents (name) VALUES ('a'), ('b')")
  conn.execute("INSERT INTO mig_children (mig_parent_id, owner_id, label) VALUES (1, 2, 'x')")
  assert_raises("DB::ForeignKeyViolation") { conn.execute("INSERT INTO mig_children (mig_parent_id) VALUES (99)") }
  conn.execute("DELETE FROM mig_parents WHERE id = 2")
  assert_nil conn.execute("SELECT owner_id FROM mig_children")[0]["owner_id"]
  conn.execute("DELETE FROM mig_parents WHERE id = 1")
  assert_equal 0, Cybertrain::Cast.int(conn.execute("SELECT COUNT(*) AS n FROM mig_children")[0]["n"])
  assert_equal 1, migrator.rollback(migrations, 1)
  assert_equal 1, Dialect.schema_foreign_key_rows(conn, "mig_children").size
  assert_equal ["id", "mig_parent_id", "label"], Dialect.column_names(conn, "mig_children")
  conn.close
end

class ChangeMigChildren < Cybertrain::Migration::Base
  def up
    change_column "mig_children", "label", :string, null: false, default: "'none'", limit: 40
    change_column_default "mig_children", "label", from: "'none'", to: "'unnamed'"
    change_column_null "mig_children", "mig_parent_id", true
    remove_foreign_key "mig_children", "mig_parents"
  end

  def down
    add_foreign_key "mig_children", "mig_parents", on_delete: :cascade
    change_column_null "mig_children", "mig_parent_id", false
    change_column "mig_children", "label", :string
  end
end

class DropParentFromMigChildren < Cybertrain::Migration::Base
  def up
    remove_reference "mig_children", :mig_parent
  end

  def down
    add_reference "mig_children", :mig_parent, null: true, on_delete: :cascade
  end
end

class BackfillMigChildren < Cybertrain::Migration::Base
  def change
    change_column_null "mig_children", "label", false, "blank"
  end
end

test "the operations SQLite rebuilds a table for are one ALTER TABLE each on MySQL" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrations = [["20270401000000", CreateMigParents.new], ["20270401000100", CreateMigChildren.new],
                ["20270401000200", ChangeMigChildren.new]]
  migrator.migrate(migrations)
  puts dump_of(conn, ["mig_parents", "mig_children"])
  conn.execute("INSERT INTO mig_children (mig_parent_id) VALUES (NULL)")
  assert_equal "unnamed", Cybertrain::Cast.str(conn.execute("SELECT label FROM mig_children")[0]["label"])
  conn.execute("DELETE FROM mig_children")
  assert_equal 1, migrator.rollback(migrations, 1)
  puts dump_of(conn, ["mig_parents", "mig_children"])
  drop = [["20270401000300", DropParentFromMigChildren.new]]
  migrator.migrate(drop)
  assert_equal ["id", "label"], Dialect.column_names(conn, "mig_children")
  assert_equal 0, Dialect.schema_foreign_key_rows(conn, "mig_children").size
  assert_equal 0, Dialect.schema_index_rows(conn, "mig_children").size
  assert_equal 1, migrator.rollback(drop, 1)
  puts dump_of(conn, ["mig_children"])
  conn.execute("INSERT INTO mig_children (label) VALUES (NULL), ('kept')")
  migrator.migrate([["20270401000400", BackfillMigChildren.new]])
  labels = conn.execute("SELECT label FROM mig_children ORDER BY id").map { |r| Cybertrain::Cast.str(r["label"]) }
  assert_equal ["blank", "kept"], labels
  assert_includes show_create(conn, "mig_children"), "`label` varchar(255) COLLATE utf8mb4_0900_bin NOT NULL"
  conn.close
end

Cybertrain::Test.run!
