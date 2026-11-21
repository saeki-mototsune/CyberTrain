# NOTES 52: what still differs on a UTF-8 String literal holding a stray
# byte. The parts that match are in ../invalid_utf8_shapes.rb.
#
#   ruby spikes/rechecks/differing/invalid_utf8.rb
#   spinel spikes/rechecks/differing/invalid_utf8.rb -O 0 -o "$TMPDIR/u8" && "$TMPDIR/u8"
#
# Linux x86_64, Spinel 2026.11.04.7026 (a2d06115, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-19.
#   CRuby:    byteindex after "&": IndexError offset 4 does not land on character boundary
#             byteindex after "+": IndexError offset 2 does not land on character boundary
#             strip: Encoding::CompatibilityError invalid byte sequence in UTF-8
#   compiled: byteindex after "&": 5
#             byteindex after "+": 3
#             strip: "x\x81"

def try(label)
  puts "#{label}: #{yield.inspect}"
rescue StandardError => e
  puts "#{label}: #{e.class.name} #{e.message}"
end

try('byteindex after "&"') { "a=1&\x81b=2".byteindex("b", 4) }
try('byteindex after "+"') { "x+\x81y".byteindex("y", 2) }
try("strip") { " x\x81 ".strip }
