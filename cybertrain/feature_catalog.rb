# Cybertrain::FeatureCatalog -- what each optional subsystem's require line
# brings, as data (docs/superpowers/specs/2026-11-13-optional-subsystems-design.md,
# sections 3 and 5): its view helpers, its roles and commands, and what the
# line loads besides. One table for the two places that tell an
# application which line it is missing: `spin run gen`, which refuses a
# view calling a helper of a subsystem bin/NAME.rb does not require
# (Gen::ViewRequires), and the binary, whose `worker`, `jobs` and `feeds`
# say which line they need (Main.missing_subsystem).
#
# A leaf: no require, nothing but Strings and Arrays of them, so it loads
# under CRuby (the generators) and compiles under Spinel (the core and
# gen), and names no subsystem class (script/check-core-closure).
module Cybertrain
  module FeatureCatalog
    # One row per subsystem line: name, require line, view helpers, roles,
    # commands, other subsystems the line loads (lists space-separated).
    # turbo_frame_tag and dom_id are the core's, not streams'.
    ROWS = [
      ["jobs", "cybertrain/jobs", "", "worker", "jobs", ""],
      ["streams", "cybertrain/streams", "turbo_stream_from turbo_stream signed_stream_name stream_source_path", "", "", ""],
      ["feeds", "cybertrain/feeds", "", "feeds", "", ""],
      ["mailer", "cybertrain/mailer", "", "", "", ""],
      ["mailer/later", "cybertrain/mailer/later", "", "", "", "mailer jobs"],
      ["cache", "cybertrain/cache", "", "", "", ""],
      ["rate_limit", "cybertrain/rate_limit", "", "", "", "cache"]
    ].freeze

    # Other framework files whose require loads a subsystem: [require
    # line, subsystem].
    ALSO_LOADED_BY = [
      ["cybertrain/websocket", "feeds"]
    ].freeze

    # The line that loads every subsystem.
    EVERYTHING = "cybertrain"

    # Every subsystem's name, in the table's order.
    # @return [Array<String>]
    def self.subsystem_names
      out = Array.new(0) { "" }
      ROWS.each { |row| out << row[0] }
      out
    end

    # The require line of the subsystem `name` ("cybertrain/jobs"); "" for
    # an unknown name.
    # @param name [String]
    # @return [String]
    def self.require_line(name)
      i = 0
      while i < ROWS.size
        return ROWS[i][1] if ROWS[i][0] == name

        i += 1
      end
      ""
    end

    # The subsystem whose view helper `helper` is; "" for a core helper or
    # an application's.
    # @param helper [String]
    # @return [String]
    def self.helper_subsystem(helper)
      i = 0
      while i < ROWS.size
        return ROWS[i][0] if ROWS[i][2].split(" ").include?(helper)

        i += 1
      end
      ""
    end

    # Every subsystem's view helpers.
    # @return [Array<String>]
    def self.view_helpers
      out = Array.new(0) { "" }
      ROWS.each { |row| row[2].split(" ").each { |h| out << h } }
      out
    end

    # The subsystems `require "LINE"` loads: all of them for "cybertrain",
    # the line's own and those it loads besides, none for another line.
    # @param line [String] the require's argument
    # @return [Array<String>]
    def self.loaded_by(line)
      return subsystem_names if line == EVERYTHING

      out = Array.new(0) { "" }
      ROWS.each do |row|
        next unless row[1] == line

        out << row[0]
        row[5].split(" ").each { |also| out << also }
      end
      ALSO_LOADED_BY.each { |pair| out << pair[1] if pair[0] == line }
      out
    end

    # What `./NAME WORD` prints when WORD is a role or command of a
    # subsystem this binary did not load: `the worker role needs require
    # "cybertrain/jobs" in bin/NAME.rb`. "" when WORD is no subsystem's.
    # @param word [String]
    # @param name [String] the binary's name
    # @return [String]
    def self.missing_command_message(word, name)
      i = 0
      while i < ROWS.size
        row = ROWS[i]
        kind = ""
        kind = "role" if row[3].split(" ").include?(word)
        kind = "command" if row[4].split(" ").include?(word)
        return "the #{word} #{kind} needs require \"#{row[1]}\" in bin/#{name}.rb" unless kind.empty?

        i += 1
      end
      ""
    end

    # What gen prints for a view calling a helper of a subsystem bin/NAME.rb
    # does not require.
    # @param path [String] the view, relative to the application
    # @param line [Integer]
    # @param helper [String]
    # @param name [String] the binary's name
    # @return [String]
    def self.missing_helper_message(path, line, helper, name)
      "#{path}:#{line}: #{helper} needs require \"#{require_line(helper_subsystem(helper))}\" in bin/#{name}.rb"
    end
  end
end
