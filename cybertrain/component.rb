# Cybertrain::Component -- a view component in ViewComponent's shape: a
# class under app/components with keyword arguments, and a template beside
# it (spec 3.2).
#
#   class CardComponent < Cybertrain::Component
#     def initialize(title:, value: 0)
#       @title = title
#       @value = value
#     end
#
#     def value_text = @value.to_s
#   end
#
# app/components/card_component.html.erb sees the component's instance
# variables as locals (`title`), its parameterless public methods by name
# (`value_text`) and `content`, the block a template passed. `spin run gen`
# writes the per-class tables (gen/components.rb): view_assigns,
# call_view_method / view_method?, component_name, component_template, and
# Gen::Components.build, which `render component: "card", title: "x"`
# reaches through Views.component_builder (Spinel has no `send` or
# `const_get`, spikes/NOTES.md rule 1).
require "cybertrain/html"
require "cybertrain/views"
require "cybertrain/template/interpreter"
require "cybertrain/generator/inflector"

module Cybertrain
  # @api public
  class Component
    # No component of that name: `render component: "nope"`. The class
    # itself (Component::Unknown < StandardError) is defined in
    # cybertrain/template/interpreter.rb, which lets it through unwrapped.

    # The instance variables the template reads, by name. Typed empty Hash
    # of polymorphic values (spikes/NOTES.md rules 9, 71); gen/components.rb
    # overrides it.
    # @api public
    def view_assigns
      out = { "" => [nil, 0, 0.0, "", true][0] }
      out.delete("")
      out
    end

    # A parameterless public method, by name (gen/components.rb); nil here.
    # @api public
    def call_view_method(name)
      nil
    end

    # Whether call_view_method answers `name` (a String, as the template
    # names it).
    def view_method?(name)
      false
    end

    # "card" for CardComponent, "admin/user_row" for Admin::UserRowComponent:
    # the name `render component:` uses. gen/components.rb spells it out
    # per class (under Spinel Class#name has no namespace, rule 46).
    # @api public
    def component_name
      Component.name_for(self.class.name)
    end

    # The template, as a Views engine name (under
    # Template::Engine::COMPONENTS_PREFIX, apart from the views).
    def component_template
      "__components/#{component_name}_component.html.erb"
    end

    # The block a template passed (`render component: "card" do ... end`),
    # "" when there was none. Subclasses do not call super in initialize,
    # so it may never have been assigned.
    # @api public
    def content
      c = @content
      return SafeString.of("") if c.nil?

      c
    end

    # @api public
    def content=(html)
      @content = SafeString.of(html.to_s)
    end

    # Renders the component's template on interp (so its depth counts
    # toward max_render_depth, as a partial's does), without a layout.
    # While it renders, helpers answer the component's view methods by name.
    def render_with(helpers, content, interp)
      engine = Views.engine
      raise ArgumentError, "no views configured (Cybertrain::Views.configure)" if engine.nil?

      self.content = content
      env = { "__template_dir" => [nil, 0, 0.0, "", true][3] }
      env["__template_dir"] = "__components"
      assigns = view_assigns
      keys = assigns.keys
      i = 0
      while i < keys.size
        env[keys[i]] = assigns[keys[i]]
        i += 1
      end
      env["content"] = self.content
      template = engine.template(component_template)
      html = ""
      helpers.component_push(self)
      begin
        html = interp.render(template, env)
      ensure
        helpers.component_pop
      end
      SafeString.of(html)
    end

    # "Admin::UserRowComponent" -> "admin/user_row".
    def self.name_for(class_name)
      under = Inflector.underscore(class_name)
      under.end_with?("_component") ? under[0, under.size - 10].to_s : under
    end

    # The keyword check of a generated construction arm: `required` names
    # come first in `known`.
    def self.check_keywords!(name, kwargs, known, required)
      i = 0
      while i < required
        raise ArgumentError, "missing keyword '#{known[i]}' for component '#{name}'" unless kwargs.key?(known[i])

        i += 1
      end
      kwargs.each_key do |key|
        found = false
        j = 0
        while j < known.size
          found = true if known[j] == key
          j += 1
        end
        raise ArgumentError, "unknown keyword '#{key}' for component '#{name}' (known: #{known.join(", ")})" unless found
      end
      nil
    end

    # `render component: "comment", collection: x` takes no other keyword:
    # each item is built from the item alone (and its counter), so another
    # keyword would be dropped. ArgumentError names the others.
    # @api private
    def self.check_collection_keywords!(name, kwargs)
      others = Array.new(0) { "" }
      kwargs.each_key { |key| others << key unless key == "collection" }
      return nil if others.empty?

      msg = "component '#{name}' with collection: takes no other keyword (given #{others.join(", ")})"
      raise ArgumentError, msg
    end
  end

  # A component rendered once per item, ViewComponent's
  # `CommentComponent.with_collection(@comments)`: gen/components.rb writes
  # `with_collection` for a component whose only required keyword is named
  # after it (`comment:`), and its build arm answers `render component:
  # "comment", collection: @comments` with one. Each item is built through
  # {Views.component_builder} as that keyword, with `comment_counter:` (0,
  # 1, ...) when the component declares it, and the outputs are joined; an
  # empty collection renders "".
  #
  #   Cybertrain::Views.render_component(CommentComponent.with_collection(comments))
  #
  # A Component itself, so that a build arm and {Views.render_component}
  # take it where they take any component.
  # @api public
  class ComponentCollection < Component
    # @param name [String] the component's name ("comment", "admin/row")
    # @param keyword [String] its collection keyword ("comment", "row")
    # @param items [Array] the items
    # @param counter [Boolean] whether it declares `<keyword>_counter:`
    def initialize(name, keyword, items, counter)
      @name = name
      @keyword = keyword
      @counter = counter
      # Typed Array of polymorphic values (spikes/NOTES.md rule 9).
      @items = Array.new(0) { [nil, 0, 0.0, "", true][0] }
      case items
      # Time before Array (spikes/NOTES.md rule 8).
      when Time then ComponentCollection.not_an_array!(items)
      when Array then items.each { |item| @items << item }
      else ComponentCollection.not_an_array!(items)
      end
    end

    def self.not_an_array!(items)
      msg = "render component: collection: must be an Array, got #{items}"
      raise ArgumentError, msg
    end

    def component_name
      @name
    end

    # Each item's component, rendered on interp, joined.
    # @return [SafeString]
    # @api public
    def render_collection_with(helpers, interp)
      out = +""
      i = 0
      while i < @items.size
        kwargs = { "" => [nil, 0, 0.0, "", true][0] }
        kwargs.delete("")
        kwargs[@keyword] = @items[i]
        kwargs["#{@keyword}_counter"] = i if @counter
        # A fresh local, not the ivar: Spinel refuses an ivar's String
        # handed to a proc that could append to it.
        name = "#{@name}"
        built = Views.component_builder.call(name, kwargs)
        case built
        when Cybertrain::Component
          html = built.render_with(helpers, "", interp)
          out << html.to_s
        else raise Component::Unknown, "component_builder returned no component for '#{@name}'"
        end
        i += 1
      end
      SafeString.of(out)
    end

    # What {Views.render_component} and `render component:` call: the
    # collection (a block's content is not passed to the items).
    def render_with(helpers, content, interp)
      render_collection_with(helpers, interp)
    end
  end
end
