def check(label)
  yield
  puts "#{label}: ok"
rescue StandardError => e
  puts "#{label}: #{e.class.name}: #{e.message}"
end
def eq(want, got)
  raise "expected #{want.inspect}, got #{got.inspect}" unless want == got
end
check("Float range direct") do
  r = 1.5..2.5
  eq 1.5, r.begin
  eq 2.5, r.end
end
check("Range.new of Times") do
  t1 = Time.utc(2026, 1, 1)
  t2 = Time.utc(2026, 2, 1)
  r = Range.new(t1, t2)
  eq 2026, r.begin.year
end
check("Integer range is a Range in a case") do
  v = 1..5
  seen = case v when Range then "range" else "other" end
  eq "range", seen
end
