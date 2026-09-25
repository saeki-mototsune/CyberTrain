require_relative "adapter"
conn = Connection.new(":memory:")
a = Adapter.new(conn)
a.execute("CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT)", [])
a.execute("CREATE TABLE post_tags (post_id INTEGER, tag_id INTEGER, FOREIGN KEY(tag_id) REFERENCES tags(id))", [])
a.execute("PRAGMA foreign_key_list(post_tags)", []).each { |r|
  puts r["table"].to_s + " " + r["from"].to_s + "->" + r["to"].to_s
}
conn.close
puts "fk ok"
