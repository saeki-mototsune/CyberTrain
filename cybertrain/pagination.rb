# Cybertrain::Page -- where one page of a list sits, for {Relation#page}
# and the `paginate` template helper.
require "cybertrain/params"

module Cybertrain
  # One page of an offset-paginated list: its 1-based number, its size, and
  # whether a newer (previous) and an older (next) page exist.
  # {Relation#page} returns it and windows the relation to the page's rows,
  # which `to_a` / `each` then load as typed records:
  #
  #     @articles = Article.order("created_at DESC")
  #     @page = @articles.page(params.page_number, per: 20)
  #     # @articles.each { |a| ... } -- at most 20 Articles
  #
  # The rows are not on the Page: a typed `Page#rows` would need a Page
  # class per model (generated, like ArticleRelation), while the relation
  # already returns typed records.
  #
  # In a template, `<%= paginate @page, articles_path %>` renders the
  # Newer / Older links; `@page.number`, `@page.next?`, `@page.prev?`,
  # `@page.per` and `@page.row_offset` can be read too.
  # @api public
  class Page
    # The largest `per:` {Relation#page} takes.
    MAX_PER = 1000

    # @return [Integer] the page's number, from 1
    # @api public
    attr_reader :number

    # @return [Integer] the most rows on one page
    # @api public
    attr_reader :per

    # Named row_offset, not offset: the relations' `offset(n)` returns a
    # relation, and one method name with two return types corrupts
    # inference under Spinel (spikes/NOTES.md rule 34).
    # @return [Integer] how many rows come before this page, `(number - 1) * per`
    # @api public
    attr_reader :row_offset

    # @param number [Integer] from 1
    # @param per [Integer]
    # @param more [Boolean] whether a row exists past this page
    def initialize(number, per, more)
      @number = number
      @per = per
      @row_offset = (number - 1) * per
      @more = more
    end

    # @return [Boolean] true when an older page (number + 1) has rows
    # @api public
    def next?
      @more
    end

    # @return [Boolean] true when this is not the first page
    # @api public
    def prev?
      @number > 1
    end

    # @return [Integer] the next page's number (whether or not it exists)
    # @api public
    def next_number
      @number + 1
    end

    # @return [Integer] the previous page's number, never below 1
    # @api public
    def prev_number
      @number > 1 ? @number - 1 : 1
    end

    # n clamped to 1..max: a page number from code (Params#page_number is
    # already clamped). Not named clamp: a method defined with a builtin's
    # name changes how every boxed call of that name compiles (NOTES rule 62).
    def self.clamp_number(n, max)
      return 1 if n < 1
      return max if n > max

      n
    end
  end
end
