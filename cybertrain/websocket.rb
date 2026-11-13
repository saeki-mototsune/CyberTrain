# Cybertrain::WebSocket -- long-lived subscriptions to outbound WebSocket
# feeds (market ticks, telemetry, event streams) while the server runs.
#
#   # config/app.rb, or a file bin/<app>.rb requires before Main.run:
#   require "cybertrain/websocket"
#   require "cybertrain/net/tls"   # for wss:// only
#
#   Cybertrain::WebSocket.subscribe("trades", ENV["FEED_URL"], stale_after: 30)
#     .on_open    { |conn| conn.send_text(JSON.generate({ "op" => "subscribe" })) }
#     .on_message { |conn, text| Cybertrain::DB.with { |c| c.execute("INSERT INTO trades(raw) VALUES (?)", [text]) } }
#
# Requiring this file registers a Background service, so Application#serve
# starts the feeds ({WebSocket.start!}) after the scheduler and stops them
# ({WebSocket.stop!}) at shutdown; `./<app> migrate`, `db ...`,
# Main.command and Test::Client never do. Each subscription gets one
# thread, started through a method (spikes/NOTES.md rule 21), that:
#
# 1. connects ({Client.connect}) and calls `on_open` (an exception there is
#    logged and the connection closed: a feed that is not subscribed is of
#    no use);
# 2. calls `receive(1)` in a loop, so it looks at {WebSocket.stop!} and the
#    clock every second, and hands each message to `on_message` (an
#    exception there is logged; the connection stays);
# 3. sends a ping once nothing has arrived for `ping_interval` seconds (and
#    then once per `ping_interval`);
# 4. after `stale_after` seconds without any frame, closes the connection
#    and reconnects;
# 5. after any error logs it and waits {WebSocket.retry_delay} seconds (1,
#    2, 4, ... up to 60, +-20 %; back to 1 after a connection that lasted
#    60 s), looking at stop! every second, then goes back to 1;
# 6. between those one-second waits, connected or not, calls `on_tick`
#    every N seconds when the subscription has one
#    ({Subscription#on_tick}; `conn` is nil while disconnected).
#
# A feed's thread that ends anyway (an exception that is not a
# StandardError, or the runtime killing it) is started again by the
# supervisor (cybertrain/background/supervisor.rb), which also writes each
# feed's status into `cybertrain_feeds` (WebSocket::FeedTable, which the
# framework entry point requires) every
# Config#feed_status_interval seconds; a `feeds` process whose feed keeps
# dying exits with status 1.
#
# Every wait is bounded and is a wait_readable or a sleep, except one: each
# connect attempt resolves the host name with a blocking getaddrinfo
# (Net.resolve), which holds the OS worker until the resolver answers or
# times out. With SPINEL_WORKERS=1 a dead resolver stalls requests for the
# resolver's timeout once per attempt per feed; an IP address in the URL
# skips the lookup.
# A SQLite call in `on_message` also holds the worker until it returns (as
# a Scheduler task's does): keep the work per
# message small, or collect messages in memory and write them from a
# Scheduler task. Not built: adding or removing subscriptions while the
# feeds run (subscribe before the server starts), and sending from outside
# the callbacks (the Connection they receive is valid only during the call).
require "json"
require "cybertrain/logger"
require "cybertrain/config"
require "cybertrain/background"
# The feeds subsystem: the server role starts the services, `./<app> feeds`
# runs them, `/up` checks them (FeedsFeature).
require "cybertrain/feeds"
require "cybertrain/http_client"
require "cybertrain/websocket/frame"
require "cybertrain/websocket/client"
require "cybertrain/websocket/status_writer"

module Cybertrain
  module WebSocket
    # What a callback uses to talk back on the connection it was called
    # for. Valid only during the call.
    # @api public
    class Connection
      def initialize(client)
        @client = client
        @last_opcode = :text
      end

      # Sends a text message.
      # @param text [String]
      # @return [nil]
      # @raise [Error] when the connection is gone (the feed reconnects)
      # @api public
      def send_text(text)
        @client.send_text(text)
      end

      # Sends a binary message.
      # @param data [String]
      # @return [nil]
      # @api public
      def send_binary(data)
        @client.send_binary(data)
      end

      # Closes the connection (close 1000); the feed reconnects after the
      # retry delay.
      # @return [nil]
      # @api public
      def close
        @client.close
      end

      # The kind of the message on_message was last given.
      # @return [Symbol] :text or :binary
      # @api public
      def last_opcode
        @last_opcode
      end

      def conn_opcode!(opcode)
        @last_opcode = opcode
        nil
      end
    end

    # A snapshot of a subscription's state, from {WebSocket.feed_status}.
    # @api public
    class Status
      def initialize(connected, last_message_at, reconnects, restarts, thread_alive)
        @connected = connected
        @last_message_at = last_message_at
        @reconnects = reconnects
        @restarts = restarts
        @thread_alive = thread_alive
      end

      # @return [Boolean] whether the feed is connected now
      # @api public
      def connected?
        @connected
      end

      # @return [Integer] epoch seconds of the last message, 0 for none yet
      # @api public
      def last_message_at
        @last_message_at
      end

      # @return [Integer] how many times the feed connected again after its
      #   first connection
      # @api public
      def reconnects
        @reconnects
      end

      # @return [Integer] how many times the supervisor started the feed's
      #   thread again after it ended
      # @api public
      def restarts
        @restarts
      end

      # @return [Boolean] whether the feed's thread is running (false
      #   before {WebSocket.start!}, after {WebSocket.stop!}, and between
      #   the thread's death and its restart)
      # @api public
      def thread_alive?
        @thread_alive
      end
    end

    # One registered feed, from {WebSocket.subscribe}. Distinctive accessor
    # names and no #call (NOTES rules 10/34/40).
    # @api public
    class Subscription
      attr_reader :sub_url, :sub_target, :sub_headers, :sub_timeout, :sub_max_message,
                  :sub_ping_interval, :sub_stale_after, :sub_allow_private,
                  :sub_open_block, :sub_message_block, :sub_thread, :sub_tick_block, :sub_tick_seconds

      def initialize(name, url, target, headers, timeout, max_message, ping_interval, stale_after, allow_private)
        @sub_name = name
        @sub_url = url
        @sub_target = target
        @sub_headers = headers
        @sub_timeout = timeout
        @sub_max_message = max_message
        @sub_ping_interval = ping_interval
        @sub_stale_after = stale_after
        @sub_allow_private = allow_private
        @sub_open_block = nil
        @sub_message_block = nil
        @sub_thread = nil
        # The connection the feed thread has open, nil between connections:
        # only the feed thread touches it (closed on its way out if the
        # thread dies, so a restart never leaves the old socket open).
        @sub_client = nil
        @sub_tick_block = nil
        @sub_tick_seconds = 0
        # When on_tick is next due (Net::Timer.now): only the feed thread
        # touches it.
        @sub_tick_next = 0.0
        # Guarded by WebSocket::LOCK: the feed thread writes them, a request
        # thread reads them through WebSocket.feed_status.
        @connected = false
        @last_message_at = 0
        @reconnects = 0
        @sessions = 0
        # Epoch seconds of the last message or pong, 0 for none; when
        # start! started the feed, 0 when it did not; how many times the
        # supervisor started its thread again.
        @last_activity_at = 0
        @started_at = 0
        @restarts = 0
        # When the current connection opened (Net::Timer.now), -1.0 when
        # none is open: only the feed thread touches it.
        @connected_since = -1.0
      end

      # @return [String] the name given to {WebSocket.subscribe}
      # @api public
      def sub_name
        @sub_name
      end

      # Sets the block called after each (re)connect, before any message:
      # send the subscription request here. It receives a {Connection}.
      # @return [Subscription] self
      # @api public
      def on_open(&block)
        @sub_open_block = block
        self
      end

      # Sets the block called with each message: `|conn, data|`, a
      # {Connection} and the bytes (a text message is UTF-8 as the server
      # sent it, not checked). Required before {WebSocket.start!}.
      # @return [Subscription] self
      # @api public
      def on_message(&block)
        @sub_message_block = block
        self
      end

      # Sets the block called every `seconds` on the feed's own thread,
      # between its one-second waits, whether or not the feed is connected:
      # `|conn|`, a {Connection} while connected and nil while not (test
      # it). The first call is `seconds` after the feed starts. An
      # exception is logged and the feed goes on, as for on_message. Work
      # that belongs to the feed's thread (flushing what on_message
      # collected, closing a time bucket) goes here, with no lock and no
      # scheduler task.
      # @param seconds [Integer] at least 1 (the granularity is the
      #   one-second receive timeout)
      # @return [Subscription] self
      # @raise [ArgumentError] seconds is not an Integer of at least 1, or
      #   the subscription already has an on_tick
      # @api public
      def on_tick(seconds, &block)
        unless seconds.is_a?(Integer) && seconds >= 1
          message = "WebSocket subscription #{@sub_name.inspect}: on_tick needs whole seconds, at least 1 (got #{seconds.inspect})"
          raise ArgumentError, message
        end
        unless @sub_tick_block.nil?
          message = "WebSocket subscription #{@sub_name.inspect} already has on_tick"
          raise ArgumentError, message
        end
        @sub_tick_block = block
        @sub_tick_seconds = seconds
        self
      end

      # Whether on_tick is due at `now` (Net::Timer.now); false without one.
      # @param now [Float]
      # @return [Boolean]
      def sub_tick_due?(now)
        !@sub_tick_block.nil? && now >= @sub_tick_next
      end

      # The feed's thread started at `now`: the first tick is due
      # sub_tick_seconds later.
      def sub_tick_start!(now)
        @sub_tick_next = now + @sub_tick_seconds
        nil
      end

      # on_tick ran at `now`: the next one is due sub_tick_seconds later.
      def sub_ticked!(now)
        @sub_tick_next = now + @sub_tick_seconds
        nil
      end

      def sub_thread!(thread)
        @sub_thread = thread
        nil
      end

      def sub_client!(client)
        @sub_client = client
        nil
      end

      # Closes the connection the feed thread had open, if any (close
      # never raises, and a second close does nothing), and forgets it.
      def sub_drop_client
        client = @sub_client
        @sub_client = nil
        client.ws_close_within(STOP_CLOSE_SECONDS) unless client.nil?
        nil
      end

      # "ws://host:port" for the start line (no path, no query).
      def sub_origin
        scheme = @sub_target.target_tls ? "wss://" : "ws://"
        "#{scheme}#{@sub_target.target_label}"
      end

      # The status fields, each read under the lock. Status itself is built
      # by WebSocket.feed_status: a method that returns a Status from inside
      # a synchronize block does not compile in a program with the whole
      # framework (Spinel lays Status out as a value type there).
      def sub_connected?
        connected = false
        LOCK.synchronize { connected = @connected }
        connected
      end

      def sub_last_message_at
        last = 0
        LOCK.synchronize { last = @last_message_at }
        last
      end

      def sub_reconnects
        count = 0
        LOCK.synchronize { count = @reconnects }
        count
      end

      # Epoch seconds of the last message or pong, 0 for none yet.
      def sub_last_activity_at
        last = 0
        LOCK.synchronize { last = @last_activity_at }
        last
      end

      # Epoch seconds of when start! started this feed, 0 when the feeds
      # that run (or ran last) do not include it.
      def sub_started_at
        at = 0
        LOCK.synchronize { at = @started_at }
        at
      end

      def sub_started!(epoch)
        LOCK.synchronize { @started_at = epoch }
        nil
      end

      def sub_restarts
        count = 0
        LOCK.synchronize { count = @restarts }
        count
      end

      # The supervisor started the thread again; answers the new count.
      def sub_restarted!
        count = 0
        LOCK.synchronize do
          @restarts = @restarts + 1
          count = @restarts
        end
        count
      end

      # A connection opened: a reconnect unless it is the first.
      def sub_connected!(now)
        LOCK.synchronize do
          @reconnects = @reconnects + 1 if @sessions > 0
          @sessions = @sessions + 1
          @connected = true
        end
        @connected_since = now
        nil
      end

      def sub_disconnected!
        LOCK.synchronize { @connected = false }
        nil
      end

      def sub_message!(epoch)
        LOCK.synchronize do
          @last_message_at = epoch
          @last_activity_at = epoch
        end
        nil
      end

      # A pong arrived: the feed is alive though it sent no message.
      def sub_activity!(epoch)
        LOCK.synchronize { @last_activity_at = epoch }
        nil
      end

      # How long the connection that just ended lasted (0.0 when none
      # opened), and forgets it.
      def sub_lasted(now)
        since = @connected_since
        @connected_since = -1.0
        return 0.0 if since < 0.0

        now - since
      end
    end

    # The registry: a constant, which Spinel roots for the collector
    # (NOTES rule 64), seeded and emptied (rule 9).
    SUBSCRIPTIONS = Array.new(0) do
      Subscription.new("", "", HttpClient::Target.new(false, "", 0, "", ""), Client::NO_HEADERS, 5, 1, 15, 45, false)
    end

    # Guards each Subscription's status fields.
    LOCK = Mutex.new

    # A connection that lasted this long resets the retry delay to 1 s.
    STEADY_SECONDS = 60.0

    # How long stop! waits for all the feed threads together.
    STOP_JOIN_SECONDS = 2.0

    # How long a feed that is being stopped waits for the server's close.
    STOP_CLOSE_SECONDS = 1.0

    @running = false
    # Counts start!s: a feed loop left from before a stop! and a new start!
    # sees a newer number and ends instead of running beside the new one.
    @generation = 0
    @random_source = -> { rand }
    # "<hostname>:<pid>", the `process` of the status rows; "" until the
    # first publish_status.
    @process_label = ""

    # Registers a feed to keep connected while the server runs. Register
    # before the server starts; give it {Subscription#on_message} (and
    # usually {Subscription#on_open}).
    # @example
    #   Cybertrain::WebSocket.subscribe("trades", "wss://feed.example.com/v1")
    #     .on_open { |conn| conn.send_text("{\"op\":\"subscribe\"}") }
    #     .on_message { |conn, text| Trade.record(text) }
    # @param name [String] for the log and {WebSocket.feed_status}; unique
    # @param url [String] ws:// or wss://
    # @param headers [Hash{String => String}] extra handshake headers
    # @param timeout [Numeric] seconds per wait while connecting and per write
    # @param max_message [Integer] the largest message accepted, in bytes
    # @param ping_interval [Integer] seconds of quiet before a ping, at least 1
    # @param stale_after [Integer] seconds of quiet before reconnecting,
    #   more than ping_interval
    # @param allow_private [Boolean] allow non-public destinations
    # @return [Subscription]
    # @raise [ArgumentError] an empty, reserved ("status") or taken name, a URL that is not ws://
    #   or wss://, a header the client refuses, a bad interval
    # @api public
    def self.subscribe(name, url, headers: Client::NO_HEADERS, timeout: 5, max_message: 1_048_576,
                       ping_interval: 15, stale_after: 45,
                       allow_private: Cybertrain.config.http_allow_private)
      label = name.to_s
      raise ArgumentError, "WebSocket.subscribe: the name is empty" if label.empty?
      # `./<app> feeds status` is the status command, so no feed can be
      # started by that name.
      raise ArgumentError, "WebSocket.subscribe: the name \"status\" is reserved (./<app> feeds status)" if label == "status"
      raise ArgumentError, "WebSocket.subscribe #{label.inspect}: already registered" if subscription_index(label) >= 0

      target = HttpClient.parse_url_for(url, "ws://", "wss://")
      ping = ping_interval.to_i
      stale = stale_after.to_i
      raise ArgumentError, "WebSocket.subscribe #{label.inspect}: ping_interval must be at least 1" if ping < 1
      raise ArgumentError, "WebSocket.subscribe #{label.inspect}: stale_after must be more than ping_interval" if stale <= ping
      raise ArgumentError, "WebSocket.subscribe #{label.inspect}: timeout must be positive" unless timeout.to_f > 0.0
      raise ArgumentError, "WebSocket.subscribe #{label.inspect}: max_message must be at least 1" if max_message.to_i < 1

      # The headers are checked now, not at every connect.
      Client.handshake_head(target, "", headers)
      sub = Subscription.new(label, url.to_s, target, headers, timeout.to_f, max_message.to_i, ping, stale, allow_private == true)
      SUBSCRIPTIONS << sub
      sub
    end

    # The index of the subscription named name, -1 when none (NOTES rules
    # 11/56).
    def self.subscription_index(name)
      i = 0
      while i < SUBSCRIPTIONS.size
        return i if SUBSCRIPTIONS[i].sub_name == name
        i += 1
      end
      -1
    end

    # The state of the feed named `name`. Not part of `/up`: an
    # application's own health check can use it.
    # @param name [String]
    # @return [Status]
    # @raise [ArgumentError] when no feed has that name
    # @api public
    def self.feed_status(name)
      i = subscription_index(name.to_s)
      raise ArgumentError, "WebSocket.feed_status: no subscription named #{name.to_s.inspect}" if i < 0

      sub = SUBSCRIPTIONS[i]
      Status.new(sub.sub_connected?, sub.sub_last_message_at, sub.sub_reconnects, sub.sub_restarts, sub_alive?(sub))
    end

    # Whether the thread of the feed named `name` is running.
    # @param name [String]
    # @return [Boolean]
    # @raise [ArgumentError] when no feed has that name
    # @api public
    def self.thread_alive?(name)
      i = subscription_index(name.to_s)
      raise ArgumentError, "WebSocket.thread_alive?: no subscription named #{name.to_s.inspect}" if i < 0

      sub_alive?(SUBSCRIPTIONS[i])
    end

    def self.sub_alive?(sub)
      thread = sub.sub_thread
      !thread.nil? && thread.alive?
    end

    # The names of the feeds {WebSocket.start!} started whose thread has
    # ended while the feeds run, for the supervisor to restart.
    # @return [Array<String>]
    # @api public
    def self.dead_feeds
      out = Array.new(0) { "" }
      return out unless @running

      i = 0
      while i < SUBSCRIPTIONS.size
        sub = SUBSCRIPTIONS[i]
        out << sub.sub_name if sub.sub_started_at > 0 && !sub_alive?(sub)
        i += 1
      end
      out
    end

    # Starts the feed named `name` again on a new thread, when the feeds
    # run, it is one of those {WebSocket.start!} started and its thread
    # has ended; counts it in {Status#restarts}. The supervisor calls it.
    # @param name [String]
    # @return [Boolean] true when it started a thread
    # @api public
    def self.restart_feed(name)
      i = subscription_index(name.to_s)
      return false if i < 0 || !@running

      sub = SUBSCRIPTIONS[i]
      return false if sub.sub_started_at == 0 || sub_alive?(sub)

      sub.sub_disconnected!
      count = sub.sub_restarted!
      Cybertrain.logger.info("WebSocket restarted: #{sub.sub_name} (restart #{count})")
      sub.sub_thread!(spawn_feed(sub, @generation))
      true
    end

    # Writes one status row per feed {WebSocket.start!} started, with
    # `updated_at` = `now`, through the registered {StatusWriter}s (in an
    # application, the `cybertrain_feeds` row of {FeedTable}, when a
    # database is connected); nothing when the feeds do not run. The
    # supervisor calls it every Config#feed_status_interval seconds.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many rows were written
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.publish_status(now)
      return 0 unless @running

      process = status_process
      written = 0
      i = 0
      while i < SUBSCRIPTIONS.size
        sub = SUBSCRIPTIONS[i]
        started_at = sub.sub_started_at
        if started_at > 0
          connected = sub_alive?(sub) && sub.sub_connected?
          last_activity_at = sub.sub_last_activity_at
          restarts = sub.sub_restarts
          j = 0
          while j < STATUS_WRITERS.size
            wrote = STATUS_WRITERS[j].status_write(sub.sub_name, process, connected, started_at, last_activity_at,
                                                   restarts, now)
            written += 1 if wrote
            j += 1
          end
        end
        i += 1
      end
      written
    end

    # "<hostname>:<pid>", the `process` this process writes in its status
    # rows.
    # @return [String]
    # @api public
    def self.status_process
      @process_label = "#{Socket.gethostname}:#{Process.pid}" if @process_label.empty?
      @process_label
    end

    # Deletes the status rows this process wrote, through the registered
    # {StatusWriter}s: a `feeds` process does it after a clean stop
    # (Application#run_feeds_threads), so the health check stops counting
    # feeds nobody runs. A crashed process deletes nothing, and its rows go
    # stale. Does nothing while the feeds run.
    # @return [Integer] how many rows were deleted
    # @api public
    def self.withdraw_status
      return 0 if @running

      process = status_process
      removed = 0
      i = 0
      while i < STATUS_WRITERS.size
        removed += STATUS_WRITERS[i].status_withdraw(process)
        i += 1
      end
      removed
    end

    # Why {WebSocket.start!} would refuse to start: the first subscription
    # without on_message, named. Application#serve asks it (through
    # Background.boot_problem) before binding the port.
    # @return [String] "" when every subscription has on_message
    # @api public
    def self.subscriptions_problem
      i = 0
      while i < SUBSCRIPTIONS.size
        sub = SUBSCRIPTIONS[i]
        return "WebSocket subscription #{sub.sub_name.inspect} has no on_message" if sub.sub_message_block.nil?

        i += 1
      end
      ""
    end

    # The names of the registered subscriptions, in registration order.
    # @return [Array<String>]
    # @api public
    def self.feed_names
      out = Array.new(0) { "" }
      SUBSCRIPTIONS.each { |sub| out << sub.sub_name }
      out
    end

    # `unknown feed "NAME" (registered: a, b)` for the first of `names`
    # that is not a subscription's name, "" when all are (`./<app> feeds
    # NAME...` checks its arguments with it, through Background).
    # @param names [Array<String>]
    # @return [String]
    # @api public
    def self.unknown_feed(names)
      Background.unknown_name_in(names, feed_names)
    end

    # Starts one thread per subscription (only those named in `only`, when
    # it is not empty), unless {Config#worker} is off, nothing is
    # subscribed or the feeds already run. Application#serve calls it
    # (through the Background service) with every subscription; `./<app>
    # feeds NAME...` with the named ones.
    # @param config [Config]
    # @param only [Array<String>] subscription names; empty for all
    # @return [Boolean] true when it started the threads
    # @raise [ArgumentError] when a subscription has no on_message, or a
    #   name in `only` is not subscribed
    # @api public
    def self.start!(config = Cybertrain.config, only: Background::NO_NAMES)
      return false if @running
      unless config.worker
        Cybertrain.logger.info("Background worker off (CYBERTRAIN_WORKER=0): WebSocket subscriptions run elsewhere")
        return false
      end
      return false if SUBSCRIPTIONS.empty?

      problem = subscriptions_problem
      raise ArgumentError, "WebSocket.start!: #{problem}" unless problem.empty?
      unknown = unknown_feed(only)
      raise ArgumentError, "WebSocket.start!: #{unknown}" unless unknown.empty?

      # spikes/NOTES.md rule 22: before the first Thread.new.
      ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
      @running = true
      @generation += 1
      generation = @generation
      started_at = Time.now.to_i
      i = 0
      while i < SUBSCRIPTIONS.size
        sub = SUBSCRIPTIONS[i]
        if only.empty? || only.include?(sub.sub_name)
          Cybertrain.logger.info("WebSocket started: #{sub.sub_name} (#{sub.sub_origin})")
          sub.sub_started!(started_at)
          sub.sub_thread!(spawn_feed(sub, generation))
        else
          sub.sub_started!(0)
        end
        i += 1
      end
      true
    end

    # Asks every feed to end and waits for them, at most 2 s in all: a
    # connected feed sends close 1000 and waits at most 1 s for the
    # server's answer. Every feed reads as disconnected once it returns
    # (a thread still closing finishes on its own). Does nothing when the
    # feeds do not run.
    # @return [nil]
    # @api public
    def self.stop!
      return nil unless @running

      @running = false
      ends_at = Net::Timer.now + STOP_JOIN_SECONDS
      i = 0
      while i < SUBSCRIPTIONS.size
        thread = SUBSCRIPTIONS[i].sub_thread
        left = ends_at - Net::Timer.now
        join_feed(thread, left) if !thread.nil? && left > 0.0
        i += 1
      end
      i = 0
      while i < SUBSCRIPTIONS.size
        SUBSCRIPTIONS[i].sub_disconnected!
        i += 1
      end
      nil
    end

    # Waits at most `wait` seconds for a feed thread. Thread#join raises
    # the exception a thread died of (one that is not a StandardError ends
    # a feed's thread: the supervisor restarts it); stop! must not, so the
    # rescue names Exception, in a method that takes no block (NOTES rules
    # 32/45).
    def self.join_feed(thread, wait)
      thread.join(wait)
      nil
    rescue Exception
      nil
    end

    # @return [Boolean] true between {WebSocket.start!} and {WebSocket.stop!}
    # @api public
    def self.running?
      @running
    end

    # Seconds to wait before connecting again after the `attempt`th failure
    # in a row: min(60, 2 ** (attempt - 1)), times 0.8 to 1.2.
    # @param attempt [Integer] 1 for the first failure
    # @param jitter [Float] 0.0..1.0 (0.5 is the plain doubling)
    # @return [Float]
    # @api public
    def self.retry_delay(attempt, jitter)
      n = attempt.to_i
      base = 1
      if n >= 7
        base = 60
      elsif n > 1
        base = 2**(n - 1)
      end
      j = jitter.to_f
      j = 0.0 if j < 0.0
      j = 1.0 if j > 1.0
      # Tenths, so (1, 1.0) is exactly 1.2 (0.8 + 0.4 is not).
      (base.to_f * (8.0 + 4.0 * j)) / 10.0
    end

    # The source of the retry delay's jitter: a Proc answering a Float in
    # 0.0..1.0. Tests set `-> { 0.5 }`.
    # @param source [Proc]
    # @return [Proc]
    # @api public
    def self.random_source=(source)
      @random_source = source
    end

    # ---- the feed threads ---------------------------------------------------

    def self.feed_live?(generation)
      @running && @generation == generation
    end

    # Through a method, as Scheduler.spawn_loop does: the closure captures
    # the parameters (NOTES rule 21).
    def self.spawn_feed(sub, generation)
      Thread.new { run_feed_logged(sub, generation) }
    end

    # run_feed, with what ends the thread anyway (an exception that is not
    # a StandardError, from a callback or the loop itself) logged: the
    # thread then ends and the supervisor starts it again. The rescue names
    # Exception, in a method that takes no block (NOTES rules 32/45).
    # The connection the thread had open is closed before the thread ends,
    # so the restart does not leave a second subscriber on the server.
    def self.run_feed_logged(sub, generation)
      run_feed(sub, generation)
    rescue Exception => e
      Cybertrain.logger.error("WebSocket #{sub.sub_name.inspect} thread ended: #{e.class.name}: #{e.message}")
      sub.sub_drop_client
      nil
    end

    def self.run_feed(sub, generation)
      sub.sub_tick_start!(Net::Timer.now)
      attempt = 0
      while feed_live?(generation)
        failure = feed_session(sub, generation)
        # Closed and forgotten: the normal ways out of feed_session closed
        # it already (a second close does nothing); an error its rescue
        # arms caught may have left it open. A thread left from before a
        # stop! and a new start! leaves the reference alone: it may be the
        # new generation's connection.
        sub.sub_drop_client if @generation == generation
        # After a stop! the state is marked disconnected, but a thread
        # left from before a stop! and a new start! leaves it to the new
        # generation's thread.
        unless feed_live?(generation)
          sub.sub_disconnected! if @generation == generation
          break
        end
        sub.sub_disconnected!
        lasted = sub.sub_lasted(Net::Timer.now)

        attempt = 0 if lasted >= STEADY_SECONDS
        attempt += 1
        delay = retry_delay(attempt, @random_source.call)
        unless failure.empty?
          Cybertrain.logger.warn("WebSocket #{sub.sub_name.inspect} disconnected: #{failure} (retry in #{delay.round}s)")
        end
        feed_wait(sub, delay, generation)
      end
      nil
    end

    # Sleeps `seconds`, a second at a time, ending early on stop!, and
    # calls on_tick (with no connection) when it is due.
    def self.feed_wait(sub, seconds, generation)
      ends_at = Net::Timer.now + seconds
      while feed_live?(generation)
        tick_if_due(sub, nil)
        left = ends_at - Net::Timer.now
        return nil if left <= 0.0

        sleep(left < 1.0 ? left : 1.0)
      end
      nil
    end

    # Calls on_tick when it is due.
    def self.tick_if_due(sub, conn)
      now = Net::Timer.now
      return nil unless sub.sub_tick_due?(now)

      sub.sub_ticked!(now)
      run_tick(sub, conn)
      nil
    end

    # One connection, from connect to its end. Answers "" when it ended
    # without an error (stop!, silence, a failed on_open: logged where they
    # happen), else "Class: message" for the disconnect line. The rescue
    # ladder is in a method that takes no block and tells the classes apart
    # by clause, with their full names (NOTES rules 32/45/47/70).
    def self.feed_session(sub, generation)
      client = Client.connect(sub.sub_url, headers: sub.sub_headers, timeout: sub.sub_timeout,
                                           max_message: sub.sub_max_message, allow_private: sub.sub_allow_private)
      sub.sub_client!(client)
      feed_connected(sub, client, generation)
    rescue Cybertrain::WebSocket::ClosedError => e
      "Cybertrain::WebSocket::ClosedError: #{e.message}"
    rescue Cybertrain::WebSocket::TimeoutError => e
      "Cybertrain::WebSocket::TimeoutError: #{e.message}"
    rescue Cybertrain::WebSocket::RefusedError => e
      "Cybertrain::WebSocket::RefusedError: #{e.message}"
    rescue Cybertrain::WebSocket::TLSError => e
      "Cybertrain::WebSocket::TLSError: #{e.message}"
    rescue Cybertrain::WebSocket::BlockedAddressError => e
      "Cybertrain::WebSocket::BlockedAddressError: #{e.message}"
    rescue Cybertrain::WebSocket::HandshakeError => e
      "Cybertrain::WebSocket::HandshakeError: #{e.message}"
    rescue Cybertrain::WebSocket::ProtocolError => e
      "Cybertrain::WebSocket::ProtocolError: #{e.message}"
    rescue Cybertrain::WebSocket::TooLargeError => e
      "Cybertrain::WebSocket::TooLargeError: #{e.message}"
    rescue StandardError => e
      "#{e.class.name}: #{e.message}"
    end

    # Steps 1 to 4 on an open connection.
    def self.feed_connected(sub, client, generation)
      name = sub.sub_name
      unless feed_live?(generation)
        client.ws_close_within(STOP_CLOSE_SECONDS)
        return ""
      end
      Cybertrain.logger.info("WebSocket #{name.inspect} connected to #{client.ws_label}")
      sub.sub_connected!(Net::Timer.now)
      conn = Connection.new(client)
      unless run_open(sub, conn)
        client.close
        return ""
      end

      ping_every = sub.sub_ping_interval.to_f
      stale = sub.sub_stale_after.to_f
      pinged_at = client.last_activity_at
      pongs = client.ws_pongs
      while feed_live?(generation)
        msg = client.receive(1)
        unless msg.nil?
          conn.conn_opcode!(msg.ws_opcode)
          sub.sub_message!(Time.now.to_i)
          run_message(sub, conn, msg.ws_data)
        end
        if client.ws_pongs != pongs
          pongs = client.ws_pongs
          sub.sub_activity!(Time.now.to_i)
        end
        tick_if_due(sub, conn)
        now = Net::Timer.now
        activity = client.last_activity_at
        if now - activity >= stale
          Cybertrain.logger.warn("WebSocket #{name.inspect} silent for #{sub.sub_stale_after}s; reconnecting")
          client.close
          return ""
        end
        quiet_since = activity > pinged_at ? activity : pinged_at
        if now - quiet_since >= ping_every
          client.send_ping
          pinged_at = now
        end
      end
      client.ws_close_within(STOP_CLOSE_SECONDS)
      ""
    end

    # Calls on_open; false (logged) when it raised. Reads the Proc from the
    # Subscription rather than yielding (NOTES rules 32/45/69).
    def self.run_open(sub, conn)
      block = sub.sub_open_block
      block.call(conn) unless block.nil?
      true
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("WebSocket #{sub.sub_name.inspect} on_open failed: #{e.class.name}: #{e.message}")
      false
    end

    # Calls on_message; false (logged) when it raised. The connection stays.
    def self.run_message(sub, conn, data)
      block = sub.sub_message_block
      block.call(conn, data) unless block.nil?
      true
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("WebSocket #{sub.sub_name.inspect} on_message failed: #{e.class.name}: #{e.message}")
      false
    end

    # Calls on_tick; false (logged) when it raised a StandardError. `conn`
    # is nil while the feed is disconnected. Anything else ends the feed's
    # thread, which the supervisor starts again.
    def self.run_tick(sub, conn)
      block = sub.sub_tick_block
      block.call(conn) unless block.nil?
      true
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("WebSocket #{sub.sub_name.inspect} on_tick failed: #{e.class.name}: #{e.message}")
      false
    end

    # Starts and stops the feeds from Application#serve
    # (cybertrain/background.rb).
    class WebSocketService < Background::Service
      def service_name
        "websocket"
      end

      def service_start(config)
        WebSocket.start!(config)
      end

      def service_start_only(config, names)
        WebSocket.start!(config, only: names)
      end

      def service_feed_names
        WebSocket.feed_names
      end

      def service_stop
        WebSocket.stop!
      end

      def service_problem
        WebSocket.subscriptions_problem
      end

      def service_dead_feeds
        WebSocket.dead_feeds
      end

      def service_feed_restarts(name)
        WebSocket.feed_status(name).restarts
      end

      def service_restart_feed(name)
        WebSocket.restart_feed(name)
      end

      def service_publish_status(now)
        WebSocket.publish_status(now)
      end

      def service_withdraw_status
        WebSocket.withdraw_status
      end
    end
  end
end

Cybertrain::Background.register(Cybertrain::WebSocket::WebSocketService.new)
