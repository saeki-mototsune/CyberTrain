# The migrator, schema dumper and bin/db CLI compiled together with the
# whole framework.
#
# test/migrator.rb, test/schema_dumper.rb and test/db_cli.rb require only
# the db files, so a method name they share with another framework file
# (Migrator#status next to Response#status and Controller#status, the
# migration DSL's add_index next to Schema's: spikes/NOTES.md rules 10, 34
# and 41) would compile there and break only once both are in one program.
# This program requires the framework entry point plus cybertrain/db/cli,
# migrates a database through the CLI, and drives a controller with
# stored blocks against the migrated table (rule 36).
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/db/cli"
require "cybertrain/test"
require "cybertrain/test/client"

class CreateNotes < Cybertrain::Migration::Base
  version "20260101000000"

  def change
    create_table "notes" do |t|
      t.string "title", null: false
      t.boolean "pinned", null: false, default: "0"
      t.timestamps
    end
    add_index "notes", ["title"]
  end
end

Cybertrain::Migration.reset!
Cybertrain::Migration.register("20260101000000", CreateNotes.new)

ROOT = "tmp/db_integration_test"
ENV["CYBERTRAIN_ENV"] = "test"
ENV.delete("CYBERTRAIN_DATABASE")

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

class NotesController < Cybertrain::Controller
  before_action { |c| c.response.set_header("X-Before", "block") }
  rescue_from(KeyError) { |c, e| c.render plain: "missing #{e.message}", status: :not_found }

  def index
    titles = Array.new(0) { "" }
    Cybertrain::DB.with do |conn|
      conn.execute("SELECT title FROM notes ORDER BY id").each { |r| titles << r["title"].to_s }
    end
    render plain: titles.join(",")
  end

  def missing
    raise KeyError, "the key"
  end
end

def notes_client
  router = Cybertrain::Router.new
  router.get("/notes", "notes") { |ctx| NotesController.new(ctx).process(:index) { |c| c.index } }
  router.get("/missing", "missing") { |ctx| NotesController.new(ctx).process(:missing) { |c| c.missing } }
  Cybertrain::Test::Client.new(Cybertrain::App.new(router, logging: false))
end

test "bin/db migrate builds the database and dumps a typed db/schema.rb" do
  assert_equal 0, Cybertrain::DB::CLI.run(["migrate"], ROOT)
  schema = File.read("#{ROOT}/db/schema.rb")
  assert_includes schema, "t.boolean \"pinned\", null: false, default: \"0\""
  assert_includes schema, "t.datetime \"created_at\", null: false"
  assert_includes schema, "s.add_index \"notes\", [\"title\"], name: \"index_notes_on_title\""
end

test "the migrator reports status next to controllers and responses" do
  connection = Cybertrain::DB::Connection.new(Cybertrain::DB::CLI.resolved_path(ROOT))
  rows = Cybertrain::DB::Migrator.new(connection).status(Cybertrain::Migration.all)
  assert_equal [["up", "20260101000000", "CreateNotes"]], rows
  definition = Cybertrain::DB::SchemaDumper.dump(connection)
  assert_equal "boolean", definition.table("notes").column("pinned").type.to_s
  connection.close
end

test "a controller with stored blocks reads the migrated table" do
  Cybertrain::DB.connect(Cybertrain::DB::CLI.resolved_path(ROOT), size: 1)
  Cybertrain::DB.with do |conn|
    conn.execute("INSERT INTO notes (title, created_at, updated_at) VALUES (?, ?, ?)", ["first", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"])
    conn.execute("INSERT INTO notes (title, created_at, updated_at) VALUES (?, ?, ?)", ["second", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"])
  end
  client = notes_client
  page = client.get("/notes")
  assert_response page, :ok
  assert_equal "first,second", page.body
  assert_equal "block", page.header("x-before")
  missing = client.get("/missing")
  assert_response missing, :not_found
  assert_equal "missing the key", missing.body
  Cybertrain::DB.disconnect
end

test "bin/db rollback drops the table and rewrites db/schema.rb" do
  assert_equal 0, Cybertrain::DB::CLI.run(["rollback"], ROOT)
  refute File.read("#{ROOT}/db/schema.rb").include?("notes")
end

Cybertrain::Test.run!
