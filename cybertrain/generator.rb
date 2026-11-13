# The generator behind `spin run gen`: an app's bin/gen.rb requires this,
# then its config/routes.rb, then calls Cybertrain::Gen::Runner.run.
require "cybertrain/generator/inflector"
require "cybertrain/generator/routes_dsl"
require "cybertrain/generator/routes_emitter"
require "cybertrain/generator/controller_scan"
require "cybertrain/generator/controllers_emitter"
require "cybertrain/generator/concern_scan"
require "cybertrain/generator/concerns_emitter"
require "cybertrain/generator/manifest"
require "cybertrain/generator/locale_yaml"
require "cybertrain/generator/locale_scan"
require "cybertrain/generator/locales_emitter"
require "cybertrain/generator/runner"
