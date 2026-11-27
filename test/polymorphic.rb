require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"
require_relative "support/schema_tables"

# Polymorphic associations as the model generator writes them
# (docs/design.md D94): the checked-in gen/models files of
# test/fixtures/gen_poly, with the fixture's app/models files, driven
# against SQLite. Comment belongs to a Post or a Photo (NOT NULL columns),
# Note to either or nothing (nullable ones). SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_poly/db/schema"
require_relative "fixtures/gen_poly/gen/models/comment"
require_relative "fixtures/gen_poly/gen/models/note"
require_relative "fixtures/gen_poly/gen/models/photo"
require_relative "fixtures/gen_poly/gen/models/post"
require_relative "fixtures/gen_poly/app/models/comment"
require_relative "fixtures/gen_poly/app/models/note"
require_relative "fixtures/gen_poly/app/models/photo"
require_relative "fixtures/gen_poly/app/models/post"

POLY_FIXTURE = "test/fixtures/gen_poly"

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with { |c| c.exec_script(SchemaTables.create_sql(Cybertrain::Schema.current)) }

def reset_poly_tables
  Cybertrain::DB.with do |c|
    c.exec_script("DELETE FROM comments; DELETE FROM notes; DELETE FROM photos; DELETE FROM posts; " \
                  "DELETE FROM sqlite_sequence;")
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

Cybertrain::Test.run!
