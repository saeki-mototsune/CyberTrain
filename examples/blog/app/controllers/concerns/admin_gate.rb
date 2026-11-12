# The admin namespace's gate (Admin::ArticlesController includes it):
# `spin run gen` splices the `included` block into each including
# controller and forwards `per_page` to the class (gen/concerns.rb).
# require_admin is the Authentication concern's (written by `cybertrain
# generate authentication`, included by ApplicationController), the same
# one the jobs page names in config/routes.rb: a signed-in user who is
# not an admin gets 404, and require_authentication, which runs first,
# sends a visitor to sign in.
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
  end

  class_methods do
    # The admin lists' page size: `self.class.per_page` in an action.
    def per_page = 20
  end
end
