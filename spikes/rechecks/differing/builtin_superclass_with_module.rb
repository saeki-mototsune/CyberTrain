# NOTES 104: `superclass` on one of Ruby's own exception classes, in a
# program that defines a module. The same program without its first line is
# ../builtin_superclass_no_module.rb, which matches CRuby.
#
#   ruby spikes/rechecks/differing/builtin_superclass_with_module.rb
#   spinel spikes/rechecks/differing/builtin_superclass_with_module.rb -O 0 -o "$TMPDIR/sc" && "$TMPDIR/sc"
#
# Linux x86_64, Spinel 2026.11.04.7026 (a2d06115, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-19. CRuby prints three lines and exits 0:
#   Pkg::Mine < ArgumentError < StandardError < Exception < Object < BasicObject
#   RuntimeError < StandardError < Exception < Object < BasicObject
#   ArgumentError < StandardError < Exception < Object < BasicObject
# The compiled program prints the first line (a class the program defines
# walks through its built-in ancestors) and then stops, exit 1, with
#   undefined method 'superclass' for module RuntimeError (NoMethodError)
# With `module Pkg; end` alone as the first line and the `Pkg::Mine` raise
# removed, it stops at once with the same message for ArgumentError.
module Pkg; class Mine < ArgumentError; end; end

def chain(kind)
  raise Pkg::Mine, "m" if kind == 0
  raise "rt" if kind == 1
  Integer("zz")
rescue StandardError => e
  names = []
  c = e.class
  while c
    names << c.name
    c = c.superclass
  end
  names.join(" < ")
end

3.times { |i| puts chain(i) }
