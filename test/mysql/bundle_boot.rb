require "cybertrain/mysql"
require "cybertrain/test_help"
require "cybertrain/test/bundle_mysql"
require_relative "support/tables"

# A program on the whole framework with the MySQL adapter, as an
# application's gen/tests.rb is (cybertrain/mysql, cybertrain/test_help,
# cybertrain/test/bundle_mysql), against the server CYBERTRAIN_TEST_MYSQL_URL
# names (script/test-mysql runs this program): that it compiles and links no
# SQLite (no libsqlite3, no SqliteDDL, no Normalizer), that Bundle.boot
# migrates the test database and boots the application on it, and that
# Main's database words are MySQL's (`db` through DB::CLI's MySQL part, the
# help lines).
#
# It boots on cybertrain_tdb_test, which test/mysql/test_database.rb also
# uses (script/mysql-dev and CI's mysql-tests job create it): the bundle
# empties the database it boots on, so it cannot be the shared
# cybertrain_test. This program drops what it made there before and after,
# by name (MySQLTestTables.drop), and leaves it empty.

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# URL with its database name replaced by `name` (the parameters kept).
def url_for(name)
  q = URL.index("?")
  head = q.nil? ? URL : URL[0, q].to_s
  tail = q.nil? ? "" : URL[q, URL.size - q].to_s
  slash = head.rindex("/").to_i
  "#{head[0, slash]}/#{name}#{tail}"
end

TEST_URL = url_for("cybertrain_tdb_test")

class CreateBootNotes < Cybertrain::Migration::Base
  def change
    create_table "boot_notes" do |t|
      t.string "title", null: false
      t.timestamps
    end
  end
end
Cybertrain::Migration.register("20261127000000", CreateBootNotes.new)

# What boot makes in cybertrain_tdb_test: the marker, the Migrator's table,
# the migration's, and any framework table the boot creates.
OWN_TABLES = ["cybertrain_test_marker", "schema_migrations", "boot_notes", "cybertrain_jobs", "cybertrain_cache",
              "cybertrain_leases", "cybertrain_messages", "cybertrain_schedules", "cybertrain_feeds"]

def drop_own_tables
  conn = Cybertrain::DB::Connection.new(TEST_URL)
  MySQLTestTables.drop(conn, OWN_TABLES)
  conn.close
  nil
end

def tables_of_test_database
  conn = Cybertrain::DB::Connection.new(TEST_URL)
  names = Cybertrain::DB::Dialect.table_names(conn)
  conn.close
  names
end

def bundle_config(env, url)
  c = Cybertrain::Config.new
  c.env = env
  c.database_url = url
  c.secret_key_base = "test-bundle-secret"
  c.views_root = "tmp/mysql_bundle_boot/views"
  c.public_root = "tmp/mysql_bundle_boot/public"
  c.log_level = :none
  Cybertrain.config = c
  c
end

def bundle_boot
  Cybertrain::Test::Bundle.boot(Cybertrain::Router.new, ->(name, args, options) { "/" })
end

drop_own_tables
at_exit { drop_own_tables }

test "the program is built with the MySQL adapter" do
  assert_equal "mysql", Cybertrain::DB::Adapter.adapter_name
end

test "boot refuses a database whose name does not end in _test, before anything connects" do
  bundle_config("test", url_for("cybertrain_tdb"))
  label = Cybertrain::DB::MySQL::Url.parse(url_for("cybertrain_tdb")).to_s
  assert_equal "cybertrain test refuses to empty #{label}: not a test database (its name does not end in _test)",
               Cybertrain::Test::Bundle.refusal
end

test "boot migrates the test database and boots the application on it" do
  bundle_config("test", TEST_URL)
  assert_equal "", Cybertrain::Test::Bundle.refusal
  app = bundle_boot
  assert app.booted?
  assert Cybertrain::Test.app.booted?
  names = tables_of_test_database
  assert names.include?("cybertrain_test_marker")
  assert names.include?("boot_notes")
  assert names.include?("schema_migrations")
  # The application's pool is on the test database.
  count = Cybertrain::DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM boot_notes") }
  assert_equal 0, Cybertrain::Cast.int(count[0]["n"])
  app.shutdown
  Cybertrain::Runtime.reset!
end

test "a second boot empties the database and migrates again" do
  bundle_config("test", TEST_URL)
  conn = Cybertrain::DB::Connection.new(TEST_URL)
  conn.execute("INSERT INTO boot_notes (title, created_at, updated_at) VALUES ('left', NOW(6), NOW(6))")
  conn.close
  app = bundle_boot
  count = Cybertrain::DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM boot_notes") }
  assert_equal 0, Cybertrain::Cast.int(count[0]["n"])
  app.shutdown
  Cybertrain::Runtime.reset!
end

test "Main's db word runs DB::CLI's MySQL part on DATABASE_URL" do
  bundle_config("test", TEST_URL)
  status = Cybertrain::Main.run("shop", ["db", "status"], router: Cybertrain::Router.new,
                                                          url_resolver: ->(name, args, options) { "/" },
                                                          views: { "" => "" })
  assert_equal 0, status
  assert_equal 2, Cybertrain::Main.run("shop", ["db", "backup", "tmp/x"], router: Cybertrain::Router.new,
                                                                          url_resolver: ->(name, args, options) { "/" },
                                                                          views: { "" => "" })
end

test "help names MySQL's db commands and client" do
  usage = Cybertrain::Main.usage("shop")
  assert_includes usage, "  ./shop db COMMAND        migrate | rollback [N] | status | schema | schema:dump | create | drop\n"
  assert_includes usage, "  ./shop dbconsole         open the mysql client on the database\n"
  assert_nil usage.index("vacuum")
  assert_nil usage.index("sqlite")
end

Cybertrain::Test.run!
