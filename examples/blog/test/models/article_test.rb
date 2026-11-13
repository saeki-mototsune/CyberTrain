require "test_helper"

# Article (app/models/article.rb): its validations, the comments it
# deletes before it is destroyed, and Article.recent.
class ArticleTest < ActiveSupport::TestCase
  test "the fixtures are valid" do
    assert articles(:one).valid?
    assert articles(:two).valid?
  end

  # articles(:one) has comments(:one) and the two below; articles(:two)
  # has only "Staying".
  test "destroying an article destroys its comments" do
    article = articles(:one)
    kept = articles(:two)
    Comment.create(commenter: "Alice", body: "Going", article_id: article.id)
    Comment.create(commenter: "Bob", body: "Going too", article_id: article.id)
    Comment.create(commenter: "Carol", body: "Staying", article_id: kept.id)
    article.destroy
    assert_equal 1, Article.count
    assert_equal 1, Comment.count
    assert_equal "Staying", Comment.first.body
  end

  # The fixtures are dated 2024-03-10 (one) and 2024-03-11 (two), between
  # the two articles made here.
  test "Article.recent puts the newest first" do
    older = Article.create(title: "Older article", body: "I am on Rails! This is my first article.")
    newer = Article.create(title: "Newer article", body: "I am on Rails! This is my first article.")
    older.update_columns(created_at: Time.utc(2024, 1, 1, 0, 0, 0))
    newer.update_columns(created_at: Time.utc(2024, 6, 1, 0, 0, 0))
    assert_equal newer.id, Article.recent.first.id
    assert_equal ["Newer article", "Second article", "Hello Rails", "Older article"], Article.recent.to_a.map { |a| a.title }
  end

  test "a title is required, a body of 10 characters or more, and the title is unique" do
    article = Article.new(title: "", body: "Too short")
    refute article.valid?
    assert_equal ["Title can't be blank", "Body is too short (minimum is 10 characters)"], article.errors.full_messages
    taken = Article.new(title: articles(:one).title, body: "Another article with the same title.")
    refute taken.valid?
    assert_equal ["Title has already been taken"], taken.errors.full_messages
  end
end
