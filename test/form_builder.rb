require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/session"
require "cybertrain/http/query"

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

# The V-7 builder fields: statuses, tags, times, an author.
class Article < Cybertrain::Model
  def initialize(id, title, status, author_id, published_at)
    super()
    set_id(id)
    mark_persisted! if id > 0
    @title = title
    @status = status
    @author_id = author_id
    @published_at = published_at
  end

  def model_name = "Article"

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :status then @status
    when :author_id then @author_id
    when :published_at then @published_at
    else nil
    end
  end
end

class Author < Cybertrain::Model
  def initialize(id, name)
    super()
    set_id(id)
    mark_persisted!
    @name = name
  end

  def model_name = "Author"

  def read_attribute(name)
    case name
    when :id then @id
    when :name then @name
    else nil
    end
  end

  def call_view_method(name)
    case name
    when :label then "#{@id}: #{@name}"
    else nil
    end
  end

  def attribute_or_method?(name)
    case name
    when :id, :name, :label then true
    else false
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

Cybertrain::Views.url_resolver = lambda do |name, args, options|
  case name
  when "posts_path" then "/posts"
  when "post_path" then "/posts/#{route_param(args[0])}"
  when "post_blog_comments_path" then "/posts/#{route_param(args[0])}/blog_comments"
  when "sheep_index_path" then "/sheep"
  when "articles_path" then "/articles"
  when "article_path" then "/articles/#{route_param(args[0])}"
  when "admin_articles_path" then "/admin/articles"
  when "admin_article_path" then "/admin/articles/#{route_param(args[0])}"
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

def render_article(src, article)
  env = {}
  env["article"] = article
  env["authors"] = [Author.new(1, "Ann"), Author.new(2, "Bo <3>")]
  template = Cybertrain::Template::Template.parse(src, "posts/_form")
  Cybertrain::Template::Interpreter.new(helpers).render(template, env)
end

FIELD_OPEN = "<form action=\"/x\" method=\"get\">"

# One builder call's HTML: src is the call (`f.select :status, [...]`)
# inside a GET form, which adds no hidden fields, with the form taken off.
def field(article, src)
  html = render_article("<%= form_with model: article, url: '/x', method: :get do |f| %><%= #{src} %><% end %>", article)
  raise "not a field form: #{html}" unless html.start_with?(FIELD_OPEN) && html.end_with?("</form>")

  html[FIELD_OPEN.length, html.length - FIELD_OPEN.length - 7]
end

def article(status) = Article.new(3, "Hi", status, 2, nil)

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

test "form_with multipart: true adds enctype after method and keeps the hidden fields" do
  html = render_inline("<%= form_with(model: post, multipart: true) do |f| %>|<% end %>", new_post)
  assert_equal "<form action=\"/posts\" method=\"post\" enctype=\"multipart/form-data\">#{TOKEN}|</form>", html
  html = render_inline("<%= form_with model: post, multipart: true, class: 'up' do |f| %>|<% end %>", saved_post)
  assert_equal "<form action=\"/posts/7\" method=\"post\" enctype=\"multipart/form-data\" class=\"up\"><input type=\"hidden\" name=\"_method\" value=\"patch\">#{TOKEN}|</form>", html
  # false and absent leave the form urlencoded.
  html = render_inline("<%= form_with(model: post, multipart: false) do |f| %>|<% end %>", new_post)
  assert_equal "<form action=\"/posts\" method=\"post\">#{TOKEN}|</form>", html
end

test "form_with multipart: true on a GET form is an error" do
  msg = assert_raises("RuntimeError") { render_inline("<%= form_with(url: '/search', method: :get, multipart: true) do |f| %><% end %>", new_post) }
  assert_equal "posts/_form:1: form_with multipart: true needs a non-GET method", msg
end

test "file_field has no value, and accept and required pass through" do
  html = render_inline("<%= form_with model: post, multipart: true do |f| %><%= f.file_field :cover %>|<%= f.file_field :cover, accept: 'image/png,image/jpeg', required: true %>|<%= f.file_field :cover, class: 'pick' %><% end %>", saved_post)
  assert_includes html, "<input type=\"file\" name=\"post[cover]\" id=\"post_cover\">|"
  assert_includes html, "<input type=\"file\" name=\"post[cover]\" id=\"post_cover\" accept=\"image/png,image/jpeg\" required=\"required\">|"
  assert_includes html, "<input type=\"file\" name=\"post[cover]\" id=\"post_cover\" class=\"pick\"></form>"
  assert !html.include?("file\" name=\"post[cover]\" id=\"post_cover\" value"), "file_field must not emit value="
  # A column name: still no value attribute.
  html = render_inline("<%= form_with model: post, multipart: true do |f| %><%= f.file_field :title %><% end %>", saved_post)
  assert_includes html, "<input type=\"file\" name=\"post[title]\" id=\"post_title\"></form>"
  # Without a model the bare attribute is the name; a String attribute works.
  html = render_inline("<%= form_with url: '/up', multipart: true do |f| %><%= f.file_field 'doc' %><% end %>", new_post)
  assert_includes html, "<form action=\"/up\" method=\"post\" enctype=\"multipart/form-data\">"
  assert_includes html, "<input type=\"file\" name=\"doc\" id=\"doc\"></form>"
end

test "file_field takes the field_with_errors class and rejects multiple: true" do
  post = new_post
  post.errors.add(:cover, "is too large")
  html = render_inline("<%= form_with model: post, multipart: true do |f| %><%= f.file_field :cover %><% end %>", post)
  assert_includes html, "<input type=\"file\" name=\"post[cover]\" id=\"post_cover\" class=\"field_with_errors\"></form>"
  msg = assert_raises("RuntimeError") { render_inline("<%= form_with model: post, multipart: true do |f| %>\n<%= f.file_field :cover, multiple: true %><% end %>", new_post) }
  assert_equal "posts/_form:2: file_field multiple: true is not supported", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= form_with model: post, multipart: true do |f| %>\n<%= f.file_field %><% end %>", new_post) }
  assert_equal "posts/_form:2: wrong number of arguments for 'file_field'", msg
end

test "select with values, pairs, groups, blank, prompt, selected, disabled" do
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"draft\">draft</option>\n<option selected=\"selected\" value=\"published\">published</option></select>",
               field(article("published"), "f.select :status, ['draft', 'published']")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"d\">Draft</option>\n<option selected=\"selected\" value=\"p\">Published</option></select>",
               field(article("p"), "f.select :status, [['Draft', 'd'], ['Published', 'p']]")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"\" label=\" \"></option>\n<option value=\"d\">Draft</option></select>",
               field(article(nil), "f.select :status, [['Draft', 'd']], include_blank: true")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"\">None</option>\n<option value=\"d\">Draft</option></select>",
               field(article(nil), "f.select :status, [['Draft', 'd']], include_blank: 'None'")
  # The prompt shows only while the value is blank, before a blank option.
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"\">Pick</option>\n<option value=\"d\">Draft</option></select>",
               field(article(nil), "f.select :status, [['Draft', 'd']], prompt: 'Pick'")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"\">Please select</option>\n<option value=\"\" label=\" \"></option>\n<option value=\"d\">Draft</option></select>",
               field(article(""), "f.select :status, [['Draft', 'd']], prompt: true, include_blank: true")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option selected=\"selected\" value=\"d\">Draft</option></select>",
               field(article("d"), "f.select :status, [['Draft', 'd']], prompt: 'Pick'")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option disabled=\"disabled\" value=\"d\">Draft</option>\n<option selected=\"selected\" disabled=\"disabled\" value=\"p\">P</option>\n<option value=\"x\">X</option></select>",
               field(article("p"), "f.select :status, [['Draft', 'd'], ['P', 'p'], ['X', 'x']], disabled: ['d', 'p']")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option disabled=\"disabled\" value=\"d\">Draft</option></select>",
               field(article(nil), "f.select :status, [['Draft', 'd']], disabled: 'd'")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><optgroup label=\"G\"><option value=\"a\">a</option>\n<option selected=\"selected\" value=\"b\">b</option></optgroup><optgroup label=\"K\"><option value=\"k\">Kay</option></optgroup></select>",
               field(article("b"), "f.select(:status, { G: ['a', 'b'], K: [['Kay', 'k']] })")
  # [label, [choices]] pairs group too; a Hash of plain values is label => value.
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><optgroup label=\"G &amp; H\"><option value=\"a\">a</option></optgroup><option value=\"z\">z</option></select>",
               field(article(nil), "f.select :status, [['G & H', ['a']], 'z']")
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"d\">Draft</option>\n<option selected=\"selected\" value=\"p\">Published</option></select>",
               field(article("p"), "f.select(:status, { Draft: 'd', Published: 'p' })")
  assert_equal "<input type=\"hidden\" name=\"article[tags][]\" value=\"\" autocomplete=\"off\"><select name=\"article[tags][]\" id=\"article_tags\" multiple=\"multiple\"><option selected=\"selected\" value=\"ruby\">ruby</option>\n<option value=\"c\">c</option>\n<option selected=\"selected\" value=\"go\">go</option></select>",
               field(article(nil), "f.select :tags, ['ruby', 'c', 'go'], multiple: true, selected: ['ruby', 'go']")
  assert_equal "<select name=\"article[tags][]\" id=\"article_tags\" multiple=\"multiple\"><option value=\"c\">c</option></select>",
               field(article(nil), "f.select :tags, ['c'], multiple: true, include_hidden: false")
end

test "select escapes text and values once, compares values as strings, takes html options" do
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"&lt;b&gt;\">&lt;b&gt;</option>\n<option value=\"a&amp;b\"><i>x</i></option>\n<option value=\"&amp;\">&amp;</option></select>",
               field(article(nil), "f.select :status, ['<b>', [raw('<i>x</i>'), 'a&b'], raw('&amp;')]")
  # Integer choices against a String selected:, an Integer value against String choices.
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"1\">1</option>\n<option selected=\"selected\" value=\"2\">2</option></select>",
               field(article("x"), "f.select :status, [1, 2], selected: '2'")
  assert_equal "<select name=\"article[id]\" id=\"article_id\"><option selected=\"selected\" value=\"3\">three</option></select>",
               field(article(nil), "f.select :id, [['three', '3']]")
  assert_equal "<select name=\"article[status]\" id=\"article_status\" data-role=\"s&lt;\" class=\"pick\"><option value=\"d\">d</option></select>",
               field(article(nil), "f.select :status, ['d'], class: 'pick', data: { role: 's<' }")
  a = article(nil)
  a.errors.add(:status, "is invalid")
  assert_equal "<select name=\"article[status]\" id=\"article_status\" class=\"field_with_errors\"><option value=\"d\">d</option></select>",
               field(a, "f.select :status, ['d']")
  msg = assert_raises("RuntimeError") { field(article(nil), "f.select :status") }
  assert_equal "posts/_form:1: wrong number of arguments for 'select' (given 1, expected 2)", msg
end

test "collection_select reads each record's attribute or view method" do
  assert_equal "<select name=\"article[author_id]\" id=\"article_author_id\"><option value=\"1\">Ann</option>\n<option selected=\"selected\" value=\"2\">Bo &lt;3&gt;</option></select>",
               field(article(nil), "f.collection_select :author_id, authors, :id, :name")
  assert_equal "<select name=\"article[author_id]\" id=\"article_author_id\"><option value=\"\" label=\" \"></option>\n<option value=\"Ann\">1: Ann</option>\n<option value=\"Bo &lt;3&gt;\">2: Bo &lt;3&gt;</option></select>",
               field(article(nil), "f.collection_select :author_id, authors, :name, :label, include_blank: true")
  msg = assert_raises("RuntimeError") { field(article(nil), "f.collection_select :author_id, authors, :id, :nope") }
  assert_equal "posts/_form:1: collection_select: Author has no attribute or view method 'nope'", msg
  msg = assert_raises("RuntimeError") { field(article(nil), "f.collection_select :author_id, 'x', :id, :name") }
  assert_equal "posts/_form:1: collection_select expects an Array of records, got x", msg
end

test "radio_button, check_box include_hidden: false, the new input types" do
  assert_equal "<input type=\"radio\" name=\"article[status]\" id=\"article_status_draft\" value=\"draft\" checked=\"checked\">",
               field(article("draft"), "f.radio_button :status, 'draft'")
  assert_equal "<input type=\"radio\" name=\"article[status]\" id=\"article_status_big_deal_x-1\" value=\"Big Deal.x-1&lt;\" class=\"r\">",
               field(article("draft"), "f.radio_button :status, 'Big Deal.x-1<', class: 'r'")
  assert_equal "<input type=\"radio\" name=\"article[author_id]\" id=\"article_author_id_2\" value=\"2\" checked=\"checked\">",
               field(article(nil), "f.radio_button :author_id, 2")
  assert_equal "<input type=\"radio\" name=\"article[status]\" id=\"article_status_\" value=\"\">",
               field(article(nil), "f.radio_button :status, ''")
  assert_equal "<input type=\"checkbox\" name=\"article[published]\" id=\"article_published\" value=\"1\">",
               field(article(nil), "f.check_box :published, include_hidden: false")
  assert_equal "<input type=\"hidden\" name=\"article[published]\" value=\"0\"><input type=\"checkbox\" name=\"article[published]\" id=\"article_published\" value=\"1\">",
               field(article(nil), "f.check_box :published, include_hidden: true")
  types = [["datetime_local_field", "datetime-local"], ["time_field", "time"], ["range_field", "range"], ["color_field", "color"],
           ["search_field", "search"], ["telephone_field", "tel"], ["url_field", "url"], ["email_field", "email"]]
  types.each do |pair|
    assert_equal "<input type=\"#{pair[1]}\" name=\"article[title]\" id=\"article_title\" value=\"Hi\">", field(article(nil), "f.#{pair[0]} :title")
  end
  msg = assert_raises("RuntimeError") { field(article(nil), "f.telephone_field") }
  assert_equal "posts/_form:1: wrong number of arguments for 'telephone_field'", msg
  msg = assert_raises("RuntimeError") { field(article(nil), "f.radio_button :status") }
  assert_equal "posts/_form:1: wrong number of arguments for 'radio_button' (given 1, expected 2)", msg
end

test "date, datetime-local and time fields write a Time as the browser reads it" do
  a = Article.new(3, "Hi", nil, 2, Time.utc(2026, 11, 10, 9, 5, 7))
  assert_equal "<input type=\"datetime-local\" name=\"article[published_at]\" id=\"article_published_at\" value=\"2026-11-10T09:05:07\">", field(a, "f.datetime_local_field :published_at")
  assert_equal "<input type=\"date\" name=\"article[published_at]\" id=\"article_published_at\" value=\"2026-11-10\">", field(a, "f.date_field :published_at")
  assert_equal "<input type=\"time\" name=\"article[published_at]\" id=\"article_published_at\" value=\"09:05:07.000\">", field(a, "f.time_field :published_at")
  assert_equal "<input type=\"datetime-local\" name=\"article[published_at]\" id=\"article_published_at\">", field(article(nil), "f.datetime_local_field :published_at")
end

test "form_with scope: and a namespaced model" do
  html = render_article("<%= form_with url: '/search', scope: :q, method: :get do |f| %><%= f.text_field :term %><% end %>", article(nil))
  assert_equal "<form action=\"/search\" method=\"get\"><input type=\"text\" name=\"q[term]\" id=\"q_term\"></form>", html
  html = render_article("<%= form_with model: [:admin, article] do |f| %><%= f.text_field :title %><% end %>", article(nil))
  assert_equal "<form action=\"/admin/articles/3\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\">#{TOKEN}<input type=\"text\" name=\"article[title]\" id=\"article_title\" value=\"Hi\"></form>", html
  html = render_article("<%= form_with model: [:admin, article] do |f| %><%= f.submit %><% end %>", Article.new(0, "", nil, 0, nil))
  assert_equal "<form action=\"/admin/articles\" method=\"post\">#{TOKEN}<input type=\"submit\" name=\"commit\" value=\"Create Article\"></form>", html
  # With model:, scope: replaces the model's prefix; the submit text still names the model.
  html = render_article("<%= form_with model: article, scope: 'post', local: true do |f| %><%= f.text_field :title %><%= f.submit %><% end %>", article(nil))
  assert_equal "<form action=\"/articles/3\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\">#{TOKEN}<input type=\"text\" name=\"post[title]\" id=\"post_title\" value=\"Hi\"><input type=\"submit\" name=\"commit\" value=\"Update Article\"></form>", html
end

test "form_with data: writes data- attributes" do
  html = render_article("<%= form_with url: '/s', class: 'f', data: { turbo_frame: 'top', x: '<' } do |f| %>|<% end %>", article(nil))
  assert_equal "<form action=\"/s\" method=\"post\" class=\"f\" data-turbo-frame=\"top\" data-x=\"&lt;\">#{TOKEN}|</form>", html
end

test "a data: key is checked, a Hash for another attribute refused, a SafeString attribute escaped once" do
  env = {}
  env["article"] = article(nil)
  env["bad"] = { "x\" onclick=\"a" => 1 }
  template = Cybertrain::Template::Template.parse("<%= form_with model: article, url: '/x', method: :get do |f| %><%= f.text_field :title, data: bad %><% end %>", "posts/_form")
  msg = assert_raises("Cybertrain::Template::RuntimeError") { Cybertrain::Template::Interpreter.new(helpers).render(template, env) }
  assert_equal "posts/_form:1: invalid attribute name 'data-x\" onclick=\"a'", msg
  msg = assert_raises("Cybertrain::Template::RuntimeError") { field(article(nil), "f.text_field :title, style: { color: 'red' }") }
  assert_equal "posts/_form:1: attribute 'style' cannot be a Hash", msg
  assert_equal "<input type=\"text\" name=\"article[title]\" id=\"article_title\" value=\"Hi\" placeholder=\"&amp;\" class=\"a&amp;b\">",
               field(article(nil), "f.text_field :title, placeholder: raw('&amp;'), class: raw('a&amp;b')")
  assert_equal "<input type=\"text\" name=\"article[title]\" id=\"article_title\" value=\"Hi\" class=\"a&amp;b\">",
               field(article(nil), "f.text_field :title, class: 'a&b'")
end

test "nested and array field names round-trip through params.expect" do
  html = render_article("<%= form_with url: '/a', scope: 'article[meta]', method: :get do |f| %><%= f.text_field :source %><% end %>", article(nil))
  assert_equal "<form action=\"/a\" method=\"get\"><input type=\"text\" name=\"article[meta][source]\" id=\"article_meta_source\"></form>", html
  html = field(article(nil), "f.select :tags, ['a', 'b'], multiple: true")
  assert_includes html, "name=\"article[tags][]\""
  # What a browser sends for those names, the hidden "" first.
  p = Cybertrain::Query.parse("article[title]=Hi&article[tags][]=&article[tags][]=b&article[meta][source]=rss")
  h = p.expect(article: [:title, tags: [], meta: [:source]])
  assert_equal "Hi", h["title"]
  assert_equal ["", "b"], h["tags"]
  assert_equal({ "source" => "rss" }, h["meta"])
end

Cybertrain::Test.run!
