# NOTES 86 (docs/spinel-feedback.md Q): a Range of Time, and a Float Range
# behind `when Range`. Integer and String Ranges in the same places match
# CRuby and are in ../container_shapes.rb.
#
#   ruby spikes/rechecks/differing/float_range_boxed.rb
#   spinel spikes/rechecks/differing/float_range_boxed.rb -O 0 -o "$TMPDIR/fr" && "$TMPDIR/fr"
#
# Linux x86_64, Spinel 2026.11.04.7026 (a2d06115, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-19.
#   CRuby:    literal of Time: 0                 compiled: literal of Time: TypeError no implicit conversion of Time into Integer
#             Range.new of Time: 100                       Range.new of Time: TypeError no implicit conversion of Time into Integer
#             Float Range from a Hash: range               Float Range from a Hash: other
#             Float Range as an argument: [1.5, 2.5]       Float Range as an argument: []
# The last two lines, an Integer Range and an Array through the same
# parameter, are `[1, 3]` and `[]` on both.

def try(label)
  puts "#{label}: #{yield}"
rescue StandardError => e
  puts "#{label}: #{e.class.name} #{e.message}"
end

def kind(v)
  case v
  when Range then "range"
  when Array then "array"
  else "other"
  end
end

def ends_of(v)
  case v
  when Range then [v.begin, v.end]
  else []
  end
end

t1 = Time.at(0)
t2 = Time.at(100)
try("literal of Time") { (t1..t2).begin.to_i }
try("Range.new of Time") { Range.new(t1, t2).end.to_i }
held = { "f" => (1.5..2.5), "i" => (1..3), "a" => [1] }
try("Float Range from a Hash") { kind(held["f"]) }
try("Float Range as an argument") { ends_of(1.5..2.5).inspect }
try("Integer Range as an argument") { ends_of(1..3).inspect }
try("Array as an argument") { ends_of([1]).inspect }
