require "cybertrain/generator/inflector"

module Cybertrain
  module Gen
    # What the lexical scan found in one controller file.
    class ControllerInfo
      attr_reader :file, :class_name, :superclass_name, :ivars, :callbacks

      def initialize(file, class_name, superclass_name, ivars, callbacks)
        @file = file
        @class_name = class_name
        @superclass_name = superclass_name
        @ivars = ivars
        @callbacks = callbacks
      end
    end

    # Reads app/controllers/*.rb line by line (no parsing, design D4): the
    # `class X < Y` line, every `@name =` / `@name ||=` assignment (and each
    # ivar target of a statement-level `@a, b, *@c = ...`), and the symbol
    # names given to before_action/after_action/around_action and
    # `rescue_from ..., with:`. Being lexical, it misses nested
    # destructuring (`@a, (@b, @c) = ...`) and does not skip string
    # contents ("@x = 1" inside a literal counts as an assignment).
    module ControllerScan
      CLASS_LINE = /\A\s*class\s+([A-Z][\w:]*)\s*<\s*([A-Z][\w:]*)/
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
        ivars = []
        callbacks = []
        source.each_line do |line|
          next if line.strip.start_with?("#")

          m = line.match(CLASS_LINE)
          if m && (class_name == "" || m[1] == expected)
            class_name = m[1].to_s
            superclass_name = m[2].to_s
          end
          ivar_names(line).each { |n| ivars << n unless ivars.include?(n) }
          callback_names(line).each { |n| callbacks << n unless callbacks.include?(n) }
        end
        return nil if class_name == ""

        ControllerInfo.new(file, class_name, superclass_name, ivars, callbacks)
      end

      # Every controller under dir (recursively), sorted by file path.
      def self.scan_dir(dir)
        infos = []
        ruby_files(dir).each do |path|
          info = scan_source(path, File.read(path))
          infos << info unless info.nil?
        end
        infos
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
