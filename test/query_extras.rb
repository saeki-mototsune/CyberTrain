require "json"
require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# The query additions of issue #74: Model.upsert, Relation#increment,
# where_like, pluck_str/int/float, count_by/count_by_sql, sum_int/sum_float,
# and Cast.binds / like_escape / hash / array / empty_hash / empty_array.
# SQLite is FFI, so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
#
# Stat and Event are hand-written in the shape the model generator emits
# (test/model.rb is that shape's specification); two models so that
# Model.upsert is seen to take each subclass's own table_name.

class StatRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
  def where_like(c, t) = (add_where_like(c, t); self)
  def order(o) = (set_order(o); self)
  def order_sql(s) = (add_order_sql(s); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)

  def to_a
    out = Array.new(0) { Stat.new }
    found = rows
    i = 0
    while i < found.size
      out << Stat.from_row(found[i])
      i += 1
    end
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    Stat.from_row(r)
  end

  def find_by(h) = where(h).first
  def size = count
end

class Stat < Cybertrain::Model
  def self.table_name = "stats"
  def self.column_names = ["id", "project_id", "key", "calls", "max_ms", "seen_at"]
  def model_name = "Stat"

  attr_accessor :project_id, :key, :calls, :max_ms, :seen_at

  def initialize(attrs = {})
    super()
    @project_id = 0
    @key = nil
    @calls = 0
    @max_ms = nil
    @seen_at = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Stat.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @project_id = Cybertrain::Cast.int(row["project_id"])
    @key = Cybertrain::Cast.str_or_nil(row["key"])
    @calls = Cybertrain::Cast.int(row["calls"])
    @max_ms = Cybertrain::Cast.float_or_nil(row["max_ms"])
    @seen_at = Cybertrain::Cast.time_or_nil(row["seen_at"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :project_id then @project_id
    when :key then @key
    when :calls then @calls
    when :max_ms then @max_ms
    when :seen_at then @seen_at
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :project_id then @project_id = Cybertrain::Cast.int(value)
    when :key then @key = Cybertrain::Cast.str_or_nil(value)
    when :calls then @calls = Cybertrain::Cast.int(value)
    when :max_ms then @max_ms = Cybertrain::Cast.float_or_nil(value)
    when :seen_at then @seen_at = Cybertrain::Cast.time_or_nil(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "project_id" => Cybertrain::Cast.to_sql(@project_id),
      "key" => Cybertrain::Cast.to_sql(@key),
      "calls" => Cybertrain::Cast.to_sql(@calls),
      "max_ms" => Cybertrain::Cast.to_sql(@max_ms),
      "seen_at" => Cybertrain::Cast.to_sql(@seen_at)
    }
  end

  def self.all = StatRelation.new("stats")
  def self.where(h) = all.where(h)
  def self.where_like(c, t) = all.where_like(c, t)
  def self.order(o) = all.order(o)
  def self.find_by(h) = all.find_by(h)
  def self.count = all.count

  def self.create(attrs = {})
    rec = Stat.new(attrs)
    rec.save
    rec
  end

  def read_association(name) = nil
  def call_view_method(name) = nil
end

class EventRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)
end

class Event < Cybertrain::Model
  def self.table_name = "events"
  def self.column_names = ["id", "name", "n", "created_at"]
  def model_name = "Event"

  attr_accessor :name, :n, :created_at

  def initialize(attrs = {})
    super()
    @name = ""
    @n = 0
    @created_at = nil
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
    @n = Cybertrain::Cast.int(row["n"])
    @created_at = Cybertrain::Cast.time_or_nil(row["created_at"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    when :n then @n
    when :created_at then @created_at
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :name then @name = Cybertrain::Cast.str(value)
    when :n then @n = Cybertrain::Cast.int(value)
    when :created_at then @created_at = Cybertrain::Cast.time_or_nil(value)
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
      "n" => Cybertrain::Cast.to_sql(@n),
      "created_at" => Cybertrain::Cast.to_sql(@created_at)
    }
  end

  def self.all = EventRelation.new("events")
  def self.where(h) = all.where(h)

  def self.create(attrs = {})
    rec = Event.new(attrs)
    rec.save
    rec
  end

  def read_association(name) = nil
  def call_view_method(name) = nil
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE stats (id INTEGER PRIMARY KEY AUTOINCREMENT, project_id INTEGER NOT NULL, " \
    "`key` TEXT, calls INTEGER NOT NULL DEFAULT 0, max_ms REAL, seen_at DATETIME);" \
    "CREATE UNIQUE INDEX stats_project_key ON stats (project_id, `key`);" \
    "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, " \
    "n INTEGER NOT NULL DEFAULT 0, created_at DATETIME);"
  )
end

def reset_tables
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM stats; DELETE FROM events;") }
end

def seed_stats
  reset_tables
  Stat.create({ project_id: 1, key: "GET /", calls: 3, max_ms: 1.5, seen_at: Time.utc(2026, 10, 25, 9, 10, 0) })
  Stat.create({ project_id: 1, key: "GET /a_b", calls: 4, max_ms: 2.25, seen_at: Time.utc(2026, 10, 25, 9, 40, 0) })
  Stat.create({ project_id: 2, key: "POST /50%", calls: 5, max_ms: nil, seen_at: Time.utc(2026, 10, 25, 10, 5, 0) })
  Stat.create({ project_id: 2, key: nil, calls: 6, max_ms: 4.0, seen_at: nil })
  nil
end

def stat_calls(project_id, key)
  found = Stat.find_by(project_id: project_id, key: key)
  found.nil? ? -1 : found.calls
end

# ---- Cast ---------------------------------------------------------------

test "Cast.binds casts each value the way a relation binds it" do
  list = Cybertrain::Cast.binds(1, "x", nil, Time.utc(2026, 10, 25, 9, 0, 0), true, false, 1.5)
  assert_equal 7, list.size
  assert_equal 1, list[0]
  assert_equal "x", list[1]
  assert_nil list[2]
  assert_equal "2026-10-25T09:00:00Z", list[3]
  assert_equal 1, list[4]
  assert_equal 0, list[5]
  assert_equal 1.5, list[6]
  assert_equal ["only"], Cybertrain::Cast.binds("only")
  assert_equal 0, Cybertrain::Cast.binds.size
end

test "Cast.binds feeds Connection#execute" do
  seed_stats
  sql = "SELECT COUNT(*) AS n FROM stats WHERE project_id = ? AND seen_at >= ?"
  binds = Cybertrain::Cast.binds(1, Time.utc(2026, 10, 25, 9, 30, 0))
  found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
  assert_equal 1, Cybertrain::Cast.int(found[0]["n"])
end

test "Cast.like_escape escapes backslash, percent and underscore only" do
  assert_equal "50\\%\\_off\\\\x", Cybertrain::Cast.like_escape("50%_off\\x")
  assert_equal "plain text", Cybertrain::Cast.like_escape("plain text")
  assert_equal "", Cybertrain::Cast.like_escape("")
  assert_equal "\\%", Cybertrain::Cast.like_escape("%")
  assert_equal "松\\%本\\_", Cybertrain::Cast.like_escape("松%本_")
end

test "Cast.hash and Cast.array narrow parsed JSON, a fresh empty container otherwise" do
  doc = Cybertrain::Cast.hash(JSON.parse('{"a": {"tags": [1, "two", null]}, "n": 3}'))
  assert_equal 2, doc.size
  assert_equal 3, Cybertrain::Cast.int(doc["n"])
  inner = Cybertrain::Cast.hash(doc["a"])
  tags = Cybertrain::Cast.array(inner["tags"])
  assert_equal 3, tags.size
  assert_equal "two", Cybertrain::Cast.str(tags[1])
  assert_nil tags[2]
  assert_equal 0, Cybertrain::Cast.hash(doc["n"]).size
  assert_equal 0, Cybertrain::Cast.hash(doc["missing"]).size
  assert_equal 0, Cybertrain::Cast.hash(tags).size
  assert_equal 0, Cybertrain::Cast.array(doc).size
  assert_equal 0, Cybertrain::Cast.array("text").size
  assert_equal 0, Cybertrain::Cast.hash(Time.utc(2026, 10, 25)).size
  assert_equal 0, Cybertrain::Cast.array(Time.utc(2026, 10, 25)).size
end

test "Cast.hash and Cast.array copy: writing to the result leaves the value alone" do
  parsed = JSON.parse('{"k": 1, "list": [1]}')
  copy = Cybertrain::Cast.hash(parsed)
  copy["added"] = "x"
  assert_equal 3, copy.size
  assert_equal 2, Cybertrain::Cast.hash(parsed).size
  items = Cybertrain::Cast.array(copy["list"])
  items << 2
  assert_equal 1, Cybertrain::Cast.array(copy["list"]).size
end

test "Cast.empty_hash and Cast.empty_array are fresh on every call" do
  first_hash = Cybertrain::Cast.empty_hash
  first_hash["a"] = 1
  assert_equal 0, Cybertrain::Cast.empty_hash.size
  first_array = Cybertrain::Cast.empty_array
  first_array << "x"
  assert_equal 0, Cybertrain::Cast.empty_array.size
end

# ---- Model.upsert -------------------------------------------------------

test "upsert inserts, then updates the conflicting row with the update expressions" do
  reset_tables
  update = { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)" }
  written = Stat.upsert({ project_id: 1, key: "GET /", calls: 1, max_ms: 12.5 }, conflict: [:project_id, :key], update: update)
  assert_equal 1, written
  Stat.upsert({ project_id: 1, key: "GET /", calls: 2, max_ms: 3.0 }, conflict: [:project_id, :key], update: update)
  Stat.upsert({ project_id: 1, key: "GET /", calls: 4, max_ms: 20.0 }, conflict: [:project_id, :key], update: update)
  Stat.upsert({ project_id: 2, key: "GET /", calls: 9, max_ms: 1.0 }, conflict: [:project_id, :key], update: update)
  assert_equal 2, Stat.count
  row = Stat.find_by(project_id: 1, key: "GET /")
  assert !row.nil?
  assert_equal 7, row.calls
  assert_equal 20.0, row.max_ms
  assert_equal 9, stat_calls(2, "GET /")
end

test "upsert binds a Time as its ISO 8601 text and can keep the first or last seen value" do
  reset_tables
  first_seen = Time.utc(2026, 10, 25, 9, 0, 0)
  later = Time.utc(2026, 10, 25, 11, 0, 0)
  keep = { calls: "calls + 1", seen_at: "MIN(seen_at, excluded.seen_at)" }
  Stat.upsert({ project_id: 1, key: "k", calls: 1, seen_at: later }, conflict: [:project_id, :key], update: keep)
  Stat.upsert({ project_id: 1, key: "k", calls: 1, seen_at: first_seen }, conflict: [:project_id, :key], update: keep)
  Stat.upsert({ project_id: 1, key: "k", calls: 1, seen_at: later }, conflict: [:project_id, :key], update: keep)
  row = Stat.find_by(project_id: 1, key: "k")
  assert !row.nil?
  assert_equal 3, row.calls
  assert_equal first_seen, row.seen_at
end

test "upsert with an empty update is DO NOTHING and reports 0 rows on a conflict" do
  reset_tables
  assert_equal 1, Stat.upsert({ project_id: 1, key: "x", calls: 1 }, conflict: [:project_id, :key])
  assert_equal 0, Stat.upsert({ project_id: 1, key: "x", calls: 5 }, conflict: [:project_id, :key])
  assert_equal 0, Stat.upsert({ project_id: 1, key: "x", calls: 5 }, conflict: [:project_id, :key], update: {})
  assert_equal 1, stat_calls(1, "x")
end

test "upsert writes the table of the model it is called on" do
  reset_tables
  Event.upsert({ name: "boot", n: 1 }, conflict: [:name], update: { n: "n + excluded.n" })
  Event.upsert({ name: "boot", n: 2 }, conflict: [:name], update: { n: "n + excluded.n" })
  assert_equal 0, Stat.count
  found = Cybertrain::DB.with { |c| c.execute("SELECT n FROM events WHERE name = ?", ["boot"]) }
  assert_equal 1, found.size
  assert_equal 3, Cybertrain::Cast.int(found[0]["n"])
end

test "upsert refuses empty attributes, no conflict target and names that are not columns" do
  assert_raises("ArgumentError") { Stat.upsert({}, conflict: [:key]) }
  assert_raises("ArgumentError") { Stat.upsert({ key: "x" }, conflict: []) }
  msg = assert_raises("ArgumentError") { Stat.upsert({ "key; DROP": "x" }, conflict: [:key]) }
  assert_equal "upsert: \"key; DROP\" is not a column name", msg
  assert_raises("ArgumentError") { Stat.upsert({ key: "x" }, conflict: [:"a b"]) }
  assert_raises("ArgumentError") { Stat.upsert({ key: "x" }, conflict: [:key], update: { "calls=0,x": "1" }) }
end

test "upsert surfaces SQLite's refusal when no unique index matches the conflict target" do
  reset_tables
  assert_raises("Error") { Stat.upsert({ project_id: 1, key: "x" }, conflict: [:calls], update: { calls: "calls + 1" }) }
end

# ---- Relation#increment ---------------------------------------------------

test "increment adds to a column over the relation's rows and returns how many changed" do
  seed_stats
  assert_equal 2, Stat.where(project_id: 1).increment(:calls)
  assert_equal 4, stat_calls(1, "GET /")
  assert_equal 5, stat_calls(1, "GET /a_b")
  assert_equal 5, stat_calls(2, "POST /50%")
  assert_equal 1, Stat.where(key: "POST /50%").increment(:calls, by: 10)
  assert_equal 15, stat_calls(2, "POST /50%")
  assert_equal 0, Stat.where(project_id: 99).increment(:calls)
  assert_equal 4, Stat.all.increment(:calls, by: -1)
  assert_equal 3, stat_calls(1, "GET /")
end

test "increment with a limit or offset changes only that window, by id" do
  seed_stats
  assert_equal 1, Stat.all.limit(1).increment(:calls, by: 100)
  assert_equal 103, stat_calls(1, "GET /")
  assert_equal 4, stat_calls(1, "GET /a_b")
  assert_equal 2, Stat.where(project_id: 2).order("calls DESC").limit(5).offset(0).increment(:calls)
  assert_equal 1, Stat.where(project_id: 2).order("calls DESC").limit(1).increment(:calls, by: 10)
  assert_equal 6, stat_calls(2, "POST /50%")
  assert_equal 1, Stat.all.offset(3).increment(:calls)
end

test "increment refuses a name that is not a column" do
  assert_raises("ArgumentError") { Stat.all.increment("calls = 0; --") }
end

# ---- where_like -----------------------------------------------------------

test "where_like is a substring match with the text's wildcards escaped" do
  seed_stats
  assert_equal 2, Stat.where_like(:key, "GET").count
  assert_equal 1, Stat.where_like(:key, "50%").count
  assert_equal 0, Stat.where_like(:key, "5_%").count
  assert_equal 1, Stat.where_like(:key, "a_b").count
  assert_equal 0, Stat.where_like(:key, "a%b").count
  assert_equal 3, Stat.where_like(:key, "").count
  assert_equal 1, Stat.where(project_id: 1).where_like(:key, "/a").count
  assert_equal ["GET /a_b"], Stat.where_like(:key, "_").pluck_str(:key)
end

test "where_like quotes the column and binds the pattern" do
  rel = Stat.where_like(:key, "50%_")
  assert_equal "SELECT * FROM `stats` WHERE `key` LIKE ? ESCAPE '\\'", rel.to_sql
  assert_equal ["%50\\%\\_%"], rel.binds
  assert_raises("ArgumentError") { Stat.where_like("key OR 1=1", "x") }
end

test "a prefix search writes its own pattern from like_escape" do
  seed_stats
  pattern = Cybertrain::Cast.like_escape("GET /") + "%"
  assert_equal 2, Stat.all.where_sql("`key` LIKE ? ESCAPE '\\'", [pattern]).count
  starts = Cybertrain::Cast.like_escape("/50%") + "%"
  assert_equal 0, Stat.all.where_sql("`key` LIKE ? ESCAPE '\\'", [starts]).count
end

# ---- pluck ----------------------------------------------------------------

test "pluck_str, pluck_int and pluck_float read one column in the relation's order" do
  seed_stats
  assert_equal ["GET /", "GET /a_b", "POST /50%", ""], Stat.all.order("id").pluck_str(:key)
  assert_equal [6, 5, 4, 3], Stat.all.order("calls DESC").pluck_int(:calls)
  assert_equal [1.5, 2.25, 0.0, 4.0], Stat.all.order("id").pluck_float(:max_ms)
  assert_equal [1, 1], Stat.where(project_id: 1).pluck_int("project_id")
  assert_equal [4, 5], Stat.all.order("calls").offset(1).limit(2).pluck_int(:calls)
  assert_equal 0, Stat.where(project_id: 99).pluck_str(:key).size
  assert_equal "2026-10-25T09:10:00Z", Stat.all.order("id").limit(1).pluck_str(:seen_at)[0]
end

test "pluck refuses a name that is not a column" do
  assert_raises("ArgumentError") { Stat.all.pluck_str("key, calls") }
  assert_raises("ArgumentError") { Stat.all.pluck_int("") }
  assert_raises("ArgumentError") { Stat.all.pluck_float("max_ms)") }
end

# ---- count_by / count_by_sql -----------------------------------------------

test "count_by counts the rows per value, keys as Strings in order" do
  seed_stats
  Stat.create({ project_id: 1, key: "GET /b", calls: 1 })
  by_project = Stat.all.count_by(:project_id)
  assert_equal 2, by_project.size
  assert_equal 3, by_project["1"]
  assert_equal 2, by_project["2"]
  assert_equal ["1", "2"], by_project.keys
  assert_equal 2, Stat.where(project_id: 2).count_by(:project_id)["2"]
  assert_equal 0, Stat.where(project_id: 99).count_by(:project_id).size
end

test "count_by merges NULL into the empty-String key and groups only the window" do
  seed_stats
  Stat.create({ project_id: 3, key: "", calls: 0 })
  by_key = Stat.all.count_by(:key)
  assert_equal 2, by_key[""]
  assert_equal 1, by_key["GET /"]
  assert_equal 4, by_key.size
  windowed = Stat.all.order("id").limit(2).count_by(:project_id)
  assert_equal 1, windowed.size
  assert_equal 2, windowed["1"]
  assert_raises("ArgumentError") { Stat.all.count_by("project_id, key") }
end

test "count_by_sql groups by an expression: hour buckets" do
  seed_stats
  hours = Stat.all.where_sql("seen_at IS NOT NULL").count_by_sql("strftime('%Y-%m-%dT%H', seen_at)")
  assert_equal ["2026-10-25T09", "2026-10-25T10"], hours.keys
  assert_equal 2, hours["2026-10-25T09"]
  assert_equal 1, hours["2026-10-25T10"]
  assert_equal 1, Stat.all.order("id").offset(2).limit(1).count_by_sql("calls * 2")["10"]
end

# ---- sum_int / sum_float ----------------------------------------------------

test "sum_int and sum_float add up a column, 0 for no rows" do
  seed_stats
  assert_equal 18, Stat.all.sum_int(:calls)
  assert_equal 7, Stat.where(project_id: 1).sum_int(:calls)
  assert_equal 0, Stat.where(project_id: 99).sum_int(:calls)
  assert_equal 7.75, Stat.all.sum_float(:max_ms)
  assert_equal 0.0, Stat.where(project_id: 99).sum_float(:max_ms)
  assert_equal 4.0, Stat.where(project_id: 2).sum_float(:max_ms)
  assert_equal 0, Stat.where(key: "POST /50%").sum_int(:max_ms)
  assert_equal 7, Stat.all.order("calls").limit(2).sum_int(:calls)
  assert_equal 6.25, Stat.all.order("id").offset(1).sum_float(:max_ms)
  assert_raises("ArgumentError") { Stat.all.sum_int("calls) FROM stats --") }
end

Cybertrain::Test.run!
