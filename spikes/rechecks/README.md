# Retained compiler rechecks

These small programs retain evidence for [NOTES.md](../NOTES.md), not a
claim that their workarounds can be removed from the whole framework.
Run them explicitly; they are not part of `spin test` or the CI gate.

Recorded on 2026-11-11 against framework base `72104d7`: Linux x86_64,
Spinel `2026.11.04.7026` (`a2d06115`, GCC 14.2.0), `-O 0`, CRuby 3.3.8.
All four programs compiled and exited 0, and their output matched CRuby.
The checked-in `.expected` files are the reviewed CRuby output from that
run. No custom worker or GC-stress setting was used for these probes.

`exception_shapes.rb` was then strengthened in review. It now picks the raised
class at run time and catches it with `rescue StandardError`, the shape rules
47 and 54 were seen in. All four programs were re-run with `run.sh` on Linux
x86_64, Spinel `2026.11.04.7026` (`a2d06115`, GCC 13.3.0), `-O 0` and CRuby
3.3.6. All four matched.

| Program | Evidence |
| --- | --- |
| `value_shapes.rb` | Rules 12/18/60: destructuring, a reopened module's class variable, NUL preservation |
| `exception_shapes.rb` | Rules 46/47/53/54: qualified names (including `JSON::ParserError`), `is_a?` on a superclass after `rescue StandardError`, an unraised exception's message, and the superclass chain of user-defined classes |
| `openssl_dispatch.rb` | Rule 62: one boxed String builtin call with OpenSSL |
| `decimal.rb` | Design D42: exact decimal comparisons and rounding, and Float precision loss |

Run them with the pinned toolchain, CRuby and the documented OpenSSL
development libraries configured:

```bash
spikes/rechecks/run.sh
```

The script prints its output directory first, then runs every probe even
after one fails, and exits 1 if any did. Each failure names the file that
holds its output. Each compile and each run is bounded at 180 seconds
(`RECHECK_TIMEOUT`; `gtimeout` on macOS, unbounded with a note when
neither exists). Compiler output other than the usual `src -> bin` line is
flagged as `warn`. A timeout or missing native library
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

A failing reduction does not belong in this directory as a `.rb` file,
because `run.sh` expects every program here to match CRuby. Record it in the
NOTES status table with its source inline instead, as rule 54's
`JSON::ParserError` superclass walk is.
