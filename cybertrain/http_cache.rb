# Cybertrain::HttpCache -- what a response tells a cache, and whether the
# client's copy is still good: the validators (ETag, Last-Modified), the
# Cache-Control beside them, the freshness decision of a conditional GET
# (RFC 9110 section 13) and `Vary: Accept`.
#
# Controller is the facade (`fresh_when`, `stale?`, `expires_in`, and the
# Vary it adds after every action); it hands its request and response here
# and answers the 304 itself. Nothing in this file names a controller, a
# callback or a template (docs/design.md D70).
#
# Module functions over a Request and a Response, with names of this
# module's own (spikes/NOTES.md rules 10, 34, 41).
require "digest"
require "cybertrain/assets"
require "cybertrain/http/request"
require "cybertrain/generator/inflector"

module Cybertrain
  # @api private
  module HttpCache
    # Sets the ETag, Last-Modified and (unless one is already set, by
    # {.lifetime}) Cache-Control headers of fresh_when and stale?.
    # @param request [Request]
    # @param response [Response]
    # @param etag [String, Model, nil]
    # @param last_modified [Time, nil]
    # @param public [Boolean] let shared caches store it
    # @param html_fallback [Boolean] whether the request, of another format,
    #   is also answered in HTML when the action has nothing for its own
    #   (Rendering.accepts_html?, which the caller asks: this file names
    #   no template)
    # @return [nil]
    # @raise [ArgumentError] for an `etag` that is neither a String nor a record
    def self.set_validators(request, response, etag, last_modified, public, html_fallback)
      key = etag_key(etag)
      unless key.empty?
        # The representation and the build digest too (see
        # Controller#fresh_when): "\0" never occurs in a format or a hex
        # digest, so the parts cannot run together.
        keyed = "#{key}\0#{representation(request.format, html_fallback)}\0#{Assets.build_digest}"
        response.set_header("ETag", "W/\"#{Digest::SHA256.hexdigest(keyed).byteslice(0, 32)}\"")
      end
      stamp = modified_stamp(last_modified)
      response.set_header("Last-Modified", Request.http_date(Time.at(stamp).utc)) if stamp >= 0
      if response.header("Cache-Control").nil?
        response.set_header("Cache-Control", public ? "max-age=0, public, must-revalidate" : "max-age=0, private, must-revalidate")
      end
      nil
    end

    # Whether the request's validators say the client's copy of the
    # response (its ETag and Last-Modified, set by {.set_validators}) is
    # current: RFC 9110 section 13.1.2 and 13.1.3 for GET and HEAD: a
    # non-empty If-None-Match decides alone and If-Modified-Since is
    # ignored; without one, a parseable If-Modified-Since decides. An
    # If-None-Match that lists `*` matches whatever the response is, with
    # or without an ETag (a response validated by date only has none);
    # any other entry needs the response's ETag to match.
    # @param request [Request]
    # @param response [Response]
    # @return [Boolean]
    def self.validators_fresh?(request, response)
      return false unless request.get? || request.head?

      since = Request.parse_http_date(request.header("If-Modified-Since").to_s)
      none_match = request.header("If-None-Match").to_s
      unless none_match.empty?
        return true if any_listed?(none_match)

        return etag_listed?(none_match, response.header("ETag").to_s)
      end
      return false if since < 0

      stamp = Request.parse_http_date(response.header("Last-Modified").to_s)
      stamp >= 0 && stamp <= since
    end

    # `Cache-Control: max-age=<seconds>, private` (`public` when asked).
    # @param response [Response]
    # @param seconds [Integer]
    # @param public [Boolean]
    # @return [nil]
    def self.lifetime(response, seconds, public)
      response.set_header("Cache-Control", "max-age=#{seconds.to_i}, #{public ? "public" : "private"}")
      nil
    end

    # `Vary: Accept` on a response whose format came from the Accept header
    # (the path has no extension, and the request sent one): one URL answers
    # HTML, JSON or a Turbo Stream by Accept, so a cache must key on it, or
    # a browser hands a cached HTML page to a later fetch for JSON (Rails'
    # should_apply_vary_header?). Added to a Vary the action set, unless
    # that already lists Accept or is `*`.
    # @param request [Request]
    # @param response [Response]
    # @return [nil]
    def self.add_vary_accept(request, response)
      return nil unless request.format_extension.empty?
      return nil if request.header("Accept").to_s.empty?

      vary = response.header("Vary").to_s
      if vary.strip.empty?
        response.set_header("Vary", "Accept")
      elsif !vary_lists_accept?(vary)
        response.set_header("Vary", "#{vary}, Accept")
      end
      nil
    end

    # Whether a Vary value already covers Accept (lists it, in any case,
    # or is `*`).
    # @param vary [String]
    # @return [Boolean]
    def self.vary_lists_accept?(vary)
      vary.split(",").each do |item|
        name = item.strip.downcase
        return true if name == "accept" || name == "*"
      end
      false
    end

    # What a request's ETag is keyed on beside the key: its format, and
    # "+html" when the answer may be the HTML one instead (the format came
    # from an Accept that also offers HTML). Which of the two the action
    # sends is not known when fresh_when runs, so the two kinds of request
    # get validators of their own: "json+html" may be answered with a
    # page, "json" never is, and an ETag of the first must not turn the
    # second's 406 into a 304. "+" occurs in no format's name.
    # @param format [Symbol]
    # @param html_fallback [Boolean]
    # @return [String]
    def self.representation(format, html_fallback)
      html_fallback ? "#{format}+html" : "#{format}"
    end

    # The text an ETag is made from: a String as given, a record as
    # "posts/1-<updated_at epoch>", "" for nil; anything else is an
    # ArgumentError.
    def self.etag_key(value)
      case value
      when String then value.to_s
      when nil then ""
      when Model
        name = Inflector.pluralize(Inflector.underscore(value.model_name))
        at = Cast.time_or_nil(value.read_attribute(:updated_at))
        at.nil? ? "#{name}/#{value.to_param}" : "#{name}/#{value.to_param}-#{at.to_i}"
      else
        message = "etag: must be a String or a record, got #{value.class}"
        raise ArgumentError, message
      end
    end

    # A Last-Modified value as epoch seconds, -1 for none. `when Time`
    # first (NOTES rule 8).
    def self.modified_stamp(value)
      case value
      when Time then value.to_i
      else -1
      end
    end

    # Whether the If-None-Match list is, or has an entry, `*`.
    def self.any_listed?(list)
      list.split(",").each do |item|
        return true if item.strip == "*"
      end
      false
    end

    # Whether the If-None-Match list names `tag` (weak comparison: a W/
    # prefix is ignored). `*` is {.any_listed?}'s.
    def self.etag_listed?(list, tag)
      return false if tag.empty?

      want = strip_weak(tag)
      list.split(",").each do |item|
        return true if strip_weak(item.strip) == want
      end
      false
    end

    def self.strip_weak(tag)
      tag.start_with?("W/") ? tag.byteslice(2, tag.bytesize - 2).to_s : tag
    end
  end
end
