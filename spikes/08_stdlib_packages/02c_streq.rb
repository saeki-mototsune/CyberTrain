# SPIKE (throwaway): does String#== behave for binary strings that print identical hex?
require "securerandom"

a = SecureRandom.random_bytes(16)
b = String.new(a)
puts a == b
puts a.equal?(b)
puts a.bytesize
puts b.bytesize
puts a.length
puts b.length
puts a.encoding rescue puts "no encoding method"
puts b.encoding rescue puts "no encoding method"
