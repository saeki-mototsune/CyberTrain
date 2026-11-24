module CommentsHelper
  # The commenter's name in a <strong>, escaped: `<%= comment_author(c) %>`.
  def comment_author(comment)
    tag.strong(comment.commenter.to_s, class: "comment-author")
  end
end
