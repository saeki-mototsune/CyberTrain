require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/params"

module Cybertrain
  # Everything one request carries through the middleware stack, the router
  # and the controller. The Response is created here and written back to the
  # socket by the Server once the stack returns.
  class Context
    attr_reader :request, :response
    attr_accessor :params, :route_params, :route_name

    def initialize(request)
      @request = request
      @response = Response.new
      @params = Params.new
      @route_params = {}
      @route_name = ""
    end
  end
end
