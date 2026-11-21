require "json"
begin
  JSON.parse("{")
rescue JSON::ParserError => e
  puts e.class.superclass.name
end
