# Cybertrain::Params -- typed, nested request parameters.
#
# Rack/Rails represent params as one Hash mixing String, Array and nested
# Hash values. Spinel's typed containers reject that mix, so a Params keeps
# three separate typed Hashes (scalars, lists, nested Params) and exposes the
# Rails-flavoured surface (#require, #permit, #[]) on top of them. Key order
# is the insertion order of each Hash (Ruby and Spinel Hashes are ordered), so
# evicting a key is one O(1) Hash#delete: the earlier per-kind order Arrays
# made every kind change an O(n) Array#delete, i.e. quadratic parsing.
module Cybertrain
  class Params
    class ParameterMissing < StandardError
    end

    # The state shared by every node of one tree. A Params is created with a
    # tree of its own; child! hands its own tree to the child, so the whole
    # tree answers to one flag and Params#read_only! flips it in O(1) instead
    # of walking up to MAX_PAIRS * MAX_DEPTH nodes. Its method names are not
    # shared with any Params or Hash method (NOTES rules 10, 34, 51).
    class Tree
      def initialize
        @sealed = false
      end

      def seal!
        @sealed = true
        nil
      end

      def sealed?
        @sealed
      end
    end

    # `tree` defaults to a fresh Tree (a Params.new has a tree of its own);
    # child! passes its own. It is always a Tree, never nil, so it is not a
    # nullable parameter (NOTES rule 7). Creating the child with a default
    # tree and swapping it afterwards would allocate a throwaway Tree per node
    # (~20% slower parse and merge! under CRuby at the Query limits).
    def initialize(tree = Tree.new)
      @values = {}
      @lists = {}
      @children = {}
      @tree = tree
    end

    # Marks this Params and every nested Params of its tree read-only and
    # returns self: after that each mutator (set_value, add_list_value,
    # child!, set_path, merge!, replace_list!) raises RuntimeError, and every
    # reader is unchanged. Request#query_params and #form_params use it on
    # the trees they cache, which several holders share. This is the
    # framework's own flag, not Object#freeze: `freeze`/`frozen?` are Object
    # methods, and sharing a name with Hash/Object is what NOTES rule 51
    # warns against. One-way: build a writable copy with
    # Params.new.merge!(read_only_params) (merge! copies, it never aliases).
    #
    # O(1): the flag lives in the Tree object that all nodes of a tree share
    # (child! creates every child in its parent's tree), so there is no walk
    # over the nodes. The flag belongs to the tree, not the node: marking a
    # nested Params (`p.nested("a").read_only!`) seals the whole tree it is
    # in, root included. Only trees built by child! (set_path, merge!, Query)
    # share state; a Params from Params.new, and the empty one #nested
    # returns for an absent key, has a tree of its own and stays writable.
    def read_only!
      @tree.seal!
      self
    end

    def read_only?
      @tree.sealed?
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
      @values.keys + @lists.keys + @children.keys
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

    # Rack-style: setting a key as one kind (scalar/list/nested) deletes it
    # from the other two (a no-op when absent), so a name is only ever one
    # kind at a time and the last write wins.
    def set_value(key, value)
      writable!
      k = key.to_s
      @lists.delete(k)
      @children.delete(k)
      @values[k] = value
    end

    def add_list_value(key, value)
      writable!
      k = key.to_s
      @values.delete(k)
      @children.delete(k)
      @lists[k] = [] unless @lists.key?(k)
      @lists[k] << value
    end

    def child!(key)
      writable!
      k = key.to_s
      @values.delete(k)
      @lists.delete(k)
      unless @children.key?(k)
        # The child joins this tree.
        @children[k] = Params.new(@tree)
      end
      @children[k]
    end

    # path comes from Query.split_key: ["id"], ["tags", ""] (append to
    # list), or ["post", "title"] / ["post", "tags", ""] (one hop per
    # nesting level). Walks down with a cursor node instead of recursing, so
    # the stack stays flat however long the path is (Query caps it at
    # MAX_DEPTH, but that is not the only guard).
    def set_path(path, value)
      writable!
      node = self
      i = 0
      done = false
      until done
        remaining = path.length - i
        if remaining <= 0
          done = true
        elsif remaining == 1
          node.set_value(path[i], value)
          done = true
        elsif remaining == 2 && path[i + 1] == ""
          node.add_list_value(path[i], value)
          done = true
        else
          node = node.child!(path[i])
          i += 1
        end
      end
      nil
    end

    # other wins on conflicts: a scalar or list key present on other
    # replaces this Params' value for it outright, and a nested Params
    # present on both sides is merged recursively (so a key only the
    # receiver's nested Params has survives). A key only this Params has,
    # at any level, is left untouched. other is never mutated, and nothing
    # of other's internal Arrays/Hashes/Params is aliased into self --
    # every list and nested Params that crosses over is copied. The copies
    # are fresh and writable (dst.child! builds a new Params in dst's tree, lists
    # are dup'd), so merging a read_only! source into Params.new yields an
    # independent, mutable tree; only the receiver must be writable.
    #
    # Iterative: dsts[i] receives srcs[i], and each nested pair found while
    # merging one level is appended to the two work lists. Levels are
    # independent of each other, so visiting order does not matter.
    def merge!(other)
      writable!
      dsts = [self]
      srcs = [other]
      i = 0
      while i < dsts.length
        dst = dsts[i]
        src = srcs[i]
        src.raw_values.keys.each { |k| dst.set_value(k, src.raw_values[k]) }
        src.lists.keys.each { |k| dst.replace_list!(k, src.lists[k].dup) }
        src.children.keys.each do |k|
          dsts << dst.child!(k)
          srcs << src.children[k]
        end
        i += 1
      end
      self
    end

    def to_h
      h = {}
      @values.keys.each { |k| h[k] = @values[k] }
      h
    end

    def empty?
      @values.empty? && @lists.empty? && @children.empty?
    end

    def inspect
      parts = []
      @values.keys.each { |k| parts << "#{k.inspect}=>#{@values[k].inspect}" }
      @lists.keys.each { |k| parts << "#{k.inspect}=>#{@lists[k].inspect}" }
      @children.keys.each { |k| parts << "#{k.inspect}=>#{@children[k].inspect}" }
      "{#{parts.join(", ")}}"
    end

    protected

    attr_reader :lists, :children

    # NOTE: named raw_values, not values -- naming this accessor "values"
    # (colliding with Hash#values) miscompiled merge! (above) under Spinel
    # back when it called itself recursively: a "const char * -> sp_int" C
    # build error, confirmed on 2026.09.12, the call resolving "values"
    # against Hash#values instead of this reader. merge! is iterative now,
    # but the name stays: a reader called like a Hash method on a class
    # whose Hashes it reads is asking for the same mis-resolution.
    def raw_values
      @values
    end

    # Replaces the list under k with arr (an owned copy), evicting the other
    # kinds. Used by merge!, which calls it on another Params.
    def replace_list!(k, arr)
      writable!
      @values.delete(k)
      @children.delete(k)
      @lists[k] = arr
      nil
    end

    private

    # Every mutator starts here (set_path reaches it through set_value,
    # add_list_value and child!). A nil return so it is one type everywhere.
    def writable!
      if @tree.sealed?
        raise "request parameters are read-only: request.query_params and request.form_params are shared caches; build your own Params (Params.new.merge!(request.query_params)) to change them"
      end
      nil
    end
  end
end
