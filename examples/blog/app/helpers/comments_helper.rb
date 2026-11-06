# Application helpers (app/helpers/*.rb) are mixed into every template:
# `spin run gen` writes the dispatch in gen/helpers.rb. Arguments arrive as
# the template's values, so the helper narrows them with `case`.
module CommentsHelper
  # The commenter's name in a <strong>, escaped: `<%= comment_author(c) %>`.
  def comment_author(comment)
    name = case comment
           when Comment then comment.commenter.to_s
           else ""
           end
    Cybertrain::Html.tag("strong", { class: "comment-author" }, name)
  end
end
