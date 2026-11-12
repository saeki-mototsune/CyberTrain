# Phase 5 of the Rails-gap programme: tests and operations

Date: 2026-11-11. Status: agreed with the maintainer (thirteen questions,
2026-11-11); the plans follow, one per part.

## 0. Context and scope

The programme (docs/design.md D1, revised 2026-11-05) delivers the 120 items
of the fin_dash survey in five phases. Phase 1 landed on 2026-11-05 (D36 to
D41), phase 2 on 2026-11-07 (D42 to D50), phase 3 on 2026-11-10 (D51 to
D57), phase 4a on 2026-11-11 (D58 to D63); phase 4b (D79, D80) is being
implemented on this branch. This document is **phase 5**, the last: the
programme paragraph names "setup / teardown, frozen time, component tests,
assertions, error reporting, log tags". The survey's chapters 15
(observability and operations) and 16 (tests) hold these. Two deferrals join
them: N-2, the ActiveSupport time helpers phase 2 sent here "with frozen
time, after a spike on adding methods to Integer and Time" (phase 2 spec
section 15), and the inline job mode for tests that phase 3 left out (phase
3 spec section 15).

Phase 5 is one design and **two plans and two pull requests**:

- **5a, tests:** the clock and the time helpers, the configured time zone,
  Rails-shaped test classes with `setup` / `teardown`, database isolation,
  fixtures, `cybertrain test` (one binary for an application's tests),
  `render_inline` / `assert_select` / broadcast assertions, and the
  remaining assertions, mail and job helpers and receivers (T-1 in part,
  T-2, T-3, T-4 in part, T-5, T-6, N-2).
- **5b, operations:** log lines with time, level and tags, the request id,
  and error reporting with a built-in Sentry-protocol sender (O-2, O-3).
  5a comes first: 5b's tests use its clock and its test classes.

**Out** (section 17): coverage (T-7), static analysis (O-4), cross-building
(O-5), performance tracing and sending warning-level logs (the rest of
O-2), parallel test processes and bundling the framework's own suite (the
rest of T-1; the spike measures the latter), replacing a class's `new` with
a fake (the rest of T-4). O-1, the console, was phase 1's (D41).

The criteria of the earlier phases decide every judgement call here as
well, in this order: **closer to Rails** (vocabulary, defaults, file
layout, what a Rails developer types) and **easier to understand**.
Compatibility with applications on 0.4 carries low weight (section 18
lists each break).

Where Spinel forbids the Rails mechanism, the Rails vocabulary is kept and
the mechanism is the framework's own: build-time generation from a lexical
scan into `case` tables (D4, D8, D38), never a computed `send` or a
`constantize` (spikes/NOTES.md rule 1), never a block stored on an object
and run through a base-class receiver (rule 88), one return type per method
name across the program (rules 10, 34, 41). Phase 5 leans on two more
records: class methods added to a core class from Ruby source compile and
dispatch (rule 87: `Time.current`, `Date.current`), and a `Thread.current`
slot works as a per-green-thread store (rule 102: the request id and the
log tags).

## 1. The decisions in one table

| # | Question | Decision |
| --- | --- | --- |
| Q1 | Scope | T-2, T-3, T-5, T-6, O-2, O-3; N-2; inline job execution for tests; from T-4 the automatic stop of receivers and `Mailer.deliveries`; from T-1 one binary for an application's tests. Out: T-7, O-4, O-5, performance tracing, sending warning logs, parallel test processes, bundling the framework's own suite |
| Q2 | Database isolation | Before each test the framework deletes every table's rows and resets the sequences (gen knows the tables from the schema); not a transaction rollback. Order: clear → fixtures → `setup` → body → `teardown`, and teardown always runs |
| Q3 | Clock | `Cybertrain::Clock` is the one seam; `Time.current` reads it; every `Time.now` of the framework runtime goes through it and the five existing seams fold into it; wait loops stay on real time; `travel_to`, `travel`, `freeze_time`, `travel_back`, restored after each test; spike on overriding `Time.now` |
| Q4 | Durations | `5.minutes` is Integer seconds; seconds to weeks and the singulars; `.ago` / `.from_now` return Time on the Clock; no `months` / `years` on Integer (a build error), calendar-aware `months_ago`, `advance(months:)` and friends on Time; `Time.current`, `beginning_of_*` / `end_of_*`, `yesterday` / `tomorrow`, `Date.current` |
| Q5 | Time zone | `c.time_zone` (`CYBERTRAIN_TIME_ZONE`, `"UTC"`), `Time.zone`; Time stays a UTC instant (no TimeWithZone); boundaries computed in the zone's calendar; `l` and `time_tag` render in the zone, `l(t, zone:)` once; `scheduler_tz` defaults to it; `time.in_time_zone` returns a small value object |
| Q6 | Component tests | `render_inline(component)` and `render_inline(partial:, locals:)`; `assert_select` over the last render or response, backed by a test-only tag reader; a fixed selector subset with `count:` / `minimum:` / `maximum:` / `text:`; `assert_broadcasts`, `assert_no_broadcasts`, `assert_turbo_stream`; channel tests are stream tests |
| Q7 | Assertions | `assert_in_delta`, `assert_match` / `assert_no_match`, `assert_not_equal` / `_nil` / `_includes`, `assert_empty` / `assert_not_empty`, `assert_nothing_raised`, lambda-only `assert_difference` / `assert_no_difference` / `assert_changes`; no `assert_predicate`; `assert_raises(Class)` if the spike allows; `Mailer.deliveries`, `assert_emails`, `assert_no_emails`; `perform_enqueued_jobs do end`; receivers stop at the end of a test; better failure output |
| Q8 | One binary | `cybertrain test` bundles `test/**/*_test.rb` and `test/*.rb` into one program compiled once; file and `-n` filters at run time; per-file headings, file and line on failures; duplicate top-level helpers refused; `spin test` per file still works; `cybertrain new` writes `test/test_helper.rb` and a sample test |
| Q9 | Logs | `2026-11-11T12:00:00.123Z INFO [3f2a9c1e...] message` on STDOUT; a request id generated or accepted from a trusted proxy, echoed, thread-local; jobs `[JobClass id]`, feeds `[feed:name]`; `c.log_tags`, `tagged`, five levels, `CYBERTRAIN_LOG_LEVEL`; a mutex around writes; `c.log_format = :json` |
| Q10 | Error reporting | `Cybertrain.error.report` / `handle` / `subscribe` with `Cybertrain::ErrorSubscriber`; a Sentry-protocol sender behind `CYBERTRAIN_SENTRY_DSN`; automatic for 500s, jobs, scheduled tasks, feeds, mail; class, message, where, request id, method, path, environment, release, nothing personal; a bounded queue on its own thread, dedupe, `c.error_sample_rate`; a backtrace only if `--debug` builds give one |
| Q11 | Test file shape | `ActiveSupport::TestCase`, `ActionDispatch::IntegrationTest`, `ViewComponent::TestCase`; gen rewrites `test "..." do`, `setup do`, `teardown do` into methods (rule 88); helpers and ivars per class; the top-level form keeps working; generators write the class form; spike, falling back to the top-level DSL with `setup` / `teardown` |
| Q12 | Fixtures | `test/fixtures/<table>.yml` read by gen with 4b's YAML subset reader; per-test inserts after the clear; `articles(:one)`; `belongs_to` by label with ids derived from the label; all loaded for every test; timestamps filled; ERB refused; generators write fixtures |
| Q13 | Split and acceptance | 5a (tests) then 5b (operations), one design, two plans and PRs; acceptance through the blog, the generators, the spike, the suite, guides in five languages, design.md D66 onwards and implementation notes here |

# Part 5a

## 2. The clock and time travel (T-3)

### 2.1 What a test writes

Rails' `ActiveSupport::Testing::TimeHelpers`, with Rails' names:

```ruby
test "a remembered session survives day 15" do
  sign_in_as users(:ann), remember: true
  travel_to 15.days.from_now do
    get root_path
    assert_response :success
  end
end

test "the cache entry expires" do
  freeze_time
  Cybertrain::Cache.write("k", "v", expires_in: 5.minutes)   # Rails.cache.write in Rails
  travel 6.minutes
  assert_nil Cybertrain::Cache.read("k")
end
```

- `travel_to(time) { }` sets the clock to `time` and holds it there; with a
  block, the previous state comes back when the block ends (also when it
  raises).
- `travel(seconds) { }` is `travel_to(Time.current + seconds)`.
- `freeze_time { }` is `travel_to(Time.current)`.
- `travel_back` returns to real time.
- Without a block, the travel lasts until `travel_back` or the end of the
  test: the runner calls `travel_back` after `teardown`, whatever happened.
- As in Rails, all three freeze the clock (time does not move during the
  travel) and drop the sub-second part (Rails' `with_usec: false`).
  Nested block forms are allowed; each restores what it found.

They are top-level methods, as the other assertions are, so they work in
the class form (section 5) and in the top-level form alike.

### 2.2 `Cybertrain::Clock`

The one seam. `Cybertrain::Clock.now` answers a UTC `Time`: real time, or
the travelled instant. `Clock.travel_to(time)`, `Clock.travel_back` and
`Clock.travelling?` are what the test helpers call; an application never
needs them. The state is two module-level ivars (rules 18 and 64): a flag
and the instant as Integer microseconds since the epoch (an ivar holding a
nullable `Time` miscompiles, rule 7). Real time is read with
`Process.clock_gettime(Process::CLOCK_REALTIME)`, never through `Time.now`,
so that an override of `Time.now` (spike item 1) cannot recurse.

`Time.current` (rule 87: a class method added to `Time` from Ruby source)
is `Cybertrain::Clock.now`. Rails' `Time.current` answers a TimeWithZone;
here it answers a plain UTC `Time` (section 4).

### 2.3 What follows the clock

Every `Time.now` of the framework runtime (survey: 47 non-comment lines
outside cli/, generator/ and test/) goes through `Clock.now`, among them:

- `created_at` / `updated_at`: `Model.now_string` (model.rb), used by
  `Model#save` and the bulk writes;
- the cache's expiry and pruning (`Cache.now`);
- rate limits, both stores;
- the session's lifetime checks in `SessionStore` (phase 4b's per-session
  limit, idle timeout and `last_active_at` included);
- jobs: `Job.enqueue`'s `run_at:` default, the claim, `perform_in`, `perform_enqueued_jobs`' default `now`;
- `Cybertrain::Token.issue` / `Token.valid?` (their `now` default);
- the scheduler's due check, the stream table's row timestamp, the jobs
  page's ages, `time_ago_in_words`, the mail `Date` header, `feeds status`,
  the health check, the log line's timestamp (section 12);
- phase 4b's authentication code generated into an application (password
  reset expiry, lockout period, remember-me lifetime) reads `Time.current`.

Explicit `now` parameters (`Job.work_one(now)`, `Scheduler.run_due(now)`,
`Cache.prune(now)`, `Lease.acquire(name, holder, now, ttl:)`,
`Cron.next_after`) stay; their callers pass `Clock.now`.

The five separate seams fold into the Clock and are removed:
`Cache.clock=` / `Cache.system_clock`, `RateLimit.current_time=`,
`SessionStore#fixed_now=`, `Application.status_now=` and
`Background.supervisor_clock=` (section 18).

**What stays on real time.** Waiting and measuring are not "the current
time": deadline and timeout loops (`Stream::Hub`, the WebSocket server's
ping and close timers, `Test::MemorySink`, the receivers, the HTTP
server's drain, `HttpClient`'s deadlines, the job poll and the
supervisor's backoff) and elapsed-time measurements (the request log's
milliseconds) use the monotonic clock,
`Process.clock_gettime(Process::CLOCK_MONOTONIC)`. Sites among them that
read `Time.now.to_f` today move to it, so a frozen clock can never hang a
wait.

### 2.4 `Time.now` itself

Spike item 1 decides:

- **If a Ruby-source `def self.now` on `Time` overrides the builtin under
  Spinel:** `cybertrain/test_help` (section 5.1) defines it to answer
  `Clock.now`, so during a travel `Time.now`, and every library call that
  reads it, follows too, as in Rails. Only test programs require that file;
  a production binary keeps the builtin.
- **If not:** `Time.now` stays real time and the guide says so: during a
  travel only `Time.current` and the framework's own times follow, so
  application code that should be testable under travel uses
  `Time.current` (Rails' advice anyway).

`Date.today` is the system's date in both cases; `Date.current` (section
3.2) is the one that follows the clock and the zone.

## 3. Durations and time helpers (N-2)

### 3.1 Integer durations

```ruby
5.minutes          # => 300
1.day              # => 86400
2.weeks.ago        # => Time, 14 days before Time.current
3.days.from_now    # => Time
Time.current + 90.seconds
```

- `seconds`, `minutes`, `hours`, `days`, `weeks` and the singulars
  `second` ... `week` are methods on Integer answering Integer seconds.
  Rails answers an `ActiveSupport::Duration`; here a duration is an
  Integer, so `5.minutes == 300` and `5.minutes.inspect` is `"300"`.
- `Integer#ago` and `Integer#from_now` answer a `Time` on the Clock
  (`Clock.now - self`, `Clock.now + self`); so `300.ago` works as
  `5.minutes.ago` does.
- `month(s)` and `year(s)` are not defined on Integer: a month has no fixed
  length in seconds, and an Integer cannot carry "one calendar month".
  Calling `1.month` is a build error under Spinel (spike item 2 confirms
  the refusal) and `NoMethodError` under CRuby. The calendar-aware forms
  below replace it; the guide shows `1.month.ago` → `Time.current.months_ago(1)`.

### 3.2 Time and Date additions

On `Time` (instance methods, all answering a UTC `Time`):

| Method | Meaning |
| --- | --- |
| `beginning_of_day` / `end_of_day` | 00:00:00 / 23:59:59.999999 of the instant's day in `Time.zone` |
| `beginning_of_week` / `end_of_week` | Monday 00:00 / Sunday's end (Rails' default week start) |
| `beginning_of_month` / `end_of_month` | |
| `beginning_of_year` / `end_of_year` | |
| `advance(years: 0, months: 0, weeks: 0, days: 0, hours: 0, minutes: 0, seconds: 0)` | years, months, weeks and days move the wall date in the zone's calendar (31 January plus one month is 28 or 29 February, as Rails); hours, minutes and seconds add elapsed seconds |
| `months_ago(n)` / `months_since(n)` | `advance(months: -n)` / `advance(months: n)` |
| `years_ago(n)` / `years_since(n)` | `advance(years: -n)` / `advance(years: n)` |
| `yesterday` / `tomorrow` | `advance(days: -1)` / `advance(days: 1)` |
| `in_time_zone(zone = Time.zone)` | a `Cybertrain::ZonedTime` (section 4) |

Class methods (rule 87): `Time.current` (section 2.2), `Time.zone`
(section 4), `Date.current` (today in `Time.zone` on the Clock).

A wall time that a zone's transition skips moves forward by the gap; one
that occurs twice takes the earlier instant (ActiveSupport's choice for
`Time.zone.local`). Arithmetic uses D19's `Cybertrain::TimeZone`
(`TimeZone.find`, `utc_offset_at`, `civil_to_epoch`).

## 4. The configured time zone

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.time_zone = "Asia/Tokyo"
end
```

- `c.time_zone`, from `CYBERTRAIN_TIME_ZONE`, default `"UTC"`: an IANA
  name; boot refuses one the system zoneinfo does not have (as for
  `scheduler_tz`). Rails' `config.time_zone` takes Rails' own names
  ("Tokyo"); here IANA names only.
- `Time.zone` answers the `Cybertrain::TimeZone` for it. Its name is
  `Time.zone.zone_name` (Rails: `Time.zone.name`; `name` is left alone, as
  every class answers `name`, rules 10 and 34).
- **Values stay UTC instants.** There is no TimeWithZone: a `Time` read
  from a column, `Time.current` and every method of section 3.2 answer a
  UTC `Time`. `time.hour` is the UTC hour (Rails: the zone's hour); the
  guide states this difference first.
- **Boundaries are the zone's.** `beginning_of_day` and the others compute
  the day, week, month or year in the zone's calendar and answer its first
  instant as UTC: with `"Asia/Tokyo"`, `Time.utc(2026, 11, 11, 20).beginning_of_day`
  is `2026-11-11 15:00:00 UTC` (midnight of 12 November in Tokyo).
  `Date.current` is today in the zone.
- **Reading wall fields.** `time.in_time_zone` (or `in_time_zone("Europe/London")`)
  answers a `Cybertrain::ZonedTime`, a small value with `year`, `month`,
  `day`, `hour`, `min`, `sec`, `wday`, `yday`, `utc_offset`, `zone`
  (the abbreviation), `to_time` (the UTC instant) and `to_date`. It is not
  a Time: it has no arithmetic and is not stored.
- **Display.** `l(time)` and `time_tag(time)` render in `Time.zone`: the
  strftime fields, `%z` and `%Z` are the zone's, and `time_tag`'s
  `datetime` attribute is ISO 8601 with the zone's offset
  (`2026-11-12T05:00:00+09:00`). One call in another zone:
  `l(time, zone: "America/New_York")`, `time_tag(time, zone: "...")`. A
  `Date` is rendered as is.
- **Schedules.** `scheduler_tz` (`CYBERTRAIN_SCHEDULER_TZ`) defaults to
  `time_zone` when unset; a cron task's `tz:` still wins.
- Storage is unchanged: datetime columns hold UTC text (D46).

## 5. Test classes, setup and teardown (T-2)

### 5.1 What a test file looks like

Rails' classes and file layout:

```ruby
# test/test_helper.rb (written by `cybertrain new`)
ENV["CYBERTRAIN_ENV"] ||= "test"
require_relative "../config/app"
require "cybertrain/test_help"

class ActiveSupport::TestCase
  fixtures :all

  # Helper methods used by all tests go here.
end
```

```ruby
# test/controllers/articles_controller_test.rb
require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = articles(:one)
  end

  test "shows an article" do
    get article_path(@article)
    assert_response :success
    assert_select "h1", text: @article.title
  end

  test "creates an article" do
    assert_difference -> { Article.count }, 1 do
      post articles_path, params: { article: { title: "New", body: "A body long enough" } }
    end
    assert_redirected_to article_path(Article.last)
    follow_redirect!
    assert_response :success
  end

  private

  def title_of(article) = article.title.upcase
end
```

- **`ActiveSupport::TestCase`**: models, jobs, mailers, anything else.
  Every assertion of section 10, the time helpers, the fixture accessors.
- **`ActionDispatch::IntegrationTest < ActiveSupport::TestCase`**:
  `get`, `post`, `patch`, `put`, `delete`, `head`(path, `params: {}`,
  `headers: {}`) as Rails spells them, `follow_redirect!`, `response`,
  `assert_response(:success)` and `assert_redirected_to(path)` on the last
  response, `cookies`, and the application's path helpers (the bundle
  includes the generated `Gen::UrlHelpers`). `params:` takes a Hash whose
  values are Strings or nested Hashes (encoded `article[title]=New`). The
  requests go through `Cybertrain::Test::Client` in process (no socket),
  one client per test, against the application the bundle booted.
- **`ViewComponent::TestCase < ActiveSupport::TestCase`**: `render_inline`
  (section 9).
- `fixtures :all` is accepted and does nothing: every fixture is loaded for
  every test (Q12, section 7). `require "test_helper"` is accepted (gen
  drops it from the copy it compiles, as the bundle requires the helper
  first).
- An application may put its own base class in `test/test_helper.rb` or
  `test/support/` (`class ApplicationIntegrationTest < ActionDispatch::IntegrationTest`)
  and inherit from it.
- `cybertrain/test_help` requires the harness, the client, the job helpers,
  the views helper, the receivers' base and the classes above.

### 5.2 What gen does with a class-form file

A `test "..." do` inside a class body, under Spinel, would store a block on
the class and later call it with a base-class receiver: rule 88's shape
(the base's stub of a helper would run instead of the subclass's), and
rule 2's (no `instance_exec`) makes the block unable to reach the test's
instance variables at all. So gen rewrites the file, as phase 4 did for
concerns, into `gen/test/<path under test/>`:

```ruby
# gen/test/controllers/articles_controller_test.rb (generated)
class ArticlesControllerTest < ActionDispatch::IntegrationTest
  def setup
    super
    @article = articles(:one)
  end

  def test_shows_an_article
    get article_path(@article)
    ...
  end
  ...
end
```

- `test "name" do ... end` becomes `def test_<name>` with every character
  outside `[A-Za-z0-9_]` turned into `_` (Rails' rule, so `-n
  test_shows_an_article` names the same test as in Rails). Two tests whose
  method names coincide in one class are refused, naming both lines (Rails
  raises too).
- `setup do ... end` blocks become one `def setup` that calls `super`
  first and then the blocks' bodies in order; `teardown do ... end` blocks
  become one `def teardown` that runs the bodies in reverse order and then
  `super` (ActiveSupport's callback order). A class that writes both
  `setup do` and `def setup` is refused, naming both.
- Everything else in the class body (helper `def`s, `private`, constants,
  `include`) is copied unchanged: helpers and instance variables belong to
  the class, and each test runs on a new instance (Minitest's model).
- Line numbers are kept: the copy pads so that each test method starts on
  the line of its `test` call, and the runner's table records the original
  file and line.
- gen also writes `gen/tests.rb`, the program `cybertrain test` compiles
  (section 8): it requires the framework, `config/app.rb`, gen's outputs,
  `test/test_helper.rb`, `test/support/**/*.rb`, the copies and the
  top-level-form files, then a generated `case` over every test (rule 1):

  ```ruby
  when 7
    t = ArticlesControllerTest.new
    if Cybertrain::Test.before_case(t)        # clear, fixtures, t.setup
      Cybertrain::Test.run_body(t) { t.test_shows_an_article }
    end
    Cybertrain::Test.after_case(t)            # t.teardown, travel_back, receivers
  ```

  `t` is the concrete class in each arm, so `t.test_...` is a direct call;
  `setup` and `teardown` are ordinary overrides called through the base
  (`ActiveSupport::TestCase` defines both empty), which dispatches to the
  subclass as any virtual call does: no stored block meets a base-class
  receiver.

### 5.3 The order of one test

1. The database is cleared (section 6).
2. The fixtures are inserted (section 7).
3. `Mailer.deliveries`, the in-memory rate-limit counters
   (`RateLimit.reset_all!`) and `I18n.locale` are reset, and from 5b the
   log tags.
4. `setup` (the superclass's first).
5. The test body, if setup did not fail.
6. `teardown`, **always**: after a failed assertion, an exception in the
   body, or a failure in setup.
7. `travel_back`; every receiver the test started is stopped (section 10).

A failure in step 1, 2 or 4 reports the test as `ERR` with the step named;
a failure in `teardown` is reported too, after the body's.

### 5.4 The top-level form

Today's shape keeps working unchanged, in the bundle and under `spin test`:

```ruby
setup do
  Cybertrain.config.http_allow_private = true
end

teardown do
  Cybertrain.config.http_allow_private = false
end

test "title must be present" do
  refute Article.new(body: "x" * 20).save
end

Cybertrain::Test.run!
```

Top-level `setup do` / `teardown do` register into `Cybertrain::Test`'s
module state, as `test` does; their blocks take no receiver and are called
as plain Procs (today's safe form), before and after every case of the
file that declared them. This is also the spike's fallback for the class
form (spike item 3). In the bundle, `Cybertrain::Test.run!` at the end of
a file does nothing (the bundle runs every test once at its end); under
`spin test` it runs the file's cases as today. Locals in top-level blocks
of different files share a type in one program (rule 63), which the spike
(item 6) measures.

## 6. Database isolation (T-2)

Before each test, after the previous test's teardown:

- every table of `db/schema.rb` loses its rows (`DELETE FROM`), with
  `PRAGMA foreign_keys = OFF` around the deletes so the order does not
  matter; gen writes the table list into `gen/test/data.rb` from the schema
  it already reads;
- the framework's own tables lose theirs too when they exist
  (`cybertrain_jobs`, `cybertrain_cache`, `cybertrain_messages`,
  `cybertrain_schedules`, `cybertrain_feeds`, `cybertrain_leases`): the
  cache, queued jobs and broadcasts do not leak between tests;
- `sqlite_sequence` is emptied, so ids start again at 1.

All of it is one transaction on the test thread's connection.

**Not Rails' transaction.** Rails wraps each test in a transaction rolled
back at the end. That does not fit here: SQLite in this framework has no
savepoints (db.rb, connection.rb), so a test's own `transaction` would end
the wrapping one; job threads, the stream poller and feeds use other pooled
connections and would not see the test's rows; and `Job.install!` and the
other `CREATE TABLE IF NOT EXISTS` would be rolled back with the test
(cache.rb's note on `DB.generation`). Deleting before each test costs one
statement per table (the blog: 2 application tables and 6 framework ones).
D13's "Revised 2026-09-27" note already records that the rollback was not
built.

The database itself is created once per run: the bundle deletes
`storage/test.sqlite3` and its `-wal` / `-shm`, migrates a new one and
boots the application on it before the first test (what the generated
`AppTest.boot` does today). The application is booted with no job,
scheduler or feed threads, as `Application#boot` does today: jobs run
when a test runs them (section 10).

## 7. Fixtures

```yaml
# test/fixtures/users.yml
alice:
  email_address: alice@example.com
  admin: true

# test/fixtures/articles.yml
one:
  title: First post
  body: A body long enough to pass the length check.
  author: alice
  created_at: 2026-11-01 09:00:00

two:
  id: 42
  title: Second post
  body: Another body long enough.
  author: alice
```

- **Files.** `test/fixtures/<table>.yml`, Rails' shape: labels at the top,
  columns under them. gen reads them at build time with 4b's YAML subset
  reader (`Gen::LocaleYaml`); the subset's refusals apply, with file and
  line. A file whose name is not a table of the schema, and a key that is
  neither a column nor a `belongs_to` of the table's model, are refused
  with file and line.
- **ERB is refused** (`<%` anywhere in the file), with file and line:
  there is no `eval` (design.md section 8). A fixture that needs a time
  relative to now sets it in `setup` or uses `travel_to`.
- **Ids.** A row without `id:` gets Rails' id for its label:
  `Zlib.crc32(label) % (2**30 - 1)` (`ActiveRecord::FixtureSet.identify`),
  computed by gen with a pure-Ruby CRC-32, so a label has the same id as in
  a Rails application. Two labels of one table with the same id are
  refused, naming both.
- **`belongs_to` by label.** `author: alice` sets `author_id` to alice's
  id, as Rails does; gen knows the association from the model scan
  (phase 2's `belongs_to`). The label is not checked against the other
  file (Rails does not either); a missing parent shows as a foreign-key
  failure when the test runs.
- **Values** are converted by the column's type from the schema: strings
  and text as written, integers and decimals, booleans (`true` / `false`),
  dates and datetimes (`2026-11-01 09:00:00`, read as UTC), json as the
  scalar text. `created_at` and `updated_at`, when the table has them and
  the fixture does not, are the Clock's time at insert.
- **Loading.** gen writes the inserts into `gen/test/data.rb` as literal
  SQL, run after the clear of each test (all fixtures for every test,
  Rails' `fixtures :all`), with foreign keys off during the insert as
  Rails' `disable_referential_integrity` does.
- **Accessors.** `articles(:one)` answers `Article.find(<one's id>)`;
  `articles(:one, :two)` is not offered (one label per call); an unknown
  label raises `Cybertrain::Test::FixtureNotFound` "No fixture named
  'three' found for fixture set 'articles'". gen writes one method per
  fixture file into a module that `ActiveSupport::TestCase` includes and
  the top-level form reaches too. Spike item 3 checks the accessor's name
  beside a `has_many :articles` association of the same name (rules 10 and
  34).

## 8. `cybertrain test`: one binary (T-1)

```text
$ cybertrain test
$ cybertrain test test/controllers/articles_controller_test.rb
$ cybertrain test -n "creates an article"
$ cybertrain test -n test_creates_an_article
$ cybertrain test -n /article/
```

- **One program.** `cybertrain test` runs `spin run gen` (which writes
  `gen/tests.rb` and `gen/test/**`, section 5.2), compiles `gen/tests.rb`
  into `build/test/tests` when any input is newer than the binary, and runs
  it with the remaining arguments. Every `test/**/*_test.rb` and every
  `test/*.rb` other than `test/test_helper.rb` is in it, each once; gen
  tells the forms apart by content (a class inheriting one of section
  5.1's classes is the class form). `test/support/` and `test/fixtures/`
  are not tests. An application with 50 test files
  compiles once, about the cost of one `cybertrain build` (D34, docs/benchmark.md),
  instead of 50 times.
- **Filters at run time, no recompile.** File arguments keep the tests of
  those files; `-n NAME` keeps the tests whose name, or method name, is
  `NAME`; `-n /TEXT/` keeps those whose name contains `TEXT`. Both combine
  (a file and a name). Changing a filter reuses the binary.
- **Output.** A heading per file, then a line per test, then the totals;
  no timings, so the output is deterministic:

  ```text
  test/controllers/articles_controller_test.rb
    ok   ArticlesControllerTest: shows an article
    FAIL ArticlesControllerTest: creates an article (test/controllers/articles_controller_test.rb:18)
         Expected: 1
           Actual: 0
  test/models/article_test.rb
    ok   ArticleTest: title must be present

  3 tests, 9 assertions, 1 failure
  ```

  The line is the test's `test "..."` line: without a backtrace (Spinel's
  release builds have none, section 13.3) the assertion's own line is not
  known. The exit status is 1 when anything failed, 0 otherwise; 0 tests
  is not a failure.
- **Duplicate top-level helpers.** Two files in one program that define
  the same top-level method or constant (each test file today defines
  `new_client`, `CLOCK`, `SEEN`) would merge into one (rules 10, 41); gen
  refuses the bundle and names both files and lines. Shared helpers go in
  `test/support/`; a helper of one class goes inside the class.
- **`spin test` per file** still compiles and runs one top-level-form file
  against its `.expected`, as today, with top-level `setup` / `teardown`
  but without the clear and the fixtures, which are the bundle's (they
  need gen's table list). A class-form file is run on its own
  with `cybertrain test FILE` (the bundle, filtered), since its class body
  compiles only after gen's rewrite.
- The generated CI runs `cybertrain test` (section 11).
- The framework's own 184 programs keep `spin test` and the shards (D34);
  spike item 6 measures how many could share one binary.

## 9. Component and stream tests (T-5)

### 9.1 `render_inline`

```ruby
class CardComponentTest < ViewComponent::TestCase
  test "renders the title" do
    render_inline(CardComponent.new(title: "Hello"))
    assert_select "div.card > h2", text: "Hello"
  end

  test "renders the form partial" do
    html = render_inline(partial: "articles/form", locals: { article: Article.new })
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
    assert_includes html, "Save"
  end
end
```

- `render_inline(component, content: "")` renders a component detached
  from any request (`Views.render_component`, phase 1); `render_inline(partial:
  "articles/form", locals: {})` renders a partial (`Views.render_partial`).
  Both answer the HTML String and keep it as the last rendered HTML for
  `assert_select`. Rails' `render_inline` answers a Nokogiri fragment and
  takes the component's content as a block; here it answers a String and
  takes `content:` (phase 1's `Test.render_component` signature).
- Request-bound helpers raise `Views::OutsideRequest`, as today.
- `Test.render_partial` and `Test.render_component` stay.

### 9.2 `assert_select`

`assert_select(selector, equality = nil, count: nil, minimum: nil,
maximum: nil, text: nil)` checks the most recent of: the last
`render_inline` result, the last response body of an integration test.

- **Selectors**: a tag (`h1`), `.class`, `#id`, `[attr]`, `[attr="v"]`
  (also single quotes), compounds (`a.btn[href="/x"]`), descendant
  (`ul li`) and child (`ul > li`) combinators, and a list (`h1, h2`).
- **Options**: `count: n` exactly n matches; `minimum:` / `maximum:`
  bounds; `text:` a String compared with each match's text after
  collapsing whitespace and stripping (Rails' default), or a Regexp. The
  default is at least one match. As in Rails, the second positional
  argument may be a String (the text), an Integer (the count) or `false`
  (no match).
- **Unsupported**, each failing with `"assert_select: <feature> is not
  supported (selector: \"...\")"`: pseudo-classes (`:first-child`,
  `:not(...)`), the sibling combinators `+` and `~`, attribute operators
  other than `=` (`^=`, `*=`, `~=`), and the nested block form
  (`assert_select "ul" do ... end`).
- **Answer**: the matched elements, an Array of `Cybertrain::Test::HtmlNode`
  (readers `node_tag`, `node_attr(name)`, `node_text`, `node_html`), for
  a test that wants to look further.
- **Failure output** names the selector, what was expected and found, and
  an excerpt: the first 500 characters of the HTML it searched.
- **The reader.** `Cybertrain::Test::HtmlReader` (cybertrain/test/html_reader.rb,
  required only by tests) reads the well-formed HTML the framework writes:
  start and end tags, void elements (`br`, `img`, `input`, `meta`, `link`,
  `hr`, ...), quoted, unquoted and boolean attributes, character
  references in text and attributes, comments and the doctype skipped,
  `script` and `style` content as raw text. It is not a repairing HTML5
  parser: a mismatched or missing end tag fails the assertion with the
  byte offset. Rails uses Nokogiri; the HTML a template writes by hand
  without closing its tags will fail here where Nokogiri would repair it.

### 9.3 Broadcasts

There is no channel concept in CyberTrain (no Action Cable analogue):
realtime is named streams (D36, D37). Rails' channel tests become stream
tests:

```ruby
test "a new comment is broadcast" do
  payloads = assert_broadcasts(articles(:one), 1) do
    post article_comments_path(articles(:one)), params: { comment: { body: "Hi" } }
  end
  assert_includes payloads[0], 'target="comments"'
end

test "a new comment answers with a Turbo Stream" do
  post article_comments_path(articles(:one)), params: { comment: { body: "Hi" } },
       headers: { "Accept" => "text/vnd.turbo-stream.html" }
  assert_turbo_stream action: "append", target: "comments"
end
```

- `assert_broadcasts(stream, count) { }` counts the rows written to
  `cybertrain_messages` for that stream while the block runs; `stream` is
  a name or a record (`Stream.name_for`). It answers the payloads. Without
  a block it counts since the test began. Reading the table means no
  poller, hub or socket is needed.
- `assert_no_broadcasts(stream) { }` is `assert_broadcasts(stream, 0)`.
- `assert_turbo_stream(action:, target:)` checks that the last response
  (or render) holds a `<turbo-stream action="..." target="...">`, as
  turbo-rails' assertion does, through the tag reader.

## 10. Assertions, mail, jobs and receivers (T-6, T-4)

New assertions, top-level methods like the existing ones:

| Assertion | Notes |
| --- | --- |
| `assert_in_delta(expected, actual, delta = 0.001)` | Minitest's default delta |
| `assert_match(matcher, string)` / `assert_no_match` | a String matcher is a substring, a Regexp is matched (the validators already use Regexp under Spinel) |
| `assert_not_equal(expected, actual)` | |
| `assert_not_nil(object)` | |
| `assert_not_includes(collection, object)` | String or Array, as `assert_includes` |
| `assert_empty(object)` / `assert_not_empty` | String, Array or Hash |
| `assert_nothing_raised { }` | reports the exception's class and message |
| `assert_difference(-> { Post.count }, 1) { }` | lambda only, passed positionally (rule 42); Rails' String expression needs `eval` |
| `assert_no_difference(-> { Post.count }) { }` | |
| `assert_changes(-> { post.reload.title }, from: "a", to: "b") { }` | lambda only; `from:` / `to:` optional, compared with `==` |
| `assert_raises(ArgumentError) { }` | if spike item 4 passes; the String form `assert_raises("ArgumentError")` stays either way |

- `assert_predicate(x, :valid?)` is not offered (it needs a computed
  `send`, rule 1): write `assert x.valid?`. `assert_not(x)` is `refute`.
- The block helpers compute the before value, `yield` into a local (rule
  90), compute the after value, and compare; none needs `ensure`. Rails'
  `assert_difference` with an Array or Hash of expressions is not offered.
- **Failure output.** `assert_equal` and `assert_not_equal` print
  Minitest's form, `Expected: <inspect>` and `  Actual: <inspect>` on two
  lines; `assert_select` prints the excerpt of section 9.2.

**Mail.** As Rails' `delivery_method = :test`:

- In the test environment `Cybertrain.config.mail_delivery_method` is
  `:test`: `Mailer#deliver` (and so `deliver_now`, `Mailer.deliver` and
  the `deliver_later` job) checks the message as today and appends a
  `Cybertrain::MailMessage` to `Mailer.deliveries` instead of connecting.
  Elsewhere it is `:smtp`. A test that wants the SMTP path (with
  `Test::SmtpReceiver`) sets `:smtp`.
- `Mailer.deliveries` is cleared before every test (section 5.3).
- `assert_emails(1) { }` counts deliveries added during the block; as in
  Rails, mail queued with `deliver_later` inside the block is delivered
  (the `cybertrain mail` jobs queued in the block are performed) before
  counting. `assert_no_emails { }` is `assert_emails(0)`.

**Jobs.** `perform_enqueued_jobs do ... end` runs the block, then performs
on the test thread every job queued during it, and the jobs those queue,
whatever their `run_at`, as Rails' block form does (the inline job mode
phase 3 deferred). The existing forms stay: `perform_enqueued_jobs(now =
Time.current)` without a block, `assert_enqueued_jobs`,
`assert_enqueued_with`, `assert_no_enqueued_jobs`, `clear_enqueued_jobs`.

**Receivers.** `Test::HttpReceiver`, `Test::SmtpReceiver` and
`Test::WebSocketReceiver` record themselves in `Cybertrain::Test` when
`start` is called inside a test; the runner calls `stop` on each after
`teardown` (section 5.3), so a failed assertion no longer leaves a
listener running until its `accept_window` ends. A receiver started at the
top of a file (outside a test) is not stopped by the runner. Fakes that
replace a class's `new` (Rails tests' `HttpClient.stub(:new, fake)`) stay
out: receivers remain the way to test outbound calls (D32).

## 11. What the generators write

- **`cybertrain new`** writes `test/test_helper.rb` (section 5.1),
  `test/integration/health_test.rb` (an integration test of `/up`), empty
  `test/fixtures/`, `test/support/` and the test environment's
  `log_level = :none` as today; the CI workflow runs `cybertrain test`.
- **`generate scaffold Article title:string body:text`** writes
  `test/fixtures/articles.yml` (two rows, `one` and `two`),
  `test/models/article_test.rb` and
  `test/controllers/articles_controller_test.rb` (index, show, new,
  create, edit, update, destroy, in Rails' scaffold test's shape).
- **`generate authentication`** writes `test/fixtures/users.yml` (two
  users with real password digests; phase 4b's admin, lockout and
  remember columns where they exist), `test/support/session_test_helper.rb`
  (`sign_in_as(user)` and `sign_out`, as Rails 8's generator writes them)
  and class-form tests for sessions, registration, passwords, accounts and
  phase 4b's remember-me and lockout, the day-15 / day-30 checks with
  `travel_to`.
- **`generate component`, `helper`, `job`, `attachment`** write the class
  form: `test/components/<name>_component_test.rb` (`ViewComponent::TestCase`),
  `test/helpers/<name>_helper_test.rb` (whose local template-rendering
  helper is renamed `render_helper_template`, section 18),
  `test/jobs/<name>_job_test.rb`, and the attachment's tests.
- No generator writes `test/support/app_test.rb` any more.

# Part 5b

## 12. Logs (O-3)

### 12.1 The line

```text
2026-11-11T12:00:00.123Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started GET "/articles" for 203.0.113.9
2026-11-11T12:00:00.135Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 12ms
2026-11-11T12:00:01.002Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 42 (WelcomeJob) attempt 1 of 5 failed: Cybertrain::Mailer::RejectedError: 550 no such user; retrying in 3 s
2026-11-11T12:00:02.410Z WARN [feed:prices] WebSocket "prices" reconnecting in 5 s
```

- The time in UTC with milliseconds and `Z` (from the Clock, so it
  follows `travel_to` as Rails' logger does), the level in capitals, the
  tags each in brackets, the message. STDOUT, flushed per line, as today;
  every level goes there (12-factor; Kamal and Docker collect it).
- The request log keeps its two lines (Started, Completed; D14) and their
  texts; only the line's shape changes. The milliseconds are measured on
  the monotonic clock.
- **Levels**: `debug`, `info`, `warn`, `error`, `fatal`.
  `c.log_level`, from `CYBERTRAIN_LOG_LEVEL` (new), default `:info`;
  `:none` keeps its meaning (no request log, errors still printed).
- **A mutex around each write** (the line is built first, outside the
  lock; the lock covers the write and the flush only), so lines from
  several threads never interleave. Rule 57 found a lock taken on every
  request stalling under `SPINEL_WORKERS=2`; spike item 9 measures this one
  with bench/run.

### 12.2 The request id

As Rails' `ActionDispatch::RequestId`:

- A new middleware, `Cybertrain::Middleware::RequestId`, outermost in the
  stack (outside `ErrorPages` and `RequestLogger`), gives every request an
  id: a UUID v4 (`SecureRandom.uuid`, Rails' choice).
- **From a proxy.** When the peer is a trusted proxy (`Config#trusted_proxy`
  / `trusted_proxies`, the same check as `request.client_ip`) and the
  request carries `X-Request-Id` made only of `[A-Za-z0-9-]` and at most
  255 bytes, that id is used, so the proxy's and the application's logs
  share it. Otherwise the header is discarded and an id is generated.
  Rails accepts the header from anyone and strips the other characters;
  here it is accepted only from a trusted proxy and never altered.
- **Echoed** in the response's `X-Request-Id`, error pages included.
- **`request.request_id`** answers it (Rails also spells it `request.uuid`;
  only `request_id` is offered).
- **Thread-local.** The id is put in a `Thread.current` slot for the
  request's duration and cleared after it, like `I18n.locale` (rule 102;
  a keep-alive connection's requests share a thread). Every line logged
  meanwhile carries it, the application's own `Cybertrain.logger.info`
  included.

### 12.3 Tags outside requests

- **Jobs**: a job's lines carry `[<JobClass> <id>]` (`[WelcomeJob 42]`;
  a block job from `Job.handle` uses its kind). A job enqueued during a
  request records the request id in a new `cybertrain_jobs.request_id`
  column (added by the existing `ALTER_COLUMNS` path, default `''`), and
  its lines carry that id as a second tag; so does its error report.
- **Feeds**: `[feed:<name>]` for the feed thread's lifetime.
- **Scheduled tasks**: `[schedule:<name>]` while a task runs.

### 12.4 API

```ruby
Cybertrain.configure do |c|
  c.log_tags = [:request_id]     # the default
  c.log_format = :json           # default :text
end

Cybertrain.logger.tagged("billing") do
  Cybertrain.logger.info("charged #{amount}")   # ... INFO [<request id>] [billing] charged 300
end
```

- `c.log_tags`: the request's tags, in order. `:request_id` (default) and
  `:remote_ip` (`request.client_ip`; off by default, it is personal data).
  `[]` turns the request tag off. Rails also takes Procs; not here.
- `Cybertrain.logger.tagged(*tags) { }` adds tags for the block on this
  thread and restores the previous ones when it ends (rule 103's
  save-yield-restore form). Rails' block-less `tagged` that answers a new
  logger is not offered.
- `debug(msg)`, `info(msg)`, `warn(msg)`, `error(msg)`, `fatal(msg)` keep
  their one-String signature.

### 12.5 JSON lines

`c.log_format = :json` (or `CYBERTRAIN_LOG_FORMAT=json`) writes one JSON
object per line, for log collectors:

```json
{"time":"2026-11-11T12:00:00.123Z","level":"INFO","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":[],"message":"Completed 200 in 12ms"}
```

`request_id` is present only when the line was logged with one; `tags`
holds the other tags (job, feed, `tagged`) in order. Generated with
`JSON.generate`, so the message is escaped.

## 13. Error reporting (O-2)

### 13.1 API

Shaped like `Rails.error`:

```ruby
Cybertrain.error.report(e, context: { "order_id" => order.id })

Cybertrain.error.handle(context: { "feed" => "prices" }) do
  parse_price(text)          # an exception is reported and the block answers nil
end

class AuditSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    Cybertrain.logger.warn("reported #{event.error_class}: #{event.error_message}")
  end
end
Cybertrain.error.subscribe(AuditSubscriber.new)    # in config/app.rb
```

- `Cybertrain.error` answers the process's `Cybertrain::ErrorReporter`.
- `report(error, handled: true, context: {})` records an exception the
  application rescued. `context:` keys and values are turned into Strings
  (a `Hash{String => String}`).
- `handle(context: {}) { }` runs the block and answers its value; a
  `StandardError` (and `JSON::ParserError`, rule 33) raised in it is
  reported with `handled: true` and the block answers nil. Rails'
  `handle` takes error classes and `fallback:`; not here.
- `subscribe(subscriber)` adds a `Cybertrain::ErrorSubscriber` subclass
  instance; its `report(event)` receives a `Cybertrain::ErrorEvent`. Rails'
  subscribers receive `(error, handled:, severity:, context:, source:)`;
  here the event is a value of Strings, because under Spinel an exception
  is read reliably only by its class name and its message where it was
  raised (rules 46, 47, 53, 54), and a value can cross threads.
- Subscribers and the Sentry sender run on the reporter's thread (13.4),
  not in the caller (Rails calls subscribers synchronously). An exception
  in a subscriber is logged, never reported.

### 13.2 What is reported automatically

- **Requests**: an exception that ends as a 500, reported once, by the
  outermost layer that sees it: `ErrorPages` in production,
  `Dev::ErrorPage` in development, `Application#call` otherwise (the test
  environment, where the exception reaches the test). 4xx client errors
  (`ClientError.status_for(e) == 400`) are not reported, nor exceptions a
  controller's `rescue_from` handled (Rails' rules).
- **Jobs**: every failed attempt, with the attempt number and the maximum
  (`job.attempt` / `job.max_attempts` in the event's context), from the
  rescue in `Job.run_handler` where the exception object is still at hand;
  also a discarded job (`discard_on`).
- **Scheduled tasks**: a task block that raises (scheduler.rb's two rescue
  sites).
- **Feeds**: an exception in `on_open`, `on_message` or `on_tick`, a feed
  thread's death, and the supervisor giving up.
- **Mail**: a failed delivery of a `deliver_later` message (the `cybertrain
  mail` job's failure, `where` `"cybertrain mail"`); a `deliver_now` that
  raises inside a request is that request's error.
- The existing log lines stay; reporting is in addition to them.

### 13.3 What a report carries

`Cybertrain::ErrorEvent` (all Strings unless noted; names prefixed to stay
clear of `Exception#message` and other builtins, rules 10 and 62):

| Field | Content |
| --- | --- |
| `error_class` | `e.class.name`, namespaced (rule 46) |
| `error_message` | `e.message` |
| `where` | `ArticlesController#create`, `WelcomeJob`, `schedule:nightly`, `feed:prices`, `cybertrain mail`, `request` (no route matched) or `""` for `report` called outside these |
| `request_id`, `request_method`, `request_path` | the request's, or the job's recorded request id; the path without its query string |
| `environment` | `Cybertrain.config.env` |
| `release` | `c.release` (`CYBERTRAIN_RELEASE`), the application's version or commit |
| `handled` | Boolean |
| `context` | `Hash{String => String}`: what the application passed, plus `job.id`, `job.attempt`, `job.max_attempts` for jobs |
| `backtrace` | `Array<String>`, empty when there is none |
| `occurred_at` | `Time`, from the Clock |

**Not sent by default**: params, headers, cookies, the client IP, the
query string, the session. Only what the application puts in `context:`.

**Backtraces.** Spinel's release builds (`cybertrain build`) have none
(the toolchain's `sp_bt.h` fills one only under `spinel --debug`). Spike
item 5 checks whether `e.backtrace` answers frames in a `--debug` build;
if it does, they are attached (as Sentry `stacktrace.frames`, parsed from
`file:line:in 'method'`), and under CRuby they always are. Otherwise a
report carries the class, the message and `where`.

### 13.4 Delivery and the Sentry sender

- **Off the request.** `report` builds the event and puts it on a bounded
  queue (100 events); a dedicated thread, started on the first report,
  takes events off it and hands each to the subscribers and to the sender.
  A full queue drops the event and counts it; the count is logged at
  `warn` at most once a minute (`error reports dropped: 7`).
- **Dedupe.** An event with the same `error_class`, `error_message` and
  `where` as one queued in the last 60 seconds is not queued again (a
  failing page hit by every visitor sends one report a minute).
- **Sampling.** `c.error_sample_rate` (`CYBERTRAIN_ERROR_SAMPLE_RATE`,
  `1.0`) is the share of events the Sentry sender sends, as Sentry's
  `sample_rate`; subscribers see every event.
- **Shutdown.** The server's graceful stop waits up to 2 seconds for the
  queue to empty; what is left is lost.
- **The sender.** `CYBERTRAIN_SENTRY_DSN`
  (`https://<public key>@<host>[/<path>]/<project id>`) turns it on; unset,
  nothing is sent and no thread starts unless a subscriber exists. It
  POSTs one Sentry envelope per event to
  `https://<host>[/<path>]/api/<project id>/envelope/` with
  `X-Sentry-Auth: Sentry sentry_version=7, sentry_key=<key>,
  sentry_client=cybertrain/<VERSION>`, through `HttpClient` (`timeout: 3,
  deadline: 5`; https needs `cybertrain/net/tls`, which every application
  links since phase 4). Sentry and GlitchTip both accept it. The event:
  `event_id` (32 hex), `timestamp`, `platform: "ruby"`, `level: "error"`,
  `environment`, `release`, `transaction` (the `where`),
  `exception.values[0]` (`type`, `value`, `mechanism.handled`,
  `stacktrace` when there is one), `tags.request_id`,
  `request.method` / `request.url` (the path), `extra` (the context). A
  DSN on a private address needs `http_allow_private`, as any
  `HttpClient` call does. A send that fails is logged at `warn` and not
  retried.

# Both parts

## 14. Configuration added

| Variable | `Config` field | Default | Meaning |
| --- | --- | --- | --- |
| `CYBERTRAIN_TIME_ZONE` | `time_zone` | `"UTC"` | IANA zone for boundaries, `Date.current`, `l` and `time_tag` (5a) |
| `CYBERTRAIN_SCHEDULER_TZ` | `scheduler_tz` | `time_zone` (was `"UTC"`) | 5a |
| `CYBERTRAIN_MAIL_DELIVERY_METHOD` | `mail_delivery_method` | `:test` in test, else `:smtp` | 5a |
| `CYBERTRAIN_LOG_LEVEL` | `log_level` | `:info` | `debug`, `info`, `warn`, `error`, `fatal`, `none` (5b) |
| `CYBERTRAIN_LOG_FORMAT` | `log_format` | `:text` | or `:json` (5b) |
| — | `log_tags` | `[:request_id]` | `:request_id`, `:remote_ip` (5b) |
| `CYBERTRAIN_SENTRY_DSN` | `sentry_dsn` | `""` | empty sends nothing (5b) |
| `CYBERTRAIN_ERROR_SAMPLE_RATE` | `error_sample_rate` | `1.0` | 0.0 to 1.0, the sender only (5b) |
| `CYBERTRAIN_RELEASE` | `release` | `""` | sent with each report (5b) |

Each is validated at boot (an unknown zone, level or format, a DSN that
does not parse, a rate outside 0 to 1 stop it). No new secret: the DSN's
key is a public key in Sentry's model, though it is still kept out of the
repository like any credential.

## 15. Documentation and design.md changes

- design.md: 5a adds D66 the clock, durations, time helpers and the
  configured zone; D67 test classes, setup / teardown and database
  isolation; D68 fixtures and `cybertrain test`; D69 the component,
  stream, mail and job test helpers, the new assertions and the receivers'
  automatic stop. 5b adds D70 the log line, tags and the request id, and
  D71 error reporting and the Sentry sender. D13 (tests and CI: the
  rollback it planned is replaced by D67's clear), D14 (logging), D19
  (time zones), D32 (receivers), D34 (T-1: the application side answered,
  the framework's own suite still deferred), D52 (`scheduler_tz`'s
  default) are amended; section 8 keeps "error pages with stack traces"
  out; section 13 gets the dated entries; D1's programme paragraph records
  phase 5 as delivered.
- Guides, each with fr / ja / ru / zh and `script/check-guide-i18n
  --update-sha`: testing.md rewritten as the testing page (the class form,
  fixtures, `cybertrain test`, time travel, components and streams,
  assertions, mail, jobs, receivers; the top-level form kept as a
  section), configuration.md (section 14), and the operations material
  (logs, request ids, error reporting, `CYBERTRAIN_SENTRY_DSN`,
  `CYBERTRAIN_RELEASE`) in background-and-operations.md; the deploy
  tutorial (docs/deploy.md, deploy.en.md) and deploy-kamal.md gain the
  environment variables for reporting and the JSON log format.
  models.md's time section covers durations and `Time.zone`.
- docs/api for the new public methods; the README's feature list.
- spikes/NOTES.md for rules found; docs/spinel-feedback.md for Spinel
  limits found (a missing `Time.now` override or backtrace would be
  written up there).
- This spec gets "## 21. Implementation notes" after each part, as phase
  4's did.

## 16. Spinel constraints and the spike

Constraints applied above:

- no computed send (rule 1): the tests are dispatched by a generated
  `case`, `assert_predicate` is not offered, fixtures are generated
  accessors;
- no `instance_exec` of a stored block (rule 2) and no stored block
  through a base-class receiver (rule 88): gen rewrites the class form
  into methods; top-level `setup` / `teardown` blocks take no receiver;
- a base method calling a subclass-only method needs a stub (rule 3):
  `ActiveSupport::TestCase` defines empty `setup` and `teardown`, called
  as ordinary overrides, never from a stored block;
- one return type per name across the program (rules 10, 34, 41):
  `render_inline` (the old generated helper tests' local one is renamed),
  the fixture accessors beside associations, `Cybertrain.error` beside
  `Logger#error`, `handle`, `report`, `subscribe`, the reader names of
  `HtmlNode` and `ErrorEvent` (prefixed); `script/check-reserved-names`'
  `NAME_HOMES` gains the new names;
- methods named like builtins change dispatch on boxed receivers (rule
  62): `ZonedTime#hour` and its siblings are the candidates;
- class methods on core classes compile (rule 87): `Time.current`,
  `Time.zone`, `Date.current`;
- a call to a method no class defines is refused at build (rule 84): the
  mechanism that makes `1.month` a build error;
- per-thread state through `Thread.current` (rule 102): the request id and
  the log tags; module-level ivars, never `@@` (rules 18, 64), for the
  clock, the test registry, `Mailer.deliveries` and the reporter's queue;
- yielding helpers yield into a local (rule 90); `travel_to { }`,
  `tagged { }` and `I18n`-style restores use rule 103's save-yield-ensure
  form in a non-re-entrant module function (rules 50, 69); the runner's
  "teardown always runs" is a plain method's `ensure`, not a yielding one;
- `rescue JSON::NestingError, JSON::ParserError, StandardError => e`
  wherever a test or a report catches everything (rules 33, 61);
- a lambda is passed positionally (rules 42, 82): `assert_difference`;
- threads are started through a method (rule 21); the reporter's queue
  uses `Queue#pop(timeout:)` (rule 85); a lock is kept off the request's
  work (rule 57);
- locals of one name in top-level blocks share a type in one program (rule
  63): relevant to bundling top-level-form files;
- a nullable `Time` ivar miscompiles (rule 7): the clock stores Integer
  microseconds.

The spike is 5a's plan's first task (items 1 to 6) and 5b's plan's first
task (items 7 to 9), on the pinned Spinel (2026.11.04.7026), with the
programs kept in spikes/phase5/ and their commands and output in each
header. The results are recorded below the list by those tasks.

1. **5a, overriding `Time.now`.** In a program with the whole framework
   required, does `class Time; def self.now = Cybertrain::Clock.now; end`
   change what `Time.now` answers at every call site, framework files
   included, and does `Process.clock_gettime(Process::CLOCK_REALTIME)`
   give the same instant as the builtin? Fallback: no override; only
   `Time.current` and the framework's times follow a travel, and the guide
   says so (section 2.4).
2. **5a, methods on Integer and Time.** `5.minutes`, `1.day`, `2.weeks.ago`,
   `3.days.from_now`; `Time#beginning_of_day`, `advance(months: 1)`,
   `months_ago`, `in_time_zone` and `ZonedTime#hour` / `min` / `wday`
   beside `Time#hour` on boxed receivers (rule 62's grep over the C);
   `Time.current` and `Date.current` beside `Schema.current`; and `1.month`
   refused at build. Fallbacks: if a `ZonedTime` reader breaks boxed
   dispatch, the readers are `local_hour`, `local_min`, `local_wday` and
   so on; if Integer methods do not compile, `Cybertrain::Durations.minutes(5)`
   module functions are the spelling and the guide uses them; if `1.month`
   compiles to a run-time `NoMethodError`, the guide says it fails at run
   time.
3. **5a, the class rewrite.** A class-form file as gen will write it: an
   `ActionDispatch::IntegrationTest` subclass of an application base class
   with `setup` / `teardown`, instance variables, a private helper, `get`
   and `post` with nested `params:`, the included `Gen::UrlHelpers`, a
   fixture accessor `articles(:one)` in a program whose `User` has
   `has_many :articles`, and the generated `case` runner; also a
   `ViewComponent::TestCase` with `render_inline`. Fallback (Q11): the
   top-level DSL plus `setup` / `teardown` only, and the generators write
   that form. Narrower fallbacks: nested `params:` → flat bracketed keys
   (`"article[title]" => "x"`); a clashing accessor → gen writes
   `articles_fixture(:one)` and rewrites `articles(:one)` in the copy, so
   the source keeps Rails' spelling.
4. **5a, `assert_raises` with a class.** `assert_raises(ArgumentError) { }`
   and a namespaced class (`Cybertrain::DB::Error`), matched by class name
   (rules 46, 47), answering the exception's message. Fallback: the String
   form only, as today.
5. **5a and 5b, `--debug` backtraces.** In a `spinel --debug` build, does
   `e.backtrace` answer frames with file and line, and what does a debug
   build cost in compile time and speed? Fallback: no backtrace is
   attached; the class, the message and `where` are the report.
6. **5a, a measurement.** Bundle the framework's own 184 top-level-form
   programs into one: how many compile together (rules 41, 63 and
   duplicate top-level names), the compile time and the binary size,
   against D34's 14-minute full compile. Nothing in phase 5 depends on the
   number; it is recorded for a later decision (section 17).
7. **5b, thread-local tags.** A String request id and an Array of String
   tags in `Thread.current` beside I18n's Symbol and the pool's
   Connection, across green threads with `SPINEL_WORKERS=4` (rule 102's
   program extended). Fallback: the request id lives on the `Context`;
   framework lines written with a `Context` at hand carry it, and an
   application's own lines carry it only inside
   `Cybertrain.logger.tagged(request.request_id) { }`.
8. **5b, Rails.error's names.** `Cybertrain.error` (answering an
   `ErrorReporter`) beside `Logger#error(msg)`; `ErrorReporter#handle`
   beside `Job.handle`; `#subscribe` beside `WebSocket.subscribe` and
   `Hub#subscribe`; `ErrorSubscriber#report`; in one program with the
   whole framework. Fallback: `Cybertrain.error_reporter` and the method
   names `report_error`, `handle_errors`, `add_subscriber`, the guide
   naming Rails' spelling beside them.
9. **5b, the logger's mutex.** bench/run's two-core configuration
   (`SPINEL_WORKERS=2`) with the locked logger and the request log on, five
   runs, against the same without the lock (rule 57's method). Fallback:
   no lock; each line is one `write` of at most 4,096 bytes (a longer
   message is cut and marked), which a pipe does not interleave.

## 17. Out of scope (recorded so nothing is lost)

- **T-7 coverage**: Spinel's compiled programs carry no coverage
  instrumentation, and a CRuby run would measure a different program.
- **O-4 static analysis** (a Brakeman-like check of unescaped component
  output, RuboCop, bundler-audit, N+1 detection): separate tools;
  `script/gate` and its checks stay what exists.
- **O-5 cross-building**: a release is built on the target's OS and CPU
  (docs/deploy.en.md).
- **The rest of O-2**: performance tracing (Sentry's 5 % traces) and
  sending warning-level log lines as events.
- **The rest of T-1**: parallel test processes; bundling the framework's
  own 184 tests (measured by spike item 6).
- **The rest of T-4**: replacing a class's `new` or a method with a fake
  (no run-time redefinition under Spinel); outbound calls are tested with
  the receivers (D32).
- Also out: Rails' transactional tests (section 6), ERB in fixtures,
  polymorphic `belongs_to` by label (`commentable: one (Article)`; write
  the `_id` and `_type` columns) and `has_and_belongs_to_many` fixture
  labels, `assert_select`'s pseudo-classes, sibling combinators and nested
  blocks, `assert_predicate`, String expressions in `assert_difference`,
  `skip`, `parallelize`, system tests (a browser), TimeWithZone,
  `months` / `years` on Integer, Rails' time zone names, `Rails.error`'s
  `record` and `set_context`, Proc log tags.

## 18. Compatibility changes for applications on 0.4

- **Removed clock seams.** `Cache.clock=`, `Cache.system_clock`,
  `RateLimit.current_time=`, `SessionStore#fixed_now=`,
  `Application.status_now=` and `Background.supervisor_clock=` are gone; a
  test that set one uses `travel_to`. The generated authentication test's
  `Cache.clock = -> { 2_000_000_000 }` with its hand-written `ensure`
  becomes a `travel_to` block.
- **Mail in tests is stored.** In the test environment `deliver_now`,
  `Mailer.deliver` and the `deliver_later` job append to
  `Mailer.deliveries` instead of connecting; a test that reads mail at a
  `Test::SmtpReceiver` sets `Cybertrain.config.mail_delivery_method =
  :smtp` first.
- **Log lines change shape.** `[INFO] msg` becomes
  `2026-11-11T12:00:00.123Z INFO [<request id>] msg`; anything that
  parses the log (alerts, greps in scripts) is updated. A test that
  captured log lines in a `StringIO` and compared them exactly compares
  the message part, or freezes time and sets `c.log_tags = []`.
- **Every response carries `X-Request-Id`.** A proxy that already sets one
  has it honoured only when the proxy is trusted.
- **`scheduler_tz` follows `time_zone`.** An application that sets
  `time_zone` and not `scheduler_tz` has its cron tasks read in that zone
  (UTC before).
- **`l` and `time_tag` render in `time_zone`.** With the default `"UTC"`
  nothing changes; an application that sets a zone sees local times where
  it saw UTC.
- **Tests run by `cybertrain test`.** The generated CI step changes from
  `spin test` to `cybertrain test`. Existing top-level-form files keep
  working in the bundle and under `spin test`, but two files defining the
  same top-level helper or constant (a `new_client` in each, as the
  authentication and attachment generators wrote them) are refused in the
  bundle until one moves to `test/support/` or is renamed. Files that boot
  the application themselves (`AppTest.boot`, `BlogTest.boot`) keep doing
  so; in the bundle the bundle's boot comes first and theirs boots a
  second time on a fresh database, which works but is slower: the guide's
  upgrade section moves them to `test_helper.rb`.
- **The clear before each test.** In the bundle every table is emptied
  before each test, so a top-level-form file whose later tests relied on
  rows an earlier test made (the opposite of today's advice) now fails;
  such data moves to fixtures or `setup`.
- **Generated helper tests** defined a top-level `render_inline(source)`;
  it clashes with the framework's `render_inline` (rule 10) and is renamed
  `render_helper_template` in those files by hand (the upgrade section
  shows the one-line change).
- **`cybertrain_jobs.request_id`** is added to an existing table on first
  use (5b).
- **Failure messages.** `assert_equal`'s failure text is Minitest's
  two-line form; nothing in a passing snapshot changes.

## 19. Acceptance

**5a**

1. The clock: every site of section 2.3 follows `travel_to` (a model's
   timestamps, a cache entry's expiry, a rate-limit window, a session's
   absolute and idle limits, a job's `run_at` and `perform_in`, a token's
   expiry); wait loops do not hang with the clock frozen (a stream read
   and an HTTP receiver wait under `freeze_time`); `travel_to`, `travel`,
   `freeze_time`, `travel_back` with and without blocks, nested, and after
   a raising block; the clock is real again in the next test; the removed
   seams are gone from the code and the tests.
2. Durations and time: every method of section 3 against Rails'
   documented examples, month-end clamping, `beginning_of_*` in
   `Asia/Tokyo` and across a DST transition in `America/New_York`;
   `Date.current` at either side of the zone's midnight; `l` and
   `time_tag` in the zone and with `zone:`; `scheduler_tz`'s new default;
   `in_time_zone`'s fields.
3. Test classes: the three Rails classes; setup and teardown order with an
   inherited base; teardown after a failing setup, a failing assertion and
   an exception; helpers and ivars per class; duplicate test names and
   `setup do` beside `def setup` refused; the top-level form with
   top-level `setup` / `teardown`, in the bundle and under `spin test`.
4. Isolation and fixtures: the clear (application and framework tables,
   sequences); fixtures with labels, `id:`, `belongs_to` by label, every
   column type, filled timestamps; ids equal to Rails' for the same
   labels; the refusals (ERB, unknown table, unknown column, colliding
   ids, the YAML subset's) with file and line; `articles(:missing)`.
5. `cybertrain test`: one compile for many files; a file filter and `-n`
   (exact, method name, `/text/`) without a recompile; the headings,
   `file:line` on a failure, the totals and the exit status; the
   duplicate-helper refusal naming both files; the blog's compile time
   recorded in D68.
6. Components and streams: `render_inline` of a component and a partial;
   every selector form and option of `assert_select`, each unsupported
   form's message, a malformed-HTML failure, the excerpt;
   `assert_broadcasts` with a record and a name, `assert_no_broadcasts`,
   `assert_turbo_stream`.
7. Assertions and helpers: each assertion of section 10 passing and
   failing with its message; `assert_raises` per spike item 4;
   `Mailer.deliveries`, `assert_emails` (including `deliver_later` in the
   block), `assert_no_emails`, the `:smtp` opt-out; `perform_enqueued_jobs`
   with a block (jobs queuing jobs, a future `run_at`); a receiver left
   running by a failing test is stopped.
8. The blog: its tests rewritten as Rails-shaped classes
   (`test/models/`, `test/controllers/`, ...) with `test/fixtures/` and
   run as one binary by `cybertrain test`; phase 4b's authentication
   tests check day 15 and day 30 with `travel_to` instead of backdating
   rows; one component test and one broadcast test.
9. Generators: `cybertrain new` writes `test/test_helper.rb` and the
   sample test; scaffold and authentication write class-form tests and
   fixtures, component / helper / job / attachment the class form; the
   generated applications' tests pass in CI's end-to-end job.
10. The full suite, the blog's tests, `gen --check`, the gate; the testing,
    configuration and operations guides and their translations; design.md
    D66 to D69; this spec's implementation notes for 5a; the spike's
    results in section 16.

**5b**

11. Logs: the line's shape at each level; `CYBERTRAIN_LOG_LEVEL`; JSON
    lines; `tagged` nested and restored after a raise; job, feed and
    schedule tags; lines from several threads never interleaved; the
    request id generated, accepted from a trusted proxy, refused from an
    untrusted peer and when malformed or too long, echoed (error pages
    included), read as `request.request_id`, carried by an application's
    own line, recorded by a job enqueued in the request and carried by
    that job's lines.
12. Error reporting: `report`, `handle`, `subscribe`; each automatic
    source of section 13.2, and none for a 4xx or a `rescue_from`; the
    event's fields and the absence of params, headers, cookies and IP;
    overflow dropped and counted, dedupe within the window, the sample
    rate; the Sentry envelope and auth header received by a
    `Test::HttpReceiver`, and a DSN with a path prefix; the backtrace per
    spike item 5.
13. The blog: request ids in its log; an error raised by a test-only route
    and a failing job reported to a `Test::HttpReceiver` through
    `CYBERTRAIN_SENTRY_DSN`.
14. As item 10 for 5b: D70 and D71, the guides, the implementation notes.

## 20. Details chosen while writing

Each is the option closest to Rails and simplest where the decisions left
it open; the maintainer may change any of them in review.

- The request log keeps its two lines (Started, Completed) in the new line shape; the example in Q9 shows the shape only.
- The request id is a UUID v4 (`SecureRandom.uuid`), logged in full.
- JSON log fields: `time`, `level`, `request_id` (only when present), `tags`, `message`; the level in capitals in both formats.
- `CYBERTRAIN_LOG_FORMAT` is the log format's variable.
- `c.log_tags` accepts `:request_id` and `:remote_ip`; no Procs.
- A job's tag is `[<JobClass> <id>]` with the recorded request id as a second tag; scheduled tasks are tagged `[schedule:<name>]`.
- Log timestamps follow the Clock; durations (the request's milliseconds) use the monotonic clock.
- The error dedupe window is 60 seconds, keyed by class, message and `where`.
- The reporter's queue holds 100 events; drops are logged at most once a minute.
- The Sentry sender uses `timeout: 3, deadline: 5`, no retry; the graceful stop waits up to 2 seconds for the queue.
- `error_sample_rate` applies to the Sentry sender only; subscribers see every event.
- The sender posts Sentry envelopes to `/api/<project>/envelope/`, with the field mapping of section 13.4.
- The release comes from `CYBERTRAIN_RELEASE` (`c.release`), default empty.
- `ErrorSubscriber#report(event)` receives an `ErrorEvent` value instead of Rails' `(error, handled:, severity:, context:, source:)`; subscribers run on the reporter's thread.
- `context:` keys and values become Strings.
- A job failure is reported on every failed attempt (dedupe collapses repeats).
- A request's 500 is reported by the outermost layer that sees it (`ErrorPages`, `Dev::ErrorPage` or `Application#call`); the path is sent without its query.
- Fixture ids are Rails' `Zlib.crc32(label) % (2**30 - 1)`, computed by gen in pure Ruby.
- The clear and the fixture insert run with foreign keys off; framework tables are cleared when present; `sqlite_sequence` is emptied.
- `fixtures :all` and `require "test_helper"` are accepted and have no effect of their own.
- gen writes the rewritten tests to `gen/test/` and the program to `gen/tests.rb` (committed and checked by `gen --check`, like `gen/concerns/`); the binary is `build/test/tests`.
- A test's method name is `test_` plus the name with non-word characters turned into `_` (Rails' rule).
- Several `setup do` blocks run in order after the superclass's; `teardown do` blocks run in reverse order before the superclass's.
- A failure shows the line of the test's `test "..."` call (no assertion line without a backtrace).
- `-n` takes an exact name or method name, or `/text/` as a substring.
- A class-form file runs alone through `cybertrain test FILE`; `spin test` per file applies to top-level-form files.
- The duplicate check in the bundle covers top-level constants as well as methods.
- `assert_select` also takes Rails' positional second argument (String text, Integer count, `false`).
- `text:` is compared after collapsing whitespace and stripping.
- The `assert_select` failure excerpt is the first 500 characters of the HTML.
- `render_inline` takes the component's content as `content:`, not a block, and answers a String.
- `assert_broadcasts` takes a record or a name (`Stream.name_for`) and answers the payloads.
- `assert_turbo_stream` checks the last response body (or render).
- `assert_emails` with a block also delivers mail queued with `deliver_later` in the block.
- `mail_delivery_method` (`CYBERTRAIN_MAIL_DELIVERY_METHOD`) is `:test` in the test environment, `:smtp` elsewhere.
- `perform_enqueued_jobs` with a block runs every job queued in it, whatever its `run_at`.
- Before each test the runner also resets the in-memory rate-limit counters, `I18n.locale` and the log tags.
- `Time.zone` answers `Cybertrain::TimeZone`, its name read with `zone_name`.
- In a zone transition, a skipped wall time moves forward and a repeated one takes the earlier instant.
- `beginning_of_week` is Monday.
- `travel_to` freezes and drops the sub-second part (Rails' `with_usec: false`).
- `in_time_zone` answers `Cybertrain::ZonedTime` with `year`, `month`, `day`, `hour`, `min`, `sec`, `wday`, `yday`, `utc_offset`, `zone`, `to_time`, `to_date`.
- The tag reader is `Cybertrain::Test::HtmlReader`, its nodes `Test::HtmlNode` with prefixed readers.
- `cybertrain new`'s sample test is `test/integration/health_test.rb` (a request to `/up`).
- The authentication generator's `sign_in_as` lives in `test/support/session_test_helper.rb`.
- `assert_in_delta`'s default delta is 0.001 (Minitest's).
- `assert_equal`'s failure text is Minitest's `Expected:` / `Actual:` pair.
- `ActionDispatch::IntegrationTest`'s `params:` takes nested Hashes, encoded with brackets.
