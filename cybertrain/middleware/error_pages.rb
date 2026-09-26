require "cybertrain/middleware"
require "cybertrain/logger"

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
      rescue StandardError => e
        @logger.error("#{e.class.name}: #{e.message}")
        internal_error(ctx.response)
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

    # Starts over like Server#error_response: every header and cookie the
    # failed action had already set goes (a stale Location or
    # Content-Disposition: attachment would hide the page).
    def internal_error(response)
      response.headers.clear
      response.cookies.clear
      response.status = 500
      response.content_type = "text/plain; charset=utf-8"
      response.body = response.status_text
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
