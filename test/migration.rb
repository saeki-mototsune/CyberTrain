require "cybertrain/migration"
require "cybertrain/db/sqlite_ddl"
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

test "add_column takes precision: and scale: for a decimal" do
  migration = CreatePosts.new
  migration.add_column("posts", "price", :decimal, precision: 18, scale: 8)
  migration.add_column("posts", "meta", :json)
  migration.add_column("posts", "views", :integer, limit: 8, null: false, default: "0")
  price = migration.operations[0]
  assert_equal :decimal, price.type
  assert_equal 18, price.precision
  assert_equal 8, price.scale
  assert_equal 0, migration.operations[1].precision
  assert_equal(-1, migration.operations[1].scale)
  stmts = migration.operations.map { |op| Cybertrain::DB::SqliteDDL.statements(op)[0] }
  assert_equal ["ALTER TABLE posts ADD COLUMN price DECIMAL(18,8)",
                "ALTER TABLE posts ADD COLUMN meta JSON",
                "ALTER TABLE posts ADD COLUMN views BIGINT NOT NULL DEFAULT 0"], stmts
end

test "add_index takes where: for a partial index" do
  migration = CreatePosts.new
  migration.add_index("posts", ["deleted_at"], where: "deleted_at IS NULL")
  op = migration.operations[0]
  assert_equal "deleted_at IS NULL", op.where
  assert_equal ["CREATE INDEX index_posts_on_deleted_at ON posts(deleted_at) WHERE deleted_at IS NULL"],
               Cybertrain::DB::SqliteDDL.statements(op)
  plain = CreatePosts.new
  plain.add_index("posts", ["title"])
  assert_equal "", plain.operations[0].where
end

test "add_reference and add_foreign_key take on_delete:" do
  migration = AddCommentsTable.new
  migration.add_reference("comments", "post", null: true, on_delete: :nullify)
  migration.add_foreign_key("comments", "authors", on_delete: :cascade)
  migration.add_reference("comments", "editor", null: true)
  ops = migration.operations
  assert_equal :nullify, ops[0].on_delete
  assert_equal :nullify, ops[1].on_delete
  assert_equal :cascade, ops[2].on_delete
  assert_equal :no_action, ops[3].on_delete
  assert_equal ["ALTER TABLE comments ADD COLUMN post_id INTEGER REFERENCES posts(id) ON DELETE SET NULL",
                "CREATE INDEX index_comments_on_post_id ON comments(post_id)"],
               Cybertrain::DB::SqliteDDL.add_reference_statements(ops[0], ops[1].to_table)
  assert_equal "ALTER TABLE comments ADD COLUMN editor_id INTEGER REFERENCES editors(id)",
               Cybertrain::DB::SqliteDDL.add_reference_statements(ops[3], ops[4].to_table)[0]
end

test "a create_table recorded by a migration writes DECIMAL(p,s) and ON DELETE RESTRICT" do
  migration = CreatePosts.new
  migration.create_table("trades") do |t|
    t.decimal "price", precision: 18, scale: 8
    t.references :post, on_delete: :restrict
  end
  stmts = Cybertrain::DB::SqliteDDL.statements(migration.operations[0])
  assert_equal "CREATE TABLE trades (id INTEGER PRIMARY KEY AUTOINCREMENT, price DECIMAL(18,8), " \
               "post_id INTEGER NOT NULL, FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE RESTRICT)", stmts[0]
  assert_equal "CREATE INDEX index_trades_on_post_id ON trades(post_id)", stmts[1]
end

test "add_column raises ArgumentError for a scale without a precision" do
  migration = CreatePosts.new
  assert_raises("ArgumentError") { migration.add_column("posts", "price", :decimal, scale: 2) }
  assert_equal 0, migration.operations.size
end

test "add_reference raises ArgumentError for on_delete: :nullify on a NOT NULL column" do
  migration = AddCommentsTable.new
  assert_raises("ArgumentError") { migration.add_reference("comments", "post", on_delete: :nullify) }
  assert_equal 0, migration.operations.size
end

test "add_reference with Symbol arguments folds its foreign key into the ADD COLUMN" do
  migration = AddCommentsTable.new
  migration.add_reference(:comments, :post, null: true, on_delete: :cascade)
  ops = migration.operations
  assert_equal "comments", ops[1].table
  assert Cybertrain::DB::SqliteDDL.folds_foreign_key?(ops[0], ops[1])
  assert_equal ["ALTER TABLE comments ADD COLUMN post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE",
                "CREATE INDEX index_comments_on_post_id ON comments(post_id)"],
               Cybertrain::DB::SqliteDDL.add_reference_statements(ops[0], ops[1].to_table)
end

class ReversibleSteps < Cybertrain::Migration::Base
  version "20260104000000"

  def change
    add_column "posts", "slug", :string
    reversible do |dir|
      dir.up { execute "UPDATE posts SET slug = title" }
      dir.down { execute "UPDATE posts SET title = slug" }
    end
  end
end

class ReversibleWithSchemaStep < Cybertrain::Migration::Base
  version "20260104000100"

  def change
    reversible do |dir|
      dir.up { add_column "posts", "slug", :string }
    end
  end
end

test "the new kinds record one Operation each, with the fields they reuse" do
  m = CreatePosts.new
  m.rename_table(:posts, :articles)
  m.change_column(:posts, :views, :decimal, null: false, default: "0", precision: 10, scale: 2)
  m.change_column_default(:posts, :views, from: "0", to: "1")
  m.change_column_null(:posts, :title, false, "untitled")
  m.remove_reference(:comments, :post)
  m.remove_foreign_key(:comments, :posts)
  m.remove_foreign_key(:comments, :people, column: "author_id")
  ops = m.operations
  assert_equal [:rename_table, :change_column, :change_column_default, :change_column_null,
                :remove_reference, :remove_foreign_key, :remove_foreign_key], ops.map { |op| op.kind }
  assert_equal "posts", ops[0].table
  assert_equal "articles", ops[0].new_name
  assert_equal "views", ops[1].name
  assert_equal :decimal, ops[1].type
  refute ops[1].null
  assert_equal "0", ops[1].default
  assert_equal 10, ops[1].precision
  assert_equal 2, ops[1].scale
  assert_equal "1", ops[2].default
  assert ops[2].from_given
  assert_equal "0", ops[2].from_default
  assert_equal "title", ops[3].name
  refute ops[3].null
  assert_equal "UPDATE posts SET title = ? WHERE title IS NULL", ops[3].exec_sql
  assert_equal 1, ops[3].exec_binds.size
  assert_equal "untitled", ops[3].exec_binds[0].to_s
  assert_equal "comments", ops[4].table
  assert_equal "post_id", ops[4].name
  assert_equal "posts", ops[5].to_table
  assert_equal "post_id", ops[5].name
  assert_equal "people", ops[6].to_table
  assert_equal "author_id", ops[6].name
  assert_equal [false, true, true, true, true, true, true], ops.map { |op| op.rebuilds? }
  refute Cybertrain::Migration::Operation.for_drop_table("posts").rebuilds?
end

test "change_column_default without from: is recorded as not knowing the previous default" do
  m = CreatePosts.new
  m.change_column_default(:posts, :views, to: nil)
  op = m.operations[0]
  assert op.default.nil?
  refute op.from_given
  assert_raises("IrreversibleMigration") { m.inverse(op) }
end

test "change_column_null without a default backfills nothing" do
  m = CreatePosts.new
  m.change_column_null(:posts, :title, false)
  op = m.operations[0]
  assert_equal "", op.exec_sql
  assert_equal 0, op.exec_binds.size
end

test "inverse of rename_table swaps the names" do
  m = CreatePosts.new
  m.rename_table("posts", "articles")
  inverse = m.inverse(m.operations[0])
  assert_equal :rename_table, inverse.kind
  assert_equal "articles", inverse.table
  assert_equal "posts", inverse.new_name
  assert_equal ["ALTER TABLE posts RENAME TO articles"], Cybertrain::DB::SqliteDDL.statements(m.operations[0])
end

test "inverse of change_column_default with from: and to: swaps them" do
  m = CreatePosts.new
  m.change_column_default("posts", "views", from: nil, to: "5")
  inverse = m.inverse(m.operations[0])
  assert_equal :change_column_default, inverse.kind
  assert_equal "views", inverse.name
  assert inverse.default.nil?
  assert inverse.from_given
  assert_equal "5", inverse.from_default
end

test "inverse of change_column_null flips null when the previous state can be restored" do
  m = CreatePosts.new
  m.change_column_null("posts", "title", false)
  m.change_column_null("posts", "body", true, "")
  m.change_column_null("posts", "summary", true)
  to_null = m.inverse(m.operations[0])
  assert_equal :change_column_null, to_null.kind
  assert to_null.null
  back = m.inverse(m.operations[1])
  refute back.null
  assert_equal "UPDATE posts SET body = ? WHERE body IS NULL", back.exec_sql
  assert_equal 1, back.exec_binds.size
  assert_equal "", back.exec_binds[0].to_s
  message = assert_raises("IrreversibleMigration") { m.inverse(m.operations[2]) }
  assert_includes message, "change_column_null"
end

test "change_column, remove_reference and remove_foreign_key have no automatic inverse" do
  m = CreatePosts.new
  m.change_column("posts", "views", :string)
  m.remove_reference("comments", "post")
  m.remove_foreign_key("comments", "posts")
  m.operations.each do |op|
    assert_raises("IrreversibleMigration") { m.inverse(op) }
  end
end

test "reversible records the up block as :reversible_up and the down block as :reversible_down" do
  m = ReversibleSteps.new
  m.up
  ops = m.operations
  assert_equal [:add_column, :reversible_up, :reversible_down], ops.map { |op| op.kind }
  assert_equal "UPDATE posts SET slug = title", ops[1].exec_sql
  assert_equal "UPDATE posts SET title = slug", ops[2].exec_sql
  back = ReversibleSteps.new
  back.down
  assert_equal [:reversible_up, :reversible_down, :remove_column], back.operations.map { |op| op.kind }
  assert_equal "UPDATE posts SET title = slug", back.operations[0].exec_sql
  assert_equal "UPDATE posts SET slug = title", back.operations[1].exec_sql
end

class TwoStepDown < Cybertrain::Migration::Base
  version "20260104000200"

  def change
    reversible do |dir|
      dir.up do
        execute "UP 1"
        execute "UP 2"
      end
      dir.down do
        execute "DOWN 1"
        execute "DOWN 2"
      end
    end
  end
end

test "a rollback runs each reversible block's statements in the order written" do
  forward = TwoStepDown.new
  forward.up
  ups = forward.operations.select { |op| op.kind == :reversible_up }.map { |op| op.exec_sql }
  assert_equal ["UP 1", "UP 2"], ups
  back = TwoStepDown.new
  back.down
  downs = back.operations.select { |op| op.kind == :reversible_up }.map { |op| op.exec_sql }
  assert_equal ["DOWN 1", "DOWN 2"], downs
end

test "reversible's blocks take only execute" do
  m = ReversibleWithSchemaStep.new
  message = assert_raises("ArgumentError") { m.up }
  assert_includes message, "execute"
end

test "rebuild_table copies the common columns through <table>_new and restores indexes, triggers and the sequence" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.integer "views", default: "0"
    end
    s.add_index "posts", ["title"], name: "index_posts_on_title"
  end
  trigger = "CREATE TRIGGER posts_audit AFTER INSERT ON posts BEGIN SELECT 1; END"
  stmts = Cybertrain::DB::SqliteDDL.rebuild_table(definition, "posts", [trigger], 7)
  assert_equal [
    "CREATE TABLE posts_new (id INTEGER PRIMARY KEY AUTOINCREMENT, title VARCHAR NOT NULL, views INTEGER DEFAULT 0)",
    "INSERT INTO posts_new (id, title, views) SELECT id, title, views FROM posts",
    "DROP TABLE posts",
    "ALTER TABLE posts_new RENAME TO posts",
    "CREATE INDEX index_posts_on_title ON posts(title)",
    trigger,
    "UPDATE sqlite_sequence SET seq = max(seq, 7) WHERE name = 'posts'",
    "INSERT INTO sqlite_sequence (name, seq) SELECT 'posts', 7 WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'posts')"
  ], stmts
  none = Cybertrain::DB::SqliteDDL.rebuild_table(definition, "posts", [], -1)
  assert_equal 5, none.size
end

test "table_after applies each rebuild kind to a copy of the table" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "comments" do |t|
      t.string "body", default: "'x'"
      t.references :post, on_delete: :cascade
      t.references :author, null: true
    end
  end
  table = definition.table("comments")
  m = CreatePosts.new
  m.change_column("comments", "body", :text, null: false)
  m.change_column_default("comments", "body", to: "'y'")
  m.change_column_null("comments", "body", false)
  m.remove_reference("comments", "post")
  m.remove_foreign_key("comments", "authors")
  ops = m.operations
  changed = Cybertrain::DB::SqliteDDL.table_after(table, ops[0]).column("body")
  assert_equal :text, changed.type
  refute changed.null
  assert changed.default.nil?
  assert_equal "'y'", Cybertrain::DB::SqliteDDL.table_after(table, ops[1]).column("body").default
  null_off = Cybertrain::DB::SqliteDDL.table_after(table, ops[2]).column("body")
  refute null_off.null
  assert_equal "'x'", null_off.default
  without_ref = Cybertrain::DB::SqliteDDL.table_after(table, ops[3])
  assert without_ref.column("post_id").nil?
  assert_equal ["index_comments_on_author_id"], without_ref.indexes.map { |i| i.name }
  assert_equal ["author_id"], without_ref.foreign_keys.map { |fk| fk.column }
  without_fk = Cybertrain::DB::SqliteDDL.table_after(table, ops[4])
  refute without_fk.column("author_id").nil?
  assert_equal ["post_id"], without_fk.foreign_keys.map { |fk| fk.column }
  assert_equal 2, without_fk.indexes.size
  # The table itself is left as it was.
  assert_equal 3, table.columns.size
  assert_equal 2, table.foreign_keys.size

  missing = CreatePosts.new
  missing.change_column_null("comments", "nope", false)
  missing.remove_foreign_key("comments", "editors")
  assert_raises("ArgumentError") { Cybertrain::DB::SqliteDDL.table_after(table, missing.operations[0]) }
  assert_raises("ArgumentError") { Cybertrain::DB::SqliteDDL.table_after(table, missing.operations[1]) }
end

Cybertrain::Test.run!
