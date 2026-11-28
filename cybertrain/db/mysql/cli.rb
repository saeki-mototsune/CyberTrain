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
      # (`Unknown database`), since `db create` makes it. With the longest
      # read wait (migration_url): an ALTER TABLE on a large table can run
      # for longer than the 30 seconds the application's connections wait,
      # and a cut connection would leave the server finishing the ALTER and
      # the version unrecorded.
      def self.open_for_migrate(root)
        Connection.new(CLI.migration_url(database_url))
      end

      def self.open_existing(root)
        Connection.new(CLI.migration_url(database_url))
      end

      # `text` with read_timeout=MySQL::Url::MAX_TIMEOUT (a day) among its
      # parameters, unless it names a read_timeout itself. The parameters
      # follow the first "?" after the last "@" (a password may hold "?"
      # and "@"), or the authority when the URL has no "@".
      # @param text [String]
      # @return [String]
      def self.migration_url(text)
        at = text.rindex("@")
        from = at.nil? ? 0 : at + 1
        mark = text.index("?", from)
        wait = "read_timeout=#{MySQL::Url::MAX_TIMEOUT}"
        return "#{text}?#{wait}" if mark.nil?

        query = text[mark + 1, text.size - mark - 1].to_s
        return text if query.start_with?("read_timeout=") || query.include?("&read_timeout=")

        "#{text}&#{wait}"
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
        # Case-insensitively: database names are case-sensitive on Linux,
        # and shop_PRODUCTION is as much production's.
        if name.downcase.end_with?("_production")
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

      # Its arguments: --protocol=TCP, then --host, --port, --user and
      # --database from DATABASE_URL, each with its value in the same word (a
      # value that starts with "-" is not taken for an option), then
      # --init-command, then --ssl-mode and, for ssl_mode=verify, the CA
      # (console_ca_args). Never the password: console_env gives it.
      #
      # --init-command runs the framework's own session settings
      # (Connection::SESSION_SETTINGS: utf8mb4, time_zone '+00:00', the
      # strict sql_mode), so that what is typed there reads and writes as
      # the application does: NOW() into a datetime column is UTC, which the
      # application reads it as, not the server's local time.
      #
      # --protocol=TCP: the client takes --host=localhost for its Unix socket
      # and ignores --port, so a localhost URL would reach whatever server
      # owns the socket rather than the URL's host:port, which the framework
      # connects to over TCP. --ssl-mode holds the client to the URL's TLS
      # (verify: VERIFY_IDENTITY; the client's own default, PREFERRED, would
      # fall back to plain text; disabled: DISABLED).
      # @param config [Cybertrain::Config]
      # @return [Array<String>]
      # @raise [Cybertrain::DB::Error] when DATABASE_URL is empty or bad, or
      #   for ssl_mode=verify when no CA can be named (console_ca_args)
      def self.console_args(config)
        url = parsed_url(DB::Adapter.connect_target(config))
        args = ["--protocol=TCP", "--host=#{url.url_host}", "--port=#{url.port}", "--user=#{url.url_user}",
                "--database=#{url.database}", "--init-command=#{Cybertrain::DB::Connection::SESSION_SETTINGS}"]
        if url.ssl_mode == "disabled"
          args << "--ssl-mode=DISABLED"
        else
          args << "--ssl-mode=VERIFY_IDENTITY"
          CLI.console_ca_args(ENV["SSL_CERT_FILE"].to_s, ENV["SSL_CERT_DIR"].to_s).each { |arg| args << arg }
        end
        args
      end

      # The system CA bundles looked for when neither SSL_CERT_FILE nor
      # SSL_CERT_DIR is set, in this order: Debian and Ubuntu, Fedora and
      # RHEL, openSUSE, macOS / Alpine / the BSDs.
      CA_BUNDLES = ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
                    "/etc/ssl/ca-bundle.pem", "/etc/ssl/cert.pem"].freeze

      # The CA the mysql client verifies the server with, which it needs for
      # VERIFY_IDENTITY ("CA certificate is required if ssl-mode is VERIFY_CA
      # or VERIFY_IDENTITY": it has no default store). The same trust as the
      # framework's own connection, which uses OpenSSL's default store with
      # SSL_CERT_FILE / SSL_CERT_DIR over it (cybertrain/net/tls.rb):
      # --ssl-ca=`file` and --ssl-capath=`dir` for the ones set; with
      # neither, --ssl-ca= the first of CA_BUNDLES that exists (where the
      # system's OpenSSL keeps its default store). With none of them a
      # DB::Error says to set SSL_CERT_FILE, rather than a client that
      # fails to connect.
      # @param file [String] SSL_CERT_FILE, "" when unset
      # @param dir [String] SSL_CERT_DIR, "" when unset
      # @return [Array<String>]
      # @raise [Cybertrain::DB::Error] when nothing names a CA
      def self.console_ca_args(file, dir)
        args = Array.new(0) { "" }
        args << "--ssl-ca=#{file}" unless file.empty?
        args << "--ssl-capath=#{dir}" unless dir.empty?
        return args unless args.empty?

        i = 0
        while i < CA_BUNDLES.size
          bundle = CA_BUNDLES[i]
          if File.file?(bundle)
            args << "--ssl-ca=#{bundle}"
            return args
          end
          i += 1
        end
        raise Error, "ssl_mode=verify needs the CA the server's certificate is checked against, and this system has none " \
                     "of #{CA_BUNDLES.join(", ")}: set SSL_CERT_FILE (or SSL_CERT_DIR)"
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
