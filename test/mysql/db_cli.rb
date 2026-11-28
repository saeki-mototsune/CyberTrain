require "cybertrain/cast"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/db/cli"
require "cybertrain/db/mysql/cli"
require "cybertrain/config"
require "cybertrain/migration"
require "cybertrain/test"

# The database commands on MySQL (cybertrain/db/mysql/cli.rb), against the
# server CYBERTRAIN_TEST_MYSQL_URL names (script/test-mysql runs this
# program): create -> migrate -> status -> rollback -> drop of the scratch
# database cybertrain_cli_test, through DB::CLI.run only, as `./NAME db
# ...` runs them; backup, vacuum and normalize refused with exit status 2;
# the database names create and drop accept; and what dbconsole is given.
#
# `db create` and `db drop` are the only code that runs CREATE DATABASE or
# DROP DATABASE, and this program runs them only through the CLI, on
# cybertrain_cli_test (never cybertrain_test, cybertrain_tdb_test or
# cybertrain_tdb, which other programs use). The program reads
# information_schema to see what they did. What the CLI prints names the
# server by its URL without the password (Url#to_s), which is
# mysql://root@127.0.0.1:33306/... with the URL of script/mysql-dev and CI.
# The tests depend on their order (create, migrate, status, rollback,
# schema, drop): Cybertrain::Test.run! runs them in the order they are
# written.

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

CLI = Cybertrain::DB::CLI
SCRATCH = "cybertrain_cli_test"
PASSWORD = Cybertrain::DB::MySQL::Url.parse(URL).url_password
# The password as the URL holds it: "cybertrain", script/mysql-dev's, is
# also the start of every database name here.
PASSWORD_PART = ":#{PASSWORD}@"

# URL with its database name replaced by `name` (the parameters kept).
def url_for(name)
  q = URL.index("?")
  head = q.nil? ? URL : URL[0, q].to_s
  tail = q.nil? ? "" : URL[q, URL.size - q].to_s
  slash = head.rindex("/").to_i
  "#{head[0, slash]}/#{name}#{tail}"
end

class CreatePosts < Cybertrain::Migration::Base
  def change
    create_table "posts" do |t|
      t.string "title", null: false
      t.timestamps
    end
  end
end

class CreateComments < Cybertrain::Migration::Base
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

ROOT = "tmp/mysql_db_cli_test"

def remove_root
  File.delete("#{ROOT}/db/schema.rb") if File.exist?("#{ROOT}/db/schema.rb")
  Dir.rmdir("#{ROOT}/db") if Dir.exist?("#{ROOT}/db")
  Dir.rmdir(ROOT) if Dir.exist?(ROOT)
end

remove_root
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(ROOT)
Dir.mkdir("#{ROOT}/db")

def use_database(name)
  Cybertrain.config.database_url = url_for(name)
  nil
end

def run_db(*argv)
  CLI.run(argv, ROOT)
end

# Whether the server has `name`, read from the shared test database (the
# scratch one may not exist).
def database_exists?(name)
  conn = Cybertrain::DB::Connection.new(URL)
  rows = conn.execute("SELECT SCHEMA_NAME AS n FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?", [name])
  conn.close
  !rows.empty?
end

def scratch_tables
  conn = Cybertrain::DB::Connection.new(URL)
  rows = conn.execute("SELECT TABLE_NAME AS t FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME",
                      [SCRATCH])
  conn.close
  rows.map { |r| Cybertrain::Cast.str(r["t"]) }
end

# A scratch database a killed run left behind goes first (the CLI prints
# its `dropped` line then, and this run's snapshot differs once).
use_database(SCRATCH)
run_db("drop") if database_exists?(SCRATCH)
at_exit do
  use_database(SCRATCH)
  CLI.run(["drop"], ROOT) if database_exists?(SCRATCH)
  remove_root
end

test "migrate before create is the server's refusal: the database does not exist" do
  use_database(SCRATCH)
  assert_equal 1, run_db("status")
  refute database_exists?(SCRATCH)
end

test "create makes the database with the adapter's character set, once" do
  use_database(SCRATCH)
  assert_equal 0, run_db("create")
  assert database_exists?(SCRATCH)
  conn = Cybertrain::DB::Connection.new(URL)
  rows = conn.execute("SELECT DEFAULT_CHARACTER_SET_NAME AS c, DEFAULT_COLLATION_NAME AS o FROM information_schema.SCHEMATA " \
                      "WHERE SCHEMA_NAME = ?", [SCRATCH])
  conn.close
  assert_equal "utf8mb4", Cybertrain::Cast.str(rows[0]["c"])
  assert_equal "utf8mb4_0900_bin", Cybertrain::Cast.str(rows[0]["o"])
  assert_equal 0, run_db("create")
end

test "migrate applies the migrations and writes db/schema.rb" do
  use_database(SCRATCH)
  assert_equal 0, run_db("migrate")
  assert_equal ["comments", "posts", "schema_migrations"], scratch_tables
  schema = File.read("#{ROOT}/db/schema.rb")
  assert_includes schema, "Cybertrain::Schema.define(version: \"20260101000100\") do |s|"
  assert_includes schema, "t.text \"body\", null: false"
  assert_includes schema, "s.add_foreign_key \"comments\", \"posts\", column: \"post_id\""
end

test "status lists each migration as up" do
  use_database(SCRATCH)
  assert_equal 0, run_db("status")
end

test "rollback reverts the newest migration and rewrites db/schema.rb" do
  use_database(SCRATCH)
  assert_equal 0, run_db("rollback")
  assert_equal ["posts", "schema_migrations"], scratch_tables
  schema = File.read("#{ROOT}/db/schema.rb")
  assert_includes schema, "version: \"20260101000000\""
  refute schema.include?("comments")
  assert_equal 0, run_db("status")
end

test "schema writes db/schema.rb and names the database without the password" do
  use_database(SCRATCH)
  File.delete("#{ROOT}/db/schema.rb")
  assert_equal 0, run_db("schema")
  assert_includes File.read("#{ROOT}/db/schema.rb"), "s.create_table \"posts\" do |t|"
  refute CLI.schema_source(ROOT).include?(PASSWORD_PART)
end

test "backup, vacuum and normalize are SQLite's: exit status 2" do
  use_database(SCRATCH)
  assert_equal 2, run_db("backup", "tmp/x.sql")
  assert_equal 2, run_db("backup", "tmp/")
  assert_equal 2, run_db("vacuum")
  assert_equal 2, run_db("normalize")
end

test "drop drops the database, and says when there is none" do
  use_database(SCRATCH)
  assert_equal 0, run_db("drop")
  refute database_exists?(SCRATCH)
  assert_equal 0, run_db("drop")
end

test "no arguments or an unknown command prints MySQL's usage and returns 1" do
  assert_equal 1, run_db
  assert_equal 1, run_db("explode")
end

test "drop refuses a name that ends in _production, before it connects" do
  use_database("shop_production")
  assert_equal 1, run_db("drop")
  # A server that cannot be reached is not tried.
  Cybertrain.config.database_url = "mysql://root:#{PASSWORD}@127.0.0.1:1/shop_production?ssl_mode=disabled"
  assert_equal 1, run_db("drop")
  # In any case.
  Cybertrain.config.database_url = "mysql://root:#{PASSWORD}@127.0.0.1:1/shop_PRODUCTION?ssl_mode=disabled"
  assert_equal 1, run_db("drop")
end

test "create and drop take letters, digits, _ and $, at most 64, and refuse anything else" do
  assert_equal "a$_Z9", CLI.database_name("a$_Z9")
  assert_equal "x" * 64, CLI.database_name("x" * 64)
  assert_equal "`shop_dev`", CLI.quote_database("shop_dev")
  ["bad-name", "a`b", "a b", "a.b", "café", "x" * 65, "a;DROP DATABASE x"].each do |name|
    message = assert_raises("Cybertrain::DB::Error") { CLI.database_name(name) }
    assert message.start_with?("the database name "), message
    refute message.include?(PASSWORD_PART)
  end
  assert_equal "DATABASE_URL names no database (mysql://user:password@host:3306/NAME)",
               assert_raises("Cybertrain::DB::Error") { CLI.database_name("") }
end

test "a refused name stops create and drop before anything runs; the message has no password" do
  ["bad-name", "a%60b", "x" * 65].each do |name|
    use_database(name)
    assert_equal 1, run_db("create")
    assert_equal 1, run_db("drop")
  end
  Cybertrain.config.database_url = "mysql://root:#{PASSWORD}@127.0.0.1:33306?ssl_mode=disabled"
  assert_equal 1, run_db("create")
  Cybertrain.config.database_url = ""
  assert_equal 1, run_db("create")
  assert_equal 1, run_db("migrate")
end

test "server_url drops the database and keeps the password and the parameters" do
  assert_equal "mysql://u:p@h:1?ssl_mode=disabled", CLI.server_url("mysql://u:p@h:1/db?ssl_mode=disabled")
  assert_equal "mysql://u:p@h:1", CLI.server_url("mysql://u:p@h:1/db")
  assert_equal "mysql://u:p@h:1", CLI.server_url("mysql://u:p@h:1")
  # The password may hold "/", "?" and "@": the database is after the last "@".
  assert_equal "mysql://u:a/b?c@d@h:1?read_timeout=5", CLI.server_url("mysql://u:a/b?c@d@h:1/db?read_timeout=5")
  assert_equal "mysql://u@[::1]:3306", CLI.server_url("mysql://u@[::1]:3306/db")
end

test "dbconsole runs mysql over TCP with the server, the user and the database, and the password in MYSQL_PWD" do
  ENV["SSL_CERT_FILE"] = "/etc/app/ca.pem"
  ENV.delete("SSL_CERT_DIR")
  config = Cybertrain::Config.new
  config.database_url = "mysql://app:s%40cr%2Ft@db.internal:3307/shop_development"
  args = CLI.console_args(config)
  assert_equal ["--protocol=TCP", "--host=db.internal", "--port=3307", "--user=app", "--database=shop_development",
                "--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=/etc/app/ca.pem"], args
  args.each { |arg| refute arg.include?("s@cr/t") }
  env = CLI.console_env(config)
  assert_equal ["MYSQL_PWD"], env.keys
  assert_equal "s@cr/t", env["MYSQL_PWD"]
  assert_equal "mysql", CLI.console_program
  # localhost is the client's Unix socket unless the protocol is TCP: the
  # URL's port is kept.
  config.database_url = "mysql://root@localhost:33306/blog?ssl_mode=disabled"
  assert_equal ["--protocol=TCP", "--host=localhost", "--port=33306", "--user=root", "--database=blog", "--ssl-mode=DISABLED"],
               CLI.console_args(config)
  assert_equal 0, CLI.console_env(config).size
  ENV.delete("SSL_CERT_FILE")
  config.database_url = ""
  message = assert_raises("Cybertrain::DB::Error") { CLI.console_args(config) }
  assert_equal Cybertrain::DB::Adapter::MISSING_URL, message
  config.database_url = "mysql://root:sekrit@db.example.com/blog?ssl_mode=disabled"
  message = assert_raises("Cybertrain::DB::Error") { CLI.console_args(config) }
  refute message.include?("sekrit")
end

test "dbconsole's CA for ssl_mode=verify: SSL_CERT_FILE and SSL_CERT_DIR, else the system bundle" do
  assert_equal ["--ssl-ca=/etc/app/ca.pem"], CLI.console_ca_args("/etc/app/ca.pem", "")
  assert_equal ["--ssl-capath=/etc/app/certs"], CLI.console_ca_args("", "/etc/app/certs")
  assert_equal ["--ssl-ca=/etc/app/ca.pem", "--ssl-capath=/etc/app/certs"], CLI.console_ca_args("/etc/app/ca.pem", "/etc/app/certs")
  # Neither: the first system bundle there is (this machine's), or a refusal
  # that says what to set.
  found = Array.new(0) { "" }
  CLI::CA_BUNDLES.each { |path| found << path if File.file?(path) }
  if found.empty?
    message = assert_raises("Cybertrain::DB::Error") { CLI.console_ca_args("", "") }
    assert message.end_with?(": set SSL_CERT_FILE (or SSL_CERT_DIR)"), message
  else
    assert_equal ["--ssl-ca=#{found[0]}"], CLI.console_ca_args("", "")
    # As many assertions as the other branch, for the snapshot's count.
    assert found[0].start_with?("/etc/")
  end
  ENV.delete("SSL_CERT_FILE")
  ENV["SSL_CERT_DIR"] = "/etc/app/certs"
  config = Cybertrain::Config.new
  config.database_url = "mysql://app@db.internal/shop"
  assert_equal "--ssl-capath=/etc/app/certs", CLI.console_args(config).last
  ENV.delete("SSL_CERT_DIR")
end

test "help's db and dbconsole lines are MySQL's" do
  assert_equal "  ./shop db COMMAND        migrate | rollback [N] | status | schema | schema:dump | create | drop\n",
               CLI.usage_lines("shop")
  assert_equal "open the mysql client on the database", CLI.console_description
end

Cybertrain::Test.run!
