require "cybertrain/db/error"
require "cybertrain/db/base"
require "cybertrain/db/cli"
require "cybertrain/db/mysql/url"
require "cybertrain/config"

module Cybertrain
  module DB
    # Cybertrain::DB::CLI's MySQL part (cybertrain/db/cli.rb has what the
    # adapters share; cybertrain/core/mysql requires this file, and
    # cybertrain/db/sqlite/cli.rb is SQLite's, method for method).
    #
    # The database is the one DATABASE_URL names (Config#database_url, read
    # through DB::Adapter.connect_target, which refuses an empty one). `db
    # create` and `db drop` are the only code of the framework that runs
    # CREATE DATABASE or DROP DATABASE: they connect to the server without
    # a database, and the name must be MYSQL_NAME's (letters, digits, `_`
    # and `$`, at most 64), written with backticks. `drop` refuses a name
    # that ends in `_production`. `backup`, `vacuum` and `normalize` are
    # SQLite's and stop with exit status 2. No message names the URL with
    # its password: a Url's to_s leaves it out, and its faults never repeat
    # the URL.
    module CLI
      # The longest database name MySQL takes.
      MYSQL_NAME_MAX = 64

      # What CREATE DATABASE makes the database's defaults: the adapter's
      # character set and collation (MySQL::DDL::TABLE_OPTIONS).
      CREATE_OPTIONS = " CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin"

      def self.usage
        puts "usage: db (migrate|rollback [N]|status|schema|schema:dump|create|drop)"
        1
      end

      # DATABASE_URL (with its password: only ever handed to Connection.new
      # and Url.parse, never printed).
      # @return [String]
      # @raise [Cybertrain::DB::Error] when it is empty
      def self.database_url
        DB::Adapter.connect_target(Cybertrain.config)
      end

      # `text` parsed; its faults as DB::Error (the message names the part
      # at fault, never the password).
      # @param text [String]
      # @return [Cybertrain::DB::MySQL::Url]
      def self.parsed_url(text)
        MySQL::Url.parse(text)
      rescue ArgumentError => e
        raise Error, e.message
      end

      # migrate, rollback, status and the schema dump connect to the
      # database itself; one that does not exist is the server's error
      # (`Unknown database`), since `db create` makes it.
      def self.open_for_migrate(root)
        Connection.new(database_url)
      end

      def self.open_existing(root)
        Connection.new(database_url)
      end

      # What `db schema` says the dump was read from: the URL without its
      # password.
      def self.schema_source(root)
        parsed_url(database_url).to_s
      end

      # `db create`: CREATE DATABASE for DATABASE_URL's database, with
      # CREATE_OPTIONS; "database already exists: <url>" and 0 when it does.
      def self.create(root)
        text = database_url
        url = parsed_url(text)
        name = CLI.database_name(url.database)
        connection = Connection.new(CLI.server_url(text))
        begin
          if CLI.database_exists?(connection, name)
            puts "database already exists: #{url}"
          else
            connection.exec_script("CREATE DATABASE #{CLI.quote_database(name)}#{CREATE_OPTIONS}")
            puts "created #{url}"
          end
        ensure
          connection.close
        end
        0
      end

      # `db drop`: DROP DATABASE for DATABASE_URL's database; "database
      # does not exist: <url>" and 0 when there is none. A name that ends
      # in "_production" is refused (exit status 1), before anything
      # connects.
      def self.drop(root)
        text = database_url
        url = parsed_url(text)
        name = CLI.database_name(url.database)
        if name.end_with?("_production")
          puts "db drop refuses to drop #{name}: its name ends in _production"
          return 1
        end
        connection = Connection.new(CLI.server_url(text))
        begin
          if CLI.database_exists?(connection, name)
            connection.exec_script("DROP DATABASE #{CLI.quote_database(name)}")
            puts "dropped #{url}"
          else
            puts "database does not exist: #{url}"
          end
        ensure
          connection.close
        end
        0
      end

      def self.backup(root, args, name, now)
        CLI.sqlite_only("backup")
      end

      def self.vacuum(root)
        CLI.sqlite_only("vacuum")
      end

      def self.normalize(root)
        CLI.sqlite_only("normalize")
      end

      # What a command of SQLite's says on MySQL; exit status 2.
      # @param word [String] the command
      # @return [Integer]
      def self.sqlite_only(word)
        puts "db #{word} is SQLite-only; use mysqldump or your provider's snapshots"
        2
      end

      # `name` when CREATE / DROP DATABASE may take it: 1 to MYSQL_NAME_MAX
      # bytes, each a letter, a digit, `_` or `$`.
      # @param name [String] the URL's database, percent-decoded
      # @return [String]
      # @raise [Cybertrain::DB::Error] for any other name
      def self.database_name(name)
        raise Error, "DATABASE_URL names no database (mysql://user:password@host:3306/NAME)" if name.empty?

        if name.bytesize > MYSQL_NAME_MAX || !CLI.database_name_bytes?(name)
          message = "the database name #{name.inspect} is not allowed: use letters, digits, _ and $ " \
                    "(at most #{MYSQL_NAME_MAX} characters)"
          raise Error, message
        end
        name
      end

      # Whether every byte of `name` is [A-Za-z0-9_$]. Read through a local
      # (NOTES rule 62).
      # @param name [String]
      # @return [Boolean]
      def self.database_name_bytes?(name)
        s = name.to_s
        i = 0
        while i < s.bytesize
          b = s.getbyte(i).to_i
          ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 36
          return false unless ok

          i += 1
        end
        true
      end

      # "`name`": a name database_name passed has no backtick to double.
      # @param name [String]
      # @return [String]
      def self.quote_database(name)
        "`#{name}`"
      end

      # `text` without its database: what create and drop connect with
      # (the server, no database selected). The path after the last "@"
      # (Url.parse's split: the password may hold a "/") is cut up to the
      # "?" of the parameters, which stay.
      # @param text [String]
      # @return [String]
      def self.server_url(text)
        s = text.to_s
        at = MySQL::Url.last_at(s)
        return s if at < 0

        slash = MySQL::Url.find_byte(s, 47, at + 1)
        return s if slash < 0

        query = MySQL::Url.find_byte(s, 63, at + 1)
        return s if query >= 0 && query < slash

        stop = query < 0 ? s.bytesize : query
        s.byteslice(0, slash) + s.byteslice(stop, s.bytesize - stop)
      end

      # Whether the server has a database named `name`.
      # @param connection [Cybertrain::DB::Connection]
      # @param name [String]
      # @return [Boolean]
      def self.database_exists?(connection, name)
        rows = connection.execute("SELECT SCHEMA_NAME AS n FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?", [name])
        !rows.empty?
      end

      # ---- what Main says and runs for the database ---------------------

      # The `db` line of `./<name> help` (Main.usage).
      # @param name [String] the binary's name
      # @return [String]
      def self.usage_lines(name)
        "  ./#{name} db COMMAND        migrate | rollback [N] | status | schema | schema:dump | create | drop\n"
      end

      # What `help` says `dbconsole` does.
      # @return [String]
      def self.console_description
        "open the mysql client on the database"
      end

      # The client `dbconsole` runs (Main.run_dbconsole).
      # @return [String]
      def self.console_program
        "mysql"
      end

      # Its arguments: --host, --port, --user and --database from
      # DATABASE_URL, each with its value in the same word (a value that
      # starts with "-" is not taken for an option), and --ssl-mode, so the
      # client is held to the URL's TLS (verify: VERIFY_IDENTITY, the
      # client's own default PREFERRED would fall back to plain text). Never
      # the password: console_env gives it.
      # @param config [Cybertrain::Config]
      # @return [Array<String>]
      # @raise [Cybertrain::DB::Error] when DATABASE_URL is empty or bad
      def self.console_args(config)
        url = parsed_url(DB::Adapter.connect_target(config))
        ssl = url.ssl_mode == "disabled" ? "DISABLED" : "VERIFY_IDENTITY"
        ["--host=#{url.url_host}", "--port=#{url.port}", "--user=#{url.url_user}", "--database=#{url.database}",
         "--ssl-mode=#{ssl}"]
      end

      # MYSQL_PWD, the password the client reads from its environment, when
      # the URL has one (a process's environment is readable only by its
      # user, unlike its command line).
      # @param config [Cybertrain::Config]
      # @return [Hash{String => String}]
      def self.console_env(config)
        env = { "MYSQL_PWD" => "" }
        env.delete("MYSQL_PWD")
        password = parsed_url(DB::Adapter.connect_target(config)).url_password
        env["MYSQL_PWD"] = password unless password.empty?
        env
      end
    end
  end
end
