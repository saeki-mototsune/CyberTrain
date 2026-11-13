require "cybertrain/test"
require "cybertrain/controller"

# i18n in views (spec 8, plan Task 5): the template helpers t and l, lazy
# lookup by the rendering template's name (plan decision D8, Rails'
# virtual path) in a page, a partial, a layout, a component and a mail
# partial, the missing-translation span, `_html` keys, and Controller#t.
#
# The templates are an embedded table (as gen/views.rb embeds them); the
# application dictionary is the hand-written lookup below, installed as
# gen/locales.rb installs Gen::Locales.
#
# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

module ViewLocales
  def self.lookup(key)
    case key
    when "en.posts.index.title" then "All posts"
    when "ja.posts.index.title" then "投稿一覧"
    when "en.posts.form.title" then "Post form"
    when "ja.posts.form.title" then "投稿フォーム"
    when "en.layouts.application.title" then "Blog"
    when "ja.layouts.application.title" then "ブログ"
    when "en.card_component.title" then "Card"
    when "en.admin.badge_component.title" then "Admin badge"
    when "en.mail.password_reset.title" then "Reset your password"
    when "ja.mail.password_reset.title" then "パスワードの再設定"
    when "en.posts.new.title" then "New post"
    when "en.posts.create.title" then "Wrong: the create action's key"
    when "en.posts.create.failed" then "Could not save %{title}"
    when "en.posts.greet.greeting_html" then "<p>Hi %{name}</p>"
    when "en.posts.greet.greeting" then "<p>Hi %{name}</p>"
    when "en.posts.greet.items_html.one" then "<b>%{count}</b> item for %{name}"
    when "en.posts.greet.items_html.other" then "<b>%{count}</b> items for %{name}"
    when "en.posts.greet.note.html" then "<em>%{who}</em>"
    when "en.admin.posts.notice.done" then "Done: %{name}"
    when "en.admin.posts.notice.done_html" then "<b>Done</b>: %{name}"
    when "en.shared.hello" then "Hello"
    end
  end

  def self.lookup_list(key)
    case key
    when "en.unused" then ["x"]
    else []
    end
  end

  def self.resolver = ->(key) { ViewLocales.lookup(key) }
  def self.list_resolver = ->(key) { ViewLocales.lookup_list(key) }
end

I18n.install_dictionary(ViewLocales.resolver, ViewLocales.list_resolver)

class CardComponent < Cybertrain::Component
  def component_name
    "card"
  end

  def component_template
    "__components/card_component.html.erb"
  end
end

class AdminBadgeComponent < Cybertrain::Component
  def component_name
    "admin/badge"
  end

  def component_template
    "__components/admin/badge_component.html.erb"
  end
end

module Gen
  module Components
    def self.build(name, kwargs)
      case name
      when "card"
        Cybertrain::Component.check_keywords!(name, kwargs, Array.new(0) { "" }, 0)
        ::CardComponent.new
      when "admin/badge"
        Cybertrain::Component.check_keywords!(name, kwargs, Array.new(0) { "" }, 0)
        ::AdminBadgeComponent.new
      else
        raise Cybertrain::Component::Unknown, "no component '#{name}'"
      end
    end
  end
end

Cybertrain::Views.component_builder = ->(name, kwargs) { Gen::Components.build(name, kwargs) }

SOURCES = {
  "layouts/application.html.erb" => "<title><%= t(\".title\") %></title>\n<%= yield %>",
  "posts/index.html.erb" => "<h1><%= t(\".title\") %></h1>\n<%= render \"form\" %>\n<%= render component: \"card\" %>\n<%= render component: \"admin/badge\" %>\n<p><%= t(\".subtitle\") %></p>\n<p><%= t(\"shared.hello\") %></p>\n",
  "posts/_form.html.erb" => "<form><%= t(\".title\") %></form>",
  "posts/new.html.erb" => "<h1><%= t(\".title\") %></h1>\n",
  "posts/greet.html.erb" => "<%= t(\".greeting_html\", name: \"<b>x</b>\") %>\n" \
                            "<%= t(\".greeting\", name: \"<b>x</b>\") %>\n" \
                            "<%= t(\".greeting_html\", name: raw(\"<i>y</i>\")) %>\n" \
                            "<%= t(\".items_html\", count: 1, name: \"A&B\") %>\n" \
                            "<%= t(\".items_html\", count: 3, name: \"A&B\") %>\n" \
                            "<%= t(\".note.html\", who: \"<me>\") %>\n" \
                            "<%= t(\".absent_html\", default: \"<u>%{v}</u>\", v: \"<v>\") %>\n",
  "posts/dates.html.erb" => "<%= l(day) %>|<%= l(day, format: :long) %>|<%= l(at, format: :short) %>|<%= localize(at, format: \"%a %p <%-d>\") %>|<%= translate(\"date.formats.long\") %>",
  "__components/card_component.html.erb" => "<div><%= t(\".title\") %></div>",
  "__components/admin/badge_component.html.erb" => "<span><%= t(\".title\") %></span>",
  "mail/_password_reset.html.erb" => "<p><%= t(\".title\") %></p>"
}
Cybertrain::Views.configure_embedded(SOURCES)

class PostsController < Cybertrain::Controller
  def controller_path = "posts"

  def index
  end

  # Rails renders new's template from create: its lazy keys are
  # posts.new.*, while the action's own t(".x") reads posts.create.x.
  def create
    @failed = t(".failed", title: "<T>")
    render :new
  end

  def greet
  end

  def japanese
    I18n.locale = :ja
    render :index
  end

  def dates
    render :dates, locals: { day: Date.new(2026, 11, 10), at: Time.utc(2026, 11, 10, 9, 5) }
  end

  attr_reader :failed

  def view_assigns
    { "failed" => @failed }
  end
end

class AdminPostsController < Cybertrain::Controller
  def controller_path = "admin/posts"

  def notice
    plain = t(".done", name: "<b>")
    html = t(".done_html", name: "<b>")
    absolute = t("shared.hello")
    sym = translate(:"shared.hello")
    render plain: "#{plain}|#{html}|#{absolute}|#{sym}"
  end
end

def build_ctx
  Cybertrain::Context.new(Cybertrain::Request.new("GET", "/posts", { "host" => "example.test" }, ""))
end

# Plays the part of gen/routes.rb: literal action names, literal bodies.
def dispatch(action)
  c = PostsController.new(build_ctx)
  case action
  when :index then c.process(:index) { |x| x.index }
  when :create then c.process(:create) { |x| x.create }
  when :greet then c.process(:greet) { |x| x.greet }
  when :japanese then c.process(:japanese) { |x| x.japanese }
  when :dates then c.process(:dates) { |x| x.dates }
  else raise ArgumentError, "no route for #{action}"
  end
  c
end

def reset_i18n
  I18n.default_locale = :en
  I18n.available_locales = [:en, :ja]
  I18n.raise_on_missing = false
  I18n.mark_missing = true
  I18n.locale = nil
  nil
end

MISSING_SPAN = "<span class=\"translation_missing\" title=\"translation missing: en.posts.index.subtitle\">Subtitle</span>"

test "lazy lookup in a template, a partial, a layout, a component and a mail partial" do
  reset_i18n
  body = dispatch(:index).response.body
  expected = "<title>Blog</title>\n<h1>All posts</h1>\n<form>Post form</form>\n<div>Card</div>\n" \
             "<span>Admin badge</span>\n<p>#{MISSING_SPAN}</p>\n<p>Hello</p>\n"
  assert_equal expected, body
  assert_equal "<p>Reset your password</p>", Cybertrain::Views.render_mail("mail/password_reset")
  # The same templates in ja: each key in the ja dictionary; the card has
  # no ja text and falls back to en.
  body = dispatch(:japanese).response.body
  assert_includes body, "<title>ブログ</title>\n<h1>投稿一覧</h1>\n<form>投稿フォーム</form>\n<div>Card</div>\n"
  assert_includes body, "title=\"translation missing: ja.posts.index.subtitle\">Subtitle</span>"
  assert_equal "<p>パスワードの再設定</p>", I18n.with_locale(:ja) { Cybertrain::Views.render_mail("mail/password_reset") }
end

test "the lazy scope of a template name" do
  assert_equal "posts.index", Cybertrain::Template::Helpers.lazy_scope("posts/index.html.erb")
  assert_equal "posts.form", Cybertrain::Template::Helpers.lazy_scope("posts/_form.html.erb")
  assert_equal "layouts.application", Cybertrain::Template::Helpers.lazy_scope("layouts/application.html.erb")
  assert_equal "card_component", Cybertrain::Template::Helpers.lazy_scope("__components/card_component.html.erb")
  assert_equal "admin.badge_component", Cybertrain::Template::Helpers.lazy_scope("__components/admin/badge_component.html.erb")
  assert_equal "mail.password_reset", Cybertrain::Template::Helpers.lazy_scope("mail/_password_reset.html.erb")
  assert_equal "admin.posts.create", Cybertrain::Template::Helpers.lazy_scope("admin/posts/create.turbo_stream.erb")
  assert_equal "index", Cybertrain::Template::Helpers.lazy_scope("index.html.erb")
end

test "render :new from create looks up posts.new" do
  reset_i18n
  c = dispatch(:create)
  assert_equal "<title>Blog</title>\n<h1>New post</h1>\n", c.response.body
  # The action's own lazy key is the action's: posts.create.failed.
  assert_equal "Could not save <T>", c.failed
end

test "the missing-key span in development, humanised in production" do
  reset_i18n
  assert_includes dispatch(:index).response.body, "<p>#{MISSING_SPAN}</p>"
  # Production (mark_missing off): the humanised last segment, escaped as
  # any text.
  I18n.mark_missing = false
  assert_includes dispatch(:index).response.body, "<p>Subtitle</p>"
  # raise_on_missing: the render fails, naming the template and the key.
  I18n.mark_missing = true
  I18n.raise_on_missing = true
  msg = assert_raises { dispatch(:index) }
  assert_includes msg, "translation missing: en.posts.index.subtitle"
  reset_i18n
end

test "an _html key escapes its arguments" do
  reset_i18n
  lines = dispatch(:greet).response.body.split("\n")
  # Layout's <title> first, then one line per call.
  assert_equal "<title>Blog</title>", lines[0]
  # The value is escaped, the dictionary's own HTML is not.
  assert_equal "<p>Hi &lt;b&gt;x&lt;/b&gt;</p>", lines[1]
  # Not an _html key: the whole text is escaped by the template.
  assert_equal "&lt;p&gt;Hi &lt;b&gt;x&lt;/b&gt;&lt;/p&gt;", lines[2]
  # A SafeString value is interpolated as it is.
  assert_equal "<p>Hi <i>y</i></p>", lines[3]
  # count: still picks the plural form; the other values are escaped.
  assert_equal "<b>1</b> item for A&amp;B", lines[4]
  assert_equal "<b>3</b> items for A&amp;B", lines[5]
  # A key ending ".html" is HTML too.
  assert_equal "<em>&lt;me&gt;</em>", lines[6]
  # The default of a missing _html key is HTML; its values are escaped.
  assert_equal "<u>&lt;v&gt;</u>", lines[7]
  assert_equal 8, lines.size
end

test "l and localize in templates" do
  reset_i18n
  body = dispatch(:dates).response.body
  assert_equal "<title>Blog</title>\n2026-11-10|November 10, 2026|10 Nov 09:05|Tue AM &lt;10&gt;|%B %d, %Y", body
end

test "Controller#t resolves .key to controller.action" do
  reset_i18n
  c = AdminPostsController.new(build_ctx)
  c.process(:notice) { |x| x.notice }
  # admin/posts#notice: admin.posts.notice.done; the _html key escapes its
  # value and is still a String; an absolute key and a Symbol key as is.
  assert_equal "Done: <b>|<b>Done</b>: &lt;b&gt;|Hello|Hello", c.response.body
end

Cybertrain::Test.run!
