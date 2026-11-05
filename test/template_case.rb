require "cybertrain/test"
require "cybertrain/template"

# `case` / `when` / `else` in templates (docs/guide/template-language.md,
# "case"). cybertrain/model links SQLite through FFI, so this program only
# runs compiled: its snapshot comes from the binary (spikes/NOTES.md rule 23).

# `tick` counts its calls, so a test can see how often the subject ran.
class CaseHelpers < Cybertrain::Template::HelperBase
  def initialize
    @ticks = 0
  end

  def helper_call(name, args, kwargs, block, interp, env)
    case name
    when "tick"
      @ticks += 1
      @ticks
    when "safe" then Cybertrain::SafeString.of("a")
    else super(name, args, kwargs, block, interp, env)
    end
  end
end

def render_case(src, env)
  template = Cybertrain::Template::Template.parse(src, "items/case")
  Cybertrain::Template::Interpreter.new(CaseHelpers.new).render(template, env)
end

# A Hash<String, value>, as every template environment (see
# test/template_interpreter.rb's new_env).
def case_env
  env = {}
  env["kind"] = :a
  env["one"] = 1
  env["word"] = "a"
  env["nothing"] = nil
  env
end

def case_syntax_error(src)
  assert_raises("Cybertrain::Template::SyntaxError") { render_case(src, case_env) }
end

test "the first matching when wins, values separated by commas" do
  src = "<% case kind %><% when :a, :b %>first<% when :a %>second<% end %>"
  assert_equal "first", render_case(src, case_env)
  env = case_env
  env["kind"] = :b
  assert_equal "first", render_case(src, env)
end

test "Integer 1 matches Float 1.0 and the subject is evaluated once" do
  assert_equal "one", render_case("<% case one %><% when 1.0 %>one<% else %>other<% end %>", case_env)
  assert_equal "two", render_case("<% case one + 1 %><% when 1 %>one<% when 2 %>two<% end %>", case_env)
  assert_equal "one 2", render_case("<% case tick %><% when 5 %>five<% when 3, 1 %>one<% end %> <%= tick %>", case_env)
end

test "Strings and SafeStrings compare by their text, both ways round" do
  assert_equal "safe", render_case("<% case safe %><% when 'a' %>safe<% end %>", case_env)
  assert_equal "str", render_case("<% case word %><% when safe %>str<% end %>", case_env)
end

test "else is taken when nothing matches" do
  assert_equal "other", render_case("<% case kind %><% when :x %>x<% else %>other<% end %>", case_env)
end

test "no else and no match prints nothing" do
  assert_equal "[]", render_case("[<% case kind %><% when :x %>x<% when :y %>y<% end %>]", case_env)
end

test "a String does not match Symbols" do
  assert_equal "none", render_case("<% case word %><% when :a %>sym<% else %>none<% end %>", case_env)
  assert_equal "str", render_case("<% case word %><% when :a %>sym<% when 'a' %>str<% end %>", case_env)
  assert_equal "nil", render_case("<% case nothing %><% when false %>false<% when nil %>nil<% end %>", case_env)
end

test "blank text between case and the first when is dropped" do
  src = "<ul>\n<% case kind %>\n  <% when :a %>\n  <li>a</li>\n  <% else %>\n  <li>?</li>\n<% end %>\n</ul>\n"
  assert_equal "<ul>\n  <li>a</li>\n</ul>\n", render_case(src, case_env)
  assert_equal "<p>a</p>", render_case("<% case kind %>  <% when :a %><p>a</p><% end %>", case_env)
end

test "case inside each, and an assignment inside a when stays block-local" do
  env = case_env
  env["items"] = [:a, :b, 3]
  src = "<% items.each do |x| %><% case x %><% when :a %><% label = 'A' %><% when 3 %><% label = 'three' %><% else %><% label = 'other' %><% end %><%= label %>;<% end %>"
  assert_equal "A;other;three;", render_case(src, env)
  refute env.key?("label")
end

test "nested case" do
  src = "<% case kind %><% when :a %><% case one %><% when 1 %>a1<% end %><% end %>"
  assert_equal "a1", render_case(src, case_env)
end

test "syntax errors name the line" do
  assert_equal "items/case:2: 'when' without 'case'", case_syntax_error("x\n<% when :a %>")
  assert_equal "items/case:1: 'when' without 'case'", case_syntax_error("<% if one %><% when 1 %><% end %>")
  assert_equal "items/case:1: 'case' without a subject", case_syntax_error("<% case %><% when 1 %><% end %>")
  assert_equal "items/case:1: 'when' without a value", case_syntax_error("<% case kind %><% when %><% end %>")
  assert_equal "items/case:1: text between 'case' and its first 'when'", case_syntax_error("<% case kind %>x<% when :a %><% end %>")
  assert_equal "items/case:1: 'case' without 'when'", case_syntax_error("<% case kind %><% end %>")
  assert_equal "items/case:1: 'when' after 'else'", case_syntax_error("<% case kind %><% when 1 %><% else %><% when 2 %><% end %>")
  assert_equal "items/case:1: 'case' without 'end'", case_syntax_error("<% case kind %><% when 1 %>")
  assert_equal "items/case:1: 'then' is not supported in templates", case_syntax_error("<% case kind %><% when :a then 1 %><% end %>")
end

Cybertrain::Test.run!
