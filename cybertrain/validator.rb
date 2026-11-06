require "cybertrain/cast"

module Cybertrain
  # One validation rule, kept as data: Spinel cannot define validation
  # methods at runtime, so Model#valid? walks these instead. Model.validates
  # makes one per attribute and rule (Validator.build); the declared
  # belongs_to's foreign key gets one from Model.validates_foreign_key.
  #
  # kind is :presence, :length, :inclusion, :exclusion, :format,
  # :numericality, :uniqueness or :foreign_key. (:custom is not used: a
  # `validate :method` line is generated into run_custom_validations, which
  # calls the method itself.) Unset options keep a sentinel or nil:
  # minimum / maximum / exact_length are -1, the Regexps and the
  # numericality limits nil (each read is guarded), message "" (the Rails
  # default then), on / condition_if / condition_unless / scope_attr nil.
  class Validator
    KINDS = [:presence, :length, :inclusion, :exclusion, :format, :numericality, :uniqueness, :custom, :foreign_key]

    # The keys Model.validates takes beside the rules, applied to each rule
    # of the line.
    COMMON_OPTIONS = [:allow_nil, :allow_blank, :on, :message, :if, :unless]
    RULES = [:presence, :length, :inclusion, :exclusion, :format, :numericality, :uniqueness]
    # Rails' order (NumericalityValidator::COMPARE_CHECKS): every failing
    # comparison adds its message.
    COMPARISONS = [:greater_than, :greater_than_or_equal_to, :equal_to, :less_than, :less_than_or_equal_to,
                   :other_than]

    attr_reader :attr, :kind, :minimum, :maximum, :allow_blank

    def initialize(attr, kind, minimum = -1, maximum = -1, allow_blank = false)
      @attr = attr
      @kind = kind
      @minimum = minimum
      @maximum = maximum
      @exact_length = -1
      # Strings or Integers, seeded with both (spikes/NOTES.md rule 9).
      @in_list = Array.new(0) { [0, ""][0] }
      # An Integer Range (the only kind Spinel builds: NOTES rule 86) as its
      # two ends; an open end has its has_range_* flag false.
      @has_range = false
      @range_min = 0
      @range_max = 0
      @range_has_min = false
      @range_has_max = false
      @pattern = nil
      @without = nil
      @only_integer = false
      @greater_than = nil
      @greater_than_or_equal_to = nil
      @less_than = nil
      @less_than_or_equal_to = nil
      @equal_to = nil
      @other_than = nil
      # A comparison limit as the model file wrote it (5, 5.5), for its
      # message.
      @limit_texts = { greater_than: "" }
      @limit_texts.delete(:greater_than)
      @scope_attr = nil
      @case_sensitive = true
      @allow_nil = false
      @allow_blank = allow_blank
      @on = nil
      @message = ""
      @condition_if = nil
      @condition_unless = nil
    end

    # The Validators of one `validates` call: `args` are its attribute
    # Symbols then its options Hash (Ruby passes the keywords as a trailing
    # Hash). One Validator per attribute and rule, in the order written;
    # every option is checked before any is made, so a bad line raises
    # ArgumentError and declares nothing.
    def self.build_all(args)
      attrs = Array.new(0) { :base }
      options = { presence: [true, false, 0, 0.0, "", :x, nil][0] }
      options.delete(:presence)
      args.each do |a|
        case a
        when Symbol then attrs << a
        when String then attrs << a.to_sym
        when Hash then a.each { |k, v| options[k.to_s.to_sym] = v }
        else raise ArgumentError, "validates takes attribute names and an options Hash"
        end
      end
      raise ArgumentError, "validates: no attribute given" if attrs.empty?

      options.each_key do |key|
        next if COMMON_OPTIONS.include?(key) || RULES.include?(key)

        names = (RULES + COMMON_OPTIONS).map { |k| "#{k}:" }.join(", ")
        raise ArgumentError, "validates: unknown option #{key}: (it takes #{names})"
      end
      if options.keys.select { |k| RULES.include?(k) }.empty?
        names = RULES.map { |k| "#{k}:" }.join(", ")
        raise ArgumentError, "validates: give at least one rule (#{names})"
      end
      out = Array.new(0) { Validator.new(:base, :presence) }
      attrs.each do |attr|
        options.each do |key, value|
          next unless RULES.include?(key)

          v = Validator.new(attr, key)
          v.apply_common(options)
          kept = v.apply_rule(value)
          out << v if kept
        end
      end
      out
    end

    # allow_nil:, allow_blank:, on:, message:, if: and unless: from the
    # `validates` line's options.
    def apply_common(options)
      options.each do |key, value|
        case key
        when :allow_nil then @allow_nil = Validator.option_flag(key, value)
        when :allow_blank then @allow_blank = Validator.option_flag(key, value)
        when :message then @message = Validator.option_text(key, value)
        when :on then @on = Validator.context_name(value)
        when :if then @condition_if = Validator.condition_name(key, value)
        when :unless then @condition_unless = Validator.condition_name(key, value)
        end
      end
      nil
    end

    # The rule's own value (`true`, or its Hash); false when the rule is
    # off (`presence: false`, `uniqueness: false`), so build drops it.
    def apply_rule(value)
      case value
      when true
        return true if @kind == :presence || @kind == :numericality || @kind == :uniqueness

        raise ArgumentError, "validates: #{@kind}: takes a Hash of options"
      when false, nil
        false
      when Hash
        raise ArgumentError, "validates: presence: takes true or false" if @kind == :presence

        value.each { |k, x| apply_rule_option(k.to_s.to_sym, x) }
        if @kind == :format && @pattern.nil? && @without.nil?
          raise ArgumentError, "validates: format: takes with: or without: a Regexp"
        end
        if (@kind == :inclusion || @kind == :exclusion) && !value.key?(:in) && !value.key?(:within)
          raise ArgumentError, "validates: #{@kind}: takes in: an Array or an Integer Range"
        end
        true
      else
        raise ArgumentError, "validates: #{@kind}: takes true or a Hash of options"
      end
    end

    # One key of a rule's Hash (`length: { maximum: 40 }`). message:,
    # allow_nil: and allow_blank: there apply to that rule alone.
    def apply_rule_option(key, value)
      case key
      when :message then @message = Validator.option_text(key, value)
      when :allow_nil then @allow_nil = Validator.option_flag(key, value)
      when :allow_blank then @allow_blank = Validator.option_flag(key, value)
      end
      return nil if key == :message || key == :allow_nil || key == :allow_blank

      case @kind
      when :length then apply_length(key, value)
      when :inclusion, :exclusion then apply_list(key, value)
      when :format then apply_format(key, value)
      when :numericality then apply_numericality(key, value)
      when :uniqueness then apply_uniqueness(key, value)
      end
      nil
    end

    def apply_length(key, value)
      case key
      when :minimum then @minimum = Validator.length_option(key, value)
      when :maximum then @maximum = Validator.length_option(key, value)
      when :is then @exact_length = Validator.length_option(key, value)
      when :in, :within
        case value
        when Range
          from = value.begin
          to = value.end
          @minimum = from.nil? ? -1 : Validator.length_option(key, from)
          unless to.nil?
            @maximum = Validator.length_option(key, to)
            @maximum -= 1 if value.exclude_end?
          end
        else raise ArgumentError, "validates: length: #{key}: takes an Integer Range"
        end
      else raise ArgumentError, "validates: length: takes minimum:, maximum:, is:, in: or within: (got #{key}:)"
      end
      nil
    end

    # inclusion / exclusion `in:` (or `within:`): an Array of Strings or
    # Integers, or a Range of Integers. Spinel builds no other Range (NOTES
    # rule 86), and one with other ends raises here under CRuby too.
    def apply_list(key, value)
      unless key == :in || key == :within
        raise ArgumentError, "validates: #{@kind}: takes in: (got #{key}:)"
      end

      case value
      when Time then raise ArgumentError, "validates: #{@kind}: in: takes an Array or an Integer Range"
      when Range
        from = value.begin
        to = value.end
        @has_range = true
        case from
        when nil then @range_has_min = false
        when Integer
          @range_min = from.to_i
          @range_has_min = true
        else raise ArgumentError, "validates: #{@kind}: in: takes a Range of Integers only"
        end
        case to
        when nil then @range_has_max = false
        when Integer
          @range_max = value.exclude_end? ? to.to_i - 1 : to.to_i
          @range_has_max = true
        else raise ArgumentError, "validates: #{@kind}: in: takes a Range of Integers only"
        end
      when Array
        value.each do |item|
          case item
          when String then @in_list << item
          when Integer then @in_list << item
          when Symbol then @in_list << item.to_s
          else raise ArgumentError, "validates: #{@kind}: in: takes Strings or Integers"
          end
        end
      else raise ArgumentError, "validates: #{@kind}: in: takes an Array or an Integer Range"
      end
      nil
    end

    def apply_format(key, value)
      case value
      when Regexp
        case key
        when :with then @pattern = value
        when :without then @without = value
        else raise ArgumentError, "validates: format: takes with: or without: (got #{key}:)"
        end
      else raise ArgumentError, "validates: format: #{key}: takes a Regexp"
      end
      nil
    end

    def apply_numericality(key, value)
      if key == :only_integer
        @only_integer = Validator.option_flag(key, value)
        return nil
      end
      unless COMPARISONS.include?(key)
        names = ([:only_integer] + COMPARISONS).map { |k| "#{k}:" }.join(", ")
        raise ArgumentError, "validates: numericality: takes #{names} (got #{key}:)"
      end
      limit = 0.0
      case value
      when Integer then limit = value.to_f
      when Float then limit = value.to_f
      else raise ArgumentError, "validates: numericality: #{key}: takes a number"
      end
      @limit_texts[key] = value.to_s
      case key
      when :greater_than then @greater_than = Cast.float_or_nil(limit)
      when :greater_than_or_equal_to then @greater_than_or_equal_to = Cast.float_or_nil(limit)
      when :equal_to then @equal_to = Cast.float_or_nil(limit)
      when :less_than then @less_than = Cast.float_or_nil(limit)
      when :less_than_or_equal_to then @less_than_or_equal_to = Cast.float_or_nil(limit)
      when :other_than then @other_than = Cast.float_or_nil(limit)
      end
      nil
    end

    def apply_uniqueness(key, value)
      case key
      when :scope
        case value
        when Symbol then @scope_attr = value.to_sym
        when String then @scope_attr = value.to_sym
        else raise ArgumentError, "validates: uniqueness: scope: takes one column name"
        end
      when :case_sensitive then @case_sensitive = Validator.option_flag(key, value)
      else raise ArgumentError, "validates: uniqueness: takes scope: or case_sensitive: (got #{key}:)"
      end
      nil
    end

    def self.option_flag(key, value)
      case value
      when true then true
      when false then false
      else raise ArgumentError, "validates: #{key}: takes true or false"
      end
    end

    def self.option_text(key, value)
      case value
      when String then value.to_s
      else raise ArgumentError, "validates: #{key}: takes a String"
      end
    end

    def self.length_option(key, value)
      case value
      when Integer
        raise ArgumentError, "validates: length: #{key}: takes a count of 0 or more" if value < 0

        value.to_i
      else raise ArgumentError, "validates: length: #{key}: takes an Integer"
      end
    end

    def self.context_name(value)
      case value
      when :create then :create
      when :update then :update
      else raise ArgumentError, "validates: on: takes :create or :update"
      end
    end

    # if: / unless: name a method of the model (the generated
    # validation_condition? calls it); a lambda cannot be called by name
    # under Spinel, so it is refused here as the generator refuses it.
    def self.condition_name(key, value)
      case value
      when Symbol then value.to_sym
      when String then value.to_sym
      else raise ArgumentError, "validates: #{key}: takes a Symbol method name"
      end
    end

    # Adds this rule's messages for `record` to its errors. `context` is
    # :create or :update (Model#valid?: new_record? or not). A rule with
    # on: runs in that context only, one with if: / unless: when
    # record.validation_condition? says so; allow_nil skips a nil value,
    # allow_blank a nil or blank (whitespace-only String) one.
    def validate(record, context)
      on = @on
      return nil if !on.nil? && on != context

      cond = @condition_if
      return nil if !cond.nil? && !record.validation_condition?(cond)

      cond = @condition_unless
      return nil if !cond.nil? && record.validation_condition?(cond)

      value = record.read_attribute(@attr)
      return nil if value.nil? && @allow_nil

      blank = Validator.blank?(value)
      return nil if blank && @allow_blank

      case @kind
      when :presence
        add_message(record, "can't be blank") if blank
      when :foreign_key
        # 0 is the id of no saved record (Model#id before the first save).
        add_message(record, "can't be blank") if blank || value == 0
      when :length
        # nil is left to a presence rule, as `length` alone allows it.
        return nil if value.nil?

        check_length(record, Validator.length_of(value))
      when :inclusion
        add_message(record, "is not included in the list") unless listed?(value)
      when :exclusion
        add_message(record, "is reserved") if listed?(value)
      when :format
        check_format(record, value)
      when :numericality
        check_number(record, value)
      when :uniqueness
        sa = @scope_attr
        scope_value = sa.nil? ? nil : record.read_attribute(sa)
        if record.unique_value_taken?(@attr, value, sa, scope_value, record.id, @case_sensitive)
          add_message(record, "has already been taken")
        end
      end
      nil
    end

    # The message: message: when the line gives one, else Rails' default.
    def add_message(record, default)
      record.errors.add(@attr, @message == "" ? default : @message)
      nil
    end

    # Rails' LengthValidator order: is:, then minimum:, then maximum:.
    def check_length(record, size)
      if @exact_length >= 0 && size != @exact_length
        add_message(record, "is the wrong length (should be #{@exact_length} characters)")
      end
      add_message(record, "is too short (minimum is #{@minimum} characters)") if @minimum >= 0 && size < @minimum
      add_message(record, "is too long (maximum is #{@maximum} characters)") if @maximum >= 0 && size > @maximum
      nil
    end

    # Whether `value` is in the in: list or Range. A String matches a
    # String, an Integer an Integer (an Integer column's "3" from a form is
    # already 3); a Range covers Integers and Floats.
    def listed?(value)
      if @has_range
        number = 0.0
        case value
        when Time then return false
        when Integer then number = value.to_f
        when Float then number = value
        else return false
        end
        return false if @range_has_min && number < @range_min.to_f
        return false if @range_has_max && number > @range_max.to_f

        return true
      end
      @in_list.each do |item|
        case item
        when String
          case value
          when String then return true if value == item
          end
        when Integer
          case value
          when Integer then return true if value == item
          end
        end
      end
      false
    end

    # with: must match and without: must not, on the value as a String; a
    # nil value fails a with: rule (unless allow_nil) and passes a
    # without:-only one.
    def check_format(record, value)
      if value.nil?
        # nil matches no Regexp: a with: rule fails it, a without: rule
        # alone passes it (Rails).
        add_message(record, "is invalid") unless @pattern.nil?
        return nil
      end
      text = Cast.str(value)
      re = @pattern
      unless re.nil?
        unless text.match?(re)
          add_message(record, "is invalid")
          return nil
        end
      end
      re = @without
      unless re.nil?
        add_message(record, "is invalid") if text.match?(re)
      end
      nil
    end

    # Rails' NumericalityValidator: not a number stops the rule, then
    # only_integer, then every failing comparison. A String is parsed as a
    # number (" 12 ", "-3", "1.5e2"); only_integer takes an Integer or an
    # integer String ("12", "-3"), so a Float fails it as Rails' does.
    def check_number(record, value)
      unless Validator.numeric?(value)
        add_message(record, "is not a number")
        return nil
      end
      if @only_integer && !Validator.integer_value?(value)
        add_message(record, "must be an integer")
        return nil
      end
      number = Validator.number_of(value)
      limit = @greater_than
      add_message(record, "must be greater than #{@limit_texts[:greater_than]}") if !limit.nil? && !(number > limit)
      limit = @greater_than_or_equal_to
      if !limit.nil? && !(number >= limit)
        add_message(record, "must be greater than or equal to #{@limit_texts[:greater_than_or_equal_to]}")
      end
      limit = @equal_to
      add_message(record, "must be equal to #{@limit_texts[:equal_to]}") if !limit.nil? && number != limit
      limit = @less_than
      add_message(record, "must be less than #{@limit_texts[:less_than]}") if !limit.nil? && !(number < limit)
      limit = @less_than_or_equal_to
      if !limit.nil? && !(number <= limit)
        add_message(record, "must be less than or equal to #{@limit_texts[:less_than_or_equal_to]}")
      end
      limit = @other_than
      add_message(record, "must be other than #{@limit_texts[:other_than]}") if !limit.nil? && number == limit
      nil
    end

    def self.numeric?(value)
      case value
      when Time then false
      when Integer then true
      when Float then true
      when String then Validator.number_text?(value.strip)
      else false
      end
    end

    def self.integer_value?(value)
      case value
      when Time then false
      when Integer then true
      when String then Validator.integer_text?(value)
      else false
      end
    end

    def self.number_of(value)
      case value
      when Time then 0.0
      when Integer then value.to_f
      when Float then value
      when String then value.strip.to_f
      else 0.0
      end
    end

    # "12", "-3", "+7": a sign, then digits only.
    def self.integer_text?(text)
      i = text.start_with?("+") || text.start_with?("-") ? 1 : 0
      return false if i >= text.size

      while i < text.size
        ch = text[i, 1]
        return false unless ch >= "0" && ch <= "9"

        i += 1
      end
      true
    end

    # A decimal number as Ruby's Float() reads one: a sign, digits with an
    # optional fraction (".5" and "5.0", not "5."), an optional exponent.
    def self.number_text?(text)
      i = text.start_with?("+") || text.start_with?("-") ? 1 : 0
      digits = 0
      while i < text.size && text[i, 1] >= "0" && text[i, 1] <= "9"
        digits += 1
        i += 1
      end
      if i < text.size && text[i, 1] == "."
        i += 1
        fraction = 0
        while i < text.size && text[i, 1] >= "0" && text[i, 1] <= "9"
          fraction += 1
          i += 1
        end
        return false if fraction == 0

        digits += fraction
      end
      return false if digits == 0

      if i < text.size && (text[i, 1] == "e" || text[i, 1] == "E")
        i += 1
        i += 1 if i < text.size && (text[i, 1] == "+" || text[i, 1] == "-")
        exponent = 0
        while i < text.size && text[i, 1] >= "0" && text[i, 1] <= "9"
          exponent += 1
          i += 1
        end
        return false if exponent == 0
      end
      i == text.size
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
