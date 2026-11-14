# Phase 5a spike: the workaround for spikes/phase5/nil_default_time.rb.
# A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from the repository root):
#   spinel spikes/phase5/nil_default_time_fixed.rb -o "${TMPDIR:-/tmp}/fixed" && "${TMPDIR:-/tmp}/fixed"
# Output (the same under CRuby; under TZ=UTC, since Time.at(0) is local time):
#   none
#   1970
#   none
# Verdict: PASS. A non-nil sentinel default keeps the parameter's type
# right whether callers leave it out, give a plain Time or give nil.
NO_TIME = Time.at(-1).utc

def stamp(expires: NO_TIME)
  return "none" if expires.nil? || expires.to_i == -1

  expires.year.to_s
end
STDOUT.sync = true
puts stamp
puts stamp(expires: Time.at(0).utc)
given = ARGV.empty? ? nil : Time.at(0)
puts stamp(expires: given)
