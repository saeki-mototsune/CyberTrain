# Evidence for docs/spinel-feedback.md AV (NOTES rule 17). Kept until AV is closed.
# A class used above its `class` statement. The half of rule 17 that
# matches CRuby, a constant assigned with `=`, is in ../constant_order.rb.
#
#   ruby spikes/rechecks/differing/class_before_definition.rb
#   spinel spikes/rechecks/differing/class_before_definition.rb -O 0 -o "$TMPDIR/cbd" && "$TMPDIR/cbd"
#
# Linux x86_64, Spinel 2026.11.15.7033 (a2f3bfaa, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-21.
#   CRuby:    NameError: uninitialized constant Later
#   compiled: hi
# Built with Spinel 2026.11.04.7026 (a2d06115) the same day, the program
# printed `hi` too. Without the `begin`, CRuby stops at the first line with
# "uninitialized constant Later (NameError)", exit 1, and the compiled
# program prints `hi` and exits 0 on both builds.
begin
  puts Later.new.hi
rescue NameError => e
  puts "#{e.class.name}: #{e.message}"
end
class Later; def hi = "hi"; end
