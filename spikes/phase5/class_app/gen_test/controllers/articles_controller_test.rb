
class ArticlesControllerTest < ApplicationIntegrationTest; def setup; super; setup_articles_controller_test_1; nil; end; def teardown; super; nil; end
  def setup_articles_controller_test_1
    @article = articles(:one)
  nil; end

  def test_shows_an_article
    get article_path(@article)
    assert_response :success
    assert_includes response.body, "<h1>First</h1>"
  nil; end

  def test_creates_an_article
    post articles_path, params: { article: { title: "x" } }
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_equal 3, Article.count
  nil; end

  def test_head_and_delete_answer_the_response
    assert_equal 200, head(articles_path).status
    assert_equal 404, delete(article_path(@article)).status
    assert_equal "FIRST", title_upcased(@article)
    assert_equal 2, @user.articles.count
  nil; end
end
