# Cybertrain::Background's feed supervisor (spec section 9): one thread
# per process that runs feeds, started by Background.start_all /
# start_only when a service with feeds (cybertrain/websocket.rb) started,
# and stopped first by Background.stop_all, so a feed that is being
# stopped is not started again. Every second it:
#
# 1. asks each service for its feeds whose thread has ended
#    ({Service#service_dead_feeds}: the loop raised past its rescues, or
#    the runtime killed it), logs a `[WARN]` line and starts the feed
#    again ({Service#service_restart_feed}) `min(30, 2 ** restarts)`
#    seconds later ({Background.restart_backoff});
# 2. counts each feed's deaths within {Config#feed_restart_window}; in a
#    `feeds` process ({Background.exit_on_feed_death=}, set by
#    Application#run_feeds) the death that reaches
#    {Config#feed_restart_limit} logs `[FATAL] feed NAME restarted N times
#    in W s; exiting` and ends supervision with
#    {Background.feeds_failed?} set: the role's main thread then stops the
#    feeds and the process exits with status 1, so the container's restart
#    policy starts a fresh one. A `server` process keeps restarting, at
#    most every 30 s;
# 3. every {Config#feed_status_interval} seconds (and at its first pass)
#    has each service publish its status ({Service#service_publish_status}:
#    the `cybertrain_feeds` rows).
#
# Times are epoch seconds from {Background.supervisor_clock=}. The state
# below is written by the supervisor thread only (and by the tests'
# direct {Background.supervise_pass} calls while no supervisor runs);
# the flags other threads read are plain booleans, as WebSocket.running?
# reads its own.

require "cybertrain/logger"
require "cybertrain/config"

module Cybertrain
  module Background
    # One feed the supervisor has seen die: when its restart is due (-1
    # while none is pending) and the epochs of its deaths inside the
    # window. Distinctive names (NOTES rules 10/34).
    class FeedWatch
      def initialize(name)
        @watch_name = name
        @watch_due_at = -1
        @watch_deaths = Array.new(0) { 0 }
      end

      def watch_name
        @watch_name
      end

      def watch_due_at
        @watch_due_at
      end

      def watch_due!(epoch)
        @watch_due_at = epoch
        nil
      end

      # Records a death at `now`, forgets those `window` seconds or more
      # before it, and answers how many are left (this one included).
      def watch_death!(now, window)
        kept = Array.new(0) { 0 }
        @watch_deaths.each { |at| kept << at if at > now - window }
        kept << now
        @watch_deaths = kept
        kept.size
      end
    end

    # Seen deaths, by feed name: a constant, rooted for the collector (NOTES
    # rule 64), seeded and emptied (rule 9).
    WATCHES = Array.new(0) { FeedWatch.new("") }

    # How long stop_supervisor! waits for the supervisor thread.
    SUPERVISOR_JOIN_SECONDS = 2.0

    # The clock the supervisor reads: the system's until a test injects one.
    def self.system_clock
      -> { Time.now.to_i }
    end

    @supervising = false
    @supervisor_generation = 0
    @supervisor_thread = nil
    @exit_on_feed_death = false
    @feeds_failed = false
    # When the status rows are next due; 0 publishes at the first pass.
    @next_publish_at = 0
    @supervisor_clock = system_clock

    # Starts the supervisor thread, unless one runs. {Background.start_all}
    # and {Background.start_only} call it when a service with feeds started.
    # @param config [Config] its feed_status_interval, feed_restart_limit
    #   and feed_restart_window
    # @return [Boolean] true when it started the thread
    # @api public
    def self.supervise!(config)
      return false if @supervising

      reset_supervisor!
      @supervising = true
      @supervisor_generation += 1
      @supervisor_thread = spawn_supervisor(config, @supervisor_generation)
      true
    end

    # Stops the supervisor thread and waits for it (at most 2 s). Does
    # nothing when none runs. {Background.stop_all} calls it before
    # stopping the services.
    # @return [nil]
    # @api public
    def self.stop_supervisor!
      return nil unless @supervising

      @supervising = false
      thread = @supervisor_thread
      join_supervisor(thread) unless thread.nil?
      nil
    end

    # Thread#join raises what the thread died of; stopping must not (a
    # rescue in a method that takes no block: NOTES rules 32/45).
    def self.join_supervisor(thread)
      thread.join(SUPERVISOR_JOIN_SECONDS)
      nil
    rescue Exception
      nil
    end

    # @return [Boolean] true between {Background.supervise!} and
    #   {Background.stop_supervisor!}
    # @api public
    def self.supervising?
      @supervising
    end

    # Whether a feed that dies too often ends the process: true in a
    # `feeds` process (Application#run_feeds sets it for the role's
    # lifetime), false in a `server` process, which serves requests and
    # keeps restarting the feed.
    # @param value [Boolean]
    # @return [Boolean]
    # @api public
    def self.exit_on_feed_death=(value)
      @exit_on_feed_death = value
    end

    # @return [Boolean] see {Background.exit_on_feed_death=}
    # @api public
    def self.exit_on_feed_death?
      @exit_on_feed_death
    end

    # True once the supervisor gave up on a feed in a `feeds` process (the
    # FATAL line is logged): the role's main thread stops the feeds and
    # exits with status 1.
    # @return [Boolean]
    # @api public
    def self.feeds_failed?
      @feeds_failed
    end

    # Replaces the clock the supervisor thread reads, so a test can move
    # time.
    # @param clock [Proc] takes no arguments, answers epoch seconds
    # @return [Proc]
    # @api public
    def self.supervisor_clock=(clock)
      @supervisor_clock = clock
    end

    # Seconds the supervisor waits before starting a dead feed again,
    # given how many times it was restarted before: min(30, 2 ** restarts).
    # @param restarts [Integer]
    # @return [Integer]
    # @api public
    def self.restart_backoff(restarts)
      return 1 if restarts < 1
      return 30 if restarts >= 5

      2**restarts
    end

    # Forgets the deaths seen, the pending restarts, a give-up and when the
    # rows were last published (supervise! starts from here, and
    # Application#run_feeds clears its role's state with it).
    # @return [nil]
    # @api private
    def self.reset_supervisor!
      WATCHES.clear
      @next_publish_at = 0
      @feeds_failed = false
      nil
    end

    # One supervision pass at `now` (epoch seconds), what the supervisor
    # thread runs every second: dead feeds are scheduled for a restart or
    # restarted, a `feeds` process gives up past the limit, and the status
    # rows are published when due.
    # @param config [Config]
    # @param now [Integer] epoch seconds
    # @return [nil]
    # @api private
    def self.supervise_pass(config, now)
      i = 0
      while i < SERVICES.size
        service = SERVICES[i]
        dead = service.service_dead_feeds
        j = 0
        while j < dead.size
          return nil if supervise_feed(config, service, dead[j], now)

          j += 1
        end
        i += 1
      end
      return nil if now < @next_publish_at

      @next_publish_at = now + config.feed_status_interval
      i = 0
      while i < SERVICES.size
        SERVICES[i].service_publish_status(now)
        i += 1
      end
      nil
    end

    # A dead feed: its first sighting schedules the restart (or gives up),
    # a later one past the due time restarts it. True when the process
    # gives up.
    def self.supervise_feed(config, service, name, now)
      watch = feed_watch(name)
      due = watch.watch_due_at
      if due < 0
        window = config.feed_restart_window
        deaths = watch.watch_death!(now, window)
        if @exit_on_feed_death && deaths >= config.feed_restart_limit
          Cybertrain.logger.fatal("feed #{name} restarted #{deaths} times in #{window} s; exiting")
          @feeds_failed = true
          return true
        end
        delay = restart_backoff(service.service_feed_restarts(name))
        watch.watch_due!(now + delay)
        Cybertrain.logger.warn("feed #{name}: its thread ended; restarting in #{delay}s")
      elsif now >= due
        watch.watch_due!(-1)
        service.service_restart_feed(name)
      end
      false
    end

    # The watch of the feed `name`, made on first use.
    def self.feed_watch(name)
      i = 0
      while i < WATCHES.size
        return WATCHES[i] if WATCHES[i].watch_name == name

        i += 1
      end
      watch = FeedWatch.new(name)
      WATCHES << watch
      watch
    end

    # ---- the supervisor thread ----------------------------------------------

    def self.supervisor_live?(generation)
      @supervising && @supervisor_generation == generation
    end

    # Through a method, the closure capturing the parameters (NOTES rule
    # 21), as WebSocket.spawn_feed.
    def self.spawn_supervisor(config, generation)
      Thread.new { supervisor_loop(config, generation) }
    end

    def self.supervisor_loop(config, generation)
      while supervisor_live?(generation)
        supervise_tick(config, @supervisor_clock.call)
        return nil if @feeds_failed

        supervisor_wait(generation)
      end
      nil
    end

    # supervise_pass with its errors logged (a database that is gone): the
    # supervisor keeps going. The rescue is in a method that takes no
    # block (NOTES rules 32/45).
    def self.supervise_tick(config, now)
      supervise_pass(config, now)
    rescue StandardError => e
      Cybertrain.logger.error("feed supervisor: #{e.class.name}: #{e.message}")
      nil
    end

    # A second, a tenth at a time, ending early on stop_supervisor!.
    def self.supervisor_wait(generation)
      n = 0
      while n < 10 && supervisor_live?(generation)
        sleep(0.1)
        n += 1
      end
      nil
    end
  end
end
