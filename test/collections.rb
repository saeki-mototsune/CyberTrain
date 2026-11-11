require "cybertrain/test"
require "cybertrain/controller"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
#
# `render partial:, collection:` and `render @records` in a template.
# Partials are test/fixtures/views/collections/**; the templates render
# from pages/.

class Comment < Cybertrain::Model
  def initialize(id, title)
    super()
    set_id(id)
    mark_persisted! if id > 0
    @title = title
  end

  def model_name = "Comment"

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    else nil
    end
  end
end

Cybertrain::Views.configure("test/fixtures/views/collections", cache: true)

def render_inline(src)
  template = Cybertrain::Template::Template.parse(src, "pages/inline")
  env = { "__template_dir" => [nil, 0, 0.0, "", true][3] }
  env["__template_dir"] = "pages"
  env["items"] = ["a", "b"]
  env["none"] = Array.new(0) { "" }
  env["comments"] = [Comment.new(1, "first"), Comment.new(2, "<second>")]
  env["comment"] = Comment.new(5, "fifth")
  Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil)).render(template, env)
end

def render_error(src)
  msg = ""
  begin
    render_inline(src)
  rescue StandardError => e
    msg = e.message
  end
  msg
end

test "render partial: collection: with as:, counter and spacer" do
  assert_equal "<li>0 a</li><hr><li>1 b</li>", render_inline("<%= render partial: \"item\", collection: items, as: :item, spacer_template: \"hr\" %>")
  # as: defaults to the partial's name.
  assert_equal "<li>0 a</li><li>1 b</li>", render_inline("<%= render partial: \"pages/item\", collection: items %>")
  # An empty collection renders nothing, spacer included.
  assert_equal "[]", render_inline("[<%= render partial: \"item\", collection: none, spacer_template: \"hr\" %>]")
end

test "strict locals get the counter only when they declare it; locals: reach every item" do
  assert_equal "<td>a</td><td>b</td>", render_inline("<%= render partial: \"row\", collection: items %>")
  # The item wins over a local of its name, as in Rails.
  assert_equal "<li>0 a</li><li>1 b</li>", render_inline("<%= render partial: \"item\", collection: items, locals: { item: \"x\" } %>")
  assert_equal "<td>0:a</td><td>1:b</td>", render_inline("<%= render partial: \"counted_row\", collection: items, as: \"row\" %>")
  assert_equal "pages/inline:1: unknown local 'extra' for pages/_row.html.erb",
               render_error("<%= render partial: \"row\", collection: items, locals: { extra: 1 } %>")
  assert_equal "pages/inline:1: render collection: must be an Array, got 1", render_error("<%= render partial: \"row\", collection: 1 %>")
end

test "render @comments picks comments/_comment" do
  assert_equal "<li>first</li><li>&lt;second&gt;</li>", render_inline("<%= render comments %>")
  # One record renders its partial once.
  assert_equal "<li>fifth</li>", render_inline("<%= render comment %>")
  assert_equal "", render_inline("<%= render none %>")
  assert_equal "pages/inline:1: render expects records in a collection, got a", render_error("<%= render items %>")
end

Cybertrain::Test.run!
