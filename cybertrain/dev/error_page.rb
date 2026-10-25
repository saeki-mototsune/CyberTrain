require "cybertrain/middleware"
require "cybertrain/html"
require "cybertrain/logger"
require "json"
require "cybertrain/dev/rebuilder"
require "cybertrain/http/client_error"
require "cybertrain/http/response"
require "cybertrain/http/parameter_filter"
require "cybertrain/cast"

module Cybertrain
  module Dev
    # Development-only diagnostics, outermost in the stack. An exception
    # from the app becomes a 500 page naming its class, message, the request
    # line and, for template errors ("posts/show.html.erb:12: ..."), the
    # template and line, and the request's parameters (the params tree the
    # Router built, and a JSON body), with the values of filtered names
    # (Config#filter_parameters) shown as "[FILTERED]". While the last
    # rebuild failed, every HTML response also carries a banner with the
    # compiler output.
    class ErrorPage < Middleware
      BANNER_ID = "cybertrain-build-failed"

      # Nesting a JSON body is dumped to; deeper levels show as "...". A
      # parsed document can be 200 levels deep and thread stacks are small
      # (spikes/NOTES.md rule 46).
      MAX_DUMP_DEPTH = 32

      # The largest JSON body the page parses for its dump, 1 MiB.
      MAX_DUMP_BODY_BYTES = 1_048_576

      def initialize(app, rebuilder = nil)
        super(app)
        @rebuilder = rebuilder
      end

      def call(ctx)
        begin
          nxt = @app
          nxt.call(ctx) unless nxt.nil?
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          # NOTES rule 33: JSON::ParserError is not a StandardError under
          # Spinel, and a bad JSON body deserves the diagnostics page too. A
          # client fault (ClientError: parameters past Query's limits) gets a
          # plain 4xx naming the limit instead, as ErrorPages does.
          status = ClientError.classify(e, Cybertrain.logger)
          if status >= 500
            render_exception(ctx, e)
          else
            ctx.response.reset_to(status, "#{Response.status_text(status)}: #{e.message}")
          end
        end
        inject_banner(ctx.response)
        nil
      end

      # "posts/show.html.erb:12" from "posts/show.html.erb:12: message", or
      # "" when the message does not start with a template location: the
      # text before the first ".erb:<digits>:" must be a bare template name
      # (no space, no colon), so "undefined thing in x.html.erb:3: ..." is
      # not taken for one.
      def self.template_location(message)
        marker = message.index(".erb:")
        return "" if marker.nil?
        return "" unless message[0, marker].index(" ").nil? && message[0, marker].index(":").nil?

        i = marker + 5
        digits_start = i
        i += 1 while i < message.size && message[i] >= "0" && message[i] <= "9"
        return "" if i == digits_start || message[i] != ":"

        message[0, i]
      end

      private

      # Response#reset_to drops the failed action's headers and cookies; the
      # diagnostics page then replaces the plain-text body.
      def render_exception(ctx, error)
        response = ctx.response
        response.reset_to(500)
        response.content_type = "text/html; charset=utf-8"
        response.body = error_html(ctx, error.class.name, error.message)
        nil
      end

      def error_html(ctx, class_name, message)
        request = ctx.request
        target = request.query_string.empty? ? request.path : "#{request.path}?#{ParameterFilter.filter_query(request.query_string)}"
        html = +"<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
        html << "<title>" << Html.escape(class_name) << "</title>\n"
        html << "<style>body { font-family: sans-serif; margin: 0; } main { padding: 1rem 2rem; } " \
                "h1 { color: #b91c1c; } pre { background: #f4f4f5; padding: 1rem; white-space: pre-wrap; }</style>\n"
        html << "</head>\n<body>\n<main>\n"
        html << "<h1>" << Html.escape(class_name) << "</h1>\n"
        html << "<pre class=\"message\">" << Html.escape(message) << "</pre>\n"
        html << "<p class=\"request\">" << Html.escape("#{request.method} #{target} #{request.http_version}") << "</p>\n"
        location = ErrorPage.template_location(message)
        unless location.empty?
          colon = location.rindex(":").to_i
          name = location[0, colon]
          line = location[colon + 1, location.size - colon - 1]
          html << "<p class=\"template\">Template: " << Html.escape(name) << ", line " << line << "</p>\n"
        end
        html << "<pre class=\"params\">Parameters: " << Html.escape(ctx.params.filtered_inspect) << "</pre>\n"
        json = ErrorPage.json_dump(request)
        html << "<pre class=\"json\">JSON body: " << Html.escape(json) << "</pre>\n" unless json.empty?
        html << "</main>\n</body>\n</html>\n"
        html
      end

      # The request's JSON body, parsed and dumped with filtered values
      # replaced, or "" when it is not a JSON request, is encoded, larger
      # than MAX_DUMP_BODY_BYTES, or does not parse (it may be what failed).
      # The rescue sits in this non-yielding method (spikes/NOTES.md rules
      # 32 and 61).
      def self.json_dump(request)
        return "" unless request.json?
        return "" unless request.content_encoding.empty?

        body = request.body
        return "" if body.bytesize > MAX_DUMP_BODY_BYTES

        begin
          ErrorPage.filtered_json(JSON.parse(body), 0)
        rescue JSON::NestingError, JSON::ParserError, StandardError
          ""
        end
      end

      # A parsed JSON value as Ruby's inspect would show it, each object
      # member whose name ParameterFilter.filter? names shown as
      # "[FILTERED]", recursively. Every piece is appended directly to a
      # +"" local (spikes/NOTES.md rule 66); typed copies through Cast.hash
      # / Cast.array (rule 71), `when Time` first (rule 8).
      def self.filtered_json(value, depth)
        return "..." if depth >= MAX_DUMP_DEPTH

        out = +""
        case value
        when Time
          out << value.to_s
        when Hash
          members = Cast.hash(value)
          out << "{"
          first = true
          members.each_key do |k|
            out << ", " unless first
            first = false
            piece = ParameterFilter.filter?(k) ? ParameterFilter::FILTERED.inspect : ErrorPage.filtered_json(members[k], depth + 1)
            out << k.inspect << "=>" << piece
          end
          out << "}"
        when Array
          items = Cast.array(value)
          out << "["
          i = 0
          while i < items.size
            out << ", " if i > 0
            out << ErrorPage.filtered_json(items[i], depth + 1)
            i += 1
          end
          out << "]"
        else
          out << value.inspect
        end
        out
      end

      def inject_banner(response)
        rebuilder = @rebuilder
        return nil if rebuilder.nil? || !rebuilder.last_failed
        return nil unless banner_status?(response.status)
        return nil if response.body.empty? # `head :ok` and friends stay bodyless
        return nil unless html?(response)

        body = response.body
        at = banner_offset(body)
        response.body = "#{body[0, at]}#{banner(rebuilder.last_output)}#{body[at, body.size - at]}"
        nil
      end

      # Redirects (3xx) and the statuses that never carry a body (1xx, 204,
      # 304: a client reads no body there, so on a keep-alive connection the
      # bytes would prefix the next response) get no banner.
      def banner_status?(status)
        status >= 200 && status < 300 && status != 204 || status >= 400
      end

      # Just after the <body ...> tag, or the very start without one.
      def banner_offset(body)
        tag = body.index("<body")
        return 0 if tag.nil?

        close = body.index(">", tag)
        close.nil? ? 0 : close + 1
      end

      def html?(response)
        type = response.header("Content-Type")
        type.nil? || type.downcase.start_with?("text/html")
      end

      def banner(output)
        html = +"<div id=\"#{BANNER_ID}\" style=\"background: #b91c1c; color: #fff; padding: 1rem; font-family: monospace;\">"
        html << "<strong>Build failed</strong>: the server keeps running the previous build until the next successful one."
        html << "<pre style=\"white-space: pre-wrap; margin: 0.5rem 0 0;\">" << Html.escape(output) << "</pre></div>\n"
        html
      end
    end
  end
end
