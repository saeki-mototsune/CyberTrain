# Optional subsystems: an application compiles only what it requires

Date: 2026-11-13. Status: agreed with the maintainer on six questions
(section 2); the internal design (sections 3 to 5) is the author's, from the
code and a measurement spike.

## 1. Why

Spinel's whole-program analysis is most of every build: 44 of the 53 s of a
controller edit on the 4-core VM of
[the development-flow spec](2026-11-12-dev-flow-bottlenecks-design.md), and
it grows faster than the program (an exponent of about 1.7). Spinel compiles
every method the required files define, called or not. A scaffolded
application requires all of `cybertrain`, and so compiles jobs, the
scheduler, Turbo Streams, WebSocket feeds, the mailer, the cache and rate
limiting whether it uses them or not.

A spike (2026-11-13, a throwaway copy of the framework at a915504 with the
subsystems cut out by hand, the same scaffolded `article` application, one
compile at a time) measured what leaving them out is worth:

| Cut, cumulative | Methods | Analysis | Notes |
| --- | --: | --: | --- |
| none (twice) | 2,690 | 41.6 s, 40.7 s | |
| WebSocket feeds, the feeds role, `Background` | 2,634 | 41.1 s | no measurable change |
| Streams, SSE, the stream endpoint and poller, Turbo Streams | 2,502 | 37.4 s | −3.8 s |
| mailer (and `net/*`, which only it uses) | 2,378 | 37.0 s | noise |
| jobs page and the `jobs` command | 2,351 | 36.0 s | about −1 s |
| jobs, scheduler, lease, cron, the worker role | 2,203 | 32.1 s | −3.9 s |
| cache, rate limiting | 2,176 | 31.2 s, 30.0 s | about −1 s together |

A full build went from 89.6 s to 68.7 s (−23%), the generated C from 21.0 to
16.7 MB. The slimmed application served `/articles`, `/articles/new` and
`/up` with 200 and the same HTML. The method count does not predict the
saving: what costs is what is wired into reachable code (the template helper
dispatch, the middleware stack, the server role's boot), not what is merely
defined. `HttpClient` and the WebSocket client are not in a default program
already.

## 2. What was decided with the maintainer

| # | Question | Decision |
| --- | --- | --- |
| 1 | Scope | Every subsystem above becomes optional: jobs (with the scheduler, the jobs page and the worker role), Turbo Streams, WebSocket feeds, the mailer, the cache, rate limiting |
| 2 | How an application says what it uses | Explicit requires in `bin/NAME.rb`, as Rails' `config/application.rb` lists railties. `cybertrain new` writes the core alone; a generator that needs a subsystem adds its line |
| 3 | What `require "cybertrain"` means | Unchanged: everything. Existing applications, `examples/blog` and the playground build and behave as before. The speed-up is opt-in, by replacing it with `require "cybertrain/core"` and the lines needed |
| 4 | A view that uses a helper of a subsystem the application did not require | `spin run gen` refuses, naming the file, the line, the helper and the require to add |
| 5 | Cache, rate limiting and jobs | The cache does not need jobs. With jobs loaded its prune runs on the scheduler as today; without, the cache prunes expired rows itself while writing. Rate limiting keeps counting through the cache, so sign-in throttling across processes is unchanged |
| 6 | Mailer and jobs | Split: `cybertrain/mailer` sends now (`Mailer.deliver`); `cybertrain/mailer/later` adds `deliver_later` and loads jobs |

## 3. The require lines

| Line | Loads | Also loads |
| --- | --- | --- |
| `require "cybertrain/core"` | everything else of today's `cybertrain.rb`: HTTP, routing, controllers, models, views and helpers, assets, sessions, CSRF, CSP, the console, `db` and `migrate` | |
| `require "cybertrain/jobs"` | `Job`, job classes, retries, `Scheduler`, `every`/`cron`, the lease, the worker role, the jobs page and the `jobs` command | core |
| `require "cybertrain/streams"` | `Stream`, broadcasts, the stream endpoint (SSE and WebSocket) and its poller, `turbo_stream_from` and the other stream helpers, `Controller#turbo_stream` | core |
| `require "cybertrain/feeds"` | `WebSocket.subscribe` feeds, `Background`, the feeds role, the feed health check | core |
| `require "cybertrain/mailer"` | `Mailer.deliver` | core |
| `require "cybertrain/mailer/later"` | `deliver_later` | mailer, jobs |
| `require "cybertrain/cache"` | `Cache`, its prune | core |
| `require "cybertrain/rate_limit"` | `Controller.rate_limit` | cache |
| `require "cybertrain"` | all of the above | |

Requires are order-insensitive and repeatable. Each line is what Rails users
would expect from the name. `cybertrain/mailer`, `mailer/later`, `cache` and
`rate_limit` are today's files; `core`, `jobs`, `streams` and `feeds` are new
entry files.

What a missing line does:

- Ruby code that names a missing subsystem (`ReportJob.perform_later`,
  `Stream.broadcast_append_to`, `Mailer.deliver`, `rate_limit to:`) is a
  compile error naming the constant or method. The guide's table maps each to
  its line.
- A view helper of a missing subsystem stops `spin run gen` (decision 4).
- `./NAME worker`, `./NAME feeds` and `./NAME jobs` without the subsystem
  print "the worker role needs `require "cybertrain/jobs"` in bin/NAME.rb"
  (and so on) and exit 1, instead of "unknown command".
- `/up` reports only on what is loaded: no worker staleness without jobs, no
  feed staleness without feeds.

## 4. How the core stays ignorant of the subsystems

The core must not name a subsystem's class anywhere, or naming it pulls it
into the program. Two mechanisms, both already used in the framework.

**A feature registry with overridable hooks.** `Cybertrain::Feature` is a
base class in the core whose methods do nothing and return a fixed type;
`Cybertrain::Features` holds the registered instances in an Array and calls
each hook on each of them. A subsystem's entry file defines a subclass that
overrides the hooks it needs and registers one instance at require time,
once (a second require is a no-op). This is the shape of
`HttpClient.gzip=` with `gzip_ffi` (D55), which compiles and dispatches; the
plan's first task checks the Array-of-base-class dispatch under the pinned
Spinel before anything else is built on it. Blocks are not stored on
features: spikes/NOTES.md rule 88 (Z in spinel-feedback.md) is a stored
block calling a method through a base-class receiver, which runs the base
stub. Where a scheduler task is needed, its block calls a module method with
an index (`Features.run_periodic(i, now)`), which dispatches outside the
block.

The hooks, each replacing a direct reference the spike had to cut:

| Hook | Called from | Replaces |
| --- | --- | --- |
| `boot_problem(app) -> String` | `Application#validate_boot` | `Scheduler.job_kinds_error`, `Background.boot_problem` |
| `start(app)`, `stop`, `request_stop` | the server role's boot, shutdown and TERM trap | `Scheduler`/`Job` thread start and stop, `Job.request_stop`, `Stream::Poller.start!`/`stop!`, `Background.start_all`/`stop_all` |
| `failed? -> Bool` | `Roles.wait_stop` | `Background.feeds_failed?` |
| `health_problem(now) -> String` | the `/up` middleware | the worker and feed staleness checks |
| `call(request) -> Response or nil` at the stream endpoint's position | the middleware stack | mounting `Stream::Endpoint` |
| `command(name, argv) -> Integer` (−1: not mine), `commands -> rows for help` | `Main.run` | the `worker`, `feeds` and `jobs` arms |
| `helper(name, args, ...)` | the template helper dispatch, after its own arms | the `turbo_stream_from`, `turbo_stream`, `signed_stream_name`, `stream_source_path` arms and the `TurboStreamBuilder` arm |
| `periodic_name`, `periodic_interval`, `periodic(now)` | the jobs feature's scheduler, one task per feature that declares one | `Cache.register_prune_task`'s direct `Scheduler.every` |

The exact signatures follow the code they replace (one return type per method
name across the program, rules 10, 34 and 41); the plan pins them.

**Reopening a class.** Methods that belong to a subsystem but live on a core
class move to the subsystem's file, which reopens the class:
`Controller#turbo_stream` to streams, `Controller.rate_limit` and the rate
check of `run_one` to rate limiting (the core keeps a hook the rate-limit
file overrides), `Mailer.deliver_later` to `mailer/later` (already so).

**The cache without jobs.** With the jobs feature loaded, the cache declares
its prune as a periodic hook and it runs on the scheduler as today, with the
same task name and interval. Without it, `Cache.write` prunes expired rows
when `cache_prune_interval` has passed since the last prune, in the same
statement budget as today's task, so a busy cache never grows past what the
scheduled prune allowed.

## 5. gen and the generators

- gen reads `bin/NAME.rb` (NAME from spin.toml) lexically for
  `require "cybertrain"` and `require "cybertrain/..."` lines. `cybertrain`
  means all subsystems. Its view scan (the one behind gen/views.rb's helper
  checks) gains a table of helper name to subsystem; a helper whose subsystem
  is not loaded fails gen with
  `app/views/articles/show.html.erb:3: turbo_stream_from needs require "cybertrain/streams" in bin/blog.rb`.
  The table is one constant read by gen and by the runtime's error message.
  `--check` refuses the same way.
- `cybertrain new` writes `require "cybertrain/core"`.
- `generate job` adds `require "cybertrain/jobs"`, `generate authentication`
  adds `require "cybertrain/rate_limit"`, when `bin/NAME.rb` has neither that
  line nor `require "cybertrain"`. The line goes after the last
  `require "cybertrain..."` line, and the generator prints it as it does a
  route.
- `examples/blog` and the playground keep `require "cybertrain"`.

## 6. What does not change

Behaviour of an application that requires `cybertrain`, `cybertrain build`,
the dev rebuild loop, the generated code of gen (other than the refusal),
the HTTP contract, the deploy files.

## 7. How it is checked

- A Spinel program per subsystem boundary: the core alone compiles and serves
  a page; each subsystem line added alone compiles; the full set behaves as
  `require "cybertrain"` (the existing suite already requires `cybertrain`
  and must pass unchanged).
- gen refuses a view helper of a missing subsystem, and accepts it with the
  line; generators add their line once.
- The cache prunes without jobs (a test with a fixed clock).
- The measurement of section 1 repeated on the real implementation: a
  scaffolded application with `cybertrain/core` against one with
  `cybertrain`, recorded in docs/performance-next.md.

## 8. Not in this change

Making the core itself smaller (sessions, CSP, the console, `db` in the
binary), a `bin/db.rb` that requires only the migrator, and moving
`examples/blog` to the explicit list.
