# SPIKE (throwaway): class identity in a Model hierarchy - case/when on class, class.name, is_a?, Hash keyed by class name, self.class.<class method>
class Model
  def self.table_name; "models"; end
  def table; self.class.table_name; end          # dynamic class-method dispatch via self.class
  def self.describe; "#{name}/#{table_name}"; end
  def tn_via_name; Model.table_for(self.class.name); end
  def self.table_for(n); TABLES[n] || "?"; end
  TABLES = { "Post" => "posts", "Comment" => "comments" }
end
class Post < Model
  attr_accessor :title
  def self.table_name; "posts"; end
end
class Comment < Model
  attr_accessor :body
  def self.table_name; "comments"; end
end

def kind(rec)
  case rec
  when Post then "post:#{rec.title}"
  when Comment then "comment:#{rec.body}"
  else "model"
  end
end

recs = []
p1 = Post.new; p1.title = "hi"
c1 = Comment.new; c1.body = "yo"
recs << p1
recs << c1
recs << Model.new

counts = {}
recs.each do |r|
  puts kind(r)
  puts "  class.name=#{r.class.name} is_a?(Model)=#{r.is_a?(Model)} is_a?(Post)=#{r.is_a?(Post)} Post===r #{Post === r}"
  puts "  r.class == Post: #{r.class == Post}  instance_of?(Model): #{r.instance_of?(Model)}"
  puts "  table via self.class.table_name: #{r.table}"
  puts "  table via TABLES[class.name]: #{r.tn_via_name}"
  counts[r.class.name] = (counts[r.class.name] || 0) + 1
end
p counts
puts Post.describe
k = recs[0].class
puts k.name
puts k.table_name
puts k.superclass.name
