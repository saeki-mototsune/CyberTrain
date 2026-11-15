module Outer; end
class Missing < StandardError; end

begin
  begin
    raise Missing, "m"
  rescue Outer::Missing => e
    puts "rescued by Outer::Missing"
  rescue NameError => e
    puts "NameError in arm"
  end
rescue NameError => e
  puts "outer NameError: #{e.message}"
end
