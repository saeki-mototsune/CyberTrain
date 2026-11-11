require "cybertrain/cache"
require "cybertrain/db"

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
        if now - start < @period_seconds
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
    # front, then the oldest open ones until a tenth of the table (at least
    # one key) is free. keys is a copy of every key, made only when the
    # table is full and then for a tenth of its size in inserts.
    def make_room(now)
      target = @max_keys - (@max_keys / 10 < 1 ? 1 : @max_keys / 10)
      keys = @starts.keys
      i = 0
      while i < keys.length
        k = keys[i]
        expired = now - @starts[k] >= @period_seconds
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
    # The generated `AppTest.sign_in` calls it, so that a test suite that
    # signs in in every test never reaches the sign-in limit.
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

    # -1 while the system clock is used; see {.current_time=}.
    @fixed_time = -1

    # The time the limiters count with, in epoch seconds: the system clock,
    # unless a test fixed it.
    # @return [Integer]
    # @api public
    def self.current_time
      fixed = @fixed_time
      fixed < 0 ? Time.now.to_i : fixed
    end

    # Fixes the time the limiters see, for a test that needs a window to
    # pass; -1 goes back to the system clock.
    # @param seconds [Integer] epoch seconds, or -1
    # @return [nil]
    # @api public
    def self.current_time=(seconds)
      @fixed_time = seconds
      nil
    end
  end
end
