# Deploying with Kamal

English translation of part 8 of [deploy.md](deploy.md) (Japanese), "Kamal
でデプロイする". The rest of that tutorial (building on the server and
running under systemd behind Caddy) is in Japanese only; this part stands on
its own.

The names used below; replace them with yours:

| Item | Value in this document |
| --- | --- |
| App name (what you passed to `cybertrain new`: lowercase letters, digits and `_`) | `notes` |
| Domain | `notes.example.com` |
| Server | Ubuntu (or another Linux with SSH), x86-64 or arm64 |

Instead of building on the server and running the app under systemd and
Caddy (parts 3 to 6 of [deploy.md](deploy.md)), you can ship it as a Docker
image with [Kamal 2](https://kamal-deploy.org). `cybertrain new` writes these
files:

| File | What it holds |
| --- | --- |
| `Dockerfile` | A two-stage build. The first stage (Ubuntu 24.04) runs `gem install cybertrain`, `cybertrain setup` (Spinel) and `cybertrain build`; the second (the same Ubuntu) gets only `dist/` and the libraries it needs at run time (SQLite, zlib, jemalloc). On start it runs `./notes migrate`, then `exec`s `./notes` |
| `.dockerignore` | Keeps `build/`, `dist/`, the databases in `storage/`, `tmp/`, `.git/` and `.kamal/` out of the build |
| `config/deploy.yml` | Kamal's configuration. kamal-proxy takes HTTPS (Let's Encrypt) and forwards to the app's port 3000, and health-checks `/up.html`. The database lives on the volume `notes_storage` (`/app/storage` in the container) |
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
    - 203.0.113.10                    # the server's IP address or host name

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
kamal-proxy switches traffic to it. Open https://notes.example.com to check.

## 8-5. Day-to-day operation

| To | Run |
| --- | --- |
| Deploy an update (after committing) | `kamal deploy` |
| Follow the logs | `kamal app logs -f` |
| See the migration status | `kamal db_status` (the `aliases` in `config/deploy.yml`) |
| Open a shell in the container | `kamal shell` |
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
