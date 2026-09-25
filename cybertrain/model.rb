require "json"
require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/errors"
require "cybertrain/validator"
require "cybertrain/relation"

module Cybertrain
  class RecordNotFound < StandardError
  end

  class RecordInvalid < StandardError
  end

  # Base class of every model. The per-table code (attribute ivars, casts,
  # finders) is generated into gen/models/ from db/schema.rb; this class holds
  # what is the same for every table: validations and callbacks (runtime data
  # keyed by model name, since Spinel cannot define methods at runtime),
  # persistence, and serialization.
  class Model
    VALIDATORS = {}   # model name => Array<Validator>
    CALLBACKS = {}    # "Post:before_save" => Array<Proc>; each block takes the record

    # validates :title, presence: true, length: { minimum: 3, maximum: 40 }
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
    def self.before_validation(&block) = add_model_callback("before_validation", block)
    def self.before_save(&block) = add_model_callback("before_save", block)
    def self.after_save(&block) = add_model_callback("after_save", block)
    def self.before_create(&block) = add_model_callback("before_create", block)
    def self.after_create(&block) = add_model_callback("after_create", block)
    def self.before_update(&block) = add_model_callback("before_update", block)
    def self.after_update(&block) = add_model_callback("after_update", block)
    def self.before_destroy(&block) = add_model_callback("before_destroy", block)
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

    attr_reader :id, :errors

    def initialize
      @id = 0
      @persisted = false
      @errors = Errors.new
    end

    def set_id(v)
      @id = v
      nil
    end

    def mark_persisted!
      @persisted = true
      nil
    end

    def persisted?
      @persisted
    end

    def new_record?
      !@persisted
    end

    def to_param
      @id.to_s
    end

    def valid?
      @errors.clear
      run_callbacks("before_validation")
      Model.validators_for(model_name).each { |v| v.validate(self) }
      @errors.empty?
    end

    # Validates, then runs before_save, before_create/before_update, writes
    # the row, and runs after_create/after_update and after_save -- the
    # ActiveRecord order. Returns false (and writes nothing) when invalid.
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

    def save!
      raise RecordInvalid, "Validation failed: #{@errors.full_messages.join(", ")}" unless save
      true
    end

    def update(attrs)
      assign_attributes(attrs)
      save
    end

    # A record that was never saved has no row: destroy then runs no
    # callbacks, sends no DELETE and returns false.
    def destroy
      return false unless @persisted

      run_callbacks("before_destroy")
      sql = "DELETE FROM #{Relation.quote_ident(self.class.table_name)} WHERE \"id\" = ?"
      id = @id
      Cybertrain::DB.with { |c| c.execute(sql, [id]) }
      @persisted = false
      run_callbacks("after_destroy")
      true
    end

    # Re-reads every column from the database.
    def reload
      sql = "SELECT * FROM #{Relation.quote_ident(self.class.table_name)} WHERE \"id\" = ?"
      id = @id
      found = Cybertrain::DB.with { |c| c.execute(sql, [id]) }
      raise RecordNotFound, "Couldn't find #{model_name} with id=#{id}" if found.empty?
      load_row(found[0])
      self
    end

    # Records are equal when they are the same model and the same saved row.
    def ==(other)
      return false unless other.is_a?(Model)
      @id != 0 && @id == other.id && model_name == other.model_name
    end

    def attributes
      attrs = { "id" => read_attribute(:id) }
      self.class.column_names.each do |column|
        attrs[column] = read_attribute(column.to_sym) unless column == "id"
      end
      attrs
    end

    # Time becomes its ISO8601 string; booleans, numbers, Strings and nil
    # stay as they are (Cast.to_sql would turn booleans into 1/0).
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
      sql = "UPDATE #{Relation.quote_ident(self.class.table_name)} SET #{sets.join(", ")} WHERE \"id\" = ?"
      binds = row.values
      binds << @id
      Cybertrain::DB.with { |c| c.execute(sql, binds) }
      nil
    end
  end
end
