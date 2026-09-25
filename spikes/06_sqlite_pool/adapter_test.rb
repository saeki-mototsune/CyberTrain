# SPIKE (throwaway): exercise Adapter#execute with mixed bind types,
# NULLs, and check the Hash<String, value> row shape compiles and
# holds Integer/Float/String/nil together.
require_relative "adapter"

conn = Connection.new(":memory:")
a = Adapter.new(conn)

a.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, views INTEGER, rating REAL)", [])
a.execute("INSERT INTO posts (title, views, rating) VALUES (?, ?, ?)", ["hello", 10, 4.5])
a.execute("INSERT INTO posts (title, views, rating) VALUES (?, ?, ?)", ["world", nil, nil])
puts "last_insert_rowid=" + a.last_insert_rowid.to_s
puts "changes=" + a.changes.to_s

rows = a.execute("SELECT id, title, views, rating FROM posts ORDER BY id", [])
rows.each { |row|
  puts row["id"].to_s + " " + row["title"].to_s + " views=" + row["views"].to_s + " rating=" + row["rating"].to_s
}

# introspection
puts ""
puts "table_info:"
a.execute("PRAGMA table_info(posts)", []).each { |r|
  puts "  " + r["name"].to_s + " " + r["type"].to_s
}

puts "sqlite_master:"
a.execute("SELECT name, sql FROM sqlite_master", []).each { |r|
  puts "  " + r["name"].to_s
}

conn.close
puts "adapter_test ok"
