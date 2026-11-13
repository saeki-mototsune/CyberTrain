class ArticlesController < ApplicationController
  def index
    render plain: "#{Article.count} articles"
  end

  def show
    article = Article.find(params[:id])
    render plain: "<h1>#{article.title}</h1>"
  end

  def create
    user = User.first
    attrs = params.require(:article).permit(:title)
    article = Article.new(title: attrs["title"].to_s, user_id: user.nil? ? 0 : user.id)
    if article.save
      redirect_to article_path(article)
    else
      render plain: "invalid", status: :unprocessable_entity
    end
  end
end
