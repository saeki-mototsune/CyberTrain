require "json"
require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/relation"
require "cybertrain/template/helpers"
require "cybertrain/console/printer"

module Cybertrain
  module Console
    # The console's helpers: what the template interpreter calls for a
    # receiverless name (`sql`, `tables`, `help`, `_`), a constant
    # (`Article`), a method on a Relation (`where`, `order`, `first`,
    # `count`, ...) and a record's write methods (`update`, `destroy`,
    # `save`). Every name goes through a `case` on a literal (spikes/NOTES.md
    # rule 2); the record and relation methods are the base classes', so one
    # arm serves every model, and the per-model steps (a relation's records,
    # a create) go through the Console.*_builder lambdas gen/console.rb sets.
    #
    # Whatever such a method raises is remembered here (failure_class,
    # failure_message) before the interpreter re-raises it as a
    # Template::RuntimeError, so the console can print the original
    # `Cybertrain::RecordNotFound: ...`.
    class Helpers < Template::Helpers
      attr_reader :failure_class, :failure_message

      def initialize
        super(nil)
        @failure_class = ""
        @failure_message = ""
      end

      def failed? = !@failure_class.empty?

      def clear_failure
        @failure_class = ""
        @failure_message = ""
        nil
      end

      # `Article`: that model's relation (Console.scope_builder), which
      # raises UnknownModel for a name that is not a model.
      def constant(name)
        Console.scope_builder.call(name)
      end

      # The record methods the console adds to what a template may call.
      def model_call?(name_sym)
        case name_sym
        when :update, :destroy, :save, :save!, :reload, :valid?, :attributes then true
        else false
        end
      end

      def helper_call(name, args, kwargs, block, interp, env)
        begin
          case name
          when "sql" then return sql_command(args)
          when "tables" then return tables_command
          when "help" then return help_command
          when "_" then return env["_"]
          end
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          remember_failure(e)
          raise e
        end
        super(name, args, kwargs, block, interp, env)
      end

      # The 5-argument signature of HelperBase#call_object_method on this
      # branch. The rescue sits in this plain method (NOTES rules 32/45);
      # JSON's errors are named (rules 33/61).
      def call_object_method(recv, name_sym, name_str, args, kwargs)
        begin
          case recv
          when Cybertrain::Relation then return relation_call(recv, name_sym, name_str, args, kwargs)
          when Cybertrain::Model then return record_call(recv, name_sym, name_str, kwargs)
          end
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          remember_failure(e)
          raise e
        end
        super(recv, name_sym, name_str, args, kwargs)
      end

      def remember_failure(error)
        @failure_class = error.class.name.to_s
        @failure_message = error.message.to_s
        nil
      end

      # --- relations ----------------------------------------------------

      # The chain methods change the relation and return it, as the
      # generated ones do; the record methods go through records_builder.
      def relation_call(rel, sym, name, args, kwargs)
        case sym
        when :all then rel
        when :where
          rel.add_where_sql(text_arg_at(args, 0, name), list_arg_at(args, 1)) unless args.empty?
          rel.add_where(symbol_hash(kwargs)) unless kwargs.empty?
          rel
        when :where_sql
          rel.add_where_sql(text_arg_at(args, 0, name), list_arg_at(args, 1))
          rel
        when :where_like
          rel.add_where_like(text_arg_at(args, 0, name), text_arg_at(args, 1, name))
          rel
        when :order
          rel.set_order(order_text(args, kwargs))
          rel
        when :order_sql
          rel.add_order_sql(text_arg_at(args, 0, name))
          rel
        when :limit
          rel.set_limit(int_arg_at(args, 0, name))
          rel
        when :offset
          rel.set_offset(int_arg_at(args, 0, name))
          rel
        when :page
          per = kwargs["per"]
          rel.page(int_arg_at(args, 0, name), per: per.nil? ? 50 : Cast.int(per))
          rel
        when :first then record_at(rel, rel.first_row)
        when :last then record_at(rel, rel.last_row)
        when :find then find_record(rel, args, name)
        when :find_by
          rel.add_where(symbol_hash(kwargs))
          record_at(rel, rel.first_row)
        when :to_a then records(rel)
        when :count, :size, :length then rel.count
        when :exists?, :any? then rel.exists?
        when :empty? then !rel.exists?
        when :pluck_str then rel.pluck_str(text_arg_at(args, 0, name))
        when :pluck_int then rel.pluck_int(text_arg_at(args, 0, name))
        when :pluck_float then rel.pluck_float(text_arg_at(args, 0, name))
        when :sum_int then rel.sum_int(text_arg_at(args, 0, name))
        when :sum_float then rel.sum_float(text_arg_at(args, 0, name))
        when :count_by then rel.count_by(text_arg_at(args, 0, name))
        when :delete_all then rel.delete_all
        when :to_sql then rel.to_sql
        when :create then Console.create_builder.call(Helpers.model_name_of(rel), symbol_hash(kwargs))
        else raise Template::RuntimeError, "undefined method '#{name}' for #{rel.class.name}"
        end
      end

      # The record of `row` (a row the relation selected, or nil), loaded
      # through records_builder: the relation narrowed to that row's id.
      def record_at(rel, row)
        return nil if row.nil?

        id = Cast.int(row["id"])
        rel.add_where(id_hash(id))
        rel.set_limit(1)
        rel.set_offset(0)
        found = records(rel)
        found.empty? ? nil : found[0]
      end

      def find_record(rel, args, name)
        raise ArgumentError, "wrong number of arguments for '#{name}'" if args.empty?

        id = Cast.int(args[0])
        rel.add_where(id_hash(id))
        rel.set_limit(1)
        rel.set_offset(0)
        found = records(rel)
        raise Cybertrain::RecordNotFound, "Couldn't find #{Helpers.model_name_of(rel)} with id=#{id}" if found.empty?

        found[0]
      end

      def records(rel)
        Console.records_builder.call(rel)
      end

      # "ArticleRelation" -> "Article": the generator names each relation
      # after its model.
      def self.model_name_of(rel)
        name = rel.class.name.to_s
        return name[0, name.size - 8] if name.end_with?("Relation") && name.size > 8

        name
      end

      # --- records ------------------------------------------------------

      def record_call(rec, sym, name, kwargs)
        case sym
        when :update then rec.update(symbol_hash(kwargs))
        when :destroy then rec.destroy
        when :save then rec.save
        when :save! then rec.save!
        when :reload then rec.reload
        when :valid? then rec.valid?
        when :attributes then rec.attributes
        else raise Template::RuntimeError, "undefined method '#{name}' for #{rec.class.name}"
        end
      end

      # --- commands -----------------------------------------------------

      # `sql "SELECT ..."` (optionally with an Array of binds): the rows as
      # a text table. Any statement runs; a write prints "(0 rows)".
      def sql_command(args)
        sql = text_arg_at(args, 0, "sql")
        binds = list_arg_at(args, 1)
        rows = Cybertrain::DB.with { |c| c.execute(sql, binds) }
        Text.new(Printer.table(rows))
      end

      def tables_command
        sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        rows = Cybertrain::DB.with { |c| c.execute(sql) }
        names = Array.new(0) { "" }
        rows.each { |r| names << Cast.str(r["name"]) }
        Text.new(names.join("\n"))
      end

      def help_command
        text = +""
        text << "Expressions are the template language's (no blocks), plus model names:\n"
        text << "  Article.count, Article.where(title: \"x\").order(id: :desc).limit(5).to_a\n"
        text << "  Article.find(1), Article.find_by(title: \"x\"), Article.first, Article.last\n"
        text << "  Article.create(title: \"x\"), Article.find(1).update(title: \"y\"), Article.find(1).destroy\n"
        text << "  relation: where where_sql where_like order order_sql limit offset page first last find\n"
        text << "            find_by to_a count exists? pluck_str pluck_int pluck_float sum_int sum_float\n"
        text << "            count_by delete_all to_sql create\n"
        text << "  record:   its attributes and view methods, update save destroy reload valid? errors attributes\n"
        text << "  x = expr  keeps a value for later lines; _ is the last value\n"
        text << "Commands:\n"
        text << "  sql \"SELECT ...\"   run SQL and print the rows\n"
        text << "  tables            list the tables\n"
        text << "  help              this text\n"
        text << "  exit, quit        leave (or end the input)\n"
        names = Console.model_names
        text << (names.empty? ? "Models: none" : "Models: #{names.join(", ")}")
        Text.new(text)
      end

      # --- arguments ----------------------------------------------------

      # The keyword arguments (String keys) as the Symbol-keyed Hash that
      # where / update / create take. Seeded with its value types (rule 9).
      def symbol_hash(kwargs)
        out = { id: [nil, 0, 0.0, "", true][0] }
        out.delete(:id)
        kwargs.each { |k, v| out[k.to_s.to_sym] = v }
        out
      end

      def id_hash(id)
        out = { id: [nil, 0, 0.0, "", true][0] }
        out[:id] = id
        out
      end

      # `order(:title)`, `order("title DESC")`, `order(id: :desc)`.
      def order_text(args, kwargs)
        parts = Array.new(0) { "" }
        args.each { |a| parts << Helpers.word_of(a) }
        kwargs.each { |k, v| parts << "#{k} #{Helpers.word_of(v).upcase}" }
        parts.join(", ")
      end

      def self.word_of(v)
        case v
        when Symbol then v.to_s
        when String then "#{v}"
        else ""
        end
      end

      # The trailing "" / 0 are never reached; they type the result (as
      # Interpreter#string_arg does).
      def text_arg_at(args, i, name)
        raise ArgumentError, "wrong number of arguments for '#{name}'" if args.size <= i

        a = args[i]
        case a
        when Symbol then return a.to_s
        when String then return "#{a}"
        end
        raise ArgumentError, "'#{name}' expects a String or a Symbol"
        ""
      end

      def int_arg_at(args, i, name)
        raise ArgumentError, "wrong number of arguments for '#{name}'" if args.size <= i

        a = args[i]
        case a
        when Integer then return a
        end
        raise ArgumentError, "'#{name}' expects an Integer"
        0
      end

      # Argument i as a bind Array, empty when absent.
      def list_arg_at(args, i)
        out = Cast.empty_array
        return out if args.size <= i

        a = args[i]
        case a
        when Time then out << a
        when Array then a.each { |x| out << x }
        else out << a
        end
        out
      end
    end
  end
end
