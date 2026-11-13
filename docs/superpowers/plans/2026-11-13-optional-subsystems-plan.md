# Optional subsystems: implementation plan

**Spec:** [docs/superpowers/specs/2026-11-13-optional-subsystems-design.md](../specs/2026-11-13-optional-subsystems-design.md).
One branch (`claude/intelligent-thompson-sa8hel`), one pull request. The
tasks are sequential: each builds on the one before.

**Starting point for every task:** the spike's hack diff (subsystems cut out
by deleting and stubbing, not by hooks), which lists every coupling with its
file and line at a915504. It is a map of what to change, not code to copy:
the real change keeps each subsystem's behaviour and moves it behind a hook.

## Global constraints

- Everything under `cybertrain/` except `cybertrain/cli*` compiles under
  Spinel only; `cybertrain/cli*` runs under CRuby and compiles under Spinel.
  No `send`, `eval`, `method_missing`; typed empty Arrays
  (`Array.new(0) { "" }`); one return type per method name across the whole
  program, including every override of a hook (spikes/NOTES.md rules 10, 34,
  41); never store a block that calls a method through a base-class-typed
  receiver (rule 88). Rule 101 (Task 1) narrowed the hazard: such a block is
  wrong when it is written inside a subclass's body before that hook's `def`.
  So a feature file defines its subclass first and registers its instance at
  the end of the file, outside the class body.
- The core files must not name a class of a subsystem, in code or in a
  `require`. Check with a grep over the core's require closure after each
  task (Task 2 adds the script).
- `require "cybertrain"` keeps its meaning: the existing test suite, which
  requires it, passes unchanged except where a snapshot changes on purpose.
  A changed snapshot goes through `script/regen-snapshot` and its diff is
  read and explained in the commit message.
- Never run two `spin`/`spinel` commands at once on this machine.
- Commits pass `script/gate` (hooks installed; no `--no-verify`), in the
  shape of CONTRIBUTING.md's "Commits", ending with the session's
  Co-Authored-By and Claude-Session trailers.
- Guide pages: English and the four translations together
  (`script/check-guide-i18n`). No release numbers on pages.

## Task 1: prove the registry under the pinned Spinel

`spikes/phase6/feature_registry.rb` (a standalone program, no framework):
a base class with hooks returning String, Bool, Integer and nil; two
subclasses in two files required in either order, each overriding some hooks
and registering one instance into a module-level Array at require time; a
second require of the same file is a no-op; dispatch through the Array; a
periodic hook run from a block stored in a module-level Array whose body
calls `Registry.run_periodic(i, now)` (no captured receiver); a hook that
receives and returns the framework's kind of object (a class with ivars).
Compile with `spinel`, compare with CRuby. Record the result as a rule in
spikes/NOTES.md. If any shape fails, stop and report: the design depends on
it.

## Task 2: the registry, the core entry, and jobs

- `cybertrain/feature.rb`: `Feature` (base, no-op hooks of section 4 of the
  spec) and `Features` (register once by class name, each hook iterated).
- `cybertrain/core.rb`: today's `cybertrain.rb` minus every subsystem require.
  `cybertrain.rb`: `require "cybertrain/core"` and every subsystem line.
- `cybertrain/jobs.rb`: requires `job`, `scheduler`, `lease`, `cron`, the
  worker role, `job/cli`/the jobs page; defines and registers `JobsFeature`
  (boot problem from `Scheduler.job_kinds_error`, start/stop/request_stop of
  the scheduler and job threads, the worker staleness health problem, the
  `worker` and `jobs` commands, running other features' periodic hooks).
- Core files lose their direct references: `application.rb`, `roles.rb`,
  `roles/server.rb`, `middleware/health_check.rb`, `main.rb` (a missing role
  prints which require it needs), `cache.rb` (periodic hook; self-prune on
  write without jobs).
- `script/check-core-closure`: computes the require closure of
  `cybertrain/core` lexically and fails if it contains a subsystem file or a
  core file names a subsystem constant; run by `script/gate`.
- Tests: `test/features_core.rb` (compiled: the core alone boots an
  application in-process and serves a page; `worker`/`jobs` without jobs
  print the require); `test/cache.rb` gains the self-prune case with a fixed
  clock; the existing job, scheduler, server and health-check tests pass
  unchanged.

## Task 3: streams

`cybertrain/streams.rb`: requires `stream` and its endpoint, poller,
`turbo_stream_renderer`, `turbo_stream_builder`; `StreamsFeature` (the
endpoint through the middleware hook at today's position, poller start/stop,
the stream helpers through the helper hook); `Controller#turbo_stream` moves
here by reopening `Controller`. The template helper dispatch in
`template/helpers.rb` loses its stream arms and asks `Features` after its own
arms. Tests: the existing stream, Turbo and template tests pass; a core-only
program has no `turbo_stream_from` (Task 6 makes gen refuse it).

## Task 4: feeds, mailer, rate limiting

- `cybertrain/feeds.rb`: `websocket/feed_table`, `background`, the feeds
  role; `FeedsFeature` (boot problem, start/stop, `failed?`, feed health,
  the `feeds` command).
- `cybertrain/mailer` stays as is; `cybertrain/mailer/later` already requires
  jobs. The core stops requiring either.
- `cybertrain/rate_limit.rb` reopens `Controller` for `rate_limit` and the
  rate check; `controller.rb` keeps a hook in `run_one` and stops requiring
  `rate_limit`. Rate limiting requires `cache`.
- Tests: feeds, mailer, rate-limit and authentication tests pass unchanged;
  `test/features_core.rb` gains one program per subsystem line compiling
  alone.

## Task 5: gen refuses a helper of a missing subsystem

`cybertrain/feature_catalog.rb` (a leaf, CRuby- and Spinel-safe): the table
of subsystem name, require line, view helpers, roles. gen reads
`bin/NAME.rb`'s require lines, scans views for the catalog's helpers and
fails with `file:line: HELPER needs require "LINE" in bin/NAME.rb`; `--check`
too. Tests: `test/gen_*.rb` for refusal and acceptance; examples/blog's gen
output unchanged.

## Task 6: generators

`cybertrain new` writes `require "cybertrain/core"`; `generate job` and
`generate authentication` add their line once, after the last
`require "cybertrain..."` line, unless `require "cybertrain"` is there, and
print it. Tests: `test/cli_new.rb`, `test/cli_generate_job.rb`,
`test/cli_authentication.rb` and their snapshots.

## Task 7: the record and the measurement

- Guide: a section "Subsystems" in docs/guide/how-it-works.md (the require
  table, what a missing line does), the configuration or install page's
  mention of `bin/NAME.rb`, the tutorial where it shows `bin/blog.rb` if it
  does; four translations each.
- docs/design.md: a new decision D71 (this spec in short).
- Measure: a scaffolded application with `cybertrain/core` against the same
  with `cybertrain` (analysis, full build, one controller edit with the dev
  loop), recorded in docs/performance-next.md.
