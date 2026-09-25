class CommentsController < ApplicationController
  def create
    @comment = params[:body].to_s
    redirect_to post_path(params[:post_id].to_s), status: :see_other
  end

  def destroy
    post_id = params[:post_id].to_s
    id = params[:id].to_s
    render plain: "destroy #{id} of #{post_id} #{post_comment_path(post_id, id)}"
  end
end
