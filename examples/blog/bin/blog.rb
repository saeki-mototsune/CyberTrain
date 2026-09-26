require "cybertrain"
require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
require_relative "../config/app"     # so it comes before the config
require_relative "../gen/app"
require_relative "../gen/migrations"

exit(Cybertrain::Main.run("blog", ARGV,
                          router: Gen::Routes.build(Cybertrain::Router.new),
                          url_resolver: Gen::Routes.url_resolver,
                          views: Gen::Views::SOURCES))
