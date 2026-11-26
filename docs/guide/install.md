# Installing

What CyberTrain needs on your machine, how to install the `cybertrain`
command, every command it has, and how it installs Spinel and the framework
for you.

> [!NOTE]
> To try CyberTrain without installing anything, open [the playground](site:playground.html):
> GitHub Codespaces opens the tutorial's blog, the `cybertrain` command and
> the pinned Spinel release in VS Code in your browser. The same image also runs locally under Docker.

## Requirements

- Spinel, at the release in `Cybertrain::SPINEL_TAG`
  ([cybertrain/version.rb](../../cybertrain/version.rb); `cybertrain doctor`
  prints it, and CI's `SPINEL_TAG` in
  [.github/workflows/ci.yml](../../.github/workflows/ci.yml) is the same), a
  release of [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)
  (`Cybertrain::SPINEL_REPOSITORY`), the fork of matz/spinel that carries
  the fixes CyberTrain needs ahead of an upstream release;
  untested against other versions. You do not install it by hand: the
  `cybertrain` command builds that release into `~/.cybertrain` the first
  time it needs it (`cybertrain setup` does that on request), unless a
  `spinel` of that release is already on `PATH` — see [How Spinel is installed](#how-spinel-is-installed).
- To build it: a C toolchain (`cc`, or the compiler `CC` names) and `make`
  — Spinel compiles every program to C — plus `git` and `curl`.
- SQLite 3 headers/library (`libsqlite3-dev` on Debian/Ubuntu; present with
  Xcode's command line tools on macOS) — models use Spinel's FFI directly,
  not a gem.
- zlib headers/library (`zlib1g-dev` on Debian/Ubuntu; in the macOS SDK) —
  gzip request bodies (`request.decoded_body`) are inflated through the
  system zlib, bound the same way.
- OpenSSL headers/library (`libssl-dev` on Debian/Ubuntu) — every
  application links them: the session cookie and `cookies.encrypted` are
  AES-256-GCM through Spinel's `openssl` package, which Spinel builds only
  when the headers are there. On macOS install Homebrew's
  (`brew install openssl@3`), which is keg-only, and put it on the
  compiler's paths: `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- Ruby 3.2+ and RubyGems, for the `cybertrain` command and the development
  server's CRuby preview, which also needs Ruby's `fiddle` library (it
  needs libffi); without `fiddle`, `cybertrain server` runs the compiled
  loop only. A deployed application never runs on CRuby. On Ruby 3.2,
  building Spinel also needs the `prism` gem (below).

`cybertrain doctor` checks these tools and headers, whether the `ruby` on
`PATH` loads `fiddle`, and the Spinel install; when a required one is
missing it also prints the install command for your platform (a missing
`fiddle` does not count: the server still runs, compiled).

<details><summary>More packages — prism on Ruby 3.2; jemalloc, optional</summary>

- Building Spinel needs Ruby's `prism` gem, which Ruby 3.3 and newer bundle;
  on Ruby 3.2, `gem install prism` (with Ruby's development headers,
  `ruby-dev` on Debian/Ubuntu). `cybertrain doctor` checks it.
- A Spinel built before the OpenSSL headers were installed has no `openssl`
  package, and an application then fails to build; run
  `cybertrain setup --force` once they are there to rebuild it. The same package serves TLS
  (`require "cybertrain/net/tls"`) and encrypted columns (`encrypts`).
- jemalloc's development package (`libjemalloc-dev`; `brew install jemalloc`)
  is optional: an app needs it only once its `spin.toml` says
  `allocator = "jemalloc"`, which `cybertrain new` writes commented out.
  Measure it on your own application before relying on it in production: on
  examples/blog it gave 1.3 to 1.4 times the requests per second on the
  dynamic pages in the run of 2026-10-09, and within a few percent on the
  pages (18% more on the POST, on one core) in the latest one
  ([docs/benchmark.md](../benchmark.md)).

</details>

## Install the CLI

```shell terminal — any directory
gem install cybertrain
cybertrain doctor
```

The first line installs the command from RubyGems and the second checks the
[requirements](#requirements); [the tutorial](tutorial.md#install) goes on
from there, from `cybertrain new` to `cybertrain build`.

## The `cybertrain` command

`cybertrain help` prints these commands:

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` creates an application in NAME, then runs `spin lock` and
  `SPIN_DEBUG=1 spin run gen` in it, installing Spinel first when it is
  needed (the CLI builds gen and `bin/db.rb` in spin's debug mode).
- `cybertrain generate scaffold NAME field:type ... [parent:references] [--any]`
  (alias `g scaffold`) adds a resource to the application in the current
  directory; a `parent:references` field is the `parent_id` column, and
  `--any` goes with an attachment field (below).
- `cybertrain generate authentication [--invite-only] [--confirmable] [--force]`
  adds email-and-password sign-in to it: users and sessions tables, `User`
  and `Session` models, the `Authentication` concern that
  `ApplicationController` includes, the sign-in, sign-up, password-reset and
  account controllers and views, the routes, the jobs page behind
  `require_admin`, the subsystem lines it needs in `bin/<app>.rb` and
  `bin/db.rb`, and tests. `--invite-only` leaves the sign-up page out,
  `--confirmable` has a new account confirm its address by mail before it
  can sign in, and `--force` overwrites the files for which a second run
  otherwise only prints a diff ([Authentication](authentication.md)).
- `cybertrain generate attachment MODEL FIELD [--any] [--show-checks-nothing]`
  adds a file upload
  to a scaffolded model: five metadata columns, model methods and
  callbacks, a download action, the route, the form field and a test (see
  [Add a cover image](advanced-tutorial.md#attachments)). A scaffold field `cover:attachment` does the same.
  The download does not run the code inside `def show`, so a `show` with
  code of its own is refused until that code moves into a `before_action`
  or `--show-checks-nothing` says it limits nobody.
- `cybertrain generate helper NAME [--force]` adds
  `app/helpers/NAME_helper.rb`, a module whose methods every template can
  call once `spin run gen` has run, and a test
  ([Application helpers](template-language.md#application-helpers)).
- `cybertrain generate component NAME [attr[:type] ...] [--force]` adds a
  view component: `app/components/NAME_component.rb`, its template and a
  test ([Components](template-language.md#components)).
- `cybertrain generate job NAME [--retry Klass:wait:attempts ...] [--force]`
  adds `app/jobs/NAME_job.rb` and a test, and `require "cybertrain/jobs"` to
  `bin/<app>.rb` and `bin/db.rb`
  ([Background work](background-and-operations.md#background-work)).
- `cybertrain db migrate` generates, applies pending migrations, and
  generates again (`SPIN_DEBUG=1 spin run gen; SPIN_DEBUG=1 spin run db --
  migrate; SPIN_DEBUG=1 spin run gen`);
  `cybertrain migration` is kept as an alias.
- `cybertrain db COMMAND...` runs any other database command after
  `SPIN_DEBUG=1 spin run gen`: `status`, `rollback [N]` (which generates
  again afterwards), `schema` (writes `db/schema.rb` from the database as it
  is, without migrating), `schema:dump`, `create`, `backup` and `vacuum`
  ([Operations](background-and-operations.md#operations-backups-vacuum-health-check))
  and `normalize`
  ([Datetimes and `db normalize`](models.md#datetimes-and-db-normalize)).
- `cybertrain server [PORT] [--spinel]` starts the development server
  (default: the application's port, `PORT` or `c.port`, 3000 unless set).
  Right after a change the application runs under CRuby while Spinel builds it in the background, and the compiled binary
  takes the port when its build succeeds; the application's responses
  carry `X-Cybertrain-Runtime: cruby` or `spinel` ([The development
  loop](how-it-works.md#the-development-loop)). `--spinel` runs the
  compiled loop only, every change waiting for its build
  (`SPIN_DEBUG=1 spin run gen`; `spin build NAME -- --incremental` when a
  Ruby file is newer than `build/bin/NAME`; `spin run NAME`, or `spin run
  NAME -- PORT`).
- `cybertrain build` builds NAME with `app/views/` embedded and assembles
  `dist/` (the binary, `public/`, `storage/`, `tmp/`).
- `cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]` generates, compiles
  every test under `test/` into one program (again only when something
  changed) and runs it, keeping the tests the arguments name (see
  [Testing an app](testing.md#running-the-tests)).
- `cybertrain spin ARGS...` runs `spin` with the pinned Spinel from any
  directory (`cybertrain spin test`, `cybertrain spin run gen -- --check`).
- `cybertrain secret [--hex]` prints a new random secret for
  `CYBERTRAIN_SECRET_KEY_BASE`; with `--hex`, a new key for
  `CYBERTRAIN_ENCRYPTION_KEY`. Both are 64 hex digits.
- `cybertrain setup [--force]` installs the pinned Spinel release into
  `~/.cybertrain` unless a `spinel` of that release is already on `PATH`;
  `--force` rebuilds the copy under `~/.cybertrain`.
- `cybertrain doctor` checks everything under [Requirements](#requirements):
  `git`, `make`, `curl`, the C compiler, the SQLite, zlib and OpenSSL
  headers, the `prism` gem, whether Ruby loads `fiddle` (the CRuby preview
  needs it) and the Spinel install.
- `cybertrain version` prints the version; `cybertrain help` prints this
  list.

`generate`, `db`, `server`, `build` and `test` run inside an application;
NAME is the `[package] name` in its `spin.toml`.

## How Spinel is installed

Every command that runs `spin` (`new`, `db`, `server`, `build`, `test`,
`spin`) first makes sure a Spinel of the release in
`Cybertrain::SPINEL_TAG` is available. A `spinel` on `PATH` (with a `spin`) whose `spinel --version` reports that
release is used as it is; otherwise the copy `cybertrain` keeps under
`~/.cybertrain/spinel/<SPINEL_TAG>/`; otherwise `cybertrain` builds that
copy from the release tag of `Cybertrain::SPINEL_REPOSITORY` (`git clone`,
`make deps`, `make -j`, `make install PREFIX=...`), once, in a few minutes,
logging to `~/.cybertrain/log/spinel-<SPINEL_TAG>-build.log` (its last
lines are printed if a step fails).

If a tool the build needs is missing,
`cybertrain` says which and prints the install command for your platform
before it starts. A `spinel` of another release on `PATH` is never used or
touched: `cybertrain` keeps its own copy (and says so when it installs it).

`cybertrain setup` does the same on request and, whenever its own copy is
the one in use, prints the line that puts it on `PATH`, for running `spin`
yourself:

```shell terminal — any directory
export PATH="$HOME/.cybertrain/bin:$PATH"
```

`~/.cybertrain/bin` holds `spinel` and `spin` links to the release in use, so
the line survives a release bump; `cybertrain spin ...` needs no `PATH` at all.

<details><summary>Environment variables — `CYBERTRAIN_HOME` moves `~/.cybertrain`, `CYBERTRAIN_SPINEL_HOME` uses an existing install</summary>

Two environment variables override all this:

- `CYBERTRAIN_HOME` replaces `~/.cybertrain` (a path without spaces, quotes,
  `$` or `:`, which Spinel's Makefile and `PATH` cannot take).
- `CYBERTRAIN_SPINEL_HOME=PREFIX` forces an existing install: `cybertrain`
  then uses the `spinel` and `spin` in `PREFIX/bin` (or in `PREFIX` itself,
  if `spinel` is directly in it) and stops with an error if they are not that
  release.

A third, `CYBERTRAIN_KEEP_SRC=1`, keeps the Spinel source the build cloned
(`~/.cybertrain/src/spinel-<SPINEL_TAG>/`) instead of deleting it after the
build.

</details>

## The gem and the framework

`gem install cybertrain` installs a command, not the framework. The gem is
the `cybertrain` command, plain Ruby that runs on your machine under CRuby
(3.2 or newer) and calls Spinel's `spin` tool for you; neither the framework
nor Spinel is in the gem. The framework is a Spinel package your app depends
on in its `spin.toml`: Spinel compiles it together with your code ahead of
time, and it is the part that ships. The binary in `dist/` runs without
Ruby, the gem or Spinel. Only in development does the application's code,
the framework included, also run under CRuby: `cybertrain server` serves a
CRuby preview of the application until the compiled binary takes over.

### What `cybertrain new` writes

`cybertrain new` writes the application with its `spin.toml` pointing at
the release matching the CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }`, where
X.Y.Z is what `cybertrain version` prints), makes
sure Spinel is installed, then runs `spin lock` (spin fetches the framework
into its cache, `~/.cache/spin/packages/`, and pins the commit in
`spin.lock`) and `SPIN_DEBUG=1 spin run gen`, much as `rails new` runs
`bundle install`, and prints the next steps. Nothing of the framework is copied into the app;
commit `spin.toml` and `spin.lock`. `bin/<app>.rb` and `bin/db.rb` require
`cybertrain/core`, the framework without its optional subsystems; the
generators that need one add its line
([Subsystems](how-it-works.md#subsystems)). It also writes `AGENTS.md`,
instructions for AI coding agents (where the application differs from
Rails, and the checks to run before a change is done), and `CLAUDE.md`,
which imports it for Claude Code.

If Spinel or one of the two `spin` steps fails, the files stay, `new` exits
with 1 and prints what to run once the cause is fixed (for Spinel:
`cybertrain setup`, then `cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin
run gen` in the new directory).

Four options change what it writes and runs:

- `--skip-spin` only writes the files: no Spinel install, no `spin lock`, no
  `spin run gen`.
- `--path DIR` depends on a local checkout instead
  (`--path ~/src/cybertrain`, wherever the checkout is, when working on
  CyberTrain itself).
- `--git URL [--ref R]` depends on the framework at URL (at branch or tag R).
- `--version V` depends on release V in a `spin-index`
  (`cybertrain = "V"`), once the framework is on one: see
  [An index version](#an-index-version).

Give only one of `--path`, `--version` and `--git`; `--ref` needs `--git`.

### An index version

A `spin-index` is the list of packages spin looks a name up in. The
framework is not on one yet: until it is, `spin lock` in an app created with
`--version` answers `not in the index: cybertrain`, and the tag that `new`
writes by default is the way to depend on a release. Once it is,
`cybertrain new NAME --version X.Y.Z` writes `cybertrain = "X.Y.Z"`, spin
finds that release's commit in the index, and `spin.lock` pins the same three
things it pins for the tag (the version, the repository and the commit), so
every command and the CI workflow `new` writes work as they do by default.
Three things differ from what a `Gemfile` leads you to expect:

- **Name one release.** Of the releases that satisfy a constraint, spin
  selects the lowest, not the newest: `"~> X.Y"` is the lowest release in
  the index from X.Y up to the next major version (only `"~> X.Y.Z"` stays
  inside X.Y), and stays that one when later ones are published. So write the exact
  version, the one `cybertrain version` prints; `new` prints a note when V
  is anything else.
- **Spinel still comes from the `cybertrain` command.** An index entry names
  no Spinel release. The framework is written for and tested with one, the
  release that `cybertrain setup` builds, and the `cybertrain` command of
  the same version installs it. Plain `spin add cybertrain` in a project
  built with another Spinel is untested.
- **spin reads its own copy of the index.** It clones the index once, into
  `~/.cache/spin/`, and `spin lock` does not update that copy;
  `spin search cybertrain` does, and prints the newest release.

### Moving an app to a new release

The gem and the framework are released from the same tag, so their versions
match: the X.Y.Z gem writes apps that depend on framework `vX.Y.Z`. To move an
app to a new release, update the gem, point `spin.toml` at the new tag, then
run, in the app:

```shell terminal — the app's directory
rm spin.lock
cybertrain spin lock
cybertrain spin run gen
```

`spin lock` keeps the commit it has locked for a git dependency, whatever
`ref` has become in `spin.toml`, which is why the lock is removed first. In
an app with other dependencies you can delete only the `[lock.cybertrain]`
table and the `[lock.spinel-http]` table (the HTTP layer the framework
depends on) from `spin.lock` instead, and keep the other pins.

An app that depends on [an index version](#an-index-version) needs no `rm`,
since there `spin lock` moves the pin: run `cybertrain spin search
cybertrain` first, which updates spin's copy of the index, then change the
version on the `cybertrain =` line of `spin.toml` to the new release and run `cybertrain spin lock` and `cybertrain spin run gen`.

The command checks that the two match. Before `server`, `build`, `db`,
`test` or `generate` runs spin or writes a file, it compares the version of
the framework spin would build, the one locked in the app's `spin.lock`,
with its own (`cybertrain version`): the command, not the app, decides which
Spinel release compiles the app, and its templates and generators are
written for its own release of the framework. When the versions differ, the
command stops with exit status 1:

```text output — cybertrain build
error: this application's framework is cybertrain X.Y.Z (spin.lock), but this cybertrain command is A.B.C.
The command decides the Spinel release, the templates and the generators, so the two must be the same version. Either
  gem install cybertrain -v X.Y.Z    # the command the application is on
or point the cybertrain dependency in spin.toml at A.B.C (ref = "vA.B.C"), then relock from nothing (spin lock keeps a locked git commit)
  rm -f spin.lock && cybertrain spin lock
```

Do one or the other. `cybertrain spin ...` is never checked, so `cybertrain
spin lock` always runs. With a version from the index, the message names
`cybertrain = "A.B.C"` and
`cybertrain spin lock` alone; spin builds the locked release only while
`spin.toml` still allows it, so the version `spin.toml` names is compared
as soon as it differs from the lock, and a range (`"~> X.Y"`) that no longer
allows the locked release is refused until `cybertrain spin lock` has run.
An app that depends on a checkout of the framework (`path = ...`) is not
checked. An app with no `spin.lock` is checked against the release its
`spin.toml` names (`"X.Y.Z"` or `ref = "vX.Y.Z"`); a branch, a commit or a
range names none, so it is not checked.

Relocking is one step of an upgrade. [Upgrading](upgrading.md) has the
whole procedure, and what each release changes for an application.
