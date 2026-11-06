require "cybertrain/ident"

module Cybertrain
  module Gen
    # What the model generator needs to know about one app/models/*.rb file.
    class ModelInfo
      attr_reader :file, :class_name, :view_methods, :scopes

      def initialize(file, class_name, view_methods, scopes)
        @file = file
        @class_name = class_name
        @view_methods = view_methods
        @scopes = scopes
      end
    end

    # One `scope :name, ->(params) { body }` line of a model file: `params`
    # is the text inside the lambda's parentheses ("" without them), `body`
    # the text between its braces, both copied verbatim into the generated
    # Relation method; `file` and `line` place the error messages.
    class ScopeInfo
      attr_reader :file, :name, :params, :body, :line

      def initialize(file, name, params, body, line)
        @file = file
        @name = name
        @params = params
        @body = body
        @line = line
      end
    end

    # Reads user model files as text (nothing is loaded) to find the
    # instance methods templates may call: `<%= post.summary %>` reaches
    # them through the generated `call_view_method` case table, since
    # Spinel cannot `send` a computed name (spikes/NOTES.md rule 1).
    module ModelScan
      class Error < StandardError
      end

      # Names a scope may not take: a scope is generated as a method of the
      # model's Relation and as a class method of the model, so it must not
      # replace a method either already has (NOTES rule 34: one return type
      # per name). Every method of Cybertrain::Relation (public and private),
      # every method the generated Relation defines (emit_relation), the
      # class delegations (ModelsEmitter::DELEGATED), the generated class
      # methods (all, create, table_name, ...), the class methods of
      # Cybertrain::Model, and the Object methods both inherit that the
      # framework or Ruby calls (hash, inspect, to_s, then; raise and fail,
      # which find_by! and find call on the Relation itself). The other
      # Object methods (dup, tap, send, ...) and the Ruby keywords are
      # refused through Ident (reserved_scope_name?). script/check-reserved-names keeps it complete
      # against those files; a column name is checked by the emitter
      # (ModelsEmitter.check_scope_names), which knows the schema.
      RESERVED_SCOPE_NAMES = %w[
        initialize binds add_where add_where_not check_not_json where_term range_term add_where_between merge_or
        relation_shape condition_sql set_distinct set_none column_type decimal_scale binary_column? bind_for
        add_where_sql set_order set_order_hash add_order_sql set_limit set_offset to_sql rows count exists?
        delete_all first_row last_row page add_where_like pluck_str pluck_int pluck_float count_by count_by_sql
        sum_int sum_float increment update_all ids batch_rows pluck_rows aggregate_cell grouped_counts
        order_or_id pick_row write_scope_sql select_sql
        where not where_sql where_like where_between or order order_sql limit offset distinct none to_a each
        first last find_by find_by! find find_or_create_by find_or_initialize_by destroy_all find_each size
        all create create! from_row table_name column_names new name class
        validates before_validation before_save after_save before_create after_create before_update
        after_update before_destroy after_destroy add_model_callback validators_for callbacks_for now_string
        transaction upsert upsert_into scope
        hash inspect to_s then raise fail
      ]

      # Whether a scope may not be called `name`: RESERVED_SCOPE_NAMES, an
      # Object method (Ident::SHADOWING_COLUMN_NAMES) or a Ruby keyword.
      def self.reserved_scope_name?(name)
        RESERVED_SCOPE_NAMES.include?(name) || Ident.shadowing_column?(name) || Ident.keyword?(name)
      end

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
      #
      # scopes are the class-level `scope :name, ->(params) { body }` lines,
      # in source order (scope_on). A `scope` line of any other shape, or a
      # scope named like a Relation method (RESERVED_SCOPE_NAMES) or like an
      # earlier scope, raises Error with the file and line.
      def self.scan_source(file, source)
        class_name = ""
        class_indent = -1
        skip_indent = -1
        # The indent of the instance method whose body the scan is in (-1:
        # none): a `scope` line in there is code (`scope = Post.all`), not
        # the macro.
        def_indent = -1
        methods = Array.new(0) { "" }
        scopes = Array.new(0) { ScopeInfo.new("", "", "", "", 0) }
        in_private = false
        lineno = 0
        source.each_line do |raw|
          lineno += 1
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
          elsif def_indent >= 0 && indent == def_indent && closing_end?(line)
            def_indent = -1
          elsif opens_block?(line)
            skip_indent = indent unless one_line_block?(line)
          elsif def_indent < 0 && scope_line?(line)
            scopes << scope_on(file, line, lineno, scopes)
          elsif line == "private" || line == "protected"
            in_private = true
          elsif line == "public"
            in_private = false
          elsif !in_private
            name = view_method_name(line)
            methods << name if name != "" && !methods.include?(name)
          end
          def_indent = indent if class_name != "" && def_indent < 0 && skip_indent < 0 && def_opens_body?(line)
        end
        return nil if class_name == ""

        ModelInfo.new(file, class_name, methods, scopes)
      end

      # A line calling the `scope` macro: `scope` then a Symbol, `scope :x,
      # ...` or `scope(:x, ...)`. `scope = ...`, `scope.where(...)` or
      # `scope ||= ...` are plain code.
      def self.scope_line?(line)
        return false unless line.start_with?("scope ") || line.start_with?("scope(")

        rest = line[5, line.size - 5].lstrip
        rest = rest[1, rest.size - 1].lstrip if rest.start_with?("(")
        rest.start_with?(":")
      end

      # A `def` line whose body runs to an `end` at its indent: not an
      # endless `def x = ...` / `def x(a) = ...`, nor `def x; ...; end`.
      def self.def_opens_body?(line)
        return false unless line.start_with?("def ")
        return false if one_line_block?(line)

        rest = line[4, line.size - 4].lstrip
        i = 0
        # The name: up to a space or "(" (an operator name such as `==`
        # starts with "=", so "=" ends a name only after its first char).
        while i < rest.size
          ch = rest[i, 1]
          break if ch == " " || ch == "(" || (ch == "=" && i > 0 && word_char?(rest[i - 1, 1]))
          i += 1
        end
        tail = rest[i, rest.size - i].lstrip
        if tail.start_with?("(")
          close = matching_close(tail, "(", ")")
          return true if close < 0

          tail = tail[close + 1, tail.size - close - 1].lstrip
        end
        !(tail.start_with?("=") && !tail.start_with?("=="))
      end

      # The index of the `close` that balances the `open` at text[0], with
      # String literals ("...", '...', backslash escapes) skipped; -1 when
      # there is none.
      def self.matching_close(text, open, close)
        depth = 0
        quote = ""
        escaped = false
        i = 0
        while i < text.size
          ch = text[i, 1]
          if quote != ""
            if escaped
              escaped = false
            elsif ch == "\\"
              escaped = true
            elsif ch == quote
              quote = ""
            end
          elsif ch == "\"" || ch == "'"
            quote = ch
          elsif ch == open
            depth += 1
          elsif ch == close
            depth -= 1
            return i if depth == 0
          end
          i += 1
        end
        -1
      end

      # The ScopeInfo of a `scope` line; raises Error unless it is
      # `scope :name, -> { body }` or `scope :name, ->(params) { body }` on
      # one line, with a free name (RESERVED_SCOPE_NAMES, `earlier`).
      def self.scope_on(file, line, lineno, earlier)
        at = "#{file}:#{lineno}: "
        shape = at + "scope must be a one-line lambda: scope :name, ->(args) { ... }"
        rest = line[5, line.size - 5].lstrip
        raise Error, shape unless rest.start_with?(":")

        name = +""
        rest[1, rest.size - 1].each_char do |ch|
          break unless word_char?(ch)
          name << ch
        end
        rest = rest[name.size + 1, rest.size - name.size - 1].lstrip
        raise Error, shape if name == "" || (name[0] >= "0" && name[0] <= "9") || !rest.start_with?(",")

        rest = rest[1, rest.size - 1].lstrip
        raise Error, shape unless rest.start_with?("->")

        rest = rest[2, rest.size - 2].lstrip
        params = ""
        if rest.start_with?("(")
          close = rest.index(")")
          raise Error, shape if close.nil?

          params = rest[1, close - 1].strip
          rest = rest[close + 1, rest.size - close - 1].lstrip
          raise Error, shape if scope_args(params) == "!"
        end
        raise Error, shape unless rest.start_with?("{")

        # The body ends at the `}` balancing the lambda's `{`; nothing may
        # follow it (a second statement, a comment).
        close = matching_close(rest, "{", "}")
        raise Error, shape if close < 0 || rest[close + 1, rest.size - close - 1].strip != ""

        body = rest[1, close - 1].strip
        raise Error, shape if body == ""

        if reserved_scope_name?(name)
          raise Error, at + "scope :#{name} clashes with the method #{name} of the model's Relation or class " \
                           "(a scope is generated as both); rename the scope"
        end
        earlier.each do |s|
          next unless s.name == name

          raise Error, at + "scope :#{name} is already defined on line #{s.line}; rename one of them"
        end
        ScopeInfo.new(file, name, params, body, lineno)
      end

      # The arguments the class method passes on for a scope's parameter
      # text: "a, b = 1" -> "a, b". "!" when a parameter is not a plain or
      # defaulted positional one (a keyword, a splat, a block, a default
      # holding a comma), which scope_on refuses.
      def self.scope_args(params)
        return "" if params == ""

        names = Array.new(0) { "" }
        params.split(",").each do |part|
          text = part.strip
          name = +""
          text.each_char do |ch|
            break unless word_char?(ch)
            name << ch
          end
          return "!" if name == "" || (name[0] >= "0" && name[0] <= "9")

          tail = text[name.size, text.size - name.size].lstrip
          return "!" unless tail == "" || (tail.start_with?("=") && tail.size > 1 && tail[1, 1] != "=")

          names << name
        end
        names.join(", ")
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
        infos = Array.new(0) { ModelInfo.new("", "", [], []) }
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
