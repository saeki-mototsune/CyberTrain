module ActiveSupport
  module Concern
    def included(base = nil, &block) = nil
  end
end
class Controller
  def self.before_action(name, only: [])
    nil
  end
end
module AdminGate
  extend ActiveSupport::Concern
  included do
    before_action :require_admin, only: [:index]
  end
end
puts "built"
