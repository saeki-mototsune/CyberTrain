require "cybertrain/db/connection"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/test"

# The migrations that rebuild a table (change_column, change_column_default,
# change_column_null, remove_reference, remove_foreign_key), rename_table and
# reversible, run by the Migrator against a live database: the schema SQLite
# reports afterwards, the rows that survive, the indexes, triggers and
# AUTOINCREMENT high-water mark that come back, foreign keys switched off
# around the rebuild (so ON DELETE CASCADE does not fire on the children)
# and checked before the commit, and the rollbacks.
#
# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class CreateBlog < Cybertrain::Migration::Base
  version "20260301000000"

  def change
    create_table "posts" do |t|
      t.string "title"
      t.text "body"
      t.integer "views", default: "0"
    end
    add_index "posts", ["title"]
    create_table "comments" do |t|
      t.references :post, on_delete: :cascade
      t.string "body", null: false
    end
  end
end

class ChangeViewsToString < Cybertrain::Migration::Base
  version "20260301000100"

  def up
    change_column :posts, :views, :string, null: false, default: "'none'", limit: 20
  end

  def down
    change_column :posts, :views, :integer, default: "0"
  end
end

class ChangeViewsInChange < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    change_column :posts, :views, :string
  end
end

class ChangeViewsDefault < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    change_column_default :posts, :views, from: "0", to: "10"
  end
end

class ChangeViewsDefaultBlind < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    change_column_default :posts, :views, to: "10"
  end
end

class TitleNotNull < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    change_column_null :posts, :title, false, "untitled"
  end
end

class TitleNotNullPlain < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    change_column_null :posts, :title, false
  end
end

class CommentBodyNullable < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    change_column_null :comments, :body, true
  end
end

class RemovePostReference < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    remove_reference :comments, :post
  end
end

class RemovePostForeignKey < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    remove_foreign_key :comments, :posts
  end
end

class RenamePosts < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    rename_table :posts, :articles
  end
end

class FillSlugs < Cybertrain::Migration::Base
  version "20260301000100"

  def change
    add_column "posts", "slug", :string
    reversible do |dir|
      dir.up { execute "UPDATE posts SET slug = 'up-' || title" }
      dir.down { execute "INSERT INTO posts (title) VALUES ('down ran')" }
    end
  end
end

# A rebuild in a version that also leaves an orphan behind: the foreign key
# check before the commit finds it and the version rolls back.
class OrphanAndRebuild < Cybertrain::Migration::Base
  version "20260301000100"

  def up
    execute "INSERT INTO comments (post_id, body) VALUES (999, 'orphan')"
    change_column_default :posts, :views, from: "0", to: "1"
  end

  def down
  end
end

def blog_migrations(second)
  [["20260301000000", CreateBlog.new], ["20260301000100", second]]
end

# CreateBlog applied, with two posts ("first", and one with no title) and
# two comments on the first.
def blog
  connection = Cybertrain::DB::Connection.new(":memory:")
  Cybertrain::DB::Migrator.new(connection).migrate([["20260301000000", CreateBlog.new]])
  connection.execute("INSERT INTO posts (title, body, views) VALUES ('first', 'one', 5)")
  connection.execute("INSERT INTO posts (title, body, views) VALUES (NULL, 'two', 7)")
  connection.execute("INSERT INTO comments (post_id, body) VALUES (1, 'a')")
  connection.execute("INSERT INTO comments (post_id, body) VALUES (1, 'b')")
  connection
end

def migrate_blog(connection, second)
  Cybertrain::DB::Migrator.new(connection).migrate(blog_migrations(second))
end

def rollback_blog(connection, second)
  Cybertrain::DB::Migrator.new(connection).rollback(blog_migrations(second))
end

# "name type notnull dflt" for one column of PRAGMA table_info; "" when the
# column does not exist.
def column_info(connection, table, column)
  connection.execute("PRAGMA table_info(#{table})").each do |r|
    next unless r["name"].to_s == column
    default = Cybertrain::Cast.str_or_nil(r["dflt_value"])
    return "#{r["name"]} #{r["type"]} #{r["notnull"]} #{default.nil? ? "nil" : default}"
  end
  ""
end

def index_names(connection, table)
  connection.execute("PRAGMA index_list(#{table})").map { |r| r["name"].to_s }.sort
end

# "from->table on_delete" per foreign key of `table`.
def foreign_keys(connection, table)
  connection.execute("PRAGMA foreign_key_list(#{table})").map { |r| "#{r["from"]}->#{r["table"]} #{r["on_delete"]}" }
end

def column_values(connection, sql)
  connection.execute(sql).map { |r| r["v"].to_s }
end

def foreign_keys_enforced(connection)
  Cybertrain::Cast.int(connection.execute("PRAGMA foreign_keys")[0]["foreign_keys"])
end

test "change_column rebuilds the column with its new type, null and default, keeping rows and indexes" do
  connection = blog
  migrate_blog(connection, ChangeViewsToString.new)
  assert_equal "views VARCHAR(20) 1 'none'", column_info(connection, "posts", "views")
  assert_equal ["5", "7"], column_values(connection, "SELECT views AS v FROM posts ORDER BY id")
  assert_equal ["first", ""], column_values(connection, "SELECT title AS v FROM posts ORDER BY id")
  assert_equal ["index_posts_on_title"], index_names(connection, "posts")
  assert_equal 2, column_values(connection, "SELECT body AS v FROM comments").size
  rollback_blog(connection, ChangeViewsToString.new)
  assert_equal "views INTEGER 0 0", column_info(connection, "posts", "views")
  assert_equal ["5", "7"], column_values(connection, "SELECT views AS v FROM posts ORDER BY id")
  connection.close
end

test "change_column in change is irreversible" do
  connection = blog
  migrate_blog(connection, ChangeViewsInChange.new)
  assert_equal "views VARCHAR 0 nil", column_info(connection, "posts", "views")
  message = assert_raises("IrreversibleMigration") { rollback_blog(connection, ChangeViewsInChange.new) }
  assert_includes message, "change_column"
  connection.close
end

test "change_column_default with from: and to: changes the default and rolls back" do
  connection = blog
  migrate_blog(connection, ChangeViewsDefault.new)
  assert_equal "views INTEGER 0 10", column_info(connection, "posts", "views")
  connection.execute("INSERT INTO posts (title) VALUES ('third')")
  assert_equal ["5", "7", "10"], column_values(connection, "SELECT views AS v FROM posts ORDER BY id")
  rollback_blog(connection, ChangeViewsDefault.new)
  assert_equal "views INTEGER 0 0", column_info(connection, "posts", "views")
  connection.close
end

test "change_column_default without from: is irreversible" do
  connection = blog
  migrate_blog(connection, ChangeViewsDefaultBlind.new)
  assert_equal "views INTEGER 0 10", column_info(connection, "posts", "views")
  message = assert_raises("IrreversibleMigration") { rollback_blog(connection, ChangeViewsDefaultBlind.new) }
  assert_includes message, "from:"
  connection.close
end

test "change_column_null false with a default backfills the NULL cells and writes no DEFAULT" do
  connection = blog
  migrate_blog(connection, TitleNotNull.new)
  assert_equal "title VARCHAR 1 nil", column_info(connection, "posts", "title")
  assert_equal ["first", "untitled"], column_values(connection, "SELECT title AS v FROM posts ORDER BY id")
  rollback_blog(connection, TitleNotNull.new)
  assert_equal "title VARCHAR 0 nil", column_info(connection, "posts", "title")
  assert_equal ["first", "untitled"], column_values(connection, "SELECT title AS v FROM posts ORDER BY id")
  connection.close
end

test "change_column_null false over a NULL cell without a default fails and leaves the table as it was" do
  connection = blog
  message = assert_raises("Cybertrain::DB::Error") { migrate_blog(connection, TitleNotNullPlain.new) }
  assert_includes message, "NOT NULL"
  assert_equal "title VARCHAR 0 nil", column_info(connection, "posts", "title")
  assert_equal ["20260301000000"], Cybertrain::DB::Migrator.new(connection).applied_versions
  assert_equal 1, foreign_keys_enforced(connection)
  connection.close
end

test "change_column_null true has no inverse without a default for the NULL cells" do
  connection = blog
  migrate_blog(connection, CommentBodyNullable.new)
  assert_equal "body VARCHAR 0 nil", column_info(connection, "comments", "body")
  assert_raises("IrreversibleMigration") { rollback_blog(connection, CommentBodyNullable.new) }
  connection.close
end

test "remove_reference drops the column, its index and its foreign key, keeping the rows" do
  connection = blog
  migrate_blog(connection, RemovePostReference.new)
  assert_equal "", column_info(connection, "comments", "post_id")
  assert_equal [], index_names(connection, "comments")
  assert_equal [], foreign_keys(connection, "comments")
  assert_equal ["a", "b"], column_values(connection, "SELECT body AS v FROM comments ORDER BY id")
  assert_raises("IrreversibleMigration") { rollback_blog(connection, RemovePostReference.new) }
  connection.close
end

test "remove_foreign_key drops the constraint and keeps the column and its index" do
  connection = blog
  assert_equal ["post_id->posts CASCADE"], foreign_keys(connection, "comments")
  migrate_blog(connection, RemovePostForeignKey.new)
  assert_equal [], foreign_keys(connection, "comments")
  assert_equal "post_id INTEGER 1 nil", column_info(connection, "comments", "post_id")
  assert_equal ["index_comments_on_post_id"], index_names(connection, "comments")
  # Nothing enforces the reference any more.
  connection.execute("INSERT INTO comments (post_id, body) VALUES (999, 'loose')")
  assert_raises("IrreversibleMigration") { rollback_blog(connection, RemovePostForeignKey.new) }
  connection.close
end

test "rename_table renames the table, its children follow, and rollback renames it back" do
  connection = blog
  migrate_blog(connection, RenamePosts.new)
  assert_equal ["first", ""], column_values(connection, "SELECT title AS v FROM articles ORDER BY id")
  assert_equal ["post_id->articles CASCADE"], foreign_keys(connection, "comments")
  rollback_blog(connection, RenamePosts.new)
  assert_equal ["first", ""], column_values(connection, "SELECT title AS v FROM posts ORDER BY id")
  assert_equal ["post_id->posts CASCADE"], foreign_keys(connection, "comments")
  connection.close
end

test "a trigger on the rebuilt table is recreated and still fires" do
  connection = blog
  connection.exec_script("CREATE TABLE audits (note TEXT)")
  connection.exec_script("CREATE TRIGGER posts_audit AFTER INSERT ON posts BEGIN INSERT INTO audits (note) VALUES (NEW.title); END")
  migrate_blog(connection, ChangeViewsDefault.new)
  triggers = column_values(connection, "SELECT name AS v FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'posts'")
  assert_equal ["posts_audit"], triggers
  connection.execute("INSERT INTO posts (title) VALUES ('after')")
  assert_equal ["after"], column_values(connection, "SELECT note AS v FROM audits")
  connection.close
end

test "a deleted row's id is not reused after a rebuild" do
  connection = blog
  connection.execute("INSERT INTO posts (title) VALUES ('third')")
  connection.execute("DELETE FROM posts WHERE id = 3")
  migrate_blog(connection, ChangeViewsDefault.new)
  connection.execute("INSERT INTO posts (title) VALUES ('fourth')")
  assert_equal ["1", "2", "4"], column_values(connection, "SELECT id AS v FROM posts ORDER BY id")
  connection.close
end

test "an emptied table keeps its high-water mark through a rebuild" do
  connection = blog
  connection.execute("DELETE FROM comments")
  migrate_blog(connection, RemovePostForeignKey.new)
  connection.execute("INSERT INTO comments (post_id, body) VALUES (1, 'c')")
  assert_equal ["3"], column_values(connection, "SELECT id AS v FROM comments")
  connection.close
end

test "reversible runs the up block forward and the down block on rollback" do
  connection = blog
  migrate_blog(connection, FillSlugs.new)
  assert_equal ["up-first", ""], column_values(connection, "SELECT slug AS v FROM posts ORDER BY id")
  assert_equal 0, column_values(connection, "SELECT id AS v FROM posts WHERE title = 'down ran'").size
  rollback_blog(connection, FillSlugs.new)
  assert_equal "", column_info(connection, "posts", "slug")
  assert_equal 1, column_values(connection, "SELECT id AS v FROM posts WHERE title = 'down ran'").size
  connection.close
end

# Review Focus 5: with foreign keys left on, DROP TABLE posts would cascade
# to the comments.
test "rebuilding a parent keeps the children an ON DELETE CASCADE points at" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  Cybertrain::DB::Migrator.new(connection).migrate([["20260301000000", CreateBlog.new]])
  connection.execute("INSERT INTO posts (title) VALUES ('first')")
  connection.execute("INSERT INTO comments (post_id, body) VALUES (1, 'a')")
  connection.execute("INSERT INTO comments (post_id, body) VALUES (1, 'b')")
  migrate_blog(connection, TitleNotNullPlain.new)
  assert_equal "title VARCHAR 1 nil", column_info(connection, "posts", "title")
  assert_equal ["a", "b"], column_values(connection, "SELECT body AS v FROM comments ORDER BY id")
  # Enforcement is back on afterwards: deleting the post cascades now.
  assert_equal 1, foreign_keys_enforced(connection)
  connection.execute("DELETE FROM posts WHERE id = 1")
  assert_equal 0, column_values(connection, "SELECT body AS v FROM comments").size
  connection.close
end

test "a foreign key violation found before the commit rolls the version back" do
  connection = blog
  message = assert_raises("Cybertrain::DB::Error") { migrate_blog(connection, OrphanAndRebuild.new) }
  assert_includes message, "foreign key check failed after rebuilding posts"
  assert_includes message, "comments"
  assert_equal "views INTEGER 0 0", column_info(connection, "posts", "views")
  assert_equal 2, column_values(connection, "SELECT body AS v FROM comments").size
  assert_equal ["20260301000000"], Cybertrain::DB::Migrator.new(connection).applied_versions
  assert_equal 1, foreign_keys_enforced(connection)
  connection.close
end

test "a table Rails created rebuilds with its expression and partial indexes" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  connection.exec_script(<<~SQL)
    CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
    INSERT INTO schema_migrations VALUES ('20250101000000');
    CREATE TABLE "posts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "title" varchar, "body" text, "views" bigint DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL);
    CREATE UNIQUE INDEX "index_posts_on_lower_title" ON "posts" (LOWER(title));
    CREATE INDEX "index_posts_on_views" ON "posts" ("views") WHERE views > 0;
    CREATE TABLE "comments" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "post_id" integer NOT NULL, "body" varchar NOT NULL, CONSTRAINT "fk_rails_1" FOREIGN KEY ("post_id") REFERENCES "posts" ("id") ON DELETE CASCADE);
    INSERT INTO posts (title, views, created_at) VALUES ('first', 3, '2026-01-01 00:00:00.000000');
    INSERT INTO comments (post_id, body) VALUES (1, 'a');
  SQL
  # Rails' version has no file here: the migrator leaves it alone.
  migrator = Cybertrain::DB::Migrator.new(connection)
  assert_equal 1, migrator.migrate([["20260301000100", TitleNotNull.new]])
  assert_equal ["20250101000000", "20260301000100"], migrator.applied_versions
  assert_equal "title VARCHAR 1 nil", column_info(connection, "posts", "title")
  assert_equal "views BIGINT 1 0", column_info(connection, "posts", "views")
  assert_equal ["index_posts_on_lower_title", "index_posts_on_views"], index_names(connection, "posts")
  ruby = Cybertrain::DB::SchemaDumper.dump_to_ruby(connection)
  assert_includes ruby, "s.add_index \"posts\", \"LOWER(title)\", unique: true, name: \"index_posts_on_lower_title\""
  assert_includes ruby, "s.add_index \"posts\", [\"views\"], name: \"index_posts_on_views\", where: \"views > 0\""
  assert_equal ["a"], column_values(connection, "SELECT body AS v FROM comments")
  connection.close
end

Cybertrain::Test.run!
