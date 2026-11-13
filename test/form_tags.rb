require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/session"

# The standalone form tag helpers (V-7): select_tag, options_for_select,
# options_from_collection_for_select, label_tag, text_field_tag,
# hidden_field_tag, check_box_tag, submit_tag. cybertrain/model links SQLite through FFI,
# so this program cannot run under CRuby: its snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).

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

  def attribute_or_method?(name)
    case name
    when :id, :name then true
    else false
    end
  end
end

Cybertrain::Views.url_resolver = lambda do |name, args, options|
  raise "no route #{name}"
end

def helpers
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/search", { "host" => "example.test" }, ""))
  ctx.session = Cybertrain::Session.new({ "_csrf_token" => "T0K" })
  Cybertrain::Template::Helpers.new(Cybertrain::Controller.new(ctx))
end

def render_inline(src)
  env = {}
  env["authors"] = [Author.new(1, "Ann"), Author.new(2, "Bo <3>")]
  template = Cybertrain::Template::Template.parse(src, "search/index")
  Cybertrain::Template::Interpreter.new(helpers).render(template, env)
end

test "select_tag with options_for_select" do
  assert_equal "<select name=\"order\" id=\"order\"><option value=\"new\">Newest</option>\n<option selected=\"selected\" value=\"old\">Oldest</option></select>",
               render_inline("<%= select_tag('order', options_for_select([['Newest', 'new'], ['Oldest', 'old']], 'old')) %>")
  # Blank and prompt options come first, without a newline (as Rails' select_tag); multiple: names order[].
  assert_equal "<select name=\"order[]\" id=\"order\" multiple=\"multiple\" class=\"o\"><option value=\"\">Any</option><option value=\"\" label=\" \"></option><option value=\"a\">a</option></select>",
               render_inline("<%= select_tag 'order', options_for_select(['a']), include_blank: true, prompt: 'Any', multiple: true, class: 'o' %>")
  assert_equal "<select name=\"q[order]\" id=\"q_order\"><option value=\"\">None</option></select>",
               render_inline("<%= select_tag 'q[order]', nil, include_blank: 'None' %>")
  # A plain String is escaped; only option tags from the helpers (SafeStrings) pass through.
  assert_equal "<select name=\"x\" id=\"x\">&lt;option&gt;</select>", render_inline("<%= select_tag 'x', '<option>' %>")
end

test "options_for_select takes values, pairs, a Hash and several selected values, compared as strings" do
  assert_equal "<option selected=\"selected\" value=\"1\">1</option>\n<option value=\"2\">2</option>\n<option selected=\"selected\" value=\"&lt;3\">&lt;3</option>",
               render_inline("<%= options_for_select([1, 2, '<3'], ['1', '<3']) %>")
  assert_equal "<option value=\"a\">A</option>\n<option selected=\"selected\" value=\"b&amp;\">B</option>",
               render_inline("<%= options_for_select({ A: 'a', B: 'b&' }, 'b&') %>")
  assert_equal "<option value=\"x\"><b>X</b></option>", render_inline("<%= options_for_select([[raw('<b>X</b>'), 'x']]) %>")
end

test "options_from_collection_for_select reads each record" do
  assert_equal "<option value=\"1\">Ann</option>\n<option selected=\"selected\" value=\"2\">Bo &lt;3&gt;</option>",
               render_inline("<%= options_from_collection_for_select(authors, :id, :name, 2) %>")
  assert_equal "<option value=\"1\">Ann</option>\n<option value=\"2\">Bo &lt;3&gt;</option>",
               render_inline("<%= options_from_collection_for_select(authors, :id, :name) %>")
  msg = assert_raises("RuntimeError") { render_inline("<%= options_from_collection_for_select(authors, :id, :nope) %>") }
  assert_equal "search/index:1: options_from_collection_for_select: Author has no attribute or view method 'nope'", msg
end

test "label_tag, text_field_tag, hidden_field_tag and submit_tag" do
  assert_equal "<label for=\"term\">Term</label>", render_inline("<%= label_tag(:term) %>")
  assert_equal "<label for=\"q_term\" class=\"l\">Find &lt;it&gt;</label>", render_inline("<%= label_tag 'q[term]', 'Find <it>', class: 'l' %>")
  assert_equal "<input type=\"text\" name=\"term\" id=\"term\" value=\"x\" placeholder=\"Search\">",
               render_inline("<%= text_field_tag(:term, 'x', placeholder: 'Search') %>")
  assert_equal "<input type=\"text\" name=\"q[term]\" id=\"q_term\">", render_inline("<%= text_field_tag 'q[term]' %>")
  assert_equal "<input type=\"text\" name=\"term\" id=\"search\" value=\"&quot;a&quot;\" required=\"required\">",
               render_inline("<%= text_field_tag :term, '\"a\"', id: 'search', required: true %>")
  assert_equal "<input type=\"hidden\" name=\"t\" id=\"t\" value=\"1\" autocomplete=\"off\">", render_inline("<%= hidden_field_tag(:t, '1') %>")
  assert_equal "<input type=\"submit\" name=\"commit\" value=\"Save changes\">", render_inline("<%= submit_tag %>")
  assert_equal "<input type=\"submit\" name=\"commit\" value=\"Go &lt;\" data-turbo-submits-with=\"Going\" class=\"b\">",
               render_inline("<%= submit_tag 'Go <', class: 'b', data: { turbo_submits_with: 'Going' } %>")
end

test "check_box_tag is a box with no hidden field, value 1 unless given" do
  assert_equal "<input type=\"checkbox\" name=\"remember_me\" id=\"remember_me\" value=\"1\">", render_inline("<%= check_box_tag :remember_me %>")
  # checked="checked" comes last, after the other attributes, as Rails
  # writes it; any truthy third argument checks the box.
  assert_equal "<input type=\"checkbox\" name=\"tags[]\" id=\"tag_ruby\" value=\"ruby &amp; c\" class=\"c\" checked=\"checked\">",
               render_inline("<%= check_box_tag 'tags[]', 'ruby & c', true, id: 'tag_ruby', class: 'c' %>")
  assert_equal "<input type=\"checkbox\" name=\"x\" id=\"x\" value=\"1\" checked=\"checked\">", render_inline("<%= check_box_tag :x, '1', 'yes' %>")
  assert_equal "<input type=\"checkbox\" name=\"x\" id=\"x\" value=\"1\" checked=\"checked\">", render_inline("<%= check_box_tag :x, '1', 1 %>")
  assert_equal "<input type=\"checkbox\" name=\"x\" id=\"x\" value=\"1\">", render_inline("<%= check_box_tag :x, '1', nil %>")
  assert_equal "<input type=\"checkbox\" name=\"x\" id=\"x\" value=\"1\">", render_inline("<%= check_box_tag :x, '1', false %>")
  assert_equal "<input type=\"checkbox\" name=\"q[on]\" id=\"q_on\" value=\"yes\">", render_inline("<%= check_box_tag('q[on]', 'yes', false) %>")
  # A nil value writes none (Rails' check_box_tag too).
  assert_equal "<input type=\"checkbox\" name=\"n\" id=\"n\" checked=\"checked\">", render_inline("<%= check_box_tag(:n, nil, true) %>")
  assert_equal "<input type=\"checkbox\" name=\"remember_me\" id=\"remember_me\" value=\"1\"><label for=\"remember_me\">Keep me signed in</label>",
               render_inline("<%= check_box_tag :remember_me %><%= label_tag :remember_me, 'Keep me signed in' %>")
  msg = assert_raises("RuntimeError") { render_inline("<%= check_box_tag %>") }
  assert_equal "search/index:1: wrong number of arguments for 'check_box_tag' (given 0, expected 1..3)", msg
end

test "the tag helpers check their arguments" do
  msg = assert_raises("RuntimeError") { render_inline("<%= options_for_select %>") }
  assert_equal "search/index:1: wrong number of arguments for 'options_for_select' (given 0, expected 1..2)", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= options_for_select(['a'], nil, x: 1) %>") }
  assert_equal "search/index:1: 'options_for_select' takes no keyword arguments (given x)", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= select_tag %>") }
  assert_equal "search/index:1: wrong number of arguments for 'select_tag' (given 0, expected 1..2)", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= hidden_field_tag %>") }
  assert_equal "search/index:1: wrong number of arguments for 'hidden_field_tag' (given 0, expected 1..2)", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= submit_tag 'a', 'b' %>") }
  assert_equal "search/index:1: wrong number of arguments for 'submit_tag' (given 2, expected 0..1)", msg
end

Cybertrain::Test.run!
