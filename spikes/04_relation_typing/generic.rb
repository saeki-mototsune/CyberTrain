# SPIKE (throwaway): does a single generic Relation (first -> Model union) work, with callers doing 'case rec when Post', vs per-model relations?

# ---- fake DB: Array<Hash<String, poly>> ----
$db = {}
$db["posts"] = [
  {"id" => 1, "title" => "Hello", "body" => "first body", "views" => 10, "created_at" => Time.at(1700000000)},
  {"id" => 2, "title" => "World", "body" => nil, "views" => 3, "created_at" => nil},
  {"id" => 3, "title" => "Third", "body" => "b3", "views" => 0, "created_at" => Time.at(1700000200)}
]
$db["comments"] = [
  {"id" => 1, "post_id" => 1, "author" => "alice", "body" => "nice"},
  {"id" => 2, "post_id" => 1, "author" => nil, "body" => "anon"},
  {"id" => 3, "post_id" => 3, "author" => "bob", "body" => "hmm"}
]
$db["tags"] = [
  {"id" => 1, "name" => "ruby", "weight" => 1.5},
  {"id" => 2, "name" => "spinel", "weight" => nil}
]

class Adapter
  def select(table, cols, binds, order, limit, offset)
    out = []
    $db[table].each do |r|
      ok = true
      i = 0
      while i < cols.size
        ok = false if r[cols[i]] != binds[i]
        i += 1
      end
      out << r if ok
    end
    out = out.sort_by { |r| r[order].to_s } if order != ""
    out = out.drop(offset) if offset > 0
    out = out.first(limit) if limit >= 0
    out
  end
end
$adapter = Adapter.new

# ---- casts: poly -> concrete (generated from schema types) ----
module Cast
  def self.int(v) = v.is_a?(Integer) ? v : 0
  def self.int_or_nil(v) = v.is_a?(Integer) ? v : nil
  def self.str(v) = v.nil? ? "" : v.to_s
  def self.str_or_nil(v) = v.nil? ? nil : v.to_s
  def self.time_or_nil(v) = v.is_a?(Time) ? v : nil
  def self.float_or_nil(v) = v.is_a?(Float) ? v : nil
end

# ---- validations as data ----
class Validator
  attr_reader :attr, :kind, :min
  def initialize(attr, kind, min)
    @attr = attr
    @kind = kind
    @min = min
  end
end

class Errors
  def initialize
    @h = {}
  end
  def add(attr, msg)
    @h[attr] = [] unless @h.key?(attr)
    @h[attr] << msg
  end
  def [](attr) = @h.key?(attr) ? @h[attr] : []
  def any? = !@h.empty?
  def count
    n = 0
    @h.each { |k, v| n += v.size }
    n
  end
  def full_messages
    out = []
    @h.each { |k, v| v.each { |m| out << "#{k.to_s.capitalize} #{m}" } }
    out
  end
  def clear = @h.clear
end

class Model
  def self.table_name = "models"
  def read_attribute(name) = nil
  def run_before_save = nil

  # validates :title, presence: true, length: {minimum: 3}   (mixed-value options Hash)
  def self.validates(attr, opts)
    list = validators
    list << Validator.new(attr, :presence, 0) if opts[:presence] == true
    len = opts[:length]
    if len.is_a?(Hash)
      mn = len[:minimum]
      list << Validator.new(attr, :length, mn) if mn.is_a?(Integer)
    end
  end


  def errors
    @errors ||= Errors.new
  end

  def valid?
    errors.clear
    model_validators.each do |v|
      val = read_attribute(v.attr)
      if v.kind == :presence
        errors.add(v.attr, "can't be blank") if val.nil? || val.to_s.empty?
      elsif v.kind == :length
        errors.add(v.attr, "is too short (minimum is #{v.min} characters)") if val.to_s.size < v.min
      end
    end
    !errors.any?
  end

  def save
    run_before_save
    return false unless valid?
    true
  end
end

class Relation
  attr_reader :table, :wheres, :binds, :cols
  def initialize(table)
    @table = table
    @wheres = []
    @cols = []
    @binds = []
    @order = ""
    @limit = -1
    @offset = 0
  end

  def add_where(hash)
    hash.each do |k, v|
      @wheres << "#{k} = ?"
      @cols << k.to_s
      @binds << v
    end
    nil
  end
  def set_order(o) = (@order = o; nil)
  def set_limit(n) = (@limit = n; nil)
  def set_offset(n) = (@offset = n; nil)

  def to_sql
    sql = "SELECT * FROM #{@table}"
    sql += " WHERE " + @wheres.join(" AND ") unless @wheres.empty?
    sql += " ORDER BY #{@order}" if @order != ""
    sql += " LIMIT #{@limit}" if @limit >= 0
    sql += " OFFSET #{@offset}" if @offset > 0
    sql
  end

  def rows = $adapter.select(@table, @cols, @binds, @order, @limit, @offset)
  def count = rows.size
  def exists? = count > 0
end

# ================= generated: Post =================
class Post < Model
  attr_accessor :id, :title, :body, :views, :created_at
  VALIDATORS = []
  BEFORE_SAVE = []
  def self.validators = VALIDATORS
  def self.before_save_callbacks = BEFORE_SAVE
  def model_validators = VALIDATORS
  def model_before_save = BEFORE_SAVE
  def self.table_name = "posts"
  def self.before_save(&blk) = (BEFORE_SAVE << blk; nil)
  def run_before_save = BEFORE_SAVE.each { |cb| cb.call(self) }

  def initialize
    @id = 0
    @title = ""
    @body = nil
    @views = 0
    @created_at = nil
  end

  def self.from_row(row)
    m = Post.new
    m.id = Cast.int(row["id"])
    m.title = Cast.str(row["title"])
    m.body = Cast.str_or_nil(row["body"])
    m.views = Cast.int(row["views"])
    m.created_at = Cast.time_or_nil(row["created_at"])
    m
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :body then @body
    when :views then @views
    when :created_at then @created_at
    else nil
    end
  end

  def assign_attributes(h)
    h.each do |k, v|
      case k
      when :title then @title = Cast.str(v)
      when :body then @body = Cast.str_or_nil(v)
      when :views then @views = Cast.int(v)
      end
    end
    self
  end

  def self.all = PostRelation.new("posts")
  def self.where(h) = PostRelation.new("posts").where(h)
  def self.find(id) = where(id: id).first
  def self.first = all.first

  # user code (app/models/post.rb)
  validates :title, presence: true, length: {minimum: 3}
  before_save { |r| r.title = r.title.strip }
end

class PostRelation < Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)
  def to_a
    out = []
    rows.each { |r| out << Post.from_row(r) }
    out
  end
  def first = limit(1).to_a.first
  def each(&blk) = to_a.each(&blk)
  def find_by(h) = where(h).first
end

# ================= generated: Comment =================
class Comment < Model
  attr_accessor :id, :post_id, :author, :body
  VALIDATORS = []
  BEFORE_SAVE = []
  def self.validators = VALIDATORS
  def self.before_save_callbacks = BEFORE_SAVE
  def model_validators = VALIDATORS
  def model_before_save = BEFORE_SAVE
  def self.table_name = "comments"
  def self.before_save(&blk) = (BEFORE_SAVE << blk; nil)
  def run_before_save = BEFORE_SAVE.each { |cb| cb.call(self) }

  def initialize
    @id = 0
    @post_id = 0
    @author = nil
    @body = ""
  end

  def self.from_row(row)
    m = Comment.new
    m.id = Cast.int(row["id"])
    m.post_id = Cast.int(row["post_id"])
    m.author = Cast.str_or_nil(row["author"])
    m.body = Cast.str(row["body"])
    m
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :post_id then @post_id
    when :author then @author
    when :body then @body
    else nil
    end
  end

  def post = Post.find(@post_id)
  def self.all = CommentRelation.new("comments")
  def self.where(h) = CommentRelation.new("comments").where(h)
  def self.find(id) = where(id: id).first
  def self.first = all.first

  validates :body, presence: true
  before_save { |r| r.author = "anonymous" if r.author.nil? }
end

class CommentRelation < Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)
  def to_a
    out = []
    rows.each { |r| out << Comment.from_row(r) }
    out
  end
  def first = limit(1).to_a.first
  def each(&blk) = to_a.each(&blk)
  def find_by(h) = where(h).first
end

# ================= generated: Tag =================
class Tag < Model
  attr_accessor :id, :name, :weight
  VALIDATORS = []
  BEFORE_SAVE = []
  def self.validators = VALIDATORS
  def self.before_save_callbacks = BEFORE_SAVE
  def model_validators = VALIDATORS
  def model_before_save = BEFORE_SAVE
  def self.table_name = "tags"
  def self.before_save(&blk) = (BEFORE_SAVE << blk; nil)
  def run_before_save = BEFORE_SAVE.each { |cb| cb.call(self) }

  def initialize
    @id = 0
    @name = ""
    @weight = nil
  end

  def self.from_row(row)
    m = Tag.new
    m.id = Cast.int(row["id"])
    m.name = Cast.str(row["name"])
    m.weight = Cast.float_or_nil(row["weight"])
    m
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    when :weight then @weight
    else nil
    end
  end

  def self.all = TagRelation.new("tags")
  def self.where(h) = TagRelation.new("tags").where(h)
  def self.find(id) = where(id: id).first
  def self.first = all.first
end

class TagRelation < Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)
  def limit(n) = (set_limit(n); self)
  def offset(n) = (set_offset(n); self)
  def to_a
    out = []
    rows.each { |r| out << Tag.from_row(r) }
    out
  end
  def first = limit(1).to_a.first
  def each(&blk) = to_a.each(&blk)
  def find_by(h) = where(h).first
end

class GenericRelation < Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)
  def limit(n) = (set_limit(n); self)
  def build(r)
    case @table
    when "posts" then Post.from_row(r)
    when "comments" then Comment.from_row(r)
    else Tag.from_row(r)
    end
  end
  def to_a
    out = []
    rows.each { |r| out << build(r) }
    out
  end
  def first = limit(1).to_a.first
  def each(&blk) = to_a.each(&blk)
end

def describe(rec)
  case rec
  when Post then "Post #{rec.id} #{rec.title} views+1=#{rec.views + 1}"
  when Comment then "Comment #{rec.id} by #{rec.author.inspect}"
  when Tag then "Tag #{rec.name}"
  when nil then "nil"
  else "?"
  end
end
%w[posts comments tags].each do |t|
  GenericRelation.new(t).order("id").each { |rec| puts describe(rec) }
end
puts describe(GenericRelation.new("posts").where(id: 99).first)
r = GenericRelation.new("posts").where(title: "Hello").first
puts r.title
puts r.id + 1
c = GenericRelation.new("comments").first
puts c.author
puts c.id + 1
puts "valid? #{r.valid?} #{c.valid?}"
# per-model typed version in the same program: does it get widened by the generic one?
pp1 = Post.where(id: 3).first
puts pp1.title.upcase
