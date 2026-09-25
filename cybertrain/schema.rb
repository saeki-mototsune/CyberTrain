# Cybertrain::Schema -- the entry point apps use from db/schema.rb:
#
#   Cybertrain::Schema.define(version: "20260924120000") do |s|
#     s.create_table "posts" do |t|
#       t.string "title", null: false
#       t.timestamps
#     end
#   end
#
# `define` builds a Definition and remembers it as `Schema.current` for the
# generator (Task 8's schema_reader) to read back later in the same process.
require "cybertrain/schema/table"
require "cybertrain/schema/definition"

module Cybertrain
  module Schema
    # A module-level @instance_variable with self.x/self.x= accessors,
    # never a `@@class_variable` assigned directly inside `module Schema` --
    # see spikes/NOTES.md rule 18. `@current` starts nil (no schema defined
    # yet) and is fine to assign a Definition directly: the miscompile the
    # rule warns about is specific to assigning a `Time` to a nil-starting
    # ivar, not general objects.
    @current = nil

    def self.define(version: "0")
      definition = Definition.new(version)
      yield definition
      @current = definition
      definition
    end

    def self.current
      @current
    end

    def self.reset!
      @current = nil
    end

    # Minimal, private-in-spirit inflector used only by TableDef#references
    # and Definition#add_foreign_key to guess a table name from a singular
    # reference name and vice versa. Deliberately not the real Inflector:
    # Task 8 ships `Cybertrain::Inflector` with the full rule table and
    # irregulars, and callers should move to that once it exists --
    # TODO(Task 8): switch TableDef#references, Definition#add_foreign_key
    # and Migration::Base#add_reference/#add_foreign_key to
    # Cybertrain::Inflector once it lands, so there are not two diverging
    # inflectors. Handles only the shapes the blog schema needs: trailing
    # "s"/"x"/"z"/"ch"/"sh" -> "es", "y"/"ies", and the plain "s" default;
    # irregulars ("person" -> "people") are out of scope here.
    def self.pluralize(word)
      w = word.to_s
      last_index = w.length - 1
      if last_index >= 0 && w[last_index] == "y" && !vowel_before_y?(w)
        "#{w[0, last_index]}ies"
      elsif es_suffixed?(w)
        "#{w}es"
      else
        "#{w}s"
      end
    end

    def self.singularize(word)
      w = word.to_s
      return "#{w[0, w.length - 3]}y" if w.end_with?("ies")
      if w.end_with?("es")
        stem = w[0, w.length - 2]
        return stem if es_suffixed?(stem)
      end
      return w[0, w.length - 1] if w.end_with?("s")
      w
    end

    # True for the endings that take "-es" rather than a bare "-s" in the
    # plural: box -> boxes, buzz (kept simple as trailing "z") -> buzzes,
    # bus -> buses, church -> churches, dish -> dishes.
    def self.es_suffixed?(w)
      w.end_with?("ch") || w.end_with?("sh") || w.end_with?("s") || w.end_with?("x") || w.end_with?("z")
    end

    # True when the "y" in `w` is preceded by a vowel ("day" -> "days", not
    # "daies"); false (or the word is just "y") pluralizes with "ies".
    def self.vowel_before_y?(w)
      return false if w.length < 2
      before = w[w.length - 2]
      before == "a" || before == "e" || before == "i" || before == "o" || before == "u"
    end
  end
end
