require "cybertrain/router"

# Runtime support for the URL helpers in a generated gen/routes.rb (which
# requires this file). It is not part of the generator program itself.
module Cybertrain
  @url_root = "http://localhost:3000"

  # Scheme and host the *_url helpers prepend: Cybertrain.url_root = "https://example.com".
  def self.url_root
    @url_root
  end

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
  end
end
