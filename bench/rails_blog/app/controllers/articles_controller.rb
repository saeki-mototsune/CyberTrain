class ArticlesController < ApplicationController
  # Anyone may read an article; writing, editing and deleting need a
  # signed-in user (the Authentication concern's require_authentication).
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]

  # GET /articles (?from=YYYY-MM-DD&to=YYYY-MM-DD, either end optional;
  # ?order=old for the oldest first), and /articles.json
  # Newest first, each article's comments preloaded for the Comments
  # column (two queries, however many articles), and the number of
  # articles above them from the cache. A date that does not parse is
  # ignored; `to` takes in the whole of its day.
  def index
    from_date = date_or_nil(params[:from])
    to_date = date_or_nil(params[:to])
    @from = from_date.nil? ? nil : params[:from]
    @to = to_date.nil? ? nil : params[:to]
    @order = params[:order] == "old" ? "old" : "new"
    articles = @order == "old" ? Article.order(created_at: :asc) : Article.recent
    articles = articles.includes(:comments)
    unless from_date.nil? && to_date.nil?
      from_time = from_date.nil? ? nil : Time.utc(from_date.year, from_date.month, from_date.day)
      to_time = to_date.nil? ? nil : Time.utc(to_date.year, to_date.month, to_date.day) + 1.day
      articles = articles.where(created_at: from_time...to_time)
    end
    @articles = articles.to_a
    # Kept in Solid Cache for a minute: an article created meanwhile shows
    # up in the list at once and in the count within the minute.
    @article_count = Rails.cache.fetch("articles/count", expires_in: 1.minute) { Article.count }
    respond_to do |format|
      format.html
      format.json { render json: @articles.map(&:public_json) }
    end
  end

  # GET /articles/1, and /articles/1.json
  def show
    @comment = Comment.new
    respond_to do |format|
      format.html
      format.json { render json: @article.public_json }
    end
  end

  # GET /articles/new
  def new
    @article = Article.new
  end

  # GET /articles/1/edit
  def edit
  end

  # POST /articles
  def create
    @article = Article.new(article_params)
    if @article.save
      flash[:notice] = t(".created")
      redirect_to article_path(@article), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /articles/1
  def update
    if @article.update(article_params)
      flash[:notice] = t(".updated")
      redirect_to article_path(@article), status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /articles/1
  def destroy
    @article.destroy
    flash[:notice] = t(".destroyed")
    redirect_to articles_path, status: :see_other
  end

  private

  def set_article
    @article = Article.find(params[:id])
  end

  def article_params
    params.require(:article).permit(:title, :body, :cover)
  end

  # A YYYY-MM-DD date, or nil for anything else.
  def date_or_nil(value)
    text = value.to_s
    return nil unless text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(text)
  rescue Date::Error
    nil
  end
end
