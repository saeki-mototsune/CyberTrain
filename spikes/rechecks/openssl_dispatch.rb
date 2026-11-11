# Reduced shape only: NOTES 62, not all boxed builtin calls.
require "openssl"
def first_byte(value)
  value.getbyte(0)
end
puts "boxed String byte: #{first_byte({ 'text' => 'abc', 'number' => 1 }['text'])}"
