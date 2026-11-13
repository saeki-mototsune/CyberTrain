require "test_helper"

# CommentComponent (app/components/comment_component.rb and its template):
# one comment, as the article page lists it and as the broadcast appends it.
class CommentComponentTest < ViewComponent::TestCase
  test "renders the comment with its author, its body and a delete button" do
    comment = comments(:one)
    render_inline(CommentComponent.new(comment: comment))
    assert_select "div#comment_#{comment.id}.comment"
    assert_select "div.comment strong.comment-author", text: "Alice"
    assert_select "div.comment > p", text: "Great post!"
    assert_select "form.button_to[action=\"/articles/#{comment.article_id}/comments/#{comment.id}\"] button", text: "Destroy comment"
  end
end
