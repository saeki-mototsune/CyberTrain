# Deploying with Kamal

Part 8 of the deployment tutorial, [deploy.en.md](deploy.en.md) (in
Japanese: part 8 of [deploy.md](deploy.md), "Kamal でデプロイする"). It
stands on its own: you do not need the other parts to follow it.

The names used below; replace them with yours:

| Item | Value in this document |
| --- | --- |
| App name (what you passed to `cybertrain new`: lowercase letters, digits and `_`) | `notes` |
| Domain | `notes.example.com` |
| Server | Ubuntu (or another Linux with SSH), x86-64 or arm64 |

Instead of building on the server and running the app under systemd and
Caddy (parts 3 to 6 of [deploy.en.md](deploy.en.md)), you can ship it as a Docker
image with [Kamal 2](https://kamal-deploy.org). `cybertrain new` writes these
files:

| File | What it holds |
| --- | --- |
| `Dockerfile` | A two-stage build. The first stage (Ubuntu 24.04) runs `gem install cybertrain`, `cybertrain setup` (Spinel) and `cybertrain build`; the second (the same Ubuntu) gets only `dist/` and the libraries it needs at run time (SQLite, zlib, jemalloc, OpenSSL). On start it runs `./notes migrate`, then `exec`s `./notes` |
| `.dockerignore` | Keeps `build/`, `dist/`, the databases in `storage/`, `tmp/`, `.git/` and `.kamal/` out of the build |
| `config/deploy.yml` | Kamal's configuration. kamal-proxy takes HTTPS (Let's Encrypt) and forwards to the app's port 3000, and health-checks `/up.html`. The database lives on the volume `notes_storage` (`/app/storage` in the container), and `asset_path: /app/public/assets` carries the previous release's digested assets over |
| `.kamal/secrets` | Reads `KAMAL_REGISTRY_PASSWORD` and `CYBERTRAIN_SECRET_KEY_BASE` from the environment of the shell that runs kamal. It never holds the values themselves (the file is committed) |
| `public/up.html` | The health check page, served by the app itself as a static file |

[examples/blog](../examples/blog#deploying-with-kamal) has the same setup
(it uses this repository's framework, so its `Dockerfile` runs the CLI from
the checkout instead of installing the gem, and the build context is the
repository root).

The binary is compiled inside Docker, so the image takes care of "build on
the same OS as the machine that runs it". The CPU still has to match
(`builder.arch`, below).

## 8-1. What you need

- On your machine: Docker and Kamal (`gem install kamal`).
- A server you can SSH into as root (or as a user with sudo), Ubuntu or
  similar. `kamal setup` installs Docker on it. Open ports 80 and 443.
- DNS: an A (and AAAA) record pointing `notes.example.com` at the server.
- Somewhere to push the image: a Docker Hub or GitHub Container Registry
  (ghcr.io) account and a token that can push.
- The framework reference: `cybertrain =` in `spin.toml` must be a git tag
  (what `cybertrain new` writes by default) or a version. An app created
  with `--path` cannot be built, since that path is not visible inside the
  image.

## 8-2. Edit `config/deploy.yml`

Replace the values marked `CHANGE ME` with yours.

```yaml
service: notes
image: YOUR_DOCKERHUB_USER/notes      # YOUR_GITHUB/notes for ghcr.io

servers:
  web:
    hosts:
      - 203.0.113.10                  # the server's IP address or host name
  worker:
    hosts:
      - 203.0.113.10
    cmd: ./notes worker
    options:
      restart: unless-stopped

proxy:
  ssl: true
  host: notes.example.com
  app_port: 3000
  healthcheck:
    path: /up.html

registry:
  # server: ghcr.io                   # only when you use ghcr.io
  username: YOUR_DOCKERHUB_USER
  password:
    - KAMAL_REGISTRY_PASSWORD
```

Set `builder.arch` to the server's CPU (`amd64` for x86-64, `arm64` for
arm64). Building the image compiles Spinel too, so building for another CPU
under emulation is very slow. To deploy from an Apple Silicon Mac to an
x86-64 server, turn on `builder.remote: ssh://root@203.0.113.10` and let the
server build it.

Do not turn `proxy.ssl` off. The session cookie is `Secure` in production, so
over plain HTTP every form submission gets a 403.

Every role under `servers` runs the same image. `web` serves HTTP (and, unless
`CYBERTRAIN_WORKER=0`, the jobs and scheduled tasks); `worker` runs only the
jobs and scheduled tasks, with `./notes worker`. They share the database on
the volume, and only the one holding the lease runs the scheduled tasks
([deploy.en.md](deploy.en.md), part 7, "Splitting the roles"). To run the
WebSocket subscriptions in a container of their own, turn on the `feeds` role
that the generated file has commented out (`cmd: ./notes feeds trades`) and
give `web` `env: clear: CYBERTRAIN_WORKER: 0`. The first time you upgrade from
a cybertrain release without heartbeats, stop every old container with `kamal
app stop` before `kamal deploy`, so that a new worker does not run an old
worker's running job a second time.

The `worker` role needs the jobs subsystem: `require "cybertrain/jobs"` in
`bin/notes.rb` and `bin/db.rb` ([Subsystems](guide/how-it-works.md#subsystems)).
A new application requires only the core, so `cybertrain new` writes the
role commented out; `cybertrain generate job` and `generate authentication`
add the line and uncomment it. Without jobs, leave it out: `./notes worker`
would print `the worker role needs require "cybertrain/jobs" in
bin/notes.rb`, exit 1, and be restarted by Docker forever.

The `worker` role (and the commented `feeds` one) carries `options: restart:
unless-stopped`. kamal-proxy polls the health check of the `web` role only,
and only during a deploy, so nothing else restarts these containers: Docker
does when their process exits. A worker exits non-zero when it cannot boot;
a feeds process restarts a feed whose thread died, and exits with status 1
when one feed keeps dying (10 restarts within 600 seconds), so that Docker
starts a fresh container. With the feeds in their own container, the web
role's `/up` reports `503 feed stale` when a feed or its process has been
silent for 180 seconds (the feeds write their status into the database).
A feed a release removed or renamed does not count, and a feeds container
stopped cleanly (`kamal app stop -r feeds`, a scale-down) deletes its rows,
so neither holds up the next web deploy; a crashed one leaves them to go
stale. Set `CYBERTRAIN_HEALTH_FEEDS: 0` under `env.clear` if the proxy's health
check points at `/up` and a quiet feed should not hold up a deploy.

With a framework that has the built-in health check (`GET /up`, README
"Operations"), you can change the `healthcheck` `path` from `/up.html` to
`/up`. `/up` runs a query that reads the database's schema and answers 503
when it cannot, so traffic never moves to a release whose volume or database
is broken; `/up.html` is a static file and only shows that the process
answers HTTP. Keep `/up.html` for an app made with an older cybertrain.

The generated `config/deploy.yml` sets `CYBERTRAIN_TRUSTED_PROXIES:
172.16.0.0/12` under `env.clear`. kamal-proxy runs in a container of its own
and connects to the app from its address on the Docker network (inside
172.16.0.0/12 by default), so for connections from there only, the last
`X-Forwarded-For` address, the one kamal-proxy added, becomes
`request.client_ip`. Without it the sign-in rate limit (`rate_limit`) counts
every visitor as kamal-proxy's one address. If your Docker networks use
another range, put that range there instead (`docker network inspect kamal`
shows it). Leave `proxy.forward_headers` unset: kamal-proxy terminating TLS
sets `X-Forwarded-For` itself and does not pass on what the client sent,
which is what you want.

The generated `config/deploy.yml` also has `asset_path: /app/public/assets`.
Each image carries only its own digested stylesheets and scripts, so Kamal
bridges the previous release's files into the new container for the
switch-over, and a page loaded before the deploy still finds the files its
HTML names. Add the line to a `config/deploy.yml` from an older cybertrain;
its `Dockerfile` also needs `libssl-dev` in the build stage and `libssl3t64`
in the runtime stage, since every app now links OpenSSL.

kamal-proxy already redirects http to https and the app sees
`X-Forwarded-Proto: https`. If you turn on `CYBERTRAIN_FORCE_SSL: 1` as well
(for the HSTS header), or `CYBERTRAIN_HOSTS: notes.example.com` (which refuses
other `Host` values), point the `healthcheck` at `/up`. The proxy's check is
plain http to the container, by address: only the health path (`/up`) is
exempt from the redirect and from the Host check, so `/up.html` would be
redirected or get a 403 and the new container would never turn healthy.

## 8-3. Prepare the secrets

`.kamal/secrets` only reads environment variables, so set them in the shell
that runs kamal. Generate `CYBERTRAIN_SECRET_KEY_BASE` once and keep it, in a
password manager for instance (changing it signs everyone out).

```sh
export KAMAL_REGISTRY_PASSWORD=...                      # the registry token
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"   # generate once, then reuse the saved value
```

[Kamal's documentation](https://kamal-deploy.org/docs/commands/secrets/)
shows how to read them straight from a password manager.

To send error reports to Sentry (or GlitchTip), the generated files have
the lines ready, commented out: uncomment `- CYBERTRAIN_SENTRY_DSN` under
`env: secret:` in `config/deploy.yml` and
`CYBERTRAIN_SENTRY_DSN=$CYBERTRAIN_SENTRY_DSN` in `.kamal/secrets`, add
`require "cybertrain/error_reporter/sentry"` to `bin/notes.rb` (a new app
requires only the core; without the line, a container given the DSN
refuses to start and says so), and export the DSN in the same shell. The
commented `CYBERTRAIN_LOG_FORMAT: json` under `env: clear:` writes one JSON
object per log line, for a log collector; `kamal app logs` shows the lines
either way.

```sh
export CYBERTRAIN_SENTRY_DSN=https://PUBLIC_KEY@o1.ingest.sentry.io/42   # the project's DSN, from Sentry
```

## 8-4. The first deploy

Kamal builds the image from your local git HEAD. Commit first, `gen/`
included (`gen/` is generated code, and the build expects it to be current):

```sh
cybertrain spin run gen -- --check
git add -A && git commit -m "Configure Kamal"
kamal setup
```

`kamal setup` installs Docker and kamal-proxy on the server, builds and
pushes the image, and starts the container. The first time takes a few
minutes because Spinel is compiled (it stays in Docker's layer cache, so
later builds only build the app). On start the container runs
`./notes migrate`, then starts the server; once `/up.html` answers 200,
kamal-proxy switches traffic to it. If it does not answer within
`deploy_timeout` (30 seconds), the deploy fails and traffic stays on the old
container (the first time, there is none). Open https://notes.example.com
to check.

## 8-5. Day-to-day operation

| To | Run |
| --- | --- |
| Deploy an update (after committing) | `kamal deploy` |
| Follow the logs | `kamal app logs -f` |
| See the migration status | `kamal db_status` (the `aliases` in `config/deploy.yml`) |
| Open a shell in the container | `kamal shell` |
| List the failed jobs, retry one | `kamal app exec --reuse --roles=web "./notes jobs list"`, then `"./notes jobs retry 42"` |
| See the feeds' last reported status | `kamal app exec --reuse "./notes feeds status"` |
| Go back to an earlier version | `kamal rollback VERSION` (`kamal app containers` lists them) |

- The database is on the server's Docker volume `notes_storage`
  (`/var/lib/docker/volumes/notes_storage/_data/` on the server). To back it
  up, `sudo apt install -y sqlite3` on the server, then use SQLite's
  `.backup`, which is safe while the app writes:

  ```sh
  sudo sqlite3 /var/lib/docker/volumes/notes_storage/_data/production.sqlite3 ".backup /root/notes-$(date +%Y%m%d).sqlite3"
  ```

- `kamal deploy` stops the old container only after the new one passes the
  health check, so unlike a systemd restart, no connection is refused during
  a deploy. But the old and new containers briefly open the same SQLite
  file, and the new container's migrations run while the old one is still
  serving. Run a migration that removes a column in a later deploy, once the
  old code no longer uses that column.
- Use one server: the SQLite file exists only on that server's volume.
- When you upgrade the framework (move the `ref` in `spin.toml` to a new
  release), change `gem install cybertrain -v ...` in the `Dockerfile` to
  the same version.
