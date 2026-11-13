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
        other = Database.other_environment(path)
        unless other.empty?
          return "Test::Database refuses to empty #{path}: it is the #{other} database"
        end
        return "" if env == "test" && Database.test_path?(path)

        "Test::Database refuses to empty #{path}: not a test database (env #{env})"
      end

      # The environment ("development" or "production") whose database
      # `path` is, "" when it is neither: a file named development.sqlite3
      # or production.sqlite3 (by its name, or the name of the file a
      # symlink leads to), or the file one of those environments resolves
      # to: storage/<env>.sqlite3, or the `c.database_path` config/app.rb
      # gives it (Cybertrain.other_database_paths, recorded in
      # `cybertrain test`), or the file the shell's CYBERTRAIN_DATABASE
      # names outside a test shell ({shell_other_database}), compared as
      # written, as an absolute path and by real path.
      # @param path [String]
      # @return [String]
      # @api private
      def self.other_environment(path)
        return "" if DB::Connection.private_database?(path)

        file = Database.uri_file(path)
        return "" if file.empty?

        real = Database.real_path(file)
        envs = Array.new(0) { "" }
        paths = Array.new(0) { "" }
        ["development", "production"].each do |env|
          name = "#{env}.sqlite3"
          return env if File.basename(file) == name || (!real.empty? && File.basename(real) == name)

          envs << env
          paths << "storage/#{name}"
        end
        Cybertrain.other_database_envs.each { |env| envs << env }
        Cybertrain.other_database_paths.each { |other| paths << other }
        shell = Database.shell_other_database
        unless shell.empty?
          envs << (@shell_env.empty? ? "development" : @shell_env)
          paths << shell
        end
        i = 0
        while i < paths.length
          return envs[i] if Database.same_file?(file, real, Database.uri_file(paths[i]))

          i += 1
        end
        ""
      end

      # The CYBERTRAIN_ENV and CYBERTRAIN_DATABASE the shell exported, as
      # gen/tests.rb found them before it set the one and deleted the other
      # ({use_shell_database}); "" for unset.
      @shell_env = ""
      @shell_database = ""

      # Hands over the CYBERTRAIN_ENV and CYBERTRAIN_DATABASE the shell
      # exported (gen/tests.rb captures them before its own settings): the
      # exported file is what development (or that environment) uses in
      # this shell, so {other_environment} counts it too.
      # @param env [String] "" when unset
      # @param path [String] "" when unset
      # @return [nil]
      # @api private
      def self.use_shell_database(env, path)
        @shell_env = env
        @shell_database = path
        nil
      end

      # The shell's CYBERTRAIN_DATABASE when it names another environment's
      # file, else "": unset, exported in a test shell (CYBERTRAIN_ENV=test),
      # or a file named test.sqlite3 (also through a symlink) is the test
      # database, not another one.
      # @return [String]
      # @api private
      def self.shell_other_database
        path = @shell_database
        return "" if path.empty? || @shell_env == "test"

        file = Database.uri_file(path)
        return "" if file.empty? || File.basename(file) == "test.sqlite3"

        real = Database.real_path(file)
        return "" if !real.empty? && File.basename(real) == "test.sqlite3"

        file
      end

      # Whether `file` (whose real path is `real`, "" when it does not
      # exist) and `other` name one file.
      # @api private
      def self.same_file?(file, real, other)
        return false if other.empty?
        return true if file == other || File.expand_path(file) == File.expand_path(other)

        !real.empty? && real == Database.real_path(other)
      end

      # storage/test.sqlite3 (relative or under an application), the file
      # CYBERTRAIN_TEST_DATABASE names, or a private in-memory database. A
      # `file:` URI counts by its path only, and one with a query, a
      # fragment or %-escapes is refused (only the in-memory forms are
      # read). A file that exists is judged by its real path as well: a
      # storage/test.sqlite3 that is a symlink to another file, or into
      # another directory, is refused.
      # @return [Boolean]
      def self.test_path?(path)
        return true if DB::Connection.private_database?(path)

        file = Database.uri_file(path)
        return false if file.empty?

        named = ENV["CYBERTRAIN_TEST_DATABASE"].to_s
        unless named.empty?
          same = Database.real_path(file)
          return true if file == named || (!same.empty? && same == Database.real_path(named))
        end
        return false unless file == TEST_PATH || file.end_with?("/#{TEST_PATH}")
        return true unless File.exist?(file) || File.symlink?(file)

        real = Database.real_path(file)
        return false if real.empty?

        File.basename(real) == File.basename(TEST_PATH) && File.dirname(real) == Database.real_path(File.dirname(file))
      end

      # The file a database path names: the path itself, or the path part
      # of a `file:` URI ("" for a URI form this does not read).
      # @return [String]
      def self.uri_file(path)
        return path unless path.start_with?("file:")

        rest = path[5, path.size - 5].to_s
        return "" if rest.include?("?") || rest.include?("#") || rest.include?("%")

        rest = rest[11, rest.size - 11].to_s if rest.start_with?("//localhost/")
        if rest.start_with?("//")
          return "" unless rest.start_with?("///")

          rest = rest[2, rest.size - 2].to_s
        end
        rest
      end

      # The real path of an existing file or directory; "" when there is
      # none (a missing file, a dangling symlink).
      # @return [String]
      def self.real_path(path)
        return "" unless File.exist?(path)

        File.realpath(path)
      rescue JSON::NestingError, JSON::ParserError, StandardError
        ""
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
      # sqlite_sequence; then the inserts, and `PRAGMA foreign_key_check`
      # before the COMMIT (a belongs_to label or id that names no row:
      # spec section 7's foreign-key failure, which turning foreign keys on
      # again would not report). On a failure it rolls back, turns foreign
      # keys on again and re-raises. Refused inside an open transaction,
      # whose rows the deletes would join.
      def self.reset_on(c, clear, tables, sql, counts, now)
        if c.in_transaction?
          message = "Test::Database cannot clear or load fixtures inside an open transaction (DB.transaction or a BEGIN)"
          raise message
        end
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
          problem = sql.empty? ? "" : Database.foreign_key_problem(c)
          raise problem unless problem.empty?

          c.commit!
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          Database.restore_after_failure(Database.rollback_step(c), Database.foreign_keys_step(c))
          raise e
        end
        c.execute("PRAGMA foreign_keys = ON")
        nil
      end

      # The first row PRAGMA foreign_key_check reports, as a message
      # ("" when there is none): its table, its id (the fixture's id), the
      # column and the parent table it names no row of.
      # @return [String]
      def self.foreign_key_problem(c)
        rows = c.execute("PRAGMA foreign_key_check")
        return "" if rows.empty?

        r = rows[0]
        table = r["table"].to_s
        parent = r["parent"].to_s
        rowid = Cybertrain::Cast.int(r["rowid"])
        fkid = Cybertrain::Cast.int(r["fkid"])
        column = ""
        c.execute("PRAGMA foreign_key_list(\"#{table}\")").each { |f| column = f["from"].to_s if Cybertrain::Cast.int(f["id"]) == fkid }
        value = ""
        unless column.empty?
          found = c.execute("SELECT \"#{column}\" AS v FROM \"#{table}\" WHERE rowid = ?", [rowid])
          value = Cybertrain::Cast.int(found[0]["v"]).to_s unless found.empty?
        end
        "fixtures: #{table} row with id #{rowid} has #{column} #{value}, which names no row of #{parent} " \
          "(a belongs_to label or id with no fixture in test/fixtures/#{parent}.yml)"
      end

      # After a failure: the rollback, then foreign keys on again, each
      # attempted whatever the other did; neither may replace the error
      # being re-raised.
      # @param rollback [Proc]
      # @param foreign_keys_on [Proc]
      # @return [nil]
      def self.restore_after_failure(rollback, foreign_keys_on)
        Database.attempt(rollback)
        Database.attempt(foreign_keys_on)
        nil
      end

      def self.attempt(step)
        step.call
        nil
      rescue JSON::NestingError, JSON::ParserError, StandardError
        nil
      end

      def self.rollback_step(c)
        -> {
          c.rollback!
          nil
        }
      end

      def self.foreign_keys_step(c)
        -> {
          c.execute("PRAGMA foreign_keys = ON")
          nil
        }
      end
    end
  end
end
