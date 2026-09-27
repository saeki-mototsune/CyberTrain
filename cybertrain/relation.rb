require "cybertrain/cast"
require "cybertrain/db"

module Cybertrain
  # A lazily built SELECT over one table. Each generated model gets its own
  # subclass (PostRelation) whose chain methods wrap the setters below and
  # return self, so `Post.where(...).first` is typed Post|nil: a base-class
  # method that returned self would be typed as the base (spikes/NOTES.md
  # rule 5), which is why these setters return nil.
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

    # Table and column names are double-quoted in every generated fragment
    # so a column named after an SQL keyword (order, group, on) still works.
    # Raw fragments (where_sql, order) are the caller's SQL and stay as given.
    #
    # where(title: "x")    -> "title" = ?
    # where(body: nil)     -> "body" IS NULL
    # where(id: [1, 2])    -> "id" IN (?, ?)
    def add_where(hash)
      hash.each do |key, value|
        column = Relation.quote_ident(key.to_s)
        case value
        when nil
          @wheres << "#{column} IS NULL"
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

    def set_order(order)
      @order = order
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

    def exists?
      return false if @limit == 0

      sql = select_sql("1 AS one", "", 1, @offset)
      binds = @binds
      found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
      !found.empty?
    end

    # Deletes the matching rows and returns how many went.
    def delete_all
      sql = +"DELETE FROM #{Relation.quote_ident(@table)}"
      sql << " WHERE " << @wheres.join(" AND ") unless @wheres.empty?
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

      order = @order == "" ? "id" : @order
      pick_row(order, @offset)
    end

    # The last row of the relation's window. Without limit/offset that is the
    # relation's order reversed (id DESC when it has none); with them it is
    # the last row of the LIMIT/OFFSET window, as in ActiveRecord
    # (Post.offset(1).last is the table's last row, Post.limit(3).last the
    # third), which means loading that window.
    def last_row
      order = @order == "" ? "id" : @order
      if @limit >= 0 || @offset > 0
        sql = select_sql("*", order, @limit, @offset)
        binds = @binds
        found = Cybertrain::DB.with { |c| c.execute(sql, binds) }
        return found.empty? ? nil : found[found.size - 1]
      end
      pick_row(Relation.reverse_order(order), 0)
    end

    # "posts" -> "\"posts\"" (an embedded double quote is doubled).
    def self.quote_ident(name)
      "\"" + name.gsub("\"", "\"\"") + "\""
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
