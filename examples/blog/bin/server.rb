require "cybertrain"
require_relative "../config/app"
require_relative "../gen/app"

app = Cybertrain::Application.new(
  router: Gen::Routes.build(Cybertrain::Router.new),
  url_resolver: Gen::Routes.url_resolver
)
app.run
