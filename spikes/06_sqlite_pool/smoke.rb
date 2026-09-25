# SPIKE (throwaway): basic prepared statement + binds + column
# type/value round trip, in-memory DB, single thread.
require_relative "sqlite3_lib"

rc = SQL.sqlite3_open_v2(":memory:", SQL.db_out,
                          SQL::OPEN_READWRITE | SQL::OPEN_CREATE, nil)
raise "open failed: #{rc}" if rc != SQL::OK
db = SQL.read_ptr(SQL.db_out)

rc = SQL.sqlite3_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL)", nil, nil, nil)
raise "create failed: #{SQL.sqlite3_errmsg(db)}" if rc != SQL::OK

rc = SQL.sqlite3_prepare_v2(db, "INSERT INTO t (name, score) VALUES (?, ?)", -1, SQL.stmt_out, nil)
raise "prepare failed: #{SQL.sqlite3_errmsg(db)}" if rc != SQL::OK
stmt = SQL.read_ptr(SQL.stmt_out)

# bind_text with the SQLITE_TRANSIENT destructor as plain -1 literal.
SQL.sqlite3_bind_text(stmt, 1, "hello world", -1, -1)
SQL.sqlite3_bind_double(stmt, 2, 3.5)
rc = SQL.sqlite3_step(stmt)
raise "step 1 failed: #{rc} #{SQL.sqlite3_errmsg(db)}" if rc != SQL::DONE
SQL.sqlite3_reset(stmt)

# second row: NULL score
SQL.sqlite3_bind_text(stmt, 1, "nully", -1, -1)
SQL.sqlite3_bind_null(stmt, 2)
rc = SQL.sqlite3_step(stmt)
raise "step 2 failed: #{rc}" if rc != SQL::DONE
SQL.sqlite3_finalize(stmt)

puts "last_insert_rowid=" + SQL.sqlite3_last_insert_rowid(db).to_s
puts "changes=" + SQL.sqlite3_changes(db).to_s

rc = SQL.sqlite3_prepare_v2(db, "SELECT id, name, score FROM t ORDER BY id", -1, SQL.stmt_out, nil)
raise "prepare select failed" if rc != SQL::OK
stmt2 = SQL.read_ptr(SQL.stmt_out)

while SQL.sqlite3_step(stmt2) == SQL::ROW
  id = SQL.sqlite3_column_int64(stmt2, 0)
  name = SQL.sqlite3_column_text(stmt2, 1)
  name = (name == nil) ? "" : (name + "")
  score_type = SQL.sqlite3_column_type(stmt2, 2)
  if score_type == SQL::NULL_TYPE
    puts id.to_s + " " + name + " score=NULL"
  else
    puts id.to_s + " " + name + " score=" + SQL.sqlite3_column_double(stmt2, 2).to_s
  end
end
SQL.sqlite3_finalize(stmt2)

SQL.sqlite3_close(db)
puts "smoke ok"
