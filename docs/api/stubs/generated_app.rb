# Documentation only: never required, never compiled.
#
# `spin run gen` writes per-application code into gen/ (models, relations,
# route helpers), so it is not in the framework's source and YARD would never
# see it. This file describes that code for the API docs, using the classes
# examples/blog generates (compare examples/blog/gen/models/article.rb and
# examples/blog/gen/routes.rb). Every table gets the same surface under its
# own names. Keep the signatures in step with
# cybertrain/generator/models_emitter.rb and routes_emitter.rb.

# What `spin run gen` writes into `gen/models/article.rb` for this table in
# `db/schema.rb` (the {file:docs/api/README.md overview} has the rules for
# every table):
#
#     s.create_table "articles" do |t|
#       t.string "title"
#       t.text "body"
#       t.datetime "created_at", null: false
#       t.datetime "updated_at", null: false
#     end
#
# The class is named after the singular of the table (`articles` → `Article`,
# `blog_posts` → `BlogPost`), with one accessor per column, the finders below
# and an association per foreign key. `app/models/article.rb` reopens it, with
# no superclass, for {Cybertrain::Model.validates validations},
# {Cybertrain::Model.before_save callbacks} and your own methods; never edit
# the generated file.
#
# **Attributes.** Each column has a reader and a writer (`article.title`,
# `article.title = "x"`) holding a Ruby value of the column's type:
#
# | Schema type | Ruby value |
# | --- | --- |
# | `string`, `text` | String (`""` for a new record when `null: false`, else nil) |
# | `integer`, `references` | Integer (`0` when `null: false`, else nil) |
# | `float` | Float |
# | `decimal` | Float, rounded to the column's `scale:` when saved |
# | `boolean` | true / false |
# | `datetime` | Time (UTC), nil until set |
# | `date` | Date (`Date.new(2026, 10, 5)`, stored as `"2026-10-05"`), nil until set |
# | `json` | Hash with String keys (`{}` for a new record when `null: false`, else nil); its values read through `Cybertrain::Cast.int`, `Cast.hash`, `Cast.array` |
#
# `new`, `update` and {#write_attribute} cast what they are given (`"42"`
# becomes `42` for an integer column, `"1"`/`"true"`/`"on"` becomes `true`); the
# plain writer `article.title = ...` does not. A schema `default:` that is a
# plain literal becomes the initial value of a new record.
#
# A column named like a model method or a Ruby keyword (`errors`, `hash`,
# `class`) gets a reader named `<column>_column`, with a note in the
# generated file; queries keep using the SQL name.
#
# **Associations** come from foreign keys only (`t.references :article` in a
# migration, or `add_reference`): the table with the key gets a `belongs_to`
# reader ({Comment#article}), the table it points to a `has_many` reader
# ({#comments}). There is no `has_many`/`belongs_to` to declare, and no
# `has_one`, `:through`, `dependent:` or `includes`.
# @api public
class Article < Cybertrain::Model
  # @!group Class methods (finders)

  # @return [String] the table, `"articles"`
  # @api public
  def self.table_name = "articles"

  # @return [Array<String>] `"id"`, then the SQL column names in schema order
  # @api public
  def self.column_names = ["id", "title", "body", "created_at", "updated_at"]

  # A relation over the whole table; every query starts here or at one of
  # the shortcuts below. Nothing runs until rows are needed.
  # @example
  #   @articles = Article.all.to_a
  # @return [ArticleRelation]
  # @api public
  def self.all = ArticleRelation.new("articles")

  # Every query method of {ArticleRelation} is also a class method, written
  # as `def self.x(...) = all.x(...)`: `where`, `where_like`,
  # `where_between`, `order`, `order_sql`, `limit`, `offset`, `distinct`,
  # `none`, `ids`, `find`, `find_by`, `find_by!`, `find_or_create_by`,
  # `find_or_initialize_by`, `first`, `last`, `count`, `exists?`,
  # `update_all`, `delete_all`, `destroy_all` and `find_each`. The ones
  # documented here are the common ones.
  # @see ArticleRelation#where
  # @example
  #   Article.where(title: "Hello").first
  #   Article.where("created_at >= ?", Time.now - 86_400)
  #   Article.where.not(body: nil)
  # @param cond [Hash{Symbol => Object}, String, nil]
  # @param binds [Array] values for a String condition's `?` placeholders
  # @return [ArticleRelation]
  # @api public
  def self.where(cond = nil, *binds) = all.where(cond, *binds)

  # @see ArticleRelation#where_between
  # @return [ArticleRelation]
  # @api public
  def self.where_between(column, from, to, exclude_end: false) = all.where_between(column, from, to, exclude_end: exclude_end)

  # @see ArticleRelation#where_like
  # @param column [Symbol, String] a column name
  # @param text [String] matched anywhere in the column, wildcards escaped
  # @return [ArticleRelation]
  # @api public
  def self.where_like(column, text) = all.where_like(column, text)

  # @see ArticleRelation#order
  # @param order [String, Symbol, Hash{Symbol => Symbol}] `column [ASC|DESC]`,
  #   comma-separated, or `{ column: :asc | :desc }`
  # @return [ArticleRelation]
  # @api public
  def self.order(order) = all.order(order)

  # @see ArticleRelation#order_sql
  # @param sql [String] raw ORDER BY text; never request data
  # @return [ArticleRelation]
  # @api public
  def self.order_sql(sql) = all.order_sql(sql)

  # @see ArticleRelation#limit
  # @param n [Integer]
  # @return [ArticleRelation]
  # @api public
  def self.limit(n) = all.limit(n)

  # The record with this id.
  # @example
  #   @article = Article.find(params[:id])
  # @param id [Integer, String] a String (such as `params[:id]`) is compared
  #   as SQLite compares it with the integer column
  # @return [Article]
  # @raise [Cybertrain::RecordNotFound] `"Couldn't find Article with id=..."`
  # @api public
  def self.find(id) = all.find(id)

  # The first record matching the conditions (by id), or nil.
  # @example
  #   Article.find_by(title: "Hello")
  # @param conditions [Hash{Symbol => Object}]
  # @return [Article, nil]
  # @api public
  def self.find_by(conditions) = all.find_by(conditions)

  # @see ArticleRelation#find_by!
  # @return [Article]
  # @raise [Cybertrain::RecordNotFound] `"Couldn't find Article"`
  # @api public
  def self.find_by!(conditions) = all.find_by!(conditions)

  # @return [Article, nil] the record with the lowest id
  # @api public
  def self.first = all.first

  # @return [Article, nil] the record with the highest id
  # @api public
  def self.last = all.last

  # @return [Integer] the number of rows in the table
  # @api public
  def self.count = all.count

  # Builds a record and saves it. Returns the record whether or not it was
  # saved: check {Cybertrain::Model#persisted? persisted?} or
  # {Cybertrain::Model#errors errors}, or use {.create!}.
  # @example
  #   article = Article.create(title: "Hello", body: "A body long enough")
  #   article.persisted?  # => true
  # @param attrs [Hash{String, Symbol => Object}]
  # @return [Article]
  # @api public
  def self.create(attrs = {})
    rec = Article.new(attrs)
    rec.save
    rec
  end

  # Builds a record and saves it with {Cybertrain::Model#save! save!}.
  # @param attrs [Hash{String, Symbol => Object}]
  # @return [Article] the saved record
  # @raise [Cybertrain::RecordInvalid] when validation fails
  # @api public
  def self.create!(attrs = {})
    rec = Article.new(attrs)
    rec.save!
    rec
  end

  # @!endgroup

  # A new, unsaved record. Keys may be Strings or Symbols; values are cast
  # to the column types; unknown keys and `id` are ignored.
  # @example
  #   Article.new(title: "Hello")
  #   Article.new(params.require(:article).permit(:title, :body))
  # @param attrs [Hash{String, Symbol => Object}]
  # @api public
  def initialize(attrs = {}); end

  # The `title` column (`t.string "title"`).
  # @return [String, nil]
  # @api public
  attr_accessor :title

  # The `body` column (`t.text "body"`).
  # @return [String, nil]
  # @api public
  attr_accessor :body

  # Set by the first {Cybertrain::Model#save save} when nil.
  # @return [Time, nil]
  # @api public
  attr_accessor :created_at

  # Set by every {Cybertrain::Model#save save}.
  # @return [Time, nil]
  # @api public
  attr_accessor :updated_at

  # @return [String] `"Article"`
  # @api public
  def model_name = "Article"

  # The value of a column by name, the way templates read it.
  # @param name [Symbol] the SQL column name (or `:id`); a String gives nil
  # @return [Object, nil] nil for an unknown name
  # @api public
  def read_attribute(name); end

  # Sets a column by name, casting the value to the column's type. Unknown
  # names and `:id` are ignored.
  # @param name [Symbol]
  # @param value [Object]
  # @return [nil]
  # @api public
  def write_attribute(name, value); end

  # {#write_attribute} for each pair.
  # @param attrs [Hash{String, Symbol => Object}]
  # @return [self]
  # @api public
  def assign_attributes(attrs); end

  # `has_many`, from the foreign key `comments.article_id`: this article's
  # comments, by id. A fresh query on every call; it returns an Array, so
  # filter with {Comment.where} instead when you need more than all of them.
  # When two foreign keys of one table point here, each reader is named
  # `<table>_as_<key stem>` (`messages_as_sender`).
  # @example
  #   <% @article.comments.each do |comment| %>
  # @return [Array<Comment>]
  # @api public
  def comments = CommentRelation.new("comments").where(article_id: @id).to_a
end

# The relation `spin run gen` writes next to each model (`ArticleRelation`
# for `Article`): the chainable query methods and the methods that load
# records. Start one with {Article.all} or a shortcut such as
# {Article.where}. The chain methods change this relation and return it.
# @example
#   Article.where(title: "Hello").order("created_at DESC").limit(5).to_a
#   Comment.where(article_id: @article.id).count
# @api public
class ArticleRelation < Cybertrain::Relation
  # The schema type of a column: `:integer` (`"id"` included), `:float`,
  # `:decimal`, `:boolean`, `:datetime`, `:date`, `:json`, `:binary`,
  # `:string` or `:text`; `:unknown` for a name that is not a column.
  # @example
  #   Article.all.column_type("title") # => :string
  # @param name [String] the SQL column name
  # @return [Symbol]
  # @api public
  def column_type(name); end

  # A decimal column's `scale:`; -1 for any other column or a decimal
  # declared without one.
  # @param name [String] the SQL column name
  # @return [Integer]
  # @api public
  def decimal_scale(name) = -1

  # Adds conditions, AND-ed with any already there. With a Hash, keys are
  # SQL column names and values are bound, never interpolated:
  #
  # | Value | SQL |
  # | --- | --- |
  # | `nil` | `` `col` IS NULL `` |
  # | an Array | `` `col` IN (?, ?) `` (an empty Array matches nothing) |
  # | an Integer Range `1..5` | `` `col` BETWEEN ? AND ? `` |
  # | `1...5`, `5..`, `..5` | `` `col` >= ? AND `col` < ? ``, `` `col` >= ? ``, `` `col` <= ? `` |
  # | a Time | `` `col` = ? `` with the stored datetime text |
  # | `true` / `false` | `` `col` = ? `` with 1 / 0 |
  # | anything else | `` `col` = ? `` |
  #
  # A Range takes Integer ends only; other bounds (Time, Date, Float,
  # String) go through {#where_between}. A json column cannot be compared
  # (ArgumentError). With a String, it is a raw SQL condition with `?`
  # placeholders and the binds after it, as {#where_sql}, wrapped in
  # parentheses so an `OR` in it stays inside; an Array bind raises (use the
  # Hash form for `IN`). With no argument it is the relation itself, so
  # `where.not(...)` reads as in Rails; any other argument raises.
  # @example
  #   Article.where(title: ["Hello", "Bye"]).where(body: nil)
  #   Article.where("created_at >= ?", Time.now - 86_400)
  #   Article.where.not(body: nil)
  # @param cond [Hash{Symbol => Object}, String, nil]
  # @param binds [Array] one value per `?` of a String condition
  # @return [self]
  # @raise [ArgumentError] for a json column, an Array bind, or a `cond`
  #   that is neither nil, a Hash nor a String
  # @api public
  def where(cond = nil, *binds); end

  # The negation of {#where}'s Hash form, AND-ed with the other conditions:
  # `NOT (a AND b)` over the terms `where` would write (Rails 6.1+). So
  # `where.not(body: nil)` is `NOT (`body` IS NULL)`, `where.not(id: [])`
  # matches every row, and `where.not(kind: "a")` leaves out NULL kinds,
  # as SQL's `!=` does.
  # @example
  #   Article.where.not(title: "Draft")
  # @param conditions [Hash{Symbol => Object}]
  # @return [self]
  # @api public
  def not(conditions) = (add_where_not(conditions); self)

  # A bounded range on one column: `` `col` >= ? AND `col` <= ? `` (`<` with
  # `exclude_end: true`), either bound nil for an open end. A Time or Date
  # bound is compared as the stored text, which orders as the instant does.
  # @example
  #   Article.where_between(:created_at, Time.now - 86_400, nil)
  # @param column [Symbol, String] a column name
  # @param from [Integer, Float, String, Time, Date, nil]
  # @param to [Integer, Float, String, Time, Date, nil]
  # @return [self]
  # @raise [ArgumentError] when both bounds are nil, `column` is not a
  #   column name, or it is a json column
  # @api public
  def where_between(column, from, to, exclude_end: false) = (add_where_between(column, from, to, exclude_end); self)

  # Rows matching this relation's conditions or the other's: one
  # `((a) OR (b))` term. A side with no conditions matches every row.
  # @example
  #   Article.where(title: "Hello").or(Article.where(body: nil))
  # @param other [ArticleRelation]
  # @return [self]
  # @raise [ArgumentError] `"or: the relations differ in order, limit,
  #   offset or distinct"`
  # @api public
  def or(other) = (merge_or(other); self)

  # Adds a raw SQL condition with `?` placeholders, AND-ed with the others.
  # The fragment is used as written, in parentheses: never build it from
  # request data; pass values as binds (one value per `?`; an Array bind
  # raises ArgumentError).
  # @example
  #   Article.all.where_sql("created_at >= ?", [Time.now - 86_400])
  # @param sql [String]
  # @param binds [Array] one value per `?`
  # @return [self]
  # @api public
  def where_sql(sql, binds = []) = (add_where_sql(sql, binds); self)

  # Adds a substring match on one column, AND-ed with the others:
  # `` `col` LIKE ? ESCAPE '\' `` with `%text%` bound, the text's `\`, `%`
  # and `_` escaped ({Cybertrain::Cast.like_escape}), so a search box's
  # input is matched literally. Case-insensitive for ASCII, as SQLite's
  # LIKE is; NULL never matches. A prefix search writes its own pattern
  # through {#where_sql}.
  # @example
  #   Article.where_like(:title, params[:q].to_s).order("title").to_a
  #   prefix = Cybertrain::Cast.like_escape(params[:q].to_s) + "%"
  #   Article.all.where_sql("title LIKE ? ESCAPE '\\'", [prefix])
  # @param column [Symbol, String] a column name
  # @param text [String]
  # @return [self]
  # @raise [ArgumentError] when `column` is not a column name
  # @api public
  def where_like(column, text) = (add_where_like(column, text); self)

  # Sets the order, replacing any earlier one. Takes only comma-separated
  # `column [ASC|DESC]` terms (a Symbol is a column name; nil or `""`
  # removes the order). Request data must go through an allowlist first,
  # since even a well-formed term can name a column the client must not
  # sort by.
  # @example
  #   Article.order("created_at DESC, id")
  #   SORTS = { "title" => "title", "newest" => "created_at DESC" }
  #   Article.order(SORTS.fetch(params[:sort].to_s, "id"))
  #   Article.order(created_at: :desc, id: :asc)
  # @param order [String, Symbol, Hash{Symbol => Symbol}, nil] a Hash maps
  #   each column to `:asc` or `:desc`
  # @return [self]
  # @raise [ArgumentError] for anything else (`lower(title)`,
  #   `articles.title`): use {#order_sql} for raw SQL
  # @api public
  def order(order); end

  # Sets a raw ORDER BY fragment, replacing any earlier order. Never pass
  # request data. {#last} reverses it by flipping ASC/DESC around commas,
  # which can mangle text such as `COALESCE(a, b)`.
  # @example
  #   Article.order_sql("lower(title)")
  # @param sql [String]
  # @return [self]
  # @api public
  def order_sql(sql) = (add_order_sql(sql); self)

  # @param n [Integer] at most this many rows; `0` returns none
  # @return [self]
  # @api public
  def limit(n) = (set_limit(n); self)

  # @param n [Integer] skip this many rows (works without a {#limit})
  # @return [self]
  # @api public
  def offset(n) = (set_offset(n); self)

  # `SELECT DISTINCT`: the column readers return each value once
  # (`distinct.pluck_str(:kind)`, `ids`). A row of `SELECT *` carries its
  # id, so every row is distinct and {Cybertrain::Relation#count count}
  # (and `to_a`) of a distinct relation is the same as without it.
  # @return [self]
  # @api public
  def distinct = (set_distinct; self)

  # A relation that matches no row: `count`, `exists?`, `update_all` and
  # `delete_all` answer 0 / false without a query, the readers are empty.
  # @return [self]
  # @api public
  def none = (set_none; self)

  # Runs the query. Templates iterate an Array, so controllers usually
  # end a query with `to_a`.
  # @example
  #   @articles = Article.all.to_a
  # @return [Array<Article>]
  # @api public
  def to_a; end

  # `to_a.each`.
  # @yieldparam article [Article]
  # @api public
  def each(&blk) = to_a.each(&blk)

  # The first record by the relation's order (by id when it has none),
  # from the {#offset} on.
  # @return [Article, nil]
  # @api public
  def first; end

  # Without a limit or offset, the first record of the reversed order (the
  # highest id when there is no order); with them, the last record of that
  # window.
  # @return [Article, nil]
  # @api public
  def last; end

  # `where(conditions).first`. Like every chain method, it narrows this
  # relation itself.
  # @param conditions [Hash{Symbol => Object}]
  # @return [Article, nil]
  # @api public
  def find_by(conditions) = where(conditions).first

  # {#find_by}, raising when nothing matches.
  # @param conditions [Hash{Symbol => Object}]
  # @return [Article]
  # @raise [Cybertrain::RecordNotFound] `"Couldn't find Article"`
  # @api public
  def find_by!(conditions); end

  # {#find_by}, or else {Article.create} with the same attributes.
  # @example
  #   Tag.find_or_create_by(name: "ruby")
  # @param conditions [Hash{Symbol => Object}]
  # @return [Article]
  # @api public
  def find_or_create_by(conditions); end

  # {#find_by}, or else an unsaved {Article#initialize Article.new} with the same attributes.
  # @param conditions [Hash{Symbol => Object}]
  # @return [Article]
  # @api public
  def find_or_initialize_by(conditions); end

  # Loads the matching records and calls {Cybertrain::Model#destroy destroy}
  # on each, so the destroy callbacks run (one DELETE per record; use
  # {Cybertrain::Relation#delete_all delete_all} for one statement).
  # @return [Array<Article>] the destroyed records
  # @api public
  def destroy_all; end

  # Yields every matching record, loading `batch` rows at a time
  # (`id > last_id ORDER BY id LIMIT batch`), so a large table is walked
  # without loading it whole. Records come in id order; the relation's own
  # order, limit and offset are not used.
  # @example
  #   Article.where(body: nil).find_each(batch: 500) { |a| a.update_columns(body: "") }
  # @param batch [Integer] rows per query, at least 1
  # @yieldparam article [Article]
  # @return [nil]
  # @api public
  def find_each(batch: 1000, &blk); end

  # The record with this id within the relation.
  # @example
  #   Comment.where(article_id: @article.id).find(params[:id])
  # @param id [Integer, String]
  # @return [Article]
  # @raise [Cybertrain::RecordNotFound]
  # @api public
  def find(id); end

  # Same as {Cybertrain::Relation#count count}.
  # @return [Integer]
  # @api public
  def size = count
end

# The other side of {Article#comments}: what `spin run gen` writes for a
# `comments` table with `t.references :article` (an `article_id` column and
# a foreign key to `articles`). It has the same finders as {Article}, through
# `CommentRelation`.
# @api public
class Comment < Cybertrain::Model
  # @return [CommentRelation]
  # @api public
  def self.all = CommentRelation.new("comments")

  # @param cond [Hash{Symbol => Object}, String, nil]
  # @return [CommentRelation]
  # @api public
  def self.where(cond = nil, *binds) = all.where(cond, *binds)

  # @return [String, nil]
  # @api public
  attr_accessor :commenter

  # @return [String, nil]
  # @api public
  attr_accessor :body

  # The foreign key; `0` until set (`references` columns are `null: false`).
  # @return [Integer]
  # @api public
  attr_accessor :article_id

  # `belongs_to`, from the foreign key `article_id`: the article, or nil
  # when there is none. A fresh query on every call. When a column already
  # has the name, the reader is `<stem>_as_<column>` (`author_as_author_id`).
  # @return [Article, nil]
  # @api public
  def article = Article.find_by(id: @article_id)
end

# The relation for {Comment}; the same methods as {ArticleRelation}.
# @api public
class CommentRelation < Cybertrain::Relation
end

module Gen
  # The `*_path` and `*_url` helpers `spin run gen` writes into
  # `gen/routes.rb`, one pair per named route in `config/routes.rb`. They are
  # included into every controller and resolved by name in templates. These
  # are the ones examples/blog's routes generate:
  #
  #     Cybertrain::Routes.draw do
  #       root "articles#index"
  #       resources :articles do |articles|
  #         articles.resources :comments, only: [:create, :destroy]
  #       end
  #     end
  #
  # Arguments are positional, one per `:param` in the path: a record (its
  # {Cybertrain::Model#to_param to_param}, the id), an Integer or a String,
  # percent-encoded as one segment. nil raises `ArgumentError "missing route
  # parameter"`. There is no hash form and no query-string option; append
  # `"?page=2"` yourself. `*_url` prepends {Cybertrain.url_root}.
  #
  # See {Cybertrain::Routes.draw} for the names each route gets.
  # @api public
  module UrlHelpers
    # @return [String] `"/"`
    # @api public
    def root_path = "/"

    # @return [String] `"/articles"`
    # @api public
    def articles_path = "/articles"

    # @return [String] {Cybertrain.url_root} + `"/articles"`
    # @api public
    def articles_url = Cybertrain.url_root + articles_path

    # @return [String] `"/articles/new"`
    # @api public
    def new_article_path = "/articles/new"

    # @example
    #   redirect_to article_path(@article), status: :see_other
    # @param article [Cybertrain::Model, Integer, String]
    # @return [String] `"/articles/1"`
    # @api public
    def article_path(article); end

    # @param article [Cybertrain::Model, Integer, String]
    # @return [String] `"/articles/1/edit"`
    # @api public
    def edit_article_path(article); end

    # The nested collection: one argument per level.
    # @param article [Cybertrain::Model, Integer, String]
    # @return [String] `"/articles/1/comments"`
    # @api public
    def article_comments_path(article); end

    # The nested member.
    # @param article [Cybertrain::Model, Integer, String]
    # @param comment [Cybertrain::Model, Integer, String]
    # @return [String] `"/articles/1/comments/2"`
    # @api public
    def article_comment_path(article, comment); end
  end
end
