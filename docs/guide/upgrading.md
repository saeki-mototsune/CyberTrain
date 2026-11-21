# Upgrading

How to move an application to a newer CyberTrain release. The procedure is
the same for every release: each section below is one step, in order, with
its command and what a correct result looks like. What one release asks for
beyond the procedure is in [Notes by version](#notes-by-version).

## Before you start

Start from a state you can go back to, on the release the application is on
now:

```shell terminal — the app's directory
git status --short
cybertrain version
cybertrain test
```

<!-- list: points -->
- `git status --short` prints nothing: everything is committed, so each
  later step shows as a diff of its own.
- `cybertrain version` prints the release the application is on. It is also
  the `version` under `[lock.cybertrain]` in `spin.lock`.
- `cybertrain test` passes. A test that fails now is fixed first, on the old
  release: afterwards you could not tell it from a failure the upgrade
  caused.
- Production has a backup from today
  ([Operations: backups, vacuum, health check](background-and-operations.md#operations-backups-vacuum-health-check)).
  A release may change what is stored in the database.

Read the notes of the release you are moving to before you change anything.
An application that skips releases reads the notes of every release in
between, oldest first.

## Change the version

The gem and the framework are released from one tag, and the `cybertrain`
command refuses an application whose framework is another release than
itself ([Moving an app to a new release](install.md#moving-an-app-to-a-new-release)).
So the release is changed in three places, together:

1. The command: `gem install cybertrain -v X.Y.Z`. `cybertrain version`
   then prints `cybertrain X.Y.Z`.
2. `spin.toml`: the `cybertrain` line under `[dependencies]` names the new
   tag, `ref = "vX.Y.Z"`.
3. `spin.lock`, which is written again from nothing:

```shell terminal — the app's directory
rm spin.lock
cybertrain spin lock
```

It prints `locked 1 package(s)`, and `git diff spin.lock` shows the new
`version` and a new `ref` (the tag's commit) under `[lock.cybertrain]`.
Without the `rm`, `spin lock` keeps the commit it had locked and the diff is
empty. An application with other dependencies, or one that depends on a
version from the spin index, relocks as
[Moving an app to a new release](install.md#moving-an-app-to-a-new-release)
describes.

Two files `cybertrain new` wrote name the release as well. Change them when
the application has them:

<!-- list: points -->
- `Dockerfile`: `gem install cybertrain -v X.Y.Z`. The image is built with
  that command, and its `cybertrain build` stops when the version is not the
  locked one.
- `.github/workflows/ci.yml`: the tag after `setup-cybertrain@`
  ([Continuous integration](testing.md#continuous-integration)).

Until the command and `spin.lock` agree, `server`, `build`, `db`, `test` and
`generate` stop with exit status 1 and `error: this application's framework
is cybertrain A.B.C (spin.lock), but this cybertrain command is X.Y.Z.`,
before they run spin or write a file. `cybertrain spin ...` is never
checked.

## Install the pinned Spinel

Each release is written for one Spinel release and compiles the application
with it ([How Spinel is installed](install.md#how-spinel-is-installed)).

```shell terminal — any directory
cybertrain doctor
cybertrain setup
```

`cybertrain doctor` starts with the release and its pin, `cybertrain X.Y.Z,
pinned to Spinel SPINEL_TAG`, and has a `spinel    ok` line when that Spinel
is installed. When it is, `cybertrain setup` prints `nothing to install`:
the pin did not move with this release. When it is not, `cybertrain setup`
builds the new Spinel into `~/.cybertrain/spinel/<release>/`, which takes
minutes, leaves the old one in place and points the links in
`~/.cybertrain/bin` at the new one.

The commands that run spin do the same install the first time they need it,
so this step only chooses when the wait happens.

## Regenerate and read the diff

The generated code in `gen/` is committed, and the new framework's generator
may write it differently
([Build-time code generation](how-it-works.md#build-time-code-generation)):

```shell terminal — the app's directory
SPIN_DEBUG=1 cybertrain spin run gen
git status --short gen/
git diff gen/
```

The generator prints `wrote` for each file it changed and `identical` for
the others. Read the diff: it is what the release changed in the code your
application compiles, and a version note that says "after `spin run gen`"
is done by this step. An empty diff means the release changed nothing
there.

When the generator refuses something in the application's code, it stops
with a message that says what. The release's notes say what to change; run
the command again afterwards.

## Run the generators again

Code a generator wrote into `app/`, `config/` and `test/` belongs to the
application, and `spin run gen` does not touch it. A generator that can
bring such code up to date is run again in the application. Today that is
`generate authentication`, in an application that has it:

```shell terminal — the app's directory
cybertrain generate authentication > authentication.upgrade 2>&1
patch -p1 < authentication.upgrade
```

Pass the options the application was generated with (`--invite-only`,
`--confirmable`). The generator writes the files that are missing and a
migration for the columns that are missing, and prints a `manual` line and
a diff for each existing file it would write differently, without changing
it. `patch -p1` applies those diffs; apply by hand the ones for files you
edited, and delete the files a `manual` line names as replaced
([Running the generator again](authentication.md#running-the-generator-again)).

The step is done when a second run prints no `manual` line. Delete
`authentication.upgrade` then. The other generators (`scaffold`,
`attachment`, `job`, `helper`, `component`) write new code only; what a
release changes in the code they wrote earlier is listed in its notes.

## Migrate the database

```shell terminal — the app's directory
cybertrain db migrate
cybertrain db status
```

`db migrate` prints `== <version> <Name>: migrating` for each migration the
generators added, applies it, and writes `db/schema.rb` and the models in
`gen/` again; `db status` then shows `up` on every line. A table the
framework owns (`cybertrain_jobs`) needs no migration: the first process
that touches it adds a missing column.

A release that changes how existing data is stored names a `db` command in
its notes. Run it here, on the development database, and again on
production's during the deploy ([Deploy](#deploy)). Such a command is safe
to run twice.

## Apply the version's notes

Go through the release's section under [Notes by version](#notes-by-version),
topic by topic. Each entry says what changed and what to do about it. An
entry whose subject the application does not use needs nothing.

Most entries are found by the next step, as a compile error or a failing
test. The ones that are not are those about stored data, cookies, logs and
anything else outside the application's code: the scripts that read the
log, the proxy, the monitoring. Go through those by reading.

## Run the tests

```shell terminal — the app's directory
cybertrain test
cybertrain build
```

`cybertrain test` compiles the tests against the new framework and passes.
`cybertrain build` compiles the binary production runs, `dist/<app>`, with
the views embedded. A setting the new release requires stops that binary at
boot with a message naming the setting, so start it once the way production
does before you deploy
([a production rehearsal](../deploy.en.md#2-6-a-production-rehearsal)).

Then commit everything the steps changed: `spin.toml`, `spin.lock`, `gen/`,
`db/`, the generators' files and your own edits.

## Deploy

In this order:

1. Install the new command on every machine that builds the application
   (the server, in [the deployment tutorial](../deploy.en.md#upgrading-the-framework);
   the `Dockerfile` with Kamal), and run `cybertrain setup` there. The
   deploy's build stops when the command and `spin.lock` differ.
2. Add to the environment the settings and secrets the notes name
   ([Configuration and environment variables](configuration.md#configuration-and-environment-variables)).
3. Take a backup.
4. Stop every old process (`server`, `worker`, `feeds`) before the first
   new one starts, when the notes ask for it
   ([Process roles](background-and-operations.md#process-roles)).
5. Deploy as usual: the build, `./<app> migrate`, then the `db` commands
   the notes name, then the new processes.

To go back, switch to the previous build and restart
([Rolling back](../deploy.en.md#rolling-back)). Migrations are not rolled
back by that, and a `db` command that rewrote stored data is not undone.
Unless the release's notes say the old release reads the rewritten data,
going back after such a command means restoring the backup from step 3.

## Which steps a release needs

Every step is run for every release; most of them finish at once when the
release does not need them. Each one says so itself:

| Step | Nothing to do when |
| --- | --- |
| Change the version | never: every release changes it |
| Install the pinned Spinel | `cybertrain setup` prints `nothing to install` |
| Regenerate | `git status --short gen/` prints nothing |
| Run the generators again | the run prints no `manual` and no `create` line |
| Migrate | `cybertrain db status` shows no `down` line |
| Apply the notes | the release has no section below |
| Tests, deploy | never |

A patch release (`X.Y.Z` to `X.Y.Z+1`) carries no compatibility change and
has no notes. A minor release (`X.Y` to `X.Y+1`) may carry them, and then it
has a section below
([the compatibility contract](../compatibility.md#changing-a-contract)).

## Notes by version

The sections after this one hold what each release asks for beyond the
procedure, newest first. A section is named for the two releases it lies
between and is divided by topic. Notes for a
release are written here and nowhere else: the guide of a topic describes
the framework as it is, and the procedure above names no release.

## From 0.4 to 0.5

### From 0.4: requests

What changes for an application written for 0.4:

- Every session ends once: the encrypted cookie does not read the old
  signed one, so users sign in again. Code that calls `Session.load` or
  `Session.dump` passes the derived key, `Crypto.derive_key(secret,
  SessionStore::SESSION_KEY_LABEL)`; the raw secret raises
  `Encryptor::Error`.
- Every application links OpenSSL ([Installing](install.md#requirements));
  a Dockerfile `cybertrain new` wrote earlier needs `libssl-dev` in its
  build stage and `libssl3t64` in its runtime stage.
- A dynamic segment no longer captures a `.` in a route that takes a
  format: an id with dots needs `format: false` on its route.
- A hand-written `url_resolver` lambda takes three arguments, `->(name,
  args, options)`; one that passes `Gen::Routes.url_resolver` needs only
  `spin run gen`.
- `params.permit` returns `Hash{String => Object}`: call `Cast.str` or
  `.to_s` on a value before using it as a String.
- `rate_limit` counts in the cache: `store: :memory` keeps the old
  per-process counter, two limits in one controller need their own
  `name:`, a `by:` method answering nil or `""` raises, and a `with:`
  method that renders nothing is followed by the 429.
- The number helpers raise for a value that is not a number (nil renders
  `""` in a template, as before), and for a precision outside 0 to 100.
- `include A, B` in a controller or model includes B first, as Ruby does; an
  `include` of a module that is not a concern is left to Ruby.
- Every ETag changes once (it now holds the request's format and a build
  digest), a response negotiated by `Accept` sends `Vary: Accept`, and the
  html fallback covers any `Accept` that lists `text/html` or `*/*`. A
  request that may fall back to html (`application/json, text/html`) has
  an ETag of its own, apart from the one of a request for that format
  alone; `text/html;q=0` in `Accept` gets no html fallback (406 where the
  action has only html), also beside `*/*`; and `If-None-Match: *` gets a
  304 from a response validated by `last_modified:` alone.
- `permit` and `expect` raise `ArgumentError` for a filter that is not an
  Array; a `layout` that names a missing layout raises `MissingTemplate`
  (the default `application` layout stays optional); a jar cookie over 4096
  bytes raises `Session::CookieOverflow`.
- `public/style.css` keeps working; moving it to `app/assets/stylesheets/`
  is optional ([Assets](assets.md#moving-publicstylecss)).
- Validation messages come from the bundled dictionary
  ([Internationalization](i18n.md#models-and-validation-messages)), with
  the same English text except three: a message on `:base` is no longer
  prefixed "Base", an attribute ending in `_id` is named without "id"
  ("Article can't be blank", not "Article id can't be blank"), and a
  length limit of 1 reads "1 character". Tests that compare these
  messages change.
- `time_tag` without `format:`, or with a format name, formats through
  `I18n.l` (the same English text as before in an English page).
- gen writes `gen/locales.rb` (empty without `config/locales/`) and loads
  `app/mailers/**/*.rb`; `cybertrain new` writes `config/locales/en.yml`,
  which an older application can add.
- `allow_unauthenticated_access` is a framework method now; the one 0.4's
  generator wrote into `ApplicationController` keeps working and takes
  precedence. Running `cybertrain generate authentication` again adds
  password reset, lockout, remember me, the account page and admin users,
  and prints diffs for the files 0.4 wrote
  ([From 0.4: authentication](#from-04-authentication)).

### From 0.4: models and the database

Each change below is a one-pass edit to an application written for
CyberTrain 0.4:

1. A `has_many` reader returns a relation, not an Array: add `.to_a` before
   an Array-only method (`map`, `select`, `[]`, `+`). Templates are
   unchanged.
2. Datetimes are stored in Rails' format: run `db normalize` once after
   upgrading ([Datetimes and `db normalize`](models.md#datetimes-and-db-normalize));
   until then a column mixing the two formats sorts by format.
3. `as_json` and `to_json` write times as `2026-10-05T09:00:00.000Z` (it was
   `2026-10-05T09:00:00Z`): JSON snapshots in tests change.
4. A `t.date` attribute is a `Date`, not a String: `strftime` still works,
   concatenation needs `to_s`. A NOT NULL date column now validates presence.
5. A declared `belongs_to` without `optional: true` validates its foreign
   key; undeclared ones are unchanged.
6. `where(x: a..b)` with Integer ends is a range condition (it was an
   equality with the Range's text, which never matched); Time and Date
   bounds use `where_between`.
7. `Cybertrain::Cast.iso8601` is the display format: code that built SQL
   text with it switches to `Cast.sql_datetime`, and `Cast.binds` binds a
   Time in the stored format.
8. `allow_blank: true` on a `validates` line also lets `presence` on that
   line pass a blank value, as in Rails (it applied to `length` only).
9. A column named like a method every model now has (`update_columns`,
   `destroy_dependents`, `run_custom_validations`, ...) is generated as
   `<column>_column` ([Column names](models.md#column-names)).
10. A `belongs_to` reader keeps the parent it read until the foreign key
    changes (it read it again on every call): call `reload` to see a change
    another process made.

### From 0.4: authentication

Run `cybertrain generate authentication` again in the application 0.4
generated ([Run the generators again](#run-the-generators-again)).

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff)
is the whole output for a sign-up application 0.4 generated.

<!-- list: points -->
- 0.4's block in `ApplicationController` becomes `include Authentication`.
  `--force` replaces it only when it is exactly as 0.4 wrote it.
- With `--confirmable`, the diffs of the sessions and registrations
  controllers carry an `IMPORTANT:` line: until they are applied, an
  unconfirmed account is not told why it cannot sign in, and a sign-up is
  mailed no link. In a 0.4 application the concern is a new file, written
  with its confirmation check, so it still starts no session for an
  unconfirmed account (and logs `WARN [<request id>] no session started: user <id> has
  not confirmed its address`) even if those diffs are never applied.
- Every session ends once at the upgrade (the cookie is encrypted now).

### From 0.4: configuration

Two defaults changed after 0.4
([Configuration and environment variables](configuration.md#configuration-and-environment-variables)):

- Render nesting was unlimited and is now capped by `max_render_depth`, 12 by
  default. An application with a deeper tree of partials (threaded comments, a
  category menu) gets a template error until it raises the setting.
- `job_poll_interval` was 5 seconds and is now 1: jobs run on their own
  threads, and an idle one looks for work every second.

### From 0.4: jobs

- `cybertrain_jobs` gains the column `concurrency_key` and the state
  `discarded`; the first process that touches the table adds the column.
  Code that lists states (a dashboard over `Job.state_count`) adds
  `discarded`. `Job.prune_done` still prunes `done` rows only.
- `every` tasks continue from the timetable after a restart instead of
  starting afresh: an interval that passed while the process was down runs
  once at start.
- Giving an existing kind a key (`limits_concurrency ... key:`): stop every
  old process before the first new one starts, as for any upgrade
  ([Process roles](background-and-operations.md#process-roles)). The first
  new process keys the `queued` rows enqueued before (it logs the ids of
  rows whose payload has no such field), and a `running` row left by an old
  process gets its key when it is recovered.
- `jobs` is now a built-in command: an application command named `jobs`
  must be renamed.

### From 0.4: logs and error reports

- Every log line changes shape: the level in brackets at the start
  (`[INFO]`) gives way to the time, the level and the tags,
  `2026-11-14T09:30:00.132Z INFO [<request id>] Completed 200 in 3ms`.
  Anything that reads the log (a grep for `[ERROR]` in a script, an alert)
  changes with it; a test that looked for a whole line looks for the level
  and the message separately (`" ERROR "` and the message;
  [From 0.4: tests](#from-04-tests)).
- Every response the application answers carries `X-Request-Id` (not the
  server's own 400 and 413 for a request it cannot read). A proxy that set
  one has it used only when the proxy is trusted.
- `cybertrain_jobs` gains the column `request_id`; the first process that
  touches the table adds it.
- A text log line no longer continues on the next lines: a line feed or
  carriage return in a message or a tag is written as `\n` or `\r`.
  Anything that read a multi-line message from several lines reads the
  escapes instead.
- A model column named `handle` now reads as `handle_column`: an
  application with a `users.handle` column changes its `user.handle` calls
  to `user.handle_column` (queries keep the SQL name). Columns named
  `request_id` or `release` that are not text are refused by gen
  ([Column names](models.md#column-names)).
- `cybertrain test` ignores an exported `CYBERTRAIN_LOG_FORMAT` and
  `CYBERTRAIN_SENTRY_DSN` (tests read text lines and send nothing) unless
  `config/app.rb` sets them. The password tests `generate authentication`
  writes turn JSON lines off inside their `with_config`; an application
  generated earlier whose tests run with `log_format :json` runs the
  generator again or copies that change.
- `require "cybertrain"` now links `HttpClient` and the TLS layer, through
  the Sentry sender.

### From 0.4: tests

- Add `test/test_helper.rb` ([Writing a test](testing.md#writing-a-test)),
  and move what a support file did at load time (`AppTest.boot`,
  `BlogTest.boot`, migrating a database) out of it: the test program boots
  on a fresh database before the first test, and a second boot only costs
  time.
- Change the CI step from `spin test` to `cybertrain test`.
- Two files that define the same top-level helper or constant (a
  `new_client` in each, as the 0.4 generators wrote them) are refused
  together: move the helper to `test/support/` or rename one.
- Every table is emptied before each test, so a later test can no longer
  rely on rows an earlier one made: move such data to fixtures or `setup`.
- The clock seams are gone: `Cybertrain::Cache.clock=`,
  `Cache.system_clock`, `RateLimit.current_time=`, `SessionStore#fixed_now=`,
  `Application.status_now=` and `Background.supervisor_clock=`. Use
  `travel_to`, `travel` or `freeze_time`, whose block puts the time back
  without an `ensure` of your own.
- Mail in tests is kept in `Cybertrain::Mailer.deliveries`; a test that
  reads mail at a `Test::SmtpReceiver` sets
  `Cybertrain.config.mail_delivery_method = :smtp` first.
- A helper test 0.4's `generate helper` wrote defines a top-level
  `render_inline(source)`, which clashes with the framework's: rename it
  `render_helper_template` in that file, calls included.
- `1.month.ago` is `Time.current.months_ago(1)`.
- `assert_equal` fails with Minitest's two-line text; a passing snapshot
  does not change.
- `cybertrain generate authentication`, run again, writes the class-form
  tests and names each old file they replace (`test/authentication.rb`,
  `test/support/app_test.rb`, ...); `--force` deletes them.
- A test that looked for a whole log line, its level in brackets first,
  looks for the level and the message apart (`" ERROR "` and
  `"password reset mail not sent: "`): a line now starts with the time and
  may carry the request's id
  ([Logs](logs-and-errors.md#logs)).
- An exported `CYBERTRAIN_LOG_FORMAT` or `CYBERTRAIN_SENTRY_DSN` no longer
  reaches the tests; set them in `config/app.rb`, or assign the DSN in the
  test, to test with them.
