require "cybertrain/db/cli"
require "cybertrain/test"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class CreatePosts < Cybertrain::Migration::Base
  version "20260101000000"

  def change
    create_table "posts" do |t|
      t.string "title", null: false
      t.timestamps
    end
  end
end

class CreateComments < Cybertrain::Migration::Base
  version "20260101000100"

  def change
    create_table "comments" do |t|
      t.references :post
      t.text "body", null: false
    end
  end
end

Cybertrain::Migration.reset!
Cybertrain::Migration.register("20260101000100", CreateComments.new)
Cybertrain::Migration.register("20260101000000", CreatePosts.new)

# A fixed app root (not Dir.mktmpdir) so the paths the CLI prints are
# deterministic in the snapshot.
ROOT = "tmp/db_cli_test"
# A second root without a db/ directory (a deployed dist/): migrate there
# must not create one.
NODB_ROOT = "tmp/db_cli_test_nodb"
ENV.delete("CYBERTRAIN_DATABASE")
ENV["CYBERTRAIN_ENV"] = "test"

# The ":memory:" entries only exist when resolved_path regresses to a file
# under the root; removing them keeps a rerun from tripping over them.
def remove_root(root)
  ["storage/test.sqlite3-wal", "storage/test.sqlite3-shm", "storage/test.sqlite3", "db/schema.rb",
   "missing.sqlite3-wal", "missing.sqlite3-shm", "missing.sqlite3",
   ":memory:-wal", ":memory:-shm", ":memory:"].each do |f|
    File.delete("#{root}/#{f}") if File.exist?("#{root}/#{f}")
  end
  ["storage", "db", ""].each { |d| Dir.rmdir("#{root}/#{d}") if Dir.exist?("#{root}/#{d}") }
end

def remove_app_root
  remove_root(ROOT)
  remove_root(NODB_ROOT)
end

remove_app_root
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(ROOT)
Dir.mkdir("#{ROOT}/db")
Dir.mkdir(NODB_ROOT)
at_exit { remove_app_root }

def run_db(*argv)
  Cybertrain::DB::CLI.run(argv, ROOT)
end

test "database_path defaults to storage/<env>.sqlite3" do
  assert_equal "storage/test.sqlite3", Cybertrain::DB::CLI.database_path
  assert_equal "#{ROOT}/storage/test.sqlite3", Cybertrain::DB::CLI.resolved_path(ROOT)
end

test "an absolute CYBERTRAIN_DATABASE is used as is" do
  ENV["CYBERTRAIN_DATABASE"] = "/var/db/app.sqlite3"
  assert_equal "/var/db/app.sqlite3", Cybertrain::DB::CLI.resolved_path(ROOT)
  ENV.delete("CYBERTRAIN_DATABASE")
end

test ":memory: and file: URIs are SQLite names, not files under the root" do
  ENV["CYBERTRAIN_DATABASE"] = ":memory:"
  assert_equal ":memory:", Cybertrain::DB::CLI.resolved_path(ROOT)
  ENV["CYBERTRAIN_DATABASE"] = "file:blog?mode=memory&cache=shared"
  assert_equal "file:blog?mode=memory&cache=shared", Cybertrain::DB::CLI.resolved_path(ROOT)
  ENV.delete("CYBERTRAIN_DATABASE")
end

test "create and status on :memory: leave no file named :memory: behind" do
  ENV["CYBERTRAIN_DATABASE"] = ":memory:"
  assert_equal 0, run_db("create")
  assert_equal 0, run_db("status")
  refute File.exist?("#{ROOT}/:memory:")
  refute File.exist?(":memory:")
  ENV.delete("CYBERTRAIN_DATABASE")
end

test "a file: URI with mode=memory is opened as a URI, never as a file of that name" do
  ENV["CYBERTRAIN_DATABASE"] = "file:db_cli_shared?mode=memory&cache=shared"
  assert_equal 0, run_db("create")
  assert_equal 0, run_db("status")
  refute File.exist?("file:db_cli_shared?mode=memory&cache=shared")
  refute File.exist?("db_cli_shared")
  ENV.delete("CYBERTRAIN_DATABASE")
end

# The URI names a file in a directory that exists, so only the open flags
# keep SQLite from creating it.
test "status on a file: URI naming a missing file fails with exit code 1 instead of creating it" do
  ENV["CYBERTRAIN_DATABASE"] = "file:#{ROOT}/missing.sqlite3"
  assert_equal 1, run_db("status")
  assert_equal 1, run_db("rollback")
  assert_equal 1, run_db("schema:dump")
  refute File.exist?("#{ROOT}/missing.sqlite3")
  refute File.exist?("#{ROOT}/missing.sqlite3-wal")
  ENV.delete("CYBERTRAIN_DATABASE")
end

test "no arguments or an unknown command prints usage and returns 1" do
  assert_equal 1, run_db
  assert_equal 1, run_db("explode")
end

test "status on a missing database fails with exit code 1 instead of creating it" do
  assert_equal 1, run_db("status")
  refute File.exist?("#{ROOT}/storage/test.sqlite3")
end

test "create makes the database file and its directory" do
  assert_equal 0, run_db("create")
  assert File.exist?("#{ROOT}/storage/test.sqlite3")
  assert_equal 0, run_db("create")
end

test "migrate applies every registered migration and writes db/schema.rb" do
  assert_equal 0, run_db("migrate")
  schema = File.read("#{ROOT}/db/schema.rb")
  assert_includes schema, "Cybertrain::Schema.define(version: \"20260101000100\") do |s|"
  assert_includes schema, "t.text \"body\", null: false"
  assert_includes schema, "s.add_foreign_key \"comments\", \"posts\", column: \"post_id\""
end

test "status lists each migration as up" do
  assert_equal 0, run_db("status")
end

test "rollback reverts the newest migration and rewrites db/schema.rb" do
  assert_equal 0, run_db("rollback")
  schema = File.read("#{ROOT}/db/schema.rb")
  assert_includes schema, "version: \"20260101000000\""
  refute schema.include?("comments")
  assert_equal 0, run_db("status")
end

test "schema:dump rewrites db/schema.rb from the database" do
  File.delete("#{ROOT}/db/schema.rb")
  assert_equal 0, run_db("schema:dump")
  assert_includes File.read("#{ROOT}/db/schema.rb"), "s.create_table \"posts\" do |t|"
end

test "rollback 2 after re-migrating returns to an empty schema" do
  assert_equal 0, run_db("migrate")
  assert_equal 0, run_db("rollback", "2")
  schema = File.read("#{ROOT}/db/schema.rb")
  assert_includes schema, "version: \"0\""
  refute schema.include?("create_table")
end

test "migrate skips the schema dump when the root has no db/ directory" do
  assert_equal 0, Cybertrain::DB::CLI.run(["migrate"], NODB_ROOT)
  assert File.exist?("#{NODB_ROOT}/storage/test.sqlite3")
  refute Dir.exist?("#{NODB_ROOT}/db")
  refute File.exist?("#{NODB_ROOT}/db/schema.rb")
end

test "an explicit schema:dump where there is no db/ directory returns 1" do
  assert_equal 1, Cybertrain::DB::CLI.run(["schema:dump"], NODB_ROOT)
  refute Dir.exist?("#{NODB_ROOT}/db")
end

test "an empty CYBERTRAIN_DATABASE counts as unset" do
  ENV["CYBERTRAIN_DATABASE"] = ""
  assert_equal "storage/test.sqlite3", Cybertrain::DB::CLI.database_path
  assert_equal "#{ROOT}/storage/test.sqlite3", Cybertrain::DB::CLI.resolved_path(ROOT)
  ENV.delete("CYBERTRAIN_DATABASE")
end

test "rollback N accepts only a positive integer" do
  assert_equal 1, Cybertrain::DB::CLI.rollback_steps(["rollback"])
  assert_equal 3, Cybertrain::DB::CLI.rollback_steps(["rollback", "3"])
  assert_equal 0, Cybertrain::DB::CLI.rollback_steps(["rollback", "abc"])
  assert_equal 0, Cybertrain::DB::CLI.rollback_steps(["rollback", "-1"])
  assert_equal 0, Cybertrain::DB::CLI.rollback_steps(["rollback", ""])
  assert_equal 1, run_db("rollback", "abc")
  assert_equal 1, run_db("rollback", "0")
  assert_equal 1, run_db("rollback", "-1")
end

test "rollback fails with exit code 1 when an applied version has no migration" do
  connection = Cybertrain::DB::Connection.new(Cybertrain::DB::CLI.resolved_path(ROOT))
  connection.execute("INSERT INTO schema_migrations (version) VALUES (?)", ["4"])
  connection.close
  assert_equal 1, run_db("rollback")
  assert_equal 0, run_db("status")
end

Cybertrain::Test.run!
