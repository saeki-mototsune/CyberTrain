# The generator behind `spin run gen`: an app's bin/gen.rb requires this,
# then its config/routes.rb, then calls Cybertrain::Gen::Runner.run.
require "cybertrain/generator/runner"
