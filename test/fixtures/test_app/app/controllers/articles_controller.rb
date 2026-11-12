class ArticlesController < ApplicationController
  def show
    article = Article.find(params[:id].to_i)
    render plain: "#{article.title} by #{article.author.name}"
  end
end
