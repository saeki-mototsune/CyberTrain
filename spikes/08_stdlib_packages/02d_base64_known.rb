# SPIKE (throwaway): base64 roundtrip with a fixed known string, not random bytes
require "base64"

known = "hello world, this is a test 123"
enc = Base64.strict_encode64(known)
dec = Base64.strict_decode64(enc)
puts enc
puts dec
puts known == dec
puts known.bytesize
puts dec.bytesize

# byte by byte compare
i = 0
mismatch = false
while i < known.bytesize
  if known.getbyte(i) != dec.getbyte(i)
    mismatch = true
    puts "mismatch at #{i}: #{known.getbyte(i)} vs #{dec.getbyte(i)}"
  end
  i += 1
end
puts "byte mismatch: #{mismatch}"
