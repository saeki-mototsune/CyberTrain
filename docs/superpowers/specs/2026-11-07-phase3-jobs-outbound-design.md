# Phase 3 of the Rails-gap programme: jobs, delivery and outbound

Date: 2026-11-07. Status: agreed with the maintainer (twelve questions,
2026-11-07); the plan follows.

## 0. Context and scope

The programme (docs/design.md D1, revised 2026-11-05) delivers the 120 items
of the fin_dash survey in five phases. Phase 1 landed on 2026-11-05 (D36 to
D41), phase 2 on 2026-11-07 (D42 to D50). This document is **phase 3**: the
programme paragraph names "cron schedules, job classes, retry policies, a
failed-jobs page, a cache store, a fuller HTTP client, feed timers and
restarts". The survey's chapters 10 (jobs), 11 (long-lived processes), 12
(external services) and 13 (cache, configuration, mail) hold these; phase 1
also sent HTML mail here (its section 11). The cut agreed for phase 3:

- **In:** job classes with `perform` (J-3), per-class retry policies (J-4),
  the jobs page and its CLI (J-5), `limits_concurrency` with a key (J-7),
  cron and time-of-day schedules with a persisted timetable (J-2), the job
  test helpers (J-8); feed timers and the automatic restart of a dead feed
  thread (P-3, P-4); the HTTP client's gzip, streamed and large responses,
  Server-Sent Events, redirects and the remaining verbs (H-1, H-2, H-4, H-5);
  a cache store with `fetch`, `expires_in`, `race_condition_ttl` and
  `unless_exist` (K-1, K-2); HTML mail and `deliver_later` (ML-1 and phase
  1's deferral).
- **Out** (section 15): the application-side job base of fin_dash's AI jobs
  (J-6), HTML and XML parsing (H-3), YAML (H-6), a zlib wrapper (H-7), heavy
  computation in another process (P-5), error reporting and log tags (O-2,
  O-3: phase 5), job priority and queue-level uniqueness, a cache in a
  separate database file and a cache size cap, keep-alive, proxies, cookies,
  HTTP/2, mail attachments, parameterised mailer classes, an inline job mode
  for tests.

The two criteria of phase 2 decide every judgement call here as well, in
this order: **closer to Rails** (vocabulary, defaults, what a Rails developer
types) and **easier to understand**. Compatibility with applications on 0.4
carries low weight (section 16 lists each break).

Where Spinel forbids the Rails mechanism, the Rails vocabulary is kept and the
mechanism is the framework's own: build-time generation from a lexical scan
into `case` tables and literal `rescue` arms (D4, D8, D38), never a computed
`send` or a `constantize` (spikes/NOTES.md rule 1), never a block stored on
an object and run through a base-class receiver (rule 88), one return type
per method name across the program (rules 10, 34, 41).

## 1. The decisions in one table

| # | Question | Decision |
| --- | --- | --- |
| Q1 | Scope | D1's item (3) plus HTML mail, `deliver_later` and the job test helpers; H-3, H-6, P-5, O-2, O-3 out |
| Q2 | Job classes | `class WelcomeJob < Cybertrain::Job::Base` in `app/jobs/`, `def perform(args)` with `args` a `Hash<String, Object>` from JSON; `perform_later` / `perform_at` / `perform_in` / `perform_now`; scanned lexically, `gen/jobs.rb` registers each class; `Job.handle` blocks stay |
| Q3 | Retry | `retry_on Klass, wait: seconds \| :polynomially_longer, attempts: n` (first match wins), `discard_on Klass` → state `discarded`; unmatched exceptions keep the default backoff; `def retries_exhausted(error)` hook |
| Q4 | Schedules | `Scheduler.cron(expr, name, tz:, catch_up:, job:, args:)`, five-field cron evaluated in a `TimeZone`; `every` stays; the timetable persists in `cybertrain_schedules`; missed cron slots are not replayed unless `catch_up: true` |
| Q5 | Jobs page | `jobs_page "/admin/jobs", before_action: :require_admin` in routes mounts a framework controller that inherits `ApplicationController`; counts, failed / discarded / running lists, retry / discard buttons; `./<app> jobs list \| retry ID \| retry --all \| discard ID` |
| Q6 | Cache | `Cybertrain::Cache` over `cybertrain_cache` in the application database; String values, `fetch_hash` / `fetch_array` / `fetch_int` for JSON; `race_condition_ttl`, `unless_exist`; expired rows pruned by a built-in task |
| Q7 | HTTP client | gzip through the opt-in `GzipFFI`; `get(url) { \|chunk\| }` and `get_to_file`; `Sse::Parser`; `redirects:`; `request(verb, …)` for PUT / PATCH / DELETE; `Response#json_hash` / `#json_array` |
| Q8 | Feeds | `on_tick(seconds) { \|conn\| }` on the feed's own thread; a `Background` supervisor restarts a dead feed thread with backoff and exits the `feeds` process after repeated deaths (Docker restarts it); status rows in `cybertrain_feeds`; `/up` reports `feed stale` from them |
| Q9 | Mail | `deliver(html:)` builds `multipart/alternative`; bodies from `Views.render_partial`; `deliver_later` is a built-in job that stores the finished message |
| Q10 | Test helpers | `assert_enqueued_jobs`, `assert_enqueued_with`, `perform_enqueued_jobs`, `assert_no_enqueued_jobs`, `clear_enqueued_jobs`; `Klass.perform_now(args)` |
| Q11 | Concurrency | `limits_concurrency to: n, key: "arg name"`; a `concurrency_key` column; the claim excludes (kind, key) pairs at their limit |
| Q12 | Verification | Five spike checks (section 14); the blog gains a job, a cron task, the jobs page and one cached count; acceptance in section 17 |

## 2. Job classes (J-3)

### 2.1 Writing a job

```ruby
# app/jobs/welcome_job.rb
class WelcomeJob < Cybertrain::Job::Base
  retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5
  discard_on ArgumentError
  limits_concurrency to: 1, key: "user_id"

  def perform(args)
    user = User.find(Cybertrain::Cast.int(args["user_id"]))
    Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello!\n")
  end

  def retries_exhausted(error)
    Cybertrain.logger.error("welcome mail given up: #{error.message}")
  end
end
```

- `args` is the JSON object the caller passed to `perform_later`, as a
  `Hash<String, Object>` with the nested values boxed the way a json column's
  are (phase 2, section 2.2): readers narrow with `Cast.int(args["user_id"])`,
  `Cast.str`, `Cast.hash`, `Cast.array`. A job takes exactly this one Hash;
  positional arguments and keyword arguments cannot be typed across job
  classes under Spinel, and Rails' own advice is to pass ids, not records.
- Enqueueing: `WelcomeJob.perform_later("user_id" => user.id)` (an empty Hash
  when omitted), `WelcomeJob.perform_at(time, args)`,
  `WelcomeJob.perform_in(seconds, args)`, and `WelcomeJob.perform_now(args)`,
  which runs `perform` on the calling thread with no queue, no retry policy
  and no rescue (exceptions propagate: the shape tests want). Each returns
  the row id (`perform_now` returns `nil`). The kind stored in
  `cybertrain_jobs.kind` is the class name (`"WelcomeJob"`,
  `"Admin::ReportJob"`), so `Job.handle` kinds and job classes share one
  namespace and `Job.enqueue("WelcomeJob", json)` is the same row.
- The `perform_*` class methods and `job_kind` are **generated into the
  class** by `gen/jobs.rb` (reopening it, as the models' generated half is
  reopened by the hand-written half), not inherited from `Job::Base`: a
  generic `perform_later` on the base class would have to know the
  subclass's name at run time, which under Spinel means a `case` table
  anyway. `Job::Base` itself holds only `perform(args)` (raises
  `NotImplementedError`), the `retries_exhausted(error)` no-op, and the
  macro stubs (`self.retry_on`, `self.discard_on`, `self.limits_concurrency`,
  all `nil`, so the class file loads under CRuby and in the generator).
- `args` must be a JSON object: `perform_later` raises `ArgumentError` for a
  non-Hash, and the stored payload is `JSON.generate(args)`. Reading it back
  goes through `Cast.json_hash` (phase 2), so a payload hand-written through
  `Job.enqueue` that is not an object is `{}` to the job.

### 2.2 What the generator does

- `Gen::JobScan` reads `app/jobs/**/*.rb` as text (the component scan's
  method, D38): the `class X < Cybertrain::Job::Base` (or `< ApplicationJob`,
  itself `< Cybertrain::Job::Base`) line, one `retry_on` / `discard_on` /
  `limits_concurrency` macro per line, and whether `perform` and
  `retries_exhausted` are defined. A class in `app/jobs` that does not
  inherit from `Job::Base` is ignored (a helper module may live there); a
  macro it cannot read (a block, a lambda, a hashrocket spelling, a trailing
  comment) stops generation with the one-line message the model macros use
  (phase 2, section 3.4). Inheritance among job classes follows Rails'
  order: `ApplicationJob` (and any other ancestor between a class and
  `Job::Base`) is not registered as a kind of its own; its `retry_on` /
  `discard_on` arms are emitted into each descendant's `run_job` after the
  descendant's own arms, and its `limits_concurrency` applies to a
  descendant that sets none. Every `Job::Base` descendant the scan meets is
  generated, whether it is the second class in a file, nested inside
  another class, or a grandchild; a class whose superclass is none of
  `Job::Base`, `ApplicationJob` or a scanned job class is the ignored
  helper of the previous sentence.
- `gen/jobs.rb` carries, per class: the reopened class with
  `self.job_kind`, `perform_later`, `perform_at`, `perform_in`,
  `perform_now`, and `self.run_job(run)`; and one registration
  `Cybertrain::Job.register("WelcomeJob", concurrency: 1,
  concurrency_key: "user_id") { |run| WelcomeJob.run_job(run) }`. `run_job`
  is the policy table of section 3, written out as literal `rescue` arms.
- `gen/app.rb` emits a literal require for each Ruby file under `app/jobs/`,
  nested directories included (`Admin::ReportJob` in
  `app/jobs/admin/report_job.rb`), before requiring `jobs` (the class bodies
  first, then the generated reopenings), as it does for components.
- `cybertrain generate job Name [--retry Klass:wait:attempts]` writes the
  class file and a test, as `generate component` does.
- `Job.register(kind, concurrency:, concurrency_key:, max_attempts:) { |run| }`
  is the new registration form the generated code uses: the block receives
  a `Job::Run` (`run_id`, `run_kind`, `run_payload`, `run_attempts`,
  `run_claimed_by`, `run_args` (the parsed Hash, computed once)), so a
  policy can read the attempt number and write its own outcome (section 3).
  `max_attempts:` is the most attempts any of the class's policies allows
  (the largest `retry_on … attempts:`, or `Config#job_max_attempts` when
  none is larger); stale-heartbeat recovery uses it (section 3).
  `Job.handle(kind, concurrency:) { |payload| }` stays as it is for
  hand-written handlers (it registers a `Run`-taking wrapper that passes
  `run_payload`, with the default `max_attempts`). Both land in the same
  `HANDLERS` list; a kind registered twice raises, as today.

## 3. Retry policies (J-4)

- `retry_on Klass, wait: 300, attempts: 6`. `wait:` is an Integer of seconds
  or `:polynomially_longer` (Rails' formula: `attempts ** 4 + 2` seconds,
  so 3, 18, 83, 258, 627, 1298 after the first six failures); `attempts:`
  defaults to 5 and counts every attempt including the first. Several lines
  are allowed; the first whose class matches the raised exception (by
  `rescue Klass => e`, so subclasses match) wins. `discard_on Klass` stops at
  once: the row becomes `discarded`, `last_error` records the error, no
  retry. An exception no line matches keeps the default policy of D28
  (60 / 300 / 900 / 3600 seconds, `Config#job_max_attempts`).
- Mechanism: the generated `run_job(run)` is

  ```ruby
  def self.run_job(run)
    job = new
    begin
      job.perform(run.run_args)
    rescue Cybertrain::Mailer::TimeoutError => e
      # The fenced outcome write happens here, inside the generated code,
      # so the exhaustion hook can run with the live exception only when
      # this attempt's row really became `failed`.
      if Cybertrain::Job.retry_later(run, e, 60, false, 5) == Cybertrain::Job::OUTCOME_FAILED
        job.retries_exhausted(e)
      end
    rescue ArgumentError => e
      Cybertrain::Job.discard(run, e)
    end
    nil
  end
  ```

  `Job.retry_later(run, error, wait_base, polynomial, attempts_limit) ->
  Symbol` writes the outcome with phase 1's fence (`WHERE id = ? AND state =
  'running' AND claimed_by = ? AND attempts = ?`): `queued` with `run_at`
  moved by the computed wait when `run_attempts < attempts_limit`, else
  `failed` with `last_error`; it answers `OUTCOME_REQUEUED`,
  `OUTCOME_FAILED` or `OUTCOME_STALE` (the fence rejected the write because
  another worker reclaimed the row, logged at warn as today). The hook
  therefore runs **only after** the fenced transition to `failed`
  succeeded, never for a stale attempt whose replacement may yet succeed.
  `Job.discard(run, error)` writes `discarded` the same way. Both mark the
  `Run` as written (`run.run_outcome_written?`), so `Job.finish` writes
  nothing more for it; a `StandardError` that escapes `run_job` (no arm
  matched) keeps the default policy in `Job.finish`, as today.
- `retries_exhausted(error)` replaces Rails' `retry_on … do |job, error|`
  block (a stored block, rule 88). An exception raised by the hook is logged;
  the row is already `failed`.
- Stale-heartbeat recovery (`Job.recover!`, D28 revised) fails a stale row
  only when its `attempts` has reached the **kind's** `max_attempts`
  (section 2.2's registry field), not `Config#job_max_attempts` for every
  kind: a job with `retry_on … attempts: 20` that loses its worker on
  attempt 5 is requeued, not failed. `fail_exhausted` reads the limit per
  kind from the registry; a kind no longer registered keeps the default.
- The default policy is unchanged for `Job.handle` blocks and for job classes
  without macros. `Config#job_max_attempts` still caps the default policy
  only; a `retry_on` with `attempts: 20` is honoured.
- The state `discarded` joins `queued / running / done / failed`.
  `Job.state_count("discarded")`, the jobs page and `Job.prune_finished(before)`
  (new; `prune_done` stays and prunes `done` only) see it.

## 4. Concurrency with a key (J-7)

- `limits_concurrency to: 1, key: "exchange"`: `to:` is the most rows of this
  class that may be `running` at once across every worker process **per
  key**; `key:` names an entry of `args`, whose String form
  (`Cast.str(args["exchange"])`) is stored in the new column
  `cybertrain_jobs.concurrency_key` at enqueue time. Without `key:` the
  column is `""` and the limit is per class, as `Job.handle(kind,
  concurrency: n)` already is. An enqueue whose `args` lacks the key raises
  `ArgumentError` naming the class and the key.
- The claim transaction's exclusion list (D28 revised) becomes pairs: `SELECT
  kind, concurrency_key, COUNT(*) FROM cybertrain_jobs WHERE state = 'running'
  GROUP BY kind, concurrency_key`, and the claim adds `AND NOT (kind = ? AND
  concurrency_key = ?)` for each pair at its limit (a kind with no key limit
  keeps the per-kind arm). Under SQLite's single writer and the limits
  fin_dash uses (two kinds) the list stays short; the statement is built per
  claim as today.
- `install!` adds `concurrency_key TEXT NOT NULL DEFAULT ''` with `ALTER TABLE
  … ADD COLUMN` when `PRAGMA table_info` lacks it (the phase 1 upgrade path),
  and an index on `(state, kind, concurrency_key)`.
- One key derivation everywhere: `Job.concurrency_key_for(kind, payload) ->
  String` is `Cast.str(Cast.json_hash(payload)[key_name])` — the registry's
  key name for the kind, the payload parsed as a json column is (an object
  root; anything else, including a legacy non-JSON payload, is `{}`), and
  the value through `Cast.str` (so `true` is `"true"`, `7` is `"7"`, a
  missing or `null` field is `""`). `perform_later` calls it at enqueue time
  (and raises `ArgumentError` when the field is missing, section 4's first
  item); the backfill and the recovery below call the same method in Ruby
  and bind the result, never `json_extract` in SQL, so the three paths
  cannot disagree. A row the derivation cannot key (`""`: the field missing
  or the payload not an object) is keyed `""`, which is its own bucket under
  the per-kind limit, and is listed at warn with its id.
- Upgrading rows already in the table: a `queued` row enqueued before its
  kind became keyed carries `""`, and would run beside a new row of the same
  key. So `Job.start!` (every process that runs jobs, after `recover!`)
  **backfills** them: `SELECT id, payload FROM cybertrain_jobs WHERE kind = ?
  AND state = 'queued' AND concurrency_key = ''` per keyed kind, then
  `UPDATE cybertrain_jobs SET concurrency_key = ? WHERE id = ? AND
  concurrency_key = ''` per row with the derived key, in batches of 1000;
  idempotent, so every later start is a no-op (a row the derivation leaves
  `""` is listed once and not revisited). `running` rows left by the old
  processes (D39's deploy order stops them first, but a row whose heartbeat
  is still fresh stays `running` until it goes stale, which can be minutes
  after the new workers started) are keyed **by the recovery itself**:
  `Job.recover!` reads the stale rows (`id, kind, payload, attempts`), and
  for a keyed kind requeues each with `UPDATE … SET state = 'queued',
  concurrency_key = ? WHERE id = ? AND state = 'running' AND heartbeat_at <
  ?` — one statement per row, so no claim can see a requeued row with the
  wrong key; unkeyed kinds keep today's single statement. Recovery runs at
  start and from every scheduler tick at most once a minute, so a row that
  goes stale after the startup backfill is keyed the moment it is requeued.
  The guide's upgrade notes state the order (section 16).
- Rails' `duration:` (a slot that expires) is not built: a stale heartbeat
  frees the slot (D28 revised), which is the same guarantee.

## 5. Schedules (J-2)

### 5.1 `cron`

```ruby
Cybertrain::Scheduler.cron("12 * * * *", "collect prices") { Prices.collect }
Cybertrain::Scheduler.cron("0 9 * * 1-5", "morning report", tz: "Asia/Tokyo",
                           job: "MorningReportJob", args: { "scope" => "all" })
Cybertrain::Scheduler.cron("*/5 * * * *", "poll feeds", catch_up: true) { Feeds.poll }
```

- Five fields (minute, hour, day of month, month, day of week) with `*`,
  `*/n`, `a-b`, `a,b`, `a-b/n` and the names `jan`–`dec` / `sun`–`sat`; day
  of week `0` and `7` are Sunday. The `@hourly`-style shortcuts are not
  accepted. An expression that never matches (`31 2 *`-style) or that cannot
  be parsed stops boot with the expression and the task name.
- `tz:` names a zone of `Cybertrain::TimeZone` (D19; the system zoneinfo
  database, DST included); the default is `"UTC"`. The next run is the first
  wall-clock minute after the last run that matches the expression in that
  zone; across a DST gap a wall time that does not exist is skipped. Across
  a fold Vixie cron's rule applies: an expression whose hour field starts
  with `*` (`30 * * * *`, `0 */2 * * *`) runs at both occurrences of the
  repeated hour, so an hourly entry keeps its hourly cadence in real time;
  an expression with a fixed hour (`30 1 * * *`) runs once, at the first
  occurrence. `Cron.next_after(expr, epoch, zone) -> Integer` is a pure
  function with its own tests; `epoch` is the task's last run (the fold
  rule is defined against it).
- A `cron` task takes either a block (run on the scheduler thread, as
  `every` tasks are) or `job: "KindOrClassName", args: {}` — then the task
  only enqueues (`Job.enqueue(kind, JSON.generate(args))`), which is what
  Solid Queue's recurring tasks do and what a task with real work should do
  (D28). `job:` is the kind **as a String**, not a class constant: a class
  held in a variable cannot dispatch a class method under Spinel, while a
  String kind is checked against the registry at boot (an unknown one is a
  boot error naming the registered kinds).
- `every(seconds, name)` stays, and gains the persistence below.

### 5.2 The persisted timetable

- Table `cybertrain_schedules (name TEXT PRIMARY KEY, last_run_at INTEGER,
  next_run_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)`, created on
  first use and left out of `db/schema.rb` like `cybertrain_jobs`.
- The leader (D39's lease holder) reads the rows at start and writes
  `next_run_at` whenever it schedules a task and `last_run_at` when it runs
  one; a non-leader that takes over continues from the table, so a leader
  change or a restart no longer resets an `every` interval or runs every
  overdue task at once (the phase 1 judgement call is replaced by the
  persisted timetable). An `every` task whose `next_run_at` passed while no
  process ran executes once at start, as it would have; a `cron` task whose
  slot passed does **not** (cron's and Solid Queue's rule) unless
  `catch_up: true`, in which case it runs once at start and then continues
  on its schedule. When a process takes the lease over from another (or
  regains it after a tick in which it could not acquire it), it reloads
  the table first; a `cron` task whose row says its slot passed while no
  leader ran it runs that one slot once, whatever `catch_up` says, because
  processes were up and the table recorded the slot as due — only the
  "nothing ran" gap of a cold start is skipped. A task name that
  disappears from the registration keeps its row until
  `Scheduler.prune_schedules` (called at start) removes names that are no
  longer registered.
- `Scheduler.run_due(now)` keeps its test entry point; `Scheduler.task_summary`
  lists cron tasks with their next run in UTC.

## 6. The jobs page and the `jobs` command (J-5)

- Routes: `jobs_page "/admin/jobs", before_action: :require_admin` (any
  path; the `before_action:` Symbol is optional). The generator emits
  `CybertrainJobsController < ApplicationController` into
  `gen/controllers.rb` with that `before_action` line and six actions:
  `index` (GET path), `retry` (POST path/:id/retry), `discard` (POST
  path/:id/discard), `delete` (POST path/:id/delete), `retry_all` (POST
  path/retry_all, every `failed` row), and `discard_all_failed` (POST
  path/discard_all). Inheriting `ApplicationController` means the
  application's authentication helpers, layout and CSRF protection apply as
  they do to every other controller; the forms are `button_to` with the CSRF
  token. Without `before_action:` the page is open, and the generator prints
  a warning line saying so.
- Content: counts per state; the `failed` and `discarded` rows (kind,
  arguments, error, attempts, times) with retry / discard / delete buttons;
  the `running` rows (kind, claimed_by, heartbeat age); the `queued` count
  and the next due time; `Config#jobs_page_per_page` (50) rows per list with
  `page` pagination (D23). The HTML is built with the `tag` builder (D38) in
  `Cybertrain::JobsPage`, in the application's layout; no template file
  ships with the framework and nothing is written into the application's
  `app/views`.
- Retrying sets `state = 'queued', run_at = now, attempts = 0` (`attempts`
  reset so the retry policy starts afresh, as Mission Control does);
  discarding sets `discarded`; deleting removes the row. Every action is
  `WHERE id = ? AND state IN ('failed', 'discarded')` so a row a worker just
  claimed is left alone, and redirects back with a flash.
- CLI: `./<app> jobs list [STATE]` (a table of rows, `failed` by default),
  `jobs retry ID | --all`, `jobs discard ID`, `jobs delete ID`, `jobs prune
  [--before DAYS]` (`Job.prune_finished`), joining `migrate`, `db`,
  `console` as a built-in word of `Main` (D39's list). It connects to the
  database and exits; no threads start.

## 7. The cache store (K-1, K-2)

```ruby
text = Cybertrain::Cache.fetch("defillama/tvl", expires_in: 21_600, race_condition_ttl: 30) do
  client.get("https://api.llama.fi/tvl").body
end
data = Cybertrain::Cache.fetch_hash("prices/#{sym}", expires_in: 60) { { "usd" => price } }
Cybertrain::Cache.write("import-lock", "1", expires_in: 300, unless_exist: true) # true when written
```

- Storage: `cybertrain_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL,
  expires_at INTEGER, updated_at INTEGER NOT NULL)` in the application
  database, created on first use, left out of `db/schema.rb`. Writes share
  the application's SQLite writer lock (the guide says so and recommends
  caching in the jobs that produce the data, not in request paths that
  write often). A separate database file (survey D-9) and a size cap are
  not in phase 3.
- API: `fetch(key, expires_in: nil, race_condition_ttl: 0) { String }`,
  `read(key) -> String | nil`, `write(key, value, expires_in: nil,
  unless_exist: false) -> Boolean` (false only when `unless_exist` found a
  live row), `delete(key) -> Boolean`, `exist?(key)`, `increment(key, by: 1,
  expires_in: nil) -> Integer` (one `INSERT … ON CONFLICT DO UPDATE SET value
  = CAST(value AS INTEGER) + ?`), `clear`. Values are Strings (Spinel has no
  Marshal, and `fetch` must answer one type); `fetch_hash`, `fetch_array` and
  `fetch_int` store JSON / Integer text and parse on read with `Cast`, so a
  corrupt cell reads as `{}` / `[]` / `0` and is recomputed on the next
  miss. `expires_in: nil` never expires.
- `race_condition_ttl: n`: when a row is expired and the caller has a block,
  `UPDATE cybertrain_cache SET expires_at = ? WHERE key = ? AND expires_at <
  ?` extends the stale row by `n` seconds; the caller whose UPDATE changed a
  row recomputes and writes, the others read the stale value for those `n`
  seconds (Rails' semantics). Without it every caller of an expired key
  recomputes.
- Pruning: the scheduler registers the built-in task `"cybertrain cache
  prune"` (every `Config#cache_prune_interval`, 300 s) when `cybertrain/cache`
  is required; it deletes rows with `expires_at < now` in batches of 1000.
  `Cache.prune(now)` is the test entry point. Nothing is cached in memory:
  every read is a SELECT, which SQLite answers from its page cache.

## 8. The HTTP client (H-1, H-2, H-4, H-5)

- **gzip** (H-2): when `cybertrain/http/gzip_ffi` is required (the same
  opt-in as `net/tls`: it links zlib), the client sends `Accept-Encoding:
  gzip` and inflates a `Content-Encoding: gzip` body through
  `GzipFFI.gunzip` with `max_body` as the inflated limit. `HttpClient.gzip=`
  is the substitution point the gzip file sets; without it nothing changes.
  A streamed response (next item) is inflated chunk by chunk through the
  bounded inflater; `Content-Encoding` other than `gzip` or identity is a
  `BadResponseError`.
- **Streamed and large responses** (H-1): `get(url, headers:) { |chunk| }`
  (and `request(verb, …) { |chunk| }`) yields each body chunk as it arrives
  (chunked or by length) and returns the `Response` with an empty body;
  `max_body` does not apply to the streamed form, the `deadline` still does.
  `get_to_file(url, path, headers:)` streams into `path` (written to
  `path.part` and renamed) and returns the Response with `body` empty and
  `bytes_written`. A 78 MB body therefore never sits in memory.
- **Server-Sent Events** (H-5): `Cybertrain::Sse::Parser.new.feed(chunk) {
  |event| }` turns the chunks of a streamed `text/event-stream` response
  into `Sse::Event`s (`event_name`, `data`, `event_id`, `retry_ms`), with the
  spec's line rules (CR / LF / CRLF, `data:` joining with LF, comments
  ignored). It is a pure parser with its own tests; the client knows nothing
  of it. The request's `deadline:` must cover the whole stream (the guide
  shows `deadline: 180` for an AI endpoint).
- **Redirects** (H-4): `HttpClient.new(redirects: 3)` follows up to that
  many `301 / 302 / 303 / 307 / 308` with a `Location`, re-running the
  private-address check on every hop, refusing a hop from https to http
  (`BlockedAddressError`), turning `303` (and `301` / `302` of a POST) into
  a GET without a body, and raising `TooManyRedirectsError` past the limit.
  The default stays `0`: a 3xx is returned as today.
- **Verbs**: `request(verb, url, body: "", content_type: "", headers:)` adds
  PUT, PATCH and DELETE (`HEAD` too; its response has no body); `get` and
  `post` stay as the common forms. `Response#json_hash` and `#json_array`
  parse the body through `Cast.json_hash` / `Cast.array`, so a non-JSON body
  answers `{}` / `[]`.
- Unchanged: one connection per request, no proxy, no cookies, no HTTP/2;
  every wait bounded; errors name host and port only.

## 9. Feed timers and restarts (P-3, P-4)

- `on_tick(seconds) { |conn| … }` on a `WebSocket::Subscription` (beside
  `on_open` and `on_message`): the block runs on the feed's own thread
  between `receive(1)` calls, every `seconds` (an Integer, at least 1; the
  granularity is the one-second receive timeout), whether or not the feed is
  connected (`conn` is `nil` while disconnected — the Connection parameter
  is nullable, so the block tests it). An exception is logged and the loop
  continues, as for `on_message`. One `on_tick` per subscription; fin_dash's
  "save every second, close the minute candle" lives here, on the thread that
  owns the feed's buffers, with no lock and no scheduler task.
- Supervision: `Background` starts one supervisor thread per process that
  runs feeds (`Background.supervise!`, spawned through a method, rule 21). It
  checks every second that each subscription's thread is alive
  (`Thread#alive?`, spiked); a thread that ended — the loop raised past its
  rescues, or Spinel killed it — is started again after `min(30, 2 **
  restarts)` seconds, with a `[WARN]` line, and `feed_status(name)` gains
  `restarts` and `thread_alive?`. `stop!` stops the supervisor before the
  feeds so a stopping feed is not restarted.
- Health across roles: a `feeds` process serves no HTTP (D39), so its status
  is **published through the database**. Every process that runs feeds
  writes one row per subscription into `cybertrain_feeds (name TEXT PRIMARY
  KEY, process TEXT, connected INTEGER, started_at INTEGER NOT NULL,
  last_activity_at INTEGER, restarts INTEGER, updated_at INTEGER NOT NULL)`
  every `Config#feed_status_interval` (10 s) from the supervisor thread
  (created on first use, left out of `db/schema.rb`, as the leases table).
  `last_activity_at` is the epoch of the last message **or the last pong
  answered to the client's ping** (a quiet but live feed keeps it fresh; the
  subscription already pings after `ping_interval`), NULL until the first;
  `started_at` is when this process started the subscription. `GET /up` in a
  `server` process reads the table when `Config#health_feeds` is on and
  answers `503 feed stale` when **either** condition holds for a row:
  (a) the publisher is stale — `updated_at` older than
  `Config#health_feed_stale` (180 s): the feeds process stopped publishing
  (died, hung, or its database connection is gone); (b) the feed is silent —
  `COALESCE(last_activity_at, started_at)` older than `health_feed_stale`
  while `updated_at` is fresh: the process is alive but the feed has neither
  delivered a message nor answered a ping for that long, that is, beyond its
  `stale_after` plus a reconnect cycle. The two are checked independently,
  so a live publisher never masks a silent feed. `./<app> feeds status`
  prints the table for an operator; `CYBERTRAIN_HEALTH_FEEDS=0` turns the
  `/up` check off (a feed that is legitimately quiet for longer than the
  threshold).
- Restarting the process: `/up` alone restarts nothing in a feeds container
  (Kamal 2 polls the health endpoint only during a deploy and only for the
  proxied web role; Docker's restart policy acts when the process exits).
  So the supervisor is the first line and **exit is the second**: when one
  subscription's thread has died `Config#feed_restart_limit` (10) times
  within `Config#feed_restart_window` (600 s), the supervisor logs `[FATAL]
  feed NAME restarted 10 times in 600 s; exiting` and the process exits with
  status 1 after `WebSocket.stop!`, so Docker's `restart: unless-stopped`
  (which `cybertrain new` writes into `config/deploy.yml` for the `feeds`
  and `worker` roles, and docs/deploy.md's systemd unit already has as
  `Restart=always`) starts a fresh container. A `server` process that runs
  feeds does not exit (it serves requests); there the supervisor keeps
  retrying with the 30 s cap and `/up` reports `feed stale`.

## 10. Mail (ML-1, phase 1's deferral)

- `Mailer.deliver(to:, subject:, body:, html: "", from:)`: with `html:` the
  message is `multipart/alternative` (the text part first, then the HTML
  part, both `text/*; charset=UTF-8` with `Content-Transfer-Encoding: base64`
  so no line-length or dot-stuffing rule bites), with a random boundary from
  `Crypto.random_token`. Without `html:` the message is the plain text of
  today. `Mailer::Message.build(...)` is the pure function the SMTP receiver
  test parses back.
- The HTML comes from a partial: `Views.render_partial("mail/welcome", user:
  user)` (D38). If `app/views/layouts/mail.html.erb` exists,
  `Views.render_mail("mail/welcome", locals)` wraps the partial in it;
  without the layout it is the partial alone. A plain-text part can be a
  partial too (`mail/welcome.text.erb` is not special: it is a template the
  application renders itself).
- `Mailer.deliver_later(to:, subject:, body:, html: "", from:)` enqueues the
  built-in job kind `"cybertrain mail"` with the finished message as the
  payload (`{"to", "subject", "body", "html", "from"}`), registered when
  `cybertrain/mailer` is required: `retry_on Mailer::TimeoutError,
  Mailer::ConnectError` with `wait: 60, attempts: 5`, `discard_on
  Mailer::RejectedError` (a refused address will not become deliverable),
  everything else the default policy. The body is rendered at enqueue time,
  not in the job, so the job needs no view context and the payload is
  inspectable on the jobs page. Parameterised mailer classes
  (`UserMailer.welcome(user).deliver_later`) are not built: a mail is a
  method on the application's side that calls `deliver` or `deliver_later`.
- Attachments and inline images stay out.

## 11. Test helpers (J-8)

`cybertrain/test/jobs.rb` (required by the application's test support file
when it uses jobs, as `test/client` is):

- `assert_enqueued_jobs(count, kind = "")`: the number of `queued` rows (of
  that kind when given).
- `assert_enqueued_with(kind, args = {})`: at least one `queued` row of that
  kind whose parsed args contain every given key with an equal value
  (`Cast.str` comparison of both sides, so `"user_id" => 1` matches a JSON
  1).
- `assert_no_enqueued_jobs(kind = "")`.
- `perform_enqueued_jobs(now = Time.now) -> Integer`: runs every due row on
  the calling thread through `Job.work_one(now)` until none is due; returns
  the count. Retries scheduled into the future are not run (pass a later
  `now` to run them).
- `clear_enqueued_jobs`: deletes every `queued` row.
- `WelcomeJob.perform_now(args)` runs the job directly (section 2.1).
- The scheduler keeps `Scheduler.run_due(now)`; the cache has `Cache.prune`;
  mail keeps the SMTP receiver; the HTTP client keeps the HTTP receiver,
  which gains gzip, chunked and redirect responses for the new tests.

## 12. Configuration added

| Variable | `Config` field | Default | Meaning |
| --- | --- | --- | --- |
| `CYBERTRAIN_CACHE_PRUNE_INTERVAL` | `cache_prune_interval` | `300` | seconds between prunes of expired cache rows |
| `CYBERTRAIN_JOBS_PAGE_PER_PAGE` | `jobs_page_per_page` | `50` | rows per list on the jobs page |
| `CYBERTRAIN_HEALTH_FEEDS` | `health_feeds` | `true` | whether `/up` reports a stale feed |
| `CYBERTRAIN_HEALTH_FEED_STALE` | `health_feed_stale` | `180` | seconds of feed silence (or of a feeds process not publishing) before `503 feed stale` |
| `CYBERTRAIN_FEED_STATUS_INTERVAL` | `feed_status_interval` | `10` | seconds between writes of a feed's status row |
| `CYBERTRAIN_FEED_RESTART_LIMIT` | `feed_restart_limit` | `10` | feed thread deaths within the window before a `feeds` process exits |
| `CYBERTRAIN_FEED_RESTART_WINDOW` | `feed_restart_window` | `600` | the window, in seconds |
| `CYBERTRAIN_SCHEDULER_TZ` | `scheduler_tz` | `"UTC"` | the default `tz:` of `cron` tasks |

Each is validated at boot with the existing `scheduler_error` /
`health_error` checks (at least 1; a `scheduler_tz` that `TimeZone` cannot
load is a boot error). No new secret.

## 13. Documentation and design.md changes

- design.md: D51 job classes, retry policies, concurrency keys and the
  `Run`-taking registration; D52 cron schedules and the persisted timetable;
  D53 the jobs page and the `jobs` command; D54 the cache store; D55 the
  HTTP client's streaming, gzip, redirects and SSE; D56 feed timers,
  supervision and the feed health check; D57 HTML mail and `deliver_later`;
  D28's "Later" list and D33's "Deferred" list shrink; section 1's programme
  paragraph marks phase 3 delivered; section 13 gets the dated entry.
- docs/guide/background-and-operations.md: "Jobs" rewritten around job
  classes (with `Job.handle` kept as the short form), retry, concurrency,
  cron, the jobs page, the `jobs` command, the test helpers;
  docs/guide/external-services.md: streaming, gzip, redirects, SSE, feed
  timers and supervision, HTML mail and `deliver_later`;
  docs/guide/testing.md: the job helpers; docs/guide/configuration.md: the
  five variables; docs/guide/realtime.md: the feed health check. Each with
  its fr / ja / ru / zh translation and `script/check-guide-i18n
  --update-sha`. docs/deploy.md and deploy.en.md: the `jobs` command in the
  operations list and `health_feeds` for feed containers.
- README's feature list; `cybertrain new` writes `app/jobs/.keep`, a
  commented `jobs_page` line in `config/routes.rb` and a commented `cron`
  example in `config/app.rb`; the generated test support file requires
  `cybertrain/test/jobs`.
- spikes/NOTES.md: rules found during the spike (section 14), numbered after
  the current last rule. docs/spinel-feedback.md: a row if the spike finds a
  Spinel limit.
- This spec gets "## 18. Implementation notes" after implementation, as
  phases 1 and 2 did.

## 14. Spinel constraints that shape the implementation, and the spike

Constraints applied above:

- No computed send / `constantize` (rule 1): the job registry is a `case`
  table generated from a lexical scan; `job:` in `cron` is a String kind
  checked at boot.
- One return type per name (10 / 34 / 41): `fetch` answers String and
  `fetch_hash` / `fetch_array` / `fetch_int` are separate names; `Run`'s
  readers are prefixed (`run_id`, `run_args`); the supervisor's and the
  page's new methods are checked against the program (`status`, `restart`,
  `alive?` are avoided or prefixed).
- No stored block run through a base receiver (88): the retry policy is
  literal `rescue` arms in generated code; `retries_exhausted` is an
  instance method; `on_tick` is stored on the Subscription and run from the
  WebSocket module, which already does so for `on_message`.
- Threads started through a method (21); rescue in a non-yielding method
  (32 / 45); messages built into a local before `raise` (58); seeded
  containers (9 / 46); nullable `conn` in `on_tick` (7).
- openssl and zlib stay opt-in (D33, phase 2's D49): gzip support is active
  only when `cybertrain/http/gzip_ffi` is required.
- Names this phase adds that already exist on another receiver, checked
  against the program on 2026-11-07: `read` / `write` / `delete`
  (`BlobStore`, `Session#delete`, the routes DSL, the test client,
  `BodyWriter#write`), `clear` (`Session`, `Errors`), `perform`
  (`Mailer#perform`, `HttpClient#perform`), `register` (`Migration`,
  `RateLimit`, `Background`, `Test`), `prune` (`Stream.prune`),
  `increment` (`Relation#increment`, Integer as here), `request` and
  `json_hash` (same return types as here). Rails' spellings are kept for
  the cache (`Cache.read` / `write` / `delete` / `clear`) and for `perform`
  under the distinct-receiver precedent (`Column#limit` / `Relation#limit`,
  phase 2); spike item 6 compiles them together with the whole framework,
  and the fallback is a prefixed name (`cache_read`, `perform_job`) for any
  pair Spinel refuses. `fetch`, `feed`, `cron`, `run_job`, `job_kind`,
  `perform_later` / `perform_at` / `perform_in` / `perform_now`, `on_tick`,
  `supervise!`, `restarts`, `thread_alive?` are new names.

The spike (the plan's first task) checks on Spinel 2026.11.04.7026:

1. `Cron.next_after` over a DST transition with `TimeZone` (Europe/London
   and Asia/Tokyo), compiled.
2. A generated `run_job` with `rescue AppError => e` arms where `AppError` is
   defined in the application file and a subclass is raised; the arm order
   and `raise` of a framework control exception from inside a `rescue`.
3. `Thread#alive?` on a finished thread and spawning its replacement from
   another thread, in a program that also runs the WebSocket client.
4. The HTTP client program with `GzipFFI` linked: the NOTES 62 C grep for a
   boxed `getbyte` / `each_byte` dispatch, since the client scans headers
   byte by byte.
5. A `multipart/alternative` message with a UTF-8 body, base64 parts,
   through the SMTP receiver, parsed back.
6. One program that requires the whole framework plus `cybertrain/cache`,
   `cybertrain/sse`, the jobs page and a generated `gen/jobs.rb` with two
   job classes, compiled: the name pairs listed above resolve, and
   `script/check-reserved-names` sees the new names.

Each has a fallback: (1) a UTC-only `cron` with `tz:` refused at boot; (2)
`retry_on` arms for framework exception classes plus `StandardError` only,
with application classes matched by walking `e.class.ancestors` names
against the declared names in declaration order (so a subclass still meets
its parent's policy; `Class#ancestors` is checked in the same spike, and if
it is unavailable too, application classes are refused by the generator with
a message naming the limit); (3) no supervisor thread: a feed loop that
dies logs `[FATAL]` and the process exits with status 1 so Docker's restart
policy starts a fresh container (the exit rule above, applied at the first
death; a `server` process that runs feeds logs and keeps serving, and the
guide tells such deployments to use the `feeds` role); (4) gzip left out of
phase 3 and recorded; (5) a single-part HTML message (`text/html` only, with
`text:` dropped); (6) the prefixed names above.

**Results (2026-11-09, Spinel 2026.11.04.7026, programs kept in
spikes/phase3/ with their output in each header, rule 89 recorded in
spikes/NOTES.md):**

1. Cron over DST: passes, compiled and under CRuby alike
   (cron_dst.rb). Stepping the zone's wall clock a minute at a time and
   converting each matching minute back with `local_to_utc`, keeping it
   only when `utc_to_local` reads the same wall minute and it is after the
   last run: `30 1 * * *` in Europe/London after 2026-03-28 23:00 UTC skips
   the missing 01:30 of the 29th and runs 2026-03-30 00:30 UTC; on
   2026-10-25 it runs once, at the first 01:30 (00:30 UTC, BST), and next
   on the 26th at 01:30 UTC; Asia/Tokyo gives 2026-03-29 16:30 UTC. For
   `30 * * * *` across the fold the spike's "wall minute runs once" rule
   skipped the second 01:30 (00:30 then 02:30 UTC), a two-hour gap in real
   time. The implementation (Task 2) does not keep that reading: it follows
   Vixie cron, as section 5.1 now says — a wildcard-hour expression runs at
   both occurrences (00:30 and 01:30 UTC, pinned by test/cron.rb), a
   fixed-hour one once.
2. Rescue arms for application classes: passes (rescue_arms.rb, with
   `require "cybertrain"`). `rescue Sub` before `rescue AppError` catches
   a `Sub` and a grandchild in the first arm and an `AppError` in the
   second; parent first catches both in the first; a framework exception
   arm and `ArgumentError` beside them match; an unmatched class reaches
   the caller; `raise Cybertrain::RecordNotFound` from inside an arm
   reaches the caller's `rescue`; `e.class.ancestors` lists `Leaf Sub
   AppError StandardError Exception Object Kernel BasicObject` (the
   fallback's `Class#ancestors` is available, not needed). Found on the
   way (**rule 89**, docs/spinel-feedback.md R): an arm naming a qualified
   class the program does not define does not raise NameError; it matches
   by its last segment or, when a middle segment is missing and a class of
   the last segment's name exists elsewhere, turns the whole
   `begin`/`rescue` into a silent catch-all. `require "cybertrain"` does
   not load cybertrain/mailer, so `retry_on Cybertrain::Mailer::TimeoutError`
   in an application that never requires it would swallow every error of
   that job. So the job generator (section 2.2) must check every
   `retry_on` / `discard_on` class against the classes the scan found and
   the framework classes of files the application requires, and stop with
   a one-line message otherwise.
3. Thread respawn: passes, compiled and under CRuby alike
   (thread_respawn.rb, with a WebSocket feed connected to the test
   receiver and receiving meanwhile). A thread that raised reads
   `alive? == false` from another thread; the replacement started from a
   supervisor thread through a method runs to the end; `join` on the dead
   thread re-raises its exception; the feed thread reads `alive?` true
   while running and false after `WebSocket.stop!`. Spinel prints the
   thread's exception on stderr as CRuby does (`report_on_exception`).
4. HTTP client with GzipFFI and the TLS layer: passes (gzip_client.rb).
   The generated C has no `sp_raise_nomethod(sp_nomethod_msg("getbyte"` or
   `("each_byte"` (nor any `byte…` name); a control program with a
   user-defined `getbyte` and a boxed String receiver has none either and
   prints 97: on this build the grep is silent for the control too, so it
   is a regression check against rule 62 coming back, not a live detector
   of it. A gzip body served plain
   and chunked by `Test::HttpReceiver` comes through `HttpClient#get` and
   inflates with `GzipFFI.gunzip`; garbage and an over-limit body raise
   `BodyUndecodable` / `BodyTooLarge`.
5. `multipart/alternative` mail: passes, compiled and under CRuby alike
   (multipart.rb). A message with an encoded-word subject, a boundary,
   and `text/plain` / `text/html` parts in base64 (`Mailer.base64_lines`,
   `Mailer.dot_stuff`) goes through `Test::SmtpReceiver`;
   `message_header("Content-Type")` gives the boundary back and both parts
   decode (`unpack1("m")` and `Base64.decode64`) to the same UTF-8 text.
6. Name pairs: passes (names.rb). With the whole framework, the
   application stack, the mailer, the HTTP client and the receivers in one
   program, stand-ins with the spec's names and return types compile and
   run beside the existing definitions, each of which the program also
   reaches: `Cache.read` (String or nil) / `write` (Boolean) / `delete` /
   `exist?` / `clear` / `increment` / `prune` / `fetch` / `fetch_hash` over
   `cybertrain_cache` next to `BlobStore`, `Session#delete` / `#clear`,
   `Errors#clear`, `Stream.prune` and `Test::Client#delete` / `#request`;
   `Job::Base#perform(args)` next to `Mailer#perform` and
   `HttpClient#perform`; `Job.register` next to the four other
   `register`s; `HttpClient#request` (an `HttpClient::Response`) next to
   `Test::Client#request` (its own Response class); `Response#json_hash`
   next to `Cast.json_hash`; `Sse::Event#data` and `#event_id` (Strings)
   next to `Test::Upload#data` and `Stream::Endpoint.event_id` (an
   Integer). No prefixed fallback is needed. `script/check-reserved-names`
   guards Model, Controller and the helper names; it has nothing to see
   until the job and cache files exist and runs in the gate from then on.

No fallback is taken. Rule 89 adds that one check to the job generator
and nothing else; `Relation#increment` was compiled beside `Cache.increment`
but not reached (that needs a model and its table).

## 15. Out of scope for phase 3 (recorded so nothing is lost)

fin_dash's AI job base (J-6: `perform_later` overrides and batch rows are
application code over the job classes); HTML and XML parsing (H-3; Spinel's
`rexml` package is available to applications); YAML configuration (H-6);
a zlib wrapper beyond `GzipFFI` (H-7); heavy computation in another process
(P-5: `SPINEL_WORKERS` and the `worker` role cover it); error reporting and
log tags (O-2, O-3: phase 5); static analysis and cross-building (O-4, O-5);
job priority, queue names and queue-level uniqueness (`unique_by`); a cache
in a separate database file and a cache size cap; keep-alive, proxies,
cookies, HTTP/2, `permessage-deflate`; mail attachments, inline images and
parameterised mailer classes; an inline job mode for tests; adding
subscriptions while running and sending to a feed from outside its
callbacks; command namespaces and `[key]` arguments for `Main.command`
(CF-2); encrypted credentials files (CF-1: `encrypts` and the environment
cover the cases).

## 16. Compatibility changes for applications on 0.4

1. `cybertrain_jobs` gains the column `concurrency_key` and the state
   `discarded`; `install!` upgrades an existing table in place. Code that
   enumerates states (a dashboard over `Job.state_count`) adds `discarded`.
2. `Scheduler.every` tasks now continue from the persisted timetable after a
   restart instead of starting afresh; an interval that passed while the
   process was down runs once at start. `cybertrain_schedules` appears in
   the database.
3. `Job.handle` blocks are unchanged. The default retry policy is unchanged.
4. `WebSocket.feed_status` gains `restarts` and `thread_alive?`; a dead feed
   thread is restarted automatically; a `feeds` process exits with status 1
   after repeated deaths of one feed (run it under a restart policy, as the
   generated `config/deploy.yml` now does); `/up` in a `server` may answer
   `503 feed stale` from the new `cybertrain_feeds` table
   (`CYBERTRAIN_HEALTH_FEEDS=0` restores the old behaviour).
9. Upgrading a running deployment with keyed jobs: stop every old process
   before the first new one starts (D39's rule); the first `Job.start!`
   backfills `concurrency_key` for `queued` rows of keyed kinds.
5. `Mailer.deliver` gains `html:` (optional; existing calls unchanged).
6. `HttpClient` gains `redirects:`, `request`, `get_to_file` and the block
   form; existing calls unchanged. With `cybertrain/http/gzip_ffi` required,
   requests send `Accept-Encoding: gzip`.
7. The routes DSL gains `jobs_page`; `Main` gains the built-in word `jobs`
   (an application command named `jobs` must be renamed).
8. `Job.prune_done` stays; `Job.prune_finished` also removes `failed` and
   `discarded`.

## 17. Acceptance

1. Every job class in `app/jobs` is registered by `gen/jobs.rb`;
   `perform_later` / `perform_at` / `perform_in` / `perform_now` compile and
   run on the fixture app; a misspelled macro stops generation with a
   one-line message.
2. `retry_on` with an Integer wait and with `:polynomially_longer`,
   `discard_on`, `retries_exhausted` (run only after a successful fenced
   write; not run for a stale attempt whose row was reclaimed), the default
   policy and the fence are covered in compiled tests on a temporary
   database; `limits_concurrency` with a key keeps two rows of the same key
   from running at once across two `claimed_by` labels; a `queued` row
   enqueued without a key is backfilled at `Job.start!`; a `running` row
   with `""` whose heartbeat goes stale after the new worker started is
   requeued with its key set in the same statement (an old worker's row
   simulated by a fresh then aged heartbeat); the key an enqueue, a
   backfill and a recovery derive is identical for a String, an Integer, a
   Float and a boolean field (`true` → `"true"`), and a payload without the
   field or a legacy non-JSON payload is keyed `""` and listed at warn, not
   raised; a stale row of a kind with `attempts: 20` recovered on attempt 5
   is requeued, not failed.
3. `Cron.next_after` is tested over DST transitions in two zones; a cron
   task runs at its minute and not before; the timetable survives a
   simulated restart (`Scheduler.start!` twice on one database); `catch_up`
   runs once at start; a `job:` task enqueues and does not run the job on
   the scheduler thread.
4. The jobs page lists, retries, discards and deletes through the test
   client with the application's `before_action` applied; the `jobs`
   command's output is snapshot-tested.
5. The cache's `fetch`, expiry, `race_condition_ttl` (two callers, one
   recomputes), `unless_exist`, `increment`, `fetch_hash` and `prune` are
   tested on a temporary database.
6. The HTTP client streams a chunked 3 MB body in parts with `max_body` 1 MiB,
   writes `get_to_file`, inflates a gzip body (with `gzip_ffi` required),
   follows two redirects and refuses an https→http hop, raises past the
   limit, sends PUT / PATCH / DELETE; `Sse::Parser` passes the spec's line
   cases.
7. `on_tick` fires while disconnected and connected; a feed thread that
   raises past its rescues is restarted by the supervisor within the backoff
   and `restarts` counts it; the status row is written (a pong refreshes
   `last_activity_at`) and `./<app> feeds status` prints it; a `server`
   process's `/up` answers `503 feed stale` for a feeds process that
   stopped publishing (an old `updated_at`), `503 feed stale` for a silent
   feed under a live publisher (a fresh `updated_at`, an old
   `last_activity_at`), `503` for a feed that never received anything past
   the threshold (NULL `last_activity_at`, an old `started_at`), `200` for a
   fresh row, and `200` with `CYBERTRAIN_HEALTH_FEEDS=0`; a feeds
   process whose feed dies past `feed_restart_limit` within the window exits
   with status 1 (tested as a child process, the boot_encryption pattern).
8. `deliver(html:)` produces a `multipart/alternative` message the SMTP
   receiver parses back to the same text and HTML; `deliver_later` enqueues
   `"cybertrain mail"` and `perform_enqueued_jobs` delivers it; a
   `RejectedError` discards.
9. The five test helpers are exercised in `test/job_helpers.rb`.
10. `spin test` and `cd examples/blog && spin test` pass; the blog posts a
    comment that enqueues `NotifyCommentJob`, has a `cron` task, mounts the
    jobs page and caches the article count for 60 seconds; `cybertrain new`'s
    output includes `app/jobs/` and the commented lines; the guides, their
    four translations, design.md D51–D57 and the deploy notes are updated and
    `script/gate` passes.
