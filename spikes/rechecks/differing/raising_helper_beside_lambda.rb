# Evidence for docs/spinel-feedback.md rule 79 (NOTES rule 79). Kept until
# rule 79 is closed.
# Why Console.unknown_model and unknown_record (cybertrain/console.rb) keep
# a typed value after their `raise`: a method that only raises, and a
# lambda that calls it and is stored where a lambda returning an object is
# stored later, as the blocks of one rescuing method. This is not rule 79's
# own program (../2026.11.15.7033/r79_raise_block.rb): the C error differs.
#
#   ruby spikes/rechecks/differing/raising_helper_beside_lambda.rb
#   spinel spikes/rechecks/differing/raising_helper_beside_lambda.rb -O 0 -o "$TMPDIR/rhl" && "$TMPDIR/rhl"
#
# Linux x86_64, Spinel 2026.11.15.7033 (a2f3bfaa, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-21.
#   CRuby:    ["no a", "no b"]
#   compiled: does not build, exit 1; cc stops at the `yield` of `g` with
#             error: incompatible types when assigning to type 'sp_RbVal' from type 'const char *'
# Built with Spinel 2026.11.04.7026 (a2d06115) the same day, the build
# stopped with the same error. With `Rel.new("")` as a second line of
# `C.unknown`, after the `raise`, the program builds and prints
# `["no a", "no b"]` on both builds. Either `out <<` line alone builds and
# prints its message.
class Rel
  def initialize(t); @t = t; end
end
module C
  def self.unknown(name)
    raise "no #{name}"
  end
  def self.no_builder = ->(name) { C.unknown(name) }
  @b = C.no_builder
  def self.b=(v)
    @b = v
  end
end
def rel_builder = ->(name) { Rel.new(name) }
C.b = rel_builder
def g
  yield
rescue StandardError => e
  e.message
end
out = Array.new(0) { "" }
out << g { C.unknown("a") }
out << g { C.no_builder.call("b") }
p out
