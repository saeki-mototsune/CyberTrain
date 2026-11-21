module Concern
  def class_methods(&block) = nil
end
module Gate
  extend Concern
  class_methods do
    def per_page = 50
  end
end
class C
  include Gate
end
puts "#{C.new.respond_to?(:per_page)} #{Gate.respond_to?(:per_page)}"
