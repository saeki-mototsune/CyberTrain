require "json"

module Cybertrain
  # Rails-style flash: values set with []= are queued for the NEXT request
  # (SessionStore persists them into the session, then the following
  # request's SessionStore loads them back as "current"); flash.now writes
  # straight into the current values, visible only for this request.
  class Flash
    def initialize
      @current = {}
      @current_order = []
      @queued = {}
      @queued_order = []
    end

    def [](key)
      @current[key.to_s]
    end

    def []=(key, value)
      k = key.to_s
      @queued_order << k unless @queued.key?(k)
      @queued[k] = value.to_s
    end

    def now
      FlashNow.new(self)
    end

    def keys
      @current_order.dup
    end

    def empty?
      @current_order.empty?
    end

    def each
      @current_order.each { |k| yield(k, @current[k]) }
    end

    # Writes straight into the *current* values, bypassing the next-request
    # queue -- used by FlashNow and by .load to seed this request's values
    # from the previous request's queue.
    def set_now(key, value)
      k = key.to_s
      @current_order << k unless @current.key?(k)
      @current[k] = value.to_s
    end

    def queued_keys
      @queued_order
    end

    def queued_value(key)
      @queued[key]
    end

    def self.load(session)
      flash = Flash.new
      raw = session.flash_payload
      unless raw.nil?
        begin
          parsed = JSON.parse(raw)
          case parsed
          when Hash
            parsed.each { |k, v| flash.set_now(k.to_s, v.to_s) }
          end
        rescue JSON::ParserError, StandardError
        end
        session.clear_flash!
      end
      flash
    end

    def self.store(flash, session)
      return if flash.queued_keys.empty?

      h = {}
      flash.queued_keys.each { |k| h[k] = flash.queued_value(k) }
      session.flash_payload = JSON.generate(h)
    end
  end

  class FlashNow
    def initialize(flash)
      @flash = flash
    end

    def [](key)
      @flash[key]
    end

    def []=(key, value)
      @flash.set_now(key, value)
    end
  end
end
