# The playground image

`ghcr.io/saeki-mototsune/cybertrain-playground` is cybertrain ready to try
without installing anything: Ubuntu 24.04 with the `cybertrain` CLI and
Spinel built from this repository, a mirror of the framework so that
`cybertrain new` needs no network, and the tutorial's blog in
`/workspace/blog`, created, scaffolded, migrated and built once.
[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) opens
it in GitHub Codespaces (the README's
["Try it in the browser"](../README.md#try-it-in-the-browser)); a hosted
playground that runs the same image is planned.

- Tags: `latest` is the latest tested build of `main`; `X.Y.Z` comes from the
  release tag `vX.Y.Z`, which also moves `latest`; a manual run of the
  workflow pushes the tag it is given.
- Platform: `linux/amd64` only. On an arm64 machine, build it yourself
  (below).
- Files: [Dockerfile](Dockerfile) and
  [Dockerfile.dockerignore](Dockerfile.dockerignore) (its build context),
  [playground-server](playground-server) and [profile.sh](profile.sh) (the
  scripts), [routes.rb](routes.rb) and [PLAYGROUND.md](PLAYGROUND.md) (copied
  into the blog) and [smoke.sh](smoke.sh) (the smoke test).

## Run it

```sh
docker run --rm -it --init -p 3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
```

Then open http://localhost:3000. The default command, `playground-server`,
runs the blog's development server in the foreground; Ctrl-C stops it. For a
shell instead:

```sh
docker run --rm -it ghcr.io/saeki-mototsune/cybertrain-playground bash
```

- `--init` puts a small init process at PID 1 that passes Ctrl-C and
  `docker stop` on and reaps processes: the server runs as `cybertrain
  server` → `spin run blog` → the app's binary.
- `CYBERTRAIN_HOST=0.0.0.0` makes the server listen on every interface,
  which `-p` needs. The server listens on 127.0.0.1 by default and the image
  leaves it so: GitHub Codespaces forwards 127.0.0.1, and nothing else needs
  to reach the server there.

## Build it

From a regular clone of this repository (not a git worktree), at its root:

```sh
docker build -f playground/Dockerfile --target playground -t cybertrain-playground .
```

- Always name the target: a later stage will add a browser editor after
  `playground`.
- The build context is the repository root and must contain the `.git`
  directory: the framework mirror is made from it through a bind mount, so
  `.git` never lands in a layer. In a git worktree `.git` is a file, and the
  build stops with "the build context needs this repository's .git
  directory".
- The mirror holds the checkout's HEAD commit, so the blog builds against
  the committed framework, while the CLI is built from the working tree:
  commit framework changes before building.
- It builds on arm64 too: the image is for the architecture of the machine
  that builds it.
- The build needs the network: Ubuntu's package mirrors, github.com (Spinel's
  source) and rubygems.org (Spinel's `make deps` downloads the prism and rbs
  gems). The `cybertrain` gem itself is built from this checkout's
  `cybertrain.gemspec`, not downloaded.
- A clean build took 156 s on 10 CPUs (Apple M5, linux/arm64), 41.5 s of it
  building Spinel.

Then run the smoke test: `bash playground/smoke.sh cybertrain-playground`
(below).

## What is inside

| What | Where |
| --- | --- |
| User | `dev`, uid/gid 1000, home `/home/dev`; nothing the blog needs to start or rebuild lives in the home directory |
| Spinel | `CYBERTRAIN_HOME=/opt/cybertrain` (its `bin/` first on `PATH`), owned by dev |
| spin's cache | `XDG_CACHE_HOME=/opt/cybertrain-cache`, owned by dev; `cybertrain new` and rebuilds write it |
| Framework mirror | `/opt/cybertrain-mirror/cybertrain.git`, owned by dev, with two `insteadOf` rules in `/etc/gitconfig` |
| The blog | `/workspace/blog`, owned by dev: a git repository with one commit, already built |
| Start script | `/usr/local/bin/playground-server [APP_DIR]` |
| Profile | `/etc/profile.d/cybertrain-playground.sh`, also read by interactive shells through `/etc/bash.bashrc` |
| Port | 3000, on 127.0.0.1 unless `CYBERTRAIN_HOST` says otherwise |
| Written at run time outside the app | `/tmp` (spin's temporary files) and `/opt/cybertrain-cache`; inside the app, `tmp/`, `storage/`, `build/` and `gen/` |

Stages: `cli-src` (internal: exactly the files `cybertrain.gemspec`
packages, so that a change to the framework alone keeps the gem and Spinel
layers cached), `toolchain` (packages, the user, the CLI gem, Spinel, the
mirror) and `playground` (the scripts and the blog).

The blog is the tutorial after steps 02, 03, 04 and 07 (`cybertrain new
blog`, the article scaffold, the root route, `cybertrain db migrate`) plus
one full build: `gen/` is current and `build/bin/{gen,db,blog}` exist, so
the first `cybertrain server` compiles nothing. spin decides what is fresh
by file times, so copy the blog only with `cp -a` (or `tar`), which keep
them.

Not baked in: `tmp/secret_key` (each container makes its own on first start,
so no two visitors share a key), `CYBERTRAIN_HOST` and the Codespaces
variables (set at run time), the VS Code server (Codespaces installs it),
seed data, `sudo` and editor extensions.

The mirror is this checkout's HEAD as a one-commit bare repository with the
tag `v<VERSION>` forced onto it. A new app's `spin.toml` points at
`https://github.com/saeki-mototsune/cybertrain`, tag `v<VERSION>`, and the
`insteadOf` rules send that URL, with or without `.git`, to the mirror, so
`cybertrain new` works with no network. Every clone of a URL that starts
with `https://github.com/saeki-mototsune/cybertrain` is sent to the mirror,
so cloning another repository whose name starts that way fails; to reach
GitHub itself:

```sh
GIT_CONFIG_NOSYSTEM=1 git clone https://github.com/saeki-mototsune/cybertrain
```

## The scripts

**`playground-server [APP_DIR]`** starts `cybertrain server` for APP_DIR
(default `/workspace/blog`) in the foreground of the terminal it runs in.

- It is safe to run again. A second run finds the first one's lock
  (`/tmp/playground-server-3000.lock`, held by the server until it exits)
  and says "the dev server is already running"; a server started some other
  way, such as `cybertrain server` by hand, is found by connecting to the
  port, or, while it is still compiling and does not listen yet, by its
  process (any `cybertrain server` of the same user, whatever its port). In
  each case it prints the app's URL and exits 0 without starting anything.
  Codespaces runs it on every attach.
- The banner shows the app's URL (in a codespace the forwarded
  `https://<codespace>-3000.app.github.dev/`, elsewhere
  `http://localhost:3000/`), where the guide is, and how long edits take.
- When VS Code's `code` command works in its terminal, it opens
  `PLAYGROUND.md` once per container (the marker is
  `tmp/.playground-guide-opened`, which git ignores); otherwise the banner is
  the only pointer.
- `PORT` changes the port, as it does for `cybertrain server`.

**`/etc/profile.d/cybertrain-playground.sh`** (from `profile.sh`) puts
`/opt/cybertrain/bin` on `PATH` and sets `CYBERTRAIN_HOME` and
`XDG_CACHE_HOME` for every shell, login or not. In a codespace
(`CODESPACES=true`) it also defaults `CYBERTRAIN_SESSION_SAME_SITE=None` and
`CYBERTRAIN_SESSION_PARTITIONED=1`. The editor's preview shows the app in an
iframe inside a webview on another site (`vscode-cdn.net`), where a
`SameSite=Lax` session cookie is neither stored nor sent, so every form POST
would fail the CSRF check with 403; `SameSite=None; Secure` works there, and
`Partitioned` keeps it working in browsers that block third-party cookies.
These are the framework's own variables (the README's "Configuration and
environment variables"); the framework does not look at `CODESPACES`
itself. A value already set wins, which allows a control run:
`CYBERTRAIN_SESSION_SAME_SITE=Lax CYBERTRAIN_SESSION_PARTITIONED=0 playground-server`.

## Codespaces

[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) is the
repository's default dev container configuration:

- `image`: `ghcr.io/saeki-mototsune/cybertrain-playground:latest`, the latest build of `main` that passed the smoke test.
- `remoteUser`: `dev`.
- `workspaceFolder`: `/workspace/blog`, the prebuilt blog, outside the clone of this repository under `/workspaces`.
- `postCreateCommand`: empty, so no setup step runs.
- `postAttachCommand`: `playground-server`, on every attach (it is safe to run again).
- `forwardPorts` and `portsAttributes`: port 3000, labelled `cybertrain`, opened in the editor's preview (`onAutoForward: openPreview`) when the server starts listening.
- `files.autoSave: off`: the development server rebuilds the app on every save of a Ruby file, and delayed auto-save would start a minute-long rebuild at every pause in typing.
- No `hostRequirements`: the default 2-core machine, which costs the visitor the least quota.

The link is `https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1`
(the default branch; `https://codespaces.new/saeki-mototsune/CyberTrain/tree/<branch>?quickstart=1`
for another branch). `quickstart=1` resumes the visitor's codespace if there
is one, or offers a single "Create codespace" button, and always opens VS
Code in the browser.

- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab. Inside the preview, pop-ups and `confirm()` dialogs do not work.
- "Rebuild Container" starts again from the image: edits under `/workspace/blog` are lost, since only `/workspaces` survives a rebuild.
- A codespace's storage counts against the visitor's quota until it is deleted at https://github.com/codespaces.

## Smoke test

```sh
bash playground/smoke.sh IMAGE
```

It needs bash 3.2 or newer, docker and curl. It prints one PASS or FAIL line
per check, then `smoke: N passed, M failed`, and exits 0 only when every
check passes; CI runs it on every build before pushing. Most of its time
goes to three compiles of up to a minute each: the model edit (A9), the
server started by hand (D4) and the offline app (B3).

| ID | Checks |
| --- | --- |
| G1-G7 | The image as built: user `dev` (uid 1000); `cybertrain version`; `cybertrain doctor`; `CYBERTRAIN_HOME` and `XDG_CACHE_HOME` set, `CYBERTRAIN_HOST` not; the blog's `spin.toml` points at `v<VERSION>`; the blog is a clean one-commit git repository that tracks `PLAYGROUND.md`; no `tmp/secret_key`, an executable `build/bin/blog` |
| A1-A10 | The default command with `CYBERTRAIN_HOST=0.0.0.0`, reached from the host: `GET /articles`; the boot banner; nothing compiled at start; `GET /` shows `<h1>Articles</h1>`; a CSRF token and a `SameSite=Lax` cookie; creating an article (303, then its page); 403 without a token; a view edit shows on the next request; a model edit rebuilds and restarts the server (a short body then answers 422); `tmp/secret_key` generated |
| D1-D4 | `playground-server` again: it exits 0 saying "already running"; one server process; after a container restart (idle stop and resume) the server is back with the data; a server started by hand is left alone, while it is still compiling and once it listens |
| C1-C3 | `CODESPACES=true`: the cookie is `SameSite=None; Secure; Partitioned`; the banner shows the forwarded URL; interactive and login shells get the cookie settings |
| F1 | `CYBERTRAIN_SESSION_SAME_SITE=lax` stops the server at boot, naming the valid values |
| E1 | A `cp -a` copy of the blog starts without compiling |
| B1-B3 | No network: the repository URL reaches the mirror; `cybertrain new` in `/workspace` locks the blog's commit; the new app builds |

## CI and publishing

[.github/workflows/playground-image.yml](../.github/workflows/playground-image.yml)
("Playground image") runs on pull requests and pushes to `main` that touch
`playground/`, `.devcontainer/`, `cybertrain/`, `cybertrain.gemspec`,
`spin.toml`, `exe/` or the workflow itself, on every `v*` tag (GitHub does
not apply path filters to tags), and by hand. It checks that
`devcontainer.json` parses, builds the `playground` target for `linux/amd64`
with the GitHub Actions cache (a change to the framework alone rebuilds only
the mirror and the blog), runs the smoke test and then, except on pull
requests, pushes the image it tested: `latest` from `main`, `X.Y.Z` and
`latest` from a tag `vX.Y.Z`, and the given tag from a manual run (Actions →
Playground image → Run workflow, on `main`).

## Owner's one-time steps

1. After the first push, open the package `cybertrain-playground` (the
   Packages tab of github.com/saeki-mototsune) and make sure its visibility
   is **Public** (Package settings → Change visibility) and that it is
   connected to the repository (Connect repository). Codespaces cannot pull
   a private image for anyone else.
2. Optional: Codespaces prebuilds (repository Settings → Codespaces → Set up
   prebuild; branch `main`, configuration `.devcontainer/devcontainer.json`,
   as few regions as will do). The owner pays for the prebuild's storage and
   Actions minutes.

## Limitations

- `linux/amd64` only; on arm64, build the image from a checkout.
- No live reload: reload the page after a change.
- A Ruby edit is a full rebuild (about a minute); a view edit needs none.
- The blog's `spin.lock` pins the commit the image was built from, which for
  an image built from `main` can differ from the commit GitHub's
  `v<VERSION>` tag points at.
- Inside the image, clones of any URL that starts with
  `https://github.com/saeki-mototsune/cybertrain` go to the mirror (above).
