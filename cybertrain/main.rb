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
  #
  # `gen` stays a separate bin/gen.rb: it needs the generator and the
  # routes/schema DSL, none of which belong in the production binary.
  module Main
    def self.run(name, argv, router:, url_resolver:, views:)
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

    # [], ["server"], ["<port>"], ["server", "<port>"].
    def self.server?(argv)
      return true if argv.empty?
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

    def self.usage(name)
      <<~TEXT
        Usage:
          ./#{name} [server [PORT]]   start the server
          ./#{name} migrate           apply pending migrations
          ./#{name} db COMMAND        migrate | rollback [N] | status | schema:dump | create
          ./#{name} help
      TEXT
    end
  end
end
