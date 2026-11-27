require "cybertrain/test"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

# test/nested_includes.rb on MySQL, against the server CYBERTRAIN_TEST_MYSQL_URL names
# (script/test-mysql runs this program): nested includes (docs/design.md D95) on the checked-in generated
# models of test/fixtures/nested_includes_app, loaded as the original loads them, and the
# original's tests, with its snapshot (test/nested_includes.rb.expected, copied).
# test/mysql/models.rb says why the fixture-app tests have programs of
# their own.
#
# What differs from the original is marked where it is: the database (the
# fixture schema's tables as hand-written MySQL DDL in the design's types,
# foreign keys as table constraints, dropped first; the plan's Task 10
# replaces this with DDL from the schema, as test/support/schema_tables.rb
# derives SQLite's), and the ids set back to 1 by ALTER TABLE where SQLite
# empties sqlite_sequence. The original's description:
#
# Nested includes (docs/design.md D95) on the compiled models of
# test/fixtures/nested_includes_app: Author has_one :profile and has_many
# :articles (and, from comments.author_id, :comments); Profile and Article
# belong to an author; Comment belongs to its article and optionally to an
# author and has_many :likes; Like belongs to its comment. Every claim about
# queries is a delta of Connection#statements_run: one statement per level
# of the path, whatever the number of records. test/includes.rb covers the
# first level. SQLite is FFI, so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
require_relative "../fixtures/nested_includes_app/db/schema"
require_relative "../fixtures/nested_includes_app/gen/models/article"
require_relative "../fixtures/nested_includes_app/gen/models/author"
require_relative "../fixtures/nested_includes_app/gen/models/comment"
require_relative "../fixtures/nested_includes_app/gen/models/like"
require_relative "../fixtures/nested_includes_app/gen/models/profile"

FIXTURE = "test/fixtures/nested_includes_app"

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# MySQL: the fixture schema (test/fixtures/nested_includes_app/db/schema.rb) as hand-written DDL
# in the design's types (Task 10 generates it; SQLite's comes from
# test/support/schema_tables.rb), outside any transaction.
TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
CREATE_TABLES_SQL =
  "CREATE TABLE authors (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL)#{TABLE_OPTIONS};" \
  "CREATE TABLE articles (id BIGINT AUTO_INCREMENT PRIMARY KEY, author_id BIGINT NOT NULL, title VARCHAR(255) NOT NULL, FOREIGN KEY (author_id) REFERENCES authors(id))#{TABLE_OPTIONS};" \
  "CREATE TABLE comments (id BIGINT AUTO_INCREMENT PRIMARY KEY, article_id BIGINT NOT NULL, author_id BIGINT, body VARCHAR(255) NOT NULL, FOREIGN KEY (article_id) REFERENCES articles(id), FOREIGN KEY (author_id) REFERENCES authors(id))#{TABLE_OPTIONS};" \
  "CREATE TABLE likes (id BIGINT AUTO_INCREMENT PRIMARY KEY, comment_id BIGINT NOT NULL, who VARCHAR(255) NOT NULL, FOREIGN KEY (comment_id) REFERENCES comments(id))#{TABLE_OPTIONS};" \
  "CREATE TABLE profiles (id BIGINT AUTO_INCREMENT PRIMARY KEY, author_id BIGINT NOT NULL, bio VARCHAR(255) NOT NULL, FOREIGN KEY (author_id) REFERENCES authors(id))#{TABLE_OPTIONS};"
Cybertrain::DB.connect(URL, size: 1)
# This program's own tables are dropped first, by name, with any table of
# the other test/mysql programs that references one of them
# (test/mysql/support/tables.rb).
Cybertrain::DB.with { |c| MySQLTestTables.drop(c, ["likes", "comments", "articles", "profiles", "authors"]) }
Cybertrain::DB.with { |c| c.exec_script(CREATE_TABLES_SQL) }

def statements = Cybertrain::DB.with { |c| c.statements_run }

# Authors ann (profile, articles a1 and a2), bob (profile, article b1) and
# cid (nothing). a1 has comments c1 by bob and c2 by nobody; a2 has none;
# b1 has c3 by ann and c4 by bob. c1 is liked by x and y, c3 by z.
def seed
  Cybertrain::DB.with do |c|
    c.exec_script("DELETE FROM likes; DELETE FROM comments; DELETE FROM articles; DELETE FROM profiles; DELETE FROM authors;")
  end
  ann = Author.create(name: "ann")
  bob = Author.create(name: "bob")
  Author.create(name: "cid")
  Profile.create(author_id: ann.id, bio: "ann's")
  Profile.create(author_id: bob.id, bio: "bob's")
  a1 = Article.create(author_id: ann.id, title: "a1")
  Article.create(author_id: ann.id, title: "a2")
  b1 = Article.create(author_id: bob.id, title: "b1")
  c1 = Comment.create(article_id: a1.id, author_id: bob.id, body: "c1")
  Comment.create(article_id: a1.id, author_id: nil, body: "c2")
  c3 = Comment.create(article_id: b1.id, author_id: ann.id, body: "c3")
  Comment.create(article_id: b1.id, author_id: bob.id, body: "c4")
  Like.create(comment_id: c1.id, who: "x")
  Like.create(comment_id: c1.id, who: "y")
  Like.create(comment_id: c3.id, who: "z")
  nil
end

# "c1 by bob" for each comment of each article, "-" for no author.
def comment_authors(articles)
  out = Array.new(0) { "" }
  articles.each do |article|
    article.comments.each do |comment|
      author = comment.author
      out << "#{article.title}/#{comment.body} by #{author.nil? ? "-" : author.name}"
    end
  end
  out
end

def comment_likes(articles)
  out = Array.new(0) { "" }
  articles.each do |article|
    article.comments.each do |comment|
      out << "#{comment.body}:#{comment.likes.to_a.map { |l| l.who }.join(",")}"
    end
  end
  out
end

test "the checked-in gen/models files match the emitter (fixture stale otherwise)" do
  infos = Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models")
  outputs = Cybertrain::Gen::ModelsEmitter.outputs(Cybertrain::Schema.current, infos)
  assert_equal ["gen/models/article.rb", "gen/models/author.rb", "gen/models/comment.rb", "gen/models/like.rb",
                "gen/models/profile.rb"], outputs.keys
  outputs.each do |path, source|
    Cybertrain::Test.count_assertion
    flunk("fixture stale: #{path}") unless File.read(FIXTURE + "/" + path) == source
  end
end

test "includes(comments: :author) is one statement per level: has_many then belongs_to" do
  seed
  before = statements
  articles = Article.order(id: :asc).includes(comments: :author).to_a
  assert_equal 3, statements - before
  assert_equal ["a1/c1 by bob", "a1/c2 by -", "b1/c3 by ann", "b1/c4 by bob"], comment_authors(articles)
  assert_equal [2, 0, 2], articles.map { |a| a.comments.size }
  assert_equal 3, statements - before
end

test "includes(comments: [:author, :likes]) preloads both below comments" do
  seed
  before = statements
  articles = Article.order(id: :asc).includes(comments: [:author, :likes]).to_a
  assert_equal 4, statements - before
  assert_equal ["a1/c1 by bob", "a1/c2 by -", "b1/c3 by ann", "b1/c4 by bob"], comment_authors(articles)
  assert_equal ["c1:x,y", "c2:", "c3:z", "c4:"], comment_likes(articles)
  assert_equal 4, statements - before
end

test "includes(:author, comments: { likes: :comment }) mixes a name and a Hash three levels deep" do
  seed
  before = statements
  articles = Article.order(id: :asc).includes(:author, comments: { likes: :comment }).to_a
  assert_equal 5, statements - before
  assert_equal ["ann", "ann", "bob"], articles.map { |a| a.author.name }
  backs = Array.new(0) { "" }
  articles.each do |article|
    article.comments.each { |comment| comment.likes.each { |like| backs << "#{like.who}->#{like.comment.body}" } }
  end
  assert_equal ["x->c1", "y->c1", "z->c3"], backs
  assert_equal 5, statements - before
end

test "belongs_to, belongs_to, has_one: Comment.includes(article: { author: :profile })" do
  seed
  before = statements
  comments = Comment.order(id: :asc).includes(article: { author: :profile }).to_a
  assert_equal 4, statements - before
  bios = comments.map { |c| "#{c.body}:#{c.article.author.profile.bio}" }
  assert_equal ["c1:ann's", "c2:ann's", "c3:bob's", "c4:bob's"], bios
  # One parent object per id: the comments of a1 share its article.
  assert comments[0].article.equal?(comments[1].article)
  assert_equal 4, statements - before
end

test "has_one then belongs_to: Author.includes(profile: :author); a missing profile is nil" do
  seed
  before = statements
  authors = Author.order(id: :asc).includes(profile: :author).to_a
  assert_equal 3, statements - before
  names = authors.map { |a| a.profile.nil? ? "#{a.name}:-" : "#{a.name}:#{a.profile.author.name}" }
  assert_equal ["ann:ann", "bob:bob", "cid:-"], names
  assert_equal 3, statements - before
end

test "has_many three deep: Author.includes(articles: { comments: :likes })" do
  seed
  before = statements
  authors = Author.order(id: :asc).includes(articles: { comments: :likes }).to_a
  assert_equal 4, statements - before
  counts = authors.map { |a| a.articles.to_a.map { |art| art.comments.to_a.map { |c| c.likes.size }.sum }.sum }
  assert_equal [2, 1, 0], counts
  assert_equal 4, statements - before
end

test "a nil parent or an empty level stops the path there without a statement" do
  seed
  before = statements
  comments = Comment.order(id: :asc).includes(author: :profile).to_a
  assert_equal 3, statements - before
  assert_equal ["bob's", "-", "ann's", "bob's"], comments.map { |c| c.author.nil? ? "-" : c.author.profile.bio }
  assert_equal 3, statements - before
  articles = Article.where(title: "a2").includes(comments: { likes: :comment }).to_a
  assert_equal 5, statements - before
  assert_equal 0, articles[0].comments.size
  assert_equal 5, statements - before
end

test "preload takes the same nested forms; dup and a second includes keep and add paths" do
  seed
  before = statements
  articles = Article.order(id: :asc).preload(comments: :author).to_a
  assert_equal 3, statements - before
  assert_equal 4, comment_authors(articles).size
  rel = Article.order(id: :asc).includes(comments: :author)
  rel.includes(comments: :likes)
  copy = rel.dup
  before = statements
  articles = copy.to_a
  assert_equal 4, statements - before
  assert_equal ["c1:x,y", "c2:", "c3:z", "c4:"], comment_likes(articles)
  assert_equal 4, comment_authors(articles).size
  assert_equal 4, statements - before
end

test "a path that comes back to its start loads each level again: comments: { article: :comments }" do
  seed
  before = statements
  articles = Article.where(title: "a1").includes(comments: { article: :comments }).to_a
  assert_equal 4, statements - before
  back = articles[0].comments.first.article
  assert_equal ["c1", "c2"], back.comments.to_a.map { |c| c.body }
  assert_equal 4, statements - before
end

test "an unknown name at any depth raises before any statement, naming it and its model" do
  seed
  before = statements
  assert_equal "unknown association nope for Comment",
               assert_raises("ArgumentError") { Article.includes(comments: :nope) }
  assert_equal "unknown association nope for Author",
               assert_raises("ArgumentError") { Article.includes(comments: { author: [:profile, :nope] }) }
  assert_equal "unknown association bio for Profile",
               assert_raises("ArgumentError") { Comment.preload(article: { author: { profile: :bio } }) }
  assert_equal "unknown association likes for Article",
               assert_raises("ArgumentError") { Article.includes(:comments, :likes) }
  assert_equal "includes takes association names, Arrays and Hashes of them",
               assert_raises("ArgumentError") { Article.includes(comments: 1) }
  assert_equal 0, statements - before
end

test "a refused includes leaves the relation as it was" do
  seed
  rel = Article.order(id: :asc)
  assert_raises("ArgumentError") { rel.includes(:comments, author: :nope) }
  before = statements
  articles = rel.to_a
  assert_equal 1, statements - before
  articles[0].comments.size
  assert_equal 2, statements - before
end

test "String names are taken as Symbols are" do
  seed
  before = statements
  articles = Article.order(id: :asc).includes("comments").to_a
  assert_equal 2, statements - before
  assert_equal [2, 0, 2], articles.map { |a| a.comments.size }
  assert_equal 2, statements - before
end

Cybertrain::Test.run!
