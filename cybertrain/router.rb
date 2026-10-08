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

    # Percent-encodes a value for use as one path segment ("a b" -> "a%20b").
    def self.escape_segment(value)
      text = "#{value}" # a String for plain_segment?'s byte reads (see Html.escape)
      return text if Router.plain_segment?(text)

      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    # True when encode_www_form_component would return value unchanged: only
    # the bytes it leaves alone (ASCII letters and digits, `*`, `-`, `.`,
    # `_`). Ids and most slugs are, and skip the encoder and the gsub.
    def self.plain_segment?(value)
      i = 0
      n = value.bytesize
      while i < n
        b = value.getbyte(i)
        unless (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 42 || b == 45 || b == 46 || b == 95
          return false
        end
        i += 1
      end
      true
    end

    private

    # Later sources win: query string, then the form body, then the route.
    # ctx.params is the request's OWN tree, built right here by parsing the
    # query string and then (for a form) the body straight into one fresh
    # Params (Query.parse_valid, on the Request's validated texts: a form POST
    # whose body MethodOverride already read is not validated again), then
    # the route captures. There are no cached trees to alias: the parsed
    # Strings come fresh out of the decoder, and a capture is the very String
    # the cached path_segments holds (shared with Static), so it is dup'd:
    # `params[:id].upcase!` in an action must not change the segment Array
    # that Static or a later middleware reads. One tree build per request, no
    # node-by-node copy: copying a parsed tree into a fresh one cost more than
    # the parse at the Query limits (648 ms against 546 ms for MAX_PAIRS pairs
    # of MAX_DEPTH levels). The Query limits (QueryTooMany, QueryTooDeep)
    # apply per parse call: one for the query string, one for the form body.
    def assemble_params(request, captured)
      params = Params.new
      Query.parse_valid(params, request.utf8_query_string)
      Query.parse_valid(params, request.utf8_body) if request.form?
      # NOTE(Spinel): not `captured.each { |k, v| ... }` -- captured comes from
      # the nullable Route#match, and with a user-defined #to_s in the program
      # (SafeString) the pair's key reaches Params#set_value as a boxed value
      # and the C build fails. Iterating the keys keeps them typed String.
      captured.each_key { |k| params.set_value(k, captured[k].to_s.dup) }
      params
    end

    def not_found(response)
      response.status = 404
      response.content_type = "text/plain; charset=utf-8"
      response.body = "Not Found"
    end
  end
end
