require "cybertrain/schema"
require "cybertrain/schema/dumper"
require "cybertrain/db/sqlite_ddl"
require "cybertrain/test"

test "create_table records columns with type, null and default" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.text "body", null: false
      t.integer "views", null: false, default: "0"
      t.timestamps
    end
  end

  posts = definition.table("posts")
  assert_equal "posts", posts.name

  title = posts.column("title")
  assert_equal :string, title.type
  refute title.null
  assert_nil title.default

  views = posts.column("views")
  assert_equal :integer, views.type
  assert_equal "0", views.default

  created_at = posts.column("created_at")
  assert_equal :datetime, created_at.type
  refute created_at.null

  assert_nil posts.column("nope")
end

test "references adds an implicit foreign key column, index and foreign key" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title", null: false
    end
    s.create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
      t.text "body", null: false
    end
  end

  comments = definition.table("comments")
  post_id = comments.column("post_id")
  assert_equal :integer, post_id.type
  refute post_id.null

  assert_equal 1, comments.indexes.size
  index = comments.indexes[0]
  assert_equal ["post_id"], index.columns
  refute index.unique
  assert_equal "index_comments_on_post_id", index.name

  assert_equal 1, comments.references.size
  fk = comments.references[0]
  assert_equal "comments", fk.from_table
  assert_equal "post_id", fk.column
  assert_equal "posts", fk.to_table
end

test "references and add_foreign_key inflect irregular and compound names through Cybertrain::Inflector" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "people" do |t|
      t.string "name", null: false
    end
    s.create_table "blog_posts" do |t|
      t.string "title", null: false
    end
    s.create_table "comments" do |t|
      t.references :person
      t.references :blog_post
    end
    s.add_foreign_key "comments", "people"
    s.add_foreign_key "comments", "blog_posts"
  end

  comments = definition.table("comments")
  assert_equal 4, comments.references.size
  assert_equal "person_id", comments.references[0].column
  assert_equal "people", comments.references[0].to_table
  assert_equal "blog_post_id", comments.references[1].column
  assert_equal "blog_posts", comments.references[1].to_table
  assert_equal "person_id", comments.references[2].column
  assert_equal "people", comments.references[2].to_table
  assert_equal "blog_post_id", comments.references[3].column
  assert_equal "blog_posts", comments.references[3].to_table
end

test "references can skip the foreign key" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "comments" do |t|
      t.references :post, foreign_key: false
    end
  end

  comments = definition.table("comments")
  assert_equal 1, comments.indexes.size
  assert comments.references.empty?
end

test "tables are kept sorted by name regardless of declaration order" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "zebras" do |t|
      t.string "name"
    end
    s.create_table "ants" do |t|
      t.string "name"
    end
  end

  assert_equal ["ants", "zebras"], definition.tables.map { |t| t.name }
end

test "add_index and add_foreign_key can be declared outside create_table" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.string "slug", null: false
    end
    s.add_index "posts", ["slug"], unique: true
    s.add_foreign_key "posts", "authors"
  end

  posts = definition.table("posts")
  assert_equal 1, posts.indexes.size
  assert posts.indexes[0].unique
  assert_equal "index_posts_on_slug", posts.indexes[0].name

  assert_equal 1, posts.references.size
  fk = posts.references[0]
  assert_equal "author_id", fk.column
  assert_equal "authors", fk.to_table
end

test "Schema.current remembers the last defined schema; reset! clears it" do
  Cybertrain::Schema.reset!
  assert_nil Cybertrain::Schema.current

  definition = Cybertrain::Schema.define(version: "7") do |s|
    s.create_table "widgets" do |t|
      t.string "name"
    end
  end

  assert_equal definition, Cybertrain::Schema.current
  assert_equal "7", Cybertrain::Schema.current.version

  Cybertrain::Schema.reset!
  assert_nil Cybertrain::Schema.current
end

test "Dumper.to_ruby renders the blog schema deterministically" do
  definition = Cybertrain::Schema.define(version: "20260924120000") do |s|
    s.create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
      t.text "body", null: false
      t.timestamps
    end
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.text "body", null: false
      t.timestamps
    end
  end

  expected = <<~RUBY
    Cybertrain::Schema.define(version: "20260924120000") do |s|
      s.create_table "comments" do |t|
        t.integer "post_id", null: false
        t.string "commenter", null: false
        t.text "body", null: false
        t.datetime "created_at", null: false
        t.datetime "updated_at", null: false
      end

      s.create_table "posts" do |t|
        t.string "title", null: false
        t.text "body", null: false
        t.datetime "created_at", null: false
        t.datetime "updated_at", null: false
      end

      s.add_index "comments", ["post_id"], name: "index_comments_on_post_id"

      s.add_foreign_key "comments", "posts", column: "post_id"
    end
  RUBY

  assert_equal expected, Cybertrain::Schema::Dumper.to_ruby(definition)
end

test "Dumper.to_ruby renders unique:, default:, limit: and an index declared outside create_table" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title", null: false, limit: 80
      t.integer "views", null: false, default: "0"
      t.string "slug", null: false
    end
    s.add_index "posts", ["slug"], unique: true
  end

  expected = <<~RUBY
    Cybertrain::Schema.define(version: "1") do |s|
      s.create_table "posts" do |t|
        t.string "title", null: false, limit: 80
        t.integer "views", null: false, default: "0"
        t.string "slug", null: false
      end

      s.add_index "posts", ["slug"], unique: true, name: "index_posts_on_slug"

    end
  RUBY

  assert_equal expected, Cybertrain::Schema::Dumper.to_ruby(definition)
end

test "Dumper.to_ruby escapes backslash, double-quote and # in a default" do
  raw_default = 'say "hi" \ #{1}'

  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "widgets" do |t|
      t.string "label", null: false, default: raw_default
    end
  end

  table = definition.table("widgets")
  label = table.column("label")
  assert_equal raw_default, label.default

  escaped = 'say \"hi\" \\\\ \#{1}'
  dumped = Cybertrain::Schema::Dumper.to_ruby(definition)
  assert dumped.include?("default: \"#{escaped}\"")
end

test "the dumped form of an index round-trips through Definition#add_index" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "comments" do |t|
      t.references :post
    end
  end

  # This is exactly the line Dumper.to_ruby would print for the index above
  # (Dumper.index_options always includes `name:`, since the name is
  # deterministic): Definition#add_index must accept it back unchanged.
  s = definition
  s.add_index "comments", ["post_id"], name: "index_comments_on_post_id"

  comments = definition.table("comments")
  assert_equal 2, comments.indexes.size
  last = comments.indexes[comments.indexes.size - 1]
  assert_equal "index_comments_on_post_id", last.name
end

test "add_index accepts Symbol columns" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "slug", null: false
    end
    s.add_index "posts", [:slug]
  end

  posts = definition.table("posts")
  assert_equal ["slug"], posts.indexes[0].columns
end

test "add_index raises ArgumentError for an unknown table" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title"
    end
  end

  assert_raises("ArgumentError") { definition.add_index("missing", ["x"]) }
end

test "add_foreign_key raises ArgumentError for an unknown table" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title"
    end
  end

  assert_raises("ArgumentError") { definition.add_foreign_key("missing", "posts") }
end

def rails_types_definition
  Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title"
      t.datetime "deleted_at", precision: 0
    end
    s.create_table "users" do |t|
      t.string "email", null: false
    end
    s.create_table "trades" do |t|
      t.decimal "price", precision: 18, scale: 8
      t.decimal "amount", precision: 10
      t.decimal "ratio"
      t.json "meta"
      t.bigint "views", null: false, default: "0"
      t.references :post, on_delete: :cascade
      t.references :user, null: true, on_delete: :nullify, index: false
    end
    s.add_index "users", "LOWER(email)", name: "index_users_on_lower_email"
    s.add_index "posts", ["deleted_at"], where: "deleted_at IS NULL"
  end
end

test "decimal, json and bigint columns record their type, precision, scale and limit" do
  trades = rails_types_definition.table("trades")
  price = trades.column("price")
  assert_equal :decimal, price.type
  assert_equal 18, price.precision
  assert_equal 8, price.scale
  amount = trades.column("amount")
  assert_equal 10, amount.precision
  assert_equal(-1, amount.scale)
  ratio = trades.column("ratio")
  assert_equal 0, ratio.precision
  assert_equal(-1, ratio.scale)
  assert_equal :json, trades.column("meta").type
  views = trades.column("views")
  assert_equal :integer, views.type
  assert_equal 8, views.limit
  assert_equal "0", views.default
  assert_equal 0, trades.column("meta").precision
  assert_equal(-1, trades.column("meta").scale)
end

test "datetime accepts precision: and ignores it" do
  deleted_at = rails_types_definition.table("posts").column("deleted_at")
  assert_equal :datetime, deleted_at.type
  assert_equal 0, deleted_at.precision
end

test "references takes on_delete: and index:" do
  trades = rails_types_definition.table("trades")
  assert_equal 2, trades.references.size
  assert_equal :cascade, trades.references[0].on_delete
  assert_equal :nullify, trades.references[1].on_delete
  assert_equal ["index_trades_on_post_id"], trades.indexes.map { |i| i.name }
end

test "a foreign key defaults to on_delete :no_action" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title"
    end
    s.create_table "comments" do |t|
      t.references :post
      t.integer "author_id"
    end
    s.add_foreign_key "comments", "posts", column: "author_id", on_delete: :restrict
  end
  refs = definition.table("comments").references
  assert_equal :no_action, refs[0].on_delete
  assert_equal :restrict, refs[1].on_delete
end

test "add_index takes an expression String and a where: predicate" do
  definition = rails_types_definition
  expr = definition.table("users").indexes[0]
  assert_equal "LOWER(email)", expr.expression
  assert_equal [], expr.columns
  assert_equal "index_users_on_lower_email", expr.name
  assert_equal "", expr.where
  partial = definition.table("posts").indexes[0]
  assert_equal "deleted_at IS NULL", partial.where
  assert_equal "", partial.expression
  assert_equal ["deleted_at"], partial.columns
  assert_equal "index_posts_on_deleted_at", partial.name
end

test "an expression index without name: raises ArgumentError" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "users" do |t|
      t.string "email"
    end
  end
  assert_raises("ArgumentError") { definition.add_index("users", "LOWER(email)") }
end

test "SqliteDDL writes DECIMAL, JSON, BIGINT and ON DELETE" do
  sql = Cybertrain::DB::SqliteDDL.create_table(rails_types_definition.table("trades"))
  assert_includes sql, "price DECIMAL(18,8)"
  assert_includes sql, "amount DECIMAL(10),"
  assert_includes sql, "ratio DECIMAL,"
  assert_includes sql, "meta JSON"
  assert_includes sql, "views BIGINT NOT NULL DEFAULT 0"
  assert_includes sql, "FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE"
  assert_includes sql, "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL"
end

test "SqliteDDL writes ON DELETE RESTRICT and nothing for :no_action" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title"
    end
    s.create_table "comments" do |t|
      t.references :post, on_delete: :restrict
      t.references :author
    end
  end
  sql = Cybertrain::DB::SqliteDDL.create_table(definition.table("comments"))
  assert_includes sql, "REFERENCES posts(id) ON DELETE RESTRICT"
  assert_includes sql, "FOREIGN KEY (author_id) REFERENCES authors(id))"
end

test "SqliteDDL index_sql writes expression and partial indexes" do
  definition = rails_types_definition
  expr = definition.table("users").indexes[0]
  partial = definition.table("posts").indexes[0]
  assert_equal "CREATE INDEX index_users_on_lower_email ON users(LOWER(email))",
               Cybertrain::DB::SqliteDDL.index_sql(expr.table, expr.columns, expr.unique, expr.name, expr.where, expr.expression)
  assert_equal "CREATE INDEX index_posts_on_deleted_at ON posts(deleted_at) WHERE deleted_at IS NULL",
               Cybertrain::DB::SqliteDDL.index_sql(partial.table, partial.columns, partial.unique, partial.name, partial.where, partial.expression)
end

test "Dumper.to_ruby writes decimal, json, bigint, on_delete, expression and partial indexes" do
  ruby = Cybertrain::Schema::Dumper.to_ruby(rails_types_definition)
  assert_includes ruby, "    t.decimal \"price\", precision: 18, scale: 8\n"
  assert_includes ruby, "    t.decimal \"amount\", precision: 10\n"
  assert_includes ruby, "    t.decimal \"ratio\"\n"
  assert_includes ruby, "    t.json \"meta\"\n"
  assert_includes ruby, "    t.bigint \"views\", null: false, default: \"0\"\n"
  assert_includes ruby, "    t.datetime \"deleted_at\"\n"
  assert_includes ruby, "  s.add_index \"users\", \"LOWER(email)\", name: \"index_users_on_lower_email\"\n"
  assert_includes ruby, "  s.add_index \"posts\", [\"deleted_at\"], name: \"index_posts_on_deleted_at\", where: \"deleted_at IS NULL\"\n"
  assert_includes ruby, "  s.add_foreign_key \"trades\", \"posts\", column: \"post_id\", on_delete: :cascade\n"
  assert_includes ruby, "  s.add_foreign_key \"trades\", \"users\", column: \"user_id\", on_delete: :nullify\n"
end

test "decimal raises ArgumentError for a scale without a precision" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "users" do |t|
      t.string "email"
    end
  end
  table = definition.table("users")
  assert_raises("ArgumentError") { Cybertrain::Schema::TableDef.new(table).decimal("price", scale: 2) }
  assert_nil table.column("price")
end

test "references raises ArgumentError for on_delete: :nullify on a NOT NULL column" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title"
    end
  end
  table = definition.table("posts")
  assert_raises("ArgumentError") { Cybertrain::Schema::TableDef.new(table).references(:user, on_delete: :nullify) }
  assert_nil table.column("user_id")
end

test "an unknown on_delete raises ArgumentError" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title"
    end
  end
  assert_raises("ArgumentError") { definition.add_foreign_key("posts", "users", on_delete: :casade) }
end

Cybertrain::Test.run!
