# Step 3h: the other member kinds a reopening can add, through the alias:
# attr_accessor, a class-level ivar with def self., class << self, an include, a nested class.
module A
  class K
    def x
      1
    end
  end
end

module Tag
  def tag
    "t"
  end
end

module B
  K = A::K
end

module B
  class K
    include Tag

    attr_accessor :name

    class Inner < StandardError
    end

    @count = 3

    def self.count
      @count
    end

    def self.count=(n)
      @count = n
      nil
    end

    class << self
      attr_accessor :extra
    end
    @extra = 4

    def raise_inner
      raise Inner, "in"
    end
  end
end

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

k = A::K.new
k.name = "n"
check("attr_accessor added through the alias", k.name == "n")
check("include added through the alias", k.tag == "t")
check("class-level ivar with def self.", A::K.count == 3)
B::K.count = 6
check("class-level slot set via B::K read via A::K", A::K.count == 6)
check("class << self attr_accessor", A::K.extra == 4)
ok = false
begin
  k.raise_inner
rescue A::K::Inner => e
  ok = true
end
check("nested class rescued via A::K::Inner", ok)
check("B::K::Inner.equal?(A::K::Inner)", B::K::Inner.equal?(A::K::Inner))
