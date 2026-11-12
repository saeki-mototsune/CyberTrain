require "test_helper"

# ActionDispatch::IntegrationTest against the booted application: its own
# rows (no fixtures), the path helpers, a create with nested params.
class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Article.all.delete_all
    User.all.delete_all
    @author = User.create(name: "Cy", email: "cy@example.com")
    @first = Article.create(title: "First", body: "A body.", author_id: @author.id)
  end

  test "lists the rows" do
    get articles_path
    assert_response :success
    assert_equal "First", response.body
  end

  test "shows one through its path helper" do
    get article_path(@first)
    assert_response :success
    assert_equal "First by Cy", response.body
  end

  test "creates one and follows the redirect" do
    assert_difference -> { Article.count }, 1 do
      post articles_path, params: { article: { title: "New", body: "A body long enough", author_id: @author.id } }
    end
    assert_redirected_to article_path(Article.last)
    follow_redirect!
    assert_response :success
    assert_equal "New by Cy", response.body
  end

  test "an unknown path fails with the top-level form's message" do
    get "/nowhere"
    assert_response :not_found
    message = assert_raises("AssertionFailed") { assert_response :success }
    assert_equal "expected response :success, got 404", message
  end
end
