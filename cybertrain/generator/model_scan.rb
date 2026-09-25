module Cybertrain
  module Gen
    # What the model generator needs to know about one app/models/*.rb file.
    class ModelInfo
      attr_reader :file, :class_name, :view_methods

      def initialize(file, class_name, view_methods)
        @file = file
        @class_name = class_name
        @view_methods = view_methods
      end
    end

    # Reads user model files as text (nothing is loaded) to find the
    # instance methods templates may call: `<%= post.summary %>` reaches
    # them through the generated `call_view_method` case table, since
    # Spinel cannot `send` a computed name (spikes/NOTES.md rule 1).
    module ModelScan
      # -> ModelInfo, or nil when the source has no `class X` line.
      # view_methods are the public `def name` methods without parameters,
      # in source order; class methods (`def self.x`) are ignored.
      #
      # The scan is line based and uses indentation to see block structure:
      # it stops at the `end` that closes the model class (so a second class
      # later in the file contributes nothing), and it skips everything
      # inside a nested `class << self`, `class X` or `module X` block, whose
      # `def`s are not instance methods of the model. A one-line
      # `class << self; ...; end` is skipped as a whole.
      def self.scan_source(file, source)
        class_name = ""
        class_indent = -1
        skip_indent = -1
        methods = Array.new(0) { "" }
        in_private = false
        source.each_line do |raw|
          line = raw.strip
          next if line == ""

          indent = indent_of(raw)
          if class_name == ""
            class_name = class_name_in(line)
            class_indent = indent if class_name != ""
          elsif skip_indent >= 0
            skip_indent = -1 if indent == skip_indent && closing_end?(line)
          elsif indent <= class_indent && closing_end?(line)
            break
          elsif opens_block?(line)
            skip_indent = indent unless one_line_block?(line)
          elsif line == "private" || line == "protected"
            in_private = true
          elsif line == "public"
            in_private = false
          elsif !in_private
            name = view_method_name(line)
            methods << name if name != "" && !methods.include?(name)
          end
        end
        return nil if class_name == ""

        ModelInfo.new(file, class_name, methods)
      end

      # Leading spaces of a raw line (a tab counts as one column).
      def self.indent_of(raw)
        n = 0
        raw.each_char do |ch|
          break unless ch == " " || ch == "\t"
          n += 1
        end
        n
      end

      # "end", "end # comment" or "end." chains are block closers.
      def self.closing_end?(line)
        return false unless line.start_with?("end")
        return true if line == "end"

        nxt = line[3, 1]
        nxt == " " || nxt == "#" || nxt == ";" || nxt == "."
      end

      # A nested `class << self`, `class X` or `module X` inside the model.
      def self.opens_block?(line)
        line.start_with?("class ") || line.start_with?("class<<") || line.start_with?("module ")
      end

      # `class << self; def x = 1; end` or `class Error < StandardError; end`.
      def self.one_line_block?(line)
        !line.index(";").nil? && (line.end_with?(" end") || line.end_with?(";end"))
      end

      # Every app/models/*.rb under `dir` that defines a class, sorted by file.
      def self.scan_dir(dir)
        infos = Array.new(0) { ModelInfo.new("", "", []) }
        Dir.glob(dir + "/*.rb").sort.each do |path|
          info = scan_source(path, File.read(path))
          infos << info unless info.nil?
        end
        infos
      end

      # "class Post < ApplicationRecord" -> "Post"; "" for any other line.
      def self.class_name_in(line)
        return "" unless line.start_with?("class ")

        name = +""
        line[6, line.size - 6].lstrip.each_char do |ch|
          break unless word_char?(ch) || ch == ":"
          name << ch
        end
        name
      end

      # "def summary = title[0, 3]" -> "summary"; "" when the line is not a
      # parameterless instance method definition.
      def self.view_method_name(line)
        return "" unless line.start_with?("def ")

        rest = line[4, line.size - 4].lstrip
        name = +""
        rest.each_char do |ch|
          break unless word_char?(ch)
          name << ch
        end
        return "" if name == "" || name == "initialize"

        tail = rest[name.size, rest.size - name.size]
        if tail.start_with?("?") || tail.start_with?("!")
          name << tail[0]
          tail = tail[1, tail.size - 1]
        end
        tail = tail.lstrip
        tail = tail[2, tail.size - 2].lstrip if tail.start_with?("()")
        return name if tail == "" || tail.start_with?(";") || tail.start_with?("#")
        return name if tail == "=" || tail.start_with?("= ")

        ""
      end

      def self.word_char?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
      end
    end
  end
end
