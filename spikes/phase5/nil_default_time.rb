# Phase 5a spike: a parameter that defaults to nil and that one caller
# gives a plain Time. A record, not a test.
#
# Found when test/client.rb passed `expires: Clock.now + 120` to
# Cookies.serialize beside its calls without `expires:`: the compiled
# program died with SIGSEGV in sp_time_utc (gdb). Reduced to this program.
#
# Run (Spinel 2026.11.04.7026, from the repository root):
#   spinel spikes/phase5/nil_default_time.rb -o "${TMPDIR:-/tmp}/nil_default_time" && "${TMPDIR:-/tmp}/nil_default_time"
# Output: nothing, then "Segmentation fault" (exit 139). CRuby prints, under
# TZ=UTC (Time.at(0) is local time: 1969 west of UTC),
#   none
#   1970
#
# What Spinel does (spinel ... -c -o x.c): the parameter is typed from the
# values its callers give, nil and a Time, as a plain Time pointer
# (`sp_Time * lv_expires`); `expires.nil?` compiles to the constant false
# (`if (((void)(lv_expires), 0))`), so the call without the argument passes
# NULL on to `sp_time_year(NULL)`.
#
# The same program with the variations below (each its own program, same
# build):
#   a positional `def stamp(expires = nil)`                 SIGSEGV
#   `expires.nil? ? "nil" : "not nil"` only                  prints "not nil" twice
#   the caller passes a String instead of a Time             works (a String
#     pointer is nullable)
#   every caller that gives the argument gives a value typed
#     "Time or nil" (`given = cond ? Time.at(0) : nil`)      works
#   a non-nil default (spikes/phase5/nil_default_time_fixed.rb) works, with
#     plain-Time, defaulted and nil callers in one program
#
# Framework exposure: Cookies.serialize(expires: nil). The framework's own
# callers were safe (SessionStore and CookieJar#delete leave it out, and
# CookieJar#assign_cookie passes `Cast.time_or_nil(...)`, typed Time or
# nil), which is why the blog (remember me on and off) never crashed; an
# application calling `Cookies.serialize(..., expires: Time.now + ...)`
# itself, in a program that also has SessionStore, would have. Fixed with
# a sentinel default (Cookies::NO_EXPIRES); test/client.rb calls it both
# ways and is the regression program.
def stamp(expires: nil)
  return "none" if expires.nil?

  expires.year.to_s
end
STDOUT.sync = true
puts stamp
puts stamp(expires: Time.at(0))
