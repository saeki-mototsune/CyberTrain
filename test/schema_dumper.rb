require "cybertrain/db/connection"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/test"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class CreatePosts < Cybertrain::Migration::Base
  version "20260101000000"

  def change
    create_table "posts" do |t|
      t.string "title", null: false, limit: 120
      t.text "body", null: false
      t.integer "views", null: false, default: "0"
      t.float "rating"
      t.boolean "published", null: false, default: "0"
      t.date "published_on"
      t.string "slug", null: false
      t.timestamps
    end
    add_index "posts", ["slug"], unique: true
  end
end

class CreateComments < Cybertrain::Migration::Base
  version "20260101000100"

  def change
    create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
      t.text "body", null: false
      t.timestamps
    end
  end
end

def migrated_connection
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrations = [["20260101000000", CreatePosts.new], ["20260101000100", CreateComments.new]]
  Cybertrain::DB::Migrator.new(connection).migrate(migrations)
  connection
end

test "dump reproduces tables, columns, types, null and defaults" do
  connection = migrated_connection
  definition = Cybertrain::DB::SchemaDumper.dump(connection)
  assert_equal ["comments", "posts"], definition.tables.map { |t| t.name }

  posts = definition.table("posts")
  names = posts.columns.map { |c| c.name }
  assert_equal ["title", "body", "views", "rating", "published", "published_on", "slug", "created_at", "updated_at"], names
  types = posts.columns.map { |c| c.type.to_s }
  assert_equal ["string", "text", "integer", "float", "boolean", "date", "string", "datetime", "datetime"], types

  title = posts.column("title")
  refute title.null
  assert_equal 120, title.limit
  assert_nil title.default
  assert posts.column("rating").null
  assert_equal "0", posts.column("views").default
  assert_equal "0", posts.column("published").default
  connection.close
end

test "dump excludes schema_migrations and sqlite_* tables and never lists the id column" do
  connection = migrated_connection
  definition = Cybertrain::DB::SchemaDumper.dump(connection)
  assert_nil definition.table("schema_migrations")
  assert_nil definition.table("sqlite_sequence")
  assert_nil definition.table("comments").column("id")
  connection.close
end

test "dump reproduces indexes and foreign keys" do
  connection = migrated_connection
  definition = Cybertrain::DB::SchemaDumper.dump(connection)

  comments = definition.table("comments")
  assert_equal 1, comments.indexes.size
  assert_equal "index_comments_on_post_id", comments.indexes[0].name
  assert_equal ["post_id"], comments.indexes[0].columns
  refute comments.indexes[0].unique
  assert_equal 1, comments.references.size
  assert_equal "post_id", comments.references[0].column
  assert_equal "posts", comments.references[0].to_table

  posts = definition.table("posts")
  assert_equal 1, posts.indexes.size
  assert posts.indexes[0].unique
  assert_equal ["slug"], posts.indexes[0].columns
  assert_equal 0, posts.references.size
  connection.close
end

test "dump takes its version from the newest applied migration" do
  connection = migrated_connection
  assert_equal "20260101000100", Cybertrain::DB::SchemaDumper.dump(connection).version
  connection.close
end

test "a database no migrator has touched dumps version 0 and no tables" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  definition = Cybertrain::DB::SchemaDumper.dump(connection)
  assert_equal "0", definition.version
  assert_equal 0, definition.tables.size
  connection.close
end

EXPECTED_SCHEMA = <<~RUBY
  Cybertrain::Schema.define(version: "20260101000100") do |s|
    s.create_table "comments" do |t|
      t.integer "post_id", null: false
      t.string "commenter", null: false
      t.text "body", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    s.create_table "posts" do |t|
      t.string "title", null: false, limit: 120
      t.text "body", null: false
      t.integer "views", null: false, default: "0"
      t.float "rating"
      t.boolean "published", null: false, default: "0"
      t.date "published_on"
      t.string "slug", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    s.add_index "comments", ["post_id"], name: "index_comments_on_post_id"
    s.add_index "posts", ["slug"], unique: true, name: "index_posts_on_slug"

    s.add_foreign_key "comments", "posts", column: "post_id"
  end
RUBY

test "dump_to_ruby renders the db/schema.rb text" do
  connection = migrated_connection
  assert_equal EXPECTED_SCHEMA, Cybertrain::DB::SchemaDumper.dump_to_ruby(connection)
  connection.close
end

test "the dumped schema loads back into an identical dump" do
  connection = migrated_connection
  first = Cybertrain::DB::SchemaDumper.dump(connection)
  again = Cybertrain::Schema.define(version: first.version) do |s|
    s.create_table "comments" do |t|
      t.integer "post_id", null: false
      t.string "commenter", null: false
      t.text "body", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end
    s.create_table "posts" do |t|
      t.string "title", null: false, limit: 120
      t.text "body", null: false
      t.integer "views", null: false, default: "0"
      t.float "rating"
      t.boolean "published", null: false, default: "0"
      t.date "published_on"
      t.string "slug", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end
    s.add_index "comments", ["post_id"], name: "index_comments_on_post_id"
    s.add_index "posts", ["slug"], unique: true, name: "index_posts_on_slug"
    s.add_foreign_key "comments", "posts", column: "post_id"
  end
  assert_equal Cybertrain::Schema::Dumper.to_ruby(first), Cybertrain::Schema::Dumper.to_ruby(again)
  connection.close
end

Cybertrain::Test.run!
