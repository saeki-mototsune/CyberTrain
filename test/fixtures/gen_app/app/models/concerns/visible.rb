# A model concern (spec 4.2): spliced into Post at the `include` (between
# the title presence rule and the rules below it); visible? is a Post view
# method, and its before_save runs after Post's own, unlike Rails.
module Visible
  extend ActiveSupport::Concern

  included do
    validates :body, length: { maximum: 10000 }
    scope :visible, -> { where(hidden: 0) }
    before_save { |r| r.body = "#{r.body}>visible" if r.title == "callback order" }
  end

  def visible? = hidden == 0
end
