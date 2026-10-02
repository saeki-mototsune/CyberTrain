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
      "errors", "persisted", "class", "hash", "object_id", "send", "freeze",
      "display", "method", "instance_variable_get", "instance_variable_set",
      "instance_variables", "public_send", "attributes", "save", "update",
      "destroy", "reload", "model_name", "to_json", "as_json", "to_param",
      "to_row", "load_row", "set_id", "run_callbacks", "insert_row",
      "update_row", "read_attribute", "write_attribute", "assign_attributes",
      "read_association", "call_view_method", "initialize", "table_name",
      "column_names", "from_row", "dup", "clone", "tap", "itself", "extend",
      "inspect", "to_s",
      # Kernel
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
