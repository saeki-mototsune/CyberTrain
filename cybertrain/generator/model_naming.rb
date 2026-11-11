require "cybertrain/schema"
require "cybertrain/generator/inflector"
require "cybertrain/ident"

module Cybertrain
  module Gen
    # The names a table and its columns carry in a generated model: the
    # class, the file, a column's reader and ivar. Both the semantic
    # validation (ModelValidation) and the emitter (ModelsEmitter, which
    # answers the same names by delegating here) spell them, so they live
    # below both.
    module ModelNaming
      # "posts" -> "Post"; "blog_posts" -> "BlogPost".
      def self.model_class_name(table)
        Inflector.camelize(Inflector.singularize(table.to_s))
      end

      # "posts" -> "post.rb".
      def self.file_name(table)
        Inflector.singularize(table.to_s) + ".rb"
      end

      # The tables that get a model: every table but an `id: false` one (a
      # join table, or a table a dump found without an id primary key),
      # which is reached with DB.with.
      def self.modelled_tables(definition)
        definition.tables.reject { |t| t.without_id? }
      end

      # The Ruby name a column's reader, writer and ivar carry: the column's
      # own name, except for Ident::RESERVED_COLUMN_NAMES and Ruby keywords
      # (Ident::RUBY_KEYWORDS), which take `<column>_column`. This is the one
      # place that decides it. A reader named `errors`, `save`, `hash` or
      # `to_ary` would shadow a method of Cybertrain::Model or Object that
      # the framework (or Ruby itself) calls on the record, and an ivar named
      # `@errors` / `@persisted` is one the Model owns; a keyword column
      # (`end`, `begin`, `class`) would need `def class` / `@class`, which is
      # not a shape worth supporting. All of them are renamed; everything
      # keyed by the column's SQL name (column_names, to_row, load_row,
      # params) stays keyed by it; read_attribute / write_attribute answer
      # both spellings (attribute_keys), so a template, which reaches a column
      # through read_attribute, can always use the Ruby name. The query API
      # (Relation#where / order / find_by, order_sql) does not: Relation is
      # built from a table name and knows no per-model rename table, and a
      # column is its SQL name there, so `Post.where(hash: 1)` is right and
      # `Post.where(hash_column: 1)` is "no such column". The Ruby name is the
      # reader, the writer, the constructor key and the template name only
      # (rename_note says so beside the accessor). An existing
      # schema must keep generating on upgrade, so such a column is renamed
      # rather than refused (`cybertrain generate scaffold` still refuses to
      # invent one).
      def self.reader_name(column_name)
        renamed?(column_name) ? column_name + "_column" : column_name
      end

      # Whether reader_name renames the column.
      def self.renamed?(column_name)
        Ident.reserved_column?(column_name) || Ident.keyword?(column_name)
      end

      # The ivar behind reader_name.
      def self.ivar_name(column_name)
        "@" + reader_name(column_name)
      end

      # Same note a column gets (emit_model_head) when the reader's name is an
      # Object method nothing in Cybertrain calls on a record: the association
      # keeps its name, the generated file says what it shadows.
      def self.shadow_note(what, name)
        "# NOTE: #{what} #{name.inspect} shadows Object##{name} on this model (nothing in " \
          "Cybertrain calls it on a record; Ident::SHADOWING_COLUMN_NAMES)"
      end

      # "sender_id" -> "sender"; a column without the suffix is its own stem.
      def self.column_stem(column)
        column.end_with?("_id") ? column[0, column.size - 3] : column
      end
    end
  end
end
