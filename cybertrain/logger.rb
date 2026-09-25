# Cybertrain::Logger -- a small leveled logger, and Cybertrain.logger, the
# process-wide default every framework component logs through.
module Cybertrain
  class Logger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }

    attr_reader :level

    # `io` defaults to nil rather than the documented STDOUT literal: Spinel
    # cannot union a real IO handle with StringIO behind one polymorphic call
    # site (calling #puts on a variable that is sometimes STDOUT and
    # sometimes a StringIO raises NoMethodError for whichever branch isn't
    # picked at compile time -- confirmed with a standalone repro; StringIO
    # is not part of the IO family the builtin dispatch table covers). nil
    # keeps @io's inferred type StringIO-or-nil, and we go straight to the
    # STDOUT constant (never boxed into @io) when nothing was given.
    def initialize(io = nil, level = :info)
      @io = io
      @level = LEVELS[level] ? level : :info
    end

    # Falls back to :info for an unrecognized level rather than letting a
    # later `LEVELS[severity] >= LEVELS[@level]` raise
    # "comparison of Integer with nil failed".
    def level=(level)
      @level = LEVELS[level] ? level : :info
    end

    def debug(msg)
      log(:debug, msg)
    end

    def info(msg)
      log(:info, msg)
    end

    def warn(msg)
      log(:warn, msg)
    end

    def error(msg)
      log(:error, msg)
    end

    private

    def log(severity, msg)
      return unless LEVELS[severity] >= LEVELS[@level]

      line = "[#{severity.to_s.upcase}] #{msg}"
      if @io
        @io.puts(line)
      else
        STDOUT.puts(line)
      end
    end
  end

  # NOTE(Spinel): a module-level @@class variable here (`@@logger = Logger.new`
  # directly inside `module Cybertrain`) mis-compiles as soon as some earlier
  # required file has already opened `module Cybertrain` -- the C compiler
  # fails with "incompatible pointer to integer conversion assigning to
  # 'sp_int' ... from 'sp_Logger *'" (confirmed with
  # `require "cybertrain/version"; require "cybertrain/logger"`). A
  # module-level @instance variable does not have this problem. See
  # spikes/NOTES.md rule 18.
  @logger = Logger.new

  def self.logger
    @logger
  end

  def self.logger=(l)
    @logger = l
  end
end
