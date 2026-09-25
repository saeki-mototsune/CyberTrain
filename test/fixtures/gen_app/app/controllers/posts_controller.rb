class PostsController < ApplicationController
  before_action :set_post, only: [:show, :edit, :update, :destroy, :preview]
  after_action :stamp

  def index
    @posts = ["first", "second"]
    render plain: "index #{@posts.size} for #{@viewer} #{new_post_path}"
  end

  def show
    render plain: "show #{@post} #{edit_post_path(@post)} #{post_comments_path(@post)} #{preview_post_path(@post)}"
  end

  def new_action
    render plain: "new #{posts_path} #{search_posts_path}"
  end

  def create
    redirect_to post_path(3), status: :see_other
  end

  def edit
    render plain: "edit #{@post}"
  end

  def update
    redirect_to post_url(@post)
  end

  def destroy
    head :no_content
  end

  def preview
    render plain: "preview #{@post}"
  end

  def search
    render plain: "search #{params[:q]}"
  end

  private

  def set_post
    @post = params[:id].to_s
    raise NotFound, "post #{@post}" if @post == "404"
  end

  def stamp
    response.set_header("X-Action", action_name)
  end
end
