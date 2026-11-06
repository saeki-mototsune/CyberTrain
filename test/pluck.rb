require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# Task 9 of phase 2: Relation#pluck and #pick over two or more columns,
# each cell cast by the column's type (column_type): an integer an
# Integer, a float or decimal a Float, a boolean true/false, a datetime a
# UTC Time, a date a Date, anything else the String stored; NULL is nil.
# SQLite is FFI, so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
#
# Reading is hand-written in the shape the model generator emits
# (cybertrain/generator/models_emitter.rb; test/gen_models.rb holds the
# emitted text), trimmed to what these tests call: the rows are inserted
# with SQL, so the model needs no attribute readers.

class ReadingRelation < Cybertrain::Relation
  def column_type(name)
    case name
    when "id", "views" then :integer
    when "value" then :float
    when "price" then :decimal
    when "flag" then :boolean
    when "observed_at" then :datetime
    when "day" then :date
    when "meta" then :json
    when "kind" then :string
    when "note" then :text
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

  def order(o)
    case o
    when Hash then set_order_hash(o)
    else set_order(o)
    end
    self
  end

  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)
  def distinct = (set_distinct; self)
  def none = (set_none; self)
  def having_sql(s, b = []) = (set_having_sql(s, b); self)
  def size = count
end

class Reading < Cybertrain::Model
  def self.table_name = "readings"
  def self.column_names = ["id", "kind", "value", "price", "flag", "observed_at", "day", "meta", "note", "views"]
  def model_name = "Reading"

  def self.all = ReadingRelation.new("readings")
  def self.where(...) = all.where(...)
  def self.order(...) = all.order(...)
  def self.limit(...) = all.limit(...)
  def self.offset(...) = all.offset(...)
  def self.distinct(...) = all.distinct(...)
  def self.none(...) = all.none(...)
  def self.count(...) = all.count(...)
  def self.pluck(...) = all.pluck(...)
  def self.pick(...) = all.pick(...)
  def self.minimum_int(...) = all.minimum_int(...)
  def self.minimum_float(...) = all.minimum_float(...)
  def self.minimum_time(...) = all.minimum_time(...)
  def self.maximum_int(...) = all.maximum_int(...)
  def self.maximum_float(...) = all.maximum_float(...)
  def self.maximum_time(...) = all.maximum_time(...)
  def self.average(...) = all.average(...)
  def self.minimum_int_by(...) = all.minimum_int_by(...)
  def self.minimum_float_by(...) = all.minimum_float_by(...)
  def self.minimum_time_by(...) = all.minimum_time_by(...)
  def self.maximum_int_by(...) = all.maximum_int_by(...)
  def self.maximum_float_by(...) = all.maximum_float_by(...)
  def self.maximum_time_by(...) = all.maximum_time_by(...)
  def self.average_by(...) = all.average_by(...)
  def self.sum_int_by(...) = all.sum_int_by(...)
  def self.sum_float_by(...) = all.sum_float_by(...)
  def self.sum_float_sql(...) = all.sum_float_sql(...)
  def self.minimum_float_sql(...) = all.minimum_float_sql(...)
  def self.maximum_float_sql(...) = all.maximum_float_sql(...)
  def self.average_sql(...) = all.average_sql(...)
  def self.having_sql(...) = all.having_sql(...)

  def read_attribute(name) = nil
  def call_view_method(name) = nil
  def read_association(name) = nil
end

# ---- database -----------------------------------------------------------

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE readings (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, value REAL, " \
    "price decimal(10,2), flag boolean, observed_at datetime(6), day date, meta json, note TEXT, " \
    "views INTEGER);"
  )
end

T0 = Time.utc(2026, 10, 1, 9, 0, 0)
T1 = Time.utc(2026, 10, 2, 12, 0, 0, 250000)
T2 = Time.utc(2026, 10, 3, 8, 0, 0, 123456)

# Three rows, ids 1-3:
#   1: a, 1.0, 9.99, true,  T0, 2026-10-01, {"x":1}, "first", views 3
#   2: a, 2.0, 0.5,  false, T1, 2026-10-02, NULL,    NULL,    views 3
#   3: b, 1.5, NULL, NULL,  T2, NULL,       [1,2],   "third", views 7
def seed_readings
  sql = "INSERT INTO readings (kind, value, price, flag, observed_at, day, meta, note, views) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
  r1 = Cybertrain::Cast.binds("a", 1.0, 9.99, 1, T0, "2026-10-01", "{\"x\":1}", "first", 3)
  r2 = Cybertrain::Cast.binds("a", 2.0, 0.5, 0, T1, "2026-10-02", nil, nil, 3)
  r3 = Cybertrain::Cast.binds("b", 1.5, nil, nil, T2, nil, "[1,2]", "third", 7)
  Cybertrain::DB.with do |c|
    c.exec_script("DELETE FROM readings; DELETE FROM sqlite_sequence;")
    c.execute(sql, r1)
    c.execute(sql, r2)
    c.execute(sql, r3)
  end
  nil
end

D1 = Date.new(2026, 10, 1)
D2 = Date.new(2026, 10, 2)

test "pluck: a Time and a Float per row, in the relation's order" do
  seed_readings
  assert_equal [[T0, 1.0], [T1, 2.0], [T2, 1.5]], Reading.order("id").pluck(:observed_at, :value)
  assert_equal [[T2, 1.5], [T1, 2.0], [T0, 1.0]], Reading.order("id DESC").pluck(:observed_at, :value)
  rows = Reading.order("id").pluck(:observed_at, :value)
  assert_equal 3, rows.size
  assert rows[0][0].is_a?(Time)
  assert rows[0][1].is_a?(Float)
end

test "pluck: every column type cast, NULL as nil" do
  seed_readings
  rows = Reading.order("id").pluck(:id, :kind, :value, :price, :flag, :observed_at, :day, :meta, :note, :views)
  assert_equal [1, "a", 1.0, 9.99, true, T0, D1, "{\"x\":1}", "first", 3], rows[0]
  assert_equal [2, "a", 2.0, 0.5, false, T1, D2, nil, nil, 3], rows[1]
  assert_equal [3, "b", 1.5, nil, nil, T2, nil, "[1,2]", "third", 7], rows[2]
  assert rows[0][0].is_a?(Integer)
  assert rows[0][3].is_a?(Float)
  assert rows[0][6].is_a?(Date)
  assert_equal true, rows[0][4]
  assert_equal false, rows[1][4]
end

test "pluck: honours where, limit, offset and String column names" do
  seed_readings
  assert_equal [[3, "b"]], Reading.where(kind: "b").pluck("id", "kind")
  assert_equal [[2, "a"]], Reading.order("id").limit(1).offset(1).pluck(:id, :kind)
  assert_equal 0, Reading.none.pluck(:id, :kind).size
  assert_equal 0, Reading.where(kind: "z").pluck(:id, :kind).size
end

test "pluck: one column or none raises, naming the typed readers" do
  seed_readings
  message = assert_raises("ArgumentError") { Reading.pluck(:id) }
  assert_includes message, "pluck_int"
  assert_equal "pluck takes two or more columns; use pluck_str, pluck_int, pluck_float or ids for one", message
  empty = assert_raises("ArgumentError") { Reading.pluck }
  assert_includes empty, "two or more columns"
  bad = assert_raises("ArgumentError") { Reading.pluck(:id, "value; DROP TABLE readings") }
  assert_includes bad, "is not a column name"
end

test "distinct.pluck dedupes the rows" do
  seed_readings
  assert_equal [["a", 3], ["b", 7]], Reading.distinct.order("kind").pluck(:kind, :views)
  assert_equal 3, Reading.order("kind").pluck(:kind, :views).size
end

test "pick: the first row's cells, nil when nothing matches" do
  seed_readings
  assert_equal [1, 1.0], Reading.order("id").pick(:id, :value)
  assert_equal [3, 1.5], Reading.order("id DESC").pick(:id, :value)
  assert_equal [3, "b"], Reading.where(kind: "b").pick(:id, :kind)
  assert_nil Reading.where(kind: "z").pick(:id, :value)
  assert_nil Reading.none.pick(:id, :value)
  assert_nil Reading.limit(0).pick(:id, :value)
  # pick does not leave a limit on the relation it was called on.
  rel = Reading.order("id")
  assert_equal [1, "a"], rel.pick(:id, :kind)
  assert_equal 3, rel.pluck(:id, :kind).size
  message = assert_raises("ArgumentError") { Reading.pick(:id) }
  assert_includes message, "pluck_int"
end

Cybertrain::Test.run!
