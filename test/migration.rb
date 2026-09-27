require "cybertrain/migration"
require "cybertrain/test"

class CreatePosts < Cybertrain::Migration::Base
  version "20260101000000"

  def change
    create_table "posts" do |t|
      t.string "title", null: false
      t.text "body", null: false
      t.timestamps
    end
    add_index "posts", ["title"]
  end
end

class AddCommentsTable < Cybertrain::Migration::Base
  version "20260102000000"

  def change
    create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
    end
  end
end

class DropsATable < Cybertrain::Migration::Base
  version "20260103000000"

  def change
    drop_table "widgets"
  end
end

test "change records operations in call order" do
  migration = CreatePosts.new
  migration.up
  kinds = migration.operations.map { |op| op.kind }
  assert_equal [:create_table, :add_index], kinds

  create_op = migration.operations[0]
  assert_equal "posts", create_op.table.name
  assert_equal 4, create_op.table.columns.size

  index_op = migration.operations[1]
  assert_equal "posts", index_op.table
  assert_equal ["title"], index_op.columns
  refute index_op.unique
end

test "add_reference records an add_reference operation and, by default, an add_foreign_key operation" do
  migration = AddCommentsTable.new
  migration.up
  create_op = migration.operations[0]
  assert_equal :create_table, create_op.kind
  assert_equal 2, create_op.table.columns.size

  # references() inside create_table only touches the Table being built, so
  # the add_reference/add_foreign_key DSL methods on Base itself are
  # exercised directly here instead.
  standalone = AddCommentsTable.new
  standalone.add_reference("comments", "author")
  kinds = standalone.operations.map { |op| op.kind }
  assert_equal [:add_reference, :add_foreign_key], kinds
  assert_equal "author_id", standalone.operations[0].name
  refute standalone.operations[0].null
  assert_equal "authors", standalone.operations[1].to_table
  assert_equal "author_id", standalone.operations[1].name
end

test "add_reference(foreign_key: false) records only the add_reference operation" do
  migration = AddCommentsTable.new
  migration.add_reference("comments", "editor", foreign_key: false)
  kinds = migration.operations.map { |op| op.kind }
  assert_equal [:add_reference], kinds
end

test "add_foreign_key defaults its column to singularize(to_table) + _id" do
  migration = AddCommentsTable.new
  migration.add_foreign_key("comments", "posts")
  op = migration.operations[0]
  assert_equal :add_foreign_key, op.kind
  assert_equal "comments", op.table
  assert_equal "posts", op.to_table
  assert_equal "post_id", op.name
end

test "add_reference and add_foreign_key inflect irregular and compound names through Cybertrain::Inflector" do
  migration = AddCommentsTable.new
  migration.add_reference("comments", "person")
  migration.add_reference("comments", "blog_post")
  migration.add_foreign_key("comments", "people")
  migration.add_foreign_key("comments", "blog_posts")
  ops = migration.operations
  assert_equal 6, ops.size
  assert_equal "people", ops[1].to_table
  assert_equal "person_id", ops[1].name
  assert_equal "blog_posts", ops[3].to_table
  assert_equal "blog_post_id", ops[3].name
  assert_equal "people", ops[4].to_table
  assert_equal "person_id", ops[4].name
  assert_equal "blog_posts", ops[5].to_table
  assert_equal "blog_post_id", ops[5].name
end

test "inverse of create_table is drop_table" do
  migration = CreatePosts.new
  migration.up
  inverse = migration.inverse(migration.operations[0])
  assert_equal :drop_table, inverse.kind
  assert_equal "posts", inverse.table
end

test "inverse of add_column is remove_column" do
  migration = CreatePosts.new
  migration.add_column("posts", "views", :integer, default: "0")
  op = migration.operations[migration.operations.size - 1]
  inverse = migration.inverse(op)
  assert_equal :remove_column, inverse.kind
  assert_equal "posts", inverse.table
  assert_equal "views", inverse.name
end

test "inverse of add_index is remove_index" do
  migration = CreatePosts.new
  migration.up
  inverse = migration.inverse(migration.operations[1])
  assert_equal :remove_index, inverse.kind
  assert_equal "posts", inverse.table
  assert_equal ["title"], inverse.columns
end

test "inverse of rename_column reverses the direction" do
  migration = CreatePosts.new
  migration.rename_column("posts", "title", "headline")
  op = migration.operations[migration.operations.size - 1]
  inverse = migration.inverse(op)
  assert_equal :rename_column, inverse.kind
  assert_equal "posts", inverse.table
  assert_equal "headline", inverse.name
  assert_equal "title", inverse.new_name
end

test "inverse raises IrreversibleMigration for a kind with no automatic down" do
  migration = CreatePosts.new
  migration.remove_column("posts", "title")
  op = migration.operations[0]
  assert_equal :remove_column, op.kind
  assert_raises("IrreversibleMigration") { migration.inverse(op) }
end

test "register/all order migrations by version regardless of registration order" do
  Cybertrain::Migration.reset!
  later = AddCommentsTable.new
  earlier = CreatePosts.new
  Cybertrain::Migration.register("20260102000000", later)
  Cybertrain::Migration.register("20260101000000", earlier)

  all = Cybertrain::Migration.all
  assert_equal 2, all.size
  assert_equal "20260101000000", all[0][0]
  assert_equal earlier, all[0][1]
  assert_equal "20260102000000", all[1][0]
  assert_equal later, all[1][1]

  Cybertrain::Migration.reset!
  assert_equal [], Cybertrain::Migration.all
end

test "self.version / self.version_string are per-subclass" do
  assert_equal "20260101000000", CreatePosts.version_string
  assert_equal "20260102000000", AddCommentsTable.version_string
end

test "up resets operations, so calling it twice does not duplicate them" do
  migration = CreatePosts.new
  migration.up
  migration.up
  kinds = migration.operations.map { |op| op.kind }
  assert_equal [:create_table, :add_index], kinds
end

test "down on a change-only migration replays the inverse operations in reverse order" do
  migration = CreatePosts.new
  migration.down
  kinds = migration.operations.map { |op| op.kind }
  assert_equal [:remove_index, :drop_table], kinds

  remove_index_op = migration.operations[0]
  assert_equal "posts", remove_index_op.table
  assert_equal ["title"], remove_index_op.columns

  drop_table_op = migration.operations[1]
  assert_equal "posts", drop_table_op.table
end

test "down resets operations, so calling it twice does not duplicate them" do
  migration = CreatePosts.new
  migration.down
  migration.down
  kinds = migration.operations.map { |op| op.kind }
  assert_equal [:remove_index, :drop_table], kinds
end

test "down raises IrreversibleMigration when change recorded a non-invertible operation" do
  migration = DropsATable.new
  assert_raises("IrreversibleMigration") { migration.down }
end

test "add_index accepts Symbol columns" do
  migration = CreatePosts.new
  migration.add_index("posts", [:title, :slug])
  op = migration.operations[migration.operations.size - 1]
  assert_equal ["title", "slug"], op.columns
end

test "add_index name: overrides the derived name, for symmetry with Definition#add_index" do
  migration = CreatePosts.new
  migration.add_index("posts", ["title"], name: "custom_name")
  op = migration.operations[migration.operations.size - 1]
  assert_equal "custom_name", op.name
end

Cybertrain::Test.run!
