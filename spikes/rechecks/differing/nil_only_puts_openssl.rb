# NOTES 78 (docs/spinel-feedback.md K): `puts` of a String held in a
# variable, on an ivar only ever assigned nil, with the openssl package in
# the program.
#
#   ruby spikes/rechecks/differing/nil_only_puts_openssl.rb
#   spinel spikes/rechecks/differing/nil_only_puts_openssl.rb -O 0 -o "$TMPDIR/lg"
#
# Linux x86_64, Spinel 2026.11.04.7026 (a2d06115, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-19. CRuby prints `ok`. The compile fails in the C compiler:
#   error: passing argument 2 of 'sp_File_puts_bin' from incompatible pointer type
require "openssl"

class Lg
  def initialize = (@io = nil)

  def log(line)
    @io.puts(line) if @io
    nil
  end
end

Lg.new.log("hello")
puts "ok"
