# `cybertrain generate component card title value:integer`: writes
# app/components/card_component.rb (a Cybertrain::Component with one
# keyword per attribute), its template app/components/card_component.html.erb
# (each attribute, then the block's content) and
# test/components/card_component_test.rb (a ViewComponent::TestCase that
# renders it with render_inline and checks it with assert_select). A name
# may carry a namespace ("admin/user_row" -> Admin::UserRowComponent).
require "cybertrain/generator/inflector"
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/helper"

module Cybertrain
  module CLI
    module Component
      TYPES = %w[string text integer float boolean]

      # Names Cybertrain::Component itself answers in a template or defines.
      RESERVED = %w[content view_assigns call_view_method view_method component_name component_template render_with initialize]

      # Returns the paths written.
      def self.generate(root, name, attrs, force = false)
        GeneratedFiles.require_app!(root)
        segments = GeneratedFiles.name_segments(name.delete_suffix("_component"), "component")
        segments[segments.size - 1] = "#{segments.last}_component"
        modules = segments.map { |s| Inflector.camelize(s) }
        full = modules.join("::")
        rel = segments.join("/")
        names = Array.new(0) { "" }
        types = Array.new(0) { "" }
        attrs.each do |arg|
          parts = arg.split(":")
          attr = parts[0].to_s
          type = parts.size > 1 ? parts[1].to_s : "string"
          raise InvalidArgument, "bad attribute '#{arg}': use name[:type]" if parts.size > 2
          raise InvalidArgument, "bad attribute name '#{attr}'" unless Templates.identifier?(attr)
          raise InvalidArgument, "unknown type '#{type}' for #{attr} (use #{TYPES.join(", ")})" unless TYPES.include?(type)
          raise InvalidArgument, "'#{attr}' is a name Cybertrain::Component already uses; pick another attribute" if RESERVED.include?(attr)
          raise InvalidArgument, "'#{attr}' is a Ruby keyword and cannot name an attribute" if Ident.unusable_reason(attr) == "keyword"
          raise InvalidArgument, "duplicate attribute '#{attr}'" if names.include?(attr)

          names << attr
          types << type
        end
        files = [
          ["app/components/#{rel}.rb", class_source(modules, names)],
          ["app/components/#{rel}.html.erb", template_source(segments.last, names)],
          ["test/components/#{rel}_test.rb", test_source(full, segments.last, names, types)]
        ]
        GeneratedFiles.write_all(root, files, force)
      end

      def self.class_source(modules, names)
        body = +""
        body << "class #{modules.last} < Cybertrain::Component\n"
        if names.empty?
          body << "  # Keyword parameters of initialize are what `render component:` passes;\n"
          body << "  # each @ivar is a local of the template beside this file.\n"
        else
          body << "  def initialize(#{names.map { |n| "#{n}:" }.join(", ")})\n"
          names.each { |n| body << "    @#{n} = #{n}\n" }
          body << "  end\n"
        end
        body << "end\n"
        GeneratedFiles.nest(modules[0, modules.size - 1], body)
      end

      def self.template_source(file_name, names)
        css = file_name.delete_suffix("_component").tr("_", "-")
        out = +""
        out << "<div class=\"#{css}\">\n"
        names.each { |n| out << "  <p><%= #{n} %></p>\n" }
        out << "  <%= content %>\n"
        out << "</div>\n"
        out
      end

      def self.sample(type)
        case type
        when "integer" then "1"
        when "float" then "1.5"
        when "boolean" then "true"
        else ""
        end
      end

      # The class-form test: render_inline, then assert_select on each
      # attribute's paragraph and on the content.
      def self.test_source(full, file_name, names, types)
        css = file_name.delete_suffix("_component").tr("_", "-")
        args = Array.new(0) { "" }
        expected = Array.new(0) { "" }
        names.each_with_index do |n, i|
          value = sample(types[i])
          if value == ""
            args << "#{n}: \"#{Templates.humanize(n)}\""
            expected << Templates.humanize(n)
          else
            args << "#{n}: #{value}"
            expected << value
          end
        end
        call = args.empty? ? "#{full}.new" : "#{full}.new(#{args.join(", ")})"
        out = +""
        out << "require \"test_helper\"\n"
        out << "\n"
        out << "class #{full}Test < ViewComponent::TestCase\n"
        out << "  test \"renders its attributes and content\" do\n"
        out << "    render_inline(#{call}, content: \"<b>inside</b>\")\n"
        expected.each { |e| out << "    assert_select \"div.#{css} > p\", text: \"#{e}\"\n" }
        out << "    assert_select \"div.#{css} > b\", text: \"inside\"\n"
        out << "  end\n"
        out << "end\n"
        out
      end
    end
  end
end
