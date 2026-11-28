require "cybertrain/test"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/model"

# test/bulk_writes.rb on MySQL, against the server CYBERTRAIN_TEST_MYSQL_URL
# names (script/test-mysql runs this program): the same models, the same
# tests and the same snapshot (test/bulk_writes.rb.expected's ok lines,
# copied, then MySQL's own three and one summary line), so
# insert_all, insert_all! and upsert_all, `returning:` included, answer on
# MySQL what they answer on SQLite. MySQL has no RETURNING
# (DB::Dialect.returning? is false): the rows are read back in the
# statement's transaction (Model.bulk_write_and_select).
#
# What differs from test/bulk_writes.rb is marked where it is:
# - the database: the tables are created here by hand-written MySQL DDL
#   (the types of the design's type table), dropped first; the plan's Task
#   10 (MySQL DDL from the schema DSL) replaces this. reset_items empties
#   the table and sets AUTO_INCREMENT back to 1 (DDL, outside any
#   transaction).
# - stored_type: SQLite's typeof() has no MySQL form; MySQL stores a value
#   in its column's type, so the helper answers the storage class SQLite's
#   typeof names for that column type ("null" for NULL).
# - the design's allowed exceptions (docs/superpowers/specs/2026-11-27-
#   mysql-adapter-design.md, "テストと受け入れ"): JSON normalisation (MySQL
#   stores {"k": [1, 2]} for {"k":[1,2]}) and the error messages' wording
#   (MySQL's "Duplicate entry", "cannot be null"), each marked
#   "exception: JSON normalisation" or "exception: error-message wording".
#   They change assertion values only, never an output line.
#
# MySQL's own tests come last (returning: where the ids are not one new
# run). The original's description, for the operations this repeats:
# insert_all, insert_all! and upsert_all (docs/design.md D46)
# -- multi-row INSERTs, chunked by the connection's variable limit,
# all chunks in one transaction, timestamps filled once per call, values
# cast by column type as a save casts them.
#
# Item is hand-written in the shape the model generator emits
# (cybertrain/generator/models_emitter.rb; test/gen_models.rb holds the
# emitted text): the three constants and the three class methods calling
# Cybertrain::Model.insert_all_into, trimmed to what these tests call.

class ItemRelation < Cybertrain::Relation
  def column_type(name)
    case name
    when "id", "qty" then :integer
    when "price" then :decimal
    when "at", "created_at", "updated_at" then :datetime
    when "on" then :date
    when "meta" then :json
    when "code" then :string
    when "body" then :text
    when "ok" then :boolean
    when "data" then :binary
    else :unknown
    end
  end

  def decimal_scale(name)
    case name
    when "price" then 2
    else -1
    end
  end

  def where(cond = nil, *binds)
    case cond
    when nil then nil
    when Hash then add_where(cond)
    when String then add_where_sql(cond, binds)
    else raise ArgumentError, "where takes a Hash or a SQL String"
    end
    self
  end

  def where_between(c, from, to, exclude_end: false) = (add_where_between(c, from, to, exclude_end); self)

  def order(o)
    case o
    when Hash then set_order_hash(o)
    else set_order(o)
    end
    self
  end

  def size = count
end

class Item < Cybertrain::Model
  def self.table_name = "items"
  def self.column_names = ["id", "code", "qty", "body", "price", "meta", "on", "at", "ok", "data", "created_at", "updated_at"]
  def model_name = "Item"

  def self.all = ItemRelation.new("items")
  def self.where(...) = all.where(...)
  def self.order(...) = all.order(...)
  def self.count(...) = all.count(...)
  def self.pluck(...) = all.pluck(...)
  def self.pick(...) = all.pick(...)
  def self.pluck_str(...) = all.pluck_str(...)
  def self.update_all(...) = all.update_all(...)

  COLUMN_TYPES = { "id" => :integer, "code" => :string, "qty" => :integer, "body" => :text, "price" => :decimal,
                   "meta" => :json, "on" => :date, "at" => :datetime, "ok" => :boolean, "data" => :binary,
                   "created_at" => :datetime,
                   "updated_at" => :datetime }
  DECIMAL_SCALES = { "price" => 2 }
  ENCRYPTED_COLUMNS = Cybertrain::Model.no_encrypted_columns

  def self.insert_all(rows, returning: [:id], record_timestamps: true)
    Cybertrain::Model.insert_all_into("items", rows, COLUMN_TYPES, DECIMAL_SCALES, ENCRYPTED_COLUMNS, returning,
                                      record_timestamps, :nothing, nil, nil)
  end

  def self.insert_all!(rows, returning: [:id], record_timestamps: true)
    Cybertrain::Model.insert_all_into("items", rows, COLUMN_TYPES, DECIMAL_SCALES, ENCRYPTED_COLUMNS, returning,
                                      record_timestamps, :raise, nil, nil)
  end

  def self.upsert_all(rows, unique_by: [:id], update_only: nil, returning: [:id], record_timestamps: true)
    Cybertrain::Model.insert_all_into("items", rows, COLUMN_TYPES, DECIMAL_SCALES, ENCRYPTED_COLUMNS, returning,
                                      record_timestamps, :update, unique_by, update_only)
  end

  def read_attribute(name) = nil
  def call_view_method(name) = nil
  def read_association(name) = nil
end

# A model whose table has an encrypted column (the generator fills the constant
# from `encrypts`): bulk writes refuse it.
class Secret < Cybertrain::Model
  def self.table_name = "secrets"
  def self.column_names = ["id", "token"]
  def model_name = "Secret"

  COLUMN_TYPES = { "id" => :integer, "token" => :string }
  DECIMAL_SCALES = Cybertrain::Model.no_decimal_scales
  ENCRYPTED_COLUMNS = ["token"]

  def self.insert_all(rows, returning: [:id], record_timestamps: true)
    Cybertrain::Model.insert_all_into("secrets", rows, COLUMN_TYPES, DECIMAL_SCALES, ENCRYPTED_COLUMNS, returning,
                                      record_timestamps, :nothing, nil, nil)
  end

  def read_attribute(name) = nil
  def call_view_method(name) = nil
  def read_association(name) = nil
end

# ---- database -----------------------------------------------------------

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# MySQL: hand-written DDL in the design's types (Task 10 generates it from
# the schema DSL), outside any transaction (DDL commits on MySQL).
TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
Cybertrain::DB.connect(URL, size: 1)
# This program's own tables are dropped first, by name, with any table of
# the other test/mysql programs that references one of them
# (test/mysql/support/tables.rb).
Cybertrain::DB.with { |c| MySQLTestTables.drop(c, ["items", "secrets"]) }
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE items (id BIGINT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(255) UNIQUE, " \
    "qty BIGINT NOT NULL DEFAULT 0, body MEDIUMTEXT, price DECIMAL(10,2), meta JSON, `on` DATE, " \
    "`at` DATETIME(6), ok TINYINT(1), data LONGBLOB, created_at DATETIME(6), updated_at DATETIME(6))" \
    "#{TABLE_OPTIONS};" \
    "CREATE TABLE secrets (id BIGINT AUTO_INCREMENT PRIMARY KEY, token VARCHAR(255))#{TABLE_OPTIONS};"
  )
end

# MySQL: the ids start at 1 again by ALTER TABLE (SQLite: sqlite_sequence).
def reset_items
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM items; ALTER TABLE items AUTO_INCREMENT = 1;") }
  nil
end

def stored(column, code)
  sql = "SELECT `#{column}` AS v FROM items WHERE code = ?"
  binds = Cybertrain::Cast.binds(code)
  found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
  found.empty? ? "(no row)" : Cybertrain::Cast.str(found[0]["v"])
end

# MySQL: SQLite's typeof() of the cell. MySQL keeps a value in its column's
# type, so a non-NULL cell's storage class is the one SQLite's typeof names
# for that column type (an integer type "integer", a text type "text", a
# BLOB "blob", DECIMAL and DOUBLE "real").
def stored_type(column, code)
  sql = "SELECT `#{column}` IS NULL AS v, (SELECT data_type FROM information_schema.columns " \
        "WHERE table_schema = DATABASE() AND table_name = 'items' AND column_name = ?) AS t FROM items WHERE code = ?"
  binds = Cybertrain::Cast.binds(column, code)
  found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
  return "(no row)" if found.empty?
  return "null" if Cybertrain::Cast.int(found[0]["v"]) == 1

  case Cybertrain::Cast.str(found[0]["t"])
  when "tinyint", "int", "bigint" then "integer"
  when "varchar", "text", "mediumtext", "json", "date", "datetime" then "text"
  when "longblob" then "blob"
  else "real"
  end
end

test "insert_all returns the ids of the rows it inserted and skips duplicates" do
  reset_items
  first = Item.insert_all([{ code: "a" }, { code: "b" }])
  assert_equal 2, first.size
  assert_equal 1, first[0]["id"]
  assert_equal 2, first[1]["id"]
  again = Item.insert_all([{ code: "a" }, { code: "c" }], returning: [:id, :code])
  assert_equal 1, again.size
  assert_equal "c", again[0]["code"]
  # The skipped duplicate still took an id (MySQL allocates the INSERT's
  # ids before the duplicate check, as SQLite its rowid), so the id is not 3.
  assert_equal Item.where(code: "c").pick(:id, :code)[0], again[0]["id"]
  assert_equal 3, Item.count
  # String keys work as Symbol keys do.
  strings = Item.insert_all([{ "code" => "d", "qty" => 4 }])
  assert_equal 1, strings.size
  assert_equal "4", stored("qty", "d")
  # An empty Array writes nothing and returns [].
  assert_equal 0, Item.insert_all([]).size
  assert_equal 4, Item.count
end

test "returning: names the columns, cast by type; [] and nil return nothing" do
  reset_items
  rows = Item.insert_all([{ code: "a", qty: 2, price: 1.005 }], returning: [:id, :code, :qty, :price, :created_at])
  assert_equal 1, rows.size
  assert_equal 1, rows[0]["id"]
  assert_equal "a", rows[0]["code"]
  assert_equal 2, rows[0]["qty"]
  assert_equal 1.01, rows[0]["price"]
  assert rows[0]["created_at"].is_a?(Time)
  assert_equal 0, Item.insert_all([{ code: "b" }], returning: []).size
  assert_equal 0, Item.insert_all([{ code: "c" }], returning: nil).size
  assert_equal 3, Item.count
  bad = assert_raises("ArgumentError") { Item.insert_all([{ code: "d" }], returning: [:nope]) }
  assert_includes bad, "nope"
  assert_equal 3, Item.count
end

test "insert_all! raises on a duplicate" do
  reset_items
  assert_equal 2, Item.insert_all!([{ code: "a" }, { code: "b" }]).size
  message = assert_raises("Error") { Item.insert_all!([{ code: "c" }, { code: "a" }]) }
  # exception: error-message wording (SQLite: "UNIQUE constraint failed").
  assert_includes message, "Duplicate entry 'a' for key 'items.code'"
  # One transaction: "c" was not kept either.
  assert_equal 2, Item.count
  assert_equal "(no row)", stored("code", "c")
end

test "insert_all fills created_at and updated_at once per call, and not with record_timestamps: false" do
  reset_items
  before = Time.now.utc
  Item.insert_all([{ code: "a" }, { code: "b" }])
  after = Time.now.utc
  stamps = Item.order("id").pluck(:created_at, :updated_at)
  assert_equal 2, stamps.size
  created = Cybertrain::Cast.time_or_nil(stamps[0][0])
  assert !created.nil? && created >= before - 1 && created <= after + 1
  # One `now` for the whole call: every row and both columns agree.
  assert_equal stamps[0][0], stamps[0][1]
  assert_equal stamps[0][0], stamps[1][0]
  assert_equal stamps[0][0], stamps[1][1]
  # Supplied values are kept, not overwritten.
  given = Time.utc(2020, 1, 2, 3, 4, 5)
  Item.insert_all([{ code: "c", created_at: given }])
  assert_equal "2020-01-02 03:04:05.000000", stored("created_at", "c")
  assert stored("updated_at", "c") != "2020-01-02 03:04:05.000000"
  Item.insert_all([{ code: "d" }], record_timestamps: false)
  assert_equal "null", stored_type("created_at", "d")
  assert_equal "null", stored_type("updated_at", "d")
  Item.insert_all([{ code: "e", updated_at: given }], record_timestamps: false)
  assert_equal "null", stored_type("created_at", "e")
  assert_equal "2020-01-02 03:04:05.000000", stored("updated_at", "e")
end

test "rows with different keys raise before anything is written" do
  reset_items
  assert_raises("ArgumentError") { Item.insert_all([{ code: "x" }, { code: "y", qty: 1 }]) }
  assert_equal 0, Item.count
  assert_raises("ArgumentError") { Item.insert_all([{ code: "x", qty: 1 }, { code: "y", body: "b" }]) }
  assert_equal 0, Item.count
  assert_raises("ArgumentError") { Item.upsert_all([{ code: "x" }, { qty: 1 }], unique_by: [:code]) }
  assert_equal 0, Item.count
  # The same keys in another order are the same key set.
  assert_equal 2, Item.insert_all([{ code: "x", qty: 1 }, { qty: 2, code: "y" }]).size
  assert_equal "2", stored("qty", "y")
  unknown = assert_raises("ArgumentError") { Item.insert_all([{ code: "z", colour: "red" }]) }
  assert_includes unknown, "colour"
  assert_equal 2, Item.count
end

test "an encrypted column is refused in a bulk row" do
  message = assert_raises("ArgumentError") { Secret.insert_all([{ token: "t" }]) }
  assert_includes message, "token"
  count = Cybertrain::DB.with { |c| Cybertrain::Cast.int(c.execute("SELECT COUNT(*) AS n FROM secrets", [])[0]["n"]) }
  assert_equal 0, count
end

test "upsert_all updates only the supplied columns and keeps created_at" do
  reset_items
  old = Time.utc(2020, 1, 1)
  Item.insert_all([{ code: "a", qty: 1, body: "kept", created_at: old, updated_at: old }])
  rows = Item.upsert_all([{ code: "a", qty: 5 }, { code: "n", qty: 7 }], unique_by: [:code])
  assert_equal 2, rows.size
  assert_equal 1, rows[0]["id"]
  assert_equal "5", stored("qty", "a")
  assert_equal "kept", stored("body", "a")
  assert_equal "2020-01-01 00:00:00.000000", stored("created_at", "a")
  assert stored("updated_at", "a") != "2020-01-01 00:00:00.000000"
  # The new row got both timestamps.
  assert_equal stored("created_at", "n"), stored("updated_at", "n")
  assert_equal "7", stored("qty", "n")
  # By id, the default unique_by.
  Item.upsert_all([{ id: 1, body: "by id" }])
  assert_equal "by id", stored("body", "a")
  assert_equal "5", stored("qty", "a")
  # record_timestamps: false leaves updated_at alone unless the rows carry it.
  Item.upsert_all([{ code: "a", qty: 6, updated_at: old }], unique_by: [:code], record_timestamps: false)
  assert_equal "2020-01-01 00:00:00.000000", stored("updated_at", "a")
  Item.upsert_all([{ code: "a", qty: 8 }], unique_by: [:code], record_timestamps: false)
  assert_equal "2020-01-01 00:00:00.000000", stored("updated_at", "a")
  assert_equal "8", stored("qty", "a")
  assert_equal 2, Item.count
end

test "upsert_all with update_only and returning" do
  reset_items
  Item.insert_all([{ code: "a", qty: 1, body: "old" }])
  rows = Item.upsert_all([{ code: "a", qty: 9, body: "new" }], unique_by: [:code], update_only: [:body],
                         returning: [:id, :qty, :body])
  assert_equal 1, rows.size
  assert_equal 1, rows[0]["id"]
  assert_equal 1, rows[0]["qty"]
  assert_equal "new", rows[0]["body"]
  # Nothing left to set (update_only names no supplied column, no
  # timestamps): the conflicting row is skipped, as DO NOTHING.
  skipped = Item.upsert_all([{ code: "a", qty: 3 }], unique_by: [:code], update_only: [:body], record_timestamps: false)
  assert_equal 0, skipped.size
  assert_equal "1", stored("qty", "a")
  # upsert_all inside a transaction that raises is rolled back with it.
  assert_raises("RuntimeError") do
    Item.transaction do |_c|
      Item.upsert_all([{ code: "a", qty: 42 }], unique_by: [:code])
      assert Cybertrain::DB.in_transaction?
      raise "stop"
    end
  end
  assert !Cybertrain::DB.in_transaction?
  assert_equal "1", stored("qty", "a")
end

test "a call with more binds than the variable limit is chunked inside one transaction" do
  reset_items
  limit = Cybertrain::DB.with { |c| c.variable_limit }
  assert limit >= 999
  assert_equal limit, Cybertrain::DB.with { |c| c.variable_limit }
  n = limit / 3 + 10
  rows = Array.new(0) { { code: "", qty: 0, body: "" } }
  i = 0
  while i < n
    rows << { code: "c#{i}", qty: i, body: "b" }
    i += 1
  end
  assert_equal 0, Item.insert_all(rows, returning: [], record_timestamps: false).size
  assert_equal n, Item.count
  assert_equal "#{n - 1}", stored("qty", "c#{n - 1}")
  reset_items
  bad = Array.new(0) { { code: "", qty: [0, nil][0], body: "" } }
  i = 0
  while i < n
    bad << { code: "c#{i}", qty: (i == n - 1 ? nil : i), body: "b" }
    i += 1
  end
  message = assert_raises("Error") { Item.insert_all(bad, returning: [], record_timestamps: false) }
  # exception: error-message wording (SQLite: "NOT NULL constraint failed").
  assert_includes message, "Column 'qty' cannot be null"
  assert_equal 0, Item.count
end

test "decimal rounding, json text, Date text and Time format in bulk rows" do
  reset_items
  at = Time.utc(2026, 10, 5, 9, 0, 0, 123456)
  Item.insert_all([{ code: "a", price: 2.345, meta: { "k" => [1, 2] }, on: Date.new(2026, 11, 6), at: at },
                   { code: "b", price: nil, meta: nil, on: "2026-02-03", at: "2026-10-05T09:00:00Z" }])
  assert_equal "2.35", stored("price", "a")
  # exception: JSON normalisation (SQLite keeps the text as written).
  assert_equal "{\"k\": [1, 2]}", stored("meta", "a")
  assert_equal "2026-11-06", stored("on", "a")
  assert_equal "2026-10-05 09:00:00.123456", stored("at", "a")
  assert_equal "null", stored_type("price", "b")
  assert_equal "null", stored_type("meta", "b")
  assert_equal "2026-02-03", stored("on", "b")
  assert_equal "2026-10-05 09:00:00.000000", stored("at", "b")
  cells = Item.where(code: "a").pick(:price, :on)
  assert_equal 2.35, cells[0]
  assert_equal Date.new(2026, 11, 6), cells[1]
end

# update_all binds each value through the cast a save applies
# (Relation.typed_bind, the bulk writes' table): a form's "false" is 0, not
# the text "false" that where(ok: false) would no longer find.
test "update_all casts every value by its column's type, as save and the bulk writes do" do
  reset_items
  Item.insert_all([{ code: "a", qty: 1, ok: true }, { code: "b", qty: 2, ok: true }], record_timestamps: false)
  assert_equal 1, Item.where(code: "a").update_all(ok: "false", meta: "garbage", on: "2026-1-5",
                                                 at: "2026-10-05T09:00:00Z", price: 2.345, qty: "7",
                                                 body: 12, data: "raw")
  assert_equal "0", stored("ok", "a")
  assert_equal "integer", stored_type("ok", "a")
  assert_equal 1, Item.where(ok: false).count
  assert_equal "a", Item.where(ok: false).pluck_str(:code)[0]
  assert_equal "{}", stored("meta", "a")
  assert_equal "null", stored_type("on", "a")
  assert_equal "2026-10-05 09:00:00.000000", stored("at", "a")
  assert_equal "2.35", stored("price", "a")
  assert_equal "integer", stored_type("qty", "a")
  assert_equal "7", stored("qty", "a")
  assert_equal "text", stored_type("body", "a")
  assert_equal "12", stored("body", "a")
  assert_equal "blob", stored_type("data", "a")
  assert_equal "raw", stored("data", "a")
  # Typed values, and the stored shapes they take.
  at = Time.utc(2026, 10, 5, 9, 0, 0)
  Item.where(code: "b").update_all(ok: false, meta: { "x" => 1 }, on: Date.new(2026, 1, 5), at: at,
                                   data: Cybertrain::DB::Blob.new("b"))
  assert_equal "0", stored("ok", "b")
  # exception: JSON normalisation (SQLite keeps the text as written).
  assert_equal "{\"x\": 1}", stored("meta", "b")
  assert_equal "2026-01-05", stored("on", "b")
  assert_equal "2026-10-05 09:00:00.000000", stored("at", "b")
  assert_equal "blob", stored_type("data", "b")
  # A Blob binds its bytes (it used to bind its inspect text).
  assert_equal "b", stored("data", "b")
  assert_equal 2, Item.where(ok: false).count
  # The stored date and datetime text is what where and where_between
  # compare against: the "T...Z" text update_all used to store sorted after
  # every " " time of that day and fell out of this window.
  assert_equal "b", Item.where(on: Date.new(2026, 1, 5)).pluck_str(:code)[0]
  window = Item.all.where_between(:at, Time.utc(2026, 10, 5, 8, 0, 0), Time.utc(2026, 10, 5, 10, 0, 0))
  assert_equal ["a", "b"], window.order("code").pluck_str(:code)
  Item.where(code: "b").update_all(meta: "{\"y\":[2]}", on: "2026-02-03", ok: "1")
  # exception: JSON normalisation (SQLite keeps the text as written).
  assert_equal "{\"y\": [2]}", stored("meta", "b")
  assert_equal "2026-02-03", stored("on", "b")
  assert_equal "1", stored("ok", "b")
  assert_equal 1, Item.where(ok: true).count
  # nil stays NULL for every type.
  Item.where(code: "b").update_all(ok: nil, meta: nil, on: nil, at: nil, price: nil, body: nil, data: nil)
  assert_equal "null", stored_type("ok", "b")
  assert_equal "null", stored_type("meta", "b")
  assert_equal "null", stored_type("on", "b")
  assert_equal "null", stored_type("at", "b")
  assert_equal "null", stored_type("price", "b")
  assert_equal "null", stored_type("body", "b")
  assert_equal "null", stored_type("data", "b")
  # Text reads as save reads it: "abc" is 0 in an integer column (it used
  # to store the text "abc" there), and "" (an empty form field) binds
  # NULL, which the NOT NULL column refuses.
  Item.where(code: "a").update_all(qty: "abc")
  assert_equal "integer", stored_type("qty", "a")
  assert_equal "0", stored("qty", "a")
  message = assert_raises("Error") { Item.where(code: "a").update_all(qty: "") }
  # exception: error-message wording (SQLite: "NOT NULL constraint failed").
  assert_includes message, "Column 'qty' cannot be null"
  assert_equal "0", stored("qty", "a")
end

test "bulk rows bind a boolean as 1/0 and a binary value as a BLOB" do
  reset_items
  Item.insert_all([{ code: "a", ok: "false", data: "raw" }, { code: "b", ok: true, data: nil },
                   { code: "c", ok: false, data: Cybertrain::DB::Blob.new("wrapped") }])
  assert_equal "0", stored("ok", "a")
  assert_equal "integer", stored_type("ok", "a")
  assert_equal "blob", stored_type("data", "a")
  assert_equal "raw", stored("data", "a")
  assert_equal "blob", stored_type("data", "c")
  assert_equal "wrapped", stored("data", "c")
  assert_equal "1", stored("ok", "b")
  assert_equal "null", stored_type("data", "b")
  assert_equal "a", Item.where(ok: false).pluck_str(:code)[0]
end

# insert_all([{}]) used to divide by zero choosing the rows per statement
# (a table without timestamps); Rails raises "Empty list of attributes".
test "rows with no columns raise before anything is written" do
  reset_items
  assert_equal "insert_all: rows have no columns", assert_raises("ArgumentError") { Secret.insert_all([{}]) }
  assert_equal "insert_all: rows have no columns", assert_raises("ArgumentError") { Item.insert_all([{}, {}]) }
  assert_equal "upsert_all: rows have no columns", assert_raises("ArgumentError") { Item.upsert_all([{}]) }
  assert_equal 0, Item.count
end

# Rails accepts one Symbol for returning:, unique_by: and update_only:;
# update_only: :qty used to answer no columns, so the upsert set nothing.
test "returning:, unique_by: and update_only: take one Symbol or String as one column" do
  reset_items
  rows = Item.insert_all([{ code: "a", qty: 1 }], returning: :id)
  assert_equal 1, rows.size
  assert_equal 1, rows[0]["id"]
  assert_equal "b", Item.insert_all([{ code: "b" }], returning: "code")[0]["code"]
  upserted = Item.upsert_all([{ code: "a", qty: 5, body: "no" }], unique_by: :code, update_only: :qty,
                             returning: :qty)
  assert_equal 5, upserted[0]["qty"]
  assert_equal "5", stored("qty", "a")
  assert_equal "null", stored_type("body", "a")
  Item.upsert_all([{ code: "a", qty: 6 }], unique_by: "code", update_only: "qty")
  assert_equal "6", stored("qty", "a")
  # An unknown or encrypted single name is refused as in an Array.
  assert_includes assert_raises("ArgumentError") { Item.insert_all([{ code: "c" }], returning: :nope) }, "nope"
  assert_equal "insert_all: returning: token is an encrypted column",
               assert_raises("ArgumentError") { Secret.insert_all([{ id: 1 }], returning: :token) }
  assert_equal 2, Item.count
end

test "false is no columns; any other value for returning:, unique_by: or update_only: raises" do
  reset_items
  assert_equal 0, Item.insert_all([{ code: "a", qty: 1 }], returning: false).size
  assert_equal 1, Item.count
  # update_only: false updates nothing (as update_only: []): the row is skipped.
  assert_equal 0, Item.upsert_all([{ code: "a", qty: 9 }], unique_by: [:code], update_only: false,
                                  record_timestamps: false).size
  assert_equal "1", stored("qty", "a")
  assert_equal "upsert_all: unique_by names no column",
               assert_raises("ArgumentError") { Item.upsert_all([{ code: "a" }], unique_by: false) }
  assert_equal "upsert_all: unique_by names no column",
               assert_raises("ArgumentError") { Item.upsert_all([{ code: "a" }], unique_by: []) }
  assert_equal "insert_all: returning: takes an Array of column names, e.g. returning: [:id]",
               assert_raises("ArgumentError") { Item.insert_all([{ code: "b" }], returning: 1) }
  assert_equal "upsert_all: unique_by: takes an Array of column names, e.g. unique_by: [:id]",
               assert_raises("ArgumentError") { Item.upsert_all([{ code: "b" }], unique_by: 1) }
  assert_equal "upsert_all: update_only: takes an Array of column names, e.g. update_only: [:name]",
               assert_raises("ArgumentError") { Item.upsert_all([{ code: "b" }], unique_by: [:code], update_only: true) }
  assert_equal 1, Item.count
end

# ---- MySQL's own ----------------------------------------------------------

# MySQL has no RETURNING: these pin that the rows read back are the rows
# the call wrote, in input order, never a neighbour, where the ids are not
# one new run (Model.bulk_write_and_select).
test "returning: an upsert that updates a row answers that row and the new one, never a neighbour" do
  reset_items
  Item.insert_all([{ code: "a" }, { code: "b" }])
  rows = Item.upsert_all([{ code: "a", qty: 5 }, { code: "n", qty: 0 }], unique_by: [:code], returning: [:id, :code])
  assert_equal ["a", "n"], rows.map { |r| r["code"] }
  assert_equal 1, rows[0]["id"]
  assert_equal Item.where(code: "n").pick(:id, :code)[0], rows[1]["id"]
  assert_equal "5", stored("qty", "a")
  # Input order, with the updated row last.
  rows = Item.upsert_all([{ code: "m", qty: 1 }, { code: "b", qty: 2 }], unique_by: [:code], returning: [:code, :qty])
  assert_equal ["m", "b"], rows.map { |r| r["code"] }
  assert_equal [1, 2], rows.map { |r| r["qty"] }
end

test "returning: insert_all with a leading duplicate answers only the rows it inserted" do
  reset_items
  Item.insert_all([{ code: "a" }, { code: "b" }])
  rows = Item.insert_all([{ code: "a" }, { code: "c" }, { code: "b" }, { code: "d" }], returning: [:id, :code])
  assert_equal ["c", "d"], rows.map { |r| r["code"] }
  assert_equal Item.where(code: "c").pick(:id, :code)[0], rows[0]["id"]
  assert_equal Item.where(code: "d").pick(:id, :code)[0], rows[1]["id"]
  # Every row a duplicate: none.
  assert_equal 0, Item.insert_all([{ code: "a" }, { code: "b" }], returning: [:id]).size
  # Supplied ids: a taken id answers nothing, a new one its row.
  rows = Item.insert_all([{ id: 1, code: "x" }, { id: 90, code: "y" }], returning: [:id, :code])
  assert_equal [90], rows.map { |r| r["id"] }
  assert_equal 5, Item.count
end

test "returning: insert_all whose rows supply no unique index whole is refused, and writes nothing" do
  reset_items
  message = assert_raises("DB::Error") { Item.insert_all([{ qty: 1 }], returning: [:id]) }
  assert_includes message, "needs the rows to supply every column of a unique index of items"
  assert_equal 0, Item.count
  # Without returning: it writes.
  assert_equal 0, Item.insert_all([{ qty: 1 }], returning: []).size
  assert_equal 1, Item.count
  # insert_all! (a duplicate raises, so every row is new) reads the new
  # run of ids back.
  rows = Item.insert_all!([{ code: "p" }, { code: "q" }], returning: [:id, :code])
  assert_equal ["p", "q"], rows.map { |r| r["code"] }
  assert_equal rows[0]["id"] + 1, rows[1]["id"]
end

Cybertrain::Test.run!
