# Cybertrain::Params -- typed, nested request parameters.
#
# Rack/Rails represent params as one Hash mixing String, Array and nested
# Hash values. Spinel's typed containers reject that mix, so a Params keeps
# three separate typed Hashes (scalars, lists, nested Params) and exposes the
# Rails-flavoured surface (#require, #permit, #[]) on top of them. Key order
# is the insertion order of each Hash (Ruby and Spinel Hashes are ordered), so
# evicting a key is one O(1) Hash#delete (per-kind order Arrays would make
# every kind change an O(n) Array#delete, i.e. quadratic parsing).
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
    # reader keeps answering but with copies of the Strings and Arrays it
    # holds (#[], #list, #permit, #to_h), so a holder cannot change the tree
    # through a returned object either. Request#query_params and #form_params use it on
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

    # A sealed tree is shared by every holder of request.query_params, and
    # a String is mutable (`<<`, `upcase!`, `replace`): handing out the
    # stored one would let a holder change the cache for everybody without
    # ever reaching writable!. So a read_only! tree answers with a copy
    # (nil stays nil: the method's type is String|nil, NOTES rule 11). Only
    # a sealed tree pays for the copy on read; a writable Params is the
    # caller's own and returns its own objects.
    def [](key)
      v = @values[key.to_s]
      v.nil? ? nil : (@tree.sealed? ? v.dup : v)
    end

    # The same rule for the list: a sealed tree answers with a new Array of
    # copied Strings (Array#dup alone would still share the elements), so
    # neither `list("tags") << "x"` nor `list("tags")[0] << "x"` reaches the
    # cache. Copied by Params.copy_strings (a while loop, no block). A
    # writable Params returns its internal Array.
    def list(key)
      arr = @lists[key.to_s]
      return [] if arr.nil?
      @tree.sealed? ? Params.copy_strings(arr) : arr
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

    def require(key)
      k = key.to_s
      child = @children[k]
      if child.nil? || child.empty?
        raise ParameterMissing, "param is missing or the value is empty: #{k}"
      end
      child
    end

    # The values follow #[]: copies when the tree is sealed.
    def permit(*keys)
      permitted = {}
      keys.each do |key|
        k = key.to_s
        permitted[k] = self[k] if @values.key?(k)
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
    # of other's internal Arrays/Hashes/Params/Strings is aliased into self
    # -- every scalar, list element and nested Params that crosses over is
    # copied (a String is mutable, so `dst["q"] << "x"` must not change
    # other). The copies are fresh and writable (dst.child! builds a new
    # Params in dst's tree), so merging a read_only! source into Params.new
    # yields an independent, mutable tree; only the receiver must be writable.
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
        src.raw_values.keys.each { |k| dst.set_value(k, src.raw_values[k].dup) }
        src.lists.keys.each { |k| dst.replace_list!(k, Params.copy_strings(src.lists[k])) }
        src.children.keys.each do |k|
          dsts << dst.child!(k)
          srcs << src.children[k]
        end
        i += 1
      end
      self
    end

    # Scalars only, copied like #[] when the tree is sealed. Params has no
    # `keys` method on purpose: it would share its name with Hash#keys in a
    # class whose own code (to_h, inspect, merge!) calls Hash#keys on its
    # Hashes, the shape NOTES rule 51 records as mis-dispatching under
    # Spinel. Ask key? for one name, or to_h / inspect for the whole level.
    def to_h
      h = {}
      @values.keys.each { |k| h[k] = self[k] }
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

    # A new Array holding a copy of each String of arr (Array#dup alone
    # shares the elements). For merge!.
    def self.copy_strings(arr)
      copy = []
      i = 0
      while i < arr.length
        copy << arr[i].dup
        i += 1
      end
      copy
    end

    protected

    attr_reader :lists, :children

    # NOTE: named raw_values, not values -- a reader called "values" collides
    # with Hash#values: under Spinel the call resolves "values" against
    # Hash#values instead of this reader (a "const char * -> sp_int" C build
    # error, confirmed on 2026.09.12 in a recursive merge!). merge! is
    # iterative, but a reader named like a Hash method on a class whose
    # Hashes it reads asks for the same mis-resolution.
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
