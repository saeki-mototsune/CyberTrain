require "cybertrain/test"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/model"

# test/relation_where.rb, test/pluck.rb and test/aggregates.rb on MySQL,
# against the server CYBERTRAIN_TEST_MYSQL_URL names (script/test-mysql runs
# this program): their models and their tests, in that order, and their
# snapshots concatenated (test/mysql/relation.rb.expected: their `ok` lines
# as they are, one summary line for all of them), so where, order, limit,
# the aggregates, pluck and pick answer on MySQL what they answer on SQLite.
# One test is MySQL's own, last: LIKE is case-sensitive here
# (utf8mb4_0900_bin; SQLite's LIKE ignores ASCII case), the design's LIKE
# exception.
#
# What differs from the originals is marked where it is:
# - the database: both tables are created here by hand-written MySQL DDL
#   (the types of the design's type table), dropped first; the plan's Task
#   10 (MySQL DDL from the schema DSL) replaces this. The seeds empty a
#   table and set AUTO_INCREMENT back to 1 (DDL, outside any transaction)
#   where SQLite empties sqlite_sequence.
# - the design's allowed exceptions (docs/superpowers/specs/2026-11-27-
#   mysql-adapter-design.md, "テストと受け入れ"), each marked "exception:
#   <name>" where it changes an assertion's value; no output line changes.
#
# test/relation_where.rb:
# The fuller query API on Relation and the model class (docs/design.md D43) --
# where with a SQL string or an Integer Range, where.not, where_between, or,
# order with a Hash, distinct, none, ids, update_all, destroy_all,
# find_each, find_by!, find_or_create_by, find_or_initialize_by,
# Model#update_columns and Model.create!. SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Event is hand-written in the shape the model generator emits
# (cybertrain/generator/models_emitter.rb; test/gen_models.rb holds the
# emitted text), so every method below is the one a generated model has.

class EventRelation < Cybertrain::Relation
  def column_type(name)
    case name
    when "id", "views" then :integer
    when "at" then :datetime
    when "name", "kind" then :string
    else :unknown
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

  def not(h) = (add_where_not(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
  def where_like(c, t) = (add_where_like(c, t); self)
  def where_between(c, from, to, exclude_end: false) = (add_where_between(c, from, to, exclude_end); self)
  def or(other) = (merge_or(other); self)

  def order(o)
    case o
    when Hash then set_order_hash(o)
    else set_order(o)
    end
    self
  end

  def order_sql(s) = (add_order_sql(s); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)
  def distinct = (set_distinct; self)
  def none = (set_none; self)

  def to_a
    out = Array.new(0) { Event.new }
    found = rows
    i = 0
    while i < found.size
      out << Event.from_row(found[i])
      i += 1
    end
    out
  end

  def each(&blk) = to_a.each(&blk)

  def first
    r = first_row
    return nil if r.nil?
    Event.from_row(r)
  end

  def last
    r = last_row
    return nil if r.nil?
    Event.from_row(r)
  end

  def find_by(h) = where(h).first

  def find_by!(h)
    rec = find_by(h)
    raise Cybertrain::RecordNotFound, "Couldn't find Event" if rec.nil?
    rec
  end

  def find(id)
    rec = where(id: id).first
    raise Cybertrain::RecordNotFound, "Couldn't find Event with id=#{id}" if rec.nil?
    rec
  end

  def find_or_create_by(h)
    rec = find_by(h)
    return rec unless rec.nil?
    Event.create(h)
  end

  def find_or_initialize_by(h)
    rec = find_by(h)
    return rec unless rec.nil?
    Event.new(h)
  end

  def destroy_all
    out = to_a
    i = 0
    while i < out.size
      out[i].destroy
      i += 1
    end
    out
  end

  def find_each(batch: 1000, &blk)
    raise ArgumentError, "find_each: batch must be at least 1 (got #{batch})" if batch < 1
    last_id = 0
    while true
      found = batch_rows(last_id, batch)
      i = 0
      while i < found.size
        rec = Event.from_row(found[i])
        last_id = rec.id
        blk.call(rec)
        i += 1
      end
      break if found.size < batch
    end
    nil
  end

  def size = count
end

class Event < Cybertrain::Model
  def self.table_name = "events"
  def self.column_names = ["id", "name", "views", "kind", "at"]
  def model_name = "Event"

  attr_accessor :name, :views, :kind, :at

  def initialize(attrs = {})
    super()
    @name = ""
    @views = 0
    @kind = nil
    @at = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Event.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @name = Cybertrain::Cast.str(row["name"])
    @views = Cybertrain::Cast.int(row["views"])
    @kind = Cybertrain::Cast.str_or_nil(row["kind"])
    @at = Cybertrain::Cast.time_or_nil(row["at"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    when :views then @views
    when :kind then @kind
    when :at then @at
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :name then @name = Cybertrain::Cast.str(value)
    when :views then @views = Cybertrain::Cast.int(value)
    when :kind then @kind = Cybertrain::Cast.str_or_nil(value)
    when :at then @at = Cybertrain::Cast.time_or_nil(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "name" => Cybertrain::Cast.to_sql(@name),
      "views" => Cybertrain::Cast.to_sql(@views),
      "kind" => Cybertrain::Cast.to_sql(@kind),
      "at" => Cybertrain::Cast.to_sql(@at)
    }
  end

  def self.all = EventRelation.new("events")
  def self.where(...) = all.where(...)
  def self.where_like(...) = all.where_like(...)
  def self.where_between(...) = all.where_between(...)
  def self.order(...) = all.order(...)
  def self.order_sql(...) = all.order_sql(...)
  def self.limit(...) = all.limit(...)
  def self.offset(...) = all.offset(...)
  def self.distinct(...) = all.distinct(...)
  def self.none(...) = all.none(...)
  def self.ids(...) = all.ids(...)
  def self.find(...) = all.find(...)
  def self.find_by(...) = all.find_by(...)
  def self.find_by!(...) = all.find_by!(...)
  def self.find_or_create_by(...) = all.find_or_create_by(...)
  def self.find_or_initialize_by(...) = all.find_or_initialize_by(...)
  def self.first(...) = all.first(...)
  def self.last(...) = all.last(...)
  def self.count(...) = all.count(...)
  def self.exists?(...) = all.exists?(...)
  def self.update_all(...) = all.update_all(...)
  def self.delete_all(...) = all.delete_all(...)
  def self.destroy_all(...) = all.destroy_all(...)
  def self.find_each(...) = all.find_each(...)

  def self.create(attrs = {})
    rec = Event.new(attrs)
    rec.save
    rec
  end

  def self.create!(attrs = {})
    rec = Event.new(attrs)
    rec.save!
    rec
  end

  def read_association(name) = nil
  def call_view_method(name) = nil
end

# ---- app/models/event.rb (user code reopening the generated class) --------

CALLBACK_COUNTS = { "before_save" => 0, "after_destroy" => 0 }

class Event
  validates :name, presence: true
  before_save { |r| CALLBACK_COUNTS["before_save"] = CALLBACK_COUNTS["before_save"] + 1 }
  after_destroy { |r| CALLBACK_COUNTS["after_destroy"] = CALLBACK_COUNTS["after_destroy"] + 1 }
end

# ---- test/pluck.rb and test/aggregates.rb's model (the same in both) ------

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

# ---- database -----------------------------------------------------------

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# MySQL: hand-written DDL in the design's types (Task 10 generates it from
# the schema DSL), outside any transaction (DDL commits on MySQL). SQLite's
# `at datetime(6)` is DATETIME(6), its REAL a DOUBLE, its boolean a
# TINYINT(1).
TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
Cybertrain::DB.connect(URL, size: 1)
# This program's own tables are dropped first, by name, with any table of
# the other test/mysql programs that references one of them
# (test/mysql/support/tables.rb).
Cybertrain::DB.with { |c| MySQLTestTables.drop(c, ["events", "readings"]) }
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE events (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL, " \
    "views INT NOT NULL DEFAULT 0, kind VARCHAR(255), `at` DATETIME(6))#{TABLE_OPTIONS};" \
    "CREATE TABLE readings (id BIGINT AUTO_INCREMENT PRIMARY KEY, kind VARCHAR(255), value DOUBLE, " \
    "price DECIMAL(10,2), flag TINYINT(1), observed_at DATETIME(6), day DATE, meta JSON, note MEDIUMTEXT, " \
    "views INT)#{TABLE_OPTIONS};"
  )
end

T0 = Time.utc(2026, 10, 1, 9, 0, 0)
T1 = Time.utc(2026, 10, 2, 12, 0, 0, 250000)
T2 = Time.utc(2026, 10, 3, 8, 0, 0, 123456)

# Three rows, ids 1-3: views 1, 5, 10; kinds a, a, b; at T0, T1, T2.
def seed_events
  # MySQL: AUTO_INCREMENT back to 1 (SQLite: sqlite_sequence emptied).
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM events; ALTER TABLE events AUTO_INCREMENT = 1;") }
  Event.create({ name: "one", views: 1, kind: "a", at: T0 })
  Event.create({ name: "five", views: 5, kind: "a", at: T1 })
  Event.create({ name: "ten", views: 10, kind: "b", at: T2 })
  nil
end

def names_of(events)
  out = Array.new(0) { "" }
  events.each { |e| out << e.name }
  out
end

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
    # MySQL: AUTO_INCREMENT back to 1 (SQLite: sqlite_sequence emptied).
    c.exec_script("DELETE FROM readings; ALTER TABLE readings AUTO_INCREMENT = 1;")
    c.execute(sql, r1)
    c.execute(sql, r2)
    c.execute(sql, r3)
  end
  nil
end

D1 = Date.new(2026, 10, 1)
D2 = Date.new(2026, 10, 2)
# ---- where forms ----------------------------------------------------------

test "where with an Integer Range and open ranges" do
  seed_events
  assert_equal 2, Event.where(views: 1..5).count
  assert_equal 2, Event.where(views: 5..).count
  assert_equal 2, Event.where(views: ..5).count
  assert_equal 1, Event.where(views: 1...5).count
  assert_equal 1, Event.where(views: ...5).count
  assert_equal ["five", "ten"], names_of(Event.where(views: 5..).order("id").to_a)
  assert_equal "SELECT * FROM `events` WHERE `views` BETWEEN ? AND ?", Event.where(views: 1..5).to_sql
  assert_equal "SELECT * FROM `events` WHERE `views` >= ? AND `views` < ?", Event.where(views: 1...5).to_sql
end

test "where with a SQL string and binds, and where_sql still works" do
  seed_events
  assert_equal 2, Event.where("views > ?", 4).count
  assert_equal 1, Event.where("views > ? AND kind = ?", 4, "a").count
  assert_equal 3, Event.where("views > 0").count
  assert_equal 2, Event.all.where_sql("views > ?", [4]).count
  assert_equal "SELECT * FROM `events` WHERE (views > ?)", Event.where("views > ?", 4).to_sql
  # A String condition is parenthesized, so its OR cannot take the terms
  # ANDed after it: (kind = b OR views = 1) AND views = 1 is one row; the
  # bare text would be kind = b OR (views = 1 AND views = 1), two rows.
  assert_equal 1, Event.where("kind = ? OR views = ?", "b", 1).where(views: 1).count
  assert_equal ["one"], names_of(Event.where("kind = ? OR views = ?", "b", 1).where(views: 1).to_a)
  assert_equal 2, Event.where("kind = ? OR kind = ?", "a", "b").not(views: 1).count
  assert_equal 1, Event.where("kind = ? OR kind = ?", "a", "b").where_between(:views, 1, 1).count
  assert_equal 1, Event.all.where_sql("kind = ? OR views = ?", ["b", 1]).where(views: 1).count
  # Neither nil, a Hash nor a String: an error, not every row.
  message = assert_raises("ArgumentError") { Event.where(:views) }
  assert_equal "where takes a Hash or a SQL String", message
  # One ? is one value: an Array bind is refused, not bound as its text.
  message = assert_raises("ArgumentError") { Event.where("id IN (?)", [1, 2]) }
  assert_equal "where: an Array bind is not expanded; use where(column: [...])", message
  assert_raises("ArgumentError") { Event.all.where_sql("id IN (?)", [[1, 2]]) }
  assert_equal 1, Event.where("at = ?", T0).count
  # where with no argument is the relation itself (where.not reads as in Rails).
  assert_equal 3, Event.where.count
  rel = Event.all
  assert_equal rel.object_id, rel.where.object_id
end

test "where.not negates equality, nil, arrays and ranges" do
  seed_events
  assert_equal ["ten"], names_of(Event.where.not(kind: "a").to_a)
  Event.create({ name: "kindless", views: 7, kind: nil })
  assert_equal 3, Event.where.not(kind: nil).count
  assert_equal "SELECT * FROM `events` WHERE NOT (`kind` IS NULL)", Event.where.not(kind: nil).to_sql
  assert_equal ["ten", "kindless"], names_of(Event.where.not(views: [1, 5]).order("id").to_a)
  assert_equal ["ten", "kindless"], names_of(Event.where.not(views: 1..5).order("id").to_a)
  # Two keys: NOT (a AND b), as Rails 6.1+.
  assert_equal 3, Event.where.not(kind: "a", views: 1).count
  # where.not(id: []) matches every row, the complement of where(id: [])'s
  # 1 = 0.
  assert_equal 4, Event.where.not(id: []).count
  assert_equal 0, Event.where(id: []).count
  assert_equal "SELECT * FROM `events` WHERE NOT (1 = 0)", Event.where.not(id: []).to_sql
  # Chained after a where, the negation is ANDed on.
  assert_equal ["five"], names_of(Event.where(kind: "a").not(views: 1).to_a)
end

test "where_between on a datetime column, inclusive, exclusive and open-ended" do
  seed_events
  assert_equal T2, Event.find(3).at
  # The third row's at is exactly T2 (microseconds 123456): inclusive.
  assert_equal ["five", "ten"], names_of(Event.where_between(:at, T1, T2).order("id").to_a)
  assert_equal ["five"], names_of(Event.where_between(:at, T1, T2, exclude_end: true).to_a)
  assert_equal 3, Event.where_between(:at, nil, T2).count
  assert_equal 2, Event.where_between(:at, nil, T2, exclude_end: true).count
  assert_equal 2, Event.where_between(:at, T1, nil).count
  assert_equal 2, Event.where_between(:views, 2, 10).count
  assert_equal 1, Event.where_between(:views, 1.5, 9.5).count
  assert_equal 2, Event.where_between(:name, "f", "p").count
  assert_equal "SELECT * FROM `events` WHERE `at` >= ? AND `at` <= ?", Event.where_between(:at, T1, T2).to_sql
  rel = Event.where_between(:at, T1, T2)
  assert_equal ["2026-10-02 12:00:00.250000", "2026-10-03 08:00:00.123456"], rel.binds
  message = assert_raises("ArgumentError") { Event.where_between(:at, nil, nil) }
  assert_includes message, "where_between"
  assert_raises("ArgumentError") { Event.where_between("at; DROP", T1, T2) }
end

test "or joins two relations and refuses a different order" do
  seed_events
  assert_equal 3, Event.where(kind: "a").or(Event.where(views: 10)).count
  assert_equal 2, Event.where(kind: "a").or(Event.where(views: 10)).where(views: 5..).count
  rel = Event.where(kind: "a").or(Event.where(views: 10))
  assert_equal "SELECT * FROM `events` WHERE ((`kind` = ?) OR (`views` = ?))", rel.to_sql
  assert_equal 2, rel.binds.size
  # A side with no conditions makes the result unconditioned.
  assert_equal 3, Event.where(kind: "b").or(Event.all).count
  # A none side contributes nothing.
  assert_equal 1, Event.where(kind: "b").or(Event.none).count
  message = assert_raises("ArgumentError") { Event.where(kind: "a").or(Event.order(views: :desc)) }
  assert_equal "or: the relations differ in order, limit, offset or distinct", message
  assert_raises("ArgumentError") { Event.where(kind: "a").or(Event.limit(1)) }
  assert_raises("ArgumentError") { Event.where(kind: "a").or(Event.distinct) }
end

test "order with a Hash, distinct pluck and count" do
  seed_events
  assert_equal [10, 5, 1], Event.order(views: :desc).pluck_int(:views)
  assert_equal [1, 5, 10], Event.order(views: :asc).pluck_int(:views)
  assert_equal ["five", "one", "ten"], Event.order(kind: :asc, name: "asc").pluck_str(:name)
  assert_equal "SELECT * FROM `events` ORDER BY `kind` DESC, `views` ASC", Event.order(kind: :desc, views: :asc).to_sql
  assert_raises("ArgumentError") { Event.order(views: :sideways) }
  assert_raises("ArgumentError") { Event.order("views; DROP": :asc) }
  assert_equal "ten", Event.order(views: :asc).last.name
  # String and Symbol orders still work.
  assert_equal "ten", Event.order("views DESC").first.name
  assert_equal "one", Event.order(:views).first.name
  assert_equal 2, Event.distinct.order("kind").pluck_str(:kind).size
  assert_equal ["a", "b"], Event.distinct.order("kind").pluck_str(:kind)
  assert_equal "SELECT DISTINCT * FROM `events`", Event.distinct.to_sql
  # distinct dedupes what the column readers return (pluck_*, ids). A
  # SELECT * row carries its id, so count of a distinct relation (run over
  # the DISTINCT subquery) is the plain count.
  assert_equal 2, Event.where(kind: "a").distinct.count
  assert_equal 3, Event.distinct.count
  assert Event.distinct.exists?
  # An offset under distinct skips whole rows, not the one `DISTINCT 1` row.
  assert Event.distinct.offset(1).exists?
  assert Event.distinct.offset(2).exists?
  refute Event.distinct.offset(3).exists?
  pg = Event.distinct.page(1, per: 2)
  assert pg.next?
end

test "update_all, update_columns, destroy_all, none, ids, find_each" do
  seed_events
  assert_equal 3, Event.update_all(kind: "z")
  assert_equal ["z", "z", "z"], Event.order("id").pluck_str(:kind)
  assert_equal 1, Event.where(name: "ten").update_all(views: 11, at: T0)
  assert_equal 11, Event.find(3).views
  assert_equal T0, Event.find(3).at
  assert_equal 1, Event.order("id").limit(1).update_all(kind: nil)
  assert_nil Event.find(1).kind
  assert_raises("ArgumentError") { Event.update_all({}) }

  saves = CALLBACK_COUNTS["before_save"]
  rec = Event.find(2)
  assert_equal true, rec.update_columns(views: 99, kind: "q")
  assert_equal 99, rec.views
  assert_equal "q", rec.kind
  assert_equal 99, Event.find(2).views
  assert_equal "q", Event.find(2).kind
  assert_equal saves, CALLBACK_COUNTS["before_save"]
  # No validation either: a blank name goes straight to the row.
  rec.update_columns(name: "")
  assert_equal "", Event.find(2).name
  assert_raises("ArgumentError") { rec.update_columns(nope: 1) }
  assert_raises("ArgumentError") { Event.new.update_columns(views: 1) }

  assert_equal 0, Event.none.count
  assert Event.none.to_a.empty?
  assert_nil Event.none.first
  refute Event.none.exists?
  assert_equal 0, Event.none.ids.size
  assert_equal 0, Event.none.update_all(views: 0)
  assert_equal 0, Event.none.delete_all
  assert_equal 0, Event.where(views: 99).none.count
  assert_equal 3, Event.count

  assert_equal [1, 2, 3], Event.ids
  assert_equal [3, 2, 1], Event.order(id: :desc).ids
  assert_equal [2], Event.where(views: 99).ids

  seen = Array.new(0) { 0 }
  Event.find_each(batch: 2) { |e| seen << e.id }
  assert_equal [1, 2, 3], seen
  some = Array.new(0) { 0 }
  Event.where.not(views: 99).find_each { |e| some << e.id }
  assert_equal [1, 3], some
  assert_raises("ArgumentError") { Event.find_each(batch: 0) { |e| some << e.id } }

  destroyed = CALLBACK_COUNTS["after_destroy"]
  gone = Event.destroy_all
  assert_equal 3, gone.size
  assert_equal [1, 2, 3], gone.map { |e| e.id }
  assert_equal 0, Event.count
  assert_equal destroyed + 3, CALLBACK_COUNTS["after_destroy"]
end

test "find_or_create_by, find_or_initialize_by, find_by!, create!" do
  seed_events
  found = Event.find_or_create_by(name: "five")
  assert_equal 2, found.id
  assert_equal 3, Event.count
  made = Event.find_or_create_by(name: "new", views: 3)
  assert made.persisted?
  assert_equal 4, Event.count
  assert_equal 3, Event.find_by(name: "new").views

  init = Event.find_or_initialize_by(name: "later")
  refute init.persisted?
  assert_equal "later", init.name
  assert_equal 4, Event.count
  assert_equal 1, Event.find_or_initialize_by(name: "one").id

  assert_equal 3, Event.find_by!(name: "ten").id
  message = assert_raises("RecordNotFound") { Event.find_by!(name: "none") }
  assert_equal "Couldn't find Event", message

  created = Event.create!({ name: "bang", views: 2 })
  assert created.persisted?
  assert_equal 5, Event.count
  invalid = assert_raises("RecordInvalid") { Event.create!({ name: "" }) }
  assert_includes invalid, "Name can't be blank"
  assert_equal 5, Event.count
end

# ---- test/pluck.rb --------------------------------------------------------

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
  # exception: JSON normalisation (SQLite answers the text as written,
  # "{\"x\":1}" and "[1,2]").
  assert_equal [1, "a", 1.0, 9.99, true, T0, D1, "{\"x\": 1}", "first", 3], rows[0]
  assert_equal [2, "a", 2.0, 0.5, false, T1, D2, nil, nil, 3], rows[1]
  assert_equal [3, "b", 1.5, nil, nil, T2, nil, "[1, 2]", "third", 7], rows[2]
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

# ---- test/aggregates.rb ---------------------------------------------------

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

# ---- MySQL's own ----------------------------------------------------------

# exception: LIKE. where_like is case-sensitive on MySQL (the column's
# utf8mb4_0900_bin collation compares bytes); SQLite's LIKE ignores ASCII
# case, so there Event.where_like(:name, "FIVE") would find "five". `%`,
# `_` and `\` in the text are matched as themselves.
test "where_like is case-sensitive, and escapes % _ and \\" do
  seed_events
  assert_equal ["five"], names_of(Event.where_like(:name, "fiv").to_a)
  assert_equal 0, Event.where_like(:name, "FIVE").count
  assert_equal 0, Event.where_like(:name, "Five").count
  assert_equal 2, Event.where_like(:name, "n").count
  Event.create({ name: "50% off_now \\ A", views: 2, kind: "c", at: T0 })
  Event.create({ name: "500 offXnow", views: 2, kind: "c", at: T0 })
  assert_equal 1, Event.where_like(:name, "50%").count
  assert_equal 1, Event.where_like(:name, "off_now").count
  assert_equal 1, Event.where_like(:name, "\\ A").count
  assert_equal 0, Event.where_like(:name, "\\ a").count
end

Cybertrain::Test.run!
