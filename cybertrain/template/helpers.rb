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
require "cybertrain/html"
require "cybertrain/model"
require "cybertrain/params"
require "cybertrain/views"
require "cybertrain/template/engine"
require "cybertrain/template/form_builder"
require "cybertrain/generator/inflector"

module Cybertrain
  module Template
    class Helpers < HelperBase
      MINUTES_IN_YEAR = 525_600
      MINUTES_IN_QUARTER_YEAR = 131_400
      MINUTES_IN_THREE_QUARTERS_YEAR = 394_200

      def initialize(controller)
        @controller = controller
        # model_name => its underscored route key, for this request only (a
        # page with a list of records asks for the same few names once per
        # link and form). Typed empty Hash: spikes/NOTES.md rule 9.
        @model_keys = { "" => "" }
        @model_keys.delete("")
        @route_keys = { "" => "" }
        @route_keys.delete("")
      end

      def helper_call(name, args, kwargs, block, interp, env)
        case name
        when "link_to" then link_to(args, kwargs)
        when "button_to" then button_to(args, kwargs)
        when "form_with" then form_with(kwargs, block, interp, env)
        when "render" then render_helper(args, kwargs, interp, env)
        when "h", "escape" then SafeString.new(html_arg(args, 0, name))
        when "raw" then SafeString.new(text_arg(args, 0, name))
        when "pluralize" then pluralize(args)
        when "truncate" then truncate(args, kwargs)
        when "number_with_delimiter" then number_with_delimiter(args)
        when "time_ago_in_words" then distance_of_time_in_words(time_arg(args, 0, name), Time.now)
        when "content_for" then content_for(args, block, interp, env)
        when "content_for?" then !env["__content_#{text_arg(args, 0, name)}"].nil?
        when "csrf_meta_tags" then csrf_meta_tags
        when "csrf_token" then csrf_token
        when "flash" then flash_messages
        when "params" then params
        when "request_path" then request_path
        when "url_for" then url_for(arg(args, 0, name))
        else
          return route(name, args) if name.end_with?("_path") || name.end_with?("_url")

          super(name, args, kwargs, block, interp, env)
        end
      end

      # `f.label :title` and the other FormBuilder methods.
      def call_object_method(recv, name_sym, name_str, args, kwargs)
        case recv
        when FormBuilder then recv.call_method(name_sym, args, kwargs)
        else super(recv, name_sym, name_str, args, kwargs)
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

      # --- links and forms ---------------------------------------------------

      # link_to "Show", post_path(post), class: "btn"; the href may also be a
      # record (`link_to post.title, post`). method: needs a form, so it is
      # refused rather than faked with JavaScript.
      def link_to(args, kwargs)
        text = html_arg(args, 0, "link_to")
        href = url_for(arg(args, 1, "link_to"))
        unless kwargs["method"].nil?
          raise ArgumentError, "link_to does not support method: (use button_to '#{text}', path, method: :#{FormBuilder.value_text(kwargs["method"])})"
        end

        buf = +"<a"
        buf << FormBuilder.html_attr("href", href)
        buf << FormBuilder.html_attr("class", FormBuilder.value_text(kwargs["class"])) unless kwargs["class"].nil?
        buf << FormBuilder.html_attr("id", FormBuilder.value_text(kwargs["id"])) unless kwargs["id"].nil?
        buf << FormBuilder.html_attr("data-confirm", FormBuilder.value_text(kwargs["data_confirm"])) unless kwargs["data_confirm"].nil?
        buf << data_attrs(kwargs["data"]) unless kwargs["data"].nil?
        buf << ">" << text << "</a>"
        SafeString.new(buf)
      end

      # A one-button form: POST (with a hidden _method for delete/patch/put)
      # plus the CSRF token, or a plain GET form.
      def button_to(args, kwargs)
        text = html_arg(args, 0, "button_to")
        action = url_for(arg(args, 1, "button_to"))
        verb = kwargs["method"].nil? ? "post" : lower_text(kwargs["method"])
        buf = +"<form class=\"button_to\""
        buf << FormBuilder.html_attr("method", verb == "get" ? "get" : "post")
        buf << FormBuilder.html_attr("action", action)
        buf << ">"
        buf << hidden_fields(verb)
        buf << "<button"
        buf << FormBuilder.html_attr("class", FormBuilder.value_text(kwargs["class"])) unless kwargs["class"].nil?
        buf << data_attrs(kwargs["data"]) unless kwargs["data"].nil?
        buf << " type=\"submit\">" << text << "</button></form>"
        SafeString.new(buf)
      end

      # form_with(model: post) do |f| ... end, form_with(model: [post, comment]),
      # form_with(url: "/search", method: :get). A new record posts to the
      # collection route, a saved one patches its member route.
      def form_with(kwargs, block, interp, env)
        raise ArgumentError, "form_with needs a block (form_with(...) do |f| ... end)" if block.nil?

        model = kwargs["model"]
        record = form_record(model)
        action = kwargs["url"].nil? ? form_action(model) : url_for(kwargs["url"])
        verb = "post"
        if !kwargs["method"].nil?
          verb = lower_text(kwargs["method"])
        elsif !record.nil? && record.persisted?
          verb = "patch"
        end
        buf = +"<form"
        buf << FormBuilder.html_attr("action", action)
        buf << FormBuilder.html_attr("method", verb == "get" ? "get" : "post")
        buf << FormBuilder.html_attr("class", FormBuilder.value_text(kwargs["class"])) unless kwargs["class"].nil?
        buf << ">"
        buf << hidden_fields(verb)
        buf << interp.capture(block, env, FormBuilder.new(record))
        buf << "</form>"
        SafeString.new(buf)
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
      def self.route_key(singular)
        plural = Inflector.pluralize(singular)
        plural == singular ? "#{plural}_index" : plural
      end

      # posts_path / post_path(post); nested: post_comments_path(post).
      def form_action(model)
        case model
        when Cybertrain::Model
          return url_for(model) if model.persisted?

          # Bound step by step (see FormBuilder.humanize).
          route("#{route_key_of(model_key(model))}_path", [])
        when Array then url_for(model)
        else raise ArgumentError, "form_with needs model: or url:"
        end
      end

      # _method for verbs HTML forms cannot send, then the CSRF token for
      # anything but GET (omitted without a session to take it from). Tag
      # builders append what these return rather than passing their buffer
      # down (see FormBuilder.html_attr).
      def hidden_fields(verb)
        out = +""
        return out if verb == "get"

        if verb != "post"
          out << "<input type=\"hidden\" name=\"_method\""
          out << FormBuilder.html_attr("value", verb)
          out << ">"
        end
        token = csrf_token
        unless token.empty?
          out << "<input type=\"hidden\" name=\"authenticity_token\""
          out << FormBuilder.html_attr("value", token)
          out << ">"
        end
        out
      end

      # data: { turbo_confirm: "Sure?" } -> data-turbo-confirm="Sure?".
      def data_attrs(data)
        out = +""
        case data
        when Hash
          data.each_key do |key|
            out << FormBuilder.html_attr("data-#{key.tr("_", "-")}", FormBuilder.value_text(data[key]))
          end
        end
        out
      end

      # --- routes ------------------------------------------------------------

      def route(name, args)
        "#{Views.url_resolver.call(name, args)}"
      end

      # A String is already a URL; a record maps to its member route
      # ("post_path"), a [parent, child] pair to the nested one
      # ("post_comment_path", or "post_comments_path" for a new child).
      def url_for(target)
        case target
        when SafeString then "#{target.to_s}"
        when String then "#{target}"
        when Cybertrain::Model then route("#{model_key(target)}_path", [target])
        when Array then nested_url(target)
        else raise ArgumentError, "url_for cannot build a URL from #{FormBuilder.value_text(target)}"
        end
      end

      def nested_url(items)
        name = +""
        route_args = []
        items.each_with_index do |item, i|
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
          else raise ArgumentError, "url_for expects records in a nested route"
          end
        end
        route("#{name}_path", route_args)
      end

      def model_key(record)
        model_name = record.model_name
        key = @model_keys[model_name]
        return key unless key.nil?

        key = Inflector.underscore(model_name)
        @model_keys[model_name] = key
        key
      end

      # Helpers.route_key, remembered for this request like model_key.
      def route_key_of(singular)
        key = @route_keys[singular]
        return key unless key.nil?

        key = Helpers.route_key(singular)
        @route_keys[singular] = key
        key
      end

      # --- partials and content_for ----------------------------------------

      # render "form", post: @post  /  render partial: "form", locals: { post: @post }
      # The partial sees a copy of the environment plus its locals; what it
      # adds with content_for is copied back. Not named render_partial:
      # Controller#render_partial returns nil, and two same-named methods
      # with different return types emptied `kwargs` here once both were in
      # one program (spikes/NOTES.md rules 34 and 41).
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
        else
          name = text_arg(args, 0, "render")
        end
        engine = Views.engine
        raise ArgumentError, "no views configured (Cybertrain::Views.configure)" if engine.nil?

        template = engine.template(Helpers.partial_path(FormBuilder.value_text(env["__template_dir"]), name))
        names = []
        locals.each_key { |key| names << key if !(args.empty? && (key == "partial" || key == "locals")) }
        Helpers.check_locals(template, names)
        scope = env.dup
        i = 0
        while i < names.size
          key = names[i]
          scope[key] = locals[key]
          i += 1
        end
        html = interp.render(template, scope)
        scope.each_key { |key| env[key] = scope[key] if key.start_with?("__content_") }
        SafeString.new(html)
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
        env[key] = SafeString.new(before.nil? ? piece : "#{FormBuilder.value_text(before)}#{piece}")
        ""
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

      # 1234567 -> "1,234,567"; 1234.5 -> "1,234.5".
      def number_with_delimiter(args)
        text = FormBuilder.value_text(arg(args, 0, "number_with_delimiter"))
        sign = text.start_with?("-") ? "-" : ""
        digits = sign.empty? ? text : text[1, text.length - 1]
        dot = digits.index(".")
        whole = dot.nil? ? digits : digits[0, dot]
        fraction = dot.nil? ? "" : digits[dot, digits.length - dot]
        out = +""
        i = 0
        while i < whole.length
          out << "," if i > 0 && (whole.length - i) % 3 == 0
          out << whole[i]
          i += 1
        end
        "#{sign}#{out}#{fraction}"
      end

      # A value for HTML: SafeString as is, anything else escaped.
      def to_html(v)
        FormBuilder.html_text(v)
      end

      # --- request state ------------------------------------------------------

      def csrf_meta_tags
        token = csrf_token
        return SafeString.new("") if token.empty?

        SafeString.new("<meta name=\"csrf-param\" content=\"authenticity_token\">\n<meta name=\"csrf-token\" content=\"#{Html.escape(token)}\">")
      end

      # The session's token, minted on first use; "" without a session.
      def csrf_token
        controller = @controller
        return "" if controller.nil?

        session = controller.session
        return "" if session.nil?

        session.csrf_token!
      end

      def flash_messages
        controller = @controller
        controller.nil? ? Helpers.flash_messages(nil) : Helpers.flash_messages(controller.flash)
      end

      def params
        controller = @controller
        controller.nil? ? Params.new : controller.params
      end

      def request_path
        controller = @controller
        controller.nil? ? "" : controller.request.path
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
      # to a local before the second call (see FormBuilder.humanize).
      def lower_text(v)
        text = FormBuilder.value_text(v)
        text.downcase
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
