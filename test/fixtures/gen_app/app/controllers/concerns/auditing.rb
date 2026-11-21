# A concern that includes another (Stamped): gen expands Stamped first.
module Auditing
  extend ActiveSupport::Concern
  include Stamped

  included do
    before_action :audit
    layout "audit", except: [:show]
  end

  def audit
    @audited_at = "now"
  end

  # AdminGate's class_methods has an audit_limit too.
  def audit_limit = 5
end
