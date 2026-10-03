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
      segments = request.path_segments
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

    # "/posts/1/" -> ["posts", "1"], percent-decoded. The implementation
    # (and the 400 policy for invalid bytes) lives in Request.split_path,
    # which Request#path_segments caches; it cannot live here because Router
    # requires Request (through Middleware and Context), so the other way
    # round would be a require cycle. The Router itself reads
    # request.path_segments.
    def self.split_path(path)
      Request.split_path(path)
    end

    # Percent-encodes a value for use as one path segment ("a b" -> "a%20b").
    def self.escape_segment(value)
      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    private

    # Later sources win: query string, then the form body, then the route.
    # ctx.params is the request's OWN tree: a fresh Params that the query
    # tree, the form tree (when the body is a form) and the route captures
    # are merged into, in that order. merge! reads its argument and copies
    # every list and nested Params it takes over, so neither of the
    # Request's parse caches is ever mutated, and anyone who kept
    # request.query_params or request.form_params (a middleware rebuilding a
    # canonical URL after `super`) still sees the query keys or the form
    # fields alone, never `_method`, `authenticity_token` or the captures.
    # Both caches are marked Params#read_only! by the Request (an O(1) flag
    # on the tree, no walk; every mutator on them raises), so this is not a
    # defensive copy that a convention has to protect: it is the merge of
    # three sources into the one tree the controller may write to, and merge!
    # copies from a read-only source into a fresh writable one. Parsing
    # straight into ctx.params instead would parse the body a second time
    # (the middleware chain has already parsed the query and form into the
    # caches, for MethodOverride and CsrfProtection) and decode every pair
    # again; the copy decodes nothing, it only allocates the nodes. One tree
    # build per request, bounded by the Query limits (at most MAX_PAIRS pairs
    # of MAX_DEPTH levels).
    def assemble_params(request, captured)
      params = Params.new
      params.merge!(request.query_params)
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
