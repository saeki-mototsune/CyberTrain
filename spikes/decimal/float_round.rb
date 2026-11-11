# Issue #189 spike, part 2: what Float#round(n) answers under Spinel, the
# call Cast.round_scale made for every stored decimal until D73, and what
# JSON.generate does with a Float (docs/design.md D73, spikes/NOTES.md
# rule 100). A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/decimal/):
#   spinel $(spin flags) float_round.rb -o /tmp/float_round && /tmp/float_round
#   ruby float_round.rb
# Output, compiled:
#   literal.round(2):        1.01
#   variable.round(2):       1.01
#   variable.round(variable): 1.01
#   through a case/when:     1.0 1.0
#     1.005: round(2) 1.01  round(n) 1.01  floor(x*100+0.5)/100 1.0  x*100 100.49999999999999
#     1.015: round(2) 1.02  round(n) 1.02  floor(x*100+0.5)/100 1.01  x*100 101.49999999999999
#     0.285: round(2) 0.29  round(n) 0.29  floor(x*100+0.5)/100 0.28  x*100 28.499999999999996
#     2.675: round(2) 2.68  round(n) 2.68  floor(x*100+0.5)/100 2.68  x*100 267.5
#     0.125: round(2) 0.13  round(n) 0.13  floor(x*100+0.5)/100 0.13  x*100 12.5
#     8.345: round(2) 8.35  round(n) 8.35  floor(x*100+0.5)/100 8.35  x*100 834.5000000000001
#     1.115: round(2) 1.12  round(n) 1.12  floor(x*100+0.5)/100 1.12  x*100 111.5
#     -1.005: round(2) -1.01  round(n) -1.01  floor(x*100+0.5)/100 -1.0  x*100 -100.49999999999999
#     -0.125: round(2) -0.13  round(n) -0.13  floor(x*100+0.5)/100 -0.12  x*100 -12.5
#     2.5: round(2) 2.5  round(n) 2.5  floor(x*100+0.5)/100 2.5  x*100 250.0
#     0.5: round(2) 0.5  round(n) 0.5  floor(x*100+0.5)/100 0.5  x*100 50.0
#   idempotence: 123456789012345.67 -> 123456789012345.69 -> 123456789012345.69
#   idempotence: 90071992547409.94 -> 90071992547409.95 -> 90071992547409.95
#   JSON: {"price":12.5,"whole":5.0,"small":0.00000001,"big":1e+20}
#   JSON of Infinity raises JSON::GeneratorError: Infinity not allowed in JSON
#   JSON of NaN raises JSON::GeneratorError: NaN not allowed in JSON
# CRuby 3.3.6 differs in two lines: "through a case/when: 1.01 1.01" (the
# method below is Cast.round_scale's old body; Spinel rounds the binary
# product there and CRuby corrects the tie), and the JSON numbers are
# written 1.0e-08 and 1.0e+20. Both runtimes move a value that already has
# two fractional digits once it has 17 significant ones (the two
# "idempotence" lines).
require "json"

def poly_round(v, scale)
  f = case v
      when Float then v
      when String then v.to_f
      else 0.0
      end
  f.round(scale).to_f
end

x = ARGV.empty? ? "1.005".to_f : 0.0
n = ARGV.length + 2
puts "literal.round(2):        #{1.005.round(2)}"
puts "variable.round(2):       #{x.round(2)}"
puts "variable.round(variable): #{x.round(n)}"
puts "through a case/when:     #{poly_round("1.005", 2)} #{poly_round(1.005, n)}"
["1.005", "1.015", "0.285", "2.675", "0.125", "8.345", "1.115", "-1.005", "-0.125", "2.5", "0.5"].each do |t|
  f = t.to_f
  puts "  #{t}: round(2) #{f.round(2)}  round(n) #{f.round(n)}  floor(x*100+0.5)/100 #{(f * 100 + 0.5).floor / 100.0}  x*100 #{f * 100}"
end
big = "123456789012345.67".to_f
puts "idempotence: #{big} -> #{big.round(n)} -> #{big.round(n).round(n)}"
edge = "90071992547409.93".to_f
puts "idempotence: #{edge} -> #{edge.round(n)} -> #{edge.round(n).round(n)}"
puts "JSON: #{JSON.generate({ "price" => 12.5, "whole" => 5.0, "small" => 1.0e-8, "big" => 1.0e20 })}"
inf = "1e999".to_f
begin
  puts "JSON of Infinity: #{JSON.generate({ "price" => inf })}"
rescue StandardError => e
  puts "JSON of Infinity raises #{e.class}: #{e.message}"
end
begin
  puts "JSON of NaN: #{JSON.generate({ "price" => inf - inf })}"
rescue StandardError => e
  puts "JSON of NaN raises #{e.class}: #{e.message}"
end
