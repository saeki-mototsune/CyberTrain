# SPIKE (throwaway): isolate base64 urlsafe roundtrip
require "securerandom"
require "base64"

bin = SecureRandom.random_bytes(16)
enc = Base64.urlsafe_encode64(bin, padding: false)
dec = Base64.urlsafe_decode64(enc)
puts bin.bytesize
puts dec.bytesize
puts bin == dec
puts bin.unpack1("H*")
puts dec.unpack1("H*")

enc2 = Base64.strict_encode64(bin)
dec2 = Base64.strict_decode64(enc2)
puts bin == dec2
