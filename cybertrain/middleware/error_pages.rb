require "json"
require "cybertrain/middleware"
require "cybertrain/logger"
require "cybertrain/http/client_error"

module Cybertrain
  # Production's error pages (docs/design.md D14), outermost in the stack.
  # An exception from the app becomes a 500, logged as the Server would log
  # it; then any 4xx/5xx response that is not a page of its own -- an empty
  # body (`head :not_found`), no Content-Type, or text/plain (the Router's
  # "Not Found", `render plain:`) -- gets root/<status>.html when that file
  # exists. An error an action rendered as HTML or JSON is left alone, and
  # so is a status with no page (the plain text stays).
  class ErrorPages < Middleware
    def initialize(app, root = "public", logger = Cybertrain.logger)
      super(app)
      @root = root
      @logger = logger
    end

    def call(ctx)
      begin
        super
      rescue JSON::ParserError, StandardError => e
        # JSON::ParserError named too: not a StandardError under Spinel
        # (NOTES rule 33), and an action's JSON.parse of a bad body deserves
        # the same 500 page as any other failure. ClientError maps and logs:
        # a client's fault (request parameters past Query's limits) is a 400
        # at info level. Caught here because this middleware wraps the whole
        # stack, so Server#respond's own mapping never sees the exception in
        # a real application.
        ctx.response.reset_to(ClientError.classify(e, @logger))
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
