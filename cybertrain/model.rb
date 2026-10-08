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
  # Not available (compared with ActiveRecord): declared associations,
  # `has_many :through`, `includes`, `pluck`, `update_all`, `destroy_all`,
  # dirty tracking, transactions around `save`, STI, enums and the `scope`
  # macro (write `def self.published = where(published: true)` instead).
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

    # Callback blocks receive the record as their argument
    # (`before_save { |post| post.title = post.title.strip }`): Spinel cannot
    # instance_exec a stored block (spikes/NOTES.md rule 2).
    #
    # Callbacks take a block only (no `before_save :method_name`, no `if:`),
    # run in the order they were declared, and their return value is ignored:
    # raising is the only way to stop the operation, and nothing is rolled
    # back. {Relation#delete_all} runs none.

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
    # Runs in {#destroy} before the DELETE. There is no `dependent:`; delete
    # children here:
    # @example
    #   before_destroy { |article| Comment.where(article_id: article.id).delete_all }
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
      Cast.iso8601(Time.now.utc)
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
        run_callbacks("before_update")
        update_row
        run_callbacks("after_update")
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

    # Runs {.before_destroy}, deletes the row, runs {.after_destroy}. The
    # record keeps its attributes and id but is no longer {#persisted?}.
    #
    # A record that was never saved has no row: destroy then runs no
    # callbacks, sends no DELETE and returns false.
    # @return [Boolean]
    # @api public
    def destroy
      return false unless @persisted

      run_callbacks("before_destroy")
      sql = "DELETE FROM #{Relation.quote_ident(self.class.table_name)} WHERE #{Relation.quote_ident("id")} = ?"
      id = @id
      Cybertrain::DB.with { |c| c.execute(sql, [id]) }
      @persisted = false
      run_callbacks("after_destroy")
      true
    end

    # Re-reads every column from the database.
    # @return [self]
    # @raise [RecordNotFound] when the row is gone
    # @api public
    def reload
      sql = "SELECT * FROM #{Relation.quote_ident(self.class.table_name)} WHERE #{Relation.quote_ident("id")} = ?"
      id = @id
      found = Cybertrain::DB.with { |c| c.execute(sql, [id]) }
      raise RecordNotFound, "Couldn't find #{model_name} with id=#{id}" if found.empty?
      load_row(found[0])
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
    # (`"2026-10-05T09:00:00Z"`); booleans, numbers, Strings and nil
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
      sets = row.keys.map { |k| "#{Relation.quote_ident(k)} = ?" }
      sql = "UPDATE #{Relation.quote_ident(self.class.table_name)} SET #{sets.join(", ")} WHERE #{Relation.quote_ident("id")} = ?"
      binds = row.values
      binds << @id
      Cybertrain::DB.with { |c| c.execute(sql, binds) }
      nil
    end
  end
end
