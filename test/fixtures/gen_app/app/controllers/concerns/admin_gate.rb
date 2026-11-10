# The concern of spec section 4.1. The fixture app has no Current.user, so
# the admin check reads the x-admin header.
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 50
  end

  def admin? = request.header("x-admin") == "1"
  def require_admin = (render plain: "Not Found", status: :not_found unless admin?)
end
