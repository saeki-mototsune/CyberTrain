# Cybertrain::Views -- the process-wide view configuration controllers
# render through: the template Engine, the layout name, and the url_resolver
# that path helpers (`post_path(post)`) call.
#
#   Cybertrain::Views.configure("app/views", cache: false)
#   Cybertrain::Views.url_resolver = ->(name, args, options) { Gen::Routes.path_for(name, args, options) }
#
# Module-level instance variables rather than @@class_variables: the latter
# miscompile once an earlier file has opened `module Cybertrain`
# (spikes/NOTES.md rule 18).
require "cybertrain/template/engine"

module Cybertrain
  module Views
    class NoRoutes < StandardError
    end

    # OutsideRequest (a request-bound helper outside a request) is defined
    # in cybertrain/template/interpreter.rb, which this file requires.

    # nil until the app configures one; controllers then fall back to the
    # base MissingTemplate errors.
    @engine = nil
    @layout_name = "layouts/application"
    @url_resolver = ->(name, args, options) { raise NoRoutes, "no routes" }
    # Template::Helpers is defined by cybertrain/template/helpers.rb, which
    # requires this file; the lambda only names it when called. Returned by
    # a method, not written here as a literal: a lambda literal assigned to
    # a module-level ivar never learns its call sites' argument types
    # (spikes/NOTES.md rule 82), so `controller` arrived as an Integer.
    # @api private
    def self.default_helpers_builder
      ->(controller) { Template::Helpers.new(controller) }
    end
    @helpers_builder = default_helpers_builder

    # The default component_builder: gen/components.rb replaces it with
    # Gen::Components.build. Component is defined by cybertrain/component.rb
    # (required by the helpers), named only when called.
    # @api private
    def self.default_component_builder
      ->(name, kwargs) { raise Component::Unknown, "no component '#{name}' (app/components/#{name}_component.rb, then `spin run gen`)" }
    end
    @component_builder = default_component_builder

    def self.engine
      @engine
    end

    # max_render_depth: how many renders may be open at once (the page and
    # its partials; the layout renders after the page and does not nest);
    # Template::MAX_RENDER_DEPTH (12) unless the
    # app's partials legitimately recurse deeper. Must be at least 1: the
    # engine raises ArgumentError for anything lower.
    # components_root: where `render component:` templates live; "" means
    # the `components` directory beside root (app/components for app/views).
    def self.configure(root, cache: true, max_render_depth: Template::MAX_RENDER_DEPTH, components_root: "")
      @engine = Template::Engine.new(root, cache: cache, max_render_depth: max_render_depth, components_root: components_root)
      nil
    end

    # Production: the templates `spin run gen -- --embed-views` compiled in,
    # all parsed now (`eager`), or each when first rendered ({Template::Engine.embedded}).
    def self.configure_embedded(sources, max_render_depth: Template::MAX_RENDER_DEPTH, eager: true)
      @engine = Template::Engine.embedded(sources, max_render_depth: max_render_depth, eager: eager)
      nil
    end

    def self.layout_name
      @layout_name
    end

    def self.layout_name=(name)
      @layout_name = name
    end

    # ->(name String, args Array, options Hash{String => Object}) { String };
    # installed by the app from the generated Gen::Routes.path_for. options
    # are the template's keywords (`post_path(post, page: 2)`), which
    # Gen.with_options turns into the format, query string and anchor.
    def self.url_resolver
      @url_resolver
    end

    def self.url_resolver=(resolver)
      @url_resolver = resolver
    end

    # ->(controller Controller | nil) { Template::Helpers }: how controllers
    # and render_partial build the helpers a template calls. gen/helpers.rb
    # sets it to build the app's ApplicationHelpers (spec 3.1).
    # @api public
    def self.helpers_builder
      @helpers_builder
    end

    # @api public
    def self.helpers_builder=(builder)
      @helpers_builder = builder
    end

    # ->(name String, kwargs Hash<String, polymorphic>) { Component }: how
    # `render component: "card", title: "x"` builds the component.
    # @api public
    def self.component_builder
      @component_builder
    end

    # @api public
    def self.component_builder=(builder)
      @component_builder = builder
    end

    # A partial rendered with no request (a broadcast, a mail body):
    #
    #   Cybertrain::Views.render_partial("articles/article", article: article)
    #
    # "articles/article" is app/views/articles/_article.html.erb. The
    # helpers are the app's (helpers_builder) with no controller: path
    # helpers work (url_resolver is process-wide), the request-bound ones
    # (csrf_token, csrf_meta_tags, params, flash, request_path, *_url)
    # raise OutsideRequest. Strict locals are checked as in a request.
    # @return [String]
    # @api public
    def self.render_partial(name, locals = {})
      render_detached(name, locals, "")
    end

    # render_partial, inside `layout` unless it is "".
    def self.render_detached(name, locals, layout)
      engine = configured_engine
      helpers = detached_helpers
      slash = name.rindex("/")
      dir = slash.nil? ? "" : name[0, slash].to_s
      path = slash.nil? ? "_#{name}" : Template::Helpers.partial_path(dir, name)
      env = { "__template_dir" => [nil, 0, 0.0, "", true][3] }
      env["__template_dir"] = dir
      given = Array.new(0) { "" }
      keys = locals.keys
      i = 0
      while i < keys.size
        key = keys[i].to_s
        given << key
        env[key] = locals[keys[i]]
        i += 1
      end
      Template::Helpers.check_locals(engine.template(path), given)
      return engine.render(path, env, helpers).to_s if layout.empty?

      engine.render_with_layout(path, layout, env, helpers).to_s
    end

    # The layout {.render_mail} wraps a mail partial in, when it exists.
    MAIL_LAYOUT = "layouts/mail"

    # A mail body rendered with no request: the partial as
    # {.render_partial} renders it, wrapped in
    # `app/views/layouts/mail.html.erb` (its `<%= yield %>`) when the views
    # have that layout, else the partial alone.
    #
    #   html = Cybertrain::Views.render_mail("mail/welcome", user: user)
    #   Cybertrain::Mailer.deliver_later(to: user.email, subject: "Welcome", body: text, html: html)
    #
    # "mail/welcome" is app/views/mail/_welcome.html.erb.
    # @param name [String] the partial, as for {.render_partial}
    # @param locals [Hash] its locals
    # @return [String]
    # @api public
    def self.render_mail(name, locals = {})
      layout = configured_engine.exists?(MAIL_LAYOUT) ? MAIL_LAYOUT : ""
      render_detached(name, locals, layout)
    end

    # A component rendered with no request, `content` (HTML, not escaped)
    # as its block:
    #
    #   Cybertrain::Views.render_component(CardComponent.new(title: "x"))
    # @return [String]
    # @api public
    def self.render_component(component, content = "")
      engine = configured_engine
      helpers = detached_helpers
      component.render_with(helpers, content, engine.interpreter(helpers)).to_s
    end

    def self.configured_engine
      engine = @engine
      raise ArgumentError, "no views configured (Cybertrain::Views.configure)" if engine.nil?

      engine
    end

    def self.detached_helpers
      helpers = @helpers_builder.call(nil)
      helpers.outside_request!
      helpers
    end
  end
end
