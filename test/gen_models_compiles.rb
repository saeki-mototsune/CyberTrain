require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/encryptor"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

# Proves the model generator's output compiles and runs: the checked-in
# gen/models files of the fixture app are required together with the
# fixture's own app/models files and driven against SQLite. SQLite is FFI,
# so the snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
# Post encrypts secret_note, so the program links cybertrain/encryptor (the
# openssl package; gen/app.rb requires it in an app) and sets a key here.
require_relative "fixtures/gen_app/db/schema"
require_relative "fixtures/gen_app/gen/models/comment"
require_relative "fixtures/gen_app/gen/models/post"
require_relative "fixtures/gen_app/app/models/comment"
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

Cybertrain.config.encryption_key = "8f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
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

test "scan_dir finds Comment and Post, Post's summary view method and both declarations" do
  infos = Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models")
  assert_equal ["Comment", "Post"], infos.map { |info| info.class_name }
  assert_equal FIXTURE + "/app/models/post.rb", infos[1].file
  assert_equal ["summary", "published?"], infos[1].view_methods
  assert_equal ["title_not_reserved"], infos[1].custom_validations.map { |v| v.name }
  assert_equal ["published?"], infos[1].custom_validations.map { |v| v.condition_if }
  assert_equal ["recent", "min_views"], infos[1].scopes.map { |sc| sc.name }
  assert_equal ["comments"], infos[1].associations.map { |a| a.name }
  assert_equal [:destroy], infos[1].associations.map { |a| a.dependent }
  assert_equal ["post"], infos[0].associations.map { |a| a.name }
  assert_equal [true], infos[0].associations.map { |a| a.counter_cache }
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

test "uniqueness from app/models/post.rb: a taken title fails on create and on update, not the record's own" do
  reset_tables
  first = Post.create(title: "Unique")
  assert first.persisted?
  dup = Post.new(title: "Unique")
  refute dup.save
  assert_equal ["Title has already been taken"], dup.errors.full_messages
  # Case-sensitive by default (SQLite's BINARY collation).
  assert Post.new(title: "unique").valid?
  # The record's own row is not a conflict.
  first.body = "edited"
  assert first.save
  other = Post.create(title: "Other")
  other.title = "Unique"
  refute other.save
  assert_equal ["Title has already been taken"], other.errors.full_messages
  assert_equal ["Title is too long (maximum is 40 characters)"], Post.create(title: "x" * 41).errors.full_messages
end

test "the generated unique_value_taken?: case_sensitive false compares LOWER(), scope narrows, the own id is excluded" do
  reset_tables
  post = Post.create(title: "MiXed", views: 3)
  probe = Post.new
  assert probe.unique_value_taken?(:title, "MiXed", nil, nil, 0, true)
  refute probe.unique_value_taken?(:title, "mixed", nil, nil, 0, true)
  assert probe.unique_value_taken?(:title, "mixed", nil, nil, 0, false)
  assert probe.unique_value_taken?(:title, "MIXED", :views, 3, 0, false)
  refute probe.unique_value_taken?(:title, "MIXED", :views, 4, 0, false)
  refute probe.unique_value_taken?(:title, "mixed", nil, nil, post.id, false)
  # A quote in the value is a bind, not SQL.
  refute probe.unique_value_taken?(:title, "x') OR ('1' = '1", nil, nil, 0, false)
  assert_raises("ArgumentError") { probe.unique_value_taken?(:"title) OR (1", "x", nil, nil, 0, false) }
  # nil is IS NULL whether or not case-sensitive (LOWER(NULL) never matches).
  # (post's body is NULL; no title is.)
  assert probe.unique_value_taken?(:body, nil, nil, nil, 0, false)
  refute probe.unique_value_taken?(:body, nil, nil, nil, post.id, false)
  refute probe.unique_value_taken?(:title, nil, nil, nil, 0, false)
  assert probe.unique_value_taken?(:body, nil, nil, nil, 0, true)
end

test "validation_condition? raises for a name app/models never declared, so a missed condition is loud" do
  msg = assert_raises("ArgumentError") { Post.new.validation_condition?(:draft?) }
  assert_equal "validation_condition?: draft? is not an if:/unless: name app/models/post.rb declares " \
               "(write if: :draft? on the validates line)", msg
  assert_raises("ArgumentError") { Comment.new.validation_condition?(:ready?) }
end

test "numericality and the custom validation with its if: from app/models/post.rb" do
  reset_tables
  post = Post.new(title: "Count", views: -1)
  refute post.save
  assert_equal ["Views must be greater than or equal to 0"], post.errors.full_messages
  # title_not_reserved runs only once published? is true.
  draft = Post.new(title: "admin")
  assert draft.save
  published = Post.new(title: "Admin", published_on: "2026-11-06")
  refute published.save
  assert_equal ["Title is reserved once published"], published.errors.full_messages
  published.title = "News"
  assert published.save
end

test "belongs_to and has_many associations" do
  reset_tables
  post = Post.create(title: "Parent")
  other = Post.create(title: "Other")
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "first")
  Comment.create(post_id: other.id, seen_on: "2026-10-05", commenter: "bob", body: "elsewhere")
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "cy", body: "second")
  assert_equal ["first", "second"], post.comments.to_a.map { |c| c.body }
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
             "\"price\":null,\"comments_count\":0,\"meta\":null,\"published_on\":null,\"secret_note\":null," \
             "\"created_at\":\"2026-09-25T08:00:00.000Z\",\"updated_at\":\"2026-09-25T08:00:00.000Z\"}"
  assert_equal expected, post.to_json
  comment = Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: "b", created_at: at, updated_at: at)
  expected_comment = "{\"id\":#{comment.id},\"post_id\":#{post.id},\"commenter\":\"ann\",\"body\":\"b\"," \
                     "\"approved\":false,\"extras\":{},\"seen_on\":\"2026-10-05\",\"due_on\":\"2026-01-01\",\"created_at\":\"2026-09-25T08:00:00.000Z\",\"updated_at\":\"2026-09-25T08:00:00.000Z\"}"
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

test "a NOT NULL date with a default: a fresh record holds the default, invalid text fails validation" do
  reset_tables
  post = Post.create(title: "Due")
  comment = Comment.new(post_id: post.id, commenter: "ann", body: "b", seen_on: "2026-10-05")
  # Every column is inserted, so SQLite would never apply the default: the
  # generated initial value is it.
  assert_equal Date.new(2026, 1, 1), comment.due_on
  assert comment.valid?
  comment.write_attribute(:due_on, "2026-13-01")
  assert_nil comment.due_on
  refute comment.valid?
  assert_equal ["can't be blank"], comment.errors[:due_on]
  refute comment.save
  assert_equal 0, Comment.count
  comment.write_attribute(:due_on, "2026-11-30")
  assert comment.save
  assert_equal Date.new(2026, 11, 30), Comment.find(comment.id).due_on
  fresh = Comment.create(post_id: post.id, commenter: "bob", body: "c", seen_on: "2026-10-05")
  assert fresh.persisted?
  assert_equal Date.new(2026, 1, 1), Comment.find(fresh.id).due_on
  raw = Cybertrain::DB.with { |c| c.execute("SELECT due_on FROM comments WHERE id = ?", [fresh.id]) }
  assert_equal "2026-01-01", Cybertrain::Cast.str(raw[0]["due_on"])
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

# ---- declared associations (app/models/post.rb and comment.rb) ----------

DESTROYED_COMMENT_IDS = Array.new(0) { 0 }

# A comment whose body is "explode" refuses its update and its destroy
# after the row was written, so the tests below can watch the transaction
# roll back.
class Comment
  after_destroy { |c| DESTROYED_COMMENT_IDS << c.id }
  after_update do |c|
    body = Cybertrain::Cast.str(c.read_attribute(:body))
    raise ArgumentError, "after_update refused" if body == "explode"
  end
  after_destroy do |c|
    body = Cybertrain::Cast.str(c.read_attribute(:body))
    raise ArgumentError, "after_destroy refused" if body == "explode"
  end
end

def comment_on(post, body)
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: body)
end

def count_on(post)
  Post.find(post.id).comments_count
end

test "post.comments is the comments' Relation: it chains, counts and orders" do
  reset_tables
  post = Post.create(title: "Parent")
  other = Post.create(title: "Other")
  comment_on(post, "a")
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "bob", body: "b", approved: true)
  comment_on(other, "elsewhere")
  assert_equal 2, post.comments.count
  assert_equal 1, post.comments.where(approved: true).count
  assert_equal ["b", "a"], post.comments.order(id: :desc).to_a.map { |c| c.body }
  assert_equal "a", post.comments.first.body
  assert_equal 0, Post.new.comments.count
end

test "comment.post is read once per foreign key, again when the key changes, and after reload" do
  reset_tables
  a = Post.create(title: "A")
  b = Post.create(title: "B")
  comment = comment_on(a, "c")
  assert_equal "A", comment.post.title
  Post.where(id: a.id).update_all(title: "A2")
  assert_equal "A", comment.post.title
  comment.post_id = b.id
  assert_equal "B", comment.post.title
  comment.post_id = a.id
  assert_equal "A2", comment.post.title
  Post.where(id: a.id).update_all(title: "A3")
  comment.reload
  assert_equal "A3", comment.post.title
  # A key with no parent caches nil, and the next key is read again.
  comment.post_id = b.id + 100
  assert_nil comment.post
  comment.post_id = b.id
  assert_equal "B", comment.post.title
end

test "belongs_to :post without optional: validates post_id" do
  reset_tables
  comment = Comment.new(seen_on: "2026-10-05", commenter: "ann", body: "x")
  refute comment.valid?
  assert_equal ["can't be blank"], comment.errors[:post_id]
  refute comment.save
  assert_equal 0, Comment.count
  comment.post_id = Post.create(title: "P").id
  assert comment.valid?
  assert comment.save
end

test "post.destroy destroys each of its comments (their callbacks run), then the post" do
  reset_tables
  DESTROYED_COMMENT_IDS.clear
  post = Post.create(title: "Parent")
  other = Post.create(title: "Other")
  first = comment_on(post, "first")
  second = comment_on(post, "second")
  kept = comment_on(other, "kept")
  assert post.destroy
  refute post.persisted?
  assert_equal [first.id, second.id], DESTROYED_COMMENT_IDS
  assert_equal [kept.id], Comment.all.ids
  assert_equal [other.id], Post.all.ids
end

test "a destroy that raises rolls back the post and every comment and keeps the record persisted" do
  reset_tables
  post = Post.create(title: "Parent")
  comment_on(post, "first")
  comment_on(post, "explode")
  assert_equal "after_destroy refused", assert_raises("ArgumentError") { post.destroy }
  assert post.persisted?
  assert_equal 1, Post.count
  assert_equal 2, Comment.count
  assert_equal 2, count_on(post)
  refute Cybertrain::DB.in_transaction?
end

test "comments_count follows create, destroy and a moved comment; the post's own save leaves it alone" do
  reset_tables
  a = Post.create(title: "A")
  b = Post.create(title: "B")
  one = comment_on(a, "one")
  two = comment_on(a, "two")
  assert_equal 2, count_on(a)
  assert_equal 0, count_on(b)
  one.post_id = b.id
  assert one.save
  assert_equal 1, count_on(a)
  assert_equal 1, count_on(b)
  one.body = "edited"
  assert one.save
  assert_equal 1, count_on(a)
  assert_equal 1, count_on(b)
  assert two.destroy
  assert_equal 0, count_on(a)
  # b was loaded at 0 before its comment arrived: saving it keeps the 1.
  assert_equal 0, b.comments_count
  b.title = "B2"
  assert b.save
  assert_equal 1, count_on(b)
  assert_equal "B2", Post.find(b.id).title
end

test "two loaded copies of one comment moved to different posts leave every count right" do
  reset_tables
  a = Post.create(title: "A")
  b = Post.create(title: "B")
  c = Post.create(title: "C")
  comment = comment_on(a, "moving")
  first = Comment.find(comment.id)
  second = Comment.find(comment.id)
  first.post_id = b.id
  assert first.save
  second.post_id = c.id
  assert second.save
  assert_equal 0, count_on(a)
  assert_equal 0, count_on(b)
  assert_equal 1, count_on(c)
end

test "destroy decrements the post the row points to, not a stale or unsaved in-memory key" do
  reset_tables
  a = Post.create(title: "A")
  b = Post.create(title: "B")
  c = Post.create(title: "C")
  comment = comment_on(a, "moving")
  stale = Comment.find(comment.id)
  moved = Comment.find(comment.id)
  moved.post_id = b.id
  assert moved.save
  assert stale.destroy
  assert_equal 0, count_on(a)
  assert_equal 0, count_on(b)
  other = comment_on(c, "reassigned")
  other.post_id = a.id
  assert other.destroy
  assert_equal 0, count_on(a)
  assert_equal 0, count_on(c)
  # A copy whose row is already gone counts nothing.
  gone = comment_on(c, "gone")
  copy = Comment.find(gone.id)
  assert gone.destroy
  assert copy.destroy
  assert_equal 0, count_on(c)
end

test "a move whose save raises inside the transaction leaves the counts and the row as they were" do
  reset_tables
  a = Post.create(title: "A")
  b = Post.create(title: "B")
  comment = comment_on(a, "fine")
  comment.post_id = b.id
  comment.body = "explode"
  assert_equal "after_update refused", assert_raises("ArgumentError") { comment.save }
  assert_equal 1, count_on(a)
  assert_equal 0, count_on(b)
  assert_equal a.id, Comment.find(comment.id).post_id
  refute Cybertrain::DB.in_transaction?
  # Inside a transaction the application opened, the save joins it.
  comment.body = "fine"
  Cybertrain::DB.transaction { |_c| comment.save }
  assert_equal 0, count_on(a)
  assert_equal 1, count_on(b)
end

test "an encrypted column is stored as a payload and read back as the text; nil stays NULL" do
  reset_tables
  post = Post.create(title: "Locked", secret_note: "k")
  assert post.persisted?
  stored = Cybertrain::DB.with { |c| c.execute("SELECT secret_note FROM posts WHERE id = ?", [post.id]) }
  raw = stored[0]["secret_note"].to_s
  assert raw.start_with?("1:")
  refute raw == "k"
  assert_equal "k", Post.first.secret_note
  assert_equal "k", Post.find(post.id).secret_note
  # pluck answers the stored payload, not the text.
  assert Post.all.pluck_str(:secret_note)[0].start_with?("1:")
  blank = Post.create(title: "Open")
  assert_nil Post.find(blank.id).secret_note
  nulls = Cybertrain::DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM posts WHERE secret_note IS NULL", []) }
  assert_equal 1, Cybertrain::Cast.int(nulls[0]["n"])
  # A save writes a fresh payload (a new nonce), still the same text.
  found = Post.find(post.id)
  found.secret_note = "changed"
  assert found.save
  assert_equal "changed", Post.find(post.id).secret_note
end

test "where, update_all and the bulk writes refuse an encrypted column" do
  reset_tables
  Post.create(title: "Locked", secret_note: "k")
  message = assert_raises("ArgumentError") { Post.where(secret_note: "k") }
  assert_equal "where on an encrypted column (secret_note) is not supported", message
  assert_raises("ArgumentError") { Post.where.not(secret_note: "k") }
  assert_raises("ArgumentError") { Post.find_by(secret_note: "k") }
  assert_equal "where_like on an encrypted column (secret_note) is not supported",
               assert_raises("ArgumentError") { Post.where_like(:secret_note, "k") }
  assert_equal "update_all on an encrypted column (secret_note) is not supported",
               assert_raises("ArgumentError") { Post.update_all(secret_note: "x") }
  assert_equal "insert_all: secret_note is an encrypted column",
               assert_raises("ArgumentError") { Post.insert_all([{ title: "Bulk", secret_note: "x" }]) }
  assert_equal "insert_all: returning: secret_note is an encrypted column",
               assert_raises("ArgumentError") { Post.insert_all([{ title: "Bulk" }], returning: [:secret_note]) }
  assert_equal "upsert_all: unique_by: secret_note is an encrypted column",
               assert_raises("ArgumentError") { Post.upsert_all([{ title: "Bulk" }], unique_by: [:secret_note]) }
  assert_equal "upsert_all: update_only: secret_note is an encrypted column",
               assert_raises("ArgumentError") { Post.upsert_all([{ title: "Bulk" }], unique_by: [:title], update_only: [:secret_note]) }
  assert_equal 1, Post.count
end

test "a stored payload made with another key raises Encryptor::Error on read" do
  reset_tables
  post = Post.create(title: "Locked", secret_note: "k")
  saved_key = Cybertrain.config.encryption_key
  Cybertrain.config.encryption_key = "00" * 32
  assert_raises("Encryptor::Error") { Post.find(post.id) }
  Cybertrain.config.encryption_keys_previous = [saved_key]
  assert_equal "k", Post.find(post.id).secret_note
  Cybertrain.config.encryption_key = saved_key
  Cybertrain.config.encryption_keys_previous = Array.new(0) { "" }
end

test "unique_value_taken? on an encrypted column raises, case-sensitive or not" do
  reset_tables
  Post.create(title: "Locked", secret_note: "k")
  probe = Post.new
  [true, false].each do |sensitive|
    message = assert_raises("ArgumentError") { probe.unique_value_taken?(:secret_note, "k", nil, nil, 0, sensitive) }
    assert_equal "uniqueness on an encrypted column (secret_note) is not supported", message
  end
  # Other columns are unaffected.
  assert probe.unique_value_taken?(:title, "locked", nil, nil, 0, false)
end

Cybertrain::Test.run!
