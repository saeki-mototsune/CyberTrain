module C
  def self.str(v)
    case v
    when nil then ""
    when String then v
    else v.to_s
    end
  end
end
module M
  def self.f
    C.str(yield)
  end
end
N = Array.new(0) { "" }
a = M.f do
  N << "a"
  "one"
end
b = M.f { 42 }
puts "#{a} #{b} #{N.join(",")}"
