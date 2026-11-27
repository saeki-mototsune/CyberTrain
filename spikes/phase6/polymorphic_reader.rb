# The reader of a polymorphic belongs_to (docs/design.md D94), in the shape
# generator/association_emitter.rb writes it: `commentable` answers a Post,
# a Photo or nil from a `case` over the type column, cached in one ivar,
# and `commentable=` takes either (or nil) and narrows it with `case`.
# A record, not a test, and not evidence for a Spinel item: it shows the
# union compiles and dispatches like CRuby -- calls both classes define
# (`title`, the base's `id`, `model_name`, and `rank`, which answers an
# Integer on one and a String on the other), a call only one defines on a
# value of that class, `case x when Post`, the union in an Array and a Hash,
# a NoMethodError for a call the value's class lacks -- and that the writer
# coexists with an `attr_accessor` of its name on another class through a
# boxed receiver (NOTES rule 43's shape).
#
# Run (Spinel 2026.11.23.7035, 86421ea5, Linux x86_64, GCC 13.3.0, CRuby
# 3.3.6, 2026-11-27; from the repository root):
#   ruby spikes/phase6/polymorphic_reader.rb
#   spinel spikes/phase6/polymorphic_reader.rb -O 0 -o "${TMPDIR:-/tmp}/poly" && "${TMPDIR:-/tmp}/poly"
# Output: the same under both (below). `spinel --emit-rbs` types the
# reader `() -> untyped` and the writer `(untyped) -> untyped`: the union
# is a boxed value, each call on it a dynamic dispatch.
#   true
#   false
#   hello
#   1
#   Post
#   post hello
#   Photo
#   1
#   photo a.png
#   Photo
#   photo a.png
#   Photo
#   a.png
#   hello
#   true
#   true
#   Photo
#   none
#   false
#   unknown commentable_type Video
#   seven
#   7
#   8
#   a.png
#   nomethod
#   boxed
#   Photo
class Model
  attr_reader :id
  def initialize
    @id = 0
  end
  def set_id(v)
    @id = v
    nil
  end
  def model_name = ""
  def read_attribute(name) = nil
end

class Post < Model
  attr_accessor :title
  def initialize(title = "")
    super()
    @title = title
  end
  def model_name = "Post"
  def rank = 7
  def read_attribute(name) = name == :title ? @title : nil
  STORE = Array.new(0) { Post.new }
  def self.find_by_id(i)
    STORE.each { |p| return p if p.id == i }
    nil
  end
end

class Photo < Model
  attr_accessor :title, :url
  def initialize(url = "")
    super()
    @url = url
    @title = "photo " + url
  end
  def model_name = "Photo"
  def rank = "seven"
  def read_attribute(name) = name == :url ? @url : nil
  STORE = Array.new(0) { Photo.new }
  def self.find_by_id(i)
    STORE.each { |p| return p if p.id == i }
    nil
  end
end

class Comment < Model
  attr_accessor :commentable_type, :commentable_id
  def initialize
    super()
    @commentable_type = nil
    @commentable_id = nil
    @commentable_loaded = false
    @commentable_loaded_type = ""
    @commentable_loaded_key = 0
    @commentable_record = nil
  end
  def model_name = "Comment"

  def commentable
    return nil if @commentable_type.nil? || @commentable_id.nil?
    key = @commentable_id.to_i
    type = @commentable_type.to_s
    return @commentable_record if @commentable_loaded && @commentable_loaded_key == key && @commentable_loaded_type == type

    @commentable_record =
      case type
      when "Post" then Post.find_by_id(key)
      when "Photo" then Photo.find_by_id(key)
      else raise ArgumentError, "unknown commentable_type #{type}"
      end
    @commentable_loaded = true
    @commentable_loaded_key = key
    @commentable_loaded_type = type
    @commentable_record
  end

  def commentable=(record)
    case record
    when nil
      @commentable_type = nil
      @commentable_id = nil
    when Post, Photo
      @commentable_type = record.model_name
      @commentable_id = record.id
    else raise ArgumentError, "commentable= takes a Post or a Photo"
    end
    @commentable_record = record
    @commentable_loaded = true
    @commentable_loaded_key = @commentable_id.to_i
    @commentable_loaded_type = @commentable_type.to_s
    record
  end
end

STDOUT.sync = true
p1 = Post.new("hello"); p1.set_id(1); Post::STORE << p1
ph = Photo.new("a.png"); ph.set_id(1); Photo::STORE << ph

c = Comment.new
puts c.commentable.nil?
c.commentable_type = "Post"; c.commentable_id = 1
x = c.commentable
puts x.nil?
puts x.title
puts x.id
puts x.model_name
case x
when Post then puts "post " + x.title
when Photo then puts "photo " + x.url
end
c.commentable = ph
puts c.commentable_type
puts c.commentable_id
y = c.commentable
puts y.title
puts y.model_name
case y
when Post then puts "post " + y.title
when Photo then puts "photo " + y.url
end
c2 = Comment.new
c2.commentable_type = "Photo"; c2.commentable_id = 1
puts c2.commentable.model_name
puts c2.commentable.read_attribute(:url).to_s
c2.commentable = p1
puts c2.commentable.title
c2.commentable = nil
puts c2.commentable.nil?
puts c2.commentable_type.nil?
list = [c, c2]
list.each { |cc| r = cc.commentable; puts(r.nil? ? "none" : r.model_name) }
h = { "k" => [nil, 0, "", c.commentable][0] }
h["k"] = c.commentable
puts h["k"].nil?
c3 = Comment.new
c3.commentable_type = "Video"; c3.commentable_id = 1
begin
  c3.commentable
rescue ArgumentError => e
  puts e.message
end

z = c.commentable
puts z.rank.to_s
z2 = c2.commentable
c2.commentable = p1
puts c2.commentable.rank.to_s
puts c2.commentable.rank + 1
w = c.commentable
puts w.url
begin
  c2.commentable.url
rescue NoMethodError => e
  puts "nomethod"
end

# NOTES rule 43's shape: an attr_accessor of the writer's name on another
# class, both written through a boxed receiver.
class Box
  attr_accessor :commentable
  def initialize
    @commentable = "box"
  end
end
holders = [Box.new, Comment.new]
holders.each do |hd|
  case hd
  when Box then hd.commentable = "boxed"
  when Comment then hd.commentable = p1
  end
end
puts holders[0].commentable.to_s
mixed = [Box.new, Comment.new][1]
mixed.commentable = ph
puts mixed.commentable.model_name
