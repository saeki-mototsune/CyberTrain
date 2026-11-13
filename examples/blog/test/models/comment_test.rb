require "test_helper"

# Comment (app/models/comment.rb): a commenter and a body, on an article.
class CommentTest < ActiveSupport::TestCase
  test "the fixture is valid and belongs to its article" do
    comment = comments(:one)
    assert comment.valid?
    assert_equal articles(:one).id, comment.article.id
  end

  test "a comment needs a commenter and a body" do
    comment = Comment.new(commenter: "", body: "", article_id: articles(:one).id)
    refute comment.valid?
    assert_equal ["Commenter can't be blank", "Body can't be blank"], comment.errors.full_messages
  end
end
