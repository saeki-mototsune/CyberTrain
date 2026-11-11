module Cybertrain
  # A Content Security Policy (spec section 5, C-5), declared in
  # `config/app.rb` and, per controller, with `content_security_policy do
  # |p| ... end`. One method per directive, each taking its sources:
  #
  #   c.content_security_policy do |p|
  #     p.default_src :self
  #     p.script_src :self, "https://cdn.jsdelivr.net"
  #     p.img_src :self, :data
  #   end
  #
  # Symbols are the keywords: `:self`, `:none`, `:unsafe_inline`,
  # `:unsafe_eval`, `:strict_dynamic` and `:report_sample` become
  # `'self'` and so on, `:data`, `:https`, `:blob`, `:ws` and `:wss` the
  # schemes `data:` and so on. A String is written as given; one holding a
  # space, `;`, `,`, a control character or a non-ASCII byte is refused
  # with ArgumentError, so nothing in a source can end its directive or the
  # header. A directive declared again replaces its sources in place; one
  # declared with no sources is removed. The header lists the directives in
  # declaration order ({#header_value}); {ContentSecurityPolicyHeader}
  # writes it on every response.
  # @api public
  class ContentSecurityPolicy
    # The directive names, as the header spells them.
    DIRECTIVES = %w[default-src script-src style-src img-src font-src connect-src media-src object-src
                    frame-src frame-ancestors child-src worker-src manifest-src base-uri form-action
                    report-uri].freeze

    # Whether a controller declared a policy of its own
    # (Controller.content_security_policy): kept here, not on Controller,
    # so Application#build_stack can ask without requiring the controller.
    @controller_policies = false

    # @return [Boolean]
    # @api private
    def self.controller_policies?
      @controller_policies
    end

    # Set by Controller.content_security_policy.
    # @return [nil]
    # @api private
    def self.controller_policy_declared!
      @controller_policies = true
      nil
    end

    def initialize
      # Parallel lists in declaration order; typed seeds (NOTES rule 9).
      @names = Array.new(0) { "" }
      @values = Array.new(0) { "" }
    end

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def default_src(*sources) = put_directive("default-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def script_src(*sources) = put_directive("script-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def style_src(*sources) = put_directive("style-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def img_src(*sources) = put_directive("img-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def font_src(*sources) = put_directive("font-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def connect_src(*sources) = put_directive("connect-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def media_src(*sources) = put_directive("media-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def object_src(*sources) = put_directive("object-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def frame_src(*sources) = put_directive("frame-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def frame_ancestors(*sources) = put_directive("frame-ancestors", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def child_src(*sources) = put_directive("child-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def worker_src(*sources) = put_directive("worker-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def manifest_src(*sources) = put_directive("manifest-src", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def base_uri(*sources) = put_directive("base-uri", sources)

    # @param sources [Array<Symbol, String>]
    # @return [nil]
    # @api public
    def form_action(*sources) = put_directive("form-action", sources)

    # @param sources [Array<Symbol, String>] the report endpoint's URL
    # @return [nil]
    # @api public
    def report_uri(*sources) = put_directive("report-uri", sources)

    # The header's value: the directives in declaration order joined by
    # `"; "`, with `'nonce-<nonce>'` after the sources of each directive
    # named in `nonce_directives` (when `nonce` is not ""). "" for a policy
    # with no directive.
    # @example
    #   policy.header_value("abc", ["script-src"])
    #   # => "default-src 'self'; script-src 'self' 'nonce-abc'"
    # @param nonce [String] Base64, from {Context#csp_nonce}
    # @param nonce_directives [Array<String>] e.g. `["script-src", "style-src"]`
    # @return [String]
    # @api public
    def header_value(nonce, nonce_directives)
      out = +""
      names = @names
      i = 0
      while i < names.size
        name = names[i]
        out << "; " unless out.empty?
        out << name << " " << @values[i]
        out << " 'nonce-" << nonce << "'" if !nonce.empty? && nonce_directives.include?(name)
        i += 1
      end
      out
    end

    # A copy to change without touching this one (a controller's policy
    # starts as a copy of the application's).
    # @return [ContentSecurityPolicy]
    # @api public
    def dup_policy
      copy = ContentSecurityPolicy.new
      i = 0
      while i < @names.size
        copy.append_directive(@names[i], @values[i])
        i += 1
      end
      copy
    end

    # Adds a directive with its sources already written out (dup_policy).
    # @api private
    def append_directive(name, value)
      @names << name
      @values << value
      nil
    end

    # Sets, replaces (in place) or, with no sources, removes a directive.
    # @api private
    def put_directive(name, sources)
      value = ContentSecurityPolicy.sources_text(name, sources)
      at = @names.index(name)
      if at.nil?
        append_directive(name, value) unless value.empty?
      elsif value.empty?
        @names.delete_at(at)
        @values.delete_at(at)
      else
        @values[at] = value
      end
      nil
    end

    # The sources joined by spaces.
    def self.sources_text(name, sources)
      out = +""
      sources.each do |source|
        word = ContentSecurityPolicy.source_word(name, source)
        out << " " unless out.empty?
        out << word
      end
      out
    end

    # One source as the header writes it.
    def self.source_word(name, source)
      case source
      when Symbol
        word = ContentSecurityPolicy.keyword_text(source)
        if word.empty?
          msg = "content_security_policy #{name}: unknown source :#{source}"
          raise ArgumentError, msg
        end
        return word
      when String
        text = source.to_s
        unless ContentSecurityPolicy.source_text?(text)
          msg = "content_security_policy #{name}: #{text.inspect} is not a source (no spaces, ';', ',' or control characters)"
          raise ArgumentError, msg
        end
        return text
      end
      msg = "content_security_policy #{name}: a source is a Symbol or a String"
      raise ArgumentError, msg
    end

    # "" for a Symbol that is not a keyword.
    def self.keyword_text(sym)
      case sym
      when :self then "'self'"
      when :none then "'none'"
      when :unsafe_inline then "'unsafe-inline'"
      when :unsafe_eval then "'unsafe-eval'"
      when :strict_dynamic then "'strict-dynamic'"
      when :report_sample then "'report-sample'"
      when :data then "data:"
      when :https then "https:"
      when :blob then "blob:"
      when :ws then "ws:"
      when :wss then "wss:"
      else ""
      end
    end

    # Printable ASCII other than space, `;` and `,`: nothing that could end
    # the source, the directive or the header line. Reads its parameter
    # through a fresh local (NOTES rule 62).
    def self.source_text?(text)
      s = text.to_s
      n = s.bytesize
      return false if n == 0

      i = 0
      while i < n
        b = s.getbyte(i)
        return false if b <= 0x20 || b >= 0x7f || b == 0x3b || b == 0x2c

        i += 1
      end
      true
    end

    # Whether `name` is a directive this class writes (`"script-src"`).
    def self.directive?(name)
      DIRECTIVES.include?(name)
    end
  end
end
