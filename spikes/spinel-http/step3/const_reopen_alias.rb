# Step 3d: a constant added by reopening through the alias (module B; class K; LIM = 5).
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
    LIM = 5

    def lim
      LIM
    end
  end
end

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

check("lim read inside a method of the reopened class", A::K.new.lim == 5)
check("B::K::LIM from outside", B::K::LIM == 5)
check("A::K::LIM from outside", A::K::LIM == 5)
