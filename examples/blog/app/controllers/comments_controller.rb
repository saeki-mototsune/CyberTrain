class CommentsController < ApplicationController
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
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
      redirect_to article_path(@article), status: :see_other
      return
    end

    # Logged by a job thread, after the response went out.
    NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)
    # Every page subscribed with `turbo_stream_from @article` (stream
    # "articles:<id>") appends the new comment to its #comments list.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                                     component: CommentComponent.new(comment: @comment))
    # The empty form create.turbo_stream.erb puts back.
    @new_comment = Comment.new
    respond_to do |format|
      format.turbo_stream
      format.html do
        flash[:notice] = "Comment was successfully created."
        redirect_to article_path(@article), status: :see_other
      end
    end
  end

  # DELETE /articles/1/comments/1
  def destroy
    @comment = @article.comments.find(params[:id])
    # The element's id before destroy clears the record's id (dom_id of a
    # destroyed record is "new_comment"): the other pages of this article
    # drop that element; this tab reloads anyway.
    target = Cybertrain::Html.dom_id(@comment)
    @comment.destroy
    Cybertrain::Stream.broadcast_remove_to(@article, target: target)
    flash[:notice] = "Comment was successfully destroyed."
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
