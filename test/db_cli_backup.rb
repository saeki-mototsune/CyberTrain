require "cybertrain/db/cli"
require "cybertrain/test"

# `db backup` and `db vacuum` (Cybertrain::DB::CLI, issue #76): the copy is
# written by SQLite into a 0700 temporary directory, chmod 0600 and renamed
# into place, an existing target is refused without --force, a failed copy
# leaves nothing behind, `backup DIR/ --keep N` names the copy by date and
# keeps the newest N of that shape only, and vacuum shrinks the file after
# deletes and leaves the WAL empty.
#
# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

CLI = Cybertrain::DB::CLI
Conn = Cybertrain::DB::Connection

# A fixed root (not Dir.mktmpdir) so that the paths the CLI prints are the
# same on every run.
ROOT = "tmp/db_cli_backup_test"
SOURCE = "#{ROOT}/storage/test.sqlite3"
COPY = "#{ROOT}/copy.sqlite3"
BACKUPS = "#{ROOT}/backups"
ENV.delete("CYBERTRAIN_DATABASE")
ENV["CYBERTRAIN_ENV"] = "test"

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

remove_tree(ROOT)
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(ROOT)
Dir.mkdir("#{ROOT}/storage")
at_exit { remove_tree(ROOT) }

def run_db(*argv)
  CLI.run(argv, ROOT, "app")
end

# Adds count rows of filler text to notes in the database at path.
def add_notes(path, count)
  conn = Conn.new(path)
  conn.exec_script("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
  filler = "x" * 400
  conn.exec_script("BEGIN")
  n = 0
  while n < count
    conn.execute("INSERT INTO notes (body) VALUES (?)", [filler])
    n += 1
  end
  conn.exec_script("COMMIT")
  conn.close
  nil
end

# The number of notes in the database file at path, opened without create.
def notes_in(path)
  conn = Conn.new(path, create: false)
  rows = conn.execute("SELECT count(*) AS n FROM notes")
  conn.close
  Cybertrain::Cast.int(rows[0]["n"])
end

def mode_of(path)
  File.stat(path).mode & 0o777
end

# Entries of dir whose name holds ".tmp-" (a temporary copy left behind).
def temporaries_in(dir)
  found = 0
  Dir.children(dir).each { |entry| found += 1 unless entry.index(".tmp-").nil? }
  found
end

def sorted_children(dir)
  Dir.children(dir).sort.join(",")
end

add_notes(SOURCE, 50)

test "backup writes a 0600 copy, through a temporary name, that opens with the rows" do
  assert_equal 0, run_db("backup", COPY)
  assert File.file?(COPY)
  assert_equal 0o600, mode_of(COPY)
  assert_equal 50, notes_in(COPY)
  assert_equal 0, temporaries_in(ROOT)
end

test "an existing target is refused without --force and left as it was" do
  add_notes(SOURCE, 10)
  assert_equal 1, run_db("backup", COPY)
  assert_equal 50, notes_in(COPY)
  assert_equal 0, temporaries_in(ROOT)
end

test "--force replaces the target with a new copy, still 0600" do
  assert_equal 0, run_db("backup", COPY, "--force")
  assert_equal 60, notes_in(COPY)
  assert_equal 0o600, mode_of(COPY)
  assert_equal 0, temporaries_in(ROOT)
end

test "the database itself is never a target, even with --force" do
  assert_equal 1, run_db("backup", SOURCE, "--force")
  assert_equal 60, notes_in(SOURCE)
end

test "a failed copy leaves neither the target nor a temporary file" do
  File.write("#{ROOT}/garbage.sqlite3", "this is not a database, only text that is long enough to be read" * 20)
  ENV["CYBERTRAIN_DATABASE"] = "garbage.sqlite3"
  status = run_db("backup", "#{ROOT}/bad.sqlite3")
  ENV.delete("CYBERTRAIN_DATABASE")
  assert_equal 1, status
  refute File.exist?("#{ROOT}/bad.sqlite3")
  assert_equal 0, temporaries_in(ROOT)
end

test "a missing target directory, a missing database and :memory: are refused" do
  assert_equal 1, run_db("backup", "#{ROOT}/nowhere/copy.sqlite3")
  ENV["CYBERTRAIN_DATABASE"] = "missing.sqlite3"
  missing_status = run_db("backup", "#{ROOT}/m.sqlite3")
  ENV["CYBERTRAIN_DATABASE"] = ":memory:"
  memory_status = run_db("backup", "#{ROOT}/m.sqlite3")
  vacuum_status = run_db("vacuum")
  ENV.delete("CYBERTRAIN_DATABASE")
  assert_equal 1, missing_status
  assert_equal 1, memory_status
  assert_equal 1, vacuum_status
  refute File.exist?("#{ROOT}/missing.sqlite3")
  refute File.exist?("#{ROOT}/m.sqlite3")
end

test "bad arguments are refused" do
  assert_equal 1, run_db("backup")
  assert_equal 1, run_db("backup", COPY, "--keep", "2")
  assert_equal 1, run_db("backup", "#{BACKUPS}/", "--keep", "0")
  assert_equal 1, run_db("backup", "#{BACKUPS}/", "--keep")
  assert_equal 1, run_db("backup", COPY, "--fast")
  assert_equal 1, run_db("backup", COPY, "other.sqlite3")
  assert_equal 1, run_db("vacuum", "now")
  refute File.exist?(BACKUPS)
end

test "dated_backup? matches only <name>-YYYYmmddTHHMMSSZ.sqlite3" do
  assert CLI.dated_backup?("app-20261025T123456Z.sqlite3", "app")
  refute CLI.dated_backup?("app-20261025T123456Z.sqlite3.tmp-1-ab", "app")
  refute CLI.dated_backup?("other-20261025T123456Z.sqlite3", "app")
  refute CLI.dated_backup?("app-2026102XT123456Z.sqlite3", "app")
  refute CLI.dated_backup?("app-20261025-123456Z.sqlite3", "app")
  refute CLI.dated_backup?("app-notes.sqlite3", "app")
end

test "backup DIR/ writes a dated copy in a 0700 directory and --keep N prunes its own kind only" do
  Dir.mkdir(BACKUPS, 0o700)
  ["app-20260101T000000Z.sqlite3", "app-20260102T000000Z.sqlite3", "app-20260103T000000Z.sqlite3",
   "other-20250101T000000Z.sqlite3", "app-notes.txt"].each { |old| File.write("#{BACKUPS}/#{old}", "old") }
  assert_equal 0, CLI.backup(ROOT, ["#{BACKUPS}/", "--keep", "2"], "app", Time.at(1792931696).utc)
  assert_equal "app-20260103T000000Z.sqlite3,app-20261025T123456Z.sqlite3,app-notes.txt,other-20250101T000000Z.sqlite3",
               sorted_children(BACKUPS)
  assert_equal 60, notes_in("#{BACKUPS}/app-20261025T123456Z.sqlite3")
  assert_equal 0o600, mode_of("#{BACKUPS}/app-20261025T123456Z.sqlite3")
end

test "backup DIR/ makes the directory, mode 0700, and refuses the same second twice" do
  fresh = "#{ROOT}/fresh"
  assert_equal 0, CLI.backup(ROOT, ["#{fresh}/"], "app", Time.at(1792931696).utc)
  assert_equal 0o700, mode_of(fresh)
  assert_equal "app-20261025T123456Z.sqlite3", sorted_children(fresh)
  assert_raises("Error") { CLI.backup(ROOT, ["#{fresh}/"], "app", Time.at(1792931696).utc) }
  assert_equal "app-20261025T123456Z.sqlite3", sorted_children(fresh)
end

test "vacuum shrinks the file after deletes and checkpoints the WAL to empty" do
  shrink = "#{ROOT}/shrink.sqlite3"
  add_notes(shrink, 2000)
  conn = Conn.new(shrink)
  conn.execute("DELETE FROM notes WHERE id > 10")
  conn.close
  sizes = CLI.vacuum_database(shrink)
  assert sizes[1] < sizes[0], "#{sizes[1]} bytes after, #{sizes[0]} before"
  assert sizes[1] < 100_000, "#{sizes[1]} bytes after"
  assert_equal 0, sizes[2]
  wal = "#{shrink}-wal"
  assert_equal 0, File.exist?(wal) ? File.size(wal) : 0
  assert_equal 10, notes_in(shrink)
end

Cybertrain::Test.run!
