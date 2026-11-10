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

test "an unknown model concern is refused with file and line" do
  source = "class Note\n  validates :title, presence: true\n  include Missing\nend\n"
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::ModelScan.scan_source("app/models/note.rb", source, model_concerns) }
  assert_equal "app/models/note.rb:3: include Missing: no concern named Missing in app/models/concerns", msg
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
  assert_equal ["\n", "\n", "\n", "\n"], copy[6, 4]
  assert_equal source[11], copy[11]
  assert_equal "# Generated by `spin run gen` from app/models/concerns/visible.rb. Do not edit.\n", copy.last
end

Cybertrain::Test.run!
