# SPIKE (throwaway): SizedQueue-backed pool of N=4 Connections shared
# by 8 Threads, each doing 200 INSERTs + SELECTs against a file DB
# (WAL mode). Verifies row counts, no crashes/races, and measures
# throughput; also compares single-thread transactional vs autocommit
# insert throughput.
require_relative "adapter"

DB_PATH = "pool_test.sqlite3"
File.delete(DB_PATH) if File.exist?(DB_PATH)
File.delete(DB_PATH + "-wal") if File.exist?(DB_PATH + "-wal")
File.delete(DB_PATH + "-shm") if File.exist?(DB_PATH + "-shm")

N_CONNS = 4
N_THREADS = 8
N_PER_THREAD = 200

setup_conn = Connection.new(DB_PATH)
setup_a = Adapter.new(setup_conn)
setup_a.execute(
  "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, " +
  "thread_id INTEGER, seq INTEGER, title TEXT, rating REAL)", [])
setup_conn.close

# --- Pool ---
pool = SizedQueue.new(N_CONNS)
conns = []
i = 0
while i < N_CONNS
  c = Connection.new(DB_PATH)
  conns << c
  pool << Adapter.new(c)
  i += 1
end

errors = Mutex.new
error_list = []

start = Time.now
threads = []
t = 0
while t < N_THREADS
  tid = t
  threads << Thread.new {
    begin
      j = 0
      while j < N_PER_THREAD
        a = pool.pop
        begin
          a.execute("INSERT INTO posts (thread_id, seq, title, rating) VALUES (?, ?, ?, ?)",
                     [tid, j, "t" + tid.to_s + "-" + j.to_s, j * 1.5])
          rows = a.execute("SELECT COUNT(*) AS n FROM posts WHERE thread_id = ?", [tid])
        ensure
          pool << a
        end
        j += 1
      end
    rescue => e
      errors.synchronize { error_list << (e.message) }
    end
  }
  t += 1
end
threads.each { |th| th.join }
elapsed = Time.now - start

# drain pool, close all
i = 0
while i < N_CONNS
  pool.pop
  i += 1
end
conns.each { |c| c.close }

verify_conn = Connection.new(DB_PATH)
verify_a = Adapter.new(verify_conn)
total = verify_a.execute("SELECT COUNT(*) AS n FROM posts", [])[0]["n"]
expected = N_THREADS * N_PER_THREAD

puts "pool test: " + total.to_s + " rows (expected " + expected.to_s + ")"
puts "errors: " + error_list.size.to_s
error_list.each { |m| puts "  " + m }
puts "elapsed: " + elapsed.to_s + "s for " + (N_THREADS * N_PER_THREAD * 2).to_s + " statements (insert+select)"
verify_conn.close

# --- Single-thread throughput: transaction vs autocommit ---
File.delete(DB_PATH) if File.exist?(DB_PATH)
c2 = Connection.new(DB_PATH)
a2 = Adapter.new(c2)
a2.execute("CREATE TABLE t2 (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)", [])

N_SINGLE = 2000

start2 = Time.now
i2 = 0
while i2 < N_SINGLE
  a2.execute("INSERT INTO t2 (v) VALUES (?)", [i2])
  i2 += 1
end
autocommit_elapsed = Time.now - start2

a2.execute("DELETE FROM t2", [])

start3 = Time.now
a2.execute("BEGIN", [])
i3 = 0
while i3 < N_SINGLE
  a2.execute("INSERT INTO t2 (v) VALUES (?)", [i3])
  i3 += 1
end
a2.execute("COMMIT", [])
txn_elapsed = Time.now - start3

puts ""
puts "single-thread " + N_SINGLE.to_s + " inserts:"
puts "  autocommit: " + autocommit_elapsed.to_s + "s (" + (N_SINGLE / autocommit_elapsed).to_s + " inserts/s)"
puts "  in txn:     " + txn_elapsed.to_s + "s (" + (N_SINGLE / txn_elapsed).to_s + " inserts/s)"

c2.close
puts "pool_test done"
