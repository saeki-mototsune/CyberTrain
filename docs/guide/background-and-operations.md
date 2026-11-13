# Background work and operations

## Background work

An application that has to do something outside a request (send a
notification after the response went out, sweep old rows every night, retry
a call that failed) hands it to the framework, which runs it on background
threads of the served process, or of a separate worker process. A job is a
class in `app/jobs/`, as in Rails. Jobs and scheduled tasks need
`require "cybertrain/jobs"` in `bin/<app>.rb` and `bin/db.rb`, which
`cybertrain generate job` adds ([Subsystems](how-it-works.md#subsystems)):

```ruby
# app/jobs/welcome_job.rb
class WelcomeJob < Cybertrain::Job::Base
  retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5
  discard_on ArgumentError

  def perform(args)
    user = User.find(Cybertrain::Cast.int(args["user_id"]))
    Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello!\n")
  end
end
```

```ruby
# in an action, after saving the user
WelcomeJob.perform_later("user_id" => @user.id)
WelcomeJob.perform_in(600, "user_id" => @user.id)   # or perform_at(time, args)
```

```ruby
# config/app.rb (or a file bin/<app>.rb requires before Cybertrain::Main.run)
Cybertrain::Scheduler.cron("0 4 * * *", "nightly digest", job: "DigestJob")
Cybertrain::Scheduler.every(300, "refresh rates") { Rates.refresh }
```

- **Where it runs.** Jobs run on `job_threads` job threads (3,
  `CYBERTRAIN_JOB_THREADS`); scheduled tasks run on one scheduler thread of
  their own, so a long job never holds up a task. Both start when the
  binary serves (`./<app>`, `./<app> server`) or runs as a worker
  (`./<app> worker`, see [Process roles](#process-roles)), after boot has
  connected the database and set `SPINEL_WORKERS`; `migrate`, `db ...`,
  `jobs ...`, `console` and `Main.command` commands never start them, and
  neither does `Cybertrain::Test::Client`. With jobs required, the job
  threads start in every such process, even in an application with no job
  class: the framework
  registers its own mail job (`Mailer.deliver_later`,
  [Sending e-mail](external-services.md#sending-e-mail)).
- **The table.** Jobs are rows of `cybertrain_jobs`, which the framework
  creates itself (`CREATE TABLE IF NOT EXISTS`, on first use) and leaves out
  of `db/schema.rb`. Inside a `DB.transaction` the row commits or rolls back
  with the rest. Each job thread claims the oldest due row in a short
  `BEGIN IMMEDIATE` transaction, runs it outside the transaction and looks
  for the next; with nothing due it waits `job_poll_interval` seconds (1),
  so a job enqueued by a request starts within about a second. A row is
  `queued`, `running`, `done`, `failed` (its retries ran out; it stays for
  you to look at) or `discarded` (a `discard_on` stopped it).

### Job classes

`spin run gen` reads every file under `app/jobs/` (nested directories too:
`Admin::ReportJob` in `app/jobs/admin/report_job.rb`) and writes the other
half of each class `Cybertrain::Job::Base` is an ancestor of into
`gen/jobs.rb`: `perform_later`, `perform_at`, `perform_in`, `perform_now`,
`job_kind` and the code that runs it, and registers the class. `cybertrain
generate job send_digest --retry Cybertrain::Mailer::TimeoutError:60:5`
writes a class file and a test for it.

- **`args`** is the Hash given to `perform_later`, stored as JSON and read
  back as a `Hash<String, Object>`: narrow its values with
  `Cybertrain::Cast.int(args["user_id"])`, `Cast.str`, `Cast.hash`,
  `Cast.array`. A job takes this one Hash; pass ids, not records (Rails'
  advice too). `perform_later` raises `ArgumentError` for anything that is
  not a Hash, and with no argument sends `{}`.
- **Enqueueing.** `perform_later(args)`, `perform_at(time, args)` and
  `perform_in(seconds, args)` return the row's id; the row's kind is the
  class name (`"WelcomeJob"`, `"Admin::ReportJob"`).
  `perform_now(args)` runs `perform` on the calling thread, with no queue,
  no retry policy and no rescue, and returns `nil`: a test's shape.
- **The class body.** Every job class defines `perform(args)` (the generator
  refuses one that neither defines nor inherits it). `retry_on`,
  `discard_on` and `limits_concurrency` are read as text, one per line with
  literal values (an Integer or `:polynomially_longer` for `wait:`, an
  Integer for `attempts:` and `to:`, a quoted String for `key:`); a block,
  a lambda, `5.minutes`, a hashrocket or a trailing comment stops `spin run
  gen` with the file, the line and what to write instead.
- **Which exception classes.** A `retry_on` or `discard_on` names a class
  the program defines before the job: a core class (`ArgumentError`,
  `KeyError`, ...), one of the framework's `...Error` classes (the
  generator adds the require it needs), or an application class defined in
  `app/models/`, in `app/jobs/application_job.rb` or above the line in the
  job's own file. Anything else stops `spin run gen`: under Spinel a
  `rescue` naming a class the program does not define can swallow every
  exception (spikes/NOTES.md rule 89).
- **`ApplicationJob`.** A class `ApplicationJob < Cybertrain::Job::Base` in
  `app/jobs/application_job.rb` is not a job of its own: its `retry_on` and
  `discard_on` lines apply to every job inheriting it, after the job's own,
  and its `limits_concurrency` to a job that sets none. Any other job class
  can be a parent; it is then a job in its own right.
- **`Job.handle`, the short form.** A block registered under a String kind
  needs no class and no generator; it gets the payload String and the
  default policy below:

  ```ruby
  # config/app.rb
  Cybertrain::Job.handle("notify", concurrency: 1) { |payload| Notifier.post(payload) }

  # anywhere, later
  Cybertrain::Job.enqueue("notify", JSON.generate({ "text" => "Deployed" }), run_at: Time.now + 60)
  ```

  Job classes and `Job.handle` kinds share one namespace, so
  `Job.enqueue("WelcomeJob", json)` adds the same row as `perform_later`.
  `Job.enqueue` refuses an unregistered kind.

### Retries and discards

- **The default policy.** An exception that no line of the class matches
  (and any exception of a `Job.handle` block) is retried 1, 5, 15 and then 60
  minutes later, with `Class: message` (up to 1000 characters) in
  `last_error`, until `job_max_attempts` (5) attempts have failed; the row is
  then `failed`. A `NotImplementedError` (a helper not written yet), a
  `SystemStackError` or another `ScriptError` from the job's code takes this
  policy too, although none is a `StandardError`; any other exception outside
  `StandardError` is logged (`[ERROR] Job thread N: ...`), the job thread
  carries on, and the row stays `running` until recovery (below) takes it.
- **`retry_on Klass, wait: 60, attempts: 5`.** `wait:` is seconds (3 when
  left out, Rails' default) or `:polynomially_longer` (`attempts ** 4 + 2`
  seconds: 3, 18, 83, 258, ...); `attempts:` (5 when left out) counts every
  attempt, the first included. Several lines may be given: the first whose
  class matches the exception (a subclass matches) wins, so write the
  narrower class first. `retry_on StandardError` before `discard_on
  ArgumentError` retries the `ArgumentError`.
- **`discard_on Klass`** stops at once: the row is `discarded`, with the
  error in `last_error`, and is never retried.
- **`def retries_exhausted(error)`** runs when a `retry_on` line's attempts
  ran out, once the row is really `failed` (never for an attempt another
  worker took over, whose own run may still succeed). It is Rails' `retry_on
  ... do |job, error|` block; an exception it raises is logged.
- **Recovery** (below) follows the class too: a row of a class with
  `attempts: 20` whose process died on attempt 5 is queued again, not
  failed.

### Concurrency per kind and per key

`limits_concurrency to: 1, key: "account_id"` lets at most `to:` jobs of the
class run at once across every process sharing the database, counted per
value of `args["account_id"]` (`to:` alone counts for the whole class;
`Job.handle(kind, concurrency: n)` is the same for a block). Other kinds,
and other keys, go on running meanwhile. Enqueueing a keyed job whose args
lack the key raises `ArgumentError`. The limit counts `running` rows, so it
holds as long as heartbeats do: a job still running after its heartbeat went
stale is overlapped by the recovered row's next run (below); work that must
never overlap needs a guard of its own.

### Scheduled tasks

`Scheduler.every(seconds, name) { ... }` runs a block every `seconds`;
`Scheduler.cron(expr, name, ...)` runs at the minutes a five-field cron
expression matches:

```ruby
Cybertrain::Scheduler.cron("12 * * * *", "collect prices") { Prices.collect }
Cybertrain::Scheduler.cron("0 9 * * 1-5", "morning report", tz: "Asia/Tokyo",
                           job: "MorningReportJob", args: { "scope" => "all" })
Cybertrain::Scheduler.cron("*/5 * * * *", "poll feeds", catch_up: true) { Feeds.poll }
```

- **The expression.** Minute, hour, day of month, month, day of week, with
  `*`, `*/n`, `a-b`, `a,b`, `a-b/n` and the names `jan`-`dec` and
  `sun`-`sat` (day of week `0` and `7` are Sunday); `@hourly` and its kin
  are not accepted. An expression that cannot be parsed, or never matches,
  raises `ArgumentError` naming the task when `config/app.rb` loads, so the
  boot stops.
- **Time zones.** `tz:` names an IANA zone ([Time zones](configuration.md#time-zones));
  without it the task reads `scheduler_tz` (`CYBERTRAIN_SCHEDULER_TZ`,
  `UTC`). A wall time that a daylight-saving jump skips does not run that
  day. In the repeated hour of the autumn change, an expression whose hour
  field starts with `*` runs at both occurrences and one with a fixed hour
  runs once, as Vixie cron does.
- **`job:`** names a job kind (a class name as a String, or a `Job.handle`
  kind) and `args:` its args: the task then only enqueues it, which is what
  a task with real work should do. An unknown kind stops the boot with the
  list of registered ones.
- **The timetable** is kept in the database (`cybertrain_schedules`, out
  of `db/schema.rb`): when each task last ran and runs next. A restart, or
  another process taking the lead, continues from it. An `every` task whose
  time passed while nothing ran runs once at start; a `cron` slot missed
  while nothing ran is skipped (cron's rule) unless the task says `catch_up:
  true`, which runs it once at start. A slot that came due while processes
  were up but no leader ran it (a lease changing hands) runs once on the
  takeover. A task you rename or remove keeps its row until the next start.
  A task that has not run yet follows its current schedule when that comes
  sooner than the next run an earlier release stored (a weekly task made
  hourly before its first run runs within the hour).
- **How a task runs.** A block runs on the scheduler thread, one task at a
  time; each run is wrapped in a rescue that logs `[ERROR] Scheduled task
  "name" failed: ...` and the loop goes on. The block takes no arguments
  (Spinel has no `instance_eval`). A SQLite call holds its OS worker until it
  returns: with `SPINEL_WORKERS=1` (the default) a long query stalls every
  request, and every other thread, for as long. Give a task with real work a
  job (`job:`, or `Job.enqueue` from the block), and batch big work (a
  thousand rows per run, one job per item). `Cybertrain::Scheduler.last_tick`
  is the epoch second of the last tick, for a health check of your own.

### The jobs page and the `jobs` command

```ruby
# config/routes.rb
Cybertrain::Routes.draw do
  jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
end
```

`jobs_page` mounts a page that lists the count of rows per state, the queued
count and the next due time, the `failed` and `discarded` rows (kind,
arguments, error, attempts, times) and the `running` ones (who claimed them,
how old their heartbeat is), `jobs_page_per_page` (50,
`CYBERTRAIN_JOBS_PAGE_PER_PAGE`) rows per list. A failed row can be retried
(queued again at once, attempts reset), discarded or deleted, a discarded
one retried or deleted, and every failed row retried or discarded at once;
each action touches only `failed` and `discarded` rows, so a row a worker
has just claimed is left alone.

- The generated controller inherits `ApplicationController`, so the
  application's layout, helpers and CSRF protection apply, and
  `before_action:` names one of its methods: it must render or redirect to
  refuse. `cybertrain generate authentication` draws the line above, with
  its concern's `require_admin` (404 unless an admin is signed in;
  [Admin users](authentication.md#admin-users-and-the-jobs-page)). Without
  `before_action:` the page is open to every visitor, and `spin run gen`
  prints a warning saying so.
- `skip_before_action:` names one inherited before callback the page does
  not run. With `:require_authentication`, `require_admin` alone answers a
  visitor, with a 404 rather than a redirect to sign in. gen refuses it
  without a `before_action:`, and when it names the `before_action:`
  itself.
- Its buttons are forms with the CSRF token. Keep the page's path out of
  `csrf_exempt_prefixes`: under an exempt prefix those forms would be
  accepted from any site.

From a shell, `./<app> jobs` does the same on the configured database
(it starts no thread):

```sh
./blog jobs list               # failed rows, newest first (the newest 1000); or: list queued|running|done|discarded
./blog jobs retry 42           # or: retry --all (every failed row)
./blog jobs discard 42
./blog jobs delete 42
./blog jobs prune --before 30  # delete failed and discarded rows older than 30 days (7 by default)
```

`done` rows stay until something deletes them: `Job.prune_done(before_epoch)`
from a task (`Cybertrain::Scheduler.cron("0 3 * * *", "prune done jobs") {
Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400) }`).
`Job.state_count("failed")` serves a health page of your own.

### Several workers, at least once, shutting down

- **Several workers per database.** Every process that runs jobs writes a
  heartbeat for the jobs it is running every `job_heartbeat_interval` (30 s).
  A `running` row whose heartbeat is older than `job_heartbeat_stale` (a
  process that crashed or was stopped mid-job) is queued again by whichever
  process looks next, at its start and then once a minute, unless that
  attempt was its last (the larger of `job_max_attempts` and the class's
  largest `attempts:`):
  then the row is left `failed`, with `process stopped (heartbeat stale)` in
  `last_error`, so a job that kills its process is not retried for ever.
  Scheduled tasks run in one process at a time: the processes share a lease
  in the database (`cybertrain_leases`, renewed every tick,
  `scheduler_lease_ttl` 30 s), and only its holder runs due tasks; another
  takes over when it stops renewing. The lease is renewed before each task,
  not while one runs, so a task longer than the ttl can overlap with the
  next holder's: keep tasks short and safe to repeat. So two `worker`
  processes, or a server and a worker, can share one SQLite file;
  `CYBERTRAIN_WORKER=0` turns jobs, tasks and feeds off in a `server` process
  that should only serve HTTP.
- **At least once.** A job can run twice: a process that is killed, or that
  stalls for longer than `job_heartbeat_stale` (300 s), may still be running
  a job when another process takes the row back. Only the outcome of the
  claim that holds the row counts (an earlier claimer's result, finishing
  late, is discarded), but the job's side effects happened twice, so write
  jobs that can safely run again (check whether the mail was already sent,
  upsert rather than insert), as with any job queue. A scheduled task can
  run twice around a change of leader for the same reason.
- **Shutting down.** On `SIGTERM` the job threads stop claiming new jobs, and
  the process waits up to `job_drain_timeout` (10 s) for the jobs in flight.
  A job still running then keeps its row `running`; its heartbeat has
  stopped, so another process runs it again once it is stale.
- **Testing.** `WelcomeJob.perform_now(args)` runs a job,
  `Cybertrain::Scheduler.run_due(now)` runs one tick and
  `Cybertrain::Job.work_one(now)` one queued job, with an epoch time you
  choose, so a test never sleeps; [Testing jobs](testing.md#testing-jobs)
  has the assertions.

### Upgrading from 0.4

- `cybertrain_jobs` gains the column `concurrency_key` and the state
  `discarded`; the first process that touches the table adds the column.
  Code that lists states (a dashboard over `Job.state_count`) adds
  `discarded`. `Job.prune_done` still prunes `done` rows only.
- `every` tasks continue from the timetable after a restart instead of
  starting afresh: an interval that passed while the process was down runs
  once at start.
- Giving an existing kind a key (`limits_concurrency ... key:`): stop every
  old process before the first new one starts, as for any upgrade
  ([Process roles](#process-roles)). The first new process keys the `queued`
  rows enqueued before (it logs the ids of rows whose payload has no such
  field), and a `running` row left by an old process gets its key when it is
  recovered.
- `jobs` is now a built-in command: an application command named `jobs`
  must be renamed.

Not built: job priority, queue names and uniqueness, an inline job mode for
tests (`perform_now` and `perform_enqueued_jobs` cover tests). The design:
`docs/design.md` D28 and D51 to D53.

## Process roles

One binary runs in three roles. By default `./<app> server` does everything,
as `rails server` with Solid Queue inside Puma does; the other two let a
deployment split the work across processes or containers, all from the same
image and the same database:

| Command | Runs | Listens |
| --- | --- | --- |
| `./<app> server [PORT]` | HTTP, the [stream endpoint](realtime.md#which-process-does-what), and unless `CYBERTRAIN_WORKER=0` the scheduled tasks, the job threads and the WebSocket feeds | yes |
| `./<app> worker` | the scheduled tasks (one process at a time, through the lease), the job threads, heartbeats and recovery | no |
| `./<app> feeds [NAME...]` | the [WebSocket feeds](external-services.md#consuming-websocket-feeds), all of them or the named ones | no |

- `worker` and `feeds` print a banner (`=> worker: 3 job threads, 2
  scheduled tasks`), run until `SIGTERM` or `SIGINT` (Ctrl-C) and then stop
  the way a server does. They always run their work: `CYBERTRAIN_WORKER=0`, set for the web
  role, does not turn them off.
- `feeds` with names runs only those subscriptions (one container per feed),
  and an unknown name stops the boot with the list of registered ones. With
  feeds in their own process, set `CYBERTRAIN_WORKER=0` on the servers, or
  every process would receive every feed.
- A `feeds` process restarts a feed whose thread died, and exits with status
  1 when one feed keeps dying (`feed_restart_limit` restarts within
  `feed_restart_window`), so run it under a restart policy (Docker's
  `restart: unless-stopped`, systemd's `Restart=always`);
  [Consuming WebSocket feeds](external-services.md#consuming-websocket-feeds)
  has the details. `./<app> feeds status` prints each feed's last reported
  status.
- A typical split: `server` with `CYBERTRAIN_WORKER=0` behind the proxy, one
  or more `worker`s, and `feeds` if there are subscriptions. `cybertrain new`
  writes a `web` and a `worker` role into `config/deploy.yml` (and a
  commented `feeds`); [docs/deploy.en.md](../deploy.en.md) part 7,
  "Splitting the roles", has the systemd units.
- **Upgrading from a release without heartbeats**: stop every old process
  before starting the first new one. A new worker would take the jobs an
  old one is still running for abandoned, since an old process writes no
  heartbeat.
- `Cybertrain::Main.worker?(ARGV)` and `Main.feeds?(ARGV)`, like
  `Main.server?(ARGV)`, tell `bin/<app>.rb` which role it is starting.
- `worker` needs `require "cybertrain/jobs"` in `bin/<app>.rb`, and `feeds`
  `require "cybertrain/feeds"` (which `cybertrain/websocket` loads); without
  it the binary says which line is missing and exits with 1.

## The cache store

`Cybertrain::Cache` keeps answers for a while in the application's own
database, so the next request does not ask the slow API again.
`require "cybertrain"` loads it; an application on `cybertrain/core` adds
`require "cybertrain/cache"` to `bin/<app>.rb` and `bin/db.rb`, or where it
is used:

```ruby
require "cybertrain/cache"

text = Cybertrain::Cache.fetch("defillama/tvl", expires_in: 21_600, race_condition_ttl: 30) do
  client.get("https://api.llama.fi/tvl").body
end
data = Cybertrain::Cache.fetch_hash("prices/#{sym}", expires_in: 60) { { "usd" => price } }
count = Cybertrain::Cache.fetch_int("articles/count", expires_in: 60) { Article.count }
Cybertrain::Cache.write("import-lock", "1", expires_in: 300, unless_exist: true)   # true when written
```

- **Values are Strings.** `fetch(key, expires_in:, race_condition_ttl:) {
  String }` answers the live value or runs the block and stores what it
  returns; `fetch_hash`, `fetch_array` and `fetch_int` store JSON or Integer
  text and parse it on the way out, so a corrupt cell reads as `{}`, `[]` or
  `0` until it expires and the block runs again (Spinel has no `Marshal`, and
  one method answers one type). `read(key)` (a String, or nil),
  `write(key, value, expires_in:, unless_exist:)`, `delete`, `exist?`,
  `increment(key, by: 1, expires_in:)` (one statement; an expired counter
  starts again from `by`, and `expires_in:` sets the expiry only when the
  counter starts, so a counter for a minute counts that minute) and `clear`
  are the rest.
- **Expiry.** `expires_in:` is seconds; `0`, the default, never expires
  (so does a negative value). `race_condition_ttl: n`: when a row has
  expired, the first caller extends it by `n` seconds and computes the new
  value while the others keep reading the old one, as in Rails; without it
  every caller of an expired key computes. A block that raises writes
  nothing.
- **Storage.** The rows live in `cybertrain_cache`, which the framework
  creates on first use and leaves out of `db/schema.rb`. Nothing is kept in
  memory: every read is a SELECT, which SQLite answers from its page cache.
  Every write takes the database's writer lock, which requests writing their
  own rows wait for: cache what jobs produce, or values read far more often
  than they change, rather than writing in a busy request path.
- **Pruning.** With jobs loaded, requiring the file registers the scheduled
  task `"cybertrain cache prune"`, which deletes expired rows every
  `cache_prune_interval` seconds (300, `CYBERTRAIN_CACHE_PRUNE_INTERVAL`), a
  thousand per statement. Without jobs the cache prunes itself: the first
  write of a process, and the first after each `cache_prune_interval`,
  deletes up to a thousand expired rows.
  The interval is read when the file is required: set the variable, or
  `c.cache_prune_interval` in a `Cybertrain.configure` block that runs before
  the require. `Cache.prune(now)` is the test entry point.

Not built: a separate cache database file, a size cap, an in-memory store.
The design: `docs/design.md` D54.

## The console

`./<app> console` is a prompt over the application's models. Spinel has no
`eval`, so it does not run Ruby: it evaluates the expressions a template's
`<%= %>` evaluates ([the template language](template-language.md#expressions),
without blocks), plus model names. In development, run it with
`cybertrain spin run <app> -- console`.

```console
$ ./blog console
Cybertrain console (production). Type help for commands, exit to quit.
>> Article.where(title: "Hello").count
1
>> a = Article.find(1)
#<Article id: 1, title: "Hello", body: "First post", created_at: 2026-11-05 10:00:00 UTC, updated_at: 2026-11-05 10:00:00 UTC>
>> a.update(title: "Hello again")
true
```

- A model name is its relation (`Article`), with `where`, `where_like`,
  `order`, `limit`, `offset`, `page`, `first`, `last`, `find`, `find_by`,
  `to_a`, `count`, `exists?`, `pluck_str` / `pluck_int` / `pluck_float`,
  `sum_int`, `count_by`, `delete_all`, `to_sql` and `create`. A record has its
  attributes and methods, `update`, `save`, `destroy`, `reload`, `valid?`,
  `errors` and `attributes`. `help` lists them all.
- `x = expr` keeps a value for the following lines, and `_` is the last
  value. `sql "..."` runs SQL and prints the rows as a table, with a cell's
  control characters escaped (`\e`, `\n`), so data can neither send the
  terminal an escape sequence nor break the table (a TEXT value holding a NUL
  byte is cut at the NUL when it is read, as in every raw-SQL read; a BLOB
  keeps every byte); `tables` lists the tables; `exit`, `quit` or Ctrl-D leaves.
- A line that does not parse prints its error, a line that raises prints
  `Class: message`, and the prompt comes back. A binary value prints as
  `<N bytes>`.
- Writes are real. In production the console says so in a banner first.

`./<app> dbconsole` opens the `sqlite3` shell on the configured database
(`CYBERTRAIN_DATABASE`), as Rails' `dbconsole` does; it needs the `sqlite3`
command installed, and passes its exit status through. Neither command
starts the scheduler, jobs or feeds.

## Operations: backups, vacuum, health check

The data of a deployed application is one SQLite file, so the binary carries
the three operational tools such an application needs. An application with
file uploads also keeps their bytes under its upload root
(`upload_root`, `storage/uploads/` by default): back that directory up and
restore it together with the database, or restored records point at missing
files ([Add a file upload](tutorial.md#attachments)).

**Backups.** `./<app> db backup PATH` writes a consistent copy of the
configured database (`CYBERTRAIN_DATABASE`) while the server keeps running:
SQLite's `VACUUM INTO` (3.27 or newer; the binary checks) reads one snapshot,
and under WAL the server's writes go on meanwhile. The copy is written to a
temporary file next to `PATH`, created exclusively with mode 0600 (the file
holds password digests and session tokens), fsynced, and only then renamed
to `PATH`, so a failed or interrupted copy never leaves a partial file under
the real name (the temporary one is deleted). An existing `PATH` is refused
unless you pass `--force`; the database itself never is a target, nor is a
`:memory:` database a source.

```sh
./blog db backup /srv/blog/backups/before-upgrade.sqlite3
./blog db backup /srv/blog/backups/ --keep 14    # blog-20261025T031500Z.sqlite3, newest 14 kept
```

A target ending in `/` (or an existing directory) gets a dated name,
`<app>-<YYYYmmddTHHMMSSZ>.sqlite3` in UTC, in a directory created with mode
0700 if it does not exist; `--keep N` then deletes the oldest files of
exactly that shape beyond N and touches nothing else there. Restoring is
copying a backup over the database file with the server stopped (and
deleting that file's `-wal` and `-shm` beside it).

**Vacuum.** Deleting rows leaves free pages in the file. `./<app> db vacuum`
runs `VACUUM` and then `PRAGMA wal_checkpoint(TRUNCATE)`, so the rebuilt
pages reach the database file, the file is cut to its new size and the WAL
is emptied; it prints the size on disk (database plus WAL) before and after.
`VACUUM` rewrites the whole file and holds the write lock while it does, so
run it when the application is quiet. If a reader keeps the checkpoint from
finishing it says so, and the WAL shrinks at a later checkpoint.

**Run backups outside the server.** A SQLite call holds its OS worker until
it returns, so a large `VACUUM INTO` on a `Scheduler` task would stall
requests (with `SPINEL_WORKERS=1`, all of them) for as long as the copy
takes. Run the command from cron or a systemd timer instead, as a separate
process:

```sh
# crontab of the app's user: every night at 03:15, keep two weeks
15 3 * * * cd /srv/blog/current && ./blog db backup /srv/blog/backups/ --keep 14
```

An application that wants to take backups itself can run its own binary as
a child process from a scheduled task, rather than run the SQL on its own
thread: `system` waits for the child on the scheduler's thread only, and
requests go on being served meanwhile (use `system` with an argument list,
never a string with request data in it). A copy that takes longer than
`health_worker_stale` makes the health check answer `worker stale` until it
is done.

```ruby
# config/app.rb, in a served binary started from its own directory (dist/)
Cybertrain::Scheduler.every(86_400, "nightly backup") do
  system("./blog", "db", "backup", "storage/backups/", "--keep", "14")
end
```

**Health check.** While the health check is enabled (it is by default;
an empty `config.health_path` turns it off), the served application
answers `GET /up` (and `HEAD`) before the static files, the session, CSRF and the router: no controller
is involved and no login `before_action` can redirect it, and it sets no
cookie. It runs `SELECT count(*) FROM sqlite_master`, which has to read the
schema page from the file (a bare `SELECT 1` never touches it), and answers
in `text/plain` with `Cache-Control: no-store`:

| Status | Body | When |
| --- | --- | --- |
| 200 | `ok` | the query succeeded |
| 503 | `database unavailable` | it raised `Cybertrain::DB::Error` (the file is missing or unreadable, the pool is closed) |
| 503 | `worker stale` | the background `Scheduler` runs and its last tick is older than `health_worker_stale` seconds (300): a task is stuck, or runs far too long |
| 503 | `feed stale` | a [WebSocket feed](external-services.md#consuming-websocket-feeds), in this process or another, has not reported its status, or has received nothing (not even a pong), for `health_feed_stale` seconds (180); see [Feed health](realtime.md#feed-health) |

A poll is logged like any request (two lines). The path is
`config.health_path` (`CYBERTRAIN_HEALTH_PATH`, default `/up`; an empty
value turns the check off, and the path then goes on to `public/` and the
router as before). A load balancer, kamal-proxy or a deploy script can poll
it; `public/up.html`, which `cybertrain new` writes and its Kamal
configuration still polls, only shows that the process answers HTTP.
