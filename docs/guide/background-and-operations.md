# Background work and operations

## Background work

An application that has to do something outside a request (send a
notification after the response went out, sweep old rows every hour, retry a
call that failed) registers it with the framework, which runs it on one
background thread of the served process:

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

- **When it runs.** The thread starts when the binary serves (`./<app>`,
  `./<app> server`), after boot has connected the database, bound the port
  and set `SPINEL_WORKERS`; `migrate`, `db ...` and `Main.command` commands
  never start it, and neither does `Cybertrain::Test::Client`. A task runs
  first `seconds` after the start, then `seconds` after the start of each
  run. Each run is wrapped in a rescue that logs `[ERROR] Scheduled task
  "name" failed: ...` and the loop goes on. The block takes no arguments
  (Spinel has no `instance_eval`). `Cybertrain::Scheduler.last_tick` is the
  epoch second of the last tick, for a health check of your own.
- **Jobs.** `Job.enqueue` adds a row to the `cybertrain_jobs` table, which
  the framework creates itself (`CREATE TABLE IF NOT EXISTS`, on first use)
  and leaves out of `db/schema.rb`. The payload is a String: JSON-encode
  structured data. Inside a `DB.transaction` the row commits or rolls back
  with the rest. The worker, a scheduler task polling every
  `job_poll_interval` seconds (5), claims the oldest due job in a short
  `BEGIN IMMEDIATE` transaction, runs its handler outside it, and marks it
  `done`. A handler that raises is retried 1, 5, 15 and then 60 minutes
  later, with `Class: message` (up to 1000 characters) in `last_error`, until
  `job_max_attempts` (5) attempts have failed: the row is then `failed` and
  stays for you to look at. A job whose kind has no handler is `failed` at
  once; `Job.enqueue` refuses an unregistered kind. Rows a crashed process
  left `running` are requeued when the worker starts. `Job.state_count("failed")`
  and `Job.prune_done(before_epoch)` help with a health page and housekeeping.
- **One worker per database.** Every served process runs the thread unless
  `CYBERTRAIN_WORKER=0` (`config.worker = false`): when several processes
  share one SQLite file, turn it off in all but one, or each scheduled task
  runs once per process.
- **Keep tasks short.** Tasks and handlers run one at a time on that one
  thread, and a SQLite call holds its OS worker until it returns: with
  `SPINEL_WORKERS=1` (the default) a long query stalls every request for as
  long. Batch big work (delete a thousand rows per run, enqueue one job per
  item) rather than doing it in one go.
- **Testing.** `Cybertrain::Scheduler.run_due(now)` runs one tick and
  `Cybertrain::Job.work_one(now)` one job, with an epoch time you choose, so
  a test never sleeps.

There is no cron syntax, no priority or uniqueness for jobs and no mailer:
this covers "send later" and "run every N seconds" (`docs/design.md` D28).

## Operations: backups, vacuum, health check

The data of a deployed application is one SQLite file, so the binary carries
the three operational tools such an application needs. An application with
file uploads also keeps their bytes under its upload root
(`upload_root`, `storage/uploads/` by default): back that directory up and
restore it together with the database, or restored records point at missing
files ([Add a file upload](walkthrough.md#add-a-file-upload)).

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
requests go on being served meanwhile (Spinel has no `Process.wait`, and a
`Process.spawn` without it leaves a zombie, so use `system` with an argument
list, never a string with request data in it). A copy that takes longer than
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
