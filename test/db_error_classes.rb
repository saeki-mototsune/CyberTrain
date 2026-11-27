require "cybertrain/db"
require "cybertrain/test"

# The constraint failures of the SQLite connection raise subclasses of
# DB::Error, told apart by SQLite's extended result code; the message is
# SQLite's own, as before. This program links SQLite through FFI, so it
# cannot run under CRuby: its snapshot comes from the compiled binary.

DB = Cybertrain::DB

def items_db
  conn = DB::Connection.new(":memory:")
  conn.exec_script(
    "CREATE TABLE items (id INTEGER PRIMARY KEY, slug TEXT NOT NULL); " \
    "CREATE UNIQUE INDEX index_items_on_slug ON items (slug); " \
    "CREATE TABLE notes (id INTEGER PRIMARY KEY, item_id INTEGER, " \
    "FOREIGN KEY(item_id) REFERENCES items(id));"
  )
  conn
end

test "the subclasses of DB::Error exist" do
  assert DB::UniqueViolation.new("x").is_a?(DB::Error)
  assert DB::ForeignKeyViolation.new("x").is_a?(DB::Error)
  assert DB::Deadlock.new("x").is_a?(DB::Error)
  assert DB::LockTimeout.new("x").is_a?(DB::Error)
  assert DB::ConnectionLost.new("x").is_a?(DB::Error)
end

test "a unique index violation is a UniqueViolation with SQLite's message" do
  conn = items_db
  conn.execute("INSERT INTO items (slug) VALUES (?)", ["a"])
  caught = nil
  begin
    conn.execute("INSERT INTO items (slug) VALUES (?)", ["a"])
  rescue DB::Error => e
    caught = e
  end
  assert !caught.nil?
  assert caught.is_a?(DB::UniqueViolation)
  refute caught.is_a?(DB::ForeignKeyViolation)
  assert_equal "UNIQUE constraint failed: items.slug (sql: INSERT INTO items (slug) VALUES (?))", caught.message
  conn.close
end

test "a primary key violation is a UniqueViolation" do
  conn = items_db
  conn.execute("INSERT INTO items (id, slug) VALUES (?, ?)", [1, "a"])
  caught = nil
  begin
    conn.execute("INSERT INTO items (id, slug) VALUES (?, ?)", [1, "b"])
  rescue DB::Error => e
    caught = e
  end
  assert !caught.nil?
  assert caught.is_a?(DB::UniqueViolation)
  assert_equal "UNIQUE constraint failed: items.id (sql: INSERT INTO items (id, slug) VALUES (?, ?))", caught.message
  conn.close
end

test "a foreign key violation is a ForeignKeyViolation with SQLite's message" do
  conn = items_db
  conn.exec_script("PRAGMA foreign_keys = ON")
  caught = nil
  begin
    conn.execute("INSERT INTO notes (item_id) VALUES (?)", [99])
  rescue DB::Error => e
    caught = e
  end
  assert !caught.nil?
  assert caught.is_a?(DB::ForeignKeyViolation)
  refute caught.is_a?(DB::UniqueViolation)
  assert_equal "FOREIGN KEY constraint failed (sql: INSERT INTO notes (item_id) VALUES (?))", caught.message
  conn.close
end

test "a script's constraint failure is classified too" do
  conn = items_db
  caught = nil
  begin
    conn.exec_script("INSERT INTO items (slug) VALUES ('s'); INSERT INTO items (slug) VALUES ('s');")
  rescue DB::Error => e
    caught = e
  end
  assert !caught.nil?
  assert caught.is_a?(DB::UniqueViolation)
  conn.close
end

test "other failures stay plain DB::Error" do
  conn = items_db
  caught = nil
  begin
    conn.execute("INSERT INTO items (slug) VALUES (?)", [nil])
  rescue DB::Error => e
    caught = e
  end
  assert !caught.nil?
  refute caught.is_a?(DB::UniqueViolation)
  refute caught.is_a?(DB::ForeignKeyViolation)
  assert_equal "Cybertrain::DB::Error", caught.class.name
  conn.close
end

Cybertrain::Test.run!
