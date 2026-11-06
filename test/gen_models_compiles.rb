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
  assert_equal ["recent", "min_views"], infos[0].scopes.map { |sc| sc.name }
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
  comment = Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "hi")
  assert_equal false, Comment.find(comment.id).approved
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "bob", body: "yo", approved: "1")
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
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "first")
  Comment.create(post_id: other.id, seen_on: "2026-10-05", commenter: "bob", body: "elsewhere")
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "cy", body: "second")
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
  comment = Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "x")
  assert_nil comment.call_view_method(:summary)
end

test "to_json of a generated model" do
  reset_tables
  at = Time.utc(2026, 9, 25, 8, 0, 0)
  post = Post.create(title: "JSON", created_at: at, updated_at: at)
  expected = "{\"id\":#{post.id},\"title\":\"JSON\",\"body\":null,\"views\":0," \
             "\"price\":null,\"meta\":null,\"published_on\":null," \
             "\"created_at\":\"2026-09-25T08:00:00.000Z\",\"updated_at\":\"2026-09-25T08:00:00.000Z\"}"
  assert_equal expected, post.to_json
  comment = Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "b", created_at: at, updated_at: at)
  expected_comment = "{\"id\":#{comment.id},\"post_id\":#{post.id},\"commenter\":\"ann\",\"body\":\"b\"," \
                     "\"approved\":false,\"extras\":{},\"seen_on\":\"2026-10-05\",\"created_at\":\"2026-09-25T08:00:00.000Z\",\"updated_at\":\"2026-09-25T08:00:00.000Z\"}"
  assert_equal expected_comment, Comment.find(comment.id).to_json
end

# 1.006 rounds to 1.01 at scale 2 however the rounding is done (1.005
# and 1.015 sit on the binary edge).
test "decimal, json and date attributes round-trip as Float, Hash and Date" do
  reset_tables
  Post.create(title: "Typed", price: 1.006, meta: { "a" => 1 }, published_on: Date.new(2026, 10, 5))
  post = Post.first
  assert_equal 1.01, post.nil? ? -1.0 : post.price
  assert_equal 1, Cybertrain::Cast.int(post.nil? ? nil : Cybertrain::Cast.hash(post.meta)["a"])
  assert_equal "2026-10-05", post.nil? ? "" : post.published_on.to_s
  raw = Cybertrain::DB.with { |c| c.execute("SELECT price, meta, published_on FROM posts", []) }
  assert_equal 1.01, Cybertrain::Cast.float(raw[0]["price"])
  assert_equal '{"a":1}', Cybertrain::Cast.str(raw[0]["meta"])
  assert_equal "2026-10-05", Cybertrain::Cast.str(raw[0]["published_on"])
end

test "a nullable decimal, json and date left unset load back as nil and are stored as NULL" do
  reset_tables
  post = Post.create(title: "Empty")
  found = Post.find(post.id)
  assert_nil found.price
  assert_nil found.meta
  assert_nil found.published_on
  raw = Cybertrain::DB.with { |c| c.execute("SELECT price IS NULL AS p, meta IS NULL AS m, published_on IS NULL AS d FROM posts", []) }
  assert_equal 1, Cybertrain::Cast.int(raw[0]["p"])
  assert_equal 1, Cybertrain::Cast.int(raw[0]["m"])
  assert_equal 1, Cybertrain::Cast.int(raw[0]["d"])
end

test "a NOT NULL json column starts as {} and round-trips a Hash" do
  reset_tables
  post = Post.create(title: "Parent")
  empty = Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "a")
  assert_equal({}, Comment.find(empty.id).extras)
  comment = Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "bob", body: "b", extras: { "a" => 1 })
  assert_equal 1, Cybertrain::Cast.int(Comment.find(comment.id).extras["a"])
  comment.extras = { "b" => "two" }
  comment.save
  assert_equal "two", Cybertrain::Cast.str(Comment.find(comment.id).extras["b"])
  raw = Cybertrain::DB.with { |c| c.execute("SELECT extras FROM comments WHERE id = ?", [comment.id]) }
  assert_equal '{"b":"two"}', Cybertrain::Cast.str(raw[0]["extras"])
end

test "column_type and decimal_scale answer per column from the schema" do
  rel = Post.all
  assert_equal :decimal, rel.column_type("price")
  assert_equal :json, rel.column_type("meta")
  assert_equal :date, rel.column_type("published_on")
  assert_equal :integer, rel.column_type("id")
  assert_equal :integer, rel.column_type("views")
  assert_equal :string, rel.column_type("title")
  assert_equal :text, rel.column_type("body")
  assert_equal :datetime, rel.column_type("created_at")
  assert_equal :unknown, rel.column_type("nope")
  assert_equal 2, rel.decimal_scale("price")
  assert_equal(-1, rel.decimal_scale("views"))
  assert_equal :boolean, Comment.all.column_type("approved")
  assert_equal :json, Comment.all.column_type("extras")
  assert_equal(-1, Comment.all.decimal_scale("approved"))
  refute rel.binary_column?("body")
end

test "the generated query methods: where.not, where with a String and a Range, where_between on a date, or, order by Hash" do
  reset_tables
  a = Post.create(title: "Alpha", views: 1, published_on: Date.new(2026, 10, 1))
  b = Post.create(title: "Beta", views: 5, published_on: Date.new(2026, 10, 15))
  c = Post.create(title: "Gamma", views: 10)
  assert_equal ["Beta", "Gamma"], Post.where.not(title: "Alpha").order("id").pluck_str(:title)
  assert_equal 2, Post.where("views > ?", 2).count
  assert_equal 2, Post.where(views: 1..5).count
  assert_equal [b.id], Post.where_between(:published_on, Date.new(2026, 10, 2), Date.new(2026, 10, 15)).ids
  assert_equal [a.id, c.id], Post.where(views: 1).or(Post.where(views: 10)).order(id: :asc).ids
  assert_equal [c.id, b.id, a.id], Post.order(views: :desc).ids
  assert_equal 1, Post.where(title: "Gamma").update_all(views: 11)
  assert_equal 11, Post.find_by!(title: "Gamma").views
  assert Post.exists?
  refute Post.none.exists?
  seen = Array.new(0) { "" }
  Post.find_each(batch: 1) { |p| seen << p.title }
  assert_equal ["Alpha", "Beta", "Gamma"], seen
  assert_equal "Delta", Post.find_or_create_by(title: "Delta").title
  assert_equal 4, Post.count
  message = assert_raises("ArgumentError") { Post.where(meta: { "a" => 1 }) }
  assert_equal "where on a json column (meta) is not supported", message
  assert_raises("ArgumentError") { Post.where.not(meta: nil) }
  message = assert_raises("ArgumentError") { Post.where_between(:meta, "a", "b") }
  assert_equal "where_between on a json column (meta) is not supported", message
  assert_raises("RecordInvalid") { Post.create!(title: "") }
  assert_equal 4, Post.destroy_all.size
  assert_equal 0, Post.count
end

test "update_columns writes through the generated to_row: decimal rounded to its scale, json as text" do
  reset_tables
  post = Post.create(title: "Cols", price: 1.0)
  before = Post.find(post.id).updated_at
  assert_equal true, post.update_columns(price: 2.345, meta: { "k" => "v" })
  assert_equal 2.35, Post.find(post.id).price
  raw = Cybertrain::DB.with { |c| c.execute("SELECT meta, price FROM posts WHERE id = ?", [post.id]) }
  assert_equal '{"k":"v"}', Cybertrain::Cast.str(raw[0]["meta"])
  assert_equal "v", Cybertrain::Cast.str(Post.find(post.id).meta["k"])
  assert_equal before, Post.find(post.id).updated_at
end

test "a NOT NULL date: invalid assigned text stays nil and the save fails validation; a valid date round-trips" do
  reset_tables
  post = Post.create(title: "Dates")
  comment = Comment.new(post_id: post.id, commenter: "ann", body: "b", seen_on: "2026-13-01")
  assert_nil comment.seen_on
  # The generated presence validation catches it before the NOT NULL
  # constraint would: an error on the record, save returns false.
  refute comment.valid?
  assert_equal ["can't be blank"], comment.errors[:seen_on]
  refute comment.save
  comment.write_attribute(:seen_on, "")
  assert_nil comment.seen_on
  assert_nil comment.to_row["seen_on"]
  refute comment.save
  assert_equal 0, Comment.count
  comment.seen_on = nil
  comment.write_attribute(:seen_on, "2026-10-05")
  assert_equal Date.new(2026, 10, 5), comment.seen_on
  assert comment.save
  assert_equal Date.new(2026, 10, 5), Comment.find(comment.id).seen_on
  raw = Cybertrain::DB.with { |c| c.execute("SELECT seen_on FROM comments WHERE id = ?", [comment.id]) }
  assert_equal "2026-10-05", Cybertrain::Cast.str(raw[0]["seen_on"])
end

test "update_all rounds a decimal to its scale as save does, and nil stores NULL" do
  reset_tables
  post = Post.create(title: "Priced", price: 1.0)
  assert_equal 1, Post.where(id: post.id).update_all(price: 2.345)
  raw = Cybertrain::DB.with { |c| c.execute("SELECT price FROM posts WHERE id = ?", [post.id]) }
  assert_equal 2.35, Cybertrain::Cast.float(raw[0]["price"])
  assert_equal 2.35, Post.find(post.id).price
  assert_equal 1, Post.where(id: post.id).update_all(price: nil)
  raw = Cybertrain::DB.with { |c| c.execute("SELECT price IS NULL AS n FROM posts WHERE id = ?", [post.id]) }
  assert_equal 1, Cybertrain::Cast.int(raw[0]["n"])
  assert_nil Post.find(post.id).price
end

test "scopes from app/models/post.rb run as class methods and chain on a relation" do
  reset_tables
  at = Time.utc(2026, 10, 1, 12, 0, 0)
  Post.create(title: "Old", views: 5, created_at: at, updated_at: at)
  Post.create(title: "New", views: 1, created_at: at + 60, updated_at: at + 60)
  Post.create(title: "Mid", views: 2, created_at: at + 30, updated_at: at + 30)
  assert_equal "New", Post.recent.first.title
  assert_equal 2, Post.min_views(2).count
  assert_equal ["Mid", "Old"], Post.recent.min_views(2).to_a.map { |p| p.title }
  assert_equal ["Mid", "Old"], Post.min_views(2).recent.to_a.map { |p| p.title }
  assert_equal "Old", Post.where(title: "Old").min_views(2).first.title
  assert_equal 0, Post.min_views(6).count
end

Cybertrain::Test.run!
