require "cybertrain/cast"
require "cybertrain/ident"
require "cybertrain/db"

module Cybertrain
  # A lazily built SELECT over one table: nothing runs until a method that
  # needs rows ({#count}, {#exists?}, `to_a`, `first`, `each`, ...).
  #
  # Each generated model gets its own subclass, `<Model>Relation`, which adds
  # the chainable query methods (`where`, `where_sql`, `order`, `order_sql`,
  # `limit`, `offset`) and the methods that return records (`to_a`, `each`,
  # `first`, `last`, `find`, `find_by`, `size`); see {ArticleRelation}. The
  # methods documented here are the ones every relation shares.
  #
  # The chain methods change the relation they are called on and return it
  # (they do not copy it), so keep one relation per query:
  #
  #     scope = Comment.where(article_id: article.id)
  #     recent = scope.order("created_at DESC").limit(10).to_a
  #     # scope itself is now ordered and limited too
  #
  # Implementation: the subclass's chain methods wrap the setters below and
  # return self, so `Post.where(...).first` is typed Post|nil: a base-class
  # method that returned self would be typed as the base (spikes/NOTES.md
  # rule 5), which is why these setters return nil.
  # @api public
  class Relation
    attr_reader :binds

    # NOTE: blocks passed to Cybertrain::DB.with below read locals, never
    # ivars: an ivar inside such a block compiles to C with no receiver.

    def initialize(table)
      @table = table
      @wheres = Array.new(0) { "" }
      # Binds hold nil/Integer/Float/String: seed with more than one type so
      # the Array is polymorphic from the start (rule 9).
      @binds = [nil, 0, 0.0, ""]
      @binds.clear
      @order = ""
      @limit = -1
      @offset = 0
    end

    # Table and column names are backtick-quoted in every generated fragment
    # so a column named after an SQL keyword (order, group, on) still works.
    # Backticks, not double quotes: SQLite falls back to reading an unknown
    # "name" as the string literal 'name' (a misspelled key would then match
    # silently), while an unknown `name` is a "no such column" error.
    # Raw fragments (where_sql, order_sql) are the caller's SQL and stay as given.
    #
    # where(title: "x")    -> `title` = ?
    # where(body: nil)     -> `body` IS NULL
    # where(id: [1, 2])    -> `id` IN (?, ?)
    def add_where(hash)
      hash.each do |key, value|
        column = Relation.quote_ident(key.to_s)
        case value
        when nil
          @wheres << "#{column} IS NULL"
        when Time
          # Before `when Array`: a Time in a poly slot matches Array (rule 8).
          @wheres << "#{column} = ?"
          @binds << Cast.to_sql(value)
        when Array
          if value.empty?
            @wheres << "1 = 0"
          else
            marks = Array.new(value.size) { "?" }
            @wheres << "#{column} IN (#{marks.join(", ")})"
            value.each { |v| @binds << Cast.to_sql(v) }
          end
        else
          @wheres << "#{column} = ?"
          @binds << Cast.to_sql(value)
        end
      end
      nil
    end

    # A raw SQL fragment with its own `?` binds: where_sql("views > ?", [10]).
    def add_where_sql(sql, binds)
      @wheres << sql
      binds.each { |v| @binds << Cast.to_sql(v) }
      nil
    end

    # order("title DESC, id"): a comma-separated list of `column [ASC|DESC]`,
    # each column quoted. Anything else (expressions, functions, a stray
    # `;`) raises ArgumentError. The order string is the DEVELOPER's (an
    # allowlisted value, a literal), so a bad one is a programmer error and
    # a 500 at error level, not a 400: it is not the client's fault. Request
    # data must never reach `order` unvalidated, because even a well-formed
    # term can name a column that does not exist (a DB::Error, a 500) or a
    # secret column (ordering by it leaks the values' relative order). Only
    # an allowlist is safe: Post.order(SORTS.fetch(params[:sort].to_s, "id")).
    # The term is shown with String#inspect (identical on both runtimes), so
    # a decoded newline in it cannot forge a log line. Raw ORDER BY text goes
    # through add_order_sql (the models' `order_sql`). A Symbol is taken as
    # its name (order(:title) is the common Rails spelling; the column still
    # goes through Ident.column?) and nil as no order. One to_s up front, so
    # a non-String never reaches `strip` as a NoMethodError.
    def set_order(order)
      stripped = order.to_s.strip
      if stripped == ""
        @order = ""
        return nil
      end
      terms = Array.new(0) { "" }
      # split drops trailing empty strings, so "title," needs this check; a
      # leading comma yields an empty first term the loop rejects itself.
      if stripped.end_with?(",")
        raise ArgumentError, "order: #{stripped.inspect} is not `column [ASC|DESC]` (use order_sql for raw SQL)"
      end
      stripped.split(",").each do |fragment|
        term = fragment.strip
        words = term.split(" ")
        bad = words.size == 0 || words.size > 2 || !Ident.column?(words[0])
        dir = words.size == 2 ? words[1].upcase : ""
        bad = true if dir != "" && dir != "ASC" && dir != "DESC"
        if bad
          raise ArgumentError, "order: #{term.inspect} is not `column [ASC|DESC]` " \
                               "(use order_sql for raw SQL)"
        end
        quoted = Relation.quote_ident(words[0])
        terms << (dir == "" ? quoted : "#{quoted} #{dir}")
      end
      @order = terms.join(", ")
      nil
    end

    # A raw ORDER BY fragment, stored verbatim: order_sql("lower(title) DESC").
    # Never pass request data here. `last` reverses the order by splitting on
    # commas and flipping ASC/DESC (Relation.reverse_order), which is right for
    # `order` output but can mangle raw text with commas inside parentheses
    # (`COALESCE(a, b)`); call `order_sql` with the reversed text yourself then.
    def add_order_sql(sql)
      @order = sql
      nil
    end

    def set_limit(n)
      @limit = n
      nil
    end

    def set_offset(n)
      @offset = n
      nil
    end

    # The SELECT this relation runs, with `?` placeholders (see `binds`).
    # Handy in a test or a log line.
    # @return [String]
    # @api public
    def to_sql
      select_sql("*", @order, @limit, @offset)
    end

    def rows
      sql = to_sql
      binds = @binds
      Cybertrain::DB.with { |c| c.execute(sql, binds) }
    end

    # Counts the rows the relation would return: with a limit or offset the
    # count runs over the windowed subquery (Post.limit(2).count is 2).
    # @example
    #   Comment.where(article_id: article.id).count
    # @return [Integer]
    # @api public
    def count
      sql = if @limit >= 0 || @offset > 0
              "SELECT COUNT(*) AS n FROM (#{select_sql("1", "", @limit, @offset)})"
            else
              select_sql("COUNT(*) AS n", "", -1, 0)
            end
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      Cast.int(found[0]["n"])
    end

    # Whether the relation matches any row (a `SELECT 1 ... LIMIT 1`).
    # Conditions go on the relation, not the call: `Post.where(slug: s).exists?`.
    # @return [Boolean]
    # @api public
    def exists?
      return false if @limit == 0

      sql = select_sql("1 AS one", "", 1, @offset)
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      !found.empty?
    end

    # Deletes the matching rows and returns how many went, with one DELETE:
    # no model is loaded and no callback runs. With a limit or
    # offset only the rows of that window go (Post.limit(1).delete_all is one
    # row, as count/exists? read the same window): SQLite has no DELETE ...
    # LIMIT in a default build, so the window is picked by an `id` subselect
    # (the quoted primary key); the where binds appear once, inside it.
    # @example
    #   Comment.where(article_id: article.id).delete_all
    # @return [Integer] the number of rows deleted
    # @api public
    def delete_all
      sql = +"DELETE FROM #{Relation.quote_ident(@table)}"
      if @limit >= 0 || @offset > 0
        # By id when the relation has no order, as first_row/last_row do, so
        # Post.limit(1).delete_all removes the row Post.limit(1).first returns
        # rather than whichever row SQLite scans first.
        id = Relation.quote_ident("id")
        order = @order == "" ? id : @order
        sql << " WHERE #{id} IN (" << select_sql(id, order, @limit, @offset) << ")"
      else
        sql << " WHERE " << @wheres.join(" AND ") unless @wheres.empty?
      end
      binds = @binds
      Cybertrain::DB.with do |c|
        c.execute(sql, binds)
        c.changes
      end
    end

    # The first row by the relation's order (by id when it has none), from
    # the offset on.
    def first_row
      return nil if @limit == 0

      order = @order == "" ? Relation.quote_ident("id") : @order
      pick_row(order, @offset)
    end

    # The last row of the relation's window. Without limit/offset that is the
    # relation's order reversed (id DESC when it has none); with them it is
    # the last row of the LIMIT/OFFSET window, as in ActiveRecord
    # (Post.offset(1).last is the table's last row, Post.limit(3).last the
    # third), which means loading that window.
    def last_row
      order = @order == "" ? Relation.quote_ident("id") : @order
      if @limit >= 0 || @offset > 0
        sql = select_sql("*", order, @limit, @offset)
        binds = @binds
        found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
        return found.empty? ? nil : found[found.size - 1]
      end
      pick_row(Relation.reverse_order(order), 0)
    end

    # "posts" -> "`posts`" (an embedded backtick is doubled).
    def self.quote_ident(name)
      return "`#{name}`" unless name.include?("`")

      "`" + name.gsub("`", "``") + "`"
    end

    # "title DESC, id" -> "title ASC, id DESC"
    def self.reverse_order(order)
      terms = order.split(",").map do |term|
        t = term.strip
        upper = t.upcase
        if upper.end_with?(" DESC")
          t[0, t.size - 5] + " ASC"
        elsif upper.end_with?(" ASC")
          t[0, t.size - 4] + " DESC"
        else
          t + " DESC"
        end
      end
      terms.join(", ")
    end

    private

    def pick_row(order, offset)
      sql = select_sql("*", order, 1, offset)
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      found.empty? ? nil : found[0]
    end

    def select_sql(columns, order, limit, offset)
      sql = +"SELECT #{columns} FROM #{Relation.quote_ident(@table)}"
      sql << " WHERE " << @wheres.join(" AND ") unless @wheres.empty?
      sql << " ORDER BY " << order if order != ""
      if limit >= 0
        sql << " LIMIT " << limit.to_s
      elsif offset > 0
        sql << " LIMIT -1" # SQLite accepts OFFSET only after a LIMIT
      end
      sql << " OFFSET " << offset.to_s if offset > 0
      sql
    end
  end
end
