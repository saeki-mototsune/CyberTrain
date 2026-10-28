# Installing cybertrain

## Try it in the browser

[Open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
to try cybertrain without installing anything: VS Code opens in your browser with
Spinel 2026.10.27.7020, the `cybertrain` CLI and the blog from the walkthrough below
already created (`cybertrain new blog`, the article scaffold, the root route and
the first migration, built once so the server starts without compiling), its
development server running in a terminal and the app, showing the article list,
in a new browser tab. The app is a git repository with one commit, so Source
Control shows what you change. `PLAYGROUND.md` in the app lists what to try, from
editing a view to carrying on with the walkthrough's comments. A view edit shows
on the next reload; a Ruby edit is a full rebuild, about a minute, after which the
server restarts by itself; the app's tab does not reload by itself. `cybertrain new`
works there with no network.

- A GitHub account is required, and the codespace runs on your own Codespaces
  quota: GitHub's free plan includes 120 core-hours and 15 GB-month of storage a
  month, about 60 hours on the default 2-core machine the playground uses. GitHub
  stops an idle codespace after 30 minutes by default; its storage counts until
  you delete it.
- If VS Code asks whether you trust the authors of the files in this folder,
  choose "Trust Folder & Continue": the server's terminal starts only then.
- If the app's tab did not open (a pop-up blocker, or the codespace was stopped
  and restarted), click "Open in Browser" in VS Code's notification for port
  3000 or in the Ports view, or Ctrl-click the app's URL in the `server`
  terminal. `PLAYGROUND.md` shows where each is.
- The same image runs locally (it is published for linux/amd64; on arm64, build
  it from a checkout):

  ```sh
  docker run --rm -it --init -p 127.0.0.1:3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  Then open http://localhost:3000. [playground/README.md](../../playground/README.md)
  describes the image, building it and the Codespaces setup.

## Requirements

- Spinel `2026.10.27.7020` (`Cybertrain::SPINEL_TAG`, the same release as
  `SPINEL_TAG` in [.github/workflows/ci.yml](../../.github/workflows/ci.yml)), a
  release of [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)
  (`Cybertrain::SPINEL_REPOSITORY`), the fork of matz/spinel that carries
  the fixes cybertrain needs ahead of an upstream release;
  untested against other versions. You do not install it by hand: the
  `cybertrain` command builds that release into `~/.cybertrain` the first
  time it needs it (`cybertrain setup` does that on request), unless a
  `spinel` of that release is already on `PATH` — see [Installing the CLI](#installing-the-cli).
- To build it: a C toolchain (`cc`, or the compiler `CC` names) and `make`
  — Spinel compiles every program to C — plus `git` and `curl`.
- SQLite 3 headers/library (`libsqlite3-dev` on Debian/Ubuntu; present with
  Xcode's command line tools on macOS) — models use Spinel's FFI directly,
  not a gem.
- zlib headers/library (`zlib1g-dev` on Debian/Ubuntu; in the macOS SDK) —
  gzip request bodies (`request.decoded_body`) are inflated through the
  system zlib, bound the same way.
- Ruby 3.2+ and RubyGems, for the `cybertrain` command only (applications
  never run on CRuby). Building Spinel also needs Ruby's `prism` gem, which
  Ruby 3.3 and newer bundle; on Ruby 3.2, `gem install prism` (with Ruby's
  development headers, `ruby-dev` on Debian/Ubuntu). `cybertrain doctor`
  checks it.
- OpenSSL's headers (`libssl-dev`) are optional: without them Spinel builds
  without its `openssl` package, which cybertrain does not use. On macOS an
  application that requires `openssl` needs Homebrew's (keg-only) OpenSSL on
  the compiler's paths: `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- jemalloc's development package (`libjemalloc-dev`; `brew install jemalloc`)
  is optional: an app needs it only once its `spin.toml` says
  `allocator = "jemalloc"`, which `cybertrain new` writes commented out. It
  is worth turning on for production: 1.1 to 1.4 times the requests per second on
  examples/blog ([docs/benchmark.md](../benchmark.md)).

`cybertrain doctor` checks these tools and headers and the Spinel install;
when a required one is missing it also prints the install command for your
platform.

The framework has no separate test runner; it tests itself. `spin` comes
with Spinel, and `cybertrain spin` runs the copy `cybertrain` installs
without touching `PATH` (or put that copy on `PATH` with the `export
PATH=...` line `cybertrain setup` prints, and call `spin` directly):

```sh
cybertrain spin test
```

compiles and runs every program under `test/` and diffs its output against a
committed `test/<name>.rb.expected` snapshot — minitest/RSpec can't run under
Spinel, since they find test methods by reflection and an ahead-of-time
compiler has nothing to reflect on at run time. `cybertrain spin test
--regen test/<name>.rb` rewrites a snapshot from CRuby's output; a few tests that
touch SQLite through FFI take theirs from the compiled binary instead
([spikes/NOTES.md](../../spikes/NOTES.md), rule 23); `script/regen-snapshot
test/<name>.rb` does that build-then-capture step for you and prints the diff stat.

## Installing the CLI

```sh
gem install cybertrain
cybertrain new blog    # also installs Spinel, the first time (a few minutes)
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000
cybertrain build       # production: dist/
```

The `cybertrain` command is plain Ruby and the gem runs it under CRuby
(3.2 or newer); neither the framework nor Spinel is in the gem. Its
commands (`cybertrain help` prints them):

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` creates an application in NAME, then runs `spin lock` and
  `spin run gen` in it, installing Spinel first when it is needed.
- `cybertrain generate scaffold NAME field:type ...` (alias `g scaffold`)
  adds a resource to the application in the current directory.
- `cybertrain generate authentication` adds email-and-password sign-in to
  it: users and sessions tables, `User` and `Session` models, the sign-in
  and sign-up controllers and views, the routes, a `before_action` in
  `ApplicationController` and a test (see [Add authentication](tutorial.md#authentication)).
  With `--invite-only` there is no sign-up page: users are created with
  `./NAME user EMAIL`, and the first one also at a `/setup` page that
  answers only to the server's own machine, with the one-time token its
  boot warning prints, while no user exists.
- `cybertrain generate attachment MODEL FIELD [--any]` adds a file upload
  to a scaffolded model: five metadata columns, model methods and
  callbacks, a download action, the route, the form field and a test (see
  [Add a file upload](tutorial.md#attachments)). A scaffold field `cover:attachment` does the same.
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

Every command that runs `spin` (`new`, `db`, `server`, `build`, `spin`) first makes
sure a Spinel of the release in `Cybertrain::SPINEL_TAG` is available. A
`spinel` on `PATH` (with a `spin`) whose `spinel --version` reports that
release is used as it is; otherwise the copy `cybertrain` keeps under
`~/.cybertrain/spinel/2026.10.27.7020/` is used; otherwise `cybertrain`
builds that copy from the release tag of `Cybertrain::SPINEL_REPOSITORY`
(`git clone`, `make deps`, `make -j`, `make install PREFIX=...`), once, in a
few minutes. The build log is
`~/.cybertrain/log/spinel-2026.10.27.7020-build.log` (its last lines are printed
if a step fails); if a tool the build needs is missing, `cybertrain` says
which and prints the install command for your platform before it starts. A
`spinel` of another release on `PATH` is never used or touched:
`cybertrain` keeps its own copy (and says so when it installs it).

`cybertrain setup` does the same on request and, whenever its own copy is
the one in use, prints the line that puts it on `PATH`, for running `spin`
yourself (`~/.cybertrain/bin` holds `spinel` and `spin` links to the release
in use, so the line survives a release bump; `cybertrain spin ...` needs no
`PATH` at all):

```sh
export PATH="$HOME/.cybertrain/bin:$PATH"
```

Two environment variables override all this: `CYBERTRAIN_HOME` replaces
`~/.cybertrain` (a path without spaces, quotes, `$` or `:`, which Spinel's
Makefile and `PATH` cannot take), and `CYBERTRAIN_SPINEL_HOME=PREFIX` forces
an existing install — `cybertrain` then uses the `spinel` and `spin` in `PREFIX/bin` (or
in `PREFIX` itself, if `spinel` is directly in it) and stops with an error
if they are not that release.

`cybertrain new` writes the application with its `spin.toml` pointing at
the release matching the CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }`), makes
sure Spinel is installed, then runs `spin lock` (spin fetches the framework
into its cache, `~/.cache/spin/packages/`, and pins the commit in
`spin.lock`) and `spin run gen`, much as `rails new` runs `bundle install`,
and prints the next steps. Nothing of the framework is copied into the app;
commit `spin.toml` and `spin.lock`. If Spinel or one of the two `spin`
steps fails, the files stay, `new` exits with 1 and prints what to run once
the cause is fixed (for Spinel: `cybertrain setup`, then `cybertrain spin
lock && cybertrain spin run gen` in the new directory).

`--skip-spin` only writes the files: no Spinel install, no `spin lock`, no
`spin run gen`. `--path DIR` depends on a local checkout instead,
`--git URL [--ref R]` on the framework at URL (at branch or tag R), and
`--version V` on an index version once cybertrain is on a `spin-index`.
Give only one of `--path`, `--version` and `--git`; `--ref` needs `--git`.

Working on cybertrain itself, run the CLI from the checkout (`spin install`
builds `bin/cybertrain.rb` into `~/.local/bin/cybertrain`; `ruby -I.
bin/cybertrain.rb` also works) and create apps against it with `cybertrain
new NAME --path ~/src/cybertrain` (wherever the checkout is).
