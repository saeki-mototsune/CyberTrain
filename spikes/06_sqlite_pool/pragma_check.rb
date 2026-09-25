require_relative "adapter"
c = Connection.new("pragma_check.sqlite3")
a = Adapter.new(c)
r = a.execute("PRAGMA journal_mode", [])
puts r.inspect
c.close
