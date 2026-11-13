require "test_helper"

# render_inline and assert_select (spec section 9.1): a component, then a
# partial outside any request.
class CardComponentTest < ViewComponent::TestCase
  test "renders the title" do
    render_inline(CardComponent.new(title: "Hello"))
    assert_select "div.card > h2", text: "Hello"
  end

  test "renders the form partial" do
    html = render_inline(partial: "articles/form", locals: { article: Article.new })
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
    assert_includes html, "Save"
  end
end
