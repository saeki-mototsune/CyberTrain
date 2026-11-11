require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/encryptor"
require "cybertrain/number_helper"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

# The contract of a `t.decimal` column (docs/design.md D73, issue #189):
# what is stored, read, rounded, refused and aggregated, pinned on the
# generated Post of the fixture app (posts.price is a nullable
# DECIMAL(10,2)) through save, update, update_columns, update_all,
# insert_all, upsert_all and the aggregates; then the exact alternative,
# minor units in an integer column (posts.views stands in for
# `price_cents`). SQLite is FFI, so the snapshot comes from the compiled
# binary (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_app/db/schema"
require_relative "fixtures/gen_app/gen/models/comment"
require_relative "fixtures/gen_app/gen/models/post"
require_relative "fixtures/gen_app/gen/concerns/models/concerns/visible"
require_relative "fixtures/gen_app/app/models/comment"
require_relative "fixtures/gen_app/app/models/post"

Cast = Cybertrain::Cast
NH = Cybertrain::NumberHelper

def sql_type(column)
  case column.type
  when :integer, :boolean then "INTEGER"
  when :float then "REAL"
  when :decimal then "DECIMAL(#{column.precision},#{column.scale})"
  else "TEXT"
  end
end

# The fixture schema's tables, a decimal declared as the migrator declares
# it, and a unique index on posts.title for upsert_all's conflict target.
def create_tables_sql(definition)
  sql = +""
  definition.tables.each do |table|
    parts = ["id INTEGER PRIMARY KEY AUTOINCREMENT"]
    table.columns.each do |c|
      part = +"\"#{c.name}\" #{sql_type(c)}"
      part << " NOT NULL" unless c.null
      default = c.default
      part << " DEFAULT #{default}" unless default.nil?
      parts << part
    end
    sql << "CREATE TABLE \"#{table.name}\" (#{parts.join(", ")});"
  end
  sql << "CREATE UNIQUE INDEX posts_title ON posts (title);"
  sql
end

Cybertrain.config.encryption_key = "8f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.exec_script(create_tables_sql(Cybertrain::Schema.current)) }

def reset_tables
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM comments; DELETE FROM posts;") }
end

# What SQLite holds for the post titled `title`: "real 19.99", "integer 5",
# "null ".
def stored(title)
  rows = Cybertrain::DB.with do |c|
    c.execute("SELECT typeof(price) AS ty, CAST(price AS TEXT) AS tx FROM posts WHERE title = ?", [title])
  end
  "#{Cast.str(rows[0]["ty"])} #{Cast.str(rows[0]["tx"])}"
end

def price_of(title)
  post = Post.find_by(title: title)
  post.nil? ? nil : post.price
end

# n / 10**scale as decimal text, from Integer digits only.
def decimal_text(n, scale)
  s = n.abs.to_s
  s = "0" * (scale + 1 - s.length) + s if s.length <= scale
  "#{n < 0 ? "-" : ""}#{s[0, s.length - scale]}.#{s[s.length - scale, scale]}"
end

# ---- the generated declaration ---------------------------------------------

test "gen writes the precision bound of every decimal column that declares one" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "prices" do |t|
      t.decimal "amount", precision: 10, scale: 2
      t.decimal "rate", precision: 5, scale: 5, null: false, default: "0"
      t.decimal "units", precision: 4, null: false, default: "0"
      t.decimal "huge", precision: 30, scale: 2
      t.decimal "loose"
    end
  end
  source = Cybertrain::Gen::ModelsEmitter.outputs(definition, Cybertrain::Gen::ModelScan.scan_dir("test/fixtures/none"))
  text = source["gen/models/price.rb"]
  lines = text.nil? ? [] : text.lines.select { |l| l.include?("numericality") }.map { |l| l.strip }
  assert_equal [
    "validates :amount, numericality: { greater_than: -100000000, less_than: 100000000 }, allow_nil: true",
    "validates :rate, numericality: { greater_than: -1, less_than: 1 }",
    "validates :units, numericality: { greater_than: -10000, less_than: 10000 }",
    "validates :huge, numericality: { greater_than: -1.0e+28, less_than: 1.0e+28 }, allow_nil: true"
  ], lines
end

# ---- save and read ----------------------------------------------------------

test "save stores a REAL rounded to the scale, and the read is the same decimal" do
  reset_tables
  Post.create(title: "a", price: "19.99")
  assert_equal "real 19.99", stored("a")
  assert_equal 19.99, price_of("a")
  assert_equal "19.99", NH.number_with_precision(price_of("a"), precision: 2)
  assert_equal 1, Post.where(price: 19.99).count
  assert_equal 0, Post.where(price: 19.98).count
  Post.create(title: "b", price: 0.1 + 0.2)
  assert_equal "real 0.3", stored("b")
  assert_equal 0.3, price_of("b")
  Post.create(title: "c", price: 7)
  assert_equal 7.0, price_of("c")
  assert_equal "Float", price_of("c").class.to_s
end

# NUMERIC affinity: SQLite keeps a whole REAL as an INTEGER; it reads back
# as a Float all the same.
test "a whole value is stored as an INTEGER and read as a Float" do
  reset_tables
  Post.create(title: "whole", price: 5.0)
  assert_equal "integer 5", stored("whole")
  assert_equal 5.0, price_of("whole")
  assert_equal "Float", price_of("whole").class.to_s
end

test "nil and an empty field are NULL, never 0.0; text that is not a number is 0.0" do
  reset_tables
  Post.create(title: "nil", price: nil)
  Post.create(title: "empty", price: "")
  Post.create(title: "words", price: "abc")
  Post.create(title: "prefix", price: "12.5 dollars")
  assert_equal "null ", stored("nil")
  assert_nil price_of("nil")
  assert_equal "null ", stored("empty")
  assert_equal "integer 0", stored("words")
  assert_equal 0.0, price_of("words")
  assert_equal 12.5, price_of("prefix")
end

# ---- rounding ---------------------------------------------------------------

# Half away from zero on the decimal digits of the Float's shortest text:
# 1.005 is the double 1.00499999999999989..., and still rounds to 1.01, as
# Rails' BigDecimal("1.005").round(2) does. Float#round on the binary
# product answered 1.0 here under Spinel (NOTES rule 100).
test "rounding is half away from zero on the decimal digits" do
  ties = { "1.005" => 1.01, "1.015" => 1.02, "0.285" => 0.29, "2.675" => 2.68, "0.125" => 0.13,
           "8.345" => 8.35, "-1.005" => -1.01, "-0.125" => -0.13, "1.004999" => 1.0, "0.004" => 0.0,
           "-0.004" => 0.0, "99999999.994" => 99999999.99 }
  ties.each do |text, rounded|
    assert_equal rounded, Cast.round_scale(text, 2)
    assert_equal rounded, Cast.round_scale(text.to_f, 2)
    assert_equal rounded, Cast.round_scale_or_nil(text, 2)
  end
  assert_equal 3.0, Cast.round_scale(2.5, 0)
  assert_equal(-3.0, Cast.round_scale(-2.5, 0))
  assert_equal 1.0, Cast.round_scale(0.5, 0)
  assert_equal 0.12345679, Cast.round_scale("0.123456785", 8)
  assert_equal 1.0e-8, Cast.round_scale("0.000000005", 8)
  assert_equal 1.0e20, Cast.round_scale(1.0e20, 2)
  assert_equal 0.0, Cast.round_scale(5.0e-324, 2)
end

test "rounding is idempotent, also past 15 significant digits" do
  ["19.99", "0.07", "99999999.99", "123456789012345.67", "90071992547409.93", "-123456789012345.67"].each do |text|
    once = Cast.round_scale(text, 2)
    assert_equal text.to_f, once
    assert_equal once, Cast.round_scale(once, 2)
  end
end

test "the attribute keeps what was assigned; the row and a reload have the rounded value" do
  reset_tables
  post = Post.new(title: "tie", price: 1.005)
  assert post.save
  assert_equal 1.005, post.price
  assert_equal "real 1.01", stored("tie")
  post.reload
  assert_equal 1.01, post.price
end

# ---- the range --------------------------------------------------------------

# Every 2-digit decimal a DECIMAL(10,2) can hold has 10 significant digits;
# a Float carries 15, so the text written is the text read.
test "every value of the declared precision reads back as the decimal that was written" do
  reset_tables
  seed = 20261111
  bad = 0
  cents = [9_999_999_999, -9_999_999_999, 1, -1, 0, 9_999_999_998, 5_000_000_005, 1_000_000_001]
  200.times do
    seed = (seed * 1103515245 + 12345) % 2147483648
    high = seed
    seed = (seed * 1103515245 + 12345) % 2147483648
    cents << (high * 2147483648 + seed) % 10_000_000_000
  end
  cents.each_with_index do |n, i|
    text = decimal_text(n, 2)
    post = Post.create(title: "p#{i}", price: text)
    back = price_of("p#{i}")
    bad += 1 unless post.persisted? && !back.nil? && back == text.to_f && NH.number_with_precision(back, precision: 2) == text
  end
  assert_equal 208, cents.size
  assert_equal 0, bad
end

# The same holds for any decimal of up to 15 significant digits; with 16
# the Float no longer tells neighbours apart (spikes/decimal/float_contract.rb
# has the sweep).
test "15 significant digits round-trip through Cast and SQLite, 16 do not" do
  reset_tables
  ["9999999999999.99", "1234567890123.45", "0.01"].each_with_index do |text, i|
    Post.insert_all([{ title: "wide#{i}", price: text }])
    back = price_of("wide#{i}")
    assert_equal text, NH.number_with_precision(back.nil? ? 0.0 : back, precision: 2)
  end
  assert_equal "99999999999999.98", NH.number_with_precision(Cast.round_scale("99999999999999.99", 2), precision: 2)
end

test "save refuses a value outside the declared precision, Infinity and NaN" do
  reset_tables
  over = Post.new(title: "over", price: 100_000_000)
  refute over.save
  assert_equal ["Price must be less than 100000000"], over.errors.full_messages
  under = Post.new(title: "under", price: "-100000000.00")
  refute under.save
  assert_equal ["Price must be greater than -100000000"], under.errors.full_messages
  inf = Post.new(title: "inf", price: "1e999")
  refute inf.save
  assert_equal ["Price must be less than 100000000"], inf.errors.full_messages
  minus = Post.new(title: "minus", price: "-1e999")
  refute minus.save
  assert_equal ["Price must be greater than -100000000"], minus.errors.full_messages
  nan = Post.new(title: "nan", price: Float::NAN)
  refute nan.save
  assert_equal ["Price must be greater than -100000000", "Price must be less than 100000000"], nan.errors.full_messages
  assert_equal 0, Post.count
  assert Post.new(title: "top", price: "99999999.99").save
  assert Post.new(title: "bottom", price: "-99999999.99").save
  assert Post.new(title: "none", price: nil).save
  post = Post.find_by(title: "top")
  refute post.nil? || post.update(price: 1.0e8)
  assert_equal 99999999.99, price_of("top")
end

# The bound is checked on the assigned value, before rounding.
test "a value that rounds up to the bound is stored" do
  reset_tables
  assert Post.new(title: "edge", price: "99999999.995").save
  assert_equal "integer 100000000", stored("edge")
end

# ---- the other writers ------------------------------------------------------

test "update, update_columns and update_all round as save does" do
  reset_tables
  post = Post.create(title: "u", price: "1.00")
  assert post.update(price: "2.675")
  assert_equal "real 2.68", stored("u")
  post.update_columns(price: 1.005)
  assert_equal "real 1.01", stored("u")
  Post.where(title: "u").update_all(price: "0.285")
  assert_equal "real 0.29", stored("u")
  Post.where(title: "u").update_all(price: nil)
  assert_equal "null ", stored("u")
end

test "insert_all and upsert_all round as save does" do
  reset_tables
  rows = Post.insert_all([{ title: "i1", price: 1.005 }, { title: "i2", price: "2.675" }, { title: "i3", price: nil }],
                         returning: [:title, :price])
  assert_equal [1.01, 2.68, nil], rows.map { |r| r["price"] }
  assert_equal "real 1.01", stored("i1")
  assert_equal "real 2.68", stored("i2")
  assert_equal "null ", stored("i3")
  Post.upsert_all([{ title: "i1", price: "0.285" }, { title: "i4", price: 8.345 }], unique_by: [:title])
  assert_equal "real 0.29", stored("i1")
  assert_equal "real 8.35", stored("i4")
  assert_equal 4, Post.count
end

# As in Rails, the writers that skip validations skip the range too: the
# value is stored as SQLite stores a Float (NaN as NULL).
test "the writers without validations store a value outside the range" do
  reset_tables
  Post.insert_all([{ title: "big", price: 123_456_789_012.5 }, { title: "inf", price: "1e999" },
                   { title: "nan", price: Float::NAN }])
  assert_equal "real 123456789012.5", stored("big")
  assert_equal "real Inf", stored("inf")
  assert_equal "null ", stored("nan")
  inf = price_of("inf")
  assert_equal false, inf.nil? || inf.finite?
  post = Post.find_by(title: "inf")
  assert_equal "Infinity not allowed in JSON", assert_raises("GeneratorError") { post.nil? ? "" : post.to_json }
end

# ---- aggregates and JSON ----------------------------------------------------

test "sum_float, average, minimum_float and maximum_float answer Floats" do
  reset_tables
  Post.insert_all([{ title: "s1", price: "19.99" }, { title: "s2", price: "0.01" }, { title: "s3", price: "5.25" },
                   { title: "s4", price: nil }])
  assert_equal 25.25, Post.sum_float(:price)
  assert_equal 0.01, Post.minimum_float(:price)
  assert_equal 19.99, Post.maximum_float(:price)
  avg = Post.average(:price)
  assert_equal 8.42, Cast.round_scale(avg.nil? ? 0.0 : avg, 2)
  assert_equal [0.01, 5.25, 19.99], Post.where(title: ["s1", "s2", "s3"]).pluck_float(:price).sort
  assert_equal 0.0, Post.where(title: "zz").sum_float(:price)
  assert_nil Post.where(title: "zz").average(:price)
  assert_nil Post.where(title: "zz").maximum_float(:price)
end

# A sum of Floats is a Float sum: round it to the scale at the edge. Below
# 15 significant digits in the total the rounded sum is the exact one.
test "a rounded sum of many prices equals the sum of their cents" do
  reset_tables
  seed = 7
  exact = 0
  rows = Array.new(0) { { title: "", price: "", views: 0 } }
  2000.times do |i|
    seed = (seed * 1103515245 + 12345) % 2147483648
    cents = seed % 10_000_000
    exact += cents
    rows << { title: "r#{i}", price: decimal_text(cents, 2), views: cents }
  end
  Post.insert_all(rows)
  assert_equal 2000, Post.count
  assert_equal decimal_text(exact, 2), NH.number_with_precision(Cast.round_scale(Post.sum_float(:price), 2), precision: 2)
  assert_equal exact, Post.sum_int(:views)
  tenths = Array.new(0) { { title: "", price: "" } }
  1000.times { |i| tenths << { title: "t#{i}", price: "0.10" } }
  Post.where_sql("1 = 1").delete_all
  Post.insert_all(tenths)
  assert_equal 100.0, Cast.round_scale(Post.sum_float(:price), 2)
end

test "to_json writes the decimal as a JSON number" do
  reset_tables
  Post.create(title: "json", price: "19.90")
  post = Post.find_by(title: "json")
  text = post.nil? ? "" : post.to_json
  assert text.include?("\"price\":19.9,")
end

# ---- the exact alternative: minor units in an integer column ----------------

test "minor units in an integer column are exact: parse, store, sum, display" do
  reset_tables
  cents = ["19.99", "0.07", "1234567.89", "0.10", "0.20"].map { |text| (Cast.round_scale(text, 2) * 100).round }
  assert_equal [1999, 7, 123456789, 10, 20], cents
  cents.each_with_index { |c, i| Post.create(title: "m#{i}", views: c) }
  total = Post.sum_int(:views)
  assert_equal 123458825, total
  assert_equal "Integer", total.class.to_s
  assert_equal "$1,234,588.25", NH.number_to_currency(total / 100.0)
  assert_equal "0.30", NH.number_with_precision((10 + 20) / 100.0, precision: 2)
  assert_equal "$0.07", NH.number_to_currency(7 / 100.0)
  assert_equal "$99,999,999,999,999.99", NH.number_to_currency(9_999_999_999_999_999.to_s.insert(-3, "."))
end

Cybertrain::Test.run!
