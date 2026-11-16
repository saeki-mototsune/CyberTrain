def die_later(code)
  Thread.new { sleep(0.2); exit(code) }
end
die_later(1)
sleep(1.0)
puts "main still alive"
