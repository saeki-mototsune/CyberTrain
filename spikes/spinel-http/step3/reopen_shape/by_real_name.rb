# the same additions, reopened by the real name from a cybertrain file
require "reopen_shape/alias_file"

module SpinelHttp
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

module Cybertrain
  ParameterMissing = SpinelHttp::Params::ParameterMissing
end
