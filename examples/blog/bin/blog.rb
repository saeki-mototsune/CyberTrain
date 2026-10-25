require "cybertrain"
require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
require_relative "../config/app"     # so it comes before the config
require_relative "../gen/app"
require_relative "../gen/migrations"

# Operational commands: `./blog NAME ARGS...` runs the block with
# Cybertrain::DB connected (pool of 1) and exits with its value;
# `./blog help` lists them.
#   Cybertrain::Main.command("prune", "delete old comments") do |argv|
#     Cybertrain::DB.with { |c| c.execute("DELETE FROM comments WHERE created_at < date('now', '-30 days')") }
#     0
#   end

exit(Cybertrain::Main.run("blog", ARGV,
                          router: Gen::Routes.build(Cybertrain::Router.new),
                          url_resolver: Gen::Routes.url_resolver,
                          views: Gen::Views::SOURCES))
