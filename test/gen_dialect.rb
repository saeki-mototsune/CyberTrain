require "tmpdir"
require "cybertrain/test"
require "cybertrain/schema"
require "cybertrain/generator"
require "cybertrain/cli"

# The generator learns the adapter (docs/design.md D96): Dialect.detect reads
# the first `require "cybertrain..."` of bin/NAME.rb, Dialect.for answers the
# spelling per adapter, and the emitters that spell SQL or the test bundle
# take it (the model's counter_cache SELECT, gen/test/data.rb's INSERTs,
# gen/tests.rb's requires). SQLite's output is what it always was. MySQL is
# only generated text here (the driver is not built yet). Text only:
# CRuby-portable.
require_relative "support/file_tree"
require_relative "../examples/blog/db/schema"

BLOG = "examples/blog"
BLOG_SCHEMA = Cybertrain::Schema.current

TEMP_ROOTS = Array.new(0) { "" }
at_exit { TEMP_ROOTS.each { |root| FileTree.remove(root) if File.directory?(root) } }

# An application tree holding spin.toml and bin/shop.rb with `bin_source`.
def app_with_bin(bin_source)
  root = Dir.mktmpdir("cybertrain-gen-dialect")
  TEMP_ROOTS << root
  File.write("#{root}/spin.toml", "[package]\nname = \"shop\"\nversion = \"0.1.0\"\n")
  FileTree.make_dirs("#{root}/bin")
  File.write("#{root}/bin/shop.rb", bin_source)
  root
end

REFUSAL = "bin/shop.rb: the first require must be \"cybertrain\" or \"cybertrain/mysql\""

def detect_refusal(root)
  Cybertrain::Gen::Dialect.detect(root)
  ""
rescue ArgumentError => e
  e.message
end

test "for answers the spelling of each adapter" do
  sqlite = Cybertrain::Gen::Dialect.for("sqlite")
  assert_equal "sqlite", sqlite.name
  assert_equal "cybertrain", sqlite.entry
  assert_equal "cybertrain/test/bundle", sqlite.test_bundle
  assert_equal "\"posts\"", sqlite.quote_ident("posts")
  mysql = Cybertrain::Gen::Dialect.for("mysql")
  assert_equal "mysql", mysql.name
  assert_equal "cybertrain/mysql", mysql.entry
  assert_equal "cybertrain/test/bundle_mysql", mysql.test_bundle
  assert_equal "`posts`", mysql.quote_ident("posts")
end

test "quote_ident doubles the quote character it quotes with" do
  assert_equal "\"a\"\"b\"", Cybertrain::Gen::Dialect.for("sqlite").quote_ident("a\"b")
  assert_equal "\"a`b\"", Cybertrain::Gen::Dialect.for("sqlite").quote_ident("a`b")
  assert_equal "`a``b`", Cybertrain::Gen::Dialect.for("mysql").quote_ident("a`b")
  assert_equal "`a\"b`", Cybertrain::Gen::Dialect.for("mysql").quote_ident("a\"b")
end

test "SQLite models are what examples/blog/gen holds, byte for byte" do
  infos = Cybertrain::Gen::ModelScan.scan_dir("#{BLOG}/app/models")
  outputs = Cybertrain::Gen::ModelsEmitter.outputs(BLOG_SCHEMA, infos, Cybertrain::Gen::Dialect.for("sqlite"))
  assert !outputs.empty?
  outputs.each { |rel, source| assert_equal File.read("#{BLOG}/#{rel}"), source }
end

test "for refuses a name that is no adapter" do
  msg = assert_raises("ArgumentError") { Cybertrain::Gen::Dialect.for("oracle") }
  assert_equal "unknown adapter oracle: sqlite or mysql", msg
end

test "detect reads the first require of cybertrain in bin/NAME.rb" do
  assert_equal "sqlite", Cybertrain::Gen::Dialect.detect(app_with_bin("require \"cybertrain\"\nrequire_relative \"../gen/app\"\n"))
  assert_equal "mysql", Cybertrain::Gen::Dialect.detect(app_with_bin("require \"cybertrain/mysql\"\nrequire_relative \"../gen/app\"\n"))
  # Lines before it, and requires of other libraries, are skipped.
  assert_equal "mysql", Cybertrain::Gen::Dialect.detect(app_with_bin("# app\nrequire \"json\"\n  require \"cybertrain/mysql\"\n"))
  # Only the first one counts.
  assert_equal "sqlite", Cybertrain::Gen::Dialect.detect(app_with_bin("require \"cybertrain\"\nrequire \"cybertrain/mysql\"\n"))
end

test "detect takes the core entries of a cybertrain new application as the same adapters" do
  assert_equal "sqlite", Cybertrain::Gen::Dialect.detect(app_with_bin("require \"cybertrain/core\"\nrequire \"cybertrain/jobs\"\n"))
  assert_equal "mysql", Cybertrain::Gen::Dialect.detect(app_with_bin("require \"cybertrain/core/mysql\"\nrequire \"cybertrain/jobs\"\n"))
end

test "detect stops on any other cybertrain require, or on none" do
  assert_equal REFUSAL, detect_refusal(app_with_bin("require \"cybertrain/foo\"\n"))
  assert_equal REFUSAL, detect_refusal(app_with_bin("require \"cybertrain/jobs\"\nrequire \"cybertrain\"\n"))
  assert_equal REFUSAL, detect_refusal(app_with_bin("require \"cybertrain/mysql\" # x\n"))
  assert_equal REFUSAL, detect_refusal(app_with_bin("puts 1\n"))
end

test "a tree with no spin.toml name or no bin/NAME.rb is SQLite" do
  root = Dir.mktmpdir("cybertrain-gen-dialect")
  TEMP_ROOTS << root
  assert_equal "sqlite", Cybertrain::Gen::Dialect.detect(root)
  File.write("#{root}/spin.toml", "[package]\nname = \"shop\"\n")
  assert_equal "sqlite", Cybertrain::Gen::Dialect.detect(root)
end

def counter_schema
  Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.integer "comments_count", null: false, default: "0"
    end
    s.create_table "comments" do |t|
      t.references :post
      t.text "body", null: false
    end
  end
end

def counter_infos
  [Cybertrain::Gen::ModelScan.scan_source("app/models/comment.rb", "class Comment\n  belongs_to :post, counter_cache: true\nend\n"),
   Cybertrain::Gen::ModelScan.scan_source("app/models/post.rb", "class Post\n  has_many :comments\nend\n")]
end

test "a model's counter_cache SELECT quotes with the adapter's identifier quote" do
  sqlite = Cybertrain::Gen::ModelsEmitter.outputs(counter_schema, counter_infos)["gen/models/comment.rb"]
  assert_includes sqlite, "c.execute(\"SELECT \\\"post_id\\\" FROM \\\"comments\\\" WHERE \\\"id\\\" = ?\", [id])"
  mysql = Cybertrain::Gen::ModelsEmitter.outputs(counter_schema, counter_infos, Cybertrain::Gen::Dialect.for("mysql"))["gen/models/comment.rb"]
  assert_includes mysql, "c.execute(\"SELECT `post_id` FROM `comments` WHERE `id` = ?\", [id])"
  assert_nil mysql.index("\\\"post_id\\\"")
end

FIXTURE_YAML = "one:\n  title: First\n"

def fixture_rows(root)
  Cybertrain::Gen::FixtureScan.scan(root, Cybertrain::Schema.current, Array.new(0) { Cybertrain::Gen::ModelInfo.empty("", "", Array.new(0) { "" }) })
end

test "gen/test/data.rb's INSERTs quote with the adapter's identifier quote" do
  counter_schema
  root = app_with_bin("require \"cybertrain\"\n")
  FileTree.make_dirs("#{root}/test/fixtures")
  File.write("#{root}/test/fixtures/posts.yml", FIXTURE_YAML)
  rows = fixture_rows(root)
  sqlite = Cybertrain::Gen::TestDataEmitter.emit(Cybertrain::Schema.current, rows)
  assert_includes sqlite, "INSERT INTO \\\"posts\\\" (\\\"id\\\", \\\"title\\\")"
  mysql = Cybertrain::Gen::TestDataEmitter.emit(Cybertrain::Schema.current, rows, Cybertrain::Gen::Dialect.for("mysql"))
  assert_includes mysql, "INSERT INTO `posts` (`id`, `title`)"
  assert_nil mysql.index("\\\"posts\\\"")
end

test "gen/tests.rb requires the adapter's entry and test bundle" do
  root = app_with_bin("require \"cybertrain\"\n")
  files = Cybertrain::Gen::TestScan.scan(root)
  sqlite = Cybertrain::Gen::TestsEmitter.emit(root, files, false)
  assert_includes sqlite, "require \"cybertrain\"\nrequire \"cybertrain/test_help\"\nrequire \"cybertrain/test/bundle\"\n"
  assert_nil sqlite.index("bundle_mysql")
  mysql = Cybertrain::Gen::TestsEmitter.emit(root, files, false, Cybertrain::Gen::Dialect.for("mysql"))
  assert_includes mysql, "require \"cybertrain/mysql\"\nrequire \"cybertrain/test_help\"\nrequire \"cybertrain/test/bundle_mysql\"\n"
  assert_nil mysql.index("require \"cybertrain\"\n")
end

test "gen on a MySQL app writes its models, fixtures and test program for MySQL" do
  counter_schema
  root = app_with_bin("require \"cybertrain/mysql\"\n")
  FileTree.make_dirs("#{root}/app/models")
  File.write("#{root}/app/models/comment.rb", "class Comment\n  belongs_to :post, counter_cache: true\nend\n")
  File.write("#{root}/app/models/post.rb", "class Post\n  has_many :comments\nend\n")
  FileTree.make_dirs("#{root}/test/fixtures")
  File.write("#{root}/test/fixtures/posts.yml", FIXTURE_YAML)
  File.write("#{root}/test/post_test.rb", "require \"test_helper\"\n")
  File.write("#{root}/test/test_helper.rb", "require \"cybertrain/test_help\"\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert_includes File.read("#{root}/gen/models/comment.rb"), "SELECT `post_id` FROM `comments` WHERE `id` = ?"
  assert_includes File.read("#{root}/gen/test/data.rb"), "INSERT INTO `posts` (`id`, `title`)"
  tests = File.read("#{root}/gen/tests.rb")
  assert_includes tests, "require \"cybertrain/mysql\"\nrequire \"cybertrain/test_help\"\nrequire \"cybertrain/test/bundle_mysql\"\n"
end

test "the generated account test checks the refused deletion by the adapter's own error" do
  sqlite = Cybertrain::CLI::Authentication.accounts_controller_test(false)
  assert_equal sqlite, Cybertrain::CLI::Authentication.accounts_controller_test(false, "sqlite")
  assert_includes sqlite, "      assert_includes log.string, \" ERROR \"\n      assert_includes log.string, \"account not deleted: FOREIGN KEY constraint failed\"\n"
  assert_nil sqlite.index("ForeignKeyViolation")
  mysql = Cybertrain::CLI::Authentication.accounts_controller_test(false, "mysql")
  assert_includes mysql, "      assert_includes log.string, \" ERROR \"\n      assert_includes log.string, \"account not deleted: \"\n" \
                         "      assert_raises(Cybertrain::DB::ForeignKeyViolation) { User.find(ann.id).destroy }\n"
  assert_nil mysql.index("FOREIGN KEY constraint failed")
end

test "gen stops with the message on a bad first require, writing nothing" do
  root = app_with_bin("require \"cybertrain/foo\"\n")
  assert_equal 1, Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen")
end

PARTIAL_MIGRATION = "class AddIndex < Cybertrain::Migration::Base\n  def change\n" \
                    "    add_index \"posts\", [\"title\"] # where: is not here\n" \
                    "    add_index \"posts\", [\"slug\"],\n              unique: true, where: \"slug IS NOT NULL\"\n" \
                    "    add_index(\"posts\", [\"state\"], where: \"\")\n  end\nend\n"

test "partial_index_lines finds the add_index calls with a where:, across lines" do
  assert_equal [4], Cybertrain::Gen::Dialect.partial_index_lines(PARTIAL_MIGRATION)
  assert_equal [2], Cybertrain::Gen::Dialect.partial_index_lines("x = 1\n  s.add_index \"t\", [\"a\"], name: \"i\", where: \"a > 0\"\n")
  assert_equal Array.new(0) { 0 }, Cybertrain::Gen::Dialect.partial_index_lines("add_index \"t\", [\"a\"], name: \"somewhere: x\"\n")
end

test "gen on a MySQL app stops at a partial index, writing nothing; on SQLite it goes on" do
  root = app_with_bin("require \"cybertrain/mysql\"\n")
  FileTree.make_dirs("#{root}/db/migrate")
  File.write("#{root}/db/migrate/20270101000000_add_index.rb", PARTIAL_MIGRATION)
  assert_equal 1, Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen")
  sqlite = app_with_bin("require \"cybertrain\"\n")
  FileTree.make_dirs("#{sqlite}/db/migrate")
  File.write("#{sqlite}/db/migrate/20270101000000_add_index.rb", PARTIAL_MIGRATION)
  assert_equal 0, Cybertrain::Gen::Runner.run(sqlite, [])
  assert File.exist?("#{sqlite}/gen/migrations.rb")
end

test "the generated account test makes its notes table in the adapter's DDL" do
  sqlite = Cybertrain::CLI::Authentication.accounts_controller_test(false)
  assert_includes sqlite, "      c.execute(\"CREATE TABLE account_notes (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users (id))\")\n"
  mysql = Cybertrain::CLI::Authentication.accounts_controller_test(true, "mysql")
  assert_includes mysql, "      c.execute(\"CREATE TABLE account_notes (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, " \
                         "user_id BIGINT NOT NULL, FOREIGN KEY (user_id) REFERENCES users (id)) ENGINE=InnoDB\")\n"
  assert_nil mysql.index("INTEGER PRIMARY KEY")
  assert_nil mysql.index("@NOTES_TABLE@")
end

Cybertrain::Test.run!
