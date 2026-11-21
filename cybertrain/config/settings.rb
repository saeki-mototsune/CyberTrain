# Config's application-declared settings: what config/app.rb declares with
# setting_string / setting_int / setting_bool, reads with string_setting /
# int_setting / bool_setting, and what `help` and the boot banner list
# (settings_usage, settings_summary).
#
# The class is reopened here as in cybertrain/config/validation.rb. These
# methods touch only the seven @setting_* ivars, whose typed seeds stay in
# Config#initialize (spikes/NOTES.md rules 9 and 73). Config.bool_from_env
# is also what initialize reads CYBERTRAIN_WORKER and CYBERTRAIN_REUSE_PORT
# with.
module Cybertrain
  class Config
    # The widest bounds an Integer setting may have: 18 digits either way,
    # the most {Config.int_setting_text?} lets through to `to_i` (which
    # raises RangeError past 2**63-1 under Spinel, spikes/NOTES.md rule 25).
    SETTING_INT_MIN = -999_999_999_999_999_999
    SETTING_INT_MAX = 999_999_999_999_999_999

    # Declares an application setting holding a String, read once from the
    # environment variable `env` (an empty or unset variable means
    # `default`). Read it with {#string_setting}. A name may be declared
    # once; give it as a Symbol. `secret: true` keeps the value out of the
    # boot banner and `help`, which then show only the variable's name.
    # @example config/app.rb
    #   Cybertrain.configure do |c|
    #     c.setting_string :base_url, env: "MYAPP_BASE_URL", default: ""
    #     c.setting_string :smtp_password, env: "MYAPP_SMTP_PASSWORD", default: "", secret: true
    #   end
    #   Cybertrain.config.string_setting(:base_url)
    # @param name [Symbol]
    # @param env [String] the environment variable
    # @param default [String]
    # @param secret [Boolean]
    # @return [nil]
    # @raise [ArgumentError] when the name is already declared or env is empty
    # @api public
    def setting_string(name, env:, default:, secret: false)
      key = declare_setting(name, env, secret)
      @setting_strings[key] = Config.env_or(env, default)
      @setting_descriptions[key] = secret ? "string, secret" : "string, default #{default.inspect}"
      nil
    end

    # Declares an application setting holding an Integer, read once from the
    # environment variable `env`: decimal digits with an optional leading
    # `-`, within `min..max`. An empty or unset variable means `default`;
    # anything else that does not parse, or a number out of bounds, also
    # gives `default`, with a `WARN` line through {Cybertrain.logger}.
    # Read it with {#int_setting}.
    # @example config/app.rb
    #   c.setting_int :prune_interval, env: "MYAPP_PRUNE_INTERVAL", default: 3600, min: 1, max: 9_999_999
    # @param name [Symbol]
    # @param env [String] the environment variable
    # @param default [Integer]
    # @param min [Integer] the smallest accepted value (no bound by default)
    # @param max [Integer] the largest accepted value (no bound by default)
    # @return [nil]
    # @raise [ArgumentError] when the name is already declared, env is
    #   empty, or default is outside min..max
    # @api public
    def setting_int(name, env:, default:, min: SETTING_INT_MIN, max: SETTING_INT_MAX)
      key = name.to_s
      bounds = Config.int_bounds(min, max)
      if min > max || default < min || default > max
        raise ArgumentError, "setting #{key}: default #{default} is out of range (#{bounds})"
      end

      declare_setting(name, env, false)
      @setting_ints[key] = Config.int_from_env(env, default, min, max)
      @setting_descriptions[key] = bounds.empty? ? "integer, default #{default}" : "integer #{bounds}, default #{default}"
      nil
    end

    # Declares an application setting holding true or false, read once from
    # the environment variable `env`: `1` or `true` is true, `0` or `false`
    # is false, an empty or unset variable means `default`, and any other
    # value gives `default` with a `WARN` line through {Cybertrain.logger}.
    # Read it with {#bool_setting}.
    # @example config/app.rb
    #   c.setting_bool :worker, env: "MYAPP_WORKER", default: true
    # @param name [Symbol]
    # @param env [String] the environment variable
    # @param default [Boolean]
    # @return [nil]
    # @raise [ArgumentError] when the name is already declared or env is empty
    # @api public
    def setting_bool(name, env:, default:)
      key = declare_setting(name, env, false)
      @setting_bools[key] = Config.bool_from_env(env, default)
      @setting_descriptions[key] = "boolean (1/true, 0/false), default #{default}"
      nil
    end

    # The value of the String setting `name` ({#setting_string}).
    # @param name [Symbol]
    # @return [String]
    # @raise [ArgumentError] when no String setting of that name is declared
    # @api public
    def string_setting(name)
      key = name.to_s
      raise ArgumentError, "no string setting #{key} (declare it with setting_string)" unless @setting_strings.key?(key)

      @setting_strings[key].to_s
    end

    # The value of the Integer setting `name` ({#setting_int}).
    # @param name [Symbol]
    # @return [Integer]
    # @raise [ArgumentError] when no Integer setting of that name is declared
    # @api public
    def int_setting(name)
      key = name.to_s
      raise ArgumentError, "no integer setting #{key} (declare it with setting_int)" unless @setting_ints.key?(key)

      @setting_ints[key].to_i
    end

    # The value of the boolean setting `name` ({#setting_bool}).
    # @param name [Symbol]
    # @return [Boolean]
    # @raise [ArgumentError] when no boolean setting of that name is declared
    # @api public
    def bool_setting(name)
      key = name.to_s
      raise ArgumentError, "no boolean setting #{key} (declare it with setting_bool)" unless @setting_bools.key?(key)

      @setting_bools[key] == true
    end

    # Replaces the value of a declared String setting, for tests.
    # @param name [Symbol]
    # @param value [String]
    # @return [nil]
    # @raise [ArgumentError] when no String setting of that name is declared
    # @api public
    def set_string_setting(name, value)
      string_setting(name)
      @setting_strings[name.to_s] = value
      nil
    end

    # Replaces the value of a declared Integer setting, for tests. The
    # declared bounds are not applied.
    # @param name [Symbol]
    # @param value [Integer]
    # @return [nil]
    # @raise [ArgumentError] when no Integer setting of that name is declared
    # @api public
    def set_int_setting(name, value)
      int_setting(name)
      @setting_ints[name.to_s] = value
      nil
    end

    # Replaces the value of a declared boolean setting, for tests.
    # @param name [Symbol]
    # @param value [Boolean]
    # @return [nil]
    # @raise [ArgumentError] when no boolean setting of that name is declared
    # @api public
    def set_bool_setting(name, value)
      bool_setting(name)
      @setting_bools[name.to_s] = value
      nil
    end

    # Records a declaration (what `help` and the boot banner list) and
    # returns the name as the String the typed Hashes are keyed by.
    def declare_setting(name, env, secret)
      key = name.to_s
      raise ArgumentError, "a setting needs a name" if key.empty?
      raise ArgumentError, "setting #{key}: env must name an environment variable" if env.empty?
      raise ArgumentError, "setting #{key} is declared twice" if @setting_envs.key?(key)

      @setting_names << key
      @setting_envs[key] = env
      @setting_secrets[key] = secret
      key
    end

    # "1..10", ">= 1", "<= 10", or "" when neither bound is set.
    def self.int_bounds(min, max)
      if min == SETTING_INT_MIN
        return "" if max == SETTING_INT_MAX

        return "<= #{max}"
      end
      return ">= #{min}" if max == SETTING_INT_MAX

      "#{min}..#{max}"
    end

    # True when text is an optional "-" and 1 to 18 significant decimal
    # digits (leading zeros aside): what `to_i` parses without the
    # RangeError it raises past 2**63-1 (spikes/NOTES.md rule 25).
    def self.int_setting_text?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      start = 0
      start = 1 if n > 0 && s.getbyte(0) == 45
      return false if n == start

      i = start
      while i < n
        b = s.getbyte(i)
        return false if b < 48 || b > 57

        i += 1
      end
      first = start
      first += 1 while first < n - 1 && s.getbyte(first) == 48
      n - first <= 18
    end

    # The Integer in ENV[env], or default (with a warning when the variable
    # is set but unusable).
    def self.int_from_env(env, default, min, max)
      text = ENV[env] || ""
      return default if text.empty?

      unless Config.int_setting_text?(text)
        Cybertrain.logger.warn("#{env}=#{text.inspect} is not an integer; using the default #{default}")
        return default
      end
      value = text.to_i
      if value < min || value > max
        Cybertrain.logger.warn("#{env}=#{text} is out of range (#{Config.int_bounds(min, max)}); using the default #{default}")
        return default
      end
      value
    end

    # The boolean in ENV[env] ("1"/"true", "0"/"false"), or default (with a
    # warning when the variable is set to anything else).
    def self.bool_from_env(env, default)
      text = ENV[env] || ""
      return default if text.empty?
      return true if text == "1" || text == "true"
      return false if text == "0" || text == "false"

      Cybertrain.logger.warn("#{env}=#{text.inspect} is not a boolean (1/true or 0/false); using the default #{default}")
      default
    end

    # The declared settings as `help` lists them: one line per setting with
    # its environment variable, name, type and default (a secret one shows
    # neither its default nor its value). "" when none is declared.
    def settings_usage
      names = @setting_names
      return "" if names.empty?

      width = 0
      i = 0
      while i < names.size
        env = @setting_envs[names[i]].to_s
        width = env.size if env.size > width
        i += 1
      end
      out = +"Settings (environment variables):\n"
      i = 0
      while i < names.size
        key = names[i]
        env = @setting_envs[key].to_s
        out << "  "
        out << env
        pad = width - env.size + 2
        while pad > 0
          out << " "
          pad -= 1
        end
        out << key
        out << ": "
        out << @setting_descriptions[key].to_s
        out << "\n"
        i += 1
      end
      out
    end

    # The declared settings' current values on one line for the boot banner,
    # `name=value` separated by spaces, a secret one as `name=[FILTERED]`.
    # "" when none is declared.
    def settings_summary
      names = @setting_names
      out = +""
      i = 0
      while i < names.size
        key = names[i]
        out << " " unless out.empty?
        out << key
        out << "="
        out << setting_display_value(key)
        i += 1
      end
      out
    end

    def setting_display_value(key)
      return "[FILTERED]" if @setting_secrets[key] == true
      return @setting_strings[key].to_s.inspect if @setting_strings.key?(key)
      return @setting_ints[key].to_i.to_s if @setting_ints.key?(key)

      (@setting_bools[key] == true).to_s
    end
  end
end
