# The development flow of an application: where the time goes, and what is fixed first

Date: 2026-11-12. Status: written from measurements, not from a
conversation: the maintainer asked for the bottlenecks of developing an
application on CyberTrain to be found and fixed in order of effect, without
stopping for questions. Every decision below is therefore the author's, with
its reason, and section 6 lists what was left for the maintainer.

## 1. What was measured

A new application (`cybertrain new app1 --path <checkout>`, then `generate
scaffold article title:string body:text`) and `examples/blog`, on the
checkout at 34c9b7e with Spinel 2026.11.04.7026, on a 4-core x86-64 Linux VM
(Ubuntu 24.04, gcc 13.3). The VM is roughly a third as fast per core as the
Mac the figures of 2026-11-05 (docs/performance-next.md) came from, so
compare the columns of this table with each other, not with those.

| Step of the flow | Time | Where it goes |
| --- | --- | --- |
| `cybertrain new` | 38 s | compiling `bin/gen.rb`: 4.5 s analysis, 33 s for the C compiler on one unit at `-O2` (18 s in all when the unit is split, see C3) |
| `generate scaffold` | 0.07 s | |
| `cybertrain db migrate`, first | 157 s | gen compiled (38 s), `bin/db.rb` compiled (72 s), gen compiled again (38 s) |
| `cybertrain db migrate`, nothing pending | 147 s | the same three compiles |
| `cybertrain server`, first start | 130 s | gen compiled again (38 s), the application compiled (90 s) |
| a controller edit, the first after a start | 136 s | the incremental build starts from an empty object cache |
| a controller edit, later ones | 53 to 67 s | Spinel's analysis 44 s, C generation 3.6 s, compiling 2 of 81 units and linking 3 s, the gen check 4.6 s |
| a view edit | 0.01 s | views are interpreted |
| `spin test`, per test file | 52 to 56 s | each file is a whole program: the same 44 s analysis; files are built one after another |

## 2. The causes

**C1. Every build pays Spinel's whole-program analysis, and it grows faster
than the framework.** The analysis of `examples/blog`'s application, at
commits of the last week (four compiles at a time, so the absolute figures
are inflated by about a third; the ratio is what matters):

| Commit | Methods compiled | Analysis | per method |
| --- | --- | --- | --- |
| 3ec9cc0 (2026-11-05) | 1,272 | 14.6 s | 11 ms |
| 27335c5 (2026-11-06) | 1,701 | 21.5 s | 13 ms |
| bfd0d3a (2026-11-07) | 2,034 | 36.1 s | 18 ms |
| 414f594 (2026-11-10) | 2,330 | 41.4 s | 18 ms |
| 72104d7 (2026-11-11) | 2,840 | 59.7 s | 21 ms |
| 34c9b7e (2026-11-12) | 2,902 | 61.4 s | 21 ms |

2.3 times the methods cost 4.2 times the analysis (an exponent of about
1.7). No single commit did it, and the compiler's profile (45 stack samples
of one compile) is flat: 26 in the inference fixpoint (16 rounds over the
whole program), 9 in the class-facts solver, the rest spread. Nothing in an
application's own code matters next to this: an application is the
framework plus a few dozen methods. This is the cost of one edit and of one
test file, and it is in the compiler, not in this repository.

**C2. `db migrate` rewrites `db/schema.rb` even when the dump is the one
already there.** spin treats an executable as stale when any Ruby file of
the package is newer than it. The rewrite therefore makes gen, db and the
application stale on every `db migrate` and `db rollback`, whatever they
did: the command that just compiled `bin/db.rb` invalidates it, and the gen
run that follows compiles gen for nothing.

**C3. The tools are compiled like the server.** gen runs for 6 ms and db for
about as long, yet both are built at `-O2`. gen's C, with its `#line`
directives, is 4.15 MB for a framework checked out at `/home/user/CyberTrain`:
44 KB under the 4 MiB at which spinel splits a unit, so one C compiler
process takes 33 s over it and gen builds in 38 s. The 23,816 `#line`
directives each hold a path, so a framework two characters deeper is over
the line: at the path of the baseline run in section 5 the C is 5.6 MB,
spinel compiles it in four parts and gen builds in 18 s on the four cores.
Which of the two a developer gets depends on where spin keeps the
framework. With `SPIN_DEBUG=1` (spin's debug mode: `-O0 -g`, kept apart from
release builds by `build/bin/.<name>.mode`) gen builds in 8.5 s either way
and db in 57 s instead of 72 s, and gen's output is byte-identical.

**C4. The server's first build does not use the object cache the rebuilds
use.** `cybertrain server` builds with `spin run NAME`: 90 s, every unit at
`-O2`. The first edit then runs `spin build NAME -- --incremental` against
an object cache (`~/.cache/spinel`, content-addressed, shared by every
application on the machine) that this build did not fill. Measured:
`spin build NAME -- --incremental` takes 81 s with the cache empty and 48 s
with it full, and spin reads the result as up to date.

**C5. `spin test` builds test files one after another, and two `spin test`
processes in one package break each other** (run side by side on two files:
one "build failed", no time saved). Left to phase 5a's `cybertrain test`,
which puts an application's tests in one program (section 6).

## 3. What is decided

In order of what it saves in a day of work, of the causes this repository
can remove:

**D-a (C2). `DB::CLI.write_schema` leaves `db/schema.rb` alone when the dump
is what the file already holds.** It still returns true (the file holds the
dump), so `db schema:dump` and `db schema` report as before. A `db migrate`
with nothing pending then touches no Ruby file: the gen run after it finds
gen up to date, and the next `db` command finds db up to date.

**D-b (C3). The CLI and the development rebuilder build gen and db in
spin's debug mode.** Every `spin run gen` and `spin run db` they run becomes
`SPIN_DEBUG=1 spin run ...`: `cybertrain new`, `db`, `migration`, `server`,
`build` (its two gen steps; the application itself stays a release build),
`Dev::Rebuilder#command`, and the "gen/ is current" step of the CI workflow
`cybertrain new` writes. One constant holds the prefix,
`Cybertrain::Shell::TOOL_SPIN`, in the leaf file the CLI and the framework
both load.
- Why not `--jobs` or `-O 1`: `spin run` passes nothing to spinel, and
  `spin build gen -- FLAGS` is never up to date to spin, so it would compile
  on every command. `SPIN_DEBUG` is the one switch spin tracks.
- A hand-typed `spin run gen` still works; it builds a release gen (38 s, as
  today) and the next CLI command builds the debug one again (8.5 s). The
  hints that tell a person to type `spin run gen` are not changed in this
  round (section 6); the one command line the CLI prints for recovery after
  a failed `cybertrain new` carries the prefix.
- docs/performance-next.md rejected `-O0` for the edit of 2026-11-05 because
  the C compiler was then 0.75 s of 8 s. That stands for the application's
  incremental build; for gen the C compiler is now 33 s of 38 s.

**D-c (C4). `cybertrain server` builds the application with `--incremental`
when its binary is stale.** After the gen step, the CLI looks for a Ruby
file under the application (not under `build/`, `dist/`, `tmp/`, `storage/`,
`public/`, `node_modules/` or a top-level dot directory, and not through a
symlinked directory) as new as `build/bin/NAME` or newer, or a missing
binary; if it
finds one it runs `spin build NAME -- --incremental` before `spin run NAME`.
- The check may be wrong in both directions without harm. Stale by mistake:
  one incremental build (48 s) that `spin run` would have skipped. Fresh by
  mistake (a path dependency changed, a new toolchain): `spin run NAME`
  builds as it does today. spin keeps the last word.
- A failed incremental build stops the command with spinel's output, as a
  failed `spin run` does today. The CLI runs the pinned Spinel, which has
  `--incremental`; there is no fallback for an older one here (the rebuilder
  keeps its own).
- The binary is then the same kind the rebuild loop produces from the first
  edit on: units compiled apart, no inlining across them. `cybertrain build`
  is not touched.

Expected, when this was written: `db migrate` with nothing pending 147 s to
under 1 s; with a new migration 157 s to about 75 s; `new` 38 s to 9 s; a
server start after an edit 128 s to about 57 s; the first edit after a start
136 s to about 60 s; an edit that changes routes or the schema (gen's C
changes) 91 s to about 62 s. Section 5 has what was measured, which is less
in three places.

## 4. What is not changed

- The application's own build mode, `cybertrain build`, what gen emits, the
  generated files of an existing application (`bin/db.rb`, `bin/gen.rb`).
- `spin run gen` typed by hand, and `cybertrain spin ...`.
- The rebuilder's gen check (the C comparison of section 6 of
  docs/design.md): with a debug gen it saves 4 s instead of 33 s per edit,
  and it is left as it is.

## 5. How it is checked

- `test/db_cli.rb`: a second `migrate` with nothing pending leaves
  `db/schema.rb`'s modification time alone; a dump that differs is written.
- `test/cli_build.rb`, `test/cli_new.rb`, `test/dev_error_page.rb`: the
  command strings, the staleness check on a temporary tree, the order of
  the server's steps and that a failed incremental build stops it.
- The flow measured again, by one script, on the same VM: a new
  application, object cache empty at the start, every step timed to the
  first response that shows it. Before is 34c9b7e and after is 885b41e.
  The before run had the framework at a path long enough for gen's C to be
  split (C3), which is the case kinder to it: gen built in 18 s there, not
  the 38 s of section 1.

| Step | Before | After |
| --- | --: | --: |
| `cybertrain new` | 17.4 s | 11.3 s |
| `db migrate`, the first migration | 118.5 s | 68.4 s |
| `db migrate` again, nothing pending | 106.0 s | 64.3 s |
| `db status` after that | 73.6 s | 0.1 s |
| `cybertrain server`, first start | 87.6 s | 88.0 s |
| a controller edit, the first after the start | 121.2 s | 78.1 s |
| a controller edit, the second | 63.5 s | 65.6 s |
| a route added (gen's C changes) | 88.9 s | 85.5 s |
| the server stopped and started, nothing changed | 18.9 s | 9.6 s |
| the server started after a controller edit | 103.7 s | 68.3 s |
| `db status` after that edit | 78.3 s | 62.4 s |
| `db migrate` with one new migration | 117.4 s | 88.2 s |

  Where it fell short of what was expected:
  - **`db migrate` with nothing pending is 64 s once, then 0.1 s.** The gen
    step after the first migration writes `gen/models/`, which is newer
    than the db binary that just ran, so the next `db` command compiles
    `bin/db.rb` again (57 s) though nothing it requires changed. Every
    `db` command after that is 0.1 s until a Ruby file changes; before,
    each one compiled gen and db. The same holds after any edit: `db
    status` is 62 s, all of it `bin/db.rb`. This is spin's staleness rule
    (docs/spinel-feedback.md) meeting a program that is the whole
    framework (section 6, item 2).
  - **A restart with nothing changed is 9.6 s, not 1 s**: gen wrote
    `gen/routes.rb` during the route edit, after its own binary was built,
    so the next gen step compiles gen once more (8.5 s; 18 s before).
  - **The second and later edits did not move**, as section 2 says they
    could not: 63.5 s and 65.6 s are the same edit within the noise of
    the VM.

## 6. Left for the maintainer

1. **The analysis (C1) is the edit loop.** 44 of 53 s per edit, and the
   whole of a test file's build. Recorded for Spinel in
   docs/spinel-feedback.md with the table above. Inside this repository the
   only lever is the size of the program: about 730 of the 2,730 framework
   methods are subsystems a CRUD application may never call (WebSocket and
   streams, jobs and the scheduler, the HTTP client and `Net`, the mailer,
   the cache, the jobs page); at an exponent of 1.7 leaving them out would
   take about 40% off the analysis. That changes what `require "cybertrain"`
   means and how `Main` wires the roles, so it is a design question, not
   part of this change.
2. **A slimmer `bin/db.rb`.** A db program that requires only
   `cybertrain/db/cli` and `cybertrain/config` analyses in 8 s instead of
   48 s (13 s to build at `-O0` instead of 57 s). But `bin/db.rb` loads
   `config/app.rb`, which is application code (`examples/blog`'s calls
   `Cybertrain::Scheduler.cron` and `Cybertrain::Job.prune_done`), so the
   slim program does not compile for such an application, and skipping
   `config/app.rb` would ignore a configured `database_path`.
3. **`cybertrain gen`**, or hints that say `cybertrain spin run gen`: the
   generators print "spin run gen" as the next step, which builds a release
   gen after D-b. A command of the CLI's own would keep one mode.
4. **Tests**: phase 5a's `cybertrain test` (one program for an
   application's tests) removes the per-file analysis; `spin test` itself
   cannot be run in parallel in one package (C5), which is for spin.
