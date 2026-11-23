# the HTTP layer's file: SpinelHttp::Params, as cybertrain/http/params.rb has it
module SpinelHttp
  class Params
    def initialize
      @scalars = {}
      @nested = {}
    end

    def []=(key, value)
      @scalars[key] = value
    end

    def [](key)
      @scalars[key]
    end

    def child(key)
      c = @nested[key]
      if c.nil?
        c = Params.new
        @nested[key] = c
      end
      c
    end

    def nested(key)
      @nested[key]
    end

    def keys
      @scalars.keys
    end

    @max_page = 10_000

    def self.max_page
      @max_page
    end

    def self.max_page=(n)
      @max_page = n
      nil
    end
  end

  class Query
    def self.parse(s)
      p = Params.new
      p["a"] = s
      p.child("b")["c"] = "1"
      p.child("b")["d"] = "2"
      p
    end
  end
end
