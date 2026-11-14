require "cybertrain/application"
require "cybertrain/db/cli"
require "cybertrain/console"
require "cybertrain/feature"
require "cybertrain/feature_catalog"

module Cybertrain
  # Cybertrain::Main -- what bin/<name>.rb runs, the one binary an app
  # builds (`spin build blog` -> build/bin/blog; `cybertrain build` ->
  # dist/blog):
  #
  #   ./blog              serve (port from PORT / config)
  #   ./blog server 3000  serve on 3000 (a bare "3000" too: the dev loop's
  #                       execv passes the port that way)
  #   ./blog migrate      apply db/migrate (gen/migrations.rb)
  #   ./blog db status    any DB::CLI command: status, rollback N, schema, schema:dump, create,
  #                       backup PATH, vacuum
  #   ./blog worker       jobs and scheduled tasks, no HTTP (several may share a database)
  #   ./blog jobs list    any Job::CLI command: list [STATE], retry ID|--all, discard ID,
  #                       delete ID, prune [--before DAYS]
  #                       (worker and jobs with require "cybertrain/jobs":
  #                       JobsFeature#run_feature_command)
  #   ./blog feeds [NAME...]  the WebSocket subscriptions (all, or the named ones)
  #   ./blog feeds status     each feed's health, from the status rows
  #   ./blog console      the expression console over the models (Console.run)
  #   ./blog dbconsole    the sqlite3 shell on the configured database
  #   ./blog user a@b.c   a command the application registered with Main.command
  #
  # `gen` stays a separate bin/gen.rb: it needs the generator and the
  # routes/schema DSL, none of which belong in the production binary.
  module Main
    # One application command registered with {Main.command}. The accessors
    # have distinctive names (spikes/NOTES.md rules 10/34: Callback#name and
    # #block already exist with other types), and there is no #call (rule 40).
    class Command
      attr_reader :command_name, :command_description, :command_block

      def initialize(command_name, command_description, command_block)
        @command_name = command_name
        @command_description = command_description
        @command_block = command_block
      end
    end

    # The registry: a constant, which Spinel roots for the collector (a
    # class variable it does not: NOTES rule 64). Seeded with the element
    # type and emptied (rule 9), as Controller::NO_SKIPS is.
    COMMANDS = Array.new(0) { Command.new("", "", nil) }

    # The words Main itself answers to; an application command may not take
    # one (it would never run, or would hide the built-in). dev-address is
    # `cybertrain server`'s, not listed in the usage.
    BUILTIN_WORDS = ["server", "worker", "feeds", "migrate", "db", "jobs", "console", "dbconsole", "help", "--help", "-h",
                     "dev-address"].freeze

    # Registers an operational command for the application's binary:
    # `./<name> NAME ARGS...` runs the block instead of the server, and
    # `./<name> help` lists it. Call it in bin/<name>.rb before
    # `Cybertrain::Main.run` (or in a file bin/<name>.rb requires).
    #
    # Before the block runs, `Cybertrain::DB` is connected to
    # `Cybertrain.config.database_path` with a pool of one connection (and
    # disconnected afterwards), the way `./<name> db ...` works, and the
    # views and the URL resolver are configured as the server's boot does,
    # so `Cybertrain::Views.render_partial`, `render_component` and the
    # `Stream.broadcast_*_to(partial: / component:)` shortcuts work; no
    # server, scheduler, threads or session secret are set up. A `Cybertrain::DB::Error` raised
    # by the block (or by the connect) prints `NAME failed: MESSAGE` and
    # exits 1. Any other exception is not rescued.
    #
    # The block receives the arguments after the command's name as its one
    # argument (Spinel has no `instance_eval`, so there is no implicit
    # receiver, like `before_action { |c| ... }`) and returns the exit
    # status, an Integer.
    # @example bin/blog.rb, before `exit(Cybertrain::Main.run(...))`
    #   Cybertrain::Main.command("prune", "delete comments older than DAYS") do |argv|
    #     days = argv.empty? ? 30 : argv[0].to_i
    #     Cybertrain::DB.with do |c|
    #       c.execute("DELETE FROM comments WHERE created_at < datetime('now', ?)", ["-#{days} days"])
    #     end
    #     puts "pruned"
    #     0
    #   end
    # @param name [String] the first command-line word; not a built-in one
    #   (`server`, `worker`, `feeds`, `migrate`, `db`, `jobs`, `console`, `dbconsole`, `help`), not a
    #   port number, not taken
    # @param description [String] the line `help` prints next to it
    # @yieldparam argv [Array<String>] the arguments after `name`
    # @yieldreturn [Integer] the process's exit status
    # @return [nil]
    # @raise [ArgumentError] for a reserved, numeric, empty or taken name
    # @api public
    def self.command(name, description, &block)
      problem = command_name_problem(name)
      raise ArgumentError, "Main.command #{name.inspect}: #{problem}" unless problem.empty?

      COMMANDS << Command.new(name, description, block)
      nil
    end

    # "" when name can be registered, else why not.
    def self.command_name_problem(name)
      return "the name is empty" if name.empty?
      return "#{name} is a built-in command" if BUILTIN_WORDS.include?(name)
      return "a number is the server's port argument" if Cast.digits?(name)
      return "already registered" if command_index(name) >= 0

      ""
    end

    # The index of the command registered as word in COMMANDS, -1 when
    # none (an Integer rather than a nullable Command: NOTES rules 11/56).
    def self.command_index(word)
      i = 0
      while i < COMMANDS.size
        return i if COMMANDS[i].command_name == word
        i += 1
      end
      -1
    end

    def self.run(name, argv, router:, url_resolver:, views:)
      unless argv.empty?
        index = command_index(argv[0])
        return run_command(COMMANDS[index], argv[1, argv.size - 1], views, url_resolver) if index >= 0
      end
      return serve(name, argv, router, url_resolver, views) if server?(argv)

      case argv[0]
      when "migrate"
        DB::CLI.run(["migrate"], ".", name)
      when "db"
        DB::CLI.run(argv[1, argv.size - 1], ".", name)
      when "console"
        run_console
      when "dbconsole"
        run_dbconsole
      when "dev-address"
        # `cybertrain server` asks this before it binds the port for the
        # child it supervises; not in the usage, it is not for people.
        config = Cybertrain.config
        puts "#{config.host} #{config.port}"
        0
      when "help", "--help", "-h"
        puts usage(name)
        0
      else
        run_other(name, argv, router, url_resolver, views)
      end
    end

    # A word none of Main's own arms takes: a loaded subsystem's command
    # (Features.command_status: `worker` and `jobs` with cybertrain/jobs),
    # else the require line a subsystem's word needs, else unknown.
    def self.run_other(name, argv, router, url_resolver, views)
      word = argv[0]
      status = Features.command_status(word, argv[1, argv.size - 1], name, router, url_resolver, views)
      return status if status >= 0

      missing = missing_subsystem(word, name)
      unless missing.empty?
        puts missing
        STDOUT.flush
        return 1
      end
      puts "Unknown command '#{word}'"
      puts usage(name)
      1
    end

    # What `./NAME WORD` prints when WORD belongs to a subsystem bin/NAME.rb
    # did not require: which line it needs (FeatureCatalog, the table gen's
    # view check reads too). "" for any other word.
    # @param word [String]
    # @param name [String] the binary's name
    # @return [String]
    def self.missing_subsystem(word, name)
      FeatureCatalog.missing_command_message(word, name)
    end

    # A registered command, `jobs` and `console` run without
    # Application#boot, so each installs the configured zone itself
    # (Runtime.apply_zone) before anything else; an unknown zone is refused
    # with boot's line, `error: time_zone "X" is not a known time zone`,
    # and exit status 1, before the database is opened.
    def self.zone_refused(problem)
      puts "error: #{problem}"
      STDOUT.flush
      1
    end

    # A registered command with a pool of one: a one-shot process needs no
    # more, and the server's pool_size of connections would only be opened
    # and closed again. Views are configured as boot does
    # (Application.configure_views), so the block can render a partial or a
    # component; there is no server, scheduler or thread. The begin/rescue
    # sits in this plain method, which calls the stored block rather than
    # yielding (NOTES rules 32/45).
    def self.run_command(command, args, views, url_resolver)
      zone_problem = Runtime.apply_zone(Cybertrain.config)
      return zone_refused(zone_problem) unless zone_problem.empty?

      begin
        DB.connect(Cybertrain.config.database_path, size: 1)
        Application.configure_views(Cybertrain.config, views, url_resolver, eager: false)
        command.command_block.call(args)
      rescue DB::Error => e
        puts "#{command.command_name} failed: #{e.message}"
        1
      ensure
        DB.disconnect
      end
    end

    # `./<name> console`: Console.run on the terminal, with the database
    # connected as for a registered command (a pool of one; no server, no
    # scheduler), in the configured zone. The models reach the console
    # through the builders gen/console.rb sets. Returns the console's exit
    # status, or 1 when the zone is unknown or the database cannot be
    # opened. The rescue sits in this plain method (NOTES
    # rules 32/45).
    def self.run_console
      zone_problem = Runtime.apply_zone(Cybertrain.config)
      return zone_refused(zone_problem) unless zone_problem.empty?

      status = 0
      begin
        DB.connect(Cybertrain.config.database_path, size: 1)
        status = Console.run(STDIN, STDOUT, Cybertrain.config)
      rescue DB::Error => e
        puts "console failed: #{e.message}"
        status = 1
      ensure
        DB.disconnect
      end
      status
    end

    # `./<name> dbconsole`: the sqlite3 shell on the configured database
    # (Rails' dbconsole), its exit status passed through (1 when a signal
    # ended it). Process.spawn and Process.wait compile and reap under the
    # pinned Spinel (NOTES rule 75); a missing binary is Errno::ENOENT from
    # the spawn. Ctrl-C at the sqlite3 prompt reaches this process too (the
    # terminal signals the whole foreground group), so INT is trapped here
    # first: without it this process died with 130 and left sqlite3 reading
    # the terminal. The child's exec resets a handled signal to its default,
    # so sqlite3 still answers Ctrl-C itself. A path starting with "-" is
    # given as "./-...", so sqlite3 does not take it for an option.
    def self.run_dbconsole
      path = Main.dbconsole_path(Cybertrain.config.database_path)
      trap("INT") { nil }
      pid = 0
      begin
        pid = Process.spawn("sqlite3", path)
      rescue Errno::ENOENT
        puts "sqlite3 not found: install the sqlite3 CLI"
        return 1
      rescue SystemCallError => e
        puts "sqlite3 could not be started: #{e.class.name}: #{e.message}"
        return 1
      end
      Process.wait(pid)
      Main.child_exit_code($?)
    end

    # The database path as sqlite3's argument: "./" before one that starts
    # with "-".
    def self.dbconsole_path(path)
      path.start_with?("-") ? "./#{path}" : path
    end

    # A child's exit status, 1 when it has none (a signal ended it).
    def self.child_exit_code(status)
      return 1 if status.nil?

      code = status.exitstatus
      code.nil? ? 1 : code
    end

    # Whether {Main.run} starts the server for these arguments: [],
    # ["server"], ["<port>"], ["server", "<port>"]; never a registered
    # command's name, so whatever starts only for a server (the scheduler, a
    # boot-time check) stays off for a one-shot command. Ask it after the
    # commands are registered.
    # @example bin/<name>.rb, before `exit(Cybertrain::Main.run(...))`
    #   UserCommand.warn_if_no_user if Cybertrain::Main.server?(ARGV)
    # @param argv [Array<String>] the binary's ARGV
    # @return [Boolean]
    # @api public
    def self.server?(argv)
      return true if argv.empty?
      return false if command_index(argv[0]) >= 0
      return true if argv[0] == "server"

      Application.port_argument(argv) > 0
    end

    # Whether {Main.run} runs these arguments as `./<app> worker`: the
    # jobs and the scheduler, no HTTP.
    # @param argv [Array<String>] the binary's ARGV
    # @return [Boolean]
    # @api public
    def self.worker?(argv)
      !argv.empty? && argv[0] == "worker"
    end

    # Whether {Main.run} runs these arguments as `./<app> feeds [NAME...]`:
    # the WebSocket subscriptions, no HTTP and no jobs.
    # @param argv [Array<String>] the binary's ARGV
    # @return [Boolean]
    # @api public
    def self.feeds?(argv)
      !argv.empty? && argv[0] == "feeds"
    end

    def self.role_app(name, router, url_resolver, views)
      Application.new(router: router, url_resolver: url_resolver, views: views, name: name)
    end

    # The port argument Application#run expects, without the "server" word.
    def self.server_args(argv)
      return argv[1, argv.size - 1] if !argv.empty? && argv[0] == "server"

      argv
    end

    def self.serve(name, argv, router, url_resolver, views)
      app = Application.new(router: router, url_resolver: url_resolver, views: views, name: name)
      app.run(server_args(argv))
      0
    end

    # The built-in commands, then the application's (Main.command) in
    # registration order with their names padded to the built-ins' column,
    # then the settings config/app.rb declared (Config#setting_string and
    # its siblings) with their environment variables and defaults, when
    # there are any. A program that never configured anything has none, and
    # help must not create the config (it would freeze the environment it
    # reads, e.g. CYBERTRAIN_DATABASE, before a later command sets it).
    def self.usage(name)
      text = +"Usage:\n"
      text << "  ./#{name} [server [PORT]]   start the server\n"
      # A loaded subsystem's roles (cybertrain/jobs: worker; cybertrain/feeds:
      # feeds).
      text << Features.usage_text(name, "roles")
      text << "  ./#{name} migrate           apply pending migrations\n"
      text << "  ./#{name} db COMMAND        migrate | rollback [N] | status | schema | schema:dump | create\n"
      # The continuation lines up under "migrate" whatever the name.
      indent = "".ljust(name.size + 23)
      text << "#{indent}backup PATH [--force] | backup DIR/ [--keep N] | vacuum | normalize\n"
      # A loaded subsystem's commands (cybertrain/jobs: jobs).
      text << Features.usage_text(name, "commands")
      text << "  ./#{name} #{"console".ljust(17)} evaluate expressions over the models (help inside)\n"
      text << "  ./#{name} #{"dbconsole".ljust(17)} open the sqlite3 shell on the database\n"
      COMMANDS.each do |command|
        word = command.command_name.ljust(17)
        text << "  ./#{name} #{word} #{command.command_description}\n"
      end
      text << "  ./#{name} help\n"
      return text unless Cybertrain.config_loaded?

      settings = Cybertrain.config.settings_usage
      return text if settings.empty?

      text << "\n"
      text << settings
      text
    end
  end
end
