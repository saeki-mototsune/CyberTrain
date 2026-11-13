# The playground image

`ghcr.io/saeki-mototsune/cybertrain-playground` is cybertrain ready to try
without installing anything: Ubuntu 24.04 with the `cybertrain` CLI built
from this repository and the Spinel release `Cybertrain::SPINEL_TAG` names built from source, a mirror of
the framework so that `cybertrain new` needs no network, and the tutorial's
blog in `/workspace/blog`, created, scaffolded, migrated and built once.
[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) opens
it in GitHub Codespaces ([the playground page](https://saeki-mototsune.github.io/CyberTrain/playground.html)
says what to expect there).

- Tags: `X.Y.Z` comes from the release tag `vX.Y.Z` once every release
  check has passed on it, and `latest` is the latest such release; a manual run of the
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
  server`, the supervisor that holds the port, with one child serving it
  (the blog under CRuby, `ruby … bin/blog.rb 3000`, or its compiled binary,
  `build/bin/blog 3000`) and, after a Ruby change, a `spin build blog` in
  the background.
- `CYBERTRAIN_HOST=0.0.0.0` makes the server listen on every interface,
  which `-p` needs; `-p` publishes it on the host's loopback interface only,
  because it is a development server. The server listens on 127.0.0.1 by
  default and the image leaves it so: GitHub Codespaces forwards 127.0.0.1,
  and nothing else needs to reach the server there.

Development requests must also use a trusted Host: `localhost`, `127.0.0.1`
or `[::1]` by default, with an optional numeric port. Binding to `0.0.0.0`
does not allow additional hostnames. For another forwarding hostname, set
`CYBERTRAIN_ALLOWED_HOSTS=preview.example.com` (comma-separated for more),
or add it to `c.allowed_hosts` in `config/app.rb`. Names match exactly;
wildcards are not supported. Rejected hosts receive 403 before application
data, static files, session cookies or development diagnostics are served.

## Build it

From a regular clone of this repository (not a git worktree), at its root:

```sh
docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local .
```

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
  building Spinel, before the CRuby preview. With it, built from commit
  c04bb23 and this directory as it is now, a clean build took 10 min 26 s on
  4 CPUs (linux/amd64, 2026-11-13): 204 s building Spinel, 93 s `cybertrain
  db migrate`, 24 s gen, 108 s the incremental build that fills spinel's
  object cache, 112 s the release build and 0.7 s the shim's libraries.

Then run the smoke test: `bash playground/smoke.sh cybertrain-playground:local`
(below).

## What is inside

| What | Where |
| --- | --- |
| User | `dev`, uid/gid 1000, home `/home/dev`; nothing the blog needs to start or rebuild lives in the home directory |
| Spinel | `CYBERTRAIN_HOME=/opt/cybertrain` (its `bin/` first on `PATH`), owned by dev |
| spin's cache | `XDG_CACHE_HOME=/opt/cybertrain-cache`, owned by dev: the framework's package (`spin/`) and spinel's object cache for incremental builds (`spinel/`, filled by the image's build of the blog); `cybertrain new` and rebuilds write it |
| Framework mirror | `/opt/cybertrain-mirror/cybertrain.git`, owned by dev, with two `insteadOf` rules in `/etc/gitconfig` |
| The blog | `/workspace/blog`, owned by dev: a git repository with one commit, already built |
| Start script | `/usr/local/bin/playground-server [APP_DIR]` |
| Profile | `/etc/profile.d/cybertrain-playground.sh`, also read by interactive shells through `/etc/bash.bashrc` |
| Port | 3000, on 127.0.0.1 unless `CYBERTRAIN_HOST` says otherwise |
| Written at run time outside the app | `/tmp` (spin's temporary files) and `/opt/cybertrain-cache`; inside the app, `tmp/` (the supervisor's files in `tmp/cybertrain-dev/`), `storage/`, `build/` and `gen/` |

Stages: `cli-src` (internal: exactly the files `cybertrain.gemspec`
packages, so that a change to the framework alone keeps the gem and Spinel
layers cached), `toolchain` (packages, the user, the CLI gem, Spinel, the
mirror) and `playground` (the scripts and the blog).

The blog is the tutorial after steps 02, 03, 04 and 07 (`cybertrain new
blog`, the article scaffold, the root route, `cybertrain db migrate`) plus
its build: `gen/` is current and `build/bin/{gen,db,blog}` exist, and the
CRuby preview's FFI shim has compiled the framework's C into
`tmp/cybertrain-dev/ffi/` (`Cybertrain::Preview.warm!`), as `dev`, the user
every container runs as: the shim loads nothing from a cache that another
user owns or that its group or others may write to (decision P26 of the
preview's plan), and the build checks that a second `warm!` compiles
nothing.

- `build/bin/blog` is the release build of a plain `spin build blog`.
  `spin build blog -- --incremental` runs before it only to fill spinel's
  object cache, and its binary is removed: it is built from units of 256K
  at the same `-O2` and flags, about 7% more code (the same speed in a quick
  test of `GET /articles`), and the release build comes last so that its
  binary is the newest file.
- The first `cybertrain server` runs no C compiler. It runs gen under CRuby
  (`bin/gen.rb`, which rewrites only files whose text changed), then picks
  its startup build by file times: the binary is newer than every Ruby file
  of the blog and of the framework (a tie would count as stale), so it runs
  a plain `spin build blog`, which says `build blog (up to date)` in a
  fraction of a second, and the binary takes the port over within a second
  or so of the start. A stale binary would get `spin build blog --
  --incremental`, which compiles every time. The image build checks both
  rules in its last step.
- A CRuby child, which serves after an edit, finds the shim's libraries
  cached and compiles nothing either.
- Both spin and the supervisor decide what is fresh by file times, so copy
  the blog only with `cp -a` (or `tar`), which keep them.

Not baked in: `tmp/secret_key` (each container makes its own on first start,
so no two visitors share a key), `CYBERTRAIN_HOST` (set at run time), the
VS Code server (Codespaces installs it), seed data, `sudo` and editor
extensions.

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

## The scripts

**`playground-server [APP_DIR]`** starts `cybertrain server` for APP_DIR
(default `/workspace/blog`) in the foreground of the terminal it runs in.

- It is safe to run again. A second run finds the first one's lock
  (`/tmp/playground-server-3000.lock`, held by the server until it exits)
  and says "the dev server is already running"; a server started some other
  way, such as `cybertrain server` by hand, is found by connecting to the
  port, or, in the second or two before it listens (while it asks spin for
  the load path and the app for its address), by its process (any
  `cybertrain server` of the same user, whatever its port). In each case it
  prints the app's URL and exits 0 without starting anything. (Two
  `cybertrain server` in the same app cannot run anyway: the second stops
  with "a cybertrain server is already running here".)
  Codespaces runs it on every attach.
- A supervisor killed outright (SIGKILL, the OOM killer) leaves its child
  serving on the port. When the port answers but
  `tmp/cybertrain-dev/child.pid` names a live process working in the app
  and `tmp/cybertrain-dev/supervisor.pid` names none, the script says so and
  starts `cybertrain server`, which stops that leftover child and takes the
  port over.
- The banner shows the app's URL (in a codespace the forwarded
  `https://<codespace>-3000.app.github.dev/`, elsewhere
  `http://localhost:3000/`), where the guide is, and what an edit does (a
  Ruby change shows at once from CRuby; the compiled binary takes over when
  its build finishes, and the corner of the page says which one served it).
- In Codespaces, the launcher adds that exact forwarded hostname to
  `CYBERTRAIN_ALLOWED_HOSTS`, preserving any explicitly configured names.
- When VS Code's `code` command works in its terminal, it opens
  `PLAYGROUND.md` once per container (the marker is
  `tmp/.playground-guide-opened`, which git ignores); otherwise the banner is
  the only pointer.
- When `code` works, it also opens the app's URL in a browser tab (`code
  --openExternal`) as soon as the port answers, on every start (so after a
  codespace restart too), and the banner says where to open the app if no
  tab opened. The opener runs in the background, waits at most 300 s, gives
  up when the server exits and does not hold the lock. The supervisor holds
  the port while it hands it from CRuby to the compiled binary and does not
  run the script again, so an edit opens no second tab.
- `PORT` changes the port, as it does for `cybertrain server`. While another
  `cybertrain server` of the same user runs, whatever its port, the script
  starts nothing: beside the running blog, `PORT=4000 playground-server`
  only says that a server is already starting.

**`/etc/profile.d/cybertrain-playground.sh`** (from `profile.sh`) puts
`/opt/cybertrain/bin` on `PATH` and sets `CYBERTRAIN_HOME` and
`XDG_CACHE_HOME` for login shells and interactive bash (the image's
environment already sets the three for every process).

## Codespaces

[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) is the
repository's default dev container configuration:

- `image`: `ghcr.io/saeki-mototsune/cybertrain-playground:latest`, the image of the newest release (it passed the smoke test before it was pushed).
- `remoteUser`: `dev`.
- `workspaceFolder`: `/workspace/blog`, the prebuilt blog, outside the clone of this repository under `/workspaces`.
- `postCreateCommand`: empty, so no setup step runs.
- `postAttachCommand`: `playground-server`, on every attach (it is safe to run again). When the codespace first opens, VS Code asks whether the visitor trusts the authors of the files in this folder; the `server` terminal starts only after "Trust Folder & Continue".
- `forwardPorts` and `portsAttributes`: port 3000, labelled `cybertrain`, with `onAutoForward: notify`: when the server starts listening, VS Code shows "Your application (cybertrain) running on port 3000 is available." with an "Open in Browser" button. `playground-server` opens the browser tab itself (above). A tab that VS Code opens without a click (`openBrowser`, `openBrowserOnce`, or `code --openExternal`) can be stopped by a pop-up blocker, and in Chrome VS Code then shows nothing (it offers "Retry" only in Safari); allowing pop-ups afterwards does not open it. The notification's button is a click, so it gets through, and `onAutoForward` takes only one action, so the tab comes from the script and the button from `notify`. The editor's preview (`openPreview`) did not load the private forwarded port (see below).
- `files.autoSave: off`: every save of a Ruby file still starts a Spinel build (a minute or two, cancelling the one before) and restarts the CRuby preview, even though the page no longer waits for the build; delayed auto-save would do both at every pause in typing, often on a half-typed file that does not load, so the page would show the error page more often than the change.
- `workbench.editorAssociations`: `PLAYGROUND.md` opens as a Markdown preview (`vscode.markdown.preview.editor`), the guide's reading view; "Reopen Editor With... → Text Editor" shows its source.
- No `hostRequirements`: the default 2-core machine, which costs the visitor the least quota.

The link is `https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1`
(the default branch; `https://codespaces.new/saeki-mototsune/CyberTrain/tree/<branch>?quickstart=1`
for another branch). `quickstart=1` resumes the visitor's codespace if there
is one, or offers a "Create new codespace" button (and "Change options"), and always opens VS
Code in the browser.

- The app opens in a new browser tab, and the guide treats that tab as the only way to see the app. Port 3000 is a private forwarded port, and its first visit signs in through github.com, which refuses to be shown in a frame: in a new Chrome profile the editor's preview showed only "github.com refused to connect." (the live check of 2026-10-06/07). If the app's tab did not open (a pop-up blocker, or the codespace was stopped and restarted, when VS Code treats the port as already forwarded and may show no notification), `PLAYGROUND.md`'s "If the app's tab did not open" lists the notification's "Open in Browser", the Ports view's "Open in Browser" on port 3000 and the URL in the `server` terminal.
- The editor's preview needs that sign-in first: once the app's tab has opened, the Ports view's "Preview in Editor" on port 3000 shows the app inside VS Code too (reload a preview that showed the error), but after every restart of the codespace the port signs in again, and inside the preview pop-ups and `confirm()` dialogs do not work, so the guide does not mention it.
- "Rebuild Container" starts again from the image: edits under `/workspace/blog` are lost, since only `/workspaces` survives a rebuild.
- A codespace's storage counts against the visitor's quota until it is deleted at https://github.com/codespaces.
- Measured on the default 2-core machine (the same live check): the editor shows about 20 s after "Create new codespace" and the blog's files after about a minute; the server listens a few seconds after "Trust Folder & Continue"; a Ruby edit was rebuilt and the server restarted about 100 s after the save (the compiled loop, before the CRuby preview: with it the edit answers at once and the binary follows after its build); a stopped codespace starts the server again about 40 s after "Restart codespace", with the data kept.

## Smoke test

```sh
bash playground/smoke.sh IMAGE
```

It needs bash 3.2 or newer, docker and curl. It prints one PASS or FAIL line
per check, then `smoke: N passed, M failed`, and exits 0 only when every
check passes; CI runs it on every build before pushing. A3's and A9's PASS
lines also say what they timed. Most of its time goes to two compiles: the
binary after the model edit (A9) and the offline app (B3, not timed on its
own). A3, A11 and E1 wait for the startup build to end, which finds the
binary up to date: the binary serves a fraction of a second after the start.
Measured on 4 CPUs (linux/amd64, 2026-11-13), twice, on the image built from
commit c04bb23 and this directory: 33 passed in 3 min 23 s and in 2 min 48 s;
A3, the binary served 0.2 s after the start of the supervisor's first round
(its own `=> spinel: ready in` figure, which counts from after `spin flags`,
the address probe and the bind, not from `docker run`); A9, CRuby answered
1 s after the save and the binary 56 s after it (whole seconds, polled every
3 s once CRuby has answered; spinel's object cache is warm).

| ID | Checks |
| --- | --- |
| G1-G8 | The image as built: user `dev` (uid 1000); `cybertrain version`; `cybertrain doctor`; `CYBERTRAIN_HOME` and `XDG_CACHE_HOME` set, `CYBERTRAIN_HOST` not; the blog's `spin.toml` points at `v<VERSION>`; the blog is a clean one-commit git repository that tracks `PLAYGROUND.md`; no `tmp/secret_key`, an executable `build/bin/blog`; `cybertrain doctor`'s `fiddle` line is ok (the CRuby preview needs it) |
| A1-A12 | The default command with `CYBERTRAIN_HOST=0.0.0.0`, reached from the host: `GET /articles`; the boot banner; nothing compiled at start (`build/bin/blog` keeps the image's mtime once the startup build has ended); `GET /` shows `<h1>Articles</h1>`; a CSRF token and a `SameSite=Lax` cookie; creating an article (303, then its page); 403 without a token; a view edit shows on the next request; a model edit answers 422 for a short body from `X-Cybertrain-Runtime: cruby` within 10 s, then from `spinel`; `tmp/secret_key` generated; A11, no C compiler at the first start (no `cc1`, `collect2` or `ld` in any form, and no `cc` or `gcc` but `--version` probes and lines whose command line could not be read, from the container's start until the startup build has ended, polled by a loop the container's command line starts before `playground-server`, and `build/bin/gen` and the shim's `tmp/cybertrain-dev/ffi/*.so` keep the image's mtimes); A12, the CRuby child that serves the model edit, the first to use the shim, inserts and lists articles and the shim's libraries are still the image's |
| D1-D5 | `playground-server` again: it exits 0 saying "already running"; one supervisor and one child; after a container restart (idle stop and resume) the server is back, once, with the data; a server started by hand is left alone, before it listens (held there by a `spin` that waits) and once it listens; D5, once a server started by hand has had its supervisor SIGKILLed, the script takes the port over from the child it left: a new supervisor stops that child and serves, one supervisor and one child |
| C1-C4 | `CODESPACES=true`: the cookie keeps the default, `SameSite=Lax` without `Secure` or `Partitioned`; the banner shows the forwarded URL; interactive and login shells started with `PATH=/usr/bin:/bin` find `spin` in `/opt/cybertrain/bin`; with a stand-in for VS Code's `code` on `PATH`, `playground-server` opens `PLAYGROUND.md` and then the forwarded URL with `--openExternal` |
| F1 | `CYBERTRAIN_SESSION_SAME_SITE=lax` stops the app at boot, under CRuby and as the compiled binary, which the supervisor tries as soon as the startup build finds it up to date: the log names the valid values and says the binary failed, and the server answers 503 with a page that names them for both (the supervisor outlives its children, so the container does not exit) |
| E1 | A `cp -a` copy of the blog starts without compiling (its binary and the shim's libraries keep the image's mtimes once the startup build has ended) |
| B1-B3 | No network: the repository URL reaches the mirror; `cybertrain new` in `/workspace` locks the blog's commit; the new app builds |

## CI and publishing

[.github/workflows/playground-image.yml](../.github/workflows/playground-image.yml)
("Playground image") runs on pull requests that touch `playground/` (except
this README), `.devcontainer/`, the workflow itself, or what the image's
toolchain is built from (the CLI's files, `cybertrain.gemspec`,
`cybertrain/version.rb` and `spin.toml`: the build runs `cybertrain setup`
and `cybertrain doctor`), without pushing; a change to the rest of the
framework alone does not run it. Pushes to `main` do not run it. It
also runs from the Release workflow
([.github/workflows/release.yml](../.github/workflows/release.yml)), which
calls it for a tag `vX.Y.Z` after the Gate, CI and the blog image have
passed on the tag, and by hand. It
checks that `devcontainer.json` is valid JSON and, for a release tag, that
the tag is `v` + `Cybertrain::VERSION`, builds the `playground` target for `linux/amd64` with the GitHub
Actions cache (a change to the framework alone rebuilds only the mirror and
the blog), runs the smoke test and then pushes the image it tested:
`X.Y.Z` for a release tag `vX.Y.Z`, and the given tag from a
manual run (Actions → Playground image →
Run workflow, on `main`). It never pushes `latest`, and a manual run with
that tag is refused: the Release workflow's `promote-latest` job points
`latest` at the newest release's image, after the release is created.

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

## Limitations

- `linux/amd64` only; on arm64, build the image from a checkout.
- No live reload: reload the page after a change (the line in its corner
  updates itself; the page does not).
- A Ruby edit is served by CRuby at once, which is not the compiled program:
  what differs under Spinel shows once the binary takes over, after an
  incremental build. A view edit needs neither. Measured on the same image
  (2026-11-13) by saving the model edit A9 makes in a running blog: CRuby
  answered 0.6 s after the save and the binary 74 s after it on 4 CPUs, and
  0.7 s and 74 s under `docker run --cpus 2` (most of that build is
  single-threaded). The smoke's A9 timed the same edit's binary at 56 s on
  the same machine, in a separate run. A9 polls every 3 s and can only be
  late, so its 56 s means 53 to 56 s: the same incremental build took 74 s
  in one run and 53 to 56 s in the other. None of these was measured in a
  codespace: the 2-CPU figures are `docker run --cpus 2` on the development
  machine, and a codespace's cores can be slower (the compiled loop's full
  rebuild took 99 s on the default 2-core codespace), so the texts for
  visitors say "a minute or two". A new app's first `cybertrain server`
  serves from CRuby at once, and its binary took over after 112 s on 4 CPUs
  and 153 s with `docker run --cpus 2`; the texts for visitors say "a few
  minutes".
- In a codespace the editor's preview cannot sign in to the private forwarded
  port by itself. The app opens in a browser tab, and the preview shows the
  app only once that tab has signed in; after every restart of the
  codespace, the tab has to sign in again first.
- In a codespace the server runs in the `server` terminal; stop it with
  Ctrl-C. Closing that terminal with its trash icon stops it too (the
  supervisor treats SIGHUP as a stop); run `playground-server` in a new
  terminal to start it again. Stopping and restarting the codespace also
  brings the server back in a new terminal.
- The blog's `spin.lock` pins the commit the image was built from, which for
  an image built from `main` can differ from the commit GitHub's
  `v<VERSION>` tag points at.
- Inside the image, the two `insteadOf` rules apply to every git command for
  URLs that start with `https://github.com/saeki-mototsune/cybertrain` (lower
  case, the form `cybertrain new` writes), for fetches and for pushes alike:
  that URL clones the one-commit mirror and a `git push` to it goes to the
  mirror, not to GitHub, while other repositories whose URL starts that way
  cannot be cloned (above).
