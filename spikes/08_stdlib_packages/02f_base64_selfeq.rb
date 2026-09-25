# SPIKE (throwaway): does base64-decoded string == itself / a dup of itself?
require "securerandom"
require "base64"

bin = SecureRandom.random_bytes(16)
enc = Base64.strict_encode64(bin)
dec = Base64.strict_decode64(enc)
puts dec == dec
d2 = dec.dup
puts dec == d2
d3 = String.new(dec)
puts dec == d3
puts dec.bytesize == d3.bytesize
puts dec.frozen?
puts bin.frozen?
