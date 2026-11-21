# NOTES 122: a require-shaped line inside a regex literal is read as a
# require.
#
#   ruby spikes/rechecks/differing/require_in_regex.rb
#   spinel --strict-require spikes/rechecks/differing/require_in_regex.rb -O 0 -o "$TMPDIR/rx"
#   spinel spikes/rechecks/differing/require_in_regex.rb -O 0 -o "$TMPDIR/rx" && "$TMPDIR/rx"
#
# Linux x86_64, Spinel 2026.11.04.7026 (a2d06115, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-19. CRuby prints `db`. With --strict-require the build stops,
# exit 1:
#   spinel: cannot load such file -- cybertrain\/([\w\/]+) (require "cybertrain\/([\w\/]+)")
# Without the flag it builds with
#   warning: 'cybertrain\/([\w\/]+)' is not available in Spinel; the require is ignored and code using it will fail
# and the program prints `no match`. With `requirx` in place of `require`
# in both the String and the regex, the compiled program prints `db`.
raw = 'require "cybertrain/db"'
m = raw.match(/\A\s*require "cybertrain\/([\w\/]+)"/)
puts m ? m[1] : "no match"
