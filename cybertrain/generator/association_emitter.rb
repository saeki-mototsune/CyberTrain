require "cybertrain/schema"
require "cybertrain/generator/inflector"
require "cybertrain/ident"
require "cybertrain/generator/model_scan"

module Cybertrain
  module Gen
    # One association of a generated model, resolved against the schema
    # (ModelsEmitter.association_plans): `kind` (:has_many, :has_one,
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

    # The association half of ModelsEmitter (spec section 7): planning the
    # declared and foreign-key-derived associations of a model and emitting
    # their readers, caches, `dependent:`, counter_cache and
    # read_association. models_emitter.rb calls these and owns the rest.
    module ModelsEmitter
      # The name of a foreign-key-derived association reader: `plain`, or
      # `fallback` when a column, another association or a reserved name
      # owns it (association_plans says why); only both names being owned is
      # an error.
      def self.association_name(table, plain, fallback, kind, taken, assoc_names)
        return plain unless owned?(plain, taken, assoc_names)

        if owned?(fallback, taken, assoc_names)
          raise ArgumentError, "table #{table.name}: the #{kind} association can be neither #{plain.inspect} nor " \
                               "#{fallback.inspect} (a column, another association, a Cybertrain::Model method or a " \
                               "Ruby keyword owns each); rename a column"
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
        table.columns.each { |c| taken << reader_name(c.name) }
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
      def self.association_plans(table, definition, infos)
        taken = owned_names(table)
        assoc_names = Array.new(0) { "" }
        plans = Array.new(0) { AssociationPlan.new(:has_many, "", "", "", "", false, true, :none, true, false, "", false, []) }
        associations_for(model_class_name(table.name), infos).each do |a|
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
          name = association_name(table, plain, plain + "_as_" + col, "belongs_to (from #{col})", taken, assoc_names)
          assoc_names << name
          notes = Array.new(0) { "" }
          notes << association_note("belongs_to " + col, plain, name) if name != plain
          notes << shadow_note("belongs_to reader", name) if Ident.shadowing_column?(name)
          plans << AssociationPlan.new(:belongs_to, name, model_class_name(fk.to_table), fk.to_table, col, column.null,
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

          pointing = other.foreign_keys.select { |fk| fk.to_table == table.name }
          pointing.each do |fk|
            next if declared_key?(plans, :has_many, other.name, fk.column)

            as_stem = other.name + "_as_" + column_stem(fk.column)
            # Two FKs: the plain name is already the `_as_<stem>` form, so the
            # fallback uses the whole column (messages_as_sender_id).
            plain = pointing.size > 1 ? as_stem : other.name
            fallback = pointing.size > 1 ? other.name + "_as_" + fk.column : as_stem
            name = association_name(table, plain, fallback, "has_many (#{other.name}.#{fk.column})", taken, assoc_names)
            assoc_names << name
            notes = Array.new(0) { "" }
            notes << association_note("has_many #{other.name}", plain, name) if name != plain
            notes << shadow_note("has_many reader", name) if Ident.shadowing_column?(name)
            plans << AssociationPlan.new(:has_many, name, model_class_name(other.name), other.name, fk.column, false,
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
        definition.tables.each { |t| return t if model_class_name(t.name) == class_name }
        nil
      end

      # The model a declaration names: its class_name, else has_many
      # `comments` -> Comment, has_one / belongs_to `author` -> Author.
      def self.declared_class(a)
        return a.class_name if a.class_name != ""

        a.kind == :has_many ? model_class_name(a.name) : Inflector.camelize(a.name)
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
        associations_for(model_class_name(parent.name), infos).each do |h|
          next unless h.kind == :has_many && declared_class(h) == model_class_name(child.name)
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
        notes << shadow_note("#{a.kind} reader", a.name) if Ident.shadowing_column?(a.name)
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
          list << ivar_name(plan.foreign_key) + "_was"
          list << "@counter_cache_found"
        end
        list
      end

      # A column whose ivar is one an association caches in would be
      # overwritten by it: ArgumentError.
      def self.check_association_ivars(table, plans)
        plans.each do |plan|
          cache_ivars(plan).each do |iv|
            table.columns.each do |c|
              next unless ivar_name(c.name) == iv

              raise ArgumentError, "table #{table.name}: column #{c.name.inspect} is the ivar #{iv} the #{plan.name} " \
                                   "association caches in; rename the column"
            end
          end
        end
        nil
      end

      # The cache ivars' starting values, for `initialize`.
      def self.association_ivars(plan)
        n = "@" + plan.name
        return "    #{n}_preloaded = nil\n" if plan.kind == :has_many
        return "    #{n}_loaded = false\n    #{n}_record = nil\n" if plan.kind == :has_one

        src = +"    #{n}_loaded = false\n    #{n}_loaded_key = 0\n    #{n}_record = nil\n"
        src << "    #{ivar_name(plan.foreign_key)}_was = #{plan.fk_null ? "nil" : "0"}\n" if plan.counter_cache
        src
      end

      # A reader (spec 7.2). has_many: the children's Relation, so
      # `post.comments.where(...).count` chains, created preloaded with the
      # records includes left in the cache (spec 8: to_a, each, first,
      # last, size and empty? answer from memory until a chain method).
      # belongs_to: the parent, cached with the foreign key it was read
      # for, so a reassigned key never answers the old parent; a nil key
      # answers nil. has_one: the preload cache when includes filled it,
      # else a query.
      def self.association_reader(plan)
        n = plan.name
        if plan.kind == :has_many
          return "  def #{n}\n    rel = #{children_relation(plan)}\n    return rel if @#{n}_preloaded.nil?\n\n" \
                 "    rel.preloaded(@#{n}_preloaded)\n  end\n"
        end
        if plan.kind == :has_one
          return "  def #{n}\n    return @#{n}_record if @#{n}_loaded\n\n" \
                 "    #{plan.model}.find_by(#{plan.foreign_key}: @id)\n  end\n"
        end

        key = ivar_name(plan.foreign_key)
        src = +"  def #{n}\n"
        src << "    return nil if #{key}.nil?\n" if plan.fk_null
        src << "    return @#{n}_record if @#{n}_loaded && @#{n}_loaded_key == #{key}\n"
        src << "\n"
        src << "    @#{n}_record = #{plan.model}.find_by(id: #{key})\n"
        src << "    @#{n}_loaded = true\n"
        # The key is an Integer ivar: a nullable (or non-integer) column's
        # value goes through Cast.int (nil was answered above).
        stored = plan.fk_null || !plan.fk_integer ? "Cybertrain::Cast.int(#{key})" : key
        src << "    @#{n}_loaded_key = #{stored}\n"
        src << "    @#{n}_record\n"
        src << "  end\n"
        src
      end

      # `<name>_preload!(value)`, which the Relation's preload_association
      # calls on each record to fill the reader's cache (a `!` name, so no
      # column reader can be spelled like it): has_many the children's
      # Array, belongs_to the parent (or nil) with the key it was read for,
      # has_one the child (or nil).
      def self.association_preload_setter(plan)
        n = plan.name
        if plan.kind == :has_many
          return "  def #{n}_preload!(records)\n    @#{n}_preloaded = records\n    nil\n  end\n"
        end
        return "  def #{n}_preload!(found)\n    @#{n}_record = found\n    @#{n}_loaded = true\n    nil\n  end\n" if plan.kind == :has_one

        key = ivar_name(plan.foreign_key)
        stored = plan.fk_null || !plan.fk_integer ? "Cybertrain::Cast.int(#{key})" : key
        "  def #{n}_preload!(found)\n    @#{n}_record = found\n    @#{n}_loaded = true\n" \
          "    @#{n}_loaded_key = #{stored}\n    nil\n  end\n"
      end

      # The Relation's `includes(*names)` (spec 8): each name checked by a
      # `case` over the model's associations (no computed send, NOTES rule
      # 1), an unknown one an ArgumentError; `preload` is the same. With no
      # association every name is unknown.
      def self.emit_includes(model, plans)
        src = +"  def includes(*names)\n"
        if plans.empty?
          src << "    raise ArgumentError, \"unknown association \#{names[0]} for #{model}\" unless names.empty?\n"
          src << "\n"
        else
          src << "    names.each do |name|\n"
          src << "      case name\n"
          src << "      when #{plans.map { |plan| ":" + plan.name }.join(", ")} then add_include(name)\n"
          src << "      else raise ArgumentError, \"unknown association \#{name} for #{model}\"\n"
          src << "      end\n"
          src << "    end\n"
        end
        src << "    self\n"
        src << "  end\n"
        src << "\n"
        src << "  def preload(*names) = includes(*names)\n"
        src << "\n"
        src << "  def preloaded(records)\n"
        src << "    @preloaded = records\n"
        src << "    mark_records_preloaded\n"
        src << "    self\n"
        src << "  end\n"
        src << "\n"
        src
      end

      # `expr`, the value of a foreign key column, as the Integer it is
      # matched by: a nullable or non-integer column through Cast.int.
      def self.key_expr(plan, expr)
        plan.fk_null || !plan.fk_integer ? "Cybertrain::Cast.int(#{expr})" : expr
      end

      # The Relation's `preload_association(name, records)`, which to_a
      # runs for each included name: per association, one query per chunk
      # of at most Connection#variable_limit ids, its rows distributed into
      # every record's cache through `<name>_preload!` -- has_many an
      # Array per record (empty for a record with no child), belongs_to
      # and has_one the row or nil -- so no reader queries again. No
      # statement for no records. The Hashes are seeded with the concrete
      # types (NOTES rule 9). "" without associations (the base stub).
      def self.emit_preload_association(plans)
        return "" if plans.empty?

        src = +"\n  def preload_association(name, records)\n"
        src << "    return nil if records.empty?\n"
        src << "\n"
        src << "    step = Cybertrain::DB.with { |c| c.variable_limit }\n"
        src << "    case name\n"
        plans.each do |plan|
          src << "    when :#{plan.name}\n"
          src << (plan.kind == :belongs_to ? preload_parents(plan) : preload_children(plan))
        end
        src << "    end\n"
        src << "    nil\n"
        src << "  end\n"
        src
      end

      # The `when` body for a has_many / has_one: the records' ids, the
      # children `where(fk: ids)` in id order (so the preloaded first and
      # last are the queried ones) grouped (has_many) or indexed, lowest id
      # kept (has_one, as its reader's find_by), by their foreign key.
      def self.preload_children(plan)
        many = plan.kind == :has_many
        fk = reader_name(plan.foreign_key)
        src = +"      ids = Array.new(0) { 0 }\n"
        if many
          src << "      groups = { 0 => Array.new(0) { #{plan.model}.new } }\n"
          src << "      groups.delete(0)\n"
        else
          src << "      index = { 0 => #{plan.model}.new }\n"
          src << "      index.delete(0)\n"
        end
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << "        ids << records[i].id\n"
        src << "        groups[records[i].id] = Array.new(0) { #{plan.model}.new }\n" if many
        src << "        i += 1\n"
        src << "      end\n"
        src << "      start = 0\n"
        src << "      while start < ids.size\n"
        src << "        found = #{plan.model}Relation.new(\"#{plan.target_table}\").where(#{plan.foreign_key}: ids[start, step])" \
               ".order(id: :asc).to_a\n"
        src << "        j = 0\n"
        src << "        while j < found.size\n"
        src << "          key = #{key_expr(plan, "found[j].#{fk}")}\n"
        if many
          src << "          list = groups[key]\n"
          src << "          list << found[j] unless list.nil?\n"
        else
          src << "          index[key] = found[j] unless index.key?(key)\n"
        end
        src << "          j += 1\n"
        src << "        end\n"
        src << "        start += step\n"
        src << "      end\n"
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << "        records[i].#{plan.name}_preload!(#{many ? "groups" : "index"}[records[i].id])\n"
        src << "        i += 1\n"
        src << "      end\n"
        src
      end

      # The `when` body for a belongs_to: the records' distinct non-nil
      # keys, the parents `where(id: keys)` indexed by id; a record whose
      # parent is missing gets nil.
      def self.preload_parents(plan)
        fk = reader_name(plan.foreign_key)
        src = +"      ids = Array.new(0) { 0 }\n"
        src << "      seen = { 0 => true }\n"
        src << "      seen.delete(0)\n"
        src << "      index = { 0 => #{plan.model}.new }\n"
        src << "      index.delete(0)\n"
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        if plan.fk_null
          src << "        raw = records[i].#{fk}\n"
          src << "        key = #{key_expr(plan, "raw")}\n"
          src << "        unless raw.nil? || seen.key?(key)\n"
        else
          src << "        key = #{key_expr(plan, "records[i].#{fk}")}\n"
          src << "        unless seen.key?(key)\n"
        end
        src << "          seen[key] = true\n"
        src << "          ids << key\n"
        src << "        end\n"
        src << "        i += 1\n"
        src << "      end\n"
        src << "      start = 0\n"
        src << "      while start < ids.size\n"
        src << "        found = #{plan.model}Relation.new(\"#{plan.target_table}\").where(id: ids[start, step]).to_a\n"
        src << "        j = 0\n"
        src << "        while j < found.size\n"
        src << "          index[found[j].id] = found[j]\n"
        src << "          j += 1\n"
        src << "        end\n"
        src << "        start += step\n"
        src << "      end\n"
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << "        records[i].#{plan.name}_preload!(index[#{key_expr(plan, "records[i].#{fk}")}])\n"
        src << "        i += 1\n"
        src << "      end\n"
        src
      end

      # The `<Model>Relation` over the children of a has_many / has_one.
      def self.children_relation(plan)
        "#{plan.model}Relation.new(\"#{plan.target_table}\").where(#{plan.foreign_key}: @id)"
      end

      # `destroy_dependents`, which Model#destroy runs inside its
      # transaction before the DELETE: per `dependent:`, the children
      # destroyed one by one (their callbacks run), one DELETE, or one
      # UPDATE setting the key to NULL. "" when nothing is dependent (the
      # base method's nil; the database's foreign key decides).
      def self.emit_destroy_dependents(plans)
        body = +""
        plans.each do |plan|
          case plan.dependent
          when :destroy then body << "    #{children_relation(plan)}.destroy_all\n"
          when :delete_all then body << "    #{children_relation(plan)}.delete_all\n"
          when :nullify then body << "    #{children_relation(plan)}.update_all(#{plan.foreign_key}: nil)\n"
          end
        end
        return "" if body == ""

        "  def destroy_dependents\n" + body + "    nil\n  end\n\n"
      end

      # `reset_association_caches`, which Model#reload calls: every cache
      # back to empty. "" without associations (the base method's nil).
      def self.emit_reset_association_caches(plans)
        return "" if plans.empty?

        src = +"  def reset_association_caches\n"
        plans.each do |plan|
          n = "@" + plan.name
          if plan.kind == :has_many
            src << "    #{n}_preloaded = nil\n"
          else
            src << "    #{n}_loaded = false\n    #{n}_record = nil\n"
          end
        end
        src << "    nil\n  end\n\n"
        src
      end

      # The class-body lines declarations add (after emit_date_presence): a
      # declared belongs_to without `optional: true` validates its foreign
      # key (validates_foreign_key: nil or 0, the id of no saved record, is
      # blank); counter_cache registers the four callbacks, each a block
      # calling the generated method (Model#save runs the update in one
      # transaction for such a model: counter_cached?).
      def self.emit_association_rules(plans)
        src = +""
        plans.each do |plan|
          next unless plan.declared && plan.kind == :belongs_to && !plan.optional

          src << "  validates_foreign_key :#{plan.foreign_key}\n"
        end
        unless plans.select { |plan| plan.counter_cache }.empty?
          src << "  after_create { |record| record.counter_cache_created }\n"
          src << "  before_update { |record| record.counter_cache_was }\n"
          src << "  after_update { |record| record.counter_cache_moved }\n"
          src << "  before_destroy { |record| record.counter_cache_was }\n"
          src << "  after_destroy { |record| record.counter_cache_destroyed }\n"
        end
        src << "\n" unless src == ""
        src
      end

      # The counter_cache methods (spec 7.2): increment the parent's counter
      # after create; for an update or a destroy, read the persisted foreign
      # key inside the transaction (before_update / before_destroy:
      # counter_cache_was, which also notes whether the row was there), then
      # move one count from the old parent to the new one when it changed
      # (after_update) or take one from the persisted parent (after_destroy).
      # The key is read from the row, not kept from load time, so a second
      # instance of the same child, an unsaved reassignment or a rolled-back
      # save leaves no stale key; a row already gone, or a nil key, counts
      # nothing. "" without counter_cache.
      def self.emit_counter_cache(table, plans)
        cached = plans.select { |plan| plan.counter_cache }
        return "" if cached.empty?

        src = +"  def counter_cached? = true\n\n"
        src << "  def counter_cache_created\n"
        cached.each { |plan| src << "    #{counter_update(plan, ivar_name(plan.foreign_key), 1)}\n" }
        src << "    nil\n  end\n\n"
        src << "  def counter_cache_destroyed\n"
        src << "    return nil unless @counter_cache_found\n\n"
        cached.each do |plan|
          key = ivar_name(plan.foreign_key) + "_was"
          guard = plan.fk_null ? " unless #{key}.nil?" : ""
          src << "    #{counter_update(plan, key, -1)}#{guard}\n"
        end
        src << "    nil\n  end\n\n"
        columns = cached.map { |plan| "\\\"#{plan.foreign_key}\\\"" }.join(", ")
        sql = "SELECT #{columns} FROM \\\"#{table.name}\\\" WHERE \\\"id\\\" = ?"
        src << "  def counter_cache_was\n"
        src << "    id = @id\n"
        src << "    found = Cybertrain::DB.with { |c| c.execute(\"#{sql}\", [id]) }\n"
        src << "    @counter_cache_found = !found.empty?\n"
        cached.each do |plan|
          cast = plan.fk_null ? "int_or_nil" : "int"
          src << "    #{ivar_name(plan.foreign_key)}_was = Cybertrain::Cast.#{cast}(found.empty? ? nil : " \
                 "found[0][\"#{plan.foreign_key}\"])\n"
        end
        src << "    nil\n  end\n\n"
        src << "  def counter_cache_moved\n"
        src << "    return nil unless @counter_cache_found\n\n"
        cached.each do |plan|
          key = ivar_name(plan.foreign_key)
          src << "    unless #{key}_was == #{key}\n"
          src << "      #{counter_update(plan, key + "_was", -1)}\n"
          src << "      #{counter_update(plan, key, 1)}\n"
          src << "    end\n"
        end
        src << "    nil\n  end\n\n"
        src
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
            next unless a.kind == :belongs_to && a.counter_cache && declared_class(a) == model_class_name(table.name)

            name = counter_column(child, declared_key(a, child), table, infos)
            out << name unless table.column(name).nil? || out.include?(name)
          end
        end
        out
      end

      # `counter_cache_columns`, the columns Model#update_row leaves out of
      # this model's UPDATE (the children keep them; Rails' attr_readonly).
      # "" when there are none (the base method's empty Array).
      def self.emit_counter_cache_columns(names)
        return "" if names.empty?

        "  def counter_cache_columns = [#{names.map { |n| "\"#{n}\"" }.join(", ")}]\n\n"
      end

      # `PostRelation.new("posts").where(id: @post_id).increment(:comments_count, by: 1)`
      def self.counter_update(plan, key, by)
        "#{plan.model}Relation.new(\"#{plan.target_table}\").where(id: #{key}).increment(:#{plan.counter_column}, by: #{by})"
      end

      # read_association: the reader, a has_many's Relation as an Array (the
      # template interpreter iterates it), or a one-line nil stub.
      def self.emit_read_association(plans)
        return "  def read_association(name) = nil\n" if plans.empty?

        src = +"  def read_association(name)\n"
        src << "    case name\n"
        # `self.` because a reader may be capitalised (Ident.column? admits
        # `Author_id` -> def Author): bare, Ruby would read `Author` as a
        # constant.
        plans.each do |plan|
          tail = plan.kind == :has_many ? ".to_a" : ""
          src << "    when :#{plan.name} then self.#{plan.name}#{tail}\n"
        end
        src << "    else nil\n"
        src << "    end\n"
        src << "  end\n"
        src
      end

      # "sender_id" -> "sender"; a column without the suffix is its own stem.
      def self.column_stem(column)
        column.end_with?("_id") ? column[0, column.size - 3] : column
      end
    end
  end
end
