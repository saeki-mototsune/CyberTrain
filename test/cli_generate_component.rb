require "tmpdir"
require "cybertrain/cli"
require "cybertrain/generator/component_scan"
require "cybertrain/test"

# `cybertrain generate component`: the class, its template and a test.
TMP = Dir.mktmpdir("cybertrain-cli-generate-component")
Dir.chdir(TMP)

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }")

def generate(args)
  Dir.chdir("shop") { Cybertrain::CLI.run(["generate", "component"] + args) }
end

test "generate component card title value:integer writes the class with one keyword per attribute" do
  assert_equal 0, generate(["card", "title", "value:integer"])
  assert_equal <<~'RUBY', File.read("shop/app/components/card_component.rb")
    class CardComponent < Cybertrain::Component
      def initialize(title:, value:)
        @title = title
        @value = value
      end
    end
  RUBY
end

test "the template prints each attribute, then the content" do
  assert_equal <<~'ERB', File.read("shop/app/components/card_component.html.erb")
    <div class="card">
      <p><%= title %></p>
      <p><%= value %></p>
      <%= content %>
    </div>
  ERB
end

test "the component test is in the class form: render_inline and assert_select" do
  assert_equal <<~'RUBY', File.read("shop/test/components/card_component_test.rb")
    require "test_helper"

    class CardComponentTest < ViewComponent::TestCase
      test "renders its attributes and content" do
        render_inline(CardComponent.new(title: "Title", value: 1), content: "<b>inside</b>")
        assert_select "div.card > p", text: "Title"
        assert_select "div.card > p", text: "1"
        assert_select "div.card > b", text: "inside"
      end
    end
  RUBY
  refute File.exist?("shop/test/card_component.rb")
  refute File.exist?("shop/test/support/app_test.rb")
end

test "spin run gen's scan accepts the generated component" do
  infos = Cybertrain::Gen::ComponentScan.scan_dir("shop/app/components")
  assert_equal ["CardComponent"], infos.map { |i| i.class_name }
  assert_equal ["title", "value"], infos[0].keywords_required
  assert_equal ["title", "value"], infos[0].ivars
end

test "a namespaced component is nested in its module" do
  assert_equal 0, generate(["admin/user_row", "name"])
  assert_includes File.read("shop/app/components/admin/user_row_component.rb"), "module Admin\n  class UserRowComponent < Cybertrain::Component\n    def initialize(name:)\n"
  assert File.exist?("shop/app/components/admin/user_row_component.html.erb")
  test_source = File.read("shop/test/components/admin/user_row_component_test.rb")
  assert_includes test_source, "class Admin::UserRowComponentTest < ViewComponent::TestCase\n"
  assert_includes test_source, "    render_inline(Admin::UserRowComponent.new(name: \"Name\"), content: \"<b>inside</b>\")\n"
  assert_includes test_source, "    assert_select \"div.user-row > p\", text: \"Name\"\n"
end

test "an existing, different file is refused unless --force" do
  assert_equal 1, generate(["card", "title"])
  assert_includes File.read("shop/app/components/card_component.rb"), "value:"
  assert_equal 0, generate(["card", "title", "--force"])
  refute File.read("shop/app/components/card_component.rb").index("value:")
  assert_equal 0, generate(["card", "title"])
end

test "bad attributes and usage are rejected before anything is written" do
  assert_equal 1, generate(["badge", "content"])
  assert_equal 1, generate(["badge", "label:date"])
  assert_equal 1, generate(["badge", "class"])
  assert_equal 1, generate(["badge", "a", "a"])
  assert_equal 1, generate(["badge", "a:b:c"])
  assert_equal 1, generate([])
  refute File.exist?("shop/app/components/badge_component.rb")
end

Cybertrain::Test.run!
