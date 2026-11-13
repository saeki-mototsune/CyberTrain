require "cybertrain/middleware"
require "cybertrain/db"
require "cybertrain/scheduler"
require "cybertrain/cast"
require "cybertrain/websocket/feed_table"
require "cybertrain/background"

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
  #
  #   503 feed stale            Config#health_feeds, and a feed status row
  #                             (WebSocket::FeedTable) whose updated_at, or
  #                             COALESCE(last_activity_at, started_at), is
  #                             older than Config#health_feed_stale seconds;
  #                             a row whose name is not a subscription this
  #                             binary registers (a feed renamed or removed
  #                             since) is not counted
  #
  # always text/plain with Cache-Control: no-store. It sits inside
  # RequestLogger, so each poll is the normal two log lines and nothing more.
  # Any other method on the path, and every other path, go on down the stack.
  class HealthCheck < Middleware
    # Reads the schema page (page 1): a bare `SELECT 1` never touches the
    # file, so it would answer for a database that is gone. sqlite_master
    # rather than its newer alias sqlite_schema (SQLite 3.33+).
    QUERY = "SELECT count(*) AS n FROM sqlite_master"

    # Whether feed_rows has logged that the table cannot be read, until it
    # reads again (a typed initial value: NOTES rule 7).
    @feed_read_warned = false

    # Whether the WARN about an unreadable status table has been logged and
    # the table not read since: false before the first poll.
    # @return [Boolean]
    # @api private
    def self.feed_read_warned?
      @feed_read_warned
    end

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

      body = HealthCheck.problem(Clock.now.to_i, @worker_stale, @health_feeds, @feed_stale)
      response = ctx.response
      response.status = body.empty? ? 200 : 503
      response.content_type = "text/plain; charset=utf-8"
      response.set_header("Cache-Control", "no-store")
      response.body = body.empty? ? "ok" : body
      nil
    end

    # "" when healthy, else the 503's text. The database first: a worker
    # that cannot reach it is stale for that reason.
    def self.problem(now, worker_stale, feeds, feed_stale)
      return "database unavailable" unless database_ok?
      return "worker stale" if worker_stale?(now, worker_stale)
      return "feed stale" if feeds && feed_stale?(now, feed_stale)

      ""
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

    # Only a running Scheduler can be stale; before its first tick
    # (last_tick 0, the moment after start) it is not.
    def self.worker_stale?(now, worker_stale)
      return false unless Scheduler.running?

      tick = Scheduler.last_tick
      tick > 0 && now - tick > worker_stale
    end

    # Spec section 9's two independent conditions over every status row:
    # the publishing process stopped writing (updated_at old), or the feed
    # is silent under a live publisher (COALESCE(last_activity_at,
    # started_at) old: a feed never active counts from its start). No rows,
    # or an unreadable table, is not stale; the database check says so. A
    # row whose name no registered subscription has is skipped: every role
    # runs the same binary, so this process knows the current feeds, and a
    # feed renamed or removed by a release must not fail every later web
    # deploy with its old row.
    def self.feed_stale?(now, feed_stale)
      limit = now - feed_stale
      rows = feed_rows
      known = Background.feed_names
      rows.each do |row|
        next unless known.include?(Cast.str(row["name"]))
        return true if Cast.int(row["updated_at"]) < limit
        active = row["last_activity_at"]
        seen = active.nil? ? Cast.int(row["started_at"]) : Cast.int(active)
        return true if seen < limit
      end
      false
    end

    # The rows of the status table; none (not stale: the database was just
    # proven reachable, and a flapping /up over an optional signal is worse)
    # when it cannot be read, with one WARN line until it can again. The
    # empty fallback is seeded with a row of read_feeds' shape, so both
    # paths are one type (NOTES rules 10/34/41). The rescue sits in a plain
    # method that does not yield (rules 32/45).
    def self.feed_rows
      rows = WebSocket::FeedTable.read_feeds
      @feed_read_warned = false
      rows
    rescue Cybertrain::DB::Error, StandardError
      unless @feed_read_warned
        @feed_read_warned = true
        Cybertrain.logger.warn("health: the feed status table cannot be read; feeds are not checked")
      end
      Array.new(0) { { "name" => "", "started_at" => 0, "updated_at" => 0 } }
    end
  end
end
