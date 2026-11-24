# cybertrain/params.rb's shape: module Cybertrain; class Params, over the alias
require "reopen_shape/alias_file"

module Cybertrain
  class Params
    class ParameterMissing < StandardError
    end

    def permit(*keys)
      out = {}
      keys.each do |k|
        v = @scalars[k]
        out[k] = v unless v.nil?
      end
      out
    end

    def require(key)
      c = @nested[key]
      raise ParameterMissing, key if c.nil?
      c
    end
  end
end
