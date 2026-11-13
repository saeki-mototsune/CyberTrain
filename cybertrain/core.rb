# cybertrain/core: the framework without its optional subsystems
# (require "cybertrain/core").
#
# HTTP, routing, controllers, models, views and helpers, assets, sessions,
# CSRF, CSP, the console, `db` and `migrate`: what every application
# needs. An application adds the subsystems it uses with their own lines
# in bin/NAME.rb (docs/superpowers/specs/2026-11-13-optional-subsystems-design.md):
#
#   require "cybertrain/core"
#   require "cybertrain/jobs"        # Job, Scheduler, the worker role, the jobs page and command
#   require "cybertrain/streams"     # Stream, the stream endpoint, turbo_stream_from, Controller#turbo_stream
#   require "cybertrain/feeds"       # Background, the feeds role, the feed health check
#   require "cybertrain/mailer"      # Mailer.deliver ("cybertrain/mailer/later": deliver_later, with jobs)
#   require "cybertrain/cache"       # Cache
#   require "cybertrain/rate_limit"  # Controller.rate_limit (with the cache)
#
# `require "cybertrain"` is the core and every subsystem. No file this one
# requires may name a subsystem (script/check-core-closure).
require "cybertrain/version"
require "cybertrain/logger"
require "cybertrain/html"
require "cybertrain/http/parser"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/query"
require "cybertrain/http/uploaded_file"
require "cybertrain/http/multipart"
require "cybertrain/http/cookies"
require "cybertrain/params"
require "cybertrain/context"
require "cybertrain/middleware"
require "cybertrain/middleware/static"
require "cybertrain/middleware/request_logger"
require "cybertrain/middleware/method_override"
require "cybertrain/router"
require "cybertrain/app"
require "cybertrain/http/handler"
require "cybertrain/context_handler"
require "cybertrain/http/server"
require "cybertrain/http/gzip_ffi"
require "cybertrain/db"
require "cybertrain/time_ext"
require "cybertrain/model"
require "cybertrain/callback"
require "cybertrain/active_support"
require "cybertrain/controller"
require "cybertrain/crypto"
require "cybertrain/encryptor"
require "cybertrain/cookie_jar"
require "cybertrain/blob_store"
require "cybertrain/password"
require "cybertrain/time_zone"
require "cybertrain/session"
require "cybertrain/flash"
require "cybertrain/middleware/session_store"
require "cybertrain/middleware/csrf_protection"
require "cybertrain/middleware/error_pages"
require "cybertrain/schema"
require "cybertrain/schema/dumper"
require "cybertrain/migration"
require "cybertrain/generator/url_support"
require "cybertrain/template"
require "cybertrain/db/sqlite_ddl"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/db/cli"
require "cybertrain/views"
require "cybertrain/number_helper"
require "cybertrain/template/helpers"
require "cybertrain/template/form_builder"
require "cybertrain/config"
require "cybertrain/feature"
require "cybertrain/application"
require "cybertrain/main"

# The gzip inflater behind Request#decoded_body (system zlib through FFI):
# installed here, since cybertrain/http/request.rb itself must load under
# CRuby, where the FFI DSL does not exist.
Cybertrain::GzipFFI.install!
