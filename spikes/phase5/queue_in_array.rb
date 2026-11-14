# Phase 5b, found while writing test/logger_scope.rb (spikes/NOTES.md rule
# 116, docs/spinel-feedback.md AP): `pop(timeout:)` on a Queue that was
# put in an Array is compiled as Array#pop.
#
# Run (from the repository root; outputs outside the package, rule 98):
#   spinel spikes/phase5/queue_in_array.rb -o $TMPDIR/queue_in_array && $TMPDIR/queue_in_array; echo "exit $?"
#   ruby spikes/phase5/queue_in_array.rb
# Output (2026-11-14, Spinel 2026.11.04.7026 a2d06115, gcc 13.3.0, Linux
# x86_64, no flags; CRuby 3.3.6):
#   compiled: no implicit conversion of Hash into Integer (TypeError)
#             exit 1
#   CRuby:    "hello"
#             "direct"
#
# Binding the element to a local first fails the same way: a program whose
# only pop is `q = inboxes[0]; q << "direct"; q.pop(timeout: 5)` raises the
# same TypeError, and so does passing `inboxes[1]` to a method whose
# parameter it pops. What works is a Queue that never goes into an Array:
#   first = Queue.new
#   first << "local"
#   puts first.pop(timeout: 5).inspect     # "local", compiled as under CRuby
# and the same Queue passed as a method's parameter and popped there
# ("param"), as test/logger_scope.rb's tagging_thread does (both checked on
# 2026-11-14 with the same build).
inboxes = [Queue.new, Queue.new]
inboxes[1] << "hello"
got = inboxes[1].pop(timeout: 5)
puts got.inspect
q = inboxes[0]
q << "direct"
puts q.pop(timeout: 5).inspect
