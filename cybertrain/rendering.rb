# Cybertrain::Rendering -- what a controller's render is made of: the
# environment a template sees, which template and layout a name and a format
# select, the body of each `render` option, and which format an action that
# rendered nothing answers in.
#
# Controller is the facade (`render`, `respond_to`, `render_template`,
# `partial_body`); it gathers what only it has (its instance variables, its
# directory, the layout its `layout` lines choose, the helpers built around
# it) and hands the values here. Nothing in this file names a controller, a
# callback or a response: every method takes plain values and returns a body
# or a decision, which Controller writes to its response (docs/design.md
# D70).
#
# Module functions, not an object per request: a render allocates nothing
# for the collaborator. The names are this module's own (spikes/NOTES.md
# rules 10, 34, 41: one return type per method name across the program).
require "json"
require "cybertrain/html"
require "cybertrain/views"
require "cybertrain/template/helpers"
require "cybertrain/http/request"

module Cybertrain
  class MissingTemplate < StandardError
  end

  # @api private
  module Rendering
    # What a template sees: the controller's assigns, then the locals
    # (extra, keyed by String), then flash (a Hash of the current messages),
    # params and the directory partials are looked up in.
    # @param assigns [Hash{String => Object}] the instance variables
    # @param extra [Hash{String => Object}] the locals ({.stringify_locals})
    # @param flash [Flash, nil]
    # @param params [Params]
    # @param dir [String] the controller's view directory ("posts")
    # @return [Hash{String => Object}]
    def self.page_env(assigns, extra, flash, params, dir)
      env = {}
      # keys + while: an each_key block is a Proc and closure per request.
      assign_keys = assigns.keys
      i = 0
      while i < assign_keys.size
        env[assign_keys[i]] = assigns[assign_keys[i]]
        i += 1
      end
      extra_keys = extra.keys
      i = 0
      while i < extra_keys.size
        env[extra_keys[i]] = extra[extra_keys[i]]
        i += 1
      end
      env["flash"] = Template::Helpers.flash_messages(flash)
      env["params"] = params
      env["__template_dir"] = dir
      env["__controller_path"] = dir
      env
    end

    # `locals: { post: @post }` comes with Symbol keys; templates look
    # names up by String.
    # @param locals [Hash{Symbol => Object}]
    # @return [Hash{String => Object}]
    def self.stringify_locals(locals)
      out = {}
      keys = locals.keys
      i = 0
      while i < keys.size
        out[keys[i].to_s] = locals[keys[i]]
        i += 1
      end
      out
    end

    # <dir>/<name> rendered for `format`. For `:html` the template is
    # <name>.html.erb inside `layout` ("" for none): the default layout
    # ({Views.layout_name}) is used only when it exists, any other layout
    # that does not exist is a MissingTemplate. For any other format it is
    # <name>.<format>.erb, never in a layout (layouts are HTML).
    # @param owner [String] the controller's class name, for the messages
    # @param dir [String] the controller's view directory
    # @param name [String] the template's name in it
    # @param env [Hash{String => Object}] {.page_env}'s
    # @param helpers [Template::Helpers]
    # @param layout [String] the layout's name, "" for none
    # @param format [Symbol]
    # @return [String] the body
    # @raise [MissingTemplate] without views, or for a missing named layout
    # @raise [Template::MissingTemplate] when the template does not exist
    def self.page_body(owner, dir, name, env, helpers, layout, format)
      engine = Views.engine
      if engine.nil?
        message = "no template #{name} for #{owner}"
        raise MissingTemplate, message
      end

      return engine.render(format_template(dir, name, format), env, helpers) unless format == :html

      path = "#{dir}/#{name}"
      return engine.render(path, env, helpers) if layout.empty?
      return engine.render_with_layout(path, layout, env, helpers) if engine.exists?(layout)
      # The default layout is optional: without it, pages render bare.
      return engine.render(path, env, helpers) if layout == Views.layout_name

      # A layout a `layout` line or `render layout:` named: a typo must not
      # render every page bare without a word.
      message = "missing layout #{layout} for #{owner}"
      raise MissingTemplate, message
    end

    # The partial `name` ("form" in `dir`, "comments/comment" in another
    # directory) rendered as HTML, its strict locals checked against the
    # ones given.
    # @param owner [String] the controller's class name, for the message
    # @param dir [String] the controller's view directory
    # @param name [String]
    # @param given [Hash{String => Object}] the locals ({.stringify_locals})
    # @param env [Hash{String => Object}] {.page_env}'s, holding them
    # @param helpers [Template::Helpers]
    # @return [String]
    # @raise [MissingTemplate] when no views are configured
    def self.partial_html(owner, dir, name, given, env, helpers)
      engine = Views.engine
      if engine.nil?
        message = "no partial #{name} for #{owner}"
        raise MissingTemplate, message
      end

      path = Template::Helpers.partial_path(dir, name)
      Template::Helpers.check_locals(engine.template(path), given.keys)
      engine.render(path, env, helpers)
    end

    # The format an action that rendered nothing answers in: `wanted` (the
    # request's, or the one a respond_to declaration matched) when it is
    # `:html` or the action has a template for it, `:html` when the request
    # also takes HTML ({.accepts_html?}), else `:none` (406).
    # @param owner [String] the controller's class name, for the message
    # @param dir [String] the controller's view directory
    # @param name [String] the action's name
    # @param wanted [Symbol]
    # @param request [Request]
    # @return [Symbol] a format, or `:none`
    # @raise [MissingTemplate] when no views are configured
    def self.implicit_format(owner, dir, name, wanted, request)
      engine = Views.engine
      if engine.nil?
        message = "no template for #{owner}##{name}"
        raise MissingTemplate, message
      end

      return :html if wanted == :html
      return wanted if wanted != :unknown && engine.exists?(format_template(dir, name, wanted))
      return :html if accepts_html?(request)

      :none
    end

    # Whether a request whose format is not :html also takes HTML: its
    # format came from Accept (no extension asked for that format alone)
    # and Accept lists text/html or */* (Turbo's
    # "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
    # axios' "application/json, text/plain, */*"). Rails lists every format
    # of such a request and answers in the first one the action has.
    # @param request [Request]
    # @return [Boolean]
    def self.accepts_html?(request)
      return false if request.format == :html || !request.format_extension.empty?

      accept = request.header("Accept").to_s
      accept.include?("text/html") || accept.include?("*/*")
    end

    # "articles/index.csv.erb": the template of a format other than html.
    def self.format_template(dir, name, format)
      "#{dir}/#{name}.#{format}.erb"
    end

    # The layout `render layout: name` names: `"layouts/<name>"`, or
    # `name` itself when it already starts with `layouts/` (Rails'
    # `_normalize_layout`), so `layout: "layouts/admin"` is not
    # `layouts/layouts/admin`.
    # @param name [String]
    # @return [String]
    def self.layout_named(name)
      name.start_with?("layouts/") ? name : "layouts/#{name}"
    end

    # What `render json:` sends: a String is taken to be JSON already.
    def self.json_text(value)
      case value
      when String then value
      else JSON.generate(value)
      end
    end

    # What `render turbo_stream:` sends: a SafeString, or an Array of them
    # joined.
    def self.turbo_stream_text(value)
      case value
      when SafeString then return value.to_s
      when String then nil
      # Time before Array (spikes/NOTES.md rule 8).
      when Time then nil
      when Array
        out = +""
        i = 0
        while i < value.size
          out << turbo_stream_item(value[i])
          i += 1
        end
        return out
      end
      turbo_stream_refused(value)
    end

    def self.turbo_stream_item(value)
      case value
      when SafeString then return value.to_s
      end
      turbo_stream_refused(value)
    end

    def self.turbo_stream_refused(value)
      msg = "render turbo_stream: takes a SafeString or an Array of them (turbo_stream.replace and the others build them), got #{value.class.name}"
      raise ArgumentError, msg
    end
  end
end
