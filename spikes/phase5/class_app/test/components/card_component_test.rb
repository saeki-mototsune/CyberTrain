require "test_helper"

class CardComponentTest < ViewComponent::TestCase
  test "renders the title" do
    html = render_inline(CardComponent.new(title: "Hello"), content: "<p>body</p>")
    assert_includes html, "<h2>Hello</h2>"
  end
end
