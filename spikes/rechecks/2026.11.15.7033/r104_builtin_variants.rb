def chain(e)
  k = e.class
  names = []
  while k
    names << k.name.to_s
    k = k.superclass
  end
  names.join(" < ")
end
begin
  raise "boom"
rescue StandardError => e
  puts chain(e)
end
begin
  File.open("/nonexistent/x")
rescue StandardError => e
  puts chain(e)
end
begin
  Integer("x")
rescue StandardError => e
  puts chain(e)
end
begin
  {}.fetch("k")
rescue StandardError => e
  puts chain(e)
end
