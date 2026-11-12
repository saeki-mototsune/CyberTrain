require "cybertrain/schema"
require "cybertrain/generator/inflector"
require "cybertrain/ident"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/model_naming"

module Cybertrain
  module Gen
    # One association of a generated model, resolved against the schema
    # (ModelValidation.association_plans): `kind` (:has_many, :has_one,
    # :belongs_to), the reader `name`, the target `model` and its
    # `target_table`, the `foreign_key` column (on the children's table for
    # has_many / has_one, on this table for belongs_to) with whether it is
    # nullable and an integer, `dependent` (:none, :destroy, :delete_all,
    # :nullify), belongs_to's `optional` and `counter_cache` (with the
    # parent's `counter_column`), whether app/models `declared` it, and the
    # comment lines written above the reader.
    class AssociationPlan
      attr_reader :kind, :name, :model, :target_table, :foreign_key, :fk_null, :fk_integer, :dependent, :optional,
                  :counter_cache, :counter_column, :declared, :notes

      def initialize(kind, name, model, target_table, foreign_key, fk_null, fk_integer, dependent, optional,
                     counter_cache, counter_column, declared, notes)
        @kind = kind
        @name = name
        @model = model
        @target_table = target_table
        @foreign_key = foreign_key
        @fk_null = fk_null
        @fk_integer = fk_integer
        @dependent = dependent
        @optional = optional
        @counter_cache = counter_cache
        @counter_column = counter_column
        @declared = declared
        @notes = notes
      end
    end

    # Where db/schema.rb spells a table or a column, for the diagnostics
    # about the schema: Cybertrain::Schema is built by running the file, so
    # its tables carry no line, and this finds one in the file's text. A
    # table's line is its `create_table` line; a column's is the first line
    # of that block which names it as a String or a Symbol, else the
    # table's (`t.references :post` spells no `post_id`). Without the text
    # (SchemaPlaces.absent: a schema defined in a test) or when the table is
    # not found, `at` is "" and the message stands as it was.
    class SchemaPlaces
      def initialize(file, source)
        @file = file
        @lines = source.split("\n")
      end

      # No source text: every `at` is "".
      def self.absent
        SchemaPlaces.new("", "")
      end

      # The places of root/db/schema.rb (none when the file is missing).
      def self.in_app(root)
        path = "#{root}/db/schema.rb"
        return SchemaPlaces.absent unless File.exist?(path)

        SchemaPlaces.new("db/schema.rb", File.read(path))
      end

      # "db/schema.rb:12: " for `column` of `table` ("" for the table
      # itself), or "" when the place is unknown.
      def at(table, column)
        line = line_of(table, column)
        line == 0 ? "" : "#{@file}:#{line}: "
      end

      # The 1-based line, 0 when unknown.
      def line_of(table, column)
        found = 0
        i = 0
        while i < @lines.size
          text = @lines[i].strip
          if text.start_with?("#")
            # a comment names nothing
          elsif text.include?("create_table")
            return found if found > 0

            found = i + 1 if SchemaPlaces.names?(text, table)
          elsif found > 0 && column != "" && SchemaPlaces.names?(text, column)
            return i + 1
          end
          i += 1
        end
        found
      end

      # Whether `text` holds "name", 'name' or the Symbol :name.
      def self.names?(text, name)
        return true if text.include?("\"" + name + "\"") || text.include?("'" + name + "'")

        at = text.index(":" + name)
        return false if at.nil?

        after = at + name.size + 1
        after >= text.size || !ModelScan.word_char?(text[after, 1])
      end
    end

    # One model, validated: what ModelsEmitter emits gen/models/<model>.rb
    # from, with nothing left to check. `source_table` is its table and
    # `model` its class name; `plans` the associations, resolved against
    # the schema (AssociationPlan); `encrypted_columns` the columns its file encrypts;
    # `scopes` its scopes; `view_methods` the instance methods a template
    # may call (those no column or association reader already answers);
    # `condition_methods` the if: / unless: names of its `validates` lines
    # and `custom_validations` its `validate` lines, every name of both a
    # method the model has; `counter_columns` the columns of the table that
    # another model's counter_cache counts in.
    class ValidatedModel
      attr_reader :source_table, :model, :plans, :encrypted_columns, :scopes, :view_methods, :condition_methods,
                  :custom_validations, :counter_columns

      def initialize(table, model, plans, encrypted, scopes, view_methods, condition_methods, custom_validations,
                     counter_columns)
        @source_table = table
        @model = model
        @plans = plans
        @encrypted_columns = encrypted
        @scopes = scopes
        @view_methods = view_methods
        @condition_methods = condition_methods
        @custom_validations = custom_validations
        @counter_columns = counter_columns
      end

      # The element a typed empty Array of these is declared with.
      def self.placeholder
        none = Array.new(0) { "" }
        ValidatedModel.new(Cybertrain::Schema::Table.new(""), "", ModelValidation.no_plans, none, ModelValidation.no_scopes,
                           none, none, ModelValidation.no_validations, none)
      end
    end

    # The semantic validation of the model generator (docs/design.md D69):
    # the stage between ModelScan, which reads app/models/*.rb as text and
    # refuses a declaration it cannot read, and ModelsEmitter, which writes
    # Ruby. It checks what a scan of one file cannot know -- the
    # declarations against db/schema.rb and against each other -- and
    # resolves them (the association plans, the encrypted columns, the
    # names the generated dispatch tables call) into one ValidatedModel per
    # table. Every refusal of a model is raised here or in the scan, with
    # the place of what it refuses: ModelScan::Error with the app/models
    # file and line for a declaration, ArgumentError for the schema, with
    # the db/schema.rb line when `places` has the file's text. Nothing here
    # writes source, so a test can ask for a diagnostic without emitting.
    module ModelValidation
      # A ValidatedModel per modelled table of `definition`, in the
      # schema's table order; `infos` are the scanned app/models files. The
      # first declaration or table that cannot be generated raises.
      def self.validate_all(definition, infos, places)
        out = Array.new(0) { ValidatedModel.placeholder }
        ModelNaming.modelled_tables(definition).each do |table|
          model = ModelNaming.model_class_name(table.name)
          out << validate_table(table, definition, view_methods_for(model, infos), scopes_for(model, infos), infos, places)
        end
        out
      end

      # The ValidatedModel of `table`. `view_methods` and `scopes` are its
      # model file's (given apart from `infos` so a caller without a file
      # can name them); `infos` every scanned model file: this model's
      # declarations, and the parent's has_many name a counter_cache column
      # is named after, come from them.
      def self.validate_table(table, definition, view_methods, scopes, infos, places)
        raise ArgumentError, "#{places.at(table.name, "")}table #{table.name} has no columns" if table.columns.empty?

        check_column_names(table, places)
        check_binary_defaults(table, places)
        check_scope_names(table, scopes)
        plans = association_plans(table, definition, infos, places)
        check_association_ivars(table, plans, places)
        model = ModelNaming.model_class_name(table.name)
        encrypted = encrypted_columns(model, table, infos)
        names = Array.new(0) { "" }
        validations = no_validations
        infos.each do |info|
          next unless info.class_name == model

          check_validation_methods(model, table, info, plans)
          names = info.condition_methods
          validations = info.custom_validations
        end
        ValidatedModel.new(table, model, plans, encrypted, scopes, dispatched_view_methods(table, plans, view_methods),
                           names, validations, counter_columns_on(table, definition, infos))
      end

      def self.no_plans
        Array.new(0) { AssociationPlan.new(:has_many, "", "", "", "", false, true, :none, true, false, "", false, []) }
      end

      def self.no_scopes
        Array.new(0) { ScopeInfo.new("", "", "", "", 0) }
      end

      def self.no_validations
        Array.new(0) { CustomValidationInfo.new("", "", "", "", "", 0) }
      end

      # The view methods ModelScan found for `class_name` (empty when its
      # app/models file is missing or defines none).
      def self.view_methods_for(class_name, infos)
        infos.each { |info| return info.view_methods if info.class_name == class_name }
        Array.new(0) { "" }
      end

      # The scopes ModelScan found for `class_name` (empty when its
      # app/models file is missing or declares none).
      def self.scopes_for(class_name, infos)
        infos.each { |info| return info.scopes if info.class_name == class_name }
        no_scopes
      end

      # The view methods call_view_method dispatches to: each once, without
      # those a column (either spelling) or an association reader answers.
      def self.dispatched_view_methods(table, plans, view_methods)
        taken = owned_names(table)
        plans.each { |plan| taken << plan.name }
        methods = Array.new(0) { "" }
        view_methods.each do |m|
          next if taken.include?(m) || methods.include?(m)

          methods << m
        end
        methods
      end

      # The columns `class_name`'s model file encrypts (`encrypts`), checked
      # against `table`: each must be one of its string or text columns,
      # else ModelScan::Error with the file and line. Empty when the file is
      # missing or declares none.
      def self.encrypted_columns(class_name, table, infos)
        out = Array.new(0) { "" }
        infos.each do |info|
          next unless info.class_name == class_name

          i = 0
          while i < info.encrypted.size
            name = info.encrypted[i]
            at = "#{info.file}:#{info.encrypted_lines[i]}: encrypts :#{name}"
            type = :none
            table.columns.each { |c| type = c.type if c.name == name }
            raise ModelScan::Error, "#{at} names no column of #{table.name}" if type == :none
            unless type == :string || type == :text
              raise ModelScan::Error, "#{at}: only a string or text column can be encrypted (#{name} is #{type})"
            end

            out << name
            i += 1
          end
          j = 0
          while j < info.unique_columns.size
            name = info.unique_columns[j]
            if info.encrypted.include?(name)
              raise ModelScan::Error, "#{info.file}:#{info.unique_lines[j]}: validates :#{name}, uniqueness: " \
                                      "#{name} is encrypted (encrypts :#{name}), and its stored payloads never " \
                                      "compare equal: uniqueness on an encrypted column is not supported"
            end
            j += 1
          end
        end
        out
      end

      # Each if: / unless: name of the `validates` lines and each name of a
      # `validate` line must be a method the model has -- a `def` in its
      # file or a column or association reader -- or this raises
      # ModelScan::Error with the file and line, rather than the generated
      # validation_condition? / run_custom_validations failing to compile.
      def self.check_validation_methods(model, table, info, plans)
        known = Array.new(0) { "" }
        info.defined_methods.each { |m| known << m }
        table.columns.each { |c| known << ModelNaming.reader_name(c.name) }
        plans.each { |plan| known << plan.name }
        where = info.file
        i = 0
        while i < info.condition_methods.size
          name = info.condition_methods[i]
          unless known.include?(name)
            raise ModelScan::Error, "#{where}:#{info.condition_lines[i]}: if: / unless: :#{name} names no method " \
                                    "of #{model}: define it in #{where} (the generated validation_condition? calls it)"
          end
          i += 1
        end
        info.custom_validations.each do |v|
          [v.name, v.condition_if, v.condition_unless].each do |name|
            next if name == "" || known.include?(name)

            what = name == v.name ? "validate :#{name}" : "validate :#{v.name}: if: / unless: :#{name}"
            raise ModelScan::Error, "#{where}:#{v.line}: #{what} names no method of #{model}: define it in " \
                                    "#{where} (the generated run_custom_validations calls it)"
          end
        end
        nil
      end

      # Raises ArgumentError (the generator exits non-zero) for a column the
      # generated class cannot host: not an ASCII Ruby method name
      # (Ident.column?: `[A-Za-z_][A-Za-z0-9_]*`), or one whose fallback
      # `<column>_column` another column already owns. A reserved name or a
      # keyword alone is not an error (reader_name renames it), and a column
      # named like another Object method (Ident::SHADOWING_COLUMN_NAMES,
      # `display`, `tap`) is accepted with a note in the generated file: an
      # existing schema must keep generating. `cybertrain generate scaffold`
      # is stricter (and wants snake_case): it refuses keywords, reserved and
      # shadowing names before it writes any file, since it invents them.
      def self.check_column_names(table, places)
        names = table.columns.map { |c| c.name }
        table.columns.each do |c|
          name = c.name
          unless Ident.column?(name)
            raise ArgumentError, "#{places.at(table.name, name)}table #{table.name}: column #{name.inspect} is not " \
                                 "a valid attribute name (a column name is an ASCII identifier: ASCII letters, digits and _, " \
                                 "not starting with a digit)"
          end
          next unless ModelNaming.renamed?(name)

          fallback = ModelNaming.reader_name(name)
          # The fallback is `<column>_column`, which no RESERVED_COLUMN_NAMES
          # entry or keyword ends in, so the only way it is taken is by
          # another column of the table.
          if names.include?(fallback)
            raise ArgumentError, "#{places.at(table.name, name)}table #{table.name}: column #{name.inspect} can be " \
                                 "neither #{name.inspect} nor #{fallback.inspect} (a Ruby keyword or a Cybertrain::Model " \
                                 "or Object method owns the first, another column of the table owns the " \
                                 "second); rename a column"
          end
        end
        nil
      end

      # A binary column's default would have to be bytes the model writes
      # into the ivar; initial_value has no literal for it and would fall
      # back to "", silently replacing the declared default (INSERT writes
      # every column, so the database's DEFAULT never applies).
      def self.check_binary_defaults(table, places)
        table.columns.each do |c|
          next unless c.type == :binary

          raw = c.default
          next if raw.nil? || raw.strip.upcase == "NULL"

          raise ArgumentError, "#{places.at(table.name, c.name)}table #{table.name}: column #{c.name.inspect} is a " \
                               "binary column with a default (#{raw}); a BLOB column takes no default, set the bytes in " \
                               "the model instead"
        end
        nil
      end

      # A scope named like a column (either spelling: reader_name) or `id`
      # raises ModelScan::Error, like the scan's own scope checks; Relation
      # method names were refused by ModelScan.scope_on already.
      def self.check_scope_names(table, scopes)
        scopes.each do |scope|
          name = scope.name
          clash = name == "id" ? "id" : ""
          table.columns.each { |c| clash = c.name if c.name == name || ModelNaming.reader_name(c.name) == name }
          next if clash == ""

          raise ModelScan::Error, "#{scope.file}:#{scope.line}: scope :#{name} clashes with the column #{clash} " \
                                  "of table #{table.name}; rename the scope"
        end
        nil
      end

      # The name of a foreign-key-derived association reader: `plain`, or
      # `fallback` when a column, another association or a reserved name
      # owns it (association_plans says why); only both names being owned is
      # an error.
      def self.association_name(table, plain, fallback, kind, taken, assoc_names, places)
        return plain unless owned?(plain, taken, assoc_names)

        if owned?(fallback, taken, assoc_names)
          raise ArgumentError, "#{places.at(table.name, "")}table #{table.name}: the #{kind} association can be " \
                               "neither #{plain.inspect} nor #{fallback.inspect} (a column, another association, a " \
                               "Cybertrain::Model method or a Ruby keyword owns each); rename a column"
        end
        fallback
      end

      def self.owned?(name, taken, assoc_names)
        taken.include?(name) || assoc_names.include?(name) || Ident.keyword?(name) || Ident.reserved_column?(name)
      end

      # A keyword is not a method of anything: say so instead of the
      # Model-method wording (the other cases keep their exact text).
      def self.association_note(kind, plain, name)
        if Ident.keyword?(plain)
          return "# #{kind} reads as #{name}: #{plain.inspect} is a Ruby keyword"
        end

        "# #{kind} reads as #{name}: #{plain.inspect} is a column, another association or a Cybertrain::Model method"
      end

      # Both spellings of every column, and `id`: names an association
      # reader cannot take (a reserved column's SQL name and its reader
      # differ, so an association cannot land on a renamed reader).
      def self.owned_names(table)
        taken = table.columns.map { |c| c.name }
        table.columns.each { |c| taken << ModelNaming.reader_name(c.name) }
        taken << "id"
        taken
      end

      # The associations of `table`'s model, in reader order: the ones its
      # app/models file declares (spec 7.1), in source order, then the ones
      # the schema's foreign keys give (D10) -- a belongs_to per foreign key
      # of this table, a has_many per foreign key pointing here -- except
      # those a declaration covers (same foreign key column: the declared
      # options and name win; a declared has_one suppresses the has_many).
      #
      # A derived reader's name must be free: not a column, not another
      # association, not a Ruby keyword, not a method of Cybertrain::Model
      # or Object that the framework calls (`errors`, `attributes`, `raise`,
      # ... -- Ident). When the plain name is owned, the reader takes the
      # fallback instead of being dropped or aborting the generator (which
      # would break an existing schema on upgrade): `<table>_as_<stem>` for a
      # has_many, `<stem>_as_<column>` for a belongs_to, and the generated
      # file carries a note. A declared name is the developer's choice, so an
      # owned one is an error (declared_plan).
      def self.association_plans(table, definition, infos, places)
        taken = owned_names(table)
        assoc_names = Array.new(0) { "" }
        plans = no_plans
        associations_for(ModelNaming.model_class_name(table.name), infos).each do |a|
          plan = declared_plan(table, definition, infos, a, taken, assoc_names)
          assoc_names << plan.name
          plans << plan
        end

        # belongs_to: comments.post_id -> def post (posts.author_id next to an
        # `author` column -> def author_as_author_id)
        table.foreign_keys.each do |fk|
          col = fk.column
          column = table.column(col)
          next unless col.end_with?("_id") && !column.nil?
          next if declared_key?(plans, :belongs_to, table.name, col)

          plain = col[0, col.size - 3]
          name = association_name(table, plain, plain + "_as_" + col, "belongs_to (from #{col})", taken, assoc_names, places)
          assoc_names << name
          notes = Array.new(0) { "" }
          notes << association_note("belongs_to " + col, plain, name) if name != plain
          notes << ModelNaming.shadow_note("belongs_to reader", name) if Ident.shadowing_column?(name)
          plans << AssociationPlan.new(:belongs_to, name, ModelNaming.model_class_name(fk.to_table), fk.to_table, col, column.null,
                                       column.type == :integer, :none, true, false, "", false, notes)
        end

        # has_many: another table's foreign key pointing here -> def comments.
        # When that table points here through more than one column
        # (messages.sender_id and messages.recipient_id both -> users), each
        # gets its own name, `<table>_as_<column stem>` (def messages_as_sender,
        # def messages_as_recipient), so no key is dropped and the names do
        # not depend on declaration order; the same name is the fallback when
        # a column, a belongs_to reader or a Model method owns the plain one
        # (articles.comments TEXT next to comments.article_id -> def
        # comments_as_article).
        definition.tables.each do |other|
          next if other.name == table.name
          next if other.without_id? # no model to read (ModelNaming.modelled_tables)

          pointing = other.foreign_keys.select { |fk| fk.to_table == table.name }
          pointing.each do |fk|
            next if declared_key?(plans, :has_many, other.name, fk.column)

            as_stem = other.name + "_as_" + ModelNaming.column_stem(fk.column)
            # Two FKs: the plain name is already the `_as_<stem>` form, so the
            # fallback uses the whole column (messages_as_sender_id).
            plain = pointing.size > 1 ? as_stem : other.name
            fallback = pointing.size > 1 ? other.name + "_as_" + fk.column : as_stem
            name = association_name(table, plain, fallback, "has_many (#{other.name}.#{fk.column})", taken, assoc_names,
                                    places)
            assoc_names << name
            notes = Array.new(0) { "" }
            notes << association_note("has_many #{other.name}", plain, name) if name != plain
            notes << ModelNaming.shadow_note("has_many reader", name) if Ident.shadowing_column?(name)
            plans << AssociationPlan.new(:has_many, name, ModelNaming.model_class_name(other.name), other.name, fk.column, false,
                                         true, :none, true, false, "", false, notes)
          end
        end
        plans
      end

      # Whether a declared association already covers the foreign key `col`:
      # a belongs_to on this table's column, or (kind :has_many) a has_many
      # or has_one whose children live in `table_name`.
      def self.declared_key?(plans, kind, table_name, col)
        plans.each do |plan|
          next unless plan.declared && plan.foreign_key == col

          if kind == :belongs_to
            return true if plan.kind == :belongs_to
          elsif plan.kind != :belongs_to && plan.target_table == table_name
            return true
          end
        end
        false
      end

      # The AssociationInfos ModelScan found for `class_name` (empty when its
      # app/models file is missing or declares none).
      def self.associations_for(class_name, infos)
        infos.each { |info| return info.associations if info.class_name == class_name }
        Array.new(0) { AssociationInfo.new("", :has_many, "", "", "", :none, false, false, 0) }
      end

      # The table whose generated model is `class_name`, or nil.
      def self.table_for_model(definition, class_name)
        definition.tables.each { |t| return t if !t.without_id? && ModelNaming.model_class_name(t.name) == class_name }
        nil
      end

      # The model a declaration names: its class_name, else has_many
      # `comments` -> Comment, has_one / belongs_to `author` -> Author.
      def self.declared_class(a)
        return a.class_name if a.class_name != ""

        a.kind == :has_many ? ModelNaming.model_class_name(a.name) : Inflector.camelize(a.name)
      end

      # The foreign key column a declaration uses: its foreign_key, else
      # belongs_to `author` -> author_id (on this table), has_many / has_one
      # -> `<singular of this table>_id` (on the children's table).
      def self.declared_key(a, table)
        return a.foreign_key if a.foreign_key != ""

        a.kind == :belongs_to ? a.name + "_id" : Inflector.singularize(table.name) + "_id"
      end

      # The counter column of `belongs_to :post, counter_cache: true` on
      # `child`: `<has_many name>_count` on the parent, from the parent's
      # declared has_many over the same foreign key, else `<child table>_count`
      # (posts.comments_count).
      def self.counter_column(child, fk, parent, infos)
        associations_for(ModelNaming.model_class_name(parent.name), infos).each do |h|
          next unless h.kind == :has_many && declared_class(h) == ModelNaming.model_class_name(child.name)
          return h.name + "_count" if declared_key(h, parent) == fk
        end
        child.name + "_count"
      end

      # A declared association, resolved against the schema; raises
      # ModelScan::Error with the declaration's file and line when its model
      # or foreign key column does not exist, its reader name is owned
      # (owned?), `dependent: :nullify` names a NOT NULL key, or
      # `counter_cache` names a missing counter column.
      def self.declared_plan(table, definition, infos, a, taken, assoc_names)
        at = "#{a.file}:#{a.line}: #{a.kind} :#{a.name}: "
        cls = declared_class(a)
        target = table_for_model(definition, cls)
        raise ModelScan::Error, at + "#{cls} is not a model (no table of db/schema.rb generates it); set class_name:" if target.nil?

        fk = declared_key(a, table)
        owner = a.kind == :belongs_to ? table : target
        column = owner.column(fk)
        raise ModelScan::Error, at + "no column #{owner.name}.#{fk} for its foreign key; set foreign_key:" if column.nil?

        if owned?(a.name, taken, assoc_names)
          raise ModelScan::Error, at + "the reader #{a.name} is taken (a column, another association, a " \
                                       "Cybertrain::Model method or a Ruby keyword); rename the association and set " \
                                       "class_name: and foreign_key:"
        end
        if a.dependent == :nullify && !column.null
          raise ModelScan::Error, at + "dependent: :nullify needs #{owner.name}.#{fk} to be nullable"
        end

        counter = ""
        if a.counter_cache
          counter = counter_column(table, fk, target, infos)
          counted = target.column(counter)
          if counted.nil? || counted.type != :integer
            raise ModelScan::Error, at + "counter_cache: needs the integer column #{target.name}.#{counter}"
          end
        end
        notes = Array.new(0) { "" }
        notes << ModelNaming.shadow_note("#{a.kind} reader", a.name) if Ident.shadowing_column?(a.name)
        AssociationPlan.new(a.kind, a.name, cls, target.name, fk, column.null, column.type == :integer, a.dependent,
                            a.optional, a.counter_cache, counter, true, notes)
      end

      # The ivars an association keeps its cache in (spec 7.2; Task 12's
      # includes fills them): has_many `@<name>_preloaded` (nil or an Array),
      # belongs_to `@<name>_loaded` / `_loaded_key` / `_record` (plus
      # `@<foreign key>_was` under counter_cache), has_one `@<name>_loaded` /
      # `_record`.
      def self.cache_ivars(plan)
        n = "@" + plan.name
        return [n + "_preloaded"] if plan.kind == :has_many
        return [n + "_loaded", n + "_record"] if plan.kind == :has_one

        list = [n + "_loaded", n + "_loaded_key", n + "_record"]
        if plan.counter_cache
          list << ModelNaming.ivar_name(plan.foreign_key) + "_was"
          list << "@counter_cache_found"
        end
        list
      end

      # A column whose ivar is one an association caches in would be
      # overwritten by it: ArgumentError.
      def self.check_association_ivars(table, plans, places)
        plans.each do |plan|
          cache_ivars(plan).each do |iv|
            table.columns.each do |c|
              next unless ModelNaming.ivar_name(c.name) == iv

              raise ArgumentError, "#{places.at(table.name, c.name)}table #{table.name}: column #{c.name.inspect} " \
                                   "is the ivar #{iv} the #{plan.name} association caches in; rename the column"
            end
          end
        end
        nil
      end

      # The columns of `table` that another model's `belongs_to ...,
      # counter_cache: true` counts in (posts.comments_count), from every
      # scanned declaration; errors in those declarations are left to that
      # model's own file.
      def self.counter_columns_on(table, definition, infos)
        out = Array.new(0) { "" }
        infos.each do |info|
          child = table_for_model(definition, info.class_name)
          next if child.nil?

          info.associations.each do |a|
            next unless a.kind == :belongs_to && a.counter_cache && declared_class(a) == ModelNaming.model_class_name(table.name)

            name = counter_column(child, declared_key(a, child), table, infos)
            out << name unless table.column(name).nil? || out.include?(name)
          end
        end
        out
      end
    end
  end
end
