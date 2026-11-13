require "cybertrain"
require_relative "../config/app"
require_relative "../gen/migrations"

exit(Cybertrain::DB::CLI.run(ARGV))
