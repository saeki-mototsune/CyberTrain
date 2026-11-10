require "cybertrain/generator/controller_scan"
require "cybertrain/generator/helper_scan"

module Cybertrain
  module Gen
    # What the lexical scan found in one concern (spec 4.1): a module of
    # app/controllers/concerns (or a module-only file elsewhere under
    # app/controllers) written the Rails way,
    #
    #     module AdminGate
    #       extend ActiveSupport::Concern
    #       include Stamped
    #
    #       included do
    #         before_action :require_admin
    #       end
    #
    #       class_methods do
    #         def per_page = 50
    #       end
    #
    #       def require_admin = ...
    #     end
    #
    # included_body: the lines between `included do` and its `end`, as
    # written; class_method_lines: those of `class_methods do`, and
    # class_method_names / class_method_line_numbers its `def`s;
    # concern_includes / include_line_numbers: the module's own `include`
    # lines; concern_ivars: the `@x =` of its methods; concern_callbacks: the
    # method names its `included` body hands to callbacks and rescue_from;
    # concern_defs: its instance methods (a HelperDef each: the parameters
    # when HelperScan.parse_def reads them, else the name and line);
    # concern_def_errors: per def, HelperScan's message when it could not
    # read the parameters ("" when it could);
    # callback_count / rescue_count: the declarations of the `included`
    # body that add a callback / a rescue handler; block_starts /
    # block_ends: the first and last line numbers of each `included do ...
    # end` and `class_methods do ... end` block (the lines gen/concerns/**
    # leaves blank).
    class ConcernInfo
      attr_reader :concern_file, :concern_name, :concern_line, :included_body, :class_method_lines,
                  :class_method_names, :class_method_line_numbers, :concern_includes, :include_line_numbers,
                  :concern_ivars, :concern_callbacks, :concern_defs, :concern_def_errors, :callback_count, :rescue_count,
                  :block_starts, :block_ends

      def initialize(concern_file, concern_name, concern_line)
        @concern_file = concern_file
        @concern_name = concern_name
        @concern_line = concern_line
        @included_body = Array.new(0) { "" }
        @class_method_lines = Array.new(0) { "" }
        @class_method_names = Array.new(0) { "" }
        @class_method_line_numbers = Array.new(0) { 0 }
        @concern_includes = Array.new(0) { "" }
        @include_line_numbers = Array.new(0) { 0 }
        @concern_ivars = Array.new(0) { "" }
        @concern_callbacks = Array.new(0) { "" }
        @concern_defs = Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }
        @concern_def_errors = Array.new(0) { "" }
        @callback_count = 0
        @rescue_count = 0
        @block_starts = Array.new(0) { 0 }
        @block_ends = Array.new(0) { 0 }
      end

      def count_callback
        @callback_count += 1
        nil
      end

      def count_rescue
        @rescue_count += 1
        nil
      end
    end

    # Reads an application's concerns line by line, as ControllerScan reads
    # its controllers (no parsing: a block ends at the `end` of its own
    # indentation), and expands `include` lines into the concerns they
    # bring in (Gen::ConcernsEmitter writes the result).
    module ConcernScan
      INCLUDED_OPEN = /\A\s*included\s+do\s*(?:\|\s*\w*\s*\|)?\s*(?:#.*)?\z/
      CLASS_METHODS_OPEN = /\A\s*class_methods\s+do\s*(?:#.*)?\z/
      AROUND = /\A\s*around_action\b/
      RULE_93 = "Spinel compiles a def inside class_methods as an instance method too (spikes/NOTES.md rule 93), so rename one"

      # Every concern under dir (an app/controllers): the files of
      # dir/concerns, then each other file under dir that defines no
      # controller class, sorted by file within each group.
      def self.scan_dir(dir)
        infos = Array.new(0) { ConcernInfo.new("", "", 0) }
        concerns_dir = "#{dir}/concerns/"
        files = ControllerScan.ruby_files(dir)
        files.each do |path|
          next unless path.start_with?(concerns_dir)

          info = scan_source(path, File.read(path))
          infos << info unless info.nil?
        end
        files.each do |path|
          next if path.start_with?(concerns_dir)

          source = File.read(path)
          next unless ControllerScan.scan_source(path, source).nil?

          info = scan_source(path, source)
          infos << info unless info.nil?
        end
        infos
      end

      # nil when the file opens no module. The concern is the module whose
      # body holds the first statement (`module Admin` around `module Gate`
      # is Admin::Gate; a file of empty modules names its innermost one). A
      # class in its body is skipped whole, and so is a module nested in it.
      def self.scan_source(file, source)
        lines = source.lines
        modules = Array.new(0) { "" }
        indents = Array.new(0) { 0 }
        module_lines = Array.new(0) { 0 }
        info = ConcernInfo.new(file, "", 0)
        found = false
        innermost = ""
        innermost_line = 0
        i = 0
        while i < lines.size
          raw = lines[i]
          i += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = ControllerScan.indent_of(raw)
          if !indents.empty? && indent <= indents.last && ControllerScan.closing_end?(line)
            modules.pop
            indents.pop
            module_lines.pop
            next
          end
          mm = raw.match(ControllerScan::MODULE_LINE)
          if mm
            modules << (modules.empty? ? mm[1].to_s : "#{modules.last}::#{mm[1]}")
            indents << indent
            module_lines << i
            if modules.last.to_s.size > innermost.size
              innermost = modules.last.to_s
              innermost_line = i
            end
            next
          end
          next if modules.empty?

          unless found
            info = ConcernInfo.new(file, modules.last.to_s, module_lines.last)
            found = true
          end
          # Only the concern's own body.
          next unless modules.last == info.concern_name

          if line.start_with?("class ") || line.start_with?("class<<")
            i = skip_block(lines, i, indent) unless line.include?(";")
            next
          end
          if raw.match?(INCLUDED_OPEN)
            info.block_starts << i
            i = read_included(file, info, lines, i, indent)
            info.block_ends << i
            next
          end
          if raw.match?(CLASS_METHODS_OPEN)
            info.block_starts << i
            i = read_class_methods(info, lines, i, indent)
            info.block_ends << i
            next
          end
          im = raw.match(ControllerScan::INCLUDE_LINE)
          if im
            im[1].to_s.split(",").each do |name|
              info.concern_includes << name.strip
              info.include_line_numbers << i
            end
            next
          end
          if line.start_with?("def ")
            start = i
            text = line
            while HelperScan.open_parens(text) > 0 && i < lines.size
              text = "#{text} #{lines[i].strip}"
              i += 1
            end
            one_line = HelperScan.endless?(text) || (line.include?(";") && (line.end_with?(" end") || line.end_with?(";end")))
            i = skip_block(lines, i, indent) unless one_line
            add_ivars(info, lines, start - 1, i)
            info.concern_defs << def_of(file, start, text, info.concern_def_errors) unless line.start_with?("def self.") || HelperScan.setter?(text)
            next
          end
          ControllerScan.ivar_names(raw).each { |n| info.concern_ivars << n unless info.concern_ivars.include?(n) }
        end
        return nil if innermost == ""

        info = ConcernInfo.new(file, innermost, innermost_line) unless found
        check_class_methods(info)
        info
      end

      # The index of the line after the `end`, at `indent` or less, that
      # closes the block opened just before lines[from].
      def self.skip_block(lines, from, indent)
        j = from
        while j < lines.size
          raw = lines[j]
          j += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")
          return j if ControllerScan.indent_of(raw) <= indent && ControllerScan.closing_end?(line)
        end
        j
      end

      # The ivars assigned on lines[from...to].
      def self.add_ivars(info, lines, from, to)
        j = from
        while j < to && j < lines.size
          raw = lines[j]
          j += 1
          next if raw.strip.start_with?("#")

          ControllerScan.ivar_names(raw).each { |n| info.concern_ivars << n unless info.concern_ivars.include?(n) }
        end
        nil
      end

      # A HelperDef with its parameters when HelperScan reads them, else
      # with the name and line alone (a `*rest` or `...` parameter), and
      # HelperScan's message appended to errors ("" when it read them).
      def self.def_of(file, line_no, text, errors)
        name = HelperScan.def_name(file, line_no, text)
        parsed = HelperDef.new(name, line_no, [], [], [], [], "")
        error = ""
        begin
          parsed = HelperScan.parse_def(ControllerScan.app_path(file), line_no, text)
        rescue HelperScan::Error => e
          parsed = HelperDef.new(name, line_no, [], [], [], [], "")
          error = e.message
        end
        errors << error
        parsed
      end

      # Reads the `included do` body opened just before lines[from];
      # returns the index after its `end`.
      def self.read_included(file, info, lines, from, indent)
        j = from
        while j < lines.size
          raw = lines[j]
          j += 1
          line = raw.strip
          return j if ControllerScan.indent_of(raw) <= indent && ControllerScan.closing_end?(line)

          if raw.match?(AROUND)
            msg = "#{ControllerScan.app_path(file)}:#{j}: around_action is not supported (no around callbacks in Cybertrain::Controller)"
            raise ArgumentError, msg
          end
          info.included_body << raw
          next if line.start_with?("#")

          info.count_callback if raw.match?(ControllerScan::CALLBACK_DECLARATION)
          info.count_rescue if raw.match?(ControllerScan::RESCUE_DECLARATION)
          ControllerScan.callback_names(raw).each { |n| info.concern_callbacks << n unless info.concern_callbacks.include?(n) }
        end
        j
      end

      # Reads the `class_methods do` body opened just before lines[from];
      # returns the index after its `end`.
      def self.read_class_methods(info, lines, from, indent)
        j = from
        while j < lines.size
          raw = lines[j]
          j += 1
          line = raw.strip
          return j if ControllerScan.indent_of(raw) <= indent && ControllerScan.closing_end?(line)

          info.class_method_lines << raw
          dm = raw.match(ControllerScan::DEF_NAME)
          if dm
            info.class_method_names << dm[1].to_s
            info.class_method_line_numbers << j
          end
        end
        j
      end

      # spikes/NOTES.md rule 93: Spinel compiles a `def` inside the
      # never-run `class_methods` block as an instance method of the
      # concern, so its name must not be one of the concern's instance
      # methods too.
      def self.check_class_methods(info)
        where = ControllerScan.app_path(info.concern_file)
        info.class_method_names.each_with_index do |name, k|
          info.concern_defs.each do |d|
            next unless d.name == name

            msg = "#{where}:#{info.class_method_line_numbers[k]}: class_methods def #{name}: #{info.concern_name} also defines " \
                  "an instance method #{name} (#{where}:#{d.line}); #{RULE_93}"
            raise ArgumentError, msg
          end
        end
        nil
      end

      def self.find(concerns, name)
        concerns.each { |c| return c if c.concern_name == name }
        nil
      end

      # The concerns `names` bring in, depth first (a concern's own
      # includes before it), each once. `where` gives, per name, the
      # "file:line" of its `include` for the unknown-name message.
      def self.expand(names, concerns, where = Array.new(0) { "" })
        out = Array.new(0) { ConcernInfo.new("", "", 0) }
        names.each_with_index do |name, k|
          place = k < where.size ? where[k] : ""
          visit(name, place, concerns, Array.new(0) { "" }, out)
        end
        out
      end

      def self.visit(name, place, concerns, stack, out)
        if stack.include?(name)
          chain = Array.new(0) { "" }
          started = false
          stack.each do |s|
            started = true if s == name
            chain << s if started
          end
          chain << name
          msg = "concern cycle: #{chain.join(" includes ")}"
          raise ArgumentError, msg
        end
        out.each { |c| return nil if c.concern_name == name }
        concern = find(concerns, name)
        if concern.nil?
          home = place.start_with?("app/models/") ? "app/models/concerns" : "app/controllers/concerns"
          prefix = place == "" ? "" : "#{place}: "
          msg = "#{prefix}include #{name}: no concern named #{name} in #{home}"
          raise ArgumentError, msg
        end
        inner = stack.dup
        inner << name
        concern.concern_includes.each_with_index do |sub, k|
          visit(sub, "#{ControllerScan.app_path(concern.concern_file)}:#{concern.include_line_numbers[k]}", concerns, inner, out)
        end
        out << concern
        nil
      end

      # The concerns a controller brings in that its scanned ancestors have
      # not, in `include` order, each expanded depth first and kept once.
      # `from_include` receives, per concern returned, the index (into
      # info.includes) of the `include` that brought it in. Raises for an
      # unknown name or a cycle.
      def self.own_concerns(info, infos, concerns, from_include = Array.new(0) { 0 })
        inherited = inherited_concerns(info, infos, concerns)
        out = Array.new(0) { ConcernInfo.new("", "", 0) }
        info.includes.each_with_index do |name, k|
          place = "#{ControllerScan.app_path(info.file)}:#{info.include_lines[k]}"
          expand([name], concerns, [place]).each do |c|
            next if inherited.include?(c.concern_name)

            seen = false
            out.each { |o| seen = true if o.concern_name == c.concern_name }
            next if seen

            out << c
            from_include << k
          end
        end
        out
      end

      def self.controller_named(infos, class_name)
        infos.each { |i| return i if i.class_name == class_name }
        nil
      end

      # The concern names a controller's scanned ancestors include.
      def self.inherited_concerns(info, infos, concerns)
        names = Array.new(0) { "" }
        seen = Array.new(0) { "" }
        seen << info.class_name
        parent = controller_named(infos, info.superclass_name)
        until parent.nil? || seen.include?(parent.class_name)
          seen << parent.class_name
          parent.includes.each_with_index do |name, k|
            place = "#{ControllerScan.app_path(parent.file)}:#{parent.include_lines[k]}"
            expand([name], concerns, [place]).each { |c| names << c.concern_name unless names.include?(c.concern_name) }
          end
          parent = controller_named(infos, parent.superclass_name)
        end
        names
      end
    end
  end
end
