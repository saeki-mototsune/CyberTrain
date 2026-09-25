# SPIKE (throwaway): which narrowing formulations turn a poly Hash value into String|nil / Integer / Time|nil?
row = {"id" => 1, "title" => "Hello", "body" => nil, "created_at" => Time.at(1700000000), "score" => 1.5}

class Rec
  attr_accessor :a_int, :b_str, :c_str_nil, :d_time, :e_case, :f_int_nil
end

def cast_int(v)
  v.is_a?(Integer) ? v : 0
end
def cast_str_nil(v)
  return nil if v.nil?
  v.to_s
end
def cast_time(v)
  if v.is_a?(Time)
    v
  else
    nil
  end
end

r = Rec.new
r.a_int = cast_int(row["id"])
r.b_str = row["title"].to_s
r.c_str_nil = cast_str_nil(row["body"])
r.d_time = cast_time(row["created_at"])
v = row["title"]
r.e_case = case v
           when String then v
           else nil
           end
w = row["id"]
r.f_int_nil = w.is_a?(Integer) ? w : nil
puts r.a_int + 1
puts r.b_str.upcase
puts r.c_str_nil.inspect
puts r.d_time.year
puts r.e_case.inspect
puts r.f_int_nil.inspect
