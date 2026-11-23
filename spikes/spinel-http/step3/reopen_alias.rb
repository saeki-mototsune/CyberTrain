# Step 3a: reopening a class through its alias adds to the same class.
module A
  class K
    def x
      1
    end
  end
end

module B
  K = A::K
end

module B
  class K
    def y
      2
    end
  end
end

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

check("A::K.new.y == 2", A::K.new.y == 2)
check("B::K.new.x == 1 and .y == 2", B::K.new.x == 1 && B::K.new.y == 2)
check("B::K.equal?(A::K) after reopening", B::K.equal?(A::K))
check("B::K.name == \"A::K\" after reopening", B::K.name == "A::K")
