require "cybertrain/test"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/model"
require "cybertrain/params"

# test/model.rb, test/associations.rb and test/validators.rb on MySQL,
# against the server CYBERTRAIN_TEST_MYSQL_URL names (script/test-mysql runs
# this program): their models (hand-written in the generator's shape, as
# there) and their tests, in that order, and their snapshots concatenated
# (test/mysql/models.rb.expected: their `ok` lines as they are, one summary
# line for all of them), so CRUD, callbacks, validations, JSON, dates and
# datetimes, associations and includes answer on MySQL what they answer on
# SQLite. MySQL's own tests come last: uniqueness over "a" / "a " / "A",
# blob_17mb_roundtrip and utf8mb4_and_nul_roundtrip (the plan's Review
# Focus 2 and 3).
#
# The fixture-app tests (generated models of test/fixtures/*: includes,
# nested includes, has_many :through, polymorphic, encrypted columns and
# decimals) each define their own Comment, so they cannot share this
# program: test/mysql/models_gen_app.rb, models_nested_includes.rb,
# models_through.rb and models_polymorphic.rb repeat them.
#
# What differs from the originals is marked where it is:
# - the database: the tables are created here by hand-written MySQL DDL
#   (the types of the design's type table; a foreign key as a table
#   constraint, which MySQL enforces, where SQLite took a column's
#   REFERENCES), dropped first; the plan's Task 10 (MySQL DDL from the
#   schema DSL) replaces this. One connection, as there.
# - test/associations.rb's reset_tables is reset_association_tables here
#   (test/model.rb has a reset_tables of its own).
# - the design's allowed exceptions (docs/superpowers/specs/2026-11-27-
#   mysql-adapter-design.md, "テストと受け入れ"), each marked "exception:
#   <name>" where it changes an assertion's value; no output line changes.
#
# test/model.rb:
#
# Post/PostRelation and Comment/CommentRelation below are hand-written in
# exactly the shape the model generator emits into gen/models/:
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
    found = rows
    i = 0
    while i < found.size
      out << Post.from_row(found[i])
      i += 1
    end
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

  attr_accessor :title, :body, :created_at, :updated_at

  def initialize(attrs = {})
    super()
    @title = ""
    @body = nil
    @created_at = nil
    @updated_at = nil
    assign_attributes(attrs)
  end

  def self.from_row(row)
    rec = Post.new(Cybertrain::Model::NO_ATTRIBUTES)
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
    when :title then @title = Cybertrain::Cast.str(value)
    when :body then @body = Cybertrain::Cast.str_or_nil(value)
    when :created_at then @created_at = Cybertrain::Cast.time_or_nil(value)
    when :updated_at then @updated_at = Cybertrain::Cast.time_or_nil(value)
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

  def comments = CommentRelation.new("comments").where(post_id: @id)

  def read_association(name)
    case name
    when :comments then comments.to_a
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
    found = rows
    i = 0
    while i < found.size
      out << Comment.from_row(found[i])
      i += 1
    end
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

  attr_accessor :post_id, :author, :body, :created_at, :updated_at

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
    rec = Comment.new(Cybertrain::Model::NO_ATTRIBUTES)
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
    when :post_id then @post_id = Cybertrain::Cast.int(value)
    when :author then @author = Cybertrain::Cast.str_or_nil(value)
    when :body then @body = Cybertrain::Cast.str(value)
    when :created_at then @created_at = Cybertrain::Cast.time_or_nil(value)
    when :updated_at then @updated_at = Cybertrain::Cast.time_or_nil(value)
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
    found = rows
    i = 0
    while i < found.size
      out << Flag.from_row(found[i])
      i += 1
    end
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

  attr_accessor :active, :score, :group

  def initialize(attrs = {})
    super()
    @active = false
    @score = nil
    @group = nil
    assign_attributes(attrs)
  end

  def self.from_row(row)
    rec = Flag.new(Cybertrain::Model::NO_ATTRIBUTES)
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
    when :active then @active = Cybertrain::Cast.bool(value)
    when :score then @score = Cybertrain::Cast.float_or_nil(value)
    when :group then @group = Cybertrain::Cast.str_or_nil(value)
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

# ---- test/associations.rb's models -----------------------------------------

# Declared associations in the shape the model generator writes into
# gen/models (ModelsEmitter.association_reader and friends; docs/design.md D47),
# hand-written here for the cases test/gen_models_compiles.rb's fixture does
# not have: a has_one, `dependent: :nullify` and `:delete_all`, a nullable
# belongs_to, and a foreign key without `dependent:` (the database decides),
# plus includes over the has_one and the nullable keys.
# The Relations carry only the methods these tests use. SQLite is FFI, so the
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
class UserRelation < Cybertrain::Relation
  def initialize(table)
    super(table)
    @preloaded = Array.new(0) { User.new }
  end

  def where(h) = (add_where(h); self)
  def order(o) = (set_order_hash(o); self)
  def limit(n) = (set_limit(n); self)

  def includes(*names)
    names.each do |name|
      case name
      when :profile, :notes then add_include(name)
      else raise ArgumentError, "unknown association #{name} for User"
      end
    end
    self
  end

  def preload(*names) = includes(*names)

  def preloaded(records)
    @preloaded = records
    mark_records_preloaded
    self
  end

  def to_a
    if records_preloaded?
      copy = Array.new(0) { User.new }
      i = 0
      while i < @preloaded.size
        copy << @preloaded[i]
        i += 1
      end
      return copy
    end

    out = Array.new(0) { User.new }
    found = rows
    i = 0
    while i < found.size
      out << User.from_row(found[i])
      i += 1
    end
    names = includes_names
    i = 0
    while i < names.size
      preload_association(names[i], out)
      i += 1
    end
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    User.from_row(r)
  end

  def find_by(h) = where(h).first

  def destroy_all
    out = to_a
    i = 0
    while i < out.size
      out[i].destroy
      i += 1
    end
    out
  end

  def preload_association(name, records)
    return nil if records.empty?

    step = Cybertrain::DB.with { |c| c.variable_limit }
    case name
    when :profile
      ids = Array.new(0) { 0 }
      index = { 0 => Profile.new }
      index.delete(0)
      i = 0
      while i < records.size
        ids << records[i].id
        i += 1
      end
      start = 0
      while start < ids.size
        found = ProfileRelation.new("profiles").where(user_id: ids[start, step]).order(id: :asc).to_a
        j = 0
        while j < found.size
          key = Cybertrain::Cast.int(found[j].user_id)
          index[key] = found[j] unless index.key?(key)
          j += 1
        end
        start += step
      end
      i = 0
      while i < records.size
        records[i].profile_preload!(index[records[i].id])
        i += 1
      end
    when :notes
      ids = Array.new(0) { 0 }
      groups = { 0 => Array.new(0) { Note.new } }
      groups.delete(0)
      i = 0
      while i < records.size
        ids << records[i].id
        groups[records[i].id] = Array.new(0) { Note.new }
        i += 1
      end
      start = 0
      while start < ids.size
        found = NoteRelation.new("notes").where(user_id: ids[start, step]).order(id: :asc).to_a
        j = 0
        while j < found.size
          key = Cybertrain::Cast.int(found[j].user_id)
          list = groups[key]
          list << found[j] unless list.nil?
          j += 1
        end
        start += step
      end
      i = 0
      while i < records.size
        records[i].notes_preload!(groups[records[i].id])
        i += 1
      end
    end
    nil
  end
end

class User < Cybertrain::Model
  def self.table_name = "users"
  def self.column_names = ["id", "name"]
  def model_name = "User"

  attr_accessor :name

  def initialize(attrs = {})
    super()
    @name = ""
    @profile_loaded = false
    @profile_record = nil
    @notes_preloaded = nil
    @tasks_preloaded = nil
    @audits_preloaded = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = User.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @name = Cybertrain::Cast.str(row["name"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :name then @name = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "name" => Cybertrain::Cast.to_sql(@name)
    }
  end

  def self.all = UserRelation.new("users")
  def self.includes(...) = all.includes(...)
  def self.where(h) = all.where(h)
  def self.count = all.count
  def self.find_by(h) = all.find_by(h)

  def self.create(attrs = {})
    rec = User.new(attrs)
    rec.save
    rec
  end

  # app/models/user.rb:
  #   has_one :profile, dependent: :delete_all
  #   has_many :notes, dependent: :nullify
  #   has_many :tasks, dependent: :delete_all
  # audits.user_id is a schema foreign key with no declaration.
  def profile
    return @profile_record if @profile_loaded

    Profile.find_by(user_id: @id)
  end

  def notes
    rel = NoteRelation.new("notes").where(user_id: @id)
    return rel if @notes_preloaded.nil?

    rel.preloaded(@notes_preloaded)
  end

  def tasks = TaskRelation.new("tasks").where(user_id: @id)
  def audits = AuditRelation.new("audits").where(user_id: @id)

  def destroy_dependents
    ProfileRelation.new("profiles").where(user_id: @id).delete_all
    NoteRelation.new("notes").where(user_id: @id).update_all(user_id: nil)
    TaskRelation.new("tasks").where(user_id: @id).delete_all
    nil
  end

  def profile_preload!(found)
    @profile_record = found
    @profile_loaded = true
    nil
  end

  def notes_preload!(records)
    @notes_preloaded = records
    nil
  end

  def reset_association_caches
    @profile_loaded = false
    @profile_record = nil
    @notes_preloaded = nil
    @tasks_preloaded = nil
    @audits_preloaded = nil
    nil
  end

  def read_association(name)
    case name
    when :profile then self.profile
    when :notes then self.notes.to_a
    when :tasks then self.tasks.to_a
    when :audits then self.audits.to_a
    else nil
    end
  end
end

class ProfileRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order_hash(o); self)
  def limit(n) = (set_limit(n); self)

  def to_a
    out = Array.new(0) { Profile.new }
    found = rows
    i = 0
    while i < found.size
      out << Profile.from_row(found[i])
      i += 1
    end
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    Profile.from_row(r)
  end

  def find_by(h) = where(h).first

  def destroy_all
    out = to_a
    i = 0
    while i < out.size
      out[i].destroy
      i += 1
    end
    out
  end
end

class Profile < Cybertrain::Model
  def self.table_name = "profiles"
  def self.column_names = ["id", "user_id", "bio"]
  def model_name = "Profile"

  attr_accessor :user_id, :bio

  def initialize(attrs = {})
    super()
    @user_id = nil
    @bio = nil
    @user_loaded = false
    @user_loaded_key = 0
    @user_record = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Profile.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @user_id = Cybertrain::Cast.int_or_nil(row["user_id"])
    @bio = Cybertrain::Cast.str_or_nil(row["bio"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :user_id then @user_id
    when :bio then @bio
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :user_id then @user_id = Cybertrain::Cast.int_or_nil(value)
    when :bio then @bio = Cybertrain::Cast.str_or_nil(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "user_id" => Cybertrain::Cast.to_sql(@user_id),
      "bio" => Cybertrain::Cast.to_sql(@bio)
    }
  end

  def self.all = ProfileRelation.new("profiles")
  def self.where(h) = all.where(h)
  def self.count = all.count
  def self.find_by(h) = all.find_by(h)

  def self.create(attrs = {})
    rec = Profile.new(attrs)
    rec.save
    rec
  end

  def user
    return nil if @user_id.nil?
    return @user_record if @user_loaded && @user_loaded_key == @user_id

    @user_record = User.find_by(id: @user_id)
    @user_loaded = true
    @user_loaded_key = Cybertrain::Cast.int(@user_id)
    @user_record
  end

  def reset_association_caches
    @user_loaded = false
    @user_record = nil
    nil
  end
end

class NoteRelation < Cybertrain::Relation
  def initialize(table)
    super(table)
    @preloaded = Array.new(0) { Note.new }
  end

  def where(h) = (add_where(h); self)
  def order(o) = (set_order_hash(o); self)
  def limit(n) = (set_limit(n); self)

  def includes(*names)
    names.each do |name|
      case name
      when :user then add_include(name)
      else raise ArgumentError, "unknown association #{name} for Note"
      end
    end
    self
  end

  def preload(*names) = includes(*names)

  def preloaded(records)
    @preloaded = records
    mark_records_preloaded
    self
  end

  def to_a
    if records_preloaded?
      copy = Array.new(0) { Note.new }
      i = 0
      while i < @preloaded.size
        copy << @preloaded[i]
        i += 1
      end
      return copy
    end

    out = Array.new(0) { Note.new }
    found = rows
    i = 0
    while i < found.size
      out << Note.from_row(found[i])
      i += 1
    end
    names = includes_names
    i = 0
    while i < names.size
      preload_association(names[i], out)
      i += 1
    end
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    Note.from_row(r)
  end

  def find_by(h) = where(h).first

  def destroy_all
    out = to_a
    i = 0
    while i < out.size
      out[i].destroy
      i += 1
    end
    out
  end

  def preload_association(name, records)
    return nil if records.empty?

    step = Cybertrain::DB.with { |c| c.variable_limit }
    case name
    when :user
      ids = Array.new(0) { 0 }
      seen = { 0 => true }
      seen.delete(0)
      index = { 0 => User.new }
      index.delete(0)
      i = 0
      while i < records.size
        raw = records[i].user_id
        key = Cybertrain::Cast.int(raw)
        unless raw.nil? || seen.key?(key)
          seen[key] = true
          ids << key
        end
        i += 1
      end
      start = 0
      while start < ids.size
        found = UserRelation.new("users").where(id: ids[start, step]).to_a
        j = 0
        while j < found.size
          index[found[j].id] = found[j]
          j += 1
        end
        start += step
      end
      i = 0
      while i < records.size
        records[i].user_preload!(index[Cybertrain::Cast.int(records[i].user_id)])
        i += 1
      end
    end
    nil
  end
end

class Note < Cybertrain::Model
  def self.table_name = "notes"
  def self.column_names = ["id", "user_id", "body"]
  def model_name = "Note"

  attr_accessor :user_id, :body

  def initialize(attrs = {})
    super()
    @user_id = nil
    @body = ""
    @user_loaded = false
    @user_loaded_key = 0
    @user_record = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Note.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @user_id = Cybertrain::Cast.int_or_nil(row["user_id"])
    @body = Cybertrain::Cast.str(row["body"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :user_id then @user_id
    when :body then @body
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :user_id then @user_id = Cybertrain::Cast.int_or_nil(value)
    when :body then @body = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "user_id" => Cybertrain::Cast.to_sql(@user_id),
      "body" => Cybertrain::Cast.to_sql(@body)
    }
  end

  def self.all = NoteRelation.new("notes")
  def self.includes(...) = all.includes(...)
  def self.where(h) = all.where(h)
  def self.count = all.count
  def self.find_by(h) = all.find_by(h)

  def self.create(attrs = {})
    rec = Note.new(attrs)
    rec.save
    rec
  end

  def user
    return nil if @user_id.nil?
    return @user_record if @user_loaded && @user_loaded_key == @user_id

    @user_record = User.find_by(id: @user_id)
    @user_loaded = true
    @user_loaded_key = Cybertrain::Cast.int(@user_id)
    @user_record
  end

  def user_preload!(found)
    @user_record = found
    @user_loaded = true
    @user_loaded_key = Cybertrain::Cast.int(@user_id)
    nil
  end

  def reset_association_caches
    @user_loaded = false
    @user_record = nil
    nil
  end
end

class TaskRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order_hash(o); self)
  def limit(n) = (set_limit(n); self)

  def to_a
    out = Array.new(0) { Task.new }
    found = rows
    i = 0
    while i < found.size
      out << Task.from_row(found[i])
      i += 1
    end
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    Task.from_row(r)
  end

  def find_by(h) = where(h).first

  def destroy_all
    out = to_a
    i = 0
    while i < out.size
      out[i].destroy
      i += 1
    end
    out
  end
end

class Task < Cybertrain::Model
  def self.table_name = "tasks"
  def self.column_names = ["id", "user_id", "title"]
  def model_name = "Task"

  attr_accessor :user_id, :title

  def initialize(attrs = {})
    super()
    @user_id = 0
    @title = ""
    @user_loaded = false
    @user_loaded_key = 0
    @user_record = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Task.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @user_id = Cybertrain::Cast.int(row["user_id"])
    @title = Cybertrain::Cast.str(row["title"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :user_id then @user_id
    when :title then @title
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :user_id then @user_id = Cybertrain::Cast.int(value)
    when :title then @title = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "user_id" => Cybertrain::Cast.to_sql(@user_id),
      "title" => Cybertrain::Cast.to_sql(@title)
    }
  end

  def self.all = TaskRelation.new("tasks")
  def self.where(h) = all.where(h)
  def self.count = all.count
  def self.find_by(h) = all.find_by(h)

  def self.create(attrs = {})
    rec = Task.new(attrs)
    rec.save
    rec
  end

  def user
    return @user_record if @user_loaded && @user_loaded_key == @user_id

    @user_record = User.find_by(id: @user_id)
    @user_loaded = true
    @user_loaded_key = @user_id
    @user_record
  end

  def reset_association_caches
    @user_loaded = false
    @user_record = nil
    nil
  end
end

class AuditRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order_hash(o); self)
  def limit(n) = (set_limit(n); self)

  def to_a
    out = Array.new(0) { Audit.new }
    found = rows
    i = 0
    while i < found.size
      out << Audit.from_row(found[i])
      i += 1
    end
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    Audit.from_row(r)
  end

  def find_by(h) = where(h).first

  def destroy_all
    out = to_a
    i = 0
    while i < out.size
      out[i].destroy
      i += 1
    end
    out
  end
end

class Audit < Cybertrain::Model
  def self.table_name = "audits"
  def self.column_names = ["id", "user_id", "action"]
  def model_name = "Audit"

  attr_accessor :user_id, :action

  def initialize(attrs = {})
    super()
    @user_id = 0
    @action = ""
    @user_loaded = false
    @user_loaded_key = 0
    @user_record = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Audit.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @user_id = Cybertrain::Cast.int(row["user_id"])
    @action = Cybertrain::Cast.str(row["action"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :user_id then @user_id
    when :action then @action
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :user_id then @user_id = Cybertrain::Cast.int(value)
    when :action then @action = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "user_id" => Cybertrain::Cast.to_sql(@user_id),
      "action" => Cybertrain::Cast.to_sql(@action)
    }
  end

  def self.all = AuditRelation.new("audits")
  def self.where(h) = all.where(h)
  def self.count = all.count
  def self.find_by(h) = all.find_by(h)

  def self.create(attrs = {})
    rec = Audit.new(attrs)
    rec.save
    rec
  end

  def user
    return @user_record if @user_loaded && @user_loaded_key == @user_id

    @user_record = User.find_by(id: @user_id)
    @user_loaded = true
    @user_loaded_key = @user_id
    @user_record
  end

  def reset_association_caches
    @user_loaded = false
    @user_record = nil
    nil
  end
end

# app/models: a non-optional belongs_to on a nullable key, and one on a
# NOT NULL key (the generator writes this line; see ModelsEmitter).
class Profile
  validates_foreign_key :user_id
end

class Task
  validates_foreign_key :user_id
end

# ---- test/validators.rb's model ----------------------------------------------


# The validators (docs/design.md D48) --
# inclusion, exclusion, format, numericality, uniqueness, length's is:/in:,
# and allow_nil:, allow_blank:, on:, message:, if:/unless: on every rule --
# each with Rails' default English message. SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Thing is hand-written in the shape the model generator emits
# (test/gen_models.rb holds the emitted text), trimmed to what these tests
# call. It overrides the three hooks the generator writes from the model
# file: unique_value_taken? (here a recorder answering from a list, not a
# query: test/gen_models_compiles.rb runs the generated query),
# validation_condition? (the `case` over the if:/unless: names) and
# run_custom_validations (the `validate :method` calls).

UNIQUENESS_CALLS = Array.new(0) { "" }

class ThingRelation < Cybertrain::Relation
  def where(cond = nil, *binds)
    case cond
    when nil then nil
    when Hash then add_where(cond)
    when String then add_where_sql(cond, binds)
    end
    self
  end

  def size = count
end

class Thing < Cybertrain::Model
  def self.table_name = "things"
  def self.column_names = ["id", "name", "code", "state", "rating", "slug", "handle", "count_text", "qty", "price",
                           "level", "ratio", "whole", "email", "account_id", "nickname", "note", "tier", "age", "bonus",
                           "motto", "token", "score"]
  def model_name = "Thing"

  attr_accessor :name, :code, :state, :rating, :slug, :handle, :count_text, :qty, :price, :level, :ratio, :whole,
                :email, :account_id, :nickname, :note, :tier, :age, :bonus, :motto, :token, :needs_note, :draft_mode,
                :strict, :score

  def initialize(attrs = {})
    super()
    @name = "ok"
    @code = "abc"
    @state = nil
    @rating = 3
    @slug = "my-post"
    @handle = "bob"
    @count_text = "12"
    @qty = 5
    @price = Cybertrain::Cast.float_or_nil(9.5)
    @level = 2
    @ratio = 1.5
    @whole = 3
    @email = "a@b.example"
    @account_id = 1
    @nickname = nil
    @note = nil
    @tier = 1
    @age = 18
    @bonus = nil
    @motto = nil
    @token = "abc"
    @score = 1.0
    @needs_note = false
    @draft_mode = false
    @strict = false
    assign_attributes(attrs) unless attrs.empty?
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    when :code then @code
    when :state then @state
    when :rating then @rating
    when :slug then @slug
    when :handle then @handle
    when :count_text then @count_text
    when :qty then @qty
    when :price then @price
    when :level then @level
    when :ratio then @ratio
    when :whole then @whole
    when :email then @email
    when :account_id then @account_id
    when :nickname then @nickname
    when :note then @note
    when :tier then @tier
    when :age then @age
    when :bonus then @bonus
    when :motto then @motto
    when :token then @token
    when :score then @score
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :name then @name = Cybertrain::Cast.str(value)
    when :code then @code = Cybertrain::Cast.str(value)
    when :state then @state = Cybertrain::Cast.str_or_nil(value)
    when :rating then @rating = Cybertrain::Cast.int(value)
    when :slug then @slug = Cybertrain::Cast.str(value)
    when :handle then @handle = Cybertrain::Cast.str(value)
    when :count_text then @count_text = Cybertrain::Cast.str(value)
    when :qty then @qty = Cybertrain::Cast.int(value)
    when :price then @price = Cybertrain::Cast.float_or_nil(value)
    when :level then @level = Cybertrain::Cast.int(value)
    when :ratio then @ratio = Cybertrain::Cast.float(value)
    when :whole then @whole = value
    when :email then @email = Cybertrain::Cast.str(value)
    when :account_id then @account_id = Cybertrain::Cast.int(value)
    when :nickname then @nickname = Cybertrain::Cast.str_or_nil(value)
    when :note then @note = Cybertrain::Cast.str_or_nil(value)
    when :tier then @tier = Cybertrain::Cast.int(value)
    when :age then @age = Cybertrain::Cast.int(value)
    when :bonus then @bonus = Cybertrain::Cast.float_or_nil(value)
    when :motto then @motto = Cybertrain::Cast.str_or_nil(value)
    when :token then @token = Cybertrain::Cast.str_or_nil(value)
    when :score then @score = Cybertrain::Cast.float(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "name" => Cybertrain::Cast.to_sql(@name),
      "code" => Cybertrain::Cast.to_sql(@code),
      "state" => Cybertrain::Cast.to_sql(@state),
      "rating" => Cybertrain::Cast.to_sql(@rating),
      "slug" => Cybertrain::Cast.to_sql(@slug),
      "handle" => Cybertrain::Cast.to_sql(@handle),
      "count_text" => Cybertrain::Cast.to_sql(@count_text),
      "qty" => Cybertrain::Cast.to_sql(@qty),
      "price" => Cybertrain::Cast.to_sql(@price),
      "level" => Cybertrain::Cast.to_sql(@level),
      "ratio" => Cybertrain::Cast.to_sql(@ratio),
      "whole" => Cybertrain::Cast.to_sql(@whole),
      "email" => Cybertrain::Cast.to_sql(@email),
      "account_id" => Cybertrain::Cast.to_sql(@account_id),
      "nickname" => Cybertrain::Cast.to_sql(@nickname),
      "note" => Cybertrain::Cast.to_sql(@note),
      "tier" => Cybertrain::Cast.to_sql(@tier),
      "age" => Cybertrain::Cast.to_sql(@age),
      "bonus" => Cybertrain::Cast.to_sql(@bonus),
      "motto" => Cybertrain::Cast.to_sql(@motto),
      "token" => Cybertrain::Cast.to_sql(@token)
    }
  end

  def self.all = ThingRelation.new("things")
  def self.count = all.count

  # The generated shapes (models_emitter.rb), hand-written.
  def unique_value_taken?(attr, value, scope_attr, scope_value, exclude_id, case_sensitive)
    UNIQUENESS_CALLS << "#{attr}|#{value}|#{scope_attr}|#{scope_value}|#{exclude_id}|#{case_sensitive}"
    Cybertrain::Cast.str(value).downcase == "taken@b.example"
  end

  def validation_condition?(name)
    case name
    when :needs_note? then self.needs_note? ? true : false
    when :draft_mode? then self.draft_mode? ? true : false
    when :strict? then self.strict? ? true : false
    else true
    end
  end

  def run_custom_validations(context)
    self.name_not_admin if validation_condition?(:strict?)
    self.handle_not_root if context == :update
    nil
  end
end

# ---- app/models/thing.rb (user code) ----------------------------------------

class Thing
  validates :name, presence: true, length: { in: 2..10 }
  validates :code, length: { is: 3 }
  validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
  validates :rating, inclusion: { in: 1..5 }, exclusion: { in: [4] }
  validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
  validates :handle, format: { without: /[0-9]/, message: "has digits" }
  validates :count_text, numericality: { only_integer: true }
  validates :qty, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 100 }
  validates :price, numericality: { greater_than: 0, less_than_or_equal_to: 10.5 }, allow_nil: true
  validates :level, numericality: { equal_to: 2 }
  validates :ratio, numericality: { other_than: 7 }
  validates :whole, numericality: { only_integer: true }
  validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create, message: "is taken"
  validates :nickname, length: { minimum: 3 }, allow_blank: true
  validates :note, presence: true, if: :needs_note?, unless: :draft_mode?
  validates :code, :slug, presence: true, if: :strict?
  validates :name, uniqueness: true, on: :update
  validate :name_not_admin, :handle_not_root
  validates :tier, inclusion: { in: 1...5 }
  validates :age, inclusion: { in: 18.. }
  validates :score, inclusion: { in: 1...5 }
  validates :bonus, numericality: { greater_than: 0, allow_nil: true }
  validates :motto, format: { without: /!/ }
  validates :token, format: { with: /\A[a-z]+\z/ }

  def needs_note? = @needs_note
  def draft_mode? = @draft_mode
  def strict? = @strict

  def name_not_admin
    errors.add(:name, "is not allowed") if name == "admin"
  end

  def handle_not_root
    errors.add(:handle, "is root") if handle == "root"
  end
end

# ---- MySQL's own models ------------------------------------------------------

# Image is test/db_blob.rb's (the shape gen/models/image.rb takes for a
# table with a BLOB column), for the binary round trips below.
class ImageRelation < Cybertrain::Relation
  # What the emitter writes for a table with a BLOB column.
  def binary_column?(name)
    case name
    when "data" then true
    else false
    end
  end

  def where(h) = (add_where(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
  def limit(n) = (set_limit(n); self)

  def first
    r = first_row
    return nil if r.nil?
    Image.from_row(r)
  end

  def find(id)
    rec = where(id: id).first
    raise Cybertrain::RecordNotFound, "Couldn't find Image with id=#{id}" if rec.nil?
    rec
  end
end

class Image < Cybertrain::Model
  def self.table_name = "images"
  def self.column_names = ["id", "data", "name"]
  def model_name = "Image"

  attr_accessor :data, :name

  def initialize(attrs = {})
    super()
    @data = ""
    @name = ""
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Image.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @data = Cybertrain::Cast.binary(row["data"])
    @name = Cybertrain::Cast.str(row["name"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :data then @data
    when :name then @name
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :data then @data = Cybertrain::Cast.binary(value)
    when :name then @name = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "data" => Cybertrain::DB::Blob.wrap(@data),
      "name" => Cybertrain::Cast.to_sql(@name)
    }
  end

  def self.all = ImageRelation.new("images")
  def self.find(id) = all.find(id)
  def read_association(name) = nil
  def call_view_method(name) = nil
end

# Member: a `validates :email, uniqueness: true` in the shape the generator
# writes (ModelsEmitter.emit_unique_value_taken), asked of the database:
# members.email is VARCHAR in utf8mb4_0900_bin, which compares bytes and
# does not pad, so "a", "a " and "A" are three values, as on SQLite.
class MemberRelation < Cybertrain::Relation
  def column_type(name)
    case name
    when "id" then :integer
    when "email" then :string
    when "bio" then :text
    else :unknown
    end
  end

  def where(cond = nil, *binds)
    case cond
    when nil then nil
    when Hash then add_where(cond)
    when String then add_where_sql(cond, binds)
    else raise ArgumentError, "where takes a Hash or a SQL String"
    end
    self
  end

  def not(h) = (add_where_not(h); self)
  def where_sql(s, b = []) = (add_where_sql(s, b); self)
end

class Member < Cybertrain::Model
  def self.table_name = "members"
  def self.column_names = ["id", "email", "bio"]
  def model_name = "Member"

  attr_accessor :email, :bio

  def initialize(attrs = {})
    super()
    @email = ""
    @bio = nil
    assign_attributes(attrs) unless attrs.empty?
  end

  def self.from_row(row)
    rec = Member.new(Cybertrain::Model::NO_ATTRIBUTES)
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @email = Cybertrain::Cast.str(row["email"])
    @bio = Cybertrain::Cast.str_or_nil(row["bio"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :email then @email
    when :bio then @bio
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :email then @email = Cybertrain::Cast.str(value)
    when :bio then @bio = Cybertrain::Cast.str_or_nil(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    {
      "email" => Cybertrain::Cast.to_sql(@email),
      "bio" => Cybertrain::Cast.to_sql(@bio)
    }
  end

  def self.all = MemberRelation.new("members")
  def self.count = all.count
  def self.find(id)
    rows = Cybertrain::DB.with { |c| c.execute_models("SELECT * FROM `members` WHERE `id` = ?", [id]) }
    raise Cybertrain::RecordNotFound, "Couldn't find Member with id=#{id}" if rows.empty?
    Member.from_row(rows[0])
  end

  def self.create(attrs = {})
    rec = Member.new(attrs)
    rec.save
    rec
  end

  # The generated shape (models_emitter.rb).
  def unique_value_taken?(attr, value, scope_attr, scope_value, exclude_id, case_sensitive)
    rel = MemberRelation.new("members")
    if case_sensitive || value.nil?
      rel.where({ attr => value })
    else
      column = Cybertrain::Relation.checked_column("uniqueness", attr)
      rel.where_sql("LOWER(#{column}) = LOWER(?)", [value])
    end
    rel.where({ scope_attr => scope_value }) unless scope_attr.nil?
    rel.where.not(id: exclude_id) unless exclude_id == 0
    rel.exists?
  end

  def read_association(name) = nil
  def call_view_method(name) = nil
end

class Member
  validates :email, uniqueness: true
end

# ---- database -----------------------------------------------------------

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# MySQL: hand-written DDL in the design's types (Task 10 generates it from
# the schema DSL), outside any transaction (DDL commits on MySQL). The
# originals' TEXT timestamps are DATETIME(6); their boolean INTEGER a
# TINYINT(1).
TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
ID = "id BIGINT AUTO_INCREMENT PRIMARY KEY"
Cybertrain::DB.connect(URL, size: 1)
Cybertrain::DB.with do |c|
  c.exec_script(
    "DROP TABLE IF EXISTS comments; DROP TABLE IF EXISTS profiles; DROP TABLE IF EXISTS notes; " \
    "DROP TABLE IF EXISTS tasks; DROP TABLE IF EXISTS audits; DROP TABLE IF EXISTS posts; " \
    "DROP TABLE IF EXISTS users; DROP TABLE IF EXISTS flags; DROP TABLE IF EXISTS things; " \
    "DROP TABLE IF EXISTS images; DROP TABLE IF EXISTS members;" \
    "CREATE TABLE posts (#{ID}, title VARCHAR(255) NOT NULL, body MEDIUMTEXT, " \
    "created_at DATETIME(6), updated_at DATETIME(6))#{TABLE_OPTIONS};" \
    "CREATE TABLE comments (#{ID}, post_id BIGINT NOT NULL, author VARCHAR(255), body MEDIUMTEXT NOT NULL, " \
    "created_at DATETIME(6), updated_at DATETIME(6), FOREIGN KEY (post_id) REFERENCES posts(id))#{TABLE_OPTIONS};" \
    "CREATE TABLE flags (#{ID}, active TINYINT(1) NOT NULL DEFAULT 0, score DOUBLE, `group` VARCHAR(255))" \
    "#{TABLE_OPTIONS};" \
    "CREATE TABLE users (#{ID}, name VARCHAR(255) NOT NULL)#{TABLE_OPTIONS};" \
    "CREATE TABLE profiles (#{ID}, user_id BIGINT, bio MEDIUMTEXT, FOREIGN KEY (user_id) REFERENCES users(id))" \
    "#{TABLE_OPTIONS};" \
    "CREATE TABLE notes (#{ID}, user_id BIGINT, body MEDIUMTEXT NOT NULL, FOREIGN KEY (user_id) REFERENCES users(id))" \
    "#{TABLE_OPTIONS};" \
    "CREATE TABLE tasks (#{ID}, user_id BIGINT NOT NULL, title VARCHAR(255) NOT NULL, " \
    "FOREIGN KEY (user_id) REFERENCES users(id))#{TABLE_OPTIONS};" \
    "CREATE TABLE audits (#{ID}, user_id BIGINT NOT NULL, action VARCHAR(255) NOT NULL, " \
    "FOREIGN KEY (user_id) REFERENCES users(id))#{TABLE_OPTIONS};" \
    "CREATE TABLE things (#{ID}, name VARCHAR(255) NOT NULL, code VARCHAR(255), state VARCHAR(255), " \
    "rating INT, slug VARCHAR(255), handle VARCHAR(255), count_text VARCHAR(255), qty INT, price DOUBLE, level INT, " \
    "ratio DOUBLE, whole DOUBLE, email VARCHAR(255), account_id BIGINT, nickname VARCHAR(255), note MEDIUMTEXT, " \
    "tier INT, age INT, bonus DOUBLE, motto VARCHAR(255), token VARCHAR(255))#{TABLE_OPTIONS};" \
    "CREATE TABLE images (#{ID}, data LONGBLOB NOT NULL, name VARCHAR(255))#{TABLE_OPTIONS};" \
    "CREATE TABLE members (#{ID}, email VARCHAR(255), bio MEDIUMTEXT, UNIQUE KEY (email))#{TABLE_OPTIONS};"
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
  assert_equal "2026-09-24T12:30:05.000Z", Cybertrain::Cast.iso8601(t)
  t2 = Cybertrain::Cast.time_or_nil("2026-09-24 12:30:05")
  assert_equal "2026-09-24T12:30:05.000Z", Cybertrain::Cast.iso8601(t2)
  t3 = Cybertrain::Cast.time_or_nil(fixed_time)
  assert_equal "2026-09-24T12:30:05.000Z", Cybertrain::Cast.iso8601(t3)
  t4 = Cybertrain::Cast.time_or_nil(0)
  assert_equal "1970-01-01T00:00:00.000Z", Cybertrain::Cast.iso8601(t4)
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
  assert_equal "2024-02-29T23:59:59.000Z", Cybertrain::Cast.iso8601(Cybertrain::Cast.time_or_nil("2024-02-29 23:59:59"))
  assert_equal "2026-12-31T00:00:00.000Z", Cybertrain::Cast.iso8601(Cybertrain::Cast.time_or_nil("2026-12-31T00:00:00.000Z"))
  post = Post.new(title: "Bad date", created_at: "2026-13-01 00:00:00")
  assert_nil post.created_at
end

test "Cast.to_sql turns Time and booleans into SQLite values" do
  assert_equal "2026-09-24 12:30:05.000000", Cybertrain::Cast.to_sql(fixed_time)
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
  # Rails' humanize drops a trailing _id (phase 4b).
  assert_equal ["Title can't be blank", "Title is too short (minimum is 3 characters)", "Post is invalid"],
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
  assert_equal 'SELECT * FROM `posts` WHERE (views > ?)', Post.all.where_sql("views > ?", [3]).to_sql
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
  # A Symbol is its name and nil is no order, not a NoMethodError on strip.
  assert_equal Post.order("title").to_sql, Post.order(:title).to_sql
  assert_equal 'SELECT * FROM `posts` ORDER BY `title`', Post.order(:title).to_sql
  assert_equal 'SELECT * FROM `posts`', Post.order(nil).to_sql
  ["title; DROP TABLE posts", "title DESC; DROP", "lower(title)", "title, ", ",title", "title DESCX",
   "title DESC id", "1title", "posts.title", "title--"].each do |bad|
    message = assert_raises("ArgumentError") { Post.order(bad) }
    assert message.include?("order_sql"), "message for #{bad} should point to order_sql"
    assert message.include?("is not `column [ASC|DESC]`")
  end
  assert_equal "order: \"title; DROP TABLE posts\" is not `column [ASC|DESC]` (use order_sql for raw SQL)",
               assert_raises("ArgumentError") { Post.order("title; DROP TABLE posts") }
  # The term is shown escaped: a decoded newline in it (?sort=a%0Ab) cannot
  # forge a second log line or body line.
  newline_message = assert_raises("ArgumentError") { Post.order("title\nDROP") }
  assert !newline_message.include?("\n"), "the message must not carry a raw newline"
  assert newline_message.include?("title\\nDROP"), "the newline is printed as backslash-n"
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
  bodies = post.comments.to_a.map { |c| c.body }
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
             "\"created_at\":\"2026-09-24T12:30:05.000Z\",\"updated_at\":\"2026-09-24T12:30:05.000Z\"}"
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
    # MySQL: the test's own SQL quotes the keyword column with backticks
    # (without ANSI_QUOTES MySQL reads "group" as a string; SQLite takes both).
    c.execute("UPDATE flags SET `group` = ? WHERE id = ?", ["ops", flag.id])
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
  assert_equal "2026-09-24T12:30:05.000Z", Cybertrain::Cast.iso8601(created)
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

# ---- test/associations.rb ---------------------------------------------------

# test/associations.rb's reset_tables (test/model.rb has its own).
def reset_association_tables
  Cybertrain::DB.with do |c|
    c.exec_script("DELETE FROM audits; DELETE FROM tasks; DELETE FROM notes; DELETE FROM profiles; DELETE FROM users;")
  end
end

test "has_one answers the child or nil" do
  reset_association_tables
  ann = User.create(name: "ann")
  bob = User.create(name: "bob")
  Profile.create(user_id: ann.id, bio: "hi")
  assert_equal "hi", ann.profile.bio
  assert_nil bob.profile
  assert_nil User.new.profile
  rec = ann.read_association(:profile)
  bio = case rec
        when Profile then rec.bio
        else "none"
        end
  assert_equal "hi", bio
end

test "has_many readers are Relations; read_association gives an Array" do
  reset_association_tables
  ann = User.create(name: "ann")
  Note.create(user_id: ann.id, body: "a")
  Note.create(user_id: ann.id, body: "b")
  assert_equal 2, ann.notes.count
  assert_equal "b", ann.notes.where(body: "b").first.body
  list = ann.read_association(:notes)
  size = case list
         when Array then list.size
         else -1
         end
  assert_equal 2, size
end

test "a nullable belongs_to answers nil for a nil key and caches the parent per key" do
  reset_association_tables
  ann = User.create(name: "ann")
  bob = User.create(name: "bob")
  note = Note.create(body: "orphan")
  assert_nil note.user
  note.user_id = ann.id
  assert_equal "ann", note.user.name
  User.where(id: ann.id).update_all(name: "ann2")
  assert_equal "ann", note.user.name
  note.user_id = bob.id
  assert_equal "bob", note.user.name
  note.user_id = nil
  assert_nil note.user
  note.user_id = ann.id
  assert_equal "ann2", note.user.name
end

test "destroy: has_one :delete_all, has_many :nullify and :delete_all run inside destroy's transaction" do
  reset_association_tables
  ann = User.create(name: "ann")
  bob = User.create(name: "bob")
  Profile.create(user_id: ann.id, bio: "ann's")
  Profile.create(user_id: bob.id, bio: "bob's")
  note = Note.create(user_id: ann.id, body: "kept")
  Task.create(user_id: ann.id, title: "gone")
  Task.create(user_id: bob.id, title: "bob's task")
  assert ann.destroy
  refute ann.persisted?
  assert_equal 0, User.where(id: ann.id).count
  assert_equal 1, Profile.count
  assert_equal 1, Note.count
  assert_nil Note.all.find_by(id: note.id).user_id
  assert_equal 1, Task.count
  assert_equal "bob's task", Task.all.first.title
  refute Cybertrain::DB.in_transaction?
end

test "without dependent: the database's foreign key refuses, and the dependents' work is rolled back" do
  reset_association_tables
  ann = User.create(name: "ann")
  Profile.create(user_id: ann.id, bio: "ann's")
  Note.create(user_id: ann.id, body: "note")
  Task.create(user_id: ann.id, title: "task")
  Audit.create(user_id: ann.id, action: "signed up")
  assert_raises("DB::Error") { ann.destroy }
  assert ann.persisted?
  assert_equal 1, User.count
  assert_equal 1, Profile.count
  assert_equal 1, Task.count
  assert_equal ann.id, Note.all.first.user_id
  refute Cybertrain::DB.in_transaction?
end

test "destroy joins a transaction the application opened" do
  reset_association_tables
  ann = User.create(name: "ann")
  Task.create(user_id: ann.id, title: "task")
  assert_raises("RuntimeError") do
    Cybertrain::DB.transaction do |_c|
      ann.destroy
      raise "undo"
    end
  end
  assert_equal 1, User.count
  assert_equal 1, Task.count
  # The rolled-back destroy had finished, so this copy says it is gone (as
  # after a save in a rolled-back transaction); a fresh one destroys it.
  refute ann.persisted?
  assert User.all.first.destroy
  assert_equal 0, Task.count
end

test "reload clears the belongs_to cache" do
  reset_association_tables
  ann = User.create(name: "ann")
  task = Task.create(user_id: ann.id, title: "t")
  assert_equal "ann", task.user.name
  User.where(id: ann.id).update_all(name: "ann2")
  assert_equal "ann", task.user.name
  task.reload
  assert_equal "ann2", task.user.name
end

test "validates_foreign_key: nil, blank and 0 are blank; a saved parent's id is not" do
  reset_association_tables
  ann = User.create(name: "ann")
  orphan = Profile.new(bio: "x")
  assert_nil orphan.user_id
  refute orphan.valid?
  assert_equal ["can't be blank"], orphan.errors[:user_id]
  orphan.write_attribute(:user_id, "")
  assert_nil orphan.user_id
  refute orphan.valid?
  orphan.user_id = ann.id
  assert orphan.valid?
  task = Task.new(title: "t")
  assert_equal 0, task.user_id
  refute task.valid?
  assert_equal ["can't be blank"], task.errors[:user_id]
  refute task.save
  task.user_id = ann.id
  assert task.save
  # A blank String value, through the validator itself.
  profile = Profile.new(user_id: ann.id, bio: "  ")
  Cybertrain::Validator.new(:bio, :foreign_key).validate(profile, :create)
  assert_equal ["can't be blank"], profile.errors[:bio]
  profile.bio = ""
  Cybertrain::Validator.new(:bio, :foreign_key).validate(profile, :create)
  assert_equal ["can't be blank", "can't be blank"], profile.errors[:bio]
end

def statements = Cybertrain::DB.with { |c| c.statements_run }

test "includes(:profile) fills every user's has_one, nil where there is none, in one query" do
  reset_association_tables
  ann = User.create(name: "ann")
  User.create(name: "bob")
  Profile.create(user_id: ann.id, bio: "hi")
  before = statements
  users = User.where(name: ["ann", "bob"]).order(id: :asc).includes(:profile).to_a
  assert_equal 2, statements - before
  bios = users.map { |u| u.profile.nil? ? "none" : u.profile.bio }
  assert_equal ["hi", "none"], bios
  assert_equal 2, statements - before
  users[1].reload
  assert_nil users[1].profile
  assert_equal 4, statements - before
end

test "includes(:notes, :profile) runs one query per association; a nullable key groups its children" do
  reset_association_tables
  ann = User.create(name: "ann")
  bob = User.create(name: "bob")
  Note.create(user_id: ann.id, body: "a1")
  Note.create(user_id: nil, body: "loose")
  Note.create(user_id: ann.id, body: "a2")
  before = statements
  users = User.all.order(id: :asc).includes(:notes, :profile).to_a
  assert_equal 3, statements - before
  assert_equal [["a1", "a2"], []], users.map { |u| u.notes.to_a.map { |n| n.body } }
  assert_equal 3, statements - before
  assert_equal bob.id, users[1].id
  assert_equal 2, users[0].notes.count
  assert_equal 4, statements - before
end

test "Note.includes(:user) on a nullable key: a nil key queries nothing and answers nil" do
  reset_association_tables
  ann = User.create(name: "ann")
  Note.create(user_id: ann.id, body: "a")
  Note.create(user_id: nil, body: "loose")
  Note.create(user_id: ann.id, body: "b")
  before = statements
  notes = Note.includes(:user).order(id: :asc).to_a
  assert_equal 2, statements - before
  names = notes.map { |n| n.user.nil? ? "nil" : n.user.name }
  assert_equal ["ann", "nil", "ann"], names
  assert_equal 2, statements - before
  assert_equal "unknown association notes for Note", assert_raises("ArgumentError") { Note.includes(:notes) }
end

# ---- test/validators.rb -----------------------------------------------------

def messages_for(attr, attrs)
  thing = Thing.new(attrs)
  thing.valid?
  thing.errors[attr]
end

test "a Thing with its defaults is valid" do
  thing = Thing.new
  assert thing.valid?
  assert_equal [], thing.errors.full_messages
end

test "presence and length in:, is:" do
  assert_equal ["can't be blank", "is too short (minimum is 2 characters)"], messages_for(:name, { name: "" })
  assert_equal ["is too short (minimum is 2 characters)"], messages_for(:name, { name: "a" })
  assert_equal ["is too long (maximum is 10 characters)"], messages_for(:name, { name: "x" * 11 })
  assert_equal [], messages_for(:name, { name: "x" * 10 })
  assert_equal ["is the wrong length (should be 3 characters)"], messages_for(:code, { code: "abcd" })
  assert_equal ["is the wrong length (should be 3 characters)"], messages_for(:code, { code: "ab" })
end

test "inclusion in an Array of Strings, allow_nil" do
  assert_equal ["is not included in the list"], messages_for(:state, { state: "archived" })
  assert_equal [], messages_for(:state, { state: "published" })
  assert_equal [], messages_for(:state, { state: nil })
end

test "inclusion in an Integer Range, exclusion of an Integer Array" do
  assert_equal ["is not included in the list"], messages_for(:rating, { rating: 9 })
  assert_equal ["is not included in the list"], messages_for(:rating, { rating: 0 })
  assert_equal [], messages_for(:rating, { rating: 5 })
  assert_equal [], messages_for(:rating, { rating: 1 })
  assert_equal ["is reserved"], messages_for(:rating, { rating: 4 })
end

test "format with: and exclusion of Strings" do
  assert_equal ["is invalid"], messages_for(:slug, { slug: "Bad Slug" })
  assert_equal ["is reserved"], messages_for(:slug, { slug: "new" })
  assert_equal [], messages_for(:slug, { slug: "a-1" })
end

test "format without:, with message: inside the rule" do
  assert_equal ["has digits"], messages_for(:handle, { handle: "bob1" })
  assert_equal [], messages_for(:handle, { handle: "bobby" })
end

test "numericality on a String attribute: a number passes, else not a number, only_integer" do
  assert_equal [], messages_for(:count_text, { count_text: "12" })
  assert_equal [], messages_for(:count_text, { count_text: "-3" })
  assert_equal ["is not a number"], messages_for(:count_text, { count_text: "abc" })
  assert_equal ["is not a number"], messages_for(:count_text, { count_text: "" })
  assert_equal ["is not a number"], messages_for(:count_text, { count_text: "1.2.3" })
  assert_equal ["must be an integer"], messages_for(:count_text, { count_text: "1.5" })
end

test "numericality only_integer on a Float, and nil is not a number" do
  assert_equal ["must be an integer"], messages_for(:whole, { whole: 1.5 })
  assert_equal ["is not a number"], messages_for(:whole, { whole: nil })
  assert_equal ["is not a number"], messages_for(:whole, { whole: "x" })
  assert_equal [], messages_for(:whole, { whole: 7 })
end

test "numericality comparisons print their limits as written" do
  assert_equal ["must be greater than or equal to 0"], messages_for(:qty, { qty: -1 })
  assert_equal ["must be less than 100"], messages_for(:qty, { qty: 100 })
  assert_equal [], messages_for(:qty, { qty: 0 })
  assert_equal ["must be greater than 0"], messages_for(:price, { price: 0.0 })
  assert_equal ["must be less than or equal to 10.5"], messages_for(:price, { price: 11 })
  assert_equal [], messages_for(:price, { price: 10.5 })
  assert_equal [], messages_for(:price, { price: nil })
  assert_equal ["must be equal to 2"], messages_for(:level, { level: 3 })
  assert_equal ["must be other than 7"], messages_for(:ratio, { ratio: 7.0 })
  assert_equal [], messages_for(:ratio, { ratio: 7.5 })
end

test "inclusion in an exclusive-end Range and an endless Range" do
  assert_equal [], messages_for(:tier, { tier: 4 })
  assert_equal ["is not included in the list"], messages_for(:tier, { tier: 5 })
  assert_equal ["is not included in the list"], messages_for(:tier, { tier: 0 })
  assert_equal [], messages_for(:age, { age: 18 })
  assert_equal [], messages_for(:age, { age: 120 })
  assert_equal ["is not included in the list"], messages_for(:age, { age: 17 })
end

# Rails' (1...5).include?(4.5) is true: the exclusive end is compared as
# itself, not as 4 (which refused 4.5 on a float or decimal column).
test "an exclusive-end Integer Range admits a Float below its end" do
  assert_equal [], messages_for(:score, { score: 4.5 })
  assert_equal [], messages_for(:score, { score: 4.999 })
  assert_equal [], messages_for(:score, { score: 1.0 })
  assert_equal ["is not included in the list"], messages_for(:score, { score: 5.0 })
  assert_equal ["is not included in the list"], messages_for(:score, { score: 0.5 })
end

test "allow_nil inside a rule's Hash skips nil for that rule" do
  assert_equal [], messages_for(:bonus, { bonus: nil })
  assert_equal ["must be greater than 0"], messages_for(:bonus, { bonus: 0 })
  assert_equal [], messages_for(:bonus, { bonus: 0.5 })
end

test "format: nil fails a with: rule and passes a without:-only rule" do
  assert_equal [], messages_for(:motto, { motto: nil })
  assert_equal ["is invalid"], messages_for(:motto, { motto: "wow!" })
  assert_equal [], messages_for(:motto, { motto: "calm" })
  assert_equal ["is invalid"], messages_for(:token, { token: nil })
  assert_equal [], messages_for(:token, { token: "abc" })
end

test "allow_blank skips nil and blank Strings only" do
  assert_equal [], messages_for(:nickname, { nickname: nil })
  assert_equal [], messages_for(:nickname, { nickname: "  " })
  assert_equal ["is too short (minimum is 3 characters)"], messages_for(:nickname, { nickname: "ab" })
end

test "uniqueness passes scope, scope value, id and case_sensitive; message: replaces the default" do
  UNIQUENESS_CALLS.clear
  assert_equal ["is taken"], messages_for(:email, { email: "Taken@b.example", account_id: 7 })
  assert_equal ["email|Taken@b.example|account_id|7|0|false"], UNIQUENESS_CALLS
  assert_equal [], messages_for(:email, { email: "free@b.example" })
end

test "on: :create runs only on a new record, on: :update only on a persisted one" do
  UNIQUENESS_CALLS.clear
  thing = Thing.new(email: "taken@b.example")
  refute thing.save
  assert_equal ["Email is taken"], thing.errors.full_messages
  UNIQUENESS_CALLS.clear
  thing.email = "mine@b.example"
  assert thing.save
  assert_equal ["email|mine@b.example|account_id|1|0|false"], UNIQUENESS_CALLS
  UNIQUENESS_CALLS.clear
  thing.email = "taken@b.example"
  assert thing.valid?
  assert_equal ["name|ok|||#{thing.id}|true"], UNIQUENESS_CALLS
  assert_equal 1, Thing.count
end

test "if: and unless: go through validation_condition?" do
  assert_equal [], messages_for(:note, { note: nil })
  thing = Thing.new
  thing.needs_note = true
  refute thing.valid?
  assert_equal ["Note can't be blank"], thing.errors.full_messages
  thing.draft_mode = true
  assert thing.valid?
end

test "one validates line for two attributes, under if:" do
  thing = Thing.new(code: "", slug: "")
  thing.strict = true
  thing.valid?
  assert_equal ["is the wrong length (should be 3 characters)", "can't be blank"], thing.errors[:code]
  assert_equal ["is invalid", "can't be blank"], thing.errors[:slug]
  thing.strict = false
  thing.valid?
  assert_equal ["is the wrong length (should be 3 characters)"], thing.errors[:code]
  assert_equal ["is invalid"], thing.errors[:slug]
end

test "run_custom_validations runs after the declared rules with the context" do
  thing = Thing.new(name: "admin", handle: "root")
  assert thing.valid?
  thing.strict = true
  refute thing.valid?
  assert_equal ["Name is not allowed"], thing.errors.full_messages
  thing.strict = false
  assert thing.save
  refute thing.valid?
  assert_equal ["Handle is root"], thing.errors.full_messages
end

test "an unknown option, a lambda condition and an on: other than :create or :update raise ArgumentError" do
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, colour: true) }, "colour"
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, presence: true, if: -> { true }) },
                  "if: takes a Symbol method name"
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, presence: true, on: :save) }, "on:"
  assert_includes assert_raises("ArgumentError") { Thing.validates(:name, allow_nil: true) }, "at least one rule"
  assert_equal ["can't be blank", "is too short (minimum is 2 characters)"], messages_for(:name, { name: "" })
end

# apply_list and listed? had a `when Time` arm first (spikes/NOTES.md rule
# 8); without it a Time, here one read from a Hash of mixed values, is
# still neither a Range, an Array nor a number.
test "a Time is neither a list for in: nor a member of one" do
  mixed = { "at" => Time.utc(2026, 1, 1), "n" => 2, "list" => [1, 2] }
  msg = assert_raises("ArgumentError") { Cybertrain::Validator.new(:rating, :inclusion).apply_list(:in, mixed["at"]) }
  assert_equal "validates: inclusion: in: takes an Array or an Integer Range", msg
  ranged = Cybertrain::Validator.new(:rating, :inclusion)
  ranged.apply_list(:in, 1..5)
  assert ranged.listed?(mixed["n"])
  refute ranged.listed?(mixed["at"])
  refute ranged.listed?(mixed["list"])
  listed = Cybertrain::Validator.new(:rating, :inclusion)
  listed.apply_list(:in, mixed["list"])
  assert listed.listed?(mixed["n"])
  refute listed.listed?(mixed["at"])
end

# Last: it adds rules to Thing. What gen/concerns.rb writes for a model
# concern: the index counts the model's own `validates` calls
# above the `include`, however many rules each call made.
def thing_rules
  Cybertrain::Model.validators_for("Thing").map { |v| "#{v.attr}:#{v.kind}" }
end

test "model_concern_insert_at puts a concern's validates calls after the model's own call of that index" do
  own = thing_rules
  Thing.model_concern_insert_at(1)
  Thing.validates :motto, presence: true, length: { maximum: 5 }
  Thing.validates :token, presence: true
  Thing.model_concern_insert_done
  # A second concern, included after the model's second call (code).
  Thing.model_concern_insert_at(2)
  Thing.validates :age, presence: true
  Thing.model_concern_insert_done
  # One included below every call of the model.
  Thing.model_concern_insert_at(23)
  Thing.validates :level, presence: true
  Thing.model_concern_insert_done
  Thing.validates :ratio, presence: true
  assert_equal ["name:presence", "name:length", "motto:presence", "motto:length", "token:presence", "code:length", "age:presence",
                "state:inclusion"], thing_rules[0, 8]
  assert_equal own.size + 6, thing_rules.size
  assert_equal ["token:format", "level:presence", "ratio:presence"], thing_rules[own.size + 3, 3]
end

test "the default messages come from the dictionary of the current locale, message: still wins" do
  I18n.available_locales = [:en, :ja]
  I18n.locale = :ja
  assert_equal ["を入力してください", "は2文字以上で入力してください"], messages_for(:name, { name: "" })
  assert_equal ["は3文字で入力してください"], messages_for(:code, { code: "abcd" })
  assert_equal ["は一覧にありません"], messages_for(:state, { state: "gone" })
  assert_equal ["は予約されています"], messages_for(:rating, { rating: 4 })
  assert_equal ["は不正な値です"], messages_for(:token, { token: "A1" })
  assert_equal ["has digits"], messages_for(:handle, { handle: "b0b" })
  assert_equal ["は数値で入力してください"], messages_for(:count_text, { count_text: "x" })
  assert_equal ["は整数で入力してください"], messages_for(:whole, { whole: 1.5 })
  assert_equal ["は0以上の値にしてください"], messages_for(:qty, { qty: -1 })
  assert_equal ["は100より小さい値にしてください"], messages_for(:qty, { qty: 100 })
  assert_equal ["は10.5以下の値にしてください"], messages_for(:price, { price: 11.0 })
  assert_equal ["は0より大きい値にしてください"], messages_for(:price, { price: 0.0 })
  assert_equal ["は2にしてください"], messages_for(:level, { level: 3 })
  assert_equal ["は7以外の値にしてください"], messages_for(:ratio, { ratio: 7.0 })
  I18n.locale = nil
  assert_equal ["must be less than or equal to 10.5"], messages_for(:price, { price: 11.0 })
end

# ---- MySQL's own tests ---------------------------------------------------------

def reset_mysql_tables
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM images; DELETE FROM members;") }
  nil
end

# Whether two Strings hold the same bytes (test/db_blob.rb's same_bytes?).
def same_bytes?(a, b)
  return false unless a.bytesize == b.bytesize

  i = 0
  n = a.bytesize
  while i < n
    return false unless a.getbyte(i) == b.getbyte(i)
    i += 1
  end
  true
end

# The utf8mb4_0900_bin collation compares bytes without padding: the
# uniqueness rule and the UNIQUE index both see "a ", "A" and "a" as
# different values (SQLite's BINARY collation does the same).
test "uniqueness: \"a\" and \"a \" are different values, and so are \"A\" and \"a\"" do
  reset_mysql_tables
  first = Member.create(email: "a")
  assert first.persisted?
  padded = Member.create(email: "a ")
  assert padded.persisted?
  upper = Member.create(email: "A")
  assert upper.persisted?
  again = Member.create(email: "a")
  refute again.persisted?
  assert_equal ["Email has already been taken"], again.errors.full_messages
  assert_equal 3, Member.count
  assert_equal "a ", Member.find(padded.id).email
  # Its own row is not a duplicate of itself.
  assert Member.find(first.id).valid?
end

# Review Focus 2: a row bigger than one MySQL packet (0xFFFFFF bytes) goes
# out and comes back split into packets, byte for byte, through the model.
test "blob_17mb_roundtrip" do
  reset_mysql_tables
  size = 17 * 1024 * 1024 + 3
  chunk = (0..255).map { |b| b.chr }.join.b
  bytes = (chunk * (size / 256 + 1)).byteslice(0, size)
  assert_equal size, bytes.bytesize
  image = Image.new(name: "big", data: bytes)
  assert image.save
  back = Image.find(image.id)
  assert_equal size, back.data.bytesize
  assert same_bytes?(bytes, back.data)
  assert_equal "big", back.name
  length = Cybertrain::DB.with { |c| c.execute("SELECT LENGTH(data) AS n FROM images WHERE id = ?", [image.id]) }
  assert_equal size, length[0]["n"]
end

# Review Focus 3: 4-byte UTF-8 in a VARCHAR and a TEXT column, and NUL and
# invalid UTF-8 in a BLOB, round trip unchanged.
test "utf8mb4_and_nul_roundtrip" do
  reset_mysql_tables
  emoji = "\u{1F600} café \u{1F468}‍\u{1F469}‍\u{1F467} \u{20BB7}"
  member = Member.create(email: emoji, bio: "text #{emoji}\n#{emoji}")
  assert member.persisted?
  back = Member.find(member.id)
  assert_equal emoji, back.email
  assert_equal "text #{emoji}\n#{emoji}", back.bio
  assert_equal emoji.bytesize, back.email.bytesize
  found = Member.all.where(email: emoji).exists?
  assert found
  raw = "\x00a\x00\xff\xfe\x80\x00".b
  image = Image.new(name: emoji, data: raw)
  assert image.save
  loaded = Image.find(image.id)
  assert_equal 7, loaded.data.bytesize
  assert same_bytes?(raw, loaded.data)
  assert_equal emoji, loaded.name
  # A post's title (VARCHAR) and body (TEXT) through test/model.rb's Post.
  post = Post.new(title: emoji, body: "#{emoji}\tend")
  assert post.save
  assert_equal emoji, Post.find(post.id).title
  assert_equal "#{emoji}\tend", Post.find(post.id).body
end

Cybertrain::Test.run!
