require "tmpdir"
require "cybertrain/test"
require "cybertrain/test/views"
require "cybertrain/controller"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/encryptor"

# What a template may read from a record (docs/design.md D71): the generated
# models answer attribute_or_method? for their columns, associations and
# view methods, so a nil value renders empty and a name the model does not
# have is an error naming the template, the line, the name and the model --
# in a request and outside one (Views.render_partial). The models are the
# fixture app's checked-in gen/models files, as in gen_models_compiles.rb.
#
# SQLite is FFI, so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_app/db/schema"
require_relative "fixtures/gen_app/gen/models/comment"
require_relative "fixtures/gen_app/gen/models/post"
require_relative "fixtures/gen_app/gen/concerns/models/concerns/visible"
require_relative "fixtures/gen_app/app/models/comment"
require_relative "fixtures/gen_app/app/models/post"

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

Cybertrain.config.encryption_key = "8f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.exec_script(create_tables_sql(Cybertrain::Schema.current)) }

# A hand-written model that does not declare its names: the base
# attribute_or_method? (true) keeps every unanswered name a nil.
class Loose < Cybertrain::Model
  def initialize(title)
    super()
    @title = title
  end

  def model_name = "Loose"

  def read_attribute(name)
    case name
    when :title then @title
    else nil
    end
  end
end

ROOT = Dir.mktmpdir("cybertrain-model-contract")
FILES = {
  "app/views/posts/_post.html.erb" => "<%# locals: (post:) %>\n<%= post.title %>|<%= post.body %>|<%= post.comments.size %>|<%= post.summary %>|<%= post.published? %>",
  "app/views/posts/_typo.html.erb" => "<%# locals: (post:) %>\n<p>\n<%= post.titel %></p>",
  "app/views/posts/_token.html.erb" => "<%# locals: (post:) %>\n<%= post.title %><%= csrf_token %>",
  "app/views/comments/_comment.html.erb" => "<%# locals: (comment:) %>\n<%= comment.commenter %> on <%= comment.post.title %>"
}
DIRS = ["app", "app/views", "app/views/posts", "app/views/comments"]
DIRS.each { |d| Dir.mkdir("#{ROOT}/#{d}") }
FILES.each_key { |f| File.write("#{ROOT}/#{f}", FILES[f]) }
at_exit do
  FILES.each_key { |f| File.delete("#{ROOT}/#{f}") }
  DIRS.reverse.each { |d| Dir.rmdir("#{ROOT}/#{d}") }
  Dir.rmdir(ROOT)
end
Cybertrain::Views.configure("#{ROOT}/app/views", cache: false)

# src rendered as posts/inline with `record` as the local `name`.
def inline(src, name, record)
  helpers = Cybertrain::Views.helpers_builder.call(nil)
  template = Cybertrain::Template::Template.parse(src, "posts/inline")
  env = { "__template_dir" => "posts" }
  env[name] = record
  Cybertrain::Template::Interpreter.new(helpers).render(template, env).to_s
end

# The error a render raises, as "Class: message".
def inline_error(src, name, record)
  msg = ""
  begin
    inline(src, name, record)
  rescue StandardError => e
    msg = "#{e.class.name}: #{e.message}"
  end
  msg
end

def partial_error(partial, post)
  msg = ""
  begin
    Cybertrain::Views.render_partial(partial, post: post)
  rescue StandardError => e
    msg = "#{e.class.name}: #{e.message}"
  end
  msg
end

def seeded_post
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM comments; DELETE FROM posts;") }
  post = Post.create(title: "Hello", published_on: "2026-11-06")
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "hi")
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "bob", body: "yo")
  post
end

test "a generated model knows its columns, associations and view methods" do
  post = Post.new(title: "t")
  assert post.attribute_or_method?(:id)
  assert post.attribute_or_method?(:title)
  assert post.attribute_or_method?(:body)
  assert post.attribute_or_method?(:comments)
  assert post.attribute_or_method?(:summary)
  assert post.attribute_or_method?(:published?)
  assert post.attribute_or_method?(:visible?)
  assert !post.attribute_or_method?(:titel)
  assert !post.attribute_or_method?(:post)
  comment = Comment.new
  assert comment.attribute_or_method?(:post)
  assert comment.attribute_or_method?(:post_id)
  assert !comment.attribute_or_method?(:comments)
end

test "an attribute that is nil renders empty" do
  post = Post.new(title: "t")
  assert_nil post.body
  assert_equal "t[][][]", inline("<%= post.title %>[<%= post.body %>][<%= post.price %>][<%= post.published_on %>]", "post", post)
end

test "a name the model does not have is an error naming the template, line, name and model" do
  post = Post.new(title: "t")
  assert_equal "Cybertrain::Template::RuntimeError: posts/inline:2: undefined method 'titel' for Post",
               inline_error("<p>\n<%= post.titel %></p>", "post", post)
  # a name another model has
  assert_equal "Cybertrain::Template::RuntimeError: posts/inline:1: undefined method 'commenter' for Post",
               inline_error("<%= post.commenter %>", "post", post)
  # a method of the record templates may not call
  assert_equal "Cybertrain::Template::RuntimeError: posts/inline:1: undefined method 'save' for Post",
               inline_error("<%= post.save %>", "post", post)
end

test "associations: a has_many as an Array, a belongs_to as the record, a missing one as nil" do
  post = seeded_post
  assert_equal "2:ann,bob,", inline("<%= post.comments.size %>:<% post.comments.each do |c| %><%= c.commenter %>,<% end %>", "post", post)
  comment = Comment.where(commenter: "ann").first
  assert_equal "Hello", inline("<%= comment.post.title %>", "comment", comment)
  assert_equal "none", inline("<% if comment.post %>some<% else %>none<% end %>", "comment", Comment.new)
  assert_equal "Cybertrain::Template::RuntimeError: posts/inline:1: undefined method 'posts' for Comment",
               inline_error("<%= comment.posts %>", "comment", comment)
end

test "view methods, a concern's included" do
  post = seeded_post
  assert_equal "Hel|true|true", inline("<%= post.summary %>|<%= post.published? %>|<%= post.visible? %>", "post", post)
  assert_equal "false", inline("<%= post.published? %>", "post", Post.new(title: "t"))
  # private methods of app/models are not view methods
  assert_equal "Cybertrain::Template::RuntimeError: posts/inline:1: undefined method 'title_not_reserved' for Post",
               inline_error("<%= post.title_not_reserved %>", "post", post)
end

test "outside a request a record reads the same" do
  post = seeded_post
  assert_equal "Hello||2|Hel|true", Cybertrain::Views.render_partial("posts/post", post: post)
  comment = Comment.where(commenter: "bob").first
  assert_equal "bob on Hello", Cybertrain::Views.render_partial("comments/comment", comment: comment)
end

test "outside a request an unknown name is the same error, and a request-bound helper still OutsideRequest" do
  post = seeded_post
  assert_equal "Cybertrain::Template::RuntimeError: posts/_typo.html.erb:3: undefined method 'titel' for Post", partial_error("posts/typo", post)
  assert_equal "Cybertrain::Views::OutsideRequest: csrf_token needs a request", partial_error("posts/token", post)
end

test "options_from_collection_for_select reads a view method and refuses an unknown name" do
  post = seeded_post
  assert_equal "<option value=\"#{post.id}\">Hel</option>", inline("<%= options_from_collection_for_select(posts, :id, :summary) %>", "posts", [post])
  assert_equal "Cybertrain::Template::RuntimeError: posts/inline:1: options_from_collection_for_select: Post has no attribute or view method 'titel'",
               inline_error("<%= options_from_collection_for_select(posts, :id, :titel) %>", "posts", [post])
end

test "a model that does not declare its names keeps an unanswered name nil" do
  loose = Loose.new("x")
  assert loose.attribute_or_method?(:anything)
  assert_equal "x[]", inline("<%= loose.title %>[<%= loose.titel %>]", "loose", loose)
end

Cybertrain::Test.run!
