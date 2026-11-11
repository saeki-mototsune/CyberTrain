require "tmpdir"
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"
require "cybertrain/model"
require "cybertrain/job"
require "cybertrain/generator"
require_relative "fixtures/gen_app/config/routes"
# Model concerns (spec 4.2, plan decision 9), on the fixture app loaded
# through its checked-in gen/app.rb: gen/concerns/models/concerns/visible.rb
# (app/models/concerns/visible.rb with its `included` block blanked) before
# the models, then gen/concerns.rb, which splices Visible's `included` body
# into Post at its `include`, between `validates :title, presence: true`
# and the rules below it. The program links SQLite through FFI: its
# snapshot comes from the compiled binary (script/regen-snapshot).
require_relative "fixtures/gen_app/gen/app"

FIXTURE = "test/fixtures/gen_app"

def sql_type(column)
  case column.type
  when :integer, :boolean then "INTEGER"
  when :float then "REAL"
  when :decimal then "DECIMAL"
  else "TEXT"
  end
end

def create_tables_sql(definition)
  sql = +""
  definition.tables.each do |table|
    parts = ["id INTEGER PRIMARY KEY AUTOINCREMENT"]
    table.columns.each do |c|
      part = +"\"#{c.name}\" #{sql_type(c)}"
      part << " NOT NULL" unless c.null
      default = c.default
      part << " DEFAULT #{default}" unless default.nil?
      parts << part
    end
    sql << "CREATE TABLE \"#{table.name}\" (#{parts.join(", ")});"
  end
  sql
end

require_relative "fixtures/gen_app/db/schema"
Cybertrain.config.encryption_key = "8f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.exec_script(create_tables_sql(Cybertrain::Schema.current)) }

def reset_tables
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM comments; DELETE FROM posts;") }
end

def model_concerns
  Cybertrain::Gen::ConcernScan.scan_dir("#{FIXTURE}/app/models")
end

def occurrences(text, part)
  n = 0
  pos = text.index(part)
  until pos.nil?
    n += 1
    pos = text.index(part, pos + part.size)
  end
  n
end

Cybertrain::Views.configure("#{FIXTURE}/app/views", cache: false)

def render_inline(src, post)
  template = Cybertrain::Template::Template.parse(src, "posts/inline")
  env = { "__template_dir" => "posts" }
  env["post"] = post
  Cybertrain::Template::Interpreter.new(Cybertrain::Views.helpers_builder.call(nil)).render(template, env)
end

test "validates from a model concern runs at the include's position" do
  reset_tables
  post = Post.new(title: "Long", body: "x" * 10001)
  refute post.valid?
  assert_equal ["Body is too long (maximum is 10000 characters)"], post.errors.full_messages
  post.body = "x" * 10000
  assert post.valid?
  # Post: title presence, include Visible (body length), title uniqueness
  # and length, views numericality.
  rules = Cybertrain::Model.validators_for("Post").map { |v| "#{v.attr}:#{v.kind}" }
  assert_equal ["title:presence", "body:length", "title:uniqueness", "title:length", "views:numericality"], rules
  generated = File.read("#{FIXTURE}/gen/concerns.rb")
  assert_includes generated, "class Post\n  # Visible (include Visible at app/models/post.rb:4)\n  model_concern_insert_at(1)\n" \
                             "  validates :body, length: { maximum: 10000 }\n  scope :visible, -> { where(hidden: 0) }\n" \
                             "  before_save { |r| r.body = \"\#{r.body}>visible\" if r.title == \"callback order\" }\n" \
                             "  model_concern_insert_done\nend\n"
end

test "scope from a model concern" do
  reset_tables
  Post.create(title: "Shown")
  Post.create(title: "Hidden", hidden: 1)
  assert_equal 1, Post.visible.count
  assert_equal ["Shown"], Post.visible.to_a.map { |p| p.title }
  assert_equal 0, Post.where(title: "Hidden").visible.count
  infos = Cybertrain::Gen::ModelScan.scan_dir("#{FIXTURE}/app/models")
  assert_equal ["visible", "recent", "min_views"], infos[1].scopes.map { |s| s.name }
  assert_equal "#{FIXTURE}/app/models/concerns/visible.rb", infos[1].scopes[0].file
  assert_equal 9, infos[1].scopes[0].line
end

test "a concern's instance method is a view method" do
  reset_tables
  infos = Cybertrain::Gen::ModelScan.scan_dir("#{FIXTURE}/app/models")
  assert_equal ["visible?", "summary", "published?"], infos[1].view_methods
  assert_includes infos[1].defined_methods, "visible?"
  shown = Post.create(title: "Shown")
  hidden = Post.create(title: "Hidden", hidden: 1)
  assert_equal "true|Sho", render_inline("<%= post.visible? %>|<%= post.summary %>", shown)
  assert_equal "false", render_inline("<%= post.visible? %>", hidden)
end

test "a model concern included twice is expanded once" do
  source = "class Note\n  include Visible\n  validates :title, presence: true\n  include Visible\nend\n"
  info = Cybertrain::Gen::ModelScan.scan_source("app/models/note.rb", source, model_concerns)
  assert_equal ["visible"], info.scopes.map { |s| s.name }
  assert_equal ["visible?"], info.view_methods
  out = Cybertrain::Gen::ConcernsEmitter.emit_models([info], model_concerns)
  assert_equal 1, occurrences(out, "scope :visible")
  assert_includes out, "class Note\n  # Visible (include Visible at app/models/note.rb:2)\n  model_concern_insert_at(0)\n"
end

test "an include of a module that is not a concern is left to Ruby" do
  source = "class Note\n  validates :title, presence: true\n  include Comparable\n  include Visible\nend\n"
  info = Cybertrain::Gen::ModelScan.scan_source("app/models/note.rb", source, model_concerns)
  assert_equal ["Comparable", "Visible"], info.includes
  assert_equal ["Visible"], info.concern_names
  assert_equal [1], info.concern_from
  out = Cybertrain::Gen::ConcernsEmitter.emit_models([info], model_concerns)
  refute out.include?("Comparable"), "nothing is spliced for Comparable"
  assert_includes out, "  # Visible (include Visible at app/models/note.rb:4)\n  model_concern_insert_at(1)\n"
end

test "a concern's before_save runs after the model's own, wherever the include stands" do
  # Post: include Visible (line 4), then its own before_save (line 11).
  # Rails would run Visible's first; gen/concerns.rb registers it last.
  reset_tables
  post = Post.create(title: "callback order", body: "start")
  assert_equal "start>post>visible", post.body
  assert_equal "start>post>visible", Post.find(post.id).body
  assert_equal "kept", Post.create(title: "other", body: "kept").body
end

test "a scope a concern defines again is refused, naming both places" do
  source = "class Note\n  scope :visible, -> { where(hidden: 1) }\n  include Visible\nend\n"
  msg = assert_raises("Cybertrain::Gen::ModelScan::Error") { Cybertrain::Gen::ModelScan.scan_source("app/models/note.rb", source, model_concerns) }
  assert_equal "#{FIXTURE}/app/models/concerns/visible.rb:9: scope :visible is already defined at app/models/note.rb:2; rename one of them", msg
end

test "the concern's own file is loaded as gen/concerns/models/concerns/visible.rb, its included block blanked" do
  source = File.read("#{FIXTURE}/app/models/concerns/visible.rb").lines
  copy = File.read("#{FIXTURE}/gen/concerns/models/concerns/visible.rb").lines
  assert_equal source.size + 2, copy.size
  assert_equal ["\n", "\n", "\n", "\n", "\n"], copy[6, 5]
  assert_equal "  def visible? = hidden == 0\n", copy[12]
  assert_equal source[12], copy[12]
  assert_equal "# Generated by `spin run gen` from app/models/concerns/visible.rb. Do not edit.\n", copy.last
end

# A throwaway app/models for the concern shapes the fixture does not have.
TMP_APP = Dir.mktmpdir("cybertrain-model-concerns")
TMP_SOURCES = {
  "tracked.rb" => "module Tracked\n  extend ActiveSupport::Concern\n\n  included do\n    belongs_to :author, optional: true\n" \
                  "    has_many :notes\n    encrypts :token\n    validates :slug, uniqueness: true\n    validate :slug_sane, on: :create\n" \
                  "  end\n\n  def slug_sane = nil\nend\n",
  "tagged.rb" => "module Tagged\n  extend ActiveSupport::Concern\n\n  included do\n    include Tracked\n" \
                 "    scope :tagged, -> { where(tagged: 1) }\n  end\nend\n",
  "looped.rb" => "module Looped\n  extend ActiveSupport::Concern\n\n  included do\n    include Looped\n  end\nend\n",
  "paged.rb" => "module Paged\n  extend ActiveSupport::Concern\n\n  class_methods do\n    def recent = 1\n    def where = 2\n    def per_page = 3\n  end\nend\n"
}
Cybertrain::Gen::Runner.make_dirs("#{TMP_APP}/app/models/concerns")
TMP_SOURCES.each { |name, source| File.write("#{TMP_APP}/app/models/concerns/#{name}", source) }
at_exit do
  TMP_SOURCES.keys.each { |name| File.delete("#{TMP_APP}/app/models/concerns/#{name}") }
  ["app/models/concerns", "app/models", "app", ""].each { |d| Dir.rmdir("#{TMP_APP}/#{d}") }
end

def tmp_concerns
  Cybertrain::Gen::ConcernScan.scan_dir("#{TMP_APP}/app/models")
end

test "associations, encrypts, uniqueness and validate from a concern join the model's ModelInfo" do
  info = Cybertrain::Gen::ModelScan.scan_source("app/models/doc.rb", "class Doc\n  include Tracked\nend\n", tmp_concerns)
  assert_equal ["author", "notes"], info.associations.map { |a| a.name }
  assert_equal [:belongs_to, :has_many], info.associations.map { |a| a.kind }
  assert info.associations[0].optional
  assert_equal 5, info.associations[0].line
  assert_equal ["token"], info.encrypted
  assert_equal [7], info.encrypted_lines
  assert_equal ["slug"], info.unique_columns
  assert_equal [8], info.unique_lines
  assert_equal ["slug_sane"], info.custom_validations.map { |v| v.name }
  assert_equal "create", info.custom_validations[0].on
  assert_equal ["slug_sane"], info.defined_methods
  assert_equal ["app/models/concerns/tracked.rb:12"], info.defined_places
end

test "an include in a concern's included body brings that concern in after it; a cycle is refused" do
  info = Cybertrain::Gen::ModelScan.scan_source("app/models/doc.rb", "class Doc\n  include Tagged\nend\n", tmp_concerns)
  assert_equal ["Tagged", "Tracked"], info.concern_names
  assert_equal [0, 0], info.concern_from
  assert_equal ["tagged"], info.scopes.map { |s| s.name }
  assert_equal ["author", "notes"], info.associations.map { |a| a.name }
  out = Cybertrain::Gen::ConcernsEmitter.emit_models([info], tmp_concerns)
  tagged = out.index("  # Tagged (include Tagged at app/models/doc.rb:2)\n")
  tracked = out.index("  # Tracked (include Tagged at app/models/doc.rb:2)\n")
  refute tagged.nil?
  refute tracked.nil?
  assert tagged < tracked
  assert_equal 1, occurrences(out, "has_many :notes")
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ModelScan.scan_source("app/models/doc.rb", "class Doc\n  include Looped\nend\n", tmp_concerns) }
  assert_equal "concern cycle: Looped includes Looped", msg
end

test "a model concern's class_methods name may not be a scope, a model class method or an instance method" do
  rule = "Spinel compiles a def inside class_methods as an instance method too (spikes/NOTES.md rule 93), so rename one"
  scoped = Cybertrain::Gen::ModelScan.scan_source("app/models/doc.rb", "class Doc\n  include Paged\n  scope :recent, -> { order(id: :desc) }\nend\n", tmp_concerns)
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ConcernsEmitter.emit_models([scoped], tmp_concerns) }
  assert_equal "app/models/concerns/paged.rb:5: class_methods def recent: Doc, which includes Paged, has scope :recent " \
               "(app/models/doc.rb:3), and both would define Doc.recent; rename one", msg
  # Without the scope, `where` is the next name refused: every model has it.
  plain = Cybertrain::Gen::ModelScan.scan_source("app/models/doc.rb", "class Doc\n  include Paged\nend\n", tmp_concerns)
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ConcernsEmitter.emit_models([plain], tmp_concerns) }
  assert_equal "app/models/concerns/paged.rb:6: class_methods def where: every model and Relation already has where " \
               "(Cybertrain::Model, Cybertrain::Relation); a forwarder would replace it in Doc, so rename it", msg
  info = Cybertrain::Gen::ModelScan.scan_source("app/models/doc.rb", "class Doc\n  include Tracked\n\n  def recent = 0\nend\n", tmp_concerns)
  paged = Cybertrain::Gen::ConcernScan.find(tmp_concerns, "Paged")
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ConcernsEmitter.check_model_class_method(info, paged, "recent", 5) }
  assert_equal "app/models/concerns/paged.rb:5: class_methods def recent: Doc, which includes Paged, or one of its concerns " \
               "also defines an instance method recent (app/models/doc.rb:4); #{rule}", msg
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ConcernsEmitter.check_model_class_method(info, paged, "slug_sane", 5) }
  assert_equal "app/models/concerns/paged.rb:5: class_methods def slug_sane: Doc, which includes Paged, or one of its concerns " \
               "also defines an instance method slug_sane (app/models/concerns/tracked.rb:12); #{rule}", msg
  assert_nil Cybertrain::Gen::ConcernsEmitter.check_model_class_method(info, paged, "per_page", 7)
end

Cybertrain::Test.run!
