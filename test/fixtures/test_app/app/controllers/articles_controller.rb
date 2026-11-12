class ArticlesController < ApplicationController
  def index
    render plain: Article.order(id: :asc).to_a.map { |a| a.title }.join(",")
  end

  def show
    article = Article.find(params[:id].to_i)
    render plain: "#{article.title} by #{article.author.name}"
  end

  def create
    article = Article.new(params.require(:article).permit(:title, :body, :author_id))
    if article.save
      redirect_to article_path(article), status: :see_other
    else
      head :unprocessable_entity
    end
  end
end
