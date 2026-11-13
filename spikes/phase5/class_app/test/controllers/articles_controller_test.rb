require "test_helper"

class ArticlesControllerTest < ApplicationIntegrationTest
  setup do
    @article = articles(:one)
  end

  test "shows an article" do
    get article_path(@article)
    assert_response :success
    assert_includes response.body, "<h1>First</h1>"
  end

  test "creates an article" do
    post articles_path, params: { article: { title: "x" } }
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_equal 3, Article.count
  end

  test "head and delete answer the response" do
    assert_equal 200, head(articles_path).status
    assert_equal 404, delete(article_path(@article)).status
    assert_equal "FIRST", title_upcased(@article)
    assert_equal 2, @user.articles.count
  end
end
