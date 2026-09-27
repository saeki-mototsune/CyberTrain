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
# generator (Gen::Runner, cybertrain/generator/runner.rb) to read back later
# in the same process.
require "cybertrain/generator/inflector"
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
  end
end
