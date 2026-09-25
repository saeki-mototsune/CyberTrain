# SPIKE (throwaway): uri encode/decode/parse, hand-rolled query-string parsing, strscan, stringio.
require "uri"
require "strscan"
require "stringio"

puts "-- encode/decode_www_form_component --"
raw = "hello world+more/日本語?"
enc = URI.encode_www_form_component(raw)
puts enc
dec = URI.decode_www_form_component(enc)
puts dec == raw
puts URI.decode_www_form_component("a+b%20c%3D")

puts "-- URI.parse --"
u = URI.parse("https://example.com:8080/articles/1?foo=bar&baz=1#frag")
puts u.scheme
puts u.host
puts u.port
puts u.path
puts u.query
puts u.fragment

puts "-- hand-rolled nested query parsing --"
def parse_query(qs)
  result = {}
  qs.split("&").each do |pair|
    parts = pair.split("=", 2)
    k = URI.decode_www_form_component(parts[0].to_s)
    v = URI.decode_www_form_component(parts.length > 1 ? parts[1].to_s : "")
    if k.end_with?("[]")
      key = k[0, k.length - 2]
      result[key] ||= []
      result[key] << v
    elsif k =~ /\A([^\[]+)\[([^\]]+)\]\z/
      outer = $1
      inner = $2
      result[outer] ||= {}
      result[outer][inner] = v
    else
      result[k] = v
    end
  end
  result
end
q = parse_query("a=1&b[]=2&b[]=3&post[title]=hi")
p q
puts q["a"]
puts q["b"].inspect
puts q["post"]["title"]

puts "-- StringScanner --"
sc = StringScanner.new("id=42;name=alice;")
puts sc.scan(/id=/)
puts sc.scan(/\d+/)
puts sc.scan_until(/name=/)
puts sc.scan(/\w+/)
puts sc.eos?
puts sc.pos

puts "-- StringIO --"
io = StringIO.new
io.puts "line1"
io.write("line2\n")
puts io.string
r = StringIO.new("a\nb\nc\n")
puts r.gets
puts r.gets
