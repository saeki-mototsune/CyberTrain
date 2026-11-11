# The three ways a template reaches the interpreter must mean the same
# thing (docs/compatibility.md, "One template, three engines"): the files
# under app/views re-read on change (development), the same files parsed
# once (test), and the table `spin run gen -- --embed-views` compiles into
# the binary (production). Each page below is rendered by all three and the
# output compared; each failing template must fail with the same class and
# the same message, apart from the one documented difference: the embedded
# engine names a template by its table key ("pages/x.html.erb"), the file
# engines by the name it was asked for ("pages/x") or by its path.
#
# cybertrain/template/interpreter.rb requires cybertrain/model -> the SQLite
# FFI, so this runs compiled only (spikes/NOTES.md rule 23).
require "cybertrain/test"
require "cybertrain/template"
require "cybertrain/template/helpers"
require "cybertrain/views"

PARITY_ROOT = "tmp/template_parity/views"

def parity_sources
  table = { "" => "" }
  table.delete("")
  table["layouts/application.html.erb"] = "<html><title><%= yield :title %></title><body>\n<%= yield %></body></html>\n"
  table["pages/expressions.html.erb"] =
    "<% content_for :title do %>Parity<% end %>\n" \
    "<p><%= 1 + 2 * 3 %> <%= 7 / 2 %> <%= 7 % 4 %> <%= 2.5 + 1 %></p>\n" \
    "<p><%= name %> <%== name %> <%= name.upcase %> <%= name.size %></p>\n" \
    "<p><%= \"a\#{1 + 1}b\" %> <%= 'q' %> <%= :sym %> <%= nil %>|<%= @missing %>|</p>\n" \
    "<p><%= items.size > 2 ? \"many\" : \"few\" %> <%= nothing || \"fallback\" %> <%= nothing&.size %>|</p>\n" \
    "<p><%= items[0] %> <%= items.first %> <%= counts[:a] %> <%= [1, 2, 3].sum %> <%= { a: 1 }.size %></p>\n"
  table["pages/statements.html.erb"] =
    "<% total = 0 %>\n" \
    "<% items.each_with_index do |item, i| %><li><%= i %>:<%= item %></li><% total = total + i %><% end %>\n" \
    "<% counts.each do |key, n| %><b><%= key %>=<%= n %></b><% end %>\n" \
    "<% if total > 2 %>big<% elsif total == 1 %>one<% else %>small<% end %> <% unless nothing %>none<% end %>\n" \
    "<% case name %><% when \"x\", \"<world>\" %>hit<% else %>miss<% end %>\n" \
    "<%= items.map { |item| item.upcase }.join(\",\") %> <%= items.select { |item| item.size > 1 }.size %>\n"
  table["pages/partials.html.erb"] =
    "<%= render \"pages/item\", item: name, position: 1 %>\n" \
    "<%= render partial: \"pages/item\", locals: { item: \"two\", position: 2 } %>\n"
  table["pages/_item.html.erb"] = "<%# locals: (item:, position:) %>\n<i><%= position %>.<%= item %></i>\n"
  table["errors/undefined_helper.html.erb"] = "<p>ok</p>\n<%= no_such_helper %>\n"
  table["errors/undefined_method.html.erb"] = "<p>ok</p>\n\n<%= name.no_such_method %>\n"
  table["errors/each_on_scalar.html.erb"] = "<% name.size.each do |x| %><%= x %><% end %>\n"
  table["errors/zero.html.erb"] = "<%= 1 / 0 %>\n"
  table["errors/missing_local.html.erb"] = "<%= render \"pages/item\", item: name %>\n"
  table["errors/unknown_local.html.erb"] = "<%= render \"pages/item\", item: name, position: 1, extra: 2 %>\n"
  table["errors/in_partial.html.erb"] = "<%= render \"errors/broken\" %>\n"
  table["errors/_broken.html.erb"] = "<p>partial</p>\n<%= name.no_such_method %>\n"
  table["syntax/unclosed_if.html.erb"] = "<% if true %>\n<p>never closed</p>\n"
  table["syntax/unclosed_tag.html.erb"] = "<p>\n<%= name\n"
  table["syntax/reserved_word.html.erb"] = "<% if name and nothing %>x<% end %>\n"
  table["syntax/constant.html.erb"] = "<%= Time.now %>\n"
  table["syntax/space_before_paren.html.erb"] = "<%= name.center (9) %>\n"
  table["syntax/assignment_in_output.html.erb"] = "<%= x = 1 %>\n"
  table["syntax/stray_end.html.erb"] = "<p>x</p>\n<% end %>\n"
  table["syntax/hashrocket.html.erb"] = "<%= { \"a\" => 1 }.size %>\n"
  table
end

def parity_remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| parity_remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

def parity_write(path, content)
  current = +""
  File.dirname(path).split("/").each do |part|
    current << "/" unless current.empty?
    current << part
    Dir.mkdir(current) unless Dir.exist?(current)
  end
  File.write(path, content)
  nil
end

parity_remove_tree("tmp/template_parity")
parity_sources.each { |key, source| parity_write("#{PARITY_ROOT}/#{key}", source) }
at_exit { parity_remove_tree("tmp/template_parity") }

def parity_env
  env = {}
  env["name"] = "<world>"
  env["items"] = ["a", "bb", "ccc"]
  env["counts"] = { a: 1, b: 2 }
  env["nothing"] = nil
  env
end

# The `render` helper looks partials up through the process-wide engine,
# so each mode installs its own before it renders.
def parity_engine(mode)
  case mode
  when "development"
    Cybertrain::Views.configure(PARITY_ROOT, cache: false)
  when "test"
    Cybertrain::Views.configure(PARITY_ROOT, cache: true)
  else
    # eager: false, as Main.command configures it: the table holds
    # templates that do not parse, which an eager build refuses whole.
    Cybertrain::Views.configure_embedded(parity_sources, eager: false)
  end
  Cybertrain::Views.configured_engine
end

MODES = ["development", "test", "production"]

def parity_render(mode, page)
  engine = parity_engine(mode)
  engine.render_with_layout(page, "layouts/application", parity_env, Cybertrain::Template::Helpers.new(nil)).to_s
end

# "Class: message", with the template named the same way in every mode:
# the embedded key's ".html.erb" and the file engines' root are dropped.
def parity_failure(mode, page)
  failure = "no error"
  begin
    parity_render(mode, page)
  rescue Cybertrain::Template::SyntaxError => e
    failure = "SyntaxError: #{e.message}"
  rescue Cybertrain::Template::RuntimeError => e
    failure = "RuntimeError: #{e.message}"
  rescue Cybertrain::Template::MissingTemplate => e
    failure = "MissingTemplate: #{e.message}"
  rescue StandardError => e
    failure = "#{e.class.name}: #{e.message}"
  end
  failure.gsub(".html.erb", "").gsub("#{PARITY_ROOT}/", "").gsub(" (embedded)", "")
end

PAGES = ["pages/expressions", "pages/statements", "pages/partials"]

PAGES.each do |page|
  test "#{page} renders the same from files, from cached files and from the embedded table" do
    development = parity_render("development", page)
    puts development
    assert_equal development, parity_render("test", page)
    assert_equal development, parity_render("production", page)
  end
end

FAILURES = ["errors/undefined_helper", "errors/undefined_method", "errors/each_on_scalar", "errors/zero",
            "errors/missing_local", "errors/unknown_local", "errors/in_partial", "errors/nope",
            "syntax/unclosed_if", "syntax/unclosed_tag", "syntax/reserved_word", "syntax/constant",
            "syntax/space_before_paren", "syntax/assignment_in_output", "syntax/stray_end", "syntax/hashrocket"]

FAILURES.each do |page|
  test "#{page} fails the same way in all three" do
    development = parity_failure("development", page)
    puts "  #{development}"
    refute development == "no error"
    assert_equal development, parity_failure("test", page)
    assert_equal development, parity_failure("production", page)
  end
end

test "an edited file is picked up in development only; the cached and embedded engines keep what they parsed" do
  development = parity_engine("development")
  helpers = Cybertrain::Template::Helpers.new(nil)
  assert_equal "<i>1.x</i>\n", development.render("pages/_item", { "item" => "x", "position" => 1 }, helpers).to_s
  cached = parity_engine("test")
  assert_equal "<i>1.x</i>\n", cached.render("pages/_item", { "item" => "x", "position" => 1 }, helpers).to_s
  File.write("#{PARITY_ROOT}/pages/_item.html.erb", "<%# locals: (item:, position:) %>\n<u><%= item %></u>\n\n")
  assert_equal "<i>1.x</i>\n", cached.render("pages/_item", { "item" => "x", "position" => 1 }, helpers).to_s
  assert_equal "<u>x</u>\n\n", development.render("pages/_item", { "item" => "x", "position" => 1 }, helpers).to_s
end

Cybertrain::Test.run!
