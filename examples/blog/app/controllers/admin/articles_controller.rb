# /admin/articles: the newest articles, each with a delete button. Every
# action is behind AdminGate (ApplicationController#require_admin: 404
# unless BLOG_ADMIN_TOKEN is set and the request proves it).
module Admin
  class ArticlesController < ApplicationController
    include AdminGate

    # GET /admin/articles
    def index
      @articles = Article.order(created_at: :desc).limit(self.class.per_page).includes(:comments).to_a
      @article_count = Article.count
    end

    # DELETE /admin/articles/1 (its comments go first: dependent: :destroy)
    def destroy
      article = Article.find(params[:id])
      article.destroy
      flash[:notice] = "Article was successfully deleted."
      redirect_to admin_articles_path, status: :see_other
    end
  end
end
