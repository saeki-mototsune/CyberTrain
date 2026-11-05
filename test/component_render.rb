require "tmpdir"
require "cybertrain/test"
require "cybertrain/controller"

# `render component:` (spec 3.2): component classes and the Gen::Components
# table hand-written in the shape gen/components.rb emits, templates in a
# temporary app/views + app/components tree.
#
# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class CardComponent < Cybertrain::Component
  def initialize(title:, value: 0)
    @title = title
    @value = value
  end

  def value_text = "#{@value} pts"

  # What gen/components.rb emits for this class.
  def view_assigns
    { "title" => @title, "value" => @value }
  end

  def call_view_method(name)
    case name
    when :value_text then value_text
    else nil
    end
  end

  def view_method?(name)
    case name
    when "value_text" then true
    else false
    end
  end

  def component_name
    "card"
  end

  def component_template
    "components/card_component.html.erb"
  end
end

class FrameComponent < Cybertrain::Component
  def initialize(label:)
    @label = label
  end

  def view_assigns
    { "label" => @label }
  end

  def component_name
    "frame"
  end

  def component_template
    "components/frame_component.html.erb"
  end
end

# Renders itself without end, to reach max_render_depth.
class LoopComponent < Cybertrain::Component
  def component_name
    "loop"
  end

  def component_template
    "components/loop_component.html.erb"
  end
end

module Gen
  module Components
    def self.build(name, kwargs)
      case name
      when "card"
        Cybertrain::Component.check_keywords!(name, kwargs, ["title", "value"], 1)
        if kwargs.key?("value") then ::CardComponent.new(title: kwargs["title"], value: kwargs["value"])
        else ::CardComponent.new(title: kwargs["title"])
        end
      when "frame"
        Cybertrain::Component.check_keywords!(name, kwargs, ["label"], 1)
        ::FrameComponent.new(label: kwargs["label"])
      when "loop"
        Cybertrain::Component.check_keywords!(name, kwargs, Array.new(0) { "" }, 0)
        ::LoopComponent.new
      else
        raise Cybertrain::Component::Unknown, "no component '#{name}' (app/components/#{name}_component.rb, then `spin run gen`)"
      end
    end
  end
end

Cybertrain::Views.component_builder = ->(name, kwargs) { Gen::Components.build(name, kwargs) }

ROOT = Dir.mktmpdir("cybertrain-component-render")
FILES = {
  "app/components/card_component.html.erb" => "<div class=\"card\"><h3><%= title %></h3><p><%= value_text %></p><%= content %></div>",
  "app/components/frame_component.html.erb" => "<section><%= label %>:<%= render component: \"card\", title: label %>|<%= render \"shared/note\", text: label %></section>",
  "app/components/loop_component.html.erb" => "<%= render component: \"loop\" %>",
  "app/views/shared/_note.html.erb" => "<i><%= text %></i>"
}
DIRS = ["app", "app/views", "app/views/shared", "app/components"]
DIRS.each { |d| Dir.mkdir("#{ROOT}/#{d}") }
FILES.each_key { |f| File.write("#{ROOT}/#{f}", FILES[f]) }
at_exit do
  FILES.each_key { |f| File.delete("#{ROOT}/#{f}") }
  DIRS.reverse.each { |d| Dir.rmdir("#{ROOT}/#{d}") }
  Dir.rmdir(ROOT)
end
Cybertrain::Views.configure("#{ROOT}/app/views", cache: false)

def render_inline(src, max_depth = 12)
  template = Cybertrain::Template::Template.parse(src, "pages/inline")
  env = { "__template_dir" => "pages" }
  env["v"] = 2
  Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil), max_depth).render(template, env)
end

def render_error(src, max_depth = 12)
  msg = ""
  begin
    render_inline(src, max_depth)
  rescue StandardError => e
    msg = e.message
  end
  msg
end

test "render component: renders the template with the ivars, view methods and an empty content" do
  assert_equal "<div class=\"card\"><h3>T &amp; U</h3><p>2 pts</p></div>", render_inline("<%= render component: \"card\", title: \"T & U\", value: v %>")
end

test "an omitted keyword gets initialize's own default" do
  assert_equal "<div class=\"card\"><h3>T</h3><p>0 pts</p></div>", render_inline("<%= render component: \"card\", title: \"T\" %>")
end

test "a block becomes the content, unescaped" do
  html = render_inline("<%= render component: \"card\", title: \"T\" do %><b><%= v %></b><% end %>")
  assert_equal "<div class=\"card\"><h3>T</h3><p>0 pts</p><b>2</b></div>", html
end

test "components render other components and partials" do
  assert_equal "<section>L:<div class=\"card\"><h3>L</h3><p>0 pts</p></div>|<i>L</i></section>", render_inline("<%= render component: \"frame\", label: \"L\" %>")
end

test "an unknown component raises Component::Unknown with the file hint" do
  msg = render_error("<%= render component: \"nope\" %>")
  assert_equal "pages/inline:1: no component 'nope' (app/components/nope_component.rb, then `spin run gen`)", msg
end

test "keywords are checked" do
  assert_equal "pages/inline:1: missing keyword 'title' for component 'card'", render_error("<%= render component: \"card\" %>")
  assert_equal "pages/inline:1: unknown keyword 'titel' for component 'card' (known: title, value)", render_error("<%= render component: \"card\", title: \"x\", titel: \"y\" %>")
end

test "component nesting counts toward max_render_depth" do
  assert_includes render_error("<%= render component: \"loop\" %>", 4), "partial nesting too deep (> 4)"
end

test "the derived names of the base class" do
  assert_equal "admin/user_row", Cybertrain::Component.name_for("Admin::UserRowComponent")
  assert_equal "card", Cybertrain::Component.name_for("CardComponent")
  assert_equal "", Cybertrain::Component.new.content.to_s
end

Cybertrain::Test.run!
