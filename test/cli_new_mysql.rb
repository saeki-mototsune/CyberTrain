require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"
require_relative "support/file_tree"

# `cybertrain new NAME --database=mysql`: the files that name the adapter
# (bin/NAME.rb and bin/db.rb require "cybertrain/mysql", config/app.rb
# explains DATABASE_URL, .env.example has its line; the Dockerfile,
# config/deploy.yml, .kamal/secrets and the CI workflow pass DATABASE_URL,
# the workflow with a MySQL service and the worker role commented on
# purpose; AGENTS.md says MySQL), every other file as
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
MYSQL_FILES = ["bin/shop.rb", "bin/db.rb", "config/app.rb", ".env.example", "Dockerfile", "config/deploy.yml",
               ".kamal/secrets", ".github/workflows/ci.yml", "AGENTS.md", "README.md"]

# The lines of the MySQL app's `path` that the SQLite app's (with the name
# swapped) lacks, and the other way round, each in file order.
def line_diff(path)
  sqlite = read("zebra/#{path}").gsub("zebra", "shop").gsub("Zebra", "Shop").split("\n")
  mysql = read("shop/#{path}").split("\n")
  [mysql.reject { |l| sqlite.include?(l) }, sqlite.reject { |l| mysql.include?(l) }]
end

test "new --database=mysql writes the files new writes" do
  created = Cybertrain::CLI::NewApp.create("other", "{ path = \"../cybertrain\" }")
  assert_equal created.map { |f| f.sub("bin/other.rb", "bin/shop.rb") }, CREATED
end

test "bin/shop.rb requires cybertrain/mysql first" do
  assert_equal <<~RUBY, read("shop/bin/shop.rb")
    # The whole framework with the MySQL adapter: the database is the one
    # DATABASE_URL names (config/app.rb). cybertrain/mysql loads every
    # subsystem (jobs, streams, feeds, mailer, cache, rate_limit) and the
    # Sentry sender (error reports to Sentry or GlitchTip, once
    # CYBERTRAIN_SENTRY_DSN is set), so `generate job` and `generate
    # authentication` add no line here.
    require "cybertrain/mysql"
    require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
    require_relative "../config/app"     # so it comes before the config
    require_relative "../gen/app"
    require_relative "../gen/migrations"

    # Operational commands: `./shop NAME ARGS...` runs the block with
    # Cybertrain::DB connected (pool of 1) and exits with its value;
    # `./shop help` lists them.
    #   Cybertrain::Main.command("prune", "delete old comments") do |argv|
    #     Cybertrain::DB.with { |c| c.execute("DELETE FROM comments WHERE created_at < NOW() - INTERVAL 30 DAY") }
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
  assert_equal "mysql", Cybertrain::Gen::Dialect.in_source(read("shop/bin/shop.rb"))
  assert_equal "mysql", Cybertrain::Gen::Dialect.in_source(read("shop/bin/db.rb"))
  assert_equal "sqlite", Cybertrain::Gen::Dialect.in_source(read("zebra/bin/zebra.rb"))
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
  # CYBERTRAIN_DATABASE (the SQLite file) is DATABASE_URL in the list of variables read.
  rest = rest.sub("(PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,\n", "(PORT, CYBERTRAIN_ENV, DATABASE_URL,\n")
  assert text.end_with?(rest), "the rest is SQLite's"
  assert_includes text, "Cybertrain.configure do |c|\n"
end

test ".env.example names the development database" do
  text = read("shop/.env.example")
  # Commented like every other line, without TLS on the loopback example
  # (a local server's certificate is self-signed), and the _test one.
  assert_includes text, "\n# DATABASE_URL=mysql://root@127.0.0.1:3306/shop_development?ssl_mode=disabled\n"
  assert_includes text, "\n# DATABASE_URL=mysql://root@127.0.0.1:3306/shop_test?ssl_mode=disabled\n"
  assert_nil text.index("\nDATABASE_URL")
  assert text.start_with?(read("zebra/.env.example")), "SQLite's lines first"
  assert_nil read("zebra/.env.example").index("DATABASE_URL")
end

test "the Dockerfile's run example passes DATABASE_URL; storage/ keeps the uploads" do
  added, gone = line_diff("Dockerfile")
  assert_equal ["#     -e DATABASE_URL='mysql://USER:PASSWORD@HOST:3306/shop_production' \\",
                "# install from asking for a region. ca-certificates: the connection to",
                "# MySQL checks the server's certificate against this store by default",
                "# (DATABASE_URL without ?ssl_mode=disabled); a server whose certificate a",
                "# private CA signed needs that CA's file, named by SSL_CERT_FILE. No",
                "# SQLite library: a cybertrain/mysql binary does not link it.",
                "      ca-certificates zlib1g libjemalloc2 libssl3t64 tzdata && \\",
                "# The database is the MySQL server DATABASE_URL names; storage/ holds the",
                "# uploaded files (storage/uploads/): mount a volume there so they outlive",
                "# the container."], added
  assert_equal ["# install from asking for a region.",
                "      libsqlite3-0 zlib1g libjemalloc2 libssl3t64 tzdata && \\",
                "# storage/ holds the SQLite database (storage/production.sqlite3); mount",
                "# a volume there so it outlives the container."], gone
end

test "config/deploy.yml takes DATABASE_URL as a secret and says what one process guarantees" do
  added, gone = line_diff("config/deploy.yml")
  assert_equal ["# CHANGE ME: the server's address. The database is the MySQL server",
                "# DATABASE_URL names (a secret, below). On MySQL, jobs, streams, leases",
                "# and scheduled tasks are guaranteed within one process only until step 2",
                "# of the roadmap (the configuration guide, \"MySQL\"): run the web role",
                "# alone. The generators leave the worker role commented.",
                "  # Jobs and scheduled tasks without HTTP, in a process of their own.",
                "  # On MySQL keep it commented for now: jobs, streams and leases in",
                "  # several processes sharing the database are not guaranteed until",
                "  # step 2 of the MySQL roadmap (the configuration guide, \"MySQL\");",
                "  # the web role runs the jobs.",
                "    # mysql://USER:PASSWORD@HOST:3306/shop_production (config/app.rb);",
                "    # also listed in .kamal/secrets.",
                "    - DATABASE_URL",
                "# Uploaded files live in storage/uploads/: keep them on the server across",
                "# deploys. The database is MySQL's: back it up there."], added
  assert_equal ["# CHANGE ME: the server's address. One server: the database is a",
                "# SQLite file on that server's volume, which every role shares.",
                "  # Jobs and scheduled tasks without HTTP. Several workers (and the",
                "  # web role) may share the database: one at a time leads the",
                "  # scheduled tasks, and the jobs of one that dies are picked up by",
                "  # the others.",
                "  # It needs require \"cybertrain/jobs\" in bin/shop.rb and bin/db.rb;",
                "  # `cybertrain generate job` and `generate authentication` add that",
                "  # line and uncomment this role.",
                "# The SQLite database lives in storage/: keep it on the server across",
                "# deploys. Back it up from there (docs/deploy.md)."], gone
  assert_includes read("shop/config/deploy.yml"), "  # worker:\n  #   hosts:\n"
end

test "generate job and generate authentication leave a MySQL app's worker role commented" do
  # Each prints its status line (the MySQL one a skip naming step 2).
  before = read("shop/config/deploy.yml")
  Cybertrain::CLI::Templates.enable_worker_role("shop")
  assert_equal before, read("shop/config/deploy.yml")
  sqlite = read("zebra/config/deploy.yml")
  Cybertrain::CLI::Templates.enable_worker_role("zebra")
  assert_includes read("zebra/config/deploy.yml"), Cybertrain::CLI::Templates.worker_role("zebra", true)
  File.write("zebra/config/deploy.yml", sqlite)
end

test "AGENTS.md says the application is on MySQL and requires cybertrain/mysql" do
  added, gone = line_diff("AGENTS.md")
  # The command list and the layout bullet name no subsystem line either.
  assert_equal ["SPIN_DEBUG=1 cybertrain spin run gen -- --check  # gen/ is current",
                "- `bin/shop.rb`: the program. Its first line, `require",
                "  \"cybertrain/mysql\"`, operational commands",
                "  (`Cybertrain::Main.command`), job handlers. `bin/db.rb` starts",
                "  with the same line.",
                "- MySQL 8.0: the database DATABASE_URL names (config/app.rb). LIKE",
                "  is case-sensitive, a migration that fails half way is not rolled",
                "  back, and there are no partial indexes (the models guide, \"MySQL\").",
                "  A column named like a framework method or a Ruby",
                "`bin/shop.rb` and `bin/db.rb` require `cybertrain/mysql`: the",
                "whole framework with the MySQL adapter, every subsystem (jobs,",
                "streams, feeds, mailer, cache, rate_limit) and the Sentry sender, so",
                "no feature needs a line of its own. Keep that line first in both",
                "files: it is how the application is built for MySQL."], added
  assert_includes gone, "- SQLite only. A column named like a framework method or a Ruby"
  assert_includes gone, "  `bin/db.rb` must require the same subsystems."
  assert_equal "The generators add the lines their code needs.", gone[gone.size - 1]
  assert_nil read("shop/AGENTS.md").index("SQLite only")
end

test "README.md names DATABASE_URL and the cybertrain/mysql line, not SQLite's require lines" do
  added, gone = line_diff("README.md")
  assert_equal ["export DATABASE_URL='mysql://root@127.0.0.1:3306/shop_development?ssl_mode=disabled'  # .env.example",
                "cybertrain db create   # the database DATABASE_URL names",
                "`bin/shop.rb` and `bin/db.rb` require `cybertrain/mysql`: the",
                "whole framework with the MySQL adapter and every subsystem (jobs,",
                "streams, feeds, mailer, cache, rate_limit), so the generators add no",
                "require line. Keep it the first line of both files: it is how the",
                "application is built for MySQL. The database is the one DATABASE_URL",
                "names (`config/app.rb`, `.env.example`).",
                "set CYBERTRAIN_SECRET_KEY_BASE and DATABASE_URL, the production database's).",
                "KAMAL_REGISTRY_PASSWORD, CYBERTRAIN_SECRET_KEY_BASE and DATABASE_URL",
                "(read by `.kamal/secrets`), commit, then `kamal setup` once and `kamal deploy`",
                "`cybertrain test -n /title/` the tests whose names match. It runs",
                "against the database DATABASE_URL names, which it empties and",
                "migrates first, so it refuses one whose name does not end in `_test`",
                "(`.env.example` has the line)."], added
  assert_equal 12, gone.size
  assert_nil read("shop/README.md").index("cybertrain/core")
end

test ".kamal/secrets reads DATABASE_URL from the environment" do
  text = read("shop/.kamal/secrets")
  assert text.start_with?(read("zebra/.kamal/secrets")), "SQLite's lines first"
  assert text.end_with?("\nDATABASE_URL=$DATABASE_URL\n"), text
end

test "the CI workflow runs the tests against a MySQL service" do
  added, gone = line_diff(".github/workflows/ci.yml")
  assert_equal [], gone
  assert_includes added, "    services:"
  assert_includes added, "          MYSQL_DATABASE: shop_test"
  assert_includes added, "      - name: MySQL accepts root without TLS"
  assert_includes added, "          DATABASE_URL: \"mysql://root:cybertrain@127.0.0.1:3306/shop_test?ssl_mode=disabled\""
  text = read("shop/.github/workflows/ci.yml")
  assert text.index("      - name: MySQL accepts root without TLS") < text.index("      - uses: saeki-mototsune/"),
         "the user is switched before the toolchain step"
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

test "the runtime image has the CA store MySQL's TLS checks against, and no SQLite" do
  text = read("shop/Dockerfile")
  runtime = text[text.index("# ---- runtime"), text.size]
  assert_includes runtime, "      ca-certificates zlib1g libjemalloc2 libssl3t64 tzdata && \\\n"
  assert_includes runtime, "SSL_CERT_FILE"
  assert_nil runtime.index("libsqlite3-0")
  assert_includes read("zebra/Dockerfile"), "      libsqlite3-0 zlib1g libjemalloc2 libssl3t64 tzdata && \\\n"
end

# generate authentication --invite-only --confirmable in a MySQL app: the
# pieces whose SQL or error differs from a SQLite app's (the app's own
# tests run them, `cybertrain test` against a server).
test "generate authentication --confirmable on MySQL: the duplicate by class, the race trigger, the first-run lock" do
  Cybertrain::CLI::NewApp.create("store", "{ path = \"../cybertrain\" }", "mysql")
  Cybertrain::CLI::Authentication.generate_with_result("store", true, true)
  user = read("store/app/models/user.rb")
  assert_includes user, "  rescue Cybertrain::DB::UniqueViolation\n    errors.add(:email_address"
  assert_nil user.index("UNIQUE")
  confirmations = read("store/test/controllers/confirmations_controller_test.rb")
  assert_includes confirmations, "CREATE TRIGGER confirmation_race BEFORE UPDATE ON users FOR EACH ROW "
  assert_includes confirmations, "SIGNAL SQLSTATE '23000' SET MYSQL_ERRNO = 1062"
  assert_nil confirmations.index("UPDATE OF email_address")
  setup = read("store/app/controllers/setup_controller.rb")
  assert_includes setup, "SELECT id FROM users LIMIT 1 FOR UPDATE"
  assert_includes setup, "rescue Cybertrain::DB::Deadlock"
  assert_nil setup.index("immediate: true")
  first_run = read("store/test/integration/first_run_test.rb")
  assert_includes first_run, "test \"two first-run setups at once create one account\" do"
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

test "the entry in single quotes is the entry for add_require too, as it is for gen" do
  Cybertrain::CLI::NewApp.create("quoted", "{ path = \"../cybertrain\" }", "mysql")
  File.write("quoted/bin/db.rb", read("quoted/bin/db.rb").sub("require \"cybertrain/mysql\"", "require 'cybertrain/mysql'"))
  before = read("quoted/bin/db.rb")
  Cybertrain::CLI::Templates.add_require("quoted", "cybertrain/jobs")
  assert_equal before, read("quoted/bin/db.rb")
  # A core entry in single quotes: the line goes after it, not above it.
  File.write("quoted/bin/db.rb", "# The entry.\nrequire 'cybertrain/core'\nrequire_relative \"../config/app\"\n")
  Cybertrain::CLI::Templates.add_require("quoted", "cybertrain/jobs")
  assert_equal "# The entry.\nrequire 'cybertrain/core'\nrequire \"cybertrain/jobs\"\nrequire_relative \"../config/app\"\n",
               read("quoted/bin/db.rb")
end

test "an attachment's backup note names the MySQL database, not a SQLite file" do
  assert_equal "note: uploaded files live in storage/uploads/; back it up (and mount it as a volume) together with the MySQL database",
               Cybertrain::CLI::Attachment.backup_note("shop")
  assert_equal Cybertrain::CLI::Attachment::BACKUP_NOTE, Cybertrain::CLI::Attachment.backup_note("zebra")
end

test "new's next steps on MySQL export DATABASE_URL and create the database first" do
  assert_equal "next:\n  cd shop\n  cybertrain generate scaffold article title:string body:text\n" \
               "  export DATABASE_URL='mysql://root@127.0.0.1:3306/shop_development?ssl_mode=disabled'\n" \
               "  cybertrain db create\n  cybertrain db migrate\n  cybertrain server\n",
               Cybertrain::CLI.new_next_steps("shop", "mysql")
  assert_equal "next:\n  cd apps/blog\n  cybertrain generate scaffold article title:string body:text\n" \
               "  cybertrain db migrate\n  cybertrain server\n",
               Cybertrain::CLI.new_next_steps("apps/blog", "sqlite")
end

test "CLI new refuses a second --database and an option it does not have, writing nothing" do
  [["--database=mysql", "--database", "sqlite"], ["--database", "sqlite", "--database=mysql"],
   ["--database=mysql", "--database=sqlite"], ["--databse=mysql"], ["--db=mysql"], ["-d", "mysql"],
   ["-database=mysql"], ["--path=.."]].each do |options|
    assert_equal 1, Cybertrain::CLI.run(["new", "twice"] + options + ["--skip-spin"])
    refute File.exist?("twice"), options.inspect
  end
  # A value that starts with "-" after an option that takes one is a value.
  assert_equal 0, Cybertrain::CLI.run(["new", "dashed", "--path", "-x", "--skip-spin"])
  assert File.exist?("dashed/spin.toml")
end

Cybertrain::Test.run!
