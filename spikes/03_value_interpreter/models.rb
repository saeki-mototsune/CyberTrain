# SPIKE (throwaway): Model base class with read_attribute(sym) returning polymorphic values, fixture data, hand-written renderer baseline.

class Model
  def read_attribute(name) = nil
  def read_association(name) = nil
end

class Comment < Model
  attr_reader :id, :author, :body
  def initialize(id, author, body)
    @id = id
    @author = author
    @body = body
  end
  def read_attribute(name)
    case name
    when :id then @id
    when :author then @author
    when :body then @body
    else nil
    end
  end
end

class Post < Model
  attr_reader :id, :title, :body, :author, :published, :created_at, :comments
  def initialize(id, title, body, author, published, created_at, comments)
    @id = id
    @title = title
    @body = body
    @author = author
    @published = published
    @created_at = created_at
    @comments = comments
  end
  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :body then @body
    when :author then @author
    when :published then @published
    when :created_at then @created_at
    else nil
    end
  end
  def read_association(name)
    case name
    when :comments then @comments
    else nil
    end
  end
end

class User < Model
  attr_reader :name
  def initialize(name) = @name = name
  def read_attribute(name)
    case name
    when :name then @name
    else nil
    end
  end
end

def build_posts
  posts = []
  i = 0
  while i < 50
    comments = []
    (i % 4).times do |k|
      comments << Comment.new(i * 10 + k, "user#{k}", "Nice <post> ##{i} & thanks #{k}")
    end
    author = i % 3 == 0 ? nil : "author#{i % 5}"
    title = i % 7 == 6 ? "" : "Post #{i}: \"quotes\" & <tags>"
    posts << Post.new(i + 1, title, "Body of post #{i}. " * 3, author, i % 2 == 0, Time.at(1_700_000_000 + i * 86_400 * 30), comments)
    i += 1
  end
  posts
end

def h(s)
  s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\"", "&quot;").gsub("'", "&#39;")
end

def html_escape(s)
  # WORKAROUND: no `x = nil` locals -- a local initialised to nil and later assigned a String is
  # inferred `untyped` (boxed poly), not nullable String, and widens the whole method.
  n = s.bytesize
  i = 0
  start = 0
  dirty = false
  out = String.new
  while i < n
    b = s.getbyte(i)
    if b == 38 || b == 60 || b == 62 || b == 34 || b == 39
      dirty = true
      out << s.byteslice(start, i - start) if i > start
      if b == 38 then out << "&amp;"
      elsif b == 60 then out << "&lt;"
      elsif b == 62 then out << "&gt;"
      elsif b == 34 then out << "&quot;"
      else out << "&#39;"
      end
      start = i + 1
    end
    i += 1
  end
  return s unless dirty
  out << s.byteslice(start, n - start) if n > start
  out
end

def pluralize(n, word) = n == 1 ? "1 #{word}" : "#{n} #{word}s"
def link_to(text, url) = "<a href=\"#{html_escape(url)}\">#{html_escape(text)}</a>"

# Hand-written equivalent of posts.html.erb (what a compiled-ERB backend would emit).
def render_hand(title, nav, posts, owner, footer_note)
  o = String.new
  o << "<!DOCTYPE html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <title>" << html_escape(title) << "</title>\n  <link rel=\"stylesheet\" href=\"/assets/app.css\">\n</head>\n<body>\n<header class=\"site-header\">\n  <nav>\n    <ul>\n"
  nav.each do |item|
    o << "      <li>" << link_to(item["label"], item["url"]) << "</li>\n"
  end
  o << "    </ul>\n  </nav>\n  <h1>" << html_escape(title.upcase) << "</h1>\n  <p class=\"count\">" << html_escape(pluralize(posts.size, "post")) << "</p>\n</header>\n<main>\n"
  posts.each do |post|
    o << "  <article id=\"post-" << post.id.to_s << "\" class=\"post\">\n    <header>\n      <h2>" << html_escape(post.title) << "</h2>\n"
    a = post.author
    if a != nil
      o << "      <p class=\"byline\">by " << html_escape(a.to_s) << "</p>\n"
    else
      o << "      <p class=\"byline\">by anonymous</p>\n"
    end
    o << "      <p class=\"date\">" << post.created_at.year.to_s << "</p>\n    </header>\n    <div class=\"body\">\n      " << html_escape(post.body) << "\n    </div>\n    <footer>\n"
    if post.comments.empty?
      o << "      <p class=\"comments none\">No comments yet</p>\n"
    elsif post.comments.size == 1
      o << "      <p class=\"comments one\">1 comment</p>\n"
    else
      o << "      <p class=\"comments many\">" << post.comments.size.to_s << " comments</p>\n"
    end
    o << "      <ul class=\"comment-list\">\n"
    post.comments.each do |c|
      o << "        <li><strong>" << html_escape(c.author) << "</strong>: " << html_escape(c.body) << "</li>\n"
    end
    o << "      </ul>\n"
    if post.published && !(post.title == "")
      o << "      <span class=\"badge\">published</span>\n"
    else
      o << "      <span class=\"badge draft\">draft</span>\n"
    end
    o << "      <a href=\"/posts/" << post.id.to_s << "\">Read more</a>\n    </footer>\n  </article>\n"
  end
  o << "</main>\n<aside class=\"sidebar\">\n  <section class=\"about\">\n    <h3>About</h3>\n    <p>This blog is a benchmark fixture.</p>\n    <p>It has static markup to look like a real page.</p>\n  </section>\n  <section class=\"archive\">\n    <h3>Archive</h3>\n    <ul>\n"
  m = 1
  while m <= 12
    o << "      <li><a href=\"/archive/2026/" << m.to_s << "\">2026-" << m.to_s << "</a></li>\n"
    m += 1
  end
  o << "    </ul>\n  </section>\n  <section class=\"stats\">\n    <p>Total: " << posts.size.to_s << "</p>\n    <p>Owner: " << html_escape(owner.name) << "</p>\n  </section>\n</aside>\n<footer class=\"site-footer\">\n  <p>Rendered by cybertrain</p>\n  <p>" << html_escape(footer_note) << "</p>\n</footer>\n</body>\n</html>\n"
  o
end

def now_s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
