# The concern of spec section 4.1. The fixture app has no Current.user, so
# the admin check reads the x-admin header. The after_action block calls
# gate_header and per_page without a receiver: gen/concerns.rb runs it in
# the including class, where ApplicationController.gate_header and the
# class_methods forwarder answer them (compiled as written here, the calls
# would be resolved against AdminGate: spikes/NOTES.md rule 92).
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
    after_action { |c| c.response.set_header(gate_header("Per-Page"), per_page.to_s) }
  end

  class_methods do
    def per_page = 50

    # Each of these is also the name of an instance method a
    # GatedController has: AdminGate's own (below), GatedController's,
    # ApplicationController's, Stamped's (ApplicationController's concern)
    # and Auditing's (GatedController's other concern).
    def gate_limit = 51
    def class_limit = 52
    def parent_limit = 53
    def stamp_limit = 54
    def audit_limit = 55
  end

  def admin? = request.header("x-admin") == "1"
  def require_admin = (render plain: "Not Found", status: :not_found unless admin?)
  def gate_limit = 1
end
