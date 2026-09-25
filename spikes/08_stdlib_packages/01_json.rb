# SPIKE (throwaway): does require "json" give generate/parse/pretty_generate with the API cybertrain needs (nested Hash/Array, polymorphic parse result, escaping)?
require "json"

doc = {
  "name" => "Alice O'Brien",
  "age" => 30,
  "height" => 1.75,
  "active" => true,
  "manager" => nil,
  "tags" => ["a", "b", "c"],
  "address" => { "city" => "Tōkyō", "zip" => "100-0001" },
  "quote" => "she said \"hi\"",
}

puts "-- generate --"
puts JSON.generate(doc)

puts "-- to_json --"
puts doc.to_json

puts "-- pretty_generate --"
puts JSON.pretty_generate(doc)

puts "-- parse roundtrip --"
parsed = JSON.parse(JSON.generate(doc))
puts parsed.class
puts parsed["name"]
puts parsed["address"]["city"]
puts parsed["tags"][1]
p parsed == doc

puts "-- case/when on parsed values --"
def describe(v)
  case v
  when String then "string:#{v}"
  when Integer then "int:#{v}"
  when Float then "float:#{v}"
  when true, false then "bool:#{v}"
  when nil then "nil"
  when Array then "array:#{v.length}"
  when Hash then "hash:#{v.length}"
  else "other"
  end
end
puts describe(parsed["name"])
puts describe(parsed["age"])
puts describe(parsed["height"])
puts describe(parsed["active"])
puts describe(parsed["manager"])
puts describe(parsed["tags"])
puts describe(parsed["address"])

puts "-- escaping quotes/unicode --"
puts JSON.generate({ "s" => "line\nbreak \"q\" and unicode é日" })
