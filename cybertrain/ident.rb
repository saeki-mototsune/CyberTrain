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
      "errors", "persisted", "attributes", "save", "update", "destroy",
      "reload", "model_name", "to_json", "as_json", "to_param", "to_row",
      "load_row", "set_id", "run_callbacks", "insert_row", "update_row",
      "read_attribute", "write_attribute", "assign_attributes",
      "read_association", "call_view_method", "initialize",
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
      # The one Kernel method the model calls on implicit self (Model#save!
      # and #reload would dispatch `raise RecordInvalid, ...` to the
      # zero-arity reader), and its alias. No other private Kernel method is
      # reserved: `open`, `format`, `load`, `print`, `select`, `test` are
      # ordinary column names and nothing in the generated class calls them.
      "raise", "fail"
    ]

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
      "singleton_method", "singleton_methods", "singleton_method_added",
      "singleton_method_removed", "singleton_method_undefined",
      "define_singleton_method", "remove_instance_variable",
      "instance_variable_get", "instance_variable_set", "instance_variables",
      "instance_eval", "instance_exec", "dup", "clone", "tap", "yield_self",
      "itself", "extend", "enum_for", "to_enum"
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

    # The one definition of "a name the scaffold must not invent": "" when
    # `name` may be chosen, otherwise why not -- "keyword" (RUBY_KEYWORDS) or
    # "reserved" (RESERVED_COLUMN_NAMES): the two kinds the generator RENAMES,
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
      return "reserved" if reserved_column?(name)

      ""
    end
  end
end
