# The contrast to feature_registry.rb: the shapes the optional-subsystems
# design avoids because of spikes/NOTES.md rule 88, stored blocks that call
# the periodic hook on a Feature-typed receiver (captured, or the block's
# parameter, the block written at top level or in a feature subclass's
# reopened body), then the design's run_periodic(i, now) and a direct call
# in the same program. spikes/NOTES.md rule 104.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase6/):
#   ruby feature_registry_rule88.rb
#   spinel feature_registry_rule88.rb -o /tmp/feature_registry_rule88 && /tmp/feature_registry_rule88
# Output, compiled and under CRuby 3.3.6 alike (every form dispatches to
# FeatureB#periodic; see rule88_order.rb for the one that does not):
#   captured receiver: b periodic at 2000
#   block parameter: b periodic at 2500
#   block in a subclass body: b periodic at 2700
#   run_periodic(i, now): b periodic at 3000
#   direct: b periodic at 4000
require_relative "feature_registry/core"
require_relative "feature_registry/feature_a"
require_relative "feature_registry/feature_b"

module Contrast
  # The block captures a Feature-typed parameter and calls the hook on it.
  def self.schedule_captured(feature)
    Sched.every("captured #{feature.periodic_name}") { feature.periodic(Clock.now) }
    nil
  end
end

Registry::FEATURES.each { |f| Contrast.schedule_captured(f) if f.periodic_interval > 0 }
Clock.now = 2000
Sched.run_tasks
Log::LINES.each { |l| puts "captured receiver: #{l}" }
Log::LINES.clear

# Rule 88's own shape: a stored block whose parameter is the receiver,
# called with an element of the Feature Array.
module ParamBlocks
  BLOCKS = []

  def self.add(&block)
    BLOCKS << block
    nil
  end

  def self.run_each
    Registry::FEATURES.each do |f|
      next unless f.periodic_interval > 0
      BLOCKS.each { |cb| cb.call(f) }
    end
    nil
  end
end

ParamBlocks.add { |f| f.periodic(Clock.now) }
Clock.now = 2500
ParamBlocks.run_each
Log::LINES.each { |l| puts "block parameter: #{l}" }
Log::LINES.clear

# The same block written in a subclass's class body (where rule 88 was
# found: `add { |r| r.hook }` in `class Sub < Base`).
ParamBlocks::BLOCKS.clear
class FeatureA < Feature
  ParamBlocks.add { |f| f.periodic(Clock.now) }
end
Clock.now = 2700
ParamBlocks.run_each
Log::LINES.each { |l| puts "block in a subclass body: #{l}" }
Log::LINES.clear

# Then the design's shape in the same program: the block only calls
# Registry.run_periodic(i, now).
Sched::TASKS.clear
Registry.schedule_periodic
Clock.now = 3000
Sched.run_tasks
Log::LINES.each { |l| puts "run_periodic(i, now): #{l}" }

# Direct call on the Array element, no block.
Log::LINES.clear
Registry.run_periodic(Registry::FEATURES.size - 1, 4000)
Log::LINES.each { |l| puts "direct: #{l}" }
