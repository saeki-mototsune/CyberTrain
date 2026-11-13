# Cybertrain::Logger -- a small leveled logger, and Cybertrain.logger, the
# process-wide default every framework component logs through.
#
# A line (spec sections 12.1 and 12.5):
#
#   2026-11-11T12:00:00.123Z INFO Completed 200 in 12ms
#
# the time in UTC with milliseconds, the level in capitals, each tag in
# brackets, the message; or, with {Logger.json_lines} on
# (`c.log_format = :json`), one JSON object per line:
#
#   {"time":"2026-11-11T12:00:00.123Z","level":"INFO","tags":[],"message":"Completed 200 in 12ms"}
#
# The format switch, the lock and the time source are class-level, so a
# test that swaps Cybertrain.logger for a StringIO logger keeps them.
#
# The time follows the Clock (a test's `travel_to`), but this file is in
# the HTTP layer, which loads alone (script/check-http-layer) and cannot
# name the Clock: cybertrain/clock.rb pushes each change of its instant
# here through {Logger.follow_clock}; -1 means real time.
#
# Each line is built whole outside the lock (the JSON escaping and the
# UTF-8 scan included), then written with one `write` (and a flush for
# STDOUT) under {LOCK}, so lines from several threads never interleave.
# Nothing else happens inside the lock: no logging, no building of a line,
# no call back into the logger, because a blocked stdout holds every
# logging thread while one thread is inside it.
module Cybertrain
  # A leveled logger writing one line per message to standard output (or
  # to the io it was given): `debug`, `info`, `warn`, `error`, `fatal`.
  # The line's shape is the file's header comment; {Cybertrain.logger} is
  # the one the framework logs through.
  # @api public
  class Logger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }
    LEVEL_NAMES = { debug: "DEBUG", info: "INFO", warn: "WARN", error: "ERROR", fatal: "FATAL" }
    # The one lock every Logger writes under: one write of a prebuilt line
    # (and the flush) per hold.
    LOCK = Mutex.new
    # The tags of a line logged with none (seeded, spikes/NOTES.md rule 9).
    NO_TAGS = Array.new(0) { "" }
    HEX_DIGITS = %w[0 1 2 3 4 5 6 7 8 9 a b c d e f].freeze

    # What the lines logged on one thread carry while a piece of work runs
    # there (spec section 12.2, plan D5): the request's id, method, path
    # and `where` (the controller action, written by the controller), the
    # line's tags in order, the index of the request id among them (-1
    # when it is not shown), and the context an error report adds. One
    # Scope sits in the thread's Thread.current[{SCOPE_KEY}] slot
    # ({swap_scope}, {current_scope}); {tagged} adds tags to a copy.
    # @api public
    class Scope
      # @return [String]
      attr_reader :scope_request_id, :scope_request_method, :scope_request_path, :scope_where
      # @return [Array<String>]
      attr_reader :scope_tags
      # @return [Integer]
      attr_reader :scope_id_tag
      # @return [Hash{String => String}]
      attr_reader :scope_context

      # @param request_id [String]
      # @param request_method [String]
      # @param request_path [String]
      # @param where [String]
      # @param tags [Array<String>]
      # @param id_tag [Integer]
      # @param context [Hash{String => String}]
      def initialize(request_id, request_method, request_path, where, tags, id_tag, context)
        @scope_request_id = request_id
        @scope_request_method = request_method
        @scope_request_path = request_path
        @scope_where = where
        @scope_tags = tags
        @scope_id_tag = id_tag
        @scope_context = context
      end

      # Sets `where` on this thread's Scope. Does nothing on {NO_SCOPE},
      # the one empty Scope every thread without a Scope of its own shares
      # (told apart by identity).
      # @param where [String]
      # @return [nil]
      def scope_where=(where)
        @scope_where = where unless equal?(Logger::NO_SCOPE)
        nil
      end

      # A copy with `more` appended to the tags, the request id's place
      # kept; this Scope is not changed.
      # @param more [Array<String>]
      # @return [Scope]
      def with_tags(more)
        list = Array.new(0) { "" }
        @scope_tags.each { |t| list << t }
        more.each { |t| list << t.to_s }
        Scope.new(@scope_request_id, @scope_request_method, @scope_request_path, @scope_where, list,
                  @scope_id_tag, @scope_context)
      end
    end

    # The Thread.current key of the thread's Scope (spikes/NOTES.md rule
    # 102: beside I18n's locale and the db pool's Connection).
    SCOPE_KEY = :cybertrain_log_scope

    # The empty Scope, built with fresh locals (pre-flight ruling G1).
    # @api private
    def self.empty_scope
      id = ""
      verb = ""
      path = ""
      where = ""
      context = { "" => "" }
      context.delete("")
      Scope.new(id, verb, path, where, Array.new(0) { "" }, -1, context)
    end

    # The Scope of a thread with none of its own: no request id, no tags.
    # One object shared by every thread, so nothing writes to it.
    NO_SCOPE = Logger.empty_scope

    # This thread's Scope, {NO_SCOPE} when it has none.
    # @return [Scope]
    # @api public
    def self.current_scope
      value = Thread.current[SCOPE_KEY]
      value.nil? ? NO_SCOPE : value
    end

    # Makes `scope` this thread's Scope (the slot holds nil for
    # {NO_SCOPE}) and answers the one it replaces. Whoever runs work on a
    # thread swaps its Scope in and the answered one back in an `ensure`.
    # @param scope [Scope]
    # @return [Scope]
    # @api public
    def self.swap_scope(scope)
      previous = Logger.current_scope
      Thread.current[SCOPE_KEY] = scope.equal?(NO_SCOPE) ? nil : scope
      previous
    end

    # Empties this thread's slot: the thread is back to {NO_SCOPE}. The
    # test harness calls it around every case (spec section 20).
    # @return [nil]
    # @api public
    def self.reset_scope
      Thread.current[SCOPE_KEY] = nil
      nil
    end

    # Runs the block with `tags` appended to this thread's Scope and puts
    # the Scope back after it, also when it raises; answers the block's
    # value. {#tagged}'s body (spikes/NOTES.md rule 103's save-yield-ensure
    # in a module function).
    # @param tags [Array<String>]
    # @return [Object] the block's value
    # @api private
    def self.tagged_during(tags)
      saved = Logger.current_scope
      Thread.current[SCOPE_KEY] = saved.with_tags(tags)
      value = yield
      value
    ensure
      Thread.current[SCOPE_KEY] = saved.equal?(NO_SCOPE) ? nil : saved
    end

    # Module-level ivars, never @@ (spikes/NOTES.md rules 18 and 64).
    @json_lines = false
    @clock_micros = -1

    # Whether lines are JSON objects (`c.log_format = :json`, installed by
    # Runtime.apply) rather than text.
    # @return [Boolean]
    # @api public
    def self.json_lines
      @json_lines
    end

    # Turns JSON lines on or off.
    # @param on [Boolean]
    # @return [nil]
    # @api public
    def self.json_lines=(on)
      @json_lines = on
      nil
    end

    # The instant the Clock holds, in microseconds since the epoch, or -1
    # for real time: what cybertrain/clock.rb calls after each change of
    # its state, so the line's time follows a test's travel.
    # @param micros [Integer]
    # @return [nil]
    # @api private
    def self.follow_clock(micros)
      @clock_micros = micros
      nil
    end

    # The line's time, `2026-11-11T12:00:00.123Z`: UTC, from the instant
    # the Clock pushed ({follow_clock}), else the real time. The digits
    # are formatted by hand.
    # @return [String]
    # @api public
    def self.timestamp
      us = @clock_micros
      us = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond) if us == -1
      t = Time.at(us / 1_000_000).utc
      ms = (us % 1_000_000) / 1000
      "#{t.year}-#{Logger.two_digits(t.month)}-#{Logger.two_digits(t.day)}T" \
        "#{Logger.two_digits(t.hour)}:#{Logger.two_digits(t.min)}:#{Logger.two_digits(t.sec)}." \
        "#{Logger.three_digits(ms)}Z"
    end

    # @api private
    def self.two_digits(n)
      n < 10 ? "0#{n}" : n.to_s
    end

    # @api private
    def self.three_digits(n)
      return "00#{n}" if n < 10
      return "0#{n}" if n < 100

      n.to_s
    end

    # One whole line, its newline included. Text: the time, the level,
    # each tag in brackets in order, the message, and a newline unless the
    # message ends in one. JSON ({json_lines}): `time`, `level`, then
    # `request_id` when `id_tag` is the index of the request id among
    # `tags` (-1 when none of them is), `tags` without it, and `message`
    # (without the one newline it may end in).
    # @param level_name [String] `"INFO"`, `"ERROR"`, ...
    # @param tags [Array<String>]
    # @param id_tag [Integer]
    # @param msg [String]
    # @return [String]
    # @api public
    def self.format_line(level_name, tags, id_tag, msg)
      text = msg.to_s
      time = Logger.timestamp
      return Logger.json_line(time, level_name, tags, id_tag, text) if @json_lines

      # Built from the bytes (Task 2's review, I2): a UTF-8 tag beside a
      # binary or ISO-8859-1 message would raise Encoding::CompatibilityError
      # under CRuby. The bytes are written as they are.
      out = "#{time} #{level_name}".b
      tags.each do |tag|
        out << " ["
        out << tag.to_s.b
        out << "]"
      end
      out << " "
      out << text.b
      out << "\n" unless text.end_with?("\n")
      out.force_encoding("UTF-8")
      out
    end

    # {format_line}'s JSON object.
    # @api private
    def self.json_line(time, level_name, tags, id_tag, text)
      message = text.end_with?("\n") ? text.byteslice(0, text.bytesize - 1).to_s : text
      out = +"{\"time\":\"#{time}\",\"level\":\"#{level_name}\","
      if id_tag >= 0 && id_tag < tags.size
        out << "\"request_id\":"
        out << Logger.json_quote(tags[id_tag].to_s)
        out << ","
      end
      out << "\"tags\":["
      first = true
      i = 0
      while i < tags.size
        unless i == id_tag
          out << "," unless first
          out << Logger.json_quote(tags[i].to_s)
          first = false
        end
        i += 1
      end
      out << "],\"message\":"
      out << Logger.json_quote(message)
      out << "}\n"
      out
    end

    # `text` as a JSON string, its quotes included, with the Logger's own
    # escaping (JSON.generate raises on invalid UTF-8 under CRuby): `"` and
    # `\` as `\"` and `\\`, newline, carriage return and tab as `\n`, `\r`
    # and `\t`, other bytes below 0x20 and 0x7F as `\u00XX`; and, when the
    # bytes are not valid UTF-8, every byte from 0x80 up as `\ufffd`
    # (U+FFFD, the replacement character).
    # Validity is read from the bytes, whatever the String's encoding.
    # @param text [String]
    # @return [String]
    # @api public
    def self.json_quote(text)
      s = text.to_s # a fresh local (spikes/NOTES.md rule 62)
      n = s.bytesize
      valid = Logger.utf8_bytes?(s, n)
      out = +"\""
      run = 0
      i = 0
      while i < n
        b = s.getbyte(i).to_i
        escape = Logger.json_escape(b, valid)
        unless escape.empty?
          out << s.byteslice(run, i - run).to_s if i > run
          out << escape
          run = i + 1
        end
        i += 1
      end
      out << s.byteslice(run, n - run).to_s if n > run
      out << "\""
      out.force_encoding("UTF-8")
      out
    end

    # What {json_quote} writes for byte `b`, "" for the byte itself. An
    # if chain (spikes/NOTES.md rule 110).
    # @api private
    def self.json_escape(b, valid)
      if b == 34
        "\\\""
      elsif b == 92
        "\\\\"
      elsif b == 10
        "\\n"
      elsif b == 13
        "\\r"
      elsif b == 9
        "\\t"
      elsif b < 32 || b == 127
        "\\u00#{HEX_DIGITS[b >> 4]}#{HEX_DIGITS[b & 15]}"
      elsif b >= 128 && !valid
        "\\ufffd"
      else
        ""
      end
    end

    # Whether the first `n` bytes of `s` are valid UTF-8 (no overlong
    # form, no surrogate, nothing above U+10FFFF), read byte by byte.
    # @api private
    def self.utf8_bytes?(s, n)
      i = 0
      while i < n
        b = s.getbyte(i).to_i
        if b < 128
          i += 1
        else
          need = Logger.utf8_tail(b)
          return false if need == 0 || i + need >= n

          low = 128
          high = 191
          low = 160 if b == 224
          high = 159 if b == 237
          low = 144 if b == 240
          high = 143 if b == 244
          c = s.getbyte(i + 1).to_i
          return false if c < low || c > high

          k = 2
          while k <= need
            c = s.getbyte(i + k).to_i
            return false if c < 128 || c > 191

            k += 1
          end
          i += need + 1
        end
      end
      true
    end

    # How many continuation bytes the lead byte `b` takes; 0 for a byte
    # that cannot lead.
    # @api private
    def self.utf8_tail(b)
      if b >= 194 && b <= 223
        1
      elsif b >= 224 && b <= 239
        2
      elsif b >= 240 && b <= 244
        3
      else
        0
      end
    end

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
    # "comparison of Integer with nil failed". (Config#log_error refuses
    # an unknown level at boot.)
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

    # The line before the process gives up (a feeds process whose feed
    # keeps dying: cybertrain/background/supervisor.rb).
    def fatal(msg)
      log(:fatal, msg)
    end

    # Adds `tags` to every line logged on this thread while the block
    # runs, after the request's own, and restores the previous tags when
    # it ends, also when it raises (spec section 12.4). Every Logger on
    # the thread sees them: they live in the thread's {Logger::Scope}.
    # Answers the block's value. There is no block-less form.
    # @example
    #   Cybertrain.logger.tagged("billing") do
    #     Cybertrain.logger.info("charged 300") # ... INFO [<request id>] [billing] charged 300
    #   end
    # @param tags [Array<String>]
    # @return [Object] the block's value
    # @api public
    def tagged(*tags) = Logger.tagged_during(tags) { yield }

    # Writes one whole line (from {Logger.format_line}) with one `write`
    # under {LOCK}, and flushes STDOUT; the lock covers the write and the
    # flush only. No io parameter: {write_now} branches on `@io`
    # (spikes/NOTES.md rule 78).
    # @param line [String]
    # @return [nil]
    # @api private
    def write_line(line)
      LOCK.synchronize do
        write_now(line)
      end
      nil
    end

    # {write_line}'s write (and flush), inside the lock. A write that fails
    # (a closed io, a pipe whose reader died) drops the line: logging never
    # raises into its caller, and nothing is logged about it from inside
    # the lock. A plain method with one rescue clause (spikes/NOTES.md
    # rules 32 and 45).
    # @param line [String]
    # @return [nil]
    # @api private
    def write_now(line)
      if @io
        # #write, not #puts (spikes/NOTES.md rule 78): in a program whose
        # loggers never get an io, @io is nil-only, and Spinel
        # 2026.10.26.7019 sends `@io.puts(line)` through a dispatch whose
        # fallback fails C compilation once the TLS layer is in the program
        # (test/logger_tls.rb).
        @io.write(line)
      else
        # Flushed per line: a server's stdout is usually a pipe or a file,
        # where it is block-buffered (test/logger_flush.rb).
        STDOUT.write(line)
        STDOUT.flush
      end
      nil # not the flush's value: Spinel types it as a File but emits void
    rescue IOError, SystemCallError
      nil
    end

    private

    def log(severity, msg)
      return unless LEVELS[severity] >= LEVELS[@level]

      # Built whole before the lock is taken (write_line), with this
      # thread's tags (the Scope).
      scope = Logger.current_scope
      line = Logger.format_line(LEVEL_NAMES[severity] || "INFO", scope.scope_tags, scope.scope_id_tag, msg)
      write_line(line)
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
