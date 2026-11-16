begin
  raise "boom"
rescue RuntimeError => e
  puts e.class.superclass.name
end
