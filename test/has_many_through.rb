require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"
require_relative "support/schema_tables"

# `has_many ..., through:` (docs/design.md D93) on the generated models of
# test/fixtures/gen_through, driven against SQLite: each pairing of a via
# (has_many or belongs_to) with a source (belongs_to or has_many), with
# and without `source:`, a nullable key on either side, the Relation the
# reader answers, includes over each, and the declarations the generator
# refuses. Claims about queries are deltas of Connection#statements_run.
# SQLite is FFI, so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_through/db/schema"
require_relative "fixtures/gen_through/gen/models/author"
require_relative "fixtures/gen_through/gen/models/comment"
require_relative "fixtures/gen_through/gen/models/post"
require_relative "fixtures/gen_through/gen/models/tag"
require_relative "fixtures/gen_through/gen/models/tagging"
require_relative "fixtures/gen_through/app/models/author"
require_relative "fixtures/gen_through/app/models/comment"
require_relative "fixtures/gen_through/app/models/post"
require_relative "fixtures/gen_through/app/models/tag"
require_relative "fixtures/gen_through/app/models/tagging"

FIXTURE = "test/fixtures/gen_through"

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.exec_script(SchemaTables.create_sql(Cybertrain::Schema.current)) }

def statements = Cybertrain::DB.with { |c| c.statements_run }

# Authors ann (posts p1, p2) and bob (none); p3 has no author. Tags
# ruby, sql, web: p1 is tagged ruby and sql, p2 sql twice (one tag through
# two taggings), p3 web. Comments c1 and c2 on p1, c3 on p2, c4 on p3.
def seed
  Cybertrain::DB.with do |c|
    c.exec_script("DELETE FROM comments; DELETE FROM taggings; DELETE FROM tags; DELETE FROM posts; DELETE FROM authors;")
  end
  ann = Author.create(name: "ann")
  Author.create(name: "bob")
  p1 = Post.create(title: "p1", author_id: ann.id)
  p2 = Post.create(title: "p2", author_id: ann.id)
  p3 = Post.create(title: "p3")
  ruby = Tag.create(name: "ruby")
  sql = Tag.create(name: "sql")
  web = Tag.create(name: "web")
  Tagging.create(post_id: p1.id, tag_id: ruby.id)
  Tagging.create(post_id: p1.id, tag_id: sql.id)
  Tagging.create(post_id: p2.id, tag_id: sql.id)
  Tagging.create(post_id: p2.id, tag_id: sql.id)
  Tagging.create(post_id: p3.id, tag_id: web.id)
  Comment.create(post_id: p1.id, body: "c1")
  Comment.create(post_id: p1.id, body: "c2")
  Comment.create(post_id: p2.id, body: "c3")
  Comment.create(post_id: p3.id, body: "c4")
  nil
end

def post_titled(title) = Post.find_by!(title: title)

def tag_names(tags) = tags.map { |t| t.name }

def bodies(comments) = comments.map { |c| c.body }

test "the checked-in gen/models files match the emitter (fixture stale otherwise)" do
  infos = Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models")
  outputs = Cybertrain::Gen::ModelsEmitter.outputs(Cybertrain::Schema.current, infos)
  assert_equal ["gen/models/author.rb", "gen/models/comment.rb", "gen/models/post.rb", "gen/models/tag.rb",
                "gen/models/tagging.rb"], outputs.keys.sort
  outputs.each do |path, source|
    Cybertrain::Test.count_assertion
    flunk("fixture stale: #{path}") unless File.read(FIXTURE + "/" + path) == source
  end
end

test "scan_source reads through: and source:" do
  infos = Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models")
  post_info = infos.select { |info| info.class_name == "Post" }[0]
  assert_equal ["", "", "taggings", "taggings", "author"], post_info.associations.map { |a| a.through_name }
  assert_equal ["", "", "", "tag", "posts"], post_info.associations.map { |a| a.source_name }
end

test "the reader is one Relation over the target with a subquery through the middle table" do
  seed
  p1 = post_titled("p1")
  assert_equal "SELECT * FROM `tags` WHERE (`tags`.`id` IN (SELECT `tag_id` FROM `taggings` WHERE `post_id` = ?))",
               p1.tags.to_sql
  assert_equal ["ruby", "sql"], tag_names(p1.tags.order(id: :asc).to_a)
  assert_equal ["ruby", "sql"], tag_names(p1.labels.order(id: :asc).to_a)
end

test "a through has_many chains: where, order, count, exists?, first, pluck" do
  seed
  p1 = post_titled("p1")
  assert_equal 2, p1.tags.count
  assert_equal 1, p1.tags.where(name: "sql").count
  assert_equal ["sql", "ruby"], tag_names(p1.tags.order(name: :desc).to_a)
  assert p1.tags.where(name: "ruby").exists?
  refute p1.tags.where(name: "web").exists?
  assert_equal "ruby", p1.tags.first.name
  assert_equal ["sql"], p1.tags.where(name: "sql").pluck_str(:name)
end

test "a target reached through two middle rows comes once" do
  seed
  p2 = post_titled("p2")
  assert_equal 2, Tagging.where(post_id: p2.id).count
  assert_equal ["sql"], tag_names(p2.tags.to_a)
  assert_equal 1, p2.tags.count
end

test "the other way round: Tag#posts through the foreign-key-derived taggings" do
  seed
  sql = Tag.find_by!(name: "sql")
  assert_equal ["p1", "p2"], sql.posts.order(id: :asc).to_a.map { |p| p.title }
  assert_equal 0, Tag.create(name: "unused").posts.count
end

test "a has_many via with a has_many source: Author#comments through posts" do
  seed
  ann = Author.find_by!(name: "ann")
  bob = Author.find_by!(name: "bob")
  assert_equal ["c1", "c2", "c3"], bodies(ann.comments.order(id: :asc).to_a)
  assert_equal ["c3"], bodies(ann.comments.where(post_id: post_titled("p2").id).to_a)
  assert bob.comments.to_a.empty?
end

test "a belongs_to via: Comment#thread_comments and #writers through its post" do
  seed
  c1 = Comment.find_by!(body: "c1")
  c4 = Comment.find_by!(body: "c4")
  assert_equal ["c1", "c2"], bodies(c1.thread_comments.order(id: :asc).to_a)
  assert_equal ["ann"], c1.writers.to_a.map { |a| a.name }
  # p3's author_id is nil: the middle row's link is NULL, so no writer.
  assert_equal 0, c4.writers.count
end

test "a nullable belongs_to via answers nothing for a nil key" do
  seed
  assert_equal ["p1", "p2"], post_titled("p1").co_posts.order(id: :asc).to_a.map { |p| p.title }
  assert_equal 0, post_titled("p3").co_posts.count
end

test "includes of a through has_many is three statements; the readers then run none" do
  seed
  before = statements
  posts = Post.order(id: :asc).includes(:tags).to_a
  assert_equal 3, statements - before
  before = statements
  assert_equal [["ruby", "sql"], ["sql"], ["web"]], posts.map { |p| tag_names(p.tags.to_a) }
  assert_equal [2, 1, 1], posts.map { |p| p.tags.size }
  assert_equal ["sql", "sql", "web"], posts.map { |p| p.tags.last.name }
  assert_equal 0, statements - before
  # A chain method drops the preload and queries.
  assert_equal 1, posts[0].tags.where(name: "ruby").count
  assert_equal 1, statements - before
end

test "includes of each kind of path fills every record, empty where nothing matches" do
  seed
  authors = Author.order(id: :asc).includes(:comments).to_a
  assert_equal [["c1", "c2", "c3"], []], authors.map { |a| bodies(a.comments.to_a) }
  before = statements
  comments = Comment.order(id: :asc).includes(:thread_comments, :writers).to_a
  assert_equal 5, statements - before
  before = statements
  assert_equal [["c1", "c2"], ["c1", "c2"], ["c3"], ["c4"]], comments.map { |c| bodies(c.thread_comments.to_a) }
  assert_equal [["ann"], ["ann"], ["ann"], []], comments.map { |c| c.writers.to_a.map { |a| a.name } }
  assert_equal 0, statements - before
  posts = Post.order(id: :asc).includes(:co_posts, :labels).to_a
  assert_equal [["p1", "p2"], ["p1", "p2"], []], posts.map { |p| p.co_posts.to_a.map { |q| q.title } }
  assert_equal [["ruby", "sql"], ["sql"], ["web"]], posts.map { |p| tag_names(p.labels.to_a) }
  tags = Tag.order(id: :asc).includes(:posts).to_a
  assert_equal [["p1"], ["p1", "p2"], ["p3"]], tags.map { |t| t.posts.to_a.map { |q| q.title } }
  # The roots and two statements per through name (1 + 4 and 1 + 2).
  assert_equal 8, statements - before
end

test "nested includes go below and through a through has_many, one level at a time (D95)" do
  seed
  before = statements
  # posts, then taggings and tags, then each tag's taggings and posts.
  posts = Post.order(id: :asc).includes(tags: :posts).to_a
  assert_equal 5, statements - before
  before = statements
  assert_equal [["ruby:p1", "sql:p1,p2"], ["sql:p1,p2"], ["web:p3"]],
               posts.map { |p| p.tags.to_a.map { |t| "#{t.name}:#{t.posts.to_a.map { |q| q.title }.join(",")}" } }
  assert_equal 0, statements - before
  # authors, posts, then the posts' taggings and tags.
  authors = Author.order(id: :asc).includes(posts: :tags).to_a
  assert_equal 4, statements - before
  assert_equal [[["ruby", "sql"], ["sql"]], []], authors.map { |a| a.posts.to_a.map { |q| tag_names(q.tags.to_a) } }
  assert_equal 4, statements - before
  assert_equal "unknown association nope for Tag", assert_raises("ArgumentError") { Post.includes(tags: :nope) }
end

test "reload drops a through has_many's preload" do
  seed
  p1 = Post.order(id: :asc).includes(:tags).to_a[0]
  before = statements
  assert_equal 2, p1.tags.to_a.size
  assert_equal 0, statements - before
  p1.reload
  before = statements
  p1.tags.to_a
  assert_equal 1, statements - before
end

# The message ModelsEmitter.outputs raises for the fixture with one model
# file's source replaced.
def through_error(class_name, source)
  file = "#{FIXTURE}/app/models/#{class_name.downcase}.rb"
  replaced = Array.new(0) { Cybertrain::Gen::ModelInfo.empty("", "", Array.new(0) { "" }) }
  Cybertrain::Gen::ModelScan.scan_dir(FIXTURE + "/app/models").each do |info|
    if info.class_name == class_name
      scanned = Cybertrain::Gen::ModelScan.scan_source(file, source)
      replaced << scanned unless scanned.nil?
    else
      replaced << info
    end
  end
  assert_raises("ModelScan::Error") { Cybertrain::Gen::ModelsEmitter.outputs(Cybertrain::Schema.current, replaced) }
end

test "a through: or source: the generator cannot follow fails with the file and line" do
  at = FIXTURE + "/app/models/"
  assert_equal at + "post.rb:2: has_many :tags: through: :links is not an association of this model",
               through_error("Post", "class Post\n  has_many :tags, through: :links\nend\n")
  assert_equal at + "post.rb:3: has_many :things: Tagging has no association thing or things to read; set source:",
               through_error("Post", "class Post\n  has_many :taggings\n  has_many :things, through: :taggings\nend\n")
  assert_equal at + "post.rb:3: has_many :more: through: :tags is itself a through association; only one level is " \
                    "supported",
               through_error("Post", "class Post\n  has_many :tags, through: :taggings\n  has_many :more, through: :tags\nend\n")
  assert_equal at + "author.rb:3: has_many :tags: the source Post#tags is itself a through association; only one " \
                    "level is supported",
               through_error("Author", "class Author\n  has_many :posts\n  has_many :tags, through: :posts\nend\n")
end

# The message ModelScan raises for a Post model of one association line.
def scan_error(line)
  assert_raises("ModelScan::Error") do
    Cybertrain::Gen::ModelScan.scan_source("app/models/post.rb", "class Post\n  #{line}\nend\n")
  end
end

test "through: takes no dependent:, class_name: or foreign_key:, and source: needs through:" do
  assert_equal "app/models/post.rb:2: has_many :tags: dependent: does not go with through: (the key and class come " \
               "from source:)", scan_error("has_many :tags, through: :taggings, dependent: :destroy")
  assert_equal "app/models/post.rb:2: has_many :tags: class_name: does not go with through: (the key and class come " \
               "from source:)", scan_error("has_many :tags, class_name: \"Tag\", through: :taggings")
  assert_equal "app/models/post.rb:2: has_many :tags: as: does not go with through: (the key and class come " \
               "from source:)", scan_error("has_many :tags, through: :taggings, as: :taggable")
  assert_equal "app/models/post.rb:2: has_many :tags: source: needs through:", scan_error("has_many :tags, source: :tag")
  assert_equal "app/models/post.rb:2: has_many :tags: through: takes an association name (got \"a b\")",
               scan_error("has_many :tags, through: \"a b\"")
end

# A schema with a polymorphic pair (D94), for the throughs refused over
# one. Defined last: Schema.define makes it the current schema.
def poly_error(sources)
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "authors" do |t|
      t.string "name", null: false
    end
    s.create_table "comments" do |t|
      t.text "body", null: false
      t.references :commentable, polymorphic: true
    end
    s.create_table "flags" do |t|
      t.references :comment
    end
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.references :author
    end
  end
  infos = Array.new(0) { Cybertrain::Gen::ModelInfo.empty("", "", Array.new(0) { "" }) }
  sources.each do |file, source|
    scanned = Cybertrain::Gen::ModelScan.scan_source(file, source)
    infos << scanned unless scanned.nil?
  end
  assert_raises("ModelScan::Error") { Cybertrain::Gen::ModelsEmitter.outputs(definition, infos) }
end

test "a through over a polymorphic association, as its via or its source, fails with the file and line" do
  comment = "class Comment\n  belongs_to :commentable, polymorphic: true\nend\n"
  post = "class Post\n  has_many :comments, as: :commentable\nend\n"
  assert_equal "app/models/comment.rb:3: has_many :others: through: :commentable is a polymorphic association " \
               "(D94); a through over one is not supported",
               poly_error({ "app/models/post.rb" => post,
                            "app/models/comment.rb" => comment.sub("end\n", "  has_many :others, through: :commentable, " \
                                                                                "source: :comments\nend\n") })
  assert_equal "app/models/post.rb:3: has_many :bodies: through: :comments is a polymorphic association (D94); a " \
               "through over one is not supported",
               poly_error({ "app/models/comment.rb" => comment,
                            "app/models/post.rb" => post.sub("end\n", "  has_many :bodies, through: :comments, " \
                                                                      "source: :flags\nend\n") })
  assert_equal "app/models/flag.rb:3: has_many :targets: the source Comment#commentable is a polymorphic " \
               "association (D94); a through over one is not supported",
               poly_error({ "app/models/comment.rb" => comment, "app/models/post.rb" => post,
                            "app/models/flag.rb" => "class Flag\n  belongs_to :comment\n  has_many :targets, " \
                                                    "through: :comment, source: :commentable\nend\n" })
  assert_equal "app/models/author.rb:2: has_many :comments: the source Post#comments is a polymorphic association " \
               "(D94); a through over one is not supported",
               poly_error({ "app/models/comment.rb" => comment, "app/models/post.rb" => post,
                            "app/models/author.rb" => "class Author\n  has_many :comments, through: :posts\nend\n" })
end

Cybertrain::Test.run!
