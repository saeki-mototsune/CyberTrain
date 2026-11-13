require "json"
require "cybertrain/middleware"
require "cybertrain/html"
require "cybertrain/http/request"
require "cybertrain/dev/state_file"
require "cybertrain/dev/build_status"
require "cybertrain/dev/error_page"
require "cybertrain/dev/supervision"

module Cybertrain
  module Dev
    # Which runtime rendered the page in front of the developer
    # (docs/superpowers/specs/2026-11-12-cruby-preview-design.md sections 5
    # and 8, change 5). Installed by Roles::ServerRunner#front_app only
    # under `cybertrain server`, around ErrorPage and outside the
    # application's stack, so the requests it answers itself never reach
    # RequestLogger. It
    #
    # - sets X-Cybertrain-Runtime ("cruby" or "spinel") on every response;
    # - writes the indicator, one line naming the runtime and what the
    #   background build is doing (Indicator.text), before `</body>` of an
    #   HTML response that ErrorPage would give a banner (its rules) and
    #   that is not served as a download (attachment_disposition?), with
    #   the runtime and generation the page was rendered with, and a script
    #   tag (with the request's CSP nonce when the application uses nonce
    #   directives);
    # - answers two reserved development paths before the application:
    #   STATE_PATH, the state file's generation, serving runtime and build
    #   with the text for the asking page, as JSON; SCRIPT_PATH, the script,
    #   which places the indicator through the CSSOM (no `style` attribute,
    #   which a style-src policy would block), takes the page's runtime and
    #   generation from STATE_PATH asked without them, and asks STATE_PATH
    #   every second for its text. The texts are this class's alone.
    # @api private
    class Indicator < Middleware
      ID = "cybertrain-dev-indicator"
      HEADER = "X-Cybertrain-Runtime"
      STATE_PATH = "/__cybertrain/dev/state"
      SCRIPT_PATH = "/__cybertrain/dev/indicator.js"

      # The page's runtime and generation are first taken from the state
      # path asked without them (a page replayed from the browser's cache,
      # after a 304, shows the current child's content), falling back to
      # the div's data- attributes; then the state path is asked every
      # second for the text. A failed fetch leaves the text as it was.
      SCRIPT = "(function () {\n" \
               "  var el = document.getElementById(\"#{ID}\");\n" \
               "  if (!el) return;\n" \
               "  var s = el.style;\n" \
               "  s.position = \"fixed\"; s.right = \"0.5rem\"; s.bottom = \"0.5rem\"; s.zIndex = \"2147483647\";\n" \
               "  s.padding = \"0.15rem 0.5rem\"; s.borderRadius = \"0.25rem\"; s.pointerEvents = \"none\";\n" \
               "  s.font = \"12px/1.4 system-ui, sans-serif\"; s.color = \"#fff\"; s.background = \"rgba(24, 24, 27, 0.8)\";\n" \
               "  var runtime = el.getAttribute(\"data-runtime\"), generation = el.getAttribute(\"data-generation\");\n" \
               "  function ask(url) {\n" \
               "    return fetch(url, { cache: \"no-store\" })\n" \
               "      .then(function (r) { return r.ok ? r.json() : null; })\n" \
               "      .then(function (state) { if (state && typeof state.text === \"string\") el.textContent = state.text; return state; });\n" \
               "  }\n" \
               "  function poll() {\n" \
               "    ask(\"#{STATE_PATH}?runtime=\" + encodeURIComponent(runtime) + \"&generation=\" + encodeURIComponent(generation))\n" \
               "      .catch(function () {})\n" \
               "      .then(function () { setTimeout(poll, 1000); });\n" \
               "  }\n" \
               "  ask(\"#{STATE_PATH}\")\n" \
               "    .then(function (state) {\n" \
               "      if (!state || typeof state.generation !== \"number\") return;\n" \
               "      generation = String(state.generation);\n" \
               "      if (state.serving === \"cruby\" || state.serving === \"spinel\") runtime = state.serving;\n" \
               "    })\n" \
               "    .catch(function () {})\n" \
               "    .then(function () { setTimeout(poll, 1000); });\n" \
               "})();\n"

      # The indicator's line for a page rendered by page_runtime ("cruby"
      # or "spinel") at page_generation, given the state file now: the
      # first row that holds.
      # @param page_runtime [String]
      # @param page_generation [Integer]
      # @param snapshot [StateSnapshot]
      # @return [String]
      def self.text(page_runtime, page_generation, snapshot)
        return "Source changed — reload" if snapshot.generation > page_generation
        return "Spinel" if page_runtime == "spinel"

        build = snapshot.build
        return "CRuby preview · Spinel building…" if build == "building"
        return "Spinel ready — reload" if build == "ready"
        return "CRuby preview · Spinel build failed" if build == "failed"
        return "CRuby preview · Spinel binary failed" if build == "binary_failed"

        "CRuby preview"
      end

      # @param app [Middleware] the stack, ErrorPage in front
      # @param reader [StateFile::Reader] the supervisor's state file
      # @param status [BuildStatus] ErrorPage's, refreshed on each request
      # @param runtime [String] "cruby" or "spinel" (Supervision.runtime)
      # @param generation [Integer] this process's (Supervision.generation)
      # @param nonce_directives [Array<String>] Config#content_security_policy_nonce_directives
      def initialize(app, reader, status, runtime, generation, nonce_directives)
        super(app)
        @reader = reader
        @status = status
        @runtime = runtime
        @generation = generation
        @nonce_directives = nonce_directives
      end

      def call(ctx)
        snapshot = @reader.current
        @status.update(snapshot)
        request = ctx.request
        path = request.path
        if request.method == "GET" && path == STATE_PATH
          answer_state(ctx.response, request, snapshot)
        elsif request.method == "GET" && path == SCRIPT_PATH
          answer_script(ctx.response)
        else
          nxt = @app
          nxt.call(ctx) unless nxt.nil?
          insert_indicator(ctx, snapshot)
        end
        ctx.response.set_header(HEADER, @runtime)
        nil
      end

      # The JSON of STATE_PATH, written by hand: generation, serving and
      # build come from fixed vocabularies and digits; the text is escaped.
      # @return [String]
      def self.state_json(snapshot, text)
        json = +"{\"generation\":"
        json << snapshot.generation.to_s
        json << ",\"serving\":\"" << snapshot.serving
        json << "\",\"build\":\"" << snapshot.build
        json << "\",\"text\":\"" << Indicator.json_escape(text) << "\"}"
        json
      end

      # text with `"` and `\` escaped for a JSON string.
      def self.json_escape(text)
        s = text.to_s # NOTES rule 62
        s.gsub("\\", "\\\\\\\\").gsub("\"", "\\\\\"")
      end

      # Whether the response is served for saving (Content-Disposition:
      # attachment, the type case-insensitive as RFC 6266 has it; the header
      # name is matched case-insensitively by Response#header). The file is
      # the application's: the indicator must not end up in what the
      # developer saves.
      # @return [Boolean]
      def self.attachment_disposition?(response)
        value = response.header("Content-Disposition")
        return false if value.nil?

        value.to_s.lstrip.downcase.start_with?("attachment") # NOTES rule 62
      end

      # The decoded value of name in the request's query string
      # (Request#query_value), "" when there is none or the query is
      # malformed or too long (Query raises a client fault; the rescue sits
      # in this non-yielding method, NOTES rules 32 and 61).
      def self.state_param(request, name)
        request.query_value(name)
      rescue JSON::NestingError, JSON::ParserError, StandardError
        ""
      end

      private

      # For the page that asks: a garbled or missing generation reads as 0,
      # a runtime other than "spinel" as "cruby". Without either (absent or
      # empty), for a page that has just loaded: the state file's serving
      # runtime (this process's while the supervisor holds) and generation.
      def answer_state(response, request, snapshot)
        asked_runtime = Indicator.state_param(request, "runtime")
        asked_generation = Indicator.state_param(request, "generation")
        if asked_runtime.empty? && asked_generation.empty?
          serving = snapshot.serving
          runtime = serving == "cruby" || serving == "spinel" ? serving : @runtime
          generation = snapshot.generation
        else
          runtime = asked_runtime == "spinel" ? "spinel" : "cruby"
          generation = Supervision.supervision_number(asked_generation, 0)
        end
        response.content_type = "application/json"
        response.set_header("Cache-Control", "no-store")
        response.body = Indicator.state_json(snapshot, Indicator.text(runtime, generation, snapshot))
        nil
      end

      def answer_script(response)
        response.content_type = "text/javascript"
        response.body = SCRIPT
        nil
      end

      # Before the last `</body>`, or at the end without one; never twice.
      def insert_indicator(ctx, snapshot)
        response = ctx.response
        return nil unless ErrorPage.banner_status?(response.status)

        body = response.body.to_s # NOTES rule 62
        return nil if body.empty?
        return nil unless ErrorPage.html_response?(response)
        return nil if Indicator.attachment_disposition?(response)
        return nil unless body.index(ID).nil?

        at = body.rindex("</body>")
        at = body.size if at.nil?
        response.body = "#{body[0, at]}#{markup(ctx, snapshot)}#{body[at, body.size - at]}"
        nil
      end

      def markup(ctx, snapshot)
        html = +"<div id=\"#{ID}\" data-runtime=\"" << Html.escape(@runtime)
        html << "\" data-generation=\"" << @generation.to_s << "\">"
        html << Html.escape(Indicator.text(@runtime, @generation, snapshot)) << "</div>"
        html << "<script src=\"#{SCRIPT_PATH}\""
        html << " nonce=\"" << ctx.csp_nonce << "\"" unless @nonce_directives.empty?
        html << "></script>"
        html
      end
    end
  end
end
