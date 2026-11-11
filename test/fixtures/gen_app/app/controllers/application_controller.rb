# Raised by PostsController#set_post for the id "404".
class NotFound < StandardError
end

class ApplicationController < Cybertrain::Controller
  before_action :load_viewer
  rescue_from NotFound, with: :not_found
  include Stamped

  # Read without a receiver by AdminGate's after_action block, which
  # gen/concerns.rb runs in the including class.
  def self.gate_header(name) = "X-#{name}"

  def load_viewer
    @viewer = request.header("x-viewer") || "guest"
  end

  # The jobs page's guard (jobs_page ..., before_action: :require_admin in
  # config/routes.rb): a stand-in for a real sign-in check.
  def require_admin
    redirect_to "/" unless params[:admin] == "1"
  end

  def not_found
    render plain: "not found: #{rescued_exception.message}", status: :not_found
  end
end
