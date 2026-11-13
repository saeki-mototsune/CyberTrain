require "json"
require "cybertrain/middleware"
require "cybertrain/logger"
require "cybertrain/config"
require "cybertrain/crypto"
require "cybertrain/http/request"
require "cybertrain/http/parameter_filter"

module Cybertrain
  # Gives every request an id (spec section 12.2, Rails'
  # ActionDispatch::RequestId), outermost in the stack: a version 4 UUID
  # ({Crypto.uuid}), or the request's `X-Request-Id` when a trusted proxy
  # sent it ({Request.trusted_peer?}, the check {Request#client_ip} makes)
  # and it is well-formed ({RequestId.accepted?}), so the proxy's log and
  # the application's share it; any other `X-Request-Id` is discarded,
  # never altered.
  #
  # The id is {Request#request_id}, the response's `X-Request-Id` (set
  # after the stack returned, so a 403 from HostAuthorization, a redirect
  # or an error page carries it too), and, through the thread's
  # {Logger::Scope} ({RequestId.scope_for}), a tag on every line logged
  # while the request runs: the tags `log_tags` (Config#log_tags) names,
  # in its order. The Scope found before is put back when the stack
  # returns or raises; what the stack raises goes on up unchanged.
  #
  # A RequestId that finds the request's id already set (the development
  # server's front_app wraps a second one around the diagnostics page)
  # leaves the id, the Scope and the header to the outer one.
  # @api public
  class RequestId < Middleware
    # The request and response header.
    HEADER = "X-Request-Id"
    # The longest id taken from a proxy, in bytes.
    MAX_BYTES = 255

    # @param app [Middleware]
    # @param log_tags [Array<Symbol>] `:request_id` and `:remote_ip`, in
    #   the order the lines show them (Config#log_tags)
    def initialize(app, log_tags = Cybertrain.config.log_tags)
      super(app)
      @log_tags = log_tags
    end

    # The rescue sits in this method's own body, which does not yield
    # (spikes/NOTES.md rules 32 and 45); each arm puts the Scope back and
    # re-raises. JSON::NestingError and JSON::ParserError are named
    # (rules 33 and 61), and the second arm takes what is not a
    # StandardError, so no exception leaves this request's Scope on the
    # thread for the next request a keep-alive connection brings.
    # @param ctx [Context]
    # @return [nil]
    def call(ctx)
      request = ctx.request
      own = request.request_id.empty?
      id = own ? RequestId.id_for(request) : request.request_id
      saved = Logger.current_scope
      if own
        request.request_id = id
        scope = RequestId.scope_for(request, id, @log_tags)
        saved = Logger.swap_scope(scope)
      end
      begin
        nxt = @app
        nxt.call(ctx) unless nxt.nil?
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        # What escapes the stack is reported here (plan D7, Task 9).
        finish_request(ctx, own, id, saved)
        raise e
      rescue NotImplementedError, SystemStackError, ScriptError => e
        finish_request(ctx, own, id, saved)
        raise e
      end
      finish_request(ctx, own, id, saved)
      nil
    end

    # The id for this request: its `X-Request-Id` when the peer is a
    # trusted proxy and the value is {accepted?}, else a new UUID.
    # @param request [Request]
    # @return [String]
    # @api private
    def self.id_for(request)
      given = request.header(HEADER).to_s
      return given if Request.trusted_peer?(request.remote_addr) && RequestId.accepted?(given)

      Crypto.uuid
    end

    # Whether `value` may be a request id: 1 to 255 bytes, each an ASCII
    # letter, digit or hyphen. A header sent twice arrives joined with
    # `", "` and is refused.
    # @param value [String]
    # @return [Boolean]
    # @api public
    def self.accepted?(value)
      s = value.to_s # a fresh local for the byte scan (spikes/NOTES.md rule 62)
      n = s.bytesize
      return false if n == 0 || n > MAX_BYTES

      i = 0
      while i < n
        return false unless RequestId.id_byte?(s.getbyte(i).to_i)

        i += 1
      end
      true
    end

    # `[A-Za-z0-9-]`, an if chain (spikes/NOTES.md rule 110).
    # @api private
    def self.id_byte?(b)
      if b == 45
        true
      elsif b >= 48 && b <= 57
        true
      elsif b >= 65 && b <= 90
        true
      elsif b >= 97 && b <= 122
        true
      else
        false
      end
    end

    # The Scope the request's lines are logged under: the id, the method,
    # the path masked as the request log masks it
    # (ParameterFilter.filter_path, never the query), no `where` yet (the
    # controller writes it), the tags in `log_tags` order (the id for
    # `:request_id`, {Request#client_ip} for `:remote_ip`), the id's index
    # among them (-1 when it is not one), no context. Every String is
    # bound to a local before `Scope.new` (spikes/NOTES.md rule 58).
    # @param request [Request]
    # @param id [String]
    # @param log_tags [Array<Symbol>]
    # @return [Logger::Scope]
    # @api public
    def self.scope_for(request, id, log_tags)
      tags = Array.new(0) { "" }
      id_tag = -1
      i = 0
      while i < log_tags.size
        tag = log_tags[i]
        if tag == :request_id
          id_tag = tags.size
          tags << id
        elsif tag == :remote_ip
          ip = request.client_ip
          tags << ip
        end
        i += 1
      end
      verb = request.method
      path = ParameterFilter.filter_path(request.path)
      where = ""
      context = { "" => "" }
      context.delete("")
      Logger::Scope.new(id, verb, path, where, tags, id_tag, context)
    end

    private

    # After the stack: the header on the response and the Scope found
    # before back on the thread, for the RequestId that set the id.
    def finish_request(ctx, own, id, saved)
      return nil unless own

      ctx.response.set_header(HEADER, id)
      Logger.swap_scope(saved)
      nil
    end
  end
end
