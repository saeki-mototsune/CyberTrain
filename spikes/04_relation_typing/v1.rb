# SPIKE (throwaway): does a base Relation + per-model PostRelation keep first as Post|nil under Spinel whole-program inference?

$db = {}
$db["posts"] = [
  {"id" => 1, "title" => "Hello", "body" => "first body", "views" => 10, "created_at" => Time.at(1700000000)},
  {"id" => 2, "title" => "World", "body" => nil, "views" => 3, "created_at" => Time.at(1700000100)},
  {"id" => 3, "title" => "Third", "body" => "b3", "views" => 0, "created_at" => Time.at(1700000200)}
]
$db["comments"] = [
  {"id" => 1, "post_id" => 1, "author" => "alice", "body" => "nice"},
  {"id" => 2, "post_id" => 1, "author" => nil, "body" => "anon"}
]
$db["tags"] = [
  {"id" => 1, "name" => "ruby"}
]

class Adapter
  # returns rows for table filtered by simple equality binds on column names
  def select(table, cols, binds, order, limit, offset)
    rows = $db[table]
    out = []
    rows.each do |r|
      ok = true
      i = 0
      while i < cols.size
        ok = false if r[cols[i]] != binds[i]
        i += 1
      end
      out << r if ok
    end
    out = out.sort_by { |r| r[order].to_s } if order
    out = out.drop(offset) if offset
    out = out.first(limit) if limit
    out
  end
end
$adapter = Adapter.new

class Model
  def self.table_name = "models"
end

class Relation
  attr_reader :table, :wheres, :binds, :cols
  def initialize(table)
    @table = table
    @wheres = []
    @cols = []
    @binds = []
    @order = nil
    @limit = nil
    @offset = nil
  end

  def add_where(hash)
    hash.each do |k, v|
      @wheres << "#{k} = ?"
      @cols << k.to_s
      @binds << v
    end
    self
  end

  def order(o)
    @order = o
    self
  end

  def limit(n)
    @limit = n
    self
  end

  def offset(n)
    @offset = n
    self
  end

  def to_sql
    sql = "SELECT * FROM #{@table}"
    sql += " WHERE " + @wheres.join(" AND ") unless @wheres.empty?
    sql += " ORDER BY #{@order}" if @order
    sql += " LIMIT #{@limit}" if @limit
    sql += " OFFSET #{@offset}" if @offset
    sql
  end

  def rows
    $adapter.select(@table, @cols, @binds, @order, @limit, @offset)
  end

  def count = rows.size
end

class Post < Model
  attr_accessor :id, :title, :body, :views, :created_at
  def self.table_name = "posts"

  def self.from_row(row)
    p = Post.new
    p.id = row["id"]
    p.title = row["title"]
    p.body = row["body"]
    p.views = row["views"]
    p.created_at = row["created_at"]
    p
  end

  def self.all = PostRelation.new("posts")
  def self.where(h) = PostRelation.new("posts").add_where(h)
  def self.find(id) = where(id: id).first
  def self.first = all.first
end

class PostRelation < Relation
  def to_a
    out = []
    rows.each { |r| out << Post.from_row(r) }
    out
  end
  def first = limit(1).to_a.first
  def each(&blk) = to_a.each(&blk)
  def find_by(h) = add_where(h).first
end

p1 = Post.where(title: "Hello", id: 1).order("id").limit(2).to_a.first
puts p1.title
puts p1.created_at.year
puts Post.where(title: "Hello", id: 1).to_sql
none = Post.where(title: "nope").first
puts none.nil?
Post.all.each { |p| puts "#{p.id} #{p.title} #{p.body.inspect} #{p.views + 1}" }
puts Post.find(2).title
