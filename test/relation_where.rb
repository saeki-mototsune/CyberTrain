require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# Task 7 of phase 2: the fuller query API on Relation and the model class --
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

# ---- database -----------------------------------------------------------

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  # `at datetime(6)`: the precision-qualified declaration Rails writes;
  # Connection.datetime_decl? reads it as a datetime column.
  c.exec_script(
    "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, " \
    "views INTEGER NOT NULL DEFAULT 0, kind TEXT, at datetime(6));"
  )
end

T0 = Time.utc(2026, 10, 1, 9, 0, 0)
T1 = Time.utc(2026, 10, 2, 12, 0, 0, 250000)
T2 = Time.utc(2026, 10, 3, 8, 0, 0, 123456)

# Three rows, ids 1-3: views 1, 5, 10; kinds a, a, b; at T0, T1, T2.
def seed_events
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM events; DELETE FROM sqlite_sequence;") }
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
  # where.not(id: []) matches every row, the complement of where(id: [])
  # (Review Focus 2).
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

Cybertrain::Test.run!
