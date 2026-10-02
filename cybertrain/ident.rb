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
    # Column names that would collide with the generated model: a reader
    # named like a method Cybertrain::Model or Object defines and the
    # framework calls (`errors`, `save`, `attributes`, `hash`, `send`, ...),
    # a Kernel method the model (or app code in the class) calls on implicit
    # self (`raise` above all: Model#save! and #reload would dispatch to the
    # zero-arity reader and die with "wrong number of arguments"), an ivar
    # the model keeps (`errors`, `persisted` -> @errors, @persisted), or a
    # name that breaks the generated source (`class`). `id` is deliberately
    # absent: the primary key is Model#id. Names that end in `?` or `!`
    # cannot be columns at all (column? rejects them), so `valid?`,
    # `persisted?`, `is_a?` need no entry.
    RESERVED_COLUMN_NAMES = [
      # Cybertrain::Model (script/check-reserved-names keeps this in step)
      "errors", "persisted", "attributes", "save", "update", "destroy",
      "reload", "model_name", "to_json", "as_json", "to_param", "to_row",
      "load_row", "set_id", "run_callbacks", "insert_row", "update_row",
      "read_attribute", "write_attribute", "assign_attributes",
      "read_association", "call_view_method", "initialize", "table_name",
      "column_names", "from_row",
      # Object / BasicObject public instance methods (the script checks
      # these too, under CRuby): `then`, `methods`, `send`, ...
      "class", "hash", "object_id", "send", "__send__", "__id__", "freeze",
      "display", "method", "methods", "public_method", "public_methods",
      "private_methods", "protected_methods", "singleton_class",
      "singleton_method", "singleton_methods", "singleton_method_added",
      "singleton_method_removed", "singleton_method_undefined",
      "define_singleton_method", "remove_instance_variable",
      "instance_variable_get", "instance_variable_set", "instance_variables",
      "instance_eval", "instance_exec", "public_send", "dup", "clone", "tap",
      "then", "yield_self", "itself", "extend", "enum_for", "to_enum",
      "inspect", "to_s",
      # Implicit-conversion and dispatch hooks Ruby calls on its own (none is
      # defined on Object, so no reflection finds them): an arity-0 reader
      # returning a String breaks `puts post` / `[post].flatten` / a splat
      # (to_ary), string coercion (to_str), keyword splats (to_hash), `&post`
      # (to_proc), Integer coercion (to_int), and turns every NoMethodError
      # into an ArgumentError (method_missing). `respond_to_missing?` ends in
      # `?` and needs no entry.
      "to_ary", "to_str", "to_hash", "to_proc", "to_int", "to_a", "to_h",
      "to_sym", "to_io", "to_path", "to_regexp", "coerce", "method_missing",
      # Kernel methods the model (or app code in the class) calls on
      # implicit self
      "raise", "fail", "format", "sprintf", "printf", "puts", "print", "p",
      "pp", "warn", "loop", "lambda", "proc", "require", "require_relative",
      "load", "sleep", "exit", "abort", "catch", "throw", "rand", "binding",
      "caller", "eval", "system", "exec", "spawn", "fork", "trap", "open",
      "gets", "at_exit"
    ]

    # Ruby keywords a column could be spelled like: `def end=` /
    # `attr_accessor :class` would not parse or would redefine core
    # behaviour. The uppercase ones are reachable since column? accepts
    # capitals.
    RUBY_KEYWORDS = [
      "alias", "and", "begin", "break", "case", "class", "def", "defined",
      "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
      "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
      "return", "self", "super", "then", "true", "undef", "unless", "until",
      "when", "while", "yield",
      "BEGIN", "END", "__ENCODING__", "__FILE__", "__LINE__"
    ]

    # /\A[A-Za-z_][A-Za-z0-9_]*\z/ spelled out: what Ruby needs of a method
    # name, so a schema with camelCase or mixed-case columns (`createdAt`,
    # `userId`, a legacy SQLite table) generates as it did before this rule
    # existed; `attr_accessor :createdAt` and `attr_accessor :Title` both
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

    def self.keyword?(name)
      RUBY_KEYWORDS.include?(name)
    end

    def self.reserved_column?(name)
      RESERVED_COLUMN_NAMES.include?(name)
    end
  end
end
