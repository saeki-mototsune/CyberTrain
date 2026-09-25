require "cybertrain/db/connection"
require "cybertrain/db/migrator"
require "cybertrain/test"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class CreatePosts < Cybertrain::Migration::Base
  version "20260101000000"

  def change
    create_table "posts" do |t|
      t.string "title", null: false
      t.integer "views", default: "0"
    end
    add_index "posts", ["title"]
  end
end

class CreateComments < Cybertrain::Migration::Base
  version "20260101000100"

  def change
    create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
    end
  end
end

def fresh_migrations
  [["20260101000000", CreatePosts.new], ["20260101000100", CreateComments.new]]
end

def table_names(connection)
  rows = connection.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
  rows.map { |r| r["name"].to_s }
end

test "migrate applies pending migrations in order and records their versions" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  count = migrator.migrate(fresh_migrations)
  assert_equal 2, count
  assert_equal ["20260101000000", "20260101000100"], migrator.applied_versions
  assert_includes table_names(connection), "posts"
  assert_includes table_names(connection), "comments"
  connection.close
end

test "status reports up/down per migration in the order given" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  before = migrator.status(migrations)
  assert_equal [["down", "20260101000000", "CreatePosts"], ["down", "20260101000100", "CreateComments"]], before
  migrator.migrate(migrations)
  after = migrator.status(migrations)
  assert_equal [["up", "20260101000000", "CreatePosts"], ["up", "20260101000100", "CreateComments"]], after
  connection.close
end

test "a second migrate call is a no-op" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrator.migrate(migrations)
  assert_equal 0, migrator.migrate(migrations)
  assert_equal ["20260101000000", "20260101000100"], migrator.applied_versions
  connection.close
end

test "pending excludes already-applied versions" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  assert_equal 2, migrator.pending(migrations).size
  migrator.migrate([migrations[0]])
  remaining = migrator.pending(migrations)
  assert_equal 1, remaining.size
  assert_equal "20260101000100", remaining[0][0]
  connection.close
end

test "rollback drops the last applied migration, and re-migrating restores it" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrator.migrate(migrations)

  reverted = migrator.rollback(migrations)
  assert_equal 1, reverted
  assert_equal ["20260101000000"], migrator.applied_versions
  refute table_names(connection).include?("comments")
  assert_includes table_names(connection), "posts"

  reapplied = migrator.migrate(migrations)
  assert_equal 1, reapplied
  assert_equal ["20260101000000", "20260101000100"], migrator.applied_versions
  assert_includes table_names(connection), "comments"
  connection.close
end

test "rollback(steps: 2) reverts both migrations back to empty" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrator.migrate(migrations)
  reverted = migrator.rollback(migrations, 2)
  assert_equal 2, reverted
  assert_equal [], migrator.applied_versions
  refute table_names(connection).include?("posts")
  refute table_names(connection).include?("comments")
  connection.close
end

class AddSlugToPosts < Cybertrain::Migration::Base
  version "20260101000200"

  def up
    add_column "posts", "slug", :string
  end

  def down
    remove_column "posts", "slug"
  end
end

class BrokenMigration < Cybertrain::Migration::Base
  version "20260101000300"

  def change
    create_table "widgets" do |t|
      t.string "name"
    end
    add_column "no_such_table", "x", :integer
  end
end

def column_names(connection, table)
  rows = connection.execute("PRAGMA table_info(#{table})")
  rows.map { |r| r["name"].to_s }
end

test "rollback uses a migration's own down when it defines up/down" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrations << ["20260101000200", AddSlugToPosts.new]
  assert_equal 3, migrator.migrate(migrations)
  assert_includes column_names(connection, "posts"), "slug"
  assert_equal 1, migrator.rollback(migrations)
  refute column_names(connection, "posts").include?("slug")
  assert_equal ["20260101000000", "20260101000100"], migrator.applied_versions
  connection.close
end

test "a failing migration rolls back its transaction and records nothing" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrations << ["20260101000300", BrokenMigration.new]
  message = assert_raises("Cybertrain::DB::Error") { migrator.migrate(migrations) }
  assert_includes message, "no_such_table"
  assert_equal ["20260101000000", "20260101000100"], migrator.applied_versions
  refute table_names(connection).include?("widgets")
  connection.close
end

# --- SqliteDDL.statements, one operation kind at a time.

DDL = Cybertrain::DB::SqliteDDL

test "SqliteDDL.statements for :create_table includes the table and its indexes" do
  migration = CreatePosts.new
  migration.up
  create_op = migration.operations[0]
  assert_equal :create_table, create_op.kind
  stmts = DDL.statements(create_op)
  assert_equal 1, stmts.size
  assert_equal(
    "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title VARCHAR NOT NULL, views INTEGER DEFAULT 0)",
    stmts[0]
  )

  index_op = migration.operations[1]
  assert_equal ["CREATE INDEX index_posts_on_title ON posts(title)"], DDL.statements(index_op)
end

test "SqliteDDL.statements for :create_table with references emits the foreign key inline" do
  migration = CreateComments.new
  migration.up
  create_op = migration.operations[0]
  stmts = DDL.statements(create_op)
  assert_equal 2, stmts.size
  assert_equal(
    "CREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER NOT NULL, commenter VARCHAR NOT NULL, " \
    "FOREIGN KEY (post_id) REFERENCES posts(id))",
    stmts[0]
  )
  assert_equal "CREATE INDEX index_comments_on_post_id ON comments(post_id)", stmts[1]
end

test "SqliteDDL.create_table declares a SQL type per schema type" do
  table = Cybertrain::Schema::Table.new("things")
  t = Cybertrain::Schema::TableDef.new(table)
  t.string "name", limit: 80
  t.text "notes"
  t.integer "count", null: false, default: "0"
  t.float "ratio"
  t.boolean "active", default: "1"
  t.datetime "seen_at"
  t.date "born_on"
  assert_equal(
    "CREATE TABLE things (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(80), notes TEXT, " \
    "count INTEGER NOT NULL DEFAULT 0, ratio REAL, active BOOLEAN DEFAULT 1, seen_at DATETIME, born_on DATE)",
    DDL.create_table(table)
  )
end

test "SqliteDDL.statements for :drop_table" do
  migration = CreatePosts.new
  migration.drop_table("widgets")
  assert_equal ["DROP TABLE widgets"], DDL.statements(migration.operations[0])
end

test "SqliteDDL.statements for :add_column" do
  migration = CreatePosts.new
  migration.add_column("posts", "slug", :string, null: false)
  assert_equal ["ALTER TABLE posts ADD COLUMN slug VARCHAR NOT NULL"], DDL.statements(migration.operations[0])
end

test "SqliteDDL.statements for :remove_column" do
  migration = CreatePosts.new
  migration.remove_column("posts", "slug")
  assert_equal ["ALTER TABLE posts DROP COLUMN slug"], DDL.statements(migration.operations[0])
end

test "SqliteDDL.statements for :rename_column" do
  migration = CreatePosts.new
  migration.rename_column("posts", "title", "headline")
  assert_equal ["ALTER TABLE posts RENAME COLUMN title TO headline"], DDL.statements(migration.operations[0])
end

test "SqliteDDL.statements for :add_index" do
  migration = CreatePosts.new
  migration.add_index("posts", ["title"], unique: true)
  assert_equal ["CREATE UNIQUE INDEX index_posts_on_title ON posts(title)"], DDL.statements(migration.operations[0])
end

test "SqliteDDL.statements for :remove_index" do
  migration = CreatePosts.new
  migration.remove_index("posts", ["title"])
  assert_equal ["DROP INDEX index_posts_on_title"], DDL.statements(migration.operations[0])
end

test "SqliteDDL.statements for :add_reference adds the column and its index" do
  migration = CreatePosts.new
  migration.add_reference("comments", "author", foreign_key: false)
  assert_equal(
    ["ALTER TABLE comments ADD COLUMN author_id INTEGER NOT NULL", "CREATE INDEX index_comments_on_author_id ON comments(author_id)"],
    DDL.statements(migration.operations[0])
  )
end

test "SqliteDDL.statements for :add_foreign_key raises IrreversibleMigration" do
  migration = CreatePosts.new
  migration.add_foreign_key("comments", "posts")
  op = migration.operations[migration.operations.size - 1]
  assert_equal :add_foreign_key, op.kind
  message = assert_raises("IrreversibleMigration") { DDL.statements(op) }
  assert_includes message, "declare it in create_table"
end

# --- add_reference with its default foreign_key: true folds the foreign key
# into the ADD COLUMN (SQLite accepts REFERENCES inline there).

class CreateNotes < Cybertrain::Migration::Base
  version "20260101000400"

  def change
    create_table "notes" do |t|
      t.string "text"
    end
  end
end

class AddPostToNotes < Cybertrain::Migration::Base
  version "20260101000500"

  def change
    add_reference "notes", :post
  end
end

class AddStandaloneForeignKey < Cybertrain::Migration::Base
  version "20260101000600"

  def change
    add_foreign_key "notes", "posts"
  end
end

def index_names(connection, table)
  rows = connection.execute("PRAGMA index_list(#{table})")
  rows.map { |r| r["name"].to_s }.sort
end

test "a default add_reference adds the column, its index and the foreign key" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrations << ["20260101000400", CreateNotes.new]
  migrations << ["20260101000500", AddPostToNotes.new]
  assert_equal 4, migrator.migrate(migrations)
  assert_includes column_names(connection, "notes"), "post_id"
  assert_includes index_names(connection, "notes"), "index_notes_on_post_id"
  fks = connection.execute("PRAGMA foreign_key_list(notes)")
  assert_equal 1, fks.size
  assert_equal "posts", fks[0]["table"].to_s
  assert_equal "post_id", fks[0]["from"].to_s
  assert_equal "id", fks[0]["to"].to_s
  connection.close
end

test "a standalone add_foreign_key still raises IrreversibleMigration and records nothing" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrations << ["20260101000400", CreateNotes.new]
  migrations << ["20260101000600", AddStandaloneForeignKey.new]
  message = assert_raises("IrreversibleMigration") { migrator.migrate(migrations) }
  assert_includes message, "declare it in create_table"
  assert_equal ["20260101000000", "20260101000100", "20260101000400"], migrator.applied_versions
  connection.close
end

test "SqliteDDL folds an add_foreign_key that directly follows its add_reference" do
  migration = CreatePosts.new
  migration.add_reference("comments", :post)
  ref_op = migration.operations[0]
  fk_op = migration.operations[1]
  assert_equal :add_foreign_key, fk_op.kind
  assert DDL.folds_foreign_key?(ref_op, fk_op)
  assert_equal(
    ["ALTER TABLE comments ADD COLUMN post_id INTEGER NOT NULL REFERENCES posts(id)",
     "CREATE INDEX index_comments_on_post_id ON comments(post_id)"],
    DDL.add_reference_statements(ref_op, fk_op.to_table)
  )
  other = CreatePosts.new
  other.add_reference("comments", :post, foreign_key: false)
  other.add_foreign_key("comments", "authors", column: "author_id")
  refute DDL.folds_foreign_key?(other.operations[0], other.operations[1])
  refute DDL.folds_foreign_key?(ref_op, ref_op)
end

# --- Rolling back a named index drops that index, not the derived name.

class IndexPostsByTitle < Cybertrain::Migration::Base
  version "20260101000700"

  def change
    add_index "posts", ["title"], name: "by_title"
  end
end

class IndexPostsByViews < Cybertrain::Migration::Base
  version "20260101000800"

  def change
    add_index "posts", ["views"], name: "by_views"
  end
end

class DropViewsIndex < Cybertrain::Migration::Base
  version "20260101000900"

  def up
    remove_index "posts", ["views"]
  end

  def down
    add_index "posts", ["views"], name: "by_views"
  end
end

test "rolling back add_index with name: drops the named index" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrations << ["20260101000700", IndexPostsByTitle.new]
  assert_equal 3, migrator.migrate(migrations)
  assert_equal ["by_title", "index_posts_on_title"], index_names(connection, "posts")
  assert_equal 1, migrator.rollback(migrations)
  assert_equal ["index_posts_on_title"], index_names(connection, "posts")
  assert_equal ["20260101000000", "20260101000100"], migrator.applied_versions
  connection.close
end

test "remove_index by columns finds a named index on those columns" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrations << ["20260101000800", IndexPostsByViews.new]
  migrations << ["20260101000900", DropViewsIndex.new]
  assert_equal 4, migrator.migrate(migrations)
  assert_equal ["index_posts_on_title"], index_names(connection, "posts")
  assert_equal 1, migrator.rollback(migrations)
  assert_equal ["by_views", "index_posts_on_title"], index_names(connection, "posts")
  assert_equal 1, migrator.rollback(migrations)
  assert_equal ["index_posts_on_title"], index_names(connection, "posts")
  connection.close
end

# --- An applied version with no migration in the list is an error.

test "rollback raises when the newest applied version has no migration" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = fresh_migrations
  migrator.migrate(migrations)
  connection.execute("INSERT INTO schema_migrations (version) VALUES (?)", ["4"])
  message = assert_raises("Cybertrain::DB::Error") { migrator.rollback(migrations) }
  assert_includes message, "4"
  assert_equal ["20260101000000", "20260101000100", "4"], migrator.applied_versions
  message = assert_raises("Cybertrain::DB::Error") { migrator.rollback(migrations, 2) }
  assert_includes message, "no migration for applied version 4"
  assert_includes table_names(connection), "comments"
  connection.close
end

Cybertrain::Test.run!
