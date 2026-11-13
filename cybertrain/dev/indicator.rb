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
    #   HTML response that ErrorPage would give a banner (its rules: also
    #   not served as a download, ErrorPage.attachment_disposition?, and a
    #   body the application has not encoded, ErrorPage.encoded_body?), with
    #   the runtime and generation the page was rendered with, and a script
    #   tag (with the request's CSP nonce when the application uses nonce
    #   directives);
    # - answers two reserved development paths before the application:
    #   STATE_PATH, the state file's generation, serving runtime and build
    #   with the text for the asking page, as JSON; SCRIPT_PATH, the script,
    #   which places the indicator through the CSSOM (no `style` attribute,
    #   which a style-src policy would block) and asks STATE_PATH, with the
    #   page's runtime and generation from its data- attributes, at once
    #   and every second for its text. The texts are this class's alone;
    # - makes a conditional GET validate against the runtime and generation
    #   that rendered the client's copy: the application's ETag leaves with
    #   a suffix naming this child, and If-None-Match reaches the
    #   application without it only when every tag carries it, the header
    #   being dropped otherwise, as is If-Modified-Since, on GET and HEAD
    #   (Indicator.validate_against_child). A 304 then means the page the
    #   browser replays was rendered here, its data- attributes right.
    # @api private
    class Indicator < Middleware
      ID = "cybertrain-dev-indicator"
      HEADER = "X-Cybertrain-Runtime"
      STATE_PATH = "/__cybertrain/dev/state"
      SCRIPT_PATH = "/__cybertrain/dev/indicator.js"

      # The page's runtime and generation are the div's data- attributes,
      # written when the page was rendered: the state path is asked with
      # them at once and then every second, for the text. A page the
      # browser replays from its cache after a 304 was rendered by this
      # same runtime and generation (the conditional GET validates against
      # them: see #call), so its attributes are right too. A failed fetch
      # leaves the text as it was.
      SCRIPT = "(function () {\n" \
               "  var el = document.getElementById(\"#{ID}\");\n" \
               "  if (!el) return;\n" \
               "  var s = el.style;\n" \
               "  s.position = \"fixed\"; s.right = \"0.5rem\"; s.bottom = \"0.5rem\"; s.zIndex = \"2147483647\";\n" \
               "  s.padding = \"0.15rem 0.5rem\"; s.borderRadius = \"0.25rem\"; s.pointerEvents = \"none\";\n" \
               "  s.font = \"12px/1.4 system-ui, sans-serif\"; s.color = \"#fff\"; s.background = \"rgba(24, 24, 27, 0.8)\";\n" \
               "  var url = \"#{STATE_PATH}?runtime=\" + encodeURIComponent(el.getAttribute(\"data-runtime\")) +\n" \
               "    \"&generation=\" + encodeURIComponent(el.getAttribute(\"data-generation\"));\n" \
               "  function poll() {\n" \
               "    fetch(url, { cache: \"no-store\" })\n" \
               "      .then(function (r) { return r.ok ? r.json() : null; })\n" \
               "      .then(function (state) { if (state && typeof state.text === \"string\") el.textContent = state.text; })\n" \
               "      .catch(function () {})\n" \
               "      .then(function () { setTimeout(poll, 1000); });\n" \
               "  }\n" \
               "  poll();\n" \
               "})();\n"

      # The indicator's line for a page rendered by page_runtime ("cruby"
      # or "spinel") at page_generation, given the state file now: the
      # first row that holds. The supervisor writes serving none only while
      # no child runs, so a page that reads it comes from a child started
      # after the write (or one being stopped): the build it names is not
      # one this page waits on (ready there is a binary that will not be
      # started, a change being pending), and the line names the runtime
      # alone.
      # @param page_runtime [String]
      # @param page_generation [Integer]
      # @param snapshot [StateSnapshot]
      # @return [String]
      def self.text(page_runtime, page_generation, snapshot)
        return "Source changed — reload" if snapshot.generation > page_generation
        return "Spinel" if page_runtime == "spinel"
        return "CRuby preview" if snapshot.serving == "none"

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
        @etag_suffix = "-dev-#{runtime}-#{generation}"
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
          # GET and HEAD only, the requests HttpCache answers 304: another
          # method's preconditions are the application's, as sent.
          Indicator.validate_against_child(request, @etag_suffix) if request.method == "GET" || request.method == "HEAD"
          nxt = @app
          nxt.call(ctx) unless nxt.nil?
          insert_indicator(ctx, snapshot)
          tag = ctx.response.header("ETag").to_s # NOTES rule 62
          ctx.response.set_header("ETag", Indicator.child_etag(tag, @etag_suffix)) unless tag.empty?
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

      # text with every character past ASCII written as a numeric
      # character reference (&#183;), the browser showing the same text. The
      # markup is then ASCII, and joins a body in any ASCII-compatible
      # encoding: under CRuby, UTF-8 text beside a binary body with a byte
      # past 0x7F (send_data of a file read as bytes) raises
      # Encoding::CompatibilityError. Reads UTF-8 by its bytes.
      # @param text [String]
      # @return [String]
      def self.ascii_html(text)
        s = text.to_s # NOTES rule 62
        n = s.bytesize
        out = +""
        start = 0
        i = 0
        while i < n
          b = s.getbyte(i)
          if b < 128
            i += 1
          else
            out << s.byteslice(start, i - start) if i > start
            size = 2
            code = b & 31
            if b >= 240
              size = 4
              code = b & 7
            elsif b >= 224
              size = 3
              code = b & 15
            end
            j = 1
            while j < size && i + j < n
              code = code * 64 + (s.getbyte(i + j) & 63)
              j += 1
            end
            out << "&#" << code.to_s << ";"
            i += size
            start = i
          end
        end
        return s if start == 0

        out << s.byteslice(start, n - start) if n > start
        out
      end

      # Makes a conditional request validate against the runtime and
      # generation that rendered the client's copy as well as against the
      # application's own validators, so that a 304 means the cached page,
      # its data- attributes included, came from this child. Every ETag
      # this child sends carries its suffix (#call, Indicator.child_etag).
      # If-None-Match keeps its tags, the suffix removed, only when every
      # tag in it carries this child's suffix; any other tag (another
      # generation's or runtime's, or one sent before the preview), `*`
      # (which names no runtime) or a list without a tag drops the header,
      # and the application answers 200 with a page rendered here.
      # If-Modified-Since is always dropped: a date cannot say which
      # runtime rendered the page, so a page validated by Last-Modified
      # alone is answered 200 under the preview.
      # @param request [Request]
      # @param suffix [String] this child's, "-dev-<runtime>-<generation>"
      # @return [nil]
      def self.validate_against_child(request, suffix)
        headers = request.headers
        Indicator.drop_request_header(headers, "If-Modified-Since")
        listed = request.header("If-None-Match")
        return nil if listed.nil?

        kept = Indicator.child_none_match(listed.to_s, suffix) # NOTES rule 62
        Indicator.drop_request_header(headers, "If-None-Match")
        headers["if-none-match"] = kept unless kept.empty?
        nil
      end

      # Removes every header of name, in any spelling, from a request's
      # headers.
      # @param headers [Hash{String => String}]
      # @param name [String]
      # @return [nil]
      def self.drop_request_header(headers, name)
        gone = Array.new(0) { "" }
        headers.each_key { |key| gone << key if HeaderName.same?(key, name) }
        gone.each { |key| headers.delete(key) }
        nil
      end

      # The ETag tag with suffix before its closing quote (`W/"abc"` ->
      # `W/"abc-dev-cruby-3"`); a value that is not a quoted entity-tag is
      # returned as it is (a request that lists it lacks the suffix, so it
      # is never answered 304 here).
      # @param tag [String]
      # @param suffix [String]
      # @return [String]
      def self.child_etag(tag, suffix)
        text = tag.to_s # NOTES rule 62
        n = text.bytesize
        return text unless Indicator.quoted_tag?(text)

        "#{text.byteslice(0, n - 1)}#{suffix}\""
      end

      # The If-None-Match list with suffix removed from each tag, "" when
      # the header must be dropped (see .validate_against_child): an entry
      # that is `*`, is not a quoted entity-tag or lacks suffix, or no
      # entry at all. A comma inside a quoted tag is part of the tag, so
      # the list is walked byte by byte; empty entries are skipped.
      # @param list [String]
      # @param suffix [String]
      # @return [String]
      def self.child_none_match(list, suffix)
        text = list.to_s # NOTES rule 62
        n = text.bytesize
        out = +""
        quoted = false
        start = 0
        i = 0
        while i <= n
          b = i < n ? text.getbyte(i).to_i : 44
          if b == 34 # "
            quoted = !quoted
          elsif b == 44 && (!quoted || i == n) # , or the end
            entry = text.byteslice(start, i - start).to_s.strip
            unless entry.empty?
              stripped = Indicator.unsuffixed_tag(entry, suffix)
              return "" if stripped.empty?

              out << ", " unless out.empty?
              out << stripped
            end
            start = i + 1
          end
          i += 1
        end
        out
      end

      # entry without suffix before its closing quote, "" when entry is not
      # a quoted entity-tag ending in suffix.
      def self.unsuffixed_tag(entry, suffix)
        text = entry.to_s # NOTES rule 62
        return "" unless Indicator.quoted_tag?(text)

        tail = "#{suffix}\""
        return "" unless text.end_with?(tail)

        body = text.byteslice(0, text.bytesize - tail.bytesize).to_s
        return "" unless Indicator.quoted_tag?("#{body}\"")

        "#{body}\""
      end

      # Whether text is an entity-tag: `"..."` or `W/"..."`, the opaque
      # part free of quotes (RFC 9110 8.8.3).
      def self.quoted_tag?(text)
        s = text.to_s # NOTES rule 62
        from = s.start_with?("W/") ? 2 : 0
        n = s.bytesize
        return false if n - from < 2
        return false unless s.getbyte(from) == 34 && s.getbyte(n - 1) == 34

        i = from + 1
        while i < n - 1
          return false if s.getbyte(i) == 34
          i += 1
        end
        true
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
      # empty), for a page of the state file's serving runtime (this
      # process's while the supervisor holds or names none) and generation:
      # what a client that has no page, such as script/preview-e2e, reads
      # as the current state. The script always sends both.
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
        return nil if ErrorPage.attachment_disposition?(response)
        return nil if ErrorPage.encoded_body?(response)
        return nil unless body.index(ID).nil?

        at = body.rindex("</body>")
        at = body.size if at.nil?
        response.body = "#{body[0, at]}#{markup(ctx, snapshot)}#{body[at, body.size - at]}"
        nil
      end

      def markup(ctx, snapshot)
        html = +"<div id=\"#{ID}\" data-runtime=\"" << Html.escape(@runtime)
        html << "\" data-generation=\"" << @generation.to_s << "\">"
        html << Indicator.ascii_html(Html.escape(Indicator.text(@runtime, @generation, snapshot))) << "</div>"
        html << "<script src=\"#{SCRIPT_PATH}\""
        html << " nonce=\"" << ctx.csp_nonce << "\"" unless @nonce_directives.empty?
        html << "></script>"
        html
      end
    end
  end
end
