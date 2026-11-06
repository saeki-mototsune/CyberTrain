require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"

# includes / preload (spec section 8) on the compiled fixture models, loaded
# as test/gen_models_compiles.rb loads them: Post has_many :comments,
# Comment belongs_to :post. Every claim about queries is a delta of
# Connection#statements_run. test/associations.rb covers has_one and a
# nullable belongs_to in the generated shape. SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_app/db/schema"
require_relative "fixtures/gen_app/gen/models/comment"
require_relative "fixtures/gen_app/gen/models/post"
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

def comment_on(post, body)
  Comment.create(post_id: post.id, seen_on: "2026-10-05", commenter: "ann", body: body)
end

# Three posts: "A" with comments a1 and a2, "B" with b1, "C" with none.
def seed_posts
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM comments; DELETE FROM posts;") }
  a = Post.create(title: "A")
  b = Post.create(title: "B")
  Post.create(title: "C")
  comment_on(a, "a1")
  comment_on(a, "a2")
  comment_on(b, "b1")
  nil
end

test "statements_run counts every statement the connection runs" do
  before = statements
  Post.count
  Post.where(id: 1).to_a
  assert_equal 2, statements - before
end

test "Post.includes(:comments).to_a is two statements; size, first, last, each and to_a then run none" do
  seed_posts
  before = statements
  posts = Post.order(id: :asc).includes(:comments).to_a
  assert_equal 2, statements - before
  assert_equal ["A", "B", "C"], posts.map { |p| p.title }
  sizes = posts.map { |p| p.comments.size }
  firsts = posts.map { |p| p.comments.first.nil? ? "-" : p.comments.first.body }
  lasts = posts.map { |p| p.comments.last.nil? ? "-" : p.comments.last.body }
  bodies = Array.new(0) { "" }
  posts[0].comments.each { |c| bodies << c.body }
  empties = posts.map { |p| p.comments.empty? }
  arrays = posts.map { |p| p.comments.to_a.size }
  assert_equal 2, statements - before
  assert_equal [2, 1, 0], sizes
  assert_equal ["a1", "b1", "-"], firsts
  assert_equal ["a2", "b1", "-"], lasts
  assert_equal ["a1", "a2"], bodies
  assert_equal [false, false, true], empties
  assert_equal [2, 1, 0], arrays
end

test "preload is includes under another name; the class and relation both answer it" do
  seed_posts
  before = statements
  posts = Post.preload(:comments).to_a
  assert_equal 2, statements - before
  assert_equal 3, posts.map { |p| p.comments.size }.sum
  assert_equal 2, statements - before
  posts = Post.where(title: "A").preload(:comments).to_a
  assert_equal [2], posts.map { |p| p.comments.size }
  assert_equal 4, statements - before
end

test "count on a preloaded association runs SQL" do
  seed_posts
  post = Post.where(title: "A").includes(:comments).to_a[0]
  before = statements
  assert_equal 2, post.comments.count
  assert_equal 1, statements - before
  assert post.comments.exists?
  assert_equal 2, statements - before
end

test "a chain method on a preloaded association drops the preload and queries" do
  seed_posts
  post = Post.where(title: "A").includes(:comments).to_a[0]
  before = statements
  assert_equal ["a2"], post.comments.where(body: "a2").to_a.map { |c| c.body }
  assert_equal 1, statements - before
  assert_equal ["a2", "a1"], post.comments.order(id: :desc).to_a.map { |c| c.body }
  assert_equal 2, statements - before
  assert_equal 1, post.comments.limit(1).size
  assert_equal 3, statements - before
  # The record's own cache stays: the next plain read is from memory.
  assert_equal 2, post.comments.size
  assert_equal 3, statements - before
end

test "Comment.includes(:post) fills each comment's parent; a missing post answers nil without a query" do
  seed_posts
  orphan_post = Post.create(title: "Gone")
  orphan = comment_on(orphan_post, "orphan")
  pid = orphan_post.id
  Cybertrain::DB.with do |c|
    c.exec_script("PRAGMA foreign_keys=OFF")
    c.execute("DELETE FROM posts WHERE id = ?", [pid])
    c.exec_script("PRAGMA foreign_keys=ON")
  end
  before = statements
  comments = Comment.order(id: :asc).includes(:post).to_a
  assert_equal 2, statements - before
  titles = comments.map { |c| c.post.nil? ? "nil" : c.post.title }
  assert_equal ["A", "A", "B", "nil"], titles
  assert_equal 2, statements - before
  assert_equal orphan.id, comments[3].id
  # A reassigned key is not answered from the preload.
  comments[0].post_id = comments[2].post_id
  assert_equal "B", comments[0].post.title
  assert_equal 3, statements - before
end

test "includes of an unknown association raises ArgumentError" do
  assert_equal "unknown association nothing for Post", assert_raises("ArgumentError") { Post.includes(:nothing) }
  assert_equal "unknown association comments for Comment",
               assert_raises("ArgumentError") { Comment.where(id: 1).preload(:comments) }
end

test "includes with no names, or a name twice, changes nothing" do
  seed_posts
  before = statements
  assert_equal 3, Post.includes.to_a.size
  assert_equal 1, statements - before
  posts = Post.includes(:comments, :comments).to_a
  assert_equal 3, statements - before
  assert_equal 3, posts.map { |p| p.comments.size }.sum
  assert_equal 3, statements - before
end

test "an empty result runs only its own statement (Review Focus 4)" do
  seed_posts
  before = statements
  assert_equal 0, Post.where(id: -1).includes(:comments).to_a.size
  assert_equal 1, statements - before
end

test "includes leaves the other readers alone" do
  seed_posts
  before = statements
  assert_equal 3, Post.includes(:comments).count
  assert_equal ["A"], Post.includes(:comments).where(title: "A").pluck_str(:title)
  assert_equal 2, statements - before
end

test "read_association(:comments) on a preloaded post answers the Array without a statement" do
  seed_posts
  post = Post.where(title: "A").includes(:comments).to_a[0]
  before = statements
  found = post.read_association(:comments)
  assert_equal 0, statements - before
  assert_equal ["a1", "a2"], found.map { |c| c.body }
end

test "reload drops the preloaded comments" do
  seed_posts
  post = Post.where(title: "A").includes(:comments).to_a[0]
  comment_on(post, "a3")
  assert_equal 2, post.comments.size
  post.reload
  before = statements
  assert_equal 3, post.comments.size
  assert_equal 1, statements - before
end

Cybertrain::Test.run!
