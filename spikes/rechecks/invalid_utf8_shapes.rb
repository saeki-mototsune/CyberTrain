# Reduced shapes only: the parts of NOTES 52 that match CRuby on
# 2026.11.04.7026, on UTF-8 String literals holding a stray byte. Not here,
# because they still differ: `byteindex` at an offset off a character
# boundary and `strip` (differing/invalid_utf8.rb).

def try(label)
  puts "#{label}: #{yield.inspect}"
rescue StandardError => e
  puts "#{label}: #{e.class.name} #{e.message}"
end

try("valid_encoding? of a stray byte") { "x\x81y".valid_encoding? }
try("valid_encoding? of text") { "café".valid_encoding? }
try("split with the separator present") { "x\x81;y".split(";") }
try("split without it") { "x\x81".split(";") }
try("index after the stray byte") { "x\x81y".index("y") }
try("index before it") { "x\x81y".index("x") }
