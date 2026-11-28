require "cybertrain/db/error"
require "cybertrain/db/base"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/migration"
require "cybertrain/config"
require "cybertrain/cast"

module Cybertrain
  module DB
    # Cybertrain::DB::CLI -- the database commands behind `./<name> migrate`
    # and `./<name> db ...` (Cybertrain::Main) and, in development,
    # bin/db.rb: `require "cybertrain"; require_relative "../config/app";
    # require_relative "../gen/migrations";
    # exit(Cybertrain::DB::CLI.run(ARGV))`.
    #
    # This file holds what every adapter shares: the dispatch, migrate,
    # rollback, status and the schema dump, all through the Migrator and
    # the SchemaDumper (DB::Dialect). What names or opens the database, and
    # the commands of one adapter, are in the adapter's part, which the
    # entry requires beside this one (cybertrain/core: cybertrain/db/sqlite/
    # cli.rb, the database file; cybertrain/core/mysql: cybertrain/db/mysql/
    # cli.rb, DATABASE_URL's server): usage, open_for_migrate, open_existing,
    # schema_source, create, drop, backup, vacuum and normalize, each with
    # the same signature and return type on both.
    module CLI
      # name is the application's name (Main passes the binary's), used for
      # the dated file names of `backup DIR/`; "" takes the database file's
      # base name instead (bin/db.rb in development has no name to give).
      def self.run(argv, root = ".", name = "")
        return usage if argv.empty?

        begin
          dispatch(argv, root, name)
        rescue StandardError => e
          puts "db #{argv[0]} failed: #{e.message}"
          1
        end
      end

      def self.dispatch(argv, root, name)
        case argv[0]
        when "migrate"
          migrate(root)
        when "rollback"
          steps = rollback_steps(argv)
          if steps < 1
            puts "db rollback: N must be a positive integer, got #{argv[1].inspect}"
            return usage
          end
          rollback(root, steps)
        when "status"
          status(root)
        when "schema:dump"
          schema_dump(root)
        when "schema"
          schema(root)
        when "create"
          create(root)
        when "drop"
          drop(root)
        when "backup"
          backup(root, argv[1, argv.size - 1], name, Clock.now)
        when "vacuum"
          return usage if argv.size > 1
          vacuum(root)
        when "normalize"
          return usage if argv.size > 1
          normalize(root)
        else
          puts "unknown command: #{argv[0]}"
          usage
          1
        end
      end

      # 1 without an argument; the step count when argv[1] is all digits;
      # 0 (rejected by the caller) for anything else ("abc", "-1", "", "2x").
      def self.rollback_steps(argv)
        return 1 if argv.size < 2
        arg = argv[1]
        # Cast.digits? is true for "", hence the empty check before it.
        return 0 if arg.empty? || !Cast.digits?(arg)

        arg.to_i
      end

      # The database is created when it is missing where the adapter can
      # (SQLite's file; MySQL's database is `db create`'s).
      def self.migrate(root)
        connection = open_for_migrate(root)
        begin
          Migrator.new(connection).migrate(Cybertrain::Migration.all)
          write_schema(root, connection)
        ensure
          connection.close
        end
        0
      end

      def self.rollback(root, steps)
        connection = open_existing(root)
        begin
          Migrator.new(connection).rollback(Cybertrain::Migration.all, steps)
          write_schema(root, connection)
        ensure
          connection.close
        end
        0
      end

      def self.status(root)
        connection = open_existing(root)
        begin
          puts "Status  Migration ID    Migration Name"
          Migrator.new(connection).status(Cybertrain::Migration.all).each do |row|
            puts "#{row[0].rjust(6)}  #{row[1]}  #{row[2]}"
          end
        ensure
          connection.close
        end
        0
      end

      # The dump is the whole command here, so skipping it is a failure.
      def self.schema_dump(root)
        connection = open_existing(root)
        written = false
        begin
          written = write_schema(root, connection)
        ensure
          connection.close
        end
        written ? 0 : 1
      end

      # `db schema`: db/schema.rb from the database as it is (one Rails or
      # another tool created, say), without migrating; prints both paths.
      def self.schema(root)
        return 1 if schema_dump(root) != 0
        puts "wrote #{root}/db/schema.rb from #{schema_source(root)}"
        0
      end

      # The dump belongs next to the app's source, so it is written only
      # where a db/ directory already exists; a deployed dist/ that has
      # none gets a note instead of a stray dist/db/schema.rb. True when
      # db/schema.rb holds the dump afterwards. A file that already holds
      # it is left alone: spin rebuilds every executable of the package
      # when one of its Ruby files is newer than the binary, so rewriting
      # an unchanged dump made each `db migrate` with nothing pending
      # compile gen and db again (and the application, at the next start).
      def self.write_schema(root, connection)
        dir = "#{root}/db"
        unless File.directory?(dir)
          puts "schema dump skipped (no db/ directory here)"
          return false
        end
        path = "#{dir}/schema.rb"
        dump = SchemaDumper.dump_to_ruby(connection)
        File.write(path, dump) unless File.file?(path) && File.read(path) == dump
        true
      end

    end
  end
end
