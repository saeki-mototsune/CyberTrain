require "tmpdir"
require "cybertrain/test"
require "cybertrain/schema"
require "cybertrain/generator"

# Gen::Runner with a loaded db/schema.rb: it writes gen/models/<model>.rb
# per table and builds gen/app.rb listing them. Runs on a copy of the
# fixture app, so every written file can be compared with the checked-in
# fixture output. Text only (no database): CRuby-portable.
require_relative "fixtures/gen_app/config/routes"
require_relative "fixtures/gen_app/db/schema"

FIXTURE = "test/fixtures/gen_app"
ROOT = Dir.mktmpdir("cybertrain-gen-models")
APP_FILES = [
  "app/models/post.rb",
  "app/controllers/application_controller.rb",
  "app/controllers/comments_controller.rb",
  "app/controllers/pages_controller.rb",
  "app/controllers/posts_controller.rb"
]
GEN_FILES = ["gen/routes.rb", "gen/controllers.rb", "gen/models/comment.rb", "gen/models/post.rb", "gen/app.rb"]
DIRS = ["app", "app/models", "app/controllers", "gen", "gen/models"]
Dir.mkdir("#{ROOT}/app")
Dir.mkdir("#{ROOT}/app/models")
Dir.mkdir("#{ROOT}/app/controllers")
APP_FILES.each { |f| File.write("#{ROOT}/#{f}", File.read("#{FIXTURE}/#{f}")) }

at_exit do
  (APP_FILES + GEN_FILES + ["gen/models/tag.rb"]).each do |f|
    File.delete("#{ROOT}/#{f}") if File.exist?("#{ROOT}/#{f}")
  end
  DIRS.reverse.each { |d| Dir.rmdir("#{ROOT}/#{d}") if File.directory?("#{ROOT}/#{d}") }
  Dir.rmdir(ROOT)
end

def fixture_schema
  Cybertrain::Schema.reset!
  load_fixture_schema
end

# The fixture's db/schema.rb, restated (require_relative runs it only once).
def load_fixture_schema
  Cybertrain::Schema.define(version: "20260924120000") do |s|
    s.create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
      t.text "body", null: false
      t.boolean "approved", default: "false"
      t.timestamps
    end
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.text "body"
      t.integer "views", null: false, default: "0"
      t.timestamps
    end
  end
end

test "runner with a schema writes gen/models and a manifest listing them" do
  assert_equal 0, Cybertrain::Gen::Runner.run(ROOT, [])
  GEN_FILES.each do |f|
    Cybertrain::Test.count_assertion
    flunk("#{f} differs from the fixture") unless File.read("#{ROOT}/#{f}") == File.read("#{FIXTURE}/#{f}")
  end
  app = File.read("#{ROOT}/gen/app.rb")
  assert_includes app, "require_relative \"models/comment\"\nrequire_relative \"models/post\"\nrequire_relative \"routes\"\n"
end

test "runner --check passes on the fresh tree" do
  assert_equal 0, Cybertrain::Gen::Runner.run(ROOT, ["--check"])
end

test "a table added to the schema makes both its model and the manifest stale" do
  Cybertrain::Schema.reset!
  Cybertrain::Schema.define(version: "2") do |s|
    s.create_table "comments" do |t|
      t.references :post
      t.string "commenter", null: false
      t.text "body", null: false
      t.boolean "approved", default: "false"
      t.timestamps
    end
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.text "body"
      t.integer "views", null: false, default: "0"
      t.timestamps
    end
    s.create_table "tags" do |t|
      t.string "name", null: false
    end
  end
  assert_equal 1, Cybertrain::Gen::Runner.run(ROOT, ["--check"])
  refute File.exist?("#{ROOT}/gen/models/tag.rb")
  assert_equal 0, Cybertrain::Gen::Runner.run(ROOT, [])
  assert File.exist?("#{ROOT}/gen/models/tag.rb")
  assert_includes File.read("#{ROOT}/gen/app.rb"), "require_relative \"models/tag\"\n"
end

test "a dropped table's gen/models file is reported stale, then removed" do
  fixture_schema
  assert_equal 1, Cybertrain::Gen::Runner.run(ROOT, ["--check"])
  assert File.exist?("#{ROOT}/gen/models/tag.rb")
  assert_equal 0, Cybertrain::Gen::Runner.run(ROOT, [])
  refute File.exist?("#{ROOT}/gen/models/tag.rb")
  assert_equal File.read("#{FIXTURE}/gen/app.rb"), File.read("#{ROOT}/gen/app.rb")
  assert_equal 0, Cybertrain::Gen::Runner.run(ROOT, ["--check"])
end

Cybertrain::Test.run!
