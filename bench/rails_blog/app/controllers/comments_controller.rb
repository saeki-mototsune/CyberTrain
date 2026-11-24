class CommentsController < ApplicationController
  # Visitors comment; deleting a comment needs a signed-in user.
  allow_unauthenticated_access only: [:create]
  before_action :set_article

  # POST /articles/1/comments
  # A form Turbo submits asks for a Turbo Stream: create.turbo_stream.erb
  # appends the comment to #comments and puts an empty form back. A plain
  # form submission is redirected to the article with a notice. A comment
  # that does not save redirects either way, with the reason in the alert.
  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    unless @comment.save
      reasons = @comment.errors.full_messages.join(t("support.array.words_connector"))
      flash[:alert] = t(".not_saved", errors: reasons)
      redirect_to article_path(@article), status: :see_other
      return
    end

    # Logged by a Solid Queue worker thread, after the response went out.
    NotifyCommentJob.perform_later(comment_id: @comment.id, article_id: @article.id)
    # Every page subscribed with `turbo_stream_from @article` appends the
    # new comment to its #comments list. Rendered here, in the request, as
    # examples/blog renders its broadcast (not broadcast_append_later_to).
    Turbo::StreamsChannel.broadcast_append_to(@article, target: "comments",
                                                        partial: "comments/comment", locals: { comment: @comment })
    # The empty form create.turbo_stream.erb puts back.
    @new_comment = Comment.new
    respond_to do |format|
      format.turbo_stream
      format.html do
        flash[:notice] = t(".created")
        redirect_to article_path(@article), status: :see_other
      end
    end
  end

  # DELETE /articles/1/comments/1
  def destroy
    @comment = @article.comments.find(params[:id])
    @comment.destroy
    Turbo::StreamsChannel.broadcast_remove_to(@article, target: @comment)
    flash[:notice] = t(".destroyed")
    redirect_to article_path(@article), status: :see_other
  end

  private

  def set_article
    @article = Article.find(params[:article_id])
  end

  def comment_params
    params.require(:comment).permit(:commenter, :body)
  end
end
