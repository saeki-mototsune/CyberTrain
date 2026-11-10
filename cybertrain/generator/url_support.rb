require "cybertrain/router"

# Runtime support for the URL helpers in a generated gen/routes.rb (which
# requires this file). It is not part of the generator program itself.

module Cybertrain
  @url_root = "http://localhost:3000"

  # Scheme and host the *_url helpers prepend: Cybertrain.url_root = "https://example.com".
  # It is not derived from the request or from {Config}; set it in
  # `config/app.rb`, e.g.
  # `Cybertrain.url_root = "https://example.com" if Cybertrain.config.production?`.
  # @return [String] `"http://localhost:3000"` until set
  # @api public
  def self.url_root
    @url_root
  end

  # @param root [String] scheme and host, no trailing slash
  # @return [String]
  # @api public
  def self.url_root=(root)
    @url_root = root
  end

  module Gen
    # A URL helper argument as a String: Integer ids, String slugs, and
    # models (anything else answers #to_param).
    def self.param(value)
      case value
      when nil then raise ArgumentError, "missing route parameter"
      when Integer then value.to_s
      when String then value
      else value.to_param
      end
    end

    # param(value), percent-encoded for use as one path segment.
    def self.segment(value)
      Router.escape_segment(param(value))
    end

    # A helper's path with its options (spec 2.6, plan decision 14):
    # `format:` appended as an extension, every other key a query
    # parameter in the order given, then `anchor:` as the fragment.
    #
    #   with_options("/posts/3", { page: 2, format: :json, anchor: "c" })
    #   # => "/posts/3.json?page=2#c"
    #
    # Keys are Symbols (a helper called from Ruby) or Strings (a template's
    # keywords, through Gen::Routes.path_for). Values are to_s'd and
    # escaped; nil leaves the key out, an Array gives `key[]=v` per element,
    # and a Hash raises ArgumentError.
    def self.with_options(path, options)
      return path if options.empty?

      format = ""
      anchor = ""
      has_anchor = false
      # Each pair is "&"-led; the first "&" is dropped below.
      query = +""
      keys = options.keys
      i = 0
      while i < keys.size
        name = keys[i].to_s
        value = options[keys[i]]
        if name == "format"
          format = value.to_s unless value.nil?
        elsif name == "anchor"
          unless value.nil?
            anchor = value.to_s
            has_anchor = true
          end
        else
          query << query_pairs(name, value)
        end
        i += 1
      end
      out = +""
      out << path
      out << "." << Router.escape_segment(format) unless format.empty?
      out << "?" << query[1, query.size - 1].to_s unless query.empty?
      out << "#" << Router.escape_segment(anchor) if has_anchor
      out
    end

    # One query option as "&"-led `name=value` pairs ("" for nil).
    def self.query_pairs(name, value)
      key = URI.encode_www_form_component(name)
      case value
      when nil then ""
      when Time then "&#{key}=#{URI.encode_www_form_component(value.to_s)}"
      when Hash
        hash_option!(name)
        ""
      when Array
        out = +""
        j = 0
        while j < value.size
          item = value[j]
          case item
          when Hash then hash_option!(name)
          else out << "&#{key}%5B%5D=#{URI.encode_www_form_component(item.to_s)}"
          end
          j += 1
        end
        out
      else "&#{key}=#{URI.encode_www_form_component(value.to_s)}"
      end
    end

    # Plan decision 14: a Hash value has no query form here.
    def self.hash_option!(name)
      msg = "path helper option :#{name} must be a String, Symbol, number, boolean or Array (got Hash)"
      raise ArgumentError, msg
    end
  end
end
