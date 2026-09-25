require "cybertrain/db/error"
require "cybertrain/db/connection"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/migration"
require "cybertrain/config"

module Cybertrain
  module DB
    # Cybertrain::DB::CLI -- the `bin/db.rb` entry point an app's binary
    # calls: `require "cybertrain"; require_relative "../gen/migrations";
    # exit(Cybertrain::DB::CLI.run(ARGV))`.
    #
    # The database is Cybertrain.config.database_path once the app has
    # loaded its config (config/app.rb calling Cybertrain.configure);
    # otherwise the same defaults Config uses, read from ENV on every call:
    # ENV["CYBERTRAIN_DATABASE"], or "storage/#{env}.sqlite3" with env from
    # ENV["CYBERTRAIN_ENV"] || "development".
    module CLI
      def self.run(argv, root = ".")
        return usage if argv.empty?

        begin
          dispatch(argv, root)
        rescue StandardError => e
          puts "db #{argv[0]} failed: #{e.message}"
          1
        end
      end

      def self.dispatch(argv, root)
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
        when "create"
          create(root)
        else
          puts "unknown command: #{argv[0]}"
          usage
          1
        end
      end

      def self.usage
        puts "usage: db (migrate|rollback [N]|status|schema:dump|create)"
        1
      end

      # 1 without an argument; the step count when argv[1] is all digits;
      # 0 (rejected by the caller) for anything else ("abc", "-1", "", "2x").
      def self.rollback_steps(argv)
        return 1 if argv.size < 2
        arg = argv[1]
        return 0 if arg.empty?
        i = 0
        while i < arg.length
          c = arg[i]
          return 0 unless c >= "0" && c <= "9"
          i += 1
        end
        arg.to_i
      end

      # An empty CYBERTRAIN_DATABASE counts as unset (it would otherwise
      # resolve to the app root directory itself).
      def self.database_path
        return Cybertrain.config.database_path if Cybertrain.config_loaded?

        Config.default_database_path(Config.default_env)
      end

      # An absolute CYBERTRAIN_DATABASE is used as is; a relative one (and
      # the storage/<env>.sqlite3 default) is relative to the app root.
      def self.resolved_path(root)
        path = database_path
        path.start_with?("/") ? path : "#{root}/#{path}"
      end

      def self.create(root)
        path = resolved_path(root)
        if File.exist?(path)
          puts "database already exists: #{path}"
          return 0
        end
        ensure_directory(File.dirname(path))
        Connection.new(path).close
        puts "created #{path}"
        0
      end

      def self.migrate(root)
        path = resolved_path(root)
        ensure_directory(File.dirname(path))
        connection = Connection.new(path)
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

      def self.schema_dump(root)
        connection = open_existing(root)
        begin
          write_schema(root, connection)
        ensure
          connection.close
        end
        0
      end

      # rollback/status/schema:dump never create a database by accident.
      def self.open_existing(root)
        path = resolved_path(root)
        raise Error, "database does not exist: #{path} (run `db migrate` or `db create`)" unless File.exist?(path)
        Connection.new(path)
      end

      def self.write_schema(root, connection)
        dir = "#{root}/db"
        ensure_directory(dir)
        File.write("#{dir}/schema.rb", SchemaDumper.dump_to_ruby(connection))
        nil
      end

      # mkdir -p: creates missing parents first.
      def self.ensure_directory(dir)
        return nil if dir == "" || File.directory?(dir)
        ensure_directory(File.dirname(dir))
        Dir.mkdir(dir)
        nil
      end
    end
  end
end
