require "cybertrain/schema"
require "cybertrain/generator/inflector"
require "cybertrain/ident"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/model_validation"

module Cybertrain
  module Gen
    # The association half of ModelsEmitter (docs/design.md D47): emitting the
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
        src << "    #{n}_loaded_type = \"\"\n" if plan.polymorphic?
        src << "    #{ivar_name(plan.foreign_key)}_was = #{plan.fk_null ? "nil" : "0"}\n" if plan.counter_cache
        src
      end

      # A reader. has_many: the children's Relation, so
      # `post.comments.where(...).count` chains, created preloaded with the
      # records includes left in the cache (to_a, each, first,
      # last, size and empty? answer from memory until a chain method).
      # belongs_to: the parent, cached with the foreign key it was read
      # for, so a reassigned key never answers the old parent; a nil key
      # answers nil. has_one: the preload cache when includes filled it,
      # else a query. A polymorphic belongs_to: polymorphic_reader, then
      # its writer.
      def self.association_reader(plan)
        n = plan.name
        return polymorphic_reader(plan) + "\n" + polymorphic_writer(plan) if plan.polymorphic?

        if plan.kind == :has_many
          rel = plan.through? ? through_relation(plan) : children_relation(plan)
          return "  def #{n}\n    rel = #{rel}\n    return rel if @#{n}_preloaded.nil?\n\n" \
                 "    rel.preloaded(@#{n}_preloaded)\n  end\n"
        end
        if plan.kind == :has_one
          return "  def #{n}\n    return @#{n}_record if @#{n}_loaded\n\n" \
                 "    #{plan.model}.find_by(#{type_condition(plan)}#{plan.foreign_key}: @id)\n  end\n"
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
      # has_one the child (or nil); a polymorphic belongs_to the parent with
      # the type and the key it was read for.
      def self.association_preload_setter(plan)
        n = plan.name
        if plan.polymorphic?
          return "  def #{n}_preload!(found)\n    @#{n}_record = found\n    @#{n}_loaded = true\n" \
                 "    @#{n}_loaded_type = Cybertrain::Cast.str(#{ivar_name(plan.type_column)})\n" \
                 "    @#{n}_loaded_key = #{key_expr(plan, ivar_name(plan.foreign_key))}\n    nil\n  end\n"
        end
        if plan.kind == :has_many
          return "  def #{n}_preload!(records)\n    @#{n}_preloaded = records\n    nil\n  end\n"
        end
        return "  def #{n}_preload!(found)\n    @#{n}_record = found\n    @#{n}_loaded = true\n    nil\n  end\n" if plan.kind == :has_one

        key = ivar_name(plan.foreign_key)
        stored = plan.fk_null || !plan.fk_integer ? "Cybertrain::Cast.int(#{key})" : key
        "  def #{n}_preload!(found)\n    @#{n}_record = found\n    @#{n}_loaded = true\n" \
          "    @#{n}_loaded_key = #{stored}\n    nil\n  end\n"
      end

      # The Relation's `includes(*names)` (docs/design.md D47, D95): the
      # Symbols, Arrays and Hashes walked into dotted paths
      # (Relation.include_spec_paths), every path checked through the
      # models' `check_include_path` case tables (no computed send, NOTES
      # rule 1) before any is taken, so an unknown name at any depth is an
      # ArgumentError naming it and its model and leaves the relation as it
      # was; `preload` is the same. `include_path` takes one checked path:
      # its first name is an add_include, a longer path is kept for the
      # child's preload_nested. With no association every name is unknown.
      def self.emit_includes(model, plans)
        src = +"  def includes(*names)\n"
        src << "    paths = Cybertrain::Relation.include_spec_paths(names)\n"
        src << "    i = 0\n"
        src << "    while i < paths.size\n"
        src << "      #{model}Relation.check_include_path(paths[i])\n"
        src << "      i += 1\n"
        src << "    end\n"
        unless plans.empty?
          src << "    i = 0\n"
          src << "    while i < paths.size\n"
          src << "      include_path(paths[i])\n"
          src << "      i += 1\n"
          src << "    end\n"
        end
        src << "    self\n"
        src << "  end\n"
        src << "\n"
        src << "  def preload(*names) = includes(*names)\n"
        src << "\n"
        src << emit_check_include_path(model, plans)
        src << emit_include_path(plans)
        src << emit_preload_nested(plans)
        src << "  def preloaded(records)\n"
        src << "    @preloaded = records\n"
        src << "    mark_records_preloaded\n"
        src << "    self\n"
        src << "  end\n"
        src << "\n"
        src
      end

      # `check_include_path(path)`, a class method: the first name of a
      # dotted path must be one of the model's associations, and the rest
      # is checked by the associated model's own (recursively; a cycle
      # such as comments.post.comments only follows the path given), by
      # every target's for a polymorphic belongs_to.
      def self.emit_check_include_path(model, plans)
        src = +"  def self.check_include_path(path)\n"
        unknown = "raise ArgumentError, \"unknown association \#{Cybertrain::Relation.path_head(path)} for #{model}\""
        if plans.empty?
          src << "    #{unknown}\n"
        else
          src << "    rest = Cybertrain::Relation.path_rest(path)\n"
          src << "    case Cybertrain::Relation.path_head(path)\n"
          plans.each do |plan|
            # A polymorphic belongs_to (D94): the rest must be an
            # association of every target, since each loads its own.
            unless plan.polymorphic?
              src << "    when \"#{plan.name}\" then #{plan.model}Relation.check_include_path(rest) unless rest == \"\"\n"
              next
            end
            src << "    when \"#{plan.name}\"\n"
            src << "      unless rest == \"\"\n"
            plan.targets.each { |m| src << "        #{m}Relation.check_include_path(rest)\n" }
            src << "      end\n"
          end
          src << "    else #{unknown}\n"
          src << "    end\n"
        end
        src << "    nil\n"
        src << "  end\n"
        src << "\n"
        src
      end

      # `include_path(path)`: one path check_include_path accepted.
      def self.emit_include_path(plans)
        return "" if plans.empty?

        src = +"  def include_path(path)\n"
        src << "    case Cybertrain::Relation.path_head(path)\n"
        plans.each { |plan| src << "    when \"#{plan.name}\" then add_include(:#{plan.name})\n" }
        src << "    end\n"
        src << "    add_nested_include(path) if path.include?(\".\")\n"
        src << "    nil\n"
        src << "  end\n"
        src << "\n"
        src
      end

      # `preload_nested(records, paths)`: what a parent's
      # preload_association calls on this model's relation with every
      # record it loaded and the paths below it, so each takes the next
      # level (one query per association, per chunk of ids). A model
      # without associations is only ever a leaf: a nil stub.
      def self.emit_preload_nested(plans)
        return "  def preload_nested(records, paths) = nil\n\n" if plans.empty?

        src = +"  def preload_nested(records, paths)\n"
        src << "    i = 0\n"
        src << "    while i < paths.size\n"
        src << "      include_path(paths[i])\n"
        src << "      i += 1\n"
        src << "    end\n"
        src << "    names = includes_names\n"
        src << "    i = 0\n"
        src << "    while i < names.size\n"
        src << "      preload_association(names[i], records)\n"
        src << "      i += 1\n"
        src << "    end\n"
        src << "    nil\n"
        src << "  end\n"
        src << "\n"
        src
      end

      # The end of a `when` body of preload_association: the paths below
      # this association, if any, handed with every record `loaded` holds
      # to the associated model's preload_nested (the next level). An
      # association kind that preloads gathers its records into `loaded`
      # (typed by the associated model) and ends with this; a polymorphic
      # belongs_to ends with one per target, each with its own records.
      def self.preload_nested_tail(plan, model = plan.model, table = plan.target_table, loaded = "loaded")
        src = +"      subs = nested_include_paths(\"#{plan.name}\")\n"
        src << "      #{model}Relation.new(\"#{table}\").preload_nested(#{loaded}, subs) unless subs.empty?\n"
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
      # and has_one the row or nil -- so no reader queries again -- and
      # every record loaded handed on with the paths below the association
      # (nested includes, D95: preload_nested_tail). No statement for no
      # records. The Hashes are seeded with the concrete types (NOTES rule
      # 9). "" without associations (the base stub).
      def self.emit_preload_association(plans)
        return "" if plans.empty?

        src = +"\n  def preload_association(name, records)\n"
        src << "    return nil if records.empty?\n"
        src << "\n"
        src << "    step = Cybertrain::DB.with { |c| c.variable_limit }\n"
        src << "    case name\n"
        plans.each do |plan|
          src << "    when :#{plan.name}\n"
          if plan.through?
            src << preload_through(plan)
          elsif plan.polymorphic?
            src << preload_polymorphic_parents(plan)
          else
            src << (plan.kind == :belongs_to ? preload_parents(plan) : preload_children(plan))
          end
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
        src << "      loaded = Array.new(0) { #{plan.model}.new }\n"
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
        # An `as:` child's type column is one more bind (D94): its chunks
        # leave room for it under the variable limit.
        chunk = type_condition(plan) == "" ? "step" : "chunk"
        src << "      chunk = step - 1\n" unless chunk == "step"
        src << "      start = 0\n"
        src << "      while start < ids.size\n"
        src << "        found = #{plan.model}Relation.new(\"#{plan.target_table}\")" \
               ".where(#{type_condition(plan)}#{plan.foreign_key}: ids[start, #{chunk}])" \
               ".order(id: :asc).to_a\n"
        src << "        j = 0\n"
        src << "        while j < found.size\n"
        src << "          key = #{key_expr(plan, "found[j].#{fk}")}\n"
        if many
          src << "          list = groups[key]\n"
          src << "          unless list.nil?\n"
          src << "            list << found[j]\n"
          src << "            loaded << found[j]\n"
          src << "          end\n"
        else
          src << "          unless index.key?(key)\n"
          src << "            index[key] = found[j]\n"
          src << "            loaded << found[j]\n"
          src << "          end\n"
        end
        src << "          j += 1\n"
        src << "        end\n"
        src << "        start += #{chunk}\n"
        src << "      end\n"
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << "        records[i].#{plan.name}_preload!(#{many ? "groups" : "index"}[records[i].id])\n"
        src << "        i += 1\n"
        src << "      end\n"
        src << preload_nested_tail(plan)
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
        src << "      loaded = Array.new(0) { #{plan.model}.new }\n"
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
        src << "          loaded << found[j]\n"
        src << "          j += 1\n"
        src << "        end\n"
        src << "        start += step\n"
        src << "      end\n"
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << "        records[i].#{plan.name}_preload!(index[#{key_expr(plan, "records[i].#{fk}")}])\n"
        src << "        i += 1\n"
        src << "      end\n"
        src << preload_nested_tail(plan)
        src
      end

      # `expr`, a key read from a column, as the Integer it is matched by.
      def self.cast_key(null, integer, expr)
        null || !integer ? "Cybertrain::Cast.int(#{expr})" : expr
      end

      # The `<Model>Relation` of a `has_many ..., through:` (docs/design.md
      # D93): the target rows whose link column is IN the middle rows'
      # link column for this record's key, one subquery, so it chains
      # (where, order, count, includes) like any Relation and answers each
      # target once. The record's key is its id, or for a belongs_to via
      # its foreign key (nil matches no row).
      def self.through_relation(plan)
        path = plan.through_path
        owner = path.owner_key == "" ? "@id" : ivar_name(path.owner_key)
        sql = "`#{plan.target_table}`.`#{path.target_link}` IN (SELECT `#{path.middle_link}` FROM " \
              "`#{path.middle_table}` WHERE `#{path.middle_key}` = ?)"
        "#{plan.model}Relation.new(\"#{plan.target_table}\").where_sql(\"#{sql}\", [#{owner}])"
      end

      # The `when` body for a has_many through: the records' distinct keys
      # (their ids, or a belongs_to via's non-nil foreign keys), the middle
      # rows `where(middle_key: keys)` giving, per link value, the owners
      # that reach it, then the targets `where(target_link: links)` in id
      # order appended to each of their owners' Arrays (so every target
      # once per owner, as the reader answers). A record without a key gets
      # an empty Array. Two queries per chunk of at most variable_limit
      # values; past one chunk of links the order is by id within each.
      def self.preload_through(plan)
        path = plan.through_path
        model = plan.model
        by_fk = path.owner_key != ""
        owner = by_fk ? cast_key(path.owner_key_null, path.owner_key_integer, "raw") : "records[i].id"
        src = +"      keys = Array.new(0) { 0 }\n"
        src << "      loaded = Array.new(0) { #{model}.new }\n"
        src << "      groups = { 0 => Array.new(0) { #{model}.new } }\n"
        src << "      groups.delete(0)\n"
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << "        raw = records[i].#{reader_name(path.owner_key)}\n" if by_fk
        body = +"key = #{owner}\n"
        body << "unless groups.key?(key)\n"
        body << "  groups[key] = Array.new(0) { #{model}.new }\n"
        body << "  keys << key\n"
        body << "end\n"
        src << unless_nil("raw", by_fk && path.owner_key_null, body, 8)
        src << "        i += 1\n"
        src << "      end\n"
        src << "      links = { 0 => Array.new(0) { 0 } }\n"
        src << "      links.delete(0)\n"
        src << "      targets = Array.new(0) { 0 }\n"
        src << "      start = 0\n"
        src << "      while start < keys.size\n"
        src << "        middles = #{path.middle_model}Relation.new(\"#{path.middle_table}\")" \
               ".where(#{path.middle_key}: keys[start, step]).to_a\n"
        src << "        j = 0\n"
        src << "        while j < middles.size\n"
        src << "          raw_link = middles[j].#{reader_name(path.middle_link)}\n"
        body = +"link = #{cast_key(path.middle_link_null, path.middle_link_integer, "raw_link")}\n"
        body << "owner = #{cast_key(path.middle_key_null, path.middle_key_integer, "middles[j].#{reader_name(path.middle_key)}")}\n"
        body << "unless links.key?(link)\n"
        body << "  links[link] = Array.new(0) { 0 }\n"
        body << "  targets << link\n"
        body << "end\n"
        body << "owners = links[link]\n"
        body << "unless owners.nil?\n"
        body << "  owners << owner unless owners.include?(owner)\n"
        body << "end\n"
        src << unless_nil("raw_link", path.middle_link_null, body, 10)
        src << "          j += 1\n"
        src << "        end\n"
        src << "        start += step\n"
        src << "      end\n"
        src << "      start = 0\n"
        src << "      while start < targets.size\n"
        src << "        found = #{model}Relation.new(\"#{plan.target_table}\").where(#{path.target_link}: targets[start, step])" \
               ".order(id: :asc).to_a\n"
        src << "        j = 0\n"
        src << "        while j < found.size\n"
        src << "          loaded << found[j]\n"
        src << "          raw_target = found[j].#{reader_name(path.target_link)}\n"
        body = +"owners = links[#{cast_key(path.target_link_null, path.target_link_integer, "raw_target")}]\n"
        body << "unless owners.nil?\n"
        body << "  k = 0\n"
        body << "  while k < owners.size\n"
        body << "    list = groups[owners[k]]\n"
        body << "    list << found[j] unless list.nil?\n"
        body << "    k += 1\n"
        body << "  end\n"
        body << "end\n"
        src << unless_nil("raw_target", path.target_link_null, body, 10)
        src << "          j += 1\n"
        src << "        end\n"
        src << "        start += step\n"
        src << "      end\n"
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        if by_fk
          src << "        raw = records[i].#{reader_name(path.owner_key)}\n"
          if path.owner_key_null
            src << "        if raw.nil?\n"
            src << "          records[i].#{plan.name}_preload!(Array.new(0) { #{model}.new })\n"
            src << "        else\n"
            src << "          records[i].#{plan.name}_preload!(groups[#{owner}])\n"
            src << "        end\n"
          else
            src << "        records[i].#{plan.name}_preload!(groups[#{owner}])\n"
          end
        else
          src << "        records[i].#{plan.name}_preload!(groups[records[i].id])\n"
        end
        src << "        i += 1\n"
        src << "      end\n"
        src << preload_nested_tail(plan)
        src
      end

      # `body` (lines without indent) indented by `by` spaces, inside
      # `unless <var>.nil?` when `guard` (a nullable column's value).
      def self.unless_nil(var, guard, body, by)
        pad = " " * by
        inner = guard ? pad + "  " : pad
        src = +""
        src << pad + "unless #{var}.nil?\n" if guard
        body.each_line { |line| src << inner + line }
        src << pad + "end\n" if guard
        src
      end

      # The `<Model>Relation` over the children of a has_many / has_one.
      def self.children_relation(plan)
        "#{plan.model}Relation.new(\"#{plan.target_table}\").where(#{type_condition(plan)}#{plan.foreign_key}: @id)"
      end

      # `commentable_type: "Post", ` for a has_many / has_one with `as:`
      # (D94), the condition on the children's type column that goes
      # before the key's; "" otherwise.
      def self.type_condition(plan)
        return "" if plan.type_value == ""

        "#{plan.type_column}: \"#{plan.type_value}\", "
      end

      # The opening lines of a polymorphic belongs_to's reader: nil without
      # a type or a key, then the locals `type` and `key` (`key` an
      # Integer, as key_expr makes it).
      def self.polymorphic_locals(plan, indent, type_expr, key_expr_text)
        guard = "#{type_expr}.nil?"
        guard += " || #{key_expr_text}.nil?" if plan.fk_null
        src = +"#{indent}return nil if #{guard}\n"
        src << "#{indent}type = Cybertrain::Cast.str(#{type_expr})\n"
        src << "#{indent}key = #{key_expr(plan, key_expr_text)}\n"
        src
      end

      # A polymorphic belongs_to's reader (D94): the type column names the
      # parent's model, one of the plan's targets, read by id and cached
      # with the type and the key it was read for. Its return type is the
      # union of the targets (Spinel boxes it; spikes/phase6/polymorphic_reader.rb),
      # so a caller narrows with `case record when Post`. An empty type
      # answers nil; a type that is no target raises ArgumentError.
      def self.polymorphic_reader(plan)
        n = plan.name
        type_iv = ivar_name(plan.type_column)
        src = +"  def #{n}\n"
        src << polymorphic_locals(plan, "    ", type_iv, ivar_name(plan.foreign_key))
        src << "    return nil if type == \"\"\n"
        src << "    return @#{n}_record if @#{n}_loaded && @#{n}_loaded_key == key && @#{n}_loaded_type == type\n"
        src << "\n"
        src << "    unless #{plan.targets.map { |t| "type == \"#{t}\"" }.join(" || ")}\n"
        src << "      message = \"#{plan.type_column} \#{type.inspect} is not #{target_list(plan, "or")} " \
               "(the models that declare as: :#{n})\"\n"
        src << "      raise ArgumentError, message\n"
        src << "    end\n"
        src << "    @#{n}_record =\n"
        src << "      case type\n"
        plan.targets.each { |t| src << "      when \"#{t}\" then #{t}.find_by(id: key)\n" }
        src << "      end\n"
        src << "    @#{n}_loaded = true\n"
        src << "    @#{n}_loaded_key = key\n"
        src << "    @#{n}_loaded_type = type\n"
        src << "    @#{n}_record\n"
        src << "  end\n"
        src
      end

      # "Post, Photo or Video"
      def self.target_list(plan, word)
        list = plan.targets
        return list[0] if list.size == 1

        list[0, list.size - 1].join(", ") + " #{word} " + list[list.size - 1]
      end

      # A polymorphic belongs_to's writer (D94): `comment.commentable = post`
      # stores the record's class name and id (Rails' `commentable_type`
      # and `commentable_id`) and caches the record; nil clears both. A
      # record of no target raises ArgumentError. An unsaved record stores
      # id 0 (save the parent first: there is no autosave).
      def self.polymorphic_writer(plan)
        n = plan.name
        type_iv = ivar_name(plan.type_column)
        key_iv = ivar_name(plan.foreign_key)
        src = +"  def #{n}=(record)\n"
        src << "    case record\n"
        src << "    when nil\n"
        src << "      #{type_iv} = #{plan.type_null ? "nil" : "\"\""}\n"
        src << "      #{key_iv} = #{plan.fk_null ? "nil" : "0"}\n"
        plan.targets.each do |t|
          src << "    when #{t}\n"
          src << "      #{type_iv} = \"#{t}\"\n"
          src << "      #{key_iv} = record.id\n"
        end
        src << "    else\n"
        src << "      message = \"#{n}= takes #{target_list(plan, "or")} (or nil)\"\n"
        src << "      raise ArgumentError, message\n"
        src << "    end\n"
        src << "    @#{n}_record = record\n"
        src << "    @#{n}_loaded = true\n"
        src << "    @#{n}_loaded_type = Cybertrain::Cast.str(#{type_iv})\n"
        src << "    @#{n}_loaded_key = Cybertrain::Cast.int(#{key_iv})\n"
        src << "    nil\n"
        src << "  end\n"
        src
      end

      # The `when` body for a polymorphic belongs_to: the records' distinct
      # keys per type, one query per target type (chunked as
      # preload_parents), and each record given its parent or nil; a record
      # whose type is no target is left unloaded, so its reader raises.
      # Each target's parents go on to its own preload_nested (D95).
      def self.preload_polymorphic_parents(plan)
        n = plan.name
        fk = reader_name(plan.foreign_key)
        tc = reader_name(plan.type_column)
        src = +""
        plan.targets.each_with_index do |t, k|
          src << "      ids_#{n}_#{k} = Array.new(0) { 0 }\n"
          src << "      seen_#{n}_#{k} = { 0 => true }\n"
          src << "      seen_#{n}_#{k}.delete(0)\n"
          src << "      index_#{n}_#{k} = { 0 => #{t}.new }\n"
          src << "      index_#{n}_#{k}.delete(0)\n"
          src << "      loaded_#{n}_#{k} = Array.new(0) { #{t}.new }\n"
        end
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << polymorphic_preload_locals(plan, fk, tc)
        src << "        case poly_type\n"
        plan.targets.each_with_index do |t, k|
          src << "        when \"#{t}\"\n"
          src << "          unless seen_#{n}_#{k}.key?(key)\n"
          src << "            seen_#{n}_#{k}[key] = true\n"
          src << "            ids_#{n}_#{k} << key\n"
          src << "          end\n"
        end
        src << "        end\n"
        src << "        i += 1\n"
        src << "      end\n"
        plan.targets.each_with_index do |t, k|
          src << "      start = 0\n"
          src << "      while start < ids_#{n}_#{k}.size\n"
          src << "        found_#{n}_#{k} = #{t}Relation.new(\"#{plan.target_tables[k]}\")" \
                 ".where(id: ids_#{n}_#{k}[start, step]).to_a\n"
          src << "        j = 0\n"
          src << "        while j < found_#{n}_#{k}.size\n"
          src << "          index_#{n}_#{k}[found_#{n}_#{k}[j].id] = found_#{n}_#{k}[j]\n"
          src << "          loaded_#{n}_#{k} << found_#{n}_#{k}[j]\n"
          src << "          j += 1\n"
          src << "        end\n"
          src << "        start += step\n"
          src << "      end\n"
        end
        src << "      i = 0\n"
        src << "      while i < records.size\n"
        src << polymorphic_preload_locals(plan, fk, tc)
        src << "        case poly_type\n"
        src << "        when \"\" then records[i].#{n}_preload!(nil)\n"
        plan.targets.each_with_index do |t, k|
          src << "        when \"#{t}\" then records[i].#{n}_preload!(index_#{n}_#{k}[key])\n"
        end
        src << "        end\n"
        src << "        i += 1\n"
        src << "      end\n"
        plan.targets.each_with_index do |t, k|
          src << preload_nested_tail(plan, t, plan.target_tables[k], "loaded_#{n}_#{k}")
        end
        src
      end

      # Inside preload_polymorphic_parents' loops: `poly_type` (a String,
      # "" for a nil type or key) and `key` of records[i].
      def self.polymorphic_preload_locals(plan, fk, tc)
        src = +"        raw_type = records[i].#{tc}\n"
        src << "        raw_key = records[i].#{fk}\n"
        guard = "raw_type.nil?"
        guard += " || raw_key.nil?" if plan.fk_null
        src << "        poly_type = #{guard} ? \"\" : Cybertrain::Cast.str(raw_type)\n"
        src << "        key = #{guard} ? 0 : #{key_expr(plan, "raw_key")}\n"
        src
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
          when :nullify
            type_nil = plan.type_value == "" ? "" : ", #{plan.type_column}: nil"
            body << "    #{children_relation(plan)}.update_all(#{plan.foreign_key}: nil#{type_nil})\n"
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
          # A polymorphic one's type is blank while it is nil or "" (D94).
          src << "  validates_foreign_key :#{plan.type_column}\n" if plan.polymorphic?
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

      # The counter_cache methods: increment the parent's counter
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
