require "cybertrain/test"
require "cybertrain/number_helper"

N = Cybertrain::NumberHelper

test "number_with_precision" do
  assert_equal "111.235", N.number_with_precision(111.2345)
  assert_equal "111.23", N.number_with_precision(111.2345, precision: 2)
  assert_equal "13.00000", N.number_with_precision(13, precision: 5)
  assert_equal "389", N.number_with_precision(389.32314, precision: 0)
  assert_equal "13", N.number_with_precision(13, precision: 5, strip_insignificant_zeros: true)
  assert_equal "1.111,23", N.number_with_precision(1111.2345, precision: 2, separator: ",", delimiter: ".")
end

test "number_with_delimiter" do
  assert_equal "12,345,678", N.number_with_delimiter(12345678)
  assert_equal "123,456", N.number_with_delimiter("123456")
  assert_equal "12,345,678.05", N.number_with_delimiter(12345678.05)
  assert_equal "12.345.678", N.number_with_delimiter(12345678, delimiter: ".")
  assert_equal "98 765 432,98", N.number_with_delimiter(98765432.98, delimiter: " ", separator: ",")
end

test "number_to_human" do
  assert_equal "123", N.number_to_human(123)
  assert_equal "1.23 Thousand", N.number_to_human(1234)
  assert_equal "12.3 Thousand", N.number_to_human(12345)
  assert_equal "1.23 Million", N.number_to_human(1234567)
  assert_equal "1.23 Billion", N.number_to_human(1234567890)
  assert_equal "1.23 Trillion", N.number_to_human(1234567890123)
  assert_equal "1.23 Quadrillion", N.number_to_human(1234567890123456)
  assert_equal "1230 Quadrillion", N.number_to_human(1234567890123456789)
  assert_equal "490 Thousand", N.number_to_human(489939, precision: 2)
  assert_equal "489.9 Thousand", N.number_to_human(489939, precision: 4)
  assert_equal "500 lt", N.number_to_human(500000, units: { unit: "ml", thousand: "lt" })
end

test "number_to_percentage" do
  assert_equal "100.000%", N.number_to_percentage(100)
  assert_equal "100%", N.number_to_percentage(100, precision: 0)
  assert_equal "302.24399%", N.number_to_percentage(302.24398923423, precision: 5)
end

test "number_to_currency" do
  assert_equal "$1,234,567,890.50", N.number_to_currency(1234567890.50)
  assert_equal "$1,234,567,890.51", N.number_to_currency(1234567890.506)
  assert_equal "$1,234,567,890.506", N.number_to_currency(1234567890.506, precision: 3)
  assert_equal "-$1,234,567,890.50", N.number_to_currency(-1234567890.50)
  assert_equal "1,234,567,890.50 €", N.number_to_currency(1234567890.50, unit: "€", format: "%n %u")
end

test "number_to_human_size" do
  assert_equal "1 Byte", N.number_to_human_size(1)
  assert_equal "123 Bytes", N.number_to_human_size(123)
  assert_equal "1.21 KB", N.number_to_human_size(1234)
  assert_equal "12.1 KB", N.number_to_human_size(12345)
  assert_equal "1.18 MB", N.number_to_human_size(1234567)
  assert_equal "1.15 GB", N.number_to_human_size(1234567890)
  assert_equal "1.12 TB", N.number_to_human_size(1234567890123)
  assert_equal "1.1 PB", N.number_to_human_size(1234567890123456)
  assert_equal "1.07 EB", N.number_to_human_size(1234567890123456789)
end

test "rounding edges on the digits" do
  assert_equal "1.00", N.number_with_precision(0.999, precision: 2)
  assert_equal "0.1", N.number_with_precision(0.05, precision: 1)
  assert_equal "0.01", N.number_with_precision(0.005, precision: 2)
  assert_equal "0", N.number_with_precision(0.4, precision: 0)
  assert_equal "-2.5", N.number_with_precision(-2.45, precision: 1)
  assert_equal "100.00", N.number_with_precision(99.999, precision: 2)
  assert_equal "100000000000000000000", N.number_with_precision(1.0e20, precision: 0)
  assert_equal "0.00001", N.number_with_precision(1.0e-05, precision: 5)
  assert_equal "1 Million", N.number_to_human(999999)
  assert_equal "0", N.number_to_human(0)
  assert_equal "-1.23 Thousand", N.number_to_human(-1234)
  assert_equal "1.5", N.number_with_delimiter("1.5")
  assert_equal "1.0", N.number_with_delimiter(1.0)
  assert_equal "-1,000", N.number_with_delimiter(-1000)
  assert_equal "1 KB", N.number_to_human_size(1024)
end

test "number_to_human below 1 and just under a unit" do
  assert_equal "0.5", N.number_to_human(0.5)
  assert_equal "0.123", N.number_to_human(0.1234)
  assert_equal "1 Thousand", N.number_to_human(999.9)
  assert_equal "999", N.number_to_human(999)
end

test "NaN and Infinity are not numbers" do
  msg = assert_raises("ArgumentError") { N.number_with_delimiter(0.0 / 0.0) }
  assert_equal "number_with_delimiter: NaN is not a number", msg
  msg = assert_raises("ArgumentError") { N.number_to_currency(1.0 / 0.0) }
  assert_equal "number_to_currency: Infinity is not a number", msg
  msg = assert_raises("ArgumentError") { N.number_to_human(-1.0 / 0.0) }
  assert_equal "number_to_human: -Infinity is not a number", msg
end

test "a non-number raises ArgumentError" do
  msg = assert_raises("ArgumentError") { N.number_to_currency("abc") }
  assert_equal "number_to_currency: \"abc\" is not a number", msg
  # nil raises here; the template helpers render "" for it (test/helpers.rb).
  msg = assert_raises("ArgumentError") { N.number_with_precision(nil) }
  assert_equal "number_with_precision: nil is not a number", msg
  msg = assert_raises("ArgumentError") { N.number_with_delimiter(nil) }
  assert_equal "number_with_delimiter: nil is not a number", msg
end

test "an oversized exponent or precision is rejected" do
  msg = assert_raises("ArgumentError") { N.number_with_delimiter("1e401") }
  assert_equal "number_with_delimiter: \"1e401\" is not a number", msg
  assert_equal 301, N.number_with_delimiter("1e300").delete(",").length
  assert_raises("ArgumentError") { N.number_with_precision(1, precision: 101) }
  assert_raises("ArgumentError") { N.number_with_precision(1, precision: -1) }
  assert_raises("ArgumentError") { N.number_to_percentage(1, precision: 101) }
  assert_raises("ArgumentError") { N.number_to_currency(1, precision: -1) }
  assert_raises("ArgumentError") { N.number_to_human(1, precision: 101) }
end

Cybertrain::Test.run!
