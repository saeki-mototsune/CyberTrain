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
end
