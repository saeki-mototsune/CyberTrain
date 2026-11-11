require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# Task 13 of phase 2: the validators of spec section 9.1
# (docs/superpowers/specs/2026-11-06-phase2-data-layer-design.md) --
# inclusion, exclusion, format, numericality, uniqueness, length's is:/in:,
# and allow_nil:, allow_blank:, on:, message:, if:/unless: on every rule --
# each with Rails' default English message. SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Thing is hand-written in the shape the model generator emits
# (test/gen_models.rb holds the emitted text), trimmed to what these tests
# call. It overrides the three hooks the generator writes from the model
# file: unique_value_taken? (here a recorder answering from a list, not a
# query: test/gen_models_compiles.rb runs the generated query),
# validation_condition? (the `case` over the if:/unless: names) and
# run_custom_validations (the `validate :method` calls).

UNIQUENESS_CALLS = Array.new(0) { "" }

class ThingRelation < Cybertrain::Relation
  def where(cond = nil, *binds)
    case cond
    when nil then nil
    when Hash then add_where(cond)
    when String then add_where_sql(cond, binds)
    end
    self
  end

  def size = count
end

class Thing < Cybertrain::Model
  def self.table_name = "things"
  def self.column_names = ["id", "name", "code", "state", "rating", "slug", "handle", "count_text", "qty", "price",
                           "level", "ratio", "whole", "email", "account_id", "nickname", "note", "tier", "age", "bonus",
                           "motto", "token", "score"]
  def model_name = "Thing"

  attr_accessor :name, :code, :state, :rating, :slug, :handle, :count_text, :qty, :price, :level, :ratio, :whole,
                :email, :account_id, :nickname, :note, :tier, :age, :bonus, :motto, :token, :needs_note, :draft_mode,
                :strict, :score

  def initialize(attrs = {})
    super()
    @name = "ok"
    @code = "abc"
    @state = nil
    @rating = 3
    @slug = "my-post"
    @handle = "bob"
    @count_text = "12"
    @qty = 5
    @price = Cybertrain::Cast.float_or_nil(9.5)
    @level = 2
    @ratio = 1.5
    @whole = 3
    @email = "a@b.example"
    @account_id = 1
    @nickname = nil
    @note = nil
    @tier = 1
    @age = 18
    @bonus = nil
    @motto = nil
    @token = "abc"
    @score = 1.0
    @needs_note = false
    @draft_mode = false
    @strict = false
    assign_attributes(attrs) unless attrs.empty?
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    when :code then @code
    when :state then @state
    when :rating then @rating
    when :slug then @slug
    when :handle then @handle
    when :count_text then @count_text
    when :qty then @qty
    when :price then @price
    when :level then @level
    when :ratio then @ratio
    when :whole then @whole
    when :email then @email
    when :account_id then @account_id
    when :nickname then @nickname
    when :note then @note
    when :tier then @tier
    when :age then @age
    when :bonus then @bonus
    when :motto then @motto
    when :token then @token
    when :score then @score
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :name then @name = Cybertrain::Cast.str(value)
    when :code then @code = Cybertrain::Cast.str(value)
    when :state then @state = Cybertrain::Cast.str_or_nil(value)
    when :rating then @rating = Cybertrain::Cast.int(value)
    when :slug then @slug = Cybertrain::Cast.str(value)
    when :handle then @handle = Cybertrain::Cast.str(value)
    when :count_text then @count_text = Cybertrain::Cast.str(value)
    when :qty then @qty = Cybertrain::Cast.int(value)
    when :price then @price = Cybertrain::Cast.float_or_nil(value)
    when :level then @level = Cybertrain::Cast.int(value)
    when :ratio then @ratio = Cybertrain::Cast.float(value)
    when :whole then @whole = value
    when :email then @email = Cybertrain::Cast.str(value)
    when :account_id then @account_id = Cybertrain::Cast.int(value)
    when :nickname then @nickname = Cybertrain::Cast.str_or_nil(value)
    when :note then @note = Cybertrain::Cast.str_or_nil(value)
    when :tier then @tier = Cybertrain::Cast.int(value)
    when :age then @age = Cybertrain::Cast.int(value)
    when :bonus then @bonus = Cybertrain::Cast.float_or_nil(value)
    when :motto then @motto = Cybertrain::Cast.str_or_nil(value)
    when :token then @token = Cybertrain::Cast.str_or_nil(value)
    when :score then @score = Cybertrain::Cast.float(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "name" => Cybertrain::Cast.to_sql(@name),
      "code" => Cybertrain::Cast.to_sql(@code),
      "state" => Cybertrain::Cast.to_sql(@state),
      "rating" => Cybertrain::Cast.to_sql(@rating),
      "slug" => Cybertrain::Cast.to_sql(@slug),
      "handle" => Cybertrain::Cast.to_sql(@handle),
      "count_text" => Cybertrain::Cast.to_sql(@count_text),
      "qty" => Cybertrain::Cast.to_sql(@qty),
      "price" => Cybertrain::Cast.to_sql(@price),
      "level" => Cybertrain::Cast.to_sql(@level),
      "ratio" => Cybertrain::Cast.to_sql(@ratio),
      "whole" => Cybertrain::Cast.to_sql(@whole),
      "email" => Cybertrain::Cast.to_sql(@email),
      "account_id" => Cybertrain::Cast.to_sql(@account_id),
      "nickname" => Cybertrain::Cast.to_sql(@nickname),
      "note" => Cybertrain::Cast.to_sql(@note),
      "tier" => Cybertrain::Cast.to_sql(@tier),
      "age" => Cybertrain::Cast.to_sql(@age),
      "bonus" => Cybertrain::Cast.to_sql(@bonus),
      "motto" => Cybertrain::Cast.to_sql(@motto),
      "token" => Cybertrain::Cast.to_sql(@token)
    }
  end

  def self.all = ThingRelation.new("things")
  def self.count = all.count

  # The generated shapes (models_emitter.rb), hand-written.
  def unique_value_taken?(attr, value, scope_attr, scope_value, exclude_id, case_sensitive)
    UNIQUENESS_CALLS << "#{attr}|#{value}|#{scope_attr}|#{scope_value}|#{exclude_id}|#{case_sensitive}"
    Cybertrain::Cast.str(value).downcase == "taken@b.example"
  end

  def validation_condition?(name)
    case name
    when :needs_note? then self.needs_note? ? true : false
    when :draft_mode? then self.draft_mode? ? true : false
    when :strict? then self.strict? ? true : false
    else true
    end
  end

  def run_custom_validations(context)
    self.name_not_admin if validation_condition?(:strict?)
    self.handle_not_root if context == :update
    nil
  end
end

# ---- app/models/thing.rb (user code) ----------------------------------------

class Thing
  validates :name, presence: true, length: { in: 2..10 }
  validates :code, length: { is: 3 }
  validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
  validates :rating, inclusion: { in: 1..5 }, exclusion: { in: [4] }
  validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
  validates :handle, format: { without: /[0-9]/, message: "has digits" }
  validates :count_text, numericality: { only_integer: true }
  validates :qty, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 100 }
  validates :price, numericality: { greater_than: 0, less_than_or_equal_to: 10.5 }, allow_nil: true
  validates :level, numericality: { equal_to: 2 }
  validates :ratio, numericality: { other_than: 7 }
  validates :whole, numericality: { only_integer: true }
  validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create, message: "is taken"
  validates :nickname, length: { minimum: 3 }, allow_blank: true
  validates :note, presence: true, if: :needs_note?, unless: :draft_mode?
  validates :code, :slug, presence: true, if: :strict?
  validates :name, uniqueness: true, on: :update
  validate :name_not_admin, :handle_not_root
  validates :tier, inclusion: { in: 1...5 }
  validates :age, inclusion: { in: 18.. }
  validates :score, inclusion: { in: 1...5 }
  validates :bonus, numericality: { greater_than: 0, allow_nil: true }
  validates :motto, format: { without: /!/ }
  validates :token, format: { with: /\A[a-z]+\z/ }

  def needs_note? = @needs_note
  def draft_mode? = @draft_mode
  def strict? = @strict

  def name_not_admin
    errors.add(:name, "is not allowed") if name == "admin"
  end

  def handle_not_root
    errors.add(:handle, "is root") if handle == "root"
  end
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE things (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, code TEXT, state TEXT, " \
    "rating INTEGER, slug TEXT, handle TEXT, count_text TEXT, qty INTEGER, price REAL, level INTEGER, " \
    "ratio REAL, whole REAL, email TEXT, account_id INTEGER, nickname TEXT, note TEXT, tier INTEGER, " \
    "age INTEGER, bonus REAL, motto TEXT, token TEXT);"
  )
end

# The messages `attrs` gives `attr`, every other attribute at its valid
# default.
def messages_for(attr, attrs)
  thing = Thing.new(attrs)
  thing.valid?
  thing.errors[attr]
end

test "a Thing with its defaults is valid" do
  thing = Thing.new
  assert thing.valid?
  assert_equal [], thing.errors.full_messages
end

test "presence and length in:, is:" do
  assert_equal ["can't be blank", "is too short (minimum is 2 characters)"], messages_for(:name, { name: "" })
  assert_equal ["is too short (minimum is 2 characters)"], messages_for(:name, { name: "a" })
  assert_equal ["is too long (maximum is 10 characters)"], messages_for(:name, { name: "x" * 11 })
  assert_equal [], messages_for(:name, { name: "x" * 10 })
  assert_equal ["is the wrong length (should be 3 characters)"], messages_for(:code, { code: "abcd" })
  assert_equal ["is the wrong length (should be 3 characters)"], messages_for(:code, { code: "ab" })
end

test "inclusion in an Array of Strings, allow_nil" do
  assert_equal ["is not included in the list"], messages_for(:state, { state: "archived" })
  assert_equal [], messages_for(:state, { state: "published" })
  assert_equal [], messages_for(:state, { state: nil })
end

test "inclusion in an Integer Range, exclusion of an Integer Array" do
  assert_equal ["is not included in the list"], messages_for(:rating, { rating: 9 })
  assert_equal ["is not included in the list"], messages_for(:rating, { rating: 0 })
  assert_equal [], messages_for(:rating, { rating: 5 })
  assert_equal [], messages_for(:rating, { rating: 1 })
  assert_equal ["is reserved"], messages_for(:rating, { rating: 4 })
end

test "format with: and exclusion of Strings" do
  assert_equal ["is invalid"], messages_for(:slug, { slug: "Bad Slug" })
  assert_equal ["is reserved"], messages_for(:slug, { slug: "new" })
  assert_equal [], messages_for(:slug, { slug: "a-1" })
end

test "format without:, with message: inside the rule" do
  assert_equal ["has digits"], messages_for(:handle, { handle: "bob1" })
  assert_equal [], messages_for(:handle, { handle: "bobby" })
end

test "numericality on a String attribute: a number passes, else not a number, only_integer" do
  assert_equal [], messages_for(:count_text, { count_text: "12" })
  assert_equal [], messages_for(:count_text, { count_text: "-3" })
  assert_equal ["is not a number"], messages_for(:count_text, { count_text: "abc" })
  assert_equal ["is not a number"], messages_for(:count_text, { count_text: "" })
  assert_equal ["is not a number"], messages_for(:count_text, { count_text: "1.2.3" })
  assert_equal ["must be an integer"], messages_for(:count_text, { count_text: "1.5" })
end

test "numericality only_integer on a Float, and nil is not a number" do
  assert_equal ["must be an integer"], messages_for(:whole, { whole: 1.5 })
  assert_equal ["is not a number"], messages_for(:whole, { whole: nil })
  assert_equal ["is not a number"], messages_for(:whole, { whole: "x" })
  assert_equal [], messages_for(:whole, { whole: 7 })
end

test "numericality comparisons print their limits as written" do
  assert_equal ["must be greater than or equal to 0"], messages_for(:qty, { qty: -1 })
  assert_equal ["must be less than 100"], messages_for(:qty, { qty: 100 })
  assert_equal [], messages_for(:qty, { qty: 0 })
  assert_equal ["must be greater than 0"], messages_for(:price, { price: 0.0 })
  assert_equal ["must be less than or equal to 10.5"], messages_for(:price, { price: 11 })
  assert_equal [], messages_for(:price, { price: 10.5 })
  assert_equal [], messages_for(:price, { price: nil })
  assert_equal ["must be equal to 2"], messages_for(:level, { level: 3 })
  assert_equal ["must be other than 7"], messages_for(:ratio, { ratio: 7.0 })
  assert_equal [], messages_for(:ratio, { ratio: 7.5 })
end

test "inclusion in an exclusive-end Range and an endless Range" do
  assert_equal [], messages_for(:tier, { tier: 4 })
  assert_equal ["is not included in the list"], messages_for(:tier, { tier: 5 })
  assert_equal ["is not included in the list"], messages_for(:tier, { tier: 0 })
  assert_equal [], messages_for(:age, { age: 18 })
  assert_equal [], messages_for(:age, { age: 120 })
  assert_equal ["is not included in the list"], messages_for(:age, { age: 17 })
end

# Rails' (1...5).include?(4.5) is true: the exclusive end is compared as
# itself, not as 4 (which refused 4.5 on a float or decimal column).
test "an exclusive-end Integer Range admits a Float below its end" do
  assert_equal [], messages_for(:score, { score: 4.5 })
  assert_equal [], messages_for(:score, { score: 4.999 })
  assert_equal [], messages_for(:score, { score: 1.0 })
  assert_equal ["is not included in the list"], messages_for(:score, { score: 5.0 })
  assert_equal ["is not included in the list"], messages_for(:score, { score: 0.5 })
end

test "allow_nil inside a rule's Hash skips nil for that rule" do
  assert_equal [], messages_for(:bonus, { bonus: nil })
  assert_equal ["must be greater than 0"], messages_for(:bonus, { bonus: 0 })
  assert_equal [], messages_for(:bonus, { bonus: 0.5 })
end

test "format: nil fails a with: rule and passes a without:-only rule" do
  assert_equal [], messages_for(:motto, { motto: nil })
  assert_equal ["is invalid"], messages_for(:motto, { motto: "wow!" })
  assert_equal [], messages_for(:motto, { motto: "calm" })
  assert_equal ["is invalid"], messages_for(:token, { token: nil })
  assert_equal [], messages_for(:token, { token: "abc" })
end

test "allow_blank skips nil and blank Strings only" do
  assert_equal [], messages_for(:nickname, { nickname: nil })
  assert_equal [], messages_for(:nickname, { nickname: "  " })
  assert_equal ["is too short (minimum is 3 characters)"], messages_for(:nickname, { nickname: "ab" })
end

test "uniqueness passes scope, scope value, id and case_sensitive; message: replaces the default" do
  UNIQUENESS_CALLS.clear
  assert_equal ["is taken"], messages_for(:email, { email: "Taken@b.example", account_id: 7 })
  assert_equal ["email|Taken@b.example|account_id|7|0|false"], UNIQUENESS_CALLS
  assert_equal [], messages_for(:email, { email: "free@b.example" })
end

test "on: :create runs only on a new record, on: :update only on a persisted one" do
  UNIQUENESS_CALLS.clear
  thing = Thing.new(email: "taken@b.example")
  refute thing.save
  assert_equal ["Email is taken"], thing.errors.full_messages
  UNIQUENESS_CALLS.clear
  thing.email = "mine@b.example"
  assert thing.save
  assert_equal ["email|mine@b.example|account_id|1|0|false"], UNIQUENESS_CALLS
  UNIQUENESS_CALLS.clear
  thing.email = "taken@b.example"
  assert thing.valid?
  assert_equal ["name|ok|||#{thing.id}|true"], UNIQUENESS_CALLS
  assert_equal 1, Thing.count
end

test "if: and unless: go through validation_condition?" do
  assert_equal [], messages_for(:note, { note: nil })
  thing = Thing.new
  thing.needs_note = true
  refute thing.valid?
  assert_equal ["Note can't be blank"], thing.errors.full_messages
  thing.draft_mode = true
  assert thing.valid?
end

test "one validates line for two attributes, under if:" do
  thing = Thing.new(code: "", slug: "")
  thing.strict = true
  thing.valid?
  assert_equal ["is the wrong length (should be 3 characters)", "can't be blank"], thing.errors[:code]
  assert_equal ["is invalid", "can't be blank"], thing.errors[:slug]
  thing.strict = false
  thing.valid?
  assert_equal ["is the wrong length (should be 3 characters)"], thing.errors[:code]
  assert_equal ["is invalid"], thing.errors[:slug]
end

test "run_custom_validations runs after the declared rules with the context" do
  thing = Thing.new(name: "admin", handle: "root")
  assert thing.valid?
  thing.strict = true
  refute thing.valid?
  assert_equal ["Name is not allowed"], thing.errors.full_messages
  thing.strict = false
  assert thing.save
  refute thing.valid?
  assert_equal ["Handle is root"], thing.errors.full_messages
end

test "an unknown option, a lambda condition and an on: other than :create or :update raise ArgumentError" do
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, colour: true) }, "colour"
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, presence: true, if: -> { true }) },
                  "if: takes a Symbol method name"
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, presence: true, on: :save) }, "on:"
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, allow_nil: true) }, "at least one rule"
  assert_equal ["can't be blank", "is too short (minimum is 2 characters)"], messages_for(:name, { name: "" })
end

# Last: it adds rules to Thing. What gen/concerns.rb writes for a model
# concern (spec 4.2): the index counts the model's own `validates` calls
# above the `include`, however many rules each call made.
def thing_rules
  Cybertrain::Model.validators_for("Thing").map { |v| "#{v.attr}:#{v.kind}" }
end

test "model_concern_insert_at puts a concern's validates calls after the model's own call of that index" do
  own = thing_rules
  Thing.model_concern_insert_at(1)
  Thing.validates :motto, presence: true, length: { maximum: 5 }
  Thing.validates :token, presence: true
  Thing.model_concern_insert_done
  # A second concern, included after the model's second call (code).
  Thing.model_concern_insert_at(2)
  Thing.validates :age, presence: true
  Thing.model_concern_insert_done
  # One included below every call of the model.
  Thing.model_concern_insert_at(23)
  Thing.validates :level, presence: true
  Thing.model_concern_insert_done
  Thing.validates :ratio, presence: true
  assert_equal ["name:presence", "name:length", "motto:presence", "motto:length", "token:presence", "code:length", "age:presence",
                "state:inclusion"], thing_rules[0, 8]
  assert_equal own.size + 6, thing_rules.size
  assert_equal ["token:format", "level:presence", "ratio:presence"], thing_rules[own.size + 3, 3]
end

test "the default messages come from the dictionary of the current locale, message: still wins" do
  I18n.available_locales = [:en, :ja]
  I18n.locale = :ja
  assert_equal ["を入力してください", "は2文字以上で入力してください"], messages_for(:name, { name: "" })
  assert_equal ["は3文字で入力してください"], messages_for(:code, { code: "abcd" })
  assert_equal ["は一覧にありません"], messages_for(:state, { state: "gone" })
  assert_equal ["は予約されています"], messages_for(:rating, { rating: 4 })
  assert_equal ["は不正な値です"], messages_for(:token, { token: "A1" })
  assert_equal ["has digits"], messages_for(:handle, { handle: "b0b" })
  assert_equal ["は数値で入力してください"], messages_for(:count_text, { count_text: "x" })
  assert_equal ["は整数で入力してください"], messages_for(:whole, { whole: 1.5 })
  assert_equal ["は0以上の値にしてください"], messages_for(:qty, { qty: -1 })
  assert_equal ["は100より小さい値にしてください"], messages_for(:qty, { qty: 100 })
  assert_equal ["は10.5以下の値にしてください"], messages_for(:price, { price: 11.0 })
  assert_equal ["は0より大きい値にしてください"], messages_for(:price, { price: 0.0 })
  assert_equal ["は2にしてください"], messages_for(:level, { level: 3 })
  assert_equal ["は7以外の値にしてください"], messages_for(:ratio, { ratio: 7.0 })
  I18n.locale = nil
  assert_equal ["must be less than or equal to 10.5"], messages_for(:price, { price: 11.0 })
end

Cybertrain::Test.run!
