require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

# Proves the model generator's output compiles and runs: the checked-in
# gen/models files of the fixture app are required together with the
# fixture's own app/models/post.rb and driven against SQLite. SQLite is FFI,
# so the snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_app/db/schema"
require_relative "fixtures/gen_app/gen/models/comment"
require_relative "fixtures/gen_app/gen/models/post"
require_relative "fixtures/gen_app/app/models/post"

FIXTURE = "test/fixtures/gen_app"

# CREATE TABLE statements for the fixture schema, so the database always
# matches what the models were generated from.
def sql_type(column)
  case column.type
  when :integer, :boolean then "INTEGER"
  when :float then "REAL"
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
    table.foreign_keys.each do |fk|
      parts << "FOREIGN KEY (\"#{fk.column}\") REFERENCES \"#{fk.to_table}\"(id)"
    end
    sql << "CREATE TABLE \"#{table.name}\" (#{parts.join(", ")});"
  end
  sql
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.exec_script(create_tables_sql(Cybertrain::Schema.current)) }

def reset_tables
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM comments; DELETE FROM posts;") }
end

test "the checked-in gen/models files match the emitter (fixture stale otherwise)" do
  infos = Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models")
  outputs = Cybertrain::Gen::ModelsEmitter.outputs(Cybertrain::Schema.current, infos)
  assert_equal ["gen/models/comment.rb", "gen/models/post.rb"], outputs.keys
  outputs.each do |path, source|
    Cybertrain::Test.count_assertion
    flunk("fixture stale: #{path}") unless File.read(FIXTURE + "/" + path) == source
  end
end

test "scan_dir finds Post and its summary view method" do
  infos = Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models")
  assert_equal 1, infos.size
  assert_equal "Post", infos[0].class_name
  assert_equal FIXTURE + "/app/models/post.rb", infos[0].file
  assert_equal ["summary"], infos[0].view_methods
end

test "write_all writes every model file under gen/models" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  root = "tmp/gen_models_test"
  Dir.mkdir(root) unless Dir.exist?(root)
  infos = Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models")
  written = Cybertrain::Gen::ModelsEmitter.write_all(root, Cybertrain::Schema.current, infos)
  assert_equal ["gen/models/comment.rb", "gen/models/post.rb"], written
  written.each do |path|
    assert_equal File.read(FIXTURE + "/" + path), File.read(root + "/" + path)
    File.delete(root + "/" + path)
  end
  Dir.rmdir(root + "/gen/models")
  Dir.rmdir(root + "/gen")
  Dir.rmdir(root)
end

test "create and find through the generated classes" do
  reset_tables
  post = Post.create(title: "Generated", body: "works")
  assert post.persisted?
  found = Post.find(post.id)
  assert_equal "Generated", found.title
  assert_equal "works", found.body
  assert_equal 0, found.views
  refute found.created_at.nil?
  assert_equal 1, Post.count
  assert_equal "Couldn't find Post with id=0", assert_raises("RecordNotFound") { Post.find(0) }
end

test "column defaults become initial values and reach the database" do
  reset_tables
  post = Post.create(title: "Defaults")
  comment = Comment.create(post_id: post.id, commenter: "ann", body: "hi")
  assert_equal false, Comment.find(comment.id).approved
  Comment.create(post_id: post.id, commenter: "bob", body: "yo", approved: "1")
  assert_equal 1, Comment.where(approved: true).count
  assert_equal 0, Post.find(post.id).views
  post.views = 5
  post.save
  assert_equal 5, Post.find(post.id).views
end

test "validations from app/models/post.rb apply to the generated class" do
  reset_tables
  post = Post.new(title: "")
  refute post.save
  assert_equal ["Title can't be blank"], post.errors.full_messages
end

test "belongs_to and has_many associations" do
  reset_tables
  post = Post.create(title: "Parent")
  other = Post.create(title: "Other")
  Comment.create(post_id: post.id, commenter: "ann", body: "first")
  Comment.create(post_id: other.id, commenter: "bob", body: "elsewhere")
  Comment.create(post_id: post.id, commenter: "cy", body: "second")
  assert_equal ["first", "second"], post.comments.map { |c| c.body }
  comment = Comment.find_by(body: "second")
  assert_equal "Parent", comment.post.title
  assoc = post.read_association(:comments)
  size = case assoc
         when Array then assoc.size
         else -1
         end
  assert_equal 2, size
  assert_equal "Parent", comment.read_association(:post).title
  assert_nil post.read_association(:nope)
end

test "call_view_method reaches the scanned summary" do
  reset_tables
  post = Post.create(title: "Summarized")
  assert_equal "Sum", post.call_view_method(:summary)
  assert_nil post.call_view_method(:nope)
  comment = Comment.create(post_id: post.id, commenter: "ann", body: "x")
  assert_nil comment.call_view_method(:summary)
end

test "to_json of a generated model" do
  reset_tables
  at = Time.utc(2026, 9, 25, 8, 0, 0)
  post = Post.create(title: "JSON", created_at: at, updated_at: at)
  expected = "{\"id\":#{post.id},\"title\":\"JSON\",\"body\":null,\"views\":0," \
             "\"created_at\":\"2026-09-25T08:00:00Z\",\"updated_at\":\"2026-09-25T08:00:00Z\"}"
  assert_equal expected, post.to_json
  comment = Comment.create(post_id: post.id, commenter: "ann", body: "b", created_at: at, updated_at: at)
  expected_comment = "{\"id\":#{comment.id},\"post_id\":#{post.id},\"commenter\":\"ann\",\"body\":\"b\"," \
                     "\"approved\":false,\"created_at\":\"2026-09-25T08:00:00Z\",\"updated_at\":\"2026-09-25T08:00:00Z\"}"
  assert_equal expected_comment, Comment.find(comment.id).to_json
end

Cybertrain::Test.run!
