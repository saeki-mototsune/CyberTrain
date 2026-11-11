# Retained compiler rechecks

These small programs retain evidence for [NOTES.md](../NOTES.md), not a
claim that their workarounds can be removed from the whole framework.
Run them explicitly; they are not part of `spin test` or the CI gate.

Recorded on 2026-11-11 against framework base `72104d7`: Linux x86_64,
Spinel `2026.11.04.7026` (`a2d06115`, GCC 14.2.0), `-O 0`, CRuby 3.3.8.
All four programs compiled and exited 0, and their output matched CRuby.
The checked-in `.expected` files are the reviewed CRuby output from that
run. No custom worker or GC-stress setting was used for these probes.

| Program | Evidence |
| --- | --- |
| `value_shapes.rb` | Rules 12/18/60: destructuring, a reopened module's class variable, NUL preservation |
| `exception_shapes.rb` | Rules 46/47/53/54: names, `is_a?`, message and hierarchy |
| `openssl_dispatch.rb` | Rule 62: one boxed String builtin call with OpenSSL |
| `decimal.rb` | Design D42: exact decimal comparisons and rounding, and Float precision loss |

From the repository root, with the pinned toolchain, CRuby and the documented
OpenSSL development libraries configured:

```sh
set -eu
spinel --version
ruby --version
probe_output=$(mktemp -d /tmp/cybertrain-rechecks.XXXXXX)
for source in spikes/rechecks/*.rb; do
  name=$(basename "$source" .rb)
  ruby "$source" > "$probe_output/$name.ruby.txt" 2>&1
  diff -u "$source.expected" "$probe_output/$name.ruby.txt"
  spinel "$source" -O 0 -o "$probe_output/$name" > "$probe_output/$name.compile.txt" 2>&1
  "$probe_output/$name" > "$probe_output/$name.spinel.txt" 2>&1
  diff -u "$source.expected" "$probe_output/$name.spinel.txt"
done
printf 'Recheck outputs: %s\n' "$probe_output"
```

Use an external job timeout for unattended runs. The recorded audit bounded
each compilation/execution at 180 seconds. A timeout or missing native library
is inconclusive; keep the diagnostics rather than calling it a language
regression. Review compile warnings even when output matches. Keep outputs
outside the package (rule 98); remove the temporary directory after inspection.
Do not automatically regenerate expectations on a mismatch.

These probes do not cover optimized builds, macOS, GC stress, all subcases of
a numbered rule, framework integration or SQLite decimal round-trips. When
using them to justify a compiler upgrade or workaround removal, add and run
the relevant integration/stress checks described in NOTES' maintenance
procedure. Retain a failing reduction as evidence even before it can become
a passing framework test.
