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
# 2. counts each feed's restarts within {Config#feed_restart_window}; in a
#    `feeds` process ({Background.exit_on_feed_death=}, set by
#    Application#run_feeds) a feed that dies again after
#    {Config#feed_restart_limit} restarts inside the window logs `[FATAL]
#    feed NAME restarted N times in W s; exiting` (N its restarts in the
#    window) and ends supervision with {Background.feeds_failed?} set: the
#    role's main thread then stops the feeds and the process exits with
#    status 1, so the container's restart policy starts a fresh one. A
#    `server` process keeps restarting, at most every 30 s;
# 3. every {Config#feed_status_interval} seconds (and at its first pass)
#    has each service publish its status ({Service#service_publish_status}:
#    the `cybertrain_feeds` rows).
#
# The backoff, the window and the publish interval are measured on the
# monotonic clock (Process::CLOCK_MONOTONIC, as Job and Scheduler do), so
# a step of the wall clock neither delays a restart nor miscounts the
# window; the rows' `updated_at` is epoch seconds from
# {Background.supervisor_clock=}. The state below is written by the
# supervisor thread only (and by the tests' direct
# {Background.supervise_pass} calls while no supervisor runs); the flags
# other threads read are plain booleans, as WebSocket.running? reads its
# own, and a restart is decided under SUPERVISOR_LOCK, which
# stop_supervisor! takes too.

require "cybertrain/logger"
require "cybertrain/config"

module Cybertrain
  module Background
    # One feed the supervisor has seen die: when its restart is due (-1
    # while none is pending) and the monotonic seconds of its restarts
    # inside the window. Distinctive names (NOTES rules 10/34).
    class FeedWatch
      def initialize(name)
        @watch_name = name
        @watch_due_at = -1
        @watch_restarts = Array.new(0) { 0 }
      end

      def watch_name
        @watch_name
      end

      def watch_due_at
        @watch_due_at
      end

      def watch_due!(mono)
        @watch_due_at = mono
        nil
      end

      def watch_restarted!(mono)
        @watch_restarts << mono
        nil
      end

      # How many restarts were less than `window` seconds before `mono`
      # (forgetting the older ones).
      def watch_restarts_in(mono, window)
        kept = Array.new(0) { 0 }
        @watch_restarts.each { |at| kept << at if at > mono - window }
        @watch_restarts = kept
        kept.size
      end
    end

    # Seen deaths, by feed name: a constant, rooted for the collector (NOTES
    # rule 64), seeded and emptied (rule 9).
    WATCHES = Array.new(0) { FeedWatch.new("") }

    # Held while the supervisor starts, stops, and decides a restart.
    SUPERVISOR_LOCK = Mutex.new

    # How long stop_supervisor! waits for the supervisor thread.
    SUPERVISOR_JOIN_SECONDS = 2.0

    # The clock the rows' updated_at is read from: the system's until a
    # test injects one.
    def self.system_clock
      -> { Time.now.to_i }
    end

    # Whole seconds on the monotonic clock: the backoff, the window and
    # the publish interval.
    def self.monotonic_seconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i
    end

    @supervising = false
    @supervisor_generation = 0
    @supervisor_thread = nil
    @exit_on_feed_death = false
    @feeds_failed = false
    # When the status rows are next due (monotonic seconds); -1 publishes
    # at the next pass.
    @next_publish_at = -1
    @supervisor_clock = system_clock

    # Starts the supervisor thread, unless one runs. {Background.start_all}
    # and {Background.start_only} call it when a service with feeds started.
    # @param config [Config] its feed_status_interval, feed_restart_limit
    #   and feed_restart_window
    # @return [Boolean] true when it started the thread
    # @api public
    def self.supervise!(config)
      generation = 0
      SUPERVISOR_LOCK.synchronize do
        unless @supervising
          reset_supervisor!
          @supervising = true
          @supervisor_generation += 1
          generation = @supervisor_generation
        end
      end
      return false if generation == 0

      @supervisor_thread = spawn_supervisor(config, generation)
      true
    end

    # Stops the supervisor thread and waits for it (at most 2 s). Does
    # nothing when none runs. {Background.stop_all} calls it before
    # stopping the services. A pass still running past the wait restarts
    # nothing: the restart is checked against the stop under the lock.
    # @return [nil]
    # @api public
    def self.stop_supervisor!
      running = false
      SUPERVISOR_LOCK.synchronize do
        running = @supervising
        @supervising = false
      end
      return nil unless running

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

    # Replaces the clock the supervisor thread reads the rows' updated_at
    # from, so a test can move it.
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
      @next_publish_at = -1
      @feeds_failed = false
      nil
    end

    # One supervision pass, what the supervisor thread runs every second:
    # dead feeds are scheduled for a restart or restarted, a `feeds`
    # process gives up past the limit, and the status rows are published
    # when due. Called directly (generation 0) only while no supervisor
    # thread runs.
    # @param config [Config]
    # @param now [Integer] epoch seconds, the rows' updated_at
    # @param mono [Integer] monotonic seconds, for the backoff, the window
    #   and the publish interval
    # @param generation [Integer] the calling supervisor thread's, 0 for a
    #   direct call
    # @return [nil]
    # @api private
    def self.supervise_pass(config, now, mono, generation = 0)
      i = 0
      while i < SERVICES.size
        service = SERVICES[i]
        dead = service.service_dead_feeds
        j = 0
        while j < dead.size
          return nil unless pass_live?(generation)
          return nil if supervise_feed(config, service, dead[j], mono, generation)

          j += 1
        end
        i += 1
      end
      return nil if @next_publish_at >= 0 && mono < @next_publish_at
      return nil unless pass_live?(generation)

      @next_publish_at = mono + config.feed_status_interval
      i = 0
      while i < SERVICES.size
        SERVICES[i].service_publish_status(now)
        i += 1
      end
      nil
    end

    # A pass may act: the supervisor thread of `generation` is still the
    # running one, or (generation 0) none runs.
    def self.pass_live?(generation)
      return !@supervising if generation == 0

      supervisor_live?(generation)
    end

    # A dead feed: its first sighting schedules the restart (or gives up),
    # a later one past the due time restarts it. True when the process
    # gives up.
    def self.supervise_feed(config, service, name, mono, generation)
      watch = feed_watch(name)
      due = watch.watch_due_at
      if due < 0
        window = config.feed_restart_window
        restarts = watch.watch_restarts_in(mono, window)
        if @exit_on_feed_death && restarts >= config.feed_restart_limit
          Cybertrain.logger.fatal("feed #{name} restarted #{restarts} times in #{window} s; exiting")
          @feeds_failed = true
          return true
        end
        delay = restart_backoff(service.service_feed_restarts(name))
        watch.watch_due!(mono + delay)
        Cybertrain.logger.warn("feed #{name}: its thread ended; restarting in #{delay}s")
      elsif mono >= due
        watch.watch_due!(-1)
        restart_unless_stopped(service, name, generation, watch, mono)
      end
      false
    end

    # The restart itself, under SUPERVISOR_LOCK and only while this pass's
    # supervisor is the running one: a pass that outlived
    # stop_supervisor!'s wait restarts nothing.
    def self.restart_unless_stopped(service, name, generation, watch, mono)
      SUPERVISOR_LOCK.synchronize do
        if pass_live?(generation) && service.service_restart_feed(name)
          watch.watch_restarted!(mono)
        end
      end
      nil
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
        supervise_tick(config, @supervisor_clock.call, monotonic_seconds, generation)
        return nil if @feeds_failed

        supervisor_wait(generation)
      end
      nil
    end

    # supervise_pass with whatever it raises logged (a database that is
    # gone, or an exception that is not a StandardError from a service):
    # the supervisor keeps going, so the feeds stay supervised. The rescue
    # names Exception, in a method that takes no block (NOTES rules 32/45).
    def self.supervise_tick(config, now, mono, generation)
      supervise_pass(config, now, mono, generation)
    rescue Exception => e
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
