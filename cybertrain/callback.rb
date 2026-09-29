module Cybertrain
  # One before_action/after_action declaration. Symbol callbacks (name) are
  # dispatched through the controller's generated run_callback(name) case
  # table; block callbacks receive the controller as their argument, because
  # Spinel cannot instance_exec a stored block.
  class Callback
    attr_reader :kind, :name, :block

    def initialize(kind, name, block, only, except)
      @kind = kind
      @name = name
      @block = block
      @only = only
      @except = except
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
