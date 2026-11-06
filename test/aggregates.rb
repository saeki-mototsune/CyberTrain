require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# Task 9 of phase 2: the typed aggregates on Relation -- minimum_*,
# maximum_*, average (nil on an empty relation, never 0), their grouped
# `_by(group, column)` forms (a Hash keyed by the group's cell as a
# String), sum_int_by / sum_float_by, the `_sql` expression forms,
# having_sql for the grouped readers, and DISTINCT inside the function
# under `distinct`. SQLite is FFI, so the snapshot comes from the compiled
# binary (spikes/NOTES.md rule 23).
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

test "minimum, maximum and average over a column" do
  seed_readings
  assert_equal 3, Reading.minimum_int(:views)
  assert_equal 7, Reading.maximum_int(:views)
  assert_equal 1.0, Reading.minimum_float(:value)
  assert_equal 2.0, Reading.maximum_float(:value)
  assert_equal T0, Reading.minimum_time(:observed_at)
  assert_equal T2, Reading.maximum_time(:observed_at)
  assert_equal 1.5, Reading.average(:value)
  assert_equal 0.5, Reading.minimum_float(:price)
  assert_equal T1, Reading.where(kind: "a").maximum_time(:observed_at)
  assert_equal 2.0, Reading.order("id").limit(2).maximum_float(:value)
  assert_equal 1.75, Reading.order("id").offset(1).average(:value)
end

test "an empty relation answers nil, never 0" do
  seed_readings
  empty = Reading.where(kind: "z")
  assert_nil empty.minimum_int(:views)
  assert_nil Reading.where(kind: "z").maximum_int(:views)
  assert_nil Reading.where(kind: "z").minimum_float(:value)
  assert_nil Reading.where(kind: "z").maximum_float(:value)
  assert_nil Reading.where(kind: "z").minimum_time(:observed_at)
  assert_nil Reading.where(kind: "z").maximum_time(:observed_at)
  assert_nil Reading.where(kind: "z").average(:value)
  assert_nil Reading.none.average(:value)
  assert_nil Reading.where(kind: "z").average_sql("value * 2")
  # Every value NULL is nil too.
  assert_nil Reading.where(kind: "b").maximum_float(:price)
  # sum_int / sum_float keep their 0.
  assert_equal 0, Reading.where(kind: "z").sum_int(:views)
end

test "grouped forms: a Hash keyed by the group's cell" do
  seed_readings
  sums = Reading.sum_float_by(:kind, :value)
  assert_equal({ "a" => 3.0, "b" => 1.5 }, sums)
  assert_equal({ "a" => 6, "b" => 7 }, Reading.sum_int_by(:kind, :views))
  assert_equal({ "a" => T1, "b" => T2 }, Reading.maximum_time_by(:kind, :observed_at))
  assert_equal({ "a" => T0, "b" => T2 }, Reading.minimum_time_by(:kind, :observed_at))
  assert_equal({ "a" => 1.5, "b" => 1.5 }, Reading.average_by(:kind, :value))
  assert_equal({ "a" => 3, "b" => 7 }, Reading.minimum_int_by(:kind, :views))
  assert_equal({ "a" => 3, "b" => 7 }, Reading.maximum_int_by(:kind, :views))
  assert_equal({ "a" => 2.0, "b" => 1.5 }, Reading.maximum_float_by(:kind, :value))
  # A group whose values are all NULL maps to nil.
  assert_equal({ "a" => 0.5, "b" => nil }, Reading.minimum_float_by(:kind, :price))
  assert_nil Reading.minimum_float_by(:kind, :price)["b"]
  assert_equal({ "3" => 3.0, "7" => 1.5 }, Reading.sum_float_by(:views, :value))
  assert_equal 0, Reading.none.sum_float_by(:kind, :value).size
  bad = assert_raises("ArgumentError") { Reading.sum_float_by("kind)", :value) }
  assert_includes bad, "is not a column name"
end

test "expression forms take trusted SQL" do
  seed_readings
  assert_equal 9.0, Reading.sum_float_sql("value * 2")
  assert_equal 2.0, Reading.minimum_float_sql("value * 2")
  assert_equal 4.0, Reading.maximum_float_sql("value * 2")
  assert_equal 3.0, Reading.average_sql("value * 2")
  assert_equal 6.0, Reading.where(kind: "a").sum_float_sql("value * 2")
end

test "having_sql narrows a grouped reader" do
  seed_readings
  assert_equal({ "a" => 3.0 }, Reading.having_sql("SUM(value) > ?", [2.0]).sum_float_by(:kind, :value))
  assert_equal({ "b" => 7 }, Reading.having_sql("COUNT(*) = 1").sum_int_by(:kind, :views))
  assert_equal({ "a" => 2 }, Reading.all.having_sql("COUNT(*) > ?", [1]).count_by(:kind))
  assert_equal({ "a" => 1.5 }, Reading.where("views < ?", 7).having_sql("AVG(value) > ?", [1.0]).average_by(:kind, :value))
  ungrouped = assert_raises("ArgumentError") { Reading.having_sql("COUNT(*) > 1").sum_int(:views) }
  assert_includes ungrouped, "having_sql applies only to the grouped readers"
  assert_raises("ArgumentError") { Reading.having_sql("COUNT(*) > 1").count }
  assert_raises("ArgumentError") { Reading.having_sql("COUNT(*) > 1").pluck(:id, :kind) }
  assert_raises("ArgumentError") { Reading.having_sql("COUNT(*) > 1").maximum_time(:observed_at) }
  windowed = assert_raises("ArgumentError") { Reading.limit(2).having_sql("COUNT(*) > 1").sum_int_by(:kind, :views) }
  assert_includes windowed, "limit or offset"
end

test "distinct puts DISTINCT inside the function" do
  seed_readings
  assert_equal 13, Reading.all.sum_int(:views)
  assert_equal 10, Reading.distinct.sum_int(:views)
  assert_equal 10.0, Reading.distinct.sum_float(:views)
  assert_equal 5.0, Reading.distinct.average(:views)
  assert_equal 3, Reading.distinct.minimum_int(:views)
  assert_equal({ "a" => 3, "b" => 7 }, Reading.distinct.sum_int_by(:kind, :views))
  assert_equal({ "a" => 6, "b" => 7 }, Reading.sum_int_by(:kind, :views))
  assert_equal 2.0, Reading.distinct.average_sql("views - 3")
end

Cybertrain::Test.run!
