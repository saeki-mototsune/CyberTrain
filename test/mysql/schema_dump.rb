require "cybertrain/cast"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/schema/dumper"
require "cybertrain/test"
require_relative "support/tables"

# What db/schema.rb holds on MySQL where the same migrations dump something
# else on SQLite (docs/compatibility.md, "The same application on SQLite
# and on MySQL"; test/mysql/migrations.rb's header lists them), against the
# server CYBERTRAIN_TEST_MYSQL_URL names (script/test-mysql runs this
# program). Each dump is printed, so the snapshot pins it whole, and the
# line that differs from SQLite's is asserted:
# - a string with `limit: 255` dumps without it;
# - a decimal with precision 10 and scale 0 dumps as a plain decimal, and
#   one with a precision and no scale gains `scale: 0`;
# - `t.bigint "*_id"` dumps as an integer;
# - a decimal's default dumps with its scale ("0.00" for "0");
# - a reference with `index: false` and a foreign key gains an index.
# Not here: a default on a text or json column, which MySQL holds as an
# expression. Its dump keeps information_schema's backslashes
# (`(_utf8mb4\'{}\')`), and the CREATE TABLE built from that dump is a
# syntax error (1064), seen on 2026-11-28; it is pinned with its fix.
# test/mysql/migrations.rb pins the expression index's text and the refused
# partial index.

DB = Cybertrain::DB

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

OWN_TABLES = ["schema_migrations", "dump_children", "dump_parents", "dump_items"]

def fresh_db
  conn = DB::Connection.new(URL)
  MySQLTestTables.drop(conn, OWN_TABLES)
  conn
end

# The dump of `tables` alone, as db/schema.rb's text.
def dump_of(conn, tables)
  full = DB::SchemaDumper.dump(conn)
  only = Cybertrain::Schema::Definition.new(full.version)
  full.tables.each { |t| only.tables << t if tables.include?(t.name) }
  Cybertrain::Schema::Dumper.to_ruby(only)
end

class CreateDumpItems < Cybertrain::Migration::Base
  def change
    create_table "dump_items" do |t|
      t.string "name", limit: 255
      t.decimal "whole", precision: 10, scale: 0
      t.decimal "rate", precision: 8
      t.decimal "price", precision: 10, scale: 2, null: false, default: "0"
      t.bigint "account_id"
    end
  end
end

class CreateDumpParents < Cybertrain::Migration::Base
  def change
    create_table "dump_parents" do |t|
      t.string "label"
    end
    create_table "dump_children" do |t|
      t.references :dump_parent, index: false, on_delete: :cascade
    end
  end
end

test "column options MySQL does not keep dump as MySQL holds them" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrator.migrate([["20270301000000", CreateDumpItems.new]])
  dump = dump_of(conn, ["dump_items"])
  puts dump
  assert_includes dump, "t.string \"name\"\n"
  assert_includes dump, "t.decimal \"whole\"\n"
  assert_includes dump, "t.decimal \"rate\", precision: 8, scale: 0\n"
  assert_includes dump, "t.decimal \"price\", precision: 10, scale: 2, null: false, default: \"0.00\"\n"
  assert_includes dump, "t.integer \"account_id\"\n"
  conn.close
end

test "a foreign key without an index gains one from MySQL, which is dumped" do
  conn = fresh_db
  migrator = DB::Migrator.new(conn)
  migrator.quiet!
  migrator.migrate([["20270301000100", CreateDumpParents.new]])
  dump = dump_of(conn, ["dump_parents", "dump_children"])
  puts dump
  assert_includes dump, "s.add_index \"dump_children\", [\"dump_parent_id\"], name: \"dump_parent_id\"\n"
  conn.close
end

Cybertrain::Test.run!
