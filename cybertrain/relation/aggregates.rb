# Cybertrain::Relation, continued: the one-column readers (pluck_str,
# pluck_int, pluck_float, pluck, pick), count_by and every aggregate (sum_*,
# minimum_*, maximum_*, average, their _sql and _by forms), with their
# helpers. Split out of cybertrain/relation.rb, which requires this file at
# its end, so a program that requires relation.rb gets all of Relation; the
# private helpers these call (select_sql, select_from_sql, order_or_id)
# stay there.
module Cybertrain
  class Relation
    # One column of the matching rows, in the relation's order, as Strings
    # (NULL is `""`, a DATETIME its stored text). Every pluck reads the
    # stored cells, so an encrypted column (`encrypts`) answers its payloads
    # (`"1:..."`), not the text: load the records to decrypt.
    # @example
    #   Article.all.order("title").pluck_str(:title)  # => ["Bye", "Hello"]
    # @param column [Symbol, String] a column name
    # @return [Array<String>]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def pluck_str(column)
      found = pluck_rows("pluck_str", column)
      out = Array.new(0) { "" }
      i = 0
      while i < found.size
        out << Cast.str(found[i]["v"])
        i += 1
      end
      out
    end

    # {#pluck_str} as Integers (NULL is `0`, through Cast.int).
    # @example
    #   Comment.where(article_id: article.id).pluck_int(:id)  # => [3, 7]
    # @param column [Symbol, String] a column name
    # @return [Array<Integer>]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def pluck_int(column)
      found = pluck_rows("pluck_int", column)
      out = Array.new(0) { 0 }
      i = 0
      while i < found.size
        out << Cast.int(found[i]["v"])
        i += 1
      end
      out
    end

    # {#pluck_str} as Floats (NULL is `0.0`, through Cast.float).
    # @param column [Symbol, String] a column name
    # @return [Array<Float>]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def pluck_float(column)
      found = pluck_rows("pluck_float", column)
      out = Array.new(0) { 0.0 }
      i = 0
      while i < found.size
        out << Cast.float(found[i]["v"])
        i += 1
      end
      out
    end

    # Two or more columns of the matching rows, in the relation's order, one
    # Array of cells per row. Each cell is cast by the column's type
    # ({#column_type}): an integer column gives an Integer, a float or
    # decimal a Float, a boolean `true`/`false`, a datetime a UTC Time, a
    # date a Date, any other (string, text, json, binary) the String
    # stored; NULL is nil. One column has a typed reader instead
    # ({#pluck_str}, {#pluck_int}, {#pluck_float}, {#ids}), since Spinel
    # gives a method one return type.
    # @example
    #   Reading.order("id").pluck(:observed_at, :value)
    #   # => [[2026-10-01 09:00:00 UTC, 1.0], [2026-10-02 12:00:00 UTC, 2.0]]
    # @param columns [Array<Symbol, String>] two or more column names
    # @return [Array<Array<Integer, Float, String, Boolean, Time, Date, nil>>]
    # @raise [ArgumentError] with fewer than two columns, or a name that is
    #   not a column name
    # @api public
    def pluck(*columns)
      cell_rows("pluck", columns, @limit)
    end

    # The first row {#pluck} would return (`LIMIT 1`, the relation itself
    # keeps its limit), or nil when nothing matches.
    # @example
    #   Reading.order("id").pick(:id, :value)  # => [1, 1.0]
    # @param columns [Array<Symbol, String>] two or more column names
    # @return [Array<Integer, Float, String, Boolean, Time, Date, nil>, nil]
    # @raise [ArgumentError] as {#pluck} does
    # @api public
    def pick(*columns)
      found = cell_rows("pick", columns, @limit == 0 ? 0 : 1)
      found.empty? ? nil : found[0]
    end

    # How many matching rows hold each value of `column`
    # (`SELECT col, COUNT(*) ... GROUP BY col`), keys through Cast.str in
    # ascending order. NULL and `""` share the key `""`. With a limit or
    # offset the window is grouped (as {#count} counts it).
    # @example
    #   Comment.all.count_by(:article_id)  # => {"1" => 2, "4" => 1}
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Integer}]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def count_by(column)
      int_totals(grouped_cell("COUNT", Relation.checked_column("count_by", column), "*"))
    end

    # {#count_by} over a raw SQL expression, for buckets a column name
    # cannot say. The expression is used as written, like
    # {ArticleRelation#order_sql}'s: never build it from request data.
    # @example hour buckets
    #   Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")
    #   # => {"2026-10-25T09" => 3, "2026-10-25T10" => 1}
    # @param expr [String] SQL text
    # @return [Hash{String => Integer}]
    # @api public
    def count_by_sql(expr)
      int_totals(grouped_cell("COUNT", expr, "*"))
    end

    # The sum of `column` over the matching rows (`SUM`), `0` when there are
    # none or every value is NULL. A REAL column's sum is truncated: use
    # {#sum_float} for those.
    # @example
    #   Stat.where(project_id: 1).sum_int(:calls)
    # @param column [Symbol, String] a column name
    # @return [Integer]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def sum_int(column)
      Cast.int(aggregate_cell("sum_int", "SUM", column))
    end

    # The sum of `column` as a Float (SQLite's `TOTAL`), `0.0` when there
    # are no rows.
    # @param column [Symbol, String] a column name
    # @return [Float]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def sum_float(column)
      Cast.float(aggregate_cell("sum_float", "TOTAL", column))
    end

    # The smallest value of an integer `column` (`MIN`), nil when no row
    # matches or every value is NULL. Under `distinct` the function reads
    # `MIN(DISTINCT col)`, as every aggregate here does. With a limit or
    # offset the window is aggregated (as {#count} counts it).
    # @example
    #   Article.where(published: true).minimum_int(:views)  # => 3
    # @param column [Symbol, String] a column name
    # @return [Integer, nil]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def minimum_int(column)
      Cast.int_or_nil(aggregate_cell("minimum_int", "MIN", column))
    end

    # {#minimum_int} of a float or decimal column, as a Float or nil.
    # @param column [Symbol, String] a column name
    # @return [Float, nil]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def minimum_float(column)
      Cast.float_or_nil(aggregate_cell("minimum_float", "MIN", column))
    end

    # {#minimum_int} of a datetime column, as a UTC Time or nil (the stored
    # text sorts as the time does).
    # @param column [Symbol, String] a column name
    # @return [Time, nil]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def minimum_time(column)
      Cast.time_or_nil(aggregate_cell("minimum_time", "MIN", column))
    end

    # The largest value of an integer `column` (`MAX`), nil when no row
    # matches or every value is NULL.
    # @example
    #   Article.all.maximum_int(:views)  # => 10
    # @param column [Symbol, String] a column name
    # @return [Integer, nil]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def maximum_int(column)
      Cast.int_or_nil(aggregate_cell("maximum_int", "MAX", column))
    end

    # {#maximum_int} of a float or decimal column, as a Float or nil.
    # @param column [Symbol, String] a column name
    # @return [Float, nil]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def maximum_float(column)
      Cast.float_or_nil(aggregate_cell("maximum_float", "MAX", column))
    end

    # {#maximum_int} of a datetime column, as a UTC Time or nil.
    # @example
    #   Comment.where(article_id: article.id).maximum_time(:created_at)
    # @param column [Symbol, String] a column name
    # @return [Time, nil]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def maximum_time(column)
      Cast.time_or_nil(aggregate_cell("maximum_time", "MAX", column))
    end

    # The mean of `column` (`AVG`) as a Float, nil when no row matches or
    # every value is NULL.
    # @example
    #   Reading.where(kind: "a").average(:value)  # => 1.5
    # @param column [Symbol, String] a column name
    # @return [Float, nil]
    # @raise [ArgumentError] when `column` is not a column name
    # @api public
    def average(column)
      Cast.float_or_nil(aggregate_cell("average", "AVG", column))
    end

    # {#sum_float} over a SQL expression (`TOTAL(expr)`), `0.0` when no row
    # matches. The expression is used as written, like
    # {ArticleRelation#order_sql}'s: trusted SQL, never built from request
    # data (bind values through `where`).
    # @example
    #   Line.where(order_id: order.id).sum_float_sql("price * quantity")
    # @param expr [String] SQL text
    # @return [Float]
    # @api public
    def sum_float_sql(expr)
      Cast.float(aggregate_expr("TOTAL", expr))
    end

    # {#minimum_float} over a trusted SQL expression (see {#sum_float_sql}).
    # @param expr [String] SQL text
    # @return [Float, nil]
    # @api public
    def minimum_float_sql(expr)
      Cast.float_or_nil(aggregate_expr("MIN", expr))
    end

    # {#maximum_float} over a trusted SQL expression (see {#sum_float_sql}).
    # @param expr [String] SQL text
    # @return [Float, nil]
    # @api public
    def maximum_float_sql(expr)
      Cast.float_or_nil(aggregate_expr("MAX", expr))
    end

    # {#average} over a trusted SQL expression (see {#sum_float_sql}).
    # @example
    #   Reading.all.average_sql("value * 2")
    # @param expr [String] SQL text
    # @return [Float, nil]
    # @api public
    def average_sql(expr)
      Cast.float_or_nil(aggregate_expr("AVG", expr))
    end

    # The grouped readers below run `SELECT group, F(column) ... GROUP BY 1
    # ORDER BY 1` and answer a Hash keyed by the group column's cell
    # through Cast.str (NULL and `""` share the key `""`), in ascending key
    # order, as {#count_by} does. `having_sql` narrows the groups. With a
    # limit or offset the window is grouped; such a relation cannot carry
    # having_sql (ArgumentError).

    # The sum of an integer `column` per value of `group` (`SUM`), 0 for a
    # group whose values are all NULL.
    # @example
    #   Reading.all.sum_int_by(:kind, :views)  # => {"a" => 6, "b" => 7}
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Integer}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def sum_int_by(group, column)
      int_totals(grouped_by("sum_int_by", "SUM", group, column))
    end

    # The sum of `column` per value of `group` as a Float (`TOTAL`).
    # @example
    #   Reading.all.sum_float_by(:kind, :value)  # => {"a" => 3.0, "b" => 1.5}
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Float}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def sum_float_by(group, column)
      float_totals(grouped_by("sum_float_by", "TOTAL", group, column))
    end

    # {#minimum_int} per value of `group`; a group whose values are all
    # NULL maps to nil.
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Integer, nil}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def minimum_int_by(group, column)
      int_cells(grouped_by("minimum_int_by", "MIN", group, column))
    end

    # {#minimum_float} per value of `group`.
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Float, nil}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def minimum_float_by(group, column)
      float_cells(grouped_by("minimum_float_by", "MIN", group, column))
    end

    # {#minimum_time} per value of `group`.
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Time, nil}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def minimum_time_by(group, column)
      time_cells(grouped_by("minimum_time_by", "MIN", group, column))
    end

    # {#maximum_int} per value of `group`.
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Integer, nil}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def maximum_int_by(group, column)
      int_cells(grouped_by("maximum_int_by", "MAX", group, column))
    end

    # {#maximum_float} per value of `group`.
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Float, nil}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def maximum_float_by(group, column)
      float_cells(grouped_by("maximum_float_by", "MAX", group, column))
    end

    # {#maximum_time} per value of `group`.
    # @example the latest comment per article
    #   Comment.all.maximum_time_by(:article_id, :created_at)
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Time, nil}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def maximum_time_by(group, column)
      time_cells(grouped_by("maximum_time_by", "MAX", group, column))
    end

    # {#average} per value of `group`.
    # @example
    #   Reading.all.having_sql("COUNT(*) > ?", [1]).average_by(:kind, :value)
    # @param group [Symbol, String] a column name
    # @param column [Symbol, String] a column name
    # @return [Hash{String => Float, nil}]
    # @raise [ArgumentError] when either is not a column name
    # @api public
    def average_by(group, column)
      float_cells(grouped_by("average_by", "AVG", group, column))
    end

    def pluck_rows(method, column)
      quoted = Relation.checked_column(method, column)
      columns = "#{quoted} AS v"
      sql = select_sql(columns, @order, @limit, @offset)
      binds = @binds
      Cybertrain::DB.with { |c| c.execute(sql, binds) }
    end

    # One aggregate over one column: SUM(`col`), MIN(`col`), ... (see
    # aggregate_expr).
    def aggregate_cell(method, func, column)
      aggregate_expr(func, Relation.checked_column(method, column))
    end

    # One aggregate over a (quoted or trusted) SQL expression, over the
    # windowed subquery when there is a limit or offset; the raw cell.
    # Under distinct, DISTINCT goes inside the function (`SUM(DISTINCT
    # col)`): `SELECT DISTINCT SUM(col)` is one row, deduping nothing. A
    # windowed distinct relation dedupes in its subquery instead.
    def aggregate_expr(func, expr)
      sql = if @limit >= 0 || @offset > 0
              columns = "#{expr} AS v"
              inner = select_sql(columns, @order, @limit, @offset)
              "SELECT #{func}(v) AS n FROM (#{inner})"
            else
              arg = aggregate_arg(expr)
              select_sql("#{func}(#{arg}) AS n", "", -1, 0)
            end
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      found[0]["n"]
    end

    # The function's argument: `DISTINCT expr` under distinct (not for `*`).
    def aggregate_arg(expr)
      @distinct && expr != "*" ? "DISTINCT #{expr}" : expr
    end

    # grouped_cell over two column names, both checked.
    def grouped_by(method, func, group, column)
      key = Relation.checked_column(method, group)
      value = Relation.checked_column(method, column)
      grouped_cell(func, key, value)
    end

    # `SELECT group AS k, func(expr) AS n ... GROUP BY 1 [HAVING ...]
    # ORDER BY 1`, the raw rows (each read by int_totals, float_cells, ...,
    # one per value type). `GROUP BY 1 ORDER BY 1` (the first result
    # column), not the alias: a table column named `k` would win over an
    # alias in GROUP BY. `expr` is `*` for COUNT(*).
    def grouped_cell(func, group, expr)
      windowed = @limit >= 0 || @offset > 0
      if windowed && @having != ""
        raise ArgumentError, "having_sql with a limit or offset is not supported (the window is grouped, not the groups limited)"
      end

      sql = if windowed
              columns = expr == "*" ? "#{group} AS k" : "#{group} AS k, #{expr} AS v"
              inner = select_sql(columns, @order, @limit, @offset)
              arg = expr == "*" ? "*" : "v"
              "SELECT k, #{func}(#{arg}) AS n FROM (#{inner}) GROUP BY 1 ORDER BY 1"
            else
              arg = aggregate_arg(expr)
              grouped = select_from_sql("#{group} AS k, #{func}(#{arg}) AS n", "", -1, 0)
              having = @having == "" ? "" : " HAVING #{@having}"
              "#{grouped} GROUP BY 1#{having} ORDER BY 1"
            end
      binds = [nil, 0, 0.0, "", DB::Blob.new("")]
      binds.clear
      i = 0
      while i < @binds.size
        binds << @binds[i]
        i += 1
      end
      i = 0
      while i < @having_binds.size
        binds << @having_binds[i]
        i += 1
      end
      Cybertrain::DB.with { |c| c.execute(sql, binds) }
    end

    # Grouped rows as Integers through Cast.int; the NULL and `""` groups,
    # which share the key `""`, are added together (count_by, sum_int_by).
    def int_totals(found)
      out = { "" => 0 }
      out.delete("")
      i = 0
      while i < found.size
        key = Cast.str(found[i]["k"])
        n = Cast.int(found[i]["n"])
        out[key] = out.key?(key) ? out[key] + n : n
        i += 1
      end
      out
    end

    # int_totals as Floats (sum_float_by).
    def float_totals(found)
      out = { "" => 0.0 }
      out.delete("")
      i = 0
      while i < found.size
        key = Cast.str(found[i]["k"])
        n = Cast.float(found[i]["n"])
        out[key] = out.key?(key) ? out[key] + n : n
        i += 1
      end
      out
    end

    # Grouped rows as Integer or nil (minimum_int_by, maximum_int_by); of
    # the NULL and `""` groups the later (`""`) one is kept.
    def int_cells(found)
      out = { "" => Cast.int_or_nil(0) }
      out.delete("")
      i = 0
      while i < found.size
        out[Cast.str(found[i]["k"])] = Cast.int_or_nil(found[i]["n"])
        i += 1
      end
      out
    end

    # int_cells as Float or nil (minimum_float_by, average_by, ...).
    def float_cells(found)
      out = { "" => Cast.float_or_nil(0.0) }
      out.delete("")
      i = 0
      while i < found.size
        out[Cast.str(found[i]["k"])] = Cast.float_or_nil(found[i]["n"])
        i += 1
      end
      out
    end

    # int_cells as a UTC Time or nil (minimum_time_by, maximum_time_by).
    def time_cells(found)
      out = { "" => Cast.time_or_nil(0) }
      out.delete("")
      i = 0
      while i < found.size
        out[Cast.str(found[i]["k"])] = Cast.time_or_nil(found[i]["n"])
        i += 1
      end
      out
    end

    # The rows of pluck and pick: two or more checked columns, aliased
    # c0, c1, ..., each cell cast by its column's type (Relation.typed_cell).
    def cell_rows(method, columns, limit)
      if columns.size < 2
        raise ArgumentError, "#{method} takes two or more columns; use pluck_str, pluck_int, pluck_float or ids for one"
      end

      parts = Array.new(0) { "" }
      keys = Array.new(0) { "" }
      types = Array.new(0) { :unknown }
      i = 0
      while i < columns.size
        quoted = Relation.checked_column(method, columns[i])
        key = "c#{i}"
        parts << "#{quoted} AS #{key}"
        keys << key
        types << column_type(columns[i].to_s)
        i += 1
      end
      list = parts.join(", ")
      sql = select_sql(list, @order, limit, @offset)
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      # Seeded with a row (rule 9) so the outer Array holds polymorphic rows.
      out = [Relation.empty_cells]
      out.clear
      i = 0
      while i < found.size
        row = Relation.empty_cells
        j = 0
        while j < keys.size
          row << Relation.typed_cell(types[j], found[i][keys[j]])
          j += 1
        end
        out << row
        i += 1
      end
      out
    end

    # An empty row of pluck cells, seeded with every type a cell can be
    # (NOTES rules 9 and 46) so Spinel types it as the union.
    def self.empty_cells
      row = [nil, 0, 0.0, "", true, Time.at(0), Date.new(1970, 1, 1)]
      row.clear
      row
    end

    # A SQLite cell as the column type `type` (column_type) reads it.
    def self.typed_cell(type, v)
      case type
      when :integer then Cast.int_or_nil(v)
      when :float, :decimal then Cast.float_or_nil(v)
      when :boolean then Cast.bool_or_nil(v)
      when :datetime then Cast.time_or_nil(v)
      when :date then Cast.date_or_nil(v)
      else Cast.str_or_nil(v)
      end
    end
  end
end
