# cybertrain/rate_limit: Controller.rate_limit, an optional subsystem
# (require "cybertrain/rate_limit" in bin/NAME.rb, or require "cybertrain";
# docs/superpowers/specs/2026-11-13-optional-subsystems-design.md). It
# counts through the cache (cybertrain/cache), so sign-in throttling across
# processes is the same whichever lines an application has.
#
# This file defines RateLimit, reopens Controller for `rate_limit` and the
# check its callbacks run, and registers RateLimitFeature at its end: the
# core's Controller#run_one hands a rate_limit callback to
# Feature#run_controller_limit and never names RateLimit. It loads the
# controller and the cache, not the whole core (bin/NAME.rb requires
# cybertrain/core). Requiring it twice is a no-op.
require "cybertrain/cache"
require "cybertrain/db"
require "cybertrain/feature"
require "cybertrain/callback"
require "cybertrain/controller"

module Cybertrain
  # One {Controller.rate_limit} declaration: its options, and the counter
  # of `store: :memory`.
  #
  # Counts are shared through the cache by default (`store: :cache`): each
  # request adds one to a {Cache} row (Cache.increment, in the
  # application's SQLite database), so every process and thread serving
  # the application counts together, and the counts survive a restart.
  # The windows are fixed and aligned to the epoch: the row's key is
  # `"rate-limit:<controller_path>:<name>:<key>:<now / within>"`, `key`
  # being the client's address or the value of the `by:` method, and
  # `now` {Cache.now}; the `to`-th request of a window is the last one let
  # through, and an exhausted client's `Retry-After` is the rest of the
  # window, `within - now % within` (plan decision 17). Only the part
  # after the name can come from a client, and a name holds no `:`, so a
  # client cannot pick a key that counts against another limit or
  # controller.
  #
  # The `rate-limit:` prefix of the cache's keys is the framework's: an
  # application's own {Cache} keys must not start with it.
  #
  # Each client opens one row per window, which expires at the window's
  # end; nothing deletes it then but the cache's prune: with
  # cybertrain/jobs the scheduled `"cybertrain cache prune"` task
  # ({Cache.prune}, every {Config#cache_prune_interval} seconds), without
  # it the counting writes themselves ({Cache.prune_if_due}: once per
  # interval, at most 1000 expired rows per write). Between two prunes the
  # table grows by one row per client and window, so a flood of addresses
  # costs disk until the next prune, never memory.
  #
  # `store: :memory` keeps the counts in this object instead, per process
  # and lost on restart (several processes each count on their own), with
  # a window per key that the key's first request opens and that closes
  # `within` seconds later. Counting happens under one Mutex, before the
  # action runs; only the actions the declaration names take it (NOTES
  # rule 57: a lock on every request stalls under several workers, so keep
  # `only:` narrow). Its memory is bounded: at most {#max_keys} keys
  # (10 000 by default). The keys are kept in the order their windows
  # opened (a key whose window reopens is moved to the end), so when a new
  # key finds the table full the expired windows are at its front; they
  # go first, then the oldest open ones, a tenth of the table at a time. A
  # flood of addresses can therefore end a client's window early (it
  # starts again from zero), never grow the process.
  # @api public
  class RateLimit
    # The most keys one limiter keeps.
    # @api public
    MAX_KEYS = 10_000

    # The body of the default answer, a 429.
    # @api public
    BODY = "Too Many Requests"

    # @return [Integer] requests allowed per window (`to:`)
    # @api public
    attr_reader :limit_count

    # @return [Integer] the window, in seconds (`within:`)
    # @api public
    attr_reader :period_seconds

    # @return [String] where an exhausted client is redirected (`""`: a
    #   429 instead)
    # @api public
    attr_reader :redirect_path

    # @return [String] the flash alert set before that redirect (`""`: none)
    # @api public
    attr_reader :alert_message

    # @return [Integer] the most keys kept before eviction
    # @api public
    attr_reader :max_keys

    # @return [Symbol, nil] the controller method whose value keys the
    #   count (`by: :user_key`); nil to count by the client's address
    # @api public
    attr_reader :by_method

    # @return [Symbol, nil] the controller method that answers an
    #   exhausted client (`with:`); nil for the 429 or the redirect
    # @api public
    attr_reader :with_method

    # @return [Symbol, nil] the controller method that must answer true
    #   for the limit to apply (`if:`); nil when there is none
    # @api public
    attr_reader :if_method

    # @return [Symbol, nil] the controller method that, answering true,
    #   lifts the limit (`unless:`); nil when there is none
    # @api public
    attr_reader :unless_method

    # @return [String] the declaration's `name:` (`""` by default), part
    #   of the cache key
    # @api public
    attr_reader :limit_name

    # The positional form a test uses builds a `store: :memory` counter;
    # {Controller.rate_limit} passes every option.
    def initialize(limit_count, period_seconds, by_remote_addr, redirect_path, alert_message,
                   by_method = nil, with_method = nil, if_method = nil, unless_method = nil,
                   limit_name = "", memory_store = true)
      @limit_count = limit_count
      @period_seconds = period_seconds
      @by_remote_addr = by_remote_addr
      @redirect_path = redirect_path
      @alert_message = alert_message
      @by_method = by_method
      @with_method = with_method
      @if_method = if_method
      @unless_method = unless_method
      @limit_name = limit_name
      @memory_store = memory_store
      @max_keys = MAX_KEYS
      # Window start (epoch seconds) and requests so far, by key: typed,
      # seeded empty Hashes (spikes/NOTES.md rule 9).
      @starts = { "" => 0 }
      @starts.delete("")
      @counts = { "" => 0 }
      @counts.delete("")
      @lock = Mutex.new
    end

    # @return [Boolean] true for `by: :remote_addr`, false for the default
    #   `by: :client_ip`
    # @api public
    def by_remote_addr?
      @by_remote_addr
    end

    # @return [Boolean] true for `store: :memory` (this object counts),
    #   false for the default `store: :cache`
    # @api public
    def memory_store?
      @memory_store
    end

    # Changes the table's bound (a test lowers it to see eviction).
    # @param n [Integer] at least 1
    # @return [nil]
    # @api public
    def max_keys=(n)
      @max_keys = n < 1 ? 1 : n
      nil
    end

    # Counts one request for `key` at `now` (epoch seconds) and answers 0
    # when it is allowed, or else the seconds until the key's window closes
    # (at least 1: the Retry-After value).
    # @param key [String]
    # @param now [Integer]
    # @return [Integer]
    # @api public
    def hit(key, now)
      wait = 0
      @lock.synchronize do
        wait = count_hit(key, now)
      end
      wait
    end

    # @return [Integer] how many keys the table holds now
    # @api public
    def tracked_keys
      held = 0
      @lock.synchronize { held = @starts.length }
      held
    end

    # @param key [String]
    # @return [Boolean] whether the table holds `key`
    # @api public
    def tracked?(key)
      held = false
      @lock.synchronize { held = @starts.key?(key) }
      held
    end

    # Forgets every count.
    # @return [nil]
    # @api public
    def reset!
      @lock.synchronize do
        @starts.clear
        @counts.clear
      end
      nil
    end

    # Under the lock.
    def count_hit(key, now)
      if @starts.key?(key)
        start = @starts[key]
        # A window that starts after now (a test travelled back) is over,
        # as one whose period has run out: counting into it would answer a
        # Retry-After up to the distance travelled.
        if now >= start && now - start < @period_seconds
          seen = @counts[key] + 1
          @counts[key] = seen
          return 0 if seen <= @limit_count

          wait = start + @period_seconds - now
          return wait < 1 ? 1 : wait
        end
        # The window is over: delete and insert again, so the key moves to
        # the end and the table stays ordered by window start.
        @starts.delete(key)
        @counts.delete(key)
      end
      make_room(now) if @starts.length >= @max_keys
      @starts[key] = now
      @counts[key] = 1
      0
    end

    # Under the lock, with the table full: drops the expired windows at the
    # front (a window that starts after now counts as expired, as in
    # count_hit), then the oldest open ones until a tenth of the table (at
    # least one key) is free. keys is a copy of every key, made only when the
    # table is full and then for a tenth of its size in inserts.
    def make_room(now)
      target = @max_keys - (@max_keys / 10 < 1 ? 1 : @max_keys / 10)
      keys = @starts.keys
      i = 0
      while i < keys.length
        k = keys[i]
        start = @starts[k]
        expired = now < start || now - start >= @period_seconds
        break unless expired || @starts.length > target

        @starts.delete(k)
        @counts.delete(k)
        i += 1
      end
      nil
    end

    # Every limiter declared in this program, in declaration order; a
    # Callback refers to its own by index. A constant, so the limiters are
    # GC roots (NOTES rule 64), seeded with the element type (rule 9).
    ALL = Array.new(0) { RateLimit.new(1, 1, false, "", "") }

    # Adds a limiter and returns its index in {.all}.
    def self.register(limit)
      ALL << limit
      ALL.length - 1
    end

    # @return [Array<RateLimit>] every declared limiter, in declaration
    #   order (to reach one from a test)
    # @api public
    def self.all
      ALL
    end

    # Forgets every count of every limiter: the `store: :memory` tables,
    # and, when a limiter counts in the cache, the cache's rate-limit rows.
    # `cybertrain/test_help` calls it before every test, so that a test
    # suite that signs in in every test never reaches the sign-in limit.
    # @return [nil]
    # @raise [Cybertrain::DB::Error] when a limiter counts in the cache and
    #   the database is not reachable
    # @api public
    def self.reset_all!
      shared = false
      i = 0
      while i < ALL.length
        limit = ALL[i]
        limit.reset!
        shared = true unless limit.memory_store?
        i += 1
      end
      clear_shared_counts if shared
      nil
    end

    # Deletes the cache's rate-limit rows: the keys from "rate-limit:" up
    # to "rate-limit;" (";" follows ":"), so no LIKE pattern is needed.
    def self.clear_shared_counts
      Cache.install!
      DB.with { |c| c.execute("DELETE FROM cybertrain_cache WHERE key >= 'rate-limit:' AND key < 'rate-limit;'") }
      nil
    end

    # The time the `store: :memory` limiters count with, in epoch seconds:
    # {Clock.now}, so a test moves a window with `travel_to` / `travel`.
    # The cache store counts with {Cache.now}, which reads the same clock.
    # @return [Integer]
    # @api public
    def self.current_time
      Clock.now.to_i
    end
  end

  # Defined here, on the core's Controller, by cybertrain/rate_limit.
  class Controller
    # Limits how often one client may call some actions: at most `to`
    # requests per `within` seconds for each client, counted before the
    # action runs (a before callback, in declaration order with the
    # others). An exhausted client gets a 429 with the body "Too Many
    # Requests" and a `Retry-After` header (the seconds until its window
    # closes), or, with `redirect_to:`, a 303 to that path with `alert:` in
    # the flash, or what the `with:` method answers. The action does not
    # run.
    #
    # The counts are shared through the cache (`store: :cache`, the
    # default; see {RateLimit}): every process of the application counts
    # together, in fixed windows aligned to the epoch. `store: :memory`
    # keeps them in this process instead.
    #
    # A count is kept per declaration (its `name:`), per controller (a
    # limit declared in a parent counts each subclass apart, as Rails'
    # does) and per client: {Request#client_ip} by default, so behind a
    # proxy on the same host set Config#trusted_proxy, or every visitor
    # shares the proxy's address; `by: :remote_addr` counts the
    # connection's peer whatever the configuration; `by: :user_key` the
    # String the controller's `user_key` method answers (an empty one
    # raises ArgumentError rather than count every client in one bucket).
    # `if: :m` applies the limit only when the method m answers true,
    # `unless: :m` only when it answers false; a request it does not apply
    # to is not counted. The methods named by `by:`, `with:`, `if:` and
    # `unless:` are called through the tables `spin run gen` writes
    # ({#rate_limit_key}, {#rate_limit_condition?}, {#run_callback}).
    #
    # Differences from Rails: `within:` is a number of seconds (`3 * 60`;
    # there is no `3.minutes`), `only:`/`except:` take Arrays, `by:`,
    # `with:`, `if:` and `unless:` take a method's name rather than a
    # block, `store:` is `:cache` or `:memory` rather than a cache store,
    # and each limit of a controller (its parents' included) needs its own
    # `name:`.
    # @example
    #   class SessionsController < ApplicationController
    #     rate_limit to: 10, within: 3 * 60, only: [:create],
    #                redirect_to: "/session/new", alert: "Try again later."
    #   end
    #   rate_limit to: 100, within: 60, only: [:create, :update]   # a 429 with Retry-After
    #   rate_limit to: 5, within: 60, by: :account_key, with: :slow_down, name: "account"
    # @param to [Integer] requests allowed per window, at least 1
    # @param within [Integer] the window, in seconds, at least 1
    # @param only [Array<Symbol>] limit these actions only
    # @param except [Array<Symbol>] limit every action but these
    # @param by [Symbol] `:client_ip` (the default), `:remote_addr`, or the
    #   name of a controller method answering the key
    # @param with [Symbol, nil] a controller method that answers an
    #   exhausted client instead (when it renders nothing, the 429 follows)
    # @param if [Symbol, nil] a controller method; the limit applies only
    #   when it answers true
    # @param unless [Symbol, nil] a controller method; the limit applies
    #   only when it answers false
    # @param name [String] tells the limits of one controller apart (`""`
    #   by default); no `:`
    # @param store [Symbol] `:cache` (the default) or `:memory`
    # @param redirect_to [String] a path to redirect an exhausted client to
    #   (`""`, the default: answer 429 instead)
    # @param alert [String] `flash[:alert]` for that redirect (`""`: none)
    # @return [nil]
    # @raise [ArgumentError] for a `to` or `within` below 1, another
    #   `store:`, a `name:` with a `:` or one another limit of the
    #   controller has
    # @api public
    def self.rate_limit(to:, within:, only: [], except: [], by: :client_ip, with: nil, if: nil, unless: nil, name: "",
                        store: :cache, redirect_to: "", alert: "")
      raise ArgumentError, "rate_limit needs to: of at least 1 (got #{to})" if to < 1
      raise ArgumentError, "rate_limit needs within: of at least 1 second (got #{within})" if within < 1

      memory_store = false
      case store
      when :cache then memory_store = false
      when :memory then memory_store = true
      else
        msg = "rate_limit store: must be :cache or :memory (got #{store.inspect})"
        raise ArgumentError, msg
      end
      if name.include?(":")
        msg = "rate_limit name: may not contain \":\" (got #{name.inspect})"
        raise ArgumentError, msg
      end
      if rate_limit_named?(self, name)
        msg = "rate_limit name: #{name.inspect} is already taken in #{self.name}; give each limit of a controller its own name:"
        raise ArgumentError, msg
      end
      by_remote_addr = false
      by_method = nil
      case by
      when :client_ip then by_remote_addr = false
      when :remote_addr then by_remote_addr = true
      else by_method = by
      end
      # `if` and `unless` are keywords: their values are read by name.
      if_method = binding.local_variable_get(:if)
      unless_method = binding.local_variable_get(:unless)
      limit = RateLimit.new(to, within, by_remote_addr, redirect_to, alert, by_method, with, if_method, unless_method,
                            name, memory_store)
      id = RateLimit.register(limit)
      add_callback(Callback.new(:before, nil, nil, only, except, id))
    end

    # Whether a rate_limit of klass or of its parents has this name. The
    # class is passed in, as to chain_for.
    # @api private
    def self.rate_limit_named?(klass, name)
      chain = chain_for(klass)
      i = 0
      while i < chain.size
        id = chain[i].limit_id
        return true if id >= 0 && RateLimit.all[id].limit_name == name

        i += 1
      end
      false
    end

    # One rate_limit check: skipped when its `if:` method answers false or
    # its `unless:` method true; else counts this request and, when the
    # client is over the limit, answers for the action (the `with:`
    # method's answer, a 429 with Retry-After, or the declaration's
    # redirect), which halts the chain. The key carries the controller's
    # path, so a limit inherited from a parent counts each controller
    # apart, and the declaration's name, so two limits of one controller
    # count apart (plan decision 17). Public: RateLimitFeature calls it.
    # @api private
    def apply_rate_limit(limit)
      condition = limit.if_method
      return nil if !condition.nil? && !rate_limit_condition?(condition)

      condition = limit.unless_method
      return nil if !condition.nil? && rate_limit_condition?(condition)

      key = ""
      by_method = limit.by_method
      if by_method.nil?
        key = limit.by_remote_addr? ? @request.remote_addr : @request.client_ip
      else
        key = rate_limit_key(by_method)
        if key.empty?
          msg = "rate_limit by: :#{by_method} answered an empty key in #{self.class.name}, which would count every client together"
          raise ArgumentError, msg
        end
      end
      scope = "#{controller_path}:#{limit.limit_name}:#{key}"
      wait = 0
      if limit.memory_store?
        wait = limit.hit(scope, RateLimit.current_time)
      else
        now = Cache.now
        within = limit.period_seconds
        count = Cache.increment("rate-limit:#{scope}:#{now / within}", expires_in: within)
        wait = within - now % within if count > limit.limit_count
      end
      return nil if wait == 0

      with = limit.with_method
      unless with.nil?
        run_callback(with)
        return nil if performed?
      end
      path = limit.redirect_path
      if path.empty?
        r = @response
        r.status = 429
        r.content_type = "text/plain; charset=utf-8"
        r.set_header("Retry-After", wait.to_s)
        r.body = RateLimit::BODY
        r.performed!
      else
        message = limit.alert_message
        messages = flash
        messages[:alert] = message unless message.empty? || messages.nil?
        @response.redirect(path, 303)
      end
      nil
    end
  end

  # What rate limiting adds to the core, through Feature's hooks: the
  # check of a rate_limit callback (Controller#run_one).
  # @api private
  class RateLimitFeature < Feature
    def feature_name
      "rate_limit"
    end

    def feature_rank
      50
    end

    def run_controller_limit(controller, limit_id)
      controller.apply_rate_limit(RateLimit.all[limit_id])
      nil
    end
  end
end

Cybertrain::Features.register_feature(Cybertrain::RateLimitFeature.new)
