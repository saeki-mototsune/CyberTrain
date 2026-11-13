require "cybertrain/cache"

class ArticlesController < ApplicationController
  # Anyone may read an article and fetch its cover; writing, editing and
  # deleting (a cover is attached by create and update) need a signed-in
  # user (the Authentication concern's require_authentication). The
  # article page links to /admin/articles for an admin
  # (ApplicationController#admin?).
  allow_unauthenticated_access only: [:index, :show, :cover]
  before_action :set_article, only: [:show, :edit, :update, :destroy, :cover]

  # GET /articles/1/cover -- @article comes from before_action :set_article, so
  # the download is scoped exactly like show: whoever may read the article
  # (anyone, signed in or not) may fetch its cover, so :cover is in
  # allow_unauthenticated_access beside :show. show's own body (a blank
  # comment for the form) decides nothing about who may read.
  # send_blob is the one way to serve uploads: it sets the type from what the
  # server detected, nosniff, a locked-down CSP and Content-Disposition
  # (inline for images only, a download otherwise).
  def cover
    if @article.cover_attached? && Cybertrain::BlobStore.exist?(@article.cover_key)
      send_blob(Cybertrain::BlobStore.read(@article.cover_key), filename: @article.cover_filename, content_type: @article.cover_content_type)
    else
      head 404
    end
  end

  # GET /articles (?from=YYYY-MM-DD&to=YYYY-MM-DD, either end optional;
  # ?order=old for the oldest first), and /articles.json
  # Newest first, each article's comments preloaded for the Comments
  # column (two queries, however many articles), and the number of
  # articles above them from the cache. A date that does not parse is
  # ignored; `to` takes in the whole of its day.
  def index
    from_date = Cybertrain::Cast.date_or_nil(params[:from])
    to_date = Cybertrain::Cast.date_or_nil(params[:to])
    @from = from_date.nil? ? nil : params[:from]
    @to = to_date.nil? ? nil : params[:to]
    @order = params[:order] == "old" ? "old" : "new"
    articles = @order == "old" ? Article.order(created_at: :asc) : Article.recent
    articles = articles.includes(:comments)
    unless from_date.nil? && to_date.nil?
      from_time = from_date.nil? ? nil : Time.utc(from_date.year, from_date.month, from_date.day)
      to_time = to_date.nil? ? nil : Time.utc(to_date.year, to_date.month, to_date.day) + 86_400
      articles = articles.where_between(:created_at, from_time, to_time, exclude_end: true)
    end
    @articles = articles.to_a
    # Kept in cybertrain_cache for a minute: an article created meanwhile
    # shows up in the list at once and in the count within the minute.
    @article_count = Cybertrain::Cache.fetch_int("articles/count", expires_in: 60) { Article.count }
    respond_to do |format|
      format.html
      format.json { render json: @articles.map { |article| article.public_json } }
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
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.save
      flash[:notice] = t(".created")
      redirect_to article_path(@article), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /articles/1
  def update
    @article.cover_file = params.nested(:article).upload(:cover)
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
    params.require(:article).permit(:title, :body)
  end
end
