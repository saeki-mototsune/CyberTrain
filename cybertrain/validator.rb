module Cybertrain
  # One `validates` rule, kept as data: Spinel cannot define validation
  # methods at runtime, so Model#valid? walks these instead.
  class Validator
    # kind is :presence or :length; minimum/maximum are -1 when unset.
    attr_reader :attr, :kind, :minimum, :maximum, :allow_blank

    def initialize(attr, kind, minimum = -1, maximum = -1, allow_blank = false)
      @attr = attr
      @kind = kind
      @minimum = minimum
      @maximum = maximum
      @allow_blank = allow_blank
    end

    def validate(record)
      value = record.read_attribute(@attr)
      blank = Validator.blank?(value)
      return nil if blank && @allow_blank

      case @kind
      when :presence
        record.errors.add(@attr, "can't be blank") if blank
      when :length
        # nil is left to a presence rule, as `length` alone allows it.
        return nil if value.nil?
        size = Validator.length_of(value)
        if @minimum >= 0 && size < @minimum
          record.errors.add(@attr, "is too short (minimum is #{@minimum} characters)")
        elsif @maximum >= 0 && size > @maximum
          record.errors.add(@attr, "is too long (maximum is #{@maximum} characters)")
        end
      end
      nil
    end

    def self.blank?(value)
      case value
      when nil then true
      when String then value.strip.empty?
      else false
      end
    end

    def self.length_of(value)
      case value
      when String then value.size
      else value.to_s.size
      end
    end
  end
end
