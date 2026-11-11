require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/encryptor"

# Relation#dup (issue #188, design D72) on the compiled fixture models,
# loaded as test/includes.rb loads them: a copy of the same generated class
# that shares no chain state with its source, in either direction. One test
# per piece of state a Relation holds (cybertrain/relation.rb#initialize:
# @wheres and @binds, @order, @limit, @offset, @distinct, @none, @having
# and @having_binds, @includes, @records_preloaded; the subclass's
# @preloaded). SQLite is FFI, so the snapshot comes from the compiled
# binary (spikes/NOTES.md rule 23).
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
    table.foreign_keys.each do |fk|
      parts << "FOREIGN KEY (\"#{fk.column}\") REFERENCES \"#{fk.to_table}\"(id)"
    end
    sql << "CREATE TABLE \"#{table.name}\" (#{parts.join(", ")});"
  end
  sql
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.exec_script(create_tables_sql(Cybertrain::Schema.current)) }

def statements = Cybertrain::DB.with { |c| c.statements_run }

# Posts A (views 1), B (views 2), C (views 3), D (views 3); A has comments
# a1 and a2, B has b1.
def seed_posts
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM comments; DELETE FROM posts;") }
  a = Post.create(title: "A", views: 1)
  b = Post.create(title: "B", views: 2)
  Post.create(title: "C", views: 3)
  Post.create(title: "D", views: 3)
  Comment.create(post_id: a.id, seen_on: "2026-10-05", commenter: "ann", body: "a1")
  Comment.create(post_id: a.id, seen_on: "2026-10-05", commenter: "ann", body: "a2")
  Comment.create(post_id: b.id, seen_on: "2026-10-05", commenter: "bob", body: "b1")
  nil
end

def titles(rel) = rel.to_a.map { |p| p.title }

test "without dup the chain methods change the receiver (the documented behaviour, unchanged)" do
  seed_posts
  base = Post.where("views >= ?", 2)
  same = base.order(title: :desc).limit(1)
  assert_equal ["D"], titles(same)
  assert_equal ["D"], titles(base)
  assert_equal base.to_sql, same.to_sql
end

test "queries branched from one base with dup do not affect each other or the base" do
  seed_posts
  base = Post.where("views >= ?", 2).order(title: :asc)
  base_sql = base.to_sql
  top = base.dup.where(views: 3).limit(1)
  rest = base.dup.where.not(title: "D").order(title: :desc)
  assert_equal ["C"], titles(top)
  assert_equal ["C", "B"], titles(rest)
  assert_equal ["B", "C", "D"], titles(base)
  assert_equal base_sql, base.to_sql
  assert_equal 1, base.binds.size
  assert_equal 2, top.binds.size
  assert_equal 2, rest.binds.size
end

test "a copy is unaffected by what the source does afterwards" do
  seed_posts
  base = Post.where(views: 3)
  copy = base.dup
  copy_sql = copy.to_sql
  base.where(title: "C").order(title: :desc).limit(1).offset(0).distinct
  assert_equal copy_sql, copy.to_sql
  assert_equal 1, copy.binds.size
  assert_equal ["C", "D"], titles(copy.order(title: :asc))
  assert_equal ["C"], titles(base)
end

test "dup is lazy and answers the model's own relation: records, scopes and chain methods stay typed" do
  seed_posts
  base = Post.where("views >= ?", 2)
  before = statements
  copy = base.dup
  chained = base.dup.min_views(3).order(title: :asc)
  assert_equal 0, statements - before
  first = copy.dup.order(title: :asc).first
  assert_equal "B", first.nil? ? "-" : first.title
  assert_equal "B", copy.dup.find_by!(title: "B").title
  assert_equal ["C", "D"], chained.to_a.map { |p| p.title }
  assert_equal 3, copy.count
  assert_equal 2, base.dup.dup.where(views: 3).size
end

test "where terms and binds are copied: Hash, Array, Range, nil, where.not, where_sql, where_like, where_between" do
  seed_posts
  base = Post.where(views: [2, 3]).where(views: 1..3).where(body: nil).where.not(title: "B")
  base.where_sql("views > ?", [0]).where_like(:title, "C").where_between(:views, 3, nil)
  copy = base.dup
  assert_equal base.to_sql, copy.to_sql
  assert_equal base.binds.size, copy.binds.size
  assert_equal 8, copy.binds.size
  assert_equal ["C"], titles(copy)
  copy.where(title: "nope")
  assert_equal 9, copy.binds.size
  assert_equal 8, base.binds.size
  assert_equal ["C"], titles(base)
  assert_equal 0, copy.count
end

test "or on a copy leaves the source's terms and binds alone, and a copy can be the other side" do
  seed_posts
  base = Post.where(title: "A")
  either = base.dup.or(Post.where(title: "B"))
  assert_equal ["A", "B"], titles(either.order(title: :asc))
  assert_equal ["A"], titles(base)
  assert_equal 1, base.binds.size
  both = base.or(base.dup.where(views: 1))
  assert_equal ["A"], titles(both)
  assert_equal 3, both.binds.size
end

test "order, order_sql, limit and offset are copied and then independent" do
  seed_posts
  base = Post.order(title: :desc).limit(2).offset(1)
  copy = base.dup
  assert_equal base.to_sql, copy.to_sql
  assert_equal ["C", "B"], titles(copy)
  copy.order_sql("views DESC, title ASC").limit(1).offset(0)
  assert_equal ["C"], titles(copy)
  assert_equal ["C", "B"], titles(base)
  raw = Post.order_sql("lower(title) DESC")
  kept = raw.dup
  raw.order("title")
  assert_equal ["D", "C", "B", "A"], titles(kept)
  assert_equal ["A", "B", "C", "D"], titles(raw)
end

test "distinct and none are copied and then independent" do
  seed_posts
  plain = Post.where("views >= ?", 3)
  distinct = plain.dup.distinct
  assert_equal [3], distinct.pluck_int(:views)
  assert_equal [3, 3], plain.pluck_int(:views)
  assert_equal [3], distinct.dup.pluck_int(:views)
  empty = plain.dup.none
  assert_equal 0, empty.count
  assert_equal 0, empty.dup.to_a.size
  assert_equal 2, plain.count
end

test "having_sql and its binds are copied and then independent" do
  seed_posts
  base = Post.where("views >= ?", 1).having_sql("COUNT(*) > ?", [1])
  copy = base.dup
  assert_equal({ "3" => 2 }, copy.count_by(:views))
  copy.having_sql("COUNT(*) > ?", [5])
  assert_equal({ "3" => 2 }, base.count_by(:views))
  assert copy.count_by(:views).empty?
  plain = Post.where("views >= ?", 1)
  grouped = plain.dup.having_sql("COUNT(*) = ?", [1])
  assert_equal 2, grouped.count_by(:views).size
  assert_equal 4, plain.count
end

test "includes names are copied and then independent" do
  seed_posts
  base = Post.order(title: :asc)
  with = base.dup.includes(:comments)
  before = statements
  loaded = with.dup.to_a
  assert_equal 2, statements - before
  assert_equal [2, 1, 0, 0], loaded.map { |p| p.comments.size }
  assert_equal 2, statements - before
  # The base never took the include: one statement, then one per reader.
  plain = base.to_a
  assert_equal 3, statements - before
  assert_equal 2, plain[0].comments.size
  assert_equal 4, statements - before
  # Nor does an include added to the source after the copy reach the copy.
  copy = base.dup
  base.includes(:comments)
  before = statements
  copy.to_a
  assert_equal 1, statements - before
end

test "page windows the copy it is called on, not the source" do
  seed_posts
  base = Post.order(title: :asc)
  paged = base.dup
  paged.page(2, per: 3)
  assert_equal ["D"], titles(paged)
  assert_equal ["A", "B", "C", "D"], titles(base)
  assert_equal ["D"], titles(paged.dup)
end

test "a copy keeps the table its source was built for, not the schema's" do
  archived = PostRelation.new("archived_posts").where(views: 1)
  copy = archived.dup
  assert_includes archived.to_sql, "archived_posts"
  assert_equal archived.to_sql, copy.to_sql
end

test "a copy of a preloaded association answers from its own Array of the same records" do
  seed_posts
  post = Post.where(title: "A").includes(:comments).to_a[0]
  before = statements
  comments = post.comments
  copy = comments.dup
  assert_equal 2, copy.size
  assert_equal ["a1", "a2"], copy.to_a.map { |c| c.body }
  first = copy.first
  assert_equal "a1", first.nil? ? "-" : first.body
  assert_equal 0, statements - before
  # A chain method on the copy drops the copy's preload only.
  assert_equal ["a2"], copy.where(body: "a2").to_a.map { |c| c.body }
  assert_equal 1, statements - before
  assert_equal 2, comments.size
  assert_equal 2, post.comments.size
  assert_equal 1, statements - before
  # And one on the source leaves a copy taken before it preloaded.
  kept = comments.dup
  comments.limit(1)
  assert_equal 2, kept.size
  assert_equal 1, statements - before
  assert_equal 1, comments.size
  assert_equal 2, statements - before
end

Cybertrain::Test.run!
