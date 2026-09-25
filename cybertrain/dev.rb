# The development loop (docs/design.md D12): Application#run in development
# watches the Ruby sources, rebuilds the server with `spin run gen && spin
# build server`, and replaces itself with the new binary; ErrorPage shows
# exceptions and failed builds in the browser. Production never loads any
# of it into the request path.
require "cybertrain/dev/watcher"
require "cybertrain/dev/rebuilder"
require "cybertrain/dev/reexec"
require "cybertrain/dev/error_page"

module Cybertrain
  module Dev
    # The files whose changes trigger a rebuild. Views are not among them:
    # the template engine rereads those by itself in development.
    WATCHED = ["app/**/*.rb", "config/**/*.rb", "db/schema.rb", "gen/**/*.rb"]
  end
end
