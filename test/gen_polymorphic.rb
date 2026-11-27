require "cybertrain/test"
require "cybertrain/schema"
require "cybertrain/migration"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

# Polymorphic associations in the model generator (docs/design.md D94):
# the scan of `polymorphic: true` and `as:`, the plan's checks, and the
# schema side of `t.references ..., polymorphic: true` and
# `add_reference` / `remove_reference`. No database: CRuby-portable.
# test/polymorphic.rb drives the generated models against SQLite.

def poly_schema
  Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "comments" do |t|
      t.text "body", null: false
      t.references :commentable, polymorphic: true
    end
    s.create_table "posts" do |t|
      t.string "title", null: false
      t.string "subject_type"
      t.integer "subject_id"
    end
    s.create_table "photos" do |t|
      t.string "url", null: false
    end
  end
end

def scan(file, source)
  Cybertrain::Gen::ModelScan.scan_source(file, source)
end

COMMENT_SOURCE = "class Comment\n  belongs_to :commentable, polymorphic: true\nend\n"
POST_SOURCE = "class Post\n  has_many :comments, as: :commentable, dependent: :destroy\nend\n"
PHOTO_SOURCE = "class Photo\n  has_one :comment, as: :commentable\nend\n"

def emit_poly(table, infos)
  definition = poly_schema
  Cybertrain::Gen::ModelsEmitter.emit_model(definition.table(table), definition, [], [], infos)
end

def poly_infos
  [scan("app/models/comment.rb", COMMENT_SOURCE), scan("app/models/photo.rb", PHOTO_SOURCE),
   scan("app/models/post.rb", POST_SOURCE)]
end

test "t.references polymorphic: true adds the type and id columns and Rails' index, no foreign key" do
  table = poly_schema.table("comments")
  assert_equal ["body", "commentable_type", "commentable_id"], table.columns.map { |c| c.name }
  assert_equal [:text, :string, :integer], table.columns.map { |c| c.type }
  assert_equal [false, false], [table.column("commentable_type").null, table.column("commentable_id").null]
  assert_equal ["index_comments_on_commentable"], table.indexes.map { |i| i.name }
  assert_equal [["commentable_type", "commentable_id"]], table.indexes.map { |i| i.columns }
  assert_equal 0, table.foreign_keys.size
end

test "t.references polymorphic: true takes null: and index:, and refuses on_delete:" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "notes" do |t|
      t.references :notable, polymorphic: true, null: true, index: false
    end
  end
  table = definition.table("notes")
  assert_equal [true, true], table.columns.map { |c| c.null }
  assert_equal 0, table.indexes.size
  msg = assert_raises("ArgumentError") do
    Cybertrain::Schema.define(version: "1") do |s|
      s.create_table "notes" do |t|
        t.references :notable, polymorphic: true, null: true, on_delete: :cascade
      end
    end
  end
  assert_includes msg, "a polymorphic reference has none"
end

class AddNotable < Cybertrain::Migration::Base
  def up
    add_reference "notes", :notable, polymorphic: true, null: true
  end

  def down
    remove_reference "notes", :notable, polymorphic: true
  end
end

test "add_reference and remove_reference with polymorphic: true record the columns and the index" do
  m = AddNotable.new
  m.up
  ops = m.operations
  assert_equal [:add_column, :add_column, :add_index], ops.map { |op| op.kind }
  assert_equal ["notable_type", "notable_id", "index_notes_on_notable"], ops.map { |op| op.name }
  assert_equal [:string, :integer], [ops[0].type, ops[1].type]
  assert_equal ["notable_type", "notable_id"], ops[2].columns
  m.operations.clear
  m.down
  ops = m.operations
  assert_equal [:remove_index, :remove_column, :remove_column], ops.map { |op| op.kind }
  assert_equal ["notable_type", "notable_id"], ops[0].columns
end

test "the scan reads polymorphic: and as:" do
  infos = poly_infos
  assert_equal [true], infos[0].associations.map { |a| a.polymorphic }
  assert_equal [""], infos[0].associations.map { |a| a.as_name }
  assert_equal ["commentable"], infos[1].associations.map { |a| a.as_name }
  assert_equal ["commentable"], infos[2].associations.map { |a| a.as_name }
  assert_equal [false], infos[2].associations.map { |a| a.polymorphic }
end

test "the scan refuses the options a polymorphic pair does not take" do
  [["belongs_to :commentable, polymorphic: true, class_name: \"Post\"", "class_name: is not taken with polymorphic: true"],
   ["belongs_to :commentable, polymorphic: true, foreign_key: :x_id", "foreign_key: is not taken with polymorphic: true"],
   ["belongs_to :commentable, polymorphic: true, counter_cache: true", "counter_cache: is not taken with polymorphic: true"],
   ["belongs_to :commentable, polymorphic: :yes", "polymorphic: takes true or false (got :yes)"],
   ["has_many :comments, as: :commentable, foreign_key: :x_id", "foreign_key: is not taken with as: (the columns are commentable_type and commentable_id)"],
   ["has_many :comments, as: \"commentable\"", "as: takes the polymorphic belongs_to's name as a Symbol"],
   ["has_one :comment, polymorphic: true", "unknown option polymorphic:"]].each do |pair|
    msg = assert_raises("ModelScan::Error") { scan("app/models/x.rb", "class X\n  #{pair[0]}\nend\n") }
    assert_includes msg, pair[1]
  end
end

test "a polymorphic belongs_to reads, writes and preloads the models that declare as:" do
  src = emit_poly("comments", poly_infos)
  assert_includes src, "    unless type == \"Photo\" || type == \"Post\"\n"
  assert_includes src, "      when \"Photo\" then Photo.find_by(id: key)\n      when \"Post\" then Post.find_by(id: key)\n"
  assert_includes src, "  def commentable=(record)\n"
  assert_includes src, "    when Post\n      @commentable_type = \"Post\"\n      @commentable_id = record.id\n"
  assert_includes src, "    when :commentable then self.commentable = value\n"
  assert_includes src, "  validates_foreign_key :commentable_id\n  validates_foreign_key :commentable_type\n"
  assert_includes src, "    @commentable_loaded_type = \"\"\n"
  assert_includes src, "        found_commentable_1 = PostRelation.new(\"posts\").where(id: ids_commentable_1[start, step]).to_a\n"
  assert_includes src, "        when \"Post\" then records[i].commentable_preload!(index_commentable_1[key])\n"
end

test "an optional polymorphic belongs_to validates nothing" do
  source = "class Comment\n  belongs_to :commentable, polymorphic: true, optional: true\nend\n"
  infos = [scan("app/models/comment.rb", source), scan("app/models/post.rb", POST_SOURCE)]
  src = emit_poly("comments", infos)
  assert !src.include?("validates_foreign_key")
  assert_includes src, "    unless type == \"Post\"\n"
  assert_includes src, "is not Post (the models that declare as: :commentable)"
end

test "has_many and has_one with as: match the children by type and key" do
  src = emit_poly("posts", poly_infos)
  assert_includes src, "    rel = CommentRelation.new(\"comments\").where(commentable_type: \"Post\", commentable_id: @id)\n"
  assert_includes src, "    CommentRelation.new(\"comments\").where(commentable_type: \"Post\", commentable_id: @id).destroy_all\n"
  # The type column is one more bind: each chunk of ids leaves room for it.
  assert_includes src, "      chunk = step - 1\n"
  assert_includes src, ".where(commentable_type: \"Post\", commentable_id: ids[start, chunk]).order(id: :asc).to_a\n"
  assert_includes src, "        start += chunk\n"
  photo = emit_poly("photos", poly_infos)
  assert_includes photo, "    Comment.find_by(commentable_type: \"Photo\", commentable_id: @id)\n"
end

test "a polymorphic belongs_to that no model answers stops the generator" do
  msg = assert_raises("ModelScan::Error") { emit_poly("comments", [scan("app/models/comment.rb", COMMENT_SOURCE)]) }
  assert_equal "app/models/comment.rb:2: belongs_to :commentable: no model declares has_many or has_one ..., " \
               "as: :commentable for Comment; the reader answers the models that do", msg
end

test "the polymorphic columns must exist" do
  source = "class Post\n  belongs_to :topic, polymorphic: true\nend\n"
  msg = assert_raises("ModelScan::Error") { emit_poly("posts", [scan("app/models/post.rb", source)]) }
  assert_includes msg, "no column posts.topic_id for its key (t.references :topic, polymorphic: true creates it)"
  bad = "class Photo\n  has_many :posts, as: :topic\nend\n"
  msg = assert_raises("ModelScan::Error") { emit_poly("photos", [scan("app/models/photo.rb", bad)]) }
  assert_includes msg, "no column posts.topic_id for its foreign key; t.references :topic, polymorphic: true creates it"
  typed = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table "posts" do |t|
      t.integer "subject_type"
      t.integer "subject_id"
    end
  end
  source = "class Post\n  belongs_to :subject, polymorphic: true\nend\n"
  msg = assert_raises("ModelScan::Error") do
    Cybertrain::Gen::ModelsEmitter.emit_model(typed.table("posts"), typed, [], [], [scan("app/models/post.rb", source)])
  end
  assert_includes msg, "no string column posts.subject_type for the class name"
end

test "dependent: :nullify with as: needs a nullable type column" do
  source = "class Post\n  has_many :comments, as: :commentable, dependent: :nullify\nend\n"
  msg = assert_raises("ModelScan::Error") { emit_poly("posts", [scan("app/models/post.rb", source)]) }
  assert_includes msg, "dependent: :nullify needs comments.commentable_id to be nullable"
end

test "a polymorphic belongs_to on nullable columns answers nil for a nil type or key" do
  source = "class Post\n  belongs_to :subject, polymorphic: true, optional: true\nend\n"
  photo = "class Photo\n  has_many :posts, as: :subject\nend\n"
  src = emit_poly("posts", [scan("app/models/photo.rb", photo), scan("app/models/post.rb", source)])
  assert_includes src, "    return nil if @subject_type.nil? || @subject_id.nil?\n"
  assert_includes src, "    key = Cybertrain::Cast.int(@subject_id)\n"
  assert_includes src, "    when nil\n      @subject_type = nil\n      @subject_id = nil\n"
end

Cybertrain::Test.run!
