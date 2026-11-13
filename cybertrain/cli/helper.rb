# `cybertrain generate helper prices`: writes app/helpers/prices_helper.rb
# (an empty `module PricesHelper`, which `spin run gen` includes into the
# app's ApplicationHelpers) and test/helpers/prices_helper_test.rb. A name may carry a
# namespace ("admin/users" -> Admin::UsersHelper in
# app/helpers/admin/users_helper.rb).
#
# Shared with `generate component` (cli/component.rb): GeneratedFiles, the
# writer that refuses to overwrite an existing, different file unless
# --force.
require "cybertrain/generator/inflector"
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"

module Cybertrain
  module CLI
    module GeneratedFiles
      # files: [path, content] pairs. Checks every path before writing any:
      # one that exists with other content raises InvalidArgument unless
      # force. Returns the paths it created or overwrote.
      def self.write_all(root, files, force)
        files.each do |pair|
          full = File.join(root, pair[0])
          next unless File.exist?(full)
          next if force || File.read(full) == pair[1]

          raise InvalidArgument, "#{pair[0]} already exists (pass --force to overwrite it)"
        end
        written = Array.new(0) { "" }
        files.each do |pair|
          full = File.join(root, pair[0])
          if File.exist?(full)
            if File.read(full) == pair[1]
              puts "identical #{pair[0]}"
              next
            end
            File.write(full, pair[1])
            puts "force #{pair[0]}"
          else
            Templates.mkdir_p(File.dirname(full))
            File.write(full, pair[1])
            puts "create #{pair[0]}"
          end
          written << pair[0]
        end
        written
      end

      def self.require_app!(root)
        routes = File.join(root, "config/routes.rb")
        raise InvalidArgument, "#{routes} not found: run this inside a cybertrain app" unless File.exist?(routes)

        nil
      end

      # "admin/user_row" -> ["admin", "user_row"], each segment checked.
      def self.name_segments(name, what)
        segments = Inflector.underscore(name).split("/")
        raise InvalidArgument, "bad #{what} name '#{name}'" if segments.empty?

        segments.each do |seg|
          raise InvalidArgument, "bad #{what} name '#{name}'" unless Templates.identifier?(seg)
        end
        segments
      end

      # `module Admin` lines around a body, indented.
      def self.nest(modules, body)
        out = +""
        depth = 0
        modules.each do |m|
          out << ("  " * depth) << "module #{m}\n"
          depth += 1
        end
        body.each_line do |line|
          out << ("  " * depth) unless line == "\n"
          out << line
        end
        while depth > 0
          depth -= 1
          out << ("  " * depth) << "end\n"
        end
        out
      end
    end

    module Helper
      # Returns the paths written.
      def self.generate(root, name, force = false)
        GeneratedFiles.require_app!(root)

        segments = GeneratedFiles.name_segments(name.delete_suffix("_helper"), "helper")
        segments[segments.size - 1] = "#{segments.last}_helper"
        modules = segments.map { |s| Inflector.camelize(s) }
        full = modules.join("::")
        rel = segments.join("/")
        files = [
          ["app/helpers/#{rel}.rb", module_source(modules)],
          ["test/helpers/#{rel}_test.rb", test_source(full, rel)]
        ]
        GeneratedFiles.write_all(root, files, force)
      end

      def self.module_source(modules)
        body = +""
        body << "module #{modules.last}\n"
        body << "  # Helpers here are callable from every template once `spin run gen`\n"
        body << "  # has run: `def price(value, unit: \"USD\")` is `<%= price 3, unit: \"EUR\" %>`.\n"
        body << "  # Parameters are named (no *rest / **opts); values arrive as the\n"
        body << "  # template's values, so narrow them with Cybertrain::Cast. Build HTML\n"
        body << "  # with Cybertrain::Html.escape / SafeString.of, link_to_path and the\n"
        body << "  # *_path helpers.\n"
        body << "end\n"
        GeneratedFiles.nest(modules[0, modules.size - 1], body)
      end

      # The class-form test. Its template-rendering helper is
      # render_helper_template: render_inline is the framework's (component
      # and partial tests).
      def self.test_source(full, rel)
        out = +""
        out << "require \"test_helper\"\n"
        out << "\n"
        out << "# app/helpers/#{rel}.rb, through the app's ApplicationHelpers (gen/helpers.rb).\n"
        out << "class #{full}Test < ActiveSupport::TestCase\n"
        out << "  test \"#{full} is in the application's helpers\" do\n"
        out << "    assert_equal \"ApplicationHelpers\", Cybertrain::Views.helpers_builder.call(nil).class.name\n"
        out << "    assert_equal \"&lt;b&gt;\", render_helper_template(\"<%= h '<b>' %>\")\n"
        out << "  end\n"
        out << "\n"
        out << "  private\n"
        out << "\n"
        out << "  # A template rendered with the application's helpers.\n"
        out << "  def render_helper_template(source)\n"
        out << "    template = Cybertrain::Template::Template.parse(source, \"test/inline\")\n"
        out << "    env = { \"__template_dir\" => \"test\" }\n"
        out << "    Cybertrain::Template::Interpreter.new(Cybertrain::Views.helpers_builder.call(nil)).render(template, env)\n"
        out << "  end\n"
        out << "end\n"
        out
      end
    end
  end
end
