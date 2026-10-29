# Installing

What CyberTrain needs on your machine, how to install the `cybertrain`
command, every command it has, and how it installs Spinel and the framework
for you.

> [!NOTE]
> To try CyberTrain without installing anything, open [the playground](site:playground.html):
> GitHub Codespaces opens the tutorial's blog, the `cybertrain` command and
> Spinel `2026.10.27.7020` in VS Code in your browser. The same image also runs locally under Docker.

## Requirements

- Spinel `2026.10.27.7020` (`Cybertrain::SPINEL_TAG`, the same release as
  `SPINEL_TAG` in [.github/workflows/ci.yml](../../.github/workflows/ci.yml)), a
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
- Ruby 3.2+ and RubyGems, for the `cybertrain` command only (applications
  never run on CRuby); on Ruby 3.2, building Spinel also needs the `prism`
  gem (below).

`cybertrain doctor` checks these tools and headers and the Spinel install;
when a required one is missing it also prints the install command for your
platform.

<details><summary>More packages — prism on Ruby 3.2; OpenSSL and jemalloc, both optional</summary>

- Building Spinel needs Ruby's `prism` gem, which Ruby 3.3 and newer bundle;
  on Ruby 3.2, `gem install prism` (with Ruby's development headers,
  `ruby-dev` on Debian/Ubuntu). `cybertrain doctor` checks it.
- OpenSSL's headers (`libssl-dev`) are optional: without them Spinel builds
  without its `openssl` package, which CyberTrain does not use. On macOS an
  application that requires `openssl` needs Homebrew's (keg-only) OpenSSL on
  the compiler's paths: `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- jemalloc's development package (`libjemalloc-dev`; `brew install jemalloc`)
  is optional: an app needs it only once its `spin.toml` says
  `allocator = "jemalloc"`, which `cybertrain new` writes commented out. It
  is worth turning on for production: 1.1 to 1.4 times the requests per second on
  examples/blog ([docs/benchmark.md](../benchmark.md)).

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
  `spin run gen` in it, installing Spinel first when it is needed.
- `cybertrain generate scaffold NAME field:type ...` (alias `g scaffold`)
  adds a resource to the application in the current directory.
- `cybertrain generate authentication` adds email-and-password sign-in to
  it: users and sessions tables, `User` and `Session` models, the sign-in
  and sign-up controllers and views, the routes, a `before_action` in
  `ApplicationController` and a test (see [Add sign-in](tutorial.md#authentication)).
  With `--invite-only` there is no sign-up page: users are created with
  `./NAME user EMAIL`, and the first one also at a `/setup` page that
  answers only to the server's own machine, with the one-time token its
  boot warning prints, while no user exists.
- `cybertrain generate attachment MODEL FIELD [--any]` adds a file upload
  to a scaffolded model: five metadata columns, model methods and
  callbacks, a download action, the route, the form field and a test (see
  [Add a cover image](tutorial.md#attachments)). A scaffold field `cover:attachment` does the same.
- `cybertrain db migrate` generates, applies pending migrations, and
  generates again (`spin run gen; spin run db -- migrate; spin run gen`);
  `cybertrain migration` is kept as an alias.
- `cybertrain db COMMAND...` runs any other database command after `spin
  run gen`: `status`, `rollback [N]` (which generates again afterwards),
  `schema:dump`, `create`.
- `cybertrain server [PORT]` generates, then starts the development server
  (`spin run gen; spin run NAME`, or `spin run NAME -- PORT`; default port
  3000).
- `cybertrain build` builds NAME with `app/views/` embedded and assembles
  `dist/` (the binary, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` runs `spin` with the pinned Spinel from any
  directory (`cybertrain spin test`, `cybertrain spin run gen -- --check`).
- `cybertrain setup [--force]` installs Spinel `2026.10.27.7020` into
  `~/.cybertrain` unless a `spinel` of that release is already on `PATH`;
  `--force` rebuilds the copy under `~/.cybertrain`.
- `cybertrain doctor` checks the C toolchain, the SQLite headers and the
  Spinel install.
- `cybertrain version` prints the version.

`db`, `server` and `build` run inside an application; NAME is the
`[package] name` in its `spin.toml`.

## How Spinel is installed

Every command that runs `spin` (`new`, `db`, `server`, `build`, `spin`) first
makes sure a Spinel of the release in `Cybertrain::SPINEL_TAG` is available. A
`spinel` on `PATH` (with a `spin`) whose `spinel --version` reports that
release is used as it is; otherwise the copy `cybertrain` keeps under
`~/.cybertrain/spinel/2026.10.27.7020/`; otherwise `cybertrain` builds that
copy from the release tag of `Cybertrain::SPINEL_REPOSITORY` (`git clone`,
`make deps`, `make -j`, `make install PREFIX=...`), once, in a few minutes,
logging to `~/.cybertrain/log/spinel-2026.10.27.7020-build.log` (its last
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

</details>

## The gem and the framework

`gem install cybertrain` installs a command, not the framework. The gem is
the `cybertrain` command, plain Ruby that runs on your machine under CRuby
(3.2 or newer) and calls Spinel's `spin` tool for you; neither the framework
nor Spinel is in the gem. The framework is a Spinel package your app depends
on in its `spin.toml`: Spinel compiles it together with your code ahead of
time, so it never runs on CRuby, and it is the part that ships. The binary in
`dist/` runs without Ruby, the gem or Spinel.

### What `cybertrain new` writes

`cybertrain new` writes the application with its `spin.toml` pointing at
the release matching the CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }`), makes
sure Spinel is installed, then runs `spin lock` (spin fetches the framework
into its cache, `~/.cache/spin/packages/`, and pins the commit in
`spin.lock`) and `spin run gen`, much as `rails new` runs `bundle install`,
and prints the next steps. Nothing of the framework is copied into the app;
commit `spin.toml` and `spin.lock`.

If Spinel or one of the two `spin` steps fails, the files stay, `new` exits
with 1 and prints what to run once the cause is fixed (for Spinel:
`cybertrain setup`, then `cybertrain spin lock && cybertrain spin run gen` in
the new directory).

Four options change what it writes and runs:

- `--skip-spin` only writes the files: no Spinel install, no `spin lock`, no
  `spin run gen`.
- `--path DIR` depends on a local checkout instead
  (`--path ~/src/cybertrain`, wherever the checkout is, when working on
  CyberTrain itself).
- `--git URL [--ref R]` depends on the framework at URL (at branch or tag R).
- `--version V` depends on an index version once the framework is on a
  `spin-index`.

Give only one of `--path`, `--version` and `--git`; `--ref` needs `--git`.

### Moving an app to a new release

The gem and the framework are released from the same tag, so their versions
match: the 0.3.1 gem writes apps that depend on framework `v0.3.1`. To move an
app to a new release, update the gem, point `spin.toml` at the new tag, then
run, in the app:

```shell terminal — the app's directory
cybertrain spin lock
cybertrain spin run gen
```
