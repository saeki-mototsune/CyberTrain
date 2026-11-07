require "cybertrain/cast"
require "cybertrain/ident"
require "cybertrain/db"
require "cybertrain/pagination"

module Cybertrain
  # A lazily built SELECT over one table: nothing runs until a method that
  # needs rows ({#count}, {#exists?}, `to_a`, `first`, `each`, ...).
  #
  # Each generated model gets its own subclass, `<Model>Relation`, which adds
  # the chainable query methods (`where`, `not`, `where_sql`, `where_like`,
  # `where_between`, `or`, `order`, `order_sql`, `limit`, `offset`,
  # `distinct`, `none`, `having_sql`, `includes`, `preload`) and the
  # methods that return records (`to_a`, `each`, `first`, `last`, `find`,
  # `find_by`, `find_by!`, `find_or_create_by`, `find_or_initialize_by`,
  # `destroy_all`, `find_each`, `size`, `empty?`, and `preloaded`, which a
  # has_many reader uses after `includes`); see
  # {ArticleRelation}. The model class answers each query method too
  # (`Article.where(...)` is `Article.all.where(...)`). The methods
  # documented here are the ones every relation shares.
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
      # Binds hold nil/Integer/Float/String/DB::Blob: seed with more than
      # one type so the Array is polymorphic from the start (rule 9).
      @binds = [nil, 0, 0.0, "", DB::Blob.new("")]
      @binds.clear
      @order = ""
      @limit = -1
      @offset = 0
      @distinct = false
      @none = false
      # HAVING text for the grouped readers (having_sql) and its binds.
      @having = ""
      @having_binds = [nil, 0, 0.0, "", DB::Blob.new("")]
      @having_binds.clear
      # includes / preload (spec section 8): the association names `to_a`
      # preloads, and whether the subclass's `preloaded` records answer the
      # record readers (true from `preloaded` until the next chain method).
      @includes = Array.new(0) { :x }
      @records_preloaded = false
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
    # where(views: 1..5)   -> `views` BETWEEN ? AND ?   (Integer ends only:
    #                         NOTES rule 86; other bounds use where_between)
    # where(views: 1...5)  -> `views` >= ? AND `views` < ?
    # where(views: 5..)    -> `views` >= ?
    # A json column raises ArgumentError: its stored text is not a value
    # to compare; so does an encrypted one.
    def add_where(hash)
      drop_preloaded
      hash.each { |key, value| @wheres << where_term(key.to_s, value) }
      nil
    end

    # where.not(hash): the terms add_where would write, ANDed and negated
    # as one: `NOT (a AND b)` (Rails 6.1+). where.not(id: []) is
    # `NOT (1 = 0)`, every row: the complement of where(id: []).
    def add_where_not(hash)
      drop_preloaded
      terms = Array.new(0) { "" }
      hash.each { |key, value| terms << where_term(key.to_s, value) }
      return nil if terms.empty?

      joined = terms.join(" AND ")
      @wheres << "NOT (#{joined})"
      nil
    end

    # A json column's stored text is not a value to compare: raises
    # `"<method> on a json column (<name>) is not supported"`.
    def check_not_json(method, name)
      if column_type(name) == :json
        raise ArgumentError, "#{method} on a json column (#{name}) is not supported"
      end

      nil
    end

    # An encrypted column (`encrypts` in the model) stores a payload with a
    # fresh nonce per save, so no value compares equal to it: raises
    # `"<method> on an encrypted column (<name>) is not supported"`.
    def check_not_encrypted(method, name)
      if encrypted_column?(name)
        raise ArgumentError, "#{method} on an encrypted column (#{name}) is not supported"
      end

      nil
    end

    # One `column <op> ?` term for add_where / add_where_not; its binds go
    # onto @binds in order.
    def where_term(name, value)
      check_not_json("where", name)
      check_not_encrypted("where", name)
      column = Relation.quote_ident(name)
      case value
      when nil
        "#{column} IS NULL"
      when Time
        # Before `when Array`: a Time in a poly slot matches Array (rule 8).
        @binds << Cast.to_sql(value)
        "#{column} = ?"
      when Array
        return "1 = 0" if value.empty?

        marks = Array.new(value.size) { "?" }
        value.each { |v| @binds << bind_for(name, v) }
        list = marks.join(", ")
        "#{column} IN (#{list})"
      when Range
        # Integer ends only (NOTES rule 86); placed before `else`.
        range_term(column, name, value.begin, value.end, value.exclude_end?)
      else
        @binds << bind_for(name, value)
        "#{column} = ?"
      end
    end

    # The term of an Integer Range `from..to` (either end nil for an open
    # range): BETWEEN for a closed inclusive one, `>=` / `<` / `<=` else.
    def range_term(column, name, from, to, exclude_end)
      return "1 = 1" if from.nil? && to.nil?

      upper = exclude_end ? "<" : "<="
      if from.nil?
        @binds << bind_for(name, to)
        return "#{column} #{upper} ?"
      end
      @binds << bind_for(name, from)
      return "#{column} >= ?" if to.nil?

      @binds << bind_for(name, to)
      return "#{column} >= ? AND #{column} < ?" if exclude_end

      "#{column} BETWEEN ? AND ?"
    end

    # where_between(:at, t1, t2): `at` >= ? AND `at` <= ? (`<` with
    # exclude_end), for any bounds a Range cannot carry under Spinel (Time,
    # Date, Float, String: NOTES rule 86). A Time or Date is bound as its
    # stored text (Cast.to_sql), so the comparison is the stored column's;
    # nil for an open end; both nil raises ArgumentError.
    def add_where_between(column, from, to, exclude_end)
      drop_preloaded
      quoted = Relation.checked_column("where_between", column)
      check_not_json("where_between", column.to_s)
      check_not_encrypted("where_between", column.to_s)
      if from.nil? && to.nil?
        raise ArgumentError, "where_between: from and to are both nil (give at least one bound)"
      end

      name = column.to_s
      unless from.nil?
        @wheres << "#{quoted} >= ?"
        @binds << bind_for(name, from)
      end
      unless to.nil?
        op = exclude_end ? "<" : "<="
        @wheres << "#{quoted} #{op} ?"
        @binds << bind_for(name, to)
      end
      nil
    end

    # a.or(b): one WHERE term `((a) OR (b))`, a's binds then b's. The two
    # relations must agree on order, limit, offset and distinct (as Rails
    # requires them to be structurally compatible); a side with no
    # conditions matches every row, so the result has none. A `none` side
    # contributes its `1 = 0`.
    def merge_or(other)
      drop_preloaded
      raise ArgumentError, "or: a relation with having_sql cannot be combined" if @having != ""
      unless relation_shape == other.relation_shape
        raise ArgumentError, "or: the relations differ in order, limit, offset or distinct"
      end

      mine = condition_sql
      theirs = other.condition_sql
      @wheres.clear
      @none = false
      if mine == "" || theirs == ""
        @binds.clear
        return nil
      end

      @wheres << "((#{mine}) OR (#{theirs}))"
      # By index up to the size read first: `a.or(a)` hands in @binds itself.
      extra = other.binds
      n = extra.size
      i = 0
      while i < n
        @binds << extra[i]
        i += 1
      end
      nil
    end

    # What `or` requires two relations to share, as one String.
    def relation_shape
      "#{@order}|#{@limit}|#{@offset}|#{@distinct}|#{@having}"
    end

    # The WHERE text without the keyword ("" for none): the terms ANDed,
    # with `1 = 0` when the relation is `none`.
    def condition_sql
      text = @wheres.join(" AND ")
      return text unless @none

      text == "" ? "1 = 0" : "#{text} AND 1 = 0"
    end

    # SELECT DISTINCT from now on: the column readers (pluck_*, ids) dedupe;
    # a SELECT * row carries its id, so count and to_a are unchanged.
    def set_distinct
      drop_preloaded
      @distinct = true
      nil
    end

    # having_sql("SUM(value) > ?", [2.0]): a HAVING clause, in parentheses,
    # for the grouped readers only (count_by, sum_int_by, average_by, ...);
    # any other reader of a relation with one raises ArgumentError. A
    # second call ANDs its text onto the first. The text is the
    # developer's SQL, never request data; its values go in `binds`.
    def set_having_sql(sql, binds)
      drop_preloaded
      @having = @having == "" ? "(#{sql})" : "#{@having} AND (#{sql})"
      binds.each do |v|
        case v
        when Time then @having_binds << Cast.to_sql(v) # before `when Array` (rule 8)
        when Array
          raise ArgumentError, "having_sql: an Array bind is not expanded"
        else @having_binds << Cast.to_sql(v)
        end
      end
      nil
    end

    # The relation matches no row: count, exists?, update_all and
    # delete_all answer 0 / false without a statement; the readers run
    # theirs with `1 = 0` in the WHERE.
    def set_none
      drop_preloaded
      @none = true
      nil
    end

    # The type of the column `name` (its SQL name, a String): one of
    # `:integer`, `:float`, `:decimal`, `:boolean`, `:datetime`, `:date`,
    # `:json`, `:binary`, `:string`, `:text`, or `:unknown` for a name that
    # is not a column. The generated subclass answers from db/schema.rb;
    # here every name is unknown.
    # @param name [String]
    # @return [Symbol]
    def column_type(name)
      :unknown
    end

    # The scale of the decimal column `name`, -1 when it is not a decimal
    # column or declares no scale. The generated subclass answers from
    # db/schema.rb; here none has one.
    # @param name [String]
    # @return [Integer]
    def decimal_scale(name)
      -1
    end

    # Whether `name` is a binary column of the table. The generated
    # subclass answers from the schema; here nothing is.
    # @param name [String]
    # @return [Boolean]
    def binary_column?(name)
      false
    end

    # Whether `name` is an encrypted column of the table (`encrypts` in the
    # model). The generated subclass of a model that declares one answers
    # it; here nothing is.
    # @param name [String]
    # @return [Boolean]
    def encrypted_column?(name)
      false
    end

    # The bind for `column = value`: the bytes of a binary column wrapped
    # in a {DB::Blob}, so SQLite compares BLOB to BLOB (a TEXT bind never
    # equals the stored BLOB); a Blob as it is; anything else as
    # {Cast.to_sql} writes it.
    def bind_for(column, value)
      case value
      when DB::Blob then value
      else binary_column?(column) ? DB::Blob.new(value.to_s) : Cast.to_sql(value)
      end
    end

    # The value a write binds for a column of type `type` (column_type) and
    # decimal scale `scale`: the cast a save applies (the generated
    # write_attribute's, then to_row's; models_emitter.rb's cast_for and
    # bind_expression, kept in step with this table). update_all and the
    # bulk writes (Model.insert_all_into, Model.upsert_into) bind through
    # it. A boolean is 1/0, a json value its JSON text, a date
    # `YYYY-MM-DD`, a datetime the storage format ({Cast.sql_datetime}), a
    # decimal rounded to its scale, a binary value a {DB::Blob} of its
    # bytes (a Blob given unwrapped first); the `_or_nil` casts
    # throughout, so nil binds NULL for every type, and `""` (an empty form
    # field) binds NULL for an integer, float, decimal, boolean, date,
    # datetime or json column (where save would store 0 / false / `{}` in
    # a NOT NULL one) but stays `""` for a string, text or binary one; a
    # date or datetime text that does not parse, and a value the type
    # cannot hold (an Array for an integer), bind NULL too. `:unknown`
    # binds {Cast.to_sql}'s value.
    # @param type [Symbol]
    # @param scale [Integer] -1 for none
    # @param v [Object]
    # @return [Object]
    def self.typed_bind(type, scale, v)
      case type
      when :integer then Cast.int_or_nil(v)
      when :float then Cast.float_or_nil(v)
      when :decimal then Cast.round_scale_or_nil(v, scale)
      when :boolean then Cast.to_sql(Cast.bool_or_nil(v))
      when :datetime then Cast.to_sql(Cast.time_or_nil(v))
      when :date then Cast.to_sql(Cast.date_or_nil(v))
      when :json then Cast.json_text(Cast.hash_or_nil(v))
      when :binary then DB::Blob.wrap(Cast.binary_or_nil(v))
      when :string, :text then Cast.str_or_nil(v)
      else Cast.to_sql(v)
      end
    end

    # A raw SQL fragment with its own `?` binds: where_sql("views > ?", [10]).
    # The fragment is stored in parentheses, as Rails does, so an `OR`
    # inside it cannot take the ANDed terms around it
    # (where("a = ? OR b = ?", 1, 2).where(c: 3) is `(a = ? OR b = ?) AND c = ?`).
    # An Array bind raises: one `?` is one value, never a list.
    def add_where_sql(sql, binds)
      drop_preloaded
      binds.each do |v|
        case v
        when Time then nil # before `when Array` (rule 8)
        when Array
          raise ArgumentError, "where: an Array bind is not expanded; use where(column: [...])"
        end
      end
      @wheres << "(#{sql})"
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
      drop_preloaded
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

    # order(views: :desc, name: :asc): each key a column (checked and
    # quoted), each value :asc or :desc (a String works too, any case).
    def set_order_hash(hash)
      drop_preloaded
      terms = Array.new(0) { "" }
      hash.each do |key, dir|
        quoted = Relation.checked_column("order", key)
        word = dir.to_s.upcase
        unless word == "ASC" || word == "DESC"
          raise ArgumentError, "order: #{key.to_s.inspect} => #{dir.to_s.inspect} is not :asc or :desc"
        end

        terms << "#{quoted} #{word}"
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
      drop_preloaded
      @order = sql
      nil
    end

    def set_limit(n)
      drop_preloaded
      @limit = n
      nil
    end

    def set_offset(n)
      drop_preloaded
      @offset = n
      nil
    end

    # --- includes / preload (spec section 8) --------------------------------
    # The generated subclass's `includes(*names)` checks each name against
    # the model's associations and adds it here; its `to_a` runs
    # `preload_association(name, records)` for each after loading the rows.
    # Its `preloaded(records)` keeps an Array of records (typed by the
    # subclass) and calls mark_records_preloaded, so `to_a`, `each`,
    # `first`, `last`, `size` and `empty?` answer from it until a chain
    # method (every setter here runs drop_preloaded) changes the result set.

    # Adds an association name to preload (once); a chain method, so it
    # drops the preloaded records.
    def add_include(name)
      drop_preloaded
      @includes << name unless @includes.include?(name)
      nil
    end

    # The association names `to_a` preloads, in the order given.
    def includes_names
      @includes
    end

    # Whether the subclass's preloaded records answer the record readers.
    def records_preloaded?
      @records_preloaded
    end

    def mark_records_preloaded
      @records_preloaded = true
      nil
    end

    def drop_preloaded
      @records_preloaded = false
      nil
    end

    # Loads the association `name` of `records` in one query per chunk of
    # ids and stores it in each record's cache. The generated subclass
    # answers for its model's associations; here there are none.
    def preload_association(name, records)
      nil
    end

    # The SELECT this relation runs, with `?` placeholders (see `binds`).
    # Handy in a test or a log line.
    # @return [String]
    # @api public
    def to_sql
      select_sql("*", @order, @limit, @offset)
    end

    # The rows this relation selects, for Model.from_row: a DATETIME column is
    # a UTC Time (see Connection#execute_models) rather than its text;
    # Cast.time_or_nil takes either.
    def rows
      sql = to_sql
      binds = @binds
      Cybertrain::DB.with { |c| c.execute_models(sql, binds) }
    end

    # Counts the rows the relation would return: with a limit or offset the
    # count runs over the windowed subquery (Post.limit(2).count is 2).
    # @example
    #   Comment.where(article_id: article.id).count
    # @return [Integer]
    # @api public
    def count
      return 0 if @none

      sql = if @distinct
              # Over the DISTINCT rows, not `SELECT DISTINCT 1` (one row); with
              # `*` every row is distinct, so this equals the plain count.
              inner = select_sql("*", "", @limit, @offset)
              "SELECT COUNT(*) AS n FROM (#{inner})"
            elsif @limit >= 0 || @offset > 0
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
      return false if @limit == 0 || @none

      # Under distinct, `SELECT DISTINCT 1` is one row, so an offset would
      # skip past every match: probe whole rows, as page does.
      probe = @distinct ? "*" : "1 AS one"
      sql = select_sql(probe, "", 1, @offset)
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
      return 0 if @none

      sql = +"DELETE FROM #{Relation.quote_ident(@table)}"
      sql << write_scope_sql
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

      pick_row(order_or_id, @offset)
    end

    # The last row of the relation's window. Without limit/offset that is the
    # relation's order reversed (id DESC when it has none); with them it is
    # the last row of the LIMIT/OFFSET window, as in ActiveRecord
    # (Post.offset(1).last is the table's last row, Post.limit(3).last the
    # third), which means loading that window.
    def last_row
      order = order_or_id
      if @limit >= 0 || @offset > 0
        sql = select_sql("*", order, @limit, @offset)
        binds = @binds
        found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
        return found.empty? ? nil : found[found.size - 1]
      end
      pick_row(Relation.reverse_order(order), 0)
    end

    # --- pagination (issue #75) ---------------------------------------------

    # Windows the relation to page `number` of `per` rows and returns where
    # that page sits: `LIMIT per OFFSET (number - 1) * per` replaces any
    # limit/offset set before, so call it last, after where and order.
    # The rows themselves load when the relation does (`to_a`, `each`), as
    # typed records. `number` is clamped to `1..Params.max_page`
    # (Config#max_page, 10000 by default), so the offset never passes
    # `(max_page - 1) * per`; a page past the last row is empty.
    #
    # Whether an older page exists is asked with one `SELECT 1 ... LIMIT
    # per + 1` over the same window, not a COUNT(*) over the whole table.
    # @example
    #   @articles = Article.order("created_at DESC")
    #   @page = @articles.page(params.page_number, per: 20)
    # @param number [Integer] the 1-based page, usually Params#page_number
    # @param per [Integer] rows per page, 1 to {Page::MAX_PER}
    # @return [Page]
    # @raise [ArgumentError] when per is out of range (a programmer error)
    # @api public
    def page(number, per: 50)
      drop_preloaded
      if per < 1 || per > Page::MAX_PER
        raise ArgumentError, "page: per must be from 1 to #{Page::MAX_PER} (got #{per})"
      end

      n = Page.clamp_number(number, Params.max_page)
      skip = (n - 1) * per
      # Under distinct, `SELECT DISTINCT 1` would be one row.
      probe = @distinct ? "*" : "1 AS one"
      sql = select_sql(probe, "", per + 1, skip)
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      @limit = per
      @offset = skip
      Page.new(n, per, found.size > per)
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

    # --- LIKE, pluck, aggregates and increment (issue #74) ------------------
    # Typed one-column reads: Spinel needs one return type per method, so
    # pluck and sum come in flavours (pluck_str, pluck_int, pluck_float,
    # sum_int, sum_float, minimum_int, minimum_time, ...) instead of Rails'
    # polymorphic sum/minimum; pluck of two or more columns casts each cell
    # by its column's type. Each
    # honours the relation's where, order (pluck), limit and offset. Column
    # names go through Ident.column? and are quoted; the *_sql variants take
    # the developer's SQL text, which must never see request data.

    # A column name for the methods below: checked (a programmer error, an
    # ArgumentError, otherwise) and backtick-quoted.
    def self.checked_column(method, column)
      name = column.to_s
      raise ArgumentError, "#{method}: #{name.inspect} is not a column name" unless Ident.column?(name)

      Relation.quote_ident(name)
    end

    # where_like(:title, "50%") -> `title` LIKE ? ESCAPE '\' with "%50\%%":
    # a substring search, the text's `\`, `%` and `_` escaped (Cast.like_escape).
    def add_where_like(column, text)
      drop_preloaded
      quoted = Relation.checked_column("where_like", column)
      check_not_encrypted("where_like", column.to_s)
      @wheres << "#{quoted} LIKE ? ESCAPE '\\'"
      escaped = Cast.like_escape(text)
      pattern = "%#{escaped}%"
      @binds << pattern
      nil
    end

    # Adds `by` to `column` in every matching row with one
    # `UPDATE ... SET col = col + ?`: no model is loaded, no callback or
    # validation runs, `updated_at` is left alone. A limit or offset picks
    # the rows by an `id` subselect, as {#delete_all} does.
    # @example
    #   Article.where(id: article.id).increment(:views)
    #   Stat.where(project_id: 1).increment(:calls, by: 5)
    # @param column [Symbol, String] a column name
    # @param by [Integer, Float]
    # @return [Integer] the number of rows updated
    # @raise [ArgumentError] when `column` is not a column name, or is an
    #   encrypted column
    # @api public
    def increment(column, by: 1)
      quoted = Relation.checked_column("increment", column)
      # A payload plus 1 would destroy it.
      check_not_encrypted("increment", column.to_s)
      table = Relation.quote_ident(@table)
      sql = +"UPDATE #{table} SET #{quoted} = #{quoted} + ?"
      binds = [nil, 0, 0.0, ""]
      binds.clear
      binds << Cast.to_sql(by)
      sql << write_scope_sql
      i = 0
      while i < @binds.size
        binds << @binds[i]
        i += 1
      end
      Cybertrain::DB.with do |c|
        c.execute(sql, binds)
        c.changes
      end
    end

    # Sets each column to its value in every matching row with one
    # `UPDATE ... SET a = ?, b = ?`, each value cast by its column's type as
    # save stores it ({Relation.typed_bind}): a boolean as 1/0 (a form's
    # `"false"` too), a Hash or JSON text as JSON (invalid text as `{}`), a
    # Date or `YYYY-MM-DD` text as that date, a Time or time text in the
    # storage format, a decimal rounded to its scale, binary bytes as a
    # BLOB, other text as save reads it (`"abc"` is 0 in an integer
    # column). nil stores NULL in every column; `""` stores NULL in an
    # integer, float, decimal, boolean, date, datetime or json column (so a
    # NOT NULL one refuses it, where save would store 0 / false / `{}`) and
    # `""` in a string, text or binary one; date or time text that does not
    # parse stores NULL too. No model is loaded, no
    # callback or validation runs, `updated_at` is left alone. A limit or
    # offset picks the rows by an `id` subselect, as {#delete_all} does.
    # @example
    #   Comment.where(article_id: article.id).update_all(approved: true)
    # @param hash [Hash{Symbol => Object}] column => value
    # @return [Integer] the number of rows updated
    # @raise [ArgumentError] on an empty Hash, a key that is not a column
    #   name, or an encrypted column (which only a save can encrypt)
    # @api public
    def update_all(hash)
      raise ArgumentError, "update_all: no attributes" if hash.empty?
      return 0 if @none

      sets = Array.new(0) { "" }
      binds = [nil, 0, 0.0, "", DB::Blob.new("")]
      binds.clear
      hash.each do |key, value|
        quoted = Relation.checked_column("update_all", key)
        sets << "#{quoted} = ?"
        name = key.to_s
        check_not_encrypted("update_all", name)
        type = column_type(name)
        # A hand-written relation that knows no types binds as where does
        # (its binary_column? included).
        if type == :unknown
          binds << bind_for(name, value)
        else
          binds << Relation.typed_bind(type, decimal_scale(name), value)
        end
      end
      table = Relation.quote_ident(@table)
      set_list = sets.join(", ")
      sql = +"UPDATE #{table} SET #{set_list}"
      sql << write_scope_sql
      i = 0
      while i < @binds.size
        binds << @binds[i]
        i += 1
      end
      Cybertrain::DB.with do |c|
        c.execute(sql, binds)
        c.changes
      end
    end

    # The ids of the matching rows, in the relation's order (by id when it
    # has none).
    # @example
    #   Comment.where(article_id: article.id).ids  # => [3, 7]
    # @return [Array<Integer>]
    # @api public
    def ids
      id = Relation.quote_ident("id")
      columns = "#{id} AS v"
      sql = select_sql(columns, order_or_id, @limit, @offset)
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      out = Array.new(0) { 0 }
      i = 0
      while i < found.size
        out << Cast.int(found[i]["v"])
        i += 1
      end
      out
    end

    # One batch for the generated find_each: up to `batch` rows with
    # `id > after_id`, by id, under the relation's conditions (its order,
    # limit and offset are not used, as in Rails' find_each).
    def batch_rows(after_id, batch)
      refuse_having
      id = Relation.quote_ident("id")
      where = condition_sql
      clause = where == "" ? "#{id} > ?" : "(#{where}) AND #{id} > ?"
      head = @distinct ? "SELECT DISTINCT *" : "SELECT *"
      table = Relation.quote_ident(@table)
      size = batch.to_s
      sql = "#{head} FROM #{table} WHERE #{clause} ORDER BY #{id} LIMIT #{size}"
      binds = [nil, 0, 0.0, "", DB::Blob.new("")]
      binds.clear
      i = 0
      while i < @binds.size
        binds << @binds[i]
        i += 1
      end
      binds << after_id
      Cybertrain::DB.with { |c| c.execute_models(sql, binds) }
    end

    private

    # The relation's ORDER BY text, or the quoted primary key when it has
    # none: first_row, last_row and a windowed delete_all all pick rows by
    # id then, so they agree on which row is "first".
    def order_or_id
      @order == "" ? Relation.quote_ident("id") : @order
    end

    def pick_row(order, offset)
      sql = select_sql("*", order, 1, offset)
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute_models(sql, binds) }
      found.empty? ? nil : found[0]
    end

    # The WHERE of an UPDATE or DELETE over this relation: its conditions,
    # or, with a limit or offset, the window picked by an `id` subselect
    # (by id when the relation has no order, as first_row/last_row do, so
    # Post.limit(1).delete_all removes the row Post.limit(1).first returns
    # rather than whichever row SQLite scans first). "" for every row.
    def write_scope_sql
      refuse_having
      if @limit >= 0 || @offset > 0
        id = Relation.quote_ident("id")
        window = select_sql(id, order_or_id, @limit, @offset)
        return " WHERE #{id} IN (#{window})"
      end
      where = condition_sql
      where == "" ? "" : " WHERE #{where}"
    end

    # The SELECT of every reader but the grouped ones, which alone honour
    # having_sql: with a HAVING set it raises rather than drop it.
    def select_sql(columns, order, limit, offset)
      refuse_having
      select_from_sql(columns, order, limit, offset)
    end

    def refuse_having
      return nil if @having == ""

      raise ArgumentError, "having_sql applies only to the grouped readers (count_by, sum_int_by, average_by, ...)"
    end

    def select_from_sql(columns, order, limit, offset)
      head = @distinct ? "SELECT DISTINCT" : "SELECT"
      sql = +"#{head} #{columns} FROM #{Relation.quote_ident(@table)}"
      where = condition_sql
      sql << " WHERE " << where if where != ""
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

require "cybertrain/relation/aggregates"
