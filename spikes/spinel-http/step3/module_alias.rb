# Step 4: a module constant alias, its module methods and its module-level slots.
module A
  module M
    def self.f
      3
    end

    # the HTTP layer's shape: a module-level ivar with explicit accessors
    @slot = 5

    def self.slot
      @slot
    end

    def self.slot=(n)
      @slot = n
      nil
    end

    # a module-level attr_accessor inside class << self
    class << self
      attr_accessor :extra
    end
    @extra = 7
  end

  # a class with the same slot shape (Params.max_page)
  class C
    @max = 10

    def self.max
      @max
    end

    def self.max=(n)
      @max = n
      nil
    end

    class << self
      attr_accessor :extra
    end
    @extra = 1
  end
end

module B
  M = A::M
  C = A::C
end

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

check("B::M.f == 3", B::M.f == 3)
check("B::M.equal?(A::M)", B::M.equal?(A::M))
check("B::M.name == \"A::M\"", B::M.name == "A::M")

check("A::M.slot starts 5", A::M.slot == 5)
B::M.slot = 6
check("slot= via B::M seen via A::M", A::M.slot == 6)
check("slot read via B::M", B::M.slot == 6)
A::M.slot = 8
check("slot= via A::M seen via B::M", B::M.slot == 8)

check("A::M.extra starts 7", A::M.extra == 7)
B::M.extra = 9
check("attr_accessor set via B::M seen via A::M", A::M.extra == 9)

check("A::C.max starts 10", A::C.max == 10)
B::C.max = 11
check("class slot= via B::C seen via A::C", A::C.max == 11)
B::C.extra = 12
check("class attr_accessor via B::C seen via A::C", A::C.extra == 12)
