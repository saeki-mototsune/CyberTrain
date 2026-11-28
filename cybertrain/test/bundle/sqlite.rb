# Cybertrain::Test::Bundle's database on SQLite (cybertrain/test/bundle,
# the SQLite bundle, requires it after cybertrain/test/bundle/common):
# Bundle.refusal, whether the configured file may be deleted, and
# Bundle.fresh_database, the file deleted and created again, marked and
# migrated. cybertrain/test/bundle/mysql.rb is the same on MySQL.
require "cybertrain/test/bundle/common"

module Cybertrain
  module Test
    module Bundle
      # The database `cybertrain test` may delete: storage/test.sqlite3, or
      # the file CYBERTRAIN_TEST_DATABASE names.
      DEFAULT_DATABASE = "storage/test.sqlite3".freeze

      # Why boot must not delete the configured database ("" when it may),
      # decided before anything is opened, in this order:
      # CYBERTRAIN_TEST_DATABASE (or the configured path) is `:memory:` or a
      # `file:` URI (only a plain path is taken); the path is the
      # development or production database (Database.other_environment:
      # named development.sqlite3 or production.sqlite3, or the same file as
      # storage/<env>.sqlite3); the environment is not test, or the path is
      # neither storage/test.sqlite3 nor the one CYBERTRAIN_TEST_DATABASE
      # names; or the file exists and is not one `cybertrain test` created
      # (Database.deletable?: without Database::TEST_MARKER, and not
      # storage/test.sqlite3 itself).
      # @return [String]
      def self.refusal
        c = Cybertrain.config
        path = c.database_path
        named = ENV["CYBERTRAIN_TEST_DATABASE"].to_s
        unless named.empty? || Bundle.plain_path?(named)
          return "cybertrain test refuses CYBERTRAIN_TEST_DATABASE #{named.inspect}: name the test database by its file path " \
                 "(not :memory: or a file: URI)"
        end
        unless Bundle.plain_path?(path)
          return "cybertrain test refuses the database #{path.inspect}: name the test database by its file path " \
                 "(not :memory: or a file: URI)"
        end
        other = Database.other_environment(path)
        return "cybertrain test refuses to delete #{path}: it is the #{other} database" unless other.empty?
        # The same file in any spelling (absolute, `storage//test.sqlite3`).
        default = Database.same_file?(path, DEFAULT_DATABASE)
        unless c.env == "test" && (default || (!named.empty? && Database.same_file?(path, named)))
          return "cybertrain test refuses to delete #{path}: not a test database (env #{c.env})"
        end
        return "" if Database.deletable?(path)

        "cybertrain test refuses to delete #{path}: #{Database::NOT_CREATED}"
      end

      # Whether `path` names a file by its path: not empty, not SQLite's
      # in-memory forms, not a `file:` URI.
      # @api private
      def self.plain_path?(path)
        !path.empty? && !path.start_with?("file:") && !Cybertrain::DB::Connection.private_database?(path)
      end

      # Deletes the configured database and its -wal / -shm, creates it
      # marked with Database::TEST_MARKER (`PRAGMA application_id`) and
      # migrates Migration.all, quietly: what {boot} runs after {refusal}.
      # @return [nil]
      # @raise [Refused] when the path became a symlink before the open
      #   ({opened_problem}; nothing is marked or migrated)
      def self.fresh_database
        c = Cybertrain.config
        path = c.database_path
        # A dangling symlink too: SQLite would create the file it points at.
        [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) || File.symlink?(f) }
        connection = Cybertrain::DB::Connection.new(path)
        # A symlink planted between the delete and the open (a shared,
        # writable directory) was followed by SQLite: nothing is marked or
        # migrated through it.
        planted = Bundle.opened_problem(path)
        unless planted.empty?
          connection.close
          raise Refused, planted
        end
        # The mark first, written through to the file itself (out of the
        # write-ahead log), so a run stopped at any later step leaves a file
        # the next run recognises as its own.
        Database.mark!(connection)
        migrator = Cybertrain::DB::Migrator.new(connection)
        migrator.quiet!
        migrator.migrate(Cybertrain::Migration.all)
        connection.close
        nil
      end

      # Why the database just opened at `path` must not be used ("" when it
      # may): `path` is a symlink, planted after the boot deleted what was
      # there, so SQLite opened the file it points at.
      # @param path [String]
      # @return [String]
      # @api private
      def self.opened_problem(path)
        return "" unless File.symlink?(path)

        "cybertrain test refuses #{path}: it became a symlink while the test database was created " \
          "(nothing was marked or migrated); remove it and run again"
      end
    end
  end
end
