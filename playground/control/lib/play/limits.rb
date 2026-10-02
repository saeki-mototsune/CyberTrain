# frozen_string_literal: true

require "ipaddr"

module Play
  # Per-client limits (spec §5.6): the client key of a request, and the
  # sliding window of successful creations per key.
  class Limits
    # The client of a Rack request: the address in HEADER_KEY (the Rack env
    # key of PLAY_CLIENT_IP_HEADER, such as HTTP_CF_CONNECTING_IP) when it
    # holds one, else REMOTE_ADDR. IPv4 counts per address, IPv6 per /64.
    def self.client_key(env, header_key)
      (header_key && key_for(env[header_key])) || key_for(env["REMOTE_ADDR"]) || "unknown"
    end

    def self.key_for(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A[0-9A-Fa-f:.]+\z/)

      ip = IPAddr.new(text)
      ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
      ip.ipv4? ? ip.to_s : "#{ip.mask(64)}/64"
    rescue IPAddr::Error
      nil
    end

    def initialize(limit:, window:, clock:)
      @limit = limit
      @window = window
      @clock = clock
      @hits = {}
      @mutex = Mutex.new
    end

    # Seconds until KEY may create again: 0 when it may now. The wait lasts
    # until enough hits have left the window for the count to drop below the
    # limit; creations that passed this check together can leave more hits
    # than the limit.
    def retry_after(key)
      @mutex.synchronize do
        hits = fresh(key)
        hits.size < @limit ? 0 : [(hits[hits.size - @limit] + @window - @clock.monotonic).ceil, 1].max
      end
    end

    # Counts one successful creation for KEY.
    def record(key)
      @mutex.synchronize do
        @hits[key] = fresh(key) << @clock.monotonic
        sweep if @hits.size > 1000
      end
    end

    private

    def fresh(key)
      now = @clock.monotonic
      hits = (@hits[key] || []).select { |t| now - t < @window }
      hits.empty? ? @hits.delete(key) : @hits[key] = hits
      hits
    end

    def sweep
      now = @clock.monotonic
      @hits.delete_if { |_, hits| now - hits.last >= @window }
    end
  end
end
