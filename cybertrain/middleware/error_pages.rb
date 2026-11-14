require "json"
require "cybertrain/middleware"
require "cybertrain/logger"
require "cybertrain/http/client_error"
require "cybertrain/error_reporter"
require "cybertrain/middleware/request_id"

module Cybertrain
  # Production's error pages (docs/design.md D14), outermost in the stack.
  # An exception from the app becomes a 500, logged as the Server would log
  # it; then any 4xx/5xx response that is not a page of its own -- an empty
  # body (`head :not_found`), no Content-Type, or text/plain (the Router's
  # "Not Found", `render plain:`) -- gets root/<status>.html when that file
  # exists. An error an action rendered as HTML or JSON is left alone, and
  # so is a status with no page (the plain text stays).
  #
  # The exception it turns into a 500 is reported here
  # ({ErrorReporter#report_unhandled}, `where` {RequestId.where_for}): the
  # outermost layer that sees it, inside the RequestId whose Scope gives
  # the event the request's id, method and path. A 4xx is not reported.
  class ErrorPages < Middleware
    def initialize(app, root = "public", logger = Cybertrain.logger)
      super(app)
      @root = root
      @logger = logger
    end

    def call(ctx)
      begin
        super
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        # JSON::ParserError named too: not a StandardError under Spinel
        # (NOTES rule 33), and an action's JSON.parse of a bad body deserves
        # the same 500 page as any other failure. ClientError maps and logs:
        # a client's fault (request parameters past Query's limits) is a 400
        # at info level. Caught here because this middleware wraps the whole
        # stack, so Server#respond's own mapping never sees the exception in
        # a real application.
        status = ClientError.classify(e, @logger)
        report_failure(ctx, e) if status >= 500
        ctx.response.reset_to(status)
      end
      response = ctx.response
      page = page_for(response)
      unless page.empty?
        response.content_type = "text/html; charset=utf-8"
        response.body = File.read(page)
      end
      nil
    end

    private

    # The 500's report; never raises ({ErrorReporter#report_unhandled}).
    # It does not set Context#error_reported: the exception is answered
    # here and goes no further. Should serving the page then raise (an
    # unreadable public/500.html), that new exception reaches RequestId,
    # which reports it as well: two reports for the request, each a real
    # failure.
    def report_failure(ctx, e)
      where = RequestId.where_for(ctx)
      Cybertrain.error.report_unhandled(e, where, ErrorReporter::NO_CONTEXT)
      nil
    end

    # The page to serve in place of the response's body, or "".
    def page_for(response)
      status = response.status
      return "" if status < 400 || !bare?(response)

      page = "#{@root}/#{status}.html"
      File.file?(page) ? page : ""
    end

    def bare?(response)
      return true if response.body.empty?

      type = response.header("Content-Type")
      type.nil? || type.start_with?("text/plain")
    end
  end
end
