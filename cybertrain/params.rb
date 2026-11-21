# Cybertrain::Params -- typed, nested request parameters, with the
# Rails-flavoured strong parameters (#require, #permit, #expect) on top.
#
# The structure (four typed Hashes: scalars, lists, nested Params, uploaded
# files; the readers; what Query and Multipart fill) is the HTTP layer's,
# in cybertrain/http/params.rb. This file reopens the class to add the
# strong parameters, ParameterMissing and the filtered #inspect.
# cybertrain/context.rb registers ParameterMissing with ClientError as a
# client fault (not this file: see that registration's comment).
require "cybertrain/http/params"
require "cybertrain/http/parameter_filter"

module Cybertrain
  # The request parameters, {Controller#params} in an action and `params`
  # in a template. They come from the query string, a urlencoded form body
  # and the route's segments (`:id`, `:article_id`), later sources winning.
  # A `multipart/form-data` body fills them too: its text fields as Strings
  # and its files as {UploadedFile}s ({#upload}). A JSON body is not parsed
  # into them.
  #
  # Values are Strings (never Integers or booleans) or uploaded files.
  # Rails-style keys nest: `article[title]=Hi` is
  # `params.require(:article)[:title]`, and `tags[]=a&tags[]=b` is
  # `params.list(:tags)`. A key is one kind at a time, a String, a list, a
  # nested Params or an uploaded file; the last one sent wins.
  #
  # Malformed input (a bad `%` escape, invalid UTF-8, more than 32 levels of
  # nesting or 4096 pairs) is answered with 400 before the action runs.
  # @example Strong parameters, as the scaffold writes them
  #   def article_params
  #     params.require(:article).permit(:title, :body)
  #   end
  # @api public
  class Params
    # Raised by {Params#require} and {Params#expect}. Unless a
    # `rescue_from` handles it, the request is answered with 400 and the
    # message as plain text.
    # @api public
    class ParameterMissing < StandardError
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
      k = Key.string_of(key)
      child = @children[k]
      if child.nil? || child.empty?
        raise ParameterMissing, "param is missing or the value is empty: #{k}"
      end
      child
    end

    # The listed keys, as a Hash ready for `Model.new` or {Model#update}.
    # A Symbol or String key permits a String value; `key: []` permits a
    # list of Strings (`key[]=a&key[]=b`); `key: [:a, b: []]` permits a
    # nested level by the same rules, as a nested Hash. A value of another
    # kind than the one permitted (a list sent where a String is permitted,
    # a String where a nested level is) is dropped, not coerced, and so are
    # unlisted keys and uploaded files: read a file with {#upload}.
    #
    # A filter is a key or a Hash of key => Array: `permit(meta: :source)`
    # (the nested level's filters not in an Array) and an Array among the
    # filters (`permit([:title])`, `[[:title]]`, Rails 8's list of records)
    # are ArgumentErrors, a mistake in the code rather than in the request.
    # @example
    #   params.require(:article).permit(:title, :body)  # => {"title" => "Hi", "body" => "..."}
    #   params.require(:article).permit(:title, tags: [], meta: [:source])
    #   # => {"title" => "Hi", "tags" => ["a", "b"], "meta" => {"source" => "rss"}}
    # @param keys [Array<String, Symbol, Hash{Symbol => Array}>]
    # @return [Hash{String => Object}] values are Strings, Arrays of
    #   Strings, or nested Hashes of the same
    # @raise [ArgumentError] for a filter of another shape (see above)
    # @api public
    def permit(*keys)
      permitted_by(keys)
    end

    # Rails 8's strong parameters in one call: the nested level under the
    # spec's one key, permitted by the spec's filters as {#permit} does,
    # which must be present and permit something. A spec of a bare key
    # (`expect(:id)`) reads one String instead, and answers it as a
    # one-entry Hash (`{"id" => "3"}`); `expect(tags: [])` answers a
    # non-empty list the same way (`{"tags" => ["a"]}`).
    # @example
    #   def article_params
    #     params.expect(article: [:title, :body, tags: []])
    #   end
    # @param spec [Hash{Symbol => Array}, Symbol, String] one key
    # @return [Hash{String => Object}] as {#permit}'s
    # @raise [ParameterMissing] `"param is missing or the value is empty or
    #   invalid: article"` (a 400 unless rescued) when the key is absent,
    #   of the wrong kind (a String where a nested level is expected, a
    #   nested level where a list is), or permits nothing
    # @raise [ArgumentError] when spec is a Hash of more or fewer than one
    #   key, its value is not an Array (`expect(article: :title)`), or a
    #   filter has another shape than {#permit} takes: a mistake in the
    #   code, never answered as a 400
    # @api public
    def expect(spec)
      case spec
      when Hash
        names = spec.keys
        if names.length != 1
          msg = "expect takes a spec of one key, got #{names.length}"
          raise ArgumentError, msg
        end
        name = names[0]
        k = Key.string_of(name)
        filters = spec[name]
        case filters
        when Array
          if filters.empty?
            list = @lists[k]
            Params.expect_missing!(k) if list.nil? || list.empty?
            out = Params.permitted_hash
            out[k] = Params.copy_strings(list)
            return out
          end
          child = @children[k]
          Params.expect_missing!(k) if child.nil?
          permitted = child.permitted_by(filters)
          Params.expect_missing!(k) if permitted.empty?
          return permitted
        end
        Params.filter_not_array!("expect", k, filters.class.name.to_s)
        Params.permitted_hash
      else
        k = Key.string_of(spec)
        v = @values[k]
        Params.expect_missing!(k) if v.nil? || v.empty?
        out = Params.permitted_hash
        out[k] = v
        out
      end
    end

    # Raises the ArgumentError of a spec whose filters for key k are not an
    # Array (`expect(article: :title)`, `permit(meta: :source)`); kind is
    # the value's class name.
    def self.filter_not_array!(method, k, kind)
      msg = "#{method}'s filters for :#{k} must be an Array (#{k}: [:name] or #{k}: []), got #{kind}"
      raise ArgumentError, msg
    end

    # Raises the ArgumentError of an Array among a level's filters.
    def self.nested_array_filter!
      msg = "permit and expect take keys and key: [...] Hashes, not an Array among the filters ([[:title]] lists of records are not supported)"
      raise ArgumentError, msg
    end

    # Raises #expect's ParameterMissing for key k (the message built into a
    # local first, NOTES rule 58).
    def self.expect_missing!(k)
      msg = "param is missing or the value is empty or invalid: #{k}"
      raise ParameterMissing, msg
    end

    # A fresh empty Hash typed String => any value, seeded with a value of
    # every scalar type (NOTES rules 9 and 46) so a String, an Array and a
    # nested Hash can all be stored in it. Cast.empty_hash's shape; Params
    # belongs to the HTTP layer and does not require Cast.
    def self.permitted_hash
      h = { "" => [nil, 0, 0.0, "", true][0] }
      h.delete("")
      h
    end

    # #inspect with the value of every key ParameterFilter.filter? names
    # (Config#filter_parameters) replaced by "[FILTERED]", whatever its
    # kind (a String, a list, a nested level or a file), and nested levels
    # filtered the same way: what Dev::ErrorPage shows. A distinctive name
    # (NOTES rule 10).
    def filtered_inspect
      parts = []
      @values.keys.each { |k| parts << "#{k.inspect}=>#{Params.filtered_or(k, @values[k].inspect)}" }
      @lists.keys.each { |k| parts << "#{k.inspect}=>#{Params.filtered_or(k, @lists[k].inspect)}" }
      @children.keys.each do |k|
        piece = ParameterFilter.filter?(k) ? ParameterFilter::FILTERED.inspect : @children[k].filtered_inspect
        parts << "#{k.inspect}=>#{piece}"
      end
      @uploads.keys.each { |k| parts << "#{k.inspect}=>#{Params.filtered_or(k, @uploads[k].inspect)}" }
      "{#{parts.join(", ")}}"
    end

    # `"[FILTERED]"` (inspected) when key is filtered, else text.
    def self.filtered_or(key, text)
      ParameterFilter.filter?(key) ? ParameterFilter::FILTERED.inspect : text
    end

    # A new Array holding a copy of each String of arr (Array#dup alone
    # shares the elements). A while loop, no block.
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

    # #permit's work, on the filters as one Array (Symbols, Strings and
    # Hashes of key => Array). Recurses into a nested level once per
    # nesting of the filters, which the application writes, so the depth is
    # the spec's, never the request's. While loops, no blocks, so the
    # mixed-type filters stay out of block parameters.
    def permitted_by(filters)
      out = Params.permitted_hash
      i = 0
      while i < filters.length
        f = filters[i]
        case f
        when Hash
          names = f.keys
          j = 0
          while j < names.length
            name = names[j]
            k = Key.string_of(name)
            inner = f[name]
            case inner
            when Array
              if inner.empty?
                list = @lists[k]
                out[k] = Params.copy_strings(list) unless list.nil?
              else
                child = @children[k]
                out[k] = child.permitted_by(inner) unless child.nil?
              end
            else
              Params.filter_not_array!("permit", k, inner.class.name.to_s)
            end
            j += 1
          end
        when Array
          Params.nested_array_filter!
        else
          k = Key.string_of(f)
          out[k] = @values[k] if @values.key?(k)
        end
        i += 1
      end
      out
    end
  end
end
