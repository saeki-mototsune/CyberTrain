# Cybertrain::Params -- typed, nested request parameters.
#
# Rack/Rails represent params as one Hash mixing String, Array and nested
# Hash values. Spinel's typed containers reject that mix, so a Params keeps
# four separate typed Hashes (scalars, lists, nested Params, uploaded files)
# and exposes the
# Rails-flavoured surface (#require, #permit, #[]) on top of them. Key order
# is the insertion order of each Hash (Ruby and Spinel Hashes are ordered), so
# evicting a key is one O(1) Hash#delete (per-kind order Arrays would make
# every kind change an O(n) Array#delete, i.e. quadratic parsing).
require_relative "http/uploaded_file"
require_relative "http/parameter_filter"

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
    # Raised by {Params#require}. Unless a `rescue_from` handles it, the
    # request is answered with 400 and the message as plain text.
    # @api public
    class ParameterMissing < StandardError
    end

    def initialize
      @values = {}
      @lists = {}
      @children = {}
      # Seeded with a blank file and emptied so the Hash is typed
      # String => UploadedFile (NOTES rule 9).
      @uploads = { "" => UploadedFile.blank }
      @uploads.delete("")
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
      @values.key?(k) || @lists.key?(k) || @children.key?(k) || @uploads.key?(k)
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

    # The file sent as `key` in a multipart body. The same value is never
    # also a String: {#[]} gives nil for it, and {#permit} never returns it,
    # so a file reaches a model only through an explicit call such as
    # `post.cover_file = params.nested(:post).upload(:cover)`.
    #
    # A file input left empty (the browser sends filename="" and no bytes
    # when nothing was chosen) is dropped by the multipart parser, so this
    # is nil for it. A form whose only field is that file then has no
    # `post` key at all: read an optional file through {#nested}, which
    # does not raise, rather than {#require}. A chosen file with no bytes
    # is kept, as a file whose {UploadedFile#empty?} is true.
    # @example
    #   file = params.nested(:post).upload(:cover)
    #   @post.cover_file = file if file
    # @param key [String, Symbol]
    # @return [UploadedFile, nil] nil when no file was sent under that name
    # @api public
    def upload(key)
      @uploads[key.to_s]
    end

    # @param key [String, Symbol]
    # @return [Boolean] true when a file was sent under that name (even a
    #   chosen file with no bytes; never an input left empty)
    # @api public
    def upload?(key)
      @uploads.key?(key.to_s)
    end

    # The largest page number {#page_number} gives (and {Relation#page}
    # accepts), `10000` by default. A module-level ivar with a literal
    # default, the Multipart shape (spikes/NOTES.md rule 18):
    # Application#boot installs Config#max_page here, since Params belongs
    # to the HTTP layer and cannot read the Config itself.
    @max_page = 10_000

    # @return [Integer] the largest page number accepted (Config#max_page)
    # @api public
    def self.max_page
      @max_page
    end

    # Installs the page ceiling. Called by Application#boot with
    # Config#max_page; a test may call it directly.
    # @param n [Integer] at least 1
    # @return [nil]
    # @api public
    def self.max_page=(n)
      @max_page = n < 1 ? 1 : n
      nil
    end

    # The most digits {Params.parse_int} reads: 18 stay below 2**63-1, past
    # which `String#to_i` raises RangeError under Spinel instead of
    # promoting to a Bignum (spikes/NOTES.md rule 25).
    MAX_INT_DIGITS = 18

    # A String value read as a decimal Integer, bounded: `default` when the
    # key is absent or its value is not an optional `-` followed by 1 to 18
    # digits (`"12abc"`, `" 3"`, `"1e3"`, `""` and a 30-digit number all
    # give `default`, and nothing ever raises), else the number clamped to
    # `min..max`. Request data is never handed to `to_i` unchecked, since
    # past 2**63-1 that raises RangeError (a 500) under Spinel.
    # @example
    #   per = params.int(:per, default: 20, min: 1, max: 100)
    # @param key [String, Symbol]
    # @param default [Integer] returned as is (not clamped)
    # @param min [Integer]
    # @param max [Integer]
    # @return [Integer]
    # @api public
    def int(key, default:, min:, max:)
      Params.clamp_int(@values[key.to_s], default, min, max)
    end

    # The 1-based page number from `?page=N`, for {Relation#page}: 1 when
    # `page` is absent or not a number, else clamped to
    # `1..Params.max_page` (Config#max_page). Reads the key `page` only.
    # @example
    #   @page = Article.order("id DESC").page(params.page_number, per: 20)
    # @return [Integer]
    # @api public
    def page_number
      # The literal key, not int(:page, ...): one method fed Symbol and
      # String keys in one program mis-dispatches its key.to_s (NOTES rule 51).
      Params.clamp_int(@values["page"], 1, 1, Params.max_page)
    end

    # parse_int(text, default) clamped to min..max (default as is).
    def self.clamp_int(text, default, min, max)
      return default if text.nil?

      s = text.to_s
      return default unless Params.int_text?(s)

      n = s.to_i
      return min if n < min
      return max if n > max

      n
    end

    # A decimal Integer from text, or default when text is not an optional
    # `-` and 1 to {MAX_INT_DIGITS} ASCII digits. Never raises: the length
    # is checked before `to_i` (NOTES rule 25). Shared with Config.
    # @param text [String]
    # @param default [Integer]
    # @return [Integer]
    # @api public
    def self.parse_int(text, default)
      s = text.to_s
      return default unless Params.int_text?(s)

      s.to_i
    end

    # True for an optional "-" and 1 to MAX_INT_DIGITS digits. A byte scan
    # through a fresh local (NOTES rule 62: the text may arrive boxed).
    def self.int_text?(text)
      s = text.to_s
      len = s.bytesize
      start = len > 0 && s.getbyte(0) == 45 ? 1 : 0 # "-"
      digits = len - start
      return false if digits < 1 || digits > MAX_INT_DIGITS

      i = start
      while i < len
        b = s.getbyte(i)
        return false if b < 48 || b > 57
        i += 1
      end
      true
    end

    # The listed keys that were sent as Strings, as a Hash ready for
    # `Model.new` or {Model#update}. Unlisted keys are dropped silently, and
    # so are lists, nested values and uploaded files: there is no
    # `permit(tags: [])`; read those with {#list}, {#nested} and {#upload}.
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
      @uploads.delete(k)
      @values[k] = value
    end

    def add_list_value(key, value)
      k = key.to_s
      @values.delete(k)
      @children.delete(k)
      @uploads.delete(k)
      @lists[k] = [] unless @lists.key?(k)
      @lists[k] << value
    end

    def child!(key)
      k = key.to_s
      @values.delete(k)
      @lists.delete(k)
      @uploads.delete(k)
      unless @children.key?(k)
        @children[k] = Params.new
      end
      @children[k]
    end

    # Stores an uploaded file under key, evicting a String, list or nested
    # Params of the same name (the last write wins, as for the other kinds).
    # Called by the multipart parser.
    # @param key [String, Symbol]
    # @param up [UploadedFile]
    def set_upload(key, up)
      k = key.to_s
      @values.delete(k)
      @lists.delete(k)
      @children.delete(k)
      @uploads[k] = up
      nil
    end

    # Stores a file at a Query.split_key-shaped path (see #set_path), the
    # file being the leaf. A trailing "" (`files[]`) does not append: a file
    # field has no list form, so the file is stored under the key before it,
    # replacing an earlier one. Same cursor walk as #set_path, no recursion.
    def set_upload_path(path, up)
      node = self
      i = 0
      done = false
      until done
        remaining = path.length - i
        if remaining <= 0
          done = true
        elsif remaining == 1 || (remaining == 2 && path[i + 1] == "")
          node.set_upload(path[i], up)
          done = true
        else
          node = node.child!(path[i])
          i += 1
        end
      end
      nil
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
    # The exception is an uploaded file, which is shared by reference: an
    # UploadedFile is immutable, and copying its body would double the memory.
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
        # Shared, not copied: an UploadedFile is immutable.
        src.upload_map.keys.each { |k| dst.set_upload(k, src.upload_map[k]) }
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

    # @return [Boolean] true when nothing was sent at this level (a file
    #   counts, so `require(:post)` succeeds for a form that sent only one)
    # @api public
    def empty?
      @values.empty? && @lists.empty? && @children.empty? && @uploads.empty?
    end

    def inspect
      parts = []
      @values.keys.each { |k| parts << "#{k.inspect}=>#{@values[k].inspect}" }
      @lists.keys.each { |k| parts << "#{k.inspect}=>#{@lists[k].inspect}" }
      @children.keys.each { |k| parts << "#{k.inspect}=>#{@children[k].inspect}" }
      @uploads.keys.each { |k| parts << "#{k.inspect}=>#{@uploads[k].inspect}" }
      "{#{parts.join(", ")}}"
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

    # The uploads Hash, for merge!. Named upload_map rather than uploads so
    # it cannot be mistaken for a Hash method (see raw_values).
    def upload_map
      @uploads
    end

    # Replaces the list under k with arr (an owned copy), evicting the other
    # kinds. Used by merge!, which calls it on another Params.
    def replace_list!(k, arr)
      @values.delete(k)
      @children.delete(k)
      @uploads.delete(k)
      @lists[k] = arr
      nil
    end
  end
end
