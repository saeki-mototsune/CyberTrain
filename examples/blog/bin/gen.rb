require "cybertrain/generator"
require_relative "../config/routes"
require_relative "../db/schema"

exit(Cybertrain::Gen::Runner.run(".", ARGV))
