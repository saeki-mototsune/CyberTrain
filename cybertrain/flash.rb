require "json"

module Cybertrain
  # Rails-style flash: values set with []= are queued for the NEXT request
  # (SessionStore persists them into the session, then the following
  # request's SessionStore loads them back as "current"); flash.now writes
  # straight into the current values, visible only for this request.
  #
  # {Controller#flash} in an action, `flash` in a template. Keys and values
  # are Strings. A message shows on exactly the next request that is not a
  # static file, then is gone.
  #
  # Unlike Rails, `flash[:notice]` reads only the messages that arrived with
  # this request: a value set with `flash[:notice] = ...` is not readable
  # until the next one. There is no `keep` or `discard`.
  # @example Before a redirect
  #   flash[:notice] = "Article was successfully created."
  #   redirect_to article_path(@article), status: :see_other
  # @example On the page being rendered now
  #   flash.now[:alert] = "Could not save."
  #   render :new, status: :unprocessable_entity
  # @example In the layout
  #   <% if flash[:notice] %><p class="notice"><%= flash[:notice] %></p><% end %>
  # @api public
  class Flash
    def initialize
      @current = {}
      @current_order = []
      @queued = {}
      @queued_order = []
    end

    # A message that arrived with this request (or was set with {#now}).
    # @param key [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](key)
      @current[key.to_s]
    end

    # Queues a message for the next request.
    # @param key [String, Symbol]
    # @param value [Object] stored as `value.to_s`
    # @api public
    def []=(key, value)
      k = key.to_s
      @queued_order << k unless @queued.key?(k)
      @queued[k] = value.to_s
    end

    # The messages for this request: `flash.now[:alert] = "..."`
    # shows on the page rendered now and is not kept.
    # @return [FlashNow]
    # @api public
    def now
      FlashNow.new(self)
    end

    # @return [Array<String>] the keys of this request's messages, in order
    # @api public
    def keys
      @current_order.dup
    end

    # @return [Boolean] true when this request has no messages
    # @api public
    def empty?
      @current_order.empty?
    end

    # Yields this request's messages in order.
    # @yieldparam key [String]
    # @yieldparam message [String]
    # @api public
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

  # What {Flash#now} returns: writes go to the current request only.
  # @api public
  class FlashNow
    def initialize(flash)
      @flash = flash
    end

    # @param key [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](key)
      @flash[key]
    end

    # @param key [String, Symbol]
    # @param value [Object] stored as `value.to_s`
    # @api public
    def []=(key, value)
      @flash.set_now(key, value)
    end
  end
end
