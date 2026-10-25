module Cybertrain
  # The counter behind one {Controller.rate_limit} declaration: how many
  # requests each key (a client address, prefixed with the controller's
  # path) has made in its current window, in this process.
  #
  # A fixed window per key: the first request opens it, the `to`-th is the
  # last one let through, and the window closes `within` seconds after it
  # opened, when the next request opens a fresh one. Counting happens under
  # one Mutex, before the action runs; only the actions the declaration
  # names take it (NOTES rule 57: a lock on every request stalls under
  # several workers, so keep `only:` narrow).
  #
  # Memory is bounded: at most {#max_keys} keys (10 000 by default). The
  # keys are kept in the order their windows opened (a key whose window
  # reopens is moved to the end), so when a new key finds the table full the
  # expired windows are at its front; they go first, then the oldest open
  # ones, a tenth of the table at a time. A flood of addresses can therefore
  # end a client's window early (it starts again from zero), never grow the
  # process.
  #
  # The counts are per process and lost on restart: with several processes
  # each counts on its own. A later version may keep them in the database.
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

    def initialize(limit_count, period_seconds, by_remote_addr, redirect_path, alert_message)
      @limit_count = limit_count
      @period_seconds = period_seconds
      @by_remote_addr = by_remote_addr
      @redirect_path = redirect_path
      @alert_message = alert_message
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

    # Forgets every count of every limiter. The generated
    # `AppTest.sign_in` calls it, so that a test suite that signs in in
    # every test never reaches the sign-in limit.
    # @return [nil]
    # @api public
    def self.reset_all!
      i = 0
      while i < ALL.length
        ALL[i].reset!
        i += 1
      end
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
