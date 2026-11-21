# Cybertrain::Params, the structure -- typed, nested request parameters as
# the HTTP layer fills them.
#
# Rack/Rails represent params as one Hash mixing String, Array and nested
# Hash values. Spinel's typed containers reject that mix, so a Params keeps
# four separate typed Hashes (scalars, lists, nested Params, uploaded files).
# Key order is the insertion order of each Hash (Ruby and Spinel Hashes are
# ordered), so evicting a key is one O(1) Hash#delete (per-kind order Arrays
# would make every kind change an O(n) Array#delete, i.e. quadratic
# parsing).
#
# This file is the HTTP layer's half: what Query and Multipart fill and the
# readers over it. It loads alone (script/check-http-layer). Strong
# parameters are not the layer's: a framework on top adds them by
# reopening the class (docs/design.md D91).
require_relative "uploaded_file"
require_relative "../key"

module Cybertrain
  # The request parameters as the HTTP layer parses them: Strings, lists of
  # Strings, nested Params and uploaded files, one kind per key. A framework
  # on top may reopen the class to add strong parameters.
  class Params
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
      @values[Key.string_of(key)]
    end

    # The values sent as `key[]=a&key[]=b`.
    # @param key [String, Symbol]
    # @return [Array<String>] `[]` when absent
    # @api public
    def list(key)
      arr = @lists[Key.string_of(key)]
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
      @children[Key.string_of(key)] || Params.new
    end

    # @param key [String, Symbol]
    # @return [Boolean] true when the key was sent, of any kind
    # @api public
    def key?(key)
      k = Key.string_of(key)
      @values.key?(k) || @lists.key?(k) || @children.key?(k) || @uploads.key?(k)
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
      @uploads[Key.string_of(key)]
    end

    # @param key [String, Symbol]
    # @return [Boolean] true when a file was sent under that name (even a
    #   chosen file with no bytes; never an input left empty)
    # @api public
    def upload?(key)
      @uploads.key?(Key.string_of(key))
    end

    # {.max_page} until another ceiling is installed.
    DEFAULT_MAX_PAGE = 10_000

    # The largest page number {#page_number} gives, `10000` by default. A
    # module-level ivar, the Multipart shape (spikes/NOTES.md rule 18): the
    # application's configured ceiling is installed here at boot, since the
    # HTTP layer reads no configuration of its own.
    @max_page = DEFAULT_MAX_PAGE

    # @return [Integer] the largest page number accepted
    # @api public
    def self.max_page
      @max_page
    end

    # Installs the page ceiling, at boot, before any thread starts; a test
    # may call it directly.
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
    # @return [Integer]
    # @api public
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
      Params.clamp_int(@values[Key.string_of(key)], default, min, max)
    end

    # The 1-based page number from `?page=N`, for a paginated query: 1 when
    # `page` is absent or not a number, else clamped to
    # `1..Params.max_page`. Reads the key `page` only.
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
    # `-` and 1 to 18 ({MAX_INT_DIGITS}) ASCII digits. Never raises: the length
    # is checked before `to_i` (NOTES rule 25). Public, so that other text
    # (a setting, say) is read the same way.
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

    # Rack-style: setting a key as one kind (scalar/list/nested) deletes it
    # from the other two (a no-op when absent), so a name is only ever one
    # kind at a time and the last write wins.
    def set_value(key, value)
      k = Key.string_of(key)
      @lists.delete(k)
      @children.delete(k)
      @uploads.delete(k)
      @values[k] = value
    end

    def add_list_value(key, value)
      k = Key.string_of(key)
      @values.delete(k)
      @children.delete(k)
      @uploads.delete(k)
      @lists[k] = [] unless @lists.key?(k)
      @lists[k] << value
    end

    def child!(key)
      k = Key.string_of(key)
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
      k = Key.string_of(key)
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

    # This level's String values as a Hash (not the lists or nested
    # parameters).
    #
    # Params has no `keys` method on purpose: it would share its name with Hash#keys in a
    # class whose own code (to_h, inspect) calls Hash#keys on its
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
  end
end
