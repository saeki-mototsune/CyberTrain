require "cybertrain/generator/inflector"
require "cybertrain/generator/controller_scan"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/helper_scan"

module Cybertrain
  module Gen
    # What the lexical scan found in one app/components file.
    class ComponentInfo
      attr_reader :file, :class_name, :superclass_name, :ivars, :view_methods, :keywords_required, :keywords_optional, :template

      # template: the Views engine name of its .html.erb
      # ("components/card_component.html.erb").
      def initialize(file, class_name, superclass_name, ivars, view_methods, keywords_required, keywords_optional, template)
        @file = file
        @class_name = class_name
        @superclass_name = superclass_name
        @ivars = ivars
        @view_methods = view_methods
        @keywords_required = keywords_required
        @keywords_optional = keywords_optional
        @template = template
      end

      # "card" for CardComponent, "admin/user_row" for Admin::UserRowComponent.
      def component_name
        under = Inflector.underscore(@class_name)
        under.end_with?("_component") ? under[0, under.size - 10].to_s : under
      end
    end

    # Reads app/components/**/*.rb as text (design D4): the `class X <
    # Cybertrain::Component` (or `< ApplicationComponent`) line, the `@x =`
    # assignments (ControllerScan's: the template's locals), the
    # parameterless public `def`s (ModelScan's: callable by name) and the
    # keyword parameters of `initialize` (the construction arm). A file
    # whose class inherits from neither is skipped, and so is
    # ApplicationComponent itself (an abstract base with no template).
    module ComponentScan
      class Error < StandardError
      end

      BASES = ["Cybertrain::Component", "::Cybertrain::Component", "ApplicationComponent", "::ApplicationComponent"]
      CLASS_LINE = /\A\s*class\s+([A-Z][\w:]*)\s*<\s*([A-Z:][\w:]*)/
      MODULE_LINE = /\A\s*module\s+([A-Z][\w:]*)\s*(?:;|\z|#)/

      def self.scan_dir(dir)
        infos = Array.new(0) { ComponentInfo.new("", "", "", [], [], [], [], "") }
        ControllerScan.ruby_files(dir).each do |path|
          rel = path.start_with?("#{dir}/") ? path[dir.size + 1, path.size - dir.size - 1].to_s : File.basename(path)
          info = scan_source(path, rel, File.read(path))
          next if info.nil?

          erb = "#{path.delete_suffix(".rb")}.html.erb"
          raise Error, "#{path}: no template; expected #{erb}" unless File.file?(erb)

          infos.each do |other|
            next unless other.component_name == info.component_name

            raise Error, "component '#{info.component_name}' is defined twice: #{other.file} (#{other.class_name}) and #{path} (#{info.class_name})"
          end
          infos << info
        end
        infos
      end

      # rel: the file's path under app/components ("admin/user_row_component.rb").
      def self.scan_source(file, rel, source)
        modules = Array.new(0) { "" }
        module_indents = Array.new(0) { 0 }
        class_name = ""
        superclass = ""
        class_indent = -1
        skip_indent = -1
        in_private = false
        ivars = Array.new(0) { "" }
        methods = Array.new(0) { "" }
        kw_required = Array.new(0) { "" }
        kw_optional = Array.new(0) { "" }
        lines = source.lines
        i = 0
        while i < lines.size
          raw = lines[i]
          i += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = ModelScan.indent_of(raw)
          if class_name == ""
            if !module_indents.empty? && indent <= module_indents.last && ModelScan.closing_end?(line)
              modules.pop
              module_indents.pop
              next
            end
            mm = raw.match(MODULE_LINE)
            if mm && !ModelScan.one_line_block?(line)
              modules << mm[1].to_s
              module_indents << indent
              next
            end
            cm = raw.match(CLASS_LINE)
            next if cm.nil?

            full = (modules + [cm[1].to_s]).join("::")
            return nil unless BASES.include?(cm[2].to_s)
            return nil if full == "ApplicationComponent"

            class_name = full
            superclass = cm[2].to_s
            class_indent = indent
            next
          end
          if skip_indent >= 0
            skip_indent = -1 if indent == skip_indent && ModelScan.closing_end?(line)
            next
          end
          break if indent <= class_indent && ModelScan.closing_end?(line)

          ControllerScan.ivar_names(line).each { |n| ivars << n unless ivars.include?(n) }
          if ModelScan.opens_block?(line)
            skip_indent = indent unless ModelScan.one_line_block?(line)
          elsif line == "private" || line == "protected"
            in_private = true
          elsif line == "public"
            in_private = false
          elsif line.start_with?("def initialize")
            text = line
            start_line = i
            while HelperScan.open_parens(text) > 0 && i < lines.size
              text = "#{text} #{lines[i].strip}"
              i += 1
            end
            d = HelperScan.parse_def(file, start_line, text)
            unless d.required.empty? && d.optional.empty? && !d.block?
              raise Error, "#{file}:#{start_line}: component parameters must be keywords (render component: passes them by name)"
            end
            d.keywords_required.each { |k| kw_required << k }
            d.keywords_optional.each { |k| kw_optional << k }
          elsif !in_private
            name = ModelScan.view_method_name(line)
            methods << name if name != "" && !methods.include?(name)
          end
        end
        return nil if class_name == ""
        if kw_optional.size > HelperScan::MAX_OPTIONAL
          raise Error, "#{file}: #{class_name}#initialize has #{kw_optional.size} optional keywords (at most #{HelperScan::MAX_OPTIONAL}: each one doubles the construction arms); give some of them no default"
        end

        template = "components/#{rel.delete_suffix(".rb")}.html.erb"
        ComponentInfo.new(file, class_name, superclass, ivars, methods, kw_required, kw_optional, template)
      end
    end
  end
end
