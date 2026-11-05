# Cybertrain::Html -- escaping helpers and Cybertrain::SafeString, the marker
# type views use to say "this string is already safe to drop into HTML",
# and the tag builder (Html.tag and friends).
require "cybertrain/generator/inflector"

module Cybertrain
  # HTML escaping for controllers and models. Templates escape `<%= %>`
  # output themselves; these are for building HTML in Ruby, e.g. for
  # `render html:`.
  # @api public
  module Html
    # Escapes the five characters that matter for HTML text/attribute
    # contexts. Scans bytes (the five are ASCII, so multibyte UTF-8 sequences
    # are never split) and returns the input untouched when nothing needs
    # escaping, since most interpolated values are plain text. Measured 2.7x
    # faster than an each_char loop under Spinel; this runs for every <%= %>.
    #
    # `&`, `<`, `>`, `"` and `'` become entities.
    # @param value [String]
    # @return [String]
    # @api public
    def self.escape(value)
      # The parameter is polymorphic under Spinel (callers hand in Strings of
      # more than one static type), which made every getbyte and comparison
      # below a dynamic call: most of this method's time. value.to_s has one
      # static type (every to_s in the program returns a String; SafeString's
      # included, see SafeString::EMPTY), so the loops compile to plain
      # C, and for a String it is the String itself, not a copy. It is also
      # what comes back when nothing needs escaping, so callers get a typed
      # String rather than the polymorphic parameter. Spinel 2026.09.12
      # narrowed a parameter used only through to_s to one caller's type (it
      # once inferred an Integer here and turned Strings into "0"), so this
      # used to be a `case value when String`; that no longer happens on
      # 2026.10.27.7020 (docs/spinel-feedback.md, item 2).
      str = value.to_s
      n = str.bytesize
      i = 0
      # Most values need nothing: find the first byte that does before
      # allocating a buffer at all.
      while i < n
        b = str.getbyte(i)
        break if b == 38 || b == 60 || b == 62 || b == 34 || b == 39
        i += 1
      end
      return str if i == n

      buf = +""
      dirty = false
      start = 0
      while i < n
        b = str.getbyte(i)
        if b == 38 || b == 60 || b == 62 || b == 34 || b == 39
          buf << str.byteslice(start, i - start) if i > start
          case b
          when 38 then buf << "&amp;"
          when 60 then buf << "&lt;"
          when 62 then buf << "&gt;"
          when 34 then buf << "&quot;"
          else buf << "&#39;"
          end
          start = i + 1
          dirty = true
        end
        i += 1
      end
      return str unless dirty

      buf << str.byteslice(start, n - start) if n > start
      buf
    end

    # Marks trusted HTML as safe, so it is output as it is.
    # @example
    #   render html: Cybertrain::Html.safe("<p>#{Cybertrain::Html.escape(@article.title)}</p>")
    # @param str [String]
    # @return [SafeString]
    # @api public
    def self.safe(str)
      SafeString.of(str)
    end

    # Renders any value a template might interpolate: nil disappears,
    # SafeString passes through untouched, plain strings get escaped, and
    # everything else (Integer, Float, true, false) uses #to_s.
    def self.out(value)
      case value
      when nil then ""
      when SafeString then value.to_s
      when String then escape(value)
      else value.to_s
      end
    end
  end

  # A string that has already been through Html.escape (or was built from
  # only safe pieces) and should not be escaped again when rendered.
  #
  # Templates print it unescaped (`raw(x)` and `x.html_safe` make one);
  # {Controller#render} `html:` sends it as it is, where a plain String is
  # escaped. It is a wrapper, not a String subclass. There is no
  # `String#html_safe` in Ruby code: use {Html.safe} or `SafeString.of`.
  # @api public
  class SafeString
    # @param str [String] trusted HTML
    # @api public
    def initialize(str)
      @str = str
    end

    # SafeString.of(str), safe for a String made in the argument itself
    # (`SafeString.of("<a>#{x}</a>")`). Under Spinel 2026.09.12 the generated
    # `new` allocates the object before it roots its argument, so a garbage
    # collection in that allocation frees a String that only the argument
    # holds (a use-after-free that showed as a rare crash under load). The
    # parameter of an ordinary method is rooted on entry, so going through
    # one is enough; bind the String to a local first if you call `new`.
    # @param str [String] trusted HTML
    # @return [SafeString]
    # @api public
    def self.of(str)
      SafeString.new(str)
    end

    # @return [String] the HTML
    # @api public
    def to_s
      @str
    end

    def to_str
      @str
    end

    def html_safe?
      true
    end

    def ==(other)
      case other
      when SafeString then @str == other.to_s
      when String then @str == other
      else false
      end
    end

    # Concatenating with a plain String escapes it first, so building up a
    # SafeString piece by piece never lets unsafe content slip through.
    # @param other [String, SafeString]
    # @return [SafeString]
    # @api public
    def +(other)
      # Built in two steps: a case expression whose branches both construct
      # a SafeString fails to compile when SafeString gets Spinel's unboxed
      # value-type layout (every SafeString in the program travelling only
      # as a keyword argument).
      piece = case other
              when SafeString then other.to_s
              # other.to_s rather than other: in a program that never calls
              # +, Spinel types the unused parameter as an Integer and passed
              # that type on to Html.escape's (test/router.rb caught it).
              else Html.escape(other.to_s)
              end
      SafeString.of(@str + piece)
    end

    # Built here so that every program requiring this file constructs a
    # SafeString with a String. One that never did (an API-only program, a
    # program that never renders) left SafeString#to_s untyped, and with it
    # every `v.to_s` in the program: the parameter narrowing idiom (`s =
    # v.to_s` before a byte scan, Html.escape, Cast.parse_time) then kept the
    # boxed value, whose `getbyte` raises NoMethodError once the openssl
    # package is in the program (spikes/NOTES.md rules 56 and 62).
    EMPTY = SafeString.new("")
  end

  # Building tags in Ruby and in templates (`tag.div`, `content_tag`,
  # `safe_join`, `class_names`, `dom_id`): docs/guide/template-language.md,
  # "The tag builder".
  module Html
    # Elements that have no content and no closing tag.
    # @api public
    VOID_ELEMENTS = %w[area base br col embed hr img input link meta source track wbr]

    # An element: `Html.tag("a", { href: "/x", class: ["btn", "big"] }, "Go")`
    # is `<a href="/x" class="btn big">Go</a>`. The block's value, when
    # given, is the content instead of `content`. Content that is not a
    # SafeString is escaped; a void element (`br`, `input`, ...) takes none.
    # Attributes: `nil` and `false` drop the attribute, `true` writes it bare
    # (`disabled`), an Array joins its non-nil items with spaces, `data:` and
    # `aria:` Hashes become `data-*` / `aria-*` attributes (underscores
    # become dashes, `true`/`false` are written out), and every value is
    # escaped, a SafeString too.
    # @param name [String] the element name, `[a-z][a-z0-9-]*`
    # @param attrs [Hash{String, Symbol => Object}]
    # @param content [Object, nil]
    # @return [SafeString]
    # @raise [ArgumentError] for an invalid element or attribute name
    # @raise [RuntimeError] for content in a void element
    # @api public
    def self.tag(name, attrs = {}, content = nil, &block)
      inner = ""
      given = false
      if block
        inner = content_html(block.call)
        given = true
      elsif !content.nil?
        inner = content_html(content)
        given = true
      end
      build_tag(name, attrs, inner, given)
    end

    # Html.tag with the content already HTML (inner; given false for none):
    # what the template helpers call, with a block's output as `inner`.
    # @api private
    def self.build_tag(name, attrs, inner, given)
      tag_name = name.to_s
      raise ArgumentError, "invalid element name '#{tag_name}'" unless element_name?(tag_name)

      void = void_element?(tag_name)
      raise "#{tag_name} is a void element" if void && given

      attr_text = tag_attributes(attrs)
      return SafeString.of("<#{tag_name}#{attr_text}>") if void

      SafeString.of("<#{tag_name}#{attr_text}>#{inner}</#{tag_name}>")
    end

    # The attributes of Html.tag as HTML, each with its leading space ("" for
    # none). Not named `attributes`: Model#attributes returns a Hash, and one
    # name with two return types corrupts inference (spikes/NOTES.md rule 34).
    # @param attrs [Hash{String, Symbol => Object}]
    # @return [String]
    # @api public
    def self.tag_attributes(attrs)
      buf = +""
      # each_key: iterating a Hash of mixed keys into a String sink can box
      # the key (spikes/NOTES.md rule 29).
      attrs.each_key do |key|
        attr_name = key_text(key)
        value = attrs[key]
        nested = false
        if attr_name == "data" || attr_name == "aria"
          case value
          when Hash
            nested = true
            value.each_key do |sub|
              sub_name = "#{attr_name}-#{key_text(sub).tr("_", "-")}"
              buf << attribute_html(sub_name, value[sub], true)
            end
          end
        end
        if !nested && attr_name == "class"
          # class: { active: on } / ["btn", { big: x }]: Rails' class_names.
          case value
          when Time then nil
          when Array, Hash
            nested = true
            list = []
            list << value
            words = class_names_of(list)
            buf << attribute_html(attr_name, words, false)
          end
        end
        buf << attribute_html(attr_name, value, false) unless nested
      end
      buf
    end

    # One attribute, ` name="value"` ("" when it is dropped). nested: inside
    # data:/aria:, where true and false are written out as Rails does. An
    # Array joins with spaces (inside data: too).
    # @api private
    def self.attribute_html(attr_name, value, nested)
      raise ArgumentError, "invalid attribute name '#{attr_name}'" unless attribute_name?(attr_name)

      case value
      when nil then return ""
      when true then return nested ? " #{attr_name}=\"true\"" : " #{attr_name}"
      when false then return nested ? " #{attr_name}=\"false\"" : ""
      # Time before Array: a Time in a polymorphic slot matches Array
      # (spikes/NOTES.md rule 8).
      when Time then return " #{attr_name}=\"#{escape(value.to_s)}\""
      when Array
        words = Array.new(0) { "" }
        value.each do |item|
          case item
          when nil then nil
          else words << item.to_s
          end
        end
        joined = words.join(" ")
        return " #{attr_name}=\"#{escape(joined)}\""
      when Hash then raise ArgumentError, "attribute '#{attr_name}' cannot be a Hash"
      end
      " #{attr_name}=\"#{escape(value.to_s)}\""
    end

    # Content for a tag or safe_join: a SafeString as it is, nil as nothing,
    # anything else escaped.
    # @api private
    def self.content_html(value)
      case value
      when nil then ""
      when SafeString then value.to_s
      else escape(value.to_s)
      end
    end

    # @api private
    def self.key_text(key)
      case key
      when Symbol then key.to_s
      when String then key
      else key.to_s
      end
    end

    # @api private
    def self.void_element?(tag_name)
      i = 0
      while i < VOID_ELEMENTS.size
        return true if VOID_ELEMENTS[i] == tag_name
        i += 1
      end
      false
    end

    # [a-z][a-z0-9-]*: lowercase HTML, SVG and custom elements.
    # @api private
    def self.element_name?(text)
      s = text.to_s
      n = s.bytesize
      return false if n == 0

      i = 0
      while i < n
        b = s.getbyte(i)
        lower = b >= 97 && b <= 122
        ok = i == 0 ? lower : (lower || (b >= 48 && b <= 57) || b == 45)
        return false unless ok
        i += 1
      end
      true
    end

    # [a-zA-Z_:][-a-zA-Z0-9_:.]*, which leaves no way to break out of the tag.
    # @api private
    def self.attribute_name?(text)
      s = text.to_s
      n = s.bytesize
      return false if n == 0

      i = 0
      while i < n
        b = s.getbyte(i)
        start = (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || b == 95 || b == 58
        ok = i == 0 ? start : (start || (b >= 48 && b <= 57) || b == 45 || b == 46)
        return false unless ok
        i += 1
      end
      true
    end

    # Joins items into HTML, escaping every item (and the separator) that
    # is not a SafeString: `safe_join([tag.b("a"), "<"], " ")`.
    # @param items [Array]
    # @param sep [String, SafeString]
    # @return [SafeString]
    # @api public
    def self.safe_join(items, sep = "")
      glue = content_html(sep)
      parts = Array.new(0) { "" }
      items.each { |item| parts << content_html(item) }
      joined = parts.join(glue)
      SafeString.of(joined)
    end

    # Rails' class_names / token_list: the words of Strings and Symbols, of
    # Arrays (nested too) and of each Hash key whose value is truthy, each
    # word once, in order. `class_names("a", { "b" => true, "c" => false })`
    # is "a b".
    # @return [String]
    # @api public
    def self.class_names(*values)
      class_names_of(values)
    end

    # class_names for an Array of values (the template helper's arguments).
    # @api private
    def self.class_names_of(values)
      words = Array.new(0) { "" }
      add_class_words(words, values)
      words.join(" ")
    end

    # @api private
    def self.add_class_words(words, values)
      values.each do |value|
        case value
        when nil, false, true then nil
        when Time then add_words(words, value.to_s)
        when Array then add_class_words(words, value)
        when Hash
          value.each_key do |key|
            on = value[key]
            add_words(words, key_text(key)) unless on.nil? || on == false
          end
        else add_words(words, value.to_s)
        end
      end
      nil
    end

    # @api private
    def self.add_words(words, text)
      text.split(" ").each do |word|
        next if word.empty?

        seen = false
        words.each { |w| seen = true if w == word }
        words << word unless seen
      end
      nil
    end

    # The DOM id Rails' dom_id gives a record: "article_12", "new_article"
    # for an unsaved one, "edit_article_12" with a prefix. The record answers
    # model_name, id and new_record? (a Cybertrain::Model does).
    # @param prefix [String] "" for none
    # @return [String]
    # @api public
    def self.dom_id(record, prefix = "")
      key = Inflector.underscore(record.model_name).tr("/", "_")
      if record.new_record?
        return prefix.empty? ? "new_#{key}" : "#{prefix}_#{key}"
      end

      prefix.empty? ? "#{key}_#{record.id}" : "#{prefix}_#{key}_#{record.id}"
    end

    # What `tag` evaluates to in a template: `tag.div(...)` is a method call
    # on it, which Template::Helpers#call_object_method turns into
    # Html.build_tag("div", ...). It has no state; TAG_BUILDER is the one
    # instance. `<%= tag %>` alone prints nothing.
    # @api public
    class TagBuilder
      def to_s = ""
    end

    # @api public
    TAG_BUILDER = TagBuilder.new
  end
end
