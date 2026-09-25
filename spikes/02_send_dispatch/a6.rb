# SPIKE (throwaway): send on a local whose static type is the base class (router-like factory) / identity-laundered local
class B; def hi; 1; end; end
class S < B; def yo; 2; end; end
class T < B; def zz; "z"; end; end
def s(x); x; end
def make(n)
  if n == "S" then S.new else T.new end
end
arr = [:yo, :hi, :zz]
k = make(ARGV[0] || "T")
p k.class
arr.each do |m|
  m = m
  begin
    r = k.send(m)
    puts "#{m} -> #{r.inspect} (#{r.class})"
  rescue NoMethodError => e
    puts "#{m} -> NoMethodError: #{e.message}"
  end
end
