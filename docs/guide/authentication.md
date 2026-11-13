# Authentication

`cybertrain generate authentication` writes email-and-password sign-in as
Rails 8's generator does, as code the application owns, together with what
Devise adds: password reset by mail, optional address confirmation,
lockout, "keep me signed in", an account page and admin users.

## Generating it

```shell terminal — blog/
cybertrain generate authentication                  # a public sign-up page
cybertrain generate authentication --invite-only    # no sign-up: users come from the command line or /setup
cybertrain generate authentication --confirmable    # (either mode) new addresses confirm by mail
cybertrain db migrate
```

It writes, in the application:

| Files | What they are |
| --- | --- |
| `db/migrate/*_create_users.rb`, `*_create_sessions.rb` | `users` (`email_address`, `password_digest`, `admin`, `failed_attempts`, `locked_until`; with `--confirmable` `confirmed_at`, `unconfirmed_email`) and `sessions` (one row per signed-in browser, with `remember` and `last_active_at`) |
| `app/models/user.rb`, `session.rb` | `password=`, `authenticate`, `User.authenticate_by`, the tokens, the lockout |
| `app/controllers/concerns/authentication.rb` | the `Authentication` concern, included into `ApplicationController` |
| `sessions_controller.rb`, `registrations_controller.rb` (or `setup_controller.rb`), `passwords_controller.rb`, `accounts_controller.rb`, `confirmations_controller.rb` | sign-in, sign-up (or the first user's page), password reset, the account page, confirmation |
| `app/mailers/passwords_mailer.rb`, `confirmations_mailer.rb` | the mails |
| `app/commands/user_command.rb` | `./<app> user ...`, required from `bin/<app>.rb` |
| `app/views/...` | the screens, every text through `t()`, and the `sessions/_nav` partial |
| `test/fixtures/users.yml`, `test/support/session_test_helper.rb`, `test/models/`, `test/controllers/`, `test/integration/` | the fixture users, `sign_in_as`, and tests for each part ([Testing](#testing)) |

and edits, once each: `include Authentication` in `ApplicationController`,
the routes, the jobs page's line ([Admin users](#admin-users-and-the-jobs-page)),
the nav partial in the layout, the user command in `bin/<app>.rb`, and the
`base_url` setting in `config/app.rb` ([Links in mails](#links-in-mails)).
Running it again with the same options changes nothing: an edit already
made is found and skipped, and a file already as it would write it is
left. A file it would write differently (one you edited, or one an older
generator or other options wrote) is never overwritten without `--force`:
its diff is printed instead ([Upgrading from 0.4](#upgrading-from-04),
[Turning on confirmation later](#turning-on-confirmation-later)).

The texts of the generated screens are in the framework's English and
Japanese dictionaries, under their lazy keys (`sessions.new.title`,
`passwords.create.sent`); an application overrides them, or adds a
language, in `config/locales/` ([Internationalization](i18n.md#the-bundled-dictionaries)).

## Signing in and out

```ruby app/controllers/concerns/authentication.rb (excerpt)
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session
    before_action :require_authentication
    helper_method :authenticated?
  end
```

From then on every action needs a signed-in user, and a visitor is sent to
`/session/new` (a 303; a GET is remembered and returned to after sign-in,
if it is a local path). A controller opens actions to visitors as in Rails:

```ruby app/controllers/articles_controller.rb (excerpt)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
```

`allow_unauthenticated_access(only:, except:)` is a method of
`Cybertrain::Controller`, a `skip_before_action :require_authentication`.
`resume_session` still runs on open pages, so a template reads
`@current_user` (and `@current_session`), or calls `authenticated?`. There
is no `Current` object.

<!-- list: points -->
- `SessionsController` (`resource :session`): `GET /session/new`, `POST
  /session`, `DELETE /session`. Sign-in attempts are limited to ten per
  client address every three minutes, counted in the cache, so every
  process counts together; behind a proxy, set
  [trusted proxies](requests.md#rate-limiting-and-the-client-address).
- A wrong password, an unknown address and a locked account get the same
  message after the same password check (against a dummy digest when
  there is no account).
- `resume_session` ends a sign-in (and deletes its Session row) once the
  password changed since, after its lifetime, or after
  `auth_idle_timeout` without a request ([Remember me](#remember-me-and-session-limits)).
- Signing out deletes the Session row and empties the cookie session.

## Sign-up, or invite-only

By default the generator writes `RegistrationsController` (`/sign_up`),
which creates a user and signs them in. Rails' generator has no sign-up
page and leaves the first user to the console; CyberTrain has no Ruby
console, so it writes one. Sign-ups are limited to ten per client address
every three minutes, as sign-ins are: each one hashes a password, may mail
a link, and its "has already been taken" tells whether an address is
registered.

Every address the generated code saves, from the sign-up page, `/setup`,
the account page and the user command, must be one address:
`User.email_address_format?` asks for exactly one `@` with text on both
sides, and no comma, whitespace, angle bracket or control character. The
mailer reads `ann@example.com,eve@evil.example` as two recipients, so
without the check one account could hold two mailboxes, have its reset
link mailed to both and, with `--confirmable`, be confirmed by either.
The address must also pass the mailer's own check
(`Cybertrain::Mailer.address_problem`): plain ASCII only, so no Unicode
space or control character either, none of `( ) [ ] ; : \ "`, a local
part of at most 64 bytes and at most 254 bytes in all. An address the
mailer would refuse could be saved but never sent a mail, so it is
refused when it is entered. Some addresses the mail standards allow are
refused too (a quoted local part with a space or a comma in it, a
non-ASCII address); the method is the application's to change. An
address saved before the check existed is not checked again, so its
account can still be reset and signed in to.

`--invite-only` writes no sign-up page, the right default for an internal
tool, where whoever reaches the server first would otherwise get an
account. The first user comes from the user command, or from
`SetupController` (`GET` and `POST /setup`), which creates the user and
signs them in:

<!-- list: points -->
- It answers only while no user exists, only with the one-time token, and
  only to a connection whose socket peer is the loopback address and that
  carries no `X-Forwarded-For` header (a proxy on the same host makes
  every request a loopback one, and adds that header). Everyone else gets
  a 404.
- The token is 32 random hex characters made when the program starts
  (`SetupController.setup_token`), compared in constant time. It keeps the
  page closed where the address check cannot, behind a proxy that adds no
  `X-Forwarded-For`. The request log shows it as `[FILTERED]`.
- While no user exists, the server logs `[WARN] no user exists yet: run
  ./<app> user EMAIL, or open /setup?token=<token> from this machine`
  before it boots; that line is the only place the token is printed.
- `<APP>_SETUP_OPEN=1` (the `setup_open` setting in `config/app.rb`) lifts
  the address check, never the token, for a first run behind a proxy on
  another host. Unset it once the user exists.

## The user command

`./<app> user` is written in both modes:

```shell terminal — production host
./blog user ann@example.com                       # create, or set the password; it is read from stdin
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user admin ann@example.com                 # make an admin
./blog user unadmin ann@example.com
```

Without a password argument it reads one line of standard input (prompting
on a terminal; the typing is echoed), which keeps the password out of `ps`
and the shell history. Setting a password signs that user's browsers out
and clears a lockout. With `--confirmable`, the users it creates are
confirmed. It prints `created`, `updated`, `admin` or `unadmin` and the
address and exits 0, or prints the usage or an error and exits 1.

## Remember me and session limits

The sign-in form has a "Keep me signed in" box (`check_box_tag
:remember_me`). A sign-in lasts:

| | Checked | Unchecked |
| --- | --- | --- |
| The Session row and the cookie end after | `auth_remember_for` (30 days) | `session_absolute_max_age` (two weeks) |
| The cookie | `Max-Age` of the time left | no `Max-Age` and no `Expires`: it ends with the browser |
| Unused for `auth_idle_timeout` (7 days; `0` turns it off) | ends | ends |

`last_active_at` is written at most once a minute. The generated
`start_new_session_for(user, remember:)` calls `session.restart_lifetime!`,
then `session.stamp_lifetime!(seconds, persistent)`, in that order: a
restart clears the stamp. The limit it stamps is never 0: with
`session_absolute_max_age = 0` an unremembered sign-in lasts
`session_max_age`, or two weeks. The settings are in
[Configuration](configuration.md#authentication-settings).

## Lockout

`auth_lockout_attempts` (10) wrong passwords lock the account for
`auth_lockout_period` (an hour). A locked account answers the
wrong-password message, whatever the password. A successful sign-in, a
password reset and `./<app> user EMAIL` clear the count;
`auth_lockout_attempts = 0` turns lockout off and stops enforcing a lock
made before. The count is one `UPDATE` that reads the row as it is
(`Relation#update_all_sql`), so sign-ins at the same moment all count. The
per-client-address rate limit stays.

## Password reset

The sign-in page links to `/passwords/new`. The address form always
answers "If that address is registered, a link to reset the password was
sent to it.", after the same work for an unknown address short of sending.
The mail (`PasswordsMailer.reset(user, url).deliver_later`, in the
request's language) carries `/passwords/<token>/edit`; the token is valid
for 15 minutes and only while the password and the address stay as they
were, so it works once. Setting the new password clears a lockout and ends
every session of the user; with `--confirmable` it also withdraws a new
address waiting ([Confirming addresses](#confirming-addresses)).

<!-- list: points -->
- The mail is sent by a job thread with the `CYBERTRAIN_SMTP_*` settings
  ([Sending e-mail](external-services.md#sending-e-mail)): a process that
  runs jobs, and the database, are needed.
- The link's page answers `Referrer-Policy: no-referrer`, and the
  framework's request log writes the token as `[FILTERED]`.
- Ten requests per client address every three minutes.

### Links in mails

A link starts with the `base_url` setting the generator declares in
`config/app.rb`, from `<APP>_BASE_URL` (`BLOG_BASE_URL=https://blog.example.com`).
Set it, with https, wherever the application is served. Unset, the link
takes the address the request came to only when the `Host` header is
checked (development, or `CYBERTRAIN_HOSTS` set) or in tests; anywhere
else no mail is sent, the log says `[ERROR] password reset mail not sent:
set <APP>_BASE_URL (or CYBERTRAIN_HOSTS)`, and the page answers as usual. A
forged `Host` never reaches a link.

## Confirming addresses

With `--confirmable`, a sign-up mails a link to the address and signs
nobody in. The right password for an address not confirmed yet is refused
with its own message (a wrong one gets the usual message), and the sign-in
page links to a form that mails the link again. Opening the link
(`/confirmations/<token>`, valid for three days, once) confirms the
address; the user then signs in. The concern's `start_new_session_for`
refuses an unconfirmed user too, whichever controller asks, and logs
`[WARN] no session started: user <id> has not confirmed its address`. That
check is in the concern the generator writes with `--confirmable`: in a
new application, and in a 0.4 upgrade, where the concern is a new file.
An application that already has the concern gets the check as a diff
([Turning on confirmation later](#turning-on-confirmation-later)).

A new address on the account page waits in `unconfirmed_email`, and takes
the old one's place when its own link is opened; the page can withdraw it
(`DELETE /account/pending_email`), which ends that link. Users made by the
user command and by `/setup` are confirmed. A password reset confirms an
account that was never confirmed (the link proved the mailbox), never a
new address waiting: it withdraws that address, which ends its link,
since whoever asked for it may be the one the owner is taking the account
back from. The owner asks for it again afterwards. A new password on the
account page keeps the address waiting (the user is there and sees it).

## The account page

`/account/edit` (the nav's "Account") changes the address or the password,
each only with the current password, and deletes the account (with its
sessions, in one transaction) only with the password. A new password ends
every session of the user and signs this browser in again, remembered as
it was. Account changes and deletions (so also wrong current passwords)
are limited to ten every three minutes per client address and per user,
and a wrong current password does not count toward lockout.

## Admin users and the jobs page

`users.admin` (false) is set with `./<app> user admin EMAIL`. The concern's
`require_admin` answers 404 unless the signed-in user is an admin:

```ruby app/controllers/concerns/admin_gate.rb (excerpt, examples/blog)
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
  end
end
```

The generator draws the jobs page behind it, in place of the comment
`cybertrain new` writes:

```ruby config/routes.rb (excerpt)
jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication
```

<!-- list: points -->
- On the jobs page `require_admin` runs alone, so a visitor gets the 404,
  as if there were no page. In a controller that declares `before_action
  :require_admin` itself, `require_authentication` runs first (Rails'
  order), so a visitor is sent to sign in (303) and a signed-in non-admin
  gets the 404.
- gen refuses a `skip_before_action:` without a `before_action:`, and one
  that names the `before_action:` itself: either would open the page to
  everyone.
- A `jobs_page` line the application wrote itself is left alone. One that
  already has `skip_before_action: :require_authentication` counts as
  drawn; for any other, the generator says to add it. Make the line read
  `jobs_page "...", before_action: :require_admin, skip_before_action:
  :require_authentication` for the 404 (gen refuses the skip without the
  `before_action:`).
- When `ApplicationController` defines `require_admin` itself, that method
  takes the concern's place in every controller. The generator says so as
  it inserts `include Authentication` (`warn  app/controllers/application_controller.rb
  defines require_admin itself: ...`), and draws the jobs page without the
  skip (`jobs_page "/admin/jobs", before_action: :require_admin`), so
  `require_authentication` runs before it there too. Delete the method to
  use the concern's.
- A failed or discarded mail job keeps the mail in its row, and the jobs
  page shows the row's arguments: an admin can read a reset or
  confirmation link there while it is valid. The page is for admins only,
  who can act on any account already.
- `/setup` and the user command make ordinary users; make the first one an
  admin with `./<app> user admin EMAIL`.

## What is left to the application

These are choices the generated code makes, each with its reason:

<!-- list: points -->
- A wrong password for an existing, unlocked account writes its row once
  (the count); an unknown address and a locked account do not. That one
  write is a timing difference, accepted as in Devise's lockable: equal
  writes for unknown addresses would add load for a signal the rate limit
  already bounds. The password reset form has the same kind of
  difference: a known address queues its mail, one row more.
- Sign-up, reset and confirmation mails are limited per client address
  only, not per address mailed: someone can mail an address at that rate.
  Sign-ins are limited to ten every three minutes per client address, the
  lockout threshold, so one client can keep a known account locked. A
  per-address limit (`rate_limit ... by:`) and a longer window are the
  application's to add.
- The old address is not told of an address change, a new address waiting
  never expires (its link does, and a password reset withdraws it), and an
  account never confirmed is never deleted.
- The account page's "has already been taken" tells a signed-in user, who
  gave the current password, that an address is registered (as Devise
  does), within the page's rate limit.

## The pieces the framework provides

The generated code is built from framework API, usable on its own:

| API | What it does |
| --- | --- |
| `Cybertrain::Password` | PBKDF2-HMAC-SHA256 digests: `hash`, `verify?`, `verify_serialized`, `dummy_digest`, `needs_rehash?`, `session_key`, `session_key_matches?` ([docs/design.md](../design.md) D25) |
| `Cybertrain::Token` | `issue(purpose, id, expires_in, bound_to)` gives `"<id>--<expires>--<hmac>"`; `id_from(token)`; `valid?(token, purpose, bound_to)` |
| `Cybertrain::MailMessage` | what a mailer method returns: `deliver_later` (a job) or `deliver_now` |
| `Session#restart_lifetime!`, `stamp_lifetime!(seconds, persistent)` | a sign-in's own lifetime and a browser-session cookie |
| `Relation#update_all_sql(sql, binds)` | `UPDATE ... SET <sql>` on the matching rows |
| `Controller.allow_unauthenticated_access`, `skip_before_action` | open actions to visitors |
| `Controller#safe_redirect_path(text, fallback)` | a local path from the request, or the fallback |
| `ParameterFilter.filter_path(path)` | a path with token-shaped segments as `[FILTERED]` |
| `check_box_tag(name, value = "1", checked = false)` | a checkbox with no hidden field |

A hand-written sign-in uses `Password` as the generated `User` does:
`Cybertrain::Password.verify_serialized(password, user.nil? ?
Cybertrain::Password.dummy_digest : user.password_digest)` checks one
password at a time per process (a check takes about 0.2 s of CPU) and
takes as long for an unknown address; `session[:password_key] =
Cybertrain::Password.session_key(user.password_digest)` at sign-in, checked
with `session_key_matches?` on each request, signs a browser out once the
password changes.

`Token.valid?` checks a token against the `bound_to` given, so look the
record up by `Token.id_from` first and check against that record's own
value, as `User.find_by_password_reset_token` does.

## Testing

The generator writes Rails-shaped test classes, which `cybertrain test`
runs ([Testing an app](testing.md)):

| File | What it tests |
| --- | --- |
| `test/fixtures/users.yml` | `one` (an admin) and `two`, whose password is `"password"` (with `--confirmable`, both confirmed) |
| `test/support/session_test_helper.rb` | `sign_in_as(user, remember: false)`, `sign_out` and `open_session` (a second browser), included into every integration test by `test/test_helper.rb` |
| `test/models/user_test.rb` | the address format |
| `test/controllers/sessions_controller_test.rb` | sign-in and sign-out |
| `test/controllers/registrations_controller_test.rb` | sign-up (not with `--invite-only`) |
| `test/integration/first_run_test.rb` | `/setup` and the user command (with `--invite-only`) |
| `test/controllers/passwords_controller_test.rb` | the reset, its mail and its link |
| `test/controllers/accounts_controller_test.rb` | the account page |
| `test/controllers/confirmations_controller_test.rb` | confirmation (with `--confirmable`) |
| `test/integration/remember_me_test.rb` | day 15 and day 30, the idle limit |
| `test/integration/lockout_test.rb` | the lock and its hour |
| `test/integration/admin_test.rb` | `require_admin`, `user admin` |

Time moves with `travel_to` and `travel` (no row is moved back in time),
and mail is read from `Cybertrain::Mailer.deliveries` with `assert_emails`
and `perform_enqueued_jobs`. A scaffold generated after authentication
signs `users(:one)` in at the top of its controller test; one generated
before it does not, so add `sign_in_as users(:one)` to its `setup`. Run
again over an application whose tests an earlier generator wrote
(`test/authentication.rb`, `admin.rb`, `remember_me.rb`, `lockout.rb`,
`passwords.rb`, `accounts.rb`, `confirmations.rb`,
`test/support/app_test.rb`, `test/support/authentication_helpers.rb`), the
generator names each with the file that replaces it; `--force` deletes
them.

`script/auth-e2e signup invite confirmable upgrade04` in this repository
builds applications with the generator and drives them from end to end.

## Upgrading from 0.4

Run the generator again in an application 0.4 generated. It writes the
files that are missing, a migration with the columns the existing ones
lack, and the edits; for each file it would write whole that exists with
other content, it changes nothing and prints a diff:

```text output — cybertrain generate authentication (excerpt)
exist db/migrate/20260925120000_create_users.rb
create db/migrate/20260925120002_add_authentication_columns.rb
manual  app/models/user.rb (diff below)
create app/controllers/concerns/authentication.rb
manual  app/controllers/sessions_controller.rb (diff below)
create app/controllers/passwords_controller.rb
...
manual  app/controllers/application_controller.rb (diff below)
...
manual  app/controllers/application_controller.rb: apply this diff by hand, or re-run with --force to overwrite the file
--- a/app/controllers/application_controller.rb
+++ b/app/controllers/application_controller.rb
@@ -1,95 +1,5 @@
 class ApplicationController < Cybertrain::Controller
-  # ---- Authentication (cybertrain generate authentication) -------------
-  # Every action needs a signed-in user unless its controller opens it:
...
-  # ---- end of authentication ------------------------------------------
+  include Authentication
```

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff)
is the whole output for a sign-up application 0.4 generated.

<!-- list: points -->
- Save the output and apply it with `patch -p1` from the application's
  directory (patch skips the lines that are not part of a diff), or apply
  each diff by hand where you changed the file. The application may not
  build until they are applied: the new files call what the diffs add.
- `--force` writes the new files over the old ones instead, for files you
  never edited; 0.4's block in `ApplicationController` is replaced only
  when it is exactly as 0.4 wrote it.
- The new migration adds only the columns that are missing; run `cybertrain
  db migrate`. With `--confirmable` it also counts the users already there
  as confirmed (since they were created), or none of them could sign in.
- With `--confirmable`, the diffs of the sessions and registrations
  controllers carry an `IMPORTANT:` line: until they are applied, an
  unconfirmed account is not told why it cannot sign in, and a sign-up is
  mailed no link. In a 0.4 application the concern is a new file, written
  with its confirmation check, so it still starts no session for an
  unconfirmed account (and logs `[WARN] no session started: user <id> has
  not confirmed its address`) even if those diffs are never applied.
- Every session ends once at the upgrade (the cookie is encrypted now), and
  the rest of [Upgrading an application from 0.4](requests.md#upgrading-an-application-from-04)
  applies too.

### Turning on confirmation later

Run `cybertrain generate authentication --confirmable` (with
`--invite-only` if the application has it) in an application generated
without it. It writes the confirmation files and an add-columns migration,
which counts the users already there as confirmed, and prints a diff for
each file it wrote before. Here the concern exists, so its confirmation
check arrives as one of those diffs, and the output marks it `IMPORTANT:`:
until the concern's diff is applied, unconfirmed accounts sign in,
whatever the other diffs say. Apply it, and the sessions controller's,
before deploying. With `--invite-only`, the setup controller's diff is
marked too: until it is applied, the first user `/setup` creates is not
confirmed and cannot sign in (a password reset confirms it).
