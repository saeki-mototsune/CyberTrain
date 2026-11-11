# Reduced shapes only: NOTES 46 (names), 53 and 54 (hierarchy).
module Recheck
  class Parent < StandardError; end
  class Child < Parent; end
end
puts "unraised message: #{Recheck::Child.new('kept').message}"
begin
  raise Recheck::Child, "raised"
rescue Recheck::Child => error
  puts "class: #{error.class.name}"
  puts "parent: #{error.class.superclass.name}"
  puts "is_a parent: #{error.is_a?(Recheck::Parent)}"
end
