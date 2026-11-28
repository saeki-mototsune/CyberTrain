require "cybertrain/test"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

# test/polymorphic.rb on MySQL, against the server CYBERTRAIN_TEST_MYSQL_URL names
# (script/test-mysql runs this program): polymorphic associations (docs/design.md D94) on the checked-in generated
# models of test/fixtures/gen_poly, loaded as the original loads them, and the
# original's tests, with its snapshot (test/polymorphic.rb.expected, copied).
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
# Polymorphic associations as the model generator writes them
# (docs/design.md D94): the checked-in gen/models files of
# test/fixtures/gen_poly, with the fixture's app/models files, driven
# against SQLite. Comment belongs to a Post or a Photo (NOT NULL columns),
# Note to either or nothing (nullable ones). SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require_relative "../fixtures/gen_poly/db/schema"
require_relative "../fixtures/gen_poly/gen/models/comment"
require_relative "../fixtures/gen_poly/gen/models/note"
require_relative "../fixtures/gen_poly/gen/models/photo"
require_relative "../fixtures/gen_poly/gen/models/post"
require_relative "../fixtures/gen_poly/app/models/comment"
require_relative "../fixtures/gen_poly/app/models/note"
require_relative "../fixtures/gen_poly/app/models/photo"
require_relative "../fixtures/gen_poly/app/models/post"

POLY_FIXTURE = "test/fixtures/gen_poly"

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# MySQL: the fixture schema (test/fixtures/gen_poly/db/schema.rb) as hand-written DDL
# in the design's types (Task 10 generates it; SQLite's comes from
# test/support/schema_tables.rb), outside any transaction.
TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
CREATE_TABLES_SQL =
  "CREATE TABLE comments (id BIGINT AUTO_INCREMENT PRIMARY KEY, body MEDIUMTEXT NOT NULL, commentable_type VARCHAR(255) NOT NULL, commentable_id BIGINT NOT NULL, created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL)#{TABLE_OPTIONS};" \
  "CREATE TABLE notes (id BIGINT AUTO_INCREMENT PRIMARY KEY, body MEDIUMTEXT, notable_type VARCHAR(255), notable_id BIGINT)#{TABLE_OPTIONS};" \
  "CREATE TABLE photos (id BIGINT AUTO_INCREMENT PRIMARY KEY, url VARCHAR(255) NOT NULL)#{TABLE_OPTIONS};" \
  "CREATE TABLE posts (id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255) NOT NULL)#{TABLE_OPTIONS};"
Cybertrain::DB.connect(URL, size: 1)
# This program's own tables are dropped first, by name, with any table of
# the other test/mysql programs that references one of them
# (test/mysql/support/tables.rb).
Cybertrain::DB.with { |c| MySQLTestTables.drop(c, ["comments", "notes", "photos", "posts"]) }
Cybertrain::DB.with { |c| c.exec_script(CREATE_TABLES_SQL) }

def reset_poly_tables
  Cybertrain::DB.with do |c|
    # MySQL: the ids back to 1 by ALTER TABLE (SQLite: sqlite_sequence).
    c.exec_script("DELETE FROM comments; DELETE FROM notes; DELETE FROM photos; DELETE FROM posts; " \
                  "ALTER TABLE comments AUTO_INCREMENT = 1; ALTER TABLE notes AUTO_INCREMENT = 1; " \
                  "ALTER TABLE photos AUTO_INCREMENT = 1; ALTER TABLE posts AUTO_INCREMENT = 1;")
  end
end

# What a polymorphic reader answered, narrowed the way an application does.
def described(record)
  case record
  when nil then "nil"
  when Post then "Post #{record.id} #{record.title}"
  when Photo then "Photo #{record.id} #{record.url}"
  else "other"
  end
end

test "the checked-in gen/models files match the emitter (fixture stale otherwise)" do
  infos = Cybertrain::Gen::ModelScan.scan_dir(POLY_FIXTURE + "/app/models")
  outputs = Cybertrain::Gen::ModelsEmitter.outputs(Cybertrain::Schema.current, infos)
  assert_equal ["gen/models/comment.rb", "gen/models/note.rb", "gen/models/photo.rb", "gen/models/post.rb"],
               outputs.keys
  outputs.each do |path, source|
    Cybertrain::Test.count_assertion
    flunk("fixture stale: #{path}") unless File.read(POLY_FIXTURE + "/" + path) == source
  end
end

test "the writer stores Rails' class name and the id, and the reader answers the record" do
  reset_poly_tables
  post = Post.create(title: "hello")
  photo = Photo.create(url: "a.png")
  c = Comment.new(body: "first")
  c.commentable = post
  assert_equal "Post", c.commentable_type
  assert_equal post.id, c.commentable_id
  assert c.save
  row = Cybertrain::DB.with { |conn| conn.execute("SELECT commentable_type, commentable_id FROM comments") }
  assert_equal "Post", row[0]["commentable_type"].to_s
  assert_equal post.id, Cybertrain::Cast.int(row[0]["commentable_id"])
  assert_equal "Post 1 hello", described(Comment.find(c.id).commentable)
  # The same id in the other table: the type decides.
  d = Comment.create(body: "second", commentable: photo)
  assert_equal "Photo", d.commentable_type
  assert_equal "Photo 1 a.png", described(Comment.find(d.id).commentable)
  # Calls the targets share dispatch on the boxed value.
  assert_equal "post hello", Comment.find(c.id).commentable.caption
  assert_equal "photo a.png", Comment.find(d.id).commentable.caption
end

test "the reader's cache follows the type and the key" do
  reset_poly_tables
  post = Post.create(title: "p")
  photo = Photo.create(url: "u")
  c = Comment.create(body: "x", commentable: post)
  loaded = Comment.find(c.id)
  assert_equal "Post 1 p", described(loaded.commentable)
  loaded.commentable_type = "Photo"
  assert_equal "Photo 1 u", described(loaded.commentable)
  loaded.commentable_id = 2
  assert_equal "nil", described(loaded.commentable)
  loaded.commentable = nil
  assert_equal "", loaded.commentable_type
  assert_equal 0, loaded.commentable_id
  assert_equal "nil", described(loaded.commentable)
  assert_equal "Photo 1 u", described(Comment.new(body: "y", commentable: photo).commentable)
end

test "a required polymorphic belongs_to validates both columns" do
  reset_poly_tables
  c = Comment.new(body: "orphan")
  assert !c.save
  assert_equal ["Commentable type can't be blank", "Commentable can't be blank"].sort, c.errors.full_messages.sort
  note = Note.new(body: "free")
  assert note.save
  assert_equal "nil", described(note.notable)
end

test "a type that is no target raises; so does writing a record of another model" do
  reset_poly_tables
  c = Comment.new(body: "x")
  c.commentable_type = "Video"
  c.commentable_id = 1
  msg = assert_raises("ArgumentError") { c.commentable }
  assert_equal "commentable_type \"Video\" is not Photo or Post (the models that declare as: :commentable)", msg
  msg = assert_raises("ArgumentError") { c.commentable = Note.new }
  assert_equal "commentable= takes Photo or Post (or nil)", msg
end

test "has_many as: reads the children of its own type only" do
  reset_poly_tables
  post = Post.create(title: "p")
  photo = Photo.create(url: "u")
  Comment.create(body: "on post", commentable: post)
  Comment.create(body: "on photo", commentable: photo)
  Comment.create(body: "on post again", commentable: post)
  assert_equal ["on post", "on post again"], post.comments.to_a.map { |x| x.body }
  assert_equal ["on photo"], photo.comments.to_a.map { |x| x.body }
  assert_equal 1, post.comments.where(body: "on post again").count
  assert_equal "nil", described(Note.find_by(notable_id: 1))
  Note.create(body: "n", notable: post)
  assert_equal "n", post.note.body
  assert_equal [], photo.notes.to_a.map { |x| x.body }
end

test "includes preloads a polymorphic belongs_to per type, and the has_many and has_one with as:" do
  reset_poly_tables
  post = Post.create(title: "p")
  photo = Photo.create(url: "u")
  Comment.create(body: "a", commentable: post)
  Comment.create(body: "b", commentable: photo)
  Comment.create(body: "c", commentable: post)
  Note.create(body: "n", notable: photo)
  Note.create(body: "loose")
  comments = Comment.order(id: :asc).includes(:commentable).to_a
  notes = Note.order(id: :asc).includes(:notable).to_a
  posts = Post.includes(:comments, :note).to_a
  photos = Photo.includes(:comments, :notes).to_a
  # Gone from the database: only the preloaded caches can answer now.
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM posts; DELETE FROM photos; DELETE FROM comments; DELETE FROM notes;") }
  assert_equal ["Post 1 p", "Photo 1 u", "Post 1 p"], comments.map { |x| described(x.commentable) }
  assert_equal ["Photo 1 u", "nil"], notes.map { |x| described(x.notable) }
  assert_equal ["a", "c"], posts[0].comments.to_a.map { |x| x.body }
  assert_equal "nil", described(posts[0].note)
  assert_equal ["b"], photos[0].comments.to_a.map { |x| x.body }
  assert_equal ["n"], photos[0].notes.to_a.map { |x| x.body }
end

test "dependent: on has_many / has_one as: touches the children of its own type only" do
  reset_poly_tables
  post = Post.create(title: "p")
  photo = Photo.create(url: "u")
  Comment.create(body: "on post", commentable: post)
  Comment.create(body: "on photo", commentable: photo)
  Note.create(body: "post note", notable: post)
  Note.create(body: "photo note", notable: photo)
  post.destroy
  assert_equal ["on photo"], Comment.all.to_a.map { |x| x.body }
  kept = Note.find_by(body: "post note")
  assert kept.notable_type.nil?
  assert kept.notable_id.nil?
  assert_equal "Photo", Note.find_by(body: "photo note").notable_type
  photo.destroy
  assert_equal ["post note"], Note.all.to_a.map { |x| x.body }
  # Photo's has_many :comments has no dependent: the comment stays.
  assert_equal 1, Comment.count
end

test "read_association answers the polymorphic parent to templates" do
  reset_poly_tables
  photo = Photo.create(url: "u")
  c = Comment.create(body: "x", commentable: photo)
  assert_equal "Photo 1 u", described(Comment.find(c.id).read_association(:commentable))
  assert Comment.new.attribute_or_method?(:commentable)
end

# Nested includes through polymorphic associations (docs/design.md D95).
def poly_statements = Cybertrain::DB.with { |c| c.statements_run }

test "includes nests below a polymorphic belongs_to, one statement per target type found, and below has_many as:" do
  reset_poly_tables
  post = Post.create(title: "p")
  photo = Photo.create(url: "u")
  Comment.create(body: "a", commentable: post)
  Comment.create(body: "b", commentable: photo)
  Comment.create(body: "c", commentable: post)
  before = poly_statements
  # comments, then posts and photos, then the comments of each.
  comments = Comment.order(id: :asc).includes(commentable: :comments).to_a
  assert_equal 5, poly_statements - before
  counts = comments.map do |c|
    parent = c.commentable
    case parent
    when Post then "#{c.body}:post #{parent.comments.size}"
    when Photo then "#{c.body}:photo #{parent.comments.size}"
    else "-"
    end
  end
  assert_equal ["a:post 2", "b:photo 1", "c:post 2"], counts
  assert_equal 5, poly_statements - before
  # has_many as: then the polymorphic belongs_to back: posts, comments, posts.
  posts = Post.includes(comments: :commentable).to_a
  assert_equal 8, poly_statements - before
  assert_equal ["Post 1 p", "Post 1 p"], posts[0].comments.to_a.map { |c| described(c.commentable) }
  assert_equal 8, poly_statements - before
end

test "a path below a polymorphic belongs_to must be an association of every target" do
  before = poly_statements
  assert_equal "unknown association note for Photo", assert_raises("ArgumentError") { Comment.includes(commentable: :note) }
  assert_equal "unknown association nope for Photo", assert_raises("ArgumentError") { Note.preload(notable: :nope) }
  assert_equal 0, poly_statements - before
end

Cybertrain::Test.run!
