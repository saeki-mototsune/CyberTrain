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

    # Emits gen/models/<model>.rb for each table of db/schema.rb: a typed
    # `<Model>Relation` and a `<Model> < Cybertrain::Model` whose ivars,
    # casts, finders and associations are spelled out as plain Ruby, because
    # Spinel cannot define methods at runtime. test/model.rb hand-writes
    # this exact shape and is its executable specification.
    module ModelsEmitter
      # "posts" -> "Post"; "blog_posts" -> "BlogPost".
      def self.model_class_name(table)
        Inflector.camelize(Inflector.singularize(table.to_s))
      end

      # "posts" -> "post.rb".
      def self.file_name(table)
        Inflector.singularize(table.to_s) + ".rb"
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
        Array.new(0) { ScopeInfo.new("", "", "", "", 0) }
      end

      # { "gen/models/post.rb" => source, ... } for every table, by table name.
      def self.outputs(definition, infos)
        out = { "" => "" }
        out.delete("")
        definition.tables.each do |table|
          model = model_class_name(table.name)
          methods = view_methods_for(model, infos)
          out["gen/models/" + file_name(table.name)] = emit_model(table, definition, methods, scopes_for(model, infos), infos)
        end
        out
      end

      # Writes every gen/models file under `root`; returns the relative paths.
      # (Gen::Runner does not use this: it goes through `outputs` + sync_file
      # so unchanged files keep their mtime and --check works. Kept for
      # test/gen_models_compiles.rb.)
      def self.write_all(root, definition, infos)
        Dir.mkdir(root + "/gen") unless Dir.exist?(root + "/gen")
        Dir.mkdir(root + "/gen/models") unless Dir.exist?(root + "/gen/models")
        written = Array.new(0) { "" }
        outputs(definition, infos).each do |path, source|
          File.write(root + "/" + path, source)
          written << path
        end
        written
      end

      # emit_model without any app/models declarations: the associations
      # come from the schema's foreign keys alone.
      def self.emit(table, definition, view_methods, scopes)
        emit_model(table, definition, view_methods, scopes, Array.new(0) { ModelInfo.new("", "", [], [], []) })
      end

      # The gen/models file of `table`. `infos` are every scanned model file:
      # this model's declared associations, and the parent's has_many name a
      # counter_cache column is named after, come from them.
      def self.emit_model(table, definition, view_methods, scopes, infos)
        raise ArgumentError, "table #{table.name} has no columns" if table.columns.empty?

        check_column_names(table)
        check_binary_defaults(table)
        check_scope_names(table, scopes)
        plans = association_plans(table, definition, infos)
        check_association_ivars(table, plans)
        model = model_class_name(table.name)
        # Each part builds and returns its own String: a String argument
        # appended to inside the callee does not reliably update the
        # caller's copy under Spinel (`<<` may reallocate the buffer).
        src = +"# Generated by `spin run gen` from db/schema.rb. Do not edit.\n"
        src << emit_relation(model, table, scopes)
        src << "\n"
        src << emit_model_head(model, table, plans)
        src << emit_persistence(model, table, scopes)
        src << emit_dispatch(table, definition, infos, plans, view_methods)
        src << "end\n"
        src
      end

      # The Ruby name a column's reader, writer and ivar carry: the column's
      # own name, except for Ident::RESERVED_COLUMN_NAMES and Ruby keywords
      # (Ident::RUBY_KEYWORDS), which take `<column>_column`. This is the one
      # place that decides it. A reader named `errors`, `save`, `hash` or
      # `to_ary` would shadow a method of Cybertrain::Model or Object that
      # the framework (or Ruby itself) calls on the record, and an ivar named
      # `@errors` / `@persisted` is one the Model owns; a keyword column
      # (`end`, `begin`, `class`) would need `def class` / `@class`, which is
      # not a shape worth supporting. All of them are renamed; everything
      # keyed by the column's SQL name (column_names, to_row, load_row,
      # params) stays keyed by it; read_attribute / write_attribute answer
      # both spellings (attribute_keys), so a template, which reaches a column
      # through read_attribute, can always use the Ruby name. The query API
      # (Relation#where / order / find_by, order_sql) does not: Relation is
      # built from a table name and knows no per-model rename table, and a
      # column is its SQL name there, so `Post.where(hash: 1)` is right and
      # `Post.where(hash_column: 1)` is "no such column". The Ruby name is the
      # reader, the writer, the constructor key and the template name only
      # (rename_note says so beside the accessor). An existing
      # schema must keep generating on upgrade, so such a column is renamed
      # rather than refused (`cybertrain generate scaffold` still refuses to
      # invent one).
      def self.reader_name(column_name)
        renamed?(column_name) ? column_name + "_column" : column_name
      end

      # Whether reader_name renames the column.
      def self.renamed?(column_name)
        Ident.reserved_column?(column_name) || Ident.keyword?(column_name)
      end

      # The ivar behind reader_name.
      def self.ivar_name(column_name)
        "@" + reader_name(column_name)
      end

      # The `when` keys of read_attribute / write_attribute for a column: its
      # SQL name, plus the reader's name when reader_name renamed it (the
      # query API takes the SQL name only: see reader_name). The
      # interpreter resolves `post.hash_column` through read_attribute and
      # knows no other way to the column, so without the second key a renamed
      # column would be unreachable from a template under its Ruby name. A
      # multi-value `when` is plain Ruby the interpreter already uses
      # (`when :size, :length`). A column that is not renamed keeps its single
      # key, so the committed models do not change.
      def self.attribute_keys(column_name)
        key = ":" + column_name
        reader_name(column_name) == column_name ? key : key + ", :" + reader_name(column_name)
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
      def self.check_column_names(table)
        names = table.columns.map { |c| c.name }
        table.columns.each do |c|
          name = c.name
          unless Ident.column?(name)
            raise ArgumentError, "table #{table.name}: column #{name.inspect} is not a valid attribute name " \
                                 "(a column name is an ASCII identifier: ASCII letters, digits and _, " \
                                 "not starting with a digit)"
          end
          next unless renamed?(name)

          fallback = reader_name(name)
          # The fallback is `<column>_column`, which no RESERVED_COLUMN_NAMES
          # entry or keyword ends in, so the only way it is taken is by
          # another column of the table.
          if names.include?(fallback)
            raise ArgumentError, "table #{table.name}: column #{name.inspect} can be neither #{name.inspect} nor " \
                                 "#{fallback.inspect} (a Ruby keyword or a Cybertrain::Model or Object method " \
                                 "owns the first, another column of the table owns the second); rename a column"
          end
        end
        nil
      end

      # A binary column's default would have to be bytes the model writes
      # into the ivar; initial_value has no literal for it and would fall
      # back to "", silently replacing the declared default (INSERT writes
      # every column, so the database's DEFAULT never applies).
      def self.check_binary_defaults(table)
        table.columns.each do |c|
          next unless c.type == :binary

          raw = c.default
          next if raw.nil? || raw.strip.upcase == "NULL"

          raise ArgumentError, "table #{table.name}: column #{c.name.inspect} is a binary column with a default " \
                               "(#{raw}); a BLOB column takes no default, set the bytes in the model instead"
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
          table.columns.each { |c| clash = c.name if c.name == name || reader_name(c.name) == name }
          next if clash == ""

          raise ModelScan::Error, "#{scope.file}:#{scope.line}: scope :#{name} clashes with the column #{clash} " \
                                  "of table #{table.name}; rename the scope"
        end
        nil
      end

      # `def recent = (order(created_at: :desc))`: the scope's parameter
      # text and body, verbatim; the body runs with the relation as
      # receiver. The parentheses keep a body holding `;`, `and` or `or`
      # inside the endless method.
      def self.scope_relation_method(scope)
        params = scope.params == "" ? "" : "(#{scope.params})"
        "  def #{scope.name}#{params} = (#{scope.body})\n"
      end

      # `def self.min_views(n) = all.min_views(n)`: the parameter text, and
      # its names (defaults dropped) passed on.
      def self.scope_class_method(scope)
        return "  def self.#{scope.name} = all.#{scope.name}\n" if scope.params == ""

        args = ModelScan.scope_args(scope.params)
        "  def self.#{scope.name}(#{scope.params}) = all.#{scope.name}(#{args})\n"
      end

      def self.emit_relation(model, table, scopes)
        src = +""
        src << "class #{model}Relation < Cybertrain::Relation\n"
        src << emit_column_types(table)
        src << "  def where(cond = nil, *binds)\n"
        # nil (Post.where.not(...)) is the relation itself; a Hash | String
        # parameter dispatches by case under Spinel.
        src << "    case cond\n"
        src << "    when nil then nil\n"
        src << "    when Hash then add_where(cond)\n"
        src << "    when String then add_where_sql(cond, binds)\n"
        src << "    else raise ArgumentError, \"where takes a Hash or a SQL String\"\n"
        src << "    end\n"
        src << "    self\n"
        src << "  end\n"
        src << "\n"
        src << "  def not(h) = (add_where_not(h); self)\n"
        src << "  def where_sql(s, b = []) = (add_where_sql(s, b); self)\n"
        src << "  def where_like(c, t) = (add_where_like(c, t); self)\n"
        src << "  def where_between(c, from, to, exclude_end: false) = (add_where_between(c, from, to, exclude_end); self)\n"
        src << "  def or(other) = (merge_or(other); self)\n"
        src << "\n"
        src << "  def order(o)\n"
        src << "    case o\n"
        src << "    when Hash then set_order_hash(o)\n"
        src << "    else set_order(o)\n"
        src << "    end\n"
        src << "    self\n"
        src << "  end\n"
        src << "\n"
        src << "  def order_sql(s) = (add_order_sql(s); self)\n"
        src << "  def limit(n) = (set_limit(n); self)\n"
        src << "  def offset(n) = (set_offset(n); self)\n"
        src << "  def distinct = (set_distinct; self)\n"
        src << "  def none = (set_none; self)\n"
        src << "  def having_sql(s, b = []) = (set_having_sql(s, b); self)\n"
        src << "\n"
        src << "  def to_a\n"
        # A while loop: an each block is a Proc per query.
        src << "    out = Array.new(0) { #{model}.new }\n"
        src << "    found = rows\n"
        src << "    i = 0\n"
        src << "    while i < found.size\n"
        src << "      out << #{model}.from_row(found[i])\n"
        src << "      i += 1\n"
        src << "    end\n"
        src << "    out\n"
        src << "  end\n"
        src << "\n"
        src << "  def each(&blk) = to_a.each(&blk)\n"
        src << "\n"
        src << "  def first\n"
        src << "    r = first_row\n"
        src << "    return nil if r.nil?\n"
        src << "    #{model}.from_row(r)\n"
        src << "  end\n"
        src << "\n"
        src << "  def last\n"
        src << "    r = last_row\n"
        src << "    return nil if r.nil?\n"
        src << "    #{model}.from_row(r)\n"
        src << "  end\n"
        src << "\n"
        src << "  def find_by(h) = where(h).first\n"
        src << "\n"
        src << "  def find_by!(h)\n"
        src << "    rec = find_by(h)\n"
        src << "    raise Cybertrain::RecordNotFound, \"Couldn't find #{model}\" if rec.nil?\n"
        src << "    rec\n"
        src << "  end\n"
        src << "\n"
        src << "  def find(id)\n"
        src << "    rec = where(id: id).first\n"
        src << "    raise Cybertrain::RecordNotFound, \"Couldn't find #{model} with id=\#{id}\" if rec.nil?\n"
        src << "    rec\n"
        src << "  end\n"
        src << "\n"
        src << "  def find_or_create_by(h)\n"
        src << "    rec = find_by(h)\n"
        src << "    return rec unless rec.nil?\n"
        src << "    #{model}.create(h)\n"
        src << "  end\n"
        src << "\n"
        src << "  def find_or_initialize_by(h)\n"
        src << "    rec = find_by(h)\n"
        src << "    return rec unless rec.nil?\n"
        src << "    #{model}.new(h)\n"
        src << "  end\n"
        src << "\n"
        # Loads the records and destroys each, so callbacks run.
        src << "  def destroy_all\n"
        src << "    out = to_a\n"
        src << "    i = 0\n"
        src << "    while i < out.size\n"
        src << "      out[i].destroy\n"
        src << "      i += 1\n"
        src << "    end\n"
        src << "    out\n"
        src << "  end\n"
        src << "\n"
        # Pages by `id > last_id ORDER BY id LIMIT batch` (Relation#batch_rows).
        src << "  def find_each(batch: 1000, &blk)\n"
        src << "    raise ArgumentError, \"find_each: batch must be at least 1 (got \#{batch})\" if batch < 1\n"
        src << "    last_id = 0\n"
        src << "    while true\n"
        src << "      found = batch_rows(last_id, batch)\n"
        src << "      i = 0\n"
        src << "      while i < found.size\n"
        src << "        rec = #{model}.from_row(found[i])\n"
        src << "        last_id = rec.id\n"
        src << "        blk.call(rec)\n"
        src << "        i += 1\n"
        src << "      end\n"
        src << "      break if found.size < batch\n"
        src << "    end\n"
        src << "    nil\n"
        src << "  end\n"
        src << "\n"
        src << "  def size = count\n"
        # The scopes, after a blank line (none: the file is unchanged).
        src << "\n" unless scopes.empty?
        scopes.each { |scope| src << scope_relation_method(scope) }
        src << "end\n"
        src
      end

      # The column types `column_type` answers, in the order its `when`
      # lines are written. A column of any other type answers :unknown.
      COLUMN_TYPES = [:integer, :float, :decimal, :boolean, :datetime, :date, :json, :binary, :string, :text]

      # The schema, per column, on the Relation: `column_type(name)`, a
      # `case` over the SQL column names (`id` included, an :integer) with
      # one `when` per type that has columns, else :unknown;
      # `decimal_scale(name)` for a table with a decimal column that
      # declares a scale (else the base method's -1); `binary_column?`
      # for a table with BLOB columns, so `where(data: bytes)` binds a Blob
      # (Relation#bind_for; a table without them keeps the base method's
      # false). Every override returns the base method's type (Symbol,
      # Integer, Boolean: NOTES rules 10/34).
      def self.emit_column_types(table)
        src = +""
        src << "  def column_type(name)\n"
        src << "    case name\n"
        COLUMN_TYPES.each do |type|
          names = type == :integer ? ["\"id\""] : Array.new(0) { "" }
          table.columns.each { |c| names << "\"#{c.name}\"" if c.type == type }
          next if names.empty?

          src << "    when #{names.join(", ")} then :#{type}\n"
        end
        src << "    else :unknown\n"
        src << "    end\n"
        src << "  end\n"
        src << "\n"
        src << emit_decimal_scale(table)
        return src if table.columns.select { |c| c.type == :binary }.empty?

        src << "  def binary_column?(name) = column_type(name) == :binary\n"
        src << "\n"
        src
      end

      # `validates :seen_on, presence: true` for every NOT NULL date column,
      # with a default or without. write_attribute keeps invalid or blank
      # input nil (writer_cast_for), and an INSERT would then fail on the
      # NOT NULL constraint with a DB::Error (every column is inserted, so
      # SQLite never applies a default to the explicit NULL); the validation
      # makes it an error on the record instead, so `save` returns false. A
      # defaulted column starts at its default (initial_value), so a fresh
      # record passes. Keyed by the SQL name, as validates is. "" when there
      # is no such column.
      def self.emit_date_presence(table)
        src = +""
        table.columns.each do |c|
          next unless c.type == :date && !c.null

          src << "  validates :#{c.name}, presence: true\n"
        end
        src << "\n" unless src == ""
        src
      end

      # `decimal_scale(name)`: one `when` per decimal column with a scale.
      def self.emit_decimal_scale(table)
        scaled = table.columns.select { |c| c.type == :decimal && c.scale >= 0 }
        return "" if scaled.empty?

        src = +""
        src << "  def decimal_scale(name)\n"
        src << "    case name\n"
        scaled.each { |c| src << "    when \"#{c.name}\" then #{c.scale}\n" }
        src << "    else -1\n"
        src << "    end\n"
        src << "  end\n"
        src << "\n"
        src
      end

      def self.emit_model_head(model, table, plans)
        src = +""
        names = table.columns.map { |c| c.name }
        quoted = names.map { |n| "\"#{n}\"" }.join(", ")
        symbols = names.map { |n| ":#{reader_name(n)}" }.join(", ")
        src << "class #{model} < Cybertrain::Model\n"
        src << "  def self.table_name = \"#{table.name}\"\n"
        src << "  def self.column_names = [\"id\", #{quoted}]\n"
        src << "  def model_name = \"#{model}\"\n"
        src << "\n"
        # Plain attr_accessor, on purpose: not typed `def x=(v)` writers.
        # Under Spinel a `def x=` on one class breaks the run-time dispatch
        # of an `attr_accessor :x` on another (NOTES rule 43) -- a column
        # named body or status would take Response#body= / #status= down
        # with it -- and column names are the app's to choose. Probed on
        # Spinel 2026.09.12: a Time assigned through the raw writer to a
        # nullable datetime ivar reads back intact once load_row has typed
        # the ivar via Cast.time_or_nil, so rule 7 does not bite this shape.
        #
        # A column named like a method the framework calls on the record
        # (Ident::RESERVED_COLUMN_NAMES) or like a Ruby keyword reads as
        # `<column>_column` (reader, writer and ivar: reader_name); the
        # read_attribute / write_attribute keys below take either spelling
        # (attribute_keys).
        names.each do |n|
          src << "  " << rename_note(n) << "\n" if renamed?(n)
          next unless Ident.shadowing_column?(n)

          src << "  " << shadow_note("column", n) << "\n"
        end
        src << "  attr_accessor #{symbols}\n"
        src << "\n"
        src << emit_date_presence(table)
        src << emit_association_rules(plans)
        src << "  def initialize(attrs = {})\n"
        src << "    super()\n"
        table.columns.each { |c| src << "    #{ivar_name(c.name)} = #{initial_value(c)}\n" }
        plans.each { |plan| src << association_ivars(plan) }
        src << "    @counter_cache_found = false\n" unless plans.select { |plan| plan.counter_cache }.empty?
        # A record loaded from a row (from_row) passes no attributes: skip
        # the each, and the Proc it allocates, for every row of every query.
        src << "    assign_attributes(attrs) unless attrs.empty?\n"
        src << "  end\n"
        src << "\n"
        src << "  def self.from_row(row)\n"
        # The shared empty Hash, not the `{}` default: one Hash less per row.
        src << "    rec = #{model}.new(Cybertrain::Model::NO_ATTRIBUTES)\n"
        src << "    rec.load_row(row)\n"
        src << "    rec\n"
        src << "  end\n"
        src << "\n"
        src << "  def load_row(row)\n"
        src << "    set_id(Cybertrain::Cast.int(row[\"id\"]))\n"
        table.columns.each { |c| src << "    #{ivar_name(c.name)} = Cybertrain::Cast.#{cast_for(c)}(row[\"#{c.name}\"])\n" }
        src << "    mark_persisted!\n"
        src << "    nil\n"
        src << "  end\n"
        src << "\n"
        src << "  def read_attribute(name)\n"
        src << "    case name\n"
        src << "    when :id then @id\n"
        table.columns.each { |c| src << "    when #{attribute_keys(c.name)} then #{ivar_name(c.name)}\n" }
        src << "    else nil\n"
        src << "    end\n"
        src << "  end\n"
        src << "\n"
        src << "  def write_attribute(name, value)\n"
        src << "    case name\n"
        table.columns.each { |c| src << "    when #{attribute_keys(c.name)} then #{ivar_name(c.name)} = Cybertrain::Cast.#{writer_cast_for(c)}(value)\n" }
        src << "    end\n"
        src << "    nil\n"
        src << "  end\n"
        src << "\n"
        src << "  def assign_attributes(attrs)\n"
        src << "    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }\n"
        src << "    self\n"
        src << "  end\n"
        src << "\n"
        src << "  def to_row\n"
        src << "    {\n"
        pairs = table.columns.map { |c| "      \"#{c.name}\" => #{bind_expression(c)}" }.join(",\n")
        src << "#{pairs}\n"
        src << "    }\n"
        src << "  end\n"
        src << "\n"
        src
      end

      # The query methods the model class answers by delegating to `all`:
      # each is emitted as `def self.x(...) = all.x(...)`. Later work adds
      # its names here (includes).
      DELEGATED = %w[where where_like where_between order order_sql limit offset distinct none ids find find_by find_by!
                     find_or_create_by find_or_initialize_by first last count exists? update_all delete_all
                     destroy_all find_each pluck pick minimum_int minimum_float minimum_time maximum_int
                     maximum_float maximum_time average minimum_int_by minimum_float_by minimum_time_by
                     maximum_int_by maximum_float_by maximum_time_by average_by sum_int_by sum_float_by
                     sum_float_sql minimum_float_sql maximum_float_sql average_sql having_sql]

      def self.emit_persistence(model, table, scopes)
        src = +""
        src << "  def self.all = #{model}Relation.new(\"#{table.name}\")\n"
        DELEGATED.each { |name| src << "  def self.#{name}(...) = all.#{name}(...)\n" }
        scopes.each { |scope| src << scope_class_method(scope) }
        src << "\n"
        src << "  def self.create(attrs = {})\n"
        src << "    rec = #{model}.new(attrs)\n"
        src << "    rec.save\n"
        src << "    rec\n"
        src << "  end\n"
        src << "\n"
        src << "  def self.create!(attrs = {})\n"
        src << "    rec = #{model}.new(attrs)\n"
        src << "    rec.save!\n"
        src << "    rec\n"
        src << "  end\n"
        src << "\n"
        src << emit_bulk_writes(table)
        src
      end

      # The schema constants the bulk writes read -- COLUMN_TYPES (every
      # column, `id` included, with column_type's type), DECIMAL_SCALES (the
      # decimal columns that declare a scale) and ENCRYPTED_COLUMNS (empty
      # until `encrypts` exists) -- and insert_all, insert_all! and
      # upsert_all, each one call of Cybertrain::Model.insert_all_into
      # (spec section 6). The empty containers come from typed helpers
      # (NOTES rule 9).
      def self.emit_bulk_writes(table)
        src = +""
        src << "  COLUMN_TYPES = {\n"
        pairs = ["    \"id\" => :integer"]
        table.columns.each do |c|
          type = COLUMN_TYPES.include?(c.type) ? c.type : :unknown
          pairs << "    \"#{c.name}\" => :#{type}"
        end
        src << pairs.join(",\n") << "\n"
        src << "  }\n"
        scaled = table.columns.select { |c| c.type == :decimal && c.scale >= 0 }
        if scaled.empty?
          src << "  DECIMAL_SCALES = Cybertrain::Model.no_decimal_scales\n"
        else
          scales = scaled.map { |c| "\"#{c.name}\" => #{c.scale}" }.join(", ")
          src << "  DECIMAL_SCALES = { #{scales} }\n"
        end
        src << "  ENCRYPTED_COLUMNS = Cybertrain::Model.no_encrypted_columns\n"
        src << "\n"
        head = "    Cybertrain::Model.insert_all_into(\"#{table.name}\", rows, COLUMN_TYPES, DECIMAL_SCALES, ENCRYPTED_COLUMNS,\n"
        pad = "                                      "
        src << "  def self.insert_all(rows, returning: [:id], record_timestamps: true)\n"
        src << head << pad << "returning, record_timestamps, :nothing, nil, nil)\n"
        src << "  end\n"
        src << "\n"
        src << "  def self.insert_all!(rows, returning: [:id], record_timestamps: true)\n"
        src << head << pad << "returning, record_timestamps, :raise, nil, nil)\n"
        src << "  end\n"
        src << "\n"
        src << "  def self.upsert_all(rows, unique_by: [:id], update_only: nil, returning: [:id], record_timestamps: true)\n"
        src << head << pad << "returning, record_timestamps, :update, unique_by, update_only)\n"
        src << "  end\n"
        src << "\n"
        src
      end

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

      # Same note a column gets (emit_model_head) when the reader's name is an
      # Object method nothing in Cybertrain calls on a record: the association
      # keeps its name, the generated file says what it shadows.
      def self.shadow_note(what, name)
        "# NOTE: #{what} #{name.inspect} shadows Object##{name} on this model (nothing in " \
          "Cybertrain calls it on a record; Ident::SHADOWING_COLUMN_NAMES)"
      end

      # The note beside the attr_accessor of a column reader_name renamed.
      # Every note ends by telling that queries take the SQL name (the reader
      # name is not a column to Relation). A keyword is told so, not that it
      # is a method. The interpreter
      # resolves `errors` and `to_param` as model methods before it asks
      # read_attribute (Interpreter#model_method), so for those two the plain
      # name never reaches the column from a template and the note says so;
      # every other renamed name falls through to read_attribute and works
      # under either spelling.
      def self.rename_note(name)
        if Ident.keyword?(name)
          kw = "# column #{name.inspect} reads as #{reader_name(name)}: #{name.inspect} is a Ruby keyword"
          return kw + query_note(name)
        end

        note = "# column #{name.inspect} reads as #{reader_name(name)}: #{name.inspect} is a method of " \
          "Cybertrain::Model or Object that the framework calls (Ident::RESERVED_COLUMN_NAMES)"
        if name == "errors" || name == "to_param"
          note += "; templates resolve #{name} as that method, so a template reads the column as #{reader_name(name)}"
        end
        note + query_note(name)
      end

      # The clause every rename note ends with: where / order / find_by quote
      # the name as an SQL identifier, so only the SQL name is a column there.
      def self.query_note(name)
        "; queries (where, order, find_by) take the SQL name #{name.inspect}"
      end

      # The association readers and the methods behind them, then the
      # read_association / call_view_method case tables the template
      # interpreter dispatches through by name.
      def self.emit_dispatch(table, definition, infos, plans, view_methods)
        src = +""
        taken = owned_names(table)
        assoc_names = Array.new(0) { "" }
        plans.each { |plan| assoc_names << plan.name }

        methods = Array.new(0) { "" }
        view_methods.each do |m|
          next if taken.include?(m) || assoc_names.include?(m) || methods.include?(m)

          methods << m
        end

        # One-line readers (has_many) run together; a multi-line one
        # (belongs_to, has_one) ends with a blank line.
        open_run = false
        plans.each do |plan|
          plan.notes.each { |note| src << "  #{note}\n" }
          reader = association_reader(plan)
          src << reader
          open_run = reader.lines.size == 1
          src << "\n" unless open_run
        end
        src << "\n" if open_run
        src << emit_destroy_dependents(plans)
        src << emit_reset_association_caches(plans)
        src << emit_counter_cache(table, plans)
        src << emit_counter_cache_columns(counter_columns_on(table, definition, infos))
        src << emit_read_association(plans)
        src << "\n" unless plans.empty? && methods.empty?
        src << emit_case("call_view_method", methods)
        src
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
      # `post.comments.where(...).count` chains. belongs_to: the parent,
      # cached with the foreign key it was read for, so a reassigned key
      # never answers the old parent; a nil key answers nil. has_one: the
      # preload cache when Task 12's includes filled it, else a query.
      def self.association_reader(plan)
        n = plan.name
        if plan.kind == :has_many
          return "  def #{n} = #{plan.model}Relation.new(\"#{plan.target_table}\").where(#{plan.foreign_key}: @id)\n"
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

      # A `case name` over `names`; a one-line `nil` stub when there are
      # none, since a `case` without any `when` does not parse.
      def self.emit_case(method, names)
        src = +""
        if names.empty?
          src << "  def #{method}(name) = nil\n"
          return src
        end
        src << "  def #{method}(name)\n"
        src << "    case name\n"
        # `self.` because a reader may be capitalised (Ident.column? admits
        # `Author_id` -> def Author): bare, Ruby would read `Author` as a
        # constant.
        names.each { |n| src << "    when :#{n} then self.#{n}\n" }
        src << "    else nil\n"
        src << "    end\n"
        src << "  end\n"
        src
      end

      # The Cast helper that reads and writes this column (spikes/NOTES.md
      # rule 7: Time ivars always go through time_or_nil, nullable ones
      # through a helper that can return nil). A decimal is a Float; a json
      # column a Hash (json_hash parses the stored text; hash_or_nil too,
      # and keeps NULL nil); a date a Date.
      def self.cast_for(column)
        null = column.null
        case column.type
        when :integer then null ? "int_or_nil" : "int"
        when :float, :decimal then null ? "float_or_nil" : "float"
        when :boolean then null ? "bool_or_nil" : "bool"
        when :datetime then "time_or_nil"
        when :date then null ? "date_or_nil" : "date"
        when :json then null ? "hash_or_nil" : "json_hash"
        # A String of raw bytes, like a text column (Cast.binary is for
        # raw-SQL callers; it reads nil as "", which a nullable one must not).
        when :binary then null ? "str_or_nil" : "binary"
        else null ? "str_or_nil" : "str"
        end
      end

      # The cast write_attribute applies: cast_for's, except that every date
      # column, NOT NULL included, takes date_or_nil. An assigned "" or
      # "2026-13-01" then stays nil, so the NOT NULL constraint (or a
      # presence validation) refuses the save instead of Cast.date's
      # 1970-01-01 fallback being stored. load_row keeps Cast.date for a
      # NOT NULL date: a corrupt stored cell reads as the epoch.
      def self.writer_cast_for(column)
        column.type == :date ? "date_or_nil" : cast_for(column)
      end

      # What to_row binds for a column: a binary column's bytes wrapped in a
      # DB::Blob (nil stays nil), so Connection#bind sends them with
      # sqlite3_bind_blob and their length; a decimal with a scale rounded
      # to it (round_scale_or_nil keeps a nullable one's nil, so it is
      # stored as NULL, not 0.0); a json column its JSON text (nil for
      # nil); every other column (a date included) its Cast.to_sql value.
      def self.bind_expression(column)
        ivar = ivar_name(column.name)
        case column.type
        when :binary then "Cybertrain::DB::Blob.wrap(#{ivar})"
        when :json then "Cybertrain::Cast.json_text(#{ivar})"
        when :decimal
          return "Cybertrain::Cast.to_sql(#{ivar})" if column.scale < 0

          helper = column.null ? "round_scale_or_nil" : "round_scale"
          "Cybertrain::Cast.#{helper}(#{ivar}, #{column.scale})"
        else "Cybertrain::Cast.to_sql(#{ivar})"
        end
      end

      # The ivar's value in `initialize`: the column's SQL default when it
      # has a simple one (INSERT writes every column, so the database's own
      # DEFAULT never applies), else "" / 0 / 0.0 / false / an empty Hash
      # (json) for NOT NULL columns and nil for nullable ones. A decimal is
      # a float here too. Nullable columns with a default still go through
      # their Cast helper to keep the ivar's nullable type. A datetime or
      # date starts as nil even when NOT NULL (no zero value stands for "no
      # date"; saving one unset fails on the constraint, as in Rails); a
      # json column's default text is not read (it starts empty or nil).
      def self.initial_value(column)
        return date_default(column) if column.type == :date && !column.null
        return "nil" if column.type == :datetime || column.type == :date

        literal = default_literal(column)
        if column.null
          literal == "" ? "nil" : "Cybertrain::Cast.#{cast_for(column)}(#{literal})"
        elsif literal != ""
          literal
        else
          case column.type
          when :integer then "0"
          when :float, :decimal then "0.0"
          when :boolean then "false"
          when :json then "Cybertrain::Cast.empty_hash"
          else "\"\""
          end
        end
      end

      # A NOT NULL date column's initial value: its SQL default
      # (`'2026-01-01'`, quoted or not) through Cast.date_or_nil, since the
      # INSERT names every column and SQLite never applies the default; nil
      # when it has none. A default that is not `YYYY-MM-DD` text
      # (CURRENT_DATE) reads as nil, so the presence validation asks for a
      # value.
      def self.date_default(column)
        raw = column.default
        return "nil" if raw.nil?

        text = raw.strip
        return "nil" if text.upcase == "NULL"

        text = text[1, text.size - 2].gsub("''", "'") if quoted_sql?(text)
        "Cybertrain::Cast.date_or_nil(#{ruby_string(text)})"
      end

      # The Ruby literal for a column's SQL default text ("0", "'x'",
      # "false"), or "" when there is none or it is not a plain literal.
      def self.default_literal(column)
        raw = column.default
        return "" if raw.nil?

        text = raw.strip
        return "" if text.upcase == "NULL"

        case column.type
        when :integer
          integer_text?(text) ? text : ""
        when :float, :decimal
          if integer_text?(text)
            text + ".0"
          elsif float_text?(text)
            text
          else
            ""
          end
        when :boolean
          if text == "true" || text == "TRUE" || text == "1" || text == "'t'"
            "true"
          elsif text == "false" || text == "FALSE" || text == "0" || text == "'f'"
            "false"
          else
            ""
          end
        when :string, :text
          quoted_sql?(text) ? ruby_string(text[1, text.size - 2].gsub("''", "'")) : ""
        else
          ""
        end
      end

      def self.integer_text?(text)
        digits = text.start_with?("-") ? text[1, text.size - 1] : text
        return false if digits == ""

        digits.each_char { |ch| return false unless ch >= "0" && ch <= "9" }
        true
      end

      def self.float_text?(text)
        dot = text.index(".")
        return false if dot.nil?

        integer_text?(text[0, dot]) && integer_text?("0" + text[dot + 1, text.size - dot - 1])
      end

      def self.quoted_sql?(text)
        text.size >= 2 && text.start_with?("'") && text.end_with?("'")
      end

      # A double-quoted Ruby literal for `str`, with `#{` / `#$` / `#@`
      # escaped so the generated file never interpolates.
      def self.ruby_string(str)
        out = +"\""
        chars = str.chars
        chars.each_with_index do |ch, i|
          nxt = i + 1 < chars.size ? chars[i + 1] : ""
          if ch == "\\"
            out << "\\\\"
          elsif ch == "\""
            out << "\\\""
          elsif ch == "\n"
            out << "\\n"
          elsif ch == "#" && (nxt == "{" || nxt == "$" || nxt == "@")
            out << "\\#"
          else
            out << ch
          end
        end
        out << "\""
        out
      end
    end
  end
end
