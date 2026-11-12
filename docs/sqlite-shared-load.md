# One SQLite file for business data, jobs, the cache and streams: the measured interference

Business tables, the job queue, the cache (and with it the `rate_limit`
counters), the stream messages, the scheduler's lease and timetable and the
feed status all live in the application's one SQLite database. That is one
file to back up, no service to run beside the binary, and one transaction
around "save the order, enqueue the mail, tell the page". The price is that
SQLite has one writer: every write of an internal service waits for, and is
waited for by, the application's own writes. This page measures that price,
says what scale the numbers support and how to see the interference on a
running server. The decision record is
[docs/design.md, D74](design.md#d74-one-sqlite-file-for-every-service-the-storage-boundaries-their-transaction-guarantees-and-the-measured-interference-2026-11-11-issue-190),
which also holds the storage boundary table.

## The scenario

[bench/mixed_load.rb](../bench/mixed_load.rb) is one compiled program (Spinel,
the flags of `spin test`) on one database file, opened as an application
opens it: WAL, the framework's connection pool (`pool_size` 4). It starts the
services `Application#serve` starts (the stream poller, the scheduler, three
job threads and their heartbeat) and then runs, through the public APIs:

| load | what a thread does | writes per operation |
| --- | --- | --- |
| business write | `DB.transaction(immediate: true)` with two `UPDATE`s and an `INSERT` | 1 commit |
| business read | one row by primary key | none |
| jobs | `Job.enqueue`; the job threads claim the row, run the handler (one business `INSERT`) and write the outcome | 1 commit to enqueue, 3 per job run (claim, the handler's insert, outcome) |
| cache | `Cache.write` then `Cache.read` of the same key | 1 commit, then a read |
| rate limit | the `Cache.increment` `Controller#run_rate_limit` runs for `store: :cache`, with its key (200 client addresses, a 60 s window) | 1 commit |
| stream | `Stream.broadcast`; the poller hands the row to a subscriber waiting in `Subscriber#stream_pop` | 1 commit |

Each load runs alone for a fixed time (its baseline, with the other services
up but idle), then all of them run together; the table prints both, so the
interference is the "mixed" line against the "alone" line. Per kind it counts
the operations and their latency (p50, p95, p99, max: a histogram with
buckets a tenth wide, so a percentile is at most 10% high), the job delay
from `Job.enqueue` to the handler's first line, the stream delay from
`Stream.broadcast` to the subscriber's `stream_pop`, and the calls that
raised: "busy" for `database is locked` (a lock wait given up after
`Connection::BUSY_WAIT_LIMIT`, 5 s), "errors" for anything else. Before the
load it checks the transaction guarantees of D74's table on the same binary:
one transaction writing a business row, a job, a message and two cache rows
leaves none of the five after a rollback and all five after a commit.

```sh
bench/mixed                              # compiles, then 5 s per phase with the defaults
bench/mixed duration=10 workers=2        # two serving workers
bench/mixed --no-build writers=8 think_ms=0 baselines=0
```

The settings (`name=value`, listed at the top of bench/mixed_load.rb) are the
thread count of each load, the pause after each operation (`think_ms`,
`enqueue_ms`, `broadcast_ms`), `workers`, `pool`, `job_threads`, `duration`
and `baselines=0` for the mixed phase alone. The database is
`bench/tmp/mixed/` (ignored by git). It is a bench, not a test: the shape of
the output is fixed, the numbers are not, and nothing under `test/` runs it.

## The recorded runs

2026-11-11, cybertrain 0.4.1, Spinel 2026.11.04.7026, Linux, 4 cores, a
container disk. **The machine was shared and busy (load average 23 to 30)
during every run, so the numbers are indicative: read the ratios and the
shapes, not the absolute throughput.** `synchronous` is SQLite's default
(`FULL`: every commit syncs the WAL), `wal_autocheckpoint` 1000 pages,
`job_poll_interval` 1 s, `stream_poll_ms` 100. No call raised in any run
(busy 0, errors 0 on every line), so those two columns are left out below.

### A. The defaults on one worker

`workers=1`: 2 writers, 2 readers, 2 cache threads, 2 rate-limit threads
pausing 2 ms after each operation; one enqueuer and one broadcaster pausing
20 ms; 5 s per phase.

| kind | phase | ops/s | p50 ms | p95 ms | p99 ms | max ms |
| --- | --- | --: | --: | --: | --: | --: |
| business write (transaction) | alone | 310.6 | 2.29 | 8.67 | 10.49 | 12.02 |
| | mixed | 153.3 | 0.67 | 4.05 | 10.49 | 12.01 |
| business read | alone | 915.6 | 0.02 | 0.04 | 0.07 | 3.04 |
| | mixed | 153.1 | 0.02 | 0.05 | 0.06 | 3.27 |
| job enqueue | alone | 34.7 | 0.73 | 7.88 | 12.69 | 16.39 |
| | mixed | 23.9 | 1.42 | 8.67 | 12.69 | 13.29 |
| job delay (enqueue to start) | alone | 34.7 | 840.51 | 1011.92 | 1011.92 | 1011.92 |
| | mixed | 23.9 | 840.51 | 1118.72 | 1157.05 | 1157.05 |
| cache write | alone | 351.9 | 1.89 | 7.88 | 10.49 | 53.66 |
| | mixed | 152.9 | 0.73 | 4.05 | 9.54 | 12.87 |
| cache read | alone | 351.9 | 0.04 | 0.06 | 0.12 | 3.89 |
| | mixed | 152.9 | 0.03 | 0.06 | 0.08 | 1.00 |
| rate limit count | alone | 539.6 | 1.07 | 2.51 | 6.51 | 11.99 |
| | mixed | 152.3 | 0.67 | 4.45 | 11.54 | 50.04 |
| stream broadcast | alone | 43.5 | 0.67 | 6.51 | 12.69 | 13.45 |
| | mixed | 23.7 | 1.29 | 7.88 | 10.49 | 19.72 |
| stream delay (broadcast to hand-off) | alone | 43.5 | 52.99 | 103.26 | 104.01 | 104.01 |
| | mixed | 23.7 | 58.29 | 137.44 | 166.24 | 166.24 |

### B. The same load on two workers

`workers=2`, everything else as A.

| kind | phase | ops/s | p50 ms | p95 ms | p99 ms | max ms |
| --- | --- | --: | --: | --: | --: | --: |
| business write (transaction) | alone | 525.3 | 1.18 | 2.77 | 7.88 | 12.79 |
| | mixed | 153.2 | 2.29 | 32.90 | 64.12 | 123.97 |
| business read | alone | 922.2 | 0.02 | 0.04 | 0.07 | 1.11 |
| | mixed | 172.3 | 0.03 | 29.91 | 52.99 | 116.10 |
| job enqueue | alone | 41.5 | 0.67 | 18.58 | 32.90 | 67.90 |
| | mixed | 26.4 | 7.17 | 43.79 | 85.34 | 107.85 |
| job delay (enqueue to start) | alone | 41.5 | 694.64 | 1017.02 | 1017.02 | 1043.84 |
| | mixed | 26.4 | 574.08 | 1118.72 | 1137.68 | 1137.68 |
| cache write | alone | 573.6 | 0.88 | 2.29 | 4.05 | 10.18 |
| | mixed | 129.0 | 1.72 | 48.17 | 85.34 | 404.63 |
| cache read | alone | 573.6 | 0.03 | 0.06 | 0.08 | 1.96 |
| | mixed | 129.0 | 0.03 | 0.12 | 7.88 | 52.03 |
| rate limit count | alone | 552.0 | 1.29 | 2.29 | 5.38 | 22.49 |
| | mixed | 132.3 | 2.08 | 48.17 | 113.58 | 218.86 |
| stream broadcast | alone | 41.3 | 3.68 | 8.67 | 9.54 | 9.61 |
| | mixed | 19.2 | 12.69 | 113.58 | 344.83 | 344.83 |
| stream delay (broadcast to hand-off) | alone | 41.3 | 58.29 | 103.26 | 104.30 | 104.30 |
| | mixed | 19.2 | 85.34 | 201.22 | 408.00 | 408.00 |

### C. Saturation: writers that never pause

`workers=2 writers=8 readers=0 cache=4 rate=4 think_ms=0 enqueue_ms=5
broadcast_ms=5`: 16 threads writing as fast as they can, on 4 connections.

| kind | phase | ops/s | p50 ms | p95 ms | p99 ms | max ms |
| --- | --- | --: | --: | --: | --: | --: |
| business write (transaction) | alone | 740.3 | 1.42 | 52.99 | 137.44 | 439.85 |
| | mixed | 129.8 | 4.90 | 324.06 | 694.64 | 880.42 |
| job enqueue | alone | 71.4 | 2.51 | 52.99 | 151.18 | 226.98 |
| | mixed | 4.7 | 93.87 | 574.08 | 616.44 | 616.44 |
| job delay (enqueue to start) | alone | 71.4 | 1489.02 | 2100.03 | 2100.03 | 2100.03 |
| | mixed | 4.7 | 431.32 | 1017.02 | 1368.61 | 1368.61 |
| cache write | alone | 313.0 | 3.04 | 6.51 | 9.54 | 17.60 |
| | mixed | 52.2 | 4.05 | 85.34 | 324.06 | 958.46 |
| cache read | alone | 313.0 | 0.04 | 0.06 | 0.10 | 36.69 |
| | mixed | 52.2 | 0.04 | 356.46 | 744.47 | 744.47 |
| rate limit count | alone | 357.7 | 2.77 | 5.38 | 7.17 | 40.61 |
| | mixed | 71.7 | 4.45 | 294.60 | 521.89 | 628.33 |
| stream broadcast | alone | 168.5 | 0.50 | 3.04 | 6.51 | 9.66 |
| | mixed | 5.1 | 151.18 | 474.45 | 519.99 | 519.99 |
| stream delay (broadcast to hand-off) | alone | 168.5 | 52.99 | 101.23 | 101.23 | 101.23 |
| | mixed | 5.1 | 324.06 | 694.64 | 747.44 | 747.44 |

## What the numbers say

1. **The commit is the shared resource.** Adding up the commits of run A's
   mixed phase (153 business + 153 cache + 152 rate limit + 24 enqueue + 3 x
   24 for the jobs + 24 broadcast) gives about 580 a second, and no load
   alone got past 310 to 570 on the same worker. Every service's write is a
   transaction of its own (an autocommit statement), and with `synchronous =
   FULL` each one syncs the WAL: on this disk about 1 to 2 ms. So the
   database gives roughly 500 to 750 commits a second here, and the
   services divide them: in the mixed phase the business writers got half
   of what they had alone (A), or a third to a sixth (B, C). A cache write
   or a rate-limit count costs a request as much as a business transaction
   does.
2. **Nothing failed; the interference is waiting.** No run reached the 5 s
   limit, so there was no `database is locked`. A writer that finds the lock
   taken sleeps 0.1 to 1 ms and tries again (`Connection#step_waiting`), so
   the queue for the lock is not fair: the tails grow (B's business write
   p99 from 8 ms to 64 ms, C's to 0.7 s) while the medians barely move.
3. **Reads wait too, for a worker and for a connection.** WAL readers do
   not wait for the writer, and a read costs 0.02 to 0.04 ms at the median
   in every run. But an FFI call holds its OS worker (spikes/NOTES.md rule
   80): on one worker every thread stands still while one commit syncs, so
   in A the readers ran at the writers' pace (916 reads a second alone, 153
   mixed) at an unchanged latency. And a writer waiting for the lock keeps
   its pooled connection while it sleeps: with 16 writing threads on 4
   connections (C), a `Cache.read` waited behind them for a connection (p95
   0.06 ms alone, 356 ms mixed). The pool is shared by the request threads,
   the job threads, the poller, the scheduler and the heartbeat.
4. **The job delay is the poll interval, not the load.** A job thread that
   finds nothing due sleeps `job_poll_interval` (1 s); the threads drain the
   queue, find it empty together and sleep together. So even alone, at 35
   jobs a second, a job waited 0.7 to 0.84 s at the median and 1 s at p95,
   and the mixed load added 0.1 s to the tail. When the enqueue rate passes
   what the job threads complete (C alone: 71 a second enqueued), the delay
   is the backlog (2.1 s after 5 s).
5. **The stream delay is the poll interval plus the wait for a commit.**
   Alone it is 0 to 100 ms (`stream_poll_ms`), 53 ms at the median. Mixed it
   reached 137 ms (A), 201 ms (B) and 695 ms (C) at p95: the broadcast's own
   INSERT waits for the lock, and the poller's read waits for a worker and a
   connection.

### What each service writes when (read from the code)

| service | on a request | in the background, per process |
| --- | --- | --- |
| `rate_limit` (`store: :cache`, the default) | one `Cache.increment` (an upsert, one commit) for **every** request to an action the declaration names, allowed or refused | none of its own; its rows are deleted by the cache prune |
| `Cache` | `write`, `increment`, `delete`, a `fetch` miss: one commit each; `fetch` with `race_condition_ttl` on an expired row: one more (the extension). `read`, `exist?` and a `fetch` hit only read | `"cybertrain cache prune"` every `cache_prune_interval` (300 s), on the process holding the scheduler lease: `DELETE` in batches of 1000, one commit a batch |
| `Job` | `Job.enqueue` / `perform_later` / `deliver_later`: one INSERT | per job run: the claim (`BEGIN IMMEDIATE`, a SELECT and an UPDATE), the outcome UPDATE, and whatever the handler writes; an idle job thread only reads, once per `job_poll_interval`; the heartbeat thread writes one UPDATE every `job_heartbeat_interval` (30 s) and only while a job is in flight; `Job.recover!` every 60 s from the scheduler. **Nothing deletes `done` rows** unless the application schedules `Job.prune_done` (`cybertrain new` writes that task into the application as a comment) |
| `Stream` | `Stream.broadcast` / `broadcast_*_to`: one INSERT | the poller reads `MAX(id)` every `stream_poll_ms` (100 ms) and deletes the rows older than `stream_retention` (60 s) once a minute, in one statement |
| `Scheduler` / `Lease` | none | one lease upsert per `scheduler_interval` (1 s) per process that runs the scheduler, and one timetable upsert per task run |
| feed status | none | one upsert per feed every `feed_status_interval` (10 s), in processes that run feeds |

So an idle server commits about once a second (the lease), and a request
adds one commit for each of: a `rate_limit` it passes through, a cache
write, an enqueue, a broadcast, on top of its own transaction. Inside the
request's `DB.transaction` those join it and cost no commit of their own
(D74's table); outside one, each is a commit.

## The scale this supports

On hardware like the recorded machine, one database carries a few hundred
commits a second in all before the tails grow, and what counts against that
budget is the sum over every process and service, not the business writes
alone:

    commits/s = requests/s x (1 if it writes + rate limits counted + cache writes
                              + enqueues + broadcasts outside its transaction)
              + jobs/s x (2 + the handler's own commits)
              + about 1 per process (lease, heartbeat, feed status)

- Comfortable: a sum under a third of the measured ceiling (here, under
  about 150 to 200 commits a second). That is tens of writing requests a
  second with a rate limit and a broadcast each, plus tens of jobs a second;
  reads are not in the sum.
- Degrading: near the ceiling the p99 of every write, and of reads on the
  same worker or pool, goes from milliseconds to tenths of a second (B, C).
- Failing: only when a writer waits more than 5 s, which needs a long
  transaction holding the lock (a transaction that does I/O, a bulk import,
  a large prune), not just many small ones. No run here got there.

Measure the ceiling on the production disk (`bench/mixed` on the server, or
on the same volume type): a sync costs 0.1 ms on a local NVMe and 5 ms or
more on some network volumes, which moves every number by that factor.

What to do before thinking about another store, cheapest first:

- Put the service writes of a request inside its `DB.transaction`: an
  enqueue, a broadcast and a cache write then share its one commit.
- Count requests in memory where a per-process count is enough
  (`rate_limit ..., store: :memory`), and keep `only:` narrow: the default
  store writes on every counted request.
- Cache what jobs produce or what is read often and written rarely, as the
  `Cache` documentation says; a cache written on every request is a second
  business write.
- Batch broadcasts from a feed or a job (one message for many changes).
- Raise `pool_size` when threads outnumber it and reads show a tail (C):
  the default 4 is shared with the job threads and the poller.
- Schedule `Job.prune_done`, so `cybertrain_jobs` stays small.
- `job_poll_interval` cannot go under 1 s: work that must start within
  milliseconds is not what the queue is for.

## Seeing the interference on a running server

What exists today (each read from the code):

- **The request log.** `RequestLogger` writes `Completed <status> in <N>ms`
  for every request. Lock waits are inside that time, so the sign is the
  tail of the writing actions growing while the reading actions stay flat
  (on several workers) or everything slowing together (on one).
- **Error lines of the services**, all at `error` level, each naming the
  service: `Job thread <i>: ...` (a claim that failed; the thread waits a
  poll interval), `job <id>: outcome write <n> of 3 failed: ...` then
  `job <id> (<kind>) finished but its outcome could not be written; left
  running for heartbeat recovery`, `Job heartbeat: ...`, `stream poller:
  ...`, `Scheduler lease: ...`, `Scheduler timetable: ...`. With `database
  is locked` in them, a writer waited 5 s. A request that hits the limit
  raises `Cybertrain::DB::Error` and is logged as any 500.
- **`GET /up`** answers `503 worker stale` when the scheduler has not
  ticked for `health_worker_stale` seconds (a tick blocked on the database
  counts) and `503 database unavailable` when a read of the schema fails.
  It does not measure latency.
- **The queue**: `./<app> jobs list queued` and `jobs list running` (or the
  jobs page, `jobs_page "/admin/jobs"`, which shows the count per state and
  when the next queued job is due). A `queued` count that keeps growing, or
  a next-due time in the past by more than `job_poll_interval`, is a queue
  that is not keeping up.
- **SQL**, from `./<app> dbconsole` (the `sqlite3` shell, a reader, so it
  does not take the write lock):

  ```sql
  -- jobs that are due and still waiting, and for how long
  SELECT COUNT(*), strftime('%s','now') - MIN(run_at) FROM cybertrain_jobs
   WHERE state = 'queued' AND run_at <= strftime('%s','now');
  -- jobs finished per minute, lately
  SELECT updated_at / 60 * 60 AS minute, COUNT(*) FROM cybertrain_jobs
   WHERE state = 'done' GROUP BY 1 ORDER BY 1 DESC LIMIT 10;
  -- broadcasts per second over the retention window
  SELECT COUNT(*) * 1.0 / MAX(1, MAX(created_at) - MIN(created_at)) FROM cybertrain_messages;
  -- cache rows, the rate-limit counters among them, and the expired ones awaiting the prune
  SELECT COUNT(*),
         SUM(key >= 'rate-limit:' AND key < 'rate-limit;'),
         SUM(expires_at IS NOT NULL AND expires_at < strftime('%s','now')) FROM cybertrain_cache;
  ```

- **The files**: `<database>-wal` normally stays near 4 MB (1000 pages);
  one that keeps growing means a reader or a transaction is open so long
  that no checkpoint can finish.
- **`bench/mixed`** against the production volume, for the ceiling.

What does not exist, and is proposed rather than built here: the framework
counts neither lock waits nor the time spent in them. `Connection#step_waiting`
and `#exec_waiting` already know both (they loop on `SQLITE_BUSY`); two
counters there (waits, microseconds waited), read through the pool and
written to the log once a minute when they moved, would turn "the tail
grew" into "writers waited 3.1 s in total over 412 waits this minute". It
is left out of this change because it adds state to the per-statement path
that needs its own measurement under two workers (NOTES rule 57).

## If a store moves out of the file

Nothing moves now (D74). The storage boundary table in D74 lists, per
store, which guarantee depends on sharing the application's transaction and
what would have to be defined first. The rule: a store may move to another
SQLite file or to an external service only with a written definition of its
consistency with the business transaction (what replaces "in the same
commit"), and of its behaviour when the store is unavailable, when one of
the two writes fails, and for ordering and duplicates.
