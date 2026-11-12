# /admin/articles: the newest articles, each with a delete button. Every
# action is behind AdminGate (the Authentication concern's require_admin:
# 404 unless the signed-in user is an admin; require_authentication sends
# a visitor to sign in first).
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
      flash[:notice] = t(".deleted")
      redirect_to admin_articles_path, status: :see_other
    end
  end
end
