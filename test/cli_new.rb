require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"
require "cybertrain/generator/locale_yaml"

# Every path below is relative to a fresh temp dir so the output (and the
# `create <path>` lines the generator prints) is the same on every machine.
TMP = Dir.mktmpdir("cybertrain-cli-new")
Dir.chdir(TMP)

# Removes a generated tree (files, dot-files and directories).
def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

# Test.run! exits the process, so the temp tree is removed at exit.
at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

EXPECTED_FILES = [
  "spin.toml", ".gitignore", ".env.example", "README.md",
  "config/app.rb", "config/routes.rb", "config/locales/en.yml",
  "db/schema.rb", "db/migrate/.keep",
  "app/controllers/application_controller.rb", "app/models/.keep", "app/helpers/.keep", "app/jobs/.keep",
  "app/assets/stylesheets/application.css", "app/assets/images/.keep", "app/javascript/application.js",
  "config/importmap.rb",
  "app/views/layouts/application.html.erb",
  "public/404.html", "public/500.html", "public/up.html",
  "bin/blog.rb", "bin/gen.rb", "bin/db.rb",
  "Dockerfile", ".dockerignore", "config/deploy.yml", ".kamal/secrets", ".github/workflows/ci.yml",
  "gen/.keep", "storage/.keep", "tmp/.keep", "test/.keep"
]

def read(path)
  File.read(path)
end

test "new writes the app skeleton and returns the created paths" do
  created = Cybertrain::CLI::NewApp.create("blog", "{ path = \"../cybertrain\" }")
  assert_equal EXPECTED_FILES, created
  EXPECTED_FILES.each { |f| assert(File.exist?("blog/#{f}"), "missing #{f}") }
end

test "spin.toml names the package and references the framework" do
  assert_equal <<~TOML, read("blog/spin.toml")
    [package]
    name = "blog"
    version = "0.1.0"
    # jemalloc is a faster malloc for a server: 1.1 to 1.4 times the
    # requests per second on examples/blog (docs/benchmark.md). Building then
    # needs its development package (libjemalloc-dev on Debian/Ubuntu,
    # `brew install jemalloc` on macOS).
    # allocator = "jemalloc"

    [dependencies]
    cybertrain = { path = "../cybertrain" }
  TOML
end

test "config/routes.rb and db/schema.rb are empty DSL blocks (routes with the jobs page commented out)" do
  assert_equal "Cybertrain::Routes.draw do\n  # jobs_page \"/admin/jobs\", before_action: :require_admin\nend\n", read("blog/config/routes.rb")
  assert_equal "Cybertrain::Schema.define(version: \"0\") do |s|\nend\n", read("blog/db/schema.rb")
end

test "config/locales/en.yml is a dictionary gen's reader accepts, with hello" do
  text = read("blog/config/locales/en.yml")
  entries = Cybertrain::Gen::LocaleYaml.parse(text, "config/locales/en.yml")
  assert_equal 1, entries.size
  assert_equal "en.hello", entries[0].entry_key
  assert_equal "Hello world", entries[0].entry_text
  assert(text.include?("docs/guide/i18n.md"))
end

test "config/app.rb documents the i18n settings, commented" do
  text = read("blog/config/app.rb")
  assert(text.include?("  # c.i18n_default_locale = :en\n"))
  assert(text.include?("  # c.i18n_available_locales = [:en, :ja]\n"))
  assert(text.include?("docs/guide/i18n.md"))
end

test "bin/blog.rb is the app's one binary: server, migrate, db; it requires the core alone" do
  assert_equal <<~RUBY, read("blog/bin/blog.rb")
    # The framework without its optional subsystems. Add the ones the
    # application uses after it, here and in bin/db.rb: cybertrain/jobs,
    # cybertrain/streams, cybertrain/feeds, cybertrain/mailer (and
    # cybertrain/mailer/later), cybertrain/cache, cybertrain/rate_limit;
    # or require "cybertrain" for all of them. `generate job` and
    # `generate authentication` add theirs; `spin run gen` names the
    # line a view's helper needs.
    require "cybertrain/core"
    require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
    require_relative "../config/app"     # so it comes before the config
    require_relative "../gen/app"
    require_relative "../gen/migrations"

    # Operational commands: `./blog NAME ARGS...` runs the block with
    # Cybertrain::DB connected (pool of 1) and exits with its value;
    # `./blog help` lists them.
    #   Cybertrain::Main.command("prune", "delete old comments") do |argv|
    #     Cybertrain::DB.with { |c| c.execute("DELETE FROM comments WHERE created_at < date('now', '-30 days')") }
    #     0
    #   end

    exit(Cybertrain::Main.run("blog", ARGV,
                              router: Gen::Routes.build(Cybertrain::Router.new),
                              url_resolver: Gen::Routes.url_resolver,
                              views: Gen::Views::SOURCES))
  RUBY
end

test "bin/gen.rb drives the generator" do
  assert_equal <<~RUBY, read("blog/bin/gen.rb")
    require "cybertrain/generator"
    require_relative "../config/routes"
    require_relative "../db/schema"

    exit(Cybertrain::Gen::Runner.run(".", ARGV))
  RUBY
  refute File.exist?("blog/bin/server.rb")
end

test "bin/db.rb runs migrations in development without the app's models" do
  assert_equal <<~RUBY, read("blog/bin/db.rb")
    # The same subsystem lines as bin/<app>.rb: config/app.rb may name
    # them (a Scheduler.cron task needs cybertrain/jobs).
    require "cybertrain/core"
    require_relative "../config/app"
    require_relative "../gen/migrations"

    exit(Cybertrain::DB::CLI.run(ARGV))
  RUBY
end

test "the layout renders csrf_meta_tags, the flash and yield" do
  layout = read("blog/app/views/layouts/application.html.erb")
  assert_includes layout, "<title>Blog</title>"
  assert_includes layout, "<%= csrf_meta_tags %>"
  assert_includes layout, "<% if flash[:notice] %>"
  assert_includes layout, "<%= flash[:notice] %>"
  assert_includes layout, "<%= flash[:alert] %>"
  assert_includes layout, "<%= yield %>"
  assert_includes layout, "<%= csp_meta_tag %>"
  assert_includes layout, "<%= stylesheet_link_tag \"application\" %>"
  assert_includes layout, "<%= javascript_importmap_tags %>"
  assert_equal false, File.exist?("blog/public/style.css")
  assert_includes read("blog/config/importmap.rb"), "pin \"application\"\n"
  assert_includes read("blog/app/javascript/application.js"), "// import \"@hotwired/turbo\"\n"
  assert_includes read("blog/app/assets/stylesheets/application.css"), "body { font-family"
  assert_includes read("blog/config/app.rb"), "# c.content_security_policy_report_only = true\n"
  assert_includes read("blog/config/app.rb"), '# c.permissions_policy = "camera=(), microphone=(), geolocation=()"'
  assert_includes read("blog/.env.example"), "# CYBERTRAIN_FORCE_SSL=1\n"
  assert_includes read("blog/.env.example"), "# CYBERTRAIN_HOSTS=app.example.com\n"
  assert_includes read("blog/Dockerfile"), "libjemalloc-dev libssl-dev"
  assert_includes read("blog/Dockerfile"), "libjemalloc2 libssl3t64"
  assert_includes read("blog/config/deploy.yml"), "asset_path: /app/public/assets\n"
end

test "application_controller.rb and config/app.rb are ready to edit" do
  controller = read("blog/app/controllers/application_controller.rb")
  assert_includes controller, "class ApplicationController < Cybertrain::Controller"
  assert_includes controller, "rescue_from Cybertrain::RecordNotFound, with: :record_not_found"
  assert_includes read("blog/config/app.rb"), "Cybertrain.configure do |c|"
  assert_includes read("blog/config/app.rb"), 'c.allowed_hosts << "my-preview.example.com"'
  # The commented cron example prunes the done jobs every app now leaves;
  # it says which require it needs.
  assert_includes read("blog/config/app.rb"), "# the jobs command). It needs require \"cybertrain/jobs\" in\n"
  assert_includes read("blog/config/app.rb"),
                  "# Cybertrain::Scheduler.cron(\"0 4 * * *\", \"prune done jobs\") do\n" \
                  "#   Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)\n# end\n"
  assert_includes read("blog/.gitignore"), "/build/"
  assert_includes read("blog/.gitignore"), "/storage/*.sqlite3*"
  assert_includes read("blog/.gitignore"), "/storage/uploads/\n"
  assert_includes read("blog/.gitignore"), "/dist/"
  # gen's list of kept digests (spec 7.4): local state, never committed.
  assert_includes read("blog/.gitignore"), "/public/assets/\n"
end

test "README.md gives the cybertrain command sequence" do
  readme = read("blog/README.md")
  assert_includes readme, "cybertrain db migrate"
  assert_includes readme, "cybertrain server"
  assert_includes readme, "cybertrain build"
  assert_includes readme, "bin/db.rb"
  assert_includes readme, "`bin/blog.rb` and `bin/db.rb` require `cybertrain/core`"
  assert_nil readme.index("spin run db")
end

test "the Dockerfile builds dist/ in the image and runs it on 0.0.0.0:3000" do
  dockerfile = read("blog/Dockerfile")
  assert_includes dockerfile, "RUN gem install cybertrain -v #{Cybertrain::VERSION} --no-document && cybertrain setup"
  assert_includes dockerfile, "RUN cybertrain build"
  assert_includes dockerfile, "COPY --from=build --chown=app:app /src/dist/ /app/"
  assert_includes dockerfile, "CYBERTRAIN_HOST=0.0.0.0"
  assert_includes dockerfile, "EXPOSE 3000"
  # the ENV line itself, not the comment above it
  assert_includes dockerfile, "\n    SPINEL_GC_FULL_INTERVAL=8\n"
  assert_includes dockerfile, "CMD [\"sh\", \"-c\", \"./blog migrate && exec ./blog\"]"
  # Both stages are the same release: the binary links its libc and SQLite.
  assert_equal 2, dockerfile.scan("FROM docker.io/library/ubuntu:$UBUNTU_VERSION").size
  ignored = read("blog/.dockerignore")
  ["/.git/", "/.kamal/", "/build/", "/dist/", "/storage/*", "/tmp/*"].each { |path| assert_includes ignored, "#{path}\n" }
end

test "config/deploy.yml and .kamal/secrets configure Kamal for the app" do
  deploy = read("blog/config/deploy.yml")
  assert_includes deploy, "service: blog\n"
  assert_includes deploy, "image: your-user/blog\n"
  assert_includes deploy, "  app_port: 3000\n"
  assert_includes deploy, "    path: /up.html\n"
  assert_includes deploy, "\ndeploy_timeout: 30\n"
  assert_includes deploy, "    - CYBERTRAIN_SECRET_KEY_BASE\n"
  # kamal-proxy connects from the Docker network, not loopback (PR #79 review).
  assert_includes deploy, "    CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12\n"
  assert_includes deploy, "  - \"blog_storage:/app/storage\"\n"
  assert_includes deploy, "db_status: app exec --reuse \"./blog db status\""
  # The roles: web, a worker on the same image, and a commented feeds role.
  assert_includes deploy, "  web:\n    hosts:\n      - 192.168.0.1\n"
  assert_includes deploy, "  worker:\n    hosts:\n      - 192.168.0.1\n    cmd: ./blog worker\n"
  assert_includes deploy, "  #   cmd: ./blog feeds trades\n"
  secrets = read("blog/.kamal/secrets")
  assert_includes secrets, "KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD\n"
  assert_includes secrets, "CYBERTRAIN_SECRET_KEY_BASE=$CYBERTRAIN_SECRET_KEY_BASE\n"
  assert_includes read("blog/public/up.html"), "OK"
  assert_includes read("blog/README.md"), "kamal setup"
end

# The toolchain steps live in the repository's setup-cybertrain action, at
# this CLI's release tag; the workflow only adds the app's own checks.
test ".github/workflows/ci.yml sets up the toolchain and runs the app's checks" do
  ci = read("blog/.github/workflows/ci.yml")
  assert_includes ci, "runs-on: ubuntu-latest\n"
  assert_includes ci, "- uses: actions/checkout@v4\n"
  assert_includes ci, "- uses: saeki-mototsune/cybertrain/.github/actions/setup-cybertrain@v#{Cybertrain::VERSION}\n"
  assert_includes ci, "run: spin lock && git diff --exit-code spin.lock\n"
  # gen in the mode the CLI builds it in, so the check does not compile a
  # release gen as well.
  assert_includes ci, "run: SPIN_DEBUG=1 spin run gen -- --check\n"
  assert_includes ci, "      spin test\n"
  assert ci.index("setup-cybertrain") < ci.index("spin lock"), "the toolchain comes first"
end

test "CLI new --path expands a relative DIR against the current directory" do
  assert_equal 0, Cybertrain::CLI.run(["new", "shop", "--path", "../../cybertrain", "--skip-spin"])
  # spin resolves `path =` from the app's directory, so the CLI writes the
  # absolute path the user meant (relative to where they ran the command).
  expected = File.join(File.dirname(File.dirname(Dir.pwd)), "cybertrain")
  assert expected.start_with?("/"), "not absolute: #{expected}"
  assert_includes read("shop/spin.toml"), "cybertrain = { path = \"#{expected}\" }"
  assert_includes read("shop/spin.toml"), "name = \"shop\""
end

test "CLI new --path keeps an absolute DIR and works for a nested app dir" do
  assert_equal 0, Cybertrain::CLI.run(["new", "sub/store", "--path", "/opt/cybertrain", "--skip-spin"])
  assert_includes read("sub/store/spin.toml"), "cybertrain = { path = \"/opt/cybertrain\" }"
  assert_includes read("sub/store/spin.toml"), "name = \"store\""
end

# `public`, `storage` and `tmp` are identifiers, but `cybertrain build` keeps
# those names in dist/ (Build.dist_name_problem): refused before any file is
# written, by the CLI and by NewApp.create alike.
test "new refuses an app named like a dist/ entry, writing nothing" do
  ["public", "storage", "tmp"].each do |name|
    assert_equal 1, Cybertrain::CLI.run(["new", name, "--skip-spin"])
    refute File.exist?(name), name
    message = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::NewApp.create("sub/#{name}", "\"~> 0.1\"") }
    assert_includes message, "'#{name}' is not a valid app name: it collides with what `cybertrain build` keeps in dist/"
    refute File.exist?(name), name
    refute File.exist?("sub/#{name}"), name
  end
  # A different letter case is the same directory entry on a case-insensitive
  # filesystem (macOS APFS): refused too. (`cybertrain new` itself accepts
  # lowercase names only; NewApp.create is the check a caller that skipped
  # that sees.)
  ["Public", "STORAGE", "Tmp"].each do |name|
    message = assert_raises("Cybertrain::CLI::InvalidArgument") { Cybertrain::CLI::NewApp.create("sub/#{name}", "\"~> 0.1\"") }
    assert_includes message, "'#{name}' is not a valid app name: it collides with what `cybertrain build` keeps in dist/"
    refute File.exist?("sub/#{name}"), name
  end
  # Similar spellings are different entries and still fine.
  assert_equal "", Cybertrain::CLI::Build.dist_name_problem("tmp2")
  assert_equal "", Cybertrain::CLI::Build.dist_name_problem("my_public")
  assert_equal "", Cybertrain::CLI::Build.dist_name_problem("blog")
end

test "CLI new rejects --path together with --version" do
  assert_equal 1, Cybertrain::CLI.run(["new", "both", "--path", "/opt/cybertrain", "--version", "~> 0.1"])
  refute File.exist?("both")
end

test "CLI new --version writes an index constraint" do
  assert_equal 0, Cybertrain::CLI.run(["new", "wiki", "--version", "~> 0.1", "--skip-spin"])
  assert_includes read("wiki/spin.toml"), "cybertrain = \"~> 0.1\""
end

test "CLI new --git writes a git dependency, with or without --ref" do
  assert_equal 0, Cybertrain::CLI.run(["new", "fork", "--git", "https://example.com/x/cybertrain", "--skip-spin"])
  assert_includes read("fork/spin.toml"), "cybertrain = { git = \"https://example.com/x/cybertrain\" }"
  assert_equal 0, Cybertrain::CLI.run(["new", "pinned", "--git", "https://example.com/x/cybertrain", "--ref", "main", "--skip-spin"])
  assert_includes read("pinned/spin.toml"), "cybertrain = { git = \"https://example.com/x/cybertrain\", ref = \"main\" }"
  assert_equal 1, Cybertrain::CLI.run(["new", "bad", "--ref", "main", "--skip-spin"])
  refute File.exist?("bad")
  assert_equal 1, Cybertrain::CLI.run(["new", "bad", "--git", "--ref", "main", "--skip-spin"])
  refute File.exist?("bad")
  assert_equal 1, Cybertrain::CLI.run(["new", "bad", "--git", "", "--skip-spin"])
  refute File.exist?("bad")
  assert_equal 1, Cybertrain::CLI.run(["new", "bad", "--git", "https://example.com/x/cybertrain", "--path", "/opt/cybertrain", "--skip-spin"])
  refute File.exist?("bad")
end

# A quote or a backslash in a path, URL or ref must not break spin.toml;
# a control character is refused before anything is written.
test "CLI new writes dependency values as TOML strings" do
  assert_equal "\"plain\"", Cybertrain::CLI.toml_string("plain")
  assert_equal "\"a\\\"b\\\\c\"", Cybertrain::CLI.toml_string("a\"b\\c")
  assert_equal 0, Cybertrain::CLI.run(["new", "odd", "--git", "file:///srv/my \"repos\"/cybertrain", "--ref", "v0.2.0", "--skip-spin"])
  assert_includes read("odd/spin.toml"), "cybertrain = { git = \"file:///srv/my \\\"repos\\\"/cybertrain\", ref = \"v0.2.0\" }"
  assert_equal 1, Cybertrain::CLI.run(["new", "bad", "--git", "https://example.com/x/cybertrain", "--ref", "main\n", "--skip-spin"])
  refute File.exist?("bad")
end

# The default is the release this CLI belongs to, so the templates it wrote
# and the framework the app compiles against are the same version.
test "CLI new defaults to this version's release tag" do
  assert_equal 0, Cybertrain::CLI.run(["new", "notes", "--skip-spin"])
  assert_includes read("notes/spin.toml"),
                  "cybertrain = { git = \"https://github.com/saeki-mototsune/cybertrain\", ref = \"v#{Cybertrain::VERSION}\" }"
end

test "new bootstraps the app with spin lock and a debug-mode spin run gen" do
  assert_equal "cd 'notes' && spin lock && SPIN_DEBUG=1 spin run gen", Cybertrain::CLI::NewApp.bootstrap_command("notes")
  assert_equal "cd 'it'\\''s' && spin lock && SPIN_DEBUG=1 spin run gen", Cybertrain::CLI::NewApp.bootstrap_command("it's")
  assert_equal "cd 'notes' && cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen", Cybertrain::CLI::NewApp.recovery_command("notes")
end

test "CLI spin needs arguments" do
  assert_equal 1, Cybertrain::CLI.run(["spin"])
  assert_equal 1, Cybertrain::CLI.run(["doctor", "extra"])
  assert_equal 1, Cybertrain::CLI.run(["setup", "--frce"])
end

test "CLI new refuses an existing directory and a bad name" do
  assert_equal 1, Cybertrain::CLI.run(["new", "blog"])
  assert_equal 1, Cybertrain::CLI.run(["new", "Bad Name"])
  refute File.exist?("Bad Name")
  assert_equal 1, Cybertrain::CLI.run(["new"])
end

test "CLI version, help and unknown commands" do
  assert_equal 0, Cybertrain::CLI.run(["version"])
  assert_equal 0, Cybertrain::CLI.run(["help"])
  assert_equal 1, Cybertrain::CLI.run(["frobnicate"])
  assert_equal 1, Cybertrain::CLI.run([])
end

test ".env.example lists the secrets, commented, with how to make each" do
  text = read("blog/.env.example")
  assert_includes text, "# CYBERTRAIN_SECRET_KEY_BASE=\n"
  assert_includes text, "# CYBERTRAIN_ENCRYPTION_KEY=  # cybertrain secret --hex\n"
  print text
end

test "CLI secret prints a session secret, secret --hex an encryption key (64 hex digits each)" do
  [[], ["--hex"]].each do |args|
    secret = Cybertrain::CLI.secret_text(args)
    assert_equal 64, secret.size
    secret.each_char { |ch| assert("0123456789abcdef".include?(ch)) }
    refute secret == Cybertrain::CLI.secret_text(args)
  end
  assert_equal 1, Cybertrain::CLI.run(["secret", "--bin"])
  assert_equal 1, Cybertrain::CLI.run(["secret", "--hex", "32"])
  assert_includes Cybertrain::CLI::USAGE, "cybertrain secret [--hex]"
end

Cybertrain::Test.run!
