# The admin namespace's gate (Admin::ArticlesController includes it):
# `spin run gen` splices the `included` block into each including
# controller and forwards `per_page` to the class (gen/concerns.rb).
# require_admin and admin? themselves are ApplicationController's, so that
# the jobs page's controller, which inherits from it, has them too.
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    # The admin lists' page size: `self.class.per_page` in an action.
    def per_page = 20
  end
end
