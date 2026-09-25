# SPIKE (throwaway): repro - does `when Array` match a Time held in a poly value?
def kind(v)
  case v
  when String then "String"
  when Array then "Array"
  when Time then "Time"
  else "other"
  end
end
vals = ["s", [1], Time.at(0), 5]
vals.each { |v| puts kind(v) }
t = Time.at(0)
puts t.is_a?(Array)
puts vals[2].is_a?(Array)
puts Array === vals[2]
