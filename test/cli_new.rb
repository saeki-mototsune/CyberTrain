require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"

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
  "spin.toml", ".gitignore", "README.md",
  "config/app.rb", "config/routes.rb",
  "db/schema.rb", "db/migrate/.keep",
  "app/controllers/application_controller.rb", "app/models/.keep", "app/helpers/.keep",
  "app/views/layouts/application.html.erb",
  "public/404.html", "public/500.html", "public/style.css",
  "bin/blog.rb", "bin/gen.rb", "bin/db.rb",
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

    [dependencies]
    cybertrain = { path = "../cybertrain" }
  TOML
end

test "config/routes.rb and db/schema.rb are empty DSL blocks" do
  assert_equal "Cybertrain::Routes.draw do\nend\n", read("blog/config/routes.rb")
  assert_equal "Cybertrain::Schema.define(version: \"0\") do |s|\nend\n", read("blog/db/schema.rb")
end

test "bin/blog.rb is the app's one binary: server, migrate, db" do
  assert_equal <<~RUBY, read("blog/bin/blog.rb")
    require "cybertrain"
    require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
    require_relative "../config/app"     # so it comes before the config
    require_relative "../gen/app"
    require_relative "../gen/migrations"

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
    require "cybertrain"
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
  assert_includes layout, "<link rel=\"stylesheet\" href=\"/style.css\">"
end

test "application_controller.rb and config/app.rb are ready to edit" do
  controller = read("blog/app/controllers/application_controller.rb")
  assert_includes controller, "class ApplicationController < Cybertrain::Controller"
  assert_includes controller, "rescue_from Cybertrain::RecordNotFound, with: :record_not_found"
  assert_includes read("blog/config/app.rb"), "Cybertrain.configure do |c|"
  assert_includes read("blog/.gitignore"), "/build/"
  assert_includes read("blog/.gitignore"), "/storage/*.sqlite3*"
  assert_includes read("blog/.gitignore"), "/dist/"
end

test "README.md gives the cybertrain command sequence" do
  readme = read("blog/README.md")
  assert_includes readme, "cybertrain db migrate"
  assert_includes readme, "cybertrain server"
  assert_includes readme, "cybertrain build"
  assert_includes readme, "bin/db.rb"
  assert_nil readme.index("spin run db")
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

test "new bootstraps the app with spin lock and spin run gen" do
  assert_equal "cd 'notes' && spin lock && spin run gen", Cybertrain::CLI::NewApp.bootstrap_command("notes")
  assert_equal "cd 'it'\\''s' && spin lock && spin run gen", Cybertrain::CLI::NewApp.bootstrap_command("it's")
  assert_equal "cd 'notes' && cybertrain spin lock && cybertrain spin run gen", Cybertrain::CLI::NewApp.recovery_command("notes")
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

Cybertrain::Test.run!
