require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/session"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class Post < Cybertrain::Model
  def initialize(id, title, body, published)
    super()
    set_id(id)
    mark_persisted! if id > 0
    @title = title
    @body = body
    @published = published
  end

  def model_name = "Post"

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :body then @body
    when :published then @published
    else nil
    end
  end
end

class BlogComment < Cybertrain::Model
  def model_name = "BlogComment"

  def read_attribute(name)
    case name
    when :id then @id
    else nil
    end
  end
end

# A word that is its own plural: Rails names its collection route
# sheep_index (ActiveModel::Name#route_key), as the routes DSL does.
class Sheep < Cybertrain::Model
  def model_name = "Sheep"

  def read_attribute(name)
    case name
    when :id then @id
    else nil
    end
  end
end

def route_param(v)
  case v
  when Cybertrain::Model then v.to_param
  else v.to_s
  end
end

Cybertrain::Views.url_resolver = lambda do |name, args|
  case name
  when "posts_path" then "/posts"
  when "post_path" then "/posts/#{route_param(args[0])}"
  when "post_blog_comments_path" then "/posts/#{route_param(args[0])}/blog_comments"
  when "sheep_index_path" then "/sheep"
  when "post_sheep_index_path" then "/posts/#{route_param(args[0])}/sheep"
  else raise "no route #{name}"
  end
end

def helpers
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/posts/new", { "host" => "example.test" }, ""))
  ctx.session = Cybertrain::Session.new({ "_csrf_token" => "T0K" })
  Cybertrain::Template::Helpers.new(Cybertrain::Controller.new(ctx))
end

def render_inline(src, post)
  env = {}
  env["post"] = post
  env["comment"] = BlogComment.new
  env["sheep"] = Sheep.new
  template = Cybertrain::Template::Template.parse(src, "posts/_form")
  Cybertrain::Template::Interpreter.new(helpers).render(template, env)
end

def new_post = Post.new(0, "", "", false)
def saved_post = Post.new(7, "A \"quoted\" <title>", "Line one\n<b>two</b>", true)

TOKEN = "<input type=\"hidden\" name=\"authenticity_token\" value=\"T0K\">"

test "form_with a new record posts to the collection path" do
  html = render_inline("<%= form_with(model: post) do |f| %>|<% end %>", new_post)
  assert_equal "<form action=\"/posts\" method=\"post\">#{TOKEN}|</form>", html
end

test "form_with a persisted record patches the member path" do
  html = render_inline("<%= form_with model: post, class: 'edit' do |form| %>|<% end %>", saved_post)
  assert_equal "<form action=\"/posts/7\" method=\"post\" class=\"edit\"><input type=\"hidden\" name=\"_method\" value=\"patch\">#{TOKEN}|</form>", html
end

test "form_with url: and method: without a model" do
  html = render_inline("<%= form_with url: '/search', method: :get do |f| %><%= f.text_field :q %><% end %>", new_post)
  assert_equal "<form action=\"/search\" method=\"get\"><input type=\"text\" name=\"q\" id=\"q\"></form>", html
  html = render_inline("<%= form_with model: post, url: '/custom', method: :delete do |f| %><% end %>", saved_post)
  assert_equal "<form action=\"/custom\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"delete\">#{TOKEN}</form>", html
end

test "form_with a nested [parent, child] model" do
  html = render_inline("<%= form_with model: [post, comment] do |f| %><%= f.text_field :body %><% end %>", saved_post)
  assert_equal "<form action=\"/posts/7/blog_comments\" method=\"post\">#{TOKEN}<input type=\"text\" name=\"blog_comment[body]\" id=\"blog_comment_body\"></form>", html
end

test "text_field escapes the value" do
  html = render_inline("<%= form_with model: post do |f| %><%= f.text_field :title, placeholder: 'T<' %><% end %>", saved_post)
  assert_includes html, "<input type=\"text\" name=\"post[title]\" id=\"post_title\" value=\"A &quot;quoted&quot; &lt;title&gt;\" placeholder=\"T&lt;\">"
  html = render_inline("<%= form_with model: post do |f| %><%= f.text_field :title, class: 'wide' %><% end %>", new_post)
  assert_includes html, "<input type=\"text\" name=\"post[title]\" id=\"post_title\" value=\"\" class=\"wide\">"
end

test "label, text_area, hidden_field, number_field and check_box" do
  src = "<%= form_with model: post do |f| %><%= f.label :title %>\n<%= f.label :body, 'Text' %>\n<%= f.text_area :body, rows: 4 %>\n<%= f.hidden_field :id %>\n<%= f.number_field :id %>\n<%= f.check_box :published %><% end %>"
  html = render_inline(src, saved_post)
  expected = [
    "<label for=\"post_title\">Title</label>",
    "<label for=\"post_body\">Text</label>",
    "<textarea name=\"post[body]\" id=\"post_body\" rows=\"4\">\nLine one\n&lt;b&gt;two&lt;/b&gt;</textarea>",
    "<input type=\"hidden\" name=\"post[id]\" id=\"post_id\" value=\"7\">",
    "<input type=\"number\" name=\"post[id]\" id=\"post_id\" value=\"7\">",
    "<input type=\"hidden\" name=\"post[published]\" value=\"0\"><input type=\"checkbox\" name=\"post[published]\" id=\"post_published\" value=\"1\" checked=\"checked\"></form>"
  ].join("\n")
  assert_equal "<form action=\"/posts/7\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\">#{TOKEN}#{expected}", html
  # Explicit label text is escaped unless it is already a SafeString.
  html = render_inline("<%= form_with model: post do |f| %><%= f.label :title, '<i>T</i>' %>|<%= f.label :title, raw('<i>T</i>') %><% end %>", saved_post)
  assert_includes html, "<label for=\"post_title\">&lt;i&gt;T&lt;/i&gt;</label>|<label for=\"post_title\"><i>T</i></label></form>"
  html = render_inline("<%= form_with model: post do |f| %><%= f.check_box :published %><% end %>", new_post)
  assert_includes html, "<input type=\"checkbox\" name=\"post[published]\" id=\"post_published\" value=\"1\"></form>"
end

test "fields with errors get the field_with_errors class" do
  post = new_post
  post.errors.add(:title, "can't be blank")
  html = render_inline("<%= form_with model: post do |f| %><%= f.label :title %><%= f.text_field :title, class: 'wide' %><%= f.text_area :body %><% end %>", post)
  assert_includes html, "<label for=\"post_title\" class=\"field_with_errors\">Title</label>"
  assert_includes html, "<input type=\"text\" name=\"post[title]\" id=\"post_title\" value=\"\" class=\"wide field_with_errors\">"
  assert_includes html, "<textarea name=\"post[body]\" id=\"post_body\">\n</textarea>"
end

test "submit defaults to Create or Update by persisted?" do
  assert_includes render_inline("<%= form_with model: post do |f| %><%= f.submit %><% end %>", new_post), "<input type=\"submit\" name=\"commit\" value=\"Create Post\">"
  assert_includes render_inline("<%= form_with model: post do |f| %><%= f.submit %><% end %>", saved_post), "<input type=\"submit\" name=\"commit\" value=\"Update Post\">"
  assert_includes render_inline("<%= form_with model: post do |f| %><%= f.submit 'Go <now>', class: 'btn' %><% end %>", saved_post), "<input type=\"submit\" name=\"commit\" value=\"Go &lt;now&gt;\" class=\"btn\">"
  assert_includes render_inline("<%= form_with url: '/s' do |f| %><%= f.submit %><% end %>", new_post), "<input type=\"submit\" name=\"commit\" value=\"Save changes\">"
  assert_includes render_inline("<%= form_with model: [post, comment] do |f| %><%= f.submit %><% end %>", saved_post), "value=\"Create Blog comment\""
end

test "an unknown builder method is a RuntimeError" do
  msg = assert_raises("RuntimeError") { render_inline("<%= form_with model: post do |f| %>\n<%= f.color_wheel :title %><% end %>", new_post) }
  assert_equal "posts/_form:2: undefined method 'color_wheel' for FormBuilder", msg
end

test "form_with a new record whose name is its own plural posts to <plural>_index" do
  html = render_inline("<%= form_with(model: sheep) do |f| %>|<% end %>", new_post)
  assert_equal "<form action=\"/sheep\" method=\"post\">#{TOKEN}|</form>", html
  html = render_inline("<%= form_with(model: [post, sheep]) do |f| %>|<% end %>", saved_post)
  assert_equal "<form action=\"/posts/7/sheep\" method=\"post\">#{TOKEN}|</form>", html
end

Cybertrain::Test.run!
