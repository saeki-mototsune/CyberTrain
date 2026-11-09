# Phase 3 (jobs, delivery and outbound) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver phase 3 of the Rails-gap programme: job classes with retry policies and keyed concurrency, cron schedules with a persisted timetable, a jobs page and command, a cache store, a fuller HTTP client (streaming, gzip, SSE, redirects), feed timers and supervision, HTML mail and `deliver_later`, and the job test helpers.

**Architecture:** Every Rails-shaped feature keeps the Rails vocabulary and uses the framework's established mechanism under Spinel: a lexical scan of `app/jobs` into generated `case` tables and literal `rescue` arms (no `constantize`, no stored blocks on base receivers), SQLite tables the framework creates itself (`cybertrain_schedules`, `cybertrain_cache`, `cybertrain_feeds`, new columns on `cybertrain_jobs`), the opt-in substitution pattern for openssl and zlib, and one return type per method name across the program.

**Tech Stack:** Ruby compiled by Spinel 2026.11.04.7026 (also run under CRuby), SQLite via FFI, the existing `Net`, `WebSocket`, `Mailer`, `HttpClient`, `GzipFFI`, `TimeZone` and `Views` layers, the test receivers in `cybertrain/test/`.

**Spec:** docs/superpowers/specs/2026-11-07-phase3-jobs-outbound-design.md (sections 2–17; the authority for every value below).

## Global Constraints

- Spinel rules (spikes/NOTES.md): no computed send or `constantize` (1); nullable ivars through nil-capable casts (7); `when Time` before `when Array` (8); seed polymorphic containers (9/46); one return type per method name across the program, distinct statically-resolved receivers excepted (10/34/41); threads started through a method (21); rescue in a non-yielding method (32/45); messages built into a local before `raise` (58); boxed-String byte scanning once openssl or zlib is linked (62); no stored block run through a base-class receiver (88).
- openssl and zlib stay opt-in: `cybertrain.rb` requires neither `cybertrain/net/tls`, `cybertrain/http/gzip_ffi` nor `cybertrain/encryptor`; a feature that needs them installs itself through a substitution point when its file is required (spec §8, §14).
- Framework tables (`cybertrain_schedules`, `cybertrain_cache`, `cybertrain_feeds`, the new `cybertrain_jobs` column) are created with `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE … ADD COLUMN` on first use and left out of `db/schema.rb` (`SchemaDumper.table_names`), as `cybertrain_jobs` and `cybertrain_leases` are.
- Every task ends with: `ruby script/gate` green (snapshot presence, reserved names, guide i18n), `script/api-docs` clean (YARD, fail on warning; every `{Link}` resolves), the affected `spin test test/<x>.rb` programs green with `script/regen-snapshot test/<x>.rb` for changed `.expected` files (a snapshot changes only where behaviour intentionally changed), and, for tasks that touch the generator, `test/fixtures/gen_app/gen/**` regenerated through `Gen::Runner` (as test/gen_runner_models.rb does), `examples/blog/gen/**` through `cd examples/blog && spin run gen`, and docs/api/stubs/generated_app.rb mirroring every newly emitted method. `script/test-shard 0 1` (the whole suite, several minutes) runs at the end of every task; never run two Spinel builds in one build directory at once.
- Commit trailers: each commit ends with the implementer's own `Co-Authored-By` line and `Claude-Session: https://claude.ai/code/session_01ScPEggU9WUkFSWQD5AVWtS`; never a model identifier in code, comments or commit subjects (CONTRIBUTING.md).
- Toolchain: `export PATH=/root/.cybertrain/spinel/2026.11.04.7026/lib/spinel:$PATH`; `spin test test/x.rb`; `ruby test/gen_*.rb` for text-only generator tests needs `-I.`.
- New method names are checked against the program before use (spec §14's table); the fallback for a refused pair is the prefixed name there.
- Messages and option names are the spec's, verbatim (sections 2–11, 12).

## Review Focus

1. **A payload that is not a JSON object** reaches a job class through `Job.enqueue(kind, "plain")` or a legacy row: `run_args` must be `{}` and the job must run (or fail on its own terms), never crash the worker thread. Pinned in Task 4's test "a non-object payload gives a Run whose run_args is {}".
2. **Cron across a DST transition**: a wall time that does not exist on the spring-forward day is skipped (the next matching minute runs), and a time inside the autumn fold runs once. Pinned in Task 2's test "next_after over the Europe/London transitions".
3. **Two policies matching one exception** (`retry_on StandardError` written before `discard_on ArgumentError`): the first declared arm wins, so the `ArgumentError` is retried, not discarded. Pinned in Task 6's test "the first declared policy wins".
4. **A redirect whose `Location` is relative, or a loop between two URLs**: the relative target resolves against the current URL, the loop stops at `redirects:` with `TooManyRedirectsError` and no hop is dialled twice. Pinned in Task 9's test "redirects: relative Location and a loop".
5. **A `Cache.fetch` block that raises** after `race_condition_ttl` extended the stale row: nothing is written, the exception propagates, and the stale row expires after the extension (the next caller recomputes). Pinned in Task 8's test "fetch whose block raises writes nothing".

---

### Task 1: The spike (spec §14)

**Files:**
- Create: `spikes/phase3/cron_dst.rb`, `spikes/phase3/rescue_arms.rb`, `spikes/phase3/thread_respawn.rb`, `spikes/phase3/gzip_client.rb`, `spikes/phase3/multipart.rb`, `spikes/phase3/names.rb` (small Spinel programs, each with a `spin.toml` or run with `spin run`, kept as the record; they are not tests)
- Modify: `spikes/NOTES.md` (new rules numbered after the current last one, with index entries), `docs/spinel-feedback.md` (a row per Spinel limit found), `docs/superpowers/specs/2026-11-07-phase3-jobs-outbound-design.md` §14 ("**Results (2026-11-09 …)**" block, as phase 2's §14 has)

**Interfaces:**
- Produces: the six verdicts of spec §14 (1–6) with the fallback chosen where a check fails; every later task reads the amended §14 before implementing its area.

- [ ] **Step 1: Write the six programs.** (1) `Cron`-like arithmetic: compute the next minute matching `30 1 * * *` after 2026-03-28 23:00 UTC in `Europe/London` with `TimeZone.find("Europe/London")`, `utc_to_local` / `local_to_utc` and `TimeZone.civil_to_epoch`; expect the 01:30 of 2026-03-29 to be skipped (it does not exist) and 2026-10-25's 01:30 to occur once. (2) A class `AppError < StandardError`, `Sub < AppError`, and a method with `rescue Sub => e` / `rescue AppError => e` arms raising a framework control exception from inside an arm, in a program that requires `cybertrain`; plus `e.class.ancestors` printed. (3) A thread that raises, `Thread#alive?` read from the main thread, a replacement spawned through a method, with `cybertrain/websocket` required. (4) A program that requires `cybertrain/http_client`, `cybertrain/net/tls` and `cybertrain/http/gzip_ffi`, compiled with `spinel prog.rb -c -o /tmp/x.c`, grepped for `sp_raise_nomethod(sp_nomethod_msg("getbyte"` and `("each_byte"` (NOTES 62). (5) A `multipart/alternative` message with a UTF-8 body and base64 parts built by hand, delivered to `Test::SmtpReceiver`, parsed back. (6) A program requiring the whole framework plus a module `Cache` with `read` / `write` / `delete` / `clear`, a class with `perform(args)`, `Job.register`-shaped code and `Sse::Parser#feed`, compiled and run.
- [ ] **Step 2: Run each with `spin run`**, record the output in the program's header comment.
- [ ] **Step 3: Amend spec §14** with the results and the fallback taken for any failure; add NOTES rules for new findings (numbered after the current last rule; index entries), spinel-feedback rows for limits.
- [ ] **Step 4: Gate and commit**: "Phase 3 spike: cron over DST, rescue arms for application classes, thread respawn, gzip linked into the client, multipart mail, name pairs".

---

### Task 2: `Cybertrain::Cron`

**Files:**
- Create: `cybertrain/cron.rb` (`module Cybertrain::Cron`; `class Expression` with `minutes`, `hours`, `days`, `months`, `wdays` as sorted `Array<Integer>` and `expression_text`; `Cron.parse(text) -> Expression` raising `ArgumentError, "cron \"#{text}\": #{reason}"` for a bad field count, a value out of range, a step of 0, a name it does not know, or an expression that can never match (`31 2`, `30 2 30 2`); `Cron.next_after(expr, epoch, zone) -> Integer` (the first matching minute strictly after `epoch`, in `zone`, a `TimeZone`: it steps through UTC minutes and tests each one's local civil time against the expression, so a local time that does not exist (the spring gap) is never matched; across the autumn fold an expression whose hour field is `*` runs at both occurrences of the repeated hour (Vixie cron's rule for wildcard hours: `30 * * * *` keeps its hourly cadence) while an expression with a fixed hour runs once, at the earlier instant (a candidate whose local civil minute equals the previous match's is skipped); searches at most 5 years ahead and raises `ArgumentError` past that))
- Test: `test/cron.rb` (new; CRuby-runnable: no SQLite)

**Interfaces:**
- Consumes: `Cybertrain::TimeZone.find(name)`, `#utc_to_local(epoch)`, `#local_to_utc(local_epoch)`, `TimeZone.civil_to_epoch`, `TimeZone.epoch_to_civil`.
- Produces: `Cron.parse`, `Cron.next_after`, `Cron::Expression#expression_text`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "parse accepts the five-field forms" do
  e = Cybertrain::Cron.parse("12 * * * *");        assert_equal [12], e.minutes; assert_equal 24, e.hours.size
  e = Cybertrain::Cron.parse("*/15 9-17 * * 1-5"); assert_equal [0, 15, 30, 45], e.minutes; assert_equal [1, 2, 3, 4, 5], e.wdays
  e = Cybertrain::Cron.parse("0 9 1,15 jan-mar sun"); assert_equal [1, 15], e.days; assert_equal [1, 2, 3], e.months; assert_equal [0], e.wdays
  assert_equal [0], Cybertrain::Cron.parse("0 0 * * 7").wdays   # 7 is Sunday
end
test "parse refuses what it cannot run" do
  ["* * * *", "60 * * * *", "*/0 * * * *", "0 0 * foo *", "0 0 31 2 *", "@hourly"].each do |bad|
    assert_raises("ArgumentError") { Cybertrain::Cron.parse(bad) }
  end
end
test "next_after in UTC" do
  e = Cybertrain::Cron.parse("12 * * * *"); utc = Cybertrain::TimeZone.find("UTC")
  assert_equal Time.utc(2026, 11, 9, 10, 12).to_i, Cybertrain::Cron.next_after(e, Time.utc(2026, 11, 9, 10, 0).to_i, utc)
  assert_equal Time.utc(2026, 11, 9, 11, 12).to_i, Cybertrain::Cron.next_after(e, Time.utc(2026, 11, 9, 10, 12).to_i, utc) # strictly after
end
test "next_after over the Europe/London transitions" do
  e = Cybertrain::Cron.parse("30 1 * * *"); london = Cybertrain::TimeZone.find("Europe/London")
  # 2026-03-29 01:30 does not exist (clocks go 01:00 -> 02:00): the next run is 2026-03-30 01:30 BST
  assert_equal london.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(2026, 3, 30, 1, 30, 0)), Cybertrain::Cron.next_after(e, Time.utc(2026, 3, 28, 2, 0).to_i, london)
  # 2026-10-25 01:30 occurs twice: run once (the first), and the next run is the 26th
  first = Cybertrain::Cron.next_after(e, Time.utc(2026, 10, 24, 2, 0).to_i, london)
  assert_equal Time.utc(2026, 10, 25, 0, 30).to_i, first   # the first occurrence (01:30 BST), not 01:30 GMT an hour later
  assert_equal Time.utc(2026, 10, 26, 1, 30).to_i, Cybertrain::Cron.next_after(e, first, london)
end
test "an hourly expression runs at both occurrences of the repeated hour" do
  e = Cybertrain::Cron.parse("30 * * * *"); london = Cybertrain::TimeZone.find("Europe/London")
  a = Cybertrain::Cron.next_after(e, Time.utc(2026, 10, 25, 0, 0).to_i, london)   # 01:30 BST = 00:30 UTC
  b = Cybertrain::Cron.next_after(e, a, london)                                   # 01:30 GMT = 01:30 UTC
  assert_equal Time.utc(2026, 10, 25, 0, 30).to_i, a
  assert_equal Time.utc(2026, 10, 25, 1, 30).to_i, b
end
test "Asia/Tokyo weekday mornings" do
  e = Cybertrain::Cron.parse("0 9 * * 1-5"); tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
  assert_equal Time.utc(2026, 11, 9, 0, 0).to_i, Cybertrain::Cron.next_after(e, Time.utc(2026, 11, 6, 0, 0).to_i, tokyo) # Fri -> Mon 09:00 JST
end
```

- [ ] **Step 2: Run to verify it fails** (`spin test test/cron.rb`: `Cybertrain::Cron` undefined). **Step 3: Implement** (expand each field into a sorted Integer Array; `next_after` walks UTC minutes from `epoch + 60`, converts each with `utc_to_local` and `epoch_to_civil`, and tests the civil fields — day-of-month OR day-of-week when both are restricted (cron's rule); the gap needs no special case; for a fixed-hour expression a candidate whose local civil minute equals the last matched one is skipped so the fold runs once; to stay fast it jumps by whole days when the day fields rule the day out). **Step 4: Run** `spin test test/cron.rb`, regen snapshot. **Step 5: Gate and commit**: "Cron: five-field expressions and the next run in a TimeZone".

---

### Task 3: Scheduler: `cron`, `job:` tasks, the persisted timetable

**Files:**
- Modify: `cybertrain/scheduler.rb` (`Task` 39 gains `task_cron` (Expression or nil), `task_zone` (TimeZone), `task_catch_up` (Boolean), `task_job_kind` (String, "" none), `task_job_args` (String JSON); `Scheduler.cron(expr, name, tz: Cybertrain.config.scheduler_tz, catch_up: false, job: "", args: {}, &block)` 105 (a block OR `job:`, not both, not neither → `ArgumentError`); `start!` 131 loads `cybertrain_schedules` and verifies every `job:` kind is registered (`Job.handler_index(kind) >= 0`, else `fail_boot`-style `raise ArgumentError` the application turns into a boot error); `run_due` 209 computes the next run per task (`every`: last + interval; `cron`: `Cron.next_after(task_cron, last_run, zone)`), runs a block task on the scheduler thread or enqueues `job:` (`Job.enqueue(kind, args_json)`), writes `last_run_at` / `next_run_at`; `schedule_all` 286 reads the table: `every` continues from `last_run_at` (an overdue one runs at once), `cron` with `catch_up: false` takes the next future match, `catch_up: true` runs once when `next_run_at < now`; new `Scheduler.prune_schedules` (deletes rows whose name is no longer registered; called from `start!`); `task_summary` 298 shows cron tasks as `name (cron "expr" tz) next 2026-11-09T10:12Z`)
- Create: `cybertrain/scheduler/timetable.rb` (`Cybertrain::Scheduler::Timetable`: `install!` (`cybertrain_schedules (name TEXT PRIMARY KEY, last_run_at INTEGER, next_run_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)`), `read_all -> Hash<String, Array<Integer>>` ([last, next]), `write(name, last_run_at, next_run_at, now)`, `prune(names)`), required by scheduler.rb
- Modify: `cybertrain/config.rb` (`scheduler_tz` from `CYBERTRAIN_SCHEDULER_TZ`, default `"UTC"`; `scheduler_error` 1066 adds "scheduler_tz \"X\" is not a known time zone" when `TimeZone.find(tz).found?` is false), `cybertrain/db/schema_dumper.rb` (`table_names` skips `cybertrain_schedules`)
- Test: `test/scheduler.rb` (grown), `test/scheduler_cron.rb` (new, compiled with SQLite: the timetable)

**Interfaces:**
- Consumes: `Cron.parse`, `Cron.next_after` (Task 2); `Job.enqueue(kind, payload)`, `Job.handler_index(kind)` (existing).
- Produces: `Scheduler.cron(expr, name, tz:, catch_up:, job:, args:)`, `Scheduler.prune_schedules`, the `cybertrain_schedules` table; `Config#scheduler_tz`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/scheduler_cron.rb (temporary database as test/scheduler.rb sets one up)
test "a cron task runs at its minute and not before" do
  ran = [0]; Cybertrain::Scheduler.cron("12 * * * *", "at twelve") { ran[0] += 1 }
  Cybertrain::Scheduler.schedule_all(Time.utc(2026, 11, 9, 10, 0).to_i)
  Cybertrain::Scheduler.run_due(Time.utc(2026, 11, 9, 10, 11, 59).to_i); assert_equal 0, ran[0]
  Cybertrain::Scheduler.run_due(Time.utc(2026, 11, 9, 10, 12).to_i);     assert_equal 1, ran[0]
  Cybertrain::Scheduler.run_due(Time.utc(2026, 11, 9, 10, 13).to_i);     assert_equal 1, ran[0]
end
test "tz: evaluates the expression in that zone" do
  # "0 9 * * *" tz: "Asia/Tokyo" runs at 00:00 UTC, not 09:00 UTC
end
test "the timetable survives a restart and a leader change" do
  # every(600, "x"): schedule_all at t0, run_due at t0+600 (runs), stop!, start! again at t0+700: next run is t0+1200, not t0+1300
  # a row for a name that is no longer registered is pruned at start!
end
test "a missed cron slot is skipped unless catch_up" do
  # "0 3 * * *" scheduled at 02:00, process down until 04:00: schedule_all(04:00) -> no run until next 03:00; with catch_up: true -> runs once at the first run_due
end
test "a job: task enqueues and does not run the job on the scheduler thread" do
  # Job.handle("report") { |p| raise "must not run here" }; cron("* * * * *", "r", job: "report", args: { "scope" => "all" }); run_due -> Job.state_count("queued") == 1, payload == {"scope":"all"}
  # cron(..., job: "unknown") then start! raises ArgumentError naming the registered kinds
  # cron without block and without job:, or with both -> ArgumentError
end
test "task_summary names cron tasks with their next run" do ... end
```

In `test/scheduler.rb`: the existing `every` tests stay green; add "every continues from last_run_at after schedule_all".

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement** (Timetable first, then Task fields, `cron`, `run_due`, `schedule_all`, `prune_schedules`, config, dumper skip; YARD on each public method; `@api public`). **Step 4: Run** `scheduler`, `scheduler_cron`, `health` (last_tick unchanged), `config_settings` (new setting in the dump; regen snapshot), `schema_dumper` (table skipped). **Step 5: Gate and commit**: "Scheduler: cron expressions in a time zone, job: tasks, a persisted timetable with catch_up".

---

### Task 4: Job core: `Run`, `register`, outcome writes, `discarded`, per-kind limits

**Files:**
- Modify: `cybertrain/job.rb` (new `class Run` with `run_id`, `run_kind`, `run_payload`, `run_attempts`, `run_claimed_by`, `run_args` (memoised `Cast.json_hash(run_payload)`), `run_outcome_written?` / `run_outcome_written!`; `Handler` 40 gains `handler_run_block` (takes a Run), `handler_concurrency_key` (String, "" none; Task 5 uses it) and `handler_max_attempts`; `Job.register(kind, concurrency: 0, concurrency_key: "", max_attempts: 0) { |run| }` (0 → `Config#job_max_attempts` at run time); `Job.handle` 177 becomes a wrapper registering a Run block that calls the payload block; constants `OUTCOME_REQUEUED = :requeued`, `OUTCOME_FAILED = :failed`, `OUTCOME_STALE = :stale`; `Job.retry_later(run, error, wait_base, polynomial, attempts_limit) -> Symbol` and `Job.discard(run, error) -> Symbol` writing with the fence (`record_outcome` 897 reused; `polynomial` → `wait = attempts ** 4 + 2`); `finish` 830 skips the write when `run_outcome_written?`; state `discarded` accepted by `state_count` 792 and listed with `failed` by the new `Job.prune_finished(before) -> Integer` (`prune_done` 804 unchanged); `fail_exhausted` 548 uses the kind's recovery limit `Job.recovery_limit(kind) -> Integer` = the larger of `Config#job_max_attempts` and the kind's `handler_max_attempts` (an unmatched exception still follows the default policy, so a class whose `retry_on` allows fewer attempts than the default must not be failed early, and one that allows more must not be failed at the default); `run_handler` 878 passes the Run)
- Test: `test/jobs.rb` (grown)

**Interfaces:**
- Produces: `Job::Run` and its readers; `Job.register(kind, concurrency:, concurrency_key:, max_attempts:) { |run| }`; `Job.retry_later`, `Job.discard`, `Job::OUTCOME_*`; state `"discarded"`; `Job.prune_finished(before)`. Task 6's generated code and Task 13's mail job call these.

- [ ] **Step 1: Write the failing tests** (in test/jobs.rb's style, temporary database)

```ruby
test "register gives the handler a Run with the parsed args and the attempt" do
  seen = Array.new(0) { "" }
  Cybertrain::Job.register("run kind") { |run| seen << "#{run.run_kind}:#{run.run_attempts}:#{Cybertrain::Cast.int(run.run_args["n"])}" }
  Cybertrain::Job.enqueue("run kind", "{\"n\":7}"); Cybertrain::Job.work_one(Time.now)
  assert_equal ["run kind:1:7"], seen
end
test "a non-object payload gives a Run whose run_args is {}" do  # Review Focus 1
  Cybertrain::Job.register("plain") { |run| raise "bad" unless run.run_args.empty? }
  Cybertrain::Job.enqueue("plain", "plain text"); Cybertrain::Job.work_one(Time.now); assert_equal 1, Cybertrain::Job.state_count("done")
end
test "retry_later requeues with the wait, fails at the limit, and answers the outcome" do
  # attempts 1 of limit 3, wait_base 60 fixed -> OUTCOME_REQUEUED, run_at == now + 60, state queued
  # polynomial: attempts 2 -> run_at == now + 18
  # attempts 3 of limit 3 -> OUTCOME_FAILED, state failed, last_error starts with the error class
end
test "retry_later and discard answer OUTCOME_STALE when the row was reclaimed" do
  # claim, then UPDATE claimed_by to another label; retry_later -> :stale, row untouched
end
test "discard writes discarded and prune_finished removes it with failed rows; prune_done does not" do ... end
test "a handler that writes its own outcome is not written again by finish" do ... end
test "fail_exhausted uses the larger of the default and the kind's max_attempts" do
  # register("long", max_attempts: 20); a stale running row at attempts 5 -> recover! requeues it; a kind without max_attempts at attempts 5 (config 5) -> failed
  # register("short", max_attempts: 2) with config 5: a stale row at attempts 3 is requeued (the default policy may still retry it), at attempts 5 failed
end
test "Job.handle still receives the payload String" do ... end
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `jobs`, `job_threads`, `scheduler`, `main_roles`. **Step 5: Gate and commit**: "Job: Run-taking registration, retry_later and discard with the fence, the discarded state, per-kind max_attempts in recovery".

---

### Task 5: Job core: keyed concurrency, backfill, keyed recovery

**Files:**
- Modify: `cybertrain/job.rb` (`install!` 459 / `add_missing_columns` 476 add `concurrency_key TEXT NOT NULL DEFAULT ''` and `CREATE INDEX IF NOT EXISTS cybertrain_jobs_state_kind_key ON cybertrain_jobs (state, kind, concurrency_key)`; `Job.concurrency_key_for(kind, payload) -> String` = `Cast.str(Cast.json_hash(payload)[key])` ("" when the kind has no key); `enqueue` 437 computes and stores it, raising `ArgumentError, "Job.enqueue #{kind.inspect}: the payload has no #{key.inspect} field for limits_concurrency"` when the registry names a key the payload lacks (`perform_later` relies on this; `Job.enqueue` from a `job:` cron task too); `kinds_at_limit` 665 groups by `(kind, concurrency_key)` and `claim_sql` 681 excludes pairs (`AND NOT (kind = ? AND concurrency_key = ?)` per pair; a kind limited without a key keeps the per-kind arm); new `Job.backfill_keys(now) -> Integer` (per keyed kind: `SELECT id, payload … WHERE kind = ? AND state = 'queued' AND concurrency_key = ''`, then `UPDATE … SET concurrency_key = ? WHERE id = ? AND concurrency_key = ''`, batches of 1000, rows left `""` logged once at warn with their ids), called from `start!` after `recover!`; `recover!` 529 reads stale rows and requeues a keyed kind's row with `UPDATE … SET state = 'queued', concurrency_key = ?, … WHERE id = ? AND state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)` per row; unkeyed kinds keep the one statement)
- Test: `test/jobs.rb` (grown), `test/job_threads.rb` (grown: two keys run at once, the same key does not)

**Interfaces:**
- Consumes: Task 4's `Handler#handler_concurrency_key`.
- Produces: `Job.concurrency_key_for(kind, payload)`, `Job.backfill_keys(now)`, the `concurrency_key` column and index; `enqueue` keys rows.

- [ ] **Step 1: Write the failing tests**

```ruby
test "the key derivation is the same for a String, an Integer, a Float and a boolean" do
  Cybertrain::Job.register("keyed", concurrency: 1, concurrency_key: "exchange") { |run| }
  assert_equal "true", Cybertrain::Job.concurrency_key_for("keyed", "{\"exchange\":true}")
  assert_equal "7",    Cybertrain::Job.concurrency_key_for("keyed", "{\"exchange\":7}")
  assert_equal "",     Cybertrain::Job.concurrency_key_for("keyed", "{\"other\":1}")
  assert_equal "",     Cybertrain::Job.concurrency_key_for("keyed", "not json")
end
test "enqueue stores the key and refuses a payload without the field" do ... end
test "two rows of the same key never run at once across two claimed_by labels; different keys do" do
  # as the existing per-kind concurrency test, with keys "a","a","b": the second "a" is not claimed while the first is running; "b" is
end
test "backfill_keys keys queued rows of a keyed kind and lists the unkeyable ones" do
  # insert a queued row with concurrency_key '' and payload {"exchange":"X"} directly; register keyed; backfill_keys -> 1; key == "X"; a row with "not json" stays '' and warn mentions its id; second call -> 0
end
test "recovery requeues a stale running row with its key in the same statement" do
  # insert a running row with '' key, heartbeat fresh; recover! -> untouched; age the heartbeat; recover! -> queued with key "X"
end
test "an upgrade adds the column and the index to an existing table" do  # PRAGMA table_info / index_list
end
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `jobs`, `job_threads`. **Step 5: Gate and commit**: "Job: limits per concurrency key, one key derivation for enqueue, backfill and keyed recovery".

---

### Task 6: `Job::Base`, the job scan, `gen/jobs.rb`, `generate job`

**Files:**
- Create: `cybertrain/job/base.rb` (`class Cybertrain::Job::Base`: `perform(args)` raising `NotImplementedError, "#{self.class.name}#perform is not defined"`, `retries_exhausted(error)` no-op, class-method macro stubs `retry_on(*args)`, `discard_on(*args)`, `limits_concurrency(**opts)` returning nil; required by `cybertrain/job.rb`), `cybertrain/generator/job_scan.rb` (`Gen::JobInfo`: `file`, `class_name`, `superclass_name`, `policies` (ONE Array of `PolicyInfo` in declaration order: `policy_kind` (`"retry"` or `"discard"`), `exception_class`, `wait_base`, `polynomial`, `attempts`, `line`), `concurrency_to`, `concurrency_key`, `has_perform`, `has_exhausted_hook`; `JobScan.scan_dir(dir)` over `app/jobs/**/*.rb`, reusing `ModelScan.word_at`, `literal_text`, `constant_name?`, `continued?`; a macro it cannot read stops with `"#{file}:#{lineno}: #{line.strip} -- write retry_on/discard_on/limits_concurrency on one line with literal values"`), `cybertrain/generator/jobs_emitter.rb` (`JobsEmitter.emit(infos) -> String`: per class the reopening with `self.job_kind`, `perform_later(args = {})`, `perform_at(time, args = {})`, `perform_in(seconds, args = {})`, `perform_now(args = {})`, `self.run_job(run)`; then the `Cybertrain::Job.register(...)` lines; nothing when no job class)
- Modify: `cybertrain/generator/manifest.rb` (requires for every `app/jobs/**/*.rb`, nested included, then `jobs`), `cybertrain/generator/runner.rb` (`["gen/jobs.rb", JobsEmitter.emit(JobScan.scan_dir("#{root}/app/jobs"))]` always written, empty-bodied when there is no job), `cybertrain/cli.rb` + new `cybertrain/cli/job.rb` (`cybertrain generate job Name [--retry Klass:wait:attempts]`: `app/jobs/<name>_job.rb` and `test/<name>_job.rb` from templates, `--force`), `script/check-reserved-names` (reads jobs_emitter.rb), `docs/api/stubs/generated_app.rb` (the five generated class methods and `run_job` on a sample job)
- Modify: `test/fixtures/gen_app/app/jobs/welcome_job.rb` (new: `retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5`, `discard_on ArgumentError`, `limits_concurrency to: 1, key: "user_id"`, `perform` that records into a module-level Array, `retries_exhausted` that records), `test/fixtures/gen_app/app/jobs/admin/report_job.rb` (new, nested: `retry_on StandardError, wait: :polynomially_longer, attempts: 20`, no key); regenerate the fixture
- Test: `test/gen_jobs.rb` (new, text: `ruby -I. test/gen_jobs.rb`), `test/gen_jobs_compiles.rb` (new, compiled on the fixture with a temporary database), `test/gen_manifest.rb` (grown: the job requires), `test/cli_generate_job.rb` (new, snapshot)

**Interfaces:**
- Consumes: Task 4's `Job.register`, `Job::Run`, `Job.retry_later`, `Job.discard`, `OUTCOME_FAILED`; Task 5's key.
- Produces: `Job::Base`; on every job class `job_kind`, `perform_later`, `perform_at`, `perform_in`, `perform_now`, `run_job`; `gen/jobs.rb`.

- [ ] **Step 1: Write the failing tests**

test/gen_jobs.rb (text): the emitted `run_job` for WelcomeJob contains, in order, `rescue Cybertrain::Mailer::TimeoutError => e` with `Cybertrain::Job.retry_later(run, e, 60, false, 5)` and the `retries_exhausted(e)` call guarded by `== Cybertrain::Job::OUTCOME_FAILED`, then `rescue ArgumentError => e` with `Cybertrain::Job.discard(run, e)`; `Cybertrain::Job.register("WelcomeJob", concurrency: 1, concurrency_key: "user_id", max_attempts: 5)`; `register("Admin::ReportJob", concurrency: 0, concurrency_key: "", max_attempts: 20)` with `retry_later(run, e, 0, true, 20)`; the arms keep declaration order for both interleavings (a class with `discard_on ArgumentError` written BEFORE `retry_on StandardError` emits the discard arm first; the fixture's WelcomeJob has the retry arm first); `perform_later` body is `Cybertrain::Job.enqueue(job_kind, JSON.generate(args))` after an `ArgumentError` for a non-Hash; refusals: `retry_on X do |j, e|`, `retry_on X, wait: 5.minutes`, `:wait => 5`, a trailing comment, each with the one-line message; a class in app/jobs not inheriting Job::Base is skipped; the manifest lists `../app/jobs/admin/report_job.rb` before `jobs`.

test/gen_jobs_compiles.rb (compiled):
```ruby
test "perform_later enqueues the class kind with the JSON args and perform runs it" do ... end
test "perform_at and perform_in set run_at; perform_now runs synchronously and propagates" do ... end
test "retry_on requeues with the declared wait and attempts; retries_exhausted runs once after the failed write" do
  # make perform raise TimeoutError 5 times: attempts 1..4 requeued (run_at + 60), 5th -> failed, hook recorded exactly once
end
test "retries_exhausted does not run for a stale attempt" do  # reclaim the row before the 5th finish; hook not recorded
test "discard_on writes discarded without a retry" do ... end
test "the first declared policy wins" do  # Review Focus 3: a job with retry_on StandardError before discard_on ArgumentError; an ArgumentError is requeued
test "limits_concurrency key: refuses a payload without the field and keys the row" do ... end
test "a stale row of Admin::ReportJob at attempt 5 is requeued (max_attempts 20)" do ... end
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement** (scan → emitter → manifest/runner → Base → CLI → fixture regen → stub). **Step 4: Run** `gen_jobs` (CRuby), `gen_jobs_compiles`, `gen_manifest`, `gen_runner_models`, `cli_generate_job`, `jobs`, `script/check-reserved-names`. **Step 5: Gate and commit**: "Job classes: Job::Base, the app/jobs scan, gen/jobs.rb with perform_later and literal retry arms, cybertrain generate job".

---

### Task 7: The jobs page and the `jobs` command

**Files:**
- Modify: `cybertrain/generator/routes_dsl.rb` (`jobs_page(path, before_action: "")` 87-area: records a `JobsPageSpec` (path, before_action Symbol name) on `Routes`; one per app, a second raises), `cybertrain/generator/routes_emitter.rb` (the six routes for the page: GET `path`, POST `path/retry_all`, POST `path/discard_all`, POST `path/:id/retry`, POST `path/:id/discard`, POST `path/:id/delete`, to `CybertrainJobsController`), `cybertrain/generator/controllers_emitter.rb` (emits `class CybertrainJobsController < ApplicationController` with `before_action :<name>` when given, actions calling `Cybertrain::JobsPage`; a warning line on stdout from the runner when no `before_action:`)
- Create: `cybertrain/jobs_page.rb` (`Cybertrain::JobsPage`: `index_html(page, per_page, path) -> String` built with the `tag` builder (D38): the counts table, the failed / discarded lists with `button_to` forms, the running list, the queued count and next due; `retry(id) -> Boolean`, `discard(id) -> Boolean`, `delete(id) -> Boolean` (`WHERE id = ? AND state IN ('failed','discarded')`; retry resets `attempts = 0, run_at = now, last_error = NULL` and writes the derived `concurrency_key` in the same UPDATE), `retry_all -> Integer` (per row, the same statement), `discard_all_failed -> Integer`; `rows(state, page, per_page) -> Array<Hash>`)
- Modify: `cybertrain/main.rb` (`BUILTIN_WORDS` 45 gains `"jobs"`; `when "jobs"` → `Job::CLI.run(argv)` printing a table for `list [STATE]`, `retry ID | --all`, `discard ID`, `delete ID`, `prune [--before DAYS]` (default 7, through `Job.prune_finished`); usage 284), `cybertrain/config.rb` (`jobs_page_per_page`, `CYBERTRAIN_JOBS_PAGE_PER_PAGE`, 50, at least 1), `cybertrain/cli/templates.rb` (`config/routes.rb` template gains the commented `# jobs_page "/admin/jobs", before_action: :require_admin`)
- Create: `cybertrain/job/cli.rb` (`Cybertrain::Job::CLI.run(argv) -> Integer` exit status; output through `puts`)
- Modify: `test/fixtures/gen_app/config/routes.rb` (`jobs_page "/admin/jobs", before_action: :require_admin`), `test/fixtures/gen_app/app/controllers/application_controller.rb` (`def require_admin` that redirects unless `params["admin"] == "1"`), regenerate
- Test: `test/jobs_page.rb` (new, compiled: the test client on the fixture), `test/gen_routes.rb` (grown: the six routes), `test/gen_controllers.rb` (grown: the emitted controller), `test/main_jobs.rb` (new: the CLI output snapshot on a temporary database), `test/cli_new.rb` (snapshot: the routes template comment)

**Interfaces:**
- Consumes: Task 4's `discarded` state and `prune_finished`; the `tag` builder; `Relation#page`-style pagination through `Config#jobs_page_per_page`.
- Produces: `jobs_page` in routes; `CybertrainJobsController`; `./<app> jobs …`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/jobs_page.rb
test "the page lists counts and failed rows, and the before_action applies" do
  # enqueue two rows, fail one (Job.discard on a Run / direct UPDATE), GET /admin/jobs without admin=1 -> redirect; with -> 200, body includes "failed", the kind, the error text, a form posting to /admin/jobs/<id>/retry
end
test "retry resets attempts and requeues; discard and delete act only on failed or discarded rows" do ... end
test "retry keys a legacy failed row of a keyed kind in the same statement" do  # a failed row with '' key and payload {"user_id":3} of a keyed kind -> after retry, queued with key "3"
test "retry_all and discard_all_failed count the rows" do ... end
# test/main_jobs.rb: `jobs list`, `jobs retry ID`, `jobs retry --all`, `jobs discard ID`, `jobs prune --before 0` printed output and exit statuses
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `jobs_page`, `gen_routes`, `gen_controllers`, `gen_runner_models`, `main_jobs`, `main` (usage snapshot), `cli_new`, `config_settings`. **Step 5: Gate and commit**: "Jobs page from jobs_page in routes, inheriting ApplicationController; the jobs command".

---

### Task 8: `Cybertrain::Cache`

**Files:**
- Create: `cybertrain/cache.rb` (`module Cybertrain::Cache`: `install!` (`cybertrain_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires_at INTEGER, updated_at INTEGER NOT NULL)`), `fetch(key, expires_in: 0, race_condition_ttl: 0) { String } -> String` (0 = never expires), `read(key) -> String | nil`, `write(key, value, expires_in: 0, unless_exist: false) -> Boolean`, `delete(key) -> Boolean`, `exist?(key) -> Boolean`, `increment(key, by: 1, expires_in: 0) -> Integer`, `clear -> nil`, `prune(now) -> Integer` (batches of 1000), `fetch_hash`, `fetch_array`, `fetch_int` (JSON / Integer text, parsed with `Cast`); `Cache.now` injectable for tests (`Cache.clock=`); registers the scheduler task `"cybertrain cache prune"` every `Config#cache_prune_interval` when required — through `Scheduler.every`, guarded so a second require does not register twice)
- Modify: `cybertrain/config.rb` (`cache_prune_interval`, `CYBERTRAIN_CACHE_PRUNE_INTERVAL`, 300, at least 1 in `scheduler_error`), `cybertrain/db/schema_dumper.rb` (skip `cybertrain_cache`)
- Test: `test/cache.rb` (new, compiled, temporary database)

**Interfaces:**
- Produces: the `Cache` API above; Task 16 (the blog) and the guides use it.

- [ ] **Step 1: Write the failing tests**

```ruby
test "fetch computes once and serves the value until it expires" do ... end        # expires_in 60; clock + 61 recomputes
test "write with unless_exist answers false for a live row and true after it expired" do ... end
test "race_condition_ttl lets one caller recompute while the other reads the stale value" do
  # row expired; caller A fetch with race_condition_ttl: 30 and a block that records -> recomputes; before A writes, caller B (same clock) fetch -> gets the OLD value without running its block
end
test "fetch whose block raises writes nothing" do  # Review Focus 5: raise inside the block -> propagates, read(key) is the old value or nil, and after race_condition_ttl seconds the stale row expires
test "increment creates and adds, with an expiry" do ... end
test "fetch_hash / fetch_array / fetch_int parse what they stored and recover from a corrupt cell" do ... end
test "prune removes only expired rows; the scheduler task is registered once" do ... end
test "the table is created on first use and left out of the schema dump" do ... end
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement** (`race_condition_ttl`: `UPDATE cybertrain_cache SET expires_at = ? WHERE key = ? AND expires_at IS NOT NULL AND expires_at < ?` wins when `changes == 1`). **Step 4: Run** `cache`, `scheduler`, `schema_dumper`, `config_settings`. **Step 5: Gate and commit**: "Cache: a SQLite-backed store with fetch, expires_in, race_condition_ttl, unless_exist, typed readers and pruning".

---

### Task 9: HTTP client: verbs, streaming, files, redirects, JSON readers

**Files:**
- Modify: `cybertrain/http_client.rb` (`initialize` 184 gains `redirects: 0`; `request(verb, url, body: "", content_type: "", headers: NO_HEADERS) { |chunk| } -> Response` (PUT, PATCH, DELETE, HEAD, GET, POST; `get` / `post` delegate); the block form streams: `read_body` 613 / `read_chunked` 667 yield each chunk when a block is given and the Response's `body` is `""`; `get_to_file(url, path, headers:) -> Response` writing `path + ".part"` then `File.rename`, `Response#bytes_written`; redirects: after `exchange` 239, a 301/302/303/307/308 with `Location` re-enters `perform` with the resolved URL (absolute, or relative against the current URL: `HttpClient.resolve_location(current, location)`), `redirects` times at most, `TooManyRedirectsError < Error` past it, `BlockedAddressError` for https → http, 303 (and 301/302 of POST) → GET without a body, 307/308 keep verb and body; `Response#json_hash -> Hash`, `#json_array -> Array` via `Cast.json_hash` / `Cast.array`)
- Modify: `cybertrain/test/http_receiver.rb` (`respond_with` gains `redirect_to: ""` (a Location with the status), and a `chunks:` Array to serve a body in several chunked frames with a pause)
- Test: `test/http_client.rb` (grown)

**Interfaces:**
- Produces: `HttpClient#request`, `#get_to_file`, `redirects:`, `Response#json_hash` / `#json_array` / `#bytes_written`, `TooManyRedirectsError`; the block form Task 10 inflates and Task 11 feeds.

- [ ] **Step 1: Write the failing tests**

```ruby
test "request sends PUT, PATCH, DELETE and HEAD" do ... end   # received_request.method and body
test "the block form yields chunks and leaves body empty; max_body does not apply" do
  # receiver chunks: three 1 MiB frames with max_body: 1_048_576 -> 3 yields, total 3 MiB, no TooLargeError
end
test "get_to_file writes the body through a .part file" do ... end
test "redirects: follows 302 then 301 to GET, keeps 307 as POST with the body, and stops at the limit" do ... end
test "redirects: relative Location and a loop" do  # Review Focus 4: Location "/other" resolves against the receiver's URL; two URLs pointing at each other with redirects: 3 -> TooManyRedirectsError after exactly 3 hops
test "a redirect from https to http is refused" do ... end   # BlockedAddressError, message names host and port only
test "json_hash and json_array parse the body and answer {} / [] otherwise" do ... end
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `http_client`, `websocket_client` (shares `dial`), `mailer` (unchanged). **Step 5: Gate and commit**: "HttpClient: request with every verb, streamed bodies and get_to_file, redirects with the address check per hop, JSON readers".

---

### Task 10: HTTP client: gzip through the opt-in `GzipFFI`

**Files:**
- Modify: `cybertrain/http_client.rb` (`HttpClient.gzip_decoder=` / `.gzip_decoder` substitution point (nil default); when set, `request_head` 310 adds `Accept-Encoding: gzip`; `read_body` / `read_chunked` inflate a `Content-Encoding: gzip` body — buffered: `GzipFFI.gunzip(body, max_body)`; streamed: the chunks pass through the bounded inflater (`GzipFFI.inflater` 142) and the yields are the inflated pieces; an encoding other than `gzip` / `identity` → `BadResponseError`), `cybertrain/http/gzip_ffi.rb` (sets `HttpClient.gzip_decoder` when `cybertrain/http_client` is loaded, the way `net/tls` sets `Net.tls_connector`), `cybertrain/test/http_receiver.rb` (`respond_with(gzip: true)` compresses the body with `Zlib` under CRuby — the receiver runs in the test program, compiled: use the existing deflate path the stream tests use, or ship a pre-compressed fixture body as a constant)
- Test: `test/http_client_gzip.rb` (new; requires `cybertrain/http/gzip_ffi`; also runs the NOTES 62 C grep as part of its build check the way test/openssl_dispatch.rb does)

**Interfaces:**
- Consumes: Task 9's block form and `read_body`.
- Produces: gzip responses decoded when `cybertrain/http/gzip_ffi` is required; `HttpClient.gzip_decoder`.

- [ ] **Step 1: Write the failing tests** ("without the gzip file no Accept-Encoding is sent" lives in test/http_client.rb; in the new file: "Accept-Encoding: gzip is sent and a gzip body is inflated under max_body", "a streamed gzip body yields inflated chunks", "an inflated body past max_body raises TooLargeError", "Content-Encoding: br is a BadResponseError").
- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `http_client`, `http_client_gzip`, `openssl_dispatch`; `spinel test/http_client_gzip.rb -c -o /tmp/x.c && grep -c 'sp_nomethod_msg("getbyte"' /tmp/x.c` → 0. **Step 5: Gate and commit**: "HttpClient: gzip responses through the opt-in GzipFFI, buffered and streamed".

---

### Task 11: `Cybertrain::Sse::Parser`

**Files:**
- Create: `cybertrain/sse.rb` (`module Cybertrain::Sse`; `class Event` with `event_name` (String, "message" default), `event_data` (String, lines joined with "\n"), `event_id` (String, "" none), `event_retry_ms` (Integer, 0 none); `class Parser` with `feed(chunk) { |event| }` (CR / LF / CRLF line ends, a line split across chunks, `:` comments, `data:` accumulation, an optional single space after the colon, dispatch on a blank line, an empty data buffer dispatches nothing) and `finish { |event| }` for a trailing event without a final blank line)
- Test: `test/sse_parser.rb` (new; CRuby-runnable)

**Interfaces:**
- Produces: `Sse::Parser#feed`, `Sse::Event` readers; the guide pairs it with Task 9's block form.

- [ ] **Step 1: Write the failing tests** ("two events in one chunk", "an event split across three chunks mid-line", "CRLF and CR line ends", "comments and unknown fields are ignored", "event: and id: and retry: are read; retry: non-numeric is ignored", "a blank line with no data dispatches nothing", "finish flushes a trailing event").
- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `sse_parser`. **Step 5: Gate and commit**: "Sse::Parser: Server-Sent Events from streamed chunks".

---

### Task 12: Feeds: `on_tick`, supervision, status rows, exit on repeated death

**Files:**
- Modify: `cybertrain/websocket.rb` (`Subscription` 133 gains `on_tick(seconds, &block)` (Integer ≥ 1, one per subscription, a second raises) and `sub_tick_due?(now)`; `feed_connected` 561 and the disconnected wait call the tick block when due, with `conn` or `nil`, rescued and logged like `on_message`; `Status` 103 gains `restarts` and `thread_alive?`; a pong updates `sub_message!`-style `sub_activity!(epoch)`; `feed_status` 335 reports them; new `WebSocket.thread_alive?(name)` and `WebSocket.restart_feed(name) -> Boolean` (spawns a new thread for a dead subscription through `spawn_feed` 490, counts `restarts`); new `WebSocket.publish_status(now)` writing `cybertrain_feeds` rows)
- Create: `cybertrain/websocket/feed_table.rb` (`WebSocket::FeedTable`: `install!` (`cybertrain_feeds (name TEXT PRIMARY KEY, process TEXT, connected INTEGER, started_at INTEGER NOT NULL, last_activity_at INTEGER, restarts INTEGER, updated_at INTEGER NOT NULL)`), `upsert(row…)`, `read_all -> Array<Hash>`), `cybertrain/background/supervisor.rb` (`Background.supervise!(config)`: one thread per process (spawned through a method) that every second checks `WebSocket.feed_names` for dead threads, restarts them after `min(30, 2 ** restarts)` seconds with a `[WARN]`, counts deaths per feed inside `Config#feed_restart_window`, and when one reaches `Config#feed_restart_limit` in a process whose role is `feeds` (`Background.exit_on_feed_death = true`, set by `Application#run_feeds`) logs `[FATAL] feed NAME restarted N times in W s; exiting`, calls `WebSocket.stop!` and `exit 1`; publishes status rows every `Config#feed_status_interval`; `Background.stop_supervisor!` first in `stop_all`)
- Modify: `cybertrain/background.rb` (`start_all` 150 / `start_only` 170 start the supervisor when feeds run; `stop_all` 225 stops it first), `cybertrain/application.rb` (`run_feeds` 325 sets `Background.exit_on_feed_death = true`), `cybertrain/config.rb` (`feed_status_interval` 10, `feed_restart_limit` 10, `feed_restart_window` 600, each at least 1, validated in `scheduler_error`'s neighbour `feeds_error` called from boot), `cybertrain/db/schema_dumper.rb` (skip `cybertrain_feeds`)
- Test: `test/websocket_subscription.rb` (grown: `on_tick` while disconnected and connected, pong refreshes activity), `test/background.rb` (grown: supervisor restarts a dead feed thread with backoff, counts `restarts`, publishes rows), `test/feeds_exit.rb` (new, child-process pattern of test/boot_encryption.rb: a feed whose loop raises past its rescues with `feed_restart_limit` 2 and window 600 exits 1 and prints the FATAL line), `test/schema_dumper.rb` (skip)

**Interfaces:**
- Produces: `Subscription#on_tick`, `Status#restarts` / `#thread_alive?`, `WebSocket.restart_feed`, `WebSocket.publish_status`, `FeedTable.read_all`, `Background.supervise!`, `Background.exit_on_feed_death=`; the `cybertrain_feeds` table Task 13 reads.

- [ ] **Step 1: Write the failing tests** (with the scripted WebSocket receiver: "on_tick fires every N seconds while disconnected (conn nil) and connected (conn given)", "an exception in on_tick is logged and the loop continues", "a pong refreshes last_activity_at"; in background.rb: "a feed thread that dies is restarted after the backoff and restarts counts it", "status rows are written with started_at, last_activity_at, restarts"; test/feeds_exit.rb as above).
- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `websocket_subscription`, `websocket_integration`, `background`, `feeds_exit`, `main_roles`, `config_settings`, `schema_dumper`. **Step 5: Gate and commit**: "Feeds: on_tick on the feed thread, a supervisor that restarts dead feed threads and exits a feeds process after repeated deaths, status rows".

---

### Task 13: Feed health in `/up` and `feeds status`

**Files:**
- Modify: `cybertrain/middleware/health_check.rb` (`problem` 48 gains `return "feed stale" if feed_stale?(now, feed_stale)` after `worker stale`, when `Config#health_feeds`; `feed_stale?` reads `FeedTable.read_all` and applies spec §9's two independent conditions: `updated_at < now - stale` OR `COALESCE(last_activity_at, started_at) < now - stale`), `cybertrain/config.rb` (`health_feeds` true from `CYBERTRAIN_HEALTH_FEEDS`, `health_feed_stale` 180, at least 1, in `health_error`), `cybertrain/application.rb` (`run_feeds` 325 gains `status` as the first word: prints the table and exits 0; usage in `main.rb` 284)
- Test: `test/health.rb` (grown), `test/main_roles.rb` (grown: `feeds status` output)

**Interfaces:**
- Consumes: Task 12's `FeedTable.read_all`.
- Produces: `503 feed stale`; `./<app> feeds status`.

- [ ] **Step 1: Write the failing tests** ("a stale publisher row gives 503 feed stale", "a silent feed under a fresh publisher gives 503", "a never-active feed past the threshold (NULL last_activity_at, old started_at) gives 503", "a fresh row gives 200", "CYBERTRAIN_HEALTH_FEEDS=0 gives 200 with a stale row", "feeds status prints one line per row").
- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `health`, `main_roles`, `config_settings`. **Step 5: Gate and commit**: "/up reports a stale feed from the status rows; feeds status".

---

### Task 14: HTML mail and `deliver_later`

**Files:**
- Modify: `cybertrain/mailer.rb` (`deliver(to:, subject:, body:, html: "", from:)` 297/309: with `html` non-empty the DATA is `Mailer::Message.build(from, to, subject, body, html, boundary)` — `multipart/alternative`, text part then html part, both `charset=UTF-8` `base64`, boundary from `Crypto.random_token(16)`; `perform` 322 takes the built message text; `Mailer.deliver_later(to:, subject:, body:, html: "", from:) -> Integer` enqueues `"cybertrain mail"` with the JSON of the five fields; the handler is registered when the file is required: `Job.register("cybertrain mail", max_attempts: 5) { |run| Mailer.run_mail_job(run) }` whose body is the generated-style arm table: `rescue Mailer::TimeoutError, Mailer::ConnectError => e` → `Job.retry_later(run, e, 60, false, 5)`, `rescue Mailer::RejectedError => e` → `Job.discard(run, e)`)
- Create: `cybertrain/mailer/message.rb` (`Mailer::Message.build(from, to, subject, text, html, boundary) -> String` and `Message.parse(data) -> Hash` for the receiver test: `"text"`, `"html"`, `"subject"`), required by mailer.rb
- Modify: `cybertrain/views.rb` (`Views.render_mail(name, locals = {}) -> String`: `render_partial` wrapped in `app/views/layouts/mail.html.erb` when the engine has it, else the partial alone), `cybertrain/test/smtp_receiver.rb` (`ReceivedMessage#message_parts -> Hash` through `Message.parse`)
- Test: `test/mailer.rb` (grown), `test/mailer_job.rb` (new: `deliver_later` through `Job.work_one` against the SMTP receiver; a RejectedError discards; a ConnectError requeues with run_at + 60), `test/views_detached.rb` (grown: `render_mail` with and without the layout)

**Interfaces:**
- Consumes: Task 4's `Job.register`, `retry_later`, `discard`; `Views.render_partial`.
- Produces: `Mailer.deliver(html:)`, `Mailer.deliver_later`, `Mailer::Message.build` / `.parse`, `Views.render_mail`.

- [ ] **Step 1: Write the failing tests** ("deliver with html: sends multipart/alternative whose parts decode to the text and the html", "deliver without html: is the plain message of today", "a UTF-8 body with a lone dot line survives base64", "deliver_later enqueues cybertrain mail and work_one delivers it", "a rejected address discards; a connection failure requeues", "render_mail wraps in layouts/mail when present").
- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `mailer`, `mailer_job`, `views_detached`, `jobs`. **Step 5: Gate and commit**: "Mailer: multipart/alternative HTML mail, Views.render_mail, deliver_later as a built-in job with its retry policy".

---

### Task 15: The job test helpers

**Files:**
- Create: `cybertrain/test/jobs.rb` (top-level `assert_enqueued_jobs(count, kind = "")`, `assert_enqueued_with(kind, args = {})`, `assert_no_enqueued_jobs(kind = "")`, `perform_enqueued_jobs(now = Time.now) -> Integer`, `clear_enqueued_jobs -> Integer`, in the style of test/client.rb's `assert_response`; `assert_enqueued_with` compares `Cast.str` of both sides per given key)
- Modify: `cybertrain/cli/templates.rb` (the generated `test/support/<app>_test.rb` requires `cybertrain/test/jobs`), `docs/api/stubs` if the helpers need a stub entry (they are framework methods: YARD in place)
- Test: `test/job_helpers.rb` (new, compiled, temporary database)

**Interfaces:**
- Consumes: Task 4's Run and Task 6's `perform_now`.
- Produces: the five helpers.

- [ ] **Step 1: Write the failing tests** (each helper's pass and fail message; `perform_enqueued_jobs` returns the count and leaves future rows; `assert_enqueued_with("WelcomeJob", "user_id" => 1)` matches a JSON 1).
- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run** `job_helpers`, `cli_new`. **Step 5: Gate and commit**: "Test helpers for jobs: assert_enqueued_jobs, assert_enqueued_with, perform_enqueued_jobs, assert_no_enqueued_jobs, clear_enqueued_jobs".

---

### Task 16: `cybertrain new` and deploy templates

**Files:**
- Modify: `cybertrain/cli/new_app.rb` (`app/jobs/.keep`), `cybertrain/cli/templates.rb` (`config/app.rb` gains a commented `# Cybertrain::Scheduler.cron("0 4 * * *", "prune sessions") { ... }`; `config/deploy.yml` 402-422: `options: restart: unless-stopped` on the `worker` and `feeds` roles with a comment naming the exit rule; `.env.example` lines for `CYBERTRAIN_HEALTH_FEEDS` and `CYBERTRAIN_SCHEDULER_TZ` commented), `README.md` (feature list: job classes, cron, cache, jobs page, HTML mail, gzip / streaming)
- Test: `test/cli_new.rb` (snapshot)

- [ ] **Step 1: Regenerate the snapshot after the template change and review the diff** (only the new lines). **Step 2: Gate and commit**: "cybertrain new: app/jobs, a cron example, restart policies for the worker and feeds roles, the new variables".

---

### Task 17: examples/blog

**Files:**
- Create: `examples/blog/app/jobs/notify_comment_job.rb` (`perform(args)` logs `"new comment #{Cast.int(args["comment_id"])} on article #{…}"` at info; `retry_on StandardError, wait: 30, attempts: 3`)
- Modify: `examples/blog/app/controllers/comments_controller.rb` (`NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)` after a successful create), `examples/blog/config/app.rb` (`Cybertrain::Scheduler.cron("0 4 * * *", "prune sessions") { … }` using the existing session prune SQL), `examples/blog/config/routes.rb` (`jobs_page "/admin/jobs", before_action: :require_admin`) and `examples/blog/app/controllers/application_controller.rb` (`def require_admin`: answers 404 unless `BLOG_ADMIN_TOKEN` is set in the environment AND `request.header("x-admin-token")` equals it — a minimal token gate, since the blog has no user accounts; with the variable unset the page is unreachable, which is the safe default for a deployed example; the README explains how to set it and the test sets it through `ENV` before the request), `examples/blog/app/controllers/articles_controller.rb` (`@article_count = Cybertrain::Cast.int(Cybertrain::Cache.fetch("articles/count", expires_in: 60) { Article.count.to_s })` shown in the index), `examples/blog/app/views/articles/index.html.erb` (the count), `examples/blog/README.md`
- Regenerate `examples/blog/gen/**` (`spin run gen`)
- Test: `examples/blog/test/comments.rb` (grown: posting a comment enqueues `NotifyCommentJob` — `assert_enqueued_with`; `perform_enqueued_jobs` runs it), `examples/blog/test/articles.rb` (grown: the count is cached — a second request after another article still shows the old count until `Cache.delete`; `/admin/jobs` is 404 without the token and renders with it), `examples/blog/test/support/blog_test.rb` (requires `cybertrain/test/jobs`, clears the cache and the jobs between tests)

- [ ] **Step 1: Write the failing tests.** **Step 2: Run** `cd examples/blog && spin test` to see them fail. **Step 3: Implement and regenerate** (`spin run gen`, snapshots as Task 17 of phase 2 did: from the compiled output). **Step 4: Run** `spin test`, `spin run gen -- --check`, root `ruby script/gate`. **Step 5: Commit**: "blog: a NotifyCommentJob, a cron task, the jobs page, a cached article count".

---

### Task 18: Documents, design.md D51–D57, guides and translations

**Files:**
- Modify: `docs/design.md` (D51 job classes / policies / keys / `Run` registration, D52 cron and the timetable, D53 the jobs page and command, D54 the cache, D55 the HTTP client, D56 feed timers / supervision / health, D57 HTML mail and `deliver_later`, each dated 2026-11-09 with "why" and the Spinel constraint; D28's "Later" and D33's "Deferred" lists shrink; the programme paragraph (line ~102) marks phase 3 delivered; "## 13. Implementation status" gets the dated entry with the new test programs and NOTES rules), `docs/guide/background-and-operations.md` (jobs rewritten around classes; `Job.handle` as the short form; retry, concurrency keys, cron, the jobs page and `jobs` command, upgrade order for keyed kinds, test helpers), `docs/guide/external-services.md` (streaming, `get_to_file`, gzip opt-in, redirects, SSE, `on_tick`, supervision and the exit rule, HTML mail, `deliver_later`, the re-encrypt-style notes where relevant), `docs/guide/testing.md` (the five helpers), `docs/guide/configuration.md` (the eight variables of spec §12), `docs/guide/realtime.md` (feed health), their fr / ja / ru / zh translations with `script/check-guide-i18n --update-sha`, `docs/deploy.md` and `docs/deploy.en.md` (the `jobs` and `feeds status` commands, `health_feeds`, the restart policy), `cybertrain/job.rb` / `scheduler.rb` / `websocket.rb` / `http_client.rb` / `mailer.rb` header comments (final state), `spikes/NOTES.md` (rules from Task 1 cross-checked), the spec's "## 18. Implementation notes" (what differed, rule numbers, test counts from `script/test-shard 0 1` and the blog)
- Test: `ruby script/gate` (i18n), `script/api-docs`, `script/guide-pages`

- [ ] **Step 1: Write the documents.** **Step 2: Run** the checks and the full suite; record the counts. **Step 3: Commit**: "Phase 3 documents: design.md D51 to D57, the background, external-services, testing, configuration and realtime guides with translations, deploy notes, README".

---

## Execution order and verification

Task 1 first (the spike amends the spec every later task reads). Then 2 → 3 (cron, scheduler), 4 → 5 → 6 → 7 (the job core, keys, the generated classes, the page), 8 (cache, independent of 4–7 but after 3 for the prune task), 9 → 10 → 11 (the HTTP client, gzip, SSE), 12 → 13 (feeds, health), 14 (mail; after 4), 15 (helpers; after 6), 16 (templates; after 7, 12), 17 (blog; after 6, 7, 8, 15), 18 last. Every task ends with `ruby script/gate`, `script/api-docs` and the whole `script/test-shard 0 1` green; after Task 17 `cd examples/blog && spin test` and `spin run gen -- --check` pass as well, which is spec §17's acceptance item 10.
