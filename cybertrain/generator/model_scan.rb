require "cybertrain/ident"
require "cybertrain/generator/concern_scan"

module Cybertrain
  module Gen
    # What the model generator needs to know about one app/models/*.rb file.
    # custom_validations are the `validate :name, ...` lines (one
    # CustomValidationInfo per method name); condition_methods the if: /
    # unless: Symbols of the `validates` lines, in first-seen order, with
    # the line each was first seen on in condition_lines; defined_methods
    # every instance method the class body defines, private ones included
    # (the emitter checks the names above against them); encrypted the
    # columns of its `encrypts` lines, each once in first-seen order, with
    # the line each was first seen on in encrypted_lines; unique_columns
    # the attributes of its `validates ..., uniqueness:` calls, with their
    # lines in unique_lines (the emitter refuses an encrypted one).
    #
    # A model concern (spec 4.2) counts as written at its `include`: the
    # declarations of its `included` body join the lists above in that
    # place, and its instance methods join defined_methods and
    # view_methods. includes / include_lines / include_validates: the
    # names of the class body's `include` lines, their line numbers, and
    # how many of the model's own `validates` calls come above each;
    # concern_names: the concerns those bring in, depth first, each once,
    # with concern_from the index (into includes) of the `include` that
    # brought each in (a concern an `included` body includes counts as
    # brought in by the `include` of the concern around it).
    # defined_places: per defined_methods entry, the "file:line" of its def.
    class ModelInfo
      attr_reader :file, :class_name, :view_methods, :scopes, :associations, :custom_validations,
                  :condition_methods, :condition_lines, :defined_methods, :encrypted, :encrypted_lines,
                  :unique_columns, :unique_lines, :includes, :include_lines, :include_validates,
                  :concern_names, :concern_from, :defined_places

      def initialize(file, class_name, view_methods, scopes, associations, custom_validations,
                     condition_methods, condition_lines, defined_methods, encrypted, encrypted_lines,
                     unique_columns, unique_lines)
        @file = file
        @class_name = class_name
        @view_methods = view_methods
        @scopes = scopes
        @associations = associations
        @custom_validations = custom_validations
        @condition_methods = condition_methods
        @condition_lines = condition_lines
        @defined_methods = defined_methods
        @encrypted = encrypted
        @encrypted_lines = encrypted_lines
        @unique_columns = unique_columns
        @unique_lines = unique_lines
        @includes = Array.new(0) { "" }
        @include_lines = Array.new(0) { 0 }
        @include_validates = Array.new(0) { 0 }
        @concern_names = Array.new(0) { "" }
        @concern_from = Array.new(0) { 0 }
        @defined_places = Array.new(0) { "" }
      end

      # Per defined_methods entry, the "app/...:line" of its def.
      def record_defined_places(places)
        places.each { |p| @defined_places << p }
        nil
      end

      def add_include(name, line, validates)
        @includes << name
        @include_lines << line
        @include_validates << validates
        nil
      end

      def add_concern(name, from)
        @concern_names << name
        @concern_from << from
        nil
      end

      # A ModelInfo with nothing declared, for callers that have no model file.
      def self.empty(file, class_name, view_methods)
        ModelInfo.new(file, class_name, view_methods, Array.new(0) { ScopeInfo.new("", "", "", "", 0) },
                      Array.new(0) { AssociationInfo.new("", :has_many, "", "", "", :none, false, false, 0) },
                      Array.new(0) { CustomValidationInfo.new("", "", "", "", "", 0) },
                      Array.new(0) { "" }, Array.new(0) { 0 }, Array.new(0) { "" }, Array.new(0) { "" },
                      Array.new(0) { 0 }, Array.new(0) { "" }, Array.new(0) { 0 })
      end
    end

    # One method of a `validate :a, :b, on: :update, if: :x, unless: :y`
    # line (spec section 9.2): `on` is "create", "update" or "" (every
    # context), `condition_if` / `condition_unless` a method name or "".
    class CustomValidationInfo
      attr_reader :file, :name, :on, :condition_if, :condition_unless, :line

      def initialize(file, name, on, condition_if, condition_unless, line)
        @file = file
        @name = name
        @on = on
        @condition_if = condition_if
        @condition_unless = condition_unless
        @line = line
      end
    end

    # One `has_many` / `has_one` / `belongs_to` line of a model file (spec
    # section 7.1). `kind` is :has_many, :has_one or :belongs_to; `class_name`
    # and `foreign_key` are "" when the line does not give them (the emitter
    # infers them); `dependent` is :destroy, :delete_all, :nullify or :none;
    # `optional` and `counter_cache` are belongs_to's (false elsewhere);
    # `file` and `line` place the error messages.
    class AssociationInfo
      attr_reader :file, :kind, :name, :class_name, :foreign_key, :dependent, :optional, :counter_cache, :line

      def initialize(file, kind, name, class_name, foreign_key, dependent, optional, counter_cache, line)
        @file = file
        @kind = kind
        @name = name
        @class_name = class_name
        @foreign_key = foreign_key
        @dependent = dependent
        @optional = optional
        @counter_cache = counter_cache
        @line = line
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
      # (ModelValidation.check_scope_names), which knows the schema.
      RESERVED_SCOPE_NAMES = %w[
        initialize binds add_where add_where_not check_not_json where_term range_term add_where_between merge_or
        relation_shape condition_sql set_distinct set_none column_type decimal_scale binary_column? bind_for
        encrypted_column? check_not_encrypted add_where_sql set_order set_order_hash add_order_sql set_limit set_offset to_sql rows count exists?
        delete_all first_row last_row page add_where_like pluck_str pluck_int pluck_float count_by count_by_sql
        sum_int sum_float increment update_all ids batch_rows pluck_rows aggregate_cell
        order_or_id pick_row write_scope_sql select_sql
        set_having_sql pluck pick minimum_int minimum_float minimum_time maximum_int maximum_float maximum_time
        average sum_float_sql minimum_float_sql maximum_float_sql average_sql sum_int_by sum_float_by
        minimum_int_by minimum_float_by minimum_time_by maximum_int_by maximum_float_by maximum_time_by average_by
        aggregate_expr aggregate_arg grouped_by grouped_cell int_totals float_totals int_cells float_cells
        time_cells cell_rows refuse_having select_from_sql having_sql
        add_include includes_names records_preloaded? mark_records_preloaded drop_preloaded preload_association
        copy_chain_to take_chain take_having
        includes preload preloaded empty?
        where not where_sql where_like where_between or order order_sql limit offset distinct none to_a each
        first last find_by find_by! find find_or_create_by find_or_initialize_by destroy_all find_each size
        all create create! from_row table_name column_names new name class
        validates before_validation before_save after_save before_create after_create before_update
        after_update before_destroy after_destroy add_model_callback validators_for callbacks_for now_string
        transaction upsert upsert_into scope encrypts refuse_encrypted has_many has_one belongs_to validates_foreign_key validate
        model_concern_insert_at model_concern_insert_done
        insert_all insert_all! upsert_all insert_all_into no_decimal_scales no_column_types no_encrypted_columns bulk_method_name
        bulk_empty_row bulk_column bulk_columns bulk_cells typed_bind bulk_conflict_sql bulk_returned_row
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
      #
      # associations are the class-level `has_many`, `has_one` and
      # `belongs_to` lines, in source order (association_on): one line each,
      # literal options only; any other shape raises Error with the file and
      # line.
      #
      # An `include` line brings in the concerns it names from `concerns`
      # (ConcernScan.expand: depth first, each once per model), each read by
      # scan_concern and added where the `include` stands (merge_concern);
      # a name that is not a concern (`include Comparable`) is left to Ruby.
      # `include A, B` brings in B, then A, as Module#include does. within
      # names the concerns whose `included` body is being read (an
      # `include` in one is expanded too; a cycle through them raises).
      def self.scan_source(file, source, concerns = Array.new(0) { ConcernInfo.new("", "", 0) }, within = Array.new(0) { "" })
        class_name = ""
        class_indent = -1
        skip_indent = -1
        # The indent of the instance method whose body the scan is in (-1:
        # none): a `scope` line in there is code (`scope = Post.all`), not
        # the macro.
        def_indent = -1
        methods = Array.new(0) { "" }
        scopes = Array.new(0) { ScopeInfo.new("", "", "", "", 0) }
        associations = Array.new(0) { AssociationInfo.new("", :has_many, "", "", "", :none, false, false, 0) }
        validations = Array.new(0) { CustomValidationInfo.new("", "", "", "", "", 0) }
        conditions = Array.new(0) { "" }
        condition_lines = Array.new(0) { 0 }
        defined = Array.new(0) { "" }
        defined_places = Array.new(0) { "" }
        encrypted = Array.new(0) { "" }
        encrypted_lines = Array.new(0) { 0 }
        unique = Array.new(0) { "" }
        unique_lines = Array.new(0) { 0 }
        includes = Array.new(0) { "" }
        include_lines = Array.new(0) { 0 }
        include_validates = Array.new(0) { 0 }
        concern_names = Array.new(0) { "" }
        concern_from = Array.new(0) { 0 }
        validates_calls = 0
        # A `validates` call continued on the next lines (a trailing comma,
        # a backslash or an open bracket): its text so far, and its line.
        pending = +""
        pending_line = 0
        pending_indent = 0
        in_private = false
        lineno = 0
        source.each_line do |raw|
          lineno += 1
          line = raw.strip
          # A line back at the call's own indent (or left of it) that does
          # not close a bracket is the next statement: an unbalanced
          # bracket inside a Regexp literal cannot swallow the class.
          if pending != "" && line != "" && indent_of(raw) <= pending_indent && !line.start_with?(")") &&
             !line.start_with?("}") && !line.start_with?("]")
            collect_validates(file, pending, pending_line, conditions, condition_lines, unique, unique_lines)
            pending = +""
          end
          if pending != ""
            pending << " " << line
            next if continued?(pending)

            collect_validates(file, pending, pending_line, conditions, condition_lines, unique, unique_lines)
            pending = +""
            next
          end
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
          elsif def_indent < 0 && association_kind(line) != ""
            associations << association_on(file, line, lineno, associations)
          elsif def_indent < 0 && validates_line?(line)
            validates_calls += 1
            if continued?(line)
              pending << line
              pending_line = lineno
              pending_indent = indent
            else
              collect_validates(file, line, lineno, conditions, condition_lines, unique, unique_lines)
            end
          elsif def_indent < 0 && validate_line?(line)
            validate_on(file, line, lineno).each { |v| validations << v }
          elsif def_indent < 0 && encrypts_line?(line)
            encrypts_on(file, line, lineno).each do |name|
              next if encrypted.include?(name)

              encrypted << name
              encrypted_lines << lineno
            end
          elsif def_indent < 0 && raw.match?(ControllerScan::INCLUDE_LINE)
            names_text = ""
            im = raw.match(ControllerScan::INCLUDE_LINE)
            names_text = im[1].to_s if im
            # Module#include takes its arguments last to first.
            # A concern written relative to its module (ConcernScan.resolve_include):
            # a model's nesting is the class; a concern read as a model
            # (scan_concern) has its own module and the ones around it.
            owner = within.empty? ? class_name : within.last.to_s
            nesting = ConcernScan.lookup_nesting(owner, within.empty? ? "" : ConcernScan.enclosing(owner))
            names_text.split(",").reverse.each do |part|
              name = ConcernScan.resolve_include(part.strip, nesting, concerns, "#{ControllerScan.app_path(file)}:#{lineno}: ")
              includes << name
              include_lines << lineno
              include_validates << validates_calls
              ConcernScan.expand([name], concerns).each do |c|
                next if concern_names.include?(c.concern_name)

                scanned = scan_concern(c, concerns, within)
                concern_names << c.concern_name
                concern_from << includes.size - 1
                merge_concern(scanned, scopes, associations, validations, conditions, condition_lines, defined, defined_places,
                              methods, encrypted, encrypted_lines, unique, unique_lines)
                # The concerns its `included` body includes, spliced after it.
                scanned.concern_names.each do |inner|
                  next if concern_names.include?(inner)

                  concern_names << inner
                  concern_from << includes.size - 1
                end
              end
            end
          elsif line == "private" || line == "protected"
            in_private = true
          elsif line == "public"
            in_private = false
          else
            defined_name = def_name(line)
            if def_indent < 0 && defined_name != "" && !defined.include?(defined_name)
              defined << defined_name
              defined_places << "#{ControllerScan.app_path(file)}:#{lineno}"
            end
            unless in_private
              name = view_method_name(line)
              methods << name if name != "" && !methods.include?(name)
            end
          end
          def_indent = indent if class_name != "" && def_indent < 0 && skip_indent < 0 && def_opens_body?(line)
        end
        collect_validates(file, pending, pending_line, conditions, condition_lines, unique, unique_lines) if pending != ""
        return nil if class_name == ""

        info = ModelInfo.new(file, class_name, methods, scopes, associations, validations, conditions, condition_lines,
                             defined, encrypted, encrypted_lines, unique, unique_lines)
        includes.each_with_index { |name, k| info.add_include(name, include_lines[k], include_validates[k]) }
        concern_names.each_with_index { |name, k| info.add_concern(name, concern_from[k]) }
        info.record_defined_places(defined_places)
        info
      end

      # What a model concern declares, read as a model: concern_source of
      # its file, so every line keeps its number and errors name the
      # concern's file. An `include` in its `included` body is expanded
      # against concerns; within names the concerns already being read
      # (a cycle through `included` bodies raises).
      def self.scan_concern(concern, concerns, within)
        if within.include?(concern.concern_name)
          chain = Array.new(0) { "" }
          started = false
          within.each do |w|
            started = true if w == concern.concern_name
            chain << w if started
          end
          chain << concern.concern_name
          msg = "concern cycle: #{chain.join(" includes ")}"
          raise ArgumentError, msg
        end
        inner = within.dup
        inner << concern.concern_name
        info = scan_source(concern.concern_file, concern_source(concern, File.read(concern.concern_file)), concerns, inner)
        if info.nil?
          msg = "#{concern.concern_file}:#{concern.concern_line}: module #{concern.concern_name} could not be read as a model concern"
          raise Error, msg
        end
        info
      end

      # The concern's file as scan_source reads a model, line for line: the
      # concern's `module` line becomes `class Name`; the lines above it,
      # its own `include` lines (ConcernScan.expand brings those in), the
      # `included do` and `class_methods do` lines with their `end`, and
      # the `class_methods` body are blank. The `included` body stays, at
      # its own line numbers, among the module's methods.
      def self.concern_source(concern, source)
        lines = source.lines
        out = +""
        n = 0
        lines.each do |raw|
          n += 1
          keep = n > concern.concern_line && !concern.include_line_numbers.include?(n)
          concern.block_starts.each_with_index do |start, k|
            stop = concern.block_ends[k]
            next if n < start || n > stop

            # The body of an `included` block is model code; the rest of
            # the block goes.
            keep = false if n == start || n == stop || !lines[start - 1].to_s.match?(ConcernScan::INCLUDED_OPEN)
          end
          if n == concern.concern_line
            out << (" " * indent_of(raw)) << "class " << concern.concern_name.split("::").last.to_s << "\n"
          elsif keep
            out << raw
          else
            out << "\n"
          end
        end
        out
      end

      # Adds what a concern declares (part) to the lists of the model being
      # scanned, as if written at its `include`. A scope or association
      # named like one the model already has raises Error naming both
      # places.
      def self.merge_concern(part, scopes, associations, validations, conditions, condition_lines, defined, defined_places,
                             methods, encrypted, encrypted_lines, unique, unique_lines)
        part.scopes.each do |sc|
          scopes.each do |e|
            next unless e.name == sc.name

            msg = "#{sc.file}:#{sc.line}: scope :#{sc.name} is already defined at #{e.file}:#{e.line}; rename one of them"
            raise Error, msg
          end
          scopes << sc
        end
        part.associations.each do |a|
          associations.each do |e|
            next unless e.name == a.name

            msg = "#{a.file}:#{a.line}: an association named #{a.name} is already declared at #{e.file}:#{e.line}"
            raise Error, msg
          end
          associations << a
        end
        part.custom_validations.each { |v| validations << v }
        part.condition_methods.each_with_index do |name, k|
          next if conditions.include?(name)

          conditions << name
          condition_lines << part.condition_lines[k]
        end
        part.defined_methods.each_with_index do |name, k|
          next if defined.include?(name)

          defined << name
          defined_places << part.defined_places[k]
        end
        part.view_methods.each { |name| methods << name unless methods.include?(name) }
        part.encrypted.each_with_index do |name, k|
          next if encrypted.include?(name)

          encrypted << name
          encrypted_lines << part.encrypted_lines[k]
        end
        part.unique_columns.each_with_index do |name, k|
          unique << name
          unique_lines << part.unique_lines[k]
        end
        nil
      end

      # A `validates :attr, ...` call (`validates(:attr` too). The options
      # are Ruby that CRuby and Spinel evaluate at load (Model.validates);
      # the scan only reads their if: / unless: names.
      def self.validates_line?(line)
        return false unless line.start_with?("validates ") || line.start_with?("validates(")

        rest = line[9, line.size - 9].lstrip
        rest = rest[1, rest.size - 1].lstrip if rest.start_with?("(")
        rest.start_with?(":")
      end

      # A `validate` macro line: `validate` then a Symbol, a block or a
      # parenthesis. `validate = 1` or `validate.x` are plain code.
      def self.validate_line?(line)
        return false unless line.start_with?("validate ") || line.start_with?("validate(") ||
                            line.start_with?("validate{")

        rest = line[8, line.size - 8].lstrip
        rest.start_with?(":") || rest.start_with?("(") || rest.start_with?("{") || rest == "do" ||
          rest.start_with?("do ") || rest.start_with?("do|")
      end

      # An `encrypts` macro line: `encrypts` then anything but `=` or `.`
      # (`encrypts = 1` is plain code). encrypts_on checks its shape.
      def self.encrypts_line?(line)
        return false unless line.start_with?("encrypts ") || line.start_with?("encrypts(")

        rest = line[8, line.size - 8].lstrip
        !(rest.start_with?("=") || rest.start_with?("."))
      end

      # The column names of `encrypts :a, :b` (or `encrypts(:a, :b)`): a
      # Symbol list on one line, no options; any other shape raises Error
      # with the file and line. Whether each names a string or text column
      # is the emitter's check (it has the schema).
      def self.encrypts_on(file, line, lineno)
        shape = "#{file}:#{lineno}: encrypts must be one line of column names: encrypts :name, ... " \
                "(no options: deterministic encryption is not supported)"
        rest = line[8, line.size - 8].strip
        if rest.start_with?("(")
          raise Error, shape unless rest.end_with?(")")

          rest = rest[1, rest.size - 2].strip
        end
        names = Array.new(0) { "" }
        while true
          raise Error, shape unless rest.start_with?(":")

          name = word_at(rest, 1)
          raise Error, shape if name == "" || (name[0] >= "0" && name[0] <= "9")

          names << name
          rest = rest[name.size + 1, rest.size - name.size - 1].lstrip
          break if rest == ""
          raise Error, shape unless rest.start_with?(",")

          rest = rest[1, rest.size - 1].lstrip
        end
        names
      end

      # Whether a `validates` call goes on past this text: it ends with a
      # comma or a backslash, or a ( [ { is still open (quoted text skipped).
      def self.continued?(text)
        return true if text.end_with?(",") || text.end_with?("\\")

        depth = 0
        quote = ""
        escaped = false
        text.each_char do |ch|
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
          elsif ch == "(" || ch == "[" || ch == "{"
            depth += 1
          elsif ch == ")" || ch == "]" || ch == "}"
            depth -= 1
          end
        end
        depth > 0
      end

      # Adds the if: / unless: method names of a `validates` call to
      # `names` (first-seen order; `lines` gets the line of each). Quoted
      # text is skipped, so `message: "if: x"` is not an option. Anything
      # but a Symbol raises Error: the generated validation_condition? calls
      # the method by name, and a lambda has none (Spinel cannot call a
      # stored lambda on the record).
      # Both reads of one `validates` call: its if: / unless: names
      # (collect_conditions) and, when it validates uniqueness, its
      # attributes (collect_uniqueness).
      def self.collect_validates(file, text, lineno, names, lines, unique, unique_lines)
        collect_conditions(file, text, lineno, names, lines)
        collect_uniqueness(text, lineno, unique, unique_lines)
        nil
      end

      # Adds the attributes of a `validates :a, :b, ..., uniqueness: ...`
      # call to `names` (first-seen order, `lines` gets the line of each):
      # the leading Symbols, when a `uniqueness:` key appears outside quoted
      # text. Any other call adds nothing.
      def self.collect_uniqueness(text, lineno, names, lines)
        quote = ""
        escaped = false
        found = false
        i = 0
        while i < text.size && !found
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
          elsif (i == 0 || !word_char?(text[i - 1, 1])) && text[i, 11] == "uniqueness:"
            found = true
          end
          i += 1
        end
        return nil unless found

        rest = text[9, text.size - 9].lstrip
        rest = rest[1, rest.size - 1].lstrip if rest.start_with?("(")
        while rest.start_with?(":")
          name = word_at(rest, 1)
          break if name == "" || rest[name.size + 1, 1] == ":"

          unless names.include?(name)
            names << name
            lines << lineno
          end
          rest = rest[name.size + 1, rest.size - name.size - 1].lstrip
          break unless rest.start_with?(",")

          rest = rest[1, rest.size - 1].lstrip
        end
        nil
      end

      def self.collect_conditions(file, text, lineno, names, lines)
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
            refuse_condition_spelling(file, lineno, text[i + 1, text.size - i - 1], ch)
            quote = ch
          elsif ch == ":" && (i == 0 || !word_char?(text[i - 1, 1]))
            refuse_condition_spelling(file, lineno, text[i + 1, text.size - i - 1], "")
            i += 1
          elsif (i == 0 || !word_char?(text[i - 1, 1])) &&
                (text[i, 3] == "if:" || text[i, 7] == "unless:")
            key_size = text[i, 3] == "if:" ? 3 : 7
            rest = text[i + key_size, text.size - i - key_size].lstrip
            name = condition_value(file, lineno, rest)
            unless names.include?(name)
              names << name
              lines << lineno
            end
            i += key_size
            next
          end
          i += 1
        end
        nil
      end

      # Refuses `:if => :x` and `"if": :x` / `'unless': :x` (`rest` is the
      # text after the `:` or the opening `quote`): Ruby reads them as if: /
      # unless:, but the scan keys on the `if:` spelling, and a missed
      # condition would run or skip its rule silently.
      def self.refuse_condition_spelling(file, lineno, rest, quote)
        ["if", "unless"].each do |key|
          next unless rest.start_with?(key)

          tail = rest[key.size, rest.size - key.size]
          if quote == ""
            next if tail != "" && (word_char?(tail[0, 1]) || tail[0, 1] == "?" || tail[0, 1] == "!")
            next unless tail.lstrip.start_with?("=>")
          else
            next unless tail.start_with?(quote + ":")
          end
          raise Error, "#{file}:#{lineno}: validates must spell its conditions if: :method and unless: :method " \
                       "(not :#{key} => or \"#{key}\":): the generator reads only that spelling"
        end
        nil
      end

      # The method name of an if: / unless: value (`:published?`), which
      # must be all of the value; raises Error otherwise.
      def self.condition_value(file, lineno, rest)
        name = rest.start_with?(":") ? method_name_at(rest, 1) : ""
        after = rest[name.size + 1, rest.size - name.size - 1].to_s.lstrip
        if name == "" || (name[0] >= "0" && name[0] <= "9") ||
           !(after == "" || after.start_with?(",") || after.start_with?(")") || after.start_with?("}"))
          value = rest.split(",")[0].to_s.strip
          raise Error, "#{file}:#{lineno}: if: and unless: take a Symbol method name (got #{value}): " \
                       "name a method of the model"
        end
        name
      end

      # A method name at `from`: word characters and an optional ? or !.
      def self.method_name_at(text, from)
        name = word_at(text, from)
        return name if name == ""

        mark = text[from + name.size, 1]
        mark == "?" || mark == "!" ? name + mark : name
      end

      # The CustomValidationInfo of each name on a `validate` line: Symbol
      # method names, then on: / if: / unless: with Symbol values, all on
      # one line. Raises Error for any other shape.
      def self.validate_on(file, line, lineno)
        at = "#{file}:#{lineno}: "
        shape = at + "validate must be one line of method names and literal options: " \
                     "validate :name, ..., on: :create, if: :method, unless: :method"
        rest = line[8, line.size - 8].lstrip
        if rest.start_with?("{") || rest == "do" || rest.start_with?("do ") || rest.start_with?("do|")
          raise Error, at + "validate takes method names, not a block: validate :name (a block cannot be " \
                            "called by name under Spinel)"
        end
        raise Error, shape unless rest.start_with?(":")

        names = Array.new(0) { "" }
        on = ""
        condition_if = ""
        condition_unless = ""
        first = true
        options_seen = false
        while rest != ""
          unless first
            raise Error, shape unless rest.start_with?(",")

            rest = rest[1, rest.size - 1].lstrip
          end
          first = false
          if rest.start_with?(":")
            name = method_name_at(rest, 1)
            raise Error, shape if name == "" || (name[0] >= "0" && name[0] <= "9") || options_seen

            names << name
            rest = rest[name.size + 1, rest.size - name.size - 1].lstrip
            next
          end
          key = word_at(rest, 0)
          raise Error, shape if key == "" || rest[key.size, 1] != ":"

          rest = rest[key.size + 1, rest.size - key.size - 1].lstrip
          options_seen = true
          if key == "if" || key == "unless"
            value = condition_value(file, lineno, rest)
            if key == "if"
              condition_if = value
            else
              condition_unless = value
            end
            rest = rest[value.size + 1, rest.size - value.size - 1].lstrip
          elsif key == "on"
            size = literal_size(rest)
            raise Error, shape if size <= 0

            value = rest[0, size]
            unless value == ":create" || value == ":update"
              raise Error, at + "validate: on: takes :create or :update (got #{value})"
            end

            on = value[1, value.size - 1]
            rest = rest[size, rest.size - size].lstrip
          else
            raise Error, at + "validate: unknown option #{key}: (validate takes on:, if:, unless:)"
          end
          raise Error, shape unless rest == "" || rest.start_with?(",")
        end
        raise Error, shape if names.empty?

        out = Array.new(0) { CustomValidationInfo.new("", "", "", "", "", 0) }
        names.each { |name| out << CustomValidationInfo.new(file, name, on, condition_if, condition_unless, lineno) }
        out
      end

      # The name of any instance method a line defines (`def check`,
      # `def ready?(x)`, `def ok = 1`); "" for any other line and for
      # `def self.x`.
      def self.def_name(line)
        return "" unless line.start_with?("def ")

        rest = line[4, line.size - 4].lstrip
        return "" if rest.start_with?("self.")

        name = method_name_at(rest, 0)
        name == "initialize" ? "" : name
      end

      # "has_many", "has_one" or "belongs_to" when the line calls that macro
      # (the macro's name, then a Symbol: `has_many :x`, or `has_many(:x`,
      # which association_on refuses), else "". `has_many = 1` or
      # `belongs_to.x` are plain code.
      def self.association_kind(line)
        ["has_many", "has_one", "belongs_to"].each do |kind|
          next unless line.start_with?(kind + " ") || line.start_with?(kind + "(")

          rest = line[kind.size, line.size - kind.size].lstrip
          rest = rest[1, rest.size - 1].lstrip if rest.start_with?("(")
          return kind if rest.start_with?(":")
        end
        ""
      end

      # The options each macro takes, in the order the messages list them.
      def self.association_options(kind)
        return ["class_name", "foreign_key", "optional", "counter_cache"] if kind == "belongs_to"

        ["dependent", "class_name", "foreign_key"]
      end

      # The AssociationInfo of a macro line; raises Error unless it is
      # `kind :name` followed by `, option: literal` pairs on one line, each
      # option one the macro takes (association_options), given once, with a
      # value of its type, and the name free among `earlier`.
      def self.association_on(file, line, lineno, earlier)
        kind = association_kind(line)
        at = "#{file}:#{lineno}: "
        shape = at + "#{kind} must be one line with literal options: #{kind} :name, option: value, ..."
        rest = line[kind.size, line.size - kind.size].lstrip
        raise Error, shape unless rest.start_with?(":")

        name = word_at(rest, 1)
        raise Error, shape if name == "" || (name[0] >= "0" && name[0] <= "9")

        what = at + "#{kind} :#{name}: "
        rest = rest[name.size + 1, rest.size - name.size - 1].lstrip
        class_name = ""
        foreign_key = ""
        dependent = :none
        optional = false
        counter_cache = false
        seen = Array.new(0) { "" }
        while rest != ""
          raise Error, shape unless rest.start_with?(",")

          rest = rest[1, rest.size - 1].lstrip
          key = word_at(rest, 0)
          raise Error, shape if key == "" || rest[key.size, 1] != ":"

          rest = rest[key.size + 1, rest.size - key.size - 1].lstrip
          size = literal_size(rest)
          raise Error, shape if size <= 0

          value = rest[0, size]
          rest = rest[size, rest.size - size].lstrip
          raise Error, shape unless rest == "" || rest.start_with?(",")

          allowed = association_options(kind)
          unless allowed.include?(key)
            raise Error, what + "unknown option #{key}: (#{kind} takes #{allowed.map { |o| o + ":" }.join(", ")})"
          end
          raise Error, what + "#{key}: is given twice" if seen.include?(key)

          seen << key
          text = literal_text(value)
          if key == "dependent"
            unless value.start_with?(":") && (text == "destroy" || text == "delete_all" || text == "nullify")
              raise Error, what + "dependent: takes :destroy, :delete_all or :nullify (got #{value})"
            end

            dependent = text.to_sym
          elsif key == "optional" || key == "counter_cache"
            raise Error, what + "#{key}: takes true or false (got #{value})" unless value == "true" || value == "false"

            optional = value == "true" if key == "optional"
            counter_cache = value == "true" if key == "counter_cache"
          elsif key == "class_name"
            unless (value.start_with?(":") || quoted_literal?(value)) && constant_name?(text)
              raise Error, what + "class_name: takes a model name (got #{value})"
            end

            class_name = text
          else
            unless (value.start_with?(":") || quoted_literal?(value)) && Ident.column?(text)
              raise Error, what + "foreign_key: takes a column name (got #{value})"
            end

            foreign_key = text
          end
        end
        earlier.each do |a|
          next unless a.name == name

          where = a.file == file ? "on line #{a.line}" : "at #{a.file}:#{a.line}"
          raise Error, what + "an association named #{name} is already declared #{where}"
        end
        AssociationInfo.new(file, kind.to_sym, name, class_name, foreign_key, dependent, optional, counter_cache, lineno)
      end

      # The identifier (word characters) of `text` from index `from`.
      def self.word_at(text, from)
        name = +""
        i = from
        while i < text.size
          ch = text[i, 1]
          break unless word_char?(ch)

          name << ch
          i += 1
        end
        name
      end

      # The length of the literal option value at the start of `text`: a
      # Symbol (`:word`), a String without escapes or interpolation
      # (`"..."`, `'...'`), `true` or `false`; 0 when there is none.
      def self.literal_size(text)
        if text.start_with?(":")
          word = word_at(text, 1)
          return word == "" ? 0 : word.size + 1
        end
        if text.start_with?("\"") || text.start_with?("'")
          quote = text[0, 1]
          i = 1
          while i < text.size
            ch = text[i, 1]
            return 0 if ch == "\\" || (quote == "\"" && ch == "#" && text[i + 1, 1] == "{")
            return i + 1 if ch == quote

            i += 1
          end
          return 0
        end
        word = word_at(text, 0)
        word == "true" || word == "false" ? word.size : 0
      end

      # A literal's text: a Symbol's name, a String's contents, else itself.
      def self.literal_text(value)
        return value[1, value.size - 1] if value.start_with?(":")
        return value[1, value.size - 2] if quoted_literal?(value)

        value
      end

      def self.quoted_literal?(value)
        value.start_with?("\"") || value.start_with?("'")
      end

      # "Comment", "BlogPost": a capital letter, then word characters.
      def self.constant_name?(text)
        return false if text == "" || !(text[0] >= "A" && text[0] <= "Z")

        text.each_char { |ch| return false unless word_char?(ch) }
        true
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

          where = s.file == file ? "on line #{s.line}" : "at #{s.file}:#{s.line}"
          raise Error, at + "scope :#{name} is already defined #{where}; rename one of them"
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

      # Every app/models/*.rb under `dir` that defines a class, sorted by
      # file, with the concerns of dir/concerns (and the module-only files
      # elsewhere under dir) that they include.
      def self.scan_dir(dir)
        infos = Array.new(0) { ModelInfo.empty("", "", Array.new(0) { "" }) }
        concerns = ConcernScan.scan_dir(dir)
        Dir.glob(dir + "/*.rb").sort.each do |path|
          info = scan_source(path, File.read(path), concerns)
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
