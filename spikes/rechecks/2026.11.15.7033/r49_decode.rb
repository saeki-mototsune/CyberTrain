require "uri"
def ms(n)
  s = "é" + ("a" * n)
  t = Time.now.to_f
  URI.decode_www_form_component(s)
  ((Time.now.to_f - t) * 1000).round
end
puts "#{ms(50_000)} #{ms(100_000)} #{ms(200_000)}"
