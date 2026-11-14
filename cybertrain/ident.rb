# Cybertrain::Ident -- the one place that says what a column (or scaffold
# field) may be called. Used by the generator (ModelsEmitter), the ORM
# (Relation#order) and the CLI (`cybertrain generate scaffold`), so a name
# the scaffold accepts is a name the generator and the models accept, and
# the failure comes from the command that would write the files.
#
# Plain Ruby with no requires: the CLI gem ships this file and runs it under
# CRuby, the framework compiles it under Spinel (no Regexp, NOTES rule 1).
module Cybertrain
  module Ident
    # Column names whose plain reader the generated class cannot host: it
    # would shadow a method the generated class or the framework calls on the
    # record. The generator renames them, so an existing schema keeps
    # generating: the column reads as `<column>_column`
    # (ModelsEmitter.reader_name). The scaffold refuses them: its views and
    # controller call the reader by the field's name, which a renamed reader
    # would break. `id` is deliberately
    # absent: the primary key is Model#id. Names that end in `?` or `!`
    # cannot be columns at all (column? rejects them), so `valid?`,
    # `persisted?`, `is_a?` need no entry; keywords (`class`) live in
    # RUBY_KEYWORDS only, and the generator renames those the same way
    # (`class_column`). Class methods (`table_name`, `column_names`,
    # `from_row`) need no entry either: the framework calls them on the
    # class (`self.class.table_name`, `Post.from_row`), which a column
    # reader on the instance does not shadow, so a schema with a
    # `table_name` column keeps generating. script/check-reserved-names
    # keeps the Model and Object groups here and in SHADOWING_COLUMN_NAMES
    # in step with the code (it skips `def self.` methods).
    RESERVED_COLUMN_NAMES = [
      # Cybertrain::Model: its methods and the ivars behind them (`errors`,
      # `persisted` -> @errors, @persisted)
      "errors", "persisted", "attributes", "save", "update", "update_columns", "destroy",
      "reload", "model_name", "to_json", "as_json", "to_param", "to_row",
      "load_row", "set_id", "run_callbacks", "insert_row", "update_row",
      "read_attribute", "write_attribute", "assign_attributes",
      "read_association", "call_view_method", "initialize",
      "create_with_callbacks", "update_with_callbacks", "destroy_with_callbacks",
      # declared associations: dependent:, the caches reload clears,
      # counter_cache
      "destroy_dependents", "reset_association_caches", "counter_cache_created",
      "counter_cache_destroyed", "counter_cache_was", "counter_cache_moved", "counter_cache_columns",
      # validations: the generated `validate :method` calls (unique_value_taken?
      # and validation_condition? end in `?` and need no entry)
      "run_custom_validations",
      # Object methods Ruby or the framework calls on a record without being
      # asked: string interpolation and templates (to_s), error messages
      # (inspect), Hash keys (hash)
      "hash", "inspect", "to_s",
      # Implicit-conversion and dispatch hooks Ruby calls on its own (none is
      # defined on Object, so no reflection finds them): an arity-0 reader
      # returning a String breaks `puts post` / `[post].flatten` / a splat
      # (to_ary), string coercion (to_str), keyword splats (to_hash), `&post`
      # (to_proc), Integer coercion (to_int), and turns every NoMethodError
      # into an ArgumentError (method_missing). `respond_to_missing?` ends in
      # `?` and needs no entry.
      "to_ary", "to_str", "to_hash", "to_proc", "to_int", "to_a", "to_h",
      "to_sym", "to_io", "to_path", "to_regexp", "coerce", "method_missing",
      # Hooks Ruby itself calls WITH an argument, which it finds whether they
      # are public or private (so Object.instance_methods never lists the
      # private ones): `record.dup` / `clone` call initialize_copy(orig)
      # (initialize_dup / initialize_clone on the way), and defining, removing
      # or undefining a singleton method (`def record.x`) calls
      # singleton_method_added / _removed / _undefined. A zero-arity column
      # reader in their place raises ArgumentError at that call. These are
      # reserved, not merely shadowing: the problem is Ruby's call, not a
      # method the caller could have wanted. script/check-reserved-names
      # fails when one of Ruby's private hooks is missing here.
      "initialize_copy", "initialize_dup", "initialize_clone",
      "singleton_method_added", "singleton_method_removed",
      "singleton_method_undefined",
      # The one Kernel method the model calls on implicit self (Model#save!
      # and #reload would dispatch `raise RecordInvalid, ...` to the
      # zero-arity reader), and its alias. No other private Kernel method is
      # reserved: `open`, `format`, `load`, `print`, `select`, `test` are
      # ordinary column names and nothing in the generated class calls them.
      "raise", "fail",
      # Names of framework methods that answer different types
      # (UNTYPED_FRAMEWORK_NAMES says why; its wording replaces the
      # Model-method one in the messages about these).
      "handle"
    ]

    # The RESERVED_COLUMN_NAMES entries that are there because framework
    # methods of that name answer different types, to those methods: a
    # reader of the name would be one more definer, and one method name
    # answers one type across a program (spikes/NOTES.md rules 10, 34), so
    # no column type can match. They are not methods of Cybertrain::Model
    # or Object, so the generator's rename note (which also tells that the
    # application's calls change), its "fallback taken" error and the
    # scaffold's refusal (unusable_reason "framework") name these methods
    # instead. A name whose framework method answers one fixed type is not
    # here: gen accepts such a column when its reader answers that type
    # (FRAMEWORK_METHOD_TYPES). script/check-reserved-names checks that each
    # is in RESERVED_COLUMN_NAMES.
    UNTYPED_FRAMEWORK_NAMES = {
      "handle" => "Cybertrain::ErrorReporter#handle (its block's value), Cybertrain::Server#handle (a Response) " \
                  "and the jobs subsystem's handle (nil)"
    }

    # Column names that are also the name of a framework method with one
    # fixed return type, to that type as reader_type spells it. A column's
    # reader is a method of that name too, and one method name answers one
    # type across a program (spikes/NOTES.md rules 10, 34): otherwise the
    # build stops with a type error in Spinel's output, far from the
    # schema. So the generator (Gen::ModelValidation.check_framework_type)
    # accepts such a column when its reader answers this type and refuses
    # it otherwise, naming the method (FRAMEWORK_METHODS), and the scaffold
    # (Scaffold.refuse_framework_type!) refuses such a field before it writes
    # anything; both read this one table and reader_type. A String column
    # that is nullable reads as "String or nil" and is accepted beside a
    # String method (type_fits?): under Spinel a String is a nullable
    # pointer, the same C type with or without nil (rule 109), and
    # test/framework_names_compiles.rb compiles and runs both beside
    # Request#request_id and Config#release. A name whose framework methods
    # have no single type is in UNTYPED_FRAMEWORK_NAMES instead.
    # script/check-reserved-names reads this table: a framework method added
    # under one of these names must answer the type here, and a name in
    # RESERVED_COLUMN_NAMES must not be here.
    FRAMEWORK_METHOD_TYPES = { "request_id" => "String", "release" => "String" }

    # The framework method behind each FRAMEWORK_METHOD_TYPES name, as the
    # refusals name it.
    FRAMEWORK_METHODS = { "request_id" => "Cybertrain::Request#request_id", "release" => "Cybertrain::Config#release" }

    # The rest of Object's public instance methods: a column so named shadows
    # them on its model (`record.display`, `record.tap` are the column), but
    # neither the generated class nor the framework calls any of them on a
    # record, so the generator accepts the column and writes a note into the
    # generated file instead of refusing an existing schema. The scaffold
    # accepts them the same way, with a note on stdout (Scaffold.shadow_notes):
    # `payment.method` is the field, which its views and controller call.
    SHADOWING_COLUMN_NAMES = [
      "object_id", "__id__", "send", "__send__", "public_send", "freeze",
      "display", "method", "methods", "public_method", "public_methods",
      "private_methods", "protected_methods", "singleton_class",
      "singleton_method", "singleton_methods", "define_singleton_method",
      "remove_instance_variable", "instance_variable_get",
      "instance_variable_set", "instance_variables", "instance_eval",
      "instance_exec", "dup", "clone", "tap", "yield_self", "itself",
      "extend", "enum_for", "to_enum"
    ]

    # Ruby keywords a column could be spelled like: `@end` / `def class` are
    # not shapes worth supporting. The generator reads such a column as
    # `<column>_column` (ModelsEmitter.reader_name), like a reserved name;
    # the scaffold refuses them (its views call the reader by name). The
    # uppercase ones are reachable since column? accepts capitals. `defined`
    # is not here: the keyword is `defined?`, which column? rejects, and
    # `defined` is an ordinary method name (`attr_accessor :defined` works).
    RUBY_KEYWORDS = [
      "alias", "and", "begin", "break", "case", "class", "def", "do",
      "else", "elsif", "end", "ensure", "false", "for", "if", "in",
      "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
      "return", "self", "super", "then", "true", "undef", "unless", "until",
      "when", "while", "yield",
      "BEGIN", "END", "__ENCODING__", "__FILE__", "__LINE__"
    ]

    # /\A[A-Za-z_][A-Za-z0-9_]*\z/ spelled out: what Ruby needs of a method
    # name, so a schema with camelCase or mixed-case columns (`createdAt`,
    # `userId`, a legacy SQLite table) generates under its own name, not a
    # renamed one; `attr_accessor :createdAt` and `attr_accessor :Title` both
    # compile and dispatch under Spinel (probed on 2026.09.12). The
    # scaffold, which chooses new names, keeps the stricter snake_case rule
    # (CLI::Templates.identifier?). A flag rather than a `return` inside
    # the block, like Templates.identifier?: a `return` from an each_char
    # block does leave the method under Spinel (probed), but the flag needs
    # no such guarantee.
    def self.column?(name)
      return false if name.empty?

      ok = true
      first = true
      name.each_char do |ch|
        letter = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
        digit = ch >= "0" && ch <= "9"
        ok = false unless letter || ch == "_" || (digit && !first)
        first = false
      end
      ok
    end

    # The snake_case subset of column?: lowercase only, and a leading `_`
    # only when allowed. CLI::Templates.identifier? (app, resource and field
    # names: letter-first) and Template::Lexer.identifier? (template locals
    # and block parameters: `_x` allowed) are both this predicate, so the two
    # cannot drift. A positional default rather than a keyword argument: this
    # file compiles under Spinel and keeps to the shapes it already uses.
    def self.snake_case?(word, leading_underscore = true)
      column?(word) && word == word.downcase && (leading_underscore || !word.start_with?("_"))
    end

    def self.keyword?(name)
      RUBY_KEYWORDS.include?(name)
    end

    def self.reserved_column?(name)
      RESERVED_COLUMN_NAMES.include?(name)
    end

    def self.shadowing_column?(name)
      SHADOWING_COLUMN_NAMES.include?(name)
    end

    # Whether `name` is reserved because framework methods of that name
    # answer different types (UNTYPED_FRAMEWORK_NAMES).
    def self.untyped_framework_name?(name)
      UNTYPED_FRAMEWORK_NAMES.key?(name)
    end

    # The Ruby type the generated reader of a column of schema type `type`
    # (a Symbol: :string, :integer, ...) answers, as the refusals spell it:
    # the type of the Cast helper the model reads it through
    # (Gen::ModelsEmitter.cast_for), with " or nil" when `null` and for every
    # datetime column (time_or_nil). A binary column is a String of bytes;
    # an encrypted one is a string or text column, a String.
    def self.reader_type(type, null)
      base = if type == :integer
               "Integer"
             elsif type == :float || type == :decimal
               "Float"
             elsif type == :boolean
               "true or false"
             elsif type == :datetime
               "Time"
             elsif type == :date
               "Date"
             elsif type == :json
               "Hash"
             else
               "String"
             end
      null || type == :datetime ? base + " or nil" : base
    end

    # The type a reader named `name` must answer because a framework method
    # has the name (FRAMEWORK_METHOD_TYPES), "" for any other name.
    def self.framework_type(name)
      FRAMEWORK_METHOD_TYPES.key?(name) ? FRAMEWORK_METHOD_TYPES[name].to_s : ""
    end

    # The framework method behind a FRAMEWORK_METHOD_TYPES name, "" for any
    # other name.
    def self.framework_method(name)
      FRAMEWORK_METHODS.key?(name) ? FRAMEWORK_METHODS[name].to_s : ""
    end

    # Whether a reader answering `got` (reader_type's spelling) may stand
    # beside a framework method answering `want`: the same type, or a
    # nullable String beside a String (FRAMEWORK_METHOD_TYPES says why).
    def self.type_fits?(want, got)
      got == want || (want == "String" && got == "String or nil")
    end

    # The framework methods behind an UNTYPED_FRAMEWORK_NAMES entry, as the
    # messages name them; "" for any other name.
    def self.untyped_framework_methods(name)
      untyped_framework_name?(name) ? UNTYPED_FRAMEWORK_NAMES[name].to_s : ""
    end

    # The one definition of "a name the scaffold must not invent": "" when
    # `name` may be chosen, otherwise why not -- "keyword" (RUBY_KEYWORDS),
    # "framework" (UNTYPED_FRAMEWORK_NAMES, the part of
    # RESERVED_COLUMN_NAMES with its own message) or "reserved" (the rest
    # of RESERVED_COLUMN_NAMES): the kinds the generator RENAMES,
    # which the scaffold cannot accept because its views and controller call
    # the reader by the field's name. A SHADOWING_COLUMN_NAMES entry is not
    # refused: the generator keeps its name with a note, and so does the
    # scaffold (shadowing_column?). The scaffold asks here at every place it
    # takes a name from the user (field column, references reader, resource
    # singular) and raises the message for the reason, so a new list of names
    # is added to this method once, not to each call site. A String, not nil
    # or a Symbol, so the return type is the same on every path (NOTES rules
    # 10/34); a keyword that is also listed in a column array reports
    # "keyword" first.
    def self.unusable_reason(name)
      return "keyword" if keyword?(name)
      return "framework" if untyped_framework_name?(name)
      return "reserved" if reserved_column?(name)

      ""
    end
  end
end
