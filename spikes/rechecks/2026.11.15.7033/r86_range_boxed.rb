def check(label)
  yield
  puts "#{label}: ok"
rescue StandardError => e
  puts "#{label}: #{e.class.name}: #{e.message}"
end
def eq(want, got)
  raise "expected #{want.inspect}, got #{got.inspect}" unless want == got
end
def ends_of(v)
  out = Array.new(0) { "" }
  case v
  when Range
    out << v.begin.to_s
    out << v.end.to_s
  end
  out
end
check("Float range through a boxed value") { eq ["1.5", "2.5"], ends_of(1.5..2.5) }
check("String range through a boxed value") { eq ["a", "z"], ends_of("a".."z") }
check("Time range in a Hash value") do
  t1 = Time.utc(2026, 1, 1)
  t2 = Time.utc(2026, 2, 1)
  h = { created_at: t1..t2 }
  eq 2, ends_of(h[:created_at]).size
end
