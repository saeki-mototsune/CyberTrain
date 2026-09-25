# SPIKE (throwaway): uri parsing/encoding, hand-rolled query string parser with nested params
require "uri"

puts URI.encode_www_form_component("hello world & more=x/€")
puts URI.decode_www_form_component("hello+world+%26+more%3Dx%2F%E2%82%AC")

u = URI.parse("/posts/5?comment_id=9&sort=desc")
puts u.path
puts u.query
puts u.request_uri

# Hand-rolled nested query parser: a=1&b[]=2&b[]=3&post[title]=hi
def parse_query(qs)
  result = {}
  qs.split("&").each do |pair|
    k, v = pair.split("=", 2)
    k = URI.decode_www_form_component(k.to_s)
    v = URI.decode_www_form_component(v.to_s)
    if k.end_with?("[]")
      key = k[0, k.length - 2]
      (result[key] ||= []) << v
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

r = parse_query("a=1&b[]=2&b[]=3&post[title]=hi")
puts r.class
puts r["a"]
puts r["b"].class
puts r["b"].inspect
puts r["post"].class
puts r["post"]["title"]
