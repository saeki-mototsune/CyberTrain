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
    # silent override is a classic bug), a name the framework's helpers
    # already use (RESERVED_HELPER_NAMES: `include` would replace the
    # framework method, or the built-in would answer first) and a name
    # ending in _path or _url (the route helpers answer those).
    #
    # Being lexical, the scan follows indentation: a `def` body is skipped
    # up to the `end` at the def's own indent, a `class` (also
    # `class << self`, `class<<self`) up to its `end`, and a module ends at
    # the `end` at its indent. A heredoc whose text holds a line shaped like
    # `def x` or `end` at the wrong indent is an accepted limit (as for
    # ControllerScan and ModelScan).
    module HelperScan
      class Error < StandardError
      end

      # More optional parameters than this would mean more than 8 dispatch
      # arms for one helper (HelpersEmitter writes one per subset present).
      MAX_OPTIONAL = 3

      # Every method of Template::Helpers and HelperBase (public and
      # private: an app module's `def` of the same name, mixed in through
      # `include`, would replace it for the framework too, and NOTES rule 34
      # forbids the same name with another return type), every built-in
      # name helper_call answers before app_helper_call, and the interpreter's
      # `yield`. script/check-reserved-names keeps it complete against
      # cybertrain/template/helpers.rb and interpreter.rb.
      RESERVED_HELPER_NAMES = %w[
        app_block_content app_helper_call arg button_to button_to_path
        constant current_query_string model_call? no_kwargs stream_ws_base tag_builder_call
        call_object_method class_names component_pop component_push content
        content_for content_for? content_tag csrf_meta_tags csrf_token
        data_attrs distance_of_time_in_words dom_id escape flash
        flash_messages form_action form_record form_with h helper_arity!
        helper_call helper_keywords! helper_no_keywords! hidden_fields
        html_arg initialize int_text kwarg_attr link_to link_to_path
        lower_text model_key nested_url number_to_currency number_to_human
        number_to_human_size number_to_percentage number_with_delimiter
        number_with_precision
        outside_request! page_method pager_href pager_html paginate params
        partial_file plural_words pluralize raw render
        render_component_helper render_helper request_bound! request_path
        request_query_string route route_key_of safe_join session_csrf_token
        signed_stream_name stream_source_path string_keys_of string_url tag text_arg
        time_ago_in_words time_arg to_html truncate turbo_stream_from
        url_for yield
      ]

      MODULE_LINE = /\A\s*module\s+([A-Z][\w:]*)\s*(?:;|\z|#)/
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
          # A class (top-level or nested, `class << self` too) is skipped
          # whole before modules are looked for: a module inside it is not
          # a helper module.
          if line.start_with?("class ") || line.start_with?("class<<")
            skip_indent = indent unless ModelScan.one_line_block?(line)
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

          if line == "private" || line == "protected"
            in_private = true
            next
          end
          if line == "public"
            in_private = false
            next
          end
          next unless line.start_with?("def ")

          # A parameter list may run over several lines: join them until
          # the parentheses balance.
          text = line
          start_line = i
          while open_parens(text) > 0 && i < lines.size
            text = "#{text} #{lines[i].strip}"
            i += 1
          end
          # The body (when it has one) is skipped up to the def's own `end`,
          # so a column-0 `end` of an unindented body does not close the
          # module, and nothing in the body is read as a def or `private`.
          skip_indent = indent unless ModelScan.one_line_block?(line) || endless?(text)
          # A singleton method is not mixed in by `include`, so it is neither
          # a helper nor a shadowing risk. A private def is checked, though:
          # `include` mixes private methods in as well, so a private
          # `def params` would still replace the framework's.
          next if setter?(text) || line.start_with?("def self.")

          if in_private
            # Only the name: a template cannot call a private method, so its
            # parameters (`*parts`, a block) are its own business.
            check_name(file, HelperDef.new(def_name(file, start_line, text), start_line, [], [], [], [], ""))
            next
          end
          d = parse_def(file, start_line, text)
          check_name(file, d)

          owner = found_named(found, names.last)
          owner.defs << d unless owner.nil?
        end
        kept = Array.new(0) { HelperModule.new("", "", Array.new(0) { HelperDef.new("", 0, [], [], [], [], "") }) }
        found.each_with_index do |mod, j|
          kept << mod if !wraps[j] || !mod.defs.empty?
        end
        kept
      end

      # A helper the framework would answer first, or whose `include`
      # would replace a framework method.
      def self.check_name(file, d)
        name = d.name
        if RESERVED_HELPER_NAMES.include?(name)
          raise Error, "#{file}:#{d.line}: '#{name}' is a name the framework's template helpers already use; pick another helper name"
        end
        if name.end_with?("_path") || name.end_with?("_url")
          raise Error, "#{file}:#{d.line}: '#{name}' ends in _path or _url, which the route helpers answer; pick another helper name"
        end
        nil
      end

      # `def value=(v)` / `def value= v`: a writer, not a helper.
      def self.setter?(text)
        m = text.match(DEF_LINE)
        return false if m.nil?

        m[2].to_s.start_with?("=")
      end

      # `def today = "now"` / `def price(v) = v.to_s`: no body to skip.
      def self.endless?(text)
        m = text.match(DEF_LINE)
        return false if m.nil?

        rest = m[2].to_s
        return false if rest.start_with?("=")

        rest = rest.strip
        if rest.start_with?("(")
          inner = inside_parens(rest)
          close = rest.index(")", inner.size + 1)
          rest = close.nil? ? "" : rest[close + 1, rest.size - close - 1].to_s.strip
        end
        rest.start_with?("=") && !rest.start_with?("==")
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
      # The method name of a def line, and nothing else.
      def self.def_name(file, line_no, text)
        m = text.match(DEF_LINE)
        raise Error, "#{file}:#{line_no}: cannot read this def" if m.nil?

        m[1].to_s
      end

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
