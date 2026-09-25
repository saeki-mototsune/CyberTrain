# The views `cybertrain new` and `generate scaffold` write must parse with
# the framework's template engine: they may only use the template language
# subset (docs/design.md section 7), never arbitrary Ruby.
require "tmpdir"
require "cybertrain/cli"
require "cybertrain/template"
require "cybertrain/test"

TMP = Dir.mktmpdir("cybertrain-cli-views")
Dir.chdir(TMP)

# Removes a generated tree (files, dot-files and directories).
def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

# Test.run! exits the process, so the temp tree is removed at exit.
at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end
ENV["CYBERTRAIN_TIMESTAMP"] = "20260925120000"
Cybertrain::CLI::NewApp.create("blog", "{ path = \"../cybertrain\" }")
Cybertrain::CLI::Scaffold.generate("blog", "post", ["title:string", "body:text", "published:boolean"])
Cybertrain::CLI::Scaffold.generate("blog", "comment", ["commenter:string", "body:text", "post:references"])

VIEWS = [
  "layouts/application",
  "posts/index", "posts/show", "posts/new", "posts/edit", "posts/_form",
  "comments/index", "comments/show", "comments/new", "comments/edit", "comments/_form"
]

def parse_view(name)
  source = File.read("blog/app/views/#{name}.html.erb")
  Cybertrain::Template::Template.parse(source, "#{name}.html.erb")
end

VIEWS.each do |name|
  test "#{name} parses" do
    template = parse_view(name)
    assert template.nodes.size > 0, "#{name} has no nodes"
  end
end

test "the form partials declare their strict locals" do
  assert parse_view("posts/_form").strict_locals?, "posts/_form"
  assert_equal ["post"], parse_view("posts/_form").locals
  assert_equal ["comment"], parse_view("comments/_form").locals
  refute parse_view("posts/show").strict_locals?, "posts/show"
end

Cybertrain::Test.run!
