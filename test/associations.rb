require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# Declared associations in the shape the model generator writes into
# gen/models (ModelsEmitter.association_reader and friends; spec section 7.2),
# hand-written here for the cases test/gen_models_compiles.rb's fixture does
# not have: a has_one, `dependent: :nullify` and `:delete_all`, a nullable
# belongs_to, and a foreign key without `dependent:` (the database decides),
# plus includes (spec section 8) over the has_one and the nullable keys.
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

test "validates_foreign_key: nil, blank and 0 are blank; a saved parent's id is not" do
  reset_tables
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
  reset_tables
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
  reset_tables
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
  reset_tables
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

Cybertrain::Test.run!
