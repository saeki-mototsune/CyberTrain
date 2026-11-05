# Cybertrain::Console -- `./<app> console`: a read-eval-print loop over the
# template expression language (docs/guide: templates), evaluated by the
# template interpreter with Console::Helpers. Spinel has no `eval`, so this is
# not Ruby: it is the language a `<%= %>` tag already speaks, plus model
# names (`Article`), the query methods of a relation, the write methods of a
# record and a few commands (`sql`, `tables`, `help`, `_`, `exit`).
#
#   >> Article.where(title: "x").count
#   1
#   >> Article.find(1).update(title: "y")
#   true
#
# The model names reach the generated models through four module-level
# accessors that the application's generated gen/console.rb sets (a `case`
# table per model: no computed dispatch, spikes/NOTES.md rule 2). Until they
# are set, every model name is an UnknownModel, so this file needs no gen/
# file to compile:
#
#   Console.scope_builder   ->(name) { Relation }            Article -> Article.all
#   Console.records_builder ->(relation) { Array<Model> }    ArticleRelation -> its to_a
#   Console.create_builder  ->(name, attrs) { Model }        Article.create(attrs)
#   Console.model_names     Array<String>                    for errors and `help`
require "json"
require "cybertrain/config"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/relation"
require "cybertrain/template/parser"
require "cybertrain/template/inode"
require "cybertrain/template/interpreter"
require "cybertrain/console/printer"
require "cybertrain/console/helpers"

module Cybertrain
  # The expression console behind `./<app> console`.
  # @api public
  module Console
    # A name that is not one of the application's models (`Nope.count`).
    # @api public
    class UnknownModel < StandardError
    end

    # The defaults: no model is known. Methods rather than lambda literals
    # in the module body, so each lambda is one built by a method (NOTES
    # rule 42), and their raising bodies return the type the real builders
    # return (a Relation, an Array of records, a record).
    def self.no_scope_builder = ->(name) { Console.unknown_model(name) }
    def self.no_records_builder = ->(relation) { Console.no_records(relation) }
    def self.no_create_builder = ->(name, attrs) { Console.unknown_record(name) }

    # Module-level ivars with accessors, not @@class variables (NOTES rules
    # 18 and 64). model_names is seeded with its element type (rule 9).
    @scope_builder = Console.no_scope_builder
    @records_builder = Console.no_records_builder
    @create_builder = Console.no_create_builder
    @model_names = Array.new(0) { "" }

    # @return [Proc] `->(name) { Relation }`: the relation a model name
    #   evaluates to; raises UnknownModel for any other name
    # @api public
    def self.scope_builder = @scope_builder

    # @param builder [Proc]
    # @api public
    def self.scope_builder=(builder)
      @scope_builder = builder
    end

    # @return [Proc] `->(relation) { Array<Model> }`: the records of a
    #   relation, through its per-model `to_a`
    # @api public
    def self.records_builder = @records_builder

    # @param builder [Proc]
    # @api public
    def self.records_builder=(builder)
      @records_builder = builder
    end

    # @return [Proc] `->(name, attrs) { Model }`: `Model.create(attrs)` for a
    #   model name, attrs a `Hash{Symbol => Object}`
    # @api public
    def self.create_builder = @create_builder

    # @param builder [Proc]
    # @api public
    def self.create_builder=(builder)
      @create_builder = builder
    end

    # @return [Array<String>] the application's model class names
    # @api public
    def self.model_names = @model_names

    # @param names [Array<String>]
    # @api public
    def self.model_names=(names)
      @model_names = names
    end

    # Raises UnknownModel for `name`, naming the models there are:
    # `no model "Nope" (models: Article, Comment)`. The `else` of a
    # generated scope / create table calls it. Typed as returning a
    # Relation (never reached), so a lambda that ends in it has the type of
    # the real builder: raise, then a typed value, so the method is never a
    # body whose only expression is `raise` (NOTES rule 79).
    # @param name [String]
    # @return [Relation] never: it always raises
    # @raise [UnknownModel]
    # @api public
    def self.unknown_model(name)
      raise UnknownModel, unknown_model_message(name)
      Relation.new("")
    end

    # {Console.unknown_model} for create_builder: typed as returning a
    # record (raise, then a typed value: NOTES rule 79).
    # @param name [String]
    # @return [Model] never: it always raises
    # @raise [UnknownModel]
    # @api public
    def self.unknown_record(name)
      raise UnknownModel, unknown_model_message(name)
      Model.new
    end

    def self.unknown_model_message(name)
      names = @model_names
      known = names.empty? ? "no models" : "models: #{names.join(", ")}"
      "no model #{name.inspect} (#{known})"
    end

    # An empty Array of records: what the default records_builder returns
    # (no relation reaches it, since no model name resolves), and what a
    # generated records table answers for a relation it does not know.
    # @param relation [Relation]
    # @return [Array<Model>] always empty
    # @api public
    def self.no_records(relation)
      Array.new(0) { Model.new }
    end

    PROMPT = ">> "

    # Reads lines from `input` with `gets` until `exit`, `quit` or the end
    # of input, evaluates each and writes its value (Console::Printer) to
    # `output`. A line that does not parse prints its SyntaxError, a line
    # that raises prints `Class: message`; both continue. `_` is the last
    # value. Production (config.production?) prints a warning first and
    # otherwise behaves the same, as `rails console` does.
    # @param input [IO, StringIO] anything with `gets`
    # @param output [IO, StringIO] anything with `write`
    # @param config [Config] Cybertrain.config
    # @return [Integer] the exit status, 0
    # @api public
    def self.run(input, output, config)
      helpers = Helpers.new
      interp = Template::Interpreter.new(helpers)
      env = Cast.empty_hash
      env["_"] = nil
      output.write(banner_text(config))
      # Flushed before every read: under Spinel `gets` on STDIN does not
      # flush a pending partial line on STDOUT, so the prompt would appear
      # only after the user's line (NOTES rule 83).
      output.flush
      lineno = 0
      running = true
      while running
        output.write(PROMPT)
        output.flush
        line = input.gets
        if line.nil?
          output.write("\n")
          running = false
        else
          lineno += 1
          text = line.to_s.strip
          if text == "exit" || text == "quit"
            running = false
          elsif !text.empty? && !text.start_with?("#")
            output.write(evaluate_line(text, lineno, helpers, interp, env))
          end
        end
      end
      0
    end

    # The lines printed before the first prompt.
    def self.banner_text(config)
      text = +""
      if config.production?
        text << "WARNING: this console runs against the production database (CYBERTRAIN_ENV=production).\n"
        text << "Writes are real: update, destroy, delete_all and sql change data at once.\n"
      end
      text << "Cybertrain console (#{config.env}). Type help for commands, exit to quit.\n"
      text
    end

    # One line's output: its value, or the error it raised, newline-ended.
    # The rescue sits in this plain method (NOTES rules 32/45); JSON's
    # errors are named because they are not StandardErrors under Spinel
    # (rules 33 and 61). The rescued class is spelt from the top
    # (`Cybertrain::Template::...`): a relative `Template::SyntaxError` in a
    # rescue clause is not found (NOTES rule 81).
    def self.evaluate_line(text, lineno, helpers, interp, env)
      helpers.clear_failure
      names = Console.env_names(env)
      shown = ""
      failed = true
      # Every class the console prints is named exactly, from the top: a
      # rescue clause does not see an exception's superclass under Spinel
      # (NOTES rule 54) and a relative path can miss (rule 81).
      begin
        value = evaluate(text, lineno, interp, env)
        env["_"] = value
        shown = "#{Printer.format(value)}\n"
        failed = false
      rescue Cybertrain::Template::SyntaxError => e
        shown = "SyntaxError: #{e.message}\n"
      rescue Cybertrain::Template::RuntimeError => e
        shown = "#{failure_text(helpers, e, lineno)}\n"
      rescue Cybertrain::Console::UnknownModel => e
        shown = "#{failure_text(helpers, e, lineno)}\n"
      rescue Cybertrain::RecordNotFound => e
        shown = "#{failure_text(helpers, e, lineno)}\n"
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        shown = "#{failure_text(helpers, e, lineno)}\n"
      end
      Console.drop_new_names(env, names) if failed
      shown
    end

    # The names bound in the console's environment.
    def self.env_names(env)
      names = Array.new(0) { "" }
      env.each_key { |k| names << k }
      names
    end

    # After a line that raised: forget any name the line bound (a block
    # parameter or local an evaluation left behind when it stopped part
    # way), so the next line sees the environment as it was.
    def self.drop_new_names(env, names)
      stale = Array.new(0) { "" }
      env.each_key { |k| stale << k unless names.include?(k) }
      stale.each { |k| env.delete(k) }
      nil
    end

    # Parses (constants allowed) and evaluates one statement: `x = expr`
    # binds a name for later lines, as a template's `<% x = ... %>` does.
    def self.evaluate(text, lineno, interp, env)
      node = Template::Parser.parse_statement(text, "console", lineno, constants: true)
      case node
      when Template::AssignNode
        value = interp.eval_expr(Template::Compile.convert_node(node.expr), env)
        env[node.var_name] = value
        return value
      end
      interp.eval_expr(Template::Compile.convert_node(node), env)
    end

    # `Class: message`. The interpreter re-raises what a method raised as a
    # Template::RuntimeError carrying the line ("console:3: ..."); the
    # helpers kept the original class and message, which is what is shown
    # (`Cybertrain::RecordNotFound: Couldn't find Article with id=9`).
    def self.failure_text(helpers, error, lineno)
      return "#{Console.short_class_name(helpers.failure_class)}: #{helpers.failure_message}" if helpers.failed?

      message = error.message
      prefix = "console:#{lineno}: "
      message = message[prefix.size, message.size - prefix.size] if message.start_with?(prefix)
      "#{Console.short_class_name(error.class.name)}: #{message}"
    end

    # The console's own errors without their namespace (UnknownModel); a
    # template error is a plain Error; everything else keeps its full name.
    def self.short_class_name(name)
      return name[21, name.size - 21] if name.start_with?("Cybertrain::Console::")
      return "Error" if name == "Cybertrain::Template::RuntimeError"

      name
    end
  end
end
