# A model concern (spec 4.2): its `included` body is spliced into Post at
# the `include` (between the title presence rule and the rules below it),
# and its instance method is one of Post's view methods.
module Visible
  extend ActiveSupport::Concern

  included do
    validates :body, length: { maximum: 10000 }
    scope :visible, -> { where(hidden: 0) }
  end

  def visible? = hidden == 0
end
