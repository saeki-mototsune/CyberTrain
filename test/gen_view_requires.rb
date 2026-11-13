require "tmpdir"
require "cybertrain/test"
require "cybertrain/generator"

# `spin run gen` refuses a view that calls a helper of a subsystem
# bin/NAME.rb does not require (Gen::ViewRequires, the optional-subsystems
# design, section 5): file, line, helper and the require to add, exit 1,
# nothing written, with or without --check. `require "cybertrain/streams"`
# or `require "cybertrain"` accepts the view; a tree with no bin/NAME.rb
# (a fixture) refuses nothing. A helper's name inside a string, a comment,
# a `<%# %>` tag, after a receiver or as a `name:` key is not a call.

ROOT = Dir.mktmpdir("cybertrain-gen-view-requires")
DIRS = ["bin", "app", "app/views", "app/views/articles", "app/components"]
DIRS.each { |d| Dir.mkdir("#{ROOT}/#{d}") }
FILES = ["spin.toml", "bin/shop.rb", "app/views/articles/show.html.erb", "app/views/articles/index.html.erb",
         "app/components/feed_component.html.erb"]

at_exit do
  FILES.each { |f| File.delete("#{ROOT}/#{f}") if File.exist?("#{ROOT}/#{f}") }
  DIRS.reverse.each { |d| Dir.rmdir("#{ROOT}/#{d}") }
  Dir.rmdir(ROOT)
end

File.write("#{ROOT}/spin.toml", "[package]\nname = \"shop\"\nversion = \"0.1.0\"\n\n[dependencies]\ncybertrain = { path = \"../..\" }\n")
File.write("#{ROOT}/app/views/articles/show.html.erb",
           "<h1><%= @article.title %></h1>\n" \
           "<%# turbo_stream_from @article %>\n" \
           "<%= turbo_stream_from @article %>\n" \
           "<p><%= \"turbo_stream_from\" %> <%= link_to \"Back\", articles_path # turbo_stream_from\n%></p>\n" \
           "<%= dom_id(@article) %> <%= turbo_frame_tag \"x\" do %><% end %>\n")
File.write("#{ROOT}/app/views/articles/index.html.erb",
           "<%= render \"list\", turbo_stream_from: 1 %>\n<%= @x.turbo_stream_from %>\n")
File.write("#{ROOT}/app/components/feed_component.html.erb",
           "<div>\n  <%= turbo_stream.replace \"feed\" do %>x<% end %>\n</div>\n")

def write_bin(text)
  File.write("#{ROOT}/bin/shop.rb", text)
  nil
end

REFUSALS = [
  "app/views/articles/show.html.erb:3: turbo_stream_from needs require \"cybertrain/streams\" in bin/shop.rb",
  "app/components/feed_component.html.erb:2: turbo_stream needs require \"cybertrain/streams\" in bin/shop.rb"
].freeze

test "a stream helper without cybertrain/streams is refused, with file and line" do
  write_bin("require \"cybertrain/core\"\nrequire \"cybertrain/jobs\"\n\nexit(Cybertrain::Main.run(\"shop\", ARGV))\n")
  assert_equal REFUSALS.join("\n"), Cybertrain::Gen::ViewRequires.problems(ROOT).join("\n")
end

test "gen refuses before writing anything, and so does --check" do
  assert_equal 1, Cybertrain::Gen::Runner.run(ROOT, [])
  assert_equal 1, Cybertrain::Gen::Runner.run(ROOT, ["--check"])
  refute File.exist?("#{ROOT}/gen")
end

test "require \"cybertrain/streams\" accepts the views" do
  write_bin("require \"cybertrain/core\"\nrequire 'cybertrain/streams'\n")
  assert_equal 0, Cybertrain::Gen::ViewRequires.problems(ROOT).size
end

test "require \"cybertrain\" accepts the views" do
  write_bin("require \"cybertrain\"\n")
  assert_equal 0, Cybertrain::Gen::ViewRequires.problems(ROOT).size
end

test "a commented-out line does not count" do
  write_bin("require \"cybertrain/core\"\n# require \"cybertrain/streams\"\n")
  assert_equal 2, Cybertrain::Gen::ViewRequires.problems(ROOT).size
end

test "with no bin/NAME.rb nothing is refused" do
  File.delete("#{ROOT}/bin/shop.rb")
  assert_equal 0, Cybertrain::Gen::ViewRequires.problems(ROOT).size
end

Cybertrain::Test.run!
