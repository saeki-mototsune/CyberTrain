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
  # The request parameters, {Controller#params} in an action and `params`
  # in a template. They come from the query string, a urlencoded form body
  # and the route's segments (`:id`, `:article_id`), later sources winning.
  # A JSON or multipart body is not parsed into them.
  #
  # Values are Strings (never Integers or booleans). Rails-style keys nest:
  # `article[title]=Hi` is `params.require(:article)[:title]`, and
  # `tags[]=a&tags[]=b` is `params.list(:tags)`. A key is one kind at a time,
  # a String, a list or a nested Params; the last one sent wins.
  #
  # Malformed input (a bad `%` escape, invalid UTF-8, more than 32 levels of
  # nesting or 4096 pairs) is answered with 400 before the action runs.
  # @example Strong parameters, as the scaffold writes them
  #   def article_params
  #     params.require(:article).permit(:title, :body)
  #   end
  # @api public
  class Params
    # Raised by {Params#require}. Unless a `rescue_from` handles it, the
    # request is answered with 400 and the message as plain text.
    # @api public
    class ParameterMissing < StandardError
    end

    def initialize
      @values = {}
      @lists = {}
      @children = {}
    end

    # A String value. A list or nested key gives nil, as does an absent
    # one; a key sent with no `=` gives `""`.
    # @example
    #   Article.find(params[:id])
    # @param key [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](key)
      @values[key.to_s]
    end

    # The values sent as `key[]=a&key[]=b`.
    # @param key [String, Symbol]
    # @return [Array<String>] `[]` when absent
    # @api public
    def list(key)
      arr = @lists[key.to_s]
      arr.nil? ? [] : arr
    end

    # The nested parameters sent as `key[...]`, like {#require} but without
    # raising.
    #
    # A fresh, empty Params for an absent key -- it is never stored, so
    # calling #nested twice on the same missing key returns two different
    # (both empty) objects.
    # @param key [String, Symbol]
    # @return [Params]
    # @api public
    def nested(key)
      @children[key.to_s] || Params.new
    end

    # @param key [String, Symbol]
    # @return [Boolean] true when the key was sent, of any kind
    # @api public
    def key?(key)
      k = key.to_s
      @values.key?(k) || @lists.key?(k) || @children.key?(k)
    end

    # The nested parameters under `key` (`article[...]`), which must be
    # present and non-empty. Only nested keys qualify: `require(:id)`
    # raises even when `id` was sent, since it is a String.
    # @param key [String, Symbol]
    # @return [Params]
    # @raise [ParameterMissing] `"param is missing or the value is empty:
    #   article"` (a 400 unless rescued)
    # @api public
    def require(key)
      k = key.to_s
      child = @children[k]
      if child.nil? || child.empty?
        raise ParameterMissing, "param is missing or the value is empty: #{k}"
      end
      child
    end

    # The listed keys that were sent as Strings, as a Hash ready for
    # `Model.new` or {Model#update}. Unlisted keys are dropped silently, and
    # so are lists and nested values: there is no `permit(tags: [])`; read
    # those with {#list} and {#nested}.
    # @example
    #   params.require(:article).permit(:title, :body)  # => {"title" => "Hi", "body" => "..."}
    # @param keys [Array<String, Symbol>]
    # @return [Hash{String => String}]
    # @api public
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
      k = key.to_s
      @lists.delete(k)
      @children.delete(k)
      @values[k] = value
    end

    def add_list_value(key, value)
      k = key.to_s
      @values.delete(k)
      @children.delete(k)
      @lists[k] = [] unless @lists.key?(k)
      @lists[k] << value
    end

    def child!(key)
      k = key.to_s
      @values.delete(k)
      @lists.delete(k)
      unless @children.key?(k)
        @children[k] = Params.new
      end
      @children[k]
    end

    # path comes from Query.split_key: ["id"], ["tags", ""] (append to
    # list), or ["post", "title"] / ["post", "tags", ""] (one hop per
    # nesting level). Walks down with a cursor node instead of recursing, so
    # the stack stays flat however long the path is (Query caps it at
    # MAX_DEPTH, but that is not the only guard).
    def set_path(path, value)
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
    # other), so an app that merges one tree into another gets two
    # independent trees.
    #
    # Iterative: dsts[i] receives srcs[i], and each nested pair found while
    # merging one level is appended to the two work lists. Levels are
    # independent of each other, so visiting order does not matter.
    def merge!(other)
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

    # This level's String values as a Hash (not the lists or nested
    # parameters).
    #
    # Params has no `keys` method on purpose: it would share its name with Hash#keys in a
    # class whose own code (to_h, inspect, merge!) calls Hash#keys on its
    # Hashes, the shape NOTES rule 51 records as mis-dispatching under
    # Spinel. Ask key? for one name, or to_h / inspect for the whole level.
    # @return [Hash{String => String}]
    # @api public
    def to_h
      h = {}
      @values.keys.each { |k| h[k] = @values[k] }
      h
    end

    # @return [Boolean] true when nothing was sent at this level
    # @api public
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
    # shares the elements). A while loop, no block. For merge!.
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
      @values.delete(k)
      @children.delete(k)
      @lists[k] = arr
      nil
    end
  end
end
