# The spike application's settings (Cybertrain::Config).
Cybertrain.configure do |c|
  c.log_level = :none if c.test?
  # Rails turns forgery protection off in tests; the spike does the same
  # so IntegrationTest#post needs no token (see the spike report).
  c.csrf = false if c.test?
end
