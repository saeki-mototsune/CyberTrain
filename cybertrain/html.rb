# Cybertrain::Html -- escaping helpers and Cybertrain::SafeString, the marker
# type views use to say "this string is already safe to drop into HTML".
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
      # below a dynamic call: most of this method's time. The interpolated
      # copy has one static type, so the loops compile to plain C. value
      # itself is what comes back when nothing needs escaping: returning the
      # parameter keeps Spinel from narrowing it to whatever one caller
      # passes (it once inferred an Integer and turned Strings into "0").
      str = "#{value}"
      n = str.bytesize
      i = 0
      # Most values need nothing: find the first byte that does before
      # allocating a buffer at all.
      while i < n
        b = str.getbyte(i)
        break if b == 38 || b == 60 || b == 62 || b == 34 || b == 39
        i += 1
      end
      return value if i == n

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
      SafeString.new(str)
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
  # `String#html_safe` in Ruby code: use {Html.safe} or `SafeString.new`.
  # @api public
  class SafeString
    # @param str [String] trusted HTML
    # @api public
    def initialize(str)
      @str = str
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
              else Html.escape(other)
              end
      SafeString.new(@str + piece)
    end
  end
end
