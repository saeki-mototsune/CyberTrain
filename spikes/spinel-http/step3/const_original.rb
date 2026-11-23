# Step 3g: a constant defined in the original class body, read through the alias
# (Params::DEFAULT_MAX_PAGE, Response::DEFAULT_PERMISSIONS_POLICY, HttpLogContext::NONE).
module A
  class K
    MAXV = 10_000
    POLICY = "none"

    def maxv
      MAXV
    end
  end
end

module B
  K = A::K
end

module B
  class K
    def maxv2
      MAXV
    end
  end
end

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

check("B::K::MAXV from outside", B::K::MAXV == 10_000)
check("B::K::POLICY from outside", B::K::POLICY == "none")
check("original method reads MAXV", B::K.new.maxv == 10_000)
check("reopened-through-alias method reads the original's MAXV", B::K.new.maxv2 == 10_000)
