require "cybertrain/schema"
require "cybertrain/generator/inflector"
require "cybertrain/ident"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/model_validation"

module Cybertrain
  module Gen
    # The association half of ModelsEmitter (spec section 7): emitting the
    # readers, caches, `dependent:`, counter_cache and read_association of
    # a model's associations from their AssociationPlans. Planning them
    # (the declared and the foreign-key-derived ones) and every check of
    # them is ModelValidation's. models_emitter.rb calls these and owns the
    # rest.
    module ModelsEmitter
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

    end
  end
end
