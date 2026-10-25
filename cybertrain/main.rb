require "cybertrain/application"
require "cybertrain/db/cli"

module Cybertrain
  # Cybertrain::Main -- what bin/<name>.rb runs, the one binary an app
  # builds (`spin build blog` -> build/bin/blog; `cybertrain build` ->
  # dist/blog):
  #
  #   ./blog              serve (port from PORT / config)
  #   ./blog server 3000  serve on 3000 (a bare "3000" too: the dev loop's
  #                       execv passes the port that way)
  #   ./blog migrate      apply db/migrate (gen/migrations.rb)
  #   ./blog db status    any DB::CLI command: status, rollback N, schema:dump, create
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
    # one (it would never run, or would hide the built-in).
    BUILTIN_WORDS = ["server", "migrate", "db", "help", "--help", "-h"].freeze

    # Registers an operational command for the application's binary:
    # `./<name> NAME ARGS...` runs the block instead of the server, and
    # `./<name> help` lists it. Call it in bin/<name>.rb before
    # `Cybertrain::Main.run` (or in a file bin/<name>.rb requires).
    #
    # Before the block runs, `Cybertrain::DB` is connected to
    # `Cybertrain.config.database_path` with a pool of one connection (and
    # disconnected afterwards), the way `./<name> db ...` works; no server,
    # views or session secret are set up. A `Cybertrain::DB::Error` raised
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
    #   (`server`, `migrate`, `db`, `help`), not a port number, not taken
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
        return run_command(COMMANDS[index], argv[1, argv.size - 1]) if index >= 0
      end
      return serve(name, argv, router, url_resolver, views) if server?(argv)

      case argv[0]
      when "migrate"
        DB::CLI.run(["migrate"])
      when "db"
        DB::CLI.run(argv[1, argv.size - 1])
      when "help", "--help", "-h"
        puts usage(name)
        0
      else
        puts "Unknown command '#{argv[0]}'"
        puts usage(name)
        1
      end
    end

    # A registered command with a pool of one: a one-shot process needs no
    # more, and the server's pool_size of connections would only be opened
    # and closed again. The begin/rescue sits in this plain method, which
    # calls the stored block rather than yielding (NOTES rules 32/45).
    def self.run_command(command, args)
      begin
        DB.connect(Cybertrain.config.database_path, size: 1)
        command.command_block.call(args)
      rescue DB::Error => e
        puts "#{command.command_name} failed: #{e.message}"
        1
      ensure
        DB.disconnect
      end
    end

    # [], ["server"], ["<port>"], ["server", "<port>"]; never a registered
    # command's name, so whatever starts only for a server (the scheduler)
    # stays off for a one-shot command.
    def self.server?(argv)
      return true if argv.empty?
      return false if command_index(argv[0]) >= 0
      return true if argv[0] == "server"

      Application.port_argument(argv) > 0
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
      text << "  ./#{name} migrate           apply pending migrations\n"
      text << "  ./#{name} db COMMAND        migrate | rollback [N] | status | schema:dump | create\n"
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
