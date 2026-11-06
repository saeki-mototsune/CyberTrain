require "json"
require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/errors"
require "cybertrain/validator"
require "cybertrain/relation"

module Cybertrain
  # Raised by `find` and {Model#reload} when no row has the id. Map it to a
  # 404 with `rescue_from Cybertrain::RecordNotFound, with: :record_not_found`
  # in ApplicationController (the generated app does).
  # @api public
  class RecordNotFound < StandardError
  end

  # Raised by {Model#save!} when validation fails; the message is
  # `"Validation failed: "` plus the record's full messages.
  # @api public
  class RecordInvalid < StandardError
  end

  # Base class of every model.
  #
  # You never subclass it by hand: `spin run gen` writes one subclass per table
  # in `db/schema.rb` into `gen/models/<singular>.rb` (attribute accessors,
  # casts, finders and the associations read off foreign keys; see {Article}
  # for the full generated surface), and `app/models/<singular>.rb` reopens it,
  # with no superclass, for validations, callbacks and your own methods:
  #
  #     # app/models/article.rb
  #     class Article
  #       validates :title, presence: true
  #       validates :body, presence: true, length: { minimum: 10 }
  #
  #       before_save { |article| article.title = article.title.strip }
  #
  #       def summary = body[0, 80]
  #     end
  #
  # Re-run `spin run gen` after changing the schema (`cybertrain db migrate`
  # and the development server do it for you).
  #
  # Associations come from the schema's foreign keys and from
  # {.has_many} / {.has_one} / {.belongs_to} lines in the app/models file.
  #
  # Not available (compared with ActiveRecord): polymorphic associations,
  # `has_many :through`, `includes`, a one-column `pluck` (relations have
  # `pluck_str` / `pluck_int` / `pluck_float`; `pluck` takes two or more
  # columns), a polymorphic `sum` / `minimum` / `maximum` (they come typed:
  # `sum_int`, `minimum_time`, ...), a `where` over a Range with
  # other than Integer ends (use `where_between`), dirty tracking,
  # transactions around `save` (except a counter_cache child's update),
  # STI and enums.
  #
  # Implementation: validations and callbacks are runtime data keyed by model
  # name, since Spinel cannot define methods at runtime.
  # @api public
  class Model
    VALIDATORS = {}   # model name => Array<Validator>
    CALLBACKS = {}    # "Post:before_save" => Array<Proc>; each block takes the record
    # What generated from_row passes to new: never written to (initialize
    # skips assign_attributes for an empty Hash), so one serves every row.
    NO_ATTRIBUTES = {}

    # Declares validations for one attribute, run by {#valid?} (and so by
    # {#save}) in declaration order. Only `presence` and `length` exist.
    #
    # - `presence: true` adds `"can't be blank"` when the value is `nil` or a
    #   String that is empty after `strip`. `false` and `0` are present.
    # - `length: { minimum: n, maximum: m }` (either key) adds
    #   `"is too short (minimum is n characters)"` or
    #   `"is too long (maximum is m characters)"`. A `nil` value is left to
    #   `presence`; other keys (`is:`, `in:`) are ignored.
    # - `allow_blank: true` skips the length rule for a blank value. It does
    #   not apply to `presence`.
    #
    # For anything else (uniqueness, formats, cross-field rules), add errors
    # yourself in a {.before_validation} block: `valid?` clears the errors,
    # runs that block, then the declared rules.
    #
    # @example
    #   validates :title, presence: true, length: { minimum: 3, maximum: 40 }
    #   validates :subtitle, length: { maximum: 80 }, allow_blank: true
    # @param attr [Symbol] the attribute (its SQL column name)
    # @param presence [Boolean]
    # @param length [Hash{Symbol => Integer}, nil] `:minimum` and/or `:maximum`
    # @param allow_blank [Boolean] skip the length rule when the value is blank
    # @return [nil]
    # @api public
    def self.validates(attr, presence: false, length: nil, allow_blank: false)
      list = (VALIDATORS[self.name] ||= Array.new(0) { Validator.new(:base, :presence) })
      list << Validator.new(attr, :presence) if presence
      unless length.nil?
        minimum = length.key?(:minimum) ? length[:minimum] : -1
        maximum = length.key?(:maximum) ? length[:maximum] : -1
        list << Validator.new(attr, :length, minimum, maximum, allow_blank)
      end
      nil
    end

    # Declares a named query: `scope :recent, -> { order(created_at: :desc) }`
    # or, with parameters, `scope :min_views, ->(n) { where("views >= ?", n) }`.
    # The generator reads the line as text (nothing is evaluated): it copies
    # the lambda's parameters and body into a method of the model's Relation
    # (`def min_views(n) = where("views >= ?", n)`, so the body runs on the
    # relation) and a class method (`def self.min_views(n) = all.min_views(n)`),
    # so `Post.recent.min_views(2).first` chains like any other query. At run
    # time this method does nothing; it exists so the model file loads.
    #
    # A scope is one line, a `->` lambda with plain or defaulted positional
    # parameters; any other `scope` line (a multi-line lambda, `lambda do`, a
    # `proc`, keyword or splat parameters) stops the generator, as does a
    # scope named like a column, a query method (`where`, `count`, `first`,
    # ...) or another scope of the model.
    # @example
    #   scope :published, -> { where(published: true) }
    #   scope :since, ->(time) { where("created_at > ?", time) }
    # @param name [Symbol] the scope's name
    # @param body [Proc] the lambda (never called)
    # @return [nil]
    # @api public
    def self.scope(name, body) = nil

    # Declares that each record has many children: `has_many :comments`
    # reads the comments whose `<singular of this table>_id` is this
    # record's id. Like {.scope}, the generator reads the line as text and
    # writes the reader into gen/models (`def comments =
    # CommentRelation.new("comments").where(post_id: @id)`); at run time this
    # method does nothing. The reader returns the children's Relation, so it
    # chains: `post.comments.where(approved: true).count`; add `.to_a` for
    # an Array. A schema foreign key gives the same reader without a
    # declaration; a declaration names it, or adds `dependent:`.
    #
    # The macro is alone on its line, at class level, with literal options
    # only (a trailing comment, a `;` or a parenthesised call stops the
    # generator): `class_name:` (a String or Symbol;
    # inferred from the name, `comments` -> Comment), `foreign_key:` (the
    # children's column; inferred `post_id`) and `dependent:` -- `:destroy`
    # (each child is loaded and destroyed, so its callbacks and its own
    # `dependent:` run), `:delete_all` (one DELETE) or `:nullify` (one
    # UPDATE setting the key to NULL; the column must be nullable), applied
    # by {#destroy} before its DELETE in the same transaction. Without
    # `dependent:` the database's foreign key decides (`on_delete:` in the
    # schema). A model, column or option that does not exist stops the
    # generator with the file and line. No `:through`, scope lambda,
    # `inverse_of` or `counter_cache:` (that goes on the {.belongs_to}).
    # @example
    #   has_many :comments, dependent: :destroy
    #   has_many :drafts, class_name: "Post", foreign_key: :author_id
    # @param name [Symbol] the reader's name
    # @param dependent [Symbol, nil] `:destroy`, `:delete_all` or `:nullify`
    # @param class_name [String, Symbol, nil] the children's model
    # @param foreign_key [Symbol, String, nil] the children's key column
    # @return [nil]
    # @api public
    def self.has_many(name, dependent: nil, class_name: nil, foreign_key: nil) = nil

    # Declares that each record has at most one child: `has_one :profile`
    # reads `Profile.find_by(user_id: id)` (nil when there is none). Read as
    # text by the generator, like {.has_many}: alone on its line, literal
    # options only (a trailing comment is refused), the same options; a
    # has_one on a foreign key replaces the has_many the key would give.
    # @example
    #   has_one :profile, dependent: :destroy
    # @param name [Symbol] the reader's name
    # @param dependent [Symbol, nil] `:destroy`, `:delete_all` or `:nullify`
    # @param class_name [String, Symbol, nil] the child's model (inferred
    #   `Profile`)
    # @param foreign_key [Symbol, String, nil] the child's key column
    #   (inferred `<singular of this table>_id`)
    # @return [nil]
    # @api public
    def self.has_one(name, dependent: nil, class_name: nil, foreign_key: nil) = nil

    # Declares the parent a record points to: `belongs_to :author` reads
    # `Author.find_by(id: author_id)` and keeps it until `author_id`
    # changes or {#reload}. Read as text by the generator, like {.has_many}:
    # alone on its line, literal options only (a trailing comment is
    # refused).
    #
    # Unless `optional: true`, the record is invalid while the key is nil
    # or 0 ("can't be blank" on `author_id`; {.validates_foreign_key}).
    # `counter_cache: true` keeps the parent's `<children>_count` column
    # (`posts.comments_count`, or `<has_many name>_count` when the parent
    # declares one over this key) in step: +1 after create, -1 after
    # destroy (from the key the row holds, read inside destroy's
    # transaction), and a move to another parent counted on both sides; the
    # update and both counts run in one transaction. The column must exist;
    # the parent's own {#save} leaves it alone (its copy may be stale).
    # @example
    #   belongs_to :post, counter_cache: true
    #   belongs_to :author, class_name: "User", optional: true
    # @param name [Symbol] the reader's name
    # @param class_name [String, Symbol, nil] the parent's model (inferred
    #   from the name)
    # @param foreign_key [Symbol, String, nil] this table's key column
    #   (inferred `<name>_id`)
    # @param optional [Boolean] skip the foreign key validation
    # @param counter_cache [Boolean] count the children on the parent
    # @return [nil]
    # @api public
    def self.belongs_to(name, class_name: nil, foreign_key: nil, optional: false, counter_cache: false) = nil

    # The validation a declared {.belongs_to} adds to its generated class:
    # "can't be blank" on the foreign key while it is nil, blank or 0 (the
    # id of no saved record), so `save` returns false instead of the
    # database refusing the row.
    # @param attr [Symbol] the foreign key column
    # @return [nil]
    # @api public
    def self.validates_foreign_key(attr)
      list = (VALIDATORS[self.name] ||= Array.new(0) { Validator.new(:base, :presence) })
      list << Validator.new(attr, :foreign_key)
      nil
    end

    # Callback blocks receive the record as their argument
    # (`before_save { |post| post.title = post.title.strip }`): Spinel cannot
    # instance_exec a stored block (spikes/NOTES.md rule 2).
    #
    # Callbacks take a block only (no `before_save :method_name`, no `if:`),
    # run in the order they were declared, and their return value is ignored:
    # raising is the only way to stop the operation. {#destroy} runs in a
    # transaction, so a raise there rolls its DELETE back; {#save} does not
    # (except a counter_cache child's update). {Relation#delete_all} runs
    # none.

    # Runs at the start of every {#valid?} (so of every {#save}), after the
    # errors are cleared and before the declared validations. Errors added
    # here make the record invalid.
    # @example
    #   before_validation do |post|
    #     taken = Post.where(slug: post.slug).where_sql("id != ?", [post.id]).exists?
    #     post.errors.add(:slug, "is taken") if taken
    #   end
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.before_validation(&block) = add_model_callback("before_validation", block)
    # Runs in {#save} after validation passes, before the INSERT or UPDATE.
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.before_save(&block) = add_model_callback("before_save", block)
    # Runs in {#save} after the row is written and after `after_create` /
    # `after_update`.
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.after_save(&block) = add_model_callback("after_save", block)
    # Runs in {#save} of a new record, after `before_save`, before the INSERT.
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.before_create(&block) = add_model_callback("before_create", block)
    # Runs in {#save} of a new record, after the INSERT (the record has its id).
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.after_create(&block) = add_model_callback("after_create", block)
    # Runs in {#save} of a persisted record, after `before_save`, before the
    # UPDATE.
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.before_update(&block) = add_model_callback("before_update", block)
    # Runs in {#save} of a persisted record, after the UPDATE.
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.after_update(&block) = add_model_callback("after_update", block)
    # Runs in {#destroy} before the `dependent:` children go and before the
    # DELETE, inside destroy's transaction.
    # @example
    #   before_destroy { |article| AuditLog.create(note: "deleted #{article.id}") }
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.before_destroy(&block) = add_model_callback("before_destroy", block)
    # Runs in {#destroy} after the DELETE.
    # @yieldparam record [Model]
    # @return [nil]
    # @api public
    def self.after_destroy(&block) = add_model_callback("after_destroy", block)

    def self.add_model_callback(kind, block)
      (CALLBACKS["#{self.name}:#{kind}"] ||= []) << block
      nil
    end

    def self.validators_for(model_name)
      list = VALIDATORS[model_name]
      list.nil? ? Array.new(0) { Validator.new(:base, :presence) } : list
    end

    def self.callbacks_for(model_name, kind)
      CALLBACKS["#{model_name}:#{kind}"]
    end

    def self.now_string
      Cast.sql_datetime(Time.now.utc)
    end

    # `Cybertrain::DB.transaction`, under the name Rails gives it: saves,
    # updates, destroys and queries run in the block (on this thread) are one
    # transaction, committed when the block returns and rolled back when it
    # raises. The block gets the connection, for SQL of its own.
    #
    #     Article.transaction do |c|
    #       article.save!
    #       Comment.create(article_id: article.id, body: "First!")
    #     end
    #
    # As with ActiveRecord, the transaction is the database's, not the
    # model's: `Article.transaction` and `Comment.transaction` are the same.
    # Unlike ActiveRecord it returns nil rather than the block's value, a
    # `save` returning false does not roll anything back (raise, or use
    # `save!`), and there is no `ActiveRecord::Rollback`.
    # @param immediate [Boolean] BEGIN IMMEDIATE instead of BEGIN
    # @yieldparam conn [Cybertrain::DB::Connection]
    # @return [nil]
    # @api public
    def self.transaction(immediate: false, &block)
      Cybertrain::DB.transaction(immediate: immediate, &block)
    end

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
    # encrypted column.
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
    # `encrypted` is refused (ArgumentError).
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

    # --- hooks every generated subclass overrides ---------------------------
    # The stubs are required: a base method calling a method only subclasses
    # define crashes the compiler (spikes/NOTES.md rule 3).

    def self.table_name = ""
    def self.column_names = Array.new(0) { "" }
    def model_name = ""
    def read_attribute(name) = nil
    def write_attribute(name, value) = nil
    def assign_attributes(attrs) = self
    def to_row = { "" => Cast.to_sql(nil) }   # seeds the Hash<String, value> type
    def load_row(row) = nil
    def read_association(name) = nil
    def call_view_method(name) = nil
    # Declared associations (has_many / has_one / belongs_to): the
    # `dependent:` children, the caches {#reload} clears, and counter_cache.
    # counter_cache_created / _destroyed / _was / _moved have no stub: only
    # the generated callback blocks call them, and a block's record is typed
    # Cybertrain::Model, so a stub here would be the method they call.
    def destroy_dependents = nil
    def reset_association_caches = nil
    def counter_cached? = false
    def counter_cache_columns = Array.new(0) { "" }

    # --- concrete ----------------------------------------------------------

    # The primary key, `0` until the record is first saved.
    # @return [Integer]
    # @api public
    attr_reader :id

    # The validation messages from the last {#valid?} or {#save}.
    # @return [Errors]
    # @api public
    def errors
      e = @errors
      return e unless e.nil?

      e = Errors.new
      @errors = e
      e
    end

    def initialize
      @id = 0
      @persisted = false
      # Made on first use: a page that lists loaded records never validates
      # them, and an Errors (with its Hash and seed Array) per record was a
      # few dozen allocations per request.
      @errors = nil
    end

    def set_id(v)
      @id = v
      nil
    end

    def mark_persisted!
      @persisted = true
      nil
    end

    # @return [Boolean] true once the record has been saved or was loaded
    #   from the database, false after {#destroy}
    # @api public
    def persisted?
      @persisted
    end

    # @return [Boolean] the opposite of {#persisted?}
    # @api public
    def new_record?
      !@persisted
    end

    # The id as a String, what route helpers put in a URL (`"0"` for a new
    # record).
    # @return [String]
    # @api public
    def to_param
      @id.to_s
    end

    # Clears {#errors}, runs the {.before_validation} callbacks, then every
    # rule declared with {.validates}.
    # @return [Boolean] true when no errors were added
    # @api public
    def valid?
      errors.clear
      run_callbacks("before_validation")
      Model.validators_for(model_name).each { |v| v.validate(self) }
      errors.empty?
    end

    # Validates, then runs before_save, before_create/before_update, writes
    # the row, and runs after_create/after_update and after_save -- the
    # ActiveRecord order. Returns false (and writes nothing) when invalid.
    #
    # A new record is INSERTed (`created_at` / `updated_at` are filled in when
    # the table has them and they are nil) and gets its {#id}; a persisted one
    # is UPDATEd, every column, with `updated_at` set to now. Timestamps are
    # UTC, to the second.
    #
    # @example
    #   @article = Article.new(article_params)
    #   if @article.save
    #     redirect_to article_path(@article), status: :see_other
    #   else
    #     render :new, status: :unprocessable_entity
    #   end
    # @return [Boolean] false when invalid (see {#errors})
    # @raise [DB::Error] when SQLite refuses the write (a NOT NULL or foreign
    #   key constraint, a missing column)
    # @api public
    def save
      return false unless valid?

      run_callbacks("before_save")
      if @persisted
        # A counter_cache child reads its persisted key (before_update),
        # writes the row and moves the counts (after_update) in one
        # transaction, so a raise leaves the counters as they were.
        if counter_cached? && !Cybertrain::DB.in_transaction?
          Cybertrain::DB.transaction { |_c| update_with_callbacks }
        else
          update_with_callbacks
        end
      else
        run_callbacks("before_create")
        insert_row
        run_callbacks("after_create")
      end
      run_callbacks("after_save")
      true
    end

    # Like {#save}, but raises instead of returning false.
    # @return [true]
    # @raise [RecordInvalid] when validation fails
    # @api public
    def save!
      raise RecordInvalid, "Validation failed: #{errors.full_messages.join(", ")}" unless save
      true
    end

    # Assigns the attributes (cast to the column types, unknown keys ignored)
    # and saves.
    # @example
    #   @article.update(article_params)
    # @param attrs [Hash{String, Symbol => Object}] e.g. a permitted
    #   {Params#permit} Hash
    # @return [Boolean] the result of {#save}
    # @api public
    def update(attrs)
      assign_attributes(attrs)
      save
    end

    # Writes the given columns straight to the row with one UPDATE of
    # exactly those columns, then keeps the new values on the record: no
    # validation, no callback, `updated_at` left alone. Each value is cast
    # as the attribute writer casts it and stored as {#save} would store it
    # (a decimal rounded to its scale, a Hash as JSON text). Keys are SQL
    # column names.
    # @example
    #   article.update_columns(views: article.views + 1)
    # @param attrs [Hash{Symbol => Object}] column => value
    # @return [true]
    # @raise [ArgumentError] on an empty Hash, a key that is not a column
    #   of the model (or is `id`), or a record that was never saved
    # @api public
    def update_columns(attrs)
      raise ArgumentError, "update_columns: no attributes" if attrs.empty?
      raise ArgumentError, "update_columns: #{model_name} is not saved (a new record has no row)" unless @persisted

      names = Array.new(0) { "" }
      attrs.each do |key, _value|
        name = key.to_s
        unless name != "id" && column?(name)
          raise ArgumentError, "update_columns: #{name.inspect} is not a column of #{model_name}"
        end

        names << name
      end
      attrs.each { |key, value| write_attribute(key.to_s.to_sym, value) }
      # to_row's expressions for those columns: the generated casts and
      # scale rounding, read off the values just written.
      row = to_row
      sets = Array.new(0) { "" }
      binds = [nil, 0, 0.0, "", DB::Blob.new("")]
      binds.clear
      names.each do |name|
        sets << "#{Relation.quote_ident(name)} = ?"
        binds << row[name]
      end
      binds << @id
      table = Relation.quote_ident(self.class.table_name)
      id_column = Relation.quote_ident("id")
      set_list = sets.join(", ")
      sql = "UPDATE #{table} SET #{set_list} WHERE #{id_column} = ?"
      Cybertrain::DB.with { |c| c.execute(sql, binds) }
      true
    end

    # Runs {.before_destroy}, removes the `dependent:` children of
    # {.has_many} / {.has_one}, deletes the row, runs {.after_destroy}, all
    # in one transaction (joining one already open): a raise anywhere rolls
    # every step back and the record stays {#persisted?}. Afterwards the
    # record keeps its attributes and id but is no longer {#persisted?}.
    #
    # A record that was never saved has no row: destroy then runs no
    # callbacks, sends no DELETE and returns false.
    # @return [Boolean]
    # @api public
    def destroy
      return false unless @persisted

      begin
        if Cybertrain::DB.in_transaction?
          destroy_with_callbacks
        else
          Cybertrain::DB.transaction { |_c| destroy_with_callbacks }
        end
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        @persisted = true
        raise e
      end
      true
    end

    # Re-reads every column from the database and forgets every
    # association it had read (a belongs_to parent, a preload).
    # @return [self]
    # @raise [RecordNotFound] when the row is gone
    # @api public
    def reload
      sql = "SELECT * FROM #{Relation.quote_ident(self.class.table_name)} WHERE #{Relation.quote_ident("id")} = ?"
      id = @id
      found = Cybertrain::DB.with { |c| c.execute_models(sql, [id]) }
      raise RecordNotFound, "Couldn't find #{model_name} with id=#{id}" if found.empty?
      load_row(found[0])
      reset_association_caches
      self
    end

    # Records are equal when they are the same model and the same saved row.
    # Two unsaved records are never equal, not even a record to itself.
    # @param other [Object]
    # @return [Boolean]
    # @api public
    def ==(other)
      return false unless other.is_a?(Model)
      @id != 0 && @id == other.id && model_name == other.model_name
    end

    # Every column, keyed by its SQL name, `"id"` first, with typed values.
    # @example
    #   article.attributes  # => {"id" => 1, "title" => "Hello", "body" => "...", "created_at" => 2026-10-05 09:00:00 UTC, ...}
    # @return [Hash{String => Object}]
    # @api public
    def attributes
      attrs = { "id" => read_attribute(:id) }
      self.class.column_names.each do |column|
        attrs[column] = read_attribute(column.to_sym) unless column == "id"
      end
      attrs
    end

    # {#attributes}, ready for JSON: a Time becomes its ISO 8601 String
    # (`"2026-10-05T09:00:00.000Z"`); booleans, numbers, Strings and nil
    # stay as they are (Cast.to_sql would turn booleans into 1/0).
    # @return [Hash{String => Object}]
    # @api public
    def as_json
      out = {}
      attributes.each do |k, v|
        out[k] = case v
                 when Time then Cast.iso8601(v)
                 else v
                 end
      end
      out
    end

    # {#as_json} as a JSON String, e.g. for `render json: @article.to_json`.
    # @return [String]
    # @api public
    def to_json
      JSON.generate(as_json)
    end

    private

    def run_callbacks(kind)
      list = Model.callbacks_for(model_name, kind)
      list.each { |cb| cb.call(self) } unless list.nil?
      nil
    end

    def column?(name)
      self.class.column_names.include?(name)
    end

    def update_with_callbacks
      run_callbacks("before_update")
      update_row
      run_callbacks("after_update")
      nil
    end

    def destroy_with_callbacks
      run_callbacks("before_destroy")
      destroy_dependents
      sql = "DELETE FROM #{Relation.quote_ident(self.class.table_name)} WHERE #{Relation.quote_ident("id")} = ?"
      id = @id
      Cybertrain::DB.with { |c| c.execute(sql, [id]) }
      @persisted = false
      run_callbacks("after_destroy")
      nil
    end

    # created_at/updated_at are filled in when the table has them and the
    # record does not already carry a value (as ActiveRecord does).
    def insert_row
      now = Model.now_string
      write_attribute(:created_at, now) if column?("created_at") && read_attribute(:created_at).nil?
      write_attribute(:updated_at, now) if column?("updated_at") && read_attribute(:updated_at).nil?
      row = to_row
      marks = Array.new(row.size) { "?" }
      columns = row.keys.map { |k| Relation.quote_ident(k) }
      sql = "INSERT INTO #{Relation.quote_ident(self.class.table_name)} (#{columns.join(", ")}) VALUES (#{marks.join(", ")})"
      binds = row.values
      new_id = Cybertrain::DB.with do |c|
        c.execute(sql, binds)
        c.last_insert_id
      end
      @id = new_id
      @persisted = true
      nil
    end

    def update_row
      write_attribute(:updated_at, Model.now_string) if column?("updated_at")
      row = to_row
      # A counter_cache column is the children's to change (Rails'
      # attr_readonly): this record's copy may be stale.
      skipped = counter_cache_columns
      sets = Array.new(0) { "" }
      binds = row.values
      binds.clear
      row.each do |k, v|
        next if skipped.include?(k)

        sets << "#{Relation.quote_ident(k)} = ?"
        binds << v
      end
      sql = "UPDATE #{Relation.quote_ident(self.class.table_name)} SET #{sets.join(", ")} WHERE #{Relation.quote_ident("id")} = ?"
      binds << @id
      Cybertrain::DB.with { |c| c.execute(sql, binds) }
      nil
    end
  end
end
