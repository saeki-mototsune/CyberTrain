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
ENV.delete("CYBERTRAIN_DATABASE")
ENV["CYBERTRAIN_ENV"] = "test"

def remove_app_root
  ["storage/test.sqlite3-wal", "storage/test.sqlite3-shm", "storage/test.sqlite3", "db/schema.rb"].each do |f|
    File.delete("#{ROOT}/#{f}") if File.exist?("#{ROOT}/#{f}")
  end
  ["storage", "db", ""].each { |d| Dir.rmdir("#{ROOT}/#{d}") if Dir.exist?("#{ROOT}/#{d}") }
end

remove_app_root
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(ROOT)
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
