# /admin/articles: the newest articles, each with a delete button; 404
# unless the signed-in user is an admin (a visitor is sent to sign in).
module Admin
  class ArticlesController < ApplicationController
    before_action :require_admin

    # GET /admin/articles
    def index
      @articles = Article.order(created_at: :desc).limit(20).includes(:comments).to_a
      @article_count = Article.count
    end

    # DELETE /admin/articles/1 (its comments go first: dependent: :destroy)
    def destroy
      Article.find(params[:id]).destroy
      flash[:notice] = t(".deleted")
      redirect_to admin_articles_path, status: :see_other
    end

    private

    def require_admin
      render plain: "Not Found", status: :not_found unless admin?
    end
  end
end
