# Cybertrain::Test::Database -- steps 1 and 2 of one bundled test (spec
# sections 5.3, 6 and 7; plan decision D8): the database is emptied, then
# the fixtures are inserted. `cybertrain test`'s program (gen/tests.rb)
# registers both through Test.before_each_bundled:
#
#   def self.fixtures_hook
#     -> {
#       Cybertrain::Test::Database.clear_and_load!(Gen::TestData::TABLES, Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS)
#       nil
#     }
#   end
#   Cybertrain::Test.before_each_bundled(Gen::Tests.fixtures_hook)
#
# gen/tests.rb registers both in one call, Database.clear_and_load!, one
# transaction for the clear and the inserts together (plan decision D8);
# clear! and load_fixtures! are the same steps as a transaction each.
#
# Not Rails' transactional tests: every table's rows are deleted instead
# (spec section 6 says why). Each transaction is on one connection, with
# `PRAGMA foreign_keys = OFF` around it (a no-op inside a transaction, so
# it brackets the BEGIN and the COMMIT).
#
# Both steps refuse a database that is not a test one, before touching
# it: the configured environment must be "test" and the connected file
# `storage/test.sqlite3`, the file CYBERTRAIN_TEST_DATABASE names, or a
# private in-memory database. A development or production database is
# never emptied, whatever a program connected to.
#
# Spinel rules followed: 58 (messages built into a local before raise), 33
# (the rescue names JSON's errors with StandardError), 67 (only plain
# methods are called on DB.with's connection).
require "json"
require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/model"
require "cybertrain/config"

module Cybertrain
  module Test
    # What a fixture accessor raises for a label its file does not have
    # (`posts(:three)`).
    # @api public
    class FixtureNotFound < StandardError
    end

    # The fixture's id, for the generated accessors: the id at label's
    # position in `labels`.
    # @param set [String] the fixture file's table (`"posts"`)
    # @param label [Symbol, String] the label (`:one`)
    # @param labels [Array<String>] the file's labels (Gen::TestData::LABELS_<set>)
    # @param ids [Array<Integer>] their ids, parallel
    # @return [Integer]
    # @raise [Cybertrain::Test::FixtureNotFound] "No fixture named 'three'
    #   found for fixture set 'posts'"
    # @api private
    def self.fixture_id(set, label, labels, ids)
      name = label.to_s
      i = labels.index(name)
      if i.nil?
        message = "No fixture named '#{name}' found for fixture set '#{set}'"
        raise FixtureNotFound, message
      end
      ids[i.to_i]
    end

    # The bundle's per-test clear and fixture load.
    # @api private
    module Database
      # The framework's own tables (created on first use, not in
      # db/schema.rb), emptied with the application's when they exist.
      FRAMEWORK_TABLES = %w[cybertrain_jobs cybertrain_cache cybertrain_messages cybertrain_schedules cybertrain_feeds cybertrain_leases].freeze

      # The test database's file under the application.
      TEST_PATH = "storage/test.sqlite3".freeze

      # Deletes every row of `tables` (db/schema.rb's, Gen::TestData::TABLES)
      # and of the framework tables present, and empties sqlite_sequence so
      # ids start again at 1: one transaction, foreign keys off.
      # @param tables [Array<String>]
      # @return [nil]
      # @raise [RuntimeError] when the database is not a test database
      #   (nothing is deleted)
      def self.clear!(tables)
        Database.refuse_unless_test_database
        DB.with { |c| Database.clear_on(c, tables) }
        nil
      end

      # Runs each fixture INSERT, binding its `?`s (counts[i] of them) to
      # the Clock's time (Model.now_string): one transaction, foreign keys
      # off, as Rails' disable_referential_integrity.
      # @param sql [Array<String>] Gen::TestData::FIXTURE_SQL
      # @param counts [Array<Integer>] Gen::TestData::FIXTURE_TIMESTAMPS
      # @return [nil]
      # @raise [RuntimeError] when the database is not a test database
      def self.load_fixtures!(sql, counts)
        Database.refuse_unless_test_database
        now = Cybertrain::Model.now_string
        DB.with { |c| Database.load_on(c, sql, counts, now) }
        nil
      end

      # Steps 1 and 2 in one transaction (what the bundle runs before each
      # test): the clear of {clear!}, then the inserts of {load_fixtures!},
      # committed together, foreign keys off around them.
      # @param tables [Array<String>] Gen::TestData::TABLES
      # @param sql [Array<String>] Gen::TestData::FIXTURE_SQL
      # @param counts [Array<Integer>] Gen::TestData::FIXTURE_TIMESTAMPS
      # @return [nil]
      # @raise [RuntimeError] when the database is not a test database
      #   (nothing is deleted)
      def self.clear_and_load!(tables, sql, counts)
        Database.refuse_unless_test_database
        now = Cybertrain::Model.now_string
        DB.with { |c| Database.reset_on(c, true, tables, sql, counts, now) }
        nil
      end

      # "" when env and path name a test database, else the refusal.
      # @return [String]
      def self.refusal(env, path)
        return "" if env == "test" && Database.test_path?(path)

        "Test::Database refuses to empty #{path}: not a test database (env #{env})"
      end

      # storage/test.sqlite3 (relative or under an application), the file
      # CYBERTRAIN_TEST_DATABASE names, or a private in-memory database.
      # @return [Boolean]
      def self.test_path?(path)
        return true if DB::Connection.private_database?(path)

        named = ENV["CYBERTRAIN_TEST_DATABASE"].to_s
        return true if !named.empty? && path == named

        path == TEST_PATH || path.end_with?("/#{TEST_PATH}")
      end

      def self.refuse_unless_test_database
        message = Database.refusal(Cybertrain.config.env, DB.connected_path)
        raise message unless message.empty?

        nil
      end

      def self.clear_on(c, tables)
        Database.reset_on(c, true, tables, Array.new(0) { "" }, Array.new(0) { 0 }, "")
      end

      def self.load_on(c, sql, counts, now)
        Database.reset_on(c, false, Array.new(0) { "" }, sql, counts, now)
      end

      # One transaction, foreign keys off around it: with `clear`, the
      # deletes of `tables`, of the framework tables present and of
      # sqlite_sequence; then the inserts. On a failure it rolls
      # back, turns foreign keys on again and re-raises.
      def self.reset_on(c, clear, tables, sql, counts, now)
        present = Array.new(0) { "" }
        c.execute("SELECT name FROM sqlite_master WHERE type = 'table'").each { |r| present << r["name"].to_s } if clear
        c.execute("PRAGMA foreign_keys = OFF")
        begin
          c.begin!
          if clear
            tables.each { |t| c.execute("DELETE FROM \"#{t}\"") }
            FRAMEWORK_TABLES.each { |t| c.execute("DELETE FROM \"#{t}\"") if present.include?(t) }
            c.execute("DELETE FROM sqlite_sequence") if present.include?("sqlite_sequence")
          end
          i = 0
          while i < sql.size
            binds = Array.new(counts[i]) { now }
            c.execute(sql[i], binds)
            i += 1
          end
          c.commit!
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          c.rollback!
          c.execute("PRAGMA foreign_keys = ON")
          raise e
        end
        c.execute("PRAGMA foreign_keys = ON")
        nil
      end
    end
  end
end
