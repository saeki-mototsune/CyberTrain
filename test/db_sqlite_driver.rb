# The SQLite Connection's side of methods the MySQL Connection added, so
# that code above the adapter can call them on either.
require "cybertrain/db"
require "cybertrain/test"

test "forget_last_insert_id is a no-op on SQLite, and refused once closed" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)")
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["a"])
  assert_equal 1, conn.last_insert_id
  assert_nil conn.forget_last_insert_id
  # SQLite's own last rowid is kept: nothing here to forget.
  assert_equal 1, conn.last_insert_id
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["b"])
  assert_equal 2, conn.last_insert_id
  conn.close
  message = assert_raises("Cybertrain::DB::Error") { conn.forget_last_insert_id }
  assert_equal "connection closed (forget_last_insert_id)", message
end

Cybertrain::Test.run!
