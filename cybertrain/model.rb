require "json"
require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/errors"
require "cybertrain/validator"
require "cybertrain/relation"
# A model concern (app/models/concerns) extends ActiveSupport::Concern.
require "cybertrain/active_support"
require "cybertrain/generator/inflector"

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
  # `has_many :through`, nested `includes`, `eager_load` and `joins`,
  # `select`, a one-column `pluck` (relations have `pluck_str` /
  # `pluck_int` / `pluck_float`; `pluck` takes two or more columns), a
  # polymorphic `sum` / `minimum` / `maximum` (they come typed: `sum_int`,
  # `minimum_time`, ...), a `where` over a Range with other than Integer
  # ends (use `where_between`), deterministic encryption, dirty tracking,
  # transactions around `save` (except a counter_cache child's update),
  # STI and enums.
  #
  # Implementation: validations and callbacks are runtime data keyed by model
  # name, since Spinel cannot define methods at runtime.
  # @api public
  class Model
    VALIDATORS = {}   # model name => Array<Validator>
    # model name => where the validators of each of the model's own
    # `validates` calls start in its VALIDATORS list (a concern's calls,
    # spliced by gen/concerns.rb, are not counted, and move these along).
    VALIDATES_STARTS = {}
    # While gen/concerns.rb splices a model concern's `included` body:
    # model name => the index its next validator goes to.
    MODEL_CONCERN_AT = {}
    CALLBACKS = {}    # "Post:before_save" => Array<Proc>; each block takes the record
    # What generated from_row passes to new: never written to (initialize
    # skips assign_attributes for an empty Hash), so one serves every row.
    NO_ATTRIBUTES = {}

    # Declares validations for one or more attributes, run by {#valid?}
    # (and so by {#save}) in declaration order, with Rails' default English
    # messages (`message:` replaces them).
    #
    # - `presence: true`: `"can't be blank"` when the value is `nil` or a
    #   String that is empty after `strip`. `false` and `0` are present.
    # - `length: { minimum:, maximum:, is:, in: }` (`in:` / `within:` an
    #   Integer Range): `"is too short (minimum is n characters)"`, `"is too
    #   long (maximum is m characters)"`, `"is the wrong length (should be n
    #   characters)"`. A `nil` value is left to `presence`.
    # - `inclusion: { in: }` / `exclusion: { in: }`: an Array of Strings or
    #   Integers, or a Range of Integers (Spinel builds no other Range);
    #   `"is not included in the list"` / `"is reserved"`.
    # - `format: { with: /re/, without: /re/ }`: the value as a String must
    #   match `with:` and must not match `without:`, else `"is invalid"`
    #   (nil fails `with:` unless `allow_nil:`, and passes a `without:`
    #   rule alone).
    # - `numericality: true | { only_integer:, greater_than:,
    #   greater_than_or_equal_to:, equal_to:, less_than:,
    #   less_than_or_equal_to:, other_than: }`: a String is parsed as a
    #   number first (`"12"` passes, `"abc"` is `"is not a number"`, as is
    #   nil); `only_integer` takes an Integer or an integer String
    #   (`"must be an integer"`; a Float fails it, as in Rails); each failing
    #   comparison adds `"must be greater than 0"` and so on, the limit as
    #   written.
    # - `uniqueness: true | { scope: :column, case_sensitive: false }`:
    #   `"has already been taken"` when another row holds the value
    #   (`LOWER()` on both sides when not case-sensitive; nil is `IS NULL`),
    #   through the generated `unique_value_taken?`.
    # - On every rule: `allow_nil:` skips nil, `allow_blank:` nil and blank
    #   Strings; `on: :create | :update` runs it for a new or a persisted
    #   record only; `if:` / `unless:` name a method of the model (a Symbol:
    #   the generator writes the `validation_condition?` table that calls it,
    #   and refuses a lambda and the `:if =>` / `"if":` spellings; a name the
    #   table lacks raises ArgumentError); `message:` replaces the default (also inside
    #   a rule's Hash, for that rule).
    #
    # An unknown option or a value of the wrong kind raises ArgumentError
    # when the model loads, and the line declares nothing. For cross-field
    # rules, name a method with {.validate}.
    #
    # @example
    #   validates :title, presence: true, length: { minimum: 3, maximum: 40 }, uniqueness: true
    #   validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
    #   validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
    #   validates :views, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    #   validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create
    #   validates :summary, presence: true, if: :published?
    # @param args [Array<Symbol, Hash>] the attributes (their SQL column
    #   names), then the options
    # @return [nil]
    # @raise [ArgumentError] for an unknown option or a malformed value
    # @api public
    def self.validates(*args)
      built = Validator.build_all(args)
      list = (VALIDATORS[self.name] ||= Array.new(0) { Validator.new(:base, :presence) })
      starts = (VALIDATES_STARTS[self.name] ||= Array.new(0) { 0 })
      if MODEL_CONCERN_AT.key?(self.name)
        at = MODEL_CONCERN_AT[self.name]
        at = list.size if at > list.size
        built.each_with_index { |v, k| list.insert(at + k, v) }
        # The model's own calls from this one on start further along.
        starts.each_with_index { |s, k| starts[k] = s + built.size if s >= at }
        MODEL_CONCERN_AT[self.name] = at + built.size
      else
        starts << list.size
        built.each { |v| list << v }
      end
      nil
    end

    # Written by gen/concerns.rb (`spin run gen`) around the `included`
    # body of a model concern it splices into this class (spec 4.2):
    # until {.model_concern_insert_done}, the rules its `validates` calls
    # declare go before the model's own call number `validators_index`
    # (the count of the model's `validates` calls above the `include`
    # line), not to the end, so they run where the `include` was written.
    # Not for application code.
    # @param validators_index [Integer]
    # @return [nil]
    # @api public
    def self.model_concern_insert_at(validators_index)
      list = (VALIDATORS[self.name] ||= Array.new(0) { Validator.new(:base, :presence) })
      starts = (VALIDATES_STARTS[self.name] ||= Array.new(0) { 0 })
      MODEL_CONCERN_AT[self.name] = validators_index < starts.size ? starts[validators_index] : list.size
      nil
    end

    # Ends a {.model_concern_insert_at} splice: `validates` appends again.
    # @return [nil]
    # @api public
    def self.model_concern_insert_done
      MODEL_CONCERN_AT.delete(self.name)
      nil
    end

    # Declares methods that validate the record by adding to {#errors}
    # themselves, run by {#valid?} after the {.validates} rules:
    # `validate :check_dates, :check_totals, on: :update, if: :published?,
    # unless: :imported?`. The generator reads the line as text (like
    # {.scope}) and writes `run_custom_validations` calling each method by
    # name; at run time this method does nothing. One line, Symbol method
    # names defined in the model file, and `on:` / `if:` / `unless:` with
    # literal values; a block or a lambda stops the generator.
    # @example
    #   validate :ends_after_start
    #
    #   def ends_after_start
    #     errors.add(:ends_on, "must be after the start") if ends_on < starts_on
    #   end
    # @param args [Array<Symbol, Hash>] the method names, then `on:`, `if:`,
    #   `unless:`
    # @return [nil]
    # @api public
    def self.validate(*args) = nil

    # Encrypts columns at rest: `encrypts :api_key, :notes` (spec section
    # 10). The generator reads the line as text: the generated load_row
    # decrypts each column ({Crypto.decrypt}) and to_row encrypts it with a
    # fresh nonce, so the record holds the text and the table the payload
    # (`"1:..."`, AES-256-GCM). Each must be a string or text column, named
    # with Symbols, no options (there is no deterministic encryption). The
    # application then needs `CYBERTRAIN_ENCRYPTION_KEY` (boot fails
    # without it); the encryption is cybertrain/encryptor.rb's (openssl),
    # which every program loads. `where`, `where_like`, `where_between`,
    # `update_all` and the bulk writes refuse an encrypted column
    # (ArgumentError); `pluck` answers the stored payload. At run time this
    # method does nothing; it exists so the model file loads.
    # @example
    #   class Account
    #     encrypts :api_key
    #   end
    # @param attrs [Array<Symbol>] the column names
    # @return [nil]
    # @api public
    def self.encrypts(*attrs) = nil

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
    # --- what a template may read (the reference contract) ------------------
    # `<%= post.title %>` has no `send` to go through (spikes/NOTES.md rule
    # 1), so a record answers a template by name, and these four hooks are
    # everything the template layer (Template::Interpreter#model_method,
    # FormBuilder.record_value) asks of a model besides id, persisted?,
    # new_record?, to_param and errors:
    #
    #   read_attribute(name)       a column's value (`:id` too)
    #   read_association(name)     an association's record, or a has_many's records as an Array
    #   call_view_method(name)     an arity-0 public method of app/models/<model>.rb
    #   attribute_or_method?(name) whether one of the three answers `name`
    #
    # The first three return nil both for a nil value and for a name they do
    # not know; attribute_or_method? is what tells the two apart. Templates
    # only read: no hook writes, saves or queries by a computed name.
    # None of them needs a request, so a record reads the same in
    # Views.render_partial / render_mail / render_component.
    def read_association(name) = nil
    def call_view_method(name) = nil

    # Whether a template may read `name` from this record. A generated
    # model answers with a `case` over its columns, associations and view
    # methods (ModelsEmitter.emit_attribute_or_method), so a name it does
    # not have is an "undefined method" error in the template instead of an
    # empty string (docs/design.md D71). The base answer is true: a model
    # that does not declare its names (a hand-written subclass) keeps
    # every unanswered name a nil.
    # @param name [Symbol]
    # @return [Boolean]
    # @api private
    def attribute_or_method?(name) = true
    # Declared associations (has_many / has_one / belongs_to): the
    # `dependent:` children, the caches {#reload} clears, and counter_cache.
    # counter_cache_created / _destroyed / _was / _moved have no stub: only
    # the generated callback blocks call them, and a block's record is typed
    # Cybertrain::Model, so a stub here would be the method they call.
    def destroy_dependents = nil
    def reset_association_caches = nil
    # Validations (spec section 9): the generated model answers uniqueness
    # with a query, if: / unless: through a `case` over the names the model
    # file gives, and `validate :method` lines by calling each method. A
    # hand-written model has no uniqueness conflicts, every condition true
    # and no custom validations.
    def unique_value_taken?(attr, value, scope_attr, scope_value, exclude_id, case_sensitive) = false
    def validation_condition?(name) = true
    def run_custom_validations(context) = nil
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

      # The dictionary key full_messages and the validators look names
      # and messages up by ("post", "admin/post"; plan decision D9).
      e = Errors.new(Inflector.underscore(model_name))
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
    # rule declared with {.validates}, then the {.validate} methods. The
    # context is `:create` for a new record and `:update` for a persisted
    # one (rules with `on:` run in theirs only).
    # @return [Boolean] true when no errors were added
    # @api public
    def valid?
      errors.clear
      run_callbacks("before_validation")
      context = new_record? ? :create : :update
      Model.validators_for(model_name).each { |v| v.validate(self, context) }
      run_custom_validations(context)
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
      elsif counter_cached? && !Cybertrain::DB.in_transaction?
        # A counter_cache child writes the row and increments the parent's
        # count (after_create) in one transaction too.
        begin
          Cybertrain::DB.transaction { |_c| create_with_callbacks }
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          # Rolled back: the record is new again.
          @persisted = false
          @id = 0
          raise e
        end
      else
        create_with_callbacks
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

    def create_with_callbacks
      run_callbacks("before_create")
      insert_row
      run_callbacks("after_create")
      nil
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

require "cybertrain/model/bulk_writes"
