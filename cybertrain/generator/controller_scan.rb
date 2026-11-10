require "cybertrain/generator/inflector"

module Cybertrain
  module Gen
    # What the lexical scan found in one controller file.
    class ControllerInfo
      attr_reader :file, :class_name, :superclass_name, :ivars, :callbacks,
                  :includes, :include_positions, :rescue_positions, :include_lines,
                  :method_names, :method_lines, :module_prefix

      # includes: the module names of the class's `include` lines, in order.
      # include_positions / rescue_positions: per include, the count of
      # callback declarations (before_action, after_action, rate_limit,
      # prepend_before_action) / of rescue_from lines above it in the class.
      # include_lines: per include, its line number. method_names /
      # method_lines: the class's instance `def`s. module_prefix: the
      # modules around the class line ("Admin"; "" at the top level).
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
    # class's `include` lines (concerns, spec 4.1) and instance `def`s.
    module ControllerScan
      CLASS_LINE = /\A\s*class\s+([A-Z][\w:]*)\s*<\s*([A-Z][\w:]*)/
      MODULE_LINE = /\A\s*module\s+([A-Z][\w:]*)\s*(?:#.*)?\z/
      INCLUDE_LINE = /\A\s*include\s+([A-Z][\w:]*(?:\s*,\s*[A-Z][\w:]*)*)\s*(?:#.*)?\z/
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
        # The open modules (full names) and their indentation.
        modules = Array.new(0) { "" }
        module_indents = Array.new(0) { 0 }
        # The chosen class's body: its indentation while open, -1 otherwise.
        class_indent = -1
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
              callbacks_above = 0
              rescues_above = 0
              class_indent = indent unless stripped.include?(";")
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
            end
          end
          ivar_names(line).each { |n| ivars << n unless ivars.include?(n) }
          callback_names(line).each { |n| callbacks << n unless callbacks.include?(n) }
        end
        return nil if class_name == ""

        ControllerInfo.new(file, class_name, superclass_name, ivars, callbacks, includes, include_positions,
                           rescue_positions, include_lines, method_names, method_lines, prefix)
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

      # "app/controllers/x.rb" for any path that has an app/ directory in it
      # (messages name files as the application sees them).
      def self.app_path(file)
        return file if file.start_with?("app/")

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
