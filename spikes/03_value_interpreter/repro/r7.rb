# SPIKE (throwaway): repro - is_a? matrix for poly-boxed values
class M; end
class N < M; end
vals = ["s", [1], {"a" => 1}, Time.at(0), 5, 1.5, nil, true, :sym, N.new]
names = ["String", "Array", "Hash", "Time", "Integer", "Float", "nil", "true", "Symbol", "N"]
i = 0
vals.each do |v|
  r = []
  r << "String" if v.is_a?(String)
  r << "Array" if v.is_a?(Array)
  r << "Hash" if v.is_a?(Hash)
  r << "Time" if v.is_a?(Time)
  r << "Integer" if v.is_a?(Integer)
  r << "Float" if v.is_a?(Float)
  r << "M" if v.is_a?(M)
  r << "NilClass" if v.nil?
  puts "#{names[i]} -> #{r.join(",")}"
  i += 1
end
