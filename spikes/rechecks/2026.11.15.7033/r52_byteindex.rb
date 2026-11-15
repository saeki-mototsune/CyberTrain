begin
  p "a=1&\x81b=2".byteindex("b", 4)
rescue IndexError
  puts "IndexError"
end
