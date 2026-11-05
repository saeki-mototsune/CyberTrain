# One comment on the article page: rendered in the list by
# `<%= render component: "comment", comment: c %>` (articles/show) and,
# outside any request, by CommentsController#create's broadcast
# (Cybertrain::Stream.broadcast_append_to). The template beside it,
# comment_component.html.erb, sees @comment as `comment`.
class CommentComponent < Cybertrain::Component
  def initialize(comment:)
    @comment = comment
  end
end
