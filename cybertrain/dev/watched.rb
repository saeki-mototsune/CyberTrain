module Cybertrain
  module Dev
    # The files whose changes trigger a rebuild. Views are not among them:
    # the template engine rereads those by itself in development. The asset
    # roots are: gen digests them, so a saved stylesheet gets a new digest
    # (config/importmap.rb is under config/**/*.rb). In a file of their own
    # so that a test of the watcher can read them without the rest of
    # cybertrain/dev (Reexec's FFI does not load under CRuby).
    WATCHED = ["app/**/*.rb", "config/**/*.rb", "db/schema.rb", "gen/**/*.rb", "app/assets/**/*", "app/javascript/**/*",
               "vendor/javascript/**/*"]

    # Matched by WATCHED but never a reason to rebuild: gen/views.rb is the
    # empty table in development, and `cybertrain build` fills and restores
    # it while a development server may be running.
    IGNORED = ["gen/views.rb"]
  end
end
