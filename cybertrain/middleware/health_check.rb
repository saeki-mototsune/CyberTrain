require "cybertrain/middleware"
require "cybertrain/db"
require "cybertrain/feature"
require "cybertrain/cast"

module Cybertrain
  # The built-in health check (Config#health_path, "/up" by default): a GET
  # or HEAD of exactly that path is answered here, before Static, the
  # session, CSRF and the router, so it needs no controller, sets no cookie
  # and no login before_action can redirect it. A load balancer or
  # kamal-proxy polls it:
  #
  #   200 ok                    the database answered a query on its schema
  #   503 database unavailable  it did not (a missing or unreadable file, a
  #                             closed pool: any Cybertrain::DB::Error)
  #   503 worker stale          the Scheduler runs, and its last tick is
  #                             older than Config#health_worker_stale seconds
  #                             (with cybertrain/jobs: JobsFeature's
  #                             Feature#health_problem)
  #
  #   503 feed stale            Config#health_feeds, and a feed status row
  #                             (WebSocket::FeedTable) whose updated_at, or
  #                             COALESCE(last_activity_at, started_at), is
  #                             older than Config#health_feed_stale seconds;
  #                             a row whose name is not a subscription this
  #                             binary registers (a feed renamed or removed
  #                             since) is not counted (with cybertrain/feeds:
  #                             FeedsFeature's Feature#health_problem, and
  #                             HealthCheck.feed_stale? in cybertrain/feeds.rb)
  #
  # always text/plain with Cache-Control: no-store. It sits inside
  # RequestLogger, so each poll is the normal two log lines and nothing more.
  # Any other method on the path, and every other path, go on down the stack.
  class HealthCheck < Middleware
    # Reads the schema page (page 1): a bare `SELECT 1` never touches the
    # file, so it would answer for a database that is gone. sqlite_master
    # rather than its newer alias sqlite_schema (SQLite 3.33+).
    QUERY = "SELECT count(*) AS n FROM sqlite_master"

    def initialize(app, path, worker_stale, feeds, feed_stale)
      super(app)
      @health_path = path
      @worker_stale = worker_stale
      @health_feeds = feeds
      @feed_stale = feed_stale
    end

    def call(ctx)
      request = ctx.request
      return super unless request.path == @health_path && (request.get? || request.head?)

      body = HealthCheck.problem(Time.now.to_i, @worker_stale, @health_feeds, @feed_stale)
      response = ctx.response
      response.status = body.empty? ? 200 : 503
      response.content_type = "text/plain; charset=utf-8"
      response.set_header("Cache-Control", "no-store")
      response.body = body.empty? ? "ok" : body
      nil
    end

    # "" when healthy, else the 503's text. The database first: a worker
    # that cannot reach it is stale for that reason. Then the loaded
    # subsystems', in registration order (with `require "cybertrain"`:
    # "worker stale", then "feed stale").
    def self.problem(now, worker_stale, feeds, feed_stale)
      return "database unavailable" unless database_ok?

      Features.health_problem(now, worker_stale, feeds, feed_stale)
    end

    # The rescue sits in this plain method, around a DB.with whose block
    # calls a plain method on the connection (NOTES rules 32/45/67); the
    # full name in the clause (rule 70).
    def self.database_ok?
      DB.with { |c| c.execute(QUERY) }
      true
    rescue Cybertrain::DB::Error, StandardError
      false
    end
  end
end
