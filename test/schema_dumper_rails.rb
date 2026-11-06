require "cybertrain/db/connection"
require "cybertrain/db/schema_dumper"
require "cybertrain/db/migrator"
require "cybertrain/db/sqlite_ddl"
require "cybertrain/test"

# The schema dumper reading a database Rails 8.1 created: decimal(p,s),
# json, bigint, datetime(6), an expression index, a partial index, a
# foreign key with ON DELETE CASCADE, and Rails' ar_internal_metadata.
# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

RAILS_DDL = <<~SQL
  CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
  CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
  INSERT INTO schema_migrations VALUES ('20260101000000');
  CREATE TABLE "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "email" varchar NOT NULL, "balance" decimal(18,8) DEFAULT 0, "meta" json, "views" bigint DEFAULT 0 NOT NULL, "active" boolean DEFAULT 1 NOT NULL, "born_on" date, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
  CREATE UNIQUE INDEX "index_accounts_on_lower_email" ON "accounts" (LOWER(email));
  CREATE INDEX "index_accounts_on_views" ON "accounts" ("views") WHERE active = 1;
  CREATE TABLE "entries" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "body" text, CONSTRAINT "fk_rails_1" FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE);
  CREATE INDEX "index_entries_on_account_id" ON "entries" ("account_id");
SQL

def rails_connection
  connection = Cybertrain::DB::Connection.new(":memory:")
  connection.exec_script(RAILS_DDL)
  connection
end

test "dump_to_ruby maps Rails 8.1's column types, indexes and foreign keys" do
  connection = rails_connection
  ruby = Cybertrain::DB::SchemaDumper.dump_to_ruby(connection)
  assert_includes ruby, "t.decimal \"balance\", precision: 18, scale: 8, default: \"0\""
  assert_includes ruby, "t.json \"meta\""
  assert_includes ruby, "t.bigint \"views\", null: false, default: \"0\""
  assert_includes ruby, "t.boolean \"active\", null: false, default: \"1\""
  assert_includes ruby, "t.date \"born_on\""
  assert_includes ruby, "t.datetime \"created_at\", null: false"
  assert_includes ruby, "s.add_index \"accounts\", \"LOWER(email)\", unique: true, name: \"index_accounts_on_lower_email\""
  assert_includes ruby, "s.add_index \"accounts\", [\"views\"], name: \"index_accounts_on_views\", where: \"active = 1\""
  assert_includes ruby, "s.add_index \"entries\", [\"account_id\"], name: \"index_entries_on_account_id\""
  assert_includes ruby, "s.add_foreign_key \"entries\", \"accounts\", column: \"account_id\", on_delete: :cascade"
  refute ruby.include?("ar_internal_metadata")
  refute ruby.include?("schema_migrations")
  refute ruby.include?("datetime(6)")
  connection.close
end

test "dump reads precision, scale, limit, where, expression and on_delete" do
  connection = rails_connection
  definition = Cybertrain::DB::SchemaDumper.dump(connection)
  assert_equal "20260101000000", definition.version
  assert_equal ["accounts", "entries"], definition.tables.map { |t| t.name }
  accounts = definition.table("accounts")
  balance = accounts.column("balance")
  assert_equal :decimal, balance.type
  assert_equal 18, balance.precision
  assert_equal 8, balance.scale
  assert_equal :json, accounts.column("meta").type
  assert_equal :integer, accounts.column("views").type
  assert_equal 8, accounts.column("views").limit
  assert_equal :datetime, accounts.column("created_at").type
  lower = accounts.indexes.select { |i| i.name == "index_accounts_on_lower_email" }[0]
  assert_equal "LOWER(email)", lower.expression
  assert_equal [], lower.columns
  assert lower.unique
  views = accounts.indexes.select { |i| i.name == "index_accounts_on_views" }[0]
  assert_equal "active = 1", views.where
  assert_equal ["views"], views.columns
  assert_equal "", views.expression
  fk = definition.table("entries").references[0]
  assert_equal :cascade, fk.on_delete
  assert_equal "accounts", fk.to_table
  connection.close
end

test "the other ON DELETE actions read back as their Symbols" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  connection.exec_script(<<~SQL)
    CREATE TABLE "parents" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL);
    CREATE TABLE "kids" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
      "a_id" integer, "b_id" integer, "c_id" integer, "d_id" integer,
      FOREIGN KEY ("a_id") REFERENCES "parents" ("id") ON DELETE SET NULL,
      FOREIGN KEY ("b_id") REFERENCES "parents" ("id") ON DELETE RESTRICT,
      FOREIGN KEY ("c_id") REFERENCES "parents" ("id"),
      FOREIGN KEY ("d_id") REFERENCES "parents" ("id") ON DELETE SET DEFAULT);
  SQL
  refs = Cybertrain::DB::SchemaDumper.dump(connection).table("kids").references
  by_column = { "" => "" }
  by_column.delete("")
  refs.each { |fk| by_column[fk.column] = fk.on_delete.to_s }
  assert_equal "nullify", by_column["a_id"]
  assert_equal "restrict", by_column["b_id"]
  assert_equal "no_action", by_column["c_id"]
  assert_equal "no_action", by_column["d_id"]
  connection.close
end

test "a numeric column without precision and a quoted expression read back" do
  connection = Cybertrain::DB::Connection.new(":memory:")
  connection.exec_script(<<~SQL)
    CREATE TABLE "prices" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "amount" numeric, "cents" decimal(10), "code" varchar);
    CREATE INDEX "index_prices_on_code_lower" ON "prices" (lower("code"), "amount");
    CREATE INDEX "index_prices_on_code_and_amount" ON "prices" ("code", amount) WHERE code <> 'x(y)';
  SQL
  prices = Cybertrain::DB::SchemaDumper.dump(connection).table("prices")
  amount = prices.column("amount")
  assert_equal :decimal, amount.type
  assert_equal 0, amount.precision
  assert_equal(-1, amount.scale)
  assert_equal 10, prices.column("cents").precision
  assert_equal(-1, prices.column("cents").scale)
  lower = prices.indexes.select { |i| i.name == "index_prices_on_code_lower" }[0]
  assert_equal "lower(\"code\"), \"amount\"", lower.expression
  both = prices.indexes.select { |i| i.name == "index_prices_on_code_and_amount" }[0]
  assert_equal ["code", "amount"], both.columns
  assert_equal "code <> 'x(y)'", both.where
  ruby = Cybertrain::Schema::Dumper.to_ruby(Cybertrain::DB::SchemaDumper.dump(connection))
  assert_includes ruby, "t.decimal \"amount\"\n"
  assert_includes ruby, "t.decimal \"cents\", precision: 10\n"
  assert_includes ruby, "s.add_index \"prices\", \"lower(\\\"code\\\"), \\\"amount\\\"\", name: \"index_prices_on_code_lower\"\n"
  connection.close
end

test "the dump describes the same schema as the DSL written from it" do
  connection = rails_connection
  dumped = Cybertrain::DB::SchemaDumper.dump(connection)
  written = Cybertrain::Schema.define(version: "20260101000000") do |s|
    s.create_table "accounts" do |t|
      t.string "email", null: false
      t.decimal "balance", precision: 18, scale: 8, default: "0"
      t.json "meta"
      t.bigint "views", null: false, default: "0"
      t.boolean "active", null: false, default: "1"
      t.date "born_on"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end
    s.create_table "entries" do |t|
      t.integer "account_id", null: false
      t.text "body"
    end
    s.add_index "accounts", "LOWER(email)", unique: true, name: "index_accounts_on_lower_email"
    s.add_index "accounts", ["views"], name: "index_accounts_on_views", where: "active = 1"
    s.add_index "entries", ["account_id"], name: "index_entries_on_account_id"
    s.add_foreign_key "entries", "accounts", column: "account_id", on_delete: :cascade
  end
  assert_equal Cybertrain::Schema::Dumper.to_ruby(written), Cybertrain::Schema::Dumper.to_ruby(dumped)
  connection.close
end

test "the schema the DDL writes for the new types dumps back unchanged" do
  written = Cybertrain::Schema.define(version: "0") do |s|
    s.create_table "accounts" do |t|
      t.decimal "balance", precision: 18, scale: 8, default: "0"
      t.decimal "ratio"
      t.json "meta"
      t.bigint "views", null: false, default: "0"
    end
    s.create_table "entries" do |t|
      t.references :account, on_delete: :cascade
      t.references :owner, null: true, on_delete: :nullify, foreign_key: false
    end
    s.add_index "accounts", "LOWER(meta)", unique: true, name: "index_accounts_on_lower_meta"
    s.add_index "accounts", ["views"], name: "index_accounts_on_views", where: "views > 0"
  end
  connection = Cybertrain::DB::Connection.new(":memory:")
  written.tables.each do |table|
    connection.exec_script(Cybertrain::DB::SqliteDDL.create_table(table))
    table.indexes.each do |i|
      connection.exec_script(Cybertrain::DB::SqliteDDL.index_sql(i.table, i.columns, i.unique, i.name, i.where, i.expression))
    end
  end
  assert_equal Cybertrain::Schema::Dumper.to_ruby(written),
               Cybertrain::Schema::Dumper.to_ruby(Cybertrain::DB::SchemaDumper.dump(connection))
  connection.close
end

test "after the dump, a migrator with no migrations finds nothing to do" do
  connection = rails_connection
  Cybertrain::DB::SchemaDumper.dump_to_ruby(connection)
  migrator = Cybertrain::DB::Migrator.new(connection)
  assert_equal 0, migrator.pending(Cybertrain::Migration.empty_entries).size
  assert_equal 0, migrator.migrate(Cybertrain::Migration.empty_entries)
  assert_equal [["up", "20260101000000", "applied (no file)"]], migrator.status(Cybertrain::Migration.empty_entries)
  connection.close
end

Cybertrain::Test.run!
