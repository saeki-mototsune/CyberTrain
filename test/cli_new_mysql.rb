require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"
require_relative "support/file_tree"

# `cybertrain new NAME --database=mysql`: the files that name the adapter
# (bin/NAME.rb and bin/db.rb require "cybertrain/mysql", config/app.rb
# explains DATABASE_URL, .env.example has its line), every other file as
# `cybertrain new` writes it for SQLite, and gen reading the app as MySQL
# (Gen::Dialect.in_source). The CLI runs under CRuby; nothing here touches a
# database.
TMP = Dir.mktmpdir("cybertrain-cli-new-mysql")
Dir.chdir(TMP)

at_exit do
  Dir.chdir("/")
  FileTree.remove(TMP)
end

def read(path)
  File.read(path)
end

Cybertrain::CLI::NewApp.create("zebra", "{ path = \"../cybertrain\" }")
CREATED = Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }", "mysql")

# The files whose text differs from a SQLite app's.
MYSQL_FILES = ["bin/shop.rb", "bin/db.rb", "config/app.rb", ".env.example"]

test "new --database=mysql writes the files new writes" do
  created = Cybertrain::CLI::NewApp.create("other", "{ path = \"../cybertrain\" }")
  assert_equal created.map { |f| f.sub("bin/other.rb", "bin/shop.rb") }, CREATED
end

test "bin/shop.rb requires cybertrain/mysql first" do
  assert_equal <<~RUBY, read("shop/bin/shop.rb")
    # The whole framework with the MySQL adapter: the database is the one
    # DATABASE_URL names (config/app.rb). cybertrain/mysql loads every
    # subsystem (jobs, streams, feeds, mailer, cache, rate_limit), so
    # `generate job` and `generate authentication` add no line here.
    # cybertrain/error_reporter/sentry (error reports to Sentry or
    # GlitchTip) goes here only.
    require "cybertrain/mysql"
    require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
    require_relative "../config/app"     # so it comes before the config
    require_relative "../gen/app"
    require_relative "../gen/migrations"

    # Operational commands: `./shop NAME ARGS...` runs the block with
    # Cybertrain::DB connected (pool of 1) and exits with its value;
    # `./shop help` lists them.
    #   Cybertrain::Main.command("prune", "delete old comments") do |argv|
    #     Cybertrain::DB.with { |c| c.execute("DELETE FROM comments WHERE created_at < date('now', '-30 days')") }
    #     0
    #   end

    exit(Cybertrain::Main.run("shop", ARGV,
                              router: Gen::Routes.build(Cybertrain::Router.new),
                              url_resolver: Gen::Routes.url_resolver,
                              views: Gen::Views::SOURCES))
  RUBY
end

test "bin/db.rb requires cybertrain/mysql" do
  assert_equal <<~RUBY, read("shop/bin/db.rb")
    # The same entry as bin/<app>.rb: the MySQL adapter and every subsystem.
    require "cybertrain/mysql"
    require_relative "../config/app"
    require_relative "../gen/migrations"

    exit(Cybertrain::DB::CLI.run(ARGV))
  RUBY
end

test "gen reads the app as MySQL, and the SQLite app as SQLite" do
  assert_equal "mysql", Cybertrain::Gen::Dialect.in_source("shop", read("shop/bin/shop.rb"))
  assert_equal "mysql", Cybertrain::Gen::Dialect.in_source("shop", read("shop/bin/db.rb"))
  assert_equal "sqlite", Cybertrain::Gen::Dialect.in_source("zebra", read("zebra/bin/zebra.rb"))
end

test "config/app.rb explains DATABASE_URL" do
  text = read("shop/config/app.rb")
  assert text.start_with?(<<~RUBY), text[0, 400]
    # Application settings; see Cybertrain::Config for every option.
    #
    # The database is MySQL (bin/shop.rb requires cybertrain/mysql): the one
    # DATABASE_URL names, read from the environment before this block runs,
    #   mysql://USER:PASSWORD@HOST:3306/NAME
    # (.env.example has development's). The connection uses TLS and checks
    # the server's certificate (the CA from SSL_CERT_FILE or SSL_CERT_DIR);
    # ?ssl_mode=disabled turns TLS off, for a server on localhost or a
    # private address only. `cybertrain db create` creates NAME, `db drop`
    # drops it. Keep the password in the environment (or your deploy's
    # secrets), never in this file or the repository.
  RUBY
  rest = read("zebra/config/app.rb").sub("# Application settings; see Cybertrain::Config for every option.\n", "")
  assert text.end_with?(rest), "the rest is SQLite's"
  assert_includes text, "Cybertrain.configure do |c|\n"
end

test ".env.example names the development database" do
  text = read("shop/.env.example")
  assert_includes text, "\nDATABASE_URL=mysql://root@127.0.0.1:3306/shop_development\n"
  assert text.start_with?(read("zebra/.env.example")), "SQLite's lines first"
  assert_nil read("zebra/.env.example").index("DATABASE_URL")
end

test "every other file is SQLite's" do
  CREATED.each do |f|
    next if MYSQL_FILES.include?(f)

    other = f == "bin/shop.rb" ? "bin/zebra.rb" : f
    assert read("zebra/#{other}").gsub("zebra", "shop").gsub("Zebra", "Shop") == read("shop/#{f}"), "#{f} differs"
  end
end

test "a subsystem's require is not added: cybertrain/mysql loads them all" do
  Cybertrain::CLI::Templates.add_require("shop", "cybertrain/jobs")
  assert_nil read("shop/bin/shop.rb").index("require \"cybertrain/jobs\"")
  assert_nil read("shop/bin/db.rb").index("require \"cybertrain/jobs\"")
end

test "CLI new --database=mysql and --database mysql" do
  assert_equal 0, Cybertrain::CLI.run(["new", "eq", "--path", "..", "--database=mysql", "--skip-spin"])
  assert_includes read("eq/bin/eq.rb"), "\nrequire \"cybertrain/mysql\"\n"
  assert_equal 0, Cybertrain::CLI.run(["new", "sp", "--database", "mysql", "--path", "..", "--skip-spin"])
  assert_includes read("sp/bin/sp.rb"), "\nrequire \"cybertrain/mysql\"\n"
  assert_equal 0, Cybertrain::CLI.run(["new", "lite", "--database=sqlite", "--path", "..", "--skip-spin"])
  assert_equal read("zebra/bin/zebra.rb").gsub("zebra", "lite"), read("lite/bin/lite.rb")
end

test "CLI new refuses another --database, writing nothing" do
  assert_equal 1, Cybertrain::CLI.run(["new", "pg", "--database=postgresql", "--skip-spin"])
  refute File.exist?("pg")
  assert_equal 1, Cybertrain::CLI.run(["new", "none", "--database", "--skip-spin"])
  refute File.exist?("none")
end

Cybertrain::Test.run!
