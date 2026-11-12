require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator"

# Fixtures at build time (spec section 7, plan decision D8): gen reads
# test/fixtures/*.yml against db/schema.rb and the model scan into one
# INSERT per label with Rails' ids, and writes gen/test/data.rb with the
# tables, the statements and the accessors. Run against copies of
# test/fixtures/gen_app (posts and comments, Comment belongs_to :post:
# pre-flight ruling B5). Text only: CRuby-portable.
require_relative "fixtures/gen_app/config/routes"
require_relative "fixtures/gen_app/db/schema"

FIXTURE = "test/fixtures/gen_app"
TEMP_ROOTS = Array.new(0) { "" }
Crc32 = Cybertrain::Gen::Crc32

def copy_tree(from, to)
  Dir.mkdir(to) unless File.directory?(to)
  Dir.children(from).sort.each do |entry|
    if File.directory?("#{from}/#{entry}")
      copy_tree("#{from}/#{entry}", "#{to}/#{entry}")
    else
      File.write("#{to}/#{entry}", File.read("#{from}/#{entry}"))
    end
  end
  nil
end

def remove_tree(dir)
  Dir.children(dir).each do |entry|
    path = "#{dir}/#{entry}"
    if File.directory?(path)
      remove_tree(path)
    else
      File.delete(path)
    end
  end
  Dir.rmdir(dir)
  nil
end

at_exit { TEMP_ROOTS.each { |root| remove_tree(root) if File.directory?(root) } }

# A copy of the fixture app whose test/fixtures holds only `files`
# (name => text).
def app_copy(files)
  root = Dir.mktmpdir("cybertrain-gen-fixtures")
  TEMP_ROOTS << root
  copy_tree(FIXTURE, root)
  Dir.children("#{root}/test/fixtures").each { |f| File.delete("#{root}/test/fixtures/#{f}") }
  files.each { |name, text| File.write("#{root}/test/fixtures/#{name}", text) }
  root
end

def scan_root(root)
  Cybertrain::Gen::FixtureScan.scan(root, Cybertrain::Schema.current, Cybertrain::Gen::ModelScan.scan_dir("#{root}/app/models"))
end

def scan(files) = scan_root(app_copy(files))

def emitted(files) = Cybertrain::Gen::TestDataEmitter.emit(Cybertrain::Schema.current, scan(files))

def refusal(files)
  scan(files)
  ""
rescue ArgumentError => e
  e.message
end

def row(rows, label)
  rows.each { |r| return r if r.row_label == label }
  flunk("no row #{label}")
end

def insert(r) = Cybertrain::Gen::TestDataEmitter.insert_sql(r)

test "ids are Rails' for the same labels" do
  assert_equal [980_190_962, 298_486_374, 663_665_735], %w[one two alice].map { |l| Crc32.fixture_id(l) }
  assert_equal 0xCBF43926, Crc32.crc32("123456789")
  assert_equal 0, Crc32.crc32("")
end

test "labels, id:, belongs_to by label, every column type, filled timestamps" do
  rows = scan("comments.yml" => "one:\n  post: one\n  commenter: Ann\n  body: Hi\n  approved: true\n  extras: '{\"a\":1}'\n  seen_on: 2026-11-01\n" \
                                "two:\n  post: two\n  commenter: Bo\n  body: Yo\n  approved: false\n  extras: '{}'\n  seen_on: 2026-11-02\n",
              "posts.yml" => "one:\n  title: First\n  created_at: 2026-11-01 09:00:00\n  price: 4.50\n  views: 3\n  meta: '{\"a\":1}'\n" \
                             "  published_on: 2026-11-01\ntwo:\n  id: 42\n  title: Second\n")
  assert_equal %w[comments comments posts posts], rows.map(&:row_table)
  one = row(rows, "one")
  assert_equal "comments", one.row_table
  assert_equal %w[id post_id commenter body approved extras seen_on created_at updated_at], one.row_columns
  assert_equal ["980190962", "980190962", "'Ann'", "'Hi'", "1", "'{\"a\":1}'", "'2026-11-01'", "?", "?"], one.row_values
  assert_equal %w[created_at updated_at], one.row_timestamps
  assert_equal "0", row(rows, "two").row_values[4]
  assert_equal "298486374", row(rows, "two").row_values[1]
  post_one = rows[2]
  assert_equal 980_190_962, post_one.row_id
  assert_equal %w[id title created_at price views meta published_on updated_at], post_one.row_columns
  assert_equal ["980190962", "'First'", "'2026-11-01 09:00:00.000000'", "4.50", "3", "'{\"a\":1}'", "'2026-11-01'", "?"], post_one.row_values
  assert_equal ["updated_at"], post_one.row_timestamps
  assert_equal 1, post_one.row_line
  assert_equal 42, rows[3].row_id
  assert_equal "42", rows[3].row_values[0]
  assert_equal 8, rows[3].row_line
end

test "values with quotes, YAML 1.1 words, newlines and nulls insert as written" do
  files = { "posts.yml" => "a:\n  title: It's here\nb:\n  title: no\nc:\n  title: 123\nd:\n  body: \"x\\ny\"\ne:\n  published_on: ~\nf:\n  title:\nDEFAULTS:\n  title: d\n" }
  rows = scan(files)
  assert_equal %w[a b c d e f DEFAULTS], rows.map(&:row_label)
  assert_equal "'It''s here'", row(rows, "a").row_values[1]
  assert_equal "'no'", row(rows, "b").row_values[1]
  assert_equal "'123'", row(rows, "c").row_values[1]
  assert_equal "'x\ny'", row(rows, "d").row_values[1]
  assert_equal "NULL", row(rows, "e").row_values[1]
  assert_equal "INSERT INTO \"posts\" (\"id\", \"title\", \"created_at\", \"updated_at\") VALUES (#{Crc32.fixture_id("f")}, NULL, ?, ?)",
               insert(row(rows, "f"))
  assert_equal "INSERT INTO \"posts\" (\"id\", \"title\", \"created_at\", \"updated_at\") VALUES (#{Crc32.fixture_id("DEFAULTS")}, 'd', ?, ?)",
               insert(row(rows, "DEFAULTS"))
  sql = emitted(files)
  assert_includes sql, "'It''s here'"
  assert_includes sql, "'no'"
  assert_includes sql, "'123'"
  # The newline is escaped in the Ruby literal of gen/test/data.rb.
  assert_includes sql, "'x\\ny'"
  assert_includes sql, "VALUES (#{Crc32.fixture_id("f")}, NULL, ?, ?)"
  assert_includes sql, "VALUES (#{Crc32.fixture_id("e")}, NULL, ?, ?)"
  assert_includes sql, "LABELS_posts = [\"a\", \"b\", \"c\", \"d\", \"e\", \"f\", \"DEFAULTS\"]"
  # A quoted empty string is not NULL.
  assert_equal "''", row(scan("posts.yml" => "g:\n  title: \"\"\n"), "g").row_values[1]
end

test "a label with nothing under it and a datetime's spellings" do
  rows = scan("posts.yml" => "bare:\nlate:\n  title: x\n  created_at: 2026-11-01T09:30Z\n  updated_at: 2026-11-01 09:30:15.25\n")
  assert_equal ["id", "created_at", "updated_at"], row(rows, "bare").row_columns
  assert_equal [Crc32.fixture_id("bare").to_s, "?", "?"], row(rows, "bare").row_values
  late = row(rows, "late")
  assert_equal ["'2026-11-01 09:30:00.000000'", "'2026-11-01 09:30:15.250000'"], late.row_values[2, 2]
  assert_equal [], late.row_timestamps
end

test "files outside test/fixtures' top level are not fixtures" do
  root = app_copy("posts.yml" => "one:\n  title: x\n", "notes.txt" => "not yaml: [")
  Dir.mkdir("#{root}/test/fixtures/files")
  File.write("#{root}/test/fixtures/files/widgets.yml", "a: [")
  assert_equal ["one"], scan_root(root).map(&:row_label)
end

test "the refusals name file and line" do
  assert_equal "test/fixtures/posts.yml:2: ERB is not supported in fixtures (there is no eval); set the value in setup or use travel_to",
               refusal("posts.yml" => "one:\n  title: <%= 1 %>\n")
  assert_equal "test/fixtures/widgets.yml:1: no table named \"widgets\" in db/schema.rb", refusal("widgets.yml" => "a:\n  x: 1\n")
  assert_equal "test/fixtures/posts.yml:2: posts has no column or belongs_to named \"titel\"", refusal("posts.yml" => "one:\n  titel: x\n")
  assert_equal "test/fixtures/posts.yml:4: posts: labels \"a\" and \"b\" (line 1) have the same id 5",
               refusal("posts.yml" => "a:\n  id: 5\n  title: x\nb:\n  id: 5\n  title: y\n")
  assert_equal "test/fixtures/posts.yml:3: fixtures hold one level of columns under each label",
               refusal("posts.yml" => "one:\n  title:\n    x: y\n")
  assert_equal "test/fixtures/posts.yml:2: fixtures hold one level of columns under each label",
               refusal("posts.yml" => "one:\n  title:\n    - x\n")
  assert_equal "test/fixtures/posts.yml:1: fixtures hold one level of columns under each label", refusal("posts.yml" => "one: x\n")
  assert_equal "test/fixtures/posts.yml:2: anchors and aliases are not supported", refusal("posts.yml" => "one:\n  title: &t x\n")
  assert_equal "test/fixtures/posts.yml:2: posts.views takes an integer (got \"many\")", refusal("posts.yml" => "one:\n  views: many\n")
  assert_equal "test/fixtures/posts.yml:2: posts.price takes a number (got \"1,5\")", refusal("posts.yml" => "one:\n  price: 1,5\n")
  assert_equal "test/fixtures/comments.yml:2: comments.approved takes true or false (got \"no\")", refusal("comments.yml" => "one:\n  approved: no\n")
  assert_equal "test/fixtures/posts.yml:2: posts.published_on takes a date such as 2026-11-01 (got \"Nov 1\")",
               refusal("posts.yml" => "one:\n  published_on: Nov 1\n")
  assert_equal "test/fixtures/posts.yml:2: posts.created_at takes a UTC time such as 2026-11-01 09:00:00 (got \"2026-11-01 09:00:00+09:00\")",
               refusal("posts.yml" => "one:\n  created_at: 2026-11-01 09:00:00+09:00\n")
  assert_equal "test/fixtures/posts.yml:2: posts.id takes an integer (got \"x\")", refusal("posts.yml" => "one:\n  id: x\n")
  assert_equal "test/fixtures/comments.yml:3: comments: post_id is set twice in \"one\"", refusal("comments.yml" => "one:\n  post: one\n  post_id: 3\n")
  assert_equal "test/fixtures/posts.yml:2: a NUL byte is not allowed", refusal("posts.yml" => "one:\n  title: \"a\\u0000b\"\n")
  assert_equal "test/fixtures/posts.yml:3: duplicate key \"title\"", refusal("posts.yml" => "one:\n  title: a\n  title: b\n")
end

test "gen writes gen/test/data.rb and --check reports it stale" do
  root = app_copy("posts.yml" => "one:\n  title: x\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  data = File.read("#{root}/gen/test/data.rb")
  assert_includes data, "LABELS_posts = [\"one\"]"
  assert_includes data, "def self.posts(label) = Post.find(Cybertrain::Test.fixture_id(\"posts\", label, TestData::LABELS_posts, TestData::IDS_posts))"
  assert_includes data, "  def posts(label) = Gen::TestFixtures.posts(label)\n"
  assert_includes data, "\ndef posts(label) = Gen::TestFixtures.posts(label)\n"
  assert_not_includes data, "LABELS_comments"
  # The bundle requires the file and registers its clear and load.
  bundle = File.read("#{root}/gen/tests.rb")
  assert_includes bundle, "require \"cybertrain/test_help\"\n"
  assert_includes bundle, "require_relative \"test/data\"\n"
  assert_includes bundle, "Cybertrain::Test::Database.clear_and_load!(Gen::TestData::TABLES, Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS)"
  assert_includes bundle, "Cybertrain::Test.before_each_bundled(Gen::Tests.fixtures_hook)\n"
  # The Runner's sweep of gen/test/ removes only gen's own copies.
  assert_not_includes data, Cybertrain::Gen::TestScan::FOOTER
  File.write("#{root}/test/fixtures/posts.yml", "one:\n  title: y\n")
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert_equal 0, Cybertrain::Gen::Runner.run(root, ["--check"])
  # With test/ gone, gen/test/data.rb goes too (and gen/test with it).
  remove_tree("#{root}/test")
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen/test")
end

test "with test/ and no fixtures, data.rb holds the tables and empty lists" do
  data = Cybertrain::Gen::TestDataEmitter.emit(Cybertrain::Schema.current, scan({}))
  assert_includes data, "TABLES = [\n      \"comments\",\n      \"posts\"\n    ].freeze"
  assert_includes data, "FIXTURE_SQL = Array.new(0) { \"\" }.freeze"
  assert_includes data, "FIXTURE_TIMESTAMPS = Array.new(0) { 0 }.freeze"
end

test "the fixture app's gen/test/data.rb and gen/tests.rb match the emitters (fixture stale otherwise)" do
  expected = Cybertrain::Gen::TestDataEmitter.emit(Cybertrain::Schema.current, scan_root(FIXTURE))
  Cybertrain::Test.count_assertion
  flunk("fixture stale: #{FIXTURE}/gen/test/data.rb") unless File.read("#{FIXTURE}/gen/test/data.rb") == expected
  bundle = Cybertrain::Gen::TestsEmitter.emit(FIXTURE, Cybertrain::Gen::TestScan.scan(FIXTURE), true)
  Cybertrain::Test.count_assertion
  flunk("fixture stale: #{FIXTURE}/gen/tests.rb") unless File.read("#{FIXTURE}/gen/tests.rb") == bundle
end

Cybertrain::Test.run!
