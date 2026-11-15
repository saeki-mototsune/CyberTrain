begin
  p "99999999999999999999".to_i
rescue RangeError => e
  puts "RangeError: #{e.message}"
end
