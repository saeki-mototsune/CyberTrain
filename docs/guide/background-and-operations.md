# Background work and operations

## Background work

An application that has to do something outside a request (send a
notification after the response went out, sweep old rows every hour, retry a
call that failed) registers it with the framework, which runs it on
background threads of the served process, or of a separate worker process:

```ruby
# config/app.rb (or a file bin/<app>.rb requires before Cybertrain::Main.run)
Cybertrain::Scheduler.every(3600, "prune sessions") do
  Cybertrain::DB.with { |c| c.execute("DELETE FROM sessions WHERE updated_at < datetime('now', '-30 days')") }
end

Cybertrain::Job.handle("welcome_mail") do |payload|
  data = Cybertrain::Cast.hash(JSON.parse(payload))
  WelcomeMail.deliver(data["email"].to_s)   # raise to have it retried
end
```

```ruby
# in an action, after saving the user
Cybertrain::Job.enqueue("welcome_mail", JSON.generate({ "email" => @user.email }))
Cybertrain::Job.enqueue("reminder", @order.id.to_s, run_at: Time.now + 600)
```

- **Where it runs.** Scheduled tasks run on one scheduler thread; jobs run
  on `job_threads` job threads of their own (3, `CYBERTRAIN_JOB_THREADS`),
  so a long job never holds up a task. Both start when the binary serves
  (`./<app>`, `./<app> server`) or runs as a worker (`./<app> worker`, see
  [Process roles](#process-roles)), after boot has connected the database
  and set `SPINEL_WORKERS`; `migrate`, `db ...`, `console` and `Main.command`
  commands never start them, and neither does `Cybertrain::Test::Client`. A
  task runs first `seconds` after the start, then `seconds` after the start
  of each run. Each run is wrapped in a rescue that logs `[ERROR] Scheduled
  task "name" failed: ...` and the loop goes on. The block takes no
  arguments (Spinel has no `instance_eval`). `Cybertrain::Scheduler.last_tick`
  is the epoch second of the last tick, for a health check of your own.
- **Jobs.** `Job.enqueue` adds a row to the `cybertrain_jobs` table, which
  the framework creates itself (`CREATE TABLE IF NOT EXISTS`, on first use)
  and leaves out of `db/schema.rb`. The payload is a String: JSON-encode
  structured data. Inside a `DB.transaction` the row commits or rolls back
  with the rest. Each job thread claims the oldest due job in a short
  `BEGIN IMMEDIATE` transaction, runs its handler outside it, marks it
  `done` and looks for the next; with nothing due it waits
  `job_poll_interval` seconds (1), so a job enqueued by a request starts
  within about a second. A handler that raises is retried 1, 5, 15 and then
  60 minutes later, with `Class: message` (up to 1000 characters) in
  `last_error`, until `job_max_attempts` (5) attempts have failed: the row is
  then `failed` and stays for you to look at. A job whose kind has no
  handler is `failed` at once; `Job.enqueue` refuses an unregistered kind.
  `Job.state_count("failed")` and `Job.prune_done(before_epoch)` help with a
  health page and housekeeping.
- **At least once.** A job can run twice: a process that is killed, or that
  stalls for longer than `job_heartbeat_stale` (300 s), may still be running
  a job when another process takes the row back (below). Only the first
  outcome written counts, but the handler's side effects happened twice, so
  write handlers that can safely run again (check whether the mail was
  already sent, upsert rather than insert), as with any job queue.
- **Concurrency per kind.** `Job.handle("sync_account", concurrency: 1) {
  ... }` lets at most that many jobs of the kind run at once, across every
  process sharing the database (for a rate-limited API, or work that must
  not overlap); the default, 0, is no limit. Other kinds go on running
  meanwhile.
- **Several workers per database.** Every process that runs jobs writes a
  heartbeat for the jobs it is running every `job_heartbeat_interval` (30 s).
  A `running` row whose heartbeat is older than `job_heartbeat_stale` (a
  process that crashed or was stopped mid-job) is queued again by whichever
  process looks next, at its start and then once a minute. Scheduled tasks
  run in one process at a time: the processes share a lease in the
  database (`cybertrain_leases`, renewed every tick, `scheduler_lease_ttl`
  30 s), and only its holder runs due tasks; another takes over when it
  stops renewing. So two `worker` processes, or a server and a worker, can
  share one SQLite file; `CYBERTRAIN_WORKER=0` turns jobs, tasks and feeds
  off in a `server` process that should only serve HTTP.
- **Shutting down.** On `SIGTERM` the job threads stop claiming new jobs, and
  the process waits up to `job_drain_timeout` (10 s) for the jobs in flight.
  A job still running then keeps its row `running`; its heartbeat has
  stopped, so another process runs it again once it is stale.
- **Keep tasks short.** Tasks run one at a time on the scheduler thread, and
  a SQLite call holds its OS worker until it returns: with `SPINEL_WORKERS=1`
  (the default) a long query stalls every request, and every other thread,
  for as long. Give a task with real work a job (`Job.enqueue` from the
  task), and batch big work (delete a thousand rows per run, enqueue one job
  per item) rather than doing it in one go.
- **Testing.** `Cybertrain::Scheduler.run_due(now)` runs one tick and
  `Cybertrain::Job.work_one(now)` one job, with an epoch time you choose, so
  a test never sleeps.

There is no cron syntax, no priority or uniqueness for jobs and no
`deliver_later`: a job that sends mail calls `Cybertrain::Mailer` itself
([Sending e-mail](external-services.md#sending-e-mail)). This covers "send
later" and "run every N seconds" (`docs/design.md` D28).

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
  scheduled tasks`), run until `SIGTERM` and then stop the way a server
  does. They always run their work: `CYBERTRAIN_WORKER=0`, set for the web
  role, does not turn them off.
- `feeds` with names runs only those subscriptions (one container per feed),
  and an unknown name stops the boot with the list of registered ones. With
  feeds in their own process, set `CYBERTRAIN_WORKER=0` on the servers, or
  every process would receive every feed.
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

A poll is logged like any request (two lines). The path is
`config.health_path` (`CYBERTRAIN_HEALTH_PATH`, default `/up`; an empty
value turns the check off, and the path then goes on to `public/` and the
router as before). A load balancer, kamal-proxy or a deploy script can poll
it; `public/up.html`, which `cybertrain new` writes and its Kamal
configuration still polls, only shows that the process answers HTTP.
