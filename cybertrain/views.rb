# Cybertrain::Views -- the process-wide view configuration controllers
# render through: the template Engine, the layout name, and the url_resolver
# that path helpers (`post_path(post)`) call.
#
#   Cybertrain::Views.configure("app/views", cache: false)
#   Cybertrain::Views.url_resolver = ->(name, args) { Gen::Routes.path_for(name, args) }
#
# Module-level instance variables rather than @@class_variables: the latter
# miscompile once an earlier file has opened `module Cybertrain`
# (spikes/NOTES.md rule 18).
require "cybertrain/template/engine"

module Cybertrain
  module Views
    class NoRoutes < StandardError
    end

    # nil until the app configures one; controllers then fall back to the
    # base MissingTemplate errors.
    @engine = nil
    @layout_name = "layouts/application"
    @url_resolver = ->(name, args) { raise NoRoutes, "no routes" }
    # Template::Helpers is defined by cybertrain/template/helpers.rb, which
    # requires this file; the lambda only names it when called. Returned by
    # a method, not written here as a literal: a lambda literal assigned to
    # a module-level ivar never learns its call sites' argument types
    # (spikes/NOTES.md rule 79), so `controller` arrived as an Integer.
    def self.default_helpers_builder
      ->(controller) { Template::Helpers.new(controller) }
    end
    @helpers_builder = default_helpers_builder

    def self.engine
      @engine
    end

    # max_render_depth: how many renders may be open at once (the page and
    # its partials; the layout renders after the page and does not nest);
    # Template::MAX_RENDER_DEPTH (12) unless the
    # app's partials legitimately recurse deeper. Must be at least 1: the
    # engine raises ArgumentError for anything lower.
    def self.configure(root, cache: true, max_render_depth: Template::MAX_RENDER_DEPTH)
      @engine = Template::Engine.new(root, cache: cache, max_render_depth: max_render_depth)
      nil
    end

    # Production: the templates `spin run gen -- --embed-views` compiled in.
    def self.configure_embedded(sources, max_render_depth: Template::MAX_RENDER_DEPTH)
      @engine = Template::Engine.embedded(sources, max_render_depth: max_render_depth)
      nil
    end

    def self.layout_name
      @layout_name
    end

    def self.layout_name=(name)
      @layout_name = name
    end

    # ->(name String, args Array) { String }; installed by the app from the
    # generated Gen::Routes.path_for.
    def self.url_resolver
      @url_resolver
    end

    def self.url_resolver=(resolver)
      @url_resolver = resolver
    end

    # ->(controller Controller | nil) { Template::Helpers }: how controllers
    # and render_partial build the helpers a template calls. gen/helpers.rb
    # sets it to build the app's ApplicationHelpers (spec 3.1).
    def self.helpers_builder
      @helpers_builder
    end

    def self.helpers_builder=(builder)
      @helpers_builder = builder
    end
  end
end
