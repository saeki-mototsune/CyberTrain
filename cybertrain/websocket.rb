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
#    60 s), looking at stop! every second, then goes back to 1.
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
require "cybertrain/http_client"
require "cybertrain/websocket/frame"
require "cybertrain/websocket/client"

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
      def initialize(connected, last_message_at, reconnects)
        @connected = connected
        @last_message_at = last_message_at
        @reconnects = reconnects
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
    end

    # One registered feed, from {WebSocket.subscribe}. Distinctive accessor
    # names and no #call (NOTES rules 10/34/40).
    # @api public
    class Subscription
      attr_reader :sub_url, :sub_target, :sub_headers, :sub_timeout, :sub_max_message,
                  :sub_ping_interval, :sub_stale_after, :sub_allow_private,
                  :sub_open_block, :sub_message_block, :sub_thread

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
        # Guarded by WebSocket::LOCK: the feed thread writes them, a request
        # thread reads them through WebSocket.feed_status.
        @connected = false
        @last_message_at = 0
        @reconnects = 0
        @sessions = 0
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

      def sub_thread!(thread)
        @sub_thread = thread
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
        LOCK.synchronize { @last_message_at = epoch }
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
    # @raise [ArgumentError] an empty or taken name, a URL that is not ws://
    #   or wss://, a header the client refuses, a bad interval
    # @api public
    def self.subscribe(name, url, headers: Client::NO_HEADERS, timeout: 5, max_message: 1_048_576,
                       ping_interval: 15, stale_after: 45,
                       allow_private: Cybertrain.config.http_allow_private)
      label = name.to_s
      raise ArgumentError, "WebSocket.subscribe: the name is empty" if label.empty?
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
      Status.new(sub.sub_connected?, sub.sub_last_message_at, sub.sub_reconnects)
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

    # Starts one thread per subscription, unless {Config#worker} is off,
    # nothing is subscribed or the feeds already run. Application#serve
    # calls it (through the Background service).
    # @param config [Config]
    # @return [Boolean] true when it started the threads
    # @raise [ArgumentError] when a subscription has no on_message
    # @api public
    def self.start!(config = Cybertrain.config)
      return false if @running
      unless config.worker
        Cybertrain.logger.info("Background worker off (CYBERTRAIN_WORKER=0): WebSocket subscriptions run elsewhere")
        return false
      end
      return false if SUBSCRIPTIONS.empty?

      problem = subscriptions_problem
      raise ArgumentError, "WebSocket.start!: #{problem}" unless problem.empty?

      # spikes/NOTES.md rule 22: before the first Thread.new.
      ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
      @running = true
      @generation += 1
      generation = @generation
      i = 0
      while i < SUBSCRIPTIONS.size
        sub = SUBSCRIPTIONS[i]
        Cybertrain.logger.info("WebSocket started: #{sub.sub_name} (#{sub.sub_origin})")
        sub.sub_thread!(spawn_feed(sub, generation))
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
        thread.join(left) if !thread.nil? && left > 0.0
        i += 1
      end
      i = 0
      while i < SUBSCRIPTIONS.size
        SUBSCRIPTIONS[i].sub_disconnected!
        i += 1
      end
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
      Thread.new { run_feed(sub, generation) }
    end

    def self.run_feed(sub, generation)
      attempt = 0
      while feed_live?(generation)
        failure = feed_session(sub, generation)
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
        feed_wait(delay, generation)
      end
      nil
    end

    # Sleeps `seconds`, a second at a time, ending early on stop!.
    def self.feed_wait(seconds, generation)
      ends_at = Net::Timer.now + seconds
      while feed_live?(generation)
        left = ends_at - Net::Timer.now
        return nil if left <= 0.0

        sleep(left < 1.0 ? left : 1.0)
      end
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
      while feed_live?(generation)
        msg = client.receive(1)
        unless msg.nil?
          conn.conn_opcode!(msg.ws_opcode)
          sub.sub_message!(Time.now.to_i)
          run_message(sub, conn, msg.ws_data)
        end
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

    # Starts and stops the feeds from Application#serve
    # (cybertrain/background.rb).
    class WebSocketService < Background::Service
      def service_name
        "websocket"
      end

      def service_start(config)
        WebSocket.start!(config)
      end

      def service_stop
        WebSocket.stop!
      end

      def service_problem
        WebSocket.subscriptions_problem
      end
    end
  end
end

Cybertrain::Background.register(Cybertrain::WebSocket::WebSocketService.new)
