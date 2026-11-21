# Feedback for Spinel

This document is the one record of what Spinel does that CyberTrain has had
to know about, and of where each behaviour stands: what happens, the
program that shows it, what it did on each build tried, what is asked of
Spinel, and whether it is closed. Each behaviour is an item whose
identifier never changes: a digit (1 to 7), a letter (A to AU so far; the
next is AV) or, for a behaviour first written as a rule of spikes/NOTES.md
and never lettered, "rule N". "Item register" lists them all.

[spikes/](../spikes/README.md) is the other half and repeats none of this.
It holds the programs, and [spikes/NOTES.md](../spikes/NOTES.md), the
numbered rules that say how CyberTrain's code is written because of an
item. Each rule and each program names its item here and is kept until
that item is closed. For how the framework is written, the rule and the
code are the authority, and the "What CyberTrain does" columns here are a
summary for a reader upstream, as of their section's date. For what Spinel
does on a build, this document is the authority, and NOTES points here.

"The pin" is the present pin, 2026.11.15.7033, in three places only: "Item
register", the "On 2026.11.15.7033" table of "Status by rule" and "Written
up on 2026-11-21". Everywhere else it is the pin of the time the passage
was written, and for everything written from 2026-11-04 on that is
2026.11.04.7026, the passages dated 2026-11-15 to 2026-11-20 included: the
pin moved on 2026-11-15, but the runs those passages record used
2026.11.04.7026, and what they say of "the pin" is not all true of the
present one (Q's "re-run of 2026-11-15 on the pin" is an example: "Status
by rule", row 86 on 2026.11.15.7033).

These builds are covered, and the source of one more was read:

- **2026.09.12** (112bae85c1a2), matz/spinel's release, which CyberTrain
  was pinned to until 2026-10-26. Items 1 to 7 and the tables were found on
  it. Rebuilt from source on 2026-10-30 to measure 4 and 5 beside
  2026.10.27.7020, and to run J's program.
- **2026.10.25-7018** (0e3ccff, `spinel --version`: `unreleased
  (0e3ccffa8)`), a package of the
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) fork
  (`ghcr.io/saeki-mototsune/spinel`), checked on 2026-10-25 against
  CyberTrain 0a0d99e. `spin test` passed 88 of 98, and examples/blog did not
  get past `spin run gen`. The regressions are A to G at the end; an
  earlier package (2026.10.09-7009, edb9dd0) was checked on 2026-10-13.
- **2026.10.26.7019** (80b2f98), the fork's release tag carrying the fixes
  for A, C, F, G and 3, which CyberTrain was pinned to until 2026-10-28.
  With the
  toolchain `cybertrain setup` builds from that tag, `spin test` passes 98 of
  98 (test/template_engine.rb with its argument built where the call sees
  it, see C), and examples/blog's `spin run gen` writes files identical to
  the committed ones and its tests pass. The package
  `ghcr.io/saeki-mototsune/spinel:2026.10.26-7019`, built from the same
  commit, gave the same results.
- **matz/spinel master 9b9972399** (2026-10-28 01:58 +0900), built from
  source and checked on 2026-10-27. The fork's fixes are no longer only in
  the fork: they are merged into matz/spinel (all by SaekiMototsune, merged
  2026-10-26), #10254 (A), #10255 (B), #10256 (`OpenSSL::Digest#to_s` and
  `#hexdigest` typed), #10257 (3), #10258 and #10259 (the two shapes of C),
  #10260 (F), #10261 (the `VERSIONS` refusal under C), #10262 (G) and
  #10263 (`String#hex` and `#oct` past the word under
  `--int-overflow=promote`, see D), and #10316 ("An
  empty {} handed on through a parameter takes the Hash kind its callee
  wants", the fork's `fix/empty-hash-through-param`).
- **matz/spinel master 003ceda5d** (2026-10-28 05:13 +0900), built from
  source and checked on 2026-10-27, after the fixes for what 9b9972399
  still got wrong were merged (2026-10-27): #10415 (H), #10416 and #10417
  (the two shapes found in review). H's two programs and the three PRs'
  tests print Ruby's result there, and so do the reduced programs of 3, A,
  F and G; D's still raises `RangeError` in the default mode, by design.
  Items not listed were not re-checked on it.
- **2026.10.27.7020** (d37f38a), the fork's release tag carrying matz/spinel
  master up to #10415 to #10417, which CyberTrain was pinned to from
  2026-10-28 until 2026-11-03. With the toolchain `cybertrain setup` builds from that tag,
  `spin test` passes 106 of 106 (checked on 2026-10-28), including
  test/db_with_value.rb's use of a DB.with block's own value, which H made
  raise on 2026.10.26.7019 (issue #90). Items 4 and 5 were re-measured on
  it on 2026-10-30 (see "Runtime cost"): 4 is fixed, and J was found on it.
- **fork master 49ccdced** (2026-10-30, "Merge branch 'matz:master'"),
  built from source and checked on 2026-10-30. It does not build CyberTrain
  (I, new; bisected to matz/spinel#10527); a minimal keep-alive server
  built with it gives 4 the same counts as 2026.10.27.7020, and J's program
  fails on it as on 2026.10.27.7020. Nothing else was checked on it.
- **2026.11.04.7026** (a2d06115f, `spinel 2026.11.04.7026 (a2d06115)`),
  the fork's release tag carrying matz/spinel master up to #10959, and the
  build CyberTrain was pinned to from 2026-11-04 to 2026-11-15
  (CyberTrain 0.4.1).
  It carries #10525 (the refusal under C) and #10524 (the run-time
  `TypeError` beside it), and #10735 and #10786 (I). Checked on 2026-11-04 with the toolchain `cybertrain setup`
  builds from that tag: `spin test` passes 106 of 106; examples/blog's
  `spin run gen` writes files identical to the committed ones, `spin build
  blog` builds it, and its tests pass; the reduced programs of 3, A, C, F,
  G, H and I print Ruby's result; J's program fails as on 2026.10.27.7020.
  Re-checked on 2026-11-05 for regressions against the pin before it:
  2026.10.27.7020 and 2026.11.03.7025 (built from source), and
  2026.11.04.7026 (the prebuilt tree) side by side on one 4-vCPU VM, all building the
  same CyberTrain source (ae195f4). `spin test` passes 106 of 106 on
  2026.11.04.7026 there too, examples/blog's `spin run gen` writes
  identical files and its tests pass, and examples/blog built by each of
  the three serves the same requests a second, CPU per request, objects
  per request, collections, `futex` calls and peak RSS within the spread
  between runs ("Re-checked side by side" under "Runtime cost"). Nothing
  found is new in 2026.11.04.7026: L (an explicit `SPINEL_WORKERS=N`
  counts the main thread) is on 2026.10.27.7020 and 2026.11.03.7025 as
  well, and rule 79's compile failure is too (see "Rule 79"). The release
  before it, 2026.11.03.7025
  (25d8038d4, CyberTrain 0.4.0, pinned 2026-11-03 to 2026-11-04), carries
  the same four PRs and was not checked on its own until 2026-11-05.
  Still the pin on 2026-11-11, when the programs of spikes/NOTES.md
  rules 66, 70, 81, 82 and 88 were run on it (see "Re-checked on
  2026-11-11"): the fork has no release after it, and its master
  (da8d4ba8, 2026-11-05) is one commit past the tag.
- **matz/spinel master 494deaac** (2026-11-12 01:25 +0900), read on
  2026-11-11 and **not built**: its history since 2026-11-04, its tests
  and its docs/thread.md and docs/limitations.md were searched for every
  open item. Where this document says "fixed on master" with this
  commit, it means the fixing commit and its test are there and the
  test's program is the one given here; nothing was compiled or run with
  it for that reading. It was built once after that, on 2026-11-12, as
  the base of the pull requests for Q, R and S: Q's first program, R's
  first two and S's were run on it and answered as on the pin, except
  that nothing raised at construction (Q's String Range was matched
  there; a re-run on 2026-11-15 found it matched on the pin as well, see
  Q).
  Those runs are named where they are used (the Q, R and S rows of "What
  can go upstream" and the Q and R sections); every other mention of
  494deaac is the reading. It is in no fork tag.
- **matz/spinel master 1c0cc5e35** (2026-11-12 18:40 +0900), built from
  source on macOS arm64 on 2026-11-13 to run the reduced programs of the open
  items, and nothing else: CyberTrain was not built with it, `spin test`
  was not run, and it is in no fork tag. It carries the fixes sent from
  this project and merged on 2026-11-12:
  #11639 (Q, the Float half), #11643 (S), #11646 (5 (b)), #11650 (R) and
  #11683 (U). The programs of K, N, Q, R (all three), S, T, U and rule 79
  print CRuby's result on it; Y's and Z's fail as on the pin; M's, O's,
  P's and J's were not run (see "What is asked of Spinel now").
- **2026.11.15.7033** (a2f3bfaaf), the fork's release tag CyberTrain is
  pinned to since 2026-11-15 (`Cybertrain::SPINEL_TAG`,
  `Cybertrain::SPINEL_REPOSITORY`). What was run on it, on 2026.11.14.7031
  and on 2026.11.15.7032, and why those two were not pinned, is under
  "Status by rule", "On 2026.11.15.7033". Apart from the three places
  named above, the sections below were not brought up to it, whatever
  their date.

2026.11.04.7026, the pin at the time, was used once more on 2026-11-13,
for the inventory below: forty small programs built with it on Linux x86_64
(`spinel prog.rb -o prog`, gcc 13.3.0) and run beside CRuby 3.3.6, and
examples/blog's program of main 34c9b7e written out as C. Nothing else
was built for it: `spin test` was not run, and no other build was tried.

The programs are under [spikes/](../spikes/README.md); the rules the
framework follows are in [spikes/NOTES.md](../spikes/NOTES.md); the
measurements are in [benchmark.md](benchmark.md) and
[performance-next.md](performance-next.md).

## Item register

One row per item, with where it stands on the pinned build. An item is a
digit, a letter or "rule N", as the top of this document says; the "Rules"
column gives the rules of spikes/NOTES.md that exist because of it. Which
program shows an item is in the READMEs under
[spikes/](../spikes/README.md), not here.

An item is **closed** by one pull request of its own that does these three
things together, and the row then names the date, the pull request and
the test:

1. it removes the workaround from the framework and names a compiled test
   (`test/`) of the framework's own shape written the plain way, or the
   row says the item never had a workaround;
2. it sets the last line of each of the item's rules in spikes/NOTES.md to
   "Closed (docs/spinel-feedback.md X): kept for its number.";
3. it sets the item's row here to `closed`.

It can do so once the item's program prints CRuby's result on the pinned
build ("Status by rule" names the program and the run), or once the item
is withdrawn as not a Spinel behaviour. Until then "passes on the pin" is
not closed: a passing probe is not a licence to drop an active workaround
(spikes/NOTES.md, "Maintaining this inventory"). Items of kind
"constraint" and "refusal by design" (how Spinel is; nothing is asked) and
the records that are not Spinel items are never closed, and their rules
are permanent.

Once an item is closed, that pull request or a later one may delete the
item's programs under spikes/ and cut the body of its rule in
spikes/NOTES.md down to the "Closed" line, after rewriting every comment
under cybertrain/, test/, script/, docs/ and examples/ that gives "rule N"
as a present reason. The rule number and the item's identifier are never
reused, and the item's section here stays as the record.

The rows closed before 2026-11-21 were closed by the pin moving to a build
with the fix; "Closed by" names that build, and the test where there is
one.

Kinds: **bug** (differs from CRuby or stops a build, and is not by
design), **cost** (time or memory, not a wrong result), **refusal by
design**, **constraint** (how Spinel or its tools are) and **record** (not
a Spinel item: ordinary Ruby, a form that works, a measurement or advice
on writing tests, kept in spikes/NOTES.md as a rule the code cites).

States:

- `open`: a program that stands on its own differs from CRuby on the pin,
  or does not compile there.
- `open, not reduced`: seen in the framework only; on the pin it is
  covered by `spin test` and examples/blog, with the workaround in place.
- `fixed upstream, not in the pin`.
- `passes on the pin, workaround kept`: the item's reduced program prints
  CRuby's result on the pin, and the framework is still written around
  it.
- `passes on the pin, no workaround left`: the same, and nothing in the
  framework is written around it any more. These are the candidates for a
  closing pull request: rule 79, and rules 33 and 61.
- `probe matches on the pin`: for a "rule N" item that was never reduced,
  its section of a saved program printed CRuby's output when
  `spikes/rechecks/run.sh` was run on the pin (Linux x86_64, 2026-11-21;
  the last row of "Status by rule", "On 2026.11.15.7033"). This does not
  show that the behaviour is gone.
- `not re-checked on the pin (last: ...)`: nobody has tried it on the pin;
  the last recorded state and its build follow. Not a claim either way.
- `closed`, as defined above.
- `settled`: a constraint, a refusal by design or a record; nothing is
  asked and nothing is re-checked.

"(status N)" is row N of "Status by rule", "On 2026.11.15.7033", unless
the cell names another build.

| Item | Kind | Rules | State on the pin (2026.11.15.7033) | Closed by |
| --- | --- | --- | --- | --- |
| 1 | constraint | 58, 65 | settled: accepted on 2026-10-28 ("Accepted as Spinel constraints"); not re-checked on the pin |  |
| 2 | bug | 56 | closed; the callers' `x.to_s` stays as rule 56's guidance for speed | 2026.10.27.7020: `Html.escape`'s `case` is dropped; 106 of 106 tests and examples/blog pass without it |
| 3 | bug |  | closed | 2026.10.26.7019 (#10257); never had a workaround |
| 4 | cost |  | closed | 2026.10.27.7020 (#8702, #10024); never had a workaround |
| 5 (a) | cost |  | not re-checked on the pin (last: open, 83% of collections full on 2026.11.04.7026, 2026-11-05) |  |
| 5 (b) | cost |  | not re-checked on the pin (last: fixed on matz/spinel master, #11646, in no fork tag on 2026-11-13) |  |
| 6 | cost |  | not re-checked on the pin (last: jemalloc measured on 2026.11.04.7026, section 2 of "Everything on main") |  |
| 7 | cost | 57 | not re-checked on the pin (last: not seen since the lock left the request path; not retried since 2026.09.12) |  |
| A | bug |  | closed | 2026.10.26.7019 (#10254); never had a workaround |
| B | constraint | 59 | settled: accepted on 2026-10-28 ("Accepted as Spinel constraints") |  |
| C | bug |  | closed | 2026.10.26.7019 (#10258, #10259) and, for the refusal under it, 2026.11.04.7026 (#10525, #10524): test/template_engine.rb is back in its earlier form |
| D | constraint | 25 | settled: by design; still raises RangeError on the pin (status 25) |  |
| E | cost |  | not re-checked on the pin (last: no change against 2026.10.27.7020 on 2026.11.04.7026, 2026-11-05) |  |
| F | bug |  | closed | 2026.10.26.7019 (#10260); never had a workaround |
| G | bug |  | closed | 2026.10.26.7019 (#10262); never had a workaround |
| H | bug | 77 | closed | 2026.10.27.7020 (#10415); test/db_with_value.rb covers the plain form. The body of rule 77 is not cut yet |
| I | bug |  | closed | 2026.11.04.7026 (#10735, #10786); never had a workaround |
| J | bug |  | not re-checked on the pin (last: fails with `SPINEL_GC_SLAB=0` on 2026.11.04.7026, 3 runs of 3; the default is unknown) |  |
| K | bug | 78 | passes on the pin, workaround kept (status 78) |  |
| L | constraint | 22 | settled: documented upstream (da4485a5) |  |
| M | bug | 83 | passes on the pin, workaround kept (status 83) |  |
| N | bug |  | not re-checked on the pin (last: fails on 2026.11.04.7026; fixed on matz/spinel master, #11184 and #11219); no workaround in the framework (Daicho's `n.to_i`) |  |
| O | bug | 72 | not re-checked on the pin (last: `connect_timeout:` ignored on 2026.11.04.7026, 2026-11-19; fixed on matz/spinel master, #11183) |  |
| P | bug |  | not re-checked on the pin (last: does not return on 2026.11.04.7026; fixed on matz/spinel master, dcc46945c) |  |
| Q | bug | 86 | passes on the pin, workaround kept (status 86) |  |
| R | bug | 70, 81, 89 | passes on the pin for 81 and 89, workaround kept (status 81 and 89); 70's aliased name was not re-run |  |
| S | bug | 90 | passes on the pin, workaround kept (status 90) |  |
| T | bug | 91 | passes on the pin, workaround kept (status 91) |  |
| U | bug | 93 | passes on the pin, workaround kept (status 93) |  |
| V | bug | 96 | open, not reduced (status 96) |  |
| W | bug | 97 | open, not reduced (status 97) |  |
| X | bug | 94 | open, not reduced (status 94) |  |
| Y | bug | 82 | passes on the pin, workaround kept (status 82) |  |
| Z | bug | 88 (111 narrows it) | passes on the pin, workaround kept (status 88) |  |
| AA | cost |  | not re-checked on the pin (last: in the generated C of main on 2026.11.04.7026, 2026-11-13; not reduced) |  |
| AB | bug | 80 | open (status 80: `blocking: true` and no option still hold the worker; the pin adds `offload: true`) |  |
| AC | bug | 49 | passes on the pin, workaround kept (status 49) |  |
| AD | bug | 52 | passes on the pin, workaround kept (status 52: `byteindex`; `strip` is AU) |  |
| AE | bug | 47, 53, 54 | passes on the pin, workaround kept (status 54; 47 and 53 match in rechecks/exception_shapes.rb) |  |
| AF | bug | 100 | passes on the pin, workaround kept (status 100) |  |
| AG | bug |  | not re-checked on the pin (last: fails on 2026.11.04.7026, 2026-11-13) |  |
| AH | bug |  | no workaround and no rule; not re-checked on the pin as a program; the difference recorded was with CRuby 3.3, and CRuby 4.0.7 writes these Floats as Spinel does (status 100) |  |
| AI | cost | 101 | open (status 101: still one C function; the time was not reproduced on macOS) |  |
| AJ | bug | 104 | passes on the pin, workaround kept (status 104) |  |
| AK | cost |  | not re-checked on the pin (last: seen on 2026.11.04.7026, 2026-11-12) |  |
| AL | cost | 108 | not re-checked on the pin (last: seen on 2026.11.04.7026, 2026-11-12) |  |
| AM | bug | 107 | open (status 107) |  |
| AN | bug | 109 | passes on the pin, workaround kept (status 109) |  |
| AO | bug | 110 | open (status 110) |  |
| AP | bug | 117 | passes on the pin, workaround kept (status 117) |  |
| AQ | bug | 116 | open (status 116) |  |
| AR | bug | 122 | open (status 122) |  |
| AS | bug | 123 | open, not reduced (status 123) |  |
| AT | bug | 112 | open (status 112) |  |
| AU | bug | 52 | open (status 52) |  |
| rule 1 | constraint | 1 | settled (1.4: no run-time code); the probes of a computed `send` and of reflection with a non-literal name match on the pin (rechecks/dispatch_shapes.rb) |  |
| rule 2 | constraint | 2 | settled (1.4); a stored block handed to `instance_exec` still raises when reached on the pin (status 2) |  |
| rule 3 | bug | 3 | probe matches on the pin (rechecks/dispatch_shapes.rb), workaround kept |  |
| rule 4 | bug | 4 | probe matches on the pin (rechecks/dispatch_shapes.rb), workaround kept |  |
| rule 5 | constraint | 5 | settled (1.4: one static return type per method) |  |
| rule 6 | bug | 6 | probe matches on the pin (rechecks/dispatch_shapes.rb), workaround kept |  |
| rule 7 | bug | 7 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 8 | bug | 8 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept; retired in part on 2026-11-15 (1.5) |  |
| rule 9 | bug | 9 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 10 | bug | 10 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 11 | cost | 11 | the probe's output matches on the pin (rechecks/type_shapes.rb); the cost the rule is about was not looked at on the pin |  |
| rule 12 | bug | 12 | probe matches on the pin (rechecks/value_shapes.rb), workaround kept |  |
| rule 13 | record | 13 | settled: ordinary Ruby (1.4) |  |
| rule 14 | bug | 14 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 15 | bug | 15 | not re-checked on the pin (last: seen on 2026.09.12 and not tried since) |  |
| rule 16 | record | 16 | settled: ordinary Ruby (1.4) |  |
| rule 17 | bug | 17 | open (status 17): a class used above its definition runs compiled where CRuby raises NameError. A constant assigned with `=` and read before its assignment raises NameError as under CRuby (rechecks/constant_order.rb matches on the pin). Nothing in the framework is written around it: the rule's advice is to keep an order CRuby accepts |  |
| rule 18 | bug | 18 | probe matches on the pin (rechecks/value_shapes.rb), workaround kept |  |
| rule 19 | bug | 19 | probe matches on the pin (rechecks/io_shapes.rb), workaround kept |  |
| rule 20 | bug | 20 | probe matches on the pin (rechecks/socket_bare_readpartial.rb), workaround kept either way: its nil return is the idle timeout |  |
| rule 21 | bug | 21 | probe matches on the pin (rechecks/socket_shapes.rb), workaround kept |  |
| rule 23 | constraint | 23 | settled (1.4: tests) |  |
| rule 24 | constraint | 24 | settled (1.4: tests) |  |
| rule 26 | bug | 26 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 27 | bug | 27 | passes on the pin for `IO#gets` on a socket, which answers a byte String as CRuby does (status 27; Linux, 2026-11-21), and `readpartial`, `read(n)` and `read_nonblock` match on the pin (rechecks/socket_shapes.rb); open for an append of socket bytes to a UTF-8 String that holds non-ASCII, which appends where CRuby raises (status 27). Framing by byte is kept: it is right under both runtimes |  |
| rule 28 | bug | 28 | probe matches on the pin (rechecks/io_shapes.rb), workaround kept |  |
| rule 29 | bug | 29 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 30 | bug | 30 | probe matches on the pin (rechecks/dispatch_shapes.rb), workaround kept |  |
| rule 31 | bug | 31 | probe matches on the pin (rechecks/dispatch_shapes.rb), workaround kept |  |
| rule 32 | bug | 32 | probe matches on the pin (rechecks/rescue_shapes.rb), workaround kept |  |
| rule 33 | bug | 33 | probe matches on the pin (rechecks/json_error_shapes.rb), no workaround left: the three-class clause is gone from `cybertrain/` since 2026-11-20 (status 33 on 2026.11.04.7026); `Cast.parse_json` still names the two JSON classes |  |
| rule 34 | bug | 34 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 35 | bug | 35 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 36 | bug | 36 | not re-checked on the pin (last: a probe of the one recorded shape passes on 2026.11.04.7026, 2026-11-19; never reduced) |  |
| rule 37 | cost | 37 | the probe's output matches on the pin (rechecks/type_shapes.rb); the cost the rule is about was not looked at on the pin |  |
| rule 38 | record | 38 | settled: ordinary Ruby (1.4) |  |
| rule 39 | bug | 39 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 40 | bug | 40 | probe matches on the pin (rechecks/dispatch_shapes.rb), workaround kept |  |
| rule 41 | bug | 41 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 42 | bug | 42 | probe matches on the pin (rechecks/dispatch_shapes.rb), workaround kept |  |
| rule 43 | bug | 43 | probe matches on the pin (rechecks/type_shapes.rb), workaround kept |  |
| rule 44 | bug | 44 | probe matches on the pin (rechecks/rescue_shapes.rb), workaround kept |  |
| rule 45 | bug | 45 | probe matches on the pin (rechecks/rescue_shapes.rb), workaround kept |  |
| rule 46 | bug | 46 | probe matches on the pin (rechecks/exception_shapes.rb and rechecks/type_shapes.rb), workaround kept; the depth at which nested renders overflow a thread stack was not re-measured |  |
| rule 48 | bug | 48 | probe matches on the pin (rechecks/json_error_shapes.rb); never had a workaround, only the statement that an application cannot register `rescue_from JSON::ParserError` |  |
| rule 50 | bug | 50 | probe matches on the pin (rechecks/rescue_shapes.rb), workaround kept |  |
| rule 51 | bug | 51 | probe matches on the pin (rechecks/container_shapes.rb), workaround kept |  |
| rule 55 | bug | 55 | probe matches on the pin (rechecks/container_shapes.rb), workaround kept |  |
| rule 60 | bug | 60 | probe matches on the pin (rechecks/value_shapes.rb), workaround kept |  |
| rule 61 | bug | 61 | probe matches on the pin (rechecks/json_error_shapes.rb and rechecks/json_nesting_shapes.rb), no workaround left: retired as a clause with 33 |  |
| rule 62 | bug | 62 | probe matches on the pin (rechecks/openssl_dispatch.rb), workaround kept |  |
| rule 63 | bug | 63 | not re-checked on the pin (last: seen on 2026.09.12 and not tried since) |  |
| rule 64 | bug | 64 | not re-checked on the pin (last: marked as a GC root on 2026.11.04.7026 in the shape checked) |  |
| rule 66 | bug | 66 | not re-checked on the pin (last: the buffer-append program passes on 2026.11.04.7026; the `name` collision was not re-checked) |  |
| rule 67 | bug | 67 | not re-checked on the pin (last: probe passes on 2026.11.04.7026) |  |
| rule 68 | bug | 68 | not re-checked on the pin (last: probe passes on 2026.11.04.7026) |  |
| rule 69 | bug | 69 | probe matches on the pin (rechecks/block_call_shapes.rb), workaround kept |  |
| rule 71 | bug | 71 | not re-checked on the pin (last: as recorded on 2026.11.04.7026, 2026-11-15: an inference fact, not a miscompile) |  |
| rule 72 | bug | 72 | probe matches on the pin for the parts in rechecks/outbound_socket_shapes.rb (Linux), workaround kept; `Socket#bind(sockaddr)` and the openssl package notes were not tried since 2026.09.12; `connect_timeout:` is O |  |
| rule 73 | bug | 73 | not re-checked on the pin (last: reduced program passes on 2026.11.04.7026) |  |
| rule 74 | bug | 74 | not re-checked on the pin (last: reduced program passes on 2026.11.04.7026) |  |
| rule 75 | bug | 75 | closed | 2026.11.04.7026: `Process.spawn` and `Process.wait` work; test/rate_limit_store.rb uses them. The body of rule 75 is not cut yet |
| rule 76 | constraint | 76 | settled (1.4: a constant resolves as in CRuby) |  |
| rule 79 | bug | 79 | passes on the pin, no workaround left (status 79): nothing in the framework worked around it |  |
| rule 84 | refusal by design | 84 | settled ("A refusal of a never-reached class-method call") |  |
| rule 85 | record | 85 | settled: a form that works (1.4) |  |
| rule 87 | record | 87 | settled: a form that works (1.4) |  |
| rule 92 | refusal by design | 92 | settled ("A refusal inside a block that never runs"); on the pin the program whose `included` drops its block builds, and the one that keeps it is still refused (status 92) |  |
| rule 95 | record | 95 | settled: a form that works (1.4) |  |
| rule 98 | constraint | 98 | settled (1.4: tool behaviour) |  |
| rule 99 | record | 99 | settled: ordinary Ruby (1.4) |  |
| rule 102 | record | 102 | settled: a form that works (1.4) |  |
| rule 103 | record | 103 | settled: a form that works (1.4) |  |
| rule 105 | constraint | 105 | settled (1.4: compiler behaviour, the instance-method counterpart of rule 84) |  |
| rule 106 | record | 106 | settled: a form that works (1.4) |  |
| rule 111 | record | 111 | settled: a form that works (1.4); it narrows Z |  |
| rule 113 | record | 113 | settled: a form that works (1.4) |  |
| rule 114 | constraint | 114 | settled (1.4: how green threads are scheduled at one worker) |  |
| rule 115 | record | 115 | settled: a measurement (1.4) |  |
| rule 118 | record | 118 | settled: how a thread test is written (1.4) |  |
| rule 119 | record | 119 | settled: a form that works (1.4) |  |
| rule 120 | constraint | 120 | settled (1.4: tool behaviour, spin's freshness check) |  |
| rule 121 | record | 121 | settled: a form that works (1.4) |  |

## Everything on main, in one place

The pin of this section is 2026.11.04.7026, the pin when it was written.
Where an item stands on the present pin is in "Item register".

Written on 2026-11-13 against main 34c9b7e (cybertrain 0.4.1, pinned to
Spinel 2026.11.04.7026). The sections after this one are in the order
things were found. This one is the index by what a reader asks:

1. what CyberTrain does today because of something Spinel does;
2. what a change in Spinel would give CyberTrain in speed;
3. every Spinel bug known here, and where it stands.

It was put together from the rest of this document, the hundred rules of
spikes/NOTES.md, performance-next.md, benchmark.md, design.md, and every
comment in `cybertrain/`, `test/`, `script/` and `examples/` that names
Spinel, so it also holds what had only ever been a comment in the code.
Each named workaround was looked for in main's source and is there.

Three words are used for the pin's state, close to those of "Status by
rule":

- **fails**: a program that stands on its own differs from CRuby on the
  pin. "(2026-11-13)" marks one run for this inventory; its program is
  under "Written up on 2026-11-13" or under the item's letter.
- **probe passes (2026-11-13)**: a program of a few lines, of the shape
  the rule or the comment describes, printed CRuby's result on the pin.
  The behaviour was first seen in a larger program, so this does not show
  it is gone, and no workaround was removed for it. The table under
  "Written up on 2026-11-13" has each program's shape.
- **not re-checked**: nobody has tried it on the pin. Not a claim either
  way.

Letters are the items of this document (AA to AH are new, written up
under "Written up on 2026-11-13"; AI, phase 4b's, AJ to AO, phase 5a's,
AP and AQ, phase 5b's, AR, the follow-ups', and AS, found in the clean-up
of 2026-11-15, were merged in after the inventory); numbers after "rule"
are spikes/NOTES.md's.

The items stand where they were found, so the letters do not run in order
through the document. 1 to 3 are under "Correctness" and 4 to 7 under
"Runtime cost"; A to J and L under "Regressions in newer packages"; K, M
and rules 64, 65 and 79 under "From spikes/NOTES.md, not written up
before"; N, O and P under "Found by Daicho"; Q, then R to T, then U to X
under the sections of phases 2, 3 and 4a; Y and Z under "Re-checked on
2026-11-11"; AA to AH under "Written up on 2026-11-13"; AI, AJ to AO, AP
and AQ, and AR under the sections of phases 4b, 5a and 5b and the phase 5b
follow-ups; AS under "Found in the clean-up of 2026-11-15"; AT and AU,
written up from rules 112 and 52 on 2026-11-21, are the last section.

### 1. What CyberTrain does today because of Spinel

#### 1.1 Needed on the pin: the behaviour is confirmed there

"The pin" here is 2026.11.04.7026. On 2026.11.15.7033 the reduced programs
of K, rule 79, M, Q, R, S, T, U, Y, Z, AC, AD, AE, AF, AJ, AN and AP print
CRuby's result; "Item register" has the state of every row.

| Item | What Spinel does | What CyberTrain does about it, and where | Upstream |
| --- | --- | --- | --- |
| Z (rule 88) | A stored block called with a base-class receiver runs the base class's method, not the subclass's override, when the block stands before the override's `def` in the subclass body | No method that only stored blocks call has a stub on its base class (the generated `counter_cache_*`, a job's `run_job`); `respond_to`, `content_security_policy` and the Turbo Stream builder run their block at once instead of storing it (format_collector.rb, controller.rb, template/turbo_stream_builder.rb, generator/jobs_emitter.rb, mailer/later.rb) | Open: fails on master 1c0cc5e35 too; not reported |
| Y (rule 82) | A lambda literal written into a module-body ivar keeps Integer parameters, and is called with garbage | Every lambda kept in module state comes from a method: `Views.default_url_resolver`, `Views.default_helpers_builder`, `Views.default_component_builder` and `Assets.empty_resolver` (views.rb, assets.rb) | Open: fails on master 1c0cc5e35 too; not reported |
| S (rule 90) | A `yield` passed as an argument runs the block twice when blocks differ in type | `computed = yield` before the cast in `Cache.fetch`, `fetch_hash`, `fetch_array` and `fetch_int` (cache.rb) | Fixed, matz/spinel#11643; in no fork tag |
| R (rules 81, 89; 70) | A `rescue` arm Spinel cannot resolve matches by its last segment, or the whole `begin` swallows the exception | A rescued class is spelt from the top (`rescue Cybertrain::Template::SyntaxError`, console.rb); the generated `run_job` names only classes the program defines (generator/job_scan.rb, jobs_emitter.rb); the "uninitialized constant" warning on a `rescue` line is treated as an error | Fixed, #11650 (and #11689, #11690); in no fork tag |
| U (rule 93) | A `def` inside a block that never runs defines the method on the code around it | gen writes a concern's `class_methods` as `def self.x` plus a forwarder and refuses a name an instance method already has (`ConcernScan::RULE_93`, generator/concern_scan.rb, concerns_emitter.rb) | Fixed, #11683; in no fork tag |
| Rule 92 | A block that never runs is compiled, and an implicit-self call in it is refused | `ActiveSupport::Concern` defines a no-op for each declaration (active_support.rb); gen loads each concern from a copy in `gen/concerns/` with its `included` and `class_methods` blocks blanked (generator/concerns_emitter.rb, D60) | By design; nothing asked |
| V (rule 96) | `strftime` with a pattern built at run time returns the pattern | `Strftime.walk` calls `strftime` with a literal per directive, for `time_tag`'s `format:` and `I18n.l` (strftime.rb; `Template::Helpers.time_tag_strftime`) | Open; not reduced, not reported |
| W (rule 97) | An ivar String passed to a stored lambda is refused | `Component` passes `"#{@name}"`, a fresh local (component.rb) | Open; not reduced, not reported |
| X (rule 94) | Type inference does not converge in examples/blog's generator | Each emitter scans `app/controllers` for itself (`Runner.controllers_source`, `concerns_source`, generator/runner.rb) | Open; not reduced, not reported |
| Q (rule 86) | A Range holds Integer ends only: Time and Date ends raise, a boxed Float Range is not a Range | `where(col: a..b)` takes Integer ends and other bounds go through `where_between`; `inclusion:` / `exclusion:` take an Integer Range or an Array (relation.rb, validator.rb, model.rb) | Fixed, #10998 and #11639; in no fork tag |
| T (rule 91) | `exit` on a thread other than main ends only that thread | The feed supervisor sets `Background.feeds_failed?` and the `feeds` role's main thread returns the status (background/supervisor.rb, roles/feeds.rb) | Fixed on master; in no fork tag |
| K (rule 78) | `puts` on a nil-only receiver does not compile with the TLS layer in the program | `Logger#write_now` calls `@io.write` (logger.rb) | Fixed, #11129; in no fork tag |
| M (rule 83) | `gets` on STDIN does not show a partial STDOUT line first | `Console.run` flushes after the banner and every prompt (console.rb) | Fixed, #11193; in no fork tag |
| O (rule 72) | `TCPSocket.new` ignores `connect_timeout:` | `Net::TcpStream` connects with `connect_nonblock`, `wait_writable` and `SO_ERROR` (net/socket.rb); kept after a fix, for the deadline | Fixed, #11183; in no fork tag |
| P | Net::HTTP's TLS handshake and reads are not bounded by its timeouts | `HttpClient` does the handshake and every read itself, with bounded waits (http_client.rb, net/tls.rb); kept after a fix | Fixed, dcc46945c; in no fork tag |
| L (rule 22) | An explicit `SPINEL_WORKERS=N` counts main, which a server keeps waiting | `Application.spinel_workers` hands Spinel `workers + 1` above 1 (application.rb; roles/server.rb, roles/worker.rb, roles/feeds.rb) | Documented upstream (da4485a5): how Spinel is used |
| 5 (a) | At one worker 83% of collections are full | `SPINEL_GC_FULL_INTERVAL=8` in the Dockerfile `cybertrain new` writes (cli/templates.rb), in examples/blog/Dockerfile and in docs/deploy.md and deploy.en.md | Open; the change is described under 5, not written |
| Rule 79 | A rescuing method's value does not compile when its block only raises | Nothing in the framework; a test gives the block a value after the `raise` | Fixed, #11137; in no fork tag |
| AB (rule 80) | A foreign call holds its OS worker for as long as it runs, with or without `blocking: true`: fails (2026-11-13) | SQLite's busy handler reports instead of sleeping, and `Connection#step_waiting` / `#exec_waiting` retry after a green-thread `sleep` (db/sqlite_ffi.rb, db/connection.rb); the guides tell an application to run heavy SQLite work in its own binary with `system`; names are resolved once per request (net/socket.rb) | Open; not reported |
| AC (rule 49) | `URI.decode_www_form_component` is quadratic on non-ASCII text: fails (2026-11-13) | `Query.decode` copies the text between escapes by byte and hands the library only ASCII runs of `%XX` (http/query.rb; http/request.rb for a path) | Open; not reported |
| AD (rule 52) | `String#byteindex` accepts an offset inside a character: fails (2026-11-13) | `Query.utf8!` validates request text once, up front, and an invalid sequence is `QueryMalformed`, a 400; nothing rescues `IndexError` (http/query.rb, http/request.rb, http/cookies.rb) | Open; not reported |
| AE (rule 54; 47, 53) | `Class#superclass` on a package's exception class is NoMethodError: fails (2026-11-13) | Client faults are listed by full name in `ClientError::CLIENT_FAULTS`, and `script/check-client-faults` keeps the list complete under CRuby in CI (http/client_error.rb) | Open; not reported. The reduced programs of 47 and 53 pass, and `Class#name` carries the namespace on the pin (46) |
| AF (rule 100) | `Float#round(n)` on a Float narrowed by a `case` rounds the binary product: fails (2026-11-13) | `Cast.round_digits` rounds on the digits of `Float#to_s`, and `NumberHelper` never calls `Float#round` (cast.rb, number_helper.rb; D73) | Open; not reported |
| AG | `TCPServer.new` on a port in use raises `Errno::ECONNREFUSED`: fails (2026-11-13); a privileged port refused to a non-root user raised the same class | `Server#bind_listener` turns both into `PortInUse`, and `privileged_denied?` tells them apart by the port number and the user (http/server.rb) | Open; not reported |
| AA | A method that holds a block allocates a heap cell for each captured local when it is entered | `while` loops in `Interpreter#eval_expr` and `Helpers#nested_url`, and `Response#respell_header` as a method of its own (template/interpreter.rb, template/helpers.rb, http/response.rb) | Open; not reduced, not reported |
| AI (rule 101) | A large Hash literal constant is one long C function that cc takes some 13 s to build (a cost, not a wrong result) | gen/locales.rb and cybertrain/locales/bundled.rb fill their Hash through methods of at most 50 stores (generator/locales_emitter.rb, phase 4b) | Not reported |
| AJ (rule 104) | `Class#superclass` on Ruby's own exception classes is NoMethodError once the program requires json, uri or stringio, or defines a module: fails (2026-11-15; the same lines alone pass) | `assert_raises(Class)` reads the chain above the first built-in class from `Test::BUILTIN_PARENTS` (test/assertions.rb, phase 5a) | Open; not reported |
| AK | The C of a very large program (87.6 MB, 196 test programs bundled) needs more than 9.7 GB to compile at -O2 (a cost, not a wrong result) | The framework's suite stays one program per file; only applications bundle their tests (`cybertrain test`, D83) | Not reported |
| AL (rule 108) | `spin run gen` rebuilds `bin/gen` when any `.rb` of the package is newer, test files included (spin, a cost) | Accepted: `cybertrain test` pays about 55 s on each edit of a test | Not reported |
| AM (rule 107) | A release build's `e.backtrace` is empty; only `--debug` gives frames | A failing test is named by its `test` line; reports carry class, message and where | Open; not reported |
| AN (rule 109) | A parameter defaulting to nil that a caller gives a plain Time is compiled as a non-nullable Time; the defaulted call crashes (SIGSEGV): fails (2026-11-13) | `Cookies.serialize`'s `expires:` defaults to the sentinel `Cookies::NO_EXPIRES`; framework callers pass `Cast.time_or_nil(...)` (http/cookies.rb, phase 5a) | Open; not reported |
| AO (rule 110) | A statement `case` on a plain Integer, compiled after a statement `case` on a nullable Integer in another method, can take its temporary number and not compile (`'_oN' undeclared`): fails (2026-11-13) | `HtmlReader.parse` uses an `if` chain; shared framework code avoids statement `case` on a plain Integer (cybertrain/test/html_reader.rb) | Open; not reported |
| AP (rule 117) | `pop(timeout:)` on a Queue that was put in an Array is compiled as `Array#pop`: fails (2026-11-14) | No Queue is kept in an Array; a test passes each Queue as a local or a parameter (test/logger_scope.rb) | Open; not reported |
| AQ (rule 116) | Threads on several workers writing one StringIO with no lock corrupt the heap: fails (2026-11-14) | Every Logger writes under `Logger::LOCK` (logger.rb; test/logger_threads.rb) | Open; not reported |
| AR (rule 122) | A regex literal holding a require-shaped text is read as a require; without `--strict-require` it is dropped with a warning: fails (2026-11-15) | A program that scans source for requires builds the keyword from pieces (test/gen_jobs.rb's `core_closure`) | Open; not reported |
| AS (rule 123) | `ENV[name]` with a key held in a variable answers the key in a program that requires two framework files: fails (2026-11-15) | Nothing; the four reads with such a key (config.rb, dev/supervision.rb) stay, `Config.env_or` answered the value in the programs tried that require `cybertrain/core`, and no new one is added | Open; not reduced, not reported |

#### 1.2 Kept, though a small program of the shape now passes on the pin

Candidates for a pull request each, which has to show the framework's own
shape passing without the workaround (spikes/NOTES.md, "When the pinned
Spinel changes"). Until then new code follows the rule.

| Rule or comment | What was seen, and on which build | What CyberTrain does, and where | On the pin |
| --- | --- | --- | --- |
| 1 (rules 58, 65) | A generated `new` frees a String only its argument holds; a call's result is not rooted while a later argument allocates (2026.09.12) | `SafeString.of`; the String bound to a local before `new` (html.rb, mailer.rb, cli/toolchain.rb and others) | Accepted as a constraint; rooted in the shape checked, no AddressSanitizer run |
| Rules 33, 61, 48 | `JSON::ParserError` is not a `StandardError`, `JSON::NestingError` is not caught by its parent's arm, the constant is not a value | None left under `cybertrain/` since 2026-11-20: every `rescue JSON::NestingError, JSON::ParserError, StandardError` is `rescue StandardError` ("Status by rule", row 33 on 2026.11.04.7026, lists the changes and their compiled tests). `Cast.parse_json` names the two JSON classes in two arms. 48 never had a workaround, only the statement that an application cannot register `rescue_from JSON::ParserError` | Probe passes for all three (33 on 2026-11-13: `rescue StandardError` catches `JSON.parse("{")`'s error; 48 on 2026-11-20 on the framework's Controller, spikes/rechecks/differing/rescue_from_json_error.rb) |
| Rules 31, 32, 45, 50, 69 | `yield self` in a base-class method, and a `rescue` or `ensure` in a yielding method called from nested blocks, do not compile or run wrong | `begin` / `rescue` / `ensure` live in a plain method that takes the block as a Proc and calls `block.call(self)`, one level down and no further: `DB.run_transaction`, `Controller#process` / `#run_action`, the job loop, `Main.run_command` | The shape of 32 compiles and 31's probe passes (2026-11-04); probes of 45, 50 and 69 pass (2026-11-13). Rule 79 beside them still fails |
| Rule 42 | A lambda literal passed as a keyword argument is not marked escaping and keeps Integer parameters | The application's URL resolver is returned by a method (`Gen::Routes.url_resolver`, generator/routes_emitter.rb); application.rb's header says so to applications | Probe passes (2026-11-04). Y, its cousin, still fails |
| Rules 44, 67, 68 | A `return` in a block ends the block, not the method; a yielding method on a boxed receiver is NoMethodError; a Proc block nested two deep does not see an outer block's parameter | The block of `DB.transaction` must not `break` or `return`; a pooled connection is driven through `DB.transaction` and the plain `begin!` / `commit!` / `rollback!`, not the yielding `Connection#transaction`; `DB.with` stays a yielding method and loops are hoisted into methods (db.rb, db/connection.rb, db/pool.rb) | Probes pass (2026-11-13; 44's `break` on 2026-11-04) |
| Rules 62, 51, 10, 34, 40, 43 | A Ruby method named like a builtin, or one name with two return types, changes every dispatch of that name on a boxed receiver | Byte scanners read their parameter through a new `to_s` local; distinctive names (`stream_read`, `raw_values`, `helper_call`, `zone_name`, `reject_status`); `SafeString::EMPTY`; `Interpreter#key_in?` in place of `Hash#key?`; `script/check-reserved-names` | 62's reduced program passes; probes of 10/34, 40, 43 and of `key?` beside a user class's `key?` pass (the last on 2026-11-13) |
| Rule 60 | A String local appended to in a loop is a buffer filled with `strlen`: bytes after a NUL are lost, and so in an interpolation | Such a local starts as `+""` and is filled with `<<`; no interpolation of a binary String (http/server.rb, mailer.rb, http/multipart.rb) | Reduced program passes; `"#{body}"` keeps a NUL (2026-11-13) |
| Rule 28 | `URI.decode_www_form_component` decodes a malformed escape silently | `Query.decode_valid` refuses one itself with a byte scan (http/query.rb, http/cookies.rb) | Probe passes: `%ZZ` raises ArgumentError |
| Rule 20 | `readpartial` without `wait_readable` is a blocking `read(2)` that holds the OS worker (2026.09.12, matz/spinel#4528) | `wait_readable(timeout)` before every `readpartial`; kept either way, since its nil return is the idle timeout (http/server.rb, http/body_writer.rb, websocket.rb) | Probe passes (2026-11-13): at `SPINEL_WORKERS=1` the main thread kept ticking while another sat a second in a bare `readpartial` |
| Rule 21 | A socket passed as a `Thread.new` argument loses its type | A socket reaches its thread through a method parameter the block captures (`spawn_connection`) | Probe passes (2026-11-13) |
| Rule 30 | A call made from inside a stored block does not widen the callee's parameter: a Symbol arrives as its internal id | `Controller::DEFAULT_STATUS`, a polymorphic default that keeps `status` boxed (controller.rb; test/controller_status.rb) | Probe passes (2026-11-13) |
| Rule 3 | A base-class method calling a method only subclasses define crashes the compiler | Abstract stubs on `Cybertrain::Model` and the other bases for directly dispatched hooks (not for hooks only stored blocks call: Z) | Probe passes (2026-11-13) |
| Rule 19 | `STDOUT` and a `StringIO` cannot share one call site | `Logger` keeps `@io` nil or a StringIO and writes to the `STDOUT` constant otherwise (logger.rb) | Probe passes (2026-11-13) |
| Rules 18, 64 | A module's `@@x` miscompiled, and was not a GC root | Module-level `@x` with `def self.x` accessors everywhere; registries are constants (D64; test/harness_gc.rb) | Reduced program passes; marked on the pin |
| Rules 7, 9, 12, 14, 26, 29, 73, 74 | A Time assigned to a nil ivar, unseeded containers, `k, v = split`, `include?` on polymorphic values, `obj.attr += x` in a block, an ivar first assigned in a helper, an inherited constant | `Cast.*_or_nil`, seeded containers, indexing instead of destructuring, narrowing first, the long form of `+=`, every ivar assigned in `initialize`, constants spelt with their owner | Probe or reduced program passes for each (2026-11-04) |
| Rule 8 | `when Array` matching a Time | `when Time` first where the arm has a body of its own, and in component.rb, rendering.rb, `render` (template/helpers.rb), console/printer.rb and dev/error_page.rb, which were not re-checked | Probe passes (2026-11-04, again 2026-11-15); retired in part on 2026-11-15 (1.5) |
| Rule 55 | An in-place `<<` on a String read out of a container does not reach the stored String | Tests do not assert it (`Params#merge!`, which copied per String, was removed on 2026-11-15) | Probe passes (2026-11-13) |
| Rule 66 | Direct appends to a String local lose what a helper appended; a String appended to through a parameter does not reach the caller | A buffer filled through helpers is filled only through helpers; the generator's emitters build and return their own String (generator/models_emitter.rb, routes_emitter.rb) | Reduced program passes; so does an append through a parameter (2026-11-13) |
| Comment, blob_store.rb and config/files.rb | `Dir.mkdir(dir, mode)` ignored the mode (755 under a 022 umask) | `File.chmod` after `Dir.mkdir` for a directory made for secrets or blobs | Probe passes (2026-11-13): the directory is 700 |
| Comment, http/server.rb | Inside a `loop do` block a raised exception lost its ivars (`Rejected#status` read 0) and `return value` skipped its value | `Server#serve` is a `while true` | Probe passes (2026-11-13) |
| Comment, template/interpreter.rb and form_builder.rb | An interpolation does not call a user-defined `to_s` | `"#{v.to_s}"` for objects in `Interpreter#to_s_value` and `FormBuilder.value_text` | Probe passes (2026-11-13) |
| Comment, generator/routes_dsl.rb | A receiverless call in a block nested inside `instance_eval` has no `self` in the C | Nested routing blocks take the mapper (`resources :articles do \|r\|`); part of the public API | Probe passes (2026-11-13); A was this call one level up |
| Comment, generator/routes_dsl.rb | A class with an instance method named `new` does not compile | The `new` action is `def new_action` in controllers; part of the public API | Probe passes (2026-11-13) for a plain class |
| Comment, generator/inflector.rb | Regexp objects cannot be kept in a collection | Each inflection table is written out as literal regexes | Probe passes (2026-11-13) |
| Comment, logger.rb | `STDOUT.flush` as a method's value is typed a File and emitted as void | `Logger#write_now` ends in an explicit `nil` | Probe passes (2026-11-13) |
| Comment, test/cli_toolchain.rb | `File.join(Dir.pwd, *parts)` passed only the first element of the splat (2026.09.12) | The helper takes one joined argument | Probe passes (2026-11-13) |
| Comment, stream.rb and password.rb | `Base64.urlsafe_decode64` was not relied on to take unpadded input | The text is padded back before decoding | Probe passes (2026-11-13) |
| Comment, http/server.rb, roles/server.rb, dev/reexec.rb | A `trap` block runs inside the C signal handler, where a join, an allocation or `execv` is not safe | A handler only sets a flag (`Server#request_stop`); the stop and the re-exec run on ordinary threads | Not run. The pinned tree's lib/spinel_rt.h says a threaded program runs trap procs on a green thread of its own (`sp_sig_thread_body`), so the comment describes the unthreaded runtime; the flag is right either way |
| Rule 36 | Requiring a middleware whose `#call` is never reached miscompiles unrelated files | Every program that requires the framework exercises the stack it requires; test/csrf_conditional.rb's header records the shape that did not compile on 2026.09.12 | Probe passes for the one recorded shape (2026-11-15, 2026-11-19, 2026-11-20; "Status by rule", row 36 on 2026.11.04.7026, has its source); seen in larger programs and never reduced, so not conclusive |
| Rule 35 | `obj[k] = v` on an object received as a plain parameter does nothing behind a middleware chain | The mutation is a typed instance method (`Session#csrf_token!`, session.rb) | Probe passes (2026-11-15, spikes/rechecks/type_shapes.rb); seen in the whole framework and never reduced, so not conclusive |
| Rule 4 | An inherited class method called as `self.class.foo` binds `self` to the base class | The class is passed in (`Controller.chain_for(klass)`); registries are keyed by class name | Probe passes (2026-11-15, spikes/rechecks/dispatch_shapes.rb) |

#### 1.3 Kept, and not re-checked on the pin

| Rule or comment | What was seen (2026.09.12 unless it says otherwise) | What CyberTrain does, and where |
| --- | --- | --- |
| Rule 57 (item 7) | A `Mutex#synchronize` on every request stalls requests for seconds at `SPINEL_WORKERS=2` | No lock on the request path; the template cache is filled at boot (`Engine.embedded`); development serves on one worker (`Application.serving_workers`); `TimeZone` reads its snapshot under the lock and looks up outside it |
| Rules 6, 11, 37, 39, 63, 71 | A Method object in a collection; a nil-initialised local; a Symbol-keyed Integer Hash read with a polymorphic key; a `case` whose branches both build a SafeString; same-named locals in two top-level blocks; narrowing that does not type a return value | Lambdas; typed sentinels; `.to_i` on every branch; `SafeString#+` in two steps; distinct local names in tests; `Cast.hash` / `Cast.array` copy into a seeded container |
| Rule 41 | One accessor name with two types in files that never meet stops the compiler | Each subsystem has a test that requires the whole framework (test/template_integration.rb); `script/check-reserved-names` |
| Rule 15 | A static `ffi_buffer` out-parameter crashes under threads | A `malloc`ed scratch pointer per call (db/sqlite_ffi.rb, http/gzip_ffi.rb) |
| Rule 46 | Thread stacks are small: about 50 nested template renders overflow one, and an overflow is a SIGSEGV, not a `SystemStackError` | The interpreter caps nesting (template/limits.rb) and `Query` caps depth; http/server.rb does not name `SystemStackError` in its rescue |
| Rule 51 | One method called with Symbol and with String keys mis-dispatches the `key.to_s` in it | One key type per test program |
| Rule 66, second half | An instance method named `name` on a framework class made `.class.name` fail on a boxed receiver | `TimeZone#zone_name`; no framework class writes `def name` (readers made by `attr_reader :name`, as in schema/table.rb and the generator's scans, are there, and the suite builds and passes with them) |
| Rule 72, the rest | No `Addrinfo`, `IPSocket.getaddress` or `Socket#bind(sockaddr)`; in the openssl package a handshake error is raised even with `exception: false`, there is no `X509::Store`, `SSLContext` defaults to `VERIFY_PEER`, and the cipher error is `OpenSSL::CipherError` | `Socket.getaddrinfo` with destructured block parameters; `set_params` on both runtimes; `SSL_CERT_FILE` for another CA; `rescue OpenSSL::OpenSSLError` (net/socket.rb, net/tls.rb, encryptor.rb). Three parts pass a probe: an unresolvable name raises, `entry[3]` indexes, and `Errno::ENOENT::Errno` and a `SystemCallError`'s message read as CRuby's (the last two on 2026-11-13) |
| Comment, template/helpers.rb (`Helpers#hidden_fields`) | A method that appends to a String it was given makes the GC write barrier run on the caller's stack slot, which later crashes a minor collection | Tag builders append what a helper returns (`hidden_fields`, `FormBuilder.text_attr`, `FormBuilder.attrs_html`) and never pass their buffer down |
| Comment, websocket.rb | A method that returns a value-type object from inside a `synchronize` block does not compile with the whole framework in the program | Each status field is read under the lock by its own method, and `WebSocket.feed_status` builds the `Status` outside |
| Comment, cast.rb | An Integer multiplied in an unbounded loop is typed a Bigint | A table of powers of ten (`FRACTION_SCALE`). The value is right on the pin (probe, 2026-11-13); the type was not looked at |
| Comment, http/uploaded_file.rb | Class names are global | `UploadedFile`, `Multipart` and `BlobStore` are reserved names for an application |

#### 1.4 Not defects: how Spinel is, which the framework is built around

Nothing is asked for these, and a Spinel release does not retire them.
They are listed so that they are not mistaken for the rows above.

| What Spinel is | What CyberTrain does |
| --- | --- |
| No run-time code: no `eval` or `method_missing`, and no method defined while the program runs (`define_method` from a class body compiles, spikes/rechecks/define_method_shapes.rb, 2026-11-20; `const_get` with a non-literal name passes a probe, rule 1's status); `instance_exec(&stored)` is refused (rule 2, refused on 2026-11-13 as before); a computed `send` works up to the dispatch's 1024 arms (rule 1) | Models, relations, routes, helpers, components, jobs and concerns are generated Ruby; blocks take their receiver (`before_action { \|c\| ... }`); names dispatch through generated `case` tables; templates are an interpreted language of their own; the console evaluates template expressions (D3, D4, D8, D9, D41) |
| One static return type per method; a base method returning `self` is typed as the base (rule 5) | `pluck_int`, `sum_float`, `Cache.fetch_hash` and the like; `DB.transaction` returns nil; a per-model Relation subclass wraps the base setters (D10, D20, D22, D43) |
| D (rule 25): `String#to_i` raises `RangeError` past 2**63-1 in the default mode | Request numbers are length-checked first: `Request#content_length`, `Server#body_length`, `Params#int`, the session's and the configuration's Integers |
| B (rule 59): an `ffi_source` fragment declares what it calls, with the types already emitted | `extern` declarations in db/sqlite_ffi.rb and http/gzip_ffi.rb |
| `IO#gets` on a socket answers a UTF-8 character String (rule 27; `readpartial`, `read(n)` and `read_nonblock` answer byte Strings on the pin, "Status by rule", row 27 on 2026.11.04.7026) | All framing is by byte (`byteindex`, `byteslice`, `bytesize`). This row does not belong under 1.4 (noted 2026-11-21): the left cell is what 2026.11.04.7026 did, and on 2026.11.15.7033 `gets` on a socket answers an ASCII-8BIT String as CRuby does ("Status by rule", row 27 on 2026.11.15.7033). A build changed it, so rule 27 is an item of kind bug in "Item register", not a constraint; an append of socket bytes to a UTF-8 String still differs there |
| A constant resolves as in CRuby (rule 76); a class method no class defines is refused at compile time, reached or not (rule 84) | Code outside `module Cybertrain` writes `Cybertrain::DB`; a program requires every file whose class methods it names |
| No `fork`: a compiled `fork` is `NameError` (checked 2026-11-13) | Several processes share a port with `SO_REUSEPORT` (`CYBERTRAIN_REUSE_PORT`, D35) instead of a prefork server; jobs run on threads of a `worker` process |
| No tz database, `IPAddr` or asynchronous resolver (`Marshal` was listed here until 2026-11-20: a `Marshal.dump` / `Marshal.load` round trip of a Hash holding an Array compiles and prints CRuby's result on the pin, docs/design.md D54); the `zlib` package inflates in one shot with no ceiling; `bigdecimal` has no `to_s("F")`, `to_d` or construction from a Float (rule 100) | `TimeZone` reads TZif files (D19); byte-scanned addresses (net/address.rb, http/ip_address.rb); cache values are Strings; `GzipFFI` streams through the system zlib under a limit (http/gzip_ffi.rb); decimals are Floats rounded on their digits (D73) |
| Tests: no reflection to find test methods (rule 23); a test requires `cybertrain/test` itself (rule 24); a C file Spinel wrote is refused inside a package (rule 98) | Tests are programs compared with a snapshot (test.rb, D13); probe output is kept outside the package |
| Rules 13, 16 and 38: frozen String literals, `Class#name` and `case rec when Post`, a protected method called from a class method | Ordinary Ruby, recorded so that nobody takes them for a Spinel rule. Rule 17 (constants read before their definition) was in this row until 2026-11-21. Only its half about a constant assigned with `=` is ordinary Ruby; a class used above its definition runs compiled where CRuby raises NameError, on this section's pin and on 2026.11.15.7033, so rule 17 is an open item of kind bug ("Item register"; "Status by rule", row 17) |
| Rule 99: `dup` of a user-defined object is a shallow copy | The generated `<Model>Relation#dup` copies its Arrays (D72). CRuby's `dup` is shallow in the same way, and the pin calls `initialize_copy` as CRuby does (probe, 2026-11-13: both print `2 2 0 5` and `1 2`), so this is ordinary Ruby, not a Spinel behaviour |
| Rules 85, 87, 95: `Queue#pop(timeout:)`, class methods added to `Time`, `binding.local_variable_get` for a keyword named `if` | Used as they are (stream/hub.rb, time_ext.rb, rate_limit.rb and generator/routes_dsl.rb) |
| Rules 102, 103, 106, 111, 113, 119, 121 (forms that work), 115 (a measurement), 118 (how a thread test is written), 105, 114, 120 (compiler, scheduler and tool behaviour, not defects) | Recorded in spikes/NOTES.md so that nobody takes them for defects; nothing is asked |

#### 1.5 No longer worked around

| Item | Was | Since |
| --- | --- | --- |
| H (rule 77) | An application object computed in a `DB.with` block went through a local declared before it | 2026.10.27.7020 (#10415) |
| The refusal under C | test/template_engine.rb settled the layout Hash's value types where it is built | 2026.11.04.7026 (#10525, #10524) |
| 2 | `Html.escape` kept a `case value when String` on its parameter | 2026.10.27.7020 (the callers' `x.to_s` stays, 1.2) |
| Rule 75 | Child processes went through `system` only | The pin: `Process.spawn` and `Process.wait` work (test/rate_limit_store.rb) |
| Rule 8, in part | `when Time` came before `when Array` in every `case` over polymorphic values | 2026-11-15, on the pin: the arms that only repeated the fall-through are gone from cast.rb, relation.rb, validator.rb, html.rb, template/form_builder.rb, `Helpers#safe_join` and template/interpreter.rb, with a Time passed through each `case` in the tests ("Status by rule", row 8 on 2026.11.04.7026) |
| 3, A, F, G, I | Never had a workaround: CyberTrain stayed on a build without them until each was fixed | 2026.10.26.7019 and 2026.11.04.7026 |

### 2. What a change in Spinel would give CyberTrain in speed

Requests a second are examples/blog's on one CPU unless a row says
otherwise; each figure names the build it was measured on, and none was
re-measured for this inventory. The first rows are the larger ones.

| What Spinel does | What it costs CyberTrain, as measured | What CyberTrain does today | The change in Spinel | Where it stands |
| --- | --- | --- | --- | --- |
| 5 (a). The full-collection cadence falls to every cycle for a server's request garbage | 83% of collections full; fixing the interval at 8 gives 16 to 17% more requests a second (2026.10.27.7020; the same rule and the same 83% on the pin) | `SPINEL_GC_FULL_INTERVAL=8` in the deploy files; bench/run leaves it unset | Weigh what a full mark costs against the promoted garbage it frees, or make aging work with the slab | Open; not written |
| AA. Closure cells are allocated on entry to the method that holds the block | 576 of an article page's 1,650 objects (35%), and `eval_expr`'s alone 756 of the list page's (41%); writing around three methods took the pages to 1,073 and 1,058 objects (the pin, 2026-11-05) | `while` loops on the request path. 85 methods of examples/blog's program still allocate 176 cells on entry (generated C, 2026-11-13), ten cells a page on the request path | Allocate a cell where the block is made, so a call that never reaches the block pays nothing | Open; not reduced, not reported |
| AB. A foreign call holds its OS worker | At one worker a long SQLite call stalls every request for as long; a writer waiting in the busy handler stalled the server for 5 s (saeki-mototsune/CyberTrain#134) | The wait is done in Ruby (`step_waiting`); long work is sent to another process; `getaddrinfo` still holds the worker | Around a `blocking: true` call, hand the worker's other green threads to another OS thread | Open; not reported |
| 5 (b). At one worker the sweep is handed to a thread that shares the CPU | 5.4% fewer requests a second, 12% higher p99 (2026.10.27.7020) | Nothing (`SPINEL_GC_CONC=0` helps only on a one-CPU host) | Start no sweeper when the process may use one CPU | Fixed, #11646; in no fork tag |
| L. `SPINEL_WORKERS=N` counts a main that only waits; a helper's spawns stay on that helper | A second worker gave 0 to 2% on the pages until the workaround, 24 to 44% with it; connections still split 15 to 3 between two helpers, which is queueing latency | `workers + 1` | Place a thread a helper spawns as main's spawns are placed | First half documented upstream; the second not looked for on master |
| A block allocates a Proc and its cells per call; `each { return }` is a `setjmp` and a Proc | The template interpreter's loops, `run_before_callbacks` and the partial lookup had to become `while` loops (2026.09.12) | `while` on the request path | Inline the blocks of known iterators; a non-local return without `setjmp` when the block is inlined | Not re-checked on the pin |
| An FFI `:str` return always copies, and a `:str` argument is copied on the way in | 44 allocations an article page for 22 text values, 120 on the list page (the pin); a BLOB is copied twice on the way in (rule 60) | DATETIME columns are read as epoch seconds in C; nothing for text | A borrowed or into-buffer return | Open; under "FFI and tools" |
| `"#{v}"` allocates and copies when `v` is a String | An object per interpolation | `v.to_s` where the value is a String (rule 56) | Skip the copy where the result is never mutated | Still copies on the pin |
| `str << int` builds a one-character String | An object per byte appended | `setbyte` into a sized String, or literals | Append the byte directly | Still so on the pin |
| Boxing: `Array#clear` anywhere makes that Array polymorphic; an Array of the class that holds it; a Hash with object values; a nullable object parameter; a narrowed value returned (rule 71) | Every access on them is a dynamic dispatch | `Engine` keeps Templates in an Array found through a String => index Hash and assigns a fresh Array instead of `clear`; `INode` slots never nil; `Cast.hash` / `Cast.array` | Keep the element type through `clear`; a nullable object type | Not re-checked on the pin |
| AC. `URI.decode_www_form_component` is quadratic on non-ASCII text | 117, 463 and 1,883 ms for 50,000, 100,000 and 200,000 bytes after one e-acute (the pin, 2026-11-13); CRuby 1 ms each | `Query.decode` | A linear decode | Open; not reported |
| `URI.encode_www_form_component` runs a regular expression per character | About 11% of the CPU of a page that writes the session cookie (the pin, a macOS profile, 2026-11-05) | `Cookies.serialize` skips it for a value of unreserved bytes (`Query.plain?`): 15.6 to 2.1 µs for 205 bytes | A byte loop | Not reported |
| `Digest::SHA256#update` keeps the bytes and hashes them at the end; there is no HMAC over a streaming state | 12 objects a request in `Session.load` and `Crypto.hmac_digest`; PBKDF2 is two digests and two concatenations per iteration, 1.09 s for 600,000 (compiled, 2026-10-22) | HMAC and PBKDF2 in Ruby over the one-shot digest | Expose the runtime's SHA-256 state | Not asked before |
| 6. The system allocator | jemalloc gave 1.3 to 1.4 times the requests on 2026.09.12; on the pin -3 to +1% on the pages and +18% on the POST | `allocator = "jemalloc"` in spin.toml, off by default | A size-class pool for the runtime's small objects | Less pressing on the pin |
| 7. An uncontended `Mutex` between two workers can wait for seconds | The two-core benchmark failed one run in two (2026.09.12) | No lock on the request path, which costs the framework its process-wide caches and development its parallelism (rule 57) | Find the cause | Not seen since the lock left; not retried |
| E. `each_key` on a polymorphic Hash allocates boxed Arrays; `sp_StrPolyHash_set` allocates Strings | 852 objects a page against 511 for one source (2026.10.09-7009) | Nothing | Iterate without the Arrays | Not re-measured; the pin allocates 1% less than 2026.10.27.7020 |
| Allocations nobody has attributed: `sp_PolyArray_new` and `sp_String_new_inline_len` | 187 and 119 objects an article page (the pin) | Nothing | `SPINEL_ALLOC_SITES` naming the Ruby method, not the runtime function | A tool, under "FFI and tools" |
| The monitor's timer turns take the scheduler lock | 0.32 `futex` a request, about 215 turns a second under load (2026.10.27.7020) | Nothing | None asked | What is left of 4; small |
| A `case` over String literals tries its arms in order | 293 ns a lookup over 200 arms; CRuby hashes them, 183 ns (the pin, 2026-11-10) | The generated asset table is such a `case` (generator/assets_emitter.rb) | Hash or switch on literal Strings | Small; not asked |
| Whole-program analysis on every build | A development rebuild of examples/blog was 8 s, 3.9 of it Spinel's analysis (2026-11-05); writing the blog's C took 52 and 57 s cold on a 4-vCPU cloud VM (`spinel bin/blog.rb $(spin flags) -c`, 2026-11-13); `spin test` was 9 of CI's 21 minutes on Ubuntu when D34 measured it | `--incremental`, a freshness check before `spin run gen`, CI in four shards (D12, D34) | A faster analysis; freshness by dependency in spin | A developer's time, not a request's; not asked |
| 4. Parking a fiber went through the monitor thread; `String#to_sym` searched linearly | About a fifth of a request on 2026.09.12 | Nothing | Done | Fixed in the pin |

### 3. Every known Spinel bug, by where it stands

"Bug" here is a behaviour that differs from CRuby or stops a build, and is
not by design. Costs are in 2; what is by design is in 1.4.

**Open on the pin, with no fix known upstream.**

| Item | In one line | Program | Reported |
| --- | --- | --- | --- |
| Z | A stored block called with a base-class receiver runs the base class's method | 22 lines; fails on master 1c0cc5e35 | No |
| Y | A lambda written into a module-body ivar is called with an Integer in place of its argument | 14 lines; fails on master 1c0cc5e35 | No |
| J | With the slab off, AddressSanitizer finds a thread's captured variables freed before it runs; the default is unknown | In J | No |
| AB | A foreign call holds its OS worker, `blocking: true` or not | 22 lines | No |
| AC | `URI.decode_www_form_component` is quadratic on non-ASCII text | 8 lines | No |
| AD | `String#byteindex` accepts an offset inside a character | 5 lines | No |
| AE | `Class#superclass` on a package's exception class is NoMethodError | 6 lines | No |
| AJ | `Class#superclass` on a built-in exception's class is NoMethodError once a package is required or a module defined (AE on the core classes) | 6 lines | No |
| AF | `Float#round(n)` on a Float narrowed by a `case` rounds the binary product | 12 lines | No |
| AG | `TCPServer.new` on a port in use raises `Errno::ECONNREFUSED` | 9 lines | No |
| AH | `JSON.generate` writes a Float in another form than CRuby's | 2 lines | No |
| AM | A release build's `e.backtrace` is empty | spikes/phase5/backtrace.rb | No |
| AN | A nil-defaulted parameter given a plain Time by a caller crashes the defaulted call | 8 lines | No |
| AO | A statement `case` on a plain Integer after one on a nullable Integer does not compile | 28 lines | No |
| AP | `pop(timeout:)` on a Queue that was put in an Array is `Array#pop` (phase 5b) | 4 lines | No |
| AQ | Four threads writing one StringIO with no lock crash the program (phase 5b) | 17 lines | No |
| AR | A regex literal holding a require-shaped text is read as a require | 2 lines | No |
| AS | `ENV[name]` with a key held in a variable answers the key | Not reduced (spikes/rechecks/differing/env_nonliteral_key.rb, against two framework files) | No |
| AT | `File#stat` on an open File stats its path, not the descriptor | spikes/phase5/flock_fstat.rb | No |
| AU | `String#strip` on a String with an invalid byte returns it where CRuby raises | 5 lines | No |
| V | `strftime` with a built pattern returns the pattern | Not reduced | No |
| W | An ivar String passed to a stored lambda is refused | Not reduced | No |
| X | Type inference does not converge in examples/blog's generator | Not reduced | No |
| AA | Closure cells allocated on method entry (a cost, listed here because 2026.09.12 allocated none for the same source) | Not reduced | No |
| Rule 36 | Requiring a middleware whose `#call` is never reached miscompiles unrelated files | Not reduced; the one recorded shape compiles in a probe on the pin ("Status by rule", row 36 on 2026.11.04.7026) | No |
| Rule 17 | A class used above its definition runs, where CRuby raises NameError (added 2026-11-21; listed under 1.4 until then) | 2 lines ("Status by rule", row 17 of both tables) | No |
| Rule 27 | `IO#gets` on a socket answers a UTF-8 character String, and socket bytes append to a UTF-8 String that holds non-ASCII where CRuby raises (added 2026-11-21; listed under 1.4 until then). On 2026.11.15.7033 `gets` answers as CRuby does and the append still differs Inline in "Status by rule", row 27 of both tables | No |
| 7 | A `Mutex` on the request path stalls for seconds at two workers | Not reduced; not retried since 2026.09.12 | No |
| 5 (a) | At one worker 83% of collections are full | Measured, under 5 | No |

**Fixed on matz/spinel master, in no fork tag: the pin still has them.**
K (#11129), rule 79 (#11137, #11143 to #11145), M (#11193), N (#11184,
#11219), O (#11183), P (dcc46945c), T, Q (#10998, #11639), R (#11650,
#11689, #11690), S (#11643), U (#11683) and 5 (b) (#11646, #11697). The
table under "A fork release that carries matz/spinel master" has what
each one's program did on master 1c0cc5e35.

**Seen once, and not shown on the pin.** The rows of 1.2 and 1.3: each
was a real failure on the build named there, mostly 2026.09.12. For the
rows of 1.2 a small program of the shape passes on the pin, so the bug is
either gone or needs more of a program than the probe has. The rows of
1.3 were not tried on the pin at all, and nothing is known about them
there. None is asked of Spinel until a program shows it on the pin.

**Fixed in the pin.** 2, 3, 4, A, C and its refusal, F, G, H, I, the
untyped `OpenSSL::Digest#to_s`, the linear `String#to_sym`, the two
shapes found in review, and rules 64, 65 and 66 in the shapes checked.

**By design, or settled.** B, D, L, 1 (accepted), the two refusals
("A refusal of a never-reached class-method call", "A refusal inside a
block that never runs") and everything in 1.4.

## What is asked of Spinel now

The inventory of 2026-11-13 ("Everything on main, in one place") adds to
what this section lists: seven bugs with a program each and no report
yet (AB to AH), and one cost seen only in the framework (AA). The
section itself reads as it did before the inventory; in order of harm
the new ones come after Z and Y, with AF (one number rounded two ways,
silently) and AB (a one-worker server stalled by one foreign call) first
among them.

Brought up to date on 2026-11-13. Since this section was written, the first,
fourth and fifth of its open bugs (S, R, U), the sweeper half of 5 and
the Float half of Q were sent to matz/spinel and merged (#11643, #11650,
#11683, #11646, #11639), and master 1c0cc5e35 was built to run each item's
program. Those items moved from "Bugs still open" to the table under 1,
which gained a column for that run. The rest reads as it did on
2026-11-11.

Written on 2026-11-11, after phase 4a of the Rails-gap programme and its
final fixes. Two things were done for it. The programs that had only been
rules in spikes/NOTES.md (66, 70, 81, 82 and 88) were run on the pinned
2026.11.04.7026, which adds Y and Z, a third shape to R, and one rule
that no longer holds (see "Re-checked on 2026-11-11"). And matz/spinel
master 494deaac was read for every open item: master was not built for
that, so each "fixed on master" below is to be confirmed with the item's
program when a fork tag carries it.

### 1. A fork release that carries matz/spinel master

This is the first thing asked, and it is asked of the fork, not of
upstream. The fork has no tag after 2026.11.04.7026 (its master,
da8d4ba8, is one commit past it), and master has since merged a fix for
thirteen items here, ten of them sent from this project (K, rule 79, M,
N and O, and on 2026-11-12 Q's Float half, R, S, U and 5 (b)). Any tag
that carries master up to matz/spinel#11697 (2026-11-13) has them all.
The third column is the item's program built with master 1c0cc5e35 on
2026-11-13:

| Item | On master | Its program on master 1c0cc5e35 | What changes in CyberTrain once pinned to it |
| --- | --- | --- | --- |
| K. `puts` on a nil-only receiver does not compile with the TLS layer | #11129, merged 2026-11-06 | builds and prints `ok` | `Logger#write_now` goes back to `@io.puts(line)` |
| Rule 79. A rescuing method's value from a block that only raises | #11137, merged 2026-11-06 (and #11143 to #11145) | prints `["b"]` | the test idiom of rule 79 is no longer needed |
| M. `gets` on STDIN does not show a partial STDOUT line first | #11193, merged 2026-11-06 | not run (it needs a terminal) | `Console.run`'s flushes go |
| N. A Hash return does not follow an ivar widened late | #11184 and #11219, merged 2026-11-06 and 2026-11-07 | prints `0` | nothing here; Daicho's `n.to_i` goes |
| O. `TCPSocket.new` ignores `connect_timeout:` | #11183, merged 2026-11-06 | not run | a sentence in socket.rb's header and the guides |
| P. Net::HTTP against a silent TLS peer | dcc46945c, 2026-11-05 | not run | the header comment of http_client.rb and the guides' "why it exists" |
| T. `exit` on a thread other than main | test/thread_exit_raises_in_main.rb, in master before #11035 (2026-11-05) | exits 1 and prints nothing, as CRuby does | nothing; rule 91 becomes history |
| Q, the Time and Date half | #10998, merged 2026-11-05 | `t1..t2`, `Range.new(t1, t2)` and a Range of Dates are built and answer `begin` | `where(col: t1..t2)` and the validators can be looked at again |
| Q, the Float half: `when Range` misses a boxed Float Range, or a Time Range held in a Hash | #11639, merged 2026-11-12 | Q's first program prints `["1.5", "2.5"]`, `["a", "z"]` and `2` | the same look at `where(col: a..b)` and the validators covers Float ends |
| R. A `rescue` arm Spinel does not resolve matches by its last segment, or the `begin` swallows the exception | #11650, merged 2026-11-12 (and #11689 and #11690 from its review, merged later that day and not in 1c0cc5e35) | all three programs print CRuby's result | nothing has to change; the warning on a `rescue` line (rule 89) and the spelling from the top (rule 81) stop being what keeps an exception from being lost |
| S. A `yield` passed as an argument runs the block twice | #11643, merged 2026-11-12 | prints `one 42 a` | `Cybertrain::Cache`'s fetch family can pass `yield` to the cast again (rule 90) |
| U. A `def` inside a block that never runs defines the method | #11683, merged 2026-11-12 | prints `false false` | gen's refusal of a `class_methods` name (`ConcernScan::RULE_93`) can be looked at again |
| 5 (b). At one worker the sweep is handed to a thread that shares the CPU | #11646, merged 2026-11-12 (and #11697, its test made stricter, 2026-11-13) | not run (the change shows on Linux held to one CPU; the pull request's figures are under 5) | nothing to change; a one-CPU deployment stops paying for the sweeper |

With the tag: run each item's program, `spin test`, and examples/blog's
`spin run gen`, tests and the side-by-side run of "Re-checked side by
side" before `SPINEL_TAG` moves (some 1,800 commits lie between the pinned
tag and 494deaac).

### 2. Bugs still open, each with a program that shows it

On 2026-11-11 none of these had an upstream issue or a fixing commit
(matz/spinel's issues searched by keyword, master's history from
2026-11-04 to 494deaac by subject), and none was reported. Eight were
listed then: S, Z, Y, R, U, J, 5 and Q. S, R, U, the Float half of Q and
the sweeper half of 5 (5 (b)) are merged since and are in the table under
1. Four are left, in order of harm, 5 with its first half only. The
first two give a wrong result with no error at compile time, each has a
workaround in the framework that an application author has to know as
well, and both fail on master 1c0cc5e35 as on the pin (2026-11-13); neither is
reported yet.

1. **Z**: a stored block called with a base-class receiver runs the base
   class's method, not the subclass's override. 22 lines.
2. **Y**: a lambda written into a module-body ivar is called with an
   Integer in place of its argument. 14 lines.
3. **J**: with the slab off, AddressSanitizer finds a thread's captured
   variables freed before it runs. Whether the default is affected is
   still open. (matz/spinel#11138, merged 2026-11-06, fixed another
   object freed while still referenced that showed with
   `SPINEL_GC_SLAB=0`, an interned frozen String; it does not touch a
   thread's captures, and J's program is to be run again on a tag that
   carries it. It was not run on 1c0cc5e35.)
4. **5 (a)**: at one worker 83% of collections are full. The change to
   the cadence rule is described under 5 and not written as a patch; it
   is what would take `SPINEL_GC_FULL_INTERVAL=8` out of the deploy
   files.

### 3. Seen in the framework, not reduced yet

(Since the inventory of 2026-11-13, **AA**, closure cells allocated on
method entry, belongs here too, and since 2026-11-15 **AS**, `ENV[name]`
answering the key, whose generated C shows V's cause.)

Nothing can be sent for these until a program stands on its own: **V**
(`strftime` with a built pattern returns the pattern; five standalone
programs tried on 2026-11-11 format correctly), **W** (an ivar String
passed to a stored lambda is refused), **X** (type inference does not
converge in examples/blog's generator), and the runtime costs **6** (the
system allocator) and **7** (a `Mutex` on the request path, not seen
again since the lock left it).

### 4. Nothing asked

- **B, D and 1** are accepted as Spinel's constraints (see "Accepted as
  Spinel constraints").
- **L** is settled as documented behaviour: master's docs/thread.md
  (da4485a5, 2026-11-06) tells a program whose main only joins to ask
  for `SPINEL_WORKERS=N+1`, which `Application.spinel_workers` does.
- The two refusals by design ("A refusal of a never-reached class-method
  call", "A refusal inside a block that never runs") stay as questions,
  not requests.
- **AI** (phase 4b, 2026-11-11) is a compile-time cost, not a defect:
  it is ready to report as a request (a large constant literal's stores
  written into helper functions of bounded size), and nothing in
  CyberTrain waits on it.
- **AJ to AO** (phase 5a, 2026-11-12 and 2026-11-13): AJ, AM, AN and AO
  are defects with a program each, ready to report; AK and AL are costs (the C compiler's
  memory on a very large program, spin's freshness check), and nothing in
  CyberTrain waits on any of them.
- **AP and AQ** (phase 5b, 2026-11-13, reduced 2026-11-14): defects with a
  program each, ready to report; the framework works around both (no
  Queue in an Array, one lock around every log write), and nothing waits
  on them.
- **AR** (phase 5b follow-ups, 2026-11-14, reduced 2026-11-15): a defect
  with a two-line program, ready to report; test/gen_jobs.rb builds the
  keyword from pieces, and nothing waits on it.
- Fixed and carried by the pin already: 2, 3, 4, A, C and its refusal
  (#10525, #10524), F, G, H (#10415) and I (#10735, #10786); their
  workarounds are dropped where there were any (see each).

### 5. Build time (added 2026-11-12)

Not a bug: the time an application developer waits. One edit of a
controller is 53 s on a 4-core Linux VM, 44 s of it the analysis, and the
analysis grew 4.2 times while the framework grew 2.3 times. Four things
are asked, in "Build time, measured on 2026-11-12" at the end: an
analysis whose cost follows what changed, a staleness check per
executable in spin, a way to give an executable its build flags (or a
split of a unit well under 4 MB), and `spin test` on several files at
once.

## What can go upstream

Looked at on 2026-11-05, against 2026.11.04.7026 and the fork's master
(one commit past it, none in the code below), for each item that still
has a workaround in CyberTrain or an open bug. The rows were brought up
to date on 2026-11-11 with what matz/spinel master 494deaac has merged
since (read, not built; see "What is asked of Spinel now"), and Y and Z
were added. On 2026-11-13 the rows of 5 (b), Q, R, S and U were brought up to
date with what was sent and merged on 2026-11-12, and Y's and Z's with a
run on master 1c0cc5e35:

| Item | Workaround it would remove | What can be sent |
| --- | --- | --- |
| K | `Logger#write_now`'s `@io.write` instead of `@io.puts` | **Ready**: a nine-line reduced program and a one-line fix in src/codegen_call_io.c, tested on a build of 2026.11.04.7026 (see K). **Sent and merged**: matz/spinel#11129 (2026-11-06), which reads the argument through `emit_to_s_expr` and covers `print` as well. Needs a fork tag that carries it |
| 5 (a) | `SPINEL_GC_FULL_INTERVAL=8` in the deploy files | A change to the full-collection cadence rule (`SP_GC_PROMOTED_DEAD_CUT`), a policy change that upstream's benchmarks would have to support; not written yet |
| 5 (b) | none (a gain of about 5% on one CPU) | Small: start no sweeper in `sp_cs_start_sweepers` (lib/sp_sched.c) when `SPINEL_GC_SWEEPERS` is unset and the process may use one CPU; not written or measured as a patch. **Sent and merged**: matz/spinel#11646 (2026-11-12), measured there on Linux/aarch64 held to one CPU (see 5), with its test made stricter by #11697 (2026-11-13). Needs a fork tag that carries it |
| J | none | Nothing yet: where the capture struct becomes unreachable is not known |
| L | `Application.spinel_workers` (`workers + 1` above 1) | **Ready to report**: the 15-line program and its table in L show it without a server; a choice of fix for upstream (main pumps while it joins, or N helpers when main only waits), plus the separate placement of a helper's spawns. **Settled upstream as documented behaviour**: docs/thread.md on master says a program whose main only starts and joins threads has N-1 threads of work and is to be given `SPINEL_WORKERS=N+1` (da4485a5, 2026-11-06), which is what `Application.spinel_workers` does. Nothing more is asked |
| `"#{v}"` copies | the idioms of rule 56 | Not as stated in the table: CRuby's `"#{s}"` also answers a new, unfrozen String that `<<` does not share with `s`, so the copy can only be skipped where the result is never mutated |
| `str << int` | the idioms of rule 56 | A codegen change appending the byte directly; a speed gain, not a correctness fix; not written |
| B, D, 1 | — | Nothing, by decision (see "Accepted as Spinel constraints") |
| Rule 64 | none (CyberTrain keeps objects out of class variables anyway) | Nothing: a class variable's object is marked on 2026.11.04.7026 and survives `SPINEL_GC_STRESS=1` (see "Rules 64 and 65") |
| Rule 79 | none (a test gives the block a value after the `raise`, or passes the result through a method) | **Ready to report**: an eight-line reduced program that CRuby runs and 2026.10.27.7020, 2026.11.03.7025 and 2026.11.04.7026 all refuse with the same C error (see "Rule 79"). **Sent and merged**: matz/spinel#11137 (2026-11-06), with #11143 to #11145 for a block that ends in `exit`, `abort`, `throw` or `next`. Needs a fork tag that carries it |
| Rule 65 | building the allocating argument first, in a local (cybertrain/cli/toolchain.rb) | Not known yet: the shape checked is rooted on 2026.11.04.7026, but only in its generated C, with no AddressSanitizer run; a shape still left unrooted would first have to be found (see "Rules 64 and 65") |
| N | none (the shape is not in the framework) | **Ready to report**: Daicho's 16-line program (CRuby prints `0`; the C does not compile on 2026.11.03.7025, 2026.11.04.7026 and master 60381c464) and the two fixes the report suggests (see N). **Sent and merged**: matz/spinel#11184 (2026-11-06) and #11219 (2026-11-07), the first of the two fixes (the return type follows the widened ivar). Needs a fork tag that carries them |
| O | the non-blocking connect of cybertrain/net/socket.rb (rule 72), kept anyway for the deadline; a sentence in socket.rb's header and the guides | **Ready to report**: a nine-line program, and the cause named to the line: `sp_net_connect_timeout` has been in lib/sp_net.c since 59c06d979 and nothing emits a call to it (see O). **Sent and merged**: matz/spinel#11183 (2026-11-06). Needs a fork tag that carries it |
| P | none (`HttpClient` stays for the deadline and the address policy); the header comment of cybertrain/http_client.rb and the guides describe the pinned behaviour | Nothing: fixed on matz/spinel master dcc46945c (2026-11-05). Needs a fork tag that carries it, then a `SPINEL_TAG` move and the comment revised (see P). Still in no fork tag on 2026-11-11 |
| Q | `where(col: a..b)` (phase 2) takes Integer ends only; other bounds go through `where_between(col, from, to)`, and the validator options `inclusion: { in: }` / `exclusion: { in: }` take an Integer Range or an Array | **Ready to report**: two reduced programs (see Q); the Time and Date construction error and the Float `when Range` miss are separate defects (the String Range of the first program is matched on the pin, re-run 2026-11-15). The first is **fixed on master** by matz/spinel#10998 ("Ranges of Times and of the program's comparable objects", 2026-11-05; a Range of Dates is a Range of objects in docs/limitations.md). For the second, master has tests of boxed Float and String Ranges (test/float_range_boxed_methods.rb, test/boxed_range_eq_float_range.rb, "boxed Range compares by ends", e0992bb9) but no commit was matched to Q's first program: to be run on a fork tag that carries master before anything is sent. Run on master 494deaac on 2026-11-12 instead: the String Range was matched, as on the pin; the Float Range and a Time Range held in a Hash were not. **Sent and merged**: matz/spinel#11639 (2026-11-12), "A boxed Range of Float, Time or object ends is a Range to when, in and a class value". Needs a fork tag that carries it |
| R | none needed: the generator of `run_job` names only classes the program defines (phase 3, spikes/NOTES.md rule 89) | **Ready to report**: the reduced programs in R (CRuby raises NameError; the compiled programs match by the last segment or swallow the exception), and a third added on 2026-11-11 from rule 81, where every class exists and the `begin` still swallows the exception. **Asked**: not reported upstream yet, and no issue or commit found for it; 24d05c78 (2026-11-07) changed how a `rescue` arm finds its class, so the three programs are to be run on master first. Run on master 494deaac on 2026-11-12: the first two answered as on the pin. **Sent and merged**: matz/spinel#11650 (2026-11-12), "A rescue clause naming a path that fails past its first name raises NameError when reached", with #11689 and #11690 from its review. All three programs print CRuby's result on master 1c0cc5e35; which commit fixed the third was not looked for. Needs a fork tag that carries them |
| S | `computed = yield` before `Cast.str(computed)` in cybertrain/cache.rb's fetch family (spikes/NOTES.md rule 90) | **Ready to report**: the reduced program in S (CRuby runs the block once; the compiled program runs it twice). No fix written. **Asked**: not reported upstream yet, and no issue or commit found for it on master 494deaac (test/yield_argument_diverging_block_types.rb, already in the pinned tree, covers this shape's TypeError and not how often the block runs). Run on master 494deaac on 2026-11-12: `one 42 a,a`, as on the pin. **Sent and merged**: matz/spinel#11643 (2026-11-12), which also fixes a method called again from its own block reading the outer call's arguments. Needs a fork tag that carries it |
| T | the feed supervisor sets `Background.feeds_failed?` and the `feeds` role's main thread returns the exit status (spikes/NOTES.md rule 91) | **Ready to report**: the six-line program in T (CRuby exits 1; the compiled program goes on and exits 0). **Fixed on master**: test/thread_exit_raises_in_main.rb ("`exit` in a thread other than main ended that thread and nothing else ... CRuby raises the SystemExit in the main thread") is in master since before #11035 (2026-11-05) and not in the pinned tree. Needs a fork tag that carries it; nothing in CyberTrain has to change with it |
| U | gen writes a concern's `class_methods` as `def self.x` on the concern plus a forwarder, and refuses a `class_methods` name an instance method of the concern or an including class has (phase 4a, spikes/NOTES.md rule 93) | **Ready to report**: the reduced program in U (CRuby prints `false false`; the compiled program `true false`). No fix written. **Asked**: not reported upstream yet, and no commit found for it on master 494deaac; the open proposals matz/spinel#9898 ("definitions at their point") and #10866 (method cells) are where a fix would belong. **Sent and merged**: matz/spinel#11683 (2026-11-12), "A block a class body hands to a method that never uses its block defines nothing"; it leaves the block's body out, so a call of a method only such a block defined is refused at build time (see U). Needs a fork tag that carries it |
| V | `Strftime.walk`, reached from `Template::Helpers.time_tag_strftime` and `I18n.l`, calls `strftime` with a literal pattern per directive (spikes/NOTES.md rule 96) | Nothing yet: seen in the framework, the cause read from the generated C, no reduced program written: five standalone programs tried on 2026-11-11 all format correctly (see V). Not reported upstream yet |
| W | `Component` passes `"#{@name}"`, a fresh local, to `Views.component_builder.call` (spikes/NOTES.md rule 97) | Nothing yet: seen only in examples/blog's program, not reduced (see W). Not reported upstream yet |
| X | `Gen::Runner` has each emitter scan `app/controllers` for itself (spikes/NOTES.md rule 94) | Nothing yet: bisected to one change in examples/blog's generator, not reduced (see X). Not reported upstream yet |
| M | `Console.run`'s `flush` after the banner and every prompt (rule 83) | **Sent and merged**: matz/spinel#11193 (2026-11-06), "STDOUT on a terminal is written through, as CRuby's is". Needs a fork tag that carries it |
| Y | every stored lambda of the framework is made in a method, not written into a module-body ivar: `Views.default_url_resolver`, `Views.default_helpers_builder`, `Views.default_component_builder` and `Assets.empty_resolver` (spikes/NOTES.md rule 82) | **Ready to report**: the 14-line program in Y (CRuby prints `sess`; the compiled program raises NoMethodError on an Integer). No fix written. Not reported upstream yet; the same on master 1c0cc5e35 (2026-11-13) |
| Z | no method that only stored blocks call has a stub on its base class (the generated `counter_cache_*` on `Cybertrain::Model`, a job's `run_job` on `Job::Base`), and `respond_to`, a controller's `content_security_policy` and the Turbo Stream builder run a block at once instead of storing it (spikes/NOTES.md rule 88) | **Ready to report**: the 22-line program in Z (CRuby prints `"sub"`; the compiled program `""`). No fix written. Not reported upstream yet; the same on master 1c0cc5e35 (2026-11-13) |
| AA | the `while` loops that stand in for blocks on the request path (`Interpreter#eval_expr`, `Helpers#nested_url`), and `Response#respell_header` | Nothing yet: seen in the generated C of the framework's methods, not reduced (two standalone programs allocate nothing on entry, see AA). Not reported |
| AB | the busy handler that reports instead of waiting, and `Connection#step_waiting` (spikes/NOTES.md rule 80); kept after a fix unless a foreign call stops holding its worker | **Ready to report**: the 22-line program in AB (`ticks=1` at one worker with `blocking: true`). First to be run on master, and docs/FFI.md read for what the option promises. Not reported |
| AC | `Query.decode`'s own byte loop around the library decoder (spikes/NOTES.md rule 49) | **Ready to report**: the 8-line program in AC (1 ms under CRuby; 119, 556 and 1,949 ms compiled). Not reported; not run on master |
| AD | none (the framework validates the text first, and stays that way) | **Ready to report**: the 5-line program in AD. Low in harm. Not reported; not run on master |
| AE | the list of client faults by name, `ClientError::CLIENT_FAULTS`, with `script/check-client-faults` (spikes/NOTES.md rules 47 and 54); it stays unless an ancestor walk works for every class | **Ready to report**: the 6-line program in AE. Not reported; not run on master |
| AF | `Cast.round_digits` in place of `Float#round(scale)` (spikes/NOTES.md rule 100); kept either way, since it is what makes a stored decimal the same under both runtimes | **Ready to report**: the 12-line program in AF (CRuby `1.01`, compiled `1.0` for the same Float). Not reported; not run on master |
| AG | `privileged_denied?` in `Server#bind_listener` | **Ready to report**: the 9-line program in AG (CRuby `Errno::EADDRINUSE`, compiled `Errno::ECONNREFUSED`). Not reported; not run on master |
| AH | none | The 2-line program in AH. A difference in form, not in value: to be mentioned with AF rather than reported alone |
| AI | gen/locales.rb fills its Hash through methods of at most 50 stores (spikes/NOTES.md rule 101) | **Ready to report** as a compile-time cost, not a defect: spikes/phase4b/locale_hash.rb and its generator make_keys.rb, with the `--timing` figures (see AI). Not reported upstream yet |
| AJ | `Test::BUILTIN_PARENTS` and the `Errno::` prefix in `assert_raises` (spikes/NOTES.md rule 104) | **Ready to report**: the 6-line program in AJ, the same defect as AE. Not reported; not run on master |
| AK | the framework's suite kept one program per file (design D34, D83) | A measurement (spikes/phase5/bundle_suite.sh), to be mentioned as a cost, not reported alone. Not reported |
| AL | none (the cost is paid) | A request to spin, not to Spinel. Not reported |
| AM | the test runner names a test by its `test` line (spikes/NOTES.md rule 107) | **Ready to report**: spikes/phase5/backtrace.rb. Not reported; not run on master |
| AN | the sentinel default `Cookies::NO_EXPIRES` (spikes/NOTES.md rule 109) | **Ready to report**: spikes/phase5/nil_default_time.rb (SIGSEGV, exit 139; CRuby `none`, `1970`). Not reported; not run on master |
| AO | an `if` chain in `HtmlReader.parse` instead of a statement `case` (spikes/NOTES.md rule 110) | **Ready to report**: spikes/phase5/case_nullable_temp.rb (the C compile fails, `'_o1' undeclared`; CRuby `amp`, `long`). Not reported; not run on master |
| AP | no Queue is kept in an Array (spikes/NOTES.md rule 117) | **Ready to report**: the 4-line program in AP (spikes/phase5/queue_in_array.rb). Not reported; not run on master |
| AQ | `Logger::LOCK` around every log write (spikes/NOTES.md rule 116); kept either way if upstream documents the race instead | **Ready to report**: the 17-line program in AQ (spikes/phase5/stringio_threads.rb). Not reported; not run on master |
| AR | test/gen_jobs.rb builds the word `require` from pieces (spikes/NOTES.md rule 122) | **Ready to report**: the 2-line program in AR. Not reported; not run on master |
| AS | none (nothing guards the reads; spikes/NOTES.md rule 123) | Nothing yet: seen with two framework files required, the cause read from the generated C, not reduced (see AS). Not reported |

The other rules of spikes/NOTES.md (cybertrain/logger.rb alone cites
rules 18 and 19) were not re-checked on 2026.11.04.7026 when this table
was written, except 66 (its program prints CRuby's result there) and 70
(its reduced form does not show it), both on 2026-11-11 (see "Re-checked
on 2026-11-11"). The inventory of 2026-11-13 went through all of them:
the rules whose shape fits a small program were run on the pin, and
every rule is in one of the tables of "Everything on main, in one
place". What that added to this table is the rows AA to AH.

## Status at a glance

"Not re-checked" means no one has tried it on that build; it is not a claim
that it is fixed. The table has no column for matz/spinel master
494deaac, which was read on 2026-11-11 and built only for the programs
of Q, R and S on 2026-11-12, nor for master 1c0cc5e35, built
on 2026-11-13 for the reduced programs only: what master has merged for K, M,
N, O, P, Q, R, S, T, U, 5 (b) and rule 79, and what each program did on
1c0cc5e35, is in "What is asked of Spinel now".
2026.11.15.7033 has no column: its results are by rule, under "Status by
rule".

| Item | 2026.09.12 | 2026.10.25-7018 | 2026.10.26.7019 | master 9b9972399 | master 003ceda5d | 2026.10.27.7020 | fork master 49ccdced | 2026.11.04.7026 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1. A generated `new` frees its own arguments | yes | not re-checked | not re-checked | not reproduced (arguments rooted at the call site; no ASan run) | not re-checked | not reproduced under ASan, but neither on 2026.09.12 in that shape (workaround kept) | not re-checked | not re-checked (accepted, see "Accepted as Spinel constraints") |
| 2. A `to_s`-only parameter narrowed to one caller's type | yes | not re-checked | not re-checked | not reproduced (47 of 47 related test files pass without the workaround) | not re-checked | not reproduced (106 of 106 and examples/blog pass without the workaround; dropped) | not re-checked | not reproduced (106 of 106 and examples/blog pass without the workaround) |
| 3. An Array assigned to a wider local is copied | yes | yes | **fixed** | **fixed** (#10257) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked | **fixed** (its program prints Ruby's result) |
| 4. Parking a fiber goes through the monitor thread | yes (re-measured on 2026-10-30: 9.9 `futex` per request) | not re-measured | not re-measured | not re-checked | not re-checked | **fixed** (2.1 `futex` per request, none on the park path; #8702, #10024) | same counts as 2026.10.27.7020 on a minimal server; examples/blog does not build (I) | **fixed**, re-measured 2026-11-05 beside 2026.10.27.7020: 3.7 `futex` per request against 3.6, the same `epoll_wait`, `epoll_ctl` and `poll` counts (see "Re-checked side by side") |
| 5. At one worker, most collections are full, and the sweep is handed to another thread | yes (as "a collection stops every thread") | not re-measured | not re-measured | not re-checked | not re-checked | **yes**, re-measured: the stop-the-world wait is negligible at one worker (0.001 s over 2,852 collections), but 83% of collections are full (`SPINEL_GC_FULL_INTERVAL=8`: +16%) and the sweeper thread costs 5% on one CPU | not re-checked | **yes**, re-measured 2026-11-05 beside 2026.10.27.7020: 83% of collections full on both, the collector 14 to 17% of wall on both (see 5) |
| 6 and 7. Runtime cost | yes | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured (7: no stall in 6 two-worker runs of 16,000 requests, with no lock on the request path) |
| `String#to_sym` searches linearly | yes | **fixed** (hashed) | fixed | not re-checked | not re-checked | not re-checked | not re-checked | not re-checked |
| `"#{v}"` copies a String | yes | yes | yes | not re-checked | not re-checked | not re-checked | not re-checked | yes (the generated C allocates and copies) |
| A. Block call inside `instance_eval` is `NoMethodError` | no | **yes** | **fixed** | **fixed** (#10254) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked | **fixed** (its program prints Ruby's result) |
| B. `ffi_func` declared under another name | no | yes (worked around) | by design: an undeclared call is a build error; CyberTrain declares it | by design (#10255) | not re-checked | not re-checked | not re-checked | not re-checked (accepted) |
| C. Generated C that does not compile | no | yes, other shapes | **fixed** (not seen) | **fixed** (#10258, #10259); the template_engine.rb refusal is still made | not re-checked | not re-checked | not re-checked | not seen (106 of 106 pass); the template_engine.rb refusal is **fixed** (#10525), and so is the run-time `TypeError` beside it (#10524) |
| D. `String#to_i` raises `RangeError` on overflow | yes (re-checked on 2026-10-28; not a regression, see D) | yes (worked around) | yes (worked around, re-checked) | by design (raise mode); promote (experimental) parses a Bignum | by design (still raises `RangeError` in raise mode) | not re-checked | not re-checked | by design (still raises `RangeError` in raise mode; accepted) |
| E. More allocation per request | no | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured | no change against 2026.10.27.7020, measured 2026-11-05: 1% fewer objects for the same requests (see E) |
| F. A call whose result is always nil is dropped | no | **yes** | **fixed** | **fixed** (#10260) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked | **fixed** (its program prints Ruby's result) |
| G. `<<` of a binary String keeps UTF-8, then a Regexp raises | no | **yes** | **fixed** | **fixed** (#10262) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked | **fixed** (its program prints Ruby's result) |
| H. A forwarded block's value loses an application class | no | not checked (predates b6ca774) | **yes** (new; worked around) | **yes** | **fixed** (#10415) | **fixed** (test/db_with_value.rb uses the block's own value) | not re-checked | **fixed** (its two programs print Ruby's result) |
| I. A constant written `Array.new(n) { Obj.new }` is refused | no | no | no | not checked | not checked | no | **yes** (new; from 8594f2be2, matz/spinel#10527) | **fixed** (#10735, #10786: both forms of the reduced program print Ruby's result; examples/blog builds) |
| J. With the slab off, AddressSanitizer finds a thread's captured variables freed before it runs | not reproduced (2 of 2 runs under AddressSanitizer; it has no slab) | not checked | not checked | not checked | not checked | **yes** with `SPINEL_GC_SLAB=0`; the default is unknown | **yes** with `SPINEL_GC_SLAB=0` | **yes** with `SPINEL_GC_SLAB=0` (3 of 3 runs); the default is unknown |
| `OpenSSL::Digest#to_s` is untyped | no (the package has none) | yes (why 3 shows in test/http_client.rb) | **fixed** (returns a String) | **fixed** (#10256) | not re-checked | not re-checked | not re-checked | not re-checked (test/http_client.rb passes) |
| Two shapes found in review (a Hash through a chain of locals into a constant; a `case` of 17 or more Array arms) | not checked | not checked | not checked | **yes** | **fixed** (#10416, #10417) | not re-checked | not re-checked | not re-checked |
| K. `puts` on a nil-only receiver does not compile with the TLS layer in the program | not checked | not checked | **yes** (rule 78; worked around) | not checked | not checked | not checked | not checked | **yes** (worked around; reduced, fix tested, see K) |
| L. `SPINEL_WORKERS=N` counts main, which a server keeps waiting | no (N helpers beside main) | not checked | not checked | not checked | not checked | **yes** (checked 2026-11-05: its reduced program uses 1.01 CPUs at N=2, 1.97 at N=3) | not checked | **yes** (from #9840; worked around; 1.01 CPUs at N=2, 1.97 at N=3, the same on 2026.11.03.7025, so not new here) |
| Rule 79. A rescuing method's value, from a block that only raises, does not compile when appended | not checked | not checked | not checked | not checked | not checked | **yes** (checked 2026-11-05) | not checked | **yes** (found 2026-11-04; also on 2026.11.03.7025, so not new here) |
| M. `gets` on STDIN does not flush a partial STDOUT line first | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (rule 83; worked around with `flush`) |
| N. A method's return type does not follow an ivar widened through an `attr_accessor` writer | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (Daicho's report, 2026-11-05; re-checked here, and the same on 2026.11.03.7025, so not new here; still on master 60381c464 per the report) |
| O. `TCPSocket.new` ignores `connect_timeout:` | yes (docs/design.md D24: "60 seconds or more against an unreachable address") | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (Daicho's report; re-checked here, and the same on 2026.11.03.7025; still on master 60381c464 per the report) |
| P. Net::HTTP against a TLS peer that never answers does not return at the timeout | yes, as "the handshake and the reads are blocking C calls" (D24) | not checked | not checked | not checked | not checked | yes: returns at the timeout, but other threads stop meanwhile (the report) | not checked | **yes**: does not return at all (the report, 40 s; here it returns only when the peer closes, 30 s, the same on 2026.11.03.7025); **fixed** on matz/spinel master dcc46945c (2026-11-05), in no fork tag yet |
| Q. A Range of Time or Date raises at construction; a Float Range is not a Range once boxed | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 2 spike, 2026-11-06; re-run 2026-11-15, when the String Range the title named until then was matched; phase 2 routes non-Integer bounds through `where_between`) |
| R. A `rescue` arm naming an undefined qualified class matches by its last segment, or swallows every exception | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 3 spike, 2026-11-09; rule 89) |
| S. A `yield` passed as an argument runs the block twice when blocks differ in type | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 3, 2026-11-09; rule 90) |
| T. `exit` on a thread other than the main one ends only that thread | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 3, 2026-11-09; rule 91) |
| U. A `def` inside a block that never runs defines the method anyway | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 4a spike, 2026-11-10; rule 93) |
| V. `strftime` with a built pattern on a Time or Date returns the pattern | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 4a, 2026-11-11; rule 96) |
| W. An ivar String passed to a stored lambda is refused | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 4a, 2026-11-11; rule 97) |
| Y. A lambda written into a module-body ivar never learns its parameter's type | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (rule 82, found 2026-11-05; its program re-run 2026-11-11) |
| Z. A stored block called with a base-class receiver runs the base class's method, not the override | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (rule 88, found 2026-11-06; reduced and run 2026-11-11) |
| Rule 66. Direct appends to a String local lose what a helper appended through a parameter | yes (found on it) | not checked | not checked | not checked | not checked | not checked | not checked | **not reproduced** (its program prints CRuby's result, 2026-11-11) |
| X. Type inference does not converge in examples/blog's generator | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 4a, 2026-11-10; rule 94) |
| AA. A method that holds a block allocates its closure cells on entry | no (allocates none for the same source line) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (found 2026-11-05; in the generated C of main on 2026-11-13) |
| AB. A foreign call holds its OS worker, with or without `blocking: true` | yes (rule 80: the option was accepted and ignored) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-13: `ticks=1` at one worker) |
| AC. `URI.decode_www_form_component` is quadratic on non-ASCII text | yes (rule 49: 517 ms for 50,000 bytes, 8.5 s for 200,000) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-04, and 2026-11-13: 119 ms and 1,949 ms) |
| AD. `String#byteindex` accepts an offset inside a character | yes (rule 52) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-04 and 2026-11-13) |
| AE. `Class#superclass` on a package's exception class is NoMethodError | yes, and for the program's own classes too (rule 54) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** for `JSON::ParserError` (2026-11-11 and 2026-11-13); the program's own classes give CRuby's chain |
| AF. `Float#round(n)` on a Float narrowed by a `case` rounds the binary product | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (rule 100, found 2026-11-11; its program re-run 2026-11-13) |
| AG. `TCPServer.new` on a port in use raises `Errno::ECONNREFUSED` | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-13) |
| AH. `JSON.generate` writes a Float in another form than CRuby's | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-11 and 2026-11-13) |
| AI. A large Hash literal constant takes cc 13 s | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 4b spike, 2026-11-11; rule 101) |
| AJ. `Class#superclass` on Ruby's own exception classes is NoMethodError (with a package required or a module defined) | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5a spike, 2026-11-12; narrowed 2026-11-15, a bare program passes; rule 104) |
| AK. The C of a very large program needs more memory to compile than its front end | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5a, 2026-11-12) |
| AL. `spin run gen` rebuilds the generator when a test file changes | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5a, 2026-11-12; rule 108) |
| AM. A release build has no backtrace | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5a spike, 2026-11-12; rule 107) |
| AN. A parameter defaulting to nil, given a plain Time by a caller, is a non-nullable Time | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5a, 2026-11-13; rule 109) |
| AO. A statement `case` on a plain Integer takes an earlier nullable case's temporary number | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5a, 2026-11-13; rule 110) |
| AP. `pop(timeout:)` on a Queue that was put in an Array is `Array#pop` | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5b, 2026-11-13, reduced 2026-11-14; rule 117) |
| AQ. Four threads writing one StringIO with no lock crash the program | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5b, 2026-11-13, reduced 2026-11-14; rule 116) |
| AR. A require-shaped line inside a regex literal is read as a require | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-14, reduced 2026-11-15; rule 122) |
| AS. `ENV[name]` with a key held in a variable can answer the key | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-15, in a program that requires two framework files; rule 123) |
| AT. `File#stat` on an open File stats its path, not the descriptor | not checked | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (phase 5b, 2026-11-13; rule 112) |
| AU. `String#strip` on a String with an invalid byte returns it | yes (rule 52) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** (2026-11-15 and 2026-11-19; rule 52) |
| Rule 17. A class used above its definition runs, where CRuby raises NameError | yes (rule 17, recorded for constants read before their definition) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** for a class name (2026-11-15); a constant assigned with `=` raises NameError as under CRuby |
| Rule 27. `IO#gets` on a socket answers a UTF-8 character String; socket bytes append to a UTF-8 String where CRuby raises | yes (rule 27, recorded for socket buffers generally) | not checked | not checked | not checked | not checked | not checked | not checked | **yes** for `gets` and for the append (2026-11-15); `readpartial`, `read(n)` and `read_nonblock` answer byte Strings as under CRuby |

## Status by rule

What each rule's program did on a build: one table per pin, the newest
first. The numbers are the rules of [spikes/NOTES.md](../spikes/NOTES.md);
"Item register" says which item a rule belongs to. "Status N", in a
comment or a document of this repository, means row N of the tables here:
read the newest first; each row says what its build did. Paths that begin
`rechecks/` are under `spikes/`.

- **Still there**: the program still differs from CRuby or does not compile.
- **Reduced program passes**: the rule's own reduced program prints Ruby's
  result. The failure was not reproduced in that shape; this does not prove
  its cause is gone in every program.
- **Probe passes**: a small program of the shape the rule describes prints
  Ruby's result, but the rule was seen in a larger program and never
  reduced, so this does not show that it is gone.
- **Not re-checked**: no one has tried it on this build. That is not a
  claim either way.

Compiler evidence and project policy are separate. A passing probe is not
a licence to drop an active workaround: keep it until a dedicated change
removes it with a test of the affected framework shape. Rule 77 is already
retired; capability notes, ordinary Ruby behaviour and historical measurements
are not blanket coding prohibitions. For a rule with several observations,
a passing subcase does not clear the rest. See spikes/NOTES.md,
"Maintaining this inventory", for the evidence needed to change a status.
Every workaround of "Tied to a build" there stays in place on
2026.11.15.7033.

### On 2026.11.15.7033

Checked on 2026-11-14 with Spinel 2026.11.14.7031 (2e505bd45), repeated
on 2026-11-15 with 2026.11.15.7032 (3203cff1a) and again with
2026.11.15.7033 (a2f3bfaaf), the pinned `Cybertrain::SPINEL_TAG`, built
from source, by compiling each re-checked
rule's reduced program (or, where the rule has none, a small probe of the
shape it describes) and comparing its output with CRuby 4.0.7's
(`LANG=en_US.UTF-8`, `TZ=UTC`; the 2026.11.04.7026 section compared with
CRuby 3.3). Each program was also compiled with 2026.11.04.7026
(a2d06115f), the previous pin, as a control, so that a pass on this pin is
a change of the compiler and not of the program. All on macOS arm64
(Darwin 27.2, Apple clang 21.0.0), `spinel prog.rb -o prog` with no flags
unless the row says so, with the new reduced programs kept in
`spikes/rechecks/2026.11.15.7033/` and their binaries and outputs outside
the package (rule 98). A concurrent `spin test` kept
the load average between 75 and 87, so the timings below are under load.
On 2026.11.15.7032 and on 2026.11.15.7033 every program was compiled and
run again and printed what it printed on 2026.11.14.7031, line for line
(rule 49's timings and rule 116's runs vary from run to run, within what
the rows give); the rows give the 2026.11.14.7031 run. 2026.11.14.7031 was
not pinned: it refused `Date.new` with an Array element (`Date.current`,
cybertrain/clock.rb) and resolved `Time.utc` beside test/cron.rb's
top-level `utc` to that method, both fixed upstream (matz/spinel#11895,
#11896). 2026.11.15.7032 was not pinned either: a method that a class
inherits, called through a dispatch over several classes, ran the parent's
first definition after the parent redefined it, so test/command_e2e.rb's
`failing` app ran `Cybertrain::TestCase#setup` in place of the test's own;
fixed upstream (matz/spinel#11919) and in 2026.11.15.7033.
Only the rows that were **Still there** on 2026.11.04.7026, and rule 112,
were re-checked; the rules that were seen only in the whole framework (94,
96, 97) are left to that pin's `spin test` and examples/blog run.

Rows 17, 27, 52 (its `strip` half), 122, 123 and the last row were added on
2026-11-21 from runs on another machine; each names its platform and its
CRuby.

| Rule | On 2026.11.15.7033 |
| --- | --- |
| 2 | **Still there**, as on 2026.11.04.7026. A block stored in a module's Array and run with `C.new.instance_exec(&b)` compiles on both pins and raises "instance_exec of a proc whose self spinel cannot rebind (NotImplementedError)" when reached; CRuby prints `7`. A proc held in a local and passed straight to `instance_exec` prints `7` on both pins. |
| 17 | **Still there** for a class name, run on 2026-11-21 on Linux x86_64 (gcc 13.3.0, `-O 0`) beside CRuby 3.3.6, not on the machine of the rows below: the two lines `puts Later.new.hi` and `class Later; def hi = "hi"; end` print `hi` compiled, where CRuby raises "uninitialized constant Later (NameError)". 2026.11.04.7026 printed `hi` in the same run. The half about a constant assigned with `=`, which raises NameError as under CRuby, is rechecks/constant_order.rb (the last row). |
| 27 | **Split**, run on 2026-11-21 on the same Linux machine and tools as row 17. Probe passes for `IO#gets`: the program of row 27 of the next table (a thread writes `"café 日本\n"` to an accepted socket, the client prints `line.encoding`, `line.size` and `line.bytesize` of `cl.gets`) prints `ASCII-8BIT`, `13`, `13`, as under CRuby; 2026.11.04.7026 printed `UTF-8`, `8`, `13` in the same run. **Still there** for the append: `require "socket"; srv = TCPServer.new("127.0.0.1", 0); t = Thread.new { c = srv.accept; c.write("café 日本\n"); c.close }; cl = TCPSocket.new("127.0.0.1", srv.addr[1]); buf = cl.readpartial(64); t.join; u = +"é"; begin; u << buf; puts "appended #{u.bytesize}"; rescue => e; puts "#{e.class}"; end` prints `appended 15` compiled and `Encoding::CompatibilityError` under CRuby; 2026.11.04.7026 printed `appended 15` in the same run. Neither program is saved under spikes/: both are inline, the first in the next table and the second here. `readpartial`, `read(n)` and `read_nonblock` are rechecks/socket_shapes.rb (the last row). |
| 25 | **Still there**, by design (docs/spinel-feedback.md D): `"99999999999999999999".to_i` raises "RangeError: integer overflow parsing "99999999999999999999"" on both pins; CRuby 4.0.7 returns the Bignum. |
| 49 | Reduced program passes (docs/spinel-feedback.md AC): decoding e-acute + 50,000 / 100,000 / 200,000 bytes takes `0 0 0` ms (`0 0 1` in one run of three), against `76 384 2435`, `84 447 2470` and `88 389 2513` on 2026.11.04.7026; CRuby prints `0 0 0`. |
| 52 | Reduced program passes (docs/spinel-feedback.md AD): `"a=1&\x81b=2".byteindex("b", 4)` raises IndexError, as under CRuby; 2026.11.04.7026 prints `5`. The `strip` half of the rule was not run for this row. Run on 2026-11-21 (Linux x86_64, gcc 13.3.0, CRuby 3.3.6, `-O 0`; rechecks/differing/invalid_utf8.rb): both `byteindex` lines raise IndexError, as under CRuby, and `" x\x81 ".strip` is **still there** (docs/spinel-feedback.md AU): it returns `"x\x81"` where CRuby raises Encoding::CompatibilityError. 2026.11.04.7026 printed `5`, `3` and `"x\x81"` in the same run. |
| 54 | Reduced program passes for the half that failed (docs/spinel-feedback.md AE): `e.class.superclass.name` for a rescued `JSON::ParserError` prints `JSON::JSONError`, as under CRuby; 2026.11.04.7026 raises "undefined method 'superclass' for module JSON::ParserError (NoMethodError)". The user-class half still matches: rechecks/exception_shapes.rb prints its `.expected` on both pins. |
| 78 | Reduced program passes (docs/spinel-feedback.md K): `@io.puts(line)` on a nil-only `@io` with `require "openssl"` builds and prints `ok`; on 2026.11.04.7026 cc stops with "incompatible pointer types passing 'sp_String *' ... to parameter of type 'const char *'" (sp_io.h). |
| 79 | Reduced program passes (docs/spinel-feedback.md, "Rule 79"): `out << g { raise "b" }` builds and prints `["b"]`; on 2026.11.04.7026 cc stops with "variable has incomplete type 'void'" (spinel_rt.h, `SP_STR_HDL`). |
| 80 | **Still there** for `blocking: true` and for no option (docs/spinel-feedback.md AB, the 600 ms `nanosleep` program, three runs each): at `SPINEL_WORKERS=1` it prints `ticks=1` on both pins, at `SPINEL_WORKERS=2` `ticks=10` (once `ticks=9`). The pin adds `ffi_func ... offload: true` (docs/FFI.md, "`offload: true` (Spinel's own)": the C function runs on a pool thread while the caller waits as for I/O; it implies `blocking: true`, and is refused for a variadic function or in a program with an `ffi_callback`). With `offload: true` the same program prints `ticks=10` (once `ticks=9`) at one worker and at two, and still takes 0.61 s, so the call ran its full 600 ms while the worker ran main. 2026.11.04.7026 accepts `offload: true` without a word and prints `ticks=1` at one worker. |
| 81 | Reduced program passes (docs/spinel-feedback.md R, the third program): `rescue Inner::Oops` inside `Outer::User` prints `oops` with no warning; 2026.11.04.7026 warns "uninitialized constant Inner: defined nowhere in the program" and prints `none`. |
| 82 | Reduced program passes (docs/spinel-feedback.md Y): a lambda literal in a module-body ivar, called through a reader with a `Ctl`, prints `sess`; 2026.11.04.7026 raises "undefined method 'session' for an instance of Integer (NoMethodError)". docs/spinel-feedback.md recorded the same failure on matz/spinel master 1c0cc5e35, so the fix is later than that commit. |
| 83 | Reduced program passes (docs/spinel-feedback.md M), run under a pty from CRuby's `PTY.spawn`: `A> ` is shown before a line is typed and `got hi` after it, as under CRuby; 2026.11.04.7026 shows nothing until the line is typed and then `A> got hi`. |
| 86 | Reduced program passes (docs/spinel-feedback.md Q, both programs, with a small `check` / `eq` in place of `test` / `assert_equal`): all six cases pass, as under CRuby; on 2026.11.04.7026 the boxed Float Range answers `[]`, and `t1..t2` in a Hash value and `Range.new(t1, t2)` raise "TypeError: no implicit conversion of Time into Integer". A probe of a Range of Dates (`d1..d2`, `begin`, `end`, `cover?`) prints CRuby's `2026-01-01 2026-02-01 true false`; 2026.11.04.7026 raises "no implicit conversion of Date into Integer (TypeError)". |
| 88 | Reduced program passes (docs/spinel-feedback.md Z): a block registered in `Sub`'s body and called with `self` from `Base#run` reaches `Sub#hook` and prints `"sub"`; 2026.11.04.7026 prints `""`. docs/spinel-feedback.md recorded `""` on master 1c0cc5e35 too. Rule 111's narrowing (the block before the override's `def`) is the shape of this program. |
| 89 | Reduced programs pass (docs/spinel-feedback.md R, the first two): `rescue Outer::Missing` beside a top-level `Missing` raises NameError from the arm (`outer NameError: uninitialized constant Outer::Missing` when wrapped), where 2026.11.04.7026 prints `rescued by Outer::Missing`; `rescue Outer::Mailer::TimeoutError` beside `Outer::Net::TimeoutError` lets the caller see `["NameError"]`, where 2026.11.04.7026 prints `[]`. Both pins still warn "uninitialized constant Outer::Mailer: defined nowhere in the program" for the second. |
| 90 | Reduced program passes (docs/spinel-feedback.md S): `C.str(yield)` with a String block and an Integer block prints `one 42 a`; 2026.11.04.7026 prints `one 42 a,a`. |
| 91 | Reduced program passes (docs/spinel-feedback.md T): `exit(1)` on a thread spawned through a method ends the process with status 1 and no output, as under CRuby; 2026.11.04.7026 prints `main still alive` and exits 0. |
| 92 | **Split.** The program of the rule (`included do before_action :require_admin, only: [:index] end`, with `ActiveSupport::Concern#included(base = nil, &block)` doing nothing) builds and prints `built`; 2026.11.04.7026 refuses it ("unsupported call: ... (CallNode `before_action`) recv=-/ty-1", 1 refusal). This follows from U's fix (rule 93): a block handed to a method that never uses its block is left out. **Still there**, by design, when `included` keeps its block (`@included = block`): both pins refuse the same call. gen's blanked copies in `gen/concerns/` are unaffected either way. |
| 93 | Reduced program passes (docs/spinel-feedback.md U): prints `false false`, as under CRuby; 2026.11.04.7026 prints `true false`. |
| 94 | Not reduced: covered by the suite/blog run on this pin, which passes (`spin test` 239 of 239; examples/blog regenerates with no change and `cybertrain test` passes 157 tests) (examples/blog's `spin run gen`, with `Gen::Runner`'s separate scans still in place). |
| 96 | Not reduced: covered by the suite/blog run on this pin. The framework still walks the pattern itself (`Cybertrain::Strftime.walk`), so that run does not exercise `strftime` with a built pattern. |
| 97 | Not reduced: covered by the suite/blog run on this pin. `Component` still passes `"#{@name}"`, so that run does not exercise the ivar form. |
| 100 | Reduced program passes (docs/spinel-feedback.md AF): `round_scale` prints `1.01`, `1.01`, `0.29`, as under CRuby; 2026.11.04.7026 prints `1.01`, `1.0`, `0.28`. spikes/decimal/float_round.rb prints CRuby 4.0.7's output line for line ("through a case/when: 1.01 1.01"); 2026.11.04.7026 still prints "1.0 1.0". CRuby 4.0.7's `JSON.generate` now writes `0.00000001` and `1e+20`, as Spinel does (AH, which CRuby 3.3 wrote `1.0e-08` and `1.0e+20`). |
| 101 | **Still there** in the generated C: spikes/phase4b/locale_hash.rb's 1,980 pairs are still 1,980 `sp_StrStrHash_set_e` calls in one function, `_sp_main_body`. The cost was not reproduced on this machine on either pin, so it is not shown here either way: `spinel --timing` puts cc_total at 1.4 to 1.5 s (three builds) against 3.3 to 6.7 s on 2026.11.04.7026, and locale_hash_split.rb at 4.0 s and 5.0 s. The rule's 12.5 to 15.2 s were gcc on Linux; re-measure there. The binary's lookups print what CRuby prints. |
| 104 | Reduced program passes. spikes/phase5/assert_raises.rb with `matches?` walking `superclass` to the top and no `BUILTIN_PARENTS` (the spike's first version, `--strict-require -I .`) prints CRuby's 14 lines; 2026.11.04.7026 raises "undefined method 'superclass' for module RuntimeError (NoMethodError)" after three. The spike as saved prints CRuby's lines on both pins. The six lines of docs/spinel-feedback.md AJ print `StandardError` on both pins on this machine, so they are not a control. |
| 107 | **Still there**: with spikes/phase5/backtrace.rb (`--strict-require -I .`), a release build answers 0 frames for both raises. `-g` answers one `<main>` frame and `--debug` four for the raise three methods deep, as before, but `<main>` now carries its line (`backtrace.rb:60`, `:66`) where 2026.11.04.7026 says line 1; CRuby 4.0.7 also gives `Kernel#Integer` a frame, quotes with `'` and not a backtick. |
| 109 | Reduced program passes (spikes/phase5/nil_default_time.rb): prints `none` and `1970`, as under CRuby; 2026.11.04.7026 dies with SIGSEGV (exit 139). nil_default_time_fixed.rb prints CRuby's three lines on both pins. |
| 110 | **Still there**: spikes/phase5/case_nullable_temp.rb does not compile on either pin ("use of undeclared identifier '_o1'; did you mean '_t1'?" at line 65); CRuby prints `amp` and `long`. |
| 112 | **Still there**: spikes/phase5/flock_fstat.rb prints the same lines on both pins; they differ from CRuby's only in "a.stat names the new file" (CRuby: "old"). `flock` and `IO.for_fd(...).stat` agree with CRuby. |
| 116 | **Still there**: spikes/phase5/stringio_threads.rb (`SPINEL_WORKERS=4` set by the program) printed nothing in fourteen runs of fifteen on this pin (of the ten whose status was kept, nine exited 134 and one 133); one run printed `2432000`, CRuby's answer. 2026.11.04.7026 printed nothing in fifteen runs of fifteen (exit 134 in all ten whose status was kept). |
| 117 | Reduced program passes (spikes/phase5/queue_in_array.rb): prints `"hello"` and `"direct"`, as under CRuby; 2026.11.04.7026 raises "no implicit conversion of Hash into Integer (TypeError)". |
| 122 | **Still there** (docs/spinel-feedback.md AR), run on 2026-11-21 on Linux x86_64 (gcc 13.3.0, `-O 0`) beside CRuby 3.3.6, not on the machine of the rows above: with rechecks/differing/require_in_regex.rb, `--strict-require` stops the build ("cannot load such file", naming the text of the regex), and without the flag the build warns that the require is ignored and the program prints `no match`, where CRuby prints `db`. 2026.11.04.7026 did the same in the same run. |
| 123 | **Still there** (docs/spinel-feedback.md AS), run on 2026-11-21 on the same Linux machine and tools as row 122: rechecks/differing/env_nonliteral_key.rb, built with `spinel -I .` from the repository root (the framework at 79b38b68), prints `set: CYBERTRAIN_RECHECK_HOST` and `unset: default`, as 2026.11.04.7026 did in the same run; the value, `0.0.0.0`, was expected. Not reduced. |
| 1, 3 to 16, 18 to 24, 26, 28 to 48, 50, 51, 53, 55 to 77, 84, 85, 87, 95, 98, 99, 102, 103, 105, 106, 108, 111, 113 to 115, 118 to 121 | Not re-checked on this pin with a program of their own. Their status on 2026.11.04.7026 is in the next section, "On 2026.11.04.7026"; it is not carried over. The saved probes that hold a shape of some of them were run on 2026-11-21: the last row. |
| rechecks/run.sh | Run on 2026-11-21 on Linux x86_64 (gcc 13.3.0, `-O 0`, CRuby 3.3.6): all nineteen programs of rechecks/ compiled and printed their `.expected`. That is a **Probe passes** for each section's own small shape, with the limits spikes/rechecks/README.md states, for the shapes of rules 1 to 12, 14, 17 to 21, 26 to 35, 37, 39 to 48, 50 to 55, 60 to 62, 69, 72, 86 and 104 that those programs hold (for 2, 17, 27, 52, 54, 72, 86 and 104 only the half that already matched CRuby on 2026.11.04.7026). 2026.11.04.7026 was not run beside it that day. |

### On 2026.11.04.7026

Checked on 2026-11-04 with Spinel 2026.11.04.7026 (a2d06115f), the pinned
`Cybertrain::SPINEL_TAG`, built from source, by compiling each re-checked
rule's reduced program (or, where the rule has none, a small probe of the
shape it describes; the rules marked "Not re-checked" were not run) and
comparing its output with CRuby 3.3's. The recorded 2026-11-04 run passed
106 of 106 framework programs; this is a historical count, not the current
suite size or a new test result. Later entries state their own observation dates.
The 2026-11-11 document audit checked all 98 rule IDs for status coverage; it
did not re-run all 98 behaviours. Records 99 to 123 were added after that
audit, each with its own status row. Fresh, saved probes are described in
spikes/rechecks/README.md; the rows dated 2026-11-15 rest on the probes of
that day, saved as described there.

| Rule | On 2026.11.04.7026 |
| --- | --- |
| 1 | Computed `send` over 150 method names and `respond_to?` pass a probe; the compiler documentation caps such dispatch at 1024 arms. The original 128-literal limit is historical. `public_send`, `instance_variable_get` and `const_get` with a non-literal name also pass a probe (2026-11-15, rechecks/dispatch_shapes.rb: two methods, two ivars, two constants, not an application's worth); the generated-dispatch policy remains. |
| 2 | **Still there** for a stored block (2026-11-15): `class C; def initialize; @v = 5; @blk = proc { 1 }; end; def keep(&blk); @blk = blk; end; def run = instance_exec(&@blk); end; c = C.new; c.keep { @v + 1 }; puts c.run` prints 6 under CRuby and is refused by Spinel ("unsupported call: CallNode `instance_exec`"); with `instance_eval(&@blk)` the refusal names `instance_eval`. A Proc held in a local and handed in as an ordinary argument (`def run(blk) = instance_exec(&blk)`) is refused too ("instance_exec/instance_eval of a proc parameter some call site hands a value spinel cannot trace to a proc literal"). A block parameter given a literal block at its call site (`def run(&blk) = instance_eval(&blk)`) and a literal block (`instance_exec(2) { \|x\| @v * x }`) compile and run (rechecks/dispatch_shapes.rb). The framework's callbacks are stored, so the policy is unchanged. |
| 7, 9, 10/34, 14, 29, 31, 40, 42, 55, 67, 68 | Probe passes. 7, 9, 10/34, 14, 29, 31, 40, 42 and 55 again on 2026-11-15, now saved: rechecks/type_shapes.rb (7, 9, 10/34, 14, 29), rechecks/dispatch_shapes.rb (31, 40, 42) and rechecks/container_shapes.rb (55: an append through a reader, a list element and a narrowed boxed value reaches the stored String). |
| 43 | Probe passes for both parts (2026-11-15): an `attr_accessor :body` writer beside another class's `def body=`, on boxed receivers, and a writer that calls a `Cast.time_or_nil`-shaped helper, given a Time and a String or only ever a Time (rechecks/type_shapes.rb, where the two writers share the helper; the probe in which nothing else called the helper was not saved). Generated models keep `attr_accessor`. |
| 8 | Probe passes (2026-11-15, rechecks/type_shapes.rb: with `when Array`, `when Hash`, `when String` and `when Integer` first, Times taken from an Array and from a Hash's values reach `when Time`, and `Array === time` is false). **Retired in part** on this pin: the `when Time` arms that only repeated the `else` (or the no-match) result are gone from cast.rb, relation.rb and validator.rb; test/query_extras.rb and test/validators.rb pass a Time through each of those `case` statements (`when Array`, `when Hash`, `when Date`, `when Range`, the numeric arms). So are those in html.rb (`tag_attributes`, `attribute_html`, `add_class_words`), template/form_builder.rb (`text_list`, `choice_option`, `group_choices?`, `options_html`'s element test, `collection_options`), `Helpers#safe_join` and template/interpreter.rb (`exec_each`, `blank?`, `index`, `zip`, `flatten_into`); test/form_tags.rb and test/template_interpreter.rb pass a Time through each. The arms with a body of their own, and those in console/printer.rb and dev/error_page.rb, were not re-checked and stay. Two later changes took out more arms that only repeated the fall-through, and their commit messages name the compiled tests left unchanged: "Views: drop the Time guard arms that only repeat the fall-through" (2026-11-15: `render_helper`, `render_collection` and `render_records` in template/helpers.rb, `ComponentCollection#initialize`, the interpreter's `block_value`) and "Rendering: drop turbo_stream_text's Time arm" (2026-11-20). |
| 12, 18, 26, 47, 53, 73, 74 | Reduced program passes (18: the class variable is also marked as a GC root, see 64). 47: `is_a?` on a superclass after `rescue StandardError`, with the raised class chosen at run time, passes in rechecks/exception_shapes.rb (2026-11-11), and again for the rule's own example (`QueryTooDeep` caught by `rescue StandardError`, `is_a?` its superclasses true, `KeyError#is_a?(IndexError)` true) in phase 5a (2026-11-12, Tasks 1 and 7). 47's last sentence (a `begin ... ensure ... end` ending a block) passes as a probe. 26 and both parts of 47 were run again on 2026-11-15 (rechecks/type_shapes.rb, rechecks/rescue_shapes.rb). |
| 54 | **Split.** For user-defined classes, walking `e.class` / `.superclass` after `rescue StandardError` gives CRuby's full chain (rechecks/exception_shapes.rb, 2026-11-11). **Still there** for a package exception: `begin; JSON.parse("{"); rescue JSON::ParserError => e; puts e.class.superclass.name; end` prints `JSON::JSONError` under CRuby, but under Spinel it raises "undefined method 'superclass' for module JSON::ParserError (NoMethodError)" (checked 2026-11-11). A fallback that walks ancestor names is still unavailable for such classes. Rule 104 is the same failure for Ruby's own exception classes, and its row says in which programs it was seen. |
| 25 | **Still there**, by design (docs/spinel-feedback.md D). |
| 28 | Probe passes: `URI.decode_www_form_component("%ZZ")` raises ArgumentError as under CRuby; so do `a%`, `%4` and `%` (2026-11-15, rechecks/io_shapes.rb). |
| 32 | The shape described (a yielding method with `rescue => e` called from a block nested in another block) compiles and runs, also when the inner block only raises (2026-11-15, rechecks/rescue_shapes.rb). What still fails is rule 79's narrower trigger, the value of such a call appended (`out << g { raise "b" }`). Rule 45's shape passes as a probe (2026-11-13, docs/spinel-feedback.md 1.2; again 2026-11-15, see 45). |
| 38 | Not a Spinel rule: CRuby raises NoMethodError too (a protected method is callable only with an instance of the class as `self`, not from a class method). |
| 44 | Probe passes for each part (2026-11-13, docs/spinel-feedback.md 1.2; again 2026-11-15, rechecks/rescue_shapes.rb): `break` out of a block whose `yield` sits inside `begin/rescue`, `return` in a block given to a user-defined yielding method (it leaves the enclosing method, as under CRuby), and `break` in a block forwarded as `&block`. `DB.transaction`'s block still must not `break` or `return`. |
| 46 | `Class#name` now carries the namespace, as under CRuby, for a rescued `JSON::ParserError` and for user-defined nested classes (rechecks/exception_shapes.rb, 2026-11-11). A Hash literal of Strings later given an Integer and an Array works as a probe (2026-11-15, rechecks/type_shapes.rb, which also recurses 5,000 small frames deep on a Thread); the depth at which nested template renders overflow a thread stack was not re-measured. |
| 48 | Probe passes: `klass = JSON::ParserError` is a value and `rescue klass` catches with it, and passing the constant to a registering class method from a class body works (2026-11-15, rechecks/json_error_shapes.rb). The framework's own `rescue_from(JSON::ParserError)` has no test in `test/`; on 2026-11-20 rechecks/differing/rescue_from_json_error.rb compiled and ran it on `Cybertrain::Controller`: a block handler and a `with:` handler each answer for an action's `JSON.parse("{")`, and with no handler the error is re-raised out of `process`. Three small controllers in one program, `-O 0`, compiled side only (the header says why). |
| 49 | **Still there**: decoding e-acute + 50,000 / 100,000 / 200,000 bytes takes 224 / 855 / 3,668 ms (quadratic). |
| 51 | Probe passes for both parts (2026-11-15 for the second; rechecks/container_shapes.rb): `Hash#keys` next to a user class's `keys` dispatches, and one class's readers doing `key.to_s` take Symbol and String keys in one program. The rule was seen in test/router.rb with the framework's `Params` and never reduced, so not conclusive. |
| 52 | **Still there**: `"a=1&\x81b=2".byteindex("b", 4)` returns 5 where CRuby raises IndexError, and `" x\x81 ".strip` returns the String where CRuby raises Encoding::CompatibilityError (2026-11-15, rechecks/differing/invalid_utf8.rb). `split` on such a String now raises ArgumentError as under CRuby, and `index` with a String needle raises on neither (rechecks/invalid_utf8_shapes.rb). |
| 56 | `String#to_sym` is hashed since 2026.10.25-7018 (docs/spinel-feedback.md); the rest was not re-checked. |
| 60 | Reduced program passes (the NUL byte and what follows are kept). |
| 61 | Probe passes: `rescue JSON::ParserError, StandardError` catches `JSON.generate`'s NestingError, and so does `rescue StandardError` alone (2026-11-15, rechecks/json_error_shapes.rb); `rescue JSON::ParserError` alone catches it too, and on a Thread it is caught and the `ensure` runs (rechecks/json_nesting_shapes.rb). **Retired** as a clause with 33 on 2026-11-20, see there; what the rule says about an escaped thread's `ensure` was not re-run. |
| 62 | Reduced program passes: with `require "openssl"`, `getbyte` on a boxed String prints 97, and the C has no `sp_nomethod_msg("getbyte"` switch. |
| 66 | Reduced buffer-append program passes. The separate `TimeZone#name` collision in the whole framework was not re-checked; do not treat it as cleared. |
| 64, 65 | Marked / rooted in the shape checked (docs/spinel-feedback.md, "From spikes/NOTES.md"). |
| 69 | Probe passes in a small program (2026-11-13, docs/spinel-feedback.md 1.2; again 2026-11-15, rechecks/block_call_shapes.rb): a `&block` method with `ensure` or `rescue` compiles and runs them, and a Proc passed two levels down is called with a user-class argument whose method the block calls. The rule was seen in the framework (DB.transaction -> Pool -> Connection), so not conclusive; the framework keeps the one-level form. |
| 70 | Probe passes in a small program; the rule was seen only with the whole framework required, so not conclusive. The aliased short name was not run again. Seen beside it on 2026-11-20: three clauses that named `Cybertrain::DB::Error` in full ahead of `StandardError` (`Poller.tick`, `HealthCheck.feed_rows`, `FeedTableWriter#status_withdraw`) are `rescue StandardError` alone and still catch it compiled (test/health.rb and test/features_feeds.rb drop the status table and get the fail-open answer). That shows a `DB::Error` is caught as a `StandardError` there, not that a short name matches. |
| 71 | As recorded (2026-11-15, `spinel --emit-rbs`): `case v when Hash then v else {} end` is `(untyped) -> untyped`, and the copy into a seeded Hash is `(untyped) -> Hash[String, untyped]`. An inference fact, not a miscompile. The program is short enough to stay in the rule; it is not saved, since `run.sh` compares output and not signatures. |
| 72 | Probe passes for six parts on Linux (2026-11-15 for the last four; rechecks/outbound_socket_shapes.rb): an unresolvable name raises SocketError, `entry[3]` indexes a `getaddrinfo` entry, `IPSocket.getaddress` and `Addrinfo.tcp` exist, a second `connect_nonblock` on a refused socket raises `Errno::ECONNREFUSED` (its message has strerror text, worded "Connection refused @ connect - " where CRuby says "Connection refused - connect(2) for 127.0.0.1:1"), and `Errno::ECONNREFUSED::Errno` compiles. **Still there**: `connect_timeout:` is ignored (docs/spinel-feedback.md O; on 2026-11-19 `TCPSocket.new("127.0.0.1", port, connect_timeout: 1)` against a full `listen(0)` queue raised IO::TimeoutError after a second under CRuby and was still waiting compiled when it was killed after 20). `Socket#bind(sockaddr)`, the openssl package notes and macOS were not re-checked. |
| 75 | Probe passes: Kernel `spawn` and `Process.spawn` compile and `Process.wait` reaps the child. `VACUUM INTO` was not re-checked. Phase 4a relies on it: test/rate_limit_store.rb spawns its own binary with `Process.spawn` and reaps it with `Process.wait(pid)` (2026-11-10). |
| 76 | Matches CRuby: a bare `DB` outside `module Cybertrain` raises NameError, as under CRuby. The rule stays: such code must spell `Cybertrain::DB`. |
| 77 | **Retired workaround** since 2026.10.27.7020; reduced program passes on this pin and `test/db_with_value.rb` covers both forms. |
| 78 | **Still there** for the reduced program (docs/spinel-feedback.md K; rechecks/differing/nil_only_puts_openssl.rb fails in the C compiler, 2026-11-15 and 2026-11-19). The framework no longer shows it: with `@io.puts(line)` put back into `Logger#write_now`, the rule's three lines and test/logger_tls.rb both compile at `-O 0`, and the test matches its snapshot (2026-11-19). So test/logger_tls.rb does not fail without the workaround today; the workaround stays because the reduced program fails. |
| 79 | **Still there**: found on this build (its reduced program does not compile), and not new in it: the same program fails the same way on 2026.10.27.7020 and 2026.11.03.7025 (checked 2026-11-05; docs/spinel-feedback.md, "Rule 79"). |
| 80 | **Still there**: found on this build, and re-run on 2026-11-13: at `SPINEL_WORKERS=1` a foreign call holds the worker, with or without `blocking: true` (docs/spinel-feedback.md AB). The option is no longer ignored on this build: it takes the worker out of the collector's stop for the call. |
| 81 | **Still there**, recorded on this build in phase 1: a relative rescue path can swallow an exception; use a defined, fully qualified class. Not freshly re-run by the document audit. |
| 82 | **Still there**: found on this build (its reduced program, a lambda literal in a module-body ivar called with an argument, prints garbage for the argument). |
| 83 | **Still there**: found on this build (a pty shows the prompt only after the line is read; docs/spinel-feedback.md M). |
| 84 | Compiler refusal by design, checked 2026-11-05 on this pin; not a runtime Ruby-equivalence claim. |
| 85 | Not a defect: found on this build, `Queue#pop(timeout:)` behaves as under CRuby. |
| 86 | **Still there** (re-run 2026-11-15, rechecks/differing/float_range_boxed.rb): a Range of Time raises TypeError when built, and a Float Range held in a Hash value or passed through a parameter that takes other types is not matched by `when Range`. A String Range in the same two places is matched, as an Integer one is (rechecks/container_shapes.rb). Only Integer bounds go through the supported query path; other bounds use `where_between`. |
| 87 | Supported capability on this pin: Ruby-defined class methods on `Time` are exercised by `test/time_ext.rb`; not a defect. |
| 88 | **Still there**: found on this build (its reduced program, a block registered in a subclass calling a method the base class stubs, runs the stub). Narrowed on 2026-11-13 (rule 111): the trigger is the block being written in the subclass's body before the override's `def`; the same block at top level, after the `def`, or capturing a base-class receiver elsewhere dispatches. |
| 89 | **Still there**: found on this build (its reduced programs, `rescue Outer::Missing` beside a top-level `Missing`, and `rescue Outer::Gone::TimeoutError` beside another `TimeoutError`, differ from CRuby). |
| 90 | **Still there**: found on this build (its reduced program, `C.str(yield)` with a String block at one call site and an Integer block at another, runs the first block twice). |
| 91 | **Still there**: found on this build (its reduced program, `exit(1)` on a thread spawned through a method while the main thread sleeps, prints the main thread's line and exits 0). |
| 92 | **Still there**: found on this build (the refusal is by design, as rule 84's is). |
| 93 | **Still there**: found on this build (its reduced program prints `true false`; CRuby prints `false false`). |
| 94, 96, 97 | **Still there**: found on this build (phase 4a, 2026-11-10 to 2026-11-11). |
| 95 | Works on this build: a record of a form that compiles, not of a defect. |
| 98 | Tool behaviour, checked 2026-11-11: generated C inside a package is refused as input and can invalidate builds. Keep probe outputs outside the package. |
| 99 | **Not a Spinel defect** (corrected 2026-11-13; recorded on 2026-11-11 as "still there", issue #188): `dup` on a user-defined class is a shallow copy that shares Array ivars, and CRuby's `dup` is shallow in the same way. A probe prints `2 2 0 5` under CRuby 3.3.6 and compiled by this build alike, and a class's `initialize_copy` is called on both (docs/spinel-feedback.md, "Written up on 2026-11-13"). The generated `<Model>Relation#dup` (D72) is what a branching relation needs under either runtime; test/relation_dup.rb fails without it. |
| 100 | **Still there**: found on this build (2026-11-11, issue #189): `Float#round(n)` on a Float narrowed by a `case` in a method whose scale is a parameter rounds the binary product (1.005 at scale 2 is 1.0; CRuby and a Float local answer 1.01). `Cast.round_digits` (D73) rounds on the decimal digits instead; spikes/decimal/float_round.rb prints both, and test/decimal_contract.rb fails without it. |
| 101 | **Still there**: found on this build (phase 4b spike, 2026-11-11; spikes/phase4b/locale_hash.rb). |
| 102, 103 | Work on this build: records of forms that compile (phase 4b spike, 2026-11-11), not of defects. |
| 104 | **Still there** in a program that defines a module (2026-11-15, rechecks/differing/builtin_superclass_with_module.rb): with `module Pkg; end` in the program, `e.class.superclass` for a rescued `ArgumentError` or `RuntimeError` raises NoMethodError. The same program without the module line walks the chain as CRuby does (rechecks/builtin_superclass_no_module.rb). A class the program defines walks its whole chain, built-in ancestors included, in the program where the built-in start fails. spikes/phase5/assert_raises.rb holds the workaround (`BUILTIN_PARENTS`) and prints what CRuby prints; it is not the reproduction. |
| 105 | Compiler behaviour checked on this build (phase 5a, 2026-11-12): the refusal depends on whether the name is defined anywhere; not a defect. |
| 106 | Works on this build: a record of a form that compiles (phase 5a, 2026-11-12), not of a defect. |
| 107 | Build-mode behaviour recorded on this build (phase 5a, 2026-11-12); the empty release backtrace is still there. |
| 108 | Tool behaviour, checked 2026-11-12: spin's freshness check for `bin/gen` counts test files and gen's outputs as inputs. |
| 109 | **Still there**: found on this build (phase 5a, 2026-11-13; spikes/phase5/nil_default_time.rb). |
| 110 | **Still there**: found on this build (phase 5a, 2026-11-13; spikes/phase5/case_nullable_temp.rb does not compile). |
| 111 | Works on this build (2026-11-13): a record of a form that compiles and dispatches, the feature registry of the optional-subsystems design, not of a defect. |
| 112 | Runtime behaviour, checked 2026-11-13 on this pin (spikes/phase5/flock_fstat.rb): `File#flock` matches CRuby; `File#stat` and `IO.for_fd` do not. |
| 113, 119 | Work on this build (phase 5b, 2026-11-13): records of forms that compile and behave as under CRuby, not of defects. |
| 114 | Found on this build (phase 5b spike item 7, 2026-11-13): how green threads are scheduled at one worker, not a defect. |
| 115 | Performance observation on this build (phase 5b spike item 9, 2026-11-13), with the limits its entry lists; not re-measured with wrk or a slow reader. |
| 116, 117 | **Still there**: found on this build (phase 5b, 2026-11-13) and reduced on 2026-11-14 (spikes/phase5/stringio_threads.rb, queue_in_array.rb). |
| 118 | How a thread test is written: CRuby hides the race, not a Spinel defect (phase 5b, 2026-11-13). |
| 120 | Tool behaviour, seen 2026-11-13: spin's freshness check for a test binary compares modification times. |
| 121 | Works on this build: a record of a form that compiles and runs (phase 5b follow-ups, 2026-11-14; test/framework_names_compiles.rb), not of a defect. |
| 122 | **Still there**, reduced on 2026-11-15 to three lines (in the rule; rechecks/differing/require_in_regex.rb): a require-shaped line inside a regex literal stops a `--strict-require` build, and without that flag the build passes with a warning and the match fails where CRuby's succeeds. |
| 123 | **Still there**: found on this build (2026-11-15; rechecks/differing/env_nonliteral_key.rb, again 2026-11-19), in a program that requires two framework files; correct once cybertrain/core is required first. Not reduced (docs/spinel-feedback.md AS). |
| 3, 19, 20, 21, 30, 33, 45, 50 | Probe passes (2026-11-13, docs/spinel-feedback.md 1.2; again on 2026-11-15, saved in rechecks/dispatch_shapes.rb (3, 30), io_shapes.rb (19), socket_bare_readpartial.rb (20), socket_shapes.rb (21), json_error_shapes.rb (33) and rescue_shapes.rb (45, 50)). 20: at `SPINEL_WORKERS=1` another green thread keeps running while one sits in a bare `readpartial` on an idle connection; the `wait_readable` stays, since its nil return is the idle timeout. 33: `rescue StandardError` and a bare `rescue` catch `JSON::ParserError`, and `rescue StandardError` catches `JSON.generate`'s `JSON::NestingError`. 33 and 61 are **retired in part**: the change "DB: rescue StandardError alone in the data layer's rollback arms" (2026-11-15) took the three-class clause out of db.rb, db/cli.rb, db/connection.rb, db/pool.rb and model.rb, checked there with a whole-framework compiled program and the transaction tests it names; Since 2026-11-20 no file under `cybertrain/` has the three-class clause (`git grep -n 'JSON::ParserError, StandardError' cybertrain` prints nothing). Four changes of 2026-11-19 and 2026-11-20 removed it, each with compiled tests whose snapshots did not change: the scheduler, the job executor and worker and the console, with test/json_rescue_background.rb added as the regression (a job handler, scheduled tasks, job threads and plain Threads raising both errors); the HTTP server, WebSocket and ErrorReporter files, with test/server.rb's `/json` and `/deep` cases; the controller, the middleware, Session and Flash (test/controller.rb, error_pages.rb, request_id.rb, session.rb, flash.rb); and dev/error_page.rb, dev/indicator.rb and test/database.rb (test/dev_error_page.rb, dev_indicator.rb, test_database.rb). Of the tests in `test/`, json_rescue_background.rb, server.rb and dev_error_page.rb (a body that does not parse, in `ErrorPage.json_dump`) raise a JSON error into a changed clause; for the controller and middleware clauses and for `Dev::ErrorPage#call` that was shown by compiled programs that were not saved (their commits describe them). `Cast.parse_json` still names the two JSON classes, in two arms and without `StandardError`; it was not changed. All of this is as `spin test` builds a program, on Linux x86_64, without GC stress. The other workarounds of this row stay until a change removes each with a test of the framework's own shape. |
| 4, 5, 6, 35, 39, 41 | Probe passes (2026-11-15; rechecks/dispatch_shapes.rb for 4, 5 and 6, rechecks/type_shapes.rb for 35, 39 and 41): an inherited class method called as `self.class.foo`, a base chain method returning `self` with a subclass's typed `first`, `Method` objects in an Array and a Hash, `obj[k] = v` on a parameter behind a chain of `call(env)` objects, `SafeString#+` with a constructing `case`, and an Array-valued `attr_accessor :target` beside a String `target`. 35 and 41 were seen in the whole framework and never reduced, so this is not conclusive. |
| 11, 37 | Cost rules, not wrong results. Probe output matches CRuby (2026-11-15, rechecks/type_shapes.rb), and for 11's probe, alone and inside that program, the generated C (`spinel -c`) keeps the two nil-initialised locals typed (`sp_String *`, `sp_oint`), not boxed. 37's generated C was not read. |
| 17 | **Split** (2026-11-15). A constant assigned with `=` and read before its assignment raises NameError compiled, as under CRuby, at top level, in a module body and in a class body (rechecks/constant_order.rb). **Still there** for a class name: `puts Later.new.hi; class Later; def hi = "hi"; end` prints `hi` compiled and raises "uninitialized constant Later (NameError)" under CRuby. |
| 27 | **Split** (2026-11-15). `readpartial`, `read(n)` and `read_nonblock` on a socket return ASCII-8BIT byte Strings, as under CRuby (rechecks/socket_shapes.rb). **Still there** for `IO#gets`: `require "socket"; srv = TCPServer.new("127.0.0.1", 0); t = Thread.new { c = srv.accept; c.write("café 日本\n"); c.close }; cl = TCPSocket.new("127.0.0.1", srv.addr[1]); line = cl.gets; puts line.encoding, line.size, line.bytesize; t.join` prints `ASCII-8BIT`, 13, 13 under CRuby and `UTF-8`, 8, 13 compiled. One more difference was seen beside it: appending a socket's bytes (with non-ASCII in them) to a UTF-8 String that holds non-ASCII raises Encoding::CompatibilityError under CRuby and appends compiled (`u = +"é"; u << buf`, not in the saved program, which must match CRuby). Framing by byte stays. |
| 36 | Probe passes for the one recorded shape, the one test/csrf_conditional.rb's header describes (2026-11-15, again 2026-11-19): `require "cybertrain/params"; require "cybertrain/middleware/session_store"; p = Cybertrain::Params.new; p.set_value("a", "1"); p.set_path(["b", "c"], "2"); puts p["a"].to_s; puts p.key?("a"); puts p.nested("b")["c"].to_s; puts p.int("a", default: 0, min: 0, max: 9)`, which never builds a `SessionStore`, compiles with `spinel -I . probe.rb -O 0 -o /tmp/probe` from the repository root without a diagnostic (about 16 seconds) and prints 1, true, 2, 1, as `ruby -I . probe.rb` does. The result belongs to the framework tree it was built against. The 2026.09.12 program that failed was not kept, and the rule was seen in larger programs and never reduced: not conclusive. |
| 15, 22, 57 to 59, 63 | Not re-checked. 22 is a measurement (docs/benchmark.md). 58 and 59 are accepted as Spinel constraints (docs/spinel-feedback.md 1 and B). |
| 13, 16, 23, 24 | Language/tool behaviour recorded in the numbered entries, not a newly re-checked compiler defect. The other such records (38, 76, 84, 85, 87, 95, 98, 99, 102, 103, 105 to 108, 111 to 115, 118 to 121) have their own rows. |

## What CyberTrain still works around

Re-checked on 2026-10-27 against matz/spinel master 9b9972399, built from
source; CyberTrain itself was then pinned to 2026.10.26.7019 (`spinel
2026.10.26.7019 (80b2f988)`), where the rows were checked on 2026-10-26
(the H row on 2026-10-27, when it was added). From 2026-10-28 it was
pinned to 2026.10.27.7020; the H row and the workarounds for 1 and 2
were re-checked there (2026-10-28). Since 2026-11-04 it is pinned to
2026.11.04.7026, where the refusal row was re-checked (2026-11-04). The
regressions that 2026.10.26.7019 fixes (A, the generated C of C, F, G,
and 3) never had a workaround in CyberTrain: it stayed on 2026.09.12,
where they do not happen, until it moved to 2026.10.26.7019. The refusal
listed under C is separate: every build checked up to 2026.10.27.7020
makes it (2026.10.26.7019, master 9b9972399 and 2026.10.27.7020), and
2026.11.04.7026 no longer does (#10525): test/template_engine.rb's
earlier form passes there, and the test is back in that form, so that
row's workaround is dropped. The first two rows are needed on every
build checked, and are accepted as Spinel's constraints; the `SafeString.of`
row did not reproduce on master 9b9972399, but is kept (see 1); the K, L
and M rows are still needed on 2026.11.04.7026. The workaround for 2 in
`Html.escape` used to be in the `SafeString.of` row; it is dropped on 2026.10.27.7020
(see 2). Master
003ceda5d fixes H (#10415), and the H row has not been needed since
CyberTrain moved to 2026.10.27.7020, which carries it (issue #90):

| Workaround | Item | On 2026.10.26.7019 | On master 9b9972399 | On 2026.11.04.7026 |
| --- | --- | --- | --- | --- |
| `extern` declarations in the `ffi_source` of cybertrain/db/sqlite_ffi.rb | B | required: an undeclared call is now a build error | required (#10255) | not re-checked (accepted) |
| `Request#content_length` answers `INT64_MAX` for more than 18 digits instead of calling `to_i` (cybertrain/http/request.rb), and `Server#body_length` answers one past the body limit (cybertrain/http/server.rb) | D | `"99999999999999999999".to_i` still raises `RangeError` | still raises `RangeError`, by design in the default `raise` mode; kept (`--int-overflow=promote`, experimental, parses it as a Bignum; see D) | still raises `RangeError` (accepted) |
| test/template_engine.rb settles the layout Hash's value types where it is built (`layout_env`) | refusal under C | the earlier form, through a local, is still refused | still refused at line 49, with #10316 merged; still refused on 2026.10.27.7020 (see "The refusal in test/template_engine.rb") | not needed: the earlier form (`git show 81778ea^:test/template_engine.rb`) passes (#10525). Dropped: the test is back in that form, and `layout_env` is gone |
| `DB.with`'s comment, and test/db_with_value.rb: an application object computed in a DB.with block goes through a local declared before it (rule 77) | H | required: the block's own value raises NoMethodError on a method call | required: both programs of H still raise `NoMethodError`; fixed on master 003ceda5d (#10415). Dropped on 2026.10.27.7020: `DB.with`'s comment no longer asks for the local, and test/db_with_value.rb also covers the block's own value | dropped (test/db_with_value.rb passes) |
| `SafeString.of` and binding arguments to locals (rule 58) | 1 | not re-checked, kept | not reproduced in the shapes checked, which 2026.09.12 roots as well (see 1); kept | not re-checked (accepted) |
| `Logger#write_now` writes with `@io.write` instead of `@io.puts` (cybertrain/logger.rb, rule 78) | K | required: `@io.puts` does not compile with the TLS layer in the program | not checked | the nine-line reduced program still does not compile; test/logger_tls.rb builds with `@io.puts` put back (2026-11-19, again 2026-11-20). Fixed on master (#11129); goes with the pin's move |
| The `server`, `worker` and `feeds` roles set `SPINEL_WORKERS` to `workers + 1` when `workers > 1` (`Application.spinel_workers_for`, cybertrain/application.rb; cybertrain/roles/*.rb) | L | not checked | not checked | required: `SPINEL_WORKERS=2` starts one helper, which main does not help. Upstream documents `N+1` for such a program (da4485a5), so this row is how Spinel is used, not a debt |
| `Console.run` flushes after the banner and after every prompt (cybertrain/console.rb, rule 83) | M | not checked | not checked | required: without it the prompt appears only after the line is read. Fixed on master (#11193); goes with the pin's move |
| `Net::TcpStream` connects with `connect_nonblock` + `wait_writable` + `SO_ERROR` (cybertrain/net/socket.rb, rule 72), not `TCPSocket.new(connect_timeout:)`; socket.rb's header and the guides say why | O | not checked | not checked | required: the keyword is still ignored (checked 2026-11-05 here and in Daicho's report). The connect stays for the deadline either way; a fix retires the sentence. Fixed on master (#11183) |
| `HttpClient` does the TLS handshake and every read itself, with bounded waits (D24), and its header comment and the guides' "why it exists" name Net::HTTP's blocking waits | P | not checked | not checked | required: against a silent TLS peer Net::HTTP does not return (Daicho's report; checked here). Fixed on matz/spinel master dcc46945c; the client stays either way (deadline, address policy), and the comment is revised when the pin carries the fix |

Every fix the fork carried is now in matz/spinel master, not only in the
fork (#10254 to #10263, and #10316). #10316 is the fork's
`fix/empty-hash-through-param`, which this document used to name for the
refusal under C; it is merged, and it does not remove that refusal (see C);
#10525 does, merged 2026-10-29.
The H row's workaround is dropped: every pin since 2026.10.27.7020 carries
#10415 (issue #90); the row stays as a record.
The row for D stays as long as CyberTrain builds in the default `raise`
mode, where the `RangeError` is by design (see D).

## Accepted as Spinel constraints

Decided on 2026-10-28: the workarounds for B, D and 1 are how CyberTrain is
written for Spinel, not debts to pay off. They are not targets for future
fixes, in CyberTrain or upstream: do not try to remove them, do not open
upstream issues or pull requests for them, and do not re-check them on
each new Spinel release. Revisit one only if Spinel itself changes the
behaviour behind it (its release notes or docs say so).

- **B, `extern` declarations in `ffi_source`.** Spinel's documented rule
  (docs/FFI.md): a fragment declares what it calls. Declaring
  `ffi_func`s under their C names inside Spinel would bring back the
  conflicting-types errors, so this is the intended way to write FFI code.
- **D, `Request#content_length` refusing more than 18 digits.** The
  `RangeError` is the default `raise` mode's intended behaviour (Matz,
  412a2200c). The guard is also correct HTTP input validation on its own: no
  real body is that long, so the request is refused either way.
- **1, `SafeString.of` and binding a String to a local before `new`.** No
  reduced program shows the bug on any build, so there is nothing to send
  upstream, and the idioms cost nothing. New code keeps following rule 58.

## Correctness

### 1. A generated `new` can free its own arguments (use-after-free)

`Foo.new(<a String made in the argument>)` allocates the object first, which
may run a collection, and roots its arguments only after that. A String
that only the argument holds (an interpolation, `code.strip`, a `+""` buffer
converted to a String) can be swept; the object keeps a dangling pointer and
a later read crashes.

- Seen as a SIGSEGV in 4 to 17% of the benchmark's seeding runs; located
  with an AddressSanitizer build (`spinel app.rb --cc=<wrapper running cc
  -fsanitize=address -fno-sanitize-address-use-after-scope -g>`,
  `ASAN_OPTIONS=fast_unwind_on_malloc=0`). Changing allocation counts moves
  the window, so unrelated commits looked like fixes.
- Today: bind the String to a local first, or pass it through an ordinary
  method (`SafeString.of`), whose parameters are rooted on entry (rule 58).
- Fix: root the arguments of the generated `new` before it allocates.

Re-checked on 2026-10-27 on matz/spinel master 9b9972399: for
`Foo.new("v#{i}".strip)` and `Foo.new("x#{i}" + "y")` the generated C roots
each argument at the call site (`SP_GC_ROOT(_t7)` before
`sp_Foo_new(_t7)`). Not reproduced in that shape; there was no
AddressSanitizer run, so this is not a claim that it is fixed in general.

Re-checked on 2026-10-28 on 2026.10.27.7020, and against 2026.09.12 for
comparison: the same two shapes, 200,000 times each in a loop, built with
AddressSanitizer, report no use-after-free on either build, and
2026.09.12's generated C roots each argument at the call site too
(`SP_GC_ROOT(_t6)` before `sp_Foo_new(_t6)`). So this shape never showed
the bug, and the check above says nothing about whether it is fixed; the
shape the benchmark crashed on has not been reduced. CyberTrain keeps
`SafeString.of` and the locals: they cost nothing, and the crash was rare
and moved with allocation counts. That check ran with the object slab on,
which hides a freed object from AddressSanitizer (the slab recycles its
slots itself; 2026.09.12 has no slab): on 2026.10.27.7020 a check has to
run with `SPINEL_GC_SLAB=0`, which found J.

### 2. A parameter used only through `to_s` is narrowed to one caller's type

`Html.escape(value)` was typed as taking an Integer because one caller
passed one; Strings passed by other callers came out as `"0"`. A parameter
of a caller that is otherwise unused is typed as an Integer the same way.

- Seen in the router tests (wrong output, no error). A two-caller program
  (`esc(1)`, `esc("abc")`) does not show it on either build; it takes the
  router tests' shapes.
- Today: callers pass `x.to_s` (rule 56); the `case value when String`
  that `Html.escape` kept on the parameter is dropped on 2026.10.27.7020.
- Fix: unify the types of every call site, or widen to untyped instead of
  picking one.

Re-checked on 2026-10-27 on matz/spinel master 9b9972399: with
`Html.escape`'s `case value when String ... else "#{value.to_s}" end`
replaced by `str = value.to_s`, the 47 CyberTrain test files that mention it
or the router (`grep -lE "Html|escape|router|Router" test/*.rb`, 843 `test`
blocks between them) all pass under `spin test`. Not
reproduced; the workaround can be reconsidered, but this check does not
prove the general case.

Dropped on 2026-10-28, on 2026.10.27.7020: with `str = value.to_s`, `spin
test` passes 106 of 106 and examples/blog's tests pass. In
test/template_integration.rb (the whole framework), `--emit-types` keeps
`value` untyped and types `str` as a String, so the byte loops still
compile to plain C. The callers' `x.to_s` (`SafeString#+`) stays.

### 3. An Array assigned to a local of a wider element type is copied

When pushes through a local make its element type wider than the Array
assigned to it, the assignment converts: `sp_PolyArray_from_int_array(...)`
makes a new Array, and every later `<<` goes to the copy. Ruby code that
picks one of two Arrays and appends to it loses the appends, silently.

```ruby
def pick(x) = x
pick("s")              # pick returns an untyped value
def f(gap)
  head = Array.new(0) { 0 }
  tail = Array.new(0) { 0 }
  tail << 1
  groups = gap ? tail : head
  groups << pick(2)    # a boxed value: groups becomes a PolyArray copy
  tail.size
end
puts f(true)           # 1 on 2026.09.12 and 2026.10.25-7018; 2 on 2026.10.26.7019 and in Ruby
```

**Fixed in 2026.10.26.7019**, together with the untyped
`OpenSSL::Digest#to_s` below, and test/http_client.rb passes there. Both
fixes are merged into matz/spinel (#10257, and #10256 for the Digest).
A `case` of 17 or more arms still copied on master 9b9972399; #10417 fixes
it, see the next section.

- Seen on 2026.10.25-7018 in test/http_client.rb: `::ffff:127.0.0.1` was
  classified as "reserved" instead of "loopback", because
  `IpAddress.parse_ipv6`'s dotted-IPv4 tail went into the copy. It surfaced
  only there because on that build `parse_ipv4`'s `s = text.to_s` is boxed
  in that program: the openssl package's `OpenSSL::Digest#to_s` returns an
  untyped value, which leaves the result of every `x.to_s` on a boxed
  receiver untyped (rule 62's remedy then no longer narrows), and the bytes
  pushed into `groups` came out boxed.
- Today: nothing; the IPv6 parser works on 2026.09.12 because the bytes
  stay typed there, and on 2026.10.26.7019 because the copy is gone.
- Fix: keep aliasing. Either widen the Array where it is made (the
  assignment shares its storage), or refuse the program at compile time
  instead of copying.

### Two shapes master 9b9972399 got wrong

Found in review of the upstream fixes, and still wrong on matz/spinel
master 9b9972399 (2026-10-27). **Fixed** by matz/spinel#10416 (the chain of
locals) and #10417 (the `case` of 17 or more arms), merged 2026-10-27:
on master 003ceda5d both print Ruby's result. As far as known neither
affected CyberTrain's own tests.

- **A Hash literal handed through a long chain of locals into a
  constant.** `a = {"x"=>1}; b = a; c = b; d = c; e = d; f = e; DEEP = f`,
  then a method that stores `DEEP["y"] = "s"`, raises `TypeError` at run
  time: "cannot store a String key with a String value into a hash Spinel
  typed as String-keyed with Integer values".
- **A `case` of 17 or more arms yielding Arrays**, assigned to a local that
  is then pushed to, loses the push: the Array is copied, as in 3.

## Runtime cost

On examples/blog, one core, about a fifth of each request was thread
hand-offs and another fifth collection and malloc/free on 2026.09.12;
neither can be changed from the application except by allocating less.
Measured on 2026.09.12; 2026.10.25-7018 was not measured (examples/blog
does not build on it, see A). 4 and 5 were re-measured on 2026-10-30 on
2026.10.27.7020, with 2026.09.12 rebuilt from source beside it (the method
is under 4): 4 is fixed. What remains of its `futex` count is the
collector's sweeper hand-off (see 5) and the monitor's time-based turns.

### Re-checked side by side: 2026.11.04.7026 against 2026.10.27.7020 and 2026.11.03.7025

Done on 2026-11-05 to see whether moving the pin from 2026.10.27.7020 to
2026.11.04.7026 cost CyberTrain anything at run time, since the tests
only say that the programs still pass. The three releases were installed
beside each other on one 4-vCPU cloud VM (2026.10.27.7020 and
2026.11.03.7025 built from source as `cybertrain setup` does,
2026.11.04.7026 from the prebuilt tree the Release workflow attaches), and
each built examples/blog from the
same CyberTrain source (ae195f4), production mode. The server ran pinned
to CPU 0 with `SPINEL_WORKERS=1`, the load came from a Python client on
the other CPUs (16 keep-alive connections, 16,000 requests a run, after
2,000 of warm-up, 30 articles seeded through the form), three runs per
release, alternated. The server used its whole CPU in every run, so
requests a second measure it; the spread between runs of one release is
up to 15% here, more than on the benchmark machine.

| `GET /articles`, one CPU, medians of 3 | 2026.10.27.7020 | 2026.11.03.7025 | 2026.11.04.7026 |
| --- | --: | --: | --: |
| Requests a second | 1,114 | 1,193 | 1,246 |
| Server CPU per request | 0.88 ms | 0.83 ms | 0.80 ms |
| p99 latency | 29.2 ms | 26.2 ms | 24.1 ms |
| OS thread context switches per request | 2.9 | 2.9 | 2.9 |
| Peak RSS | 15.6 MB | 15.7 MB | 15.8 MB |
| `GET /articles/1`, requests a second (2 runs) | 2,150 / 2,382 | 2,258 / 2,018 | 2,304 / 2,277 |

The runs of the three releases overlap on every `GET /articles` row:
requests a second were 1,023 to 1,234 on 2026.10.27.7020, 1,143 to 1,275
on 2026.11.03.7025 and 1,171 to 1,304 on 2026.11.04.7026, and p99 was
25.0 to 29.6 ms, 25.4 to 27.8 ms and 23.8 to 30.1 ms. The medians put
2026.11.04.7026 12% ahead on requests a second and 17% ahead on p99, but
one run of 2026.10.27.7020 (1,234 requests a second, p99 25.0 ms) sits
inside 2026.11.04.7026's range. On `GET /articles/1` (two runs each)
2026.10.27.7020's range covers 2026.11.04.7026's, and 2026.11.03.7025's
two runs both fall below 2026.11.04.7026's. No slowdown was seen in these
runs, but two or three runs per release neither establish a difference
nor rule out a small one either way. Alongside: the objects allocated (`SPINEL_ALLOC_REPORT`, see
E) are 1% fewer on 2026.11.04.7026 for the same requests; `futex` calls
per request are the same (see 4); the collector's cadence is the same
(see 5); the blog binary grew from 3.80 MB on 2026.10.27.7020 to 4.00 MB
on 2026.11.03.7025 and 2026.11.04.7026 (`build/bin/blog`; the runtime
gained code, among it the fork support in lib/sp_sched.c). Nothing here
is a regression of the move to 2026.11.04.7026.

Two workers, the one place a difference from an older release shows,
and it is older than 2026.11.04.7026. With the server on CPUs 0 and 1 and
`SPINEL_WORKERS=2` as `Application#serve` sets it today (two runs each,
alternated), 2026.10.27.7020 served 1,180 and 1,201 requests a second and
2026.11.04.7026 1,329 and 1,319, no more than at one worker on either,
and on both one OS thread had 13.7 to 15.1 s of the 16,000 requests' CPU
while the next busiest had 0.2 s: every request ran on one worker. L
explains it (since #9840 an explicit `SPINEL_WORKERS=N` counts the main
thread, which only waits in a server, and starts N-1 helpers), and since
saeki-mototsune/CyberTrain#128 `Application#serve` asks for `workers +
1`. L's reduced program (four CPU-bound threads, main joins them) gives the same
answer on all three releases here: 1.01 CPUs at `SPINEL_WORKERS=2` and
1.94 to 1.97 at 3 (1.00 at 1), on 2026.10.27.7020 as on 2026.11.03.7025
and 2026.11.04.7026. So the two-worker figures of 2026-10-09 (on
2026.09.12, +9 to 25%) were already not reachable on the 2026.10.27.7020
pin; no two-worker benchmark was recorded on it. Item 7's stall did not
show in these six two-worker runs (no lock is on the request path now).

### 4. Parking a fiber goes through the monitor thread

**Fixed in 2026.10.27.7020** (re-measured on 2026-10-30). On 2026.09.12 a
connection's fiber that parks on `wait_readable` is woken through the
scheduler's monitor thread and the scheduler lock: about 16 `futex` calls
per request on the benchmark machine, 10 on the one below.

Both builds compiled from source on one 4-vCPU cloud VM, examples/blog in
production mode, `SPINEL_WORKERS=1`, `GET /articles`, 16 keep-alive
connections, 8,000 requests from a Python client that tops out near 2,700
requests a second, so the rates are not comparable here and the counts
are. Syscalls from `strace -f -c`, context switches from
`/proc/<pid>/task/*/status` without strace, threads told apart with
`strace --seccomp-bpf -f -e trace=futex` and the `futex` addresses
resolved against `nm` with ASLR off. The per-thread row is from its own
run under `strace --seccomp-bpf`, which stops the server only at the
traced calls: on 2026.10.27.7020 that run sums to 1.49 `futex` per
request against 2.08 under `strace -f -c`, which stops it at every
call and so makes the threads meet on their locks more often. The
thread that runs the connections is the helper worker on 2026.09.12
and main on 2026.10.27.7020, where main is the only worker.

| Per request | 2026.09.12 | 2026.10.27.7020 |
| --- | --: | --: |
| `futex` | 9.85 | 2.08 |
| OS thread context switches | 2.1 | 0.50 |
| `epoll_ctl` / `epoll_wait` / `poll` | 1.05 / 1.03 / 1.00 | 1.03 / 1.03 / 2.01 |
| `futex` by thread, from a second run (below) | helper worker 4.2, monitor 4.1, main 1.7 (10.0 in all) | GC sweeper 0.72, main 0.45, monitor 0.32 (1.49 in all) |

- What it was, on 2026.09.12: at `SPINEL_WORKERS=1` the connections ran
  on one helper OS thread beside main and the monitor. Every park woke the
  monitor (`g_sysmon_cv`), and every park and wake passed `g_sched_lock`
  between the three threads, each hand-over a `futex` wait and wake. The
  monitor made 7,492 turns for 8,032 parks (`SPINEL_SCHED_STATS=1`, on a
  minimal server). A `wait_readable(0)` before the real wait did not
  change the counts (the next request is never there yet), and a blocking
  `readpartial` would hold the only worker.
- What fixed it, upstream: per-worker readiness sets (#4306, in
  2026.09.12 already), the scheduler's hand-offs leaving the global lock
  and a park nudging the monitor only for an earlier deadline (#8702,
  2026-10-14), and a thread start waking the monitor only when its wait
  would end too late (#10024, 2026-10-23). On 2026.10.27.7020 a park is
  one `epoll_ctl` (a one-shot re-arm in the worker's own set) and one
  `epoll_wait` on the worker, no `futex`; the monitor made 630 turns for
  8,070 parks, and the worker thread switched out 92 times in 8,000
  requests. The two `poll` calls are the zero-timeout readiness checks
  before the `readpartial` and before the write. A minimal keep-alive
  server (one green thread per connection, `wait_readable(5)` before
  `readpartial`) goes from 7.5 `futex` per request on 2026.09.12 to 0.3,
  on 2026.10.27.7020 and on the fork's master 49ccdced alike.
- What is left: of the 1.49 `futex` per request in the per-thread run,
  the sweeper's 0.72 and most of main's 0.45 are the collector's
  concurrent-sweep hand-off (see 5), and the monitor's 0.32 are its
  time-based turns (about 215 a second under load), each taking
  `g_sched_lock`. None is on the park path.
- Also seen: an idle keep-alive connection costs more in CyberTrain than
  in that minimal server, because `head_readable?` re-parks it every
  `ACCEPT_POLL` (0.1 s) with a new deadline so that `#stop` is noticed.
  Each re-park is a timer expiry and a monitor turn under
  `g_sched_lock`. With the server on one CPU and the connections open
  for 10 s, 100 idle connections cost 1.6% of the CPU and 1,000 cost
  8.6% (2,349 context switches a second), growing with the connections;
  a server that parks each connection once with a 30 s timeout costs
  0.4 to 0.5% (about 140 switches a second, the monitor's and the
  trimmer's own) at either count. That is CyberTrain's design, not a
  Spinel issue: on 2026.10.27.7020 a `close` from another thread wakes a
  thread parked in `wait_readable(t)` on that socket at once, with
  `IOError` ("stream closed in another thread", as in CRuby; checked at
  `SPINEL_WORKERS=1` and 2), and so does `shutdown(Socket::SHUT_RD)`,
  with EOF, leaving the socket writable. So the drain can end idle
  connections instead of each one polling the flag. CyberTrain does so
  since 2026-10-30, with the read-side shutdown: 1,000 idle connections
  now cost 0.8% of the CPU instead of 8.8% (see
  [performance-next.md](performance-next.md), 8).
- Today: nothing; every release pinned since 2026.10.27.7020 has the fix.
  Re-measured on 2026-11-05 on 2026.11.04.7026 beside 2026.10.27.7020
  (same VM, same CyberTrain source, server pinned to one CPU with
  `SPINEL_WORKERS=1`, `strace -f -c` over 8,000 keep-alive `GET
  /articles`, two runs each, alternated): 3.72 and 3.76 `futex` per
  request on 2026.11.04.7026 against 3.63 and 3.62 on 2026.10.27.7020,
  with 1.03 `epoll_wait`, 1.02 `epoll_ctl` and 2.0 `poll` per request on
  both. The counts are higher than the 2.08 above because the sweeper
  and monitor threads share the server's one CPU here (the 2026-10-30 run
  let them use the others), and they include the start, the seeding and
  the stop; the two builds are within 4% of each other (3.76 against
  3.62 at the widest), which the alternated runs do not separate.
- Fix: done.

### 5. At one worker, most collections are full, and the sweep is handed to another thread

Re-measured on 2026-10-30 on 2026.10.27.7020, and on 2026-11-05 on the
pinned 2026.11.04.7026 beside it, where it is unchanged: with
`SPINEL_GC_PHASES=1` on the one-CPU setup of "Re-checked side by side",
83% of collections are full on both builds (2,707 of 3,258 in the first
five seconds on 2026.10.27.7020, 3,063 of 3,686 on 2026.11.04.7026, which
served more requests in them), the collector takes 14 to 17% of wall on
both, and the sweeper thread is there on both (`sp-sweeper`, 0.13 s of
CPU over 16,000 requests). That matches the code: 2026.11.04.7026's
lib/sp_gc.c has the same full-cadence rule
(`SP_GC_PROMOTED_DEAD_CUT`), the same aging switch (cleared when the slab
is on); lib/sp_gc.c only gained `--gc=none` guards, and lib/sp_sched.c,
which starts the sweepers, only code for a fork after threads have
started. The title this item had on
2026.09.12, "a collection stops every thread even with one worker", no
longer describes a cost: at `SPINEL_WORKERS=1` the stop-the-world waits
for nobody (`SPINEL_GC_PHASES=1`: 0.001 s waiting for workers to park over
2,852 collections). What costs at one worker now is when the collector
does a full mark, and that it hands the sweep to a sweeper thread.

Setup, beside 4's: examples/blog on 2026.10.27.7020, `SPINEL_WORKERS=1`,
the server pinned to one CPU (`taskset -c 0`, as bench/run's one-CPU
configuration does), and the load from three Python processes on the
other three CPUs, 16 keep-alive connections in all, 16,000 requests a run.
The server used 97 to 98% of its CPU in every run, so requests a second
measure it. Settings were alternated run by run, three runs each unless
noted; the spread between runs of one setting is 3 to 6%.

| `GET /articles`, one CPU | Requests a second | Server CPU per request | p99 latency | Full collections |
| --- | --: | --: | --: | --: |
| default | 2,930 | 0.331 ms | 9.3 ms | 83% of 5,784 |
| `SPINEL_GC_CONC=0` (no sweeper thread) | 3,084 (+5%) | 0.314 ms | 8.3 ms | 83% |
| `SPINEL_GC_FULL_INTERVAL=8` | 3,395 (+16%) | 0.285 ms | 7.7 ms | 12.5% of 4,814 |
| both | 3,444 (+18%) | 0.281 ms | 8.1 ms | 12.5% |

`GET /articles/1` moves the same way: +6% without the sweeper and +17%
with the interval fixed at 8. Peak RSS is 14 to 15 MB in every row.

- **Nearly every collection is a full one.** The full cadence adapts
  (`sp_gc_full_interval`, lib/sp_gc.c): when what the minors between two
  full collections promoted and the full then freed exceeds 1/16 of the
  live set per minor (`SP_GC_PROMOTED_DEAD_CUT`), the interval halves, down
  to 1, every cycle full. At 1 it tries 2 again after eight fulls, and
  goes back to 1. A server's in-flight requests are exactly that
  garbage: with a collection every 2.8 requests and 16 requests in flight,
  each minor promotes the objects of the requests being served, and they
  die as their responses go out, against a live set of 0.7 MB. Marking the
  whole live set on 83% of collections costs more than carrying that
  garbage for eight cycles: fixing the interval at 8 is worth 16 to 17%.
  The rule was added for an interpreter whose promoted frames were 13% of
  its live set per minor (390a0ec95, 2026-09-12); it weighs what is
  promoted against the live set, not against what a full mark costs.
  Aging, which keeps a first-time survivor young for one more minor and
  is what would keep request objects out of the old generation, is off
  whenever the slab allocator is on (`sp_gc_age_on` is cleared when
  `sp_slab_on`). With the slab off (`SPINEL_GC_SLAB=0`) aging cuts the
  full share from 83% to 51%, but the slab off costs 30% on its own (and
  is where J shows), so that is not a way out today.
- **The sweep goes to a thread that shares the CPU.** Since the
  concurrent sweep (f98add994, 2026-09-14, measured on a 32-core machine)
  the collector releases the world and hands the sweep to sweeper threads,
  `min(workers, 8)` of them, so one at `SPINEL_WORKERS=1` however many
  CPUs the process may use. On one CPU the hand-off is two `futex` wakes
  and a wait, and the sweeper preempts the worker to do the sweep it would
  have done itself: 1.64 context switches per request against 0.21, about
  half of them involuntary. Over ten alternated runs each, no sweeper gave
  +5.4% requests a second (3,083 against 2,925, Welch's t 2.4), 5.5% less
  CPU per request and 12% lower p99. The handed-off sweep also makes the
  slab's chunk release walk twenty times as many chunks (4.08 million in
  74,401 releases, against 0.2 million in 2,369). With four CPUs and the
  server unpinned, the sweeper's removal did not change requests a second
  (the client was the limit there).
- Re-tried on this build: a larger `SPINEL_GC_THRESHOLD_KB` (4096: a
  sixth of the collections and 4.5% of wall instead of 13%, but the same
  requests a second with the sweeper, and +12% instead of +5% without it,
  at 18 MB; 16384: 9% slower and twice the RSS), and `SPINEL_GC_MINOR=0`
  (+8%, less than the fixed interval).
- Today: the Dockerfile `cybertrain new` writes, examples/blog's, and the
  environment file in docs/deploy.md set `SPINEL_GC_FULL_INTERVAL=8`
  (since 2026-10-30). `SPINEL_GC_CONC=0` is not set: it helps only on a
  one-CPU host, which the deploy files cannot tell apart.
- Fix: (a) do not let the promoted-garbage rule take the full cadence
  below the default when the live set is small, or weigh what a full mark
  costs (the live set it walks) against the promoted garbage it frees;
  or make aging work with the slab, so that a request's objects die young.
  (b) Start no sweeper thread when the process may use one CPU
  (`sp_available_cpus() == 1`, which already narrows by affinity and the
  cgroup quota): the collector then sweeps inline, as `SPINEL_GC_CONC=0`
  does, which the code already falls back to when no sweeper started.
  On 2026.11.04.7026 that is a few lines in `sp_cs_start_sweepers`
  (lib/sp_sched.c), which takes the count from `SPINEL_GC_SWEEPERS` or
  the worker cap and leaves the concurrent-sweep hooks unset when no
  sweeper started. (b) is a gain only; it is (a) that would let the
  deploy files drop `SPINEL_GC_FULL_INTERVAL=8`.
- Upstream: (b) is matz/spinel#11646 ("A process that may use one CPU
  sweeps under the collector's stop and starts no sweeper thread", merged
  2026-11-12). With `SPINEL_GC_SWEEPERS` unset and `sp_available_cpus()`
  below two, `sp_cs_start_sweepers` starts no sweeper and the collector
  sweeps under its own stop; `SPINEL_GC_SWEEPERS=N` still starts N, and
  with two CPUs or more nothing changes. Measured in the pull request,
  not here: eight green threads on one worker building request-shaped
  objects, Linux/aarch64 in a container held to one CPU,
  `SPINEL_WORKERS=1`, 39,600 collections: 79,533 voluntary context
  switches before and 1,004 after, and 6.5 to 8.2% less wall time
  (Welch's t 2.1 and 2.2 over 7 and 10 alternated runs, on a busy host).
  examples/blog was not measured with it. #11697 (2026-11-13) makes its
  test run the two-CPU cases under a quota of two CPUs and take only a
  child that exits cleanly. In no fork tag yet. (a) is still not written.

### 6. The system allocator

Linking jemalloc (`allocator = "jemalloc"` in spin.toml, or `LD_PRELOAD`)
gives 1.3 to 1.4 times the requests on the dynamic pages. It is not the
default because it needs jemalloc's development package to build. (On
2026.10.09-7009 jemalloc no longer helped, see E.)

- Fix: ship or vendor a faster allocator, or a size-class pool for the
  runtime's own small objects.

### 7. A `Mutex` on the request path stalls for seconds

A `Mutex#synchronize` taken on every request (a process-wide cache) stalled
requests for seconds with `SPINEL_WORKERS=2`; the two-core benchmark failed
about one run in two with wrk timeouts or a dead server, and five of five
passed once the lock was gone (rule 57).

- Today: no locks on the per-request path.
- Fix: find why an uncontended lock between two workers can wait that long
  (a fiber holding it while parked, or a missed wake-up).

## Typing and code generation

Each made code slower than it reads; all are in rule 56. `spinel
--emit-types` and `-S` were how they were found. Status is for
2026.10.25-7018 and 2026.10.26.7019 (the same on both), and for the rows
re-checked on 2026.11.04.7026 (2026-11-04), from their generated C for a
small program.

| What happens | Cost | What would fix it | 2026.10.25-7018, 2026.10.26.7019 | 2026.11.04.7026 |
| --- | --- | --- | --- | --- |
| `"#{v}"` allocates and copies even when `v` is a String | an object per call | skip the copy for a single String interpolation where the result is never mutated (CRuby's `"#{s}"` is a new, unfrozen String too) | still copies | still copies (`sp_str_alloc_raw` and `memcpy`) |
| `Array#clear` anywhere makes that Array `sp_PolyArray` | every element access is dynamic | keep the element type through `clear` | not re-checked | not re-checked |
| An Array of the class that holds it is `sp_PolyArray` | same | type self-referencing element Arrays | not re-checked | not re-checked |
| A Hash with object values boxes them | every lookup is polymorphic | infer the value type | not re-checked | not re-checked |
| A nullable object parameter is boxed, and so is what returns it | the method's result is polymorphic | a nullable object type | not re-checked | not re-checked |
| A block (`each`, `map`, `times`) allocates a Proc and closure cells per call | the template interpreter's loops had to become `while` | inline blocks of known methods | not re-checked | not re-checked |
| `each { return ... }` compiles to `setjmp` and a Proc | slow early exits | a non-local return without `setjmp` when the block is inlined | not re-checked | not re-checked |
| `String#to_sym` searches the symbol table linearly | O(symbols) per call | a hashed symbol table | **fixed**: hashed lookup | not re-checked |
| `str << int` makes a one-character String | an object per byte | append the byte directly | still builds a String (`sp_int_codepoint_to_str_in`) before appending | still builds a String (`sp_int_codepoint_to_str_in`) |

## FFI and tools

- **`ffi_source` shares a translation unit with the runtime** (rule 59). An
  `extern` there must use the types already emitted (`const char *` for
  `sqlite3_column_text`, `long` for a `:long` return) or the build stops
  with "conflicting types". Document it, or compile `ffi_source` on its
  own. Since 2026.10.09-7009 the runtime's own declarations are under other
  names (B), so a conflicting `extern` no longer collides, but calling an
  `ffi_func` by its C name needs one (since 2026.10.26.7019 a build error
  without it, see B).
- **A `:str` return always copies.** About 30 objects per article page are
  SQLite text columns. A borrowed or into-buffer return would let a caller
  avoid them.
- **`--emit-types`** was the most useful tool; naming the call site that
  widened a method to untyped would make it quicker still.
- **`SPINEL_ALLOC_REPORT` / `SPINEL_ALLOC_SITES`** gave deterministic object
  counts, which is what made progress measurable on a VM with 5 to 15% run
  to run noise. Symbol names in the report instead of offsets (now
  `addr2line` on each) would help.
- **`--cc=<wrapper>`** is how a generated C file can be patched with
  `fprintf`s before it compiles; it found F.

## Regressions in newer packages

None of these happens on 2026.09.12, except D, which raises there too (see D). First found on 2026.10.09-7009 (A to E, while
benchmarking), re-checked, with F and G new, on 2026.10.25-7018, and fixed in the fork's
2026.10.26.7019 except D, which is by design in the default `raise` mode and
which CyberTrain works around, and B, which that release turns into a build
error by design (and E, not re-measured). Each section's reduced program
from A, C, F and G prints Ruby's result on 2026.10.26.7019. H is new on
2026.10.26.7019 itself. The fixes are merged into matz/spinel (#10254 to
#10263, 2026-10-26); on master 9b9972399 (re-checked on 2026-10-27) H is
still present, and D still raises, by design. H is fixed by #10415, merged
2026-10-27 (master 003ceda5d). I is new on the fork's master 49ccdced
(2026-10-30) and absent from 2026.10.27.7020; it is fixed by #10735 and
#10786 (merged 2026-11-01 and 2026-11-02), which 2026.11.03.7025 and
2026.11.04.7026 carry. J is on 2026.10.27.7020, 49ccdced and
2026.11.04.7026, seen only with the object slab off, and not reproduced
on 2026.09.12 (2 of 2 runs).

On 2026.10.25-7018, the ten `spin test` failures:

| Test | Cause |
| --- | --- |
| gen_runner_models.rb | A |
| gen_namespaced.rb, gen_routes_compiles.rb | C (`view_assigns`) |
| client.rb, router.rb | C (attribute write in a route block) |
| http_response.rb | F |
| send_blob.rb | G |
| http_client.rb | 3, made visible by the untyped `OpenSSL::Digest#to_s` |
| template_engine.rb | a deliberate refusal (below C) |
| template_integration.rb | a new refusal (below C) |

On 2026.10.26.7019 only template_engine.rb failed, at the same deliberate
refusal; with its argument built where the call sees it, 98 of 98 pass.

### A. A receiverless call with a block inside `instance_eval` is `NoMethodError`

Present on 2026.10.25-7018; **fixed in 2026.10.26.7019** (the program
below prints `res x` and `res y`, and examples/blog's `spin run gen` writes
files identical to the committed ones). Merged into matz/spinel as #10254.

```ruby
class Mapper
  def initialize; @s = Array.new(0) { "" }; end
  def res(name, &block)
    @s << "res #{name}"
    block.call(self) unless block.nil?
    nil
  end
  def s = @s
end
m = Mapper.new
m.instance_eval do
  res(:x) { |a| a.res :y }   # undefined method 'res' for an instance of Mapper
end
puts m.s
```

The same call without a block, or with an explicit receiver
(`instance_eval do |r| r.res(:x) { ... } end`), works. It breaks every
app's `config/routes.rb` that nests `resources`: examples/blog's
`spin run gen` stops with "undefined method 'resources' for an instance of
Cybertrain::Gen::Mapper", and so does test/gen_runner_models.rb.

### B. `ffi_func` functions are no longer declared under their own names

The runtime declares them as `sp_ffi_fN_<name>` with an
`__asm__` label (`extern long sp_ffi_f0_strlen(const char *)
__asm__(SP_FFI_SYM("strlen"))`), so an `ffi_source` block calling one by
its C name gets an implicit declaration: `int`, a cut pointer, a SIGSEGV.
CyberTrain declares what it calls (db/sqlite_ffi.rb, aedcf4b), which works
on every build.

Settled in 2026.10.26.7019, as suggested here: the generated C is compiled
with `-Werror=implicit-function-declaration`, so the call above is a build
error instead of a crash. The private names stay (declaring the function
under its C name as well would bring back the conflicting-types errors),
and Spinel's docs/FFI.md says a fragment declares what it calls or
includes the header. CyberTrain's declaration is therefore required, not a
workaround to remove. Merged into matz/spinel as #10255.

### C. Generated C that does not compile

None of the shapes below is reported on 2026.10.26.7019, nor on matz/spinel
master, where their fixes are merged as #10258 (the dispatched call's
result) and #10259 (the attribute write). On 2026.10.25-7018:

- **A dispatched call's result is not boxed into a boxed local.**
  `assigns = view_assigns` in `Controller#view_env` (controller.rb:458),
  where the base class returns `{}` and generated controllers return
  `{ "viewer" => @viewer }`: the local is `sp_RbVal`, the switch over the
  subclasses yields `sp_StrPolyHash *`, and the assignment does not compile
  ("incompatible types when assigning to type `sp_RbVal` from type
  `sp_StrPolyHash *`"). test/gen_namespaced.rb and
  test/gen_routes_compiles.rb. On 2026.10.09-7009 the same methods failed
  one step earlier, in the overriding method's return type.
- **An attribute write in a route block, of a `to_s` value.**
  `router.get(...) { |c| c.response.body = c.request.header("X-Token").to_s }`
  (test/client.rb) and `{ |c| c.response.body = c.params[:a].to_s }`
  (test/router.rb): `c` is boxed (a Context or a Test::Client), and the
  write compiles to `iv_body = SP_STR_B(...)`, a `const char *` into an
  `sp_String *` field (`-Werror=incompatible-pointer-types`). A smaller
  program of the same shape compiles, so it takes something more of these
  programs; the generated C is the evidence.

The template lexer's `sp_poly_opnd_i` errors of 2026.10.09-7009
(cybertrain/template/lexer.rb lines 48 and 91) are not reported any more.

Two compile-time refusals, which name the line and stop instead of
generating wrong code:

- test/template_engine.rb (since 2026.10.09-7009): "a typed Hash is passed
  to `render_with_layout`'s parameter `env`, which the method stores keys or
  values of other types into". The next section has the details. Still refused on 2026.10.26.7019
  (re-checked on 2026-10-26 with the test's earlier form), and on matz/spinel
  master 9b9972399 (re-checked on 2026-10-27 with the earlier form,
  `git show 81778ea^:test/template_engine.rb`, refused at line 49), although
  #10316 ("An empty {} handed on through a parameter takes the Hash kind its
  callee wants", the fork's `fix/empty-hash-through-param`) is merged there:
  that fix does not cover this program. Fixed in CyberTrain by storing the
  title String into the Hash in `layout_env`, before it returns the Hash
  (see the next section: passing a call alone was still refused). Not
  refused any more on 2026.11.04.7026, which carries #10525, and the
  workaround is dropped (see the next section).
- test/template_integration.rb (new): "a constant write given a Hash,
  which no conversion keeps in its `sp_StrPolyHash *` slot", at
  `Migration::Base::VERSIONS = begin h = { "" => "" }; h.delete(""); h end`
  (migration.rb:173), the seeding idiom of rule 9. If the refusal is
  intended, rule 9 needs another idiom; either way CyberTrain has to change
  for it. Not refused any more on 2026.10.26.7019, nor on matz/spinel
  master since #10261, so rule 9's seeding idiom stayed. (The constant
  itself was removed on 2026-11-15, nothing having read it; the idiom is
  still what seeds a typed empty container elsewhere, as in
  cybertrain/model/bulk_writes.rb.)

#### The refusal in test/template_engine.rb

**Fixed** by matz/spinel#10525 ("A Hash a method returns widens where it
is built for a store through a parameter") and, for the run-time
`TypeError` further down, #10524 ("A Hash parameter's reads are not typed
as the one class the method stores"), both by SaekiMototsune, merged
2026-10-29, and carried by 2026.11.03.7025 and 2026.11.04.7026. On
2026.11.04.7026 (re-checked on 2026-11-04) the test's earlier form, `git
show 81778ea^:test/template_engine.rb`, passes, and every program below
prints CRuby's result, without the "did not converge" warning. What
follows is how it stood on 2026.10.27.7020.

Still refused on 2026.10.27.7020 (re-checked on 2026-10-28 with the test's
earlier form, refused at line 49). It was then the one CyberTrain
workaround left that a change in Spinel could remove, and the candidate
for an upstream pull request.

What happens: a Hash whose value type is settled in one method (say
String => Integer), returned, and passed on to a method that stores a value
of another type into it, is refused at the call. CRuby runs the program.
The message suggests building the argument from a hash literal the call can
see, which is not always possible: the Hash was built somewhere else.

```ruby
class Box
  def initialize(s)
    @s = s
  end
  def to_s
    @s
  end
end

def new_env
  env = {}
  env["n"] = 7
  env
end

def fill(env)
  env["content"] = Box.new("page")
  env.size
end

env = new_env
p fill(env)                # CRuby: 2
p env["content"].to_s      # CRuby: "page"
```

2026.10.27.7020 refuses it:

```
spinel: refusal.rb:22: a typed Hash is passed to `fill`'s parameter `env`, which the method stores keys or values of other types into: the caller's hash cannot hold them, and a converted copy would not see the stores. Build the argument from a hash literal the call can see, so it is widened with the parameter.
spinel: 1 refusal, nothing written
```

Variations:

| Shape | 2026.10.27.7020 | 2026.11.04.7026 |
| --- | --- | --- |
| The program above (Hash from `new_env` through a local) | refused | prints CRuby's result |
| `fill(new_env)`, the call itself as the argument | refused | prints CRuby's result |
| `env = new_env; env["title"] = "x"; fill(env)` (the caller widens it to String and Integer values first; this is test/template_engine.rb's earlier form) | refused | prints CRuby's result |
| The `"title"` store moved into a method that returns the Hash (`def titled_env; env = new_env; env["title"] = "x"; env; end`, then `fill(titled_env)`) | compiles, prints CRuby's result | prints CRuby's result |
| `env = {}; env["n"] = 7; fill(env)` at the call site, the literal visible to the call | compiles, prints CRuby's result | prints CRuby's result |
| The program above storing a String (`"page"`) instead of a `Box` | compiles and prints CRuby's result, with `warning: type inference did not converge in 128 rounds` | prints CRuby's result, no warning |

So on 2026.10.27.7020, in the shapes checked, what decides it is where the Hash's value type
is settled, not whether it reaches the call through a local: a Hash whose
values are already polymorphic when it leaves the method that builds it is
accepted, and a Hash whose only value type is Integer is refused when the
callee stores a `Box`, even when the caller widens it afterward. Storing a
String instead compiles (last row), so not every Hash with one value type
is refused.

A related shape is accepted but wrong at run time. When the literal is
visible to the call and the callee also reads the Integer before storing
the object, the program raises:

```ruby
def fill(env)
  n = env["n"]
  env["content"] = Box.new("page")
  n
end

env = {}
env["n"] = 7
p fill(env)                # CRuby: 7
```

2026.10.27.7020 compiles it and prints `wrong argument type Integer
(expected Box) (TypeError)`. 2026.09.12 generates C that does not compile.
That is wrong code, not a refusal, and the more serious of the two for an
upstream report. With a String stored instead of a `Box` it prints CRuby's
result. 2026.11.04.7026 prints `7`, as CRuby does (#10524).

Who met it, up to 2026.10.27.7020: anyone who builds a Hash in one method and hands it to
another that adds values of another type. In CyberTrain that is a caller of
`Engine#render_with_layout`, which stores the rendered page into `env`
(`env["__content"] = SafeString.of(...)`). `Controller#render` is not
affected, because the controller builds its environment where the store
widens it. An application that calls the Engine directly was.

What this document asked of Spinel, and what #10525 does (it follows the
Hash back through a local's writes and a method's values to the literal or
`Hash.new`, and widens it there; an ivar, a block parameter or a method
with another body is still refused, with a message naming what the call
can follow): widen a Hash where it is built when a store
reached through a parameter needs a wider type, following the Hash back
through method returns and locals (#10316 does this for an empty `{}`
handed on through a parameter, not for a Hash returned from a method). If
that is too wide a change, the refusal message should at least name what
works ("settle the Hash's value types in the method that builds it"), since
building it from a literal at the call is often not possible. The run-time
`TypeError` above needs a fix either way: the callee's read of `env["n"]`
must use the widened value type.

Today: nothing. Up to 2026.10.27.7020, test/template_engine.rb built the
Hash in `layout_env`, which stored the title String into it before
returning it, so its values were already polymorphic when it reached
`render_with_layout`. It was `layout_env`'s store that mattered; passing
the call instead of a local alone was still refused (second row of the
table). On the pinned 2026.11.04.7026 the earlier form passes, and the
test is back in it (the caller stores the title into `new_env`'s Hash
through a local), so it now covers the shape #10525 fixes.

Reported and fixed upstream: #10524 and #10525, merged 2026-10-29.

### D. `String#to_i` on more digits than an Integer holds raises `RangeError`

By design in the default `raise` mode, not a bug to fix.
On 2026.10.26.7019 (re-checked on 2026-10-26) and on matz/spinel master
9b9972399 (re-checked on 2026-10-27), `"99999999999999999999".to_i` raises
`RangeError: integer overflow parsing "99999999999999999999"`; CRuby returns
a Bignum. 2026.09.12 raises the same `RangeError`, for a literal and for a
run-time String (re-checked on 2026-10-28 on a build of its commit,
112bae85c1a2): D was never a regression. This document used to say
2026.09.12 saturated, after spikes/NOTES.md rule 25, which 977bfdb
(2026-10-22) already corrected; the raise has been there since 412a2200c
(2026-05-27), which that release includes.

- Why: upstream 412a2200c (Matz, 2026-05-27, "runtime: to_i / Integer() on
  overflowing input raise RangeError", fixes #842) replaced the silent
  saturation at INT64_MAX on purpose, because it hid the precision loss
  and made `rescue RangeError` ineffective. Spinel's docs/int-overflow.md
  describes the default `raise` mode as catching overflow loudly, never
  silently wrong, and as a deliberate deviation from CRuby;
  docs/limitations.md lists Integer overflow under "By design".
- `--int-overflow=promote` is experimental in Spinel's own words
  (docs/int-overflow.md): its coverage is not complete, and some overflow
  paths through method arguments, closures and certain containers still
  raise rather than promote. For the parse itself it gives CRuby's answer:
  in the shapes checked on master 9b9972399 (and before that on
  0d0a621fb), `String#to_i`, `to_i(base)`, `Integer()` (also with
  `exception: false` and `"0x..."`), `hex` and `oct` return the same
  Bignum CRuby does, for literals and for run-time Strings
  (ARGV, a Hash value, a method parameter) (upstream 317d9bbe8, 2026-09-26,
  "promote mode reads String#to_i and Integer() past sp_int as a Bignum";
  #10263 covers `String#hex` and `#oct` past the word in that mode). What
  the program then does with the Bignum is outside those checks.
- Today: test/http_request.rb passes because `Request#content_length`
  refuses more than 18 digits before calling `to_i` (977bfdb). CyberTrain
  keeps that guard. Building with `--int-overflow=promote` would be an
  alternative only once the whole program is known to work in that mode.

### E. More allocation per request

Measured on 2026.10.09-7009 only (examples/blog did not build on
2026.10.25-7018; 2026.10.26.7019 is not measured yet). An article page allocated 852 objects instead of 511
(same source): about 136 more boxed Arrays from `each_key` on a
polymorphic Hash (`sp_poly_each_elem`), about 92 more Strings inside
`sp_StrPolyHash_set`, and about 50 more internal objects. With jemalloc the
pages were 7 to 15% slower than on 2026.09.12; with system malloc the other
gains covered it.

Measured again on 2026-11-05 across the three releases of "Re-checked
side by side" (`SPINEL_ALLOC_REPORT`, one process each: start, 30
articles seeded through the form, 200 `GET /articles`, stop), where the
report is deterministic: 658,405 objects on 2026.10.27.7020, 650,413 on
2026.11.03.7025 and 650,411 on 2026.11.04.7026: 9,097 `Hash(String)` and
6,061 `Article` on each, 819 fewer Strings of 167 thousand and 1,350
fewer `Array`s on the newer two, the rest of the difference in two
internal scan types. So the
pin's move from 2026.10.27.7020 allocates 1% less, not more; what grew
since this item was written is CyberTrain's own code
([performance-next.md](performance-next.md)), not Spinel's.

### F. A call whose result is always nil is dropped when passed to a typed parameter

New on 2026.10.25-7018, and silent. When a method that always returns nil
is called as the argument of a parameter typed otherwise (here a String),
the argument compiles to the constant `NULL`: the call, with its side
effects, is gone.

```ruby
class Box
  def initialize = @items = ["a"]
  def clear!
    @items.clear
    nil
  end
  def size = @items.size
end
def check_nil(v)
  puts(v.nil? ? "nil" : "got #{v.inspect}")
end
check_nil "x"          # v is typed String
b = Box.new
check_nil b.clear!     # compiled as check_nil(NULL): clear! never runs
puts b.size            # 1 on 2026.10.25-7018; 0 on 2026.09.12, 2026.10.26.7019 and in Ruby
```

**Fixed in 2026.10.26.7019**, and merged into matz/spinel as #10260.

Seen in test/http_response.rb: `assert_nil res.drop_header("Location")`
compiled to `sp_assert_nil(NULL)`, so the header was never dropped and the
next assertion failed. Tests are where this shape is common (`assert_nil`
around a mutating call), and they then test nothing.

- Fix: evaluate the argument for its side effects, then pass nil.

### G. `<<` of a binary String keeps UTF-8, then a Regexp raises

New on 2026.10.25-7018. Appending an ASCII-8BIT String to an ASCII-only
UTF-8 String leaves the result UTF-8 (CRuby makes it ASCII-8BIT), and a
Regexp on it now validates the encoding and raises:

```ruby
body = "\x89PNG\r\n".b
out = +"HTTP/1.1 200 OK\r\n"
out << "X-A: 1\r\n\r\n"
out << body
p out.encoding.to_s           # "UTF-8"; Ruby: "ASCII-8BIT"
p out.scan(/^x-a:/i).length   # ArgumentError: invalid byte sequence in UTF-8; Ruby: 1
```

**Fixed in 2026.10.26.7019** (it prints "ASCII-8BIT" and 1, as Ruby does),
and merged into matz/spinel as #10262.

2026.09.12 also said "UTF-8" but did not validate, so the scan worked.
Seen in test/send_blob.rb, which scans `Response#to_http` of a PNG
download. An application hits it when it matches a Regexp against a
response or request whose binary body holds bytes that are not valid
UTF-8 (a PNG or JPEG does; an ASCII-only body does not).

- Fix: follow CRuby's encoding of the result of `<<` (ASCII-only receiver
  plus a binary argument gives ASCII-8BIT).

### H. A forwarded block's value loses an application class

New on 2026.10.26.7019 (reported downstream on 2026-10-27, issue #27;
2026.10.25-7018 not checked; the reporter saw it pass on matz/spinel's
2026.10.25 release, which only hid it: see the bisection below). When a method forwards its block with `&block` to a
yielding method, and the program's blocks for it return different types,
the forwarding call's value is boxed without the class of an application
object: calling a method on it raises `NoMethodError`, and the method is
not even emitted.

```ruby
class Pool; def with; begin; yield 1; ensure; nil; end; end; end
module Db; @pool = Pool.new; def self.with(&block) = @pool.with(&block); end
class Result; def ok? = true; end
def result_of = Db.with { |c| Result.new }
p result_of.ok?      # undefined method 'ok?' for an instance of Result (NoMethodError);
                     # true on 2026.09.12 and in Ruby
p Db.with { |c| 1 }  # without this second block, or calling Pool#with directly: true
```

The generated C dispatches `ok?` with a `switch` that has only the
`default:` NoMethodError case; 2026.09.12's has `case <Result>:`. Builtin
values (Arrays, Hashes, Integers, Strings, true/false) still dispatch, so
CyberTrain's own `Cybertrain::DB.with` sites, which return rows and
Integers, are unaffected, and its 98 test programs pass. An application's
`DB.with { |c| ... }` that returns its own object breaks, because the
framework's blocks already make DB.with's value polymorphic. The reporter
also saw a Boolean block value refused as a condition ("unsupported
condition (non-bool)") in a larger program; that was not reproduced.

CyberTrain's workaround while it was pinned to 2026.10.26.7019: DB.with's
comment said to assign such a value to a local declared before the block
(as DB.transaction already requires), and test/db_with_value.rb covered
that form and a Boolean condition (spikes/NOTES.md rule 77). Since the pin
moved to 2026.10.27.7020, which carries the fix below, the comment no
longer asks for it, and the test also covers the block's own value, which
raises the reported `NoMethodError` on 2026.10.26.7019 (issue #90).

Bisected on 2026-10-27 between matz/spinel's 2026.10.25 release (2814693f6)
and the fork's 2026.10.26.7019, whose compiler is matz/spinel master
9d1040375 (the fork adds only its Docker image files). The first bad commit
is upstream b6ca77437 (2026-10-25, "superclass answers its parents' Class
objects, and a dynamic name's method takes what dynamic calls hand on",
src/analyze_cls.c only). It exposes an older gap rather than adding one:

- The gap: the class analysis does not carry a block's value class from
  the call site, through the `&block` forward, into the inner yield's
  value once a second call site passes a block of another type. A program
  with no dynamic name already fails on 2026.10.25:

  ```ruby
  class R; def ok? = true; end
  def run_block = yield(0)
  def with(&block) = run_block(&block)
  p with { |c| 1 }
  r = with { |c| R.new }
  puts r.ok?   # NoMethodError on 2026.10.25 and on 2026.10.26.7019
  ```

- What hid it: a call to `method` (or `send`, `public_send`) with a
  computed name, or with no name at all as in `req.method`, makes every
  method name dynamic (a literal Symbol or String name, `method(:m)`,
  makes only that one dynamic), and until b6ca77437 a dynamic name's
  method had its parameters, its `&block` one included, seeded with every
  class. The forwarded value then held every
  class, and `r.ok?` dispatched over every class that defines `ok?`.
  CyberTrain programs always have such a call (`Request#method`, called
  as `req.method` in cybertrain/middleware/csrf_protection.rb and
  cybertrain/http/request.rb), which is why the reporter's program passed
  on 2026.10.25. Adding `class Req; attr_reader :method; def initialize =
  (@method = "GET"); end` and `puts Req.new.method` to the program above
  makes it print `true` on 2026.10.25.
- What b6ca77437 changed: a dynamic (not opaque) name's parameters now
  take a `dynarg` element, and the `&block` parameter only the builtin
  values, so the gap shows again.

Still present on matz/spinel master b7007eb8b (2026-10-27), and on master
9b9972399: both programs above still raise `NoMethodError` (re-checked on
2026-10-27). **Fixed** by matz/spinel#10415, merged 2026-10-27: on master
003ceda5d both programs print Ruby's result. A read of the forwarded
`block` as a proc's value now marks the method as reading its yields'
value in every class walk, not only the closed one, and so does a block
forwarded to a receiverless call of a method of the same class
(`def forward(&block) = run(&block)`), which review of the PR found.

- Fix: carry the classes the block can return through the `&block`
  forward into the forwarding call's boxed value, as 2026.09.12 did.

### I. A constant written `Array.new(n) { Obj.new }` is refused

New on the fork's master 49ccdced (2026-10-30, "Merge branch
'matz:master'"), built from source on 2026-10-30; 2026.10.27.7020 builds
the same source. In examples/blog, `spin build blog` stops with:

```
spinel: warning: type inference did not converge in 128 rounds; the output may be built from unsettled types (please report this program)
spinel: cybertrain/controller.rb:111: a constant write given a Array, which no conversion keeps in its sp_PtrArray * slot
spinel: 1 refusal, nothing written
```

Line 111 is `NO_SKIPS = Array.new(0) { Callback.new(:skip, nil, nil, [],
[], -1) }`, the Array seeded with its element type and emptied
(spikes/NOTES.md rule 9). Of CyberTrain's tests, test/controller_status.rb
makes the same refusal and test/controller.rb does not; `spin test` was
not run in full on that build. Reduced (prints `0` in Ruby and on
2026.10.27.7020; refused, with the same warning, on 49ccdced):

```ruby
class Cb
  attr_reader :name
  def initialize(name) = (@name = name)
end
NONE = Array.new(0) { Cb.new(nil) }
p NONE.size
```

The same write inside a class (`K::NONE`) is refused too. These are not:
a literal (`[Cb.new(:a)]`), `[1, 2].map { |i| Cb.new(i) }`,
`Array.new(2) { |i| Cb.new(i) }.freeze`, a method's return value, and
`Array.new(0) { ... }` assigned to a local.

Bisected on 2026-10-30 (`git bisect run` on the fork's history between
2026.10.27.7020 and 49ccdced, test/controller_status.rb compiled with
`-c`): the first bad commit is 8594f2be2 (2026-10-29, "Narrow an object
table handed to its elements' methods, and a constant one", merged as
matz/spinel#10527). It gives a constant that holds a table of objects a
slot of its own, narrowed to `sp_PtrArray *`, and takes the constant's
statement-position writes as its sources (`narrow_object_arrays`, step
5a' in src/analyze.c). The value of the write is classified as a local's
would be, and `Array.new(n) { obj }` passes as an object table. Only an
Array literal, though, is noted as built in place at the narrowed kind
(`oa_note_src` is called for an `ArrayNode` alone): `Array.new`'s value
is still built boxed, and the write of a boxed Array into the narrowed
slot is refused.

- Today: nothing to do. The pinned 2026.11.04.7026 carries both fixes
  below: the reduced program and its `Reg::NONE = ...` form print Ruby's
  result, examples/blog builds, and test/controller_status.rb passes
  (re-checked on 2026-11-04). Before the fixes, a `.freeze` on the
  `Array.new`, or `[Callback.new(...)][0, 0]`, avoided it: both forms of
  the reduced program print Ruby's result on 49ccdced and on
  2026.10.27.7020.
- Fix: matz/spinel#10735, merged on 2026-11-01 (the fork's
  saeki-mototsune/spinel#14, the same change, was closed). The constant's
  write builds
  `Array.new(n) { ... }` at the narrowed kind (`emit_ptr_array_build`, as a
  local's, an ivar's and a method return's write already do), and
  `infer_global_const_types` keeps a constant narrowed to an object table
  at that kind instead of unifying it back to the call's boxed Array each
  round, which is what kept inference from converging. Tests:
  test/object_array_constant_array_new.rb (the output), and
  test/infer/const_array_new_object_table_converges.rb, which `make
  infer-test` fails if inference runs to its 128-round cap (it settles in
  4 rounds; with the codegen half of the fix alone the program still
  compiles and prints the right answer, beside a "did not converge"
  warning the corpus harness does not check). On that branch the reduced
  program prints Ruby's result, and `make test-corpus` passes but for two
  failures of the sandbox (no UDP socket; root ignores `chmod 0500`).
- Not covered by #10735: the same value written through the constant's
  path from outside its module (`Reg::NONE = Array.new(0) { Cb.new(nil) }`)
  takes another branch of the constant write, which still emitted the call
  at its boxed type, and the C did not compile on master 52808c9c2
  (`assignment to 'sp_PtrArray *' from incompatible pointer type
  'sp_PolyArray *'`; 2026.10.27.7020 builds it). Found by CodeRabbit's
  review of #10735; the fix, the same in-place build on that branch, is
  matz/spinel#10786, merged on 2026-11-02, with
  test/object_array_constant_path_array_new.rb. CyberTrain does not write
  this form. With both merged, upstream master builds the constant
  written either way (`NONE = ...` and `Reg::NONE = ...`), and so does
  2026.11.04.7026.

### J. With the slab off, AddressSanitizer finds a thread's captured variables freed before it runs

Found on 2026-10-30 on 2026.10.27.7020 while re-measuring 5, and present on
the fork's master 49ccdced and on the pinned 2026.11.04.7026 (re-checked
on 2026-11-04: 3 of 3 runs, the same 64-byte object from
`sp_Srv_spawn_connection` freed by the sweep and read by
`_fiber_body_Srv_spawn_connection_1`); not reproduced on 2026.09.12 (2
of 2 runs).
The object slab
(`lib/sp_slab.c`, on by default) recycles freed slots itself, so an
AddressSanitizer build sees a use-after-free only when the slab is off
(`SPINEL_GC_SLAB=0`, which allocates every object with `calloc`). With it
off, this program fails under AddressSanitizer in every run (3 of 3 on
2026.10.27.7020, 2 of 2 on 49ccdced, 3 of 3 on 2026.11.04.7026) when a
client opens and closes
connections quickly (8 at a time, each sending one to three requests),
`SPINEL_WORKERS=1`:

```ruby
require "socket"

class Srv
  def run(port)
    server = TCPServer.new("127.0.0.1", port)
    Thread.new { accept_loop(server) }.join
  end

  def accept_loop(server)
    while true
      spawn_connection(server.accept) unless server.wait_readable(0.1).nil?
    end
  end

  def spawn_connection(sock)
    Thread.new { serve(sock) }
  end

  def serve(sock)
    while !sock.wait_readable(5).nil?
      req = sock.readpartial(4096)
      body = "#{req.bytesize} #{Time.now.to_f}\n" * 20
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    end
  rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
  ensure
    sock.close unless sock.closed?
  end
end

Srv.new.run((ARGV[0] || "3570").to_i)
```

- What AddressSanitizer reports: the 64-byte object allocated at
  `Thread.new { serve(sock) }` in `spawn_connection` (the block's capture
  struct, `_fib_cap_Srv_spawn_connection_1`, holding `self` and `sock`) is
  freed by a collection that another connection's `serve` started, and is
  then read by the new thread's fiber body on its first line
  (`sp_Srv *self = _fc->self_ptr`). The same happens with
  `SPINEL_GC_CONC=0` (3 of 3) and with `SPINEL_GC_MINOR=0` (2 of 2), so
  neither the concurrent sweep nor the minor collection is needed for it.
  Built by 2026.09.12, which has no slab and so lets AddressSanitizer see
  every object, the same program passed 2 of 2.
- What was ruled out: the generated code roots the fiber and the capture
  struct across the allocations and stores the struct into the fiber's
  `user_data` behind a write barrier; the fiber's scan marks `user_data`,
  and the live-thread registry marks every thread record, whose scan marks
  its fiber. A counting variant of the program started `serve` exactly as
  many times as it spawned threads (4,002 of 4,002, slab on and off), so a
  finished thread is not run a second time. Where the chain breaks for a
  thread that has been spawned but has not started is not known.
- In examples/blog under the same conditions, AddressSanitizer reports
  this and a second one: the frozen String `Module#name` caches
  (`sp_str_frozen_name`, used by `Controller.chain_for`'s `k.name`) freed
  by the object sweep and read again on a later request. A plain build
  with the slab off also dies with SIGSEGV (in `sp_Controller_run_action`
  where gdb caught it): 6 of 31 loaded runs, and 1 of 2 runs of 12,000
  short connections.
- Whether the default (slab on) is affected is open. A plain build with
  the slab on did not crash in over 70 loaded runs and 36,000 short
  connections, but the collector decides what to free the same way with
  the slab on or off, and the slab can hand out a freed slot again
  later. An AddressSanitizer build with the slab on stopped in 5 of 6
  runs with a wild read inside `serve`'s `rescue StandardError` (a block
  that plain builds never entered in any run), which may be an artifact of
  AddressSanitizer and fiber stack switching rather than this bug.
- Today: nothing in CyberTrain; it runs with the slab on.
- Fix: find why a spawned thread's capture struct is unreachable before
  the thread first runs, and add the program above to the tests with an
  AddressSanitizer job that runs with `SPINEL_GC_SLAB=0`, since the slab
  hides this class of bug from AddressSanitizer.

### L. `SPINEL_WORKERS=N` counts main, which a server keeps waiting: 2 runs on one worker

Found on 2026-11-05 on the pinned 2026.11.04.7026, from the benchmark run
of that day: `SPINEL_WORKERS=2` gave examples/blog 0 to 2% more requests
than 1 on the pages, where 2026.09.12 gave 9 to 25% (2026-10-09). Not a
bug in any one line: two deliberate changes meet in a program whose main
thread only waits. Not new in 2026.11.04.7026: checked on 2026-11-05, the
reduced program below gives the same figures on 2026.10.27.7020 and
2026.11.03.7025 (1.01 CPUs at N=2), and examples/blog built by
2026.10.27.7020 also serves every request on one OS thread at
`SPINEL_WORKERS=2` (see "Re-checked side by side" under "Runtime cost"),
so it entered between 2026.09.12 and 2026.10.27.7020, with #9840.

- **What changed.** Since #9840, an explicit `SPINEL_WORKERS=N` counts main
  among the N workers, as docs/thread.md says, and starts N-1 helpers
  (`sp_sched_start_workers`: `if (e && *e) g_worker_cap--;`). On
  2026.09.12 `g_worker_cap = sp_worker_count()` started N helpers beside
  main. Unset, both start one helper per online core beside main.
- **Why main does not make up for it.** With helpers present, main runs no
  general green thread: `sched_place_unstarted` places threads on workers
  1 and up (`/* worker 0 (main) runs no general thread */`), and main's
  join pump runs only threads already pinned to worker 0 (the published
  root-fiber snapshot, see the comment there). A server's main thread
  starts the accept thread and joins it, so it runs nothing for the whole
  run. At N=2 that leaves one OS thread for every request.
- **How it was seen.** examples/blog on two CPUs (`taskset -c 0,1`,
  `SPINEL_WORKERS=2`), wrk -t2 -c16 on CPUs 2 and 3, 8 s: one OS thread
  used 7.85 s of CPU and main 0.15 s (/proc/<pid>/task/*/stat);
  `SPINEL_SCHED_STATS=2` printed `workers=2 busy=1 runnable=14` and `pinned
  per worker: 0 18`, with run-queue waits of 4 to 8 ms. Nothing else
  serialized the requests: `mutex-wait n=0`, and the sweeper threads used
  0.07 s. With `SPINEL_WORKERS=3` on the same two CPUs, `perf sched` counted
  8.0 s of CPU in 4 s (two helpers at 3.49 s each), and the pages gained 24
  to 44% over 1 (medians of 3, same session).
- **Without a server** (4 CPU-bound threads; main joins them):

  ```ruby
  def burn(n)
    x = 0
    i = 0
    while i < n
      x = (x * 31 + i) % 1000003
      i += 1
    end
    x
  end
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  c0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  ths = []
  4.times { ths << Thread.new { burn(150_000_000) } }
  ths.each(&:join)
  wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - c0
  puts "wall=#{wall.round(2)} cpu=#{cpu.round(2)} parallelism=#{(cpu / wall).round(2)}"
  ```

  CPUs used (cpu / wall) on a 4-core VM:

  | `SPINEL_WORKERS` | 2026.09.12 | 2026.11.04.7026 |
  | --- | --- | --- |
  | 1 | 1.00 | 0.99 |
  | 2 | 1.97 | 0.99 |
  | 3 | 2.00 | 1.97 |
  | 4 | not run | 2.01 |
  | 5 | not run | 3.66 |
  | unset | not run | 3.43 |

  So on 2026.11.04.7026 the advice "set it to the core count" gives one
  worker fewer than leaving the variable unset, and at 2 it gives none.
- **A second effect, on latency.** A thread spawned by a helper goes onto
  that helper's own queue (`lrq_push(sp_worker_id, t)` in the spawn path),
  and only main's spawns and the global queue go through
  `sched_place_unstarted`. A server's accept loop is a thread on a helper,
  so its connections stay there unless another helper steals one while
  idle: with two helpers, 15 and 3 of 18 threads. Moving the accept loop
  onto main (an experiment, not kept) placed them 9 and 8, at the same
  throughput, since the two CPUs were already saturated; the 15-thread
  queue is what a request waits behind.
- Today: each of the `server`, `worker` and `feeds` roles sets
  `SPINEL_WORKERS` to `workers + 1` when `workers > 1`
  (`Application.spinel_workers_for`, cybertrain/roles/*.rb), so
  `SPINEL_WORKERS=2` as CyberTrain reads it starts two helpers again
  (spikes/NOTES.md rule 22).
- Fix, any of: (a) let main pump general threads while it blocks in
  `#join` / `#value` with helpers present, re-publishing its roots when it
  returns to the root fiber; (b) do not count a main that is blocked in
  `#join` among the N, e.g. start N helpers when main parks, or document
  that a program whose main only joins needs N+1; (c) for the second
  effect, place an unstarted thread spawned by a helper as main's spawns
  are placed, onto the worker with the fewest pinned threads.
- Settled upstream, the second half of (b): docs/thread.md on master
  494deaac says so in "The execution model" (da4485a5, "a main that only
  joins counts among SPINEL_WORKERS", 2026-11-06): main runs no thread it
  did not start on itself, a program whose main only starts threads and
  joins them has N-1 OS threads of work under `SPINEL_WORKERS=N`,
  `SPINEL_WORKERS=2` runs every thread on one helper, and such a program
  is to be given `SPINEL_WORKERS=N+1` or no variable at all. That is
  `Application.spinel_workers`, so the workaround is the documented use
  and nothing more is asked for the first effect. The second effect (a
  helper's spawns stay on the helper) was not looked for on master.

## From spikes/NOTES.md, not written up before

Three Spinel behaviours CyberTrain works around were recorded only as
rules in spikes/NOTES.md. They were looked at on 2026.11.04.7026 on
2026-11-04: one is still there (K), and the generated C of the other two
no longer shows the cause in the shape checked. A fourth, rule 79, was
found on 2026.11.04.7026 on 2026-11-04 and checked against the two
releases before it on 2026-11-05 (at the end).

### K. `puts` on a nil-only receiver does not compile once the TLS layer is in the program

Rule 78, found on 2026.10.26.7019; **still there on 2026.11.04.7026**.
When a receiver's type is nil-only (Logger's `@io` in a program that never
gives a logger an io), `@io.puts(line)` goes through the IO dispatch, and
once cybertrain/net/tls (Spinel's openssl package) is in the program the
dispatch's fallback does not compile: `passing argument 2 of
'sp_File_puts_bin' from incompatible pointer type
[-Werror=incompatible-pointer-types]`, an `sp_String *` where sp_io.h
wants a `const char *`. Checked on 2026.11.04.7026 by putting
`@io.puts(line)` back into `Logger#log` (cybertrain/logger.rb:57) and
building test/logger_tls.rb, which then failed to build (2026-11-05).
The method is `Logger#write_now` today, and the framework's program no
longer shows it: on 2026-11-19, and again on 2026-11-20, test/logger_tls.rb
built at `-O 0` with `@io.puts(line)` put back and matched its snapshot.
The reduced program below still fails in the C compiler
(spikes/rechecks/differing/nil_only_puts_openssl.rb).

Reduced on 2026-11-05 on 2026.11.04.7026 (a standalone class with a
nil-default `@io` and `require "openssl"` had not reproduced it on
2026.10.26.7019; what it takes is a String held in a variable):

```ruby
require "openssl"
class Lg
  def initialize = (@io = nil)
  def log(line)
    @io.puts(line) if @io
    nil
  end
end
Lg.new.log("hello")
puts "ok"                # CRuby: ok
```

2026.11.04.7026 stops at `@io.puts(line)` with the error above. Without
`require "openssl"` it builds, and so does `@io.puts("x#{msg}")`, an
interpolation in place of the parameter.

- Cause: with the openssl package in the program, `@io`'s `puts` goes
  through `emit_call_poly_io_arms` (src/codegen_call_io.c), and its
  default arm writes a String argument as `sp_File_puts_bin(_t13,
  lv_line)`: `lv_line` is the String's `sp_String *` handle, emitted
  without the conversion to its bytes. `STDOUT.puts(line)` in the same
  method passes `sp_strbuf_read_pub(lv_line)`.
- Fix, tested on a build of 2026.11.04.7026: wrap the argument in
  `SP_STR_B(...)`, which takes either an `sp_String *` or a `const char
  *`:

  ```diff
  -            if (bin2) buf_printf(b, "sp_File_puts_bin(_t%d, %s); ", tio2, at2);
  +            if (bin2) buf_printf(b, "sp_File_puts_bin(_t%d, SP_STR_B(%s)); ", tio2, at2);
  ```

  With it, the program above prints `ok`, the same class writing to a
  StringIO prints what CRuby prints, and test/logger_tls.rb with
  `@io.puts(line)` back in `Logger#log` passes. Spinel's own test suite
  was not run with the change, and the `print` arm beside it was not
  looked at. The fork's master (one commit past 2026.11.04.7026) has not
  touched this code.
- Today: `Logger#write_now` calls `@io.write(line)` on a line that
  `Logger.format_line` ends with a newline, which compiles through the
  same dispatch with the right argument type. test/logger_tls.rb was
  written as the regression program and builds either way today (above).
  With the fix released, `Logger#write_now` could go back to
  `@io.puts(line)`.
- Fixed upstream by matz/spinel#11129 ("puts and print on an IO known
  only at run time write a held String's bytes", 8ec94a54, merged
  2026-11-06), read on master 494deaac and not run here. It names the
  trigger more exactly than the above: any class in the program that
  defines `puts(*args)` (OpenSSL::Buffering does) makes the dispatch hold
  the argument as its handle. The arm now reads the argument with
  `emit_to_s_expr`, as the `write` arm beside it does, and `print`
  (`sp_File_write_bin`) is fixed with it; its test is
  test/poly_io_puts_print_string_local.rb. It is in no fork tag yet: with
  the pin on a tag that carries it, put `@io.puts(line)` back and keep
  test/logger_tls.rb.

### Rules 64 and 65: roots that were missing on 2026.09.12

- **Rule 64, class variables were not GC roots** (2026.09.12): `@@x`
  compiled to a C static that `sp_mark_user_globals` never marked, so an
  object reachable only from it was freed. On 2026.11.04.7026 a module's
  `@@items` holding an object is marked there (`if (cvar_Reg_items)
  sp_gc_mark(...)`) and survives `SPINEL_GC_STRESS=1`. CyberTrain keeps
  objects out of class variables anyway (test/harness_gc.rb).
- **Rule 65, a call's result in an argument list was not rooted while a
  later argument allocated** (2026.09.12; `File.join(home, "spinel",
  "#{tag}.lock")` read freed memory on macOS CI). On 2026.11.04.7026 the
  same shape roots the call's result (`SP_GC_ROOT(_t5)`) before the
  interpolation allocates. There was no AddressSanitizer run, so this is
  not a claim that it is fixed in general; CyberTrain keeps building the
  allocating argument first, in a local (cybertrain/cli/toolchain.rb).

### Rule 79: a rescuing method's value does not compile when its block only raises

Found on 2026-11-04 on 2026.11.04.7026 while re-checking rule 32, and
**not new in 2026.11.04.7026**: on 2026-11-05 the same program failed the same way on
2026.10.27.7020 and 2026.11.03.7025, so it is not a regression of the
2026-11-04 pin, only one that had not been tried before. CRuby prints
`["b"]`:

```ruby
def g
  yield
rescue => e
  e.message
end
out = []
out << g { raise "b" }
p out
```

- What happens: `spinel r79.rb` stops in the C compiler with "variable or
  field '_sp_fv' declared void" in spinel_rt.h (on all three releases,
  the note trail ends at the `SP_STR_HDL` expansion for line 2 and the
  `SP_STR_B` expansion for line 7). The block's only expression is a
  `raise`, so its value type is empty (void), and the code that appends
  `g`'s result declares a slot of that type. `p g { raise "b" }` and
  `p h(g { raise "b" })` compile, and so does a block that can also
  return a value (`raise "b" if x > 0; "ok"`).
- Today: nothing in the framework; a test of a rescuing helper gives the
  block a value after the `raise`, or passes the result through a method
  (spikes/NOTES.md rule 79).
- Fix: give a block whose body cannot complete the bottom type at the
  value slot (as the method's own `rescue` value is what the call
  answers), or type the call by the method's return type rather than the
  block's.
- Fixed upstream by matz/spinel#11137 ("A yielded block that ends in a
  raise builds where the call's String is stored", 805a3585, merged
  2026-11-06; its message opens with the program above), read on master
  494deaac and not run here: a block whose body diverges no longer takes
  the String-handle arm. #11143, #11144 and #11145 do the same for a
  block that ends in `exit` or `abort`, that leaves through `next` and
  otherwise raises, and that leaves by `throw`. In no fork tag yet.

### M. `gets` on STDIN does not flush a partial STDOUT line first

- Found on 2026.11.04.7026 (spikes/NOTES.md rule 83): `STDOUT.write("A> ");
  STDIN.gets` on a terminal shows `A> ` only after the line is read;
  CRuby flushes STDOUT before the read blocks. CyberTrain's console calls
  `flush` after its prompt. Fix: flush STDOUT (as CRuby's `rb_io_flush` on
  the tied stdout does) before a read from STDIN blocks.
- Fixed upstream by matz/spinel#11193 ("STDOUT on a terminal is written
  through, as CRuby's is", 820b9a6a, merged 2026-11-06), read on master
  494deaac and not run here: STDOUT is unbuffered when the program starts
  on a terminal, as CRuby's `FMODE_TTY` writes are, so the same holds for
  `print` followed by `sleep` and for `getc`, `readline` and `read`; a
  file or a pipe keeps its buffering. In no fork tag yet: with the pin on
  a tag that carries it, `Console.run`'s flushes can go (rule 83).

## Found by Daicho, an application built on CyberTrain

Reported on 2026-11-05 by the authors of Daicho, an application built on
CyberTrain 0.4.1, from reduced programs they built on 2026.11.04.7026 and
on matz/spinel master 60381c464: three Spinel behaviours (N, O, P) and
one refusal that is by design. Each was re-checked here on 2026-11-05 on
2026.11.03.7025 (the prebuilt release on the machine) and on
2026.11.04.7026 (built with `cybertrain setup`), with the programs below
as given, and the two releases behave alike on every one; the figures for
2026.10.27.7020 and for master are the report's. None has a workaround in
CyberTrain that an upstream fix would remove: N's shape is not in the
framework, and O and P are two of the reasons cybertrain/net/socket.rb
and `HttpClient` exist (docs/design.md D24), which stay for the
whole-request deadline and the address policy whatever Spinel fixes.

### N. A method's return type does not follow an ivar widened through an `attr_accessor` writer, and the C does not compile

Daicho's app/lib/daicho/prune.rb hit it in `delete_batches`. CRuby prints
`0`:

```ruby
class T
  attr_accessor :a
  def initialize
    @a = 0
  end
  def h
    { "a" => @a }
  end
end
def run
  t = T.new
  n = DB.with { |c| c.changes }   # a block call on a constant defined nowhere
  t.a = t.a + n
  t.h
end
p(ARGV.size > 5 ? run : 0)
```

2026.11.03.7025 and 2026.11.04.7026 (here) and master 60381c464 (the
report) stop in the C compiler:

```
m.rb:7: error: returning 'sp_StrPolyHash *' from a function with incompatible
       return type 'sp_StrIntHash *' [-Werror=incompatible-pointer-types]
```

- What it takes (the report tried each variation): a value of undecided
  type, the answer of a block call on an undefined constant, written to an
  ivar through an `attr_accessor` writer, and another method returning
  that ivar inside a Hash literal. A call without a block (`DB.count`) is
  inferred Integer and compiles; writing the ivar through an ordinary
  method's parameter compiles, and so does returning it in an Array
  literal.
- Cause (the report's `--emit-types` run): `h`'s body infers the Hash
  literal as `str_poly_hash`, which is right, while `h`'s signature stays
  `() -> Hash[String, Integer]` and the caller `t.h` is typed
  `str_int_hash`; in the generated struct the ivar is `sp_RbVal`. `@a` was
  Integer from `initialize`'s `0`, widened by the write in `run`, and the
  widening did not reach the method's return type.
- Fix, two the report suggests: recompute a method's return type from its
  body's final value when a later inference pass widens an ivar it reads
  (which pass fixes the return type was not traced); or, as a stopgap, a
  conversion in `emit_ret_hash_widen_conv` (src/codegen_stmt.c) for a
  `TY_STR_POLY_HASH` value returned where `TY_STR_INT_HASH` or
  `TY_STR_STR_HASH` is expected, built like `sp_StrIntHash_from_poly_hash`
  (lib/spinel_rt.h), which does this for `TY_POLY_POLY_HASH` today,
  raising TypeError for an element of the wrong type. The program above is
  the regression test (`.expected`: `0`).
- Today: Daicho writes `count = n.to_i` before the addition. Nothing in
  CyberTrain has the shape, so there is no workaround to drop here.
- Fixed upstream by matz/spinel#11184 ("A method answering a Hash of an
  ivar widened late returns the boxed-value Hash", ec775097, merged
  2026-11-06; its message opens with the program above) and #11219
  ("Calls bound to a Hash return that widened late bind again",
  2026-11-07), read on master 494deaac and not run here. It is the first
  of the two fixes: the late ivar re-run now lets a Hash of typed values
  follow its widened ivar to the boxed-value Hash, and the callers with
  it. In no fork tag yet.

### O. `TCPSocket.new(host, port, connect_timeout: t)` ignores the timeout

Known to CyberTrain since the HTTP client was designed (docs/design.md
D24, on 2026.09.12: "ignored on Spinel, 60 seconds or more against an
unreachable address") but never written up with a program. Daicho's
report has one; here it does not return within 20 s on 2026.11.03.7025
or 2026.11.04.7026 (killed), and the report says the same of
2026.11.04.7026 and master 60381c464 (70 s). CRuby prints `err
IO::TimeoutError` and `bounded`:

```ruby
require "socket"
t = Time.now.to_f
begin
  TCPSocket.new("10.255.255.1", 81, connect_timeout: 2)
  puts "connected"
rescue SocketError, StandardError => e
  puts "err " + e.class.name
end
puts((Time.now.to_f - t) < 5 ? "bounded" : "unbounded")
```

- Cause (the report's): the `TCPSocket.new` emission in
  src/codegen_call.c (near line 15965) passes `argv[0]` and `argv[1]` to
  `sp_net_connect` and reads no keyword, and nothing warns.
  `sp_net_connect_timeout(host, port, timeout_s)` and
  `sp_net_take_connect_timeout()` have been in lib/sp_net.c since
  59c06d979 (2026-10-19), with tests (test/sp_net_connect_timeout*.rb),
  and no code generation calls them.
- Fix (the report's): emit `sp_net_connect_timeout` when
  `connect_timeout:` is given; on -1 with `sp_net_take_connect_timeout()`
  set, raise `IO::TimeoutError` (CRuby's text is `Connect timed out!`),
  otherwise fail as `sp_net_connect`'s failure does; `connect_timeout:
  nil` is no limit, as in CRuby (a negative value does that in the
  runtime function today); refuse the other keywords (`resolv_timeout:`)
  instead of dropping them.
- Today: cybertrain/net/socket.rb connects with `connect_nonblock` +
  `wait_writable` + `SO_ERROR` (spikes/NOTES.md rule 72) and never calls
  `TCPSocket.new`, so nothing in the framework is affected, and the
  socket layer stays after a fix for the per-request deadline. A fix
  removes a sentence, not code: socket.rb's header,
  docs/guide/external-services.md and its translations name the ignored
  keyword.
- Fixed upstream by matz/spinel#11183 ("TCPSocket.new gives up on an
  unanswered connect after connect_timeout:", acd880f6, merged
  2026-11-06), read on master 494deaac and not run here: the call goes
  through `sp_net_connect_timeout` and raises `IO::TimeoutError` with
  CRuby's message, `nil` is no limit, and `TCPSocket.open` without a
  block is the same call. In no fork tag yet; with the pin on a tag that
  carries it, the sentence in socket.rb's header and the guides is to be
  revised, as P's is.

### P. Net::HTTP against a TLS peer that accepts and never answers does not return at `open_timeout` / `read_timeout`

The report: on 2026.10.27.7020 the request returned at the timeout but
other threads stopped while it waited; on 2026.11.04.7026 it had not
returned when killed at 40 s; on matz/spinel master 60381c464 it does
what CRuby does (an error at the timeout, the other threads running),
since dcc46945c ("Bound Net::HTTP TLS handshakes and response reads",
2026-11-05). Here, with the program below at `SPINEL_WORKERS=1`,
2026.11.03.7025 and 2026.11.04.7026 both return only when the server
closes the socket after 30 s (`err OpenSSL::SSL::SSLError: SSL_connect
returned an error: TLS handshake failed`, `unbounded 30.1`), 28 s past
`open_timeout`; the counting thread did advance here (`other thread
ran`), unlike in the report's 2026.10.27.7020 run. CRuby prints `err
Net::OpenTimeout: Net::OpenTimeout`, `bounded 2.1`, `other thread ran`.
(`require "openssl"` is needed: without it Spinel's net/http raises
`an https request needs the openssl package` at once.)

```ruby
require "socket"
require "net/http"
require "openssl"
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
holder = Thread.new do
  s = srv.accept
  sleep 30
  s.close
end
ticks = 0
counter = Thread.new do
  while ticks < 100
    ticks += 1
    sleep 0.2
  end
end
t0 = Time.now.to_f
http = Net::HTTP.new("127.0.0.1", port)
http.use_ssl = true
http.open_timeout = 2
http.read_timeout = 2
begin
  http.get("/")
  puts "ok"
rescue StandardError => e
  puts "err " + e.class.name + ": " + e.message
end
el = Time.now.to_f - t0
puts((el < 10 ? "bounded" : "unbounded") + " " + el.round(1).to_s)
puts(ticks >= 5 ? "other thread ran" : "other thread stalled #{ticks}")
```

- Cause: the handshake (`SSL_connect`) and the reads after it are
  blocking calls inside the package that `open_timeout` / `read_timeout`
  do not bound (docs/design.md D24, which is why `HttpClient` does its
  own). The connect itself, `open_timeout` against an address that does
  not answer, is bounded on 2026.11.04.7026 and lets other threads run,
  per the report.
- Fix: dcc46945c on matz/spinel master. Nothing to write; what is left is
  a fork tag that carries it and a `SPINEL_TAG` move. On 2026-11-11 the
  fork still has no tag after 2026.11.04.7026.
- Today: `Cybertrain::HttpClient` (D24) does the handshake and every read
  with `connect_nonblock` / `read_nonblock` and bounded waits, and stays
  whatever Net::HTTP does: the whole-request `deadline` and the refusal of
  non-public addresses are its own. The header comment of
  cybertrain/http_client.rb and the guides' "why it exists" describe
  Net::HTTP's blocking waits, which is true on the pinned release; once
  the pin is on a tag that carries dcc46945c, that sentence is history and
  is to be revised with the move. What Net::HTTP would still lack for a
  webhook sender, the report notes, is `Net::HTTP#ipaddr=` (CRuby's:
  connect to a given address while Host and SNI keep the name, the usual
  shape of a DNS-rebinding defence; not in packages/net/net/http.rb on
  master 60381c464) and a deadline for the whole request, which CRuby's
  Net::HTTP has not either.

### A refusal of a never-reached class-method call (by design)

Daicho's test/envelope.rb, which loads part of the framework, met it;
re-checked here on 2026.11.03.7025 and 2026.11.04.7026. CRuby prints `0`:

```ruby
module Cybertrain
end
def f = Cybertrain.config.port
puts(ARGV.size > 5 ? f : 0)
```

Spinel refuses it: `undefined method 'config' for a Class: no class in
the program defines a class method 'config' (NoMethodError)`, `1 refusal,
nothing written`. Deliberate: `unsup_message` in src/codegen_util.c
classes the call `CR_NOMETHOD`, a NoMethodError found ahead of time. An
undefined *constant* in the same position is treated the other way:
`warning: uninitialized constant Nope: defined nowhere in the program
(raises NameError when reached)`, and the program builds and raises
NameError only when the call runs (checked here). `--defer-refusals`, or
`# spinel: defer-refusals` at the top of the file, builds the refused
program too, and what it raises when reached is NotImplementedError
carrying the refusal's text, not CRuby's NoMethodError (checked here).

The question for upstream, if one is sent: whether `CR_NOMETHOD` should
match the constant case (warn, raise NoMethodError when reached), which
would let a program that loads part of a library build, at the price of a
real mistake surfacing at run time. CyberTrain asks for nothing: a file
that names `Cybertrain.config` requires cybertrain/config, which is right
under CRuby too (spikes/NOTES.md rule 84).

The report's other note, that `"99999999999999999999999".to_i` raises
`RangeError` where a comparison of the parsed value works, is D, by
design in the default `--int-overflow=raise` mode; its "compare before
converting" is the right shape in either mode.

## Found in phase 2 of the Rails-gap programme (2026-11-06)

The data-layer design (docs/superpowers/specs/2026-11-06-phase2-data-layer-design.md,
section 14) ran seven checks against 2026.11.04.7026 before any code was
written; six passed, and this is the one that did not.

### Q. A Range of Time or Date raises at construction; a Float Range is not a Range once boxed

CRuby accepts a Range of any comparable ends and `when Range` matches it
wherever it is held. Spinel 2026.11.04.7026 keeps a Range as two Integers.
Reduced from the spike's first program (a `test "..."` block each):

```ruby
def ends_of(v)
  out = Array.new(0) { "" }
  case v
  when Range
    out << v.begin.to_s
    out << v.end.to_s
  end
  out
end

test "Float range through a boxed value" do
  assert_equal ["1.5", "2.5"], ends_of(1.5..2.5)
end

test "String range through a boxed value" do
  assert_equal ["a", "z"], ends_of("a".."z")
end

test "Time range in a Hash value" do
  t1 = Time.utc(2026, 1, 1)
  t2 = Time.utc(2026, 2, 1)
  h = { created_at: t1..t2 }
  assert_equal 2, ends_of(h[:created_at]).size
end
```

The build accepts it. The first test fails: `1.5..2.5` is not matched by
`when Range` once passed through the boxed parameter `v`, so `ends_of`
answers an empty Array. The second passes: a String Range is matched,
through the parameter and out of a Hash value. The third raises
`TypeError: no implicit conversion of Time into Integer` when `t1..t2` is
built. This is the re-run of 2026-11-15 on the pin, in the test harness
and as a plain program (spikes/rechecks/differing/float_range_boxed.rb,
and spikes/rechecks/container_shapes.rb for the String and Integer
Ranges). Until then this section said the String test failed as well;
the spike's own program of 2026-11-06 is not kept, so whether it differed
from the one above is not known.

The second program reads the same Ranges directly, with no boxed value:

```ruby
test "Float range direct" do
  r = 1.5..2.5
  assert_equal 1.5, r.begin
  assert_equal 2.5, r.end
end

test "Range.new of Times" do
  t1 = Time.utc(2026, 1, 1)
  t2 = Time.utc(2026, 2, 1)
  r = Range.new(t1, t2)
  assert_equal 2026, r.begin.year
end

test "Integer range is a Range in a case" do
  v = 1..5
  seen = case v when Range then "range" else "other" end
  assert_equal "range", seen
end
```

A Float (and a String) Range reads back directly, and an Integer Range is
matched by `case ... when Range`, but `Range.new(t1, t2)` raises the same
`TypeError` as the literal `t1..t2`, and so does a Range of `Date` ends.

- What CyberTrain does with it (phase 2 of the Rails-gap programme,
  docs/superpowers/specs/2026-11-06-phase2-data-layer-design.md 3.1 and
  9.1, delivered 2026-11-07): `where(col: a..b)` (cybertrain/relation.rb)
  accepts Integer ends only; any other bound goes through
  `where_between(col, from, to)`, and the validator options
  `inclusion: { in: }` / `exclusion: { in: }` take an Integer Range or an
  Array (cybertrain/validator.rb; spikes/NOTES.md rule 86).
- Upstream, read on master 494deaac and not run here: matz/spinel#10998
  ("Ranges of Times and of the program's comparable objects", merged
  2026-11-05, the day after the pinned tag) builds `t1..t2` over Times
  (test/time_range.rb, test/time_range_boxed.rb), and docs/limitations.md
  there calls a Range of Dates a Range of objects, with its limits listed
  ("most Enumerable methods" over a boxed one). So the construction
  `TypeError` should be gone on master. For the Float half
  (`when Range` missing a boxed `1.5..2.5`), master has
  tests of boxed Float and String Ranges but none was matched to the
  first program above. Not reported upstream: run both programs on a fork
  tag that carries master first, and report only what still fails. If
  both pass there, `where(col: a..b)` and the validators can take Time,
  Date, Float and String ends, and `where_between` stays as the spelling
  for mixed bounds.
- Sent and merged (2026-11-13): the first program was run on master
  494deaac on 2026-11-12. Nothing raised at construction there (#10998),
  the String Range was matched, as on the pin, but the Float Range and the Time
  Range held in a Hash value were not (`[]` and `0`). matz/spinel#11639
  ("A boxed Range of Float, Time or object ends is a Range to when, in
  and a class value", merged 2026-11-12) fixes that: a boxed Range
  carries the class id of its representation, one of five, and the three
  places that ask whether a boxed value is a Range named only some of
  them. `when Range`, `in Range`, `is_a?` with the class held in a value
  and `is_a?(Enumerable)` now agree for Float, Time and object ends. On
  master 1c0cc5e35 the first program prints `["1.5", "2.5"]`, `["a",
  "z"]` and `2`, `Range.new(t1, t2).begin.year` is 2026, and a Range of
  Dates answers `begin` and `cover?`. In no fork tag yet, so
  `where(col: a..b)` and the validators are as they were.

## Found in phase 3 of the Rails-gap programme (2026-11-09)

The jobs-and-outbound design (docs/superpowers/specs/2026-11-07-phase3-jobs-outbound-design.md,
section 14) ran six checks against 2026.11.04.7026 before any code was
written; all six passed, and this was found while writing the second.

### R. A `rescue` arm naming a qualified class the program does not define

CRuby evaluates a `rescue` arm's class when the arm is tried, so an arm
naming a constant that does not exist raises NameError, which the caller
sees. Spinel 2026.11.04.7026 resolves the arm by its last segment instead.
With `Outer` defined and `Missing` defined only at top level:

```ruby
module Outer; end
class Missing < StandardError; end

begin
  raise Missing, "m"
rescue Outer::Missing => e
  puts "rescued by Outer::Missing"
rescue NameError => e
  puts "NameError in arm"
end
```

CRuby raises `NameError: uninitialized constant Outer::Missing` from the
arm; the compiled program prints "rescued by Outer::Missing", with no
warning at compile time (`p Outer::Missing` in an expression does raise
NameError). With no `Missing` anywhere the arm never matches and the next
arm is tried.

When a middle segment is missing and the last one names a class defined
elsewhere, the whole `begin` / `rescue` swallows every exception and runs
no arm:

```ruby
module Outer
  module Net
    class TimeoutError < StandardError; end
  end
end
class AppError < StandardError; end

def inner(log)
  begin
    raise AppError, "boom"
  rescue Outer::Mailer::TimeoutError => e
    log << "arm Mailer"
  rescue AppError => e
    log << "arm AppError"
  end
  nil
end

log = []
begin
  inner(log)
rescue StandardError => e
  log << e.class.name
end
p log
```

CRuby prints `["NameError"]`; the compiled program prints `[]` (the
generated C catches everything and only evaluates the missing class). The
compiler warns "uninitialized constant Outer::Mailer: defined nowhere in
the program (raises NameError when reached)". Without a `TimeoutError`
elsewhere the program raises NameError as CRuby does, and classes that
exist resolve by their full name (`rescue A::TimeoutError` and `rescue
B::TimeoutError` side by side each catch their own).

- What CyberTrain does with it (phase 3): the generated `run_job` names only
  classes the program defines (the application's classes found by the job
  scan, and framework classes whose files the application requires;
  `require "cybertrain"` does not load cybertrain/mailer), and treats the
  warning on a `rescue` line as an error (spikes/NOTES.md rule 89).

A third shape, where every class exists (spikes/NOTES.md rule 81, found
on 2026-11-05 in cybertrain/console.rb, run again on 2026-11-11 on
2026.11.04.7026): a relative path in a `rescue` arm whose first segment
names a module that holds a class of the same name.

```ruby
module Outer
  module Inner
    class Inner; end
    class Oops < StandardError; end
    def self.boom = raise(Oops, "x")
  end
end
module Outer
  module User
    def self.run
      s = "none"
      begin
        Inner.boom
      rescue Inner::Oops => e
        s = "oops"
      rescue StandardError => e
        s = "std"
      end
      s
    end
  end
end
puts Outer::User.run
```

CRuby prints `oops`. Spinel 2026.11.04.7026 warns "uninitialized
constant Inner: defined nowhere in the program (raises NameError when
reached)" for the `rescue Inner::Oops` line and the program prints
`none`: no arm ran, not even `rescue StandardError`, and the exception
did not leave the `begin`. Without `class Inner` inside `Inner` both
agree, and the same path outside a `rescue` (`Inner.boom`, two lines up)
resolves. It is the second program's failure, the whole `begin`
swallowing the exception, reached from a constant that does exist.

- What CyberTrain does with it: a rescued class is spelt from the top
  (`rescue Cybertrain::Template::SyntaxError`, cybertrain/console.rb), and
  the warnings `spin test` prints are read.
- Asked of Spinel, in order of harm: (a) a `begin` whose arm names a
  class Spinel cannot resolve must not swallow the exception: raise
  CRuby's NameError from the arm, as test/rescue_undefined_constant_raises.rb
  (#10440) already does for a constant defined nowhere; (b) resolve a
  relative path in an arm as the same path is resolved in an expression
  (lexical scope first, so `Inner::Oops` is `Outer::Inner::Oops`); (c) do
  not match an arm by its last segment.
- Not reported upstream yet, and no issue found for it (searched
  matz/spinel's issues on 2026-11-11). On master, 24d05c78 ("A raise or
  a rescue arm asks the node for the class it matches", 2026-11-07)
  changed how an arm finds its class; whether the three programs answer
  differently after it is not known without a build, so they are to be
  run on master before a report is written.
- Sent and merged (2026-11-13): on master 494deaac the first program still
  printed `rescued by Outer::Missing` and the second `[]`.
  matz/spinel#11650 ("A rescue clause naming a path that fails past its
  first name raises NameError when reached", merged 2026-11-12) answers
  (a) and (c): the arm finds the segment of the path the lookup fails
  on, reading left to right as CRuby does, and raises that segment's
  NameError when an exception reaches the arm; an arm is no longer
  matched by its last segment when the module before it holds no such
  constant. Two changes came out of its review, both merged the same
  day: #11689 (the lookup asks each ancestor once; a program of 35
  modules that each include the three before them did not finish
  compiling in 90 s, and takes 0.3 s) and #11690 (a `const_missing`
  given by `define_singleton_method` or `define_method` counts as the
  hook, as a `def` does). On master 1c0cc5e35, which has #11650 and
  not the other two, the first program prints `outer NameError:
  uninitialized constant Outer::Missing` when wrapped in an outer
  `rescue NameError`, the second `["NameError"]`, and the third `oops`.
  Which commit fixed the third, (b), was not looked for. In no fork tag
  yet.

### S. A `yield` passed as an argument runs the block twice when blocks differ in type

A method that passes `yield` straight to another method whose parameter
goes through a `case` runs the block twice under Spinel 2026.11.04.7026
when the method is called with blocks of different value types:

```ruby
module C
  def self.str(v)
    case v
    when nil then ""
    when String then v
    else v.to_s
    end
  end
end
module M
  def self.f
    C.str(yield)
  end
end
N = Array.new(0) { "" }
a = M.f do
  N << "a"
  "one"
end
b = M.f { 42 }
puts "#{a} #{b} #{N.join(",")}"
```

CRuby prints `one 42 a`; the compiled program prints `one 42 a,a`. With
`{ "s" }` in place of `{ 42 }` (one value type at every call site) the
block runs once. The `&block` form, `def self.g(&block) =
C.str(block.call)`, called the same way, runs it once.

- What CyberTrain does with it (phase 3): Cybertrain::Cache's `fetch`,
  `fetch_hash`, `fetch_array` and `fetch_int` assign the block's value to
  a local before casting it (`computed = yield; value =
  Cast.str(computed)`; spikes/NOTES.md rule 90).
- Asked of Spinel: evaluate a `yield` in an argument once, whatever the
  callee's parameter is converted to (bind the block's value to a
  temporary before the dispatch on its type, as the `&block` form does).
  It is the first thing asked: nothing warns, and a block with a side
  effect (a counter, an INSERT, a cache fill) does it twice.
- Not reported upstream yet, and no issue or commit found for it on
  master 494deaac (2026-11-11). Spinel's
  test/yield_argument_diverging_block_types.rb, which the pinned tree
  already has, is this shape (a `yield` as an argument, blocks of
  different types) and checks only the values; the program above, with
  its count of runs, would extend it.
- Sent and merged (2026-11-13): matz/spinel#11643 ("A yield passed as an
  argument runs its block once; a method called again from its own block
  runs its own arguments", merged 2026-11-12). A call runs an argument
  into a temporary ahead of binding it; the code that boxes a value for
  a parameter of more than one type did not ask whether a `yield` had
  already run, and ran the block again. The same change fixes what that
  second run had been hiding: `def self.k(x) = C.cat(note(x), yield)`
  called from its own block (`M.k("p") { M.k("q") { "s" } }`) answered
  `p/p/s` where CRuby answers `p/q/s`. On master 1c0cc5e35 the program
  above prints `one 42 a`. In no fork tag yet, so the fetch family keeps
  its local.

### T. `exit` on a thread other than the main one ends only that thread

```ruby
def die_later(code)
  Thread.new { sleep(0.2); exit(code) }
end
die_later(1)
sleep(1.0)
puts "main still alive"
```

CRuby exits with status 1 and prints nothing: `exit` raises `SystemExit`,
which ends the process. Compiled with Spinel 2026.11.04.7026 the program
prints `main still alive` and exits 0: only the thread that called `exit`
ended (checked again on 2026-11-10 with `spinel exit_thread.rb`).

- What CyberTrain does with it (phase 3): the feed supervisor
  (cybertrain/background/supervisor.rb) never calls `exit`; after a feed's
  repeated deaths it logs the FATAL line and sets
  `Background.feeds_failed?`, and the `feeds` role's main thread
  (`Roles::FeedsRunner#run_feeds_threads`, cybertrain/roles/feeds.rb)
  stops the feeds and returns 1, the status `Main.run`'s caller exits
  with (spikes/NOTES.md rule 91).
- Fixed on matz/spinel master, read on 494deaac and not run here:
  test/thread_exit_raises_in_main.rb, whose header is this item ("`exit`
  in a thread other than main ended that thread and nothing else ...
  CRuby raises the SystemExit in the main thread, from whatever wait it
  is in, so its ensures and at_exit hooks run"), is in master since
  before #11035 (2026-11-05) and is not in the pinned tree, with
  test/thread_exit_beside_main_raise.rb and
  test/thread_exit_does_not_wait_for_blocked.rb beside it. Nothing to
  report. With the pin on a tag that carries it nothing in CyberTrain has
  to change: the supervisor's flag and main's return are right either
  way, and rule 91 becomes history.

## Found in phase 4a of the Rails-gap programme (2026-11-10)

The web-layer design (docs/superpowers/specs/2026-11-10-phase4-web-layer-design.md,
section 12) ran five checks against 2026.11.04.7026 before any code was
written (spikes/phase4/, deleted since); all five passed, one with a stub,
and these were found while writing the third.

### U. A `def` inside a block that never runs defines the method anyway

```ruby
module Concern
  def class_methods(&block) = nil
end
module Gate
  extend Concern
  class_methods do
    def per_page = 50
  end
end
class C
  include Gate
end
puts "#{C.new.respond_to?(:per_page)} #{Gate.respond_to?(:per_page)}"
```

CRuby prints `false false`: the block never runs, so `per_page` is never
defined. Compiled with Spinel 2026.11.04.7026 the program prints `true
false`: the `def` was compiled as an instance method of `Gate`, the code
around the block, and `C` has it through the include.

- What CyberTrain does with it (phase 4a): a concern's `class_methods do
  def x ... end end` is written by gen as `def self.x` on the concern and
  a forwarding `def self.x(...)` in each including class (plan decision
  12); since `x` is also an instance method of every including class
  under Spinel, gen refuses a `class_methods` name that an instance method
  of the concern or of an including class has (spikes/NOTES.md rule 93).
  Since the final fixes of phase 4a (2026-11-11) the refusal also covers
  the including class's ancestors and its other concerns, and a model
  concern's `class_methods` name against the model's instance methods,
  its scopes and the class methods every model has
  (cybertrain/generator/concerns_emitter.rb, `ConcernScan::RULE_93`): an
  application author meets this Spinel behaviour as a gen error asking
  for a rename.
- Asked of Spinel: do not define a method from a `def` in a block that
  the program never calls; or, short of that, define it where CRuby
  would if the block ran (here nowhere on `Gate`'s instances), or refuse
  the program. Today a name appears on a class silently.
- Not reported upstream yet, and no commit found for it on master
  494deaac (2026-11-11). The open proposals matz/spinel#9898
  ("Load-model migration: per-file scopes, run-time requires, definitions
  at their point") and #10866 ("a call reaches the method CRuby's table
  holds when the call runs") are about when a definition takes effect,
  and are where this program belongs.
- Sent and merged (2026-11-13): matz/spinel#11683 ("A block a class body
  hands to a method that never uses its block defines nothing", merged
  2026-11-12). The block's body is left out, as the dead arm of `if
  false` is, when the call is on `self` in a class or module body, the
  method is a `def` of the program's, and no `def` of that name anywhere
  uses its block (a `yield`, a read of the block parameter, `&`, `...`,
  a `super`), is redefined another way, or is removed. On master
  1c0cc5e35 the program above prints `false false`. Two things to
  know before the pin moves: a method only such a block would have
  defined is now defined nowhere, so a call of it is refused when the
  program is built (CRuby raises NoMethodError when the call runs); and
  blocks handed over in a loop, on another receiver, or to a method that
  tests or keeps its block parameter without calling it still define
  their methods. `ActiveSupport::Concern#class_methods` takes `&block`
  and does nothing with it, the shape the fix covers, so the refusal of
  rule 93 can be looked at again then. In no fork tag yet.

### A refusal inside a block that never runs (by design)

`ActiveSupport::Concern#included(&block)` in CyberTrain does nothing, so
a concern's `included do before_action :x end` never runs under CRuby. Spinel
2026.11.04.7026 compiles the block anyway, resolves `before_action` on the
block's `self`, the concern module, and refuses the program ("unsupported
call: ... (CallNode `before_action`)", 1 refusal, nothing written), though
Cybertrain::Controller defines `before_action`. This is the ahead-of-time
NoMethodError of "A refusal of a never-reached class-method call" above,
met from a receiver Spinel knows; CyberTrain asks for nothing:
`ActiveSupport::Concern` defines a no-op for each declaration an
`included` block may make (spikes/NOTES.md rule 92). The stubs cover only
the declarations themselves: a call inside a block in the block, such as
the `where` of `scope :visible, -> { where(hidden: 0) }` in a model
concern's `included`, is refused the same way, and stubbing every Relation
method on the concern would give those names a second return type (rule
34). So gen does not let Spinel see the blocks at all: it loads each
concern from a copy in `gen/concerns/` with its `included` and
`class_methods` blocks blanked, and splices their bodies into the
including classes (phase 4a Task 7, 2026-11-10; docs/design.md D60).

### V. `strftime` with a built pattern on a Time or Date returns the pattern

In `Template::Helpers#time_tag`, a value narrowed by `case value when
Time` from a slot that can also hold a Date, formatted with
`value.strftime(pattern)` where `pattern` is a String built at run time
(from `format:`), returns `pattern` itself, unformatted, under Spinel
2026.11.04.7026; CRuby formats it. The generated C shows why: the
polymorphic dispatch (`sp_pd_*`) reads the pattern with
`sp_strbuf_read_pub(pattern)`, and the caller then takes the stale
`_sp_ret_strbuf`, which still holds the pattern. The variant that takes a
`const char*` (a literal pattern) formats correctly.

- What CyberTrain does with it (phase 4a Task 17): `Strftime.walk`
  (cybertrain/strftime.rb; reached from
  `Template::Helpers.time_tag_strftime` and `I18n.l`) parses the pattern
  and calls `strftime` with a literal for each directive it supports,
  applying flags and widths itself, and raises for an unknown directive
  (spikes/NOTES.md rule 96).
- Not reduced to a standalone program yet; not reported upstream. Five
  programs tried on 2026-11-11 on 2026.11.04.7026 all format correctly: a method
  `fmt(t, pattern) = t.strftime(pattern)` called with a Time and with a
  Date and a pattern built by `+`; the same with the receiver narrowed by
  `case value when Time ... when Date`; a receiver read out of an Array
  of mixed values, with and without that narrowing; and the framework's own shape, with the value from
  `args[0]`, the pattern from a Hash of mixed values through a `case`
  that returns it, and one helper called from both arms. So the trigger
  is more of the program than the call; the next step is to put
  `time.strftime(pattern)` back into `Strftime.walk`'s caller
  (`time_tag_strftime`) and cut test/helpers.rb down around it. AS shows
  the same stale `_sp_ret_strbuf` on `ENV[name]`, in a short program
  against two framework files; reducing either should help with the
  other.
- Not the same as matz/spinel 612f4ac5 ("Time#strftime builds its result
  in a buffer of the thread's own", 2026-11-08, refs #11352), which makes
  `sp_timev_strftime`'s static result buffer thread-local: here the
  wrong answer comes with one thread, from the dispatch reading the
  pattern into `_sp_ret_strbuf`. To be run again on a tag that carries
  it all the same.

### W. An ivar String passed to a stored lambda is refused

examples/blog's program was refused with "a String is passed through `a
proc.call` ..." at `Views.component_builder.call(@name, kwargs)` in
`Cybertrain::Component`, where `component_builder` is a lambda stored on
the `Views` module and `@name` a String ivar; the same call with a fresh
local (`name = "#{@name}"`) builds. It showed only in the blog's
program, so the trigger needs more of a program than that line.

- What CyberTrain does with it (phase 4a Task 17): `Component` passes the
  interpolated local (spikes/NOTES.md rule 97).
- Not reduced; not reported upstream.

### X. Type inference does not converge in examples/blog's generator

`spin run gen` in examples/blog stopped at the compile of `bin/gen.rb`
with "type inference did not converge in 128 rounds" after one change to
`Gen::Runner.run`: holding the controller scan and the concern scan of
`app/controllers` in locals and passing both to two emitters. Bisected to
that change.

- What CyberTrain does with it (phase 4a Task 5): each emitter scans
  `app/controllers` for itself (`Runner.controllers_source`,
  `concerns_source`), so the directory is read twice (spikes/NOTES.md rule
  94).
- Not reduced; not reported upstream.

## Re-checked on 2026-11-11

Five rules of spikes/NOTES.md that describe a Spinel behaviour, have a
reduced program and were never written up here, run on the pinned
2026.11.04.7026 (`spinel prog.rb -o prog`) beside CRuby 3.3.6. Rule 81
is under R (its third shape); 82 and 88 are Y and Z below, both found
while building phases 1 and 2 and worked around across the framework
since.

### Y. A lambda written into a module-body ivar never learns its parameter's type

Rule 82, found on 2026-11-05 in test/template_integration.rb once
`Controller#render_template` called `Views.helpers_builder`.

```ruby
class Ctl
  def session = "sess"
end
class H
  def initialize(c)
    @c = c
  end
  def who = @c.session
end
module V
  @b = ->(c) { H.new(c) }
  def self.b = @b
end
puts V.b.call(Ctl.new).who
```

CRuby prints `sess`. Compiled with Spinel 2026.11.04.7026 the program
builds with no warning and raises `undefined method 'session' for an
instance of Integer (NoMethodError)`: the lambda's parameter kept the
Integer default, so `H.new` was handed the object as an Integer.

- What it takes: the lambda literal as the initialiser of a module-level
  ivar in the module body, called with an argument through a reader. The
  same lambda returned by a method builds and prints `sess` (checked
  here: `def self.default_b = ->(c) { H.new(c) }; @b = default_b`), and
  so does a literal passed positionally to a setter at top level (rule
  82; what gen/helpers.rb does).
- What CyberTrain does with it: every stored lambda of the framework is
  made in a method: `Views.default_url_resolver`,
  `Views.default_helpers_builder` and `Views.default_component_builder`
  (cybertrain/views.rb) and `Assets.empty_resolver`
  (cybertrain/assets.rb). An application that writes `@x = ->(a) { ... }`
  in a module body of its own meets it with nothing to point at the
  cause.
- Asked of Spinel: type the parameters of a lambda stored by a
  module-body ivar assignment from the `.call` sites of that ivar's
  readers, as is done for a lambda a method returns; or, until then,
  refuse the call at compile time instead of passing an Integer.
- Not reported upstream yet; no issue found for it on 2026-11-11. On
  matz/spinel master 1c0cc5e35 (2026-11-13) the program raises the same
  NoMethodError.

### Z. A stored block called with a base-class receiver runs the base class's method, not the override

Rule 88, found on 2026-11-06 while writing declared associations, where
a `before_save { |r| r.hook }` block registered by a model reached
`Cybertrain::Model`'s stub instead of the model's method.

```ruby
class Base
  @cbs = []
  def self.cbs = @cbs
  def self.add(&block)
    Base.cbs << block
    nil
  end
  def hook = nil
  def run
    out = "none"
    Base.cbs.each do |cb|
      v = cb.call(self)
      out = v.to_s
    end
    out
  end
end
class Sub < Base
  add { |r| r.hook }
  def hook = "sub"
end
puts Sub.new.run.inspect
```

CRuby prints `"sub"`. Compiled with Spinel 2026.11.04.7026 the program
prints `""`: inside the stored block `r.hook` ran `Base#hook`, though
`r` is a `Sub`. With the line `def hook = nil` removed from `Base` the
compiled program prints `"sub"` (checked here), and a call on implicit
self inside a `Base` method dispatches to the override as expected (rule
88).

- What it takes: a block written in a subclass's body before that
  subclass's `def` of the method it calls, stored, and later called with
  `self` from a base-class method, the method being defined on both
  classes. With the `add { |r| r.hook }` line moved below `def hook =
  "sub"` the compiled program prints `"sub"`, and so does the same block
  registered at top level after both classes (found 2026-11-13,
  spikes/NOTES.md rule 111; re-run 2026-11-15). The block's parameter
  is typed from the call site in `Base#run`, as a `Base`, and the call in
  the block is bound to `Base`'s method instead of being dispatched on
  the object's class.
- What CyberTrain does with it: no method that only stored blocks call
  has a stub on its base class: the generated `counter_cache_created` /
  `_destroyed` / `_was` / `_moved` are not on `Cybertrain::Model`
  (test/gen_models_compiles.rb, test/counter_cache_two_models.rb), and a
  job's registered block calls the concrete class's `run_job`, never
  through `Job::Base` (cybertrain/generator/jobs_emitter.rb,
  cybertrain/mailer/later.rb). Where a block would have to be stored and
  called through a base class, it is run at once instead: `respond_to`'s
  format blocks (cybertrain/format_collector.rb), a controller's
  `content_security_policy` block (cybertrain/controller.rb), a Turbo
  Stream builder's block (cybertrain/template/turbo_stream_builder.rb).
  An application's own `before_save { |r| r.x }`, which is normally
  written above `def x`, is safe only because `x` has no definition on
  `Cybertrain::Model`.
- Asked of Spinel: dispatch a call on a block parameter by the object's
  class when the parameter's static class has subclasses that override
  the method, as a call on implicit self already does. On master,
  e86b6d94 ("A dispatch on self leaves out the descendants that override
  the method it runs in", 2026-11-11) and #11335 ("A bare call in a
  block runs a subclass's own method", 2026-11-08) are near this code;
  neither names this shape, and the program is to be run on a tag that
  carries them before it is reported.
- Not reported upstream yet; no issue found for it on 2026-11-11. On
  matz/spinel master 1c0cc5e35 (2026-11-13) the program prints `""` as on
  the pin.

### Rule 66: direct appends to a String local no longer lose a helper's

Found on 2026.09.12: a String local that a method appended to directly
two or more times lost what a helper had appended to it through a
parameter. Its program, `def add(buf, s) = buf << s` and `def two; buf =
"".b; add(buf, "ab"); buf << "\n"; buf << "\n"; buf; end; p two`, printed
`"\n\n"` there. On 2026.11.04.7026 it prints `"ab\n\n"`, as CRuby does.
Not reproduced, and nothing is asked. The framework's habit that a
buffer filled through helpers is filled only through helpers
(test/time_zone.rb's TZif writer) can be relaxed in new code; the second
half of rule 66 (an instance method named `name` on a framework class)
was not re-checked.

### Rule 70: an aliased module in a `rescue` arm, not reproduced when reduced

`rescue DB::Error => e` with `DB = Cybertrain::DB` at the top of a
program that requires the whole framework matched on the names "Error" /
"DB::Error" and never caught a `Cybertrain::DB::Error` (2026.09.12,
test/db_transaction_api.rb). A twelve-line program of that shape
(`module Cy; module DB; class Error < StandardError; ...`, `DB =
Cy::DB`, `rescue DB::Error => e`) rescues it on 2026.11.04.7026, as it
did in the smaller test program on 2026.09.12, so this says nothing
about the whole-framework case. It belongs with R (an arm matched by
name instead of by class), and the framework spells a rescued class from
the top either way.

## Build time, measured on 2026-11-12

Measured for the development flow of an application
([the spec](superpowers/specs/2026-11-12-dev-flow-bottlenecks-design.md)):
CyberTrain 34c9b7e, Spinel 2026.11.04.7026, a 4-core x86-64 Linux VM
(Ubuntu 24.04, gcc 13.3). Nothing here is a wrong result. It is the time a
developer waits after each edit, and most of it is not CyberTrain's to
remove.

### The analysis grows faster than the program

`spinel bin/blog.rb -c --timing` for examples/blog's application, at
commits of one week (four compiles at a time on the four cores, so the
absolute figures are about a third above a compile alone; a compile alone
at 34c9b7e, for a scaffolded application of 2,690 methods, is 44.2 s of
analysis):

| CyberTrain | Framework lines | Methods compiled | `phase=analysis` | `analysis_fixpoint` | per method |
| --- | --: | --: | --: | --: | --: |
| 3ec9cc0 (2026-11-05) | 34,246 | 1,272 | 14.6 s | 8.2 s, 16 rounds | 11 ms |
| 27335c5 (2026-11-06) | 42,667 | 1,701 | 21.5 s | 12.4 s, 14 rounds | 13 ms |
| bfd0d3a (2026-11-07) | 49,302 | 2,034 | 36.1 s | 20.5 s, 14 rounds | 18 ms |
| 414f594 (2026-11-10) | 56,284 | 2,330 | 41.4 s | 23.1 s, 14 rounds | 18 ms |
| 72104d7 (2026-11-11) | 65,185 | 2,840 | 59.7 s | 33.7 s, 16 rounds | 21 ms |
| 34c9b7e (2026-11-12) | 66,880 | 2,902 | 61.4 s | 35.7 s, 16 rounds | 21 ms |

2.3 times the methods, 4.2 times the analysis: an exponent of about 1.7.
The round count did not move, so each round's cost per method did.

Where the 44.2 s of the compile alone go (`--timing`):
`analysis_fixpoint` 24.8 s in 16 rounds, `an_cls_facts` 5.5 s,
`an_storage` 3.2 s, `analysis_renarrow` 2.9 s, `an_desugar_register`
2.2 s, `an_method_backstops` 1.6 s, `an_nullable_returns` 1.4 s,
`an_class_structure` 1.3 s. Inside the fixpoint: `infer_write_types`
4.1 s (33 calls, 28 with a change), `infer_return_types` 3.4 s (22, 13),
`narrow_object_arrays` 3.0 s (22, 4), `infer_param_types_settle` 2.1 s
(22, 13), `infer_block_params` 1.9 s (29, 13), `infer_ivar_types` 1.0 s
(29, 16); the other 151 passes are under 0.6 s each and 8.9 s together.
163 stack samples of three compiles (gdb, one every quarter second) say
the same and name no single function: 90 in `an_phase_infer_fixpoint`
(74 of them with `infer_type` on the stack, 41 with `infer_call`), 18 in
`cf_solve`, 12 in `an_phase_storage`; the commonest leaf, `nt_str`, has
17.

What it costs: the edit loop's rebuild is `spin build NAME --
--incremental`, and of its 53 s the analysis is 44.2 s, the C generation
3.6 s, compiling 2 of 81 units and linking 3.1 s. Every test file of an
application is the same program again, 52 to 56 s. On 2026-11-05 the
same edit was 3.9 s of analysis on a Mac (docs/performance-next.md).

What would fix it, for Spinel to judge:

- **A round that visits what changed.** `narrow_object_arrays` walks the
  program 22 times and changes something 4 times; the 150 small passes
  run in every round, a third of the fixpoint between them. A worklist of the scopes whose inputs changed in
  the last round would make rounds 3 to 16 cheap.
- **Analysis kept between builds.** An edit to one controller's method
  leaves the framework's 2,600 methods as they were. `--incremental`
  reuses the objects of unchanged C; nothing reuses the types that
  produced it.
- **Pruning before the fixpoint.** A program that requires the framework
  and calls a corner of it pays for all of it: `bin/db.rb` (migrations
  only) analyses for 48 s with `require "cybertrain"` and for 8 s with
  the two files it needs, which it cannot require because the
  application's config file may name anything.

What CyberTrain does today: since 2026-11-13 an application can leave
the subsystems it does not use out of its program (`require
"cybertrain/core"` and a line per subsystem, what `cybertrain new` writes):
for a scaffolded application 2,205 methods instead of 2,767 and 38 s of
analysis instead of 52 s, a controller edit about 47 s instead of 65 s
(docs/performance-next.md, "Optional subsystems"). That is pruning by
hand, and the framework keeps growing through phase 5 of the Rails-gap
programme.

### spin: every executable is stale when any Ruby file is newer

`spin build`, `run` and `test` reuse a binary only when no `*.rb` of the
package (and of a path dependency) is newer than it. Touched in a new
application, then `spin build` on each of its three executables:

| Touched | `gen` | `db` | the application |
| --- | --- | --- | --- |
| `app/controllers/articles_controller.rb` | rebuilt | rebuilt | rebuilt |
| `app/models/article.rb`, `config/app.rb`, `config/routes.rb` | rebuilt | rebuilt | rebuilt |
| `db/schema.rb`, a file of `db/migrate/`, `gen/routes.rb`, `bin/db.rb` | rebuilt | rebuilt | rebuilt |
| a view, `README.md`, the SQLite file, `test/.keep` | up to date | up to date | up to date |

`bin/gen.rb` requires the routes and the schema; a controller cannot
reach its binary. So an edit to a controller costs the next `spin run
gen` 38 s (18 s when its C is split, below) and the next `spin run db`
72 s for binaries identical to the ones on disk, and a program that writes a Ruby file (the migrator writes
`db/schema.rb`, the generator writes `gen/`) makes itself stale.

- What would fix it: the compiler knows the files a program was compiled
  from. A list of them beside the binary (a depfile, as `spin flags
  --deps` already gives for the toolchain) would let spin compare those
  and no others.
- What CyberTrain does today: `Dev::Rebuilder` compiles `bin/gen.rb` to C
  and compares it with the C of the binary on disk before it lets spin
  rebuild gen (docs/design.md, section 6); `DB::CLI` no longer rewrites a
  `db/schema.rb` that has not changed; the CLI builds gen and db with
  `SPIN_DEBUG=1`, which makes the needless compile cheaper, not rarer.

### spin: no build flags per executable, and a unit just under 4 MiB is one compile

`bin/gen.rb` compiles to 4.15 MB of C (2.39 MB with `--no-line-map`) when
the framework is checked out at `/home/user/CyberTrain`: 44 KB under the
4 MiB at which spinel splits a unit, so one C compiler process runs over
it at `-O2`. The 23,816 `#line` directives each carry a path, so the
same program with the framework at a path of 88 characters is 5.6 MB,
is split in four, and builds in less than half the time:

| `spinel bin/gen.rb` | Total | Analysis | C compiler |
| --- | --: | --: | --: |
| as `spin run gen` builds it, 4.15 MB of C | 38.1 s | 4.5 s | 32.9 s |
| as `spin run gen` builds it, 5.6 MB of C (four parts) | 17.9 s | 4.4 s | 12.9 s |
| the 4.15 MB with `--jobs=4` | 16.9 s | 4.1 s | 12.2 s |
| the 4.15 MB with `-O 1` | 25.0 s | 4.9 s | 19.5 s |
| the 4.15 MB with `-O 0` | 11.5 s | 4.8 s | 6.1 s |

So the directory a framework is installed in decides whether a tool
takes 38 s or 18 s to build.

gen runs for 6 ms, so its optimisation level buys nothing. `spin run`
passes nothing to spinel, `spin build gen -- -O 0` is never up to date,
and spin.toml has no place for an executable's flags; `SPIN_DEBUG=1` is
the one switch spin remembers (`build/bin/.gen.mode`), and it is an
environment variable every caller must set.

- What would fix it: flags per executable in spin.toml (`[bin.gen]
  opt = 0`), and a split threshold that follows the cores and counts the
  C without its `#line` directives (a unit of 1 MB or more when `--jobs`
  would use more than one).
- What CyberTrain does today: `SPIN_DEBUG=1 spin run gen` and `... run
  db` wherever the CLI and the rebuilder run them
  (`Cybertrain::Shell::TOOL_SPIN`).

### spin: two `spin test` at once in one package

`spin test test/articles.rb` and `spin test test/comments.rb` started
together in a copy of examples/blog: one ends "FAIL articles.rb (build
failed)", the other passes, in 99 s; one after the other they pass in
112 s. `spin test` with both files builds them one after the other
(`user` 4 min 51 s of 1 min 52 s: the C compiler is parallel, the
analysis is not).

- What would fix it: `spin test --jobs N`, building N test programs at a
  time, or build paths that two spin processes do not share.
- What CyberTrain does today: nothing; phase 5a's `cybertrain test` puts
  an application's tests in one program, which is one analysis instead
  of one per file.

## Written up on 2026-11-13

What the inventory at the top added: eight items that had only been a
rule in spikes/NOTES.md, a line of performance-next.md or a comment in
the code, and the small programs behind its "probe passes". All of it is
on the pinned 2026.11.04.7026, Linux x86_64, `spinel prog.rb -o prog`
with gcc 13.3.0, beside CRuby 3.3.6; no other build was tried, so none of
these is known to be fixed or open on matz/spinel master, and none is
reported.

### AA. A method that holds a block allocates its closure cells on entry

performance-next.md, candidate 9, found on 2026-11-05. For every local a
block captures, the generated C of the enclosing method allocates a heap
cell at the top of the function, before any branch, so a call that never
reaches the block pays for it. `Interpreter#eval_expr` held one block, in
its Hash-literal case, that captured `n`, `env` and `hash`: three cells
for each of the 175 expressions an article page evaluates, 525 in all,
though the page has no Hash literal. With `Helpers#nested_url` (33),
`Response#set_header` (8) and five other methods (10), closure cells were
576 of the page's 1,650 objects (35%). On the list page `eval_expr`'s
cells alone were 756, 41% of its objects. The 2026.09.12 build allocates
none for the same source line.

- Seen again on 2026-11-13 in examples/blog's program of main 34c9b7e
  (`spinel bin/blog.rb $(spin flags) -c`): `sp_Interpreter_exec_each`
  opens with `sp_RbVal *_cell_n = (sp_RbVal *)sp_gc_alloc(sizeof(sp_RbVal),
  NULL, sp_cell_scan_rbval);`, then `_cell_env`, all under the `#line` of
  the `def`. Counting the `_cell_` allocations that sit on a function's
  own `def` line, 85 methods of that program allocate 176 cells on entry;
  on the request path `Interpreter#exec_each` 6, `Route#match` 3,
  `Route#path` 2 and `Request#keep_alive?` 2. That is a count in the C,
  not of objects per request.
- Not reduced. Two standalone programs tried on 2026-11-13 allocate
  nothing on entry (`SPINEL_ALLOC_REPORT`): a block on a typed Hash's
  `each` after an early return is inlined with no cell at all, and an
  `each_with_index` block inside an `if` gets its cell inside the `if`.
  What the framework's methods have beyond those was not found.
- Today: on the request path a block that captures locals is a `while`
  loop, or sits in a method that is called only when it is needed
  (`Response#respell_header`).
- Asked of Spinel: allocate a cell where the block is created, or at the
  first branch that can reach it.

### AB. A foreign call holds its OS worker, with or without `blocking: true`

Rule 80, from saeki-mototsune/CyberTrain#134 (2026-11-05). A green thread
inside an `ffi_func` keeps its OS thread until the C function returns, so
at one worker nothing else runs:

```ruby
module Nap
  ffi_source <<~C
    #include <time.h>
    #include <errno.h>
    int probe_nap(int ms) {
      struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
      while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
      return 0;
    }
  C
  ffi_func :probe_nap, [:int], :int, blocking: true
end
def napper = Thread.new { Nap.probe_nap(600) }
t0 = Time.now.to_f
n = napper
ticks = 0
while Time.now.to_f - t0 < 0.5
  sleep 0.05
  ticks += 1
end
n.join
puts "ticks=#{ticks}"
```

With `SPINEL_WORKERS=1` it prints `ticks=1`: the main thread's 0.05 s
sleeps did not come back while the other thread was in C. With
`SPINEL_WORKERS=2` it prints `ticks=10`. Without `blocking: true` both
figures are the same. (libc's `usleep` through `ffi_lib "c"` returned
after 0.01 s instead of 0.6, most likely interrupted by a signal of the
runtime's, which is why the C above sleeps again on `EINTR`.)

- What `blocking: true` does on the pin, from the pinned tree's
  lib/sp_sched.h: the call is bracketed by `sp_native_enter` and
  `sp_native_leave`, so that "a collection raised while the call runs
  does not wait for it". The worker leaves the collector's world; its
  other green threads stay where they are. (On 2026.09.12 the option
  was accepted and ignored, which is what cybertrain/db/sqlite_ffi.rb
  said until 2026-11-13.)
- What it costs: a SQLite call that waits (a lock, a long query, a
  `VACUUM`) stalls every request of a one-worker server for as long. A
  writer waiting in SQLite's busy handler for a transaction whose green
  thread was parked on the same worker could not be released by it: 5 s
  of stall and a "database is locked". `Socket.getaddrinfo` is the same
  for a dead resolver.
- Today: the busy handler only records that SQLite asked to wait, and
  `Connection#step_waiting` retries after a green-thread `sleep`
  (test/db_busy_wait.rb); heavy SQLite work is run in another process.
- Asked of Spinel: around a `blocking: true` call, let another OS thread
  take over the worker's run queue (what Go's runtime does around a
  system call), or say in docs/FFI.md that the option does not do this.

### AC. `URI.decode_www_form_component` is quadratic on non-ASCII text

Rule 49. One raw non-ASCII character makes the decode of everything after
it quadratic:

```ruby
require "uri"
def ms(n)
  s = "é" + ("a" * n)
  t = Time.now.to_f
  URI.decode_www_form_component(s)
  ((Time.now.to_f - t) * 1000).round
end
puts "#{ms(50_000)} #{ms(100_000)} #{ms(200_000)}"
```

CRuby prints `1 1 1`. The compiled program printed `119 556 1949` and
`117 507 1970` (milliseconds; four times the time for twice the text).
400,000 ASCII bytes take 9 ms, and so does text whose only non-ASCII
character is escaped (`"%C3%A9"` and 200,000 bytes: 4 ms), so it is the
raw character that does it, which fits a decoder that indexes a UTF-8
String by character at each step. 2026.09.12 took 517 ms and 8.5 s for
50,000 and 200,000.

- What it would cost: a 1.6 MB form value in a language other than
  English would hold a worker for minutes.
- Today: `Query.decode` copies the text between escapes with `byteslice`
  and hands the library only the ASCII runs of `%XX`.
- Asked of Spinel: decode by byte.

### AD. `String#byteindex` accepts an offset inside a character

Rule 52.

```ruby
begin
  p "a=1&\x81b=2".byteindex("b", 4)
rescue IndexError
  puts "IndexError"
end
```

CRuby prints `IndexError` ("offset 4 does not land on character
boundary"); the compiled program prints `5`. Spinel's `split`, `strip`
and `index` accept an invalid String in the same way where CRuby raises
ArgumentError (rule 52; not run again here).

- Today: request text is validated once with `valid_encoding?`
  (`Query.utf8!`), which agrees on both runtimes, and nothing rescues
  `IndexError`.
- Asked of Spinel: raise as CRuby does. Low in harm: the lenient answer
  is the useful one, and the framework no longer depends on either.

### AE. `Class#superclass` on a package's exception class is NoMethodError

Rule 54, the half that still fails.

```ruby
require "json"
begin
  JSON.parse("{")
rescue JSON::ParserError => e
  puts e.class.superclass.name
end
```

CRuby prints `JSON::JSONError`; the compiled program raises `undefined
method 'superclass' for module JSON::ParserError (NoMethodError)`. For a
class the program defines, the chain is CRuby's
(spikes/rechecks/exception_shapes.rb).

- Today: a client fault is recognised by its full class name in
  `ClientError::CLIENT_FAULTS`, never by walking ancestors.
- Asked of Spinel: answer `superclass` for a package's exception classes
  as for the program's own (the message calls the class a module).

### AF. `Float#round(n)` on a Float narrowed by a `case` rounds the binary product

Rule 100, from issue #189 (2026-11-11).

```ruby
def round_scale(v, scale)
  f = case v
      when Float then v
      when String then v.to_f
      else 0.0
      end
  f.round(scale).to_f
end
x = "1.005".to_f
puts x.round(2)
puts round_scale(x, 2)
puts round_scale("0.285", 2)
```

CRuby prints `1.01`, `1.01` and `0.29`; the compiled program `1.01`,
`1.0` and `0.28`. On the Float local the answer is CRuby's; through the
value the `case` produced, the call goes to the runtime's polymorphic
rounding, which multiplies, rounds and stops, where CRuby corrects a tie
that the binary product fell short of (1.005 * 100 is
100.49999999999999). The same number rounds two ways in one program, and
nothing warns.

- Today: a stored decimal is rounded on the digits of `Float#to_s`
  (`Cast.round_digits`), and `NumberHelper` formats from the same digits.
- Asked of Spinel: one implementation of `Float#round(n)` behind both
  paths, CRuby's.

### AG. `TCPServer.new` on a port in use raises `Errno::ECONNREFUSED`

Known since the server was written, from a comment in
cybertrain/http/server.rb.

```ruby
require "socket"
a = TCPServer.new("127.0.0.1", 0)
port = a.addr[1]
begin
  TCPServer.new("127.0.0.1", port)
  puts "bound twice"
rescue SystemCallError => e
  puts e.class.name
end
```

CRuby prints `Errno::EADDRINUSE`, with the message `Address already in
use - bind(2) for "127.0.0.1" port N`; the compiled program prints
`Errno::ECONNREFUSED`, message `Connection refused`. A port below 1024
bound without root raised the same `Errno::ECONNREFUSED` where CRuby
raises `Errno::EACCES` (a compiled binary run on port 80 as a non-root
user, when the server was written; not run again here, where the session
is root).

- Today: `Server#bind_listener` rescues both spellings and raises
  `PortInUse`; `privileged_denied?` decides between "in use" and "needs
  root" from the port number and the user, since the class cannot.
- Asked of Spinel: raise the `Errno` class of the failing `bind(2)`.

### AH. `JSON.generate` writes a Float in another form than CRuby's

Recorded in spikes/decimal/float_round.rb (2026-11-11).

```ruby
require "json"
puts JSON.generate({ "small" => 1.0e-8, "big" => 1.0e20 })
```

CRuby prints `{"small":1.0e-08,"big":1.0e+20}`; the compiled program
`{"small":0.00000001,"big":1e+20}`. `Float#to_s` agrees on both
(`1.0e-08`, `1.0e+20`). Both outputs are valid JSON for the same
numbers, so nothing in CyberTrain works around it; a test that compares
JSON text of such Floats would differ between the runtimes.

### The programs behind "probe passes (2026-11-13)"

Each printed the same under CRuby 3.3.6 and compiled by the pin. They
are small programs of the shape, written for this inventory; where the
rule was seen only in a larger program, a pass does not show the cause
is gone, and no workaround was removed.

| Rule or comment | The program, in short | Both print |
| --- | --- | --- |
| Rule 3 | `class Base; def run = hook.to_s; end`, `hook` defined only on `Sub < Base`, `Sub.new.run` | `sub` |
| Rule 19 | One `@io.puts(line)` site, given a StringIO by one `Lg.new` and `STDOUT` by another | both lines |
| Rule 20 | At `SPINEL_WORKERS=1`: one thread in a bare `readpartial` on a socket whose peer closes after 1 s, the main thread counting 0.05 s sleeps for 0.8 s | the reader waited 0.9 s or more, and main counted 10 or more |
| Rule 21 | `Thread.new(TCPSocket.new(host, port)) { \|c\| c.wait_readable(2); c.readpartial(10) }` | `hi` |
| Rule 30 | `head(status = 200)` called directly with 201, and with `:forbidden` only from a stored block | `201`, `403` |
| Rule 33 | `JSON.parse("{")` under `rescue StandardError => e` | `rescued JSON::ParserError` |
| Rule 44 | `each_item { \|i\| return "found #{i}" }` in a method, and a `return` from the block of a yielding method that has a `rescue` | `found 1`, `returned early` |
| Rule 45 | A yielding method with `rescue => e`, called from a block nested in another block, once returning and once raising | `["ok", "rolled back: boom"]` |
| Rule 50 | A re-entrant yielding method with `rescue` and `ensure @flag = true unless completed`, nested, the inner block raising | `false` |
| Rule 55 | `p0["id"] << "2"` through a reader over a Hash ivar, `h["k"] << "b"`, `a[0] << "y"` | `12`, `ab`, `xy` |
| Rule 60 | `"#{body}"` and `"x#{body}y"` with `body = "ab\x00cd".b`, their `bytesize` | `5`, `7` |
| Rule 67 | A yielding method called on an element of `[Conn.new, 1]` | `7` |
| Rule 68 | `with { \|c\| c + i }` (a `&block` method calling `block.call`) inside `3.times do \|i\|` inside another block | `[10, 11, 12]` |
| Rule 69 | A block taken as `&block` and passed as a Proc through two more methods before `blk.call(Conn.new)`, calling a method on its parameter | `3` |
| Rule 72 | `File.open` of a missing path under `rescue SystemCallError => e`: its class name and message; `Errno::ENOENT::Errno` | `Errno::ENOENT`, CRuby's message, `2` |
| Rule 99 | `dup` of an object with an Array ivar, then an append through the copy; a class with `initialize_copy` | `2 2 0 5`, `1 2` |
| `Dir.mkdir` mode | `Dir.mkdir(path, 0o700)` under a 022 umask, then `File.stat(path).mode & 0o777` | `700` |
| `loop do` | A `raise Rejected.new(413, "too large")` and a `return "ok"` inside `begin` / `rescue` inside `loop do`; the rescue returns `e.status` and `e.message` | `rejected 413 too large`, `ok` |
| Interpolation and `to_s` | `"#{a}"` for an object with `def to_s = "custom"`, typed and boxed | `custom` twice |
| Nested `instance_eval` | `m.instance_eval do res(:x) { res :y } end` | `res x`, `res y` |
| A method named `new` | `class C; def new = "new action #{@x}"; end`, `C.new(1).new` | `new action 1` |
| Regexp in a collection | `[/a/, /z/].each { \|r\| n += 1 if "abc" =~ r }` | `1` |
| `STDOUT.flush` as a value | A method ending in `STDOUT.flush`, its value tested with `nil?` | `false` |
| `key?` beside a user class's | `h.key?(k)` on an element of `[{ "x" => 1 }, Errs.new, 3]`, `Errs` defining `key?` | `true`, `true` |
| A splat into `File.join` | `def here(*parts) = File.join("/base", *parts)` | `/base/a/b` |
| An append through a parameter | `emit(src)` appending two lines to its parameter, then `src << "tail\n"` in the caller | all four lines |
| Unpadded Base64 | `Base64.urlsafe_decode64("YQ")`, `("YWI")` | `"a"`, `"ab"` |
| An Integer multiplied in a loop | `usec *= 10` six times in a `while` | `1000000` |

Two more were run and say nothing: a deep recursion meant to overflow the
stack (rule 46) returned normally when compiled, the C compiler having
turned it into a loop; and rule 2's `instance_exec(&stored)` is refused
as before ("unsupported call: ... (CallNode `instance_exec`)"), which is
by design.

## Found in phase 4b of the Rails-gap programme (2026-11-11)

The i18n and authentication part of the web-layer design
(docs/superpowers/specs/2026-11-10-phase4-web-layer-design.md, section 12,
item 6) ran four checks against 2026.11.04.7026 before any code was
written (spikes/phase4b/; the YAML reader's programs deleted since, the
generator's own reader and test/locale_yaml.rb having replaced them); all
four passed, and this was found while
measuring the second.

### AI. A large Hash literal constant takes cc 13 s

A module with a frozen Hash literal constant of 1,980 String pairs
(`TEXTS = { "en.section_00.key_00" => "Value 0 plain", ... }.freeze`)
takes 12.5 to 15.2 s to build on a 4-vCPU cloud machine. `spinel
--timing` puts 13.2 s in cc_total and under 0.1 s in the analysis and C
generation: the literal is written into the program's main body as 1,980
inlined `sp_StrStrHash_set` calls, a single function that cc at -O2 is
slow to optimise. A `case` over the same keys builds in 4.5 to 4.7 s, and
the same Hash filled by 40 methods of 50 `h["k"] = "v"` stores in 4.7 to
5.4 s. Lookups in the two Hash forms are equally fast (34 to 53 ns).

- What CyberTrain does with it (phase 4b): gen/locales.rb and
  cybertrain/locales/bundled.rb fill their Hash through `fill_NN(h)`
  methods of at most 50 keys (spikes/NOTES.md rule 101).
- A possible upstream change: emit a large constant literal's stores into
  helper functions of bounded size, or from a static table in a loop.
- Reproduced by spikes/phase4b/locale_hash.rb (written by make_keys.rb);
  not reported upstream.

### What the rest of phase 4b met (no new item)

The eighteen tasks after the spike (2026-11-11 to 2026-11-12: the YAML
reader, `I18n`, translated helpers and validation messages, tokens, mail,
the authentication generator's additions and examples/blog in two
languages) found no new defect on 2026.11.04.7026. Every new program
compiled as written once the known rules were followed, and those rules
shaped the code in four places:

- One return type per method name (spikes/NOTES.md rule 34): WebSocket's
  private `Frame#reset`, which answered a Boolean, became `clear_message`
  beside the generated `PasswordsMailer.reset`, which answers a
  `MailMessage`; the confirmation mailer's method is
  `confirmation_instructions` because `User#confirm` answers a Boolean;
  `MailMessage`'s readers are `mail_to`, `mail_subject` and the like.
- A concern's `class_methods` are defined by gen after the controllers
  that call them (rules 92 and 93), so `allow_unauthenticated_access`,
  which a controller's class body calls, became a framework method of
  `Cybertrain::Controller` rather than the concern's.
- No stored block through a base-class receiver (rule 88): the generated
  `rate_limit` lines name their `with:` and `by:` methods.
- Byte scanners read through a fresh local (rule 62): the YAML reader,
  the plural rules, `Accept-Language`, the locale-name check, token
  parsing and `ParameterFilter.filter_path`.

One finding was CRuby's, not Spinel's: under a C locale `File.read`
answers US-ASCII text, which the authentication generator's diff
compares with generated UTF-8 through `LineDiff.as_utf8`.

## Found in phase 5a of the Rails-gap programme (2026-11-12)

The tests part of the phase 5 design
(docs/superpowers/specs/2026-11-11-phase5-tests-operations-design.md,
section 16) ran six checks against 2026.11.04.7026 before the code
(spikes/phase5/), and the eighteen tasks after them met the rest. Six
items are new: AJ to AM from the spike and the tasks (spikes/NOTES.md
rules 104, 107 and 108, and the measurement behind AK), and AN and AO,
found on 2026-11-13 (rules 109 and 110).

### AJ. `Class#superclass` on Ruby's own exception classes is NoMethodError

Rule 104; AE's failure, on the core classes as well. It takes a package
in the program:

```ruby
require "json"
begin
  raise "boom"
rescue RuntimeError => e
  puts e.class.superclass.name
end
```

CRuby prints `StandardError`; the compiled program raises `undefined
method 'superclass' for module RuntimeError (NoMethodError)`. Without the
first line the compiled program prints `StandardError` too: this section
printed the program without it until 2026-11-15, and in that form it does
not show the failure on the pin. `require "uri"` and `require "stringio"`
in place of `json` fail as it does, `require "socket"` does not, and a
line `module Pkg; end` in place of the require fails as well (re-run
2026-11-19; spikes/rechecks/differing/builtin_superclass_with_module.rb,
and spikes/rechecks/builtin_superclass_no_module.rb for the form that
passes). That is as far as it was narrowed: what a package or a module
changes was not read from the generated C.

In such a program the class of a rescued built-in exception
(`RuntimeError`, `ArgumentError`, `KeyError`, `Errno::ENOENT`,
`JSON::ParserError`), whether the program, the runtime or a package
raised it, answers its qualified `Class#name` but no `superclass`. A
class the program defines answers the whole chain, built-in ancestors
included (`Mine < ArgumentError < StandardError < Exception < Object <
BasicObject`, with json required): `ArgumentError` reached as
`Mine.superclass` does answer; what fails is `superclass` asked of
`e.class` when that class is a built-in one. So AJ and AE are one defect,
and one report.

- Today: `assert_raises(Class)` walks a raised exception's ancestry by
  name and, at the first built-in class, reads the rest from a table of
  parents checked against CRuby 3.3 (`Test::BUILTIN_PARENTS`, every
  `Errno::` class by its prefix); a built-in class outside the table fails
  the assertion by name.
- Asked of Spinel: answer `superclass` for the built-in exception classes
  as for the program's own.
- spikes/phase5/assert_raises.rb records the workaround (the parents
  table) and prints what CRuby prints; the program above is the
  reproduction. Not reported upstream.

### AK. The C of a very large program needs more memory to compile than its front end

Spike item 6 bundled 196 of the framework's test programs (61,000 lines of
Ruby) into one. Spinel's front end, every rule included, passed in about
6.5 minutes at about 1.65 GB resident and wrote 87.6 MB of C (1.17 million
lines). Compiling that C at the default -O2, split into units compiled in
parallel, ran for about 21 minutes and was killed by the memory cgroup's
OOM killer at a peak of 9.7 GB for the build's processes together (one
cc1 at 4.6 GB), on a 16 GB machine shared with other builds (2026-11-12).
An application's test program is far smaller (the blog's: about 527 s,
a 10.2 MB binary).

- Today: the framework's suite stays one program per file (design D34,
  D83); only applications bundle their tests (`cybertrain test`).
- A possible upstream change: smaller C units for a large program, or a
  lower optimisation level for the largest functions.
- Measured with spikes/phase5/bundle_suite.sh; not reported upstream.

### AL. `spin run gen` rebuilds the generator when a test file changes

Rule 108. spin's freshness check for an application's `build/bin/gen`
counts every `.rb` file under the package, `test/**` and gen's own
outputs (`gen/tests.rb`) included: identical inputs print "build gen (up
to date)", and one rewritten `gen/tests.rb` costs a full rebuild of about
55 s on the next run.

- Today: accepted; `cybertrain test` pays it on every edit of a test,
  before it compiles the test program.
- A possible upstream change (to spin): a package's build inputs
  declared, or followed through `require`, rather than every `.rb` in the
  tree.

### AM. A release build has no backtrace

Rule 107. A release build's `e.backtrace` is an empty Array, `-g`'s one
`<main>:1` frame; only `--debug` answers `file:line:in 'Mod.meth'` per Ruby
method (with `<main>` always at line 1 and no frame for a builtin's raise),
compiling faster (-O0) and serving about 45% of a release build's request
rate.

- Today: a failing test is named by the line of its `test` call, not of
  the assertion; error reports carry the class, the message and where.
- Asked of Spinel: frames (even without line numbers) in a release
  build, at a cost a server can carry.
- Reproduced by spikes/phase5/backtrace.rb; not reported upstream.

### What the rest of phase 5a met (no new item)

- A call of an undefined instance method is refused at build only while
  no class defines the name; with `ZonedTime#month` in the program,
  `1.month` builds and raises `NoMethodError` when reached, as under CRuby
  (rule 105). Not a defect: rule 84's refusal by design has no
  instance-method counterpart to rely on.
- A Ruby-source `def self.now` on `Time` overrides the builtin at every
  call site, framework files included (spike item 1), and methods named
  like builtin Time methods on another class leave a boxed Time working
  (rule 106).
- `rescue Exception => e` in a yielding method catches ScriptError and
  NotImplementedError as CRuby does; rule 47's `is_a?` half did not
  reproduce for its own example (its status row).
- One return type per name (rule 34) shaped `assert_raises` (it answers
  the message String) and the block assertions (nil); no stored block
  through a base class (rule 88) is why gen rewrites test classes into
  methods.

### AN. A parameter defaulting to nil that a caller gives a plain Time crashes the defaulted call

Rule 109 (2026-11-13).

```ruby
def stamp(expires: nil)
  return "none" if expires.nil?

  expires.year.to_s
end
STDOUT.sync = true
puts stamp
puts stamp(expires: Time.at(0))
```

CRuby prints `none` and `1970` (under `TZ=UTC`; `Time.at(0)` is local time);
the compiled program prints nothing and
dies with SIGSEGV (exit 139). The parameter is typed from its callers' values
as a plain `sp_Time *`, `expires.nil?` compiles to the constant false, and
the defaulted call passes NULL to `sp_time_year`. A positional default
crashes the same way; callers giving a String, or a value typed Time-or-nil,
work.

- Today: `Cookies.serialize`'s `expires:` defaults to the sentinel
  `Cookies::NO_EXPIRES` (`Time.at(-1).utc`), tested for along with nil;
  the framework's callers pass `Cast.time_or_nil(...)`.
- Asked of Spinel: type a nil-defaulted parameter as nullable when a
  caller leaves it out.
- Reproduced by spikes/phase5/nil_default_time.rb (and the workaround,
  nil_default_time_fixed.rb); not reported upstream.

### AO. A statement `case` on a plain Integer takes an earlier nullable case's temporary and does not compile

Rule 110 (2026-11-13).

```ruby
def esc(s)
  out = +""
  b = s.getbyte(0)
  case b
  when 38 then out << "amp"
  else out << "other"
  end
  out
end

def kind_of(s)
  return 1 if s.bytesize > 3

  0
end

def parse(s)
  out = +""
  k = kind_of(s)
  case k
  when 1 then out << "long"
  else out << "short"
  end
  out
end

puts esc("&x")
puts parse("abcd")
```

CRuby prints `amp` and `long`; Spinel's C does not compile: `'_o1'
undeclared`. `case b` (a nullable Integer) declares `sp_oint _o1` and
`sp_int _t1` and switches on `_o1.nil ? 0LL : _t1`; `case k` (a plain
Integer) declares only `sp_int _t1` but switches on the same expression.
The "nullable subject" mark is kept by temporary number across methods.
With the methods in the other order, or both cases as return values, it
compiles. In the framework it showed as two test programs failing to
build while a third, loading the same file, built.

- Today: `HtmlReader.parse` uses an `if` chain; shared framework code
  avoids a statement `case` on a plain Integer. `Html.escape`'s `case b`
  still leaks its mark.
- Asked of Spinel: keep the nullable-subject mark per case (or per
  method), not per temporary number.
- Reproduced by spikes/phase5/case_nullable_temp.rb; not reported
  upstream.
- Phase 5b (2026-11-13) extended the framework's rule: no statement
  `case` on any Integer in new code, a `getbyte` value included (rule 110's
  amendment).

## Found in phase 5b of the Rails-gap programme (2026-11-13)

The operations part of the phase 5 design (logs, request ids and error
reporting; section 16's items 7 to 9 ran before the code, in
spikes/phase5/, item 8's program, error_names.rb, deleted since) met two
Spinel bugs, AP and AQ, both reduced on 2026-11-14
with the pinned 2026.11.04.7026 (a2d06115, gcc 13.3.0, Linux x86_64,
`spinel prog.rb -o prog`, no flags) and run beside CRuby 3.3.6.
spikes/NOTES.md has them as rules 117 and 116, and the rest of what the
phase met as rules 113 to 115 and 118 to 120.

### AP. `pop(timeout:)` on a Queue that was put in an Array is `Array#pop`

Rule 117.

```ruby
inboxes = [Queue.new, Queue.new]
inboxes[1] << "hello"
got = inboxes[1].pop(timeout: 5)
puts got.inspect
```

CRuby prints `"hello"`; the compiled program raises `no implicit
conversion of Hash into Integer (TypeError)` and exits 1: the call is
compiled as `Array#pop(n)`, the keyword Hash taken as the count. Binding
the element to a local first (`q = inboxes[0]; q.pop(timeout: 5)`), or
passing it to a method that pops its parameter, raises the same. A Queue
that is never put in an Array pops as under CRuby, from a local and from a
method's parameter.

- Today: a test that hands Queues to threads keeps each in its own local
  or constant and passes it as a parameter (test/logger_scope.rb's
  concurrent `tagged` test); the framework keeps no Queue in an Array.
- Asked of Spinel: type an Array literal of Queues as an Array of Queue,
  so its elements' `pop` is `Queue#pop`.
- Reproduced by spikes/phase5/queue_in_array.rb (its header has the
  variants); not reported upstream.

### AQ. Four threads writing one StringIO with no lock crash the program

Rule 116.

```ruby
require "stringio"
ENV["SPINEL_WORKERS"] = "4"
SINK = StringIO.new

def spawn_writer(io, n)
  Thread.new do
    i = 0
    while i < 2000
      io.write("t#{n} #{"x" * 300}\n")
      i += 1
    end
  end
end

threads = [spawn_writer(SINK, 0), spawn_writer(SINK, 1), spawn_writer(SINK, 2), spawn_writer(SINK, 3)]
threads.each { |t| t.join }
puts SINK.string.bytesize
```

CRuby prints `2432000`. Compiled, five runs: four aborted with `double
free or corruption (!prev)` (exit 134) and one died with SIGSEGV (exit
139), printing nothing; earlier runs of the same binary showed `double
free or corruption (out)` and `malloc(): corrupted top size`. With `"1"`
in place of `"4"` in the program's second line it printed `2432000` in
three runs out of three (the line overrides the environment, so
`SPINEL_WORKERS=1` on the command line changes nothing: three such runs
aborted on 2026-11-19). The C was not read for the cause. Under CRuby the GVL
serializes the calls, so
an application ported from Ruby may rely on it without knowing.

- Today: every Logger writes under one process-wide lock
  (`Logger::LOCK`), which covers a test's StringIO logger as well as
  STDOUT; the race test, test/logger_threads.rb, runs four workers, since
  at one it could not fail.
- Asked of Spinel: either a StringIO (and a String) whose appends are
  safe across workers, as they are under CRuby's lock, or a statement in
  docs/thread.md that an object written by several threads needs a
  `Mutex`, so the crash is the documented consequence of a data race.
- Reproduced by spikes/phase5/stringio_threads.rb; not reported upstream.

### What the rest of phase 5b met (no new item)

- A rescuing yielder with one `rescue` clause around `value = yield`
  works nested, through a forwarding block, and with `next`, `break` and
  `return` in its block as under CRuby (rule 113; `Cybertrain.error.handle`
  is written so).
- `sleep 0` does not switch green threads at one worker (rule 114), and a
  thread test whose handshake relies on the other thread not running yet
  passes under CRuby and fails compiled (rule 118): how tests are written,
  not defects.
- A `Mutex` held only for one write of a prebuilt line cost nothing
  measurable at two workers (rule 115), unlike item 7's lock on the
  request path; the measurement's limits are in the rule.
- A write to a frozen Array or Hash raises `FrozenError` compiled
  (rule 119).
- `spin test` reuses a test binary newer than its sources, so sources
  changed while it compiled leave a stale binary (rule 120; a cousin of
  AL).
- `refute_equal` in an application's test stops the build of the test
  program: no file of the test framework defines it (it offers
  `assert_not_equal`), so the call is refused at build as rule 105
  describes. A missing method of CyberTrain's, not a Spinel item.

## Found in the phase 5b follow-ups (2026-11-14)

The follow-ups (docs/superpowers/plans/2026-11-14-phase5b-followups-plan.md)
met one Spinel item, AR, seen in a build and reduced on 2026-11-15;
spikes/NOTES.md has it as rule 122, and a form that works as rule 121.

### AR. A require-shaped line inside a regex literal is read as a require

Rule 122. A test program that scanned source files for their requires
held this line:

```ruby
if (m = raw.match(/\A\s*require "cybertrain\/([\w\/]+)"/))
```

CRuby runs it. The Spinel build stopped with `spinel: cannot load such
file -- cybertrain\/([\w\/]+)`: the resolution of `require` took the text
inside the regex literal for a require of a literal path (test/gen_jobs.rb
before 0dac336). Reduced on 2026-11-15 on the pin:

```ruby
r = /require "abc"/
puts r.source
```

CRuby prints `require "abc"`. `spinel --strict-require` (the flag spin
builds with) refuses it with `cannot load such file -- abc (require
"abc")`. Without the flag the build warns `'abc' is not available in
Spinel; the require is ignored and code using it will fail`, and the
program prints `nil`: the literal is gone, so a match against it fails
where CRuby's succeeds (spikes/rechecks/differing/require_in_regex.rb is
the framework's line in that form, and prints `no match`). That is a
wrong result behind a warning, not only a refused build. A String literal
holding the same kind of text (`'x require "abd" y'`) is left alone.

- Today: a program that looks for requires in text builds the keyword from
  pieces (`"req" + "uire \"cybertrain/"`) and matches with `start_with?`
  (test/gen_jobs.rb's `core_closure`).
- Asked of Spinel: resolve only `require` calls, not text that looks like
  one inside a literal.
- Not reported upstream; ready to report with the two-line program.

## Found in the clean-up of 2026-11-15

### AS. `ENV[name]` with a key held in a variable can answer the key

Rule 123. Seen in a program that requires part of the framework, and not
reduced:

```ruby
require "cybertrain/http/request"
require "cybertrain/config"

ENV["CYBERTRAIN_RECHECK_HOST"] = "0.0.0.0"
puts "set: " + Cybertrain::Config.env_or("CYBERTRAIN_RECHECK_HOST", "default")
puts "unset: " + Cybertrain::Config.env_or("CYBERTRAIN_RECHECK_UNSET", "default")
```

`Config.env_or(name, default)` is `configured = ENV[name] || ""`, then
`configured.empty? ? default : configured`. Compiled by the pinned
2026.11.04.7026 from the repository root (`spinel -I . prog.rb -O 0 -o
prog`, no warning) the program prints `set: CYBERTRAIN_RECHECK_HOST`, the
variable's name, and `unset: default`. The value was expected, `set:
0.0.0.0`; CRuby cannot load those two files without the preview's FFI
shim, so the comparison is with the method's source and with the same
program compiled with `require "cybertrain/core"` in front, which prints
`0.0.0.0`. The program is
spikes/rechecks/differing/env_nonliteral_key.rb (run 2026-11-15 with
cybertrain/http/query in place of http/request and the variable set in
the shell, to the same effect; again 2026-11-19).

- The generated C of the failing program shows why. The read is compiled
  as `_sp_ret_strbuf = NULL; _v2 = sp_env_str(getenv(...
  sp_strbuf_read_pub(lv_name) ...)); !_v2 ? NULL : _sp_ret_strbuf ?
  (sp_String *)_sp_ret_strbuf : SP_STR_HDL(_v2)`: reading the key
  publishes the key's handle in `_sp_ret_strbuf`, and the result is then
  taken from there. It is V's cause (an argument read through
  `sp_strbuf_read_pub` inside a call whose result the caller takes from
  `_sp_ret_strbuf`) on another builtin.
- What it takes is more of a program than the call, and what decides it
  is not known. The same method in the programs tried that require
  `cybertrain/core` or `cybertrain` was compiled as a `const char *` read
  and answered the value; that is two programs, not a guarantee for every
  application. cybertrain/config.rb alone answered the value, and so did
  six standalone programs with the same method (spikes/NOTES.md rule
  123). `ENV["LITERAL"]` was not seen to be affected.
- Today: nothing guards against it. The reads with a key that is not a
  literal are `Config.env_or`, `Config.int_from_env` and
  `Config.bool_from_env` (cybertrain/config.rb) and
  `Dev::Supervision.supervision_variable` (cybertrain/dev/supervision.rb);
  only `env_or` was run. A test program that requires part of the
  framework can meet it. New code does not add an `ENV[variable]` read.
- Asked of Spinel: clear `_sp_ret_strbuf` after the arguments are read,
  or take a builtin's String result from its return value when the
  builtin never publishes one.
- Not reported upstream; to be reduced first, with V.

## Written up on 2026-11-21

Two differences from CRuby that spikes/NOTES.md recorded as part of a rule
and that had no item here. Both were run again that day with
2026.11.15.7033 and 2026.11.04.7026 on Linux x86_64 (gcc 13.3.0, `-O 0`)
beside CRuby 3.3.6.

### AT. `File#stat` on an open File stats its path, not the descriptor

Rule 112, found in phase 5b (2026-11-13). The program is
spikes/phase5/flock_fstat.rb: it opens a file, deletes the path, creates
the path again and asks the first File for its `stat`.

CRuby answers from the descriptor, fstat(2): the deleted file, which the
program prints as `a.stat names the old file`. Compiled, the program
prints `a.stat names the new file`: `File#stat` is a stat(2) of the path
the File was opened with. Rule 112 records two things beside it that the
program's other lines do not separate from CRuby: with the path gone,
`File#stat` raises ENOENT; and `IO.for_fd(fd, autoclose: false)` makes a
dup of the descriptor, whose `stat` is the descriptor's fstat(2) but which
stays open after the original closes and keeps a `flock` alive until it
is closed itself. `File.for_fd` does not exist. `File#flock` itself
answers as under CRuby.

- On 2026.11.04.7026 and on 2026.11.15.7033 the program's lines differ
  from CRuby's in that one line only ("Status by rule", row 112 of both
  tables; the same in the runs of 2026-11-21).
- Today: `CLI::BuildLock#descriptor_id` (cybertrain/cli/build_lock.rb)
  takes the fstat of an open File through `IO.for_fd(f.fileno, autoclose:
  false)`, its `stat`, then its `close` under Spinel, and through plain
  `f.stat` under CRuby, where closing the `for_fd` IO would close the
  File's own descriptor.
- Asked of Spinel: `File#stat` on an open File as fstat(2) of its
  descriptor.
- Not reported upstream. The `IO.for_fd` difference has no program of its
  own.

### AU. `String#strip` on a String with an invalid byte returns it

The other half of rule 52. AD is its `byteindex` half and mentions this
one in passing.

```ruby
begin
  p " x\x81 ".strip
rescue StandardError => e
  puts "#{e.class.name}: #{e.message}"
end
```

CRuby prints `Encoding::CompatibilityError: invalid byte sequence in
UTF-8`. Compiled by 2026.11.15.7033 and by 2026.11.04.7026 the program
prints `"x\x81"`. spikes/rechecks/differing/invalid_utf8.rb holds the same
call beside AD's two: on 2026.11.15.7033 its `byteindex` lines raise as
under CRuby and its `strip` line still differs ("Status by rule", row 52).
`split` on such a String raises ArgumentError on both builds, as under
CRuby, and `index` with a String needle raises on neither runtime
(spikes/rechecks/invalid_utf8_shapes.rb, which matches CRuby).

- Today: nothing depends on it. Request text is validated once with
  `valid_encoding?` (`Query.utf8!`, rule 52) before anything strips it.
- Asked of Spinel: raise as CRuby does. Low in harm, as AD is.
- Not reported upstream.
