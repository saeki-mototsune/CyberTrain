# Phase 6 spike, Task 1 of docs/superpowers/plans/2026-11-13-optional-subsystems-plan.md:
# the feature registry of the optional-subsystems design (spec section 4)
# under the pinned Spinel, with no framework. feature_registry/core.rb
# holds a base class Feature whose hooks return String, Bool, Integer,
# nil, an Array of String and a Response (a class with ivars) or nil, and
# the module-level Array Registry::FEATURES that each hook is iterated
# over. feature_registry/feature_a.rb and feature_b.rb each override a
# subset of hooks, register one instance at require time (once by class
# name) and, for A, reopen the core's Controller with an instance and a
# class method. B's periodic hook runs from blocks stored by a scheduler
# (Task objects, and a bare Array of blocks) whose body only calls
# Registry.run_periodic(i, now). health_problem is overridden by A only.
# This program requires A then B (and A a second time);
# feature_registry_ba.rb requires B, A, B, then the core. Only the
# "order:" line differs between the two. feature_registry_rule88.rb is the
# contrast (stored blocks calling the hook on a Feature-typed receiver),
# rule88_order.rb its reduction. spikes/NOTES.md rule 101. A record, not
# a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase6/; no package needed):
#   ruby feature_registry.rb
#   spinel feature_registry.rb -o /tmp/feature_registry && /tmp/feature_registry
# Output, compiled and under CRuby 3.3.6 alike (exit 0, 4 s to compile):
#   order: a,b
#   registered: 2
#   labels: a,b
#   classes: FeatureA,FeatureB
#   register FeatureA again: false, registered: 2
#   boot problems (ok): 0
#   boot problems (broken): a: broken has no worker | b: broken has no feed
#   health problems: a: stale since 970
#   health per feature: a="a: stale since 970" b=""
#   any failed? (each/any?): false (loop): false
#   any failed? after b breaks (each/any?): true (loop): true
#   all reload ok?: false
#   reload_ok?/failed? per feature: a=false/false b=true/true
#   command alpha: 3
#   command beta: 7
#   command gamma: -1
#   command names: alpha,beta,beta-list
#   call /a: 200 from a
#   call /b: 201 from b
#   call /c: nil
#   filter: 200 page [b]
#   tasks: b-prune, blocks: 1
#   reopened: posts turbo:posts limit 5 per minute
#   log: a stopped
#   log: b periodic at 2000
#   log: b periodic at 3000
#   log: b started for shop
#   log: b stopped
require_relative "feature_registry/core"
require_relative "feature_registry/feature_a"
require_relative "feature_registry/feature_b"
require_relative "feature_registry/feature_a"
require_relative "feature_registry/checks"

puts "order: #{Registry.labels.join(",")}"
Checks.run
