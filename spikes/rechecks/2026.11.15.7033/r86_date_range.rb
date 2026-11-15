require "date"
d1 = Date.new(2026, 1, 1)
d2 = Date.new(2026, 2, 1)
r = d1..d2
puts "#{r.begin} #{r.end} #{r.cover?(Date.new(2026, 1, 15))} #{r.cover?(Date.new(2026, 3, 1))}"
