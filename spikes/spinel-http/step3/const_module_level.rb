# Step 3f: a constant at the aliasing module's own level, read from a reopened class.
module A
  class K
    def x
      1
    end
  end
end

module B
  K = A::K
  K_LIM = 5
end

module B
  class K
    def lim
      K_LIM
    end

    def lim_qualified
      B::K_LIM
    end
  end
end

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

check("B::K_LIM from outside", B::K_LIM == 5)
check("module-level constant read inside a reopened method", A::K.new.lim == 5)
check("B::K_LIM qualified inside a reopened method", A::K.new.lim_qualified == 5)
