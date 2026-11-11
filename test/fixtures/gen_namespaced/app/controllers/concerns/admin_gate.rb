# Included by the nested-form Admin::ReportsController.
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 25
  end

  def admin? = request.header("x-admin") == "1"
  def require_admin = (render plain: "Not Found", status: :not_found unless admin?)
end
