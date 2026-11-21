module Cybertrain
  # What the HTTP layer logs through, and the per-request context those
  # lines are written under (docs/design.md D90). The layer loads alone
  # (script/check-http-layer), so it defines plain bases here: a sink that
  # writes to standard error ({HttpLog}), an opaque context with no
  # behaviour ({HttpLogContext}), and the thread's context as the server
  # reads and swaps it ({HttpLogSwitch}). A framework on top subclasses
  # all three and installs its switch at load, so its own log lines carry
  # its per-request fields.

  # An opaque per-request log context: the layer stores one
  # ({Request#log_context}, {Response#body_log_context}) and hands it back
  # to the installed {HttpLogSwitch}; it never looks inside. A subclass
  # carries what the lines need (a request id and tags, say).
  # @api public
  class HttpLogContext
  end

  class HttpLogContext
    # The shared empty context: "no context". Told apart by identity.
    NONE = HttpLogContext.new
  end

  # The sink the Server logs through: `debug`, `info`, `warn`, `error`,
  # each answering nil. The base writes `"<level>: <msg>\n"` to standard
  # error and drops `debug`; a subclass writes its own lines.
  # @api public
  class HttpLog
    # @param msg [String]
    # @return [nil]
    def debug(msg)
      nil
    end

    # @param msg [String]
    # @return [nil]
    def info(msg)
      HttpLog.write_line("info", msg)
    end

    # @param msg [String]
    # @return [nil]
    def warn(msg)
      HttpLog.write_line("warn", msg)
    end

    # @param msg [String]
    # @return [nil]
    def error(msg)
      HttpLog.write_line("error", msg)
    end

    # One `"<level>: <msg>\n"` line on $stderr, with one write. A failed
    # write drops the line: logging never raises into its caller.
    # @param level [String]
    # @param msg [String]
    # @return [nil]
    # @api private
    def self.write_line(level, msg)
      $stderr.write("#{level}: #{msg}\n")
      nil
    rescue IOError, SystemCallError
      nil
    end
  end

  # The thread's log context, as the Server reads it ({#current_context}) and
  # swaps it around work it runs for a request ({#swap_context}: a handler's
  # exception line, a streamed body's writer). The base keeps none:
  # {#current_context} answers {HttpLogContext::NONE} and {#swap_context}
  # stores nothing. A subclass installed with {.installed=} keeps the
  # context in a slot of its own per thread.
  # @api public
  class HttpLogSwitch
    # The thread's context; the base keeps none.
    # @return [HttpLogContext]
    def current_context
      HttpLogContext::NONE
    end

    # Makes `ctx` the thread's context and answers the one it replaces;
    # whoever swaps one in swaps the answered one back in an `ensure`
    # (spikes/NOTES.md rule 103). The base answers NONE and stores nothing.
    # @param ctx [HttpLogContext]
    # @return [HttpLogContext]
    def swap_context(ctx)
      HttpLogContext::NONE
    end

    # A module-level ivar, never @@ (spikes/NOTES.md rules 18 and 64), in
    # the Params.max_page shape: the base until a subclass is installed at
    # load, before any thread starts.
    @installed = HttpLogSwitch.new

    # The switch the Server reads and swaps through.
    # @return [HttpLogSwitch]
    def self.installed
      @installed
    end

    # Installs `switch`, at load, before any thread starts.
    # @param switch [HttpLogSwitch] a subclass instance
    # @return [HttpLogSwitch] switch
    def self.installed=(switch)
      @installed = switch
    end
  end
end
