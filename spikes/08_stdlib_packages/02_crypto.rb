# SPIKE (throwaway): openssl HMAC/Digest, securerandom, base64 -- exact APIs and a constant-time compare.
require "openssl"
require "securerandom"
require "base64"

puts "-- OpenSSL::HMAC --"
key = "supersecretkey"
data = "message body"
puts OpenSSL::HMAC.hexdigest("SHA256", key, data)
digest_bytes = OpenSSL::HMAC.digest("SHA256", key, data)
puts digest_bytes.bytesize
puts OpenSSL::HMAC.hexdigest("SHA1", key, data)

puts "-- OpenSSL::Digest::SHA256 --"
puts OpenSSL::Digest::SHA256.hexdigest(data)
puts OpenSSL::Digest::SHA256.digest(data).bytesize

puts "-- constant time compare (bytes/XOR) --"
def const_time_eq(a, b)
  return false if a.bytesize != b.bytesize
  diff = 0
  i = 0
  while i < a.bytesize
    diff |= (a.getbyte(i) ^ b.getbyte(i))
    i += 1
  end
  diff == 0
end
mac1 = OpenSSL::HMAC.hexdigest("SHA256", key, data)
mac2 = OpenSSL::HMAC.hexdigest("SHA256", key, data)
mac3 = OpenSSL::HMAC.hexdigest("SHA256", key, "tampered")
puts const_time_eq(mac1, mac2)
puts const_time_eq(mac1, mac3)

puts "-- SecureRandom --"
h = SecureRandom.hex(32)
puts h.length
puts h
u = SecureRandom.urlsafe_base64(32)
puts u
puts u.length

puts "-- Base64 --"
bin = "hello?>>/+world\x00\xff".dup
enc = Base64.urlsafe_encode64(bin)
puts enc
dec = Base64.urlsafe_decode64(enc)
puts dec == bin
enc_nopad = Base64.urlsafe_encode64(bin, padding: false)
puts enc_nopad
puts Base64.urlsafe_decode64(enc_nopad) == bin
