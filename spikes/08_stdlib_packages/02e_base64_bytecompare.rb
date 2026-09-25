# SPIKE (throwaway): byte-by-byte compare of base64 roundtrip on random binary data
require "securerandom"
require "base64"

bin = SecureRandom.random_bytes(16)
enc = Base64.strict_encode64(bin)
dec = Base64.strict_decode64(enc)
puts bin.bytesize
puts dec.bytesize
i = 0
mismatch = false
while i < bin.bytesize
  if bin.getbyte(i) != dec.getbyte(i)
    mismatch = true
    puts "mismatch at #{i}: #{bin.getbyte(i)} vs #{dec.getbyte(i)}"
  end
  i += 1
end
puts "byte mismatch: #{mismatch}"
puts bin == dec
puts bin.eql?(dec)
puts (bin <=> dec)
