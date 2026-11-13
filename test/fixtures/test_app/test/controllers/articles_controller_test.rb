require "test_helper"

# ActionDispatch::IntegrationTest against the booted application, on the
# fixture rows (test/fixtures/*.yml): the path helpers, a create with
# nested params, follow_redirect!.
class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "lists the rows" do
    get articles_path
    assert_response :success
    assert_includes response.body, "First post"
    assert_includes response.body, "Second post"
  end

  test "shows one through its path helper" do
    get article_path(@article)
    assert_response :success
    assert_equal "First post by Alice", response.body
  end

  test "creates one and follows the redirect" do
    assert_difference -> { Article.count }, 1 do
      post articles_path, params: { article: { title: "New", body: "A body long enough", author_id: users(:alice).id } }
    end
    assert_redirected_to article_path(Article.last)
    follow_redirect!
    assert_response :success
    assert_equal "New by Alice", response.body
  end

  test "an unknown path fails with the top-level form's message" do
    get "/nowhere"
    assert_response :not_found
    message = assert_raises("AssertionFailed") { assert_response :success }
    assert_equal "expected response :success, got 404", message
  end

  test "shows the form for a new one" do
    get new_article_path
    assert_response :success
    assert_select "h1", "New article"
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
  end
end
