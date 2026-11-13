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
# it: the configured environment must be "test" and the connected
# database `storage/test.sqlite3` itself, a file carrying the mark the
# bundle writes into every database it creates (Database::TEST_MARKER), or
# a private in-memory database. A development or production database is
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

      # The `PRAGMA application_id` the bundle writes into every database it
      # creates ("CyTr", 0x43795472): the positive proof that a file is one
      # `cybertrain test` made and may delete or empty again.
      TEST_MARKER = 0x43795472

      # "" when env and path name a database the per-test clear may empty,
      # else the refusal: never the development or production database
      # ({other_environment}); only in the test environment; and only a
      # private in-memory database, the default test file
      # ({default_test_file?}) or a file carrying {TEST_MARKER}.
      # @return [String]
      def self.refusal(env, path)
        return "" if env == "test" && DB::Connection.private_database?(path)

        file = Database.uri_file(path)
        other = file.empty? ? "" : Database.other_environment(file)
        return "Test::Database refuses to empty #{path}: it is the #{other} database" unless other.empty?
        unless env == "test" && !file.empty?
          return "Test::Database refuses to empty #{path}: not a test database (env #{env})"
        end
        return "" if Database.default_test_file?(file) || Database.marked?(file)

        "Test::Database refuses to empty #{path}: #{NOT_CREATED}"
      end

      # Writes {TEST_MARKER} into the database `connection` is open on, and
      # checkpoints, so the mark is in the file's own header (where
      # {marked?} reads it) and not only in its write-ahead log. What the
      # bundle does to every database it creates.
      # @param connection [Cybertrain::DB::Connection]
      # @return [nil]
      # @api private
      def self.mark!(connection)
        connection.execute("PRAGMA application_id = #{TEST_MARKER}")
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        nil
      end

      # The end of the refusal of an existing file without {TEST_MARKER}.
      NOT_CREATED = "not a database cybertrain test created; delete it yourself or name another file".freeze

      # The environment ("development" or "production") whose database the
      # plain file `file` is, "" when it is neither: named
      # development.sqlite3 or production.sqlite3 in any letter case (or a
      # symlink to such a file), or the same file as storage/<env>.sqlite3
      # (File.identical? when both exist, so a case-insensitive file system
      # or a link cannot hide it; else the absolute paths).
      # @param file [String]
      # @return [String]
      # @api private
      def self.other_environment(file)
        real = Database.real_path(file)
        found = ""
        ["development", "production"].each do |env|
          next unless found.empty?

          name = "#{env}.sqlite3"
          if File.basename(file).downcase == name || (!real.empty? && File.basename(real).downcase == name) ||
             Database.same_file?(file, "storage/#{name}")
            found = env
          end
        end
        found
      end

      # Whether `file` and `other` name one file: File.identical? when both
      # exist, else their absolute paths are equal.
      # @api private
      def self.same_file?(file, other)
        return File.identical?(file, other) if File.exist?(file) && File.exist?(other)

        File.expand_path(file) == File.expand_path(other)
      end

      # Whether `file` is this application's own storage/test.sqlite3 (the
      # working directory's), in any spelling (relative, absolute,
      # `storage//test.sqlite3`): the same file ({same_file?}), whose real
      # file is that name in that directory. Another project's
      # storage/test.sqlite3 is not, nor a storage/test.sqlite3 that is a
      # symlink to another file or into another directory.
      # @param file [String]
      # @return [Boolean]
      # @api private
      def self.default_test_file?(file)
        return false unless Database.same_file?(file, TEST_PATH)
        return true unless File.exist?(file) || File.symlink?(file)

        real = Database.real_path(file)
        return false if real.empty?

        File.basename(real) == File.basename(TEST_PATH) && File.dirname(real) == Database.real_path(File.dirname(TEST_PATH))
      end

      # Whether `file` is a SQLite database carrying {TEST_MARKER}: read from
      # its header (the 4 bytes at 68, big-endian) without opening it with
      # SQLite, so nothing is created or changed.
      # @param file [String]
      # @return [Boolean]
      # @api private
      def self.marked?(file)
        return false unless File.file?(file)

        head = File.binread(file, 100).to_s
        return false unless head.bytesize == 100 && head.byteslice(0, 15) == "SQLite format 3" && head.getbyte(15) == 0

        id = (head.getbyte(68) << 24) | (head.getbyte(69) << 16) | (head.getbyte(70) << 8) | head.getbyte(71)
        id == TEST_MARKER
      end

      # Whether the bundle may delete `file` (and its -wal / -shm) before it
      # creates a new test database there: there is nothing (a dangling
      # symlink counts as nothing, and removing it leaves its target alone),
      # it is the default test file, it carries {TEST_MARKER}, or it is
      # empty with no write-ahead log holding data (an empty file is all a
      # new SQLite database is until its first checkpoint, so a non-empty
      # -wal beside it may be a database).
      # @param file [String]
      # @return [Boolean]
      # @api private
      def self.deletable?(file)
        return true unless File.exist?(file)
        return true if Database.default_test_file?(file) || Database.marked?(file)
        return false unless File.file?(file) && File.size(file).zero?

        wal = "#{file}-wal"
        !File.exist?(wal) || File.size(wal).zero?
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
        # Every name qualified with "main": a TEMP table of the same name
        # would otherwise take an unqualified DELETE, and an ATTACHed
        # database is never the target.
        c.execute("SELECT name FROM \"main\".sqlite_master WHERE type = 'table'").each { |r| present << r["name"].to_s } if clear
        c.execute("PRAGMA foreign_keys = OFF")
        begin
          c.begin!
          if clear
            tables.each { |t| c.execute("DELETE FROM \"main\".\"#{t}\"") }
            FRAMEWORK_TABLES.each { |t| c.execute("DELETE FROM \"main\".\"#{t}\"") if present.include?(t) }
            c.execute("DELETE FROM \"main\".sqlite_sequence") if present.include?("sqlite_sequence")
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
