# cybertrain/feeds: WebSocket feeds and the Background services they run
# on, an optional subsystem (require "cybertrain/feeds" in bin/NAME.rb, or
# require "cybertrain"; docs/superpowers/specs/
# 2026-11-13-optional-subsystems-design.md):
#
#   Background services and the feed supervisor  cybertrain/background.rb, background/*.rb
#   the feed status table                        cybertrain/websocket/feed_table.rb
#   `./NAME feeds [NAME...]`, `feeds status`     cybertrain/roles/feeds.rb, here
#   the feed staleness of `/up`                  here
#
# WebSocket.subscribe itself is cybertrain/websocket, which an application
# requires beside this (it requires this file). The core never names any
# of this: the server role checks, starts and stops the services, a role
# waiting for a stop ends when the supervisor gives up on a feed, `/up`
# reports a stale feed and Main.run runs `feeds`, all through
# FeedsFeature, which this file registers at its end
# (cybertrain/feature.rb). It loads the core too. Requiring it twice, or
# after require "cybertrain", is a no-op.
require "cybertrain/core"
require "cybertrain/feature"
require "cybertrain/background"
require "cybertrain/websocket/feed_table"
require "cybertrain/roles/feeds"

module Cybertrain
  # Defined here, on the core's Application, by cybertrain/feeds.
  class Application
    # `./<app> feeds [NAME...]` (Main.run): boots and runs
    # Roles::FeedsRunner: checks the names against the registered feeds (an
    # unknown one is an error that lists them), starts the WebSocket
    # subscriptions (all of them, or the named ones) and runs until SIGTERM
    # or SIGINT, then stops them. No port, no jobs, no scheduler. With no
    # subscription registered it says so and returns 0.
    # @param names [Array<String>] the feeds to run; empty for all
    # @return [Integer] the exit status: 0, or 1 for a refused start or
    #   after a feed died too often
    # @api public
    def run_feeds(names)
      return run_feeds_status if !names.empty? && names[0] == "status"

      busy = Runtime.role_problem
      return Roles.refuse(busy) unless busy.empty?

      Roles.reset_stop
      @config.worker = true
      boot
      Roles::FeedsRunner.new(@config).run_feeds(names)
    end

    # `./<app> feeds status`: boots (the database), prints one line per
    # feed status row (WebSocket::FeedTable) and returns 0; it starts no
    # feed. The line:
    #
    #   NAME  connected|disconnected  process  last activity Ns ago  restarts N  updated Ns ago
    #
    # "last activity never" until the feed's first message. Times are
    # relative to now, so a stale row stands out. A row whose name no
    # registered subscription has (a feed renamed or removed since; `/up`
    # does not count it) ends with "  (not registered)". With no rows it
    # says so.
    # @return [Integer] 0
    # @api public
    def run_feeds_status
      @config.worker = true
      boot
      Roles::FeedsRunner.new(@config).feeds_status
    end

    # One `feeds status` line for a FeedTable row.
    def self.feed_status_line(row, now)
      active = row["last_activity_at"]
      activity = active.nil? ? "never" : "#{now - Cast.int(active)}s ago"
      state = Cast.int(row["connected"]) == 1 ? "connected" : "disconnected"
      name = Cast.str(row["name"])
      note = Background.feed_names.include?(name) ? "" : "  (not registered)"
      "#{name}  #{state}  #{Cast.str(row["process"])}  last activity #{activity}  " \
        "restarts #{Cast.int(row["restarts"])}  updated #{now - Cast.int(row["updated_at"])}s ago#{note}"
    end
  end

  # Defined here, on the core's HealthCheck, by cybertrain/feeds.
  class HealthCheck
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

  # What feeds add to the core, through Feature's hooks: the server role's
  # check of the services before its listener, their start after its
  # banner and their stop at its end, the end of a waiting role when the
  # supervisor gives up on a feed, the feed staleness of `/up`, and the
  # `feeds` command with its help lines.
  # @api private
  class FeedsFeature < Feature
    def feature_name
      "feeds"
    end

    def feature_rank
      20
    end

    # A service that would refuse to start (a WebSocket subscription
    # without on_message).
    def server_problem(config)
      Background.boot_problem(config)
    end

    # The services files like cybertrain/websocket registered when
    # required (none unless Config#worker).
    def start_feature(config)
      Background.start_all(config)
      nil
    end

    def stop_feature
      Background.stop_all
      nil
    end

    # A feeds process's supervisor gave up on a feed.
    def feature_failed?
      Background.feeds_failed?
    end

    def health_problem(now, worker_stale, feeds, feed_stale)
      feeds && HealthCheck.feed_stale?(now, feed_stale) ? "feed stale" : ""
    end

    def run_feature_command(word, args, name, router, url_resolver, views)
      return -1 unless word == "feeds"

      Main.role_app(name, router, url_resolver, views).run_feeds(args)
    end

    def feature_usage(name, slot)
      return "" unless slot == "roles"

      "  ./#{name} feeds [NAME...]   run the WebSocket subscriptions (all, or the named ones)\n" \
        "  ./#{name} feeds status      print each feed's health from the status rows\n"
    end
  end
end

Cybertrain::Features.register_feature(Cybertrain::FeedsFeature.new)
