require "cybertrain/context"

module Cybertrain
  # Base class for every middleware and for the Router at the end of the
  # chain. Subclasses override #call(ctx) and usually finish by calling
  # super (or @app.call(ctx)) to continue the chain. The chain is typed by
  # this base class so Spinel can resolve #call statically.
  class Middleware
    attr_accessor :app

    def initialize(app = nil)
      @app = app
    end

    def call(ctx)
      nxt = @app
      nxt.call(ctx) unless nxt.nil?
      nil
    end
  end
end
