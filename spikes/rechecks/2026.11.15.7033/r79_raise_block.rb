def g
  yield
rescue => e
  e.message
end
out = []
out << g { raise "b" }
p out
