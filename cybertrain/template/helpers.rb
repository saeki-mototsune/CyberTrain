# Cybertrain::Template::Helpers -- what templates call without a receiver:
# link_to, button_to, form_with, render, pluralize, the route helpers ...
#
# The interpreter hands every receiverless call to helper_call(name, ...),
# which dispatches on the name with a `case` (Spinel has no `send`). Route
# helpers (`post_path(post)`) go to Views.url_resolver, which the app wires
# to its generated Gen::Routes.path_for.
#
# The controller is optional (nil in unit tests): without it there is no
# session (so no CSRF token), no flash and empty params. It is typed by the
# program that renders through it: cybertrain/controller.rb requires this
# file, so this file does not require the controller back.
require "cybertrain/assets"
require "cybertrain/html"
require "cybertrain/http/header_name"
require "cybertrain/http/query"
require "cybertrain/number_helper"
require "cybertrain/model"
require "cybertrain/pagination"
require "cybertrain/params"
require "cybertrain/views"
require "cybertrain/component"
require "cybertrain/stream"
require "cybertrain/template/engine"
require "cybertrain/template/form_builder"
require "cybertrain/template/turbo_stream_builder"
require "cybertrain/strftime"
require "cybertrain/i18n"
require "cybertrain/generator/inflector"
require "cybertrain/generator/url_support"

module Cybertrain
  module Template
    class Helpers < HelperBase
      MINUTES_IN_YEAR = 525_600
      MINUTES_IN_QUARTER_YEAR = 131_400
      MINUTES_IN_THREE_QUARTERS_YEAR = 394_200
      # The keywords turbo_frame_tag and time_tag take.
      TURBO_FRAME_KEYWORDS = %w[src loading target class data]
      TIME_TAG_KEYWORDS = %w[format class id title data]
      # The keywords of the asset tag helpers (spec 7.2).
      STYLESHEET_KEYWORDS = %w[media nonce]
      JAVASCRIPT_INCLUDE_KEYWORDS = %w[nonce]
      IMAGE_TAG_KEYWORDS = %w[alt size class]
      JS_HEX = "0123456789abcdef"

      def initialize(controller)
        @controller = controller
        # model_name => its underscored route key, for this request only (a
        # page with a list of records asks for the same few names once per
        # link and form). Typed empty Hash: spikes/NOTES.md rule 9.
        @model_keys = { "" => "" }
        @model_keys.delete("")
        @route_keys = { "" => "" }
        @route_keys.delete("")
        # template dir => partial name => its file name, for this request
        # only (a collection renders the same partial once per record).
        @partial_files = { "" => { "" => "" } }
        @partial_files.delete("")
        # The components being rendered, innermost last: their view methods
        # answer receiverless names (render_with pushes and pops). Typed
        # empty Array (rule 9).
        @components = Array.new(0) { Component.new }
        # Set by Views.render_partial / render_component: the request-bound
        # helpers then raise Views::OutsideRequest. A plain nil controller
        # (unit tests) keeps answering "" and empty values.
        @outside_request = false
        # The options of a url_for or route call that has none (link_to's
        # href, a form's action): a template's keywords Hash, typed empty
        # (rule 9). Never mutated.
        @no_url_options = { "" => [nil, 0, 0.0, "", true][0] }
        @no_url_options.delete("")
      end

      # Marks these helpers as rendering with no request (Views.render_partial).
      def outside_request!
        @outside_request = true
        nil
      end

      # Raises when a helper that needs a request runs outside one. Forms
      # (button_to, form_with) still render outside a request, without the
      # authenticity token, so a broadcast partial can hold one.
      def request_bound!(name)
        return nil unless @outside_request

        raise Views::OutsideRequest, "#{name} needs a request"
      end

      # Component#render_with, around its template.
      def component_push(component)
        @components << component
        nil
      end

      def component_pop
        @components.pop
        nil
      end

      def helper_call(name, args, kwargs, block, interp, env)
        case name
        when "link_to" then link_to(args, kwargs)
        when "button_to" then button_to(args, kwargs)
        when "form_with" then form_with(kwargs, block, interp, env)
        when "select_tag" then select_tag(args, kwargs)
        when "options_for_select" then options_for_select(args, kwargs)
        when "options_from_collection_for_select" then options_from_collection_for_select(args, kwargs)
        when "label_tag" then label_tag(args, kwargs)
        when "text_field_tag" then text_field_tag(args, kwargs)
        when "hidden_field_tag" then hidden_field_tag(args, kwargs)
        when "submit_tag" then submit_tag(args, kwargs)
        when "render"
          return render_component_helper(kwargs, block, interp, env) if args.empty? && !kwargs["component"].nil?

          render_helper(args, kwargs, interp, env)
        when "h", "escape" then SafeString.of(html_arg(args, 0, name))
        when "raw" then SafeString.of(text_arg(args, 0, name))
        when "pluralize" then pluralize(args)
        when "truncate" then truncate(args, kwargs)
        when "number_with_delimiter" then number_with_delimiter(args, kwargs)
        when "number_with_precision" then number_with_precision(args, kwargs)
        when "number_to_human" then number_to_human(args, kwargs)
        when "number_to_percentage" then number_to_percentage(args, kwargs)
        when "number_to_currency" then number_to_currency(args, kwargs)
        when "number_to_human_size" then number_to_human_size(args, kwargs)
        when "time_ago_in_words" then distance_of_time_in_words(time_arg(args, 0, name), Time.now)
        when "content_for" then content_for(args, block, interp, env)
        when "content_for?" then !env["__content_#{text_arg(args, 0, name)}"].nil?
        when "csrf_meta_tags" then csrf_meta_tags
        when "csrf_token" then csrf_token
        when "csp_meta_tag"
          helper_arity!(name, args, 0, 0)
          helper_no_keywords!(name, kwargs)
          csp_meta_tag
        when "content_security_policy_nonce"
          helper_arity!(name, args, 0, 0)
          helper_no_keywords!(name, kwargs)
          content_security_policy_nonce
        when "javascript_tag" then javascript_tag(args, kwargs, block, interp, env)
        when "asset_path"
          helper_arity!(name, args, 1, 1)
          helper_no_keywords!(name, kwargs)
          asset_path(text_arg(args, 0, name))
        when "stylesheet_link_tag" then stylesheet_link_tag(args, kwargs)
        when "javascript_include_tag" then javascript_include_tag(args, kwargs)
        when "image_tag" then image_tag(args, kwargs)
        when "javascript_importmap_tags"
          helper_arity!(name, args, 0, 1)
          helper_no_keywords!(name, kwargs)
          javascript_importmap_tags(args.empty? ? "application" : text_arg(args, 0, name))
        when "flash" then flash_messages
        when "params" then params
        when "request_path" then request_path
        when "url_for" then url_for(arg(args, 0, name), kwargs)
        when "paginate" then paginate(args)
        when "tag" then Html::TAG_BUILDER
        when "content_tag" then content_tag(args, kwargs, block, interp, env)
        when "safe_join"
          no_kwargs(kwargs, name)
          safe_join(args)
        when "class_names" then class_names(args, kwargs)
        when "dom_id"
          no_kwargs(kwargs, name)
          dom_id(args)
        when "turbo_stream_from" then turbo_stream_from(args, kwargs)
        when "turbo_frame_tag" then turbo_frame_tag(args, kwargs, block, interp, env)
        when "turbo_stream"
          # The template's builder (`turbo_stream.replace ...`). No method
          # named turbo_stream here: Controller#turbo_stream returns
          # TurboStreams (NAME_HOMES in script/check-reserved-names).
          helper_arity!(name, args, 0, 0)
          helper_no_keywords!(name, kwargs)
          raise CallSyntaxError, "turbo_stream takes no block (turbo_stream.replace \"id\" do ... end does)" unless block.nil?

          TurboStreamBuilder.new(self, interp, env)
        when "time_tag" then time_tag(args, kwargs, block, interp, env)
        when "t", "translate" then translate_helper(args, kwargs, interp)
        when "l", "localize" then localize_helper(args, kwargs)
        when "current_page?" then current_page?(args, kwargs)
        when "signed_stream_name" then signed_stream_name(args)
        when "stream_source_path" then stream_source_path(args, kwargs)
        else
          # Inside a component's template its view methods come first (the
          # component is the template's self, as in ViewComponent).
          depth = @components.size
          if depth > 0 && args.empty? && block.nil?
            component = @components[depth - 1]
            return component.call_view_method(name.to_sym) if component.view_method?(name)
          end
          # The controller's helper methods (`helper_method :x`, spec 4.3),
          # in its templates and the components they render. Outside a
          # request there is no controller, so the name is undefined.
          controller = @controller
          return controller.call_helper_method(name, args, kwargs) if !controller.nil? && controller.helper_method?(name)

          request_bound!(name) if name.end_with?("_url")
          return route(name, args, kwargs) if name.end_with?("_path") || name.end_with?("_url")

          app_helper_call(name, args, kwargs, block, interp, env)
        end
      end

      # The application's helpers (app/helpers): gen/helpers.rb's
      # ApplicationHelpers overrides this with a `case` over the names it
      # scanned and calls super for the rest, which ends here.
      def app_helper_call(name, args, kwargs, block, interp, env)
        raise RuntimeError, "undefined helper '#{name}'"
      end

      # --- for the generated ApplicationHelpers and Ruby helpers ---------------

      # The positional-argument check of a generated helper arm.
      def helper_arity!(name, args, min, max)
        Helpers.helper_arity!(name, args, min, max)
      end

      # A helper that takes no keywords was given some.
      def helper_no_keywords!(name, kwargs)
        Helpers.helper_no_keywords!(name, kwargs)
      end

      # known: the helper's keywords, its `required` required ones first.
      def helper_keywords!(name, kwargs, known, required)
        Helpers.helper_keywords!(name, kwargs, known, required)
      end

      # The three checks as class methods too: a controller's generated
      # call_helper_method (helper_method, spec 4.3) runs them outside
      # these helpers.
      def self.helper_arity!(name, args, min, max)
        n = args.size
        return nil if n >= min && n <= max

        expected = min == max ? min.to_s : "#{min}..#{max}"
        raise ArgumentError, "wrong number of arguments for '#{name}' (given #{n}, expected #{expected})"
      end

      def self.helper_no_keywords!(name, kwargs)
        return nil if kwargs.empty?

        raise ArgumentError, "'#{name}' takes no keyword arguments (given #{kwargs.keys.join(", ")})"
      end

      def self.helper_keywords!(name, kwargs, known, required)
        i = 0
        while i < required
          raise ArgumentError, "missing keyword '#{known[i]}' for '#{name}'" unless kwargs.key?(known[i])

          i += 1
        end
        kwargs.each_key do |key|
          raise ArgumentError, "unknown keyword '#{key}' for '#{name}' (known: #{known.join(", ")})" unless Helpers.name_in?(known, key)
        end
        nil
      end

      # What a helper's block returns: the template block's output, or ""
      # when the template passed no block.
      def app_block_content(block, interp, env)
        return SafeString.of("") if block.nil?

        SafeString.of(interp.capture(block, env))
      end

      # link_to for Ruby helpers: `link_to_path("Edit", edit_article_path(a),
      # class: "btn")`. The text is escaped unless it is a SafeString; attrs
      # takes class:, id:, data_confirm: and data: as link_to does.
      # @api public
      def link_to_path(text, path, attrs = {})
        link_to([text, path], string_keys_of(attrs))
      end

      # button_to for Ruby helpers: `button_to_path("Delete", article_path(a),
      # method: "delete", class: "danger")`.
      # @api public
      def button_to_path(text, path, attrs = {})
        button_to([text, path], string_keys_of(attrs))
      end

      # The partial `name` (found as `render` finds it from this template)
      # with `locals` (String keys), checked against its strict locals: what
      # the template's turbo_stream builder renders for `partial:`.
      # @return [SafeString]
      def partial_html(name, locals, interp, env)
        engine = Views.engine
        raise ArgumentError, "no views configured (Cybertrain::Views.configure)" if engine.nil?

        template = engine.template(partial_file(FormBuilder.value_text(env["__template_dir"]), name))
        names = Array.new(0) { "" }
        locals.each_key { |key| names << key }
        render_partial_scope(template, locals, names, interp, env)
      end

      # `f.label :title` and the other FormBuilder methods, `@page.next?`
      # (neither takes a block), and the `tag` builder.
      def call_object_method(recv, name_sym, name_str, args, kwargs, block, interp, env)
        case recv
        when FormBuilder
          raise CallSyntaxError, "FormBuilder##{name_str} takes no block" unless block.nil?

          recv.call_method(name_sym, args, kwargs)
        when Cybertrain::Page
          raise CallSyntaxError, "Page##{name_str} takes no block" unless block.nil?

          page_method(recv, name_sym, name_str)
        when Html::TagBuilder then tag_builder_call(name_str, args, kwargs, block, interp, env)
        when TurboStreamBuilder
          # The block renders at once, here: the builder never holds it
          # (spikes/NOTES.md rule 88).
          return recv.call_method(name_sym, args, kwargs) if block.nil?

          content = interp.capture(block, env)
          recv.call_method_with_block(name_sym, args, kwargs, content)
        else super(recv, name_sym, name_str, args, kwargs, block, interp, env)
        end
      end

      # Rails' distance_of_time_in_words without seconds (and without the
      # leap-year correction for spans of years).
      def distance_of_time_in_words(from, to)
        seconds = (to - from).abs
        minutes = (seconds / 60.0).round
        if minutes < 1 then "less than a minute"
        elsif minutes < 2 then "1 minute"
        elsif minutes < 45 then "#{minutes} minutes"
        elsif minutes < 90 then "about 1 hour"
        elsif minutes < 1440 then "about #{(minutes / 60.0).round} hours"
        elsif minutes < 2520 then "1 day"
        elsif minutes < 43_200 then "#{(minutes / 1440.0).round} days"
        elsif minutes < 86_400 then "about 1 month"
        elsif minutes < MINUTES_IN_YEAR then "#{(minutes / 43_200.0).round} months"
        else
          years = minutes / MINUTES_IN_YEAR
          rest = minutes % MINUTES_IN_YEAR
          if rest < MINUTES_IN_QUARTER_YEAR then "about #{plural_words(years, "year")}"
          elsif rest < MINUTES_IN_THREE_QUARTERS_YEAR then "over #{plural_words(years, "year")}"
          else "almost #{plural_words(years + 1, "year")}"
          end
        end
      end

      # Checks the locals a partial is given against its `<%# locals: (...) %>`
      # comment. Shared with Controller#render(partial:).
      def self.check_locals(template, given)
        return nil unless template.strict_locals?

        # while loops: a block here allocated a Proc and its closure cells
        # on every partial render.
        locals = template.locals
        i = 0
        while i < locals.size
          name = locals[i]
          raise ArgumentError, "missing local '#{name}' for #{template.name}" unless Helpers.name_in?(given, name)
          i += 1
        end
        i = 0
        while i < given.size
          name = given[i]
          raise ArgumentError, "unknown local '#{name}' for #{template.name}" unless Helpers.name_in?(locals, name)
          i += 1
        end
        nil
      end

      # Array#include? with String arguments mis-dispatches once the whole
      # framework (SafeString's to_str) is in the program (spikes/NOTES.md
      # rules 14 and 29); compare explicitly.
      # A while loop: `each` with a `return` in the block costs a setjmp and
      # a Proc per call under Spinel, and this runs for every partial.
      def self.name_in?(names, name)
        i = 0
        n = names.size
        while i < n
          return true if names[i] == name
          i += 1
        end
        false
      end

      # The current flash messages as a Hash ("notice" => "Saved"), so that
      # `flash[:notice]` indexes it: the interpreter's [] knows Hash, not
      # Flash. Empty without a flash (no SessionStore).
      def self.flash_messages(flash)
        messages = {}
        messages[""] = ""
        messages.clear
        return messages if flash.nil?

        flash.keys.each { |key| messages[key] = flash[key] }
        messages
      end

      # "form" -> "posts/_form" (dir: the controller's view directory);
      # "comments/comment" -> "comments/_comment".
      def self.partial_path(dir, name)
        slash = name.rindex("/")
        return "#{dir}/_#{name}" if slash.nil?

        "#{name[0, slash]}/_#{name[slash + 1, name.length - slash - 1]}"
      end

      private

      # `class: "c"` from Ruby comes with Symbol keys; the template-facing
      # helpers look keywords up by String (typed Hash, rule 71).
      def string_keys_of(attrs)
        out = { "" => [nil, 0, 0.0, "", true][0] }
        out.delete("")
        attrs.each_key { |key| out[key.to_s] = attrs[key] }
        out
      end

      # --- links and forms ---------------------------------------------------

      # link_to "Show", post_path(post), class: "btn"; the href may also be a
      # record (`link_to post.title, post`). method: needs a form, so it is
      # refused rather than faked with JavaScript.
      def link_to(args, kwargs)
        text = html_arg(args, 0, "link_to")
        href = url_for(arg(args, 1, "link_to"), @no_url_options)
        unless kwargs["method"].nil?
          raise ArgumentError, "link_to does not support method: (use button_to '#{text}', path, method: :#{FormBuilder.value_text(kwargs["method"])})"
        end

        # One interpolation (see button_to); the optional attributes are ""
        # when absent (see kwarg_attr).
        css = kwarg_attr(kwargs, "class", "class")
        id = kwarg_attr(kwargs, "id", "id")
        confirm = kwarg_attr(kwargs, "data_confirm", "data-confirm")
        data = kwargs["data"].nil? ? "" : data_attrs(kwargs["data"])
        SafeString.of("<a href=\"#{Html.escape(href)}\"#{css}#{id}#{confirm}#{data}>#{text}</a>")
      end

      # A one-button form: POST (with a hidden _method for delete/patch/put)
      # plus the CSRF token, or a plain GET form.
      def button_to(args, kwargs)
        text = html_arg(args, 0, "button_to")
        action = url_for(arg(args, 1, "button_to"), @no_url_options)
        verb = kwargs["method"].nil? ? "post" : lower_text(kwargs["method"])
        # One interpolation, allocated once at its final size: a `+""`
        # buffer costs a copy of the literal, a String object, and a copy
        # of the result when it is returned. The optional parts are "" (a
        # static literal) when absent (see kwarg_attr).
        css = kwarg_attr(kwargs, "class", "class")
        data = kwargs["data"].nil? ? "" : data_attrs(kwargs["data"])
        SafeString.of("<form class=\"button_to\" method=\"#{verb == "get" ? "get" : "post"}\" action=\"#{Html.escape(action)}\">#{hidden_fields(verb)}<button#{css}#{data} type=\"submit\">#{text}</button></form>")
      end

      # form_with(model: post) do |f| ... end, form_with(model: [post, comment]),
      # form_with(url: "/search", method: :get). A new record posts to the
      # collection route, a saved one patches its member route.
      # `multipart: true` adds enctype="multipart/form-data" (needed for
      # f.file_field); it raises ArgumentError on a GET form.
      # `scope: :q` prefixes the field names (q[term]); with model: it
      # replaces the model's prefix. `model: [:admin, article]` posts to the
      # namespaced route (admin_article_path) with fields named after the
      # last record. `data: { turbo_frame: "x" }` writes data- attributes;
      # `local:` is accepted and changes nothing (every form submits as
      # Turbo or the browser decides).
      def form_with(kwargs, block, interp, env)
        raise ArgumentError, "form_with needs a block (form_with(...) do |f| ... end)" if block.nil?

        model = kwargs["model"]
        record = form_record(model)
        scope = kwargs["scope"].nil? ? "" : FormBuilder.value_text(kwargs["scope"])
        action = kwargs["url"].nil? ? form_record_url(model) : url_for(kwargs["url"], @no_url_options)
        verb = "post"
        if !kwargs["method"].nil?
          verb = lower_text(kwargs["method"])
        elsif !record.nil? && record.persisted?
          verb = "patch"
        end
        # No auto-detect from a file_field inside: the <form> tag is built
        # before the block runs, so the caller says so up front.
        multipart = kwargs["multipart"] == true
        raise ArgumentError, "form_with multipart: true needs a non-GET method" if multipart && verb == "get"

        buf = +"<form"
        buf << " action=\"" << Html.escape(action) << "\""
        buf << " method=\"" << (verb == "get" ? "get" : "post") << "\""
        buf << " enctype=\"multipart/form-data\"" if multipart
        buf << " class=\"" << Html.escape(FormBuilder.value_text(kwargs["class"])) << "\"" unless kwargs["class"].nil?
        buf << FormBuilder.attr_html("data", kwargs["data"]) unless kwargs["data"].nil?
        buf << ">"
        buf << hidden_fields(verb)
        buf << interp.capture(block, env, FormBuilder.new(record, scope))
        buf << "</form>"
        SafeString.of(buf)
      end

      # The record the fields read from: the model itself, or the last of a
      # nested [parent, child] pair.
      def form_record(model)
        case model
        when Cybertrain::Model then model
        when Array
          last = model.last
          case last
          when Cybertrain::Model then last
          end
        end
      end

      # The collection route name for a model key, as ActiveModel::Name#route_key
      # builds it: the plural, or "<plural>_index" when the word is its own
      # plural (sheep_index_path; the routes DSL names that collection the
      # same way).
      # Not cached across requests: a process-wide table needs a lock under
      # SPINEL_WORKERS > 1, and taking a Mutex on every page stalled
      # requests for seconds there (bench/run, two workers). route_key_of
      # remembers it for the request.
      def self.route_key(singular)
        plural = Inflector.pluralize(singular)
        plural == singular ? "#{plural}_index" : plural
      end

      # posts_path / post_path(post); nested: post_comments_path(post).
      def form_record_url(model)
        case model
        when Cybertrain::Model
          return url_for(model, @no_url_options) if model.persisted?

          # Bound step by step (see I18n.humanize_attribute).
          route("#{route_key_of(model_key(model))}_path", [], @no_url_options)
        when Array then url_for(model, @no_url_options)
        else raise ArgumentError, "form_with needs model: or url:"
        end
      end

      # _method for verbs HTML forms cannot send, then the CSRF token for
      # anything but GET (omitted without a session to take it from). Tag
      # builders append what these return rather than passing their buffer
      # down (see FormBuilder.html_attr).
      # Interpolations, not a `+""` buffer (see button_to).
      def hidden_fields(verb)
        return "" if verb == "get"

        method_field = verb == "post" ? "" : "<input type=\"hidden\" name=\"_method\" value=\"#{Html.escape(verb)}\">"
        token = session_csrf_token
        return method_field if token.empty?

        "#{method_field}<input type=\"hidden\" name=\"authenticity_token\" value=\"#{Html.escape(token)}\">"
      end

      # class: "btn" -> ` class="btn"` (attr_name: the HTML spelling, as
      # data-confirm for data_confirm:), or "" (a static literal, nothing
      # allocated) when the keyword is absent, so that link_to and button_to
      # still build their tag in one interpolation.
      def kwarg_attr(kwargs, key, attr_name)
        return "" if kwargs[key].nil?

        FormBuilder.text_attr(attr_name, kwargs[key])
      end

      # data: { turbo_confirm: "Sure?" } -> data-turbo-confirm="Sure?",
      # through FormBuilder.attr_html, so a key that is not a valid
      # attribute name raises as it does for every other data: Hash; a nil
      # value is dropped.
      def data_attrs(data)
        case data
        when Hash then FormBuilder.attr_html("data", data)
        else ""
        end
      end

      # --- form tags without a model -------------------------------------------
      #
      # Rails' standalone tag helpers. Other keywords become attributes in
      # the order given (FormBuilder.attrs_html). Ids come from the name as
      # Rails' sanitize_to_id ("q[term]" -> "q_term").

      # select_tag "order", options_for_select(...), include_blank:, prompt:,
      # multiple: (which names order[]). option_tags is HTML: a SafeString
      # (the options_* helpers) goes in as it is, a String is escaped.
      def select_tag(args, kwargs)
        helper_arity!("select_tag", args, 1, 2)
        name = text_arg(args, 0, "select_tag")
        html_name = kwargs["multiple"] == true && !name.end_with?("[]") ? "#{name}[]" : name
        prefix = FormBuilder.select_prefix(kwargs, true, "")
        options = args.size > 1 ? FormBuilder.html_text(args[1]) : ""
        SafeString.of("<select name=\"#{Html.escape(html_name)}\" id=\"#{Html.escape(FormBuilder.tag_id(name))}\"#{FormBuilder.attrs_html(kwargs, FormBuilder::TAG_SELECT_KEYS, "")}>#{prefix}#{options}</select>")
      end

      # options_for_select(container, selected = nil): container as f.select's
      # choices; selected a value or an Array of them, compared as Strings.
      def options_for_select(args, kwargs)
        helper_arity!("options_for_select", args, 1, 2)
        helper_no_keywords!("options_for_select", kwargs)
        selected = FormBuilder.text_list(args.size > 1 ? args[1] : nil)
        SafeString.of(FormBuilder.options_html(args[0], selected, FormBuilder::NO_KEYS))
      end

      # options_from_collection_for_select(authors, :id, :name, selected = nil):
      # each record's value and text read as f.collection_select reads them.
      def options_from_collection_for_select(args, kwargs)
        helper_arity!("options_from_collection_for_select", args, 3, 4)
        helper_no_keywords!("options_from_collection_for_select", kwargs)
        selected = FormBuilder.text_list(args.size > 3 ? args[3] : nil)
        value_sym = FormBuilder.method_sym(args[1])
        text_sym = FormBuilder.method_sym(args[2])
        SafeString.of(FormBuilder.collection_options(args[0], value_sym, text_sym, selected, FormBuilder::NO_KEYS, "options_from_collection_for_select"))
      end

      # label_tag(:term) -> <label for="term">Term</label>; explicit text is
      # escaped unless it is a SafeString.
      def label_tag(args, kwargs)
        helper_arity!("label_tag", args, 1, 2)
        name = text_arg(args, 0, "label_tag")
        text = args.size > 1 && !args[1].nil? ? FormBuilder.html_text(args[1]) : Html.escape(I18n.humanize_attribute(name))
        SafeString.of("<label for=\"#{Html.escape(FormBuilder.tag_id(name))}\"#{FormBuilder.attrs_html(kwargs, FormBuilder::NO_KEYS, "")}>#{text}</label>")
      end

      # text_field_tag(:term, value = nil, placeholder: ...); id: replaces
      # the id taken from the name.
      def text_field_tag(args, kwargs)
        helper_arity!("text_field_tag", args, 1, 2)
        name = text_arg(args, 0, "text_field_tag")
        SafeString.of(FormBuilder.input_tag("text", name, args.size > 1 ? args[1] : nil, kwargs, ""))
      end

      # hidden_field_tag(:token, value = nil), with autocomplete="off" as
      # Rails writes it (a browser restoring the page does not refill
      # it from its form cache).
      def hidden_field_tag(args, kwargs)
        helper_arity!("hidden_field_tag", args, 1, 2)
        name = text_arg(args, 0, "hidden_field_tag")
        SafeString.of(FormBuilder.input_tag("hidden", name, args.size > 1 ? args[1] : nil, kwargs, " autocomplete=\"off\""))
      end

      # submit_tag(value = "Save changes"), named commit as f.submit is; the
      # default is cybertrain.helpers.submit.no_model in the locale.
      def submit_tag(args, kwargs)
        helper_arity!("submit_tag", args, 0, 1)
        text = args.empty? ? Html.escape(I18n.t("cybertrain.helpers.submit.no_model")) : FormBuilder.html_text(args[0])
        SafeString.of("<input type=\"submit\" name=\"commit\" value=\"#{text}\"#{FormBuilder.attrs_html(kwargs, FormBuilder::NO_KEYS, "")}>")
      end

      # --- routes ------------------------------------------------------------

      # The template's keywords go along as the helper's options
      # (`post_path(post, page: 2)`: Gen.with_options). to_s, not an
      # interpolation: a String typed without a copy (see
      # FormBuilder.value_text).
      def route(name, args, options)
        Views.url_resolver.call(name, args, options).to_s
      end

      # A String is already a URL; a record maps to its member route
      # ("post_path"), a [parent, child] pair to the nested one
      # ("post_comment_path", or "post_comments_path" for a new child).
      # options (`format:`, `anchor:`, query keys) are appended as a path
      # helper appends them (`url_for("/x", format: :csv)` is "/x.csv").
      def url_for(target, options)
        case target
        when SafeString then string_url(target.to_s, options)
        when String then string_url(target, options)
        when Cybertrain::Model then route("#{model_key(target)}_path", [target], options)
        when Array then nested_url(target, options)
        else raise ArgumentError, "url_for cannot build a URL from #{FormBuilder.value_text(target)}"
        end
      end

      # url_for's String case: options (format:, a query, anchor:) are appended
      # to the path, so a URL that already has a query or fragment is refused.
      def string_url(url, options)
        return "#{url}" if options.empty?

        if url.include?("?") || url.include?("#")
          msg = "url_for #{url.inspect}: options cannot be added to a URL that already has a query or fragment"
          raise ArgumentError, msg
        end
        Cybertrain::Gen.with_options(url, options)
      end

      # url_for's Array case: the route named after the records in items,
      # in order ("post_comment_path"), called with those records. A last
      # record that is new names the collection route instead
      # ("post_comments_path") and is left out of the arguments. A Symbol
      # is a namespace (`[:admin, article]`: "admin_article_path").
      # Raises ArgumentError when an item of the general case is neither.
      def nested_url(items, options)
        # [parent, child], the usual shape, in one interpolation.
        if items.size == 2
          parent = items[0]
          child = items[1]
          case parent
          when Cybertrain::Model
            case child
            when Cybertrain::Model
              parent_key = model_key(parent)
              return route("#{parent_key}_#{route_key_of(model_key(child))}_path", [parent], options) if child.new_record?

              return route("#{parent_key}_#{model_key(child)}_path", [parent, child], options)
            end
          end
        end
        # while, not each_with_index: a block capturing items, name and
        # route_args costs three heap cells on every call, the two-item
        # ones above included (docs/performance-next.md 9).
        name = +""
        route_args = []
        i = 0
        while i < items.size
          item = items[i]
          case item
          when Cybertrain::Model
            last = i == items.size - 1
            if last && item.new_record?
              name << route_key_of(model_key(item))
            else
              name << model_key(item)
              route_args << item
            end
            name << "_" unless last
          # A namespace ([:admin, article] -> admin_article_path): a name
          # part only, no route argument.
          when Symbol
            name << FormBuilder.value_text(item)
            name << "_" unless i == items.size - 1
          else raise ArgumentError, "url_for expects records in a nested route"
          end
          i += 1
        end
        route("#{name}_path", route_args, options)
      end

      def model_key(record)
        model_name = record.model_name
        key = @model_keys[model_name]
        return key unless key.nil?

        key = Inflector.underscore(model_name)
        @model_keys[model_name] = key
        key
      end

      # "comments/_comment.html.erb" for render "comments/comment" (or
      # "comment" from a comments/ template), remembered like model_key.
      # Ending in .erb, it is used by Engine#template as is.
      def partial_file(dir, name)
        by_name = @partial_files[dir]
        if by_name.nil?
          by_name = { "" => "" }
          by_name.delete("")
          @partial_files[dir] = by_name
        end
        file = by_name[name]
        return file unless file.nil?

        path = Helpers.partial_path(dir, name)
        file = path.end_with?(".erb") ? path : "#{path}.html.erb"
        by_name[name] = file
        file
      end

      # Helpers.route_key, remembered for this request like model_key.
      def route_key_of(singular)
        key = @route_keys[singular]
        return key unless key.nil?

        key = Helpers.route_key(singular)
        @route_keys[singular] = key
        key
      end

      # --- pagination ----------------------------------------------------------

      # paginate @page, articles_path: the Newer / Older links of a Page
      # (Relation#page) around "Page N", in a <nav class="pager">. Each link
      # is the path plus the current request's query string with `page`
      # replaced (page 1 drops it), so a search or filter survives paging; a
      # path that carries its own query string ("/search?q=x") uses that one
      # instead. A link is left out when there is no such page. Everything
      # is escaped (the href by Html.escape, the query re-encoded by
      # Query.without_key).
      def paginate(args)
        page = arg(args, 0, "paginate")
        path = url_for(arg(args, 1, "paginate"), @no_url_options)
        case page
        when Cybertrain::Page then pager_html(page, path)
        else raise ArgumentError, "paginate expects a Page (from Relation#page), got #{FormBuilder.value_text(page)}"
        end
      end

      def pager_html(page, path)
        q = path.index("?")
        base = q.nil? ? path : path[0, q].to_s
        # The current query string when there is a request; a pager in a
        # broadcast partial (no request) carries only the path's own query.
        query = q.nil? ? current_query_string : path[(q + 1)..-1].to_s
        rest = Query.without_key(query, "page")
        buf = +"<nav class=\"pager\">"
        if page.prev?
          href = Html.escape(pager_href(base, rest, page.prev_number))
          buf << "<a href=\"" << href << "\" rel=\"prev\">Newer</a> "
        end
        buf << "<span class=\"pager-current\">Page " << page.number.to_s << "</span>"
        if page.next?
          href = Html.escape(pager_href(base, rest, page.next_number))
          buf << " <a href=\"" << href << "\" rel=\"next\">Older</a>"
        end
        buf << "</nav>"
        SafeString.of(buf)
      end

      # base?rest&page=n, without page= for page 1 and without "?" when
      # nothing is left.
      def pager_href(base, rest, n)
        query = rest
        if n > 1
          number = "page=#{n}"
          query = rest.empty? ? number : "#{rest}&#{number}"
        end
        query.empty? ? base : "#{base}?#{query}"
      end

      # `@page.next?` and the other Page readers in a template.
      def page_method(page, sym, name)
        case sym
        when :number then page.number
        when :per then page.per
        when :row_offset then page.row_offset
        when :next? then page.next?
        when :prev? then page.prev?
        when :next_number then page.next_number
        when :prev_number then page.prev_number
        else raise ArgumentError, "undefined method '#{name}' for Page"
        end
      end

      # --- tag, content_tag, safe_join, dom_id --------------------------------

      # tag.div(class: "c"), tag.span("text"), tag.my_widget (<my-widget>),
      # tag.div do ... end: the method name is the element, the keyword
      # arguments its attributes (Html.tag's rules), the one positional
      # argument or the block's output its content.
      def tag_builder_call(name_str, args, kwargs, block, interp, env)
        raise ArgumentError, "tag.#{name_str} takes at most one positional argument (the content)" if args.size > 1

        element = name_str.tr("_", "-")
        if block.nil?
          return Html.build_tag(element, kwargs, "", false) if args.empty? || args[0].nil?

          return Html.build_tag(element, kwargs, Html.content_html(args[0]), true)
        end
        Html.build_tag(element, kwargs, interp.capture(block, env), true)
      end

      # content_tag "p", "text", class: "x" / content_tag :p, class: "x" do ... end
      def content_tag(args, kwargs, block, interp, env)
        element = text_arg(args, 0, "content_tag")
        raise ArgumentError, "content_tag takes a name and at most one content argument" if args.size > 2

        if block.nil?
          return Html.build_tag(element, kwargs, "", false) if args.size < 2 || args[1].nil?

          return Html.build_tag(element, kwargs, Html.content_html(args[1]), true)
        end
        Html.build_tag(element, kwargs, interp.capture(block, env), true)
      end

      # class_names("btn", active: on): the keyword arguments are one more
      # { name => condition } Hash, as in Rails.
      def class_names(args, kwargs)
        return Html.class_names_of(args) if kwargs.empty?

        values = []
        args.each { |a| values << a }
        values << kwargs
        Html.class_names_of(values)
      end

      def no_kwargs(kwargs, name)
        return nil if kwargs.empty?

        given = Array.new(0) { "" }
        kwargs.each_key { |k| given << "#{k}:" }
        raise CallSyntaxError, "#{name} takes no keyword arguments (got #{given.join(", ")})"
      end

      # safe_join(items, sep = ""): Html.safe_join.
      def safe_join(args)
        items = arg(args, 0, "safe_join")
        sep = args.size > 1 ? args[1] : ""
        case items
        when Time then nil
        when Array then return Html.safe_join(items, sep)
        end
        raise ArgumentError, "safe_join expects an Array, got #{FormBuilder.value_text(items)}"
      end

      # dom_id(record) / dom_id(record, "edit"): Html.dom_id.
      def dom_id(args)
        record = arg(args, 0, "dom_id")
        prefix = args.size > 1 ? text_arg(args, 1, "dom_id") : ""
        case record
        when Cybertrain::Model then return Html.dom_id(record, prefix)
        end
        raise ArgumentError, "dom_id expects a record, got #{FormBuilder.value_text(record)}"
      end

      # --- partials and content_for ----------------------------------------

      # render "form", post: @post  /  render partial: "form", locals: { post: @post }
      # The partial sees a copy of the environment plus its locals; what it
      # adds with content_for is copied back. Not named render_partial:
      # Controller#render_partial returns nil, and two same-named methods
      # with different return types emptied `kwargs` here once both were in
      # one program (spikes/NOTES.md rules 34 and 41).
      #
      # With collection: (an Array), the partial once per item, as the local
      # named by as: (the partial's own name by default) with
      # `<as>_counter` from 0 (to a partial with strict locals only when it
      # declares it), locals: given to each, and spacer_template: (a
      # partial) between items; an empty collection renders "". `render
      # @comments` renders each record's comments/_comment the same way, and
      # `render @comment` one record.
      def render_helper(args, kwargs, interp, env)
        locals = kwargs
        name = ""
        if args.empty?
          name = FormBuilder.value_text(kwargs["partial"])
          raise ArgumentError, "render needs a partial name" if name.empty?

          given = kwargs["locals"]
          case given
          when Hash then locals = given
          when nil then locals = {}
          else raise ArgumentError, "render locals: must be a Hash"
          end
          return render_collection(name, kwargs, locals, interp, env) if kwargs.key?("collection")
        else
          first = args[0]
          case first
          # Time before Array (spikes/NOTES.md rule 8).
          when Time then nil
          when Array, Cybertrain::Model
            helper_arity!("render", args, 1, 1)
            helper_no_keywords!("render", kwargs)
            return render_records(first, interp, env)
          end
          name = text_arg(args, 0, "render")
        end
        engine = Views.engine
        raise ArgumentError, "no views configured (Cybertrain::Views.configure)" if engine.nil?

        template = engine.template(partial_file(FormBuilder.value_text(env["__template_dir"]), name))
        names = []
        locals.each_key { |key| names << key if !(args.empty? && (key == "partial" || key == "locals")) }
        render_partial_scope(template, locals, names, interp, env)
      end

      # render partial:, collection:, as:, spacer_template:, locals:.
      def render_collection(name, kwargs, locals, interp, env)
        items = kwargs["collection"]
        case items
        when Time then nil
        when Array
          return SafeString.of("") if items.empty?

          slash = name.rindex("/")
          as_name = slash.nil? ? name : name[slash + 1, name.size - slash - 1].to_s
          as_name = FormBuilder.value_text(kwargs["as"]) if kwargs.key?("as")
          spacer = ""
          if kwargs.key?("spacer_template")
            no_locals = { "" => [nil, 0, 0.0, "", true][0] }
            no_locals.delete("")
            spacer = partial_html(FormBuilder.value_text(kwargs["spacer_template"]), no_locals, interp, env).to_s
          end
          return render_items(name, as_name, items, locals, spacer, interp, env)
        end
        msg = "render collection: must be an Array, got #{FormBuilder.value_text(items)}"
        raise ArgumentError, msg
      end

      # `render @comments` (each record's <route key>/_<singular>) and
      # `render @comment`.
      def render_records(value, interp, env)
        out = +""
        no_locals = { "" => [nil, 0, 0.0, "", true][0] }
        no_locals.delete("")
        case value
        when Cybertrain::Model
          key = record_partial_local(value)
          # One object: no counter, as in Rails.
          html = render_item(record_partial(value, key), key, value, -1, no_locals, interp, env)
          out << html.to_s
        when Array
          i = 0
          while i < value.size
            record = value[i]
            case record
            when Time then record_expected!(record)
            when Cybertrain::Model
              key = record_partial_local(record)
              # One item at a time: the records may be of different models.
              html = render_item(record_partial(record, key), key, record, i, no_locals, interp, env)
              out << html.to_s
            else record_expected!(record)
            end
            i += 1
          end
        end
        SafeString.of(out)
      end

      def record_expected!(value)
        msg = "render expects records in a collection, got #{FormBuilder.value_text(value)}"
        raise ArgumentError, msg
      end

      # "comment" for a Comment, "note" for an Admin::Note.
      def record_partial_local(record)
        key = model_key(record)
        slash = key.rindex("/")
        slash.nil? ? key : key[slash + 1, key.size - slash - 1].to_s
      end

      # "comments/comment" for a Comment, "admin/notes/note" for an
      # Admin::Note (ActiveModel's to_partial_path).
      def record_partial(record, local)
        key = model_key(record)
        slash = key.rindex("/")
        plural = Inflector.pluralize(local)
        return "#{plural}/#{local}" if slash.nil?

        "#{key[0, slash]}/#{plural}/#{local}"
      end

      # The partial once per item, spacer between.
      def render_items(name, as_name, items, locals, spacer, interp, env)
        out = +""
        i = 0
        while i < items.size
          out << spacer if i > 0
          html = render_item(name, as_name, items[i], i, locals, interp, env)
          out << html.to_s
          i += 1
        end
        SafeString.of(out)
      end

      # One item: locals, then the item as `as_name`, then `<as_name>_counter`
      # (index; none when it is -1) unless the partial's strict locals leave
      # it out.
      def render_item(name, as_name, item, index, locals, interp, env)
        engine = Views.engine
        raise ArgumentError, "no views configured (Cybertrain::Views.configure)" if engine.nil?

        template = engine.template(partial_file(FormBuilder.value_text(env["__template_dir"]), name))
        counter = "#{as_name}_counter"
        scoped = { "" => [nil, 0, 0.0, "", true][0] }
        scoped.delete("")
        locals.each_key { |key| scoped[key] = locals[key] }
        scoped[as_name] = item
        scoped[counter] = index if index >= 0 && (!template.strict_locals? || Helpers.name_in?(template.locals, counter))
        names = Array.new(0) { "" }
        scoped.each_key { |key| names << key }
        render_partial_scope(template, scoped, names, interp, env)
      end

      # The partial template with `names` of locals added to a copy of env.
      def render_partial_scope(template, locals, names, interp, env)
        Helpers.check_locals(template, names)
        scope = env.dup
        i = 0
        while i < names.size
          key = names[i]
          scope[key] = locals[key]
          i += 1
        end
        html = ""
        if @components.empty?
          html = interp.render(template, scope)
        else
          # A partial rendered from a component's template is not the
          # component's: a base Component (no view methods) on top of the
          # stack keeps the component's methods out of its names.
          component_push(Component.new)
          begin
            html = interp.render(template, scope)
          ensure
            component_pop
          end
        end
        scope.each_key { |key| env[key] = scope[key] if key.start_with?("__content_") }
        SafeString.of(html)
      end

      # render component: "card", title: "x" [do ... end]: the component the
      # app's Gen::Components.build makes from the other keywords (through
      # Views.component_builder), rendered with the block's output as its
      # content.
      def render_component_helper(kwargs, block, interp, env)
        name = FormBuilder.value_text(kwargs["component"])
        attrs = { "" => [nil, 0, 0.0, "", true][0] }
        attrs.delete("")
        kwargs.each_key { |key| attrs[key] = kwargs[key] unless key == "component" }
        built = Views.component_builder.call(name, attrs)
        content = block.nil? ? "" : interp.capture(block, env)
        # The case types the builder's result (a lambda's value is
        # polymorphic) before the method call.
        case built
        when Cybertrain::Component then built.render_with(self, content, interp)
        else raise Component::Unknown, "component_builder returned no component for '#{name}'"
        end
      end

      # content_for :title do ... end  or  content_for :title, "text";
      # the layout reads it back with <%= yield :title %>.
      def content_for(args, block, interp, env)
        key = "__content_#{text_arg(args, 0, "content_for")}"
        piece = ""
        if block.nil?
          piece = to_html(arg(args, 1, "content_for"))
        else
          piece = interp.capture(block, env)
        end
        before = env[key]
        env[key] = SafeString.of(before.nil? ? piece : "#{FormBuilder.value_text(before)}#{piece}")
        ""
      end

      # --- i18n (spec 8) ------------------------------------------------------

      # t(key, **options), as Rails' view helper: I18n.t, with a key
      # starting with "." looked up under the rendering template's name
      # (lazy lookup, plan decision D8: "posts/_form.html.erb" ->
      # "posts.form.title"). A key ending in `_html` or `.html` answers
      # its text as HTML, every interpolated value escaped (a SafeString
      # value as it is); any other text is escaped. A missing key answers
      # `<span class="translation_missing" title="translation missing:
      # en.posts.index.subtitle">Subtitle</span>` (development and test),
      # or the humanised last segment (production), or raises
      # (I18n.raise_on_missing).
      # @return [SafeString]
      def translate_helper(args, kwargs, interp)
        helper_arity!("t", args, 1, 1)
        key = text_arg(args, 0, "t")
        if key.start_with?(".")
          scope = Helpers.lazy_scope(interp.current_template_name)
          if scope.empty?
            msg = "t: the lazy key #{key.inspect} needs a template name"
            raise ArgumentError, msg
          end
          key = "#{scope}#{key}"
        end
        options = Helpers.symbol_options(kwargs)
        html = I18n.html_key?(key)
        options = Helpers.escaped_interpolations(options) if html
        found = I18n.find_translation(key, options)
        unless found.nil?
          return SafeString.of(found) if html

          return SafeString.of(Html.escape(found))
        end
        text = I18n.missing_answer(I18n.option_locale(options), key)
        return SafeString.of(Html.escape(text)) unless I18n.mark_missing?

        dot = key.rindex(".")
        last = dot.nil? ? key : key[dot + 1, key.size - dot - 1].to_s
        words = Helpers.titleized(last)
        SafeString.of("<span class=\"translation_missing\" title=\"#{Html.escape(text)}\">#{Html.escape(words)}</span>")
      end

      # l(time_or_date, format: :short), as Rails' view helper: I18n.l
      # in the current locale (`format:` a Symbol or a pattern, `locale:`).
      # The text is escaped by the template.
      # @return [String]
      def localize_helper(args, kwargs)
        helper_arity!("l", args, 1, 1)
        options = Helpers.symbol_options(kwargs)
        format = options[:format]
        case format
        when SafeString then options[:format] = format.to_s
        end
        I18n.l(args[0], options)
      end

      # A template's keywords as I18n's options (Symbol keys).
      def self.symbol_options(kwargs)
        options = { default: [nil, 0, 0.0, "", true][0] }
        options.delete(:default)
        kwargs.each { |name, value| options[name.to_sym] = value }
        options
      end

      # The options of an `_html` key's lookup, as Rails' html-safe
      # translation escapes them: every interpolation value escaped (a
      # SafeString as it is), I18n's own `default:` and `locale:` and an
      # Integer `count:` untouched. Shared with Controller#t.
      # @param options [Hash{Symbol => Object}]
      # @return [Hash{Symbol => Object}]
      def self.escaped_interpolations(options)
        out = { default: [nil, 0, 0.0, "", true][0] }
        out.delete(:default)
        options.each do |name, value|
          if name == :default || name == :locale || (name == :count && value.is_a?(Integer))
            out[name] = value
          else
            case value
            when SafeString then out[name] = value.to_s
            else out[name] = Html.escape(FormBuilder.value_text(value))
            end
          end
        end
        out
      end

      # The lazy-lookup scope of a template name (D8, Rails' virtual path):
      # "posts/index.html.erb" -> "posts.index", "posts/_form.html.erb" ->
      # "posts.form", "__components/card_component.html.erb" ->
      # "card_component", "admin/posts/show" -> "admin.posts.show".
      # @param name [String]
      # @return [String]
      def self.lazy_scope(name)
        s = name.to_s
        prefix = Engine::COMPONENTS_PREFIX
        s = s[prefix.size, s.size - prefix.size].to_s if s.start_with?(prefix)
        slash = s.rindex("/")
        dir = slash.nil? ? "" : s[0, slash].to_s
        base = slash.nil? ? s : s[slash + 1, s.size - slash - 1].to_s
        base = base[1, base.size - 1].to_s if base.start_with?("_")
        dot = base.index(".")
        base = base[0, dot].to_s unless dot.nil?
        return base if dir.empty?

        "#{dir.tr("/", ".")}.#{base}"
      end

      # "bar_baz" -> "Bar Baz": the words of a missing key's last segment,
      # as Rails' translation_missing span shows them (titleize).
      def self.titleized(segment)
        words = segment.to_s.tr("_", " ").split(" ")
        out = Array.new(0) { "" }
        words.each { |w| out << w.capitalize }
        out.join(" ")
      end

      # --- text --------------------------------------------------------------

      def pluralize(args)
        count = arg(args, 0, "pluralize")
        word = text_arg(args, 1, "pluralize")
        n = 0
        case count
        when Integer then n = count
        else n = int_text(count)
        end
        return "#{n} #{word}" if n == 1

        args.size > 2 ? "#{n} #{text_arg(args, 2, "pluralize")}" : "#{n} #{Inflector.pluralize(word)}"
      end

      def plural_words(n, word)
        n == 1 ? "#{n} #{word}" : "#{n} #{word}s"
      end

      # truncate(text, length: 30, omission: "...").
      def truncate(args, kwargs)
        text = text_arg(args, 0, "truncate")
        length = kwargs["length"].nil? ? 30 : int_text(kwargs["length"])
        omission = kwargs["omission"].nil? ? "..." : FormBuilder.value_text(kwargs["omission"])
        return text if text.length <= length

        keep = length - omission.length
        keep = 0 if keep < 0
        "#{text[0, keep]}#{omission}"
      end

      # The number helpers are Cybertrain::NumberHelper's, with Rails'
      # keywords: 1234567 -> "1,234,567"; 1234.5 -> "1,234.5".
      # nil renders "" in a template (as in Rails and 0.4: a nullable column
      # prints nothing); NumberHelper's module functions, called from Ruby,
      # raise ArgumentError for nil. Any other non-number raises in both.
      def number_with_delimiter(args, kwargs)
        helper_arity!("number_with_delimiter", args, 1, 1)
        helper_keywords!("number_with_delimiter", kwargs, ["delimiter", "separator"], 0)
        return "" if args[0].nil?

        delimiter = kwargs["delimiter"].nil? ? "," : FormBuilder.value_text(kwargs["delimiter"])
        separator = kwargs["separator"].nil? ? "." : FormBuilder.value_text(kwargs["separator"])
        NumberHelper.number_with_delimiter(args[0], delimiter: delimiter, separator: separator)
      end

      def number_with_precision(args, kwargs)
        helper_arity!("number_with_precision", args, 1, 1)
        helper_keywords!("number_with_precision", kwargs, ["precision", "delimiter", "separator", "strip_insignificant_zeros"], 0)
        return "" if args[0].nil?

        precision = kwargs["precision"].nil? ? 3 : int_text(kwargs["precision"])
        delimiter = kwargs["delimiter"].nil? ? "" : FormBuilder.value_text(kwargs["delimiter"])
        separator = kwargs["separator"].nil? ? "." : FormBuilder.value_text(kwargs["separator"])
        strip = kwargs["strip_insignificant_zeros"] == true
        NumberHelper.number_with_precision(args[0], precision: precision, delimiter: delimiter, separator: separator, strip_insignificant_zeros: strip)
      end

      # units: { thousand: "lt" } is a template Hash (String keys).
      def number_to_human(args, kwargs)
        helper_arity!("number_to_human", args, 1, 1)
        helper_keywords!("number_to_human", kwargs, ["precision", "units"], 0)
        return "" if args[0].nil?

        precision = kwargs["precision"].nil? ? 3 : int_text(kwargs["precision"])
        names = NumberHelper::UNIT_NAMES.dup
        given = kwargs["units"]
        case given
        when Hash
          i = 0
          while i < NumberHelper::UNIT_KEYS.length
            key = NumberHelper::UNIT_KEYS[i].to_s
            names[i] = FormBuilder.value_text(given[key]) if given.key?(key)
            i += 1
          end
        when nil then nil
        else raise ArgumentError, "number_to_human units: must be a Hash"
        end
        NumberHelper.human_text(args[0], precision, names)
      end

      def number_to_percentage(args, kwargs)
        helper_arity!("number_to_percentage", args, 1, 1)
        helper_keywords!("number_to_percentage", kwargs, ["precision"], 0)
        return "" if args[0].nil?

        precision = kwargs["precision"].nil? ? 3 : int_text(kwargs["precision"])
        NumberHelper.number_to_percentage(args[0], precision: precision)
      end

      def number_to_currency(args, kwargs)
        helper_arity!("number_to_currency", args, 1, 1)
        helper_keywords!("number_to_currency", kwargs, ["unit", "precision", "format"], 0)
        return "" if args[0].nil?

        unit = kwargs["unit"].nil? ? "$" : FormBuilder.value_text(kwargs["unit"])
        precision = kwargs["precision"].nil? ? 2 : int_text(kwargs["precision"])
        fmt = kwargs["format"].nil? ? "%u%n" : FormBuilder.value_text(kwargs["format"])
        NumberHelper.number_to_currency(args[0], unit: unit, precision: precision, format: fmt)
      end

      def number_to_human_size(args, kwargs)
        helper_arity!("number_to_human_size", args, 1, 1)
        helper_no_keywords!("number_to_human_size", kwargs)
        return "" if args[0].nil?

        NumberHelper.number_to_human_size(args[0])
      end

      # A value for HTML: SafeString as is, anything else escaped.
      def to_html(v)
        FormBuilder.html_text(v)
      end

      # --- streams (turbo-rails' names) ----------------------------------------

      # turbo_stream_from "alerts", @article: a <turbo-stream-source> whose
      # src is the stream endpoint with one signed token for all the names
      # (a String as it is, a record as Stream.name_for gives it). Turbo
      # opens it as an EventSource; `ws: true` gives a ws:// (wss:// behind
      # an https proxy) URL instead, built from the request, which Turbo
      # opens as a WebSocket.
      # The token is in the URL, so a proxy's access log sees it (the
      # framework's own request log writes it as [FILTERED]); anyone holding
      # it can read those streams.
      def turbo_stream_from(args, kwargs)
        token = signed_stream_name(args)
        src = +""
        src << stream_ws_base if kwargs["ws"] == true
        src << Helpers.stream_endpoint_path
        src << "?s="
        src << token
        escaped = Html.escape(src)
        SafeString.of("<turbo-stream-source src=\"#{escaped}\"></turbo-stream-source>")
      end

      # turbo_frame_tag @article, src: article_path(@article), loading: "lazy",
      # target: "_top" do ... end: `<turbo-frame id="article_3" src="..."
      # loading="lazy" target="_top">...</turbo-frame>`. The id is a String
      # or a record's dom_id; each attribute is written only when given
      # (class: and data: too), escaped once (a SafeString as it is).
      def turbo_frame_tag(args, kwargs, block, interp, env)
        helper_arity!("turbo_frame_tag", args, 1, 1)
        helper_keywords!("turbo_frame_tag", kwargs, TURBO_FRAME_KEYWORDS, 0)
        target = args[0]
        out = +"<turbo-frame"
        case target
        when Cybertrain::Model then out << FormBuilder.attr_html("id", Html.dom_id(target, ""))
        else out << FormBuilder.attr_html("id", target)
        end
        kwargs.each_key { |key| out << FormBuilder.attr_html(key, kwargs[key]) }
        out << ">"
        out << interp.capture(block, env) unless block.nil?
        out << "</turbo-frame>"
        SafeString.of(out)
      end

      # time_tag(time, text = nil, format: nil): `<time datetime="...">text
      # </time>`. A Time's datetime is its xmlschema
      # (`2026-11-10T12:00:00Z`), a Date's `2026-11-10`. The text is `text`
      # (escaped unless a SafeString), else the block's output, else the
      # value in `format:` (:short, :long or a strftime String; by default
      # `Tue, 10 Nov 2026 12:00:00 +0000` for a Time, `2026-11-10` for a
      # Date). class:, id:, title: and data: are attributes.
      def time_tag(args, kwargs, block, interp, env)
        helper_arity!("time_tag", args, 1, block.nil? ? 2 : 1)
        helper_keywords!("time_tag", kwargs, TIME_TAG_KEYWORDS, 0)
        value = args[0]
        format = kwargs["format"]
        datetime = ""
        text = ""
        case value
        when Time
          # xmlschema: "Z" for UTC, else the offset with a colon ("+09:00"),
          # which strftime's %z does not write.
          offset = value.utc_offset
          stamp = value.strftime("%Y-%m-%dT%H:%M:%S")
          datetime = offset == 0 ? "#{stamp}Z" : "#{stamp}#{Helpers.offset_text(offset, ":")}"
          if args.size < 2 && block.nil?
            if format.nil?
              text = value.strftime("%a, %d %b %Y %H:%M:%S %z")
            else
              pattern = Helpers.time_tag_pattern(format, "", "%d %b %H:%M", "%B %d, %Y %H:%M")
              text = Helpers.time_tag_strftime(value, pattern)
            end
          end
        when Date
          datetime = value.strftime("%Y-%m-%d")
          pattern = Helpers.time_tag_pattern(format, "%Y-%m-%d", "%b %d", "%B %d, %Y")
          text = Helpers.time_tag_strftime(value, pattern) if args.size < 2 && block.nil?
        else
          msg = "time_tag expects a Time or a Date, got #{FormBuilder.value_text(value)}"
          raise ArgumentError, msg
        end
        out = +"<time"
        out << FormBuilder.attr_html("datetime", datetime)
        kwargs.each_key { |key| out << FormBuilder.attr_html(key, kwargs[key]) unless key == "format" }
        out << ">"
        if args.size > 1
          out << to_html(args[1])
        elsif !block.nil?
          out << interp.capture(block, env)
        else
          out << Html.escape(text)
        end
        out << "</time>"
        SafeString.of(out)
      end

      # strftime of a pattern that is not a literal: Cybertrain::Strftime.walk
      # (spikes/NOTES.md rule 96), which formats one directive at a time with
      # literal patterns; its refusals read "time_tag format: ...".
      # I18n.l formats its dictionary patterns through the same walk.
      # @param time [Time, Date]
      # @param pattern [String]
      # @return [String]
      def self.time_tag_strftime(time, pattern) = Strftime.walk(time, pattern, "time_tag format")

      # The strftime pattern of time_tag's format: (nil: the default).
      # Interpolated, so that strftime gets a plain String.
      def self.time_tag_pattern(format, default, short, long)
        case format
        when nil then return default
        when :short then return short
        when :long then return long
        when SafeString then return "#{format.to_s}"
        when String then return "#{format}"
        end
        msg = "time_tag format: must be :short, :long or a strftime String, got #{FormBuilder.value_text(format)}"
        raise ArgumentError, msg
      end

      # "+0900" / "-05:30" for an offset in seconds.
      def self.offset_text(seconds, sep)
        sign = seconds < 0 ? "-" : "+"
        abs = seconds.abs
        hours = abs / 3600
        minutes = (abs % 3600) / 60
        hh = hours < 10 ? "0#{hours}" : "#{hours}"
        mm = minutes < 10 ? "0#{minutes}" : "#{minutes}"
        "#{sign}#{hh}#{sep}#{mm}"
      end

      # current_page?("/articles"): whether this GET or HEAD request is for
      # that path (a trailing slash aside); with a query in the argument
      # ("/articles?page=2") the query must match too. A record or an Array
      # goes through url_for. False on any other method, and without a
      # request.
      def current_page?(args, kwargs)
        helper_arity!("current_page?", args, 1, 1)
        helper_no_keywords!("current_page?", kwargs)
        request_bound!("current_page?")
        controller = @controller
        return false if controller.nil?

        req = controller.request
        return false unless req.get? || req.head?

        url = url_for(args[0], @no_url_options)
        base = req.base_url
        url = url.byteslice(base.bytesize, url.bytesize - base.bytesize).to_s if !base.empty? && url.start_with?(base)
        return false if url.start_with?("http://") || url.start_with?("https://")

        q = url.index("?")
        path = q.nil? ? url : url[0, q].to_s
        return false unless Helpers.same_path?(path, req.path)
        return true if q.nil?

        query = url[q + 1, url.size - q - 1].to_s
        query == req.query_string.to_s
      end

      # "/articles/" and "/articles" are the same page; "/" is itself.
      def self.same_path?(a, b)
        x = a.size > 1 && a.end_with?("/") ? a[0, a.size - 1].to_s : a
        y = b.size > 1 && b.end_with?("/") ? b[0, b.size - 1].to_s : b
        x == y
      end

      # The signed token naming the streams, for hand-written JavaScript.
      def signed_stream_name(args)
        raise ArgumentError, "signed_stream_name needs at least one stream" if args.empty?

        names = Array.new(0) { "" }
        i = 0
        while i < args.size
          value = args[i]
          case value
          when Cybertrain::Model then names << Stream.name_for(value)
          else names << FormBuilder.value_text(value)
          end
          i += 1
        end
        Stream.sign(names)
      end

      # The endpoint URL with the token and `mode=json` (or mode: "raw"),
      # for an EventSource or WebSocket written by hand.
      def stream_source_path(args, kwargs)
        mode = kwargs["mode"].nil? ? "json" : lower_text(kwargs["mode"])
        raise ArgumentError, "stream_source_path mode: must be \"json\" or \"raw\", got #{mode.inspect}" unless mode == "json" || mode == "raw"

        token = signed_stream_name(args)
        out = +""
        out << Helpers.stream_endpoint_path
        out << "?s="
        out << token
        out << "&mode="
        out << mode
        out
      end

      def self.stream_endpoint_path
        path = Cybertrain.config.stream_path
        raise ArgumentError, "the stream endpoint is off (Config#stream_path is \"\")" if path.empty?

        path
      end

      # "ws://host" from the request's base URL ("wss://" for https).
      def stream_ws_base
        # Raises OutsideRequest when rendering outside a request (B's rule);
        # the nil check below is the fallback for a bare Helpers.new(nil).
        request_bound!("turbo_stream_from")
        controller = @controller
        raise Views::OutsideRequest, "turbo_stream_from ws: true needs a request" if controller.nil?

        base = controller.request.base_url
        return "wss://#{base.byteslice(8, base.bytesize - 8)}" if base.start_with?("https://")

        "ws://#{base.byteslice(7, base.bytesize - 7)}"
      end

      # --- request state ------------------------------------------------------

      # The request-bound readers below raise Views::OutsideRequest when
      # these helpers render outside a request (request_bound!), whether a
      # template or a Ruby helper calls them; a nil controller otherwise
      # answers "" and empty values.
      def csrf_meta_tags
        request_bound!("csrf_meta_tags")
        token = session_csrf_token
        return SafeString.of("") if token.empty?

        SafeString.of("<meta name=\"csrf-param\" content=\"authenticity_token\">\n<meta name=\"csrf-token\" content=\"#{Html.escape(token)}\">")
      end

      # The session's token, minted on first use; "" without a session.
      def csrf_token
        request_bound!("csrf_token")
        session_csrf_token
      end

      # csrf_token without the request check: forms (hidden_fields) render
      # outside a request too, without a token.
      def session_csrf_token
        controller = @controller
        return "" if controller.nil?

        session = controller.session
        return "" if session.nil?

        session.csrf_token!
      end

      # This request's Content Security Policy nonce (Context#csp_nonce),
      # "" when no policy applies (none declared) or there is no controller.
      def content_security_policy_nonce
        request_bound!("content_security_policy_nonce")
        controller = @controller
        return "" if controller.nil?

        ctx = controller.ctx
        return "" if ctx.csp_policy.nil?

        ctx.csp_nonce
      end

      # `<meta name="csp-nonce" content="...">` for scripts that add
      # elements (Turbo reads it); "" when no policy applies.
      def csp_meta_tag
        nonce = content_security_policy_nonce
        return SafeString.of("") if nonce.empty?

        SafeString.of("<meta name=\"csp-nonce\" content=\"#{Html.escape(nonce)}\">")
      end

      # `javascript_tag(nonce: true) do ... end`: the block's output in a
      # `<script>`, with this request's nonce when `nonce: true` and a
      # policy applies. The content may instead be one String argument,
      # written as given (not escaped, as in Rails: never put request data
      # in it). id:, type: and data: are attributes.
      def javascript_tag(args, kwargs, block, interp, env)
        helper_arity!("javascript_tag", args, 0, block.nil? ? 1 : 0)
        helper_keywords!("javascript_tag", kwargs, ["nonce", "id", "type", "data"], 0)
        content = block.nil? ? (args.empty? ? "" : text_arg(args, 0, "javascript_tag")) : interp.capture(block, env)
        attrs = { "" => [nil, 0, 0.0, "", true][0] }
        attrs.delete("")
        kwargs.each_key { |key| attrs[key] = kwargs[key] unless key == "nonce" }
        if kwargs["nonce"] == true
          nonce = content_security_policy_nonce
          attrs["nonce"] = nonce unless nonce.empty?
        end
        Html.build_tag("script", attrs, content, true)
      end

      # --- assets (spec 7.2, 7.3) -------------------------------------------

      # asset_path("logo.svg") -> "/assets/logo-1a2b3c4d.svg" (Assets.path:
      # an unknown name raises in development and test). A URL or a path
      # starting with `/` comes back as given, as from the tag helpers.
      def asset_path(name)
        asset_source(name, "")
      end

      # A source as a tag helper writes it: a URL with a scheme (or `//`)
      # as written; else ext added when the name lacks it (Rails'
      # ASSET_EXTENSIONS; "" for none), then a path starting with `/` as
      # written and anything else digested.
      def asset_source(source, ext)
        return source if Helpers.url_with_scheme?(source)

        name = ext.empty? || source.end_with?(ext) ? source : "#{source}#{ext}"
        return name if name.start_with?("/")

        Assets.path(name)
      end

      # A URL a tag helper writes as given, as Rails' URI_REGEXP has it:
      # "https://x" (a scheme then "://"), "//cdn/x", "data:..." or "cid:...".
      # "javascript:x" is not one, so it is looked up as an asset name.
      def self.url_with_scheme?(source)
        s = source.to_s
        return true if s.start_with?("//")

        n = s.bytesize
        i = 0
        while i < n
          b = s.getbyte(i)
          if b == 58
            return false if i == 0

            scheme = s[0, i].to_s.downcase
            return scheme == "data" || scheme == "cid" || s[i + 1, 2].to_s == "//"
          end
          letter = (b >= 97 && b <= 122) || (b >= 65 && b <= 90)
          ok = i == 0 ? letter : (letter || (b >= 48 && b <= 57) || b == 43 || b == 45 || b == 46)
          return false unless ok

          i += 1
        end
        false
      end

      # The nonce attribute: ` nonce="..."` when nonce is true and a policy
      # applies, else "".
      def nonce_attr(nonce)
        return "" unless nonce == true

        value = content_security_policy_nonce
        value.empty? ? "" : FormBuilder.attr_html("nonce", value)
      end

      # stylesheet_link_tag("application", media: "print", nonce: true):
      # `<link rel="stylesheet" href="/assets/application-1a2b3c4d.css"
      # media="print" nonce="...">` (".css" added when missing).
      def stylesheet_link_tag(args, kwargs)
        helper_arity!("stylesheet_link_tag", args, 1, 1)
        helper_keywords!("stylesheet_link_tag", kwargs, STYLESHEET_KEYWORDS, 0)
        href = asset_source(text_arg(args, 0, "stylesheet_link_tag"), ".css")
        out = +"<link rel=\"stylesheet\""
        out << FormBuilder.attr_html("href", href)
        out << FormBuilder.text_attr("media", kwargs["media"]) unless FormBuilder.value_text(kwargs["media"]).empty?
        out << nonce_attr(kwargs["nonce"])
        out << ">"
        SafeString.of(out)
      end

      # javascript_include_tag("legacy", nonce: true):
      # `<script src="/assets/legacy-1a2b3c4d.js" nonce="..."></script>`
      # (".js" added when missing).
      def javascript_include_tag(args, kwargs)
        helper_arity!("javascript_include_tag", args, 1, 1)
        helper_keywords!("javascript_include_tag", kwargs, JAVASCRIPT_INCLUDE_KEYWORDS, 0)
        src = asset_source(text_arg(args, 0, "javascript_include_tag"), ".js")
        out = +"<script"
        out << FormBuilder.attr_html("src", src)
        out << nonce_attr(kwargs["nonce"])
        out << "></script>"
        SafeString.of(out)
      end

      # image_tag("logo.svg", alt: "Logo", size: "16x16", class: "x"):
      # `<img src="/assets/logo-1a2b3c4d.svg" alt="Logo" width="16"
      # height="16" class="x">`. A source starting with `/` or a scheme is
      # used as written; no alt is made up, but alt: "" is written as
      # `alt=""`; size: is "WxH" or "N" (another
      # shape is ignored, as in Rails).
      def image_tag(args, kwargs)
        helper_arity!("image_tag", args, 1, 1)
        helper_keywords!("image_tag", kwargs, IMAGE_TAG_KEYWORDS, 0)
        src = asset_source(text_arg(args, 0, "image_tag"), "")
        out = +"<img"
        out << FormBuilder.attr_html("src", src)
        # alt: "" is written (a decorative image); an absent or nil alt: is not.
        out << FormBuilder.text_attr("alt", kwargs["alt"]) unless kwargs["alt"].nil?
        size = FormBuilder.value_text(kwargs["size"])
        x = size.index("x")
        width = x.nil? ? size : size[0, x].to_s
        height = x.nil? ? size : size[x + 1, size.size - x - 1].to_s
        if Helpers.dimension?(width) && Helpers.dimension?(height)
          out << FormBuilder.attr_html("width", width)
          out << FormBuilder.attr_html("height", height)
        end
        out << FormBuilder.text_attr("class", kwargs["class"]) unless FormBuilder.value_text(kwargs["class"]).empty?
        out << ">"
        SafeString.of(out)
      end

      # Rails' image size part: digits, optionally "." and digits ("16", "1.5").
      def self.dimension?(text)
        s = text.to_s
        n = s.bytesize
        return false if n == 0

        i = 0
        dot = -1
        while i < n
          b = s.getbyte(i)
          if b == 46
            return false if dot >= 0 || i == 0 || i == n - 1

            dot = i
          elsif b < 48 || b > 57
            return false
          end
          i += 1
        end
        true
      end

      # javascript_importmap_tags("application"): the import map, a
      # modulepreload link per preloaded pin and the entry point's import,
      # each with this request's nonce when a policy applies (spec C-5).
      def javascript_importmap_tags(entry)
        request_bound!("javascript_importmap_tags")
        nonce = nonce_attr(true)
        out = +"<script type=\"importmap\" data-turbo-track=\"reload\""
        out << nonce << ">" << Assets.importmap_json << "</script>"
        Assets.preload_paths.each do |path|
          out << "\n<link rel=\"modulepreload\"" << FormBuilder.attr_html("href", path) << nonce << ">"
        end
        out << "\n<script type=\"module\"" << nonce << ">import " << Helpers.js_string(entry) << "</script>"
        SafeString.of(out)
      end

      # text as a JavaScript string literal that can sit inside <script>:
      # `"`, `\` and control characters escaped, `<` written \u003c.
      def self.js_string(text)
        s = text.to_s
        out = +"\""
        n = s.bytesize
        i = 0
        start = 0
        while i < n
          b = s.getbyte(i)
          if b == 34 || b == 92 || b == 60 || b < 32 || b == 127
            out << s.byteslice(start, i - start) if i > start
            if b == 34 then out << "\\\""
            elsif b == 92 then out << "\\\\"
            else
              out << "\\u00" << JS_HEX[b / 16].to_s << JS_HEX[b % 16].to_s
            end
            start = i + 1
          end
          i += 1
        end
        out << s.byteslice(start, n - start) if n > start
        out << "\""
        out
      end

      def flash_messages
        request_bound!("flash")
        controller = @controller
        controller.nil? ? Helpers.flash_messages(nil) : Helpers.flash_messages(controller.flash)
      end

      def params
        request_bound!("params")
        controller = @controller
        controller.nil? ? Params.new : controller.params
      end

      def request_path
        request_bound!("request_path")
        controller = @controller
        controller.nil? ? "" : controller.request.path
      end

      def request_query_string
        request_bound!("request_query_string")
        current_query_string
      end

      # The query string, "" without a request (does not raise).
      def current_query_string
        controller = @controller
        controller.nil? ? "" : controller.request.query_string.to_s
      end

      # --- arguments ----------------------------------------------------------

      def arg(args, i, name)
        raise ArgumentError, "wrong number of arguments for '#{name}'" if args.size <= i

        args[i]
      end

      def text_arg(args, i, name)
        FormBuilder.value_text(arg(args, i, name))
      end

      # `method: :DELETE` -> "delete"; `length: "10"` -> 10. The text is bound
      # to a local before the second call (see I18n.humanize_attribute).
      # text.downcase, without the copy for an already lowercase method:.
      def lower_text(v)
        case v
        when Symbol then HeaderName.lower(v.to_s) # a Symbol's text is not copied
        else HeaderName.lower(FormBuilder.value_text(v))
        end
      end

      def int_text(v)
        text = FormBuilder.value_text(v)
        text.to_i
      end

      # Link and button text: escaped unless it is already a SafeString.
      def html_arg(args, i, name)
        to_html(arg(args, i, name))
      end

      def time_arg(args, i, name)
        t = arg(args, i, name)
        case t
        when Time then return t
        end
        raise ArgumentError, "'#{name}' expects a Time"
      end
    end
  end
end
