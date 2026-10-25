# Cybertrain::DB.transaction, Model.transaction and the block-free
# Connection#begin! / commit! / rollback!, compiled together with the whole
# framework (NOTES rule 41) and called from the places application code calls
# them from: a block nested in another block (the shape that
# `DB.with { |c| c.transaction { ... } }` cannot compile in, NOTES rules
# 32/45), a controller action that also uses DB.with, a Model's save.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/client"

DB = Cybertrain::DB

NOTES_SQL = "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL);"

def connect_notes
  DB.connect(":memory:")
  DB.with { |c| c.exec_script(NOTES_SQL) }
  nil
end

def note_count
  DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM notes")[0]["n"] }
end

def add_note(conn, title)
  conn.execute("INSERT INTO notes (title) VALUES (?)", [title])
  nil
end

# A model in the shape the generator writes (test/model.rb has the full
# one), with only what save needs.
class Note < Cybertrain::Model
  def self.table_name = "notes"
  def self.column_names = ["id", "title"]
  def model_name = "Note"

  attr_accessor :title

  def initialize(attrs = {})
    super()
    @title = ""
    assign_attributes(attrs)
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @title = Cybertrain::Cast.str(row["title"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :title then @title = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row
    { "title" => Cybertrain::Cast.to_sql(@title) }
  end
end

# A DB.transaction block that reads an enclosing block's parameter, in a
# method as in an action: the same loop written straight into a test block
# (three blocks deep) does not compile (NOTES rule 68).
def insert_three
  3.times do |i|
    DB.transaction { |c| c.execute("INSERT INTO notes (title) VALUES (?)", ["n#{i}"]) }
  end
  nil
end

# The block's own calls on `c` (not only calls from a helper method, which
# can get the connection's class from its other callers: NOTES rule 69).
test "DB.transaction commits what its block ran" do
  connect_notes
  DB.transaction do |c|
    c.execute("INSERT INTO notes (title) VALUES (?)", ["one"])
    c.execute("INSERT INTO notes (title) VALUES (?)", ["two"])
  end
  assert_equal 2, note_count
  insert_three
  assert_equal 5, note_count
  DB.disconnect
end

test "an exception rolls DB.transaction back, is re-raised, and the connection goes back clean" do
  connect_notes
  DB.with { |c| add_note(c, "kept") }
  message = assert_raises("RuntimeError") do
    DB.transaction do |c|
      add_note(c, "lost")
      raise "boom"
    end
  end
  assert_equal "boom", message
  assert_equal 1, note_count
  # Autocommit is back on: a fresh transaction commits.
  DB.transaction { |c| add_note(c, "after") }
  assert_equal 2, note_count
  DB.disconnect
end


# 1 when every connection the nested calls were given is the outer one.
# Not `outer.transaction { }`: the block parameter is a boxed value (a
# Proc's parameter, as DB.with's always was), and a yielding method cannot be
# called on a boxed receiver, not even after a `case` (NOTES rule 67). The
# nested DB.transaction and begin!/commit! are the forms for that.
def nested_same_connection(outer)
  same = 1
  DB.transaction { |inner| same = 0 unless inner.equal?(outer) }
  DB.with { |w| same = 0 unless w.equal?(outer) }
  outer.begin!
  add_note(outer, "conn-nested")
  outer.commit!
  same
end

test "a nested DB.transaction, DB.with or begin!/commit! joins the outer transaction" do
  # One connection (":memory:"): a nested checkout of a second one would wait
  # on the empty pool forever, so finishing at all shows the joining.
  connect_notes
  joined = 0
  DB.transaction do |c|
    add_note(c, "outer")
    joined = nested_same_connection(c)
  end
  assert_equal 1, joined
  assert_equal 2, note_count
  DB.disconnect
end

test "a raise in a nested level rolls the whole transaction back, as Connection#transaction does" do
  connect_notes
  nested_message = assert_raises("RuntimeError") do
    DB.transaction do |c|
      add_note(c, "outer")
      DB.transaction do |inner|
        add_note(inner, "inner")
        raise "inner boom"
      end
    end
  end
  assert_equal "inner boom", nested_message
  assert_equal 0, note_count
  # And the depth came back to 0: the next transaction commits on its own.
  DB.transaction { |c| add_note(c, "fresh") }
  assert_equal 1, note_count
  DB.disconnect
end

test "Model.transaction: a save joins it, and a raise rolls the save back" do
  connect_notes
  Note.transaction do |c|
    Note.new(title: "saved").save
    c.execute("INSERT INTO notes (title) VALUES (?)", ["sql"])
  end
  assert_equal 2, note_count
  model_message = assert_raises("RuntimeError") do
    Note.transaction do |c|
      Note.new(title: "unsaved").save
      raise "model boom"
    end
  end
  assert_equal "model boom", model_message
  assert_equal 2, note_count
  DB.disconnect
end

# The block-free form, with its rescue in a plain method.
def transfer(conn, fail_midway)
  conn.begin!(immediate: true)
  begin
    add_note(conn, "debit")
    raise "midway" if fail_midway
    add_note(conn, "credit")
  rescue JSON::NestingError, JSON::ParserError, StandardError => e
    conn.rollback!
    raise e
  end
  conn.commit!
  nil
end

# The message transfer raised, "" when it did not raise.
def transfer_error(conn, fail_midway)
  message = ""
  begin
    transfer(conn, fail_midway)
  rescue RuntimeError => e
    message = e.message
  end
  message
end

# The error commit! raises with nothing open ("" when it did not raise).
def stray_commit(conn)
  message = ""
  begin
    conn.commit!
  rescue Cybertrain::DB::Error => e
    message = e.message
  end
  message
end

test "begin! / commit! / rollback! without a block, nested ones counting levels" do
  connect_notes
  assert_equal "", DB.with { |c| transfer_error(c, false) }
  assert_equal 2, note_count
  assert_equal "midway", DB.with { |c| transfer_error(c, true) }
  assert_equal 2, note_count
  # Nested inside DB.transaction: the inner commit! only counts down.
  DB.transaction { |c| transfer(c, false) }
  assert_equal 4, note_count
  assert_includes DB.with { |c| stray_commit(c) }, "no transaction is open"
  # rollback! with nothing open does nothing.
  DB.with { |c| c.rollback! }
  assert_equal 4, note_count
  DB.disconnect
end

# BEGIN IMMEDIATE takes the write lock at once, so a second connection's
# BEGIN IMMEDIATE is refused ("database is locked", after the busy handler's
# five seconds) while the first transaction has not written anything yet; a
# deferred BEGIN takes no lock until the first write, so the same probe
# succeeds. File-backed: an in-memory database has no second connection.
LOCK_DB = "tmp/db_transaction_api.sqlite3"

def remove_lock_db
  [LOCK_DB, LOCK_DB + "-wal", LOCK_DB + "-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

# "" when another connection could take the write lock, else the error.
def other_writer_error
  other = DB::Connection.new(LOCK_DB)
  message = ""
  begin
    other.exec_script("BEGIN IMMEDIATE")
    other.exec_script("ROLLBACK")
  rescue Cybertrain::DB::Error => e
    message = e.message
  end
  other.close
  message
end

test "immediate: true issues BEGIN IMMEDIATE (the write lock is taken before any write)" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  remove_lock_db
  DB.connect(LOCK_DB, size: 2)
  DB.with { |c| c.exec_script(NOTES_SQL) }
  deferred = "unset"
  DB.transaction { |c| deferred = other_writer_error }
  assert_equal "", deferred
  immediate = ""
  DB.transaction(immediate: true) { |c| immediate = other_writer_error }
  assert_includes immediate, "database is locked"
  # Released at COMMIT.
  assert_equal "", other_writer_error
  DB.disconnect
  remove_lock_db
end

# DB.transaction called from a block nested in another block (here DB.with's
# block in a test block), the shape Connection#transaction does not compile
# in (NOTES rules 32/45). A DB.with that encloses the call is not a
# transaction, so the transaction gets a second connection: a file-backed
# pool of two (a one-connection pool would wait on itself, see DB.transaction).
test "DB.transaction compiles inside DB.with's block, nested in a test block" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  remove_lock_db
  DB.connect(LOCK_DB, size: 2)
  DB.with { |c| c.exec_script(NOTES_SQL) }
  DB.with do |outer|
    add_note(outer, "outside")
    DB.transaction { |c| add_note(c, "inside") }
  end
  assert_equal 2, note_count
  DB.disconnect
  remove_lock_db
end

class NotesController < Cybertrain::Controller
  rescue_from(RuntimeError) { |c, e| c.render plain: "failed #{e.message}", status: :unprocessable_entity }

  # DB.with and DB.transaction in one action.
  def create
    before = 0
    DB.with { |c| before = c.execute("SELECT COUNT(*) AS n FROM notes")[0]["n"].to_s.to_i }
    title = params[:title].to_s
    DB.transaction(immediate: true) do |c|
      c.execute("INSERT INTO notes (title) VALUES (?)", [title])
      add_note(c, "#{title}-2")
      raise "refused" if title == "bad"
    end
    render plain: "#{before}->#{note_count}"
  end
end

def notes_client
  router = Cybertrain::Router.new
  router.post("/notes", "notes") { |ctx| NotesController.new(ctx).process(:create) { |c| c.create } }
  Cybertrain::Test::Client.new(Cybertrain::App.new(router, logging: false))
end

test "a controller action runs DB.with and DB.transaction; a raise in the action rolls back" do
  connect_notes
  client = notes_client
  ok = client.post("/notes", { "title" => "good" })
  assert_response ok, :ok
  assert_equal "0->2", ok.body
  failed = client.post("/notes", { "title" => "bad" })
  assert_response failed, :unprocessable_entity
  assert_equal "failed refused", failed.body
  assert_equal 2, note_count
  DB.disconnect
end

Cybertrain::Test.run!
