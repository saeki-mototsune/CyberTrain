require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# Declared associations in the shape the model generator writes into
# gen/models (ModelsEmitter.association_reader and friends; spec section 7.2),
# hand-written here for the cases test/gen_models_compiles.rb's fixture does
# not have: a has_one, `dependent: :nullify` and `:delete_all`, a nullable
# belongs_to, and a foreign key without `dependent:` (the database decides).
# The Relations carry only the methods these tests use. SQLite is FFI, so the
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class UserRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order_hash(o); self)
  def limit(n) = (set_limit(n); self)

  def to_a
    out = Array.new(0) { User.new }
    found = rows
    i = 0
    while i < found.size
      out << User.from_row(found[i])
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

  def notes = NoteRelation.new("notes").where(user_id: @id)
  def tasks = TaskRelation.new("tasks").where(user_id: @id)
  def audits = AuditRelation.new("audits").where(user_id: @id)

  def destroy_dependents
    ProfileRelation.new("profiles").where(user_id: @id).delete_all
    NoteRelation.new("notes").where(user_id: @id).update_all(user_id: nil)
    TaskRelation.new("tasks").where(user_id: @id).delete_all
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
  def where(h) = (add_where(h); self)
  def order(o) = (set_order_hash(o); self)
  def limit(n) = (set_limit(n); self)

  def to_a
    out = Array.new(0) { Note.new }
    found = rows
    i = 0
    while i < found.size
      out << Note.from_row(found[i])
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

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);" \
    "CREATE TABLE profiles (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER REFERENCES users(id), bio TEXT);" \
    "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER REFERENCES users(id), body TEXT NOT NULL);" \
    "CREATE TABLE tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL REFERENCES users(id), " \
    "title TEXT NOT NULL);" \
    "CREATE TABLE audits (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL REFERENCES users(id), " \
    "action TEXT NOT NULL);"
  )
end

def reset_tables
  Cybertrain::DB.with do |c|
    c.exec_script("DELETE FROM audits; DELETE FROM tasks; DELETE FROM notes; DELETE FROM profiles; DELETE FROM users;")
  end
end

test "has_one answers the child or nil" do
  reset_tables
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
  reset_tables
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
  reset_tables
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
  reset_tables
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
  reset_tables
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
  reset_tables
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
  reset_tables
  ann = User.create(name: "ann")
  task = Task.create(user_id: ann.id, title: "t")
  assert_equal "ann", task.user.name
  User.where(id: ann.id).update_all(name: "ann2")
  assert_equal "ann", task.user.name
  task.reload
  assert_equal "ann2", task.user.name
end

Cybertrain::Test.run!
