# Issue #189 spike, part 1: which exact number types the pinned Spinel
# offers a decimal column (docs/design.md D73). BigDecimal (the
# pre-installed `bigdecimal` package), Rational and the Integer range. A
# record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/decimal/):
#   spinel $(spin flags) exact_types.rb -o /tmp/exact_types && /tmp/exact_types
#   ruby exact_types.rb
# Output, compiled:
#   Integer max: 9223372036854775807 (Integer)
#   max + 1: RangeError: integer overflow in +
#   Rational(1, 3) + Rational(1, 6): 1/2
#   0.1 + 0.2 == 0.3: BigDecimal true, Float false
#   to_s: 0.3e0
#   to_s("F"): ArgumentError: wrong number of arguments (given 1, expected 0)
#   round: 0.101e1 0.268e1 -0.101e1
#   half even: 0.12e0
#   to_f: 1.2345678901234567e+19
#   18,8: 0.123456789012345679e10
#   cmp: true true
#   mul: 0.5997e2
#   div: 0.33333e1
#   to_i: 3840
#   invalid: invalid value for BigDecimal(): "abc"
#   sum of 1000 x 0.1: 0.1e3 == 100: true
#   float sum of 1000 x 0.1: 99.9999999999986
# CRuby 3.3.6 prints the same but for two lines: `max + 1` is
# 9223372036854775808 (a bignum; Spinel's Integer is 64-bit and raises) and
# `to_s("F")` is 12.5 (the package's to_s takes no format, so the only text
# form is "0.125e2"). Not in the package either: `require "bigdecimal/util"`
# ("cannot load such file", so no String#to_d / Float#to_d), BigDecimal(Float)
# (ArgumentError, as CRuby without a precision), NaN and Infinity.
require "bigdecimal"

big = 9223372036854775807
one = ARGV.length + 1
puts "Integer max: #{big} (#{big.class})"
begin
  puts "max + 1: #{big + one}"
rescue RangeError => e
  puts "max + 1: RangeError: #{e.message}"
end
puts "Rational(1, 3) + Rational(1, 6): #{Rational(1, 3) + Rational(1, 6)}"

a = BigDecimal("0.1")
b = BigDecimal("0.2")
puts "0.1 + 0.2 == 0.3: BigDecimal #{(a + b) == BigDecimal("0.3")}, Float #{0.1 + 0.2 == 0.3}"
puts "to_s: #{(a + b).to_s}"
begin
  puts "to_s(\"F\"): #{BigDecimal("12.5").to_s("F")}"
rescue ArgumentError => e
  puts "to_s(\"F\"): ArgumentError: #{e.message}"
end
puts "round: #{BigDecimal("1.005").round(2).to_s} #{BigDecimal("2.675").round(2).to_s} #{BigDecimal("-1.005").round(2).to_s}"
puts "half even: #{BigDecimal("0.125").round(2, BigDecimal::ROUND_HALF_EVEN).to_s}"
puts "to_f: #{BigDecimal("12345678901234567890.12345678").to_f}"
puts "18,8: #{(BigDecimal("1234567890.12345678") + BigDecimal("0.00000001")).to_s}"
puts "cmp: #{BigDecimal("1.10") == BigDecimal("1.1")} #{BigDecimal("1.2") > BigDecimal("1.1")}"
puts "mul: #{(BigDecimal("19.99") * 3).to_s}"
puts "div: #{(BigDecimal("10") / 3).round(4).to_s}"
puts "to_i: #{(BigDecimal("38.40") * 100).round.to_i}"
begin
  BigDecimal("abc")
rescue ArgumentError => e
  puts "invalid: #{e.message}"
end
sum = BigDecimal("0")
1000.times { sum += BigDecimal("0.1") }
puts "sum of 1000 x 0.1: #{sum.to_s} == 100: #{sum == 100}"
fsum = 0.0
1000.times { fsum += 0.1 }
puts "float sum of 1000 x 0.1: #{fsum}"
