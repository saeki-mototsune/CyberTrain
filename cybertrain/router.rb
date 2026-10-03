require "uri"
require "cybertrain/middleware"
require "cybertrain/http/query"

module Cybertrain
  # One routing table entry: "GET /posts/:id/edit" plus a name for path
  # helpers and the handler the Router calls with the Context.
  class Route
    attr_reader :verb, :pattern, :segments, :name, :handler

    def initialize(verb, pattern, name, handler)
      @verb = verb.upcase
      @pattern = pattern
      @segments = pattern.split("/").reject(&:empty?)
      @name = name
      @handler = handler
    end

    # The captured ":name" segments when verb and path match, nil otherwise.
    # A HEAD request is answered by the GET route (the Server drops the body).
    def match(verb, path_segments)
      return nil unless verb == @verb || (verb == "HEAD" && @verb == "GET")
      return nil unless path_segments.size == @segments.size

      captured = {}
      @segments.each_with_index do |seg, i|
        if seg.start_with?(":")
          captured[seg[1..-1].to_s] = path_segments[i]
        elsif seg != path_segments[i]
          return nil
        end
      end
      captured
    end

    # Fills the ":name" segments from params: path({ "id" => "1" }) -> "/posts/1/edit".
    def path(params)
      return "/" if @segments.empty?

      out = +""
      @segments.each do |seg|
        out << "/"
        if seg.start_with?(":")
          key = seg[1..-1].to_s
          value = params[key]
          raise ArgumentError, "missing :#{key} for route #{@pattern}" if value.nil? || value.empty?

          out << Router.escape_segment(value)
        else
          out << seg
        end
      end
      out
    end
  end

  # The end of the middleware chain: finds the first route matching the
  # request, fills ctx.params / route_params / route_name and runs the
  # route's handler. Unmatched requests get a plain-text 404.
  class Router < Middleware
    def initialize
      super(nil)
      @routes = []
    end

    def routes
      @routes
    end

    def add(verb, pattern, name = "", &handler)
      route = Route.new(verb, pattern, name, handler)
      @routes << route
      route
    end

    def get(pattern, name = "", &handler)
      add("GET", pattern, name, &handler)
    end

    def post(pattern, name = "", &handler)
      add("POST", pattern, name, &handler)
    end

    def patch(pattern, name = "", &handler)
      add("PATCH", pattern, name, &handler)
    end

    def put(pattern, name = "", &handler)
      add("PUT", pattern, name, &handler)
    end

    def delete(pattern, name = "", &handler)
      add("DELETE", pattern, name, &handler)
    end

    def path_for(name, params = {})
      @routes.each do |route|
        return route.path(params) if route.name == name
      end
      nil
    end

    def call(ctx)
      request = ctx.request
      segments = Router.split_path(request.path)
      @routes.each do |route|
        captured = route.match(request.method, segments)
        next if captured.nil?

        ctx.route_params = captured
        ctx.route_name = route.name
        ctx.params = assemble_params(request, captured)
        route.handler.call(ctx)
        return nil
      end
      not_found(ctx.response)
      nil
    end

    # "/posts/1/" -> ["posts", "1"]; each segment is percent-decoded, but a
    # "+" stays a plus (it only means space in query strings and forms).
    # A segment with a malformed escape ("%ZZ", a trailing "%" or "%2") is
    # kept literal: CRuby's decoder raises ArgumentError on it while Spinel's
    # silently yields a NUL byte, so neither runtime ever sees it
    # (Query.valid_escapes? is the check Query.decode makes too). The decoding
    # is Query.decode_escapes, the byte-chunked loop of query strings with "+"
    # left alone: URI.decode_www_form_component on a whole segment is
    # quadratic on non-ASCII text under Spinel (NOTES rule 49), and Static
    # calls split_path before routing on every request, anonymous ones
    # included, so a ~60 KB segment (inside the 64 KB head limit) holding one
    # non-ASCII byte and one "%41" cost ~0.5 s of CPU per request. The same
    # call replaces the old `gsub("+", "%2B")` pass over the segment.
    def self.split_path(path)
      segments = []
      path.split("/").each do |seg|
        next if seg.empty?

        if !seg.byteindex("%").nil? && Query.valid_escapes?(seg)
          segments << Query.decode_escapes(seg, false)
        else
          segments << seg
        end
      end
      segments
    end

    # Percent-encodes a value for use as one path segment ("a b" -> "a%20b").
    def self.escape_segment(value)
      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    private

    # Later sources win: query string, then the form body, then the route.
    # The Router is the LAST consumer of the Request's parse caches
    # (MethodOverride and CsrfProtection run before it and only read one key
    # each), so it TAKES the cached query tree (Request#take_query_params)
    # as the request's params instead of copying both trees (a copy is a
    # second full tree build per request: up to 4096 pairs x 32 levels). The
    # take clears the cache, so ctx.params is the only holder of that
    # object: the form tree is merged into it (merge! reads the form tree
    # and does not change it) and the route captures set on top, and a later
    # request.query_params is a fresh, pristine parse that never carries the
    # form, `_method`, `authenticity_token` or the captures.
    def assemble_params(request, captured)
      params = request.take_query_params
      params.merge!(request.form_params) if request.form?
      # NOTE(Spinel): not `captured.each { |k, v| ... }` -- captured comes from
      # the nullable Route#match, and with a user-defined #to_s in the program
      # (SafeString) the pair's key reaches Params#set_value as a boxed value
      # and the C build fails. Iterating the keys keeps them typed String.
      captured.each_key { |k| params.set_value(k, captured[k].to_s) }
      params
    end

    def not_found(response)
      response.status = 404
      response.content_type = "text/plain; charset=utf-8"
      response.body = "Not Found"
    end
  end
end
