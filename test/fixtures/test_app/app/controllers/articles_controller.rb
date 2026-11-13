class ArticlesController < ApplicationController
  def index
    render plain: Article.order(id: :asc).to_a.map { |a| a.title }.join(",")
  end

  def show
    article = Article.find(params[:id].to_i)
    render plain: "#{article.title} by #{article.author.name}"
  end

  def new_action
    @article = Article.new
  end

  def create
    article = Article.new(params.require(:article).permit(:title, :body, :author_id))
    if article.save
      # Every page subscribed with `turbo_stream_from "articles"` appends the title.
      Cybertrain::Stream.broadcast_append_to("articles", target: "articles", html: article.title)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.append("articles", html: article.title) }
        format.html { redirect_to article_path(article), status: :see_other }
      end
    else
      head :unprocessable_entity
    end
  end
end
