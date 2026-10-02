require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/params"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Post/PostRelation and Comment/CommentRelation below are hand-written in
# exactly the shape the model generator (Task 11b) emits into gen/models/:
# this file is the executable specification of that shape.

# ---- gen/models/post.rb -------------------------------------------------

class PostRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
  def order(o) = (set_order(o); self)
  def order_sql(s) = (add_order_sql(s); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)

  def to_a
    out = Array.new(0) { Post.new }
    rows.each { |r| out << Post.from_row(r) }
    out
  end

  def each(&blk) = to_a.each(&blk)

  def first
    r = first_row
    return nil if r.nil?
    Post.from_row(r)
  end

  def last
    r = last_row
    return nil if r.nil?
    Post.from_row(r)
  end

  def find_by(h) = where(h).first

  def find(id)
    rec = where(id: id).first
    raise Cybertrain::RecordNotFound, "Couldn't find Post with id=#{id}" if rec.nil?
    rec
  end

  def size = count
end

class Post < Cybertrain::Model
  def self.table_name = "posts"
  def self.column_names = ["id", "title", "body", "created_at", "updated_at"]
  def model_name = "Post"

  attr_reader :title, :body, :created_at, :updated_at

  def title=(v)
    @title = Cybertrain::Cast.str(v)
    v
  end
  def body=(v)
    @body = Cybertrain::Cast.str_or_nil(v)
    v
  end
  def created_at=(v)
    @created_at = Cybertrain::Cast.time_or_nil(v)
    v
  end
  def updated_at=(v)
    @updated_at = Cybertrain::Cast.time_or_nil(v)
    v
  end

  def initialize(attrs = {})
    super()
    @title = ""
    @body = nil
    @created_at = nil
    @updated_at = nil
    assign_attributes(attrs)
  end

  def self.from_row(row)
    rec = Post.new
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @title = Cybertrain::Cast.str(row["title"])
    @body = Cybertrain::Cast.str_or_nil(row["body"])
    @created_at = Cybertrain::Cast.time_or_nil(row["created_at"])
    @updated_at = Cybertrain::Cast.time_or_nil(row["updated_at"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :body then @body
    when :created_at then @created_at
    when :updated_at then @updated_at
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :title then self.title = value
    when :body then self.body = value
    when :created_at then self.created_at = value
    when :updated_at then self.updated_at = value
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "title" => Cybertrain::Cast.to_sql(@title),
      "body" => Cybertrain::Cast.to_sql(@body),
      "created_at" => Cybertrain::Cast.to_sql(@created_at),
      "updated_at" => Cybertrain::Cast.to_sql(@updated_at)
    }
  end

  def self.all = PostRelation.new("posts")
  def self.where(h) = all.where(h)
  def self.order(o) = all.order(o)
  def self.limit(n) = all.limit(n)
  def self.find(id) = all.find(id)
  def self.find_by(h) = all.find_by(h)
  def self.first = all.first
  def self.last = all.last
  def self.count = all.count

  def self.create(attrs = {})
    rec = Post.new(attrs)
    rec.save
    rec
  end

  def comments = CommentRelation.new("comments").where(post_id: @id).to_a

  def read_association(name)
    case name
    when :comments then comments
    else nil
    end
  end

  def call_view_method(name)
    case name
    when :summary then summary
    else nil
    end
  end
end

# ---- gen/models/comment.rb ----------------------------------------------

class CommentRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
  def order(o) = (set_order(o); self)
  def order_sql(s) = (add_order_sql(s); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)

  def to_a
    out = Array.new(0) { Comment.new }
    rows.each { |r| out << Comment.from_row(r) }
    out
  end

  def each(&blk) = to_a.each(&blk)

  def first
    r = first_row
    return nil if r.nil?
    Comment.from_row(r)
  end

  def last
    r = last_row
    return nil if r.nil?
    Comment.from_row(r)
  end

  def find_by(h) = where(h).first

  def find(id)
    rec = where(id: id).first
    raise Cybertrain::RecordNotFound, "Couldn't find Comment with id=#{id}" if rec.nil?
    rec
  end

  def size = count
end

class Comment < Cybertrain::Model
  def self.table_name = "comments"
  def self.column_names = ["id", "post_id", "author", "body", "created_at", "updated_at"]
  def model_name = "Comment"

  attr_reader :post_id, :author, :body, :created_at, :updated_at

  def post_id=(v)
    @post_id = Cybertrain::Cast.int(v)
    v
  end
  def author=(v)
    @author = Cybertrain::Cast.str_or_nil(v)
    v
  end
  def body=(v)
    @body = Cybertrain::Cast.str(v)
    v
  end
  def created_at=(v)
    @created_at = Cybertrain::Cast.time_or_nil(v)
    v
  end
  def updated_at=(v)
    @updated_at = Cybertrain::Cast.time_or_nil(v)
    v
  end

  def initialize(attrs = {})
    super()
    @post_id = 0
    @author = nil
    @body = ""
    @created_at = nil
    @updated_at = nil
    assign_attributes(attrs)
  end

  def self.from_row(row)
    rec = Comment.new
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @post_id = Cybertrain::Cast.int(row["post_id"])
    @author = Cybertrain::Cast.str_or_nil(row["author"])
    @body = Cybertrain::Cast.str(row["body"])
    @created_at = Cybertrain::Cast.time_or_nil(row["created_at"])
    @updated_at = Cybertrain::Cast.time_or_nil(row["updated_at"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :post_id then @post_id
    when :author then @author
    when :body then @body
    when :created_at then @created_at
    when :updated_at then @updated_at
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :post_id then self.post_id = value
    when :author then self.author = value
    when :body then self.body = value
    when :created_at then self.created_at = value
    when :updated_at then self.updated_at = value
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "post_id" => Cybertrain::Cast.to_sql(@post_id),
      "author" => Cybertrain::Cast.to_sql(@author),
      "body" => Cybertrain::Cast.to_sql(@body),
      "created_at" => Cybertrain::Cast.to_sql(@created_at),
      "updated_at" => Cybertrain::Cast.to_sql(@updated_at)
    }
  end

  def self.all = CommentRelation.new("comments")
  def self.where(h) = all.where(h)
  def self.order(o) = all.order(o)
  def self.limit(n) = all.limit(n)
  def self.find(id) = all.find(id)
  def self.find_by(h) = all.find_by(h)
  def self.first = all.first
  def self.last = all.last
  def self.count = all.count

  def self.create(attrs = {})
    rec = Comment.new(attrs)
    rec.save
    rec
  end

  def post = Post.find_by(id: @post_id)

  def read_association(name)
    case name
    when :post then post
    else nil
    end
  end

  # No view methods in app/models/comment.rb: the generator emits a plain
  # stub, since `case` with no `when` does not parse.
  def call_view_method(name) = nil
end

# ---- gen/models/flag.rb -------------------------------------------------
# A table without timestamps whose columns cover the boolean and nullable
# float mappings, and a column named after an SQL keyword ("group"), which
# every generated INSERT/UPDATE/WHERE must quote.

class FlagRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
  def order(o) = (set_order(o); self)
  def order_sql(s) = (add_order_sql(s); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)

  def to_a
    out = Array.new(0) { Flag.new }
    rows.each { |r| out << Flag.from_row(r) }
    out
  end

  def each(&blk) = to_a.each(&blk)

  def first
    r = first_row
    return nil if r.nil?
    Flag.from_row(r)
  end

  def last
    r = last_row
    return nil if r.nil?
    Flag.from_row(r)
  end

  def find_by(h) = where(h).first

  def find(id)
    rec = where(id: id).first
    raise Cybertrain::RecordNotFound, "Couldn't find Flag with id=#{id}" if rec.nil?
    rec
  end

  def size = count
end

class Flag < Cybertrain::Model
  def self.table_name = "flags"
  def self.column_names = ["id", "active", "score", "group"]
  def model_name = "Flag"

  attr_reader :active, :score, :group

  def active=(v)
    @active = Cybertrain::Cast.bool(v)
    v
  end
  def score=(v)
    @score = Cybertrain::Cast.float_or_nil(v)
    v
  end
  def group=(v)
    @group = Cybertrain::Cast.str_or_nil(v)
    v
  end

  def initialize(attrs = {})
    super()
    @active = false
    @score = nil
    @group = nil
    assign_attributes(attrs)
  end

  def self.from_row(row)
    rec = Flag.new
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @active = Cybertrain::Cast.bool(row["active"])
    @score = Cybertrain::Cast.float_or_nil(row["score"])
    @group = Cybertrain::Cast.str_or_nil(row["group"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :active then @active
    when :score then @score
    when :group then @group
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :active then self.active = value
    when :score then self.score = value
    when :group then self.group = value
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "active" => Cybertrain::Cast.to_sql(@active),
      "score" => Cybertrain::Cast.to_sql(@score),
      "group" => Cybertrain::Cast.to_sql(@group)
    }
  end

  def self.all = FlagRelation.new("flags")
  def self.where(h) = all.where(h)
  def self.order(o) = all.order(o)
  def self.limit(n) = all.limit(n)
  def self.find(id) = all.find(id)
  def self.find_by(h) = all.find_by(h)
  def self.first = all.first
  def self.last = all.last
  def self.count = all.count

  def self.create(attrs = {})
    rec = Flag.new(attrs)
    rec.save
    rec
  end

  def read_association(name) = nil
  def call_view_method(name) = nil
end

# ---- app/models/post.rb (user code reopening the generated class) --------

CREATED_IDS = []
DESTROYED_IDS = []

class Post
  validates :title, presence: true, length: { minimum: 3, maximum: 40 }
  before_save { |r| r.title = r.title.strip }
  after_create { |r| CREATED_IDS << r.id }
  after_destroy { |r| DESTROYED_IDS << r.id }

  def summary = title[0, 3]
end

class Comment
  validates :body, presence: true
  validates :author, length: { maximum: 10 }, allow_blank: true
  before_save { |r| r.author = "anonymous" if r.author.nil? }
end

# ---- database -----------------------------------------------------------

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT, " \
    "created_at TEXT, updated_at TEXT);" \
    "CREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, " \
    "post_id INTEGER NOT NULL REFERENCES posts(id), author TEXT, body TEXT NOT NULL, " \
    "created_at TEXT, updated_at TEXT);" \
    "CREATE TABLE flags (id INTEGER PRIMARY KEY AUTOINCREMENT, active INTEGER NOT NULL DEFAULT 0, " \
    "score REAL, \"group\" TEXT);"
  )
end

def reset_tables
  Cybertrain::DB.with do |c|
    c.exec_script("DELETE FROM comments; DELETE FROM posts; DELETE FROM flags;")
  end
  CREATED_IDS.clear
  DESTROYED_IDS.clear
end

def fixed_time
  Time.utc(2026, 9, 24, 12, 30, 5)
end

# ---- Cast ---------------------------------------------------------------

test "Cast converts to non-null Integer, String and Float" do
  assert_equal 42, Cybertrain::Cast.int(42)
  assert_equal 42, Cybertrain::Cast.int("42")
  assert_equal 0, Cybertrain::Cast.int(nil)
  assert_equal 3, Cybertrain::Cast.int(3.9)
  assert_equal "7", Cybertrain::Cast.str(7)
  assert_equal "", Cybertrain::Cast.str(nil)
  assert_equal 1.5, Cybertrain::Cast.float("1.5")
  assert_equal 2.0, Cybertrain::Cast.float(2)
  assert_equal 0.0, Cybertrain::Cast.float(nil)
end

test "Cast nullable helpers keep nil and blank form input as nil" do
  assert_nil Cybertrain::Cast.int_or_nil(nil)
  assert_nil Cybertrain::Cast.int_or_nil("")
  assert_equal 5, Cybertrain::Cast.int_or_nil("5")
  assert_nil Cybertrain::Cast.str_or_nil(nil)
  assert_equal "x", Cybertrain::Cast.str_or_nil("x")
  assert_nil Cybertrain::Cast.float_or_nil(nil)
  assert_equal 0.25, Cybertrain::Cast.float_or_nil("0.25")
  assert_nil Cybertrain::Cast.bool_or_nil(nil)
  assert_equal true, Cybertrain::Cast.bool_or_nil(1)
end

test "Cast.bool accepts true/false, 1/0 and form strings" do
  assert_equal true, Cybertrain::Cast.bool(true)
  assert_equal false, Cybertrain::Cast.bool(false)
  assert_equal true, Cybertrain::Cast.bool(1)
  assert_equal false, Cybertrain::Cast.bool(0)
  assert_equal true, Cybertrain::Cast.bool("1")
  assert_equal false, Cybertrain::Cast.bool("0")
  assert_equal true, Cybertrain::Cast.bool("true")
  assert_equal false, Cybertrain::Cast.bool("false")
  assert_equal true, Cybertrain::Cast.bool("on")
  assert_equal false, Cybertrain::Cast.bool("")
  assert_equal false, Cybertrain::Cast.bool(nil)
end

test "Cast.time_or_nil parses both SQLite datetime formats" do
  t = Cybertrain::Cast.time_or_nil("2026-09-24T12:30:05Z")
  assert !t.nil?
  assert_equal "2026-09-24T12:30:05Z", Cybertrain::Cast.iso8601(t)
  t2 = Cybertrain::Cast.time_or_nil("2026-09-24 12:30:05")
  assert_equal "2026-09-24T12:30:05Z", Cybertrain::Cast.iso8601(t2)
  t3 = Cybertrain::Cast.time_or_nil(fixed_time)
  assert_equal "2026-09-24T12:30:05Z", Cybertrain::Cast.iso8601(t3)
  t4 = Cybertrain::Cast.time_or_nil(0)
  assert_equal "1970-01-01T00:00:00Z", Cybertrain::Cast.iso8601(t4)
  assert_nil Cybertrain::Cast.time_or_nil(nil)
  assert_nil Cybertrain::Cast.time_or_nil("")
  assert_nil Cybertrain::Cast.time_or_nil("yesterday")
end

test "Cast.time_or_nil returns nil for well-formed but out-of-range values" do
  assert_nil Cybertrain::Cast.time_or_nil("2026-13-01 00:00:00")
  assert_nil Cybertrain::Cast.time_or_nil("2026-00-10T00:00:00Z")
  assert_nil Cybertrain::Cast.time_or_nil("2026-01-00 00:00:00")
  assert_nil Cybertrain::Cast.time_or_nil("2026-01-32 00:00:00")
  assert_nil Cybertrain::Cast.time_or_nil("2026-02-29 00:00:00")
  assert_nil Cybertrain::Cast.time_or_nil("2026-04-31 00:00:00")
  assert_nil Cybertrain::Cast.time_or_nil("2026-01-01 24:00:00")
  assert_nil Cybertrain::Cast.time_or_nil("2026-01-01 23:60:00")
  assert_nil Cybertrain::Cast.time_or_nil("2026-01-01T23:59:60Z")
  assert_equal "2024-02-29T23:59:59Z", Cybertrain::Cast.iso8601(Cybertrain::Cast.time_or_nil("2024-02-29 23:59:59"))
  assert_equal "2026-12-31T00:00:00Z", Cybertrain::Cast.iso8601(Cybertrain::Cast.time_or_nil("2026-12-31T00:00:00Z"))
  post = Post.new(title: "Bad date", created_at: "2026-13-01 00:00:00")
  assert_nil post.created_at
end

test "Cast.to_sql turns Time and booleans into SQLite values" do
  assert_equal "2026-09-24T12:30:05Z", Cybertrain::Cast.to_sql(fixed_time)
  assert_equal 1, Cybertrain::Cast.to_sql(true)
  assert_equal 0, Cybertrain::Cast.to_sql(false)
  assert_equal 7, Cybertrain::Cast.to_sql(7)
  assert_equal "s", Cybertrain::Cast.to_sql("s")
  assert_nil Cybertrain::Cast.to_sql(nil)
end

# ---- Errors -------------------------------------------------------------

test "Errors collects messages per attribute in insertion order" do
  errors = Cybertrain::Errors.new
  assert errors.empty?
  refute errors.any?
  errors.add(:title, "can't be blank")
  errors.add(:post_id, "is invalid")
  errors.add(:title, "is too short (minimum is 3 characters)")
  assert errors.any?
  assert_equal 3, errors.count
  assert errors.key?(:title)
  refute errors.key?(:body)
  assert_equal [:title, :post_id], errors.keys
  assert_equal ["can't be blank", "is too short (minimum is 3 characters)"], errors[:title]
  assert_equal [], errors[:body]
  assert_equal ["Title can't be blank", "Title is too short (minimum is 3 characters)", "Post id is invalid"],
               errors.full_messages
  seen = []
  errors.each { |attr, message| seen << "#{attr}: #{message}" }
  assert_equal ["title: can't be blank", "title: is too short (minimum is 3 characters)", "post_id: is invalid"], seen
  errors.clear
  assert errors.empty?
  assert_equal 0, errors.count
end

# ---- Relation -----------------------------------------------------------

test "Relation builds SQL from where, order, limit and offset" do
  rel = Post.where(title: "Hello").where(body: nil).order("id DESC").limit(2).offset(4)
  assert_equal 'SELECT * FROM `posts` WHERE `title` = ? AND `body` IS NULL ORDER BY `id` DESC LIMIT 2 OFFSET 4', rel.to_sql
  assert_equal 1, rel.binds.size
  assert_equal 'SELECT * FROM `posts` WHERE `id` IN (?, ?)', Post.where(id: [3, 4]).to_sql
  assert_equal 'SELECT * FROM `posts` WHERE views > ?', Post.all.where_sql("views > ?", [3]).to_sql
  assert_equal 'SELECT * FROM `posts`', Post.all.to_sql
  assert_equal 'SELECT * FROM `flags` WHERE `group` = ?', Flag.where(group: "x").to_sql
  assert_equal '`a``b`', Cybertrain::Relation.quote_ident('a`b')
  assert_equal '`a"b`', Cybertrain::Relation.quote_ident('a"b')
end

test "order validates its columns and quotes them" do
  assert_equal 'SELECT * FROM `posts` ORDER BY `title`', Post.order("title").to_sql
  assert_equal 'SELECT * FROM `posts` ORDER BY `title` DESC, `id`', Post.order("title DESC, id").to_sql
  assert_equal 'SELECT * FROM `posts` ORDER BY `title` ASC, `id` DESC', Post.order("  title  asc ,id desc ").to_sql
  assert_equal 'SELECT * FROM `posts`', Post.order("").to_sql
  ["title; DROP TABLE posts", "title DESC; DROP", "lower(title)", "title, ", ",title", "title DESCX",
   "title DESC id", "1title", "posts.title", "title--"].each do |bad|
    message = assert_raises("ArgumentError") { Post.order(bad) }
    assert message.include?("order_sql"), "message for #{bad} should point to order_sql"
    assert message.include?("is not `column [ASC|DESC]`")
  end
  assert_equal "order: \"title; DROP TABLE posts\" is not `column [ASC|DESC]` (use order_sql for raw SQL)",
               assert_raises("ArgumentError") { Post.order("title; DROP TABLE posts") }
  # Raw ORDER BY is the explicit, separate door: the hand-written Post has no
  # order_sql, so reach it through the relation's base method.
  raw = PostRelation.new("posts")
  raw.add_order_sql("lower(title) DESC")
  assert_equal 'SELECT * FROM `posts` ORDER BY lower(title) DESC', raw.to_sql
end

test "reverse_order flips quoted order terms (used by last)" do
  reset_tables
  assert_equal "`title` ASC, `id` DESC", Cybertrain::Relation.reverse_order("`title` DESC, `id`")
  assert_equal "`a` DESC", Cybertrain::Relation.reverse_order("`a` ASC")
  ["Bravo", "Alpha", "Charlie"].each { |t| Post.create(title: t) }
  assert_equal "Alpha", Post.order("title DESC").last.title
  assert_equal "Charlie", Post.order("title").last.title
  assert_equal "Alpha", Post.order("title DESC, id").last.title
  assert_equal "Charlie", Post.order("title ASC").last.title
end

test "where with a Time value binds it as a single equality" do
  reset_tables
  t = Time.at(1_700_000_000)
  rel = Post.where(created_at: t)
  assert_equal 'SELECT * FROM `posts` WHERE `created_at` = ?', rel.to_sql
  assert_equal 1, rel.binds.size
  assert_equal Cybertrain::Cast.to_sql(t), rel.binds[0]
  assert_equal 0, rel.count
  post = Post.create(title: "Stamped")
  assert_equal 1, Post.where(created_at: post.created_at).count
end

test "delete_all respects limit and offset" do
  reset_tables
  ["Alpha", "Bravo", "Charlie"].each { |t| Post.create(title: t) }
  assert_equal 1, Post.limit(1).delete_all
  assert_equal 2, Post.count
  assert_equal ["Bravo", "Charlie"], Post.order("id").to_a.map { |p| p.title }

  reset_tables
  ["Alpha", "Bravo", "Charlie"].each { |t| Post.create(title: t) }
  assert_equal 2, Post.order("title DESC").limit(2).delete_all
  assert_equal ["Alpha"], Post.all.to_a.map { |p| p.title }

  reset_tables
  ["Alpha", "Bravo", "Charlie", "Delta"].each { |t| Post.create(title: t) }
  assert_equal 2, Post.where(body: nil).offset(1).limit(2).delete_all
  assert_equal ["Alpha", "Delta"], Post.order("id").to_a.map { |p| p.title }
  assert_equal 1, Post.where(title: "Delta").offset(0).limit(5).delete_all
  assert_equal 0, Post.where(title: "Alpha").limit(0).delete_all
  assert_equal 1, Post.where(title: "Alpha").offset(0).delete_all
  assert_equal 0, Post.count

  reset_tables
  ["Alpha", "Bravo", "Charlie"].each { |t| Post.create(title: t) }
  assert_equal 2, Post.all.offset(1).delete_all
  assert_equal ["Alpha"], Post.all.to_a.map { |p| p.title }
  assert_equal 1, Post.all.delete_all
end

test "count and size respect limit and offset" do
  reset_tables
  ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].each { |t| Post.create(title: t) }
  assert_equal 5, Post.count
  assert_equal 2, Post.limit(2).count
  assert_equal 2, Post.limit(2).size
  assert_equal 3, Post.order("title DESC").limit(3).size
  assert_equal 2, Post.all.offset(3).count
  assert_equal 0, Post.all.offset(5).count
  assert_equal 1, Post.limit(10).offset(4).count
  assert_equal 0, Post.limit(0).count
  assert_equal 2, Post.where(body: nil).where_sql("title > ?", ["B"]).limit(2).count
end

test "exists? respects offset and limit" do
  reset_tables
  ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].each { |t| Post.create(title: t) }
  assert Post.all.offset(4).exists?
  refute Post.all.offset(5).exists?
  refute Post.limit(0).exists?
  assert Post.limit(1).offset(2).exists?
end

test "first and last pick from the limit/offset window" do
  reset_tables
  ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].each { |t| Post.create(title: t) }
  assert_equal "Bravo", Post.all.offset(1).first.title
  assert_equal "Echo", Post.all.offset(1).last.title
  assert_nil Post.all.offset(5).last
  assert_nil Post.all.offset(5).first
  assert_equal "Charlie", Post.order("id").limit(3).last.title
  assert_equal "Delta", Post.order("title DESC").limit(2).last.title
  assert_equal "Charlie", Post.order("id").limit(2).offset(1).last.title
  assert_nil Post.limit(0).first
  assert_nil Post.limit(0).last
end

# ---- Model --------------------------------------------------------------

test "Post.new(title: ...).save inserts and sets id and created_at" do
  reset_tables
  post = Post.new(title: "Hello world")
  assert post.new_record?
  refute post.persisted?
  assert_equal 0, post.id
  assert_nil post.created_at
  assert post.save
  assert post.persisted?
  refute post.new_record?
  assert post.id > 0
  refute post.created_at.nil?
  refute post.updated_at.nil?
  assert_equal 1, Post.count
end

test "Post.find(id) returns a typed record" do
  reset_tables
  created = Post.create(title: "Typed", body: "some body")
  post = Post.find(created.id)
  assert_equal "Post", post.class.name
  assert_equal "TYPED", post.title.upcase
  assert_equal 9, post.body.size
  assert_equal created.id + 1, post.id + 1
  assert post.persisted?
end

test "Post.find(999) raises RecordNotFound with a message" do
  reset_tables
  message = assert_raises("RecordNotFound") { Post.find(999) }
  assert_equal "Couldn't find Post with id=999", message
end

test "where chains order, limit and offset" do
  reset_tables
  ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].each { |t| Post.create(title: t) }
  titles = []
  Post.where(body: nil).order("title DESC").limit(2).offset(1).each { |p| titles << p.title }
  assert_equal ["Delta", "Charlie"], titles
  assert_equal ["Bravo"], Post.where(title: "Bravo").to_a.map { |p| p.title }
  assert_equal 2, Post.where(title: ["Alpha", "Echo"]).count
  assert_equal "Alpha", Post.first.title
  assert_equal "Echo", Post.last.title
  assert_equal "Alpha", Post.order("title DESC").last.title
  assert_equal "Charlie", Post.find_by(title: "Charlie").title
  assert_equal 5, Post.all.size
  assert_equal 3, Post.all.where_sql("title > ?", ["Bz"]).count
end

test "first on an empty relation is nil" do
  reset_tables
  assert_nil Post.first
  assert_nil Post.last
  assert_nil Post.where(title: "nope").first
  assert_nil Post.find_by(title: "nope")
  assert_equal 0, Post.all.to_a.size
end

test "count and exists?" do
  reset_tables
  refute Post.all.exists?
  assert_equal 0, Post.count
  Post.create(title: "One")
  Post.create(title: "Two")
  assert Post.all.exists?
  assert Post.where(title: "Two").exists?
  refute Post.where(title: "Three").exists?
  assert_equal 2, Post.count
  assert_equal 1, Post.where(title: "One").count
  assert_equal 1, Post.where(title: "One").delete_all
  assert_equal 1, Post.count
end

test "validations: save returns false and fills errors.full_messages" do
  reset_tables
  post = Post.new(title: "")
  refute post.valid?
  refute post.save
  assert post.new_record?
  assert_equal ["Title can't be blank", "Title is too short (minimum is 3 characters)"], post.errors.full_messages
  post.title = "ab"
  refute post.save
  assert_equal ["Title is too short (minimum is 3 characters)"], post.errors.full_messages
  post.title = "x" * 41
  refute post.save
  assert_equal ["Title is too long (maximum is 40 characters)"], post.errors.full_messages
  post.title = "Just right"
  assert post.save
  assert post.errors.empty?
  assert_equal 1, Post.count
  comment = Comment.new(post_id: post.id)
  refute comment.save
  assert_equal ["Body can't be blank"], comment.errors.full_messages
  comment.body = "text"
  comment.author = "a" * 11
  refute comment.save
  assert_equal ["Author is too long (maximum is 10 characters)"], comment.errors.full_messages
  assert_equal ["is too long (maximum is 10 characters)"], comment.errors[:author]
  comment.author = ""
  assert comment.save
  assert_equal "", Comment.find(comment.id).author
end

test "save! raises RecordInvalid" do
  reset_tables
  post = Post.new(title: "no")
  message = assert_raises("RecordInvalid") { post.save! }
  assert_equal "Validation failed: Title is too short (minimum is 3 characters)", message
  assert_equal 0, Post.count
  ok = Post.new(title: "Fine title")
  ok.save!
  assert ok.persisted?
end

test "update" do
  reset_tables
  post = Post.create(title: "Before", body: "old")
  assert post.update(title: "After", body: nil, not_a_column: 1)
  found = Post.find(post.id)
  assert_equal "After", found.title
  assert_nil found.body
  refute post.update(title: "")
  assert_equal "After", Post.find(post.id).title
  assert_equal 1, Post.count
end

test "destroy" do
  reset_tables
  post = Post.create(title: "Doomed")
  keep = Post.create(title: "Keeper")
  assert post.destroy
  refute post.persisted?
  assert_equal 1, Post.count
  assert_nil Post.find_by(id: post.id)
  assert_equal keep.id, Post.first.id
  assert_equal [post.id], DESTROYED_IDS
end

test "destroy on a new record deletes nothing and returns false" do
  reset_tables
  Post.create(title: "Survivor")
  fresh = Post.new(title: "Never saved")
  refute fresh.destroy
  assert fresh.new_record?
  assert_equal 1, Post.count
  assert_equal [], DESTROYED_IDS
end

test "reload" do
  reset_tables
  post = Post.create(title: "Original")
  Cybertrain::DB.with do |c|
    c.execute("UPDATE posts SET title = ?, body = ? WHERE id = ?", ["Changed", "from sql", post.id])
  end
  assert_equal "Original", post.title
  assert_equal "Changed", post.reload.title
  assert_equal "from sql", post.body
  gone = Post.create(title: "Vanishing")
  Post.where(id: gone.id).delete_all
  assert_raises("RecordNotFound") { gone.reload }
end

test "before_save callback runs" do
  reset_tables
  post = Post.create(title: "   padded title   ")
  assert_equal "padded title", post.title
  assert_equal "padded title", Post.find(post.id).title
  comment = Comment.create(post_id: post.id, body: "hi")
  assert_equal "anonymous", comment.author
  named = Comment.create(post_id: post.id, body: "yo", author: "alice")
  assert_equal "alice", named.author
end

test "after_create runs once" do
  reset_tables
  post = Post.create(title: "Counted")
  assert_equal [post.id], CREATED_IDS
  post.title = "Counted again"
  post.save
  post.update(body: "more")
  assert_equal [post.id], CREATED_IDS
  Post.new(title: "").save
  assert_equal 1, CREATED_IDS.size
end

test "comments association through comments.post_id" do
  reset_tables
  post = Post.create(title: "With comments")
  other = Post.create(title: "Other post")
  Comment.create(post_id: post.id, body: "first", author: "alice")
  Comment.create(post_id: other.id, body: "elsewhere")
  Comment.create(post_id: post.id, body: "second", author: "bob")
  bodies = post.comments.map { |c| c.body }
  assert_equal ["first", "second"], bodies
  assert_equal 2, Comment.where(post_id: post.id).count
  comment = Comment.find_by(body: "second")
  assert_equal "With comments", comment.post.title
  assert_equal 0, other.comments.size - 1
end

test "read_association and call_view_method dispatch by name" do
  reset_tables
  post = Post.create(title: "Dispatch")
  Comment.create(post_id: post.id, body: "c1")
  assoc = post.read_association(:comments)
  count = case assoc
          when Array then assoc.size
          else -1
          end
  assert_equal 1, count
  assert_nil post.read_association(:nope)
  assert_equal "Dis", post.call_view_method(:summary)
  assert_nil post.call_view_method(:nope)
  assert_equal "Dispatch", post.read_attribute(:title)
  assert_nil post.read_attribute(:nope)
  comment = Comment.find_by(post_id: post.id)
  assert_equal "Dispatch", comment.read_association(:post).title
  assert_nil comment.call_view_method(:summary)
end

test "to_json exact string" do
  reset_tables
  post = Post.create(title: "JSON \"quoted\"", created_at: fixed_time, updated_at: fixed_time)
  expected = "{\"id\":#{post.id},\"title\":\"JSON \\\"quoted\\\"\",\"body\":null," \
             "\"created_at\":\"2026-09-24T12:30:05Z\",\"updated_at\":\"2026-09-24T12:30:05Z\"}"
  assert_equal expected, post.to_json
  attrs = post.attributes
  assert_equal ["id", "title", "body", "created_at", "updated_at"], attrs.keys
  assert_equal post.id, attrs["id"]
end

test "to_json keeps booleans as true/false and floats as numbers" do
  reset_tables
  on = Flag.create(active: true, score: 2.5)
  off = Flag.create(active: "0", group: "staff")
  assert_equal "{\"id\":#{on.id},\"active\":true,\"score\":2.5,\"group\":null}", on.to_json
  assert_equal "{\"id\":#{off.id},\"active\":false,\"score\":null,\"group\":\"staff\"}", off.to_json
  assert_equal "{\"id\":#{off.id},\"active\":false,\"score\":null,\"group\":\"staff\"}", Flag.find(off.id).to_json
end

test "columns named after SQL keywords are quoted" do
  reset_tables
  flag = Flag.create(active: true, group: "admins")
  assert flag.persisted?
  assert_equal "admins", Flag.find(flag.id).group
  flag.group = "staff"
  assert flag.save
  assert_equal 1, Flag.where(group: "staff").count
  assert_equal 0, Flag.where(group: "admins").count
  assert_equal 1, Flag.where(group: ["staff", "x"]).count
  assert_equal 0, Flag.where(group: nil).count
  assert Flag.where(active: true).exists?
  Cybertrain::DB.with do |c|
    c.execute("UPDATE flags SET \"group\" = ? WHERE id = ?", ["ops", flag.id])
  end
  assert_equal "ops", flag.reload.group
  assert_equal 1, Flag.where(group: "ops").delete_all
  other = Flag.create(group: "tmp")
  assert other.destroy
  assert_equal 0, Flag.count
end

test "==" do
  reset_tables
  post = Post.create(title: "Equal")
  same = Post.find(post.id)
  other = Post.create(title: "Different")
  assert post == same
  refute post == other
  refute Post.new(title: "New one") == Post.new(title: "New one")
  comment = Comment.create(post_id: post.id, body: "c")
  refute post == comment
end

test "to_param" do
  reset_tables
  post = Post.create(title: "Param")
  assert_equal post.id.to_s, post.to_param
  assert_equal "0", Post.new.to_param
end

test "nullable body round trips nil and String" do
  reset_tables
  with_nil = Post.create(title: "No body")
  with_text = Post.create(title: "Has body", body: "Grüße, 世界")
  assert_nil Post.find(with_nil.id).body
  assert_equal "Grüße, 世界", Post.find(with_text.id).body
  assert_equal 1, Post.where(body: nil).count
end

test "created_at is a Time after reload" do
  reset_tables
  post = Post.create(title: "Timestamps", created_at: fixed_time)
  post.reload
  created = post.created_at
  assert_equal "Time", created.class.name
  assert_equal 2026, created.year
  assert_equal "2026-09-24T12:30:05Z", Cybertrain::Cast.iso8601(created)
  refute post.updated_at.nil?
  assert post.updated_at.year >= 2026
end

test "assign_attributes with String keys from Params#permit" do
  reset_tables
  params = Cybertrain::Params.new
  params.set_value("title", "From the form")
  params.set_value("body", "posted body")
  params.set_value("admin", "true")
  post = Post.new(params.permit(:title, :body))
  assert_equal "From the form", post.title
  assert_equal "posted body", post.body
  assert post.save
  edit = Cybertrain::Params.new
  edit.set_value("title", "Edited title")
  assert post.update(edit.permit(:title, :body))
  assert_equal "Edited title", Post.find(post.id).title
  assert_equal "posted body", Post.find(post.id).body
end

Cybertrain::Test.run!
