# The playground image

`ghcr.io/saeki-mototsune/cybertrain-playground` is cybertrain ready to try
without installing anything: Ubuntu 24.04 with the `cybertrain` CLI built
from this repository and Spinel `2026.09.12` built from source, a mirror of
the framework so that `cybertrain new` needs no network, and the tutorial's
blog in `/workspace/blog`, created, scaffolded, migrated and built once.
[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) opens
it in GitHub Codespaces (the README's
["Try it in the browser"](../README.md#try-it-in-the-browser)). The hosted
playground, where a session needs no account, runs the same image with a
browser editor added ([below](#the-hosted-playground)); its address goes
here once it is public.

- Tags: `latest` is the latest tested build of `main`; `X.Y.Z` comes from the
  release tag `vX.Y.Z`, which also moves `latest`; a manual run of the
  workflow pushes the tag it is given.
- Platform: `linux/amd64` only. On an arm64 machine, build it yourself
  (below).
- Files: [Dockerfile](Dockerfile) and
  [Dockerfile.dockerignore](Dockerfile.dockerignore) (its build context),
  [playground-server](playground-server) and [profile.sh](profile.sh) (the
  scripts), [routes.rb](routes.rb) and [PLAYGROUND.md](PLAYGROUND.md) (copied
  into the blog) and [smoke.sh](smoke.sh) (the smoke test). The hosted
  playground adds [web/](web/) and [web-smoke.sh](web-smoke.sh) (the session
  image's files and smoke test), [router/](router/), [control/](control/),
  [dev/](dev/) (the local stack and its end-to-end test) and
  [deploy/](deploy/) (Kamal, the host and the operator's guide).

## Run it

```sh
docker run --rm -it --init -p 127.0.0.1:3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
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
  which `-p` needs; `-p` publishes it on the host's loopback interface only,
  because it is a development server. The server listens on 127.0.0.1 by
  default and the image leaves it so: GitHub Codespaces forwards 127.0.0.1,
  and nothing else needs to reach the server there.

## Build it

From a regular clone of this repository (not a git worktree), at its root:

```sh
docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local .
```

- Always name the target: the `web` stage after `playground` adds the
  hosted playground's browser editor (below).
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
- The build needs the network: Docker Hub (the `ubuntu:24.04` base image and
  the `docker/dockerfile:1` syntax image), Ubuntu's package mirrors,
  github.com (Spinel's source) and rubygems.org (Spinel's `make deps`
  downloads the prism and rbs gems). The `cybertrain` gem itself is built
  from this checkout's `cybertrain.gemspec`, not downloaded.
- A clean build took 156 s on 10 CPUs (Apple M5, linux/arm64), 41.5 s of it
  building Spinel.

Then run the smoke test: `bash playground/smoke.sh cybertrain-playground:local`
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
mirror), `playground` (the scripts and the blog) and `web` (the hosted
playground's session image, built on `playground`; see "The web stage"
below).

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
`cybertrain new` works with no network. git replaces that prefix with the
mirror's path: the framework's URL gets the mirror, and another repository
whose name starts that way (`…/cybertrain-foo` becomes
`…/cybertrain.git-foo`) cannot be cloned; to reach GitHub itself:

```sh
GIT_CONFIG_NOSYSTEM=1 git clone https://github.com/saeki-mototsune/cybertrain
```

## The web stage (hosted playground)

```sh
docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
```

builds the hosted playground's session image,
`ghcr.io/saeki-mototsune/cybertrain-playground-web`: the `playground` stage,
unchanged, plus what follows.

| What | Where |
| --- | --- |
| code-server 4.139.1 | `/usr/lib/code-server`, from the GitHub release with its SHA-256 checked; `/usr/local/bin/code-server` |
| The entrypoint | `/usr/local/bin/playground-web` ([web/playground-web](web/playground-web)): fills the empty tmpfs mounts from the seed, installs the user settings, schedules the end-of-session notices and runs code-server until the session's end |
| User settings | `/opt/cybertrain-web/settings.json` ([web/settings.json](web/settings.json)), copied into the session's home: no Welcome tab, chat or trust prompt; automatic tasks on; port 3000 opens in the editor's preview; `window.restoreWindows` is `preserve`, because the editor URL opens the guide on every load and VS Code then restores no other editor: without it a reload loses the preview |
| The server's task | `/workspace/blog/.vscode/tasks.json` ([web/tasks.json](web/tasks.json)), hidden from git through `.git/info/exclude`: runs `playground-server` in a terminal when the folder opens |
| The guide | `/workspace/blog/PLAYGROUND.md` from [web/PLAYGROUND.md](web/PLAYGROUND.md), folded into the blog's one commit. The editor URL opens it as text, on purpose: the preview then opens beside it, in a group of its own that code-server locks, so a file opened from the Explorer goes to the guide's side; rendered (through an editor association), the guide had the preview opened on top of it |
| The seed | `/opt/cybertrain-web/seed/{workspace,cybertrain-cache}`, copied with `cp -a` (file times kept, so nothing rebuilds) |
| Environment | `CYBERTRAIN_HOST=0.0.0.0` (the router reaches port 3000 at the session's address) and `EXTENSIONS_GALLERY={}` (no extension marketplace) |
| `WORKDIR` | `/workspace`, the tmpfs mount point itself: a directory below it would be created by runc on the empty tmpfs, root-owned, and hide the seed |

The layout and the reload are code-server 4.139.1's behaviour: after an
upgrade, check both by hand ([deploy/README.md](deploy/README.md), 6-4).

The image expects the control plane's `docker run`
([control/lib/play/templates.rb](control/lib/play/templates.rb)): `--init`;
`--user 1000:1000`; `--read-only` with tmpfs mounts on `/tmp`, `/home/dev`,
`/workspace` and `/opt/cybertrain-cache`; `VSCODE_PROXY_URI`
(`https://{{port}}-<preview id>.<domain>`, where the preview opens; without
it the preview points at the visitor's own machine); optionally
`PLAYGROUND_ENDS_AT` (the end, in seconds since the epoch: notices 5 minutes
and 1 minute before it, and the container stops itself 60 seconds after it)
and `PLAYGROUND_IDLE_TIMEOUT` (default 300, more than 60); one network that
the router shares.

By hand, without the rest of the service:

```sh
docker run --rm -it --init -p 127.0.0.1:8080:8080 -p 127.0.0.1:3000:3000 \
  -e 'VSCODE_PROXY_URI=http://localhost:{{port}}' cybertrain-playground-web:local
```

Then open http://localhost:8080/?folder=/workspace/blog. There is no time
limit, but code-server's idle timeout ends the container a few minutes
after the last tab closes.

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
  `https://<codespace>-3000.app.github.dev/`, in the hosted playground the
  preview's address from code-server's `VSCODE_PROXY_URI`, elsewhere
  `http://localhost:3000/`), where the guide is, when the session ends (in
  the hosted playground, from `PLAYGROUND_ENDS_AT`) and how long edits take.
- When VS Code's `code` command works in its terminal, it opens
  `PLAYGROUND.md` once per container (the marker is
  `tmp/.playground-guide-opened`, which git ignores); otherwise the banner is
  the only pointer.
- `PORT` changes the port, as it does for `cybertrain server`. While another
  `cybertrain server` of the same user runs, whatever its port, the script
  starts nothing: beside the running blog, `PORT=4000 playground-server`
  only says that a server is already starting.

**`/etc/profile.d/cybertrain-playground.sh`** (from `profile.sh`) puts
`/opt/cybertrain/bin` on `PATH` and sets `CYBERTRAIN_HOME` and
`XDG_CACHE_HOME` for login shells and interactive bash (the image's
environment already sets the three for every process). In a codespace
(`CODESPACES=true`) it also defaults `CYBERTRAIN_SESSION_SAME_SITE=None` and
`CYBERTRAIN_SESSION_PARTITIONED=1`. The editor's preview shows the app in an
iframe inside a webview on another site (`vscode-cdn.net`), where a
`SameSite=Lax` session cookie is neither stored nor sent, so every form POST
would fail the CSRF check with 403; `SameSite=None; Secure` works there, and
`Partitioned` keeps it working in browsers that block third-party cookies.
These are the framework's own variables (the README's "Configuration and
environment variables"); the framework does not look at `CODESPACES`
itself. A value already set wins, which allows a control run, once the
server is stopped (Ctrl-C in its terminal):
`CYBERTRAIN_SESSION_SAME_SITE=Lax CYBERTRAIN_SESSION_PARTITIONED=0 playground-server`.

## Codespaces

[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) is the
repository's default dev container configuration:

- `image`: `ghcr.io/saeki-mototsune/cybertrain-playground:latest`, the latest build of `main` that passed the smoke test.
- `remoteUser`: `dev`.
- `workspaceFolder`: `/workspace/blog`, the prebuilt blog, outside the clone of this repository under `/workspaces`.
- `postCreateCommand`: empty, so no setup step runs.
- `postAttachCommand`: `playground-server`, on every attach (it is safe to run again). When the codespace first opens, VS Code asks whether the visitor trusts the authors of the files in this folder; the `server` terminal starts only after "Trust Folder & Continue".
- `forwardPorts` and `portsAttributes`: port 3000, labelled `cybertrain`, opened in a new browser tab (`onAutoForward: openBrowserOnce`) when the server starts listening. The editor's preview (`openPreview`) did not load the private forwarded port (live check L4; see below). `openBrowserOnce` opens the tab only the first time the port is forwarded in a session, so the server's restart after a rebuild opens no second tab. The cookie settings stay: they work in the tab, and in a preview the visitor opens by hand.
- `files.autoSave: off`: the development server rebuilds the app on every save of a Ruby file, and delayed auto-save would start a minute-long rebuild at every pause in typing.
- No `hostRequirements`: the default 2-core machine, which costs the visitor the least quota.

The link is `https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1`
(the default branch; `https://codespaces.new/saeki-mototsune/CyberTrain/tree/<branch>?quickstart=1`
for another branch). `quickstart=1` resumes the visitor's codespace if there
is one, or offers a single "Create codespace" button, and always opens VS
Code in the browser.

- The app opens in a new browser tab. Port 3000 is a private forwarded port, and its first visit signs in through github.com, which refuses to be shown in a frame: in a new Chrome profile the editor's preview showed only "github.com refused to connect." (live check L4). If the app's tab did not open (a pop-up blocker), use the Ports view's "Open in Browser" on port 3000.
- The editor's preview needs that sign-in first: once the app's tab has opened, the Ports view's "Preview in Editor" on port 3000 shows the app inside VS Code too (reload a preview that showed the error). After every restart of the codespace the port signs in again, so the preview again needs the app's tab first. Inside the preview, pop-ups and `confirm()` dialogs do not work.
- "Rebuild Container" starts again from the image: edits under `/workspace/blog` are lost, since only `/workspaces` survives a rebuild.
- A codespace's storage counts against the visitor's quota until it is deleted at https://github.com/codespaces.

## The hosted playground

A visitor presses "Start a session" and, a few seconds later, VS Code
(code-server) opens in the browser on the blog, with its development server
running in a terminal and the app in the editor's preview: no account, a
limited time (30 minutes by default), no network inside, one session per
network address. Three parts, all in this directory:

| Part | What | Runs as |
| --- | --- | --- |
| [router/](router/) | Stock Caddy with a static [Caddyfile](router/Caddyfile) and three error pages: sends each host name to its session's container through a Docker network alias, and nothing to an ended one; on the entry host it refuses a request body over 4 KB | Kamal service `cybertrain-play-router`, port 80 behind kamal-proxy |
| [control/](control/) | Ruby, Sinatra and Puma: the entry page, `POST /sessions`, the limits, the reaper and the stop switch `bin/playctl`. The only process with the Docker socket; every `docker` command line it runs is in [templates.rb](control/lib/play/templates.rb) | Kamal service `cybertrain-play`, no proxy |
| The `web` image | One container per session: read-only, no capabilities, on its own `--internal` network that only the router joins | Started and removed by the control plane |

Host names: the entry page at `<DOMAIN>`, an editor at
`<session id>.<DOMAIN>` and its app at `3000-<preview id>.<DOMAIN>`, two
separate 128-bit random numbers: whoever has the app's address has the app,
whoever has the editor's address has the session, terminal included. Logs
name a session only by its handle (the first 16 hex digits of the SHA-256 of
its id), never by an id or a network address.

Deployment and operation (Kamal, Cloudflare, the host's firewall, the stop
switch, abuse): [deploy/README.md](deploy/README.md), in Japanese.

### On this machine

```sh
docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
bash playground/web-smoke.sh cybertrain-playground-web:local         # the image (W1-W13)
docker compose -f playground/dev/compose.yml up --build -d
# Chrome or Firefox: http://play.localhost:8080/ -> Start a session
docker compose -f playground/dev/compose.yml exec control bin/playctl status
docker compose -f playground/dev/compose.yml exec control bin/playctl kill-all
docker compose -f playground/dev/compose.yml exec control bin/playctl resume
docker compose -f playground/dev/compose.yml down
bash playground/dev/e2e.sh                                            # the whole stack (E1-E19, below)
(cd playground/control && bundle install && bundle exec rake test)    # the control plane's unit tests
```

- Browsers resolve `*.localhost` to this machine and treat `play.localhost`
  as the registrable domain, so an editor and its preview are one site, as
  in production.
- A browser sends no `CF-Connecting-IP`, so locally everyone is one client:
  one session at a time. The end-to-end test sets the header.
- `playctl kill-all` also pauses the playground, and the pause is a file in
  `playground/dev/data/` that outlives `down`: `playctl resume` accepts new
  sessions again.
- Sessions are not part of the compose project: `playctl kill-all` removes
  them, and so does their own end (the container stops itself 60 seconds
  after it, and the next control plane removes the network). With no
  control plane running, remove them by hand:

  ```sh
  docker ps -aq --filter label=cybertrain-play.role=session | xargs -r docker rm -f
  for n in $(docker network ls -q --filter label=cybertrain-play.role=session); do
    for c in $(docker network inspect -f '{{range $id, $x := .Containers}}{{$id}} {{end}}' "$n"); do
      docker network disconnect -f "$n" "$c"; done
    docker network rm "$n"
  done
  ```

- The end-to-end test refuses to start (exit 2) while any session exists or
  another control plane of this stack runs on the same Docker (the dev
  stack, say; it names that container): stop it and remove the sessions
  first.
- If `10.250.0.0/16` clashes with a VPN, set `PLAY_SUBNET_POOL` (both
  services read it).

### The end-to-end test

`bash playground/dev/e2e.sh` tests the whole stack on this machine's
Docker: the router and the control plane built from this checkout
(`dev/compose.yml` as a project of its own, `ctplay-e2e`, on port 18080,
with a 180 s TTL and two sessions at most) and real sessions of
`PLAY_SESSION_IMAGE` (default `cybertrain-playground-web:local`). It needs
bash 3.2 or newer, docker with compose v2, curl and `sha256sum` or
`shasum`; it prints one line per check, then `e2e: N passed, M failed`, and
exits 0 only when every check passes (2 when it cannot start). It took
198 s on the Apple M5, plus its first build of the router and control-plane
images.

| ID | Checks |
| --- | --- |
| E1-E7 | The entry page says 2 of 2 sessions are free and `status.json` says `"live":0`; `POST /sessions` answers 303 to the editor within 30 s; the editor answers with the workbench and its headers (`Referrer-Policy`, `X-Robots-Tag`, `frame-ancestors 'self'`); its WebSocket handshake is 101 from its own origin and 403 from another; the preview answers with `no-store`, `noindex` and `frame-ancestors *.play.localhost:*`, and the banner names it; a form on the preview host gets a `SameSite=Lax` cookie without `Secure` and a 303 to the new article; `3000-<session id>` is the 502 page and `<preview id>` alone the 404 page |
| E8 | From a session, once the probe has been refused by the router's address on the session's network (the router listens only on its address on the compose network): no internet, no DNS (`example.com`, `ctplay-control`), no metadata service, no host address (docker0's ports, a listener on the host) and no other session, where a refused connection counts as a way out; the session's own request to the router is refused too (curl exit 7); no host interface has an address in the pool |
| E9 | Inside a session: uid 1000, no capabilities, no new privileges, read-only root, writable `/workspace`, 1536 MiB, 512 pids, 1 CPU, no Docker socket, no IPv6 address but loopback's |
| E10 | A second client gets a session, a third the 503 "full" page with `Retry-After: 60`; Docker holds exactly 2 sessions |
| E11 | The same client gets 429; a session just ended with `playctl end` answers the 404 page within 5 s, and a live session the router was cut from within 3 s (the check that fails without the Caddyfile's `keepalive off`); every `playctl end` succeeds; the third creation in the window gets the 429 rate page |
| E12 | Another origin and a same-site request get 403; `Origin: null` from the entry page passes the origin check (and meets the per-client 429); a small request body gets the control plane's 413 ("No request body is accepted."), 1 MiB with a declared length 413, 1 MiB chunked the router's "Request body too large" |
| E13 | Unknown hosts get the 404 page, `/internal/sessions` through the router the router's own 404 page; the router asks no outside resolver (`--dns 127.0.0.1`) and forwards nothing (`ip_forward` 0) |
| E14-E15 | `docker restart` of the control plane succeeds and `status.json` counts the live session again within 10 s, its editor answering; a re-created router (a new container) reaches it within 10 s |
| E16-E17 | `playctl pause` shows on the entry page and refuses with 503, `resume` accepts, `kill-all` leaves no session and no network; with the router stopped, a creation after a successful `resume` gets 503 "It is starting up" and leaves nothing |
| E18 | A session ends at its TTL: its `expires-at` label is 180 s after `created-at`, its editor is the 404 page between 5 s before and 15 s after `expires-at`, and no labelled container or network is left |
| E19 | The control plane's log holds exactly five creations and none of their ten ids, no client address and no other 32-hex token |

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

`bash playground/web-smoke.sh IMAGE` tests the `web` stage the same way
(bash 3.2 or newer and docker; 80 s on the Apple M5 above: the two checks
that wait for a session's end and for code-server's idle timeout run
alongside the others, which include two compiles). Its session runs with the
control plane's flags on an `--internal` network of its own, where a helper
container of the same image plays the router. The flags between
`# BEGIN hardened run` and `# END hardened run` must equal
`Play::Templates.hardening` (`control/test/drift_test.rb` checks).
`RUNTIME=runsc` adds `--runtime runsc`.

| ID | Checks |
| --- | --- |
| W1-W4 | The image as built: code-server's version; user `dev`, the CLI's version, `CYBERTRAIN_HOST=0.0.0.0` and `EXTENSIONS_GALLERY={}`; the blog is clean with one commit, the hosted guide and a git-ignored folderOpen task; the seed equals the originals |
| W5-W7 | A session started as the control plane starts it: `/healthz` answers another container; `/workspace/blog` is the seeded copy, dev's, writable, with the prebuilt binary's mtime; the user settings are installed |
| W8-W10 | `playground-server` serves port 3000 to the network and its banner shows the preview URL and the end; a model edit rebuilds on the read-only root (a short body then answers 422); with no network, `cybertrain new` and a build work in `/workspace` |
| W11 | Read-only root, no capabilities, no new privileges, the four tmpfs sizes |
| W12-W13 | A session stops and disappears by itself 60 seconds after `PLAYGROUND_ENDS_AT`, and at code-server's idle timeout when no browser ever came |

## CI and publishing

[.github/workflows/playground-image.yml](../.github/workflows/playground-image.yml)
("Playground image") runs on pull requests and pushes to `main` that touch
`playground/`, `.devcontainer/`, `cybertrain/`, `cybertrain.rb`,
`cybertrain.gemspec`, `spin.toml`, `exe/` or the workflow itself, on every
`v*` tag (GitHub does not apply path filters to tags), and by hand. It
checks that `devcontainer.json` is valid JSON and, on a tag, that the tag is
`v` + `Cybertrain::VERSION` (any other `v*` tag fails the run before the
build), builds the `playground` target for `linux/amd64` with the GitHub
Actions cache (a change to the framework alone rebuilds only the mirror and
the blog), runs the smoke test and then, except on pull requests, pushes the
image it tested: `latest` from `main`, `X.Y.Z` and `latest` from a tag
`vX.Y.Z`, and the given tag from a manual run (Actions → Playground image →
Run workflow, on `main`).

The same workflow's `web` job starts once the `image` job has passed (the
`web` stage is built on the `playground` stage): it builds the `web` target
for `linux/amd64`, runs `web-smoke.sh` and the end-to-end test
(`dev/e2e.sh`: the router and the control plane built from this checkout,
with real sessions), and pushes
`ghcr.io/saeki-mototsune/cybertrain-playground-web` by the same rules. A
manual run pushes its tag to both images; the hosted playground's next
deploy pins whatever `cybertrain-playground-web:latest` is then, so a
`latest` pushed by hand, from any branch, becomes its session image.
[.github/workflows/playground-control.yml](../.github/workflows/playground-control.yml)
runs the control plane's unit tests when `playground/control/` or
`web-smoke.sh` changes, and
[.github/workflows/playground-uptime.yml](../.github/workflows/playground-uptime.yml)
fetches `<PLAYGROUND_URL>/status.json` every 30 minutes once the repository
variable `PLAYGROUND_URL` is set.

## Owner's one-time steps

1. Once the workflow has pushed the image for the first time, open the
   package `cybertrain-playground` (the Packages tab of
   github.com/saeki-mototsune) and make sure its visibility is **Public**
   (Package settings → Change visibility) and that it is connected to the
   repository (Connect repository). Codespaces cannot pull a private image
   for anyone else.
2. Optional: Codespaces prebuilds (repository Settings → Codespaces → Set up
   prebuild; branch `main`, configuration `.devcontainer/devcontainer.json`,
   as few regions as will do). The owner pays for the prebuild's storage and
   Actions minutes.
3. Once the `web` job has pushed `cybertrain-playground-web` for the first
   time, do the same for that package (Public, connected to the
   repository). The hosted playground's own setup is in
   [deploy/README.md](deploy/README.md).

## Limitations

- `linux/amd64` only; on arm64, build the image from a checkout.
- No live reload: reload the page after a change.
- A Ruby edit is a full rebuild (about a minute); a view edit needs none.
- In a codespace the editor's preview cannot sign in to the private forwarded
  port by itself. The app opens in a browser tab, and the preview shows the
  app only once that tab has signed in; after every restart of the
  codespace, the tab has to sign in again first.
- The blog's `spin.lock` pins the commit the image was built from, which for
  an image built from `main` can differ from the commit GitHub's
  `v<VERSION>` tag points at.
- Inside the image, the two `insteadOf` rules apply to every git command for
  URLs that start with `https://github.com/saeki-mototsune/cybertrain` (lower
  case, the form `cybertrain new` writes), for fetches and for pushes alike:
  that URL clones the one-commit mirror and a `git push` to it goes to the
  mirror, not to GitHub, while other repositories whose URL starts that way
  cannot be cloned (above).
- The two guides, [PLAYGROUND.md](PLAYGROUND.md) (Codespaces and Docker) and
  [web/PLAYGROUND.md](web/PLAYGROUND.md) (the hosted playground), share
  their "Try this" and "Start a fresh app" sections word for word: change
  one, change the other.
- In the hosted playground the server runs as a task in a terminal: closing
  that terminal with its trash icon leaves the server running without one
  (the dev loop treats SIGHUP as a restart), as in Codespaces.
- A hosted session has no network: `gem install`, `curl` to the internet
  and `git push` fail there, and only port 3000 can be previewed.
- In the hosted playground, reload the editor with the browser's reload
  button: F5 inside the editor is VS Code's Start Debugging. After using the
  preview, the browser's Back button first steps back through the preview's
  pages; to leave, close the tab.
