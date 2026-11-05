require "cybertrain/generator/controller_scan"
require "cybertrain/generator/model_scan"

module Cybertrain
  module Gen
    # One public `def` of an application helper module, with its parameter
    # list split into the kinds a template can pass (spec 3.1).
    class HelperDef
      attr_reader :name, :line, :required, :optional, :keywords_required, :keywords_optional, :block

      # block: the `&name` parameter's name, "" when the helper takes none.
      def initialize(name, line, required, optional, keywords_required, keywords_optional, block)
        @name = name
        @line = line
        @required = required
        @optional = optional
        @keywords_required = keywords_required
        @keywords_optional = keywords_optional
        @block = block
      end

      def block?
        @block != ""
      end

      # Optional parameters (positional and keyword): each one doubles the
      # dispatch arms of a keyword, or adds one for a positional.
      def optional_count
        @optional.size + @keywords_optional.size
      end
    end

    # One `module X` of app/helpers and the helpers it defines.
    class HelperModule
      attr_reader :name, :file, :defs

      def initialize(name, file, defs)
        @name = name
        @file = file
        @defs = defs
      end
    end

    # Reads app/helpers/**/*.rb as text (nothing is loaded, design D4): the
    # `module Name` lines and the public instance `def`s inside them, with
    # their parameter lists. `def self.x` and everything after a `private`
    # (or `protected`) line, up to a `public` line, are skipped; so are the
    # bodies of a nested `class`. Templates pass values by position or
    # keyword, so `*rest`, `**opts`, `...` and anonymous `*` / `**` / `&`
    # are errors, and so is the same helper name in two places (Rails'
    # silent override is a classic bug).
    module HelperScan
      class Error < StandardError
      end

      # More optional parameters than this would mean more than 8 dispatch
      # arms for one helper (HelpersEmitter writes one per subset present).
      MAX_OPTIONAL = 3

      MODULE_LINE = /\A\s*module\s+([A-Z][\w:]*)\s*(?:;|\z|#)/
      CLASS_LINE = /\A\s*class\s/
      DEF_LINE = /\A\s*def\s+([a-z_]\w*[?!]?)(.*)\z/m

      # Every module under dir (recursively, sorted by file), checked for a
      # helper name defined twice.
      def self.scan_dir(dir)
        modules = Array.new(0) { HelperModule.new("", "", Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }) }
        ControllerScan.ruby_files(dir).each do |path|
          scan_source(path, File.read(path)).each { |m| modules << m }
        end
        check_duplicates(modules)
        modules
      end

      # The modules of one file. A module that only wraps others (`module
      # Admin` around `module UsersHelper`) and defines nothing is left out;
      # an innermost module is kept even when it defines nothing yet (it is
      # still included, as Rails includes every helper module).
      def self.scan_source(file, source)
        lines = source.lines
        # Parallel stacks: the open modules' full names, their indents, and
        # whether each one holds another module.
        names = Array.new(0) { "" }
        indents = Array.new(0) { 0 }
        found = Array.new(0) { HelperModule.new("", "", Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }) }
        wraps = Array.new(0) { false }
        skip_indent = -1
        in_private = false
        i = 0
        while i < lines.size
          raw = lines[i]
          i += 1
          line = raw.strip
          next if line == "" || line.start_with?("#")

          indent = ModelScan.indent_of(raw)
          if skip_indent >= 0
            skip_indent = -1 if indent == skip_indent && ModelScan.closing_end?(line)
            next
          end
          if !indents.empty? && indent <= indents.last && ModelScan.closing_end?(line)
            names.pop
            indents.pop
            in_private = false
            next
          end
          m = raw.match(MODULE_LINE)
          if m
            wraps[wraps.size - 1] = true unless wraps.empty?
            full = names.empty? ? m[1].to_s : "#{names.last}::#{m[1]}"
            if ModelScan.one_line_block?(line)
              found << HelperModule.new(full, file, Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") })
              wraps << false
              next
            end
            names << full
            indents << indent
            found << HelperModule.new(full, file, Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") })
            wraps << false
            in_private = false
            next
          end
          next if names.empty?

          if raw.match?(CLASS_LINE)
            skip_indent = indent unless ModelScan.one_line_block?(line)
            next
          end
          if line == "private" || line == "protected"
            in_private = true
            next
          end
          if line == "public"
            in_private = false
            next
          end
          next if in_private
          next unless line.start_with?("def ")
          next if line.start_with?("def self.")

          # A parameter list may run over several lines: join them until
          # the parentheses balance.
          text = line
          start_line = i
          while open_parens(text) > 0 && i < lines.size
            text = "#{text} #{lines[i].strip}"
            i += 1
          end
          d = parse_def(file, start_line, text)
          owner = found_named(found, names.last)
          owner.defs << d unless owner.nil?
        end
        kept = Array.new(0) { HelperModule.new("", "", Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }) }
        found.each_with_index do |mod, j|
          kept << mod if !wraps[j] || !mod.defs.empty?
        end
        kept
      end

      def self.found_named(found, name)
        found.each { |mod| return mod if mod.name == name }
        nil
      end

      # Unclosed "(" in text, outside string literals.
      def self.open_parens(text)
        depth = 0
        quote = ""
        text.each_char do |ch|
          if quote != ""
            quote = "" if ch == quote
          elsif ch == "\"" || ch == "'"
            quote = ch
          elsif ch == "("
            depth += 1
          elsif ch == ")"
            depth -= 1
          end
        end
        depth
      end

      # "def price(value, unit: \"USD\", precision: 2)" -> a HelperDef.
      def self.parse_def(file, line_no, text)
        m = text.match(DEF_LINE)
        raise Error, "#{file}:#{line_no}: cannot read this def" if m.nil?

        name = m[1].to_s
        rest = m[2].to_s.strip
        params = ""
        if rest.start_with?("(")
          params = inside_parens(rest)
        elsif rest != "" && !rest.start_with?("=") && !rest.start_with?(";") && !rest.start_with?("#")
          # `def price value, unit: "USD"` (no parentheses): to the end of the line.
          params = rest
        end
        required = Array.new(0) { "" }
        optional = Array.new(0) { "" }
        kw_required = Array.new(0) { "" }
        kw_optional = Array.new(0) { "" }
        block = ""
        split_params(params).each do |raw_param|
          param = raw_param.strip
          next if param == ""

          if param.start_with?("&")
            pname = param[1, param.size - 1].to_s.strip
            raise Error, "#{file}:#{line_no}: helper parameters must be named; templates pass values by position or keyword" if pname == ""

            block = pname
          elsif param.start_with?("*") || param == "..."
            raise Error, "#{file}:#{line_no}: helper parameters must be named; templates pass values by position or keyword"
          elsif (km = param.match(/\A([a-z_]\w*):(.*)\z/m))
            if km[2].to_s.strip == ""
              kw_required << km[1].to_s
            else
              kw_optional << km[1].to_s
            end
          elsif (om = param.match(/\A([a-z_]\w*)\s*=(.*)\z/m))
            optional << om[1].to_s
          elsif param.match?(/\A[a-z_]\w*\z/)
            raise Error, "#{file}:#{line_no}: '#{param}' follows an optional parameter; put required parameters first" unless optional.empty?

            required << param
          else
            raise Error, "#{file}:#{line_no}: cannot read the parameter '#{param}'"
          end
        end
        d = HelperDef.new(name, line_no, required, optional, kw_required, kw_optional, block)
        if d.optional_count > MAX_OPTIONAL
          raise Error, "#{file}:#{line_no}: '#{name}' has #{d.optional_count} optional parameters (at most #{MAX_OPTIONAL}: each one doubles the dispatch); split it into two helpers"
        end
        d
      end

      # The text between the first "(" and its matching ")".
      def self.inside_parens(text)
        depth = 0
        quote = ""
        out = +""
        text.each_char do |ch|
          if quote != ""
            quote = "" if ch == quote
          elsif ch == "\"" || ch == "'"
            quote = ch
          elsif ch == "("
            depth += 1
            next if depth == 1
          elsif ch == ")"
            depth -= 1
            break if depth == 0
          end
          out << ch
        end
        out
      end

      # Splits a parameter list on the commas outside brackets and strings.
      def self.split_params(text)
        parts = Array.new(0) { "" }
        depth = 0
        quote = ""
        current = +""
        text.each_char do |ch|
          if quote != ""
            quote = "" if ch == quote
          elsif ch == "\"" || ch == "'"
            quote = ch
          elsif ch == "(" || ch == "[" || ch == "{"
            depth += 1
          elsif ch == ")" || ch == "]" || ch == "}"
            depth -= 1
          elsif ch == "," && depth == 0
            parts << current
            current = +""
            next
          end
          current << ch
        end
        parts << current
        parts
      end

      # The same helper name in two places is an error naming both.
      def self.check_duplicates(modules)
        seen = Array.new(0) { "" }
        where = Array.new(0) { "" }
        modules.each do |mod|
          mod.defs.each do |d|
            at = "#{mod.file}:#{d.line}"
            j = seen.index(d.name)
            raise Error, "helper '#{d.name}' is defined twice: #{where[j]} and #{at}" unless j.nil?

            seen << d.name
            where << at
          end
        end
        nil
      end
    end
  end
end
