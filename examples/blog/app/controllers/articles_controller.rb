require "cybertrain/cache"

class ArticlesController < ApplicationController
  before_action :set_article, only: [:show, :edit, :update, :destroy]

  # GET /articles (?from=YYYY-MM-DD&to=YYYY-MM-DD, either end optional)
  # Newest first, each article's comments preloaded for the Comments
  # column (two queries, however many articles), and the number of
  # articles above them from the cache. A date that does not parse is
  # ignored; `to` takes in the whole of its day.
  def index
    from_date = Cybertrain::Cast.date_or_nil(params[:from])
    to_date = Cybertrain::Cast.date_or_nil(params[:to])
    @from = from_date.nil? ? nil : params[:from]
    @to = to_date.nil? ? nil : params[:to]
    articles = Article.recent.includes(:comments)
    unless from_date.nil? && to_date.nil?
      from_time = from_date.nil? ? nil : Time.utc(from_date.year, from_date.month, from_date.day)
      to_time = to_date.nil? ? nil : Time.utc(to_date.year, to_date.month, to_date.day) + 86_400
      articles = articles.where_between(:created_at, from_time, to_time, exclude_end: true)
    end
    @articles = articles.to_a
    # Kept in cybertrain_cache for a minute: an article created meanwhile
    # shows up in the list at once and in the count within the minute.
    @article_count = Cybertrain::Cache.fetch_int("articles/count", expires_in: 60) { Article.count }
  end

  # GET /articles/1
  def show
    @comment = Comment.new
  end

  # GET /articles/new
  # (named new_action: a `new` method would shadow ArticlesController.new)
  def new_action
    @article = Article.new
  end

  # GET /articles/1/edit
  def edit
  end

  # POST /articles
  def create
    @article = Article.new(article_params)
    if @article.save
      flash[:notice] = "Article was successfully created."
      redirect_to article_path(@article), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /articles/1
  def update
    if @article.update(article_params)
      flash[:notice] = "Article was successfully updated."
      redirect_to article_path(@article), status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /articles/1
  def destroy
    @article.destroy
    flash[:notice] = "Article was successfully destroyed."
    redirect_to articles_path, status: :see_other
  end

  private

  def set_article
    @article = Article.find(params[:id])
  end

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
