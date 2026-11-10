# Included by ApplicationController and, through Auditing, again by
# GatedController: its callback is in the chain once, at
# ApplicationController's include.
module Stamped
  extend ActiveSupport::Concern

  included do
    after_action :stamp_response
  end

  def stamp_response
    response.set_header("X-Stamped", "1")
  end
end
