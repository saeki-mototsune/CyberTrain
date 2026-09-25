class ApplicationController < Cybertrain::Controller
  before_action :load_viewer

  def load_viewer
    @viewer = request.header("x-viewer") || "guest"
  end
end
