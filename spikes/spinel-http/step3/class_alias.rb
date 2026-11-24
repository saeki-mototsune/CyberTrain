# Step 2: a class constant alias is the same class object.
module A
  class K
    def x
      1
    end
  end

  class E < StandardError
  end
end

module B
  K = A::K
  E = A::E
end

class Sub < B::K
  def z
    x + 10
  end
end

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

check("B::K.new.x == 1", B::K.new.x == 1)
check("class Sub < B::K; Sub.new.z == 11", Sub.new.z == 11)
check("Sub.new.x == 1 (inherited)", Sub.new.x == 1)

caught = false
begin
  raise A::E, "boom"
rescue B::E => e
  caught = true
end
check("rescue B::E catches A::E", caught)

caught2 = false
begin
  raise B::E, "boom2"
rescue A::E => e
  caught2 = (e.message == "boom2")
end
check("rescue A::E catches raise B::E", caught2)

check("B::K.name == \"A::K\"", B::K.name == "A::K")
check("B::K.equal?(A::K)", B::K.equal?(A::K))
