# cybertrain/core: the framework without its optional subsystems
# (require "cybertrain/core").
#
# HTTP, routing, controllers, models, views and helpers, assets, sessions,
# CSRF, CSP, the console, `db` and `migrate`: what every application
# needs. An application adds the subsystems it uses with their own lines
# in bin/NAME.rb (docs/design.md D85):
#
#   require "cybertrain/core"
#   require "cybertrain/jobs"        # Job, Scheduler, the worker role, the jobs page and command
#   require "cybertrain/streams"     # Stream, the stream endpoint, turbo_stream_from, Controller#turbo_stream
#   require "cybertrain/feeds"       # Background, the feeds role, the feed health check
#   require "cybertrain/mailer"      # Mailer.deliver ("cybertrain/mailer/later": deliver_later, with jobs)
#   require "cybertrain/cache"       # Cache
#   require "cybertrain/rate_limit"  # Controller.rate_limit (with the cache)
#   require "cybertrain/error_reporter/sentry"  # the Sentry sender (loads HttpClient and TLS); bin/NAME.rb only
#
# `require "cybertrain"` is the core and every subsystem. No file this one
# requires may name a subsystem (script/check-core-closure).
#
# This entry is the core with the SQLite adapter: cybertrain/core/common
# (everything but the adapter) and cybertrain/db (cybertrain/db/base plus
# cybertrain/db/sqlite). cybertrain/core/mysql is the same with MySQL.
require "cybertrain/core/common"
require "cybertrain/db"
