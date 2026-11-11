# Design D42 capability probe, not a database round-trip or integration test.
require "bigdecimal"
a = BigDecimal("9999999999.12345678")
b = BigDecimal("9999999999.12345679")
puts "decimal distinct: #{a != b}"
puts "decimal order: #{a < b}"
puts "scale rounding: #{BigDecimal('1.235').round(2) == BigDecimal('1.24')}"
puts "Float collapses values: #{'9999999999.12345678'.to_f == '9999999999.12345679'.to_f}"
