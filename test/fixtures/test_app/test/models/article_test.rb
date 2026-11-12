require "test_helper"

class ArticleTest < ApplicationTest
  test "title must be present" do
    article = Article.new(body: "A body.", author_id: @author.id)
    refute article.save
    assert_includes article.errors.full_messages, "Title can't be blank"
  end

  test "belongs to its author" do
    article = write_article("Hello Rails")
    assert_equal "Ann", Article.find(article.id).author.name
    assert_equal 1, @author.articles.to_a.size
  end

  test "keeps a boolean, a datetime and a decimal" do
    at = Time.utc(2026, 11, 12, 9, 30, 0)
    article = Article.create(title: "Typed", author_id: @author.id, published: true, published_at: at, price: 12.5)
    found = Article.find(article.id)
    assert found.published
    assert_equal at.to_i, found.published_at.to_i
    assert_equal 12.5, found.price
  end

  test "starts from empty tables" do
    assert_equal 0, Article.count
    assert_equal 1, User.count
  end

  test "a slug from the support helper" do
    assert_equal "hello-rails", slug_of(write_article("Hello Rails").title)
  end
end
