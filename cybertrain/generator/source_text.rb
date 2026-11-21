module Cybertrain
  module Gen
    # What the generator's lexical scanners and emitters share, whatever
    # they scan: the Ruby files of a tree, creating a directory, and the
    # shape of one source line, and writing a class inside its enclosing
    # modules.
    module SourceText
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

      # Creates dir and any missing parent.
      def self.make_dirs(dir)
        return nil if File.directory?(dir)

        make_dirs(File.dirname(dir))
        Dir.mkdir(dir)
        nil
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

      # "end", "end # comment", "end;" or an "end." chain: a block closer.
      def self.closing_end?(line)
        return false unless line.start_with?("end")
        return true if line == "end"

        nxt = line[3, 1]
        nxt == " " || nxt == "#" || nxt == ";" || nxt == "."
      end

      # A nested `class << self`, `class X` or `module X`.
      def self.opens_block?(line)
        line.start_with?("class ") || line.start_with?("class<<") || line.start_with?("module ")
      end

      # `class << self; def x = 1; end` or `class Error < StandardError; end`.
      def self.one_line_block?(line)
        !line.index(";").nil? && (line.end_with?(" end") || line.end_with?(";end"))
      end

      def self.word_char?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
      end

      # `body` (the source of `class X` or `module X`, X the last part of
      # full_name) inside the parts before it, indented: part i is opened
      # with keywords[i] ("module" or "class"), with "module" when keywords
      # is shorter (callers whose enclosing parts are all modules pass an
      # empty Array; JobInfo#scope_keywords has one keyword per part).
      def self.wrap_in_scopes(full_name, keywords, body)
        parts = full_name.split("::")
        out = +""
        depth = 0
        parts.each_with_index do |mod, i|
          next if i == parts.size - 1

          out << ("  " * depth) << (i < keywords.size ? keywords[i] : "module") << " #{mod}\n"
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
  end
end
