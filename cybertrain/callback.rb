module Cybertrain
  # One before_action/after_action declaration. Symbol callbacks (name) are
  # dispatched through the controller's generated run_callback(name) case
  # table; block callbacks receive the controller as their argument, because
  # Spinel cannot instance_exec a stored block. A rate_limit declaration is a
  # before callback with neither: limit_id is its index in RateLimit.all
  # (-1 for every other callback), and Controller#run_one calls the
  # controller's own method for it rather than a stored block (a call from a
  # stored block does not type its callee, NOTES rule 30).
  class Callback
    attr_reader :kind, :name, :block, :limit_id

    def initialize(kind, name, block, only, except, limit_id = -1)
      @kind = kind
      @name = name
      @block = block
      @only = only
      @except = except
      @limit_id = limit_id
    end

    def applies?(action)
      return false if !@only.empty? && !@only.include?(action)

      !@except.include?(action)
    end
  end

  # One rescue_from declaration. The exception class is kept by name and
  # matched exactly against e.class.name.
  class RescueHandler
    attr_reader :class_name, :with, :block

    def initialize(class_name, with, block)
      @class_name = class_name
      @with = with
      @block = block
    end
  end
end
