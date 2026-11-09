# Raised by PostsController#set_post for the id "404".
class NotFound < StandardError
end

class ApplicationController < Cybertrain::Controller
  before_action :load_viewer
  rescue_from NotFound, with: :not_found

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
