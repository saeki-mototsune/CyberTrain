require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"

# Two counter-cached models in one program (spikes/NOTES.md rule 88): the
# generated callback blocks (`after_create { |record|
# record.counter_cache_created }`, ...) are stored on Cybertrain::Model and
# called with a record typed as the base class, and the counter_cache_*
# hooks they call exist only on each subclass (Model has no stub for them,
# model.rb says why). This pins that each block reaches its own subclass's
# hook when two such subclasses share the program, as two `belongs_to ...,
# counter_cache: true` models do in an app. SQLite is FFI, so the snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Comment and Like are hand-written in the shape the model generator emits
# (association_emitter.rb's emit_counter_cache; test/gen_models.rb holds the
# emitted text), trimmed to create and destroy.

LOG = Array.new(0) { "" }

class Comment < Cybertrain::Model
  def self.table_name = "comments"
  def self.column_names = ["id", "post_id"]
  def model_name = "Comment"

  attr_accessor :post_id

  after_create { |record| record.counter_cache_created }
  before_destroy { |record| record.counter_cache_was }
  after_destroy { |record| record.counter_cache_destroyed }

  def initialize(attrs = {})
    super()
    @post_id = 0
    @post_id_was = 0
    @counter_cache_found = false
  end

  def to_row = { "post_id" => Cybertrain::Cast.to_sql(@post_id) }
  def read_attribute(name) = nil
  def call_view_method(name) = nil
  def read_association(name) = nil
  def counter_cached? = true

  def counter_cache_created
    LOG << "comment created on #{@post_id}"
    sql = "UPDATE posts SET comments_count = comments_count + 1 WHERE id = ?"
    id = @post_id
    Cybertrain::DB.with { |c| c.execute(sql, [id]) }
    nil
  end

  def counter_cache_was
    id = @id
    found = Cybertrain::DB.with { |c| c.execute("SELECT post_id FROM comments WHERE id = ?", [id]) }
    @counter_cache_found = !found.empty?
    @post_id_was = Cybertrain::Cast.int(found.empty? ? nil : found[0]["post_id"])
    LOG << "comment was on #{@post_id_was}"
    nil
  end

  def counter_cache_destroyed
    return nil unless @counter_cache_found

    sql = "UPDATE posts SET comments_count = comments_count - 1 WHERE id = ?"
    id = @post_id_was
    Cybertrain::DB.with { |c| c.execute(sql, [id]) }
    nil
  end
end

class Like < Cybertrain::Model
  def self.table_name = "likes"
  def self.column_names = ["id", "photo_id"]
  def model_name = "Like"

  attr_accessor :photo_id

  after_create { |record| record.counter_cache_created }
  before_destroy { |record| record.counter_cache_was }
  after_destroy { |record| record.counter_cache_destroyed }

  def initialize(attrs = {})
    super()
    @photo_id = 0
    @photo_id_was = 0
    @counter_cache_found = false
  end

  def to_row = { "photo_id" => Cybertrain::Cast.to_sql(@photo_id) }
  def read_attribute(name) = nil
  def call_view_method(name) = nil
  def read_association(name) = nil
  def counter_cached? = true

  def counter_cache_created
    LOG << "like created on #{@photo_id}"
    sql = "UPDATE photos SET likes_count = likes_count + 1 WHERE id = ?"
    id = @photo_id
    Cybertrain::DB.with { |c| c.execute(sql, [id]) }
    nil
  end

  def counter_cache_was
    id = @id
    found = Cybertrain::DB.with { |c| c.execute("SELECT photo_id FROM likes WHERE id = ?", [id]) }
    @counter_cache_found = !found.empty?
    @photo_id_was = Cybertrain::Cast.int(found.empty? ? nil : found[0]["photo_id"])
    LOG << "like was on #{@photo_id_was}"
    nil
  end

  def counter_cache_destroyed
    return nil unless @counter_cache_found

    sql = "UPDATE photos SET likes_count = likes_count - 1 WHERE id = ?"
    id = @photo_id_was
    Cybertrain::DB.with { |c| c.execute(sql, [id]) }
    nil
  end
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.exec_script(
    "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, comments_count INTEGER NOT NULL DEFAULT 0);" \
    "CREATE TABLE photos (id INTEGER PRIMARY KEY AUTOINCREMENT, likes_count INTEGER NOT NULL DEFAULT 0);" \
    "CREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER NOT NULL);" \
    "CREATE TABLE likes (id INTEGER PRIMARY KEY AUTOINCREMENT, photo_id INTEGER NOT NULL);" \
    "INSERT INTO posts (comments_count) VALUES (0); INSERT INTO photos (likes_count) VALUES (0);"
  )
end

def counter(sql)
  Cybertrain::DB.with { |c| Cybertrain::Cast.int(c.execute(sql, [])[0]["n"]) }
end

test "each model's callback blocks reach its own counter_cache hooks" do
  comment = Comment.new
  comment.post_id = 1
  assert comment.save
  like = Like.new
  like.photo_id = 1
  assert like.save
  second = Like.new
  second.photo_id = 1
  assert second.save
  assert_equal 1, counter("SELECT comments_count AS n FROM posts WHERE id = 1")
  assert_equal 2, counter("SELECT likes_count AS n FROM photos WHERE id = 1")
  assert comment.destroy
  assert like.destroy
  assert_equal 0, counter("SELECT comments_count AS n FROM posts WHERE id = 1")
  assert_equal 1, counter("SELECT likes_count AS n FROM photos WHERE id = 1")
  assert_equal ["comment created on 1", "like created on 1", "like created on 1", "comment was on 1", "like was on 1"], LOG
end

Cybertrain::Test.run!
