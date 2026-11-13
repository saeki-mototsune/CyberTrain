
class CardComponentTest < ViewComponent::TestCase
  def test_renders_the_title
    html = render_inline(CardComponent.new(title: "Hello"), content: "<p>body</p>")
    assert_includes html, "<h2>Hello</h2>"
  nil; end
end
