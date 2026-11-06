require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/schema"

# Cast's phase-2 types (design 2026-11-06, sections 2.2-2.4): the storage
# format Rails writes to SQLite (`YYYY-MM-DD HH:MM:SS.ffffff`, UTC),
# the display format (`.mmmZ`), parse_time's fractions, offsets and RFC
# 2822, the C epoch reader's microseconds, Date, hash_or_nil, json_text and
# round_scale. It links SQLite through FFI, so it cannot run under CRuby:
# its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Cast = Cybertrain::Cast

DB.connect(":memory:", size: 1)
DB.with { |c| c.exec_script("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, at DATETIME, day DATE)") }

test "sql_datetime writes Rails' format in UTC with microseconds" do
  t = Time.utc(2026, 10, 5, 9, 0, 0, 123456)
  assert_equal "2026-10-05 09:00:00.123456", Cast.sql_datetime(t)
  assert_equal "2026-10-05 09:00:00.000000", Cast.sql_datetime(Time.utc(2026, 10, 5, 9))
end

test "iso8601 is the display format with milliseconds and Z" do
  assert_equal "2026-10-05T09:00:00.123Z", Cast.iso8601(Time.utc(2026, 10, 5, 9, 0, 0, 123456))
end

test "parse_time reads both separators, any fraction length, Z and offsets" do
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 120000), Cast.parse_time("2026-10-05 09:00:00.12")
  assert_equal Time.utc(2026, 10, 5, 0, 0, 0), Cast.parse_time("2026-10-05T09:00:00+09:00")
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0), Cast.parse_time("2026-10-05T09:00:00Z")
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 123456), Cast.parse_time("2026-10-05T09:00:00.1234567-00:00")
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 250000), Cast.parse_time("2026-10-05T18:00:00.250+0900")
  assert_nil Cast.parse_time("2026-10-05 09:00:00 trailing")
  assert_nil Cast.parse_time("2026-10-05 09:00:00+")
  assert_nil Cast.parse_time("2026-10-05 09:00:00+0")
  assert_nil Cast.parse_time("2026-10-05 09:00:00-09:0")
  assert_nil Cast.parse_time("2026-13-05 09:00:00")
end

test "parse_time reads RFC 2822" do
  assert_equal Time.utc(2026, 11, 5, 9, 0, 0), Cast.parse_time("Thu, 05 Nov 2026 09:00:00 +0000")
  assert_equal Time.utc(2026, 11, 5, 0, 0, 0), Cast.parse_time("Thu, 05 Nov 2026 09:00:00 +0900")
  assert_equal Time.utc(2026, 11, 5, 9, 0, 0), Cast.parse_time("Thu, 5 Nov 2026 09:00:00 GMT")
  assert_nil Cast.parse_time("Thu, 05 Foo 2026 09:00:00 +0000")
end

test "a stored datetime round-trips through the connection with microseconds" do
  DB.with { |c| c.execute("DELETE FROM t", []) }
  at = Time.utc(2026, 10, 5, 9, 0, 0, 123456)
  DB.with { |c| c.execute("INSERT INTO t (at) VALUES (?)", [at]) }
  text = DB.with { |c| c.execute("SELECT at FROM t", []) }
  assert_equal "2026-10-05 09:00:00.123456", Cast.str(text[0]["at"])
  rows = DB.with { |c| c.execute_models("SELECT at FROM t", []) }
  read = Cast.time_or_nil(rows[0]["at"])
  assert_equal at, read
  assert_equal 123456, read.nil? ? -1 : read.usec
end

test "the epoch reader accepts a Rails fraction, an old T...Z value and an offset" do
  DB.with { |c| c.execute("DELETE FROM t", []) }
  DB.with do |c|
    c.exec_script("INSERT INTO t (at) VALUES ('2026-10-05 09:00:00.5'); " \
                  "INSERT INTO t (at) VALUES ('2026-10-05T09:00:00Z'); " \
                  "INSERT INTO t (at) VALUES ('2026-10-05T18:00:00.250+0900'); " \
                  "INSERT INTO t (at) VALUES ('2026-10-05 09:00:00+')")
  end
  rows = DB.with { |c| c.execute_models("SELECT at FROM t ORDER BY id", []) }
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 500000), Cast.time_or_nil(rows[0]["at"])
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0), Cast.time_or_nil(rows[1]["at"])
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 250000), Cast.time_or_nil(rows[2]["at"])
  assert_equal "2026-10-05 09:00:00+", Cast.str(rows[3]["at"]) # a cut offset: text
end

test "date, date_or_nil, hash_or_nil, json_text, round_scale" do
  assert_equal "2026-10-05", Cast.date("2026-10-05").to_s
  assert_equal "1970-01-01", Cast.date("not a date").to_s
  assert_nil Cast.date_or_nil(nil)
  assert_equal 5, Cast.date_or_nil("2026-10-05").day
  assert_nil Cast.hash_or_nil(nil)
  assert_equal({}, Cast.hash_or_nil("[1]"))
  assert_equal 1, Cast.int(Cast.hash_or_nil('{"n": 1}')["n"])
  assert_equal '{"a":1}', Cast.json_text({ "a" => 1 })
  assert_nil Cast.json_text(nil)
  assert_equal 1.23, Cast.round_scale(1.2345, 2)
  assert_equal 1.2345, Cast.round_scale(1.2345, -1)
end

# Float#round(0) answers an Integer; round_scale keeps the Float it promises.
test "round_scale and round_scale_or_nil answer a Float, even at scale 0" do
  assert_equal 3.0, Cast.round_scale(2.6, 0)
  assert_equal "Float", Cast.round_scale(2.6, 0).class.to_s
  assert_nil Cast.round_scale_or_nil(nil, 2)
  assert_equal 1.01, Cast.round_scale_or_nil("1.006", 2)
  assert_equal "Float", Cast.round_scale_or_nil(2.6, 0).class.to_s
  assert_equal 1.2345, Cast.round_scale_or_nil(1.2345, -1)
  assert_nil Cast.round_scale_or_nil("", 2)
end

test "json_hash reads a json cell as a Hash, {} for anything it cannot" do
  assert_equal 1, Cast.int(Cast.json_hash('{"a": 1}')["a"])
  assert_equal 2, Cast.int(Cast.json_hash({ "b" => 2 })["b"])
  assert_equal 3, Cast.int(Cast.json_hash({ c: 3 })["c"])
  assert_equal({}, Cast.json_hash("[1, 2]"))
  assert_equal({}, Cast.json_hash("7"))
  assert_equal({}, Cast.json_hash("{not json"))
  assert_equal({}, Cast.json_hash(""))
  assert_equal({}, Cast.json_hash(nil))
  assert_equal({}, Cast.json_hash(5))
end

test "a Date binds as its text and reads back from a DATE column" do
  DB.with { |c| c.execute("DELETE FROM t", []) }
  DB.with { |c| c.execute("INSERT INTO t (day) VALUES (?)", [Date.new(2026, 10, 5)]) }
  rows = DB.with { |c| c.execute("SELECT day FROM t", []) }
  assert_equal "2026-10-05", Cast.str(rows[0]["day"])
end

# Cast.date beside the schema DSL's TableDef#date (an instance method that
# returns nil): one program compiles both (NOTES rules 34 and 41).
test "Cast.date coexists with the schema DSL's t.date" do
  definition = Cybertrain::Schema.define(version: "1") { |s| s.create_table("days") { |t| t.date "day" } }
  assert_equal :date, definition.tables[0].columns[0].type
  assert_equal "2026-10-05", Cast.date("2026-10-05").to_s
  assert_equal 5, Cast.date_or_nil("2026-10-05").day
end

Cybertrain::Test.run!
