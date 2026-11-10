require "uri"
require "cybertrain/middleware"
require "cybertrain/http/query"
require "cybertrain/http/multipart"

module Cybertrain
  # One routing table entry: "GET /posts/:id/edit" plus a name for path
  # helpers and the handler the Router calls with the Context.
  class Route
    # The longest extension the router splits off a last segment.
    MAX_EXTENSION_BYTES = 20

    attr_reader :verb, :pattern, :segments, :name, :handler
    # Whether the route matches an optional extension on its last segment
    # (`/posts/3.json`), true unless drawn with `format: false`.
    attr_reader :takes_format

    def initialize(verb, pattern, name, handler, takes_format = true)
      @verb = verb.upcase
      @pattern = pattern
      @segments = pattern.split("/").reject(&:empty?)
      @name = name
      @handler = handler
      @takes_format = takes_format
    end

    # The captured ":name" segments when verb and path match, nil otherwise.
    # A HEAD request is answered by the GET route (the Server drops the body).
    #
    # A route that takes a format also matches its last segment with an
    # extension split off at the last "." (Route.extension_at): a literal
    # segment matches the whole segment first (`/robots.txt`), then the
    # part before the extension (`/posts.json`); a dynamic one captures the
    # part before it (`3` of `3.json`). A dynamic segment of such a route
    # never captures a "." (Rails' `[^/.?]+`): `/posts/3.json.bak` and
    # `/posts/.json` do not match `/posts/:id`.
    def match(verb, path_segments)
      return nil unless verb == @verb || (verb == "HEAD" && @verb == "GET")
      return nil unless path_segments.size == @segments.size

      last = @segments.size - 1
      captured = {}
      @segments.each_with_index do |seg, i|
        given = path_segments[i]
        dynamic = seg.start_with?(":")
        if @takes_format && i == last
          dot = Route.extension_at(given)
          head = dot < 0 ? given : given[0, dot].to_s
          if dynamic
            return nil unless head.index(".").nil?

            captured[seg[1..-1].to_s] = head
          elsif seg != given && seg != head
            return nil
          end
        elsif dynamic
          return nil if @takes_format && !given.index(".").nil?

          captured[seg[1..-1].to_s] = given
        elsif seg != given
          return nil
        end
      end
      captured
    end

    # The extension the last of path_segments carries for this route ("json"
    # for `/posts/3.json`), "" for none or for a route drawn with `format:
    # false`. A function of the segments, not state left by #match: a
    # Route is shared by every request thread.
    def matched_extension(path_segments)
      return "" unless @takes_format && !path_segments.empty?

      given = path_segments[path_segments.size - 1]
      dot = Route.extension_at(given)
      return "" if dot < 0

      given[dot + 1, given.size - dot - 1].to_s
    end

    # The index of the "." that starts segment's extension, -1 for none: the
    # last ".", with a non-empty part before it and 1 to
    # MAX_EXTENSION_BYTES of [A-Za-z0-9_] after it.
    def self.extension_at(segment)
      s = segment.to_s # a fresh String for the byte reads (NOTES rule 62)
      dot = s.rindex(".")
      return -1 if dot.nil? || dot == 0

      size = s.bytesize - dot - 1
      return -1 if size < 1 || size > MAX_EXTENSION_BYTES

      i = dot + 1
      while i < s.bytesize
        b = s.getbyte(i)
        word = (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95
        return -1 unless word

        i += 1
      end
      dot
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

    # takes_format false: the route matches no extension, so a dot in the
    # last segment is part of it (`format: false` in config/routes.rb).
    def add(verb, pattern, name = "", takes_format = true, &handler)
      route = Route.new(verb, pattern, name, handler, takes_format)
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
        request.format_extension = route.matched_extension(segments)
        ctx.params = assemble_params(request, captured)
        route.handler.call(ctx)
        return nil
      end
      not_found(ctx.response)
      nil
    end

    # The handler of a redirect route (`get "/old", to: redirect("/new")`):
    # answers `status` with `Location: target`, each `%{name}` in target
    # replaced by the route's `:name` segment, escaped (Router.escape_segment),
    # and an empty body. A `%{name}` the route lacks becomes "" (gen refuses
    # one when it draws the route).
    # @param ctx [Context]
    # @param target [String] `"/posts/%{id}"`
    # @param status [Integer] 301, 302, ... 308
    # @return [nil]
    def self.redirect_to(ctx, target, status)
      text = target.to_s # a fresh String for the byte reads (NOTES rule 62)
      captured = ctx.route_params
      out = +""
      i = 0
      while i < text.size
        open = text.index("%{", i)
        close = open.nil? ? nil : text.index("}", open + 2)
        if open.nil? || close.nil?
          out << text[i, text.size - i].to_s
          break
        end
        out << text[i, open - i].to_s
        key = text[open + 2, close - open - 2].to_s
        value = captured[key]
        out << Router.escape_segment(value.to_s) unless value.nil?
        i = close + 1
      end
      response = ctx.response
      response.redirect(out, status)
      response.body = ""
      nil
    end

    # Percent-encodes a value for use as one path segment ("a b" -> "a%20b").
    def self.escape_segment(value)
      text = value.to_s # a String for Query.plain?'s byte reads (see Html.escape)
      return text if Query.plain?(text)

      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    private

    # Later sources win: query string, then the form or multipart body, then
    # the route.
    # ctx.params is the request's OWN tree, built right here by parsing the
    # query string and then (for a form) the body straight into one fresh
    # Params (Query.parse_valid, on the Request's validated texts: a form POST
    # whose body MethodOverride already read is not validated again; a
    # multipart body is filled from the one parse the Request cached,
    # Multipart.fill: text fields like urlencoded ones, files into the
    # Params upload slot), then the route captures. There are no cached trees
    # to alias: the parsed Strings come fresh out of the decoder, and a capture is the very String
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
      Multipart.fill(params, request.multipart_form) if request.multipart?
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
