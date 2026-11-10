require "cybertrain/generator/inflector"
require "cybertrain/generator/helper_scan"

module Cybertrain
  module Gen
    # One `layout` line of a controller or of a concern's `included` block:
    # layout_name is the name (`layout "admin"`: "admin"; `layout false`
    # and the method form: ""), layout_method the method of `layout
    # :choose_layout` ("" otherwise), layout_only / layout_except the
    # action names of `only:` / `except:`, layout_line its line number.
    class LayoutDecl
      attr_reader :layout_name, :layout_method, :layout_only, :layout_except, :layout_line

      def initialize(layout_name, layout_method, layout_only, layout_except, layout_line)
        @layout_name = layout_name
        @layout_method = layout_method
        @layout_only = layout_only
        @layout_except = layout_except
        @layout_line = layout_line
      end

      # Whether it applies to every action.
      def unconditional?
        @layout_only.empty? && @layout_except.empty?
      end
    end

    # What the lexical scan found in one controller file.
    class ControllerInfo
      attr_reader :file, :class_name, :superclass_name, :ivars, :callbacks,
                  :includes, :include_positions, :rescue_positions, :include_lines,
                  :method_names, :method_lines, :module_prefix, :helper_methods, :defs, :def_errors, :layouts

      # includes: the module names of the class's `include` lines, in order.
      # include_positions / rescue_positions: per include, the count of
      # callback declarations (before_action, after_action, rate_limit,
      # prepend_before_action) / of rescue_from lines above it in the class.
      # include_lines: per include, its line number. method_names /
      # method_lines: the class's instance `def`s. module_prefix: the
      # modules around the class line ("Admin"; "" at the top level).
      # helper_methods: the names of the class's `helper_method` lines
      # (spec 4.3), in order; defs: a HelperDef per instance `def` (its
      # parameters when HelperScan.parse_def reads them, else the name and
      # line); def_errors: per def, HelperScan's message when it could not
      # read the parameters ("" when it could), so a helper_method naming
      # that def is refused with it. layouts: a LayoutDecl per `layout`
      # line of the class, in order.
      def initialize(file, class_name, superclass_name, ivars, callbacks,
                     includes = Array.new(0) { "" }, include_positions = Array.new(0) { 0 },
                     rescue_positions = Array.new(0) { 0 }, include_lines = Array.new(0) { 0 },
                     method_names = Array.new(0) { "" }, method_lines = Array.new(0) { 0 }, module_prefix = "")
        @file = file
        @class_name = class_name
        @superclass_name = superclass_name
        @ivars = ivars
        @callbacks = callbacks
        @includes = includes
        @include_positions = include_positions
        @rescue_positions = rescue_positions
        @include_lines = include_lines
        @method_names = method_names
        @method_lines = method_lines
        @module_prefix = module_prefix
        @helper_methods = Array.new(0) { "" }
        @defs = Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }
        @def_errors = Array.new(0) { "" }
        @layouts = Array.new(0) { LayoutDecl.new("", "", [], [], 0) }
      end

      # A superclass written bare inside a module, once every controller is
      # scanned (ControllerScan.resolve_superclasses).
      def resolve_superclass(name)
        @superclass_name = name
        nil
      end
    end

    # Reads app/controllers/*.rb line by line (no parsing, design D4): the
    # `class X < Y` line, every `@name =` / `@name ||=` assignment (and each
    # ivar target of a statement-level `@a, b, *@c = ...`), and the symbol
    # names given to before_action/after_action/around_action and
    # `rescue_from ..., with:`. Being lexical, it misses nested
    # destructuring (`@a, (@b, @c) = ...`) and does not skip string
    # contents ("@x = 1" inside a literal counts as an assignment).
    #
    # It also follows `module A` / `module A::B` lines, each closed by the
    # `end` at its own indentation, so `module Admin` around `class
    # ArticlesController < ApplicationController` is Admin::ArticlesController
    # (the compact `class Admin::ArticlesController` too), and reads the
    # class's `include` lines (concerns, spec 4.1), its `helper_method`
    # lines (spec 4.3) and instance `def`s.
    module ControllerScan
      CLASS_LINE = /\A\s*class\s+([A-Z][\w:]*)\s*<\s*([A-Z][\w:]*)/
      MODULE_LINE = /\A\s*module\s+([A-Z][\w:]*)\s*(?:#.*)?\z/
      INCLUDE_LINE = /\A\s*include\s+([A-Z][\w:]*(?:\s*,\s*[A-Z][\w:]*)*)\s*(?:#.*)?\z/
      # A line opening a method, `private def x` too.
      DEF_OPEN = /\A(?:(?:private|protected|public)\s+)?def\s/
      DEF_NAME = /\A\s*def\s+(?!self\.)([a-z_]\w*[?!]?)/
      # The declarations that add one entry to the class's callback list.
      CALLBACK_DECLARATION = /\A\s*(?:before_action|after_action|rate_limit|prepend_before_action)\b/
      RESCUE_DECLARATION = /\A\s*rescue_from\b/
      # "@post =", "@post ||=", "@count +=" but not "@post ==", "@@count =" or "@post.title =".
      IVAR_ASSIGN = /(?:\A|[^@\w])@([a-z_]\w*)\s*(?:\|\||&&|\+|-|\*)?=(?![=~>])/
      # "@a, @b = 1, 2" / "first, @c, *@rest = list" at the start of a statement.
      MULTI_ASSIGN = /\A\s*((?:\*?@?[a-z_]\w*\s*,\s*)+\*?@?[a-z_]\w*)\s*=(?![=~>])/
      IVAR_NAME = /@([a-z_]\w*)/
      CALLBACK_CALL = /\A\s*(?:before_action|after_action|around_action)\b\s*\(?\s*/
      SYMBOL_ARG = /\A:(\w+[?!]?)\s*,?\s*/
      RESCUE_WITH = /\A\s*rescue_from\b.*\bwith:\s*:(\w+[?!]?)/
      HELPER_METHOD_CALL = /\A\s*helper_method\b\s*\(?\s*/
      # `layout` followed by the start of an argument: `(`, a quote, `:`,
      # `false` or `nil`, or one gen refuses (a lambda, a constant). A local
      # named layout (`layout ||= x`, `layout if x`, `layout, b = x`) is no
      # declaration.
      LAYOUT_CALL = /\A\s*layout(?:\s*\(|\s+(?=["':A-Z]|->|false\b|nil\b|lambda\b|proc\b))\s*/
      # What follows `layout`: "admin" / 'admin', false, or :choose_layout.
      LAYOUT_ARG = /\A(?:"([^"'\#\\]*)"|'([^"'\#\\]*)'|(false)|:([a-z_]\w*[?!]?))\s*/
      # `only: [:a, :b]`, `except: %i[a b]`, `only: :a`.
      LAYOUT_OPTION = /\A,\s*(only|except):\s*(\[[^\]]*\]|%i\[[^\]]*\]|:\w+[?!]?)\s*/
      LAYOUT_UNREADABLE = "layout takes a name (layout \"admin\"), false, or a method's name (layout :choose_layout), then only: or except:"

      # nil when the source has no `class X < Y` line. When a file defines
      # several classes, the one named after the file wins
      # (posts_controller.rb -> PostsController).
      def self.scan_source(file, source)
        expected = Inflector.camelize(File.basename(file, ".rb"))
        class_name = ""
        superclass_name = ""
        prefix = ""
        ivars = []
        callbacks = []
        includes = Array.new(0) { "" }
        include_positions = Array.new(0) { 0 }
        rescue_positions = Array.new(0) { 0 }
        include_lines = Array.new(0) { 0 }
        method_names = Array.new(0) { "" }
        method_lines = Array.new(0) { 0 }
        helper_methods = Array.new(0) { "" }
        defs = Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }
        def_errors = Array.new(0) { "" }
        layouts = Array.new(0) { LayoutDecl.new("", "", [], [], 0) }
        lines = source.lines
        # The open modules (full names) and their indentation.
        modules = Array.new(0) { "" }
        module_indents = Array.new(0) { 0 }
        # The chosen class's body: its indentation while open, -1 otherwise.
        class_indent = -1
        # The open multi-line `def`'s indentation inside the class, -1 outside one.
        def_indent = -1
        callbacks_above = 0
        rescues_above = 0
        number = 0
        source.each_line do |line|
          number += 1
          stripped = line.strip
          next if stripped.start_with?("#")

          indent = indent_of(line)
          if class_indent >= 0 && indent <= class_indent && closing_end?(stripped)
            class_indent = -1
            def_indent = -1
            next
          end
          if class_indent < 0 && !module_indents.empty? && indent <= module_indents.last && closing_end?(stripped)
            modules.pop
            module_indents.pop
            next
          end
          mm = line.match(MODULE_LINE)
          if mm && class_indent < 0
            modules << (modules.empty? ? mm[1].to_s : "#{modules.last}::#{mm[1]}")
            module_indents << indent
            next
          end

          m = line.match(CLASS_LINE)
          if m && class_indent < 0
            outer = modules.empty? ? "" : modules.last.to_s
            full = outer == "" ? m[1].to_s : "#{outer}::#{m[1]}"
            if class_name == "" || full.split("::").last == expected
              class_name = full
              superclass_name = m[2].to_s
              prefix = outer
              includes = Array.new(0) { "" }
              include_positions = Array.new(0) { 0 }
              rescue_positions = Array.new(0) { 0 }
              include_lines = Array.new(0) { 0 }
              method_names = Array.new(0) { "" }
              method_lines = Array.new(0) { 0 }
              helper_methods = Array.new(0) { "" }
              defs = Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }
              def_errors = Array.new(0) { "" }
              layouts = Array.new(0) { LayoutDecl.new("", "", [], [], 0) }
              callbacks_above = 0
              rescues_above = 0
              class_indent = indent unless stripped.include?(";")
              def_indent = -1
            end
          elsif class_indent >= 0
            callbacks_above += 1 if line.match?(CALLBACK_DECLARATION)
            rescues_above += 1 if line.match?(RESCUE_DECLARATION)
            im = line.match(INCLUDE_LINE)
            if im
              im[1].to_s.split(",").each do |name|
                includes << name.strip
                include_positions << callbacks_above
                rescue_positions << rescues_above
                include_lines << number
              end
            end
            dm = line.match(DEF_NAME)
            if dm
              method_names << dm[1].to_s
              method_lines << number
              defs << def_at(file, lines, number, def_errors)
            end
            helper_method_names(line).each { |n| helper_methods << n unless helper_methods.include?(n) }
            # Declarations are class-body lines: not a method's (a local
            # named layout is no declaration).
            if def_indent >= 0
              def_indent = -1 if indent <= def_indent && closing_end?(stripped)
            elsif stripped.match?(DEF_OPEN)
              def_indent = indent unless one_line_def?(lines, number)
            else
              decl = layout_decl(file, number, line)
              layouts << decl unless decl.nil?
            end
          end
          ivar_names(line).each { |n| ivars << n unless ivars.include?(n) }
          callback_names(line).each { |n| callbacks << n unless callbacks.include?(n) }
        end
        return nil if class_name == ""

        info = ControllerInfo.new(file, class_name, superclass_name, ivars, callbacks, includes, include_positions,
                                  rescue_positions, include_lines, method_names, method_lines, prefix)
        helper_methods.each { |n| info.helper_methods << n }
        defs.each { |d| info.defs << d }
        def_errors.each { |e| info.def_errors << e }
        layouts.each { |d| info.layouts << d }
        info
      end

      # The HelperDef of the `def` on line `number` (1-based) of `lines`,
      # its parameter list joined over the lines it runs on: the parameters
      # when HelperScan.parse_def reads them, else the name and line alone
      # (a `*rest` or `...` parameter), and HelperScan's message appended to
      # errors ("" when it read them).
      def self.def_at(file, lines, number, errors)
        text = lines[number - 1].to_s.strip
        j = number
        while HelperScan.open_parens(text) > 0 && j < lines.size
          text = "#{text} #{lines[j].to_s.strip}"
          j += 1
        end
        name = HelperScan.def_name(file, number, text)
        parsed = HelperDef.new(name, number, [], [], [], [], "")
        error = ""
        begin
          parsed = HelperScan.parse_def(app_path(file), number, text)
        rescue HelperScan::Error => e
          parsed = HelperDef.new(name, number, [], [], [], [], "")
          error = e.message
        end
        errors << error
        parsed
      end

      # Whether the `def` on line `number` (1-based) of `lines` has no body
      # lines of its own: an endless def or `def x; ...; end`, its
      # parameter list joined over the lines it runs on.
      def self.one_line_def?(lines, number)
        text = lines[number - 1].to_s.strip.sub(/\A(?:private|protected|public)\s+/, "")
        j = number
        while HelperScan.open_parens(text) > 0 && j < lines.size
          text = "#{text} #{lines[j].to_s.strip}"
          j += 1
        end
        HelperScan.endless?(text) || (text.include?(";") && (text.end_with?(" end") || text.end_with?(";end")))
      end

      # The names a `helper_method :a, :b` line declares ([] for any other line).
      def self.helper_method_names(line)
        names = Array.new(0) { "" }
        m = line.match(HELPER_METHOD_CALL)
        return names unless m

        rest = line[m.end(0), line.size - m.end(0)].to_s
        while (s = rest.match(SYMBOL_ARG))
          names << s[1].to_s
          rest = rest[s.end(0), rest.size - s.end(0)].to_s
        end
        names
      end

      # The LayoutDecl of a `layout` line (line `number` of `file`); nil for
      # any other line. Raises ArgumentError, naming the line, for a
      # `layout` call gen cannot read (`layout nil`, a lambda, a constant).
      def self.layout_decl(file, number, line)
        m = line.match(LAYOUT_CALL)
        return nil unless m

        msg = "#{app_path(file)}:#{number}: #{LAYOUT_UNREADABLE}"
        rest = line[m.end(0), line.size - m.end(0)].to_s.strip
        parens = line.match?(/\A\s*layout\s*\(/)
        a = rest.match(LAYOUT_ARG)
        raise ArgumentError, msg unless a

        name = a[1].to_s
        name = a[2].to_s if a[1].nil?
        method = a[4].to_s
        only = Array.new(0) { "" }
        except = Array.new(0) { "" }
        rest = rest[a.end(0), rest.size - a.end(0)].to_s
        while (o = rest.match(LAYOUT_OPTION))
          list = o[2].to_s
          names = list.scan(/[a-z_]\w*[?!]?/)
          names.shift if list.start_with?("%i")
          if o[1].to_s == "only"
            names.each { |n| only << n.to_s }
          else
            names.each { |n| except << n.to_s }
          end
          rest = rest[o.end(0), rest.size - o.end(0)].to_s
        end
        # Then `)` for the parenthesised form, and a comment, quotes and all.
        tail = parens ? /\A\s*\)\s*(?:#.*)?\z/ : /\A\s*(?:#.*)?\z/
        raise ArgumentError, msg unless rest.match?(tail)

        LayoutDecl.new(name, method, only, except, number)
      end

      # Every controller under dir (recursively), sorted by file path. The
      # files under dir/concerns are concerns (ConcernScan), not controllers.
      def self.scan_dir(dir)
        infos = []
        concerns_dir = "#{dir}/concerns/"
        ruby_files(dir).each do |path|
          next if path.start_with?(concerns_dir)

          info = scan_source(path, File.read(path))
          infos << info unless info.nil?
        end
        resolve_superclasses(infos)
        infos
      end

      # A superclass written bare inside `module Admin` names Admin::X when
      # a scanned controller has that name (the nearest enclosing module
      # first, as Ruby looks it up), else the top-level class.
      def self.resolve_superclasses(infos)
        infos.each do |info|
          prefix = info.module_prefix
          name = info.superclass_name
          next if prefix == "" || name.start_with?("::")

          parts = prefix.split("::")
          while parts.size > 0
            candidate = "#{parts.join("::")}::#{name}"
            found = false
            infos.each { |other| found = true if other.class_name == candidate }
            if found
              info.resolve_superclass(candidate)
              break
            end
            parts.pop
          end
        end
        nil
      end

      # Sorted "<dir>/<rel>.rb" paths under dir ([] when dir is missing).
      def self.ruby_files(dir)
        files = []
        return files unless File.directory?(dir)

        Dir.children(dir).sort.each do |entry|
          path = "#{dir}/#{entry}"
          if File.directory?(path)
            ruby_files(path).each { |f| files << f }
          elsif entry.end_with?(".rb")
            files << path
          end
        end
        files.sort
      end

      def self.indent_of(raw)
        n = 0
        raw.each_char do |ch|
          break unless ch == " " || ch == "\t"

          n += 1
        end
        n
      end

      # "end", "end # comment", "end;" or an "end." chain.
      def self.closing_end?(line)
        return false unless line.start_with?("end")
        return true if line == "end"

        nxt = line[3, 1]
        nxt == " " || nxt == "#" || nxt == ";" || nxt == "."
      end

      # "app/controllers/x.rb" for a path under the project root (messages
      # name files as the application sees them, and gen/concerns/** and the
      # manifest are keyed by it). The root is the one Runner is working on
      # (use_root): the path after it, never after an "/app/" that is part
      # of the root itself.
      @root = ""

      def self.use_root(root)
        @root = root
      end

      def self.app_path(file)
        return file if file.start_with?("app/")

        base = "#{@root}/"
        return file[base.size, file.size - base.size].to_s if @root != "" && file.start_with?(base)

        i = file.index("/app/")
        i.nil? ? file : file[i + 1, file.size - i - 1].to_s
      end

      # Assigned ivar names in source order, statement by statement.
      def self.ivar_names(line)
        names = []
        line.split(";").each do |statement|
          multi = statement.match(MULTI_ASSIGN)
          if multi
            targets = multi[1].to_s
            pos = 0
            while (t = targets.match(IVAR_NAME, pos))
              names << t[1].to_s
              pos = t.end(0)
            end
          end
          pos = 0
          while (m = statement.match(IVAR_ASSIGN, pos))
            names << m[1].to_s
            pos = m.end(0)
          end
        end
        names
      end

      def self.callback_names(line)
        names = []
        m = line.match(RESCUE_WITH)
        if m
          names << m[1].to_s
          return names
        end
        m = line.match(CALLBACK_CALL)
        return names unless m

        rest = line[m.end(0), line.size - m.end(0)].to_s
        while (s = rest.match(SYMBOL_ARG))
          names << s[1].to_s
          rest = rest[s.end(0), rest.size - s.end(0)].to_s
        end
        names
      end
    end
  end
end
