# Cybertrain::Params -- typed, nested request parameters.
#
# Rack/Rails represent params as one Hash mixing String, Array and nested
# Hash values. Spinel's typed containers reject that mix, so a Params keeps
# three separate typed Hashes (scalars, lists, nested Params) plus an
# insertion-order Array per kind, and exposes the Rails-flavoured surface
# (#require, #permit, #[]) on top of them.
module Cybertrain
  class Params
    class ParameterMissing < StandardError
    end

    def initialize
      @values = {}
      @value_order = []
      @lists = {}
      @list_order = []
      @children = {}
      @child_order = []
    end

    def [](key)
      @values[key.to_s]
    end

    def list(key)
      @lists[key.to_s] || []
    end

    # A fresh, empty Params for an absent key -- it is never stored, so
    # calling #nested twice on the same missing key returns two different
    # (both empty) objects.
    def nested(key)
      @children[key.to_s] || Params.new
    end

    def key?(key)
      k = key.to_s
      @values.key?(k) || @lists.key?(k) || @children.key?(k)
    end

    def keys
      @value_order + @list_order + @child_order
    end

    def require(key)
      k = key.to_s
      child = @children[k]
      if child.nil? || child.empty?
        raise ParameterMissing, "param is missing or the value is empty: #{k}"
      end
      child
    end

    def permit(*keys)
      permitted = {}
      keys.each do |key|
        k = key.to_s
        permitted[k] = @values[k] if @values.key?(k)
      end
      permitted
    end

    def set_value(key, value)
      k = key.to_s
      evict_from_list(k)
      evict_from_children(k)
      @value_order << k unless @values.key?(k)
      @values[k] = value
    end

    def add_list_value(key, value)
      k = key.to_s
      evict_from_values(k)
      evict_from_children(k)
      unless @lists.key?(k)
        @lists[k] = []
        @list_order << k
      end
      @lists[k] << value
    end

    def child!(key)
      k = key.to_s
      evict_from_values(k)
      evict_from_list(k)
      unless @children.key?(k)
        @children[k] = Params.new
        @child_order << k
      end
      @children[k]
    end

    # path comes from Query.split_key: ["id"], ["tags", ""] (append to
    # list), or ["post", "title"] / ["post", "tags", ""] (one hop per
    # nesting level, recursing into the child Params).
    def set_path(path, value)
      if path.length == 1
        set_value(path[0], value)
      elsif path.length == 2 && path[1] == ""
        add_list_value(path[0], value)
      else
        child!(path[0]).set_path(path[1..-1], value)
      end
    end

    # other wins on conflicts: a scalar or list key present on other
    # replaces this Params' value for it outright, and a nested Params
    # present on both sides is merged recursively (so a key only the
    # receiver's nested Params has survives). A key only this Params has,
    # at any level, is left untouched. other is never mutated, and nothing
    # of other's internal Arrays/Hashes/Params is aliased into self --
    # every list and nested Params that crosses over is copied.
    def merge!(other)
      other.value_order.each { |k| set_value(k, other.raw_values[k]) }
      other.list_order.each do |k|
        evict_from_values(k)
        evict_from_children(k)
        @list_order << k unless @lists.key?(k)
        @lists[k] = other.lists[k].dup
      end
      other.child_order.each do |k|
        existing = @children[k]
        if existing.nil?
          evict_from_values(k)
          evict_from_list(k)
          @child_order << k
          @children[k] = Params.new.merge!(other.children[k])
        else
          existing.merge!(other.children[k])
        end
      end
      self
    end

    def to_h
      h = {}
      @value_order.each { |k| h[k] = @values[k] }
      h
    end

    def empty?
      @value_order.empty? && @list_order.empty? && @child_order.empty?
    end

    def inspect
      parts = []
      @value_order.each { |k| parts << "#{k.inspect}=>#{@values[k].inspect}" }
      @list_order.each { |k| parts << "#{k.inspect}=>#{@lists[k].inspect}" }
      @child_order.each { |k| parts << "#{k.inspect}=>#{@children[k].inspect}" }
      "{#{parts.join(", ")}}"
    end

    protected

    attr_reader :value_order, :lists, :list_order, :children, :child_order

    # NOTE: named raw_values, not values -- naming this accessor "values"
    # (colliding with Hash#values) miscompiles the recursive merge! below
    # under Spinel (a "const char * -> sp_int" C build error, confirmed on
    # 2026.09.12): the recursive self-call apparently resolves "values"
    # against Hash#values instead of this reader. Renaming it sidesteps
    # the miscompile; no functional change.
    def raw_values
      @values
    end

    private

    # Rack-style eviction: setting a key as one kind (scalar/list/nested)
    # removes it from the other two, so a name can only ever be one kind
    # at a time and the last write wins.
    def evict_from_values(k)
      return unless @values.key?(k)
      @values.delete(k)
      @value_order.delete(k)
    end

    def evict_from_list(k)
      return unless @lists.key?(k)
      @lists.delete(k)
      @list_order.delete(k)
    end

    def evict_from_children(k)
      return unless @children.key?(k)
      @children.delete(k)
      @child_order.delete(k)
    end
  end
end
