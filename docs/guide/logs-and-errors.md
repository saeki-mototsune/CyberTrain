# Logs and error reporting

What a running application writes to its log (the line, the level, JSON
lines, the request id and tags), and how the exceptions of its requests,
jobs, scheduled tasks and feeds reach the application's subscribers and
Sentry. The jobs, the process roles and the health check are in
[Background work and operations](background-and-operations.md).

## Logs

The framework and the application log through `Cybertrain.logger`, one line
per message on standard output, flushed after each line, as a twelve-factor
application does (systemd's journal, Kamal and Docker collect it):

```text output — ./blog server
2026-11-14T09:30:00.120Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Started GET "/articles" for 127.0.0.1
2026-11-14T09:30:00.132Z INFO [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] Completed 200 in 12ms
2026-11-14T09:30:01.002Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] job 42 (WelcomeJob) attempt 1 of 5 failed: RuntimeError: smtp down; retrying in 60 s
2026-11-14T09:30:02.410Z WARN [feed:prices] WebSocket "prices" silent for 60s; reconnecting
```

A line is the time in UTC with milliseconds (in a test it follows
`travel_to`), the level in capitals, the tags in brackets and the message.
`Cybertrain.logger` has `debug`, `info`, `warn`, `error` and `fatal`, each
taking one String. Lines from several threads never mix: each line is built
whole and written with one write under a lock that is held for that write
only. A write that fails (a closed pipe) drops the line; logging never
raises into its caller. A reader that stops reading standard output (a full
pipe) blocks every thread that logs until it reads again, so keep the
collector running.

**One event, one line.** A line feed in a message or in a tag is written
as the two characters `\n`, a carriage return as `\r`, so a message of
several lines, or a forged one, cannot start a line of its own:
`Cybertrain.logger.info("ok\n2026-11-11T12:00:00.000Z ERROR fake")` writes
one line:

```text output — one event, one line
2026-11-14T09:30:00.120Z INFO ok\n2026-11-11T12:00:00.000Z ERROR fake
```

A message's one line feed at its very end is the line's own end and is not
escaped (`info("done\n")` writes `done`); a second one is. Nothing else is
escaped: a backslash stays a backslash, and tabs, other control bytes and
invalid UTF-8 are written as they are. JSON lines escape as they always
did.

**The level.** `c.log_level` in `config/app.rb`, or `CYBERTRAIN_LOG_LEVEL`
(`debug`, `info`, `warn`, `error`, `fatal` or `none`, in any case), is the
least important level written; `:info` by default. `:none` also turns off
the request log, and still writes error lines. An assignment in
`config/app.rb` wins over the variable. Anything else stops the boot:
`error: log_level must be :debug, :info, :warn, :error, :fatal or :none (got :verbose)`.

**JSON lines.** `c.log_format = :json` (or `CYBERTRAIN_LOG_FORMAT=json`)
writes one JSON object per line instead, for a log collector:

```json
{"time":"2026-11-14T09:30:00.132Z","level":"INFO","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":[],"message":"Completed 200 in 12ms"}
```

`request_id` is there only when the line has one (inside a request, or in a
job a request enqueued) and `log_tags` shows it; `tags` holds the other
tags in order. When a message (or a tag) is not valid UTF-8, every byte of
it from 0x80 up, the bytes of valid characters included, is written as the
escape `\ufffd` in JSON, so one bad byte turns all of that message's
non-ASCII text into replacement characters; a valid message is written as
it is, and a text line keeps the bytes as they were logged. A format other than
`:text` or `:json` stops the boot:
`error: log_format must be :text or :json (got :xml)`. Boot's own first
line (the warning about `mail_delivery_method :test` outside tests)
follows the format; the warnings about an application setting whose value
is invalid (`setting_int`, `setting_bool` falling back to the default) are
logged while `config/app.rb` runs,
before the format is known, and are always text lines.

The level and the format apply to `./<app> server`, `worker` and `feeds`,
and to registered commands, `jobs` and `console`, which refuse an unknown
one with the same message and exit status 1 before they open the database.
`migrate`, `db` and `dbconsole` do not apply them: their lines are text at
the `info` level.

### Request ids

Every request gets an id, a version 4 UUID, which the action reads as
`request.request_id` and the response sends back as `X-Request-Id`, also on
the host check's 403, the https redirect of `force_ssl`, the error pages,
the development diagnostics page and the server's own 500. The server's 400
and 413 for a request it cannot read, answered before the application sees
it, carry none. Every line logged while the request runs carries the id as
a tag (the first, with the default `log_tags`), the application's own `Cybertrain.logger.info` lines
included, and so does a streamed body (`stream do ... end`, Server-Sent
Events) or a WebSocket connection the request opened, for as long as it
stays open.

```ruby
Cybertrain.logger.info("export #{report.id} for #{request.request_id}")
```

A proxy's id is used only from a proxy the application trusts: when the
connection comes from a trusted proxy (`CYBERTRAIN_TRUSTED_PROXY` or
`CYBERTRAIN_TRUSTED_PROXIES`, the check `request.client_ip` makes;
[The client address behind a proxy](requests.md#the-client-address-behind-a-proxy))
and its `X-Request-Id` is 1 to 255 ASCII letters, digits and hyphens, the
request takes that id, so the proxy's log and the application's share it.
Any other `X-Request-Id`, a header sent twice included, is discarded and a
new id made; it is never altered.

`c.log_tags` chooses the request's tags, in order: `[:request_id]` by
default, `[:request_id, :remote_ip]` to add `request.client_ip` (off by
default: an address is personal data), `[]` for none (the header is still
sent). Anything else stops the boot:
`error: log_tags may hold :request_id and :remote_ip (got :user_agent)`.

### Tags

`Cybertrain.logger.tagged` adds tags to every line logged on this thread
during the block, after the request's own, and takes them off when the
block ends, also when it raises; it answers the block's value. Blocks nest.
There is no form without a block.

```ruby
Cybertrain.logger.tagged("billing", "order #{order.id}") do
  Cybertrain.logger.info("charged 300")
  # 2026-11-14T09:30:00.140Z INFO [3f2a9c1e-...] [billing] [order 7] charged 300
end
```

Tags belong to the thread: a thread you start begins with none, whatever
the thread that started it had. The framework tags its own work the same
way:

- **Jobs.** Each attempt's lines carry `[<JobClass> <id>]` (for a block job
  from `Job.handle`, its kind), then the id of the request that enqueued
  it: `INFO [WelcomeJob 7] [3f2a9c1e-...] welcome 1`. The id is recorded
  in the job's row (`cybertrain_jobs.request_id`) whatever `log_tags`
  says, and shown when `log_tags` includes `:request_id`. A job enqueued by
  a job records its parent's id; one enqueued by a scheduled task, a feed
  or a command records none.
- **Scheduled tasks.** `[schedule:<name>]` while a task runs, its failure
  line included.
- **Feeds.** `[feed:<name>]` on every line a feed's thread logs, its
  callbacks' included. The supervisor's restart and give-up lines, logged
  on its own thread, carry no tag.

## Error reporting

`Cybertrain.error` collects the exceptions that end a request, a job's
attempt, a scheduled task or a feed, and the ones the application reports
itself, and hands each to the subscribers the application adds and to
Sentry (or GlitchTip) when a DSN is set. It is in the core; sending to
Sentry is its own line, which `require "cybertrain"` loads and an
application on `cybertrain/core` adds to `bin/<app>.rb` (not to
`bin/db.rb`; [Subsystems](how-it-works.md#subsystems)). `cybertrain new`
writes the lines of this section commented out: the variables in
`.env.example`, a subscriber in `config/app.rb`, the DSN in
`config/deploy.yml` and `.kamal/secrets`, and this line in the comment of
`bin/<app>.rb`:

```ruby
require "cybertrain/error_reporter/sentry"   # bin/<app>.rb, after require "cybertrain/core"
```

```ruby
# Something the application rescued, with what it knows:
begin
  charge(order)
rescue PaymentError => e
  Cybertrain.error.report(e, context: { "order_id" => order.id })
end

# Run a block, report what it raises, go on with nil:
price = Cybertrain.error.handle(context: { "feed" => "prices" }) do
  parse_price(text)
end
```

`report(e, handled: true, context: {})` answers nil at once: the report is
delivered on the reporter's own thread. The context's keys and values become
Strings, over the context the framework adds (a job's id and attempt).
`handle(context: {}) { }` answers the block's value, or nil after reporting
a `StandardError` (or `JSON::ParserError`, `JSON::NestingError`) the block
raised; `break v` in its block makes `handle` answer `v`, and `return`
returns from the method around it. An exception outside those classes raised
in `handle`'s block goes on to the caller. Reporting itself never raises
into the caller: if the report fails, the log says
`error report failed: <Class>: <message>` at error.

**Subscribers.** A subscriber is a class of the application's, a subclass of
`Cybertrain::ErrorSubscriber` that defines `report(event)`:

```ruby
# config/app.rb, above the line that subscribes it (bin/<app>.rb loads
# config/app before app/, so a class under app/ is not loaded yet here)
class AuditSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    Cybertrain.logger.warn("reported #{event.error_class}: #{event.error_message} at #{event.error_where}")
  end
end
Cybertrain.error.subscribe(AuditSubscriber.new)
```

Each subscriber receives every report, on the reporter's thread, not in the
request or the job that failed. One that raises is logged at error,
`error subscriber AuditSubscriber failed: <Class>: <message>`, and is never
reported itself; the others still receive the event. The event is a value
of Strings:

| Reader | What |
| --- | --- |
| `error_class` | the exception's class name, namespaced (`"Cybertrain::DB::Error"`) |
| `error_message` | its message |
| `error_where` | `"ArticlesController#create"`, `"request"` (no action ran), a job's class or kind, `"cybertrain mail"`, `"job thread"`, `"schedule:<name>"`, `"feed:<name>"`, or `""` |
| `error_request_id`, `error_request_method`, `error_request_path` | the request's, the path without its query and filtered as the request log filters it; in a job, the id of the request that enqueued it; `""` outside a request |
| `error_environment`, `error_release` | `Cybertrain.config.env` and `c.release` |
| `error_handled` | true for `report` and `handle`, false for what the framework reported |
| `error_context` | a `Hash{String => String}`: the application's context, and `job.id`, `job.attempt`, `job.max_attempts` in a job |
| `error_backtrace` | an `Array<String>`, empty in a binary from `cybertrain build` (below) |
| `error_occurred_at` | a `Time`, from the clock |

**What is reported without a line of yours:**

- A request that ends in a 500, once: an exception
  `Cybertrain::ClientError.status_for` maps to 500 or more. Never a 4xx
  (a bad parameter, a CSRF failure, a 404), never what `rescue_from`
  handled. Should serving the error page then raise a new exception (an
  unreadable `public/500.html`), that one is reported too: two reports,
  each a real failure.
- A job's failed attempts (`where` its class or kind; `job.attempt` and
  `job.max_attempts` in the context), under the default policy, `retry_on`
  or `discard_on`. Inside a job the dedupe key holds the job's id as well
  ([Delivery](#error-reporting), below): two jobs of one kind failing alike
  are two reports, and an attempt of one job that fails with the class and
  message of its own attempt reported less than a minute before is logged
  but not reported again (under the default policy the first retry waits a
  minute, so each attempt is reported; with `retry_on ..., wait: 30` the
  attempt 30 seconds after a reported one is not). A discard is reported
  once. `job.max_attempts` is `job_max_attempts` under the
  default policy, the policy's `attempts:` under `retry_on`, and the
  attempt it ended at under `discard_on`. A `deliver_later` mail that fails
  is the `cybertrain mail` job's. An exception that escapes a job thread's
  loop, or a database error there, is `where` `job thread`.
- A scheduled task whose block raises, or a `cron` task with no next run
  within five years (`schedule:<name>`).
- A feed's `on_open`, `on_message` or `on_tick` that raises, a feed thread
  that dies, and the supervisor giving up on a feed
  (`Cybertrain::Background::FeedFailed`, a name with no class behind it,
  with the message `feed <name> restarted <n> times in <w> s; exiting`),
  all `feed:<name>`.

An exception raised while a streamed body (`stream do ... end`,
Server-Sent Events) or an upgraded WebSocket connection is written is
reported once, after the server's `stream error: <Class>: <message>` line,
with the request's id, method and path and the `where`
`ArticlesController#index (stream)` (`request (stream)` when no action
ran). A client that went away (`EOFError`, `IOError`, `Errno::ECONNRESET`,
`Errno::EPIPE` out of the writer) is logged with that line and not
reported. Not reported: a job whose kind has no handler, and, in
development, an exception the diagnostics page itself raises while it
shows one that was already reported. Every log line the framework wrote
before stays as it was; the report comes in addition.

**What is never sent.** The parameters, headers, cookies, the session, the
client's address and the query string are not in an event; a request's path
is filtered as the request log filters it. Only what the application puts
in `context:` is added. Exception messages are sent as they are, unless a
filter changes them: a message that holds personal data (an SMTP server's
rejection naming the recipient) needs one.

**Filters.** A filter is a subclass of `Cybertrain::ErrorReporter::Filter`
that defines `filter_event(event)`, answering true to keep the event and
false to drop it. It may change the message (`event.error_message =`) and
the context (`event.set_error_context(key, value)`,
`event.delete_error_context(key)`). This one masks simple unquoted ASCII e-mail addresses and the
other drops a class the application does not want reported:

```ruby
# config/app.rb
class MaskAddresses < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_message = event.error_message.gsub(/[\w.+-]+@[\w-]+(\.[\w-]+)+/, "[email]")
    event.delete_error_context("email")
    true
  end
end

class DropDeclinedCards < Cybertrain::ErrorReporter::Filter
  def filter_event(event)
    event.error_class != "PaymentGateway::Declined"
  end
end

Cybertrain.error.add_filter(MaskAddresses.new)
Cybertrain.error.add_filter(DropDeclinedCards.new)
```

The pattern in `MaskAddresses` misses two kinds of address. One with
characters outside ASCII, such as `alice@例え.テスト`: Ruby's `\w` matches
ASCII letters, digits and `_` unless a Unicode property is asked for. And
one with a quoted local part, such as `"alice smith"@example.com`: the pattern needs a
letter, digit, `.`, `+`, `-` or `_` right before the `@`, finds none after
the closing quote, and matches nothing in it, so the whole address stays in
the message. Write a pattern for the addresses you expect, or drop the
event instead.

Filters run on the reporter's thread, in the order added, before the
subscribers and the sender; the next filter, the subscribers and Sentry see
what a filter changed. Once one drops the event, the later ones do not run
and nothing receives it (it is not counted among the queue's drops). A
filter that raises drops the event, since a filter exists to keep
something from leaving, and logs
`error filter failed: <Filter class>: <Class>: <message>` at error; it is
never reported. The dedupe is decided before the filters, on the
unfiltered class, message and `where`: a filter's rewrite does not change
which reports collapse, and an event a filter drops still holds its slot
for the minute. The framework's own `ERROR` log line is written before the
event exists and is not filtered. A filter alone does not make reports
queue (a subscriber or a DSN does). Filters added in `config/app.rb` stay
for every test; one added in a test is removed before the next.

**Delivery.** Reports go on a queue of 100 and one thread delivers them.
The same class, message and `where` (and, inside a job, the job's id) is
queued at most once a minute, so a
page that fails for every visitor with the same message makes one report a
minute (a message that carries an id, `Couldn't find Article with id=5`,
makes one per distinct message); when the queue
is full, a report is dropped and counted, and `error reports dropped: <n>`
is logged at warn at most once a minute. While there is no subscriber and
no DSN, nothing is queued and no thread starts. A delivery that fails is
logged, `error delivery failed: <Class>: <message>`, and the next report
starts a new thread if the old one ended. When the server, a worker or a
feeds process stops, it waits up to 2 seconds for the queued reports after
its services stopped; what is left is lost. A development rebuild waits
too, and so do a registered command, `./<app> jobs` and `./<app> console`
before they close the database and exit.

**Sending to Sentry or GlitchTip.** With the line in `bin/<app>.rb`, setting
`CYBERTRAIN_SENTRY_DSN` (or `c.sentry_dsn`) to the project's DSN sends each
report as a Sentry event:

```sh
export CYBERTRAIN_SENTRY_DSN=https://PUBLIC_KEY@o1.ingest.sentry.io/42
export CYBERTRAIN_RELEASE=2026.11.14-3f2a9c1    # optional: sent as the event's release
export CYBERTRAIN_ERROR_SAMPLE_RATE=0.25        # optional: send a quarter of them
```

- The DSN reads `http[s]://<public key>[:<secret>]@<host>[:<port>][/<path>]/<project id>`
  (the secret, Sentry's old second half, is ignored); events go to
  `<scheme>://<host>[:<port>][/<path>]/api/<project id>/envelope/`, which
  Sentry and GlitchTip both accept. It holds a key: keep it in the deploy's
  secrets, not in a committed file. One that does not read stops the boot,
  naming the part and never the key:
  `error: sentry_dsn must look like https://<public key>@<host>/<project id>: the project id must be digits`.
- A DSN set in a program that does not link the sender stops the boot,
  and refuses a registered command, `jobs` and `console` before they open
  the database (exit status 1):
  `error: CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender: add require "cybertrain/error_reporter/sentry" to bin/<app>.rb`.
  A sender class of your own (a subclass of
  `Cybertrain::ErrorReporter::Sender`) defines `sender_name` to answer a
  name that is not empty, or it meets the same refusal.
- `CYBERTRAIN_ERROR_SAMPLE_RATE` (`c.error_sample_rate`, 1.0) is the share
  of reports sent, 0.0 to 1.0; subscribers still see every report. The
  variable must be digits with an optional `.digits`, or the boot stops:
  `error: error_sample_rate must be a number from 0.0 to 1.0 (got "x")`.
- `CYBERTRAIN_RELEASE` (`c.release`, empty by default) names the version or
  commit; it is not checked.
- Each send waits at most 5 seconds once the host's name is resolved (name
  resolution blocks the delivery thread and is not cut short by the
  deadline, so a stalled resolver can hold a send longer), and is never
  retried. A refusal is
  logged at warn, `error report not sent: Sentry answered 429`, and so is a
  failure to connect, `error report not sent: <Class>: <message>`.
- The event carries the class and message, `where` as the transaction, the
  environment, the release, the request id as a tag, the request's method
  and path, the context as `extra`, and the backtrace as frames when there
  is one.
- The call goes through `Cybertrain::HttpClient` and its guard against
  private addresses ([Outbound HTTP](external-services.md#outbound-http)): a
  GlitchTip on a private network or on the same machine needs
  `CYBERTRAIN_HTTP_ALLOW_PRIVATE=1`, which lifts the guard for every
  outbound call of the application.

**Backtraces.** A binary from `cybertrain build` is a Spinel release build,
whose exceptions carry no backtrace: its reports have the class, the message
and `where`. In a `--debug` build, and under CRuby, the frames are attached.

`cybertrain test` sends nothing to Sentry: it empties an exported
`CYBERTRAIN_SENTRY_DSN` unless `config/app.rb` assigns one, and a test points
the DSN at a `Test::SentryReceiver` instead
([Testing logs and error reports](testing.md#testing-logs-and-error-reports)).
The design: [docs/design.md](../design.md) D86 and D88.

### Upgrading logs and error reports

What a release changes in the logs and the error reports is listed by
version in [Upgrading](upgrading.md#notes-by-version).
