require "cybertrain/cast"
require "cybertrain/clock"
require "cybertrain/background"
require "cybertrain/error_reporter"

module Cybertrain
  module Roles
    # `./<app> feeds [NAME...]`: the WebSocket subscriptions (all of them,
    # or the named ones: Background.start_only) and their supervisor, until
    # SIGTERM or SIGINT, then their shutdown. No port, no jobs, no
    # scheduler. The Application has booted before #run_feeds is called.
    #
    #   starts   the named feeds, the feed supervisor
    #   waits    Roles.wait_stop (TERM, INT, or a feed that keeps dying)
    #   stops    the supervisor, the feeds; the status rows withdrawn after
    #            a clean stop; waits up to 2 s for the queued error
    #            reports; the TERM and INT handlers given back
    # @api private
    class FeedsRunner
      # @param config [Config] the booted Application's
      def initialize(config)
        @config = config
      end

      # Checks the names against the registered feeds (an unknown one is an
      # error that lists them) and runs them. With no subscription
      # registered it says so and returns 0.
      # @param names [Array<String>] the feeds to run; empty for all
      # @return [Integer] the exit status
      def run_feeds(names)
        config = @config
        unknown = Background.unknown_feed(names)
        return Roles.refuse(unknown) unless unknown.empty?

        problem = Background.boot_problem(config)
        return Roles.refuse(problem) unless problem.empty?

        known = Background.feed_names
        ENV["SPINEL_WORKERS"] = Application.spinel_workers_for(config).to_s
        if known.empty?
          Roles.print_banner(config, "feeds: no WebSocket subscription is registered; nothing to run")
          return 0
        end
        busy = Runtime.enter_role("feeds")
        return Roles.refuse(busy) unless busy.empty?

        Roles.print_banner(config, "feeds: #{(names.empty? ? known : names).join(", ")}")
        # INT as TERM (Ctrl-C), and the handlers given back, as in WorkerRunner.
        previous_term = trap("TERM") { Roles.request_stop }
        previous_int = trap("INT") { Roles.request_stop }
        run_feeds_threads(names, previous_term, previous_int)
      end

      # `./<app> feeds status`: prints one line per feed status row
      # (WebSocket::FeedTable) and returns 0; it starts no feed. See
      # Application#run_feeds_status for the line.
      # @return [Integer] 0
      def feeds_status
        now = Clock.now.to_i
        rows = WebSocket::FeedTable.read_feeds
        puts "no feed has reported status" if rows.empty?
        rows.each { |row| puts Application.feed_status_line(row, now) }
        STDOUT.flush
        0
      end

      private

      # The feeds' lifetime, the counterpart of WorkerRunner#run_worker_threads.
      #
      # In this role a feed whose thread keeps dying ends the process
      # (Background.exit_on_feed_death, spec section 9): the supervisor
      # logs the FATAL line and sets Background.feeds_failed?, which ends
      # the wait as a stop does; the feeds are stopped and the role answers
      # 1, the exit status Main.run's caller exits with. (The supervisor
      # thread cannot exit itself: under Spinel `exit` on a thread other
      # than the main one ends only that thread.)
      #
      # On a clean stop (TERM, INT, a scale-down) the feeds' status rows
      # this process wrote are deleted (Background.withdraw_status_all), so
      # `/up` stops counting feeds nobody runs any more; a process that
      # crashed, or gave up on a feed, leaves them to go stale.
      # @param names [Array<String>] the feeds to run; empty for all
      # @param previous_term [Object] what trap("TERM") answered
      # @param previous_int [Object] what trap("INT") answered
      # @return [Integer] 0, or 1 after a feed died too often
      def run_feeds_threads(names, previous_term, previous_int)
        stopped = false
        Background.exit_on_feed_death = true
        Background.start_only(@config, names)
        Roles.wait_stop
        Background.stop_all
        stopped = true
        return 1 if Background.feeds_failed?

        Background.withdraw_status_all
        0
      ensure
        # Also when a feed's start raised (D66): the feeds started before
        # it are stopped. The flags are the role's: an in-process caller (a
        # test) that runs another role afterwards starts clean.
        # A service whose stop raises must not keep the role claimed or
        # the caller's handlers replaced: the inner ensure runs either way,
        # and the exception goes on to the caller.
        begin
          Background.stop_all unless stopped
        ensure
          # The error reports still queued (a give-up's among them), up to
          # 2 seconds (docs/design.md D87).
          Cybertrain.error.drain_reports(2.0)
          Background.exit_on_feed_death = false
          Background.reset_supervisor!
          Runtime.leave_role
          trap("TERM", previous_term)
          trap("INT", previous_int)
        end
      end
    end
  end
end
