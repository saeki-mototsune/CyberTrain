require "cybertrain/feature_catalog"

module Cybertrain
  module Gen
    # Cybertrain::Gen::ViewRequires -- `spin run gen` refuses a view that
    # calls a helper of a subsystem bin/NAME.rb does not require
    # (docs/superpowers/specs/2026-11-13-optional-subsystems-design.md,
    # section 5). Without the line the helper is not compiled in, and the
    # page would fail only when rendered; gen says it first:
    #
    #   app/views/articles/show.html.erb:3: turbo_stream_from needs require "cybertrain/streams" in bin/blog.rb
    #
    # NAME is spin.toml's [package] name. bin/NAME.rb is read lexically: a
    # line that is, after its indentation, `require "LINE"` (or 'LINE', or
    # require("LINE")) adds what FeatureCatalog.loaded_by(LINE) loads;
    # `require "cybertrain"` loads everything. A require written another
    # way, or in a file bin/NAME.rb requires, is not seen. With no spin.toml
    # name or no bin/NAME.rb (a fixture tree, an app laid out otherwise)
    # nothing is refused: the check needs the file to say what is loaded.
    #
    # The views are app/views/**/*.erb and app/components/**/*.erb. In each
    # `<% %>`, `<%= %>` and `<%== %>` tag (not `<%# %>` nor a literal `<%%`)
    # a helper counts where Ruby would call it: a bare name (not after `.`,
    # `::`, `@` or `:`, nor a `name:` key), outside string literals and `#`
    # comments; inside a "#{...}" interpolation it counts.
    module ViewRequires
      # Every refusal for the application at `root`, in file and line
      # order; empty when the views need nothing bin/NAME.rb lacks.
      # @param root [String]
      # @return [Array<String>]
      def self.problems(root)
        out = Array.new(0) { "" }
        name = package_name(root)
        return out if name.empty?

        bin = "#{root}/bin/#{name}.rb"
        return out unless File.file?(bin)

        loaded = loaded_subsystems(File.read(bin))
        missing = Array.new(0) { "" }
        FeatureCatalog.view_helpers.each do |helper|
          missing << helper unless loaded.include?(FeatureCatalog.helper_subsystem(helper))
        end
        return out if missing.empty?

        %w[app/views app/components].each do |dir|
          ViewsEmitter.view_files("#{root}/#{dir}").each do |rel|
            path = "#{dir}/#{rel}"
            scan_template(File.read("#{root}/#{path}"), path, missing, name, out)
          end
        end
        out
      end

      # spin.toml's [package] name; "" without one.
      # @param root [String]
      # @return [String]
      def self.package_name(root)
        path = "#{root}/spin.toml"
        return "" unless File.file?(path)

        section = ""
        File.read(path).split("\n").each do |raw|
          line = raw.strip
          if line.start_with?("[")
            section = line
          elsif section == "[package]" && line.start_with?("name")
            rest = line[4, line.size - 4].strip
            if rest.start_with?("=")
              value = rest[1, rest.size - 1].strip
              return value[1, value.size - 2] if value.size >= 2 && value.start_with?("\"") && value.end_with?("\"")
            end
          end
        end
        ""
      end

      # The subsystems the require lines of `source` (bin/NAME.rb) load.
      # @param source [String]
      # @return [Array<String>]
      def self.loaded_subsystems(source)
        out = Array.new(0) { "" }
        source.split("\n").each do |raw|
          spec = required_spec(raw.strip)
          FeatureCatalog.loaded_by(spec).each { |s| out << s } unless spec.empty?
        end
        out
      end

      # The argument of a `require "x"`, `require 'x'` or `require("x")`
      # line; "" for any other line.
      # @param line [String] stripped
      # @return [String]
      def self.required_spec(line)
        return "" unless line.start_with?("require")

        rest = line[7, line.size - 7]
        rest = rest[1, rest.size - 1] if rest.start_with?("(")
        rest = rest.strip
        return "" if rest.empty?

        quote = rest[0]
        return "" unless quote == "\"" || quote == "'"

        close = rest.index(quote, 1)
        return "" if close.nil?

        rest[1, close - 1]
      end

      # Appends a refusal to `out` for each call of a `missing` helper in
      # the tags of the template `source` (at `path`).
      # @return [nil]
      def self.scan_template(source, path, missing, name, out)
        i = 0
        line = 1
        n = source.size
        while i < n
          open = source.index("<%", i)
          break if open.nil?

          line += newlines(source, i, open)
          if source[open + 2] == "%"
            i = open + 3
            next
          end
          start = open + 2
          comment = source[start] == "#"
          start += 1 while start < n && (source[start] == "=" || source[start] == "-")
          close = tag_end(source, start)
          close = n if close < 0
          scan_code(source[start, close - start], line, path, missing, name, out) unless comment
          line += newlines(source, open, close)
          i = close + 2
        end
        nil
      end

      # The index of the `%>` that closes a tag whose code starts at
      # `from` (a `%%>` is a literal `%>`, as Template::Lexer reads it); -1
      # when the tag is not closed.
      # @return [Integer]
      def self.tag_end(source, from)
        j = from
        while true
          k = source.index("%>", j)
          return -1 if k.nil?
          return k unless k > from && source[k - 1] == "%"

          j = k + 2
        end
      end

      # How many newlines source[from...to] has.
      # @return [Integer]
      def self.newlines(source, from, to)
        count = 0
        k = from
        while k < to
          count += 1 if source[k] == "\n"
          k += 1
        end
        count
      end

      # Appends a refusal for each call of a `missing` helper in a tag's
      # Ruby `code`, whose first line is the template's line `line`.
      # @return [nil]
      def self.scan_code(code, line, path, missing, name, out)
        j = 0
        ln = line
        prev = " "
        n = code.size
        while j < n
          c = code[j]
          if c == "\n"
            ln += 1
            j += 1
          elsif c == " " || c == "\t" || c == "\r"
            j += 1
          elsif c == "#"
            j += 1 while j < n && code[j] != "\n"
          elsif c == "\"" || c == "'"
            close = string_end(code, j + 1, c)
            scan_interpolations(code, j + 1, close, ln, path, missing, name, out) if c == "\""
            ln += newlines(code, j, close)
            j = close + 1
            prev = "\""
          elsif identifier_start?(c)
            k = j + 1
            k += 1 while k < n && identifier_char?(code[k])
            k += 1 if k < n && (code[k] == "?" || code[k] == "!")
            word = code[j, k - j]
            key = k < n && code[k] == ":" && (k + 1 >= n || code[k + 1] != ":")
            # `x.name`, `x&.name` and `x.\n name` follow a `.`; `:name`,
            # `X::name`, `@name` and `$name` touch theirs (a ternary's
            # `a ? b : name` does not).
            touching = j > 0 ? code[j - 1] : " "
            receiver = prev == "." || touching == ":" || touching == "@" || touching == "$"
            if !key && !receiver && missing.include?(word)
              out << FeatureCatalog.missing_helper_message(path, ln, word, name)
            end
            j = k
            prev = "a"
          else
            prev = c
            j += 1
          end
        end
        nil
      end

      # The index of the quote that closes a string opened before `from`
      # (backslash escapes skipped; a "#{...}" interpolation's braces and
      # strings skipped too); the code's size when it is not closed.
      # @return [Integer]
      def self.string_end(code, from, quote)
        j = from
        n = code.size
        while j < n
          c = code[j]
          if c == "\\"
            j += 2
          elsif quote == "\"" && c == "#" && j + 1 < n && code[j + 1] == "{"
            j = interpolation_end(code, j + 2) + 1
          elsif c == quote
            return j
          else
            j += 1
          end
        end
        n
      end

      # The index of the `}` closing an interpolation whose code starts at
      # `from`; the code's size when it is not closed.
      # @return [Integer]
      def self.interpolation_end(code, from)
        depth = 1
        j = from
        n = code.size
        while j < n
          c = code[j]
          if c == "\"" || c == "'"
            j = string_end(code, j + 1, c) + 1
            next
          end
          depth += 1 if c == "{"
          depth -= 1 if c == "}"
          return j if depth == 0

          j += 1
        end
        n
      end

      # Scans the "#{...}" interpolations of the string body code[from...to]
      # as code.
      # @return [nil]
      def self.scan_interpolations(code, from, to, line, path, missing, name, out)
        j = from
        while j < to
          if code[j] == "\\"
            j += 2
          elsif code[j] == "#" && j + 1 < to && code[j + 1] == "{"
            close = interpolation_end(code, j + 2)
            inner_line = line + newlines(code, from, j)
            scan_code(code[j + 2, close - j - 2], inner_line, path, missing, name, out)
            j = close + 1
          else
            j += 1
          end
        end
        nil
      end

      # @return [Boolean]
      def self.identifier_start?(c)
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
      end

      # @return [Boolean]
      def self.identifier_char?(c)
        identifier_start?(c) || (c >= "0" && c <= "9")
      end
    end
  end
end
