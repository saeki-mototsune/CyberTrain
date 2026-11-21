# NOTES 123: `ENV[name]` with a key that is not a String literal answers the
# key itself when the variable is set, in this program.
#
# Needs the framework on the load path, so from the repository root:
#   ruby -I . spikes/rechecks/differing/env_nonliteral_key.rb
#   spinel -I . spikes/rechecks/differing/env_nonliteral_key.rb -O 0 -o "$TMPDIR/env_key" && "$TMPDIR/env_key"
#
# Linux x86_64, Spinel 2026.11.04.7026 (a2d06115, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-19:
#   CRuby:    set: 0.0.0.0        compiled: set: CYBERTRAIN_RECHECK_HOST
#             unset: default                unset: default
#
# The two requires are the trigger that was found, not a reduction: with
# `require "cybertrain/core"` (or `require "cybertrain"`) in front, the
# compiled program prints 0.0.0.0 (CRuby cannot load those two files
# without the preview's FFI shim, so only the compiled side was compared),
# and six standalone programs with the same `ENV[name] || ""` method were
# correct as well. Config.env_or is `configured = ENV[name] || ""`, then
# `configured.empty? ? default : configured`.
require "cybertrain/http/request"
require "cybertrain/config"

ENV["CYBERTRAIN_RECHECK_HOST"] = "0.0.0.0"
puts "set: " + Cybertrain::Config.env_or("CYBERTRAIN_RECHECK_HOST", "default")
puts "unset: " + Cybertrain::Config.env_or("CYBERTRAIN_RECHECK_UNSET", "default")
