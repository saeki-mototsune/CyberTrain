# Cybertrain::Model, continued: the class-level writes that build no model,
# upsert and the bulk writes (insert_all, insert_all!, upsert_all), with their
# helpers. Split out of cybertrain/model.rb, which requires this file at its
# end, after the subclass-hook stubs, so a program that requires model.rb
# gets all of Model before any generated model loads.
module Cybertrain
  class Model
    # Inserts one row, or, when it collides with an existing row on the
    # `conflict` columns (a UNIQUE index or the primary key), updates that
    # row instead: SQLite's `INSERT ... ON CONFLICT (...) DO UPDATE SET`.
    # The counter-and-statistics shape in one statement.
    #
    # `attrs` are column => value, bound (through Cast.to_sql), never
    # interpolated. `update` is column => SQL expression, where `excluded.x`
    # is the value this INSERT tried to write; like {ArticleRelation#order_sql}
    # it is the developer's SQL text and must never see request data. An
    # empty `update` is `DO NOTHING`. Every column name (attrs, conflict,
    # update keys) must be a column name (Ident), or ArgumentError.
    #
    # No model is built, no validation or callback runs, and
    # `created_at` / `updated_at` are not filled in: pass them in `attrs`
    # (and in `update`, `updated_at: "excluded.updated_at"`) when the table
    # has them. Use Symbol keys throughout (NOTES rule 51).
    # @example
    #   Stat.upsert({ project_id: 1, key: "GET /", calls: 1, max_ms: 12.5 },
    #               conflict: [:project_id, :key],
    #               update: { calls: "calls + excluded.calls",
    #                         max_ms: "MAX(max_ms, excluded.max_ms)" })
    # @param attrs [Hash{Symbol => Object}] the row to insert
    # @param conflict [Array<Symbol>] the conflict target's columns
    # @param update [Hash{Symbol => String}] column => SQL expression
    # @return [Integer] rows written: 1 inserted or updated, 0 when an empty
    #   `update` skipped a conflicting row
    # @raise [ArgumentError] on an empty `attrs` or `conflict`, or a name
    #   that is not a column name
    # @raise [DB::Error] when SQLite refuses the statement (no UNIQUE index
    #   matches `conflict`, a NOT NULL column is missing)
    # @api public
    def self.upsert(attrs, conflict:, update: {})
      Model.upsert_into(table_name, attrs, conflict, update)
    end

    # The work of {.upsert}, given the table: a class method on Model
    # itself so the generated subclasses need no code of their own (their
    # table_name override is what `upsert` passes).
    def self.upsert_into(table, attrs, conflict, update)
      raise ArgumentError, "upsert: no attributes" if attrs.empty?
      raise ArgumentError, "upsert: no conflict columns" if conflict.empty?

      columns = Array.new(0) { "" }
      binds = [nil, 0, 0.0, ""]
      binds.clear
      attrs.each do |key, value|
        columns << Relation.checked_column("upsert", key)
        binds << Cast.to_sql(value)
      end
      target = Array.new(0) { "" }
      conflict.each { |key| target << Relation.checked_column("upsert", key) }
      sets = Array.new(0) { "" }
      update.each do |key, expr|
        quoted = Relation.checked_column("upsert", key)
        sets << "#{quoted} = #{expr}"
      end
      marks = Array.new(columns.size) { "?" }
      # Each piece in a local before it is interpolated (NOTES rule 65).
      quoted_table = Relation.quote_ident(table)
      column_list = columns.join(", ")
      mark_list = marks.join(", ")
      target_list = target.join(", ")
      sql = +"INSERT INTO #{quoted_table} (#{column_list}) VALUES (#{mark_list})"
      sql << " ON CONFLICT (" << target_list << ")"
      if sets.empty?
        sql << " DO NOTHING"
      else
        sql << " DO UPDATE SET " << sets.join(", ")
      end
      Cybertrain::DB.with do |c|
        c.execute(sql, binds)
        c.changes
      end
    end

    # --- bulk writes (insert_all, insert_all!, upsert_all) ------------------

    # A typed empty `DECIMAL_SCALES` (column => scale) for a generated model
    # whose table has no decimal column with a scale (NOTES rule 9).
    # @return [Hash{String => Integer}]
    def self.no_decimal_scales
      h = { "" => 0 }
      h.delete("")
      h
    end

    # A typed empty `ENCRYPTED_COLUMNS` for a generated model with no
    # encrypted column (a model that declares `encrypts` lists them).
    # @return [Array<String>]
    def self.no_encrypted_columns = Array.new(0) { "" }

    # The work of the generated `insert_all`, `insert_all!` and
    # `upsert_all` class methods, given the table and its schema (the
    # model's COLUMN_TYPES, DECIMAL_SCALES and ENCRYPTED_COLUMNS constants).
    #
    # `rows` is an Array of Hashes, Symbol or String keys, every row with
    # the same key set (any order), else ArgumentError before anything is
    # written. Only the supplied columns are named in the INSERT, so a column
    # no row mentions takes the table's DEFAULT. Each value takes the cast a
    # save gives it: a decimal rounded to its scale (nil stays NULL), a Hash
    # as JSON text, a Date as `YYYY-MM-DD`, a Time in the storage format, a
    # binary value as a DB::Blob, a boolean as 1/0. With `record_timestamps`
    # true, `created_at` / `updated_at` columns the table has and the rows do
    # not supply are filled with one `now` for the whole call.
    #
    # `on_conflict` is `:nothing` (insert_all: `ON CONFLICT DO NOTHING`, a
    # duplicate is skipped), `:raise` (insert_all!: a plain INSERT, a
    # duplicate raises DB::Error) or `:update` (upsert_all: `ON CONFLICT
    # (unique_by) DO UPDATE SET c = excluded.c` for each supplied column
    # except `id`, the `unique_by` columns and `created_at`, narrowed to
    # `update_only` when that is not nil; `updated_at` is set when
    # `record_timestamps` is true and the table has it; nothing left to set
    # is `DO NOTHING`).
    #
    # The rows go in statements of `variable_limit / columns` rows each, all
    # inside one {DB.transaction} (joining one already open on this thread),
    # so a failure in any statement leaves nothing of the call written. No
    # model is built, no validation or callback runs, and a column in
    # `encrypted` is refused (ArgumentError), as a row key and in
    # `returning`, `unique_by` and `update_only` alike.
    #
    # Returns the `RETURNING` rows, `returning`'s columns each cast by its
    # type as {Relation#pluck} casts it (an Integer id, a Time for a
    # datetime, ...): one Hash per row actually inserted or updated, so a
    # skipped duplicate has none. `returning` empty or nil returns `[]`.
    # @param table [String]
    # @param rows [Array<Hash{Symbol, String => Object}>]
    # @param column_types [Hash{String => Symbol}] every column, `id` included
    # @param scales [Hash{String => Integer}] decimal column => scale
    # @param encrypted [Array<String>] the encrypted columns
    # @param returning [Array<Symbol, String>, nil]
    # @param record_timestamps [Boolean]
    # @param on_conflict [Symbol] `:nothing`, `:raise` or `:update`
    # @param unique_by [Array<Symbol, String>, nil] the conflict target (`:update`)
    # @param update_only [Array<Symbol, String>, nil] the columns an upsert may set
    # @return [Array<Hash{String => Object}>]
    # @raise [ArgumentError] on rows with different key sets, a name that is
    #   not a column of the table, an encrypted column, or an upsert without
    #   `unique_by`
    # @raise [Cybertrain::DB::Error] when SQLite refuses a statement
    #   (a constraint, a duplicate under insert_all!); nothing is written
    def self.insert_all_into(table, rows, column_types, scales, encrypted, returning, record_timestamps, on_conflict,
                             unique_by, update_only)
      caller_name = Model.bulk_method_name(on_conflict)
      out = [Model.bulk_empty_row]
      out.clear

      returned = Model.bulk_columns(caller_name, returning, column_types)
      targets = Model.bulk_columns(caller_name, unique_by, column_types)
      restricted = !update_only.nil?
      only = Model.bulk_columns(caller_name, update_only, column_types)
      # An encrypted column holds payloads: returned, it would be the
      # ciphertext; as a conflict target or an update it would compare or
      # copy ciphertext. Refused wherever it is named.
      Model.refuse_encrypted(caller_name, "returning: ", returned, encrypted)
      Model.refuse_encrypted(caller_name, "unique_by: ", targets, encrypted)
      Model.refuse_encrypted(caller_name, "update_only: ", only, encrypted)
      if on_conflict == :update && targets.empty?
        raise ArgumentError, "#{caller_name}: unique_by names no column"
      end
      return out if rows.empty?

      # The first row's keys are the column list; every row must have the
      # same set.
      columns = Array.new(0) { "" }
      rows[0].each_key { |k| columns << k.to_s }
      j = 0
      while j < columns.size
        name = Model.bulk_column(caller_name, columns[j], column_types)
        raise ArgumentError, "#{caller_name}: #{name} is an encrypted column" if encrypted.include?(name)
        j += 1
      end
      supplied = columns.size
      now = Model.now_string
      fill_created = record_timestamps && column_types.key?("created_at") && !columns.include?("created_at")
      fill_updated = record_timestamps && column_types.key?("updated_at") && !columns.include?("updated_at")
      columns << "created_at" if fill_created
      columns << "updated_at" if fill_updated
      types = Array.new(0) { :unknown }
      column_scales = Array.new(0) { 0 }
      columns.each do |name|
        types << column_types[name]
        column_scales << (scales.key?(name) ? scales[name].to_i : -1)
      end

      binds = [nil, 0, 0.0, "", Cybertrain::DB::Blob.new("")]
      binds.clear
      i = 0
      while i < rows.size
        cells = Model.bulk_cells(rows[i])
        same = cells.size == supplied && rows[i].size == supplied
        j = 0
        while same && j < supplied
          same = cells.key?(columns[j])
          j += 1
        end
        unless same
          raise ArgumentError, "#{caller_name}: every row must have the same keys (row #{i} has " \
                               "#{cells.keys.join(", ")}, row 0 has #{columns[0, supplied].join(", ")})"
        end
        j = 0
        while j < supplied
          binds << Model.bulk_bind(types[j], column_scales[j], cells[columns[j]])
          j += 1
        end
        binds << now if fill_created
        binds << now if fill_updated
        i += 1
      end

      # Each piece in a local before it is interpolated (NOTES rule 65).
      quoted_table = Relation.quote_ident(table)
      column_list = columns.map { |name| Relation.quote_ident(name) }.join(", ")
      marks = Array.new(columns.size) { "?" }
      one_row = "(" + marks.join(", ") + ")"
      tail = Model.bulk_conflict_sql(on_conflict, columns, targets, restricted, only, record_timestamps, column_types)
      unless returned.empty?
        returned_list = returned.map { |name| Relation.quote_ident(name) }.join(", ")
        tail << " RETURNING " << returned_list
      end
      returned_types = Array.new(0) { :unknown }
      returned.each { |name| returned_types << column_types[name] }

      limit = Cybertrain::DB.with { |c| c.variable_limit }
      per = limit / columns.size
      per = 1 if per < 1
      statements = Array.new(0) { "" }
      bind_sets = [binds]
      bind_sets.clear
      start = 0
      while start < rows.size
        count = rows.size - start
        count = per if count > per
        values = Array.new(count) { one_row }.join(", ")
        statements << "INSERT INTO #{quoted_table} (#{column_list}) VALUES #{values}#{tail}"
        bind_sets << binds[start * columns.size, count * columns.size]
        start += count
      end

      Cybertrain::DB.transaction do |c|
        k = 0
        while k < statements.size
          found = c.execute(statements[k], bind_sets[k])
          m = 0
          while m < found.size
            out << Model.bulk_returned_row(found[m], returned, returned_types)
            m += 1
          end
          k += 1
        end
      end
      out
    end

    # Raises ArgumentError when one of `names` is in `encrypted`
    # (insert_all_into's returning:, unique_by: and update_only:).
    def self.refuse_encrypted(caller_name, option, names, encrypted)
      i = 0
      while i < names.size
        name = names[i]
        raise ArgumentError, "#{caller_name}: #{option}#{name} is an encrypted column" if encrypted.include?(name)

        i += 1
      end
      nil
    end

    # The generated method an `on_conflict` belongs to, for messages.
    def self.bulk_method_name(on_conflict)
      case on_conflict
      when :raise then "insert_all!"
      when :update then "upsert_all"
      else "insert_all"
      end
    end

    # An empty RETURNING row, seeded with every type a cell can be
    # (NOTES rules 9 and 46).
    def self.bulk_empty_row
      row = { "" => [nil, 0, 0.0, "", true, Time.at(0), Date.new(1970, 1, 1)][0] }
      row.delete("")
      row
    end

    # A column name of the table, as a String: a column name (Ident) the
    # schema has, else ArgumentError.
    def self.bulk_column(caller_name, name, column_types)
      Relation.checked_column(caller_name, name)
      raise ArgumentError, "#{caller_name}: #{name} is not a column of this table" unless column_types.key?(name)

      name
    end

    # `list`'s names as checked column Strings; nil is none.
    def self.bulk_columns(caller_name, list, column_types)
      out = Array.new(0) { "" }
      case list
      when nil then nil
      when Array then list.each { |k| out << Model.bulk_column(caller_name, k.to_s, column_types) }
      end
      out
    end

    # One row's values keyed by the String of each key.
    def self.bulk_cells(row)
      cells = { "" => [nil, 0, 0.0, "", true, Time.at(0), Date.new(1970, 1, 1)][0] }
      cells.delete("")
      row.each { |k, v| cells[k.to_s] = v }
      cells
    end

    # The value a bulk row binds for a column of type `type`: the cast a
    # save applies (the generated write_attribute's, then to_row's).
    def self.bulk_bind(type, scale, v)
      case type
      when :integer then Cast.int_or_nil(v)
      when :float then Cast.float_or_nil(v)
      when :decimal then Cast.round_scale_or_nil(v, scale)
      when :boolean then Cast.to_sql(Cast.bool_or_nil(v))
      when :datetime then Cast.to_sql(Cast.time_or_nil(v))
      when :date then Cast.to_sql(Cast.date_or_nil(v))
      when :json then Cast.json_text(Cast.hash_or_nil(v))
      when :binary then Cybertrain::DB::Blob.wrap(Cast.str_or_nil(v))
      when :string, :text then Cast.str_or_nil(v)
      else Cast.to_sql(v)
      end
    end

    # The ON CONFLICT clause of a bulk statement ("" for insert_all!).
    def self.bulk_conflict_sql(on_conflict, columns, targets, restricted, only, record_timestamps, column_types)
      return +" ON CONFLICT DO NOTHING" if on_conflict == :nothing
      return +"" unless on_conflict == :update

      sets = Array.new(0) { "" }
      columns.each do |name|
        next if name == "id" || name == "created_at" || targets.include?(name)

        stamp = name == "updated_at" && record_timestamps && column_types.key?("updated_at")
        next if restricted && !stamp && !only.include?(name)

        quoted = Relation.quote_ident(name)
        sets << "#{quoted} = excluded.#{quoted}"
      end
      target_list = targets.map { |name| Relation.quote_ident(name) }.join(", ")
      sql = +" ON CONFLICT (" << target_list << ")"
      if sets.empty?
        sql << " DO NOTHING"
      else
        sql << " DO UPDATE SET " << sets.join(", ")
      end
      sql
    end

    # A RETURNING row with each named column cast by its type.
    def self.bulk_returned_row(found, names, types)
      row = Model.bulk_empty_row
      i = 0
      while i < names.size
        row[names[i]] = Relation.typed_cell(types[i], found[names[i]])
        i += 1
      end
      row
    end
  end
end
