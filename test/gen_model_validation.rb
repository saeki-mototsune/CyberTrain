require "cybertrain/test"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/model_validation"
require "cybertrain/generator/models_emitter"

# The semantic validation of the model generator, on its own (docs/design.md
# D69): Gen::ModelValidation checks the scanned declarations against the
# schema and answers one ValidatedModel per table, without emitting
# anything; ModelsEmitter.emit_validated writes a file from one. Text only
# (no database): CRuby-portable. test/gen_models.rb holds the exact wording
# of every diagnostic, reached there through the emitter's entry points.

SCHEMA_SOURCE = <<~RUBY
  Cybertrain::Schema.define(version: "1") do |s|
    # create_table "users" was here once
    s.create_table "users" do |t|
      t.string "email", null: false
      t.string :hash
      t.string "hash_column"
      t.integer "posts_count", null: false, default: "0"
    end
    s.create_table :posts do |t|
      t.references :user
      t.string "title", null: false
      t.binary "raw", default: "'x'"
      t.integer "views"
    end
  end
RUBY

def validation_schema(broken)
  Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "users" do |t|
      t.string "email", null: false
      t.string "hash" if broken == :hash
      t.string "hash_column" if broken == :hash
      t.integer "posts_count", null: false, default: "0"
    end
    s.create_table "posts" do |t|
      t.references :user
      t.string "title", null: false
      t.binary "raw", default: "'x'" if broken == :binary
      t.integer "views"
    end
  end
end

def places
  Cybertrain::Gen::SchemaPlaces.new("db/schema.rb", SCHEMA_SOURCE)
end

def scanned(file, source)
  Cybertrain::Gen::ModelScan.scan_source(file, source)
end

POST_MODEL = <<~RUBY
  class Post < Cybertrain::Model
    belongs_to :user, counter_cache: true
    encrypts :title
    validates :title, presence: true, if: :published?
    validate :check_views, on: :update
    scope :popular, -> { where_sql("views > 10") }

    def published? = true
    def check_views = nil
    def summary = title
    def views = 0
  end
RUBY

def validated_models
  infos = [scanned("app/models/post.rb", POST_MODEL), scanned("app/models/user.rb", "class User < Cybertrain::Model\n  has_many :posts\nend\n")]
  Cybertrain::Gen::ModelValidation.validate_all(validation_schema(:none), infos, places)
end

test "validate_all answers one validated model per table, resolved against the schema" do
  models = validated_models
  assert_equal 2, models.size
  post = models[0]
  user = models[1]
  assert_equal "User", user.model
  assert_equal "users", user.source_table.name
  assert_equal ["posts_count"], user.counter_columns
  assert_equal 1, user.plans.size
  assert_equal "posts", user.plans[0].name
  assert_equal :has_many, user.plans[0].kind
  assert_equal true, user.plans[0].declared

  assert_equal "Post", post.model
  assert_equal ["title"], post.encrypted_columns
  assert_equal ["published?"], post.condition_methods
  assert_equal 1, post.custom_validations.size
  assert_equal "check_views", post.custom_validations[0].name
  assert_equal 1, post.scopes.size
  assert_equal "popular", post.scopes[0].name
  plan = post.plans[0]
  assert_equal "user", plan.name
  assert_equal :belongs_to, plan.kind
  assert_equal "user_id", plan.foreign_key
  assert_equal "posts_count", plan.counter_column
  assert_equal "users", plan.target_table
end

test "the view methods left to call_view_method leave out a column's and an association's reader" do
  post = validated_models[0]
  assert_equal true, post.view_methods.include?("summary")
  assert_equal false, post.view_methods.include?("views")
  assert_equal false, post.view_methods.include?("user")
end

test "the emitter writes the same file from a validated model as from the schema and the scanned files" do
  infos = [scanned("app/models/post.rb", POST_MODEL), scanned("app/models/user.rb", "class User < Cybertrain::Model\n  has_many :posts\nend\n")]
  definition = validation_schema(:none)
  whole = Cybertrain::Gen::ModelsEmitter.outputs(definition, infos)
  models = Cybertrain::Gen::ModelValidation.validate_all(definition, infos, places)
  staged = Cybertrain::Gen::ModelsEmitter.outputs_for(models)
  assert_equal ["gen/models/post.rb", "gen/models/user.rb"], staged.keys
  assert_equal whole["gen/models/post.rb"], staged["gen/models/post.rb"]
  assert_equal whole["gen/models/user.rb"], staged["gen/models/user.rb"]
  assert_equal staged["gen/models/post.rb"], Cybertrain::Gen::ModelsEmitter.emit_validated(models[0])
  assert_includes staged["gen/models/post.rb"], "when :published? then self.published? ? true : false"
  assert_includes staged["gen/models/user.rb"], "def counter_cache_columns = [\"posts_count\"]"
end

def declaration_error(file, source)
  infos = [scanned(file, source)]
  assert_raises("ModelScan::Error") { Cybertrain::Gen::ModelValidation.validate_all(validation_schema(:none), infos, places) }
end

test "a declaration the schema does not bear out is refused with its file and line, without emitting" do
  msg = declaration_error("app/models/post.rb", "class Post\n\n  encrypts :views\nend\n")
  assert_equal "app/models/post.rb:3: encrypts :views: only a string or text column can be encrypted (views is integer)", msg
  msg = declaration_error("app/models/post.rb", "class Post\n  encrypts :nothing\nend\n")
  assert_equal "app/models/post.rb:2: encrypts :nothing names no column of posts", msg
  msg = declaration_error("app/models/post.rb", "class Post\n  encrypts :title\n  validates :title, uniqueness: true\nend\n")
  assert_includes msg, "app/models/post.rb:3: validates :title, uniqueness: title is encrypted (encrypts :title)"
  msg = declaration_error("app/models/post.rb", "class Post\n  validates :title, presence: true, if: :ready?\nend\n")
  assert_includes msg, "app/models/post.rb:2: if: / unless: :ready? names no method of Post"
  msg = declaration_error("app/models/post.rb", "class Post\n  scope :title, -> { limit(1) }\nend\n")
  assert_equal "app/models/post.rb:2: scope :title clashes with the column title of table posts; rename the scope", msg
  msg = declaration_error("app/models/post.rb", "class Post\n  belongs_to :author\nend\n")
  assert_includes msg, "app/models/post.rb:2: belongs_to :author: Author is not a model"
  msg = declaration_error("app/models/user.rb", "class User\n  has_many :posts, dependent: :nullify\nend\n")
  assert_equal "app/models/user.rb:2: has_many :posts: dependent: :nullify needs posts.user_id to be nullable", msg
end

test "a table the generator cannot host is refused with the db/schema.rb line when the file's text is known" do
  empty = Array.new(0) { Cybertrain::Gen::ModelInfo.empty("", "", Array.new(0) { "" }) }
  msg = assert_raises("ArgumentError") do
    Cybertrain::Gen::ModelValidation.validate_all(validation_schema(:hash), empty, places)
  end
  assert_includes msg, "db/schema.rb:5: table users: column \"hash\" can be neither \"hash\" nor \"hash_column\""
  msg = assert_raises("ArgumentError") do
    Cybertrain::Gen::ModelValidation.validate_all(validation_schema(:binary), empty, places)
  end
  assert_includes msg, "db/schema.rb:12: table posts: column \"raw\" is a binary column with a default ('x')"
  # Without the text the message stands alone, as the emitter's entry points give it.
  msg = assert_raises("ArgumentError") do
    Cybertrain::Gen::ModelValidation.validate_all(validation_schema(:binary), empty, Cybertrain::Gen::SchemaPlaces.absent)
  end
  assert_equal "table posts: column \"raw\" is a binary column with a default ('x'); a BLOB column takes no default, " \
               "set the bytes in the model instead", msg
end

test "SchemaPlaces finds a table's create_table line and a column's line inside it" do
  found = places
  assert_equal "db/schema.rb:3: ", found.at("users", "")
  assert_equal "db/schema.rb:4: ", found.at("users", "email")
  assert_equal "db/schema.rb:5: ", found.at("users", "hash")
  assert_equal "db/schema.rb:6: ", found.at("users", "hash_column")
  assert_equal "db/schema.rb:9: ", found.at("posts", "")
  assert_equal "db/schema.rb:11: ", found.at("posts", "title")
  # `t.references :user` spells no user_id: the table's line.
  assert_equal "db/schema.rb:9: ", found.at("posts", "user_id")
  # A column of another table's block is not this table's.
  assert_equal "db/schema.rb:3: ", found.at("users", "title")
  assert_equal "", found.at("tags", "name")
  assert_equal "", Cybertrain::Gen::SchemaPlaces.absent.at("users", "email")
  assert_equal "", Cybertrain::Gen::SchemaPlaces.in_app("test/fixtures/no_such_app").at("users", "")
  assert_equal "db/schema.rb:", Cybertrain::Gen::SchemaPlaces.in_app("test/fixtures/gen_app").at("posts", "")[0, 13]
end

Cybertrain::Test.run!
