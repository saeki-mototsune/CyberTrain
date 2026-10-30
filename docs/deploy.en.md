# Tutorial: from `cybertrain new` to production

English translation of [deploy.md](deploy.md) (Japanese). It walks you from
creating an app with `cybertrain new` to running it on an Ubuntu server with
HTTPS, in order, with commands you can copy and paste.

This is where you end up:

```
browser ──HTTPS──▶ Caddy (:443, obtains certificates automatically)
                     ├─ public/ is dist/public/: Caddy serves static files itself
                     └─ everything else ──HTTP──▶ dist/notes (127.0.0.1:3000, systemd)
                                                    └─ /srv/notes/shared/production.sqlite3
```

- `cybertrain build` compiles the app into a single native binary
  (`dist/notes`). The views (`app/views/`) are embedded into the binary at
  build time, and `public/` is copied to `dist/public/`. The binary links the
  system's SQLite (and libc), so it has to be built on the same OS and CPU as
  the machine that runs it. That is why this tutorial **keeps the repository
  on the server and builds there** (the way least likely to trip you up).
- The server does not speak TLS or HTTP/2, so Caddy sits in front of it.
- The database is one SQLite file. The setup assumes a single server.
- Shipping it with Docker and [Kamal](https://kamal-deploy.org) is covered in
  [part 8](#part-8-deploying-with-kamal). `cybertrain new` also writes a
  `Dockerfile` and `config/deploy.yml`, so if you can install Docker on the
  server, you can use that instead of parts 3 to 6.

## Names used in this document

Replace them with your own values; they appear as-is in the commands.

| Item | Value in this document |
| --- | --- |
| App name (what you pass to `cybertrain new`: lowercase letters, digits and `_`) | `notes` |
| Domain | `notes.example.com` |
| The app's GitHub repository (private is fine) | `YOUR_GITHUB/notes` |
| Server | Ubuntu 24.04 LTS, x86-64 or arm64, 1 GB of memory or more |
| Spinel version | `2026.10.27.7020` (what `cybertrain setup` installs; the same as `SPINEL_TAG` in [CI](../.github/workflows/ci.yml)) |

---

## Part 1: Your development machine

Your machine is assumed to run Linux or macOS (on Windows, the same steps
work in Ubuntu under WSL2).

### 1-1. Packages

In 1-3 the `cybertrain` command builds and installs Spinel by itself.
Building Spinel needs a C compiler, make, git and curl; building the app needs
the SQLite and zlib headers and libraries. `cybertrain setup` checks for both
before it starts, so install them now.

Ubuntu / Debian:

```sh
sudo apt update
sudo apt install -y build-essential git curl libsqlite3-dev zlib1g-dev libssl-dev libjemalloc-dev ruby-full ruby-dev
```

macOS: `xcode-select --install` (installs a C compiler, make, git, curl and
the SQLite and zlib headers).

jemalloc (`libjemalloc-dev`; `brew install jemalloc` on macOS) is needed only
if you turn on `allocator = "jemalloc"` in 2-2.

OpenSSL (`libssl-dev`; `brew install openssl@3` on macOS) is optional.
Without it Spinel is built without its openssl package, which cybertrain does
not use. To build an app that does `require "openssl"` on macOS, point the
compiler at Homebrew's OpenSSL (keg-only):
`export LIBRARY_PATH="$(brew --prefix openssl@3)/lib" CPATH="$(brew --prefix openssl@3)/include"`.

The `cybertrain` command is a gem, so it needs Ruby 3.2 or newer (the server
needs it too, since it runs `cybertrain build`; the app itself runs without
Ruby). Ubuntu 24.04's `ruby-full` is 3.2. The Ruby that comes with macOS is
too old: install one with Homebrew (`brew install ruby`), rbenv, mise or
similar.

Building Spinel also needs Ruby's `prism` gem. Ruby 3.3 and newer bundle it,
so there is nothing to do. On Ruby 3.2 (Ubuntu 24.04's `ruby-full`), run
`gem install prism` in 1-2; it builds an extension, so it needs the
`ruby-dev` (Ruby's development headers) in the `apt install` above.

### 1-2. Install the cybertrain CLI

```sh
gem install cybertrain
gem install prism    # Ruby 3.2 only (3.3 and newer bundle it)
cybertrain version
```

The gem holds only the `cybertrain` command (neither the framework nor
Spinel). This command installs Spinel in 1-3.

### 1-3. Install Spinel

```sh
cybertrain setup
```

This builds Spinel `2026.10.27.7020`, the release `cybertrain` pins, from its
GitHub release tag (in [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel),
the fork of matz/spinel that carries the fixes CyberTrain needs ahead of an
upstream release) and installs it into `~/.cybertrain/spinel/2026.10.27.7020/`
(`git clone` → `make deps` → `make -j` → `make install`). It happens once and
takes a few minutes (about 5 minutes on a 4-core machine; `make -j` runs one
job per CPU, so fewer CPUs take longer). CI installs Spinel with the same
`cybertrain setup`.

- If a tool is missing (git, make, curl, a Ruby that loads the `prism` gem,
  a C compiler, the SQLite headers or library), it stops before building and prints what is missing and the
  command that installs it.
- Each step's output goes to the log
  `~/.cybertrain/log/spinel-2026.10.27.7020-build.log`. When a step fails, the end
  of the log is printed.
- If it is already installed (in `~/.cybertrain`, or a `spinel` of the same
  release is on PATH), it prints `nothing to install` and does nothing. To
  rebuild the one in `~/.cybertrain`, run `cybertrain setup --force`.
- The install, `~/.cybertrain/spinel/2026.10.27.7020/`, is about 41 MB (measured
  on Linux x86-64). During the build only, the source and intermediate files
  take about 220 MB in `~/.cybertrain/src/spinel-2026.10.27.7020/`; they are deleted
  when the build succeeds.

`cybertrain doctor` checks the prerequisites (one line each for git, make,
curl, prism, cc, SQLite, OpenSSL and Spinel; anything missing says `MISSING`,
followed by the command that installs it).

`cybertrain new`, `db`, `server` and `build` find and use this Spinel by
themselves, so you need no PATH setting. To run `spin` directly,
`cybertrain spin ...` works too (for example `cybertrain spin run gen --
--check`). Only if you want to type `spin` as is, put `~/.cybertrain/bin` on
your PATH (`~/.zshrc` for zsh). `~/.cybertrain/bin` holds `spinel` and `spin`
links to the release in use, so nothing needs changing when the release moves
on. When `cybertrain setup` installs Spinel itself, it prints the same
`export PATH=...` line.

```sh
echo 'export PATH="$HOME/.cybertrain/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
spinel --version
```

It is right when the word after `spinel` is `2026.10.27.7020` (it prints
something like `spinel 2026.10.27.7020 (d37f38af) [gcc ...]`; the
parentheses hold the commit).

**Note: installing it by hand**

Instead of `cybertrain setup`, you can build and install Spinel yourself. The
steps are the same as `cybertrain setup`'s (and so is the need for a Ruby
that loads the `prism` gem).

```sh
git clone --depth 1 --branch 2026.10.27.7020 https://github.com/saeki-mototsune/spinel.git ~/src/spinel
cd ~/src/spinel
make deps
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
make install PREFIX="$HOME/.local"
```

To have `cybertrain` use it, do one of these:

- Put `~/.local/bin` on your PATH
  (`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc`). If
  `spinel --version` says `2026.10.27.7020`, `cybertrain` uses the one on PATH.
  If it is another release, `cybertrain` ignores it and installs its own into
  `~/.cybertrain`.
- Name the install location in an environment variable (add
  `export CYBERTRAIN_SPINEL_HOME="$HOME/.local"` to `~/.bashrc`). If the
  `spinel` there is not `2026.10.27.7020`, it stops with an error.

---

## Part 2: Create the app

### 2-1. `cybertrain new`

```sh
cd ~/src
cybertrain new notes
cd notes
git init -b main
```

If you installed Spinel in 1-3, `cybertrain new` uses it as is (if not, it
installs it first).

### 2-2. Check the framework reference

`cybertrain new` writes into `spin.toml` the framework of the same version
as the CLI (a GitHub tag).

```toml
[package]
name = "notes"
version = "0.1.0"
# jemalloc is a faster malloc for a server: 1.1 to 1.4 times the
# requests per second on examples/blog (docs/benchmark.md). Building then
# needs its development package (libjemalloc-dev on Debian/Ubuntu,
# `brew install jemalloc` on macOS).
# allocator = "jemalloc"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }
```

Remove the `#` in front of `# allocator = "jemalloc"` and the app is built
linking jemalloc instead of glibc's malloc. The server makes a great many
small allocations per request, and on examples/blog this gave 1.1 to 1.4 times
the requests per second ([benchmark.md](benchmark.md)). It is recommended for
production. Both your machine and the server then need `libjemalloc-dev`
(installed in 1-1 and 3-2); without it the build stops with
`cannot find -ljemalloc`.

`new` then ran `spin lock` and `spin run gen`. The framework is fetched into
spin's cache (`~/.cache/spin/packages/`) and the commit used is pinned in
`spin.lock`. None of the framework's code goes into the app's repository.
Commit `spin.toml` and `spin.lock`, and the server builds with the same
commit (the role Gemfile.lock plays).

### 2-3. Build the pages

```sh
cybertrain generate scaffold note title:string body:text
```

Make the note list the home page. `config/routes.rb`:

```ruby
Cybertrain::Routes.draw do
  root "notes#index"
  resources :notes
end
```

Run the migration.

```sh
cybertrain db migrate
```

It is three steps: generate, migrate, generate again. `spin run gen` takes
the new migration into `gen/migrations.rb`; `spin run db -- migrate` (the
development `bin/db.rb`) creates `storage/development.sqlite3` and rewrites
`db/schema.rb`; and `spin run gen` once more rebuilds `gen/` from
`db/schema.rb` and the routes.

### 2-4. Run it locally

```sh
cybertrain server
```

Open http://127.0.0.1:3000 and check that you can create, edit and delete
notes. In development, saving Ruby code rebuilds automatically, and saving a
view shows on the next request. Stop it with `Ctrl-C`.

### 2-5. (Optional) Using `*_url` helpers

The scaffold writes only `*_path` (relative paths such as `/notes/1`), so you
usually do not need this. If you use `note_url(@note)` and the like to put
absolute URLs in an email body or JSON, add the production origin at the end
of `config/app.rb` (the default is `http://localhost:3000`).

```ruby
Cybertrain.url_root = "https://notes.example.com" if Cybertrain.config.production?
```

### 2-6. A production rehearsal

Before going to the server, start the app locally the way production does
once; a missing setting shows up early.

```sh
cybertrain build
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
export CYBERTRAIN_DATABASE="$PWD/dist/storage/rehearsal.sqlite3"
(cd dist && ./notes migrate && ./notes)
```

`cybertrain build` makes the binary `dist/notes`, with the views embedded,
and `dist/public/`. In production, systemd starts the binary with `dist/` as
its working directory (5-1), so the rehearsal also runs `./notes` from inside
`dist/`. The `storage/` and `public/` used are then the copies in `dist/`, not
the ones at the app's root. Because it enters `dist/` in a subshell
`( ... )`, your shell is still at the app's root after you stop it.
A built binary is in production mode by default, so you need not set
`CYBERTRAIN_ENV` (add `CYBERTRAIN_ENV=development` only to run it in
development mode). `./notes migrate` applies the migrations compiled into the
binary to `CYBERTRAIN_DATABASE`.

It is right when it starts like this:

```
=> Booting cybertrain 0.3.1
=> production environment (1 worker)
* Listening on http://127.0.0.1:3000
```

Make sure the line `=> Watching app/, config/ and db/schema.rb for changes`
does **not** appear (if it does, it is running in development mode).

In the browser, open **http://localhost:3000** and try everything. In
production the session cookie has the `Secure` attribute, so the browser
sends it back only over HTTPS. As an exception, Chrome and Firefox treat
`localhost` as a secure context, so it works there; but opened as
`127.0.0.1`, or in another browser, form submissions get
`Invalid authenticity token` (403). In production Caddy serves HTTPS, so
this is not a problem.

When you are done, stop it with `Ctrl-C` and reset the environment.

```sh
unset CYBERTRAIN_SECRET_KEY_BASE CYBERTRAIN_DATABASE
rm -f dist/storage/rehearsal.sqlite3*
```

`dist/` is in the `.gitignore` that `cybertrain new` writes, so it is not
committed.

### 2-7. Commit and push to GitHub

`gen/` is generated code, but **commit it** (the build expects `gen/` to be
current already). Check that it is fresh before committing.

```sh
cybertrain spin run gen -- --check   # no output and exit status 0 means fresh
git add -A
git commit -m "Create notes"
```

Create a private repository `YOUR_GITHUB/notes` on GitHub (without a README
or anything else) and push.

```sh
git remote add origin git@github.com:YOUR_GITHUB/notes.git
git push -u origin main
```

---

## Part 3: Prepare the server

From here on the work is on the server. Start logged in over SSH as a user
who can sudo.

### 3-1. DNS

In your domain's DNS, add an A record pointing `notes.example.com` at the
server's IP address (and AAAA if it has IPv6). Caddy needs it to get a
certificate in part 6, so do it first.

### 3-2. Packages and the firewall

```sh
sudo apt update && sudo apt -y upgrade
sudo apt install -y build-essential git curl libsqlite3-dev zlib1g-dev libssl-dev libjemalloc-dev sqlite3 ufw ruby-full ruby-dev

sudo ufw allow OpenSSH
sudo ufw allow 80,443/tcp
sudo ufw enable
```

The app itself listens on `127.0.0.1:3000` only, so port 3000 stays closed.

### 3-3. A user for the app

A dedicated user, `notes`, builds and runs the app. Its home directory,
`/srv/notes`, is where the app lives.

```sh
sudo useradd --system --create-home --home-dir /srv/notes --shell /bin/bash notes
sudo chmod 711 /srv/notes    # so Caddy can reach public/ (without listing what is inside)
```

### 3-4. Install cybertrain and Spinel as `notes`

```sh
sudo -iu notes
```

From here **to the end of part 3, work in the `notes` user's shell**. The
steps are those of 1-2 and 1-3: first the `cybertrain` command, then Spinel.
Ruby is there from `ruby-full` in 3-2 (3.2), so, as in 1-2, install the
`prism` gem too.

First install the `cybertrain` command into the `notes` user's home (the
deploy script uses `cybertrain build`). The executable lands in the gem
directory, so link it from `~/.local/bin` and put that on PATH.

```sh
gem install --user-install cybertrain -v 0.3.1
gem install --user-install prism
mkdir -p ~/.local/bin
ln -sfn "$(ruby -e 'print Gem.user_dir')/bin/cybertrain" ~/.local/bin/cybertrain
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
cybertrain version
```

Make `-v` the same version as the `ref` in the app's `spin.toml` (the tag
`v0.3.1`). The CLI and the framework `spin.lock` pins (`spin run gen` runs
that framework's own generator) are upgraded together; if their versions
differ, building or starting fails.

Then, as the same `notes` user, install Spinel.

```sh
cybertrain setup
```

It does what 1-3 does and takes a few minutes, once (longer on a server with
fewer CPUs). Spinel goes into the `notes` user's
`~/.cybertrain/spinel/2026.10.27.7020/` (here
`/srv/notes/.cybertrain/spinel/2026.10.27.7020/`, about 41 MB), and the log stays
in `~/.cybertrain/log/spinel-2026.10.27.7020-build.log`. During the build only,
the source and intermediate files take about 220 MB in `~/.cybertrain/src/`
(deleted when it succeeds). The packages from 3-2 cover the prerequisites;
if it says something is missing, check with `cybertrain doctor`.

### 3-5. A deploy key

Create a read-only deploy key so the server can read the app's private
repository (the framework needs no key: spin fetches `spin.lock`'s commit
from the public repository).

```sh
ssh-keygen -t ed25519 -N "" -C "deploy@notes.example.com" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Paste the printed public key into GitHub at `YOUR_GITHUB/notes` → Settings →
Deploy keys → Add deploy key (leave "Allow write access" unchecked). Check the
connection:

```sh
ssh -T git@github.com
```

The first time, it asks you to confirm the host key. Check that the
fingerprint it shows matches
[GitHub's published values](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
before answering `yes`. It is right when it says
`Hi YOUR_GITHUB/notes! You've successfully authenticated`.

### 3-6. Directories

```sh
mkdir -p ~/releases ~/shared ~/backups
chmod 700 ~/shared ~/backups
exit    # leave the notes user, back to the user who can sudo
```

- `~/releases/<timestamp>/` … one checkout per deploy (the built `dist/` is
  here too)
- `~/current` … a symbolic link to the release that runs
- `~/shared/` … what outlives releases (the SQLite database)

---

## Part 4: The secret and environment variables

Production settings are passed as environment variables.
`CYBERTRAIN_SECRET_KEY_BASE` is the key that signs the session cookie; in
production the app does not start without it. Keep it out of the repository,
in a file on the server only.

As the user who can sudo:

```sh
sudo install -d -m 750 -o root -g notes /etc/notes
SECRET="$(openssl rand -hex 32)"
sudo tee /etc/notes/notes.env > /dev/null <<EOF
CYBERTRAIN_ENV=production
CYBERTRAIN_SECRET_KEY_BASE=$SECRET
CYBERTRAIN_DATABASE=/srv/notes/shared/production.sqlite3
PORT=3000
SPINEL_GC_FULL_INTERVAL=8
EOF
unset SECRET
sudo chown root:notes /etc/notes/notes.env
sudo chmod 640 /etc/notes/notes.env
```

| Variable | Meaning |
| --- | --- |
| `CYBERTRAIN_ENV=production` | A binary from `cybertrain build` is in production mode by default, so this could be left out, but it is stated here. `development` starts it in development mode, file watching and rebuilding included |
| `CYBERTRAIN_SECRET_KEY_BASE` | **Required**. Changing it ends everyone's session |
| `CYBERTRAIN_DATABASE` | The database file. It goes in `shared/` so it outlives releases |
| `PORT` | The port to listen on. Keep it in step with Caddy's configuration |
| `SPINEL_GC_FULL_INTERVAL=8` | Spinel's collector does a full collection every eighth time. Left to adapt, it falls to nearly every collection full under a web server's load; fixed at 8, a one-CPU server answers about 16% more requests a second at the same memory ([spinel-feedback.md](spinel-feedback.md), 5) |

---

## Part 5: systemd and the deploy script

### 5-1. The systemd unit

Create `/etc/systemd/system/notes.service`.

```sh
sudo tee /etc/systemd/system/notes.service > /dev/null <<'EOF'
[Unit]
Description=notes (cybertrain)
After=network.target

[Service]
Type=simple
User=notes
Group=notes
WorkingDirectory=/srv/notes/current/dist
EnvironmentFile=/etc/notes/notes.env
ExecStart=/srv/notes/current/dist/notes
Restart=always
RestartSec=2
TimeoutStopSec=15

# only the database's directory is writable
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/srv/notes/shared
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable notes
```

Do not start it yet (`/srv/notes/current` does not exist yet); the first
deploy starts it.

- `WorkingDirectory` matters. The server resolves `public/` and `storage/`
  (where the database goes when `CYBERTRAIN_DATABASE` is not set) **relative
  to the working directory**. The views are embedded in the binary, so they
  are not read from disk. Here `CYBERTRAIN_DATABASE` puts the database in
  `/srv/notes/shared/`, so that is the only place that needs to be writable
  (`ReadWritePaths`).
- Logs go to standard output, so journald collects them
  (`sudo journalctl -u notes`).
- It stops on SIGTERM: it stops accepting, finishes answering the requests in
  flight, then exits (10 seconds at most; `TimeoutStopSec=15` is longer than
  that).

### 5-2. Let the `notes` user restart the service, and nothing else

```sh
echo 'notes ALL=(root) NOPASSWD: /usr/bin/systemctl restart notes' | sudo tee /etc/sudoers.d/notes > /dev/null
sudo chmod 440 /etc/sudoers.d/notes
sudo visudo -c
```

### 5-3. The deploy script

Put the script in place as the `notes` user. Change the `REPO` line to your
repository.

```sh
sudo -iu notes
cat > ~/deploy.sh <<'EOF'
#!/usr/bin/env bash
# usage: ~/deploy.sh [branch, tag or commit]   (main if omitted)
set -euo pipefail

APP=notes
ROOT=/srv/notes
REPO=git@github.com:YOUR_GITHUB/notes.git
REF="${1:-main}"
KEEP=5   # how many releases to keep

export PATH="$HOME/.cybertrain/bin:$HOME/.local/bin:$PATH"
set -a; . /etc/notes/notes.env; set +a

release="$ROOT/releases/$(date +%Y%m%d%H%M%S)"

echo "==> Fetching $REF into $release"
git clone --quiet "$REPO" "$release"
cd "$release"
git checkout --quiet "$REF"

echo "==> Checking that gen/ is fresh"
spin run gen -- --check

echo "==> Building (dist/notes with the views embedded, and dist/public/)"
cybertrain build

echo "==> Migrating"
dist/notes migrate

echo "==> Switching and restarting"
previous="$(readlink "$ROOT/current" || true)"   # where to go back to (empty the first time)
ln -sfn "$release" "$ROOT/current.new"
mv -T "$ROOT/current.new" "$ROOT/current"
sudo /usr/bin/systemctl restart "$APP"

echo "==> Waiting for the new release to answer (about 30 seconds)"
up=""
deadline=$((SECONDS + 30))   # 2 seconds per try, about 30 seconds in all (the last try can end a little past it)
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fs --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/up.html"; then up=1; break; fi
  sleep 1
done
if [ -z "$up" ]; then
  echo "==> The new release does not answer (as the user who can sudo: sudo journalctl -u $APP)"
  if [ -n "$previous" ]; then
    echo "==> Going back to the previous release: $previous"
    ln -sfn "$previous" "$ROOT/current.new"
    mv -T "$ROOT/current.new" "$ROOT/current"
    sudo /usr/bin/systemctl restart "$APP"
  fi
  exit 1
fi

echo "==> Removing old releases (keeping the newest $KEEP)"
ls -1d "$ROOT"/releases/* | sort -r | tail -n +$((KEEP + 1)) | xargs -r rm -rf

echo "==> Done: $(git rev-parse --short HEAD)"
EOF
chmod 700 ~/deploy.sh
```

`~/.cybertrain/bin` comes first on `PATH` because the `gen/` check calls
`spin` directly (`cybertrain build` finds Spinel by itself).
`~/.cybertrain/bin` holds links that `cybertrain setup` points at the current
release, so nothing needs changing when the Spinel release moves on.

If any step fails (`gen/` is stale, a compile error, a failed migration), the
script stops before switching `current`, and the running app keeps serving the
old release. Note, though, that migrations run while the old release is still
serving, and a migration that succeeded stays applied even if a later step
fails. Keep each migration compatible with the code already running (add a
column first, remove the old one in a later deploy).

`systemctl restart` succeeds even if the new binary exits right after starting
(the unit is `Type=simple`). So after switching and restarting, the script
waits about 30 seconds for `http://127.0.0.1:$PORT/up.html` to answer; if it
does not, the script points `current` back at the previous release, restarts
it and fails. To see why the new release did not start (an empty secret, a
port in use, ...), leave the `notes` shell and run `sudo journalctl -u notes`
as the user who can sudo (`notes` may only run `systemctl restart notes`).

- `public/up.html` is the static file `cybertrain new` writes (the same one
  Kamal health-checks), served by the app itself. If an app made by an older
  `cybertrain` lacks it, create it with `echo OK > public/up.html` and commit
  it.
- Migrations are not rolled back. Going back to the previous release works
  because, as above, migrations stay compatible with the old code.
- The first deploy has nothing to go back to: if it fails, fix the cause and
  run `~/deploy.sh` again.

### 5-4. The first deploy

Still as the `notes` user:

```sh
~/deploy.sh
```

The first time, the migration creates `/srv/notes/shared/production.sqlite3`.

```sh
exit    # back to the user who can sudo
systemctl status notes --no-pager
sudo journalctl -u notes -n 20 --no-pager
curl -sI http://127.0.0.1:3000/
```

If the log has `=> production environment` and
`* Listening on http://127.0.0.1:3000`, and curl gets `HTTP/1.1 200 OK`, the
app is running.

---

## Part 6: Serve it over HTTPS with Caddy

### 6-1. Install

Install it from Caddy's official apt repository, as
[Caddy's own instructions](https://caddyserver.com/docs/install#debian-ubuntu-raspbian)
say.

```sh
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

### 6-2. The Caddyfile

Replace `/etc/caddy/Caddyfile` with this:

```sh
sudo tee /etc/caddy/Caddyfile > /dev/null <<'EOF'
notes.example.com {
	encode zstd gzip
	root * /srv/notes/current/dist/public

	# Caddy serves the files in public/ itself
	@static file
	handle @static {
		file_server
	}

	handle {
		reverse_proxy 127.0.0.1:3000
	}

	# when the app is down or restarting (a 502 and the like)
	handle_errors {
		rewrite * /500.html
		file_server
	}
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

In production the app itself answers its 404s and 500s with
`dist/public/404.html` and `dist/public/500.html`, so Caddy need not replace
them. Caddy's `handle_errors` is for when the app cannot be reached (while
it restarts, for instance).

On the first request Caddy gets a certificate from Let's Encrypt (DNS must
point at the server, and 80 and 443 must be open). Requests over HTTP are
redirected to HTTPS automatically.

### 6-3. Check

```sh
curl -sI https://notes.example.com/
```

`HTTP/2 200` means it is live. Open https://notes.example.com/ in a browser
and create, edit and delete a note. If something is wrong, look at
`sudo journalctl -u caddy -n 50 --no-pager`.

---

## Part 7: Day-to-day operation

### Deploying an update

Make the change locally, commit and push, then:

```sh
ssh YOUR_SERVER
sudo -iu notes /srv/notes/deploy.sh          # ships main
sudo -iu notes /srv/notes/deploy.sh v1.2.0   # a tag or a commit works too
```

The local workflow is the same as in development. After changing the schema,
the routes, or a controller's callbacks or instance variables, run
`cybertrain spin run gen` and commit `gen/` with the change (forget it and
the deploy stops at `Checking that gen/ is fresh`).

During the restart (a few seconds) Caddy answers with 500.html.

### Reading the logs

```sh
sudo journalctl -u notes -f             # the app (two lines per request: Started / Completed)
sudo journalctl -u caddy -f             # Caddy
```

The client IP in the request log is always `127.0.0.1` (Caddy). If you need
the real client IP, add `log` to the Caddyfile's site block and use Caddy's
access log.

### Rolling back

As the `notes` user, find the release to go back to.

```sh
sudo -iu notes
ls -1 ~/releases                                         # the releases still kept
```

If **no migrations were added** after the release you are going back to,
switch and restart:

```sh
ln -sfn ~/releases/20260926120000 ~/current.new && mv -T ~/current.new ~/current
sudo /usr/bin/systemctl restart notes
```

**If migrations were added**, roll the database back **before** switching,
from the release running now (the newer one): the older release does not
know the newer migrations. Stop the app first, so that no request meets a
schema halfway back (Caddy answers with 500.html meanwhile). Leave the
`notes` shell and, as the user who can sudo:

```sh
sudo systemctl stop notes
sudo -iu notes
cd ~/current                                  # the release running now (the newer one)
set -a; . /etc/notes/notes.env; set +a
dist/notes db status                          # see which migrations are applied
dist/notes db rollback 1                      # how many to roll back
dist/notes db status                          # check that they are rolled back
ln -sfn ~/releases/20260926120000 ~/current.new && mv -T ~/current.new ~/current
exit                                          # back to the user who can sudo
sudo systemctl start notes
```

### Backups

SQLite runs in WAL mode, so do not `cp` the database file: use `sqlite3`'s
`.backup` (it takes a consistent copy without stopping the app). Add a daily
backup at 3:15, and the deletion of backups older than 14 days, to the
`notes` user's crontab.

```sh
sudo -iu notes
crontab -e
```

```cron
15 3 * * * sqlite3 /srv/notes/shared/production.sqlite3 ".backup '/srv/notes/backups/production-$(date +\%F).sqlite3'" && find /srv/notes/backups -name 'production-*.sqlite3' -mtime +14 -delete
```

In case the server is lost, also copy `/srv/notes/backups/` somewhere else
regularly (another server, or object storage).

Instead of `sqlite3`, the app's binary can take the backup itself (an app
made with a framework that has `db backup`; README, "Operations"):
`CYBERTRAIN_DATABASE=/srv/notes/shared/production.sqlite3 /srv/notes/current/dist/notes db backup /srv/notes/backups/ --keep 14`
writes `notes-<UTC date and time>.sqlite3` with mode 0600 through a
temporary file and keeps the newest 14 files of that shape. It can replace
the `sqlite3 ... && find ...` pair in the crontab. After deleting many rows,
`notes db vacuum` with the same variable gives the free space back to the
disk (it rewrites the whole file, so run it at a quiet hour).

To restore:

```sh
sudo systemctl stop notes
sudo -u notes cp /srv/notes/backups/production-2026-09-26.sqlite3 /srv/notes/shared/production.sqlite3
sudo -u notes rm -f /srv/notes/shared/production.sqlite3-wal /srv/notes/shared/production.sqlite3-shm
sudo systemctl start notes
```

### Upgrading the framework

Locally:

Change the `ref` in `spin.toml` to the new tag (for example `"v0.3.1"`) and
bring the CLI to the same version with `gem install cybertrain` (on the
server too, as the `notes` user, update the CLI naming the same version as
`spin.toml`'s tag, as in `gem install --user-install cybertrain -v 0.3.1`.
The CLI and the framework `spin.lock` pins are upgraded together; if their
versions differ, building or starting fails). Then:

```sh
cybertrain spin lock      # pin the new tag's commit in spin.lock
cybertrain spin run gen   # the generated code may change with the framework
cybertrain spin test      # if you have written tests
cybertrain server         # check that it works
git add -A && git commit -m "Update cybertrain"
git push
```

Then deploy as usual. If the Spinel release the new `cybertrain` pins
(`Cybertrain::SPINEL_TAG`; the same as `SPINEL_TAG` in that tag's
[`.github/workflows/ci.yml`](https://github.com/saeki-mototsune/cybertrain/blob/main/.github/workflows/ci.yml))
has moved on, reinstall with `cybertrain setup` before the commands above. The
new release goes into `~/.cybertrain/spinel/<release>/` and the old one stays.
The links in `~/.cybertrain/bin` are pointed at the new release, so the PATH
lines (1-3, 5-3) stay as they are. On the server, run `cybertrain setup` as
the `notes` user after the `gem install` (3-4), and the deploy does not have
to wait for the build.

### Changing the secret

Change `CYBERTRAIN_SECRET_KEY_BASE` in `/etc/notes/notes.env` to a new value
(`openssl rand -hex 32`) and `sudo systemctl restart notes`. Everyone's
session and flash are gone, and forms left open get a CSRF error.

---

## Part 8: Deploying with Kamal

Shipping the app as a Docker image with [Kamal 2](https://kamal-deploy.org),
instead of parts 3 to 6, has its own page:
[deploy-kamal.md](deploy-kamal.md). It covers the files `cybertrain new`
writes for it, editing `config/deploy.yml`, the secrets, the first deploy and
day-to-day operation.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `CYBERTRAIN_SECRET_KEY_BASE is not set` in the startup log | `/etc/notes/notes.env` is missing, unreadable or the value is empty. Check the `EnvironmentFile=` path, and that the file is owned by `root:notes` with mode `640` |
| `=> development environment` or `Watching app/...` in the startup log | `CYBERTRAIN_ENV` in `/etc/notes/notes.env` is something other than `production`. In development mode it reads `app/views/` from disk and tries to rebuild with `spin`, so always fix this |
| It does not start, with `status=203/EXEC` | `/srv/notes/current/dist/notes` does not exist. Check that `~/deploy.sh` ran to the end |
| `error: views are not embedded in this binary` in the startup log | A binary built without embedded views (such as `build/bin/notes` from `spin build notes`) is running in production mode. Use the `dist/notes` that `cybertrain build` makes |
| A 500, with `Missing template ...` in the log | A template that was not in `app/views/` at build time. Run `cybertrain build` again |
| `attempt to write a readonly database` / `unable to open database file` | The database path is outside `ReadWritePaths=`, or `/srv/notes/shared` is not owned by `notes` |
| The deploy stops at `stale: gen/...` | You forgot to run `cybertrain spin run gen` locally and commit `gen/` |
| The deploy ends with `The new release does not answer` | The new release did not answer `/up.html` within about 30 seconds (the script has gone back to the previous release). Look at `sudo journalctl -u notes -n 50` for why. If it did start but does not answer, the app has no `public/up.html` (5-3) |
| `spin: command not found` (while deploying) | Spinel is not installed for the `notes` user (`cybertrain setup` in 3-4), or `~/deploy.sh`'s `PATH` lacks `~/.cybertrain/bin` (5-3) |
| `cybertrain: command not found` (while deploying) | The cybertrain CLI is not installed for the `notes` user (`gem install --user-install cybertrain -v 0.3.1` in 3-4) |
| `git clone` fails with `Permission denied (publickey)` | The deploy key is not registered, or another user's key is in use (run 3-5 as the `notes` user) |
| The browser keeps showing 500.html | The app is down. Look at `sudo journalctl -u notes -n 50` |
| No certificate | Check that DNS points at the server and 80 and 443 are open. Look at `sudo journalctl -u caddy` |
| Static files get 403 / 404 | Check the permissions on `/srv/notes` (`chmod 711`), and that the file is in `dist/public/` (`cybertrain build` copies it from `public/`) |
| Form submissions get 403 `Invalid authenticity token`, or the flash does not show | The site is open over HTTP. The production session cookie is `Secure`, so it only travels over HTTPS. Open it with `https://` (if you really must run it over HTTP, set `c.session_secure = false` in `config/app.rb`) |

## cybertrain's current limits (what to keep in mind in production)

- **SQLite is the only database.** It is meant to run as one process on one
  server; it cannot be scaled out.
- **Connections fail for a few seconds during a restart (a deploy).** On
  SIGTERM the server stops accepting new connections and finishes answering
  the requests in flight before it exits, but connections that arrive before
  the new process listens are refused (Caddy answers 502). It waits at most
  10 seconds for requests in flight; a request that takes longer is cut off
  there.
- To pin the site to HTTPS, once you have checked it works, add
  `header Strict-Transport-Security "max-age=31536000"` to the Caddyfile's
  site block (the session cookie is `Secure` in production).
- The app adds `X-Content-Type-Options: nosniff` and
  `X-Frame-Options: SAMEORIGIN` to every response (the app's responses, error
  responses and the `public/` files the `Static` middleware serves). But with
  the Caddyfile of 6-2, Caddy serves the files in `public/` itself, without
  going through the app, so those two headers are missing there. To add them,
  put `header ?X-Content-Type-Options nosniff` and
  `header ?X-Frame-Options SAMEORIGIN` in the site block (`?` means "do not
  overwrite a value the app already set", so a page meant for embedding that
  changes the value in the app keeps it).
- The framework has no authentication (login). Before going public, think
  about who should be able to write.
- The views are embedded into the binary at build time. Even a view-only
  change needs a deploy (a rebuild and a restart) to reach production.
