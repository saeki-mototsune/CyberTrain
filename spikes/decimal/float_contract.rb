# Issue #189 spike, part 3: a decimal column as the framework writes it (a
# Float rounded by Cast.round_scale, bound to a DECIMAL column of SQLite),
# measured: the rounding, the range that round-trips, what SQLite stores,
# the aggregates, minor units in an INTEGER column, and BigDecimal linked
# into a framework program (docs/design.md D73). It links SQLite through
# FFI, so it runs compiled only. A record, not a test.
#
# Run (Spinel 2026.11.04.7026, SQLite 3.45.1, from spikes/decimal/):
#   spinel $(spin flags) float_contract.rb -o /tmp/float_contract && /tmp/float_contract
# Output (section 2 is 200,000 inserts and reads):
#   == 1. rounding: Float#round(scale) | Cast.round_scale (decimal digits)
#     1.005: 1.0 | 1.01
#     1.015: 1.01 | 1.02
#     0.285: 0.28 | 0.29
#     2.675: 2.68 | 2.68
#     0.125: 0.13 | 0.13
#     8.345: 8.35 | 8.35
#     -1.005: -1.0 | -1.01
#     -0.125: -0.13 | -0.13
#     2.5 (scale 0): 3.0 | 3.0
#     -2.5 (scale 0): -3.0 | -3.0
#     0.5 (scale 0): 1.0 | 1.0
#     123456789012345.67: 123456789012345.69 | 123456789012345.67
#     90071992547409.93: 90071992547409.94 | 90071992547409.94
#     1234567890.12345678 (scale 8): 1234567890.1234567 | 1234567890.1234567
#   == 2. round trip of s-digit decimals with p significant digits (text -> round_scale -> REAL -> Float -> text)
#     scale 2, 13 digits: 0 of 20000 differ
#     scale 2, 14 digits: 0 of 20000 differ
#     scale 2, 15 digits: 0 of 20000 differ
#     scale 2, 16 digits: 3193 of 20000 differ (first: 99999999999999.99 -> 99999999999999.98)
#     scale 2, 17 digits: 17290 of 20000 differ (first: 999999999999999.99 -> 1.0e+15)
#     scale 8, 13 digits: 0 of 20000 differ
#     scale 8, 14 digits: 0 of 20000 differ
#     scale 8, 15 digits: 0 of 20000 differ
#     scale 8, 16 digits: 2946 of 20000 differ (first: 99999999.99999998 -> 99999999.99999999)
#     scale 8, 17 digits: 16948 of 20000 differ (first: 999999999.99999999 -> 1000000000.0)
#   == 3. what SQLite stores for a DECIMAL (NUMERIC affinity) column
#     real Float 12.34
#     integer Integer 5
#     real Float 12.34
#     real Float 1234567890.12346
#     real Float 0.1
#     real Float Inf
#     real Float -Inf
#     null NilClass
#     real Float 1.0e+300
#   == 4. aggregates over a decimal column
#     SQLite 3.45.1
#     1000 x 0.10: SUM 100.0 AVG 0.1 MIN 0.1 MAX 0.1
#     1000 x 10 cents: SUM Integer 10000 AVG Float 10.0
#     100000 random prices below 100000.00: exact 5004242496.48, SUM(price) 5004242496.48, rounded 5004242496.48, SUM(cents) 500424249648
#     SUM(price) == exact: true; SUM(price).round(2) == exact: true
#   == 4b. the migration's UPDATE: price -> minor units
#     100000 rows, 0 with the wrong cents, 0 where moved / 100.0 <> price
#   == 5. Integer minor units
#     max 9223372036854775807 min -9223372036854775807 sum 0
#     SUM past 2**63: Cybertrain::DB::Error: integer overflow (sql: SELECT SUM(cents) AS s FROM d)
#     $1,234,567.89 -0.05 $1,234,567.89
#     parse: 1999 7 7 1998
#   == 6. BigDecimal beside the framework
#     real 1234567890.12346
#     real 1.0e-08
#     BigDecimal sum of the stored texts: 0.123456789012346001e10
#     exact sum: 0.123456789012345679e10
# Reading it: (1) the left column is what a decimal was rounded with before
# D73; (2) 15 significant digits is the limit, whatever the scale; (3) a
# text bound to a DECIMAL column becomes a REAL too, so the column cannot
# hold more than a Float does (the third and fourth rows were bound as
# "12.34" and "1234567890.12345678"), a whole REAL becomes an INTEGER, NaN
# becomes NULL; (4) this SQLite's SUM compensates (Kahan-Babuska, SQLite
# 3.43 and later), which is why 1000 x 0.1 is exactly 100.0 here and
# 99.9999999999986 summed in Ruby: an older SQLite may answer the latter;
# (5) `parse` is (BigDecimal(text) * 100).round.to_i twice, then
# (0.07 * 100).to_i and (19.99 * 100).to_i: truncating a Float product
# loses a cent, rounding it does not; (6) BigDecimal compiles and runs
# beside cybertrain/db, but what the column gives back is already the
# Float's 15 digits.
require "cybertrain/db"
require "cybertrain/number_helper"
require "bigdecimal"

DB = Cybertrain::DB
Cast = Cybertrain::Cast
NH = Cybertrain::NumberHelper

DB.connect(":memory:", size: 1)
DB.with do |c|
  c.exec_script("CREATE TABLE d (id INTEGER PRIMARY KEY AUTOINCREMENT, price DECIMAL(18,8), cents INTEGER, moved INTEGER)")
end

def clear = DB.with { |c| c.execute("DELETE FROM d", []) }

# The decimal text of n / 10**scale, built from Integer digits only.
def decimal_text(n, scale)
  s = n.abs.to_s
  s = "0" * (scale + 1 - s.length) + s if s.length <= scale
  whole = s[0, s.length - scale]
  frac = s[s.length - scale, scale]
  "#{n < 0 ? "-" : ""}#{whole}#{scale > 0 ? "." : ""}#{frac}"
end

# A value written the way a save writes it (Cast.round_scale, bound as a
# Float) and read back: the Float SQLite answers.
def round_trip(text, scale)
  clear
  DB.with { |c| c.execute("INSERT INTO d (price) VALUES (?)", [Cast.round_scale(text, scale)]) }
  rows = DB.with { |c| c.execute("SELECT price FROM d", []) }
  Cast.float(rows[0]["price"])
end

# Float#round as Cast.round_scale called it until this issue: a Float
# narrowed by a case/when, a run-time scale, then to_f.
def float_round(v, scale)
  f = case v
      when Float then v
      when String then v.to_f
      else 0.0
      end
  f.round(scale).to_f
end

puts "== 1. rounding: Float#round(scale) | Cast.round_scale (decimal digits)"
["1.005", "1.015", "0.285", "2.675", "0.125", "8.345", "-1.005", "-0.125"].each do |t|
  puts "  #{t}: #{float_round(t, 2)} | #{Cast.round_scale(t, 2)}"
end
["2.5", "-2.5", "0.5"].each { |t| puts "  #{t} (scale 0): #{float_round(t, 0)} | #{Cast.round_scale(t, 0)}" }
["123456789012345.67", "90071992547409.93"].each do |t|
  puts "  #{t}: #{float_round(t, 2)} | #{Cast.round_scale(t, 2)}"
end
puts "  1234567890.12345678 (scale 8): #{float_round("1234567890.12345678", 8)} | #{Cast.round_scale("1234567890.12345678", 8)}"

puts "== 2. round trip of s-digit decimals with p significant digits (text -> round_scale -> REAL -> Float -> text)"
[2, 8].each do |scale|
  [13, 14, 15, 16, 17].each do |digits|
    top = 10**digits
    seed = 12345
    bad = 0
    first = ""
    tried = 0
    while tried < 20000
      seed = (seed * 1103515245 + 12345) % 2147483648
      high = seed
      seed = (seed * 1103515245 + 12345) % 2147483648
      n = (high * 2147483648 + seed) % top
      n = top - 1 - tried if tried < 2000 # the largest values
      text = decimal_text(n, scale)
      back = round_trip(text, scale)
      shown = NH.number_with_precision(back, precision: scale)
      if shown != text || back != text.to_f
        bad += 1
        first = "#{text} -> #{back}" if first.empty?
      end
      tried += 1
    end
    puts "  scale #{scale}, #{digits} digits: #{bad} of #{tried} differ#{bad > 0 ? " (first: #{first})" : ""}"
  end
end

puts "== 3. what SQLite stores for a DECIMAL (NUMERIC affinity) column"
clear
DB.with do |c|
  c.execute("INSERT INTO d (price) VALUES (?)", [12.34])
  c.execute("INSERT INTO d (price) VALUES (?)", [5.0])
  c.execute("INSERT INTO d (price) VALUES (?)", ["12.34"])
  c.execute("INSERT INTO d (price) VALUES (?)", ["1234567890.12345678"])
  c.execute("INSERT INTO d (price) VALUES (?)", ["0.10"])
  c.execute("INSERT INTO d (price) VALUES (?)", [Float::INFINITY])
  c.execute("INSERT INTO d (price) VALUES (?)", [-Float::INFINITY])
  c.execute("INSERT INTO d (price) VALUES (?)", [Float::NAN])
  c.execute("INSERT INTO d (price) VALUES (?)", [1.0e300])
end
DB.with { |c| c.execute("SELECT id, typeof(price) AS ty, price, CAST(price AS TEXT) AS tx FROM d ORDER BY id", []) }.each do |r|
  puts "  #{Cast.str(r["ty"])} #{r["price"].class} #{Cast.str(r["tx"])}"
end

puts "== 4. aggregates over a decimal column"
puts "  SQLite #{Cast.str(DB.with { |c| c.execute("SELECT sqlite_version() AS v", []) }[0]["v"])}"
clear
DB.transaction do
  DB.with { |c| 1000.times { c.execute("INSERT INTO d (price, cents) VALUES (?, ?)", [Cast.round_scale("0.1", 2), 10]) } }
end
r = DB.with { |c| c.execute("SELECT SUM(price) AS s, AVG(price) AS a, MIN(price) AS lo, MAX(price) AS hi, SUM(cents) AS c, TOTAL(cents) AS t, AVG(cents) AS ac FROM d", []) }[0]
puts "  1000 x 0.10: SUM #{Cast.float(r["s"])} AVG #{Cast.float(r["a"])} MIN #{Cast.float(r["lo"])} MAX #{Cast.float(r["hi"])}"
puts "  1000 x 10 cents: SUM #{r["c"].class} #{Cast.int(r["c"])} AVG #{r["ac"].class} #{Cast.float(r["ac"])}"
clear
seed = 7
exact = 0
DB.transaction do
  DB.with do |c|
    100_000.times do
      seed = (seed * 1103515245 + 12345) % 2147483648
      cents = seed % 10_000_000
      exact += cents
      c.execute("INSERT INTO d (price, cents) VALUES (?, ?)", [Cast.round_scale(decimal_text(cents, 2), 2), cents])
    end
  end
end
r = DB.with { |c| c.execute("SELECT SUM(price) AS s, SUM(cents) AS c FROM d", []) }[0]
sum = Cast.float(r["s"])
puts "  100000 random prices below 100000.00: exact #{decimal_text(exact, 2)}, SUM(price) #{sum}, rounded #{Cast.round_scale(sum, 2)}, SUM(cents) #{Cast.int(r["c"])}"
puts "  SUM(price) == exact: #{sum == decimal_text(exact, 2).to_f}; SUM(price).round(2) == exact: #{Cast.round_scale(sum, 2) == decimal_text(exact, 2).to_f}"

puts "== 4b. the migration's UPDATE: price -> minor units"
DB.with { |c| c.execute("UPDATE d SET moved = CAST(ROUND(price * 100) AS INTEGER)", []) }
r = DB.with { |c| c.execute("SELECT COUNT(*) AS n, SUM(moved <> cents) AS wrong, SUM(moved / 100.0 <> price) AS differ FROM d", []) }[0]
puts "  #{Cast.int(r["n"])} rows, #{Cast.int(r["wrong"])} with the wrong cents, #{Cast.int(r["differ"])} where moved / 100.0 <> price"

puts "== 5. Integer minor units"
clear
DB.with do |c|
  c.execute("INSERT INTO d (cents) VALUES (?)", [9223372036854775807])
  c.execute("INSERT INTO d (cents) VALUES (?)", [-9223372036854775807])
end
r = DB.with { |c| c.execute("SELECT MAX(cents) AS hi, MIN(cents) AS lo, SUM(cents) AS s FROM d", []) }[0]
puts "  max #{Cast.int(r["hi"])} min #{Cast.int(r["lo"])} sum #{Cast.int(r["s"])}"
DB.with { |c| 2.times { c.execute("INSERT INTO d (cents) VALUES (?)", [9223372036854775807]) } }
begin
  over = DB.with { |c| c.execute("SELECT SUM(cents) AS s FROM d", []) }
  puts "  SUM past 2**63: no error, #{over.size} rows"
rescue StandardError => e
  puts "  SUM past 2**63: #{e.class}: #{e.message}"
end
cents = 123456789
puts "  #{NH.number_to_currency(decimal_text(cents, 2))} #{NH.number_with_precision(decimal_text(-5, 2), precision: 2)} #{NH.number_to_currency(cents / 100.0)}"
puts "  parse: #{(BigDecimal("19.99") * 100).round.to_i} #{(BigDecimal("0.07") * 100).round.to_i} #{(0.07 * 100).to_i} #{(19.99 * 100).to_i}"

puts "== 6. BigDecimal beside the framework"
clear
DB.with { |c| c.execute("INSERT INTO d (price) VALUES (?)", ["1234567890.12345678"]) }
DB.with { |c| c.execute("INSERT INTO d (price) VALUES (?)", ["0.00000001"]) }
rows = DB.with { |c| c.execute("SELECT CAST(price AS TEXT) AS tx, typeof(price) AS ty FROM d ORDER BY id", []) }
total = BigDecimal("0")
rows.each do |row|
  puts "  #{Cast.str(row["ty"])} #{Cast.str(row["tx"])}"
  total += BigDecimal(Cast.str(row["tx"]))
end
puts "  BigDecimal sum of the stored texts: #{total.to_s}"
puts "  exact sum: #{(BigDecimal("1234567890.12345678") + BigDecimal("0.00000001")).to_s}"
