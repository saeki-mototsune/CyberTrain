# The feature-registry spike of feature_registry.rb (which has the
# description), requiring the features in the other order: B, A, B again,
# and the core last (each feature file requires it first).
#
# Run (Spinel 2026.11.04.7026, from spikes/phase6/):
#   ruby feature_registry_ba.rb
#   spinel feature_registry_ba.rb -o /tmp/feature_registry_ba && /tmp/feature_registry_ba
# Output, compiled and under CRuby 3.3.6 alike: feature_registry.rb's,
# except the first line, `order: b,a`.
require_relative "feature_registry/feature_b"
require_relative "feature_registry/feature_a"
require_relative "feature_registry/feature_b"
require_relative "feature_registry/core"
require_relative "feature_registry/checks"

puts "order: #{Registry.labels.join(",")}"
Checks.run
