# Web playground SP2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A no-login hosted playground where a visitor presses "Start a session" and, for 30 minutes, gets VS Code (code-server) in the browser on the tutorial blog, its development server in a terminal and the app in the editor's preview, built as a session image (`web` stage), a static Caddy router and a small Ruby control plane, proven locally end to end and in a real browser, with deployment files, CI, documentation and a prepared (not applied) site entry.

**Architecture:** Each session is one hardened container of the new `web` image (SP1's image plus code-server) on its own `--internal` /28 network; a stock Caddy router with a static Caddyfile reaches it through Docker network aliases built from two independent 128-bit ids (`s-<sid>` for the editor, `p-<pid>` for the app) and answers everything else with static 404/502/503 pages. A single-process Sinatra/Puma control plane, the only holder of the Docker socket, creates and removes sessions with fixed argv templates, enforces the global and per-client limits, reconciles with Docker by labels every 5 seconds and offers a stop switch (`bin/playctl`); Kamal deploys the router and the control plane as two services behind kamal-proxy and Cloudflare.

**Tech Stack:** code-server 4.139.1 on SP1's image (Ubuntu 24.04, Spinel 2026.09.12, cybertrain 0.2.1); Caddy 2.11.4 (`caddy:2.11.4-alpine`); Ruby 4.0.7 (`ruby:4.0.7-slim`; Ruby 4.0 locally) with Sinatra `~> 4.1` (4.2.1), Puma `~> 7.0` (7.2.1), minitest 6, rack-test 2.2, rake 13; the Docker CLI from `docker:28-cli`; Docker Engine with BuildKit (Docker Desktop 29.7.2, linux/arm64, on the development machine) and docker compose v2; bash 3.2+ host scripts; Kamal 2.12.0 with kamal-proxy; Cloudflare Free; GitHub Actions (docker/build-push-action v6, docker/metadata-action v5, ruby/setup-ruby v1); Playwright MCP or the built-in browser tools for the browser checks.

**Spec:** `docs/superpowers/specs/2026-10-02-web-playground-sp2-design.md` (Japanese; authoritative; its §15, the results of the probes run on 2026-10-02, takes precedence over the body)

## Global Constraints

- Work on branch `web-playground-sp2` in the primary checkout `/Users/saeki/work/cybertrain` (a regular clone whose `.git` is a directory). Never create a git worktree: the image build bind-mounts `.git` and stops in a worktree by design.
- Order: one task at a time, 1 → 12, each starting after the previous one is committed. Dependencies: 2 needs 1 (its check runs the session image); 3 needs 1-2; 4 needs 1 (its drift test reads `playground/web-smoke.sh`); 5 needs 4; 6 needs 5; 7 needs 1, 2, 6; 8 needs 7; 9 needs 6; 10 needs 1 and 7; 11 needs 3, 7, 9, 10; 12 is last.
- Stage files by path (`git add <path>...`), never `git add -A` or `git add .`. The browser tools may create `.playwright-mcp/` in the checkout: never stage it, and `rm -rf .playwright-mcp` at the end of every task that used a browser.
- Commit subjects follow `git log` ("Area: what changed", no trailing period; areas used here: `Playground`, `Router`, `Control`, `Deploy`, `CI`, `Docs`). Every commit message ends with the Co-Authored-By trailer your session specifies; the commands below show `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, replace it if yours differs. The repository sets `commit.gpgsign false`; leave it.
- Nothing is pushed, no pull request is opened, no workflow is triggered (`gh workflow run` included), no server is rented, no domain is bought, no DNS or Cloudflare setting is touched, and no `kamal setup`/`deploy`/`app exec` runs: those are the owner's steps (Task 12 lists them).
- The spec is in Japanese. Where a task corrects the spec's text, it says so and why ("Correction:"); follow the task. Spec §15 (corrections 1-7) is already folded into the file contents below.
- The command sandbox blocks the Docker socket and local port binding. Run `docker`, `docker compose`, the smoke and end-to-end scripts, local servers (`python3 -m http.server`, Puma) and browser previews through the permission-gated sandbox bypass; never work around the sandbox another way. `bundle lock` and `bundle install` need rubygems.org (allowed through the proxy).
- Long commands (image builds, `smoke.sh`, `web-smoke.sh`, `e2e.sh`) run in the background with their output in a log file under `$SDD/logs/`, polled until they end. On this machine (Apple Silicon, Docker Desktop, linux/arm64): SP1's image builds in about 2.5 minutes cold; the `web` stage adds the code-server download (217 MB) and extraction, 1-3 minutes; `smoke.sh` about 2 minutes; `web-smoke.sh` about 6 minutes; `e2e.sh` about 6 minutes plus about 3 minutes for its first build of the router and control-plane images.
- `$SDD` is the workspace directory the controller gives you (by convention `/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2`, git-ignored): logs in `$SDD/logs/`, screenshots in `$SDD/screens/`, throwaway scripts in `$SDD/scratch/`, the control plane's Ruby gems in `$SDD/bundle` (`export BUNDLE_PATH="$SDD/bundle"` before every `bundle` command). Create the subdirectories when missing.
- Shell: the commands below work in bash and zsh (the tool's shell here). Shell state may not persist between tool calls: start each command line with `cd /Users/saeki/work/cybertrain` and set `SDD=...` (and `BUNDLE_PATH=...`) in it when it uses them. The repository's scripts run under bash (`bash playground/...`).
- If a step fails for a reason its text did not foresee, fix it within the spec's meaning and these constraints, and record the exact error, the change and the reason in your report. If the fix would change a requirement (a name, a limit, a flag of the hardened run, what a check means), stop and report instead. Never weaken a check to make it pass.
- Names: session image `ghcr.io/saeki-mototsune/cybertrain-playground-web` (local tag `cybertrain-playground-web:local`, CI tag `cybertrain-playground-web:ci`); SP1's image `cybertrain-playground:local`; router image `ctplay-router:local`; control-plane image `ctplay-control:local`; Kamal services `cybertrain-play-router` (network alias `ctplay-router`) and `cybertrain-play` (network alias `ctplay-control`, port 9292); per session: container `ctplay-s-<h>`, network `ctplay-n-<h>`, labels `cybertrain-play.role=session`, `cybertrain-play.handle=<h>`, `cybertrain-play.created-at=<unix>`, `cybertrain-play.expires-at=<unix>`, network aliases `s-<sid>` and `p-<pid>`; `<sid>` and `<pid>` are two separate `SecureRandom.hex(16)` (32 lower-case hex digits); `<h>` is the first 16 hex digits of SHA-256(`<sid>`).
- Hosts: entry `<DOMAIN>`, editor `<sid>.<DOMAIN>`, preview `3000-<pid>.<DOMAIN>`. Locally the domain is `play.localhost` with `PLAY_PUBLIC_URL=http://play.localhost:8080` (dev stack), port 18080 (end-to-end test), 18081 (Task 2's check), 18082 (Task 3's hand-wired session).
- Session networks: `docker network create --driver bridge --internal --subnet <a /28 of 10.250.0.0/16> --opt com.docker.network.bridge.inhibit_ipv4=true` (both options are load-bearing, spec §15: without `inhibit_ipv4` an internal network reaches host listeners). Such a network has no gateway; the first container takes `.1`.
- The hardened run, identical in `playground/web-smoke.sh` (between `# BEGIN hardened run` and `# END hardened run`) and in `Play::Templates.hardening`: `--user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp:rw,exec,nosuid,nodev,size=256m,mode=1777 --tmpfs /home/dev:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0755 --tmpfs /workspace:rw,exec,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=0755 --tmpfs /opt/cybertrain-cache:rw,nosuid,nodev,size=64m,uid=1000,gid=1000,mode=0755 --memory 1536m --memory-swap 1536m --cpus 1 --pids-limit 512`. A session's `docker run` also has `--detach --rm --init --pull never --name ctplay-s-<h> --hostname playground --network ctplay-n-<h> --network-alias s-<sid> --network-alias p-<pid>`, the four labels, `--log-driver json-file --log-opt max-size=1m --log-opt max-file=1`, `--runtime <PLAY_RUNTIME>` only when set, and `--env VSCODE_PROXY_URI=<scheme>://{{port}}-<pid>.<domain><:port>`, `--env PLAYGROUND_ENDS_AT=<expires>`, `--env PLAYGROUND_IDLE_TIMEOUT=<PLAY_IDLE_TIMEOUT>`. Never `--privileged`, `--cap-add`, `-v`/`--mount`, `-p`, `--network host`, `--pid`, `--ipc`, `--device`, `seccomp=unconfined` or `--restart`.
- Defaults (spec §5.10): `PLAY_MAX_SESSIONS` 5, `PLAY_MAX_SESSIONS_PER_IP` 1 (IPv4 per address, IPv6 per /64), `PLAY_CREATE_LIMIT` 3 per `PLAY_CREATE_WINDOW` 600 s (successful creations only), `PLAY_TTL` 1800, `PLAY_IDLE_TIMEOUT` 300 (must be more than 60), `PLAY_READY_TIMEOUT` 30, `PLAY_REAP_INTERVAL` 5, `PLAY_SUBNET_POOL` `10.250.0.0/16`, `PLAY_SUBNET_PREFIX` 28, `PLAY_DATA_DIR` `/data` (`paused`, `kill-all`, `create.lock`), `PLAY_ROUTER_URL` `http://ctplay-router`, `PLAY_ROUTER_FILTERS` `label=service=cybertrain-play-router,label=role=web`.
- Teardown order, always: `docker rm --force ctplay-s-<h>`, then disconnect every container attached to `ctplay-n-<h>`, then `docker network rm ctplay-n-<h>`; "absent" counts as done (spec §5.4, §15 correction 4). The router runs with `--dns 127.0.0.1` and `--sysctl net.ipv4.ip_forward=0`, and both session upstreams in the Caddyfile have `keepalive off` (§15 corrections 3, 4, 6).
- Never: a value from a visitor's request in a docker argv (the routes read only `Origin`, `Sec-Fetch-Site` and `PLAY_CLIENT_IP_HEADER`); a session id, preview id, editor or preview URL, session host name or client IP address in a log line (logs name sessions by handle); the `docker run` argv in a log; the Docker socket inside a session.
- Host scripts (`web-smoke.sh`, `e2e.sh`, the throwaway checks) run on macOS's bash 3.2: no associative arrays, no `mapfile`, no `date +%N`, no host `timeout`, no `case` statement inside `$(...)` (bash 3.2 cannot parse it), and `${arr[@]+"${arr[@]}"}` for an array that may be empty under `set -u`.
- Control-plane tests run with minitest 6: no `minitest/mock` (it is gone), `assert_nil` instead of `assert_equal nil`; hand-written fakes in `test/fakes.rb`.
- SP1 keeps working: `bash playground/smoke.sh cybertrain-playground:local` must still print `smoke: 29 passed, 0 failed` (Tasks 1 and 12). `playground/smoke.sh`, `playground/PLAYGROUND.md`, `playground/profile.sh`, `playground/Dockerfile.dockerignore`, `.devcontainer/`, `cybertrain/`, `site/` and `README.md` are not changed by any task (the site and README entry is a patch file, Task 11).
- Outcomes of Task 3: its report ends with one line `V-OUTCOMES: V1=<ok|fallback> V9-ports=<ok|fallback> V9-guide=<ok|fallback> V10=<ok|fallback> V11-editor=<ok|fallback> V11-preview=<ok|fallback> V19=<ok|fallback>`; the controller copies that line into the dispatch of Tasks 6, 7, 8 and 11, which say what each value changes.

## Review Focus

1. A visitor presses "Start a session" on the entry page itself. The page is served with `Referrer-Policy: no-referrer`, so the browser sends that form POST with `Origin: null`, and the spec's origin check would answer 403 to everyone; the 303 that follows goes to the editor's host, a form-submission redirect that Chrome checks against CSP `form-action`, which the spec's `'self'` blocks. The visitor expects to land in the editor. Pinned by `test_the_entry_pages_own_button_sends_origin_null_and_is_let_through` and the `form-action 'self' https://*.play.example.test` assertion in `test_every_page_carries_the_security_headers` (Task 6, Step 1), and by U1 (B1) starting from the entry page's button (Task 8, Step 3).
2. A visitor reloads an editor or app whose session has just ended (its TTL, `playctl end`, the idle timeout). They expect the "No session at this address" page at once, not a request that hangs until kamal-proxy or Cloudflare gives up: a pooled upstream connection to a vanished session hung for over 3 minutes in the probe. Pinned by `test_teardown_disconnects_every_attachment_before_removing_the_network` (Task 5, Step 1), R10 of the router check (Task 2, Step 1) and E11's "404 within 5 s after `playctl end`" (Task 7, Step 1).
3. The operator's first router deploy with the Origin CA certificate. The spec's `.kamal/secrets` line `$(cat "${PLAY_ORIGIN_CERT:-/dev/null}")` is mangled by Kamal 2.12's parser (it substitutes `${PLAY_ORIGIN_CERT` and leaves `:-/dev/null}`), so the certificate secret comes out empty and the deploy fails. The operator expects the PEM from the file to reach kamal-proxy. Pinned by D8 and D9 of the deployment check (Task 9, Step 1), which load the secrets through Kamal 2.12 itself.
4. Cloudflare's published IPv4 list has no final newline (15 ranges in October 2026). The spec's `while read -r range` loop skips the last one (`131.0.72.0/22`), so visitors whose Cloudflare edge uses that range time out at the origin. The operator expects every listed range to be let in. Pinned by D5 of the deployment check, a firewall dry run on a list without a final newline (Task 9, Step 1).
5. A visitor presses Start, lands in the editor and presses Back. A browser that restores the entry page from its back-forward cache (recent Chrome may, even for this `no-store` page, since it sets no cookie) shows the button still disabled and reading "Starting…", which looks like a hung service. The visitor expects a usable button. Pinned by the `pageshow` handler in `BUTTON_SCRIPT` (Task 6, Step 3) and U5, the Back step of the browser checklist (Task 8, Step 3).

---

### Task 1: The session image (`web` stage) and its smoke test

**Files:**
- Create: `playground/web-smoke.sh`
- Create: `playground/web/playground-web` (git mode 100755), `playground/web/settings.json`, `playground/web/tasks.json`, `playground/web/PLAYGROUND.md`
- Modify: `playground/Dockerfile` (append the `web` stage after the last line, `CMD ["playground-server"]`)
- Modify: `playground/playground-server` (the URL choice, lines 21-25; the banner, lines 52-62)
- Test: `bash playground/web-smoke.sh cybertrain-playground-web:local` (W1-W13); `bash playground/smoke.sh cybertrain-playground:local` (SP1's 29 checks, unchanged)

**Interfaces:**
- Consumes: SP1's image layout (user `dev` 1000, `/workspace/blog` built, `/opt/cybertrain-cache`, `/usr/local/bin/playground-server`, stage `playground`); `cybertrain/version.rb` (`0.2.1`), which `web-smoke.sh` reads.
- Produces: the images `cybertrain-playground-web:local` (target `web`) and `cybertrain-playground:local` (target `playground`); `bash playground/web-smoke.sh IMAGE` printing `PASS`/`FAIL <ID> …` lines for W1-W13 and `web-smoke: N passed, M failed` (exit 0, 1, or 2 without IMAGE), whose block between `# BEGIN hardened run` and `# END hardened run` Task 4's drift test compares with `Play::Templates.hardening`; the entrypoint's contract (`VSCODE_PROXY_URI` required, `PLAYGROUND_ENDS_AT` and `PLAYGROUND_IDLE_TIMEOUT` optional, code-server on 8080, the app on 3000 from `CYBERTRAIN_HOST=0.0.0.0`, `WORKDIR /workspace`); the banner lines `  App    <url>` and `  Ends   in <n> minute(s) (<HH:MM> UTC): the session and its files are deleted then.`. Report the outcome of V5-V8 (W5-W13 settle them); if a tmpfs needed another option (for example `exec`), say so: Task 4 copies the hardened block as you commit it.

Notes on the spec's text, applied below:
- Correction (spec §15, correction 1): the stage ends with `WORKDIR /workspace`, not `/workspace/blog`: under `--tmpfs /workspace` runc creates a missing working directory on the empty tmpfs, root-owned, before the entrypoint runs, which then skipped the seed and left `dev` unable to write. The entrypoint now tests for `/workspace/blog/spin.toml` instead of an empty `/workspace` and stops with a clear message if `/workspace/blog` exists but is not writable, and W6 checks a session started with the control plane's flags has a seeded, dev-owned, writable `/workspace/blog`.
- Correction: the two checksums are filled in (the GitHub release API's `digest` of `code-server-4.139.1-linux-amd64.tar.gz`, 222,167,474 bytes, and `…-linux-arm64.tar.gz`, 216,952,063 bytes, read on 2026-10-02). The build's `sha256sum -c` verifies the download.
- Correction: `RUN mkdir .vscode` before copying `tasks.json`, so that `dev` owns the directory (VS Code writes `.vscode/settings.json` there when a visitor changes a workspace setting); a directory created by `COPY --chown` is not guaranteed to get the owner.
- `web-smoke.sh`: the image's `ENTRYPOINT` ignores arguments, so one-shot checks use `--entrypoint`. W11 tries to write `/opt/cybertrain` (dev's own directory: only the read-only root stops it) instead of the spec's `/usr/local/bin` (unwritable by `dev` even on a writable root, so it proved nothing). W12 and W13 also require that the session answered `/healthz` and lived at least 50 and 55 seconds, otherwise a session that crashed at start would pass. The main session starts with the control plane's flags except `--rm` (its logs are kept for the summary), the labels and the names.
- `playground-server`: "1 minute" in the singular; a past end shows 0 minutes.

- [ ] **Step 1: Write the failing test**

Create `playground/web-smoke.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# playground/web-smoke.sh IMAGE -- the smoke test of the hosted playground's
# session image (playground/Dockerfile, target web). CI runs it before the
# image is pushed (.github/workflows/playground-image.yml, job web); after a
# local build:
#
#   bash playground/web-smoke.sh cybertrain-playground-web:local
#
# One line per check, "PASS <ID> <what>" or "FAIL <ID> <what> (<detail>)",
# then "web-smoke: N passed, M failed". After a failure it prints the last 40
# lines of every container or command involved and exits 1; it exits 0 when
# every check passes and 2 without an IMAGE. playground/README.md lists the
# checks (W1-W13).
#
# The session runs as the control plane runs it: with the flags between
# "# BEGIN hardened run" and "# END hardened run" (Play::Templates.hardening;
# playground/control/test/drift_test.rb compares the two) on an --internal
# network of its own, where a helper container of the same image plays the
# router. RUNTIME=runsc adds --runtime runsc (gVisor, playground/deploy/README.md).
#
# The host needs bash 3.2 or newer and docker (HTTP goes through the helper's
# curl). Every container and the network it creates are removed when it exits.
set -u

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: bash playground/web-smoke.sh IMAGE" >&2
  exit 2
fi
image=$1
here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n 's/^ *VERSION = "\([^"]*\)".*/\1/p' "$here/../cybertrain/version.rb" | head -n 1)
cs_version=$(sed -n 's/^ARG CODE_SERVER_VERSION=//p' "$here/Dockerfile" | head -n 1)
if [ -z "$version" ] || [ -z "$cs_version" ]; then
  echo "web-smoke: no VERSION in cybertrain/version.rb or no CODE_SERVER_VERSION in playground/Dockerfile" >&2
  exit 2
fi

prefix="playground-web-smoke-$$"
net="$prefix-net"
helper="$prefix-helper"
main="$prefix-main"
work=$(mktemp -d "${TMPDIR:-/tmp}/playground-web-smoke.XXXXXX") || exit 2
containers=""
watchers=""
network_made=no
passed=0
failed=0
show=""
out=""
rc=0
detail=""
# The preview id the banner must show (any 32 hex digits will do).
preview=0123456789abcdef0123456789abcdef
proxy_uri="https://{{port}}-$preview.example.test"

runtime=()
if [ -n "${RUNTIME:-}" ]; then
  runtime=(--runtime "$RUNTIME")
fi

# BEGIN hardened run
hardened=(
  --user 1000:1000
  --cap-drop ALL
  --security-opt no-new-privileges
  --read-only
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=256m,mode=1777
  --tmpfs /home/dev:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0755
  --tmpfs /workspace:rw,exec,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=0755
  --tmpfs /opt/cybertrain-cache:rw,nosuid,nodev,size=64m,uid=1000,gid=1000,mode=0755
  --memory 1536m --memory-swap 1536m
  --cpus 1
  --pids-limit 512
)
# END hardened run
# The four tmpfs sizes above, in 1K blocks, as df reports them (W11).
tmpfs_sizes="/tmp=262144 /home/dev=131072 /workspace=262144 /opt/cybertrain-cache=65536"

cleanup() {
  if [ -n "$watchers" ]; then
    kill $watchers > /dev/null 2>&1
  fi
  # One container name per word: the unquoted expansion is intended.
  if [ -n "$containers" ]; then
    docker rm -f $containers > /dev/null 2>&1
  fi
  if [ "$network_made" = yes ]; then
    docker network rm "$net" > /dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

what_W1="code-server --version is $cs_version"
what_W2="user dev (uid 1000), cybertrain $version, CYBERTRAIN_HOST=0.0.0.0 and EXTENSIONS_GALLERY={}"
what_W3="the blog is clean with one commit, PLAYGROUND.md is the hosted guide, .vscode/tasks.json is git-ignored and runs on folderOpen"
what_W4="the seed equals /workspace and /opt/cybertrain-cache, build/bin/blog's mtime included"
what_W5="hardened, code-server answers /healthz to another container on the session network"
what_W6="started as the control plane starts it, /workspace/blog is the seeded copy, owned by dev, writable, with build/bin/blog's mtime (nothing compiles)"
what_W7="code-server's user settings are installed (task.allowAutomaticTasks on)"
what_W8="playground-server serves /articles to the network on port 3000 and its banner shows the preview URL and the end"
what_W9="on the read-only root a model edit rebuilds the app: a short body then answers 422"
what_W10="with no network, cybertrain new and a build work in /workspace"
what_W11="read-only root, no capabilities, no new privileges, four tmpfs mounts of the set sizes"
what_W12="a session past PLAYGROUND_ENDS_AT stops and is removed by itself"
what_W13="with no browser ever, code-server's idle timeout ends the session"

pass() {
  passed=$((passed + 1))
  echo "PASS $1 $2"
}

# fail ID WHAT DETAIL [WHERE]: WHERE is a container name, out:ID for the saved
# output of `run_once ... ID`, or srv for the dev server's log in the main
# session; its last lines are printed at the end.
fail() {
  failed=$((failed + 1))
  echo "FAIL $1 $2 ($3)"
  if [ "$#" -ge 4 ]; then
    case " $show " in
      *" $4 "*) ;;
      *) show="$show $4" ;;
    esac
  fi
}

first_line() {
  printf '%s\n' "$1" | head -n 1
}

# run_once SECONDS ID [docker run options] IMAGE [COMMAND...]: a one-shot
# container (docker run --rm, named $prefix-ID) given at most SECONDS. Sets
# $out (its stdout and stderr, also in $work/ID.out) and $rc (its exit
# status; 124 when it ran out of time and was removed).
run_once() {
  local limit=$1 id=$2
  shift 2
  local name="$prefix-$id"
  local log="$work/$id.out"
  local began=$SECONDS
  containers="$containers $name"
  docker run --rm --name "$name" "$@" < /dev/null > "$log" 2>&1 &
  local pid=$!
  rc=""
  while kill -0 "$pid" 2> /dev/null; do
    if [ $((SECONDS - began)) -ge "$limit" ]; then
      docker rm -f "$name" > /dev/null 2>&1
      wait "$pid" 2> /dev/null
      echo "(timed out after $limit s)" >> "$log"
      rc=124
      break
    fi
    sleep 0.5
  done
  if [ -z "$rc" ]; then
    wait "$pid"
    rc=$?
  fi
  out=$(cat "$log")
}

# start ID [docker run options] IMAGE [COMMAND...]: a detached container named
# $prefix-ID, run with --init. Returns docker run's exit status; its output is
# in $work/ID.start.
start() {
  local id=$1
  shift
  containers="$containers $prefix-$id"
  docker run -d --init --name "$prefix-$id" "$@" > "$work/$id.start" 2>&1
}

# session ID ALIAS [docker run options]: a session as the control plane runs
# one, on the test network under the network alias ALIAS.
session() {
  local id=$1 alias=$2
  shift 2
  start "$id" --pull never --hostname playground --network "$net" --network-alias "$alias" \
    "${hardened[@]}" --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
    ${runtime[@]+"${runtime[@]}"} -e "VSCODE_PROXY_URI=$proxy_uri" "$@" "$image"
}

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null)" = "true" ]
}

gone() {
  [ -z "$(docker ps -aq --filter "name=^$1\$" 2> /dev/null)" ]
}

# HTTP status of a GET from the helper container (the router's place).
status_of() {
  docker exec "$helper" curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2> /dev/null
}

# watch ID ALIAS LIMIT: in the background, notes in $work/ID.watch whether
# the session ALIAS ever answered /healthz and how many seconds after its
# start it was gone, or "timeout" after LIMIT seconds.
watch() {
  local id=$1 alias=$2 limit=$3
  (
    began=$SECONDS
    healthy=no
    while [ $((SECONDS - began)) -lt "$limit" ]; do
      if [ "$healthy" = no ] && [ "$(status_of "http://$alias:8080/healthz")" = 200 ]; then
        healthy=yes
      fi
      if gone "$prefix-$id"; then
        echo "gone $((SECONDS - began)) healthy $healthy" > "$work/$id.watch"
        exit 0
      fi
      sleep 2
    done
    echo "timeout $limit healthy $healthy" > "$work/$id.watch"
  ) &
  watchers="$watchers $!"
}

echo "web-smoke: $image, expecting code-server $cs_version and cybertrain $version"

# ---- the image as built (W1-W4) --------------------------------------------

run_once 30 W1 --entrypoint code-server "$image" --version
got=$(printf '%s\n' "$out" | grep -m 1 '^[0-9]' | cut -d ' ' -f 1)
if [ "$rc" = 0 ] && [ "$got" = "$cs_version" ]; then
  pass W1 "$what_W1"
else
  fail W1 "$what_W1" "exit $rc: $(first_line "$out")" out:W1
fi

run_once 30 W2 --entrypoint bash "$image" -c 'echo "user=$(id -un):$(id -u) cli=[$(cybertrain version)] host=${CYBERTRAIN_HOST-unset} gallery=${EXTENSIONS_GALLERY-unset}"'
case "$out" in
  *"user=dev:1000 cli=[cybertrain $version] host=0.0.0.0 gallery={}"*) pass W2 "$what_W2" ;;
  *) fail W2 "$what_W2" "got: $(first_line "$out")" out:W2 ;;
esac

run_once 30 W3 --entrypoint bash "$image" -c 'cd /workspace/blog && echo "status=[$(git status --porcelain)] commits=$(git rev-list --count HEAD) guide=$(grep -c "ends at the time the terminal shows" PLAYGROUND.md) ignored=$(git check-ignore -q .vscode/tasks.json && echo yes || echo no) folderOpen=$(grep -c "\"runOn\": \"folderOpen\"" .vscode/tasks.json)"'
case "$out" in
  *"status=[] commits=1 guide=1 ignored=yes folderOpen=1"*) pass W3 "$what_W3" ;;
  *) fail W3 "$what_W3" "got: $(first_line "$out")" out:W3 ;;
esac

run_once 60 W4 --entrypoint bash "$image" -c 'diff -r /workspace /opt/cybertrain-web/seed/workspace > /tmp/w.diff 2>&1; w=$?; diff -r /opt/cybertrain-cache /opt/cybertrain-web/seed/cybertrain-cache > /tmp/c.diff 2>&1; c=$?; a=$(stat -c %Y /workspace/blog/build/bin/blog); b=$(stat -c %Y /opt/cybertrain-web/seed/workspace/blog/build/bin/blog); echo "workspace=$w cache=$c mtime=$([ "$a" = "$b" ] && echo same || echo "$a/$b")"; head -n 5 /tmp/w.diff /tmp/c.diff'
case "$out" in
  *"workspace=0 cache=0 mtime=same"*) pass W4 "$what_W4" ;;
  *) fail W4 "$what_W4" "got: $(first_line "$out")" out:W4 ;;
esac

# The prebuilt binary's mtime, which W6 compares against.
run_once 30 mtime --entrypoint stat "$image" -c %Y /workspace/blog/build/bin/blog
image_mtime=$(printf '%s\n' "$out" | grep -m 1 '^[0-9][0-9]*$')

# ---- a hardened session on its own --internal network (W5-W13) -------------

if docker network create --internal "$net" > "$work/net.out" 2>&1; then
  network_made=yes
fi
helper_ok=no
if [ "$network_made" = yes ] && start helper --network "$net" --entrypoint sleep "$image" infinity; then
  helper_ok=yes
fi

# W12 and W13 wait for minutes: they start first and are judged at the end.
w12=skipped
w13=skipped
if [ "$helper_ok" = yes ]; then
  w12=failed
  if session w12 s-w12 --rm -e "PLAYGROUND_ENDS_AT=$(($(date +%s) + 5))"; then
    w12=yes
    watch w12 s-w12 120
  fi
  w13=failed
  if session w13 s-w13 --rm -e "PLAYGROUND_IDLE_TIMEOUT=61"; then
    w13=yes
    watch w13 s-w13 240
  fi
fi

main_up=no
if [ "$helper_ok" != yes ]; then
  detail="no test network or helper: $(first_line "$(cat "$work/net.out" "$work/helper.start" 2> /dev/null)")"
elif session main s-smoke -e "PLAYGROUND_ENDS_AT=$(($(date +%s) + 1800))"; then
  launched=$SECONDS
  detail="no 200 from /healthz within 30 s"
  while [ $((SECONDS - launched)) -lt 30 ]; do
    if [ "$(status_of http://s-smoke:8080/healthz)" = 200 ]; then
      main_up=yes
      took=$((SECONDS - launched))
      break
    fi
    if ! running "$main"; then
      detail="the container exited"
      break
    fi
    sleep 1
  done
else
  detail="docker run failed: $(first_line "$(cat "$work/main.start")")"
fi

if [ "$main_up" = yes ]; then
  pass W5 "$what_W5 (after $took s)"

  # The image's WORKDIR is /workspace itself: one below it would make runc
  # create it on the empty tmpfs, root-owned, before the entrypoint runs.
  seeded=$(docker exec "$main" bash -c 'echo "owner=$(stat -c %U /workspace/blog) spin=$(test -f /workspace/blog/spin.toml && echo yes) writable=$(test -w /workspace/blog && echo yes) mtime=$(stat -c %Y /workspace/blog/build/bin/blog)"' 2>&1)
  if [ -n "$image_mtime" ] && [ "$seeded" = "owner=dev spin=yes writable=yes mtime=$image_mtime" ]; then
    pass W6 "$what_W6"
  else
    fail W6 "$what_W6" "got: $seeded (image mtime ${image_mtime:-unknown})" "$main"
  fi

  settings=$(docker exec "$main" grep -c '"task.allowAutomaticTasks": "on"' /home/dev/.local/share/code-server/User/settings.json 2> /dev/null)
  if [ "$settings" = 1 ]; then
    pass W7 "$what_W7"
  else
    fail W7 "$what_W7" "grep counted ${settings:-nothing}" "$main"
  fi

  # The folderOpen task's command, started the way a terminal would.
  docker exec -d -u 1000:1000 "$main" bash -lc 'playground-server > /tmp/s.log 2>&1'
  served=no
  began=$SECONDS
  while [ $((SECONDS - began)) -lt 30 ]; do
    if [ "$(status_of http://s-smoke:3000/articles)" = 200 ]; then
      served=yes
      break
    fi
    sleep 1
  done
  banner=$(docker exec "$main" cat /tmp/s.log 2> /dev/null)
  case "$banner" in
    *"App    https://3000-$preview.example.test/"*) app_line=yes ;;
    *) app_line=no ;;
  esac
  if printf '%s\n' "$banner" | grep -Eq '^  Ends   in [0-9]+ minutes? \([0-9]{2}:[0-9]{2} UTC\): the session and its files are deleted then\.$'; then
    ends_line=yes
  else
    ends_line=no
  fi
  if [ "$served" = yes ] && [ "$app_line" = yes ] && [ "$ends_line" = yes ]; then
    pass W8 "$what_W8"
  else
    fail W8 "$what_W8" "GET /articles 200 within 30 s: $served, App line: $app_line, Ends line: $ends_line" srv
  fi

  # SP1's A9, from the helper: a short body is refused once the model rebuilt.
  cat > "$work/short.sh" <<'EOF'
rm -f /tmp/jar /tmp/new.html
code=$(curl -s -c /tmp/jar -o /tmp/new.html -w '%{http_code}' --max-time 5 http://s-smoke:3000/articles/new)
token=$(sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p' /tmp/new.html | head -n 1)
if [ "$code" != 200 ] || [ -z "$token" ]; then
  echo "new=$code"
  exit 0
fi
curl -s -b /tmp/jar -o /dev/null -w 'post=%{http_code}' --max-time 5 \
  --data-urlencode "authenticity_token=$token" \
  --data-urlencode "article[title]=Short body $(date +%s)" \
  --data-urlencode "article[body]=short" \
  http://s-smoke:3000/articles
EOF
  docker exec "$main" sed -i 's/^class Article$/&\n  validates :body, presence: true, length: { minimum: 10 }/' /workspace/blog/app/models/article.rb
  edited=$(docker exec "$main" grep -c 'validates :body' /workspace/blog/app/models/article.rb 2> /dev/null)
  short=none
  began=$SECONDS
  while [ "${edited:-0}" -ge 1 ] && [ $((SECONDS - began)) -lt 300 ]; do
    short=$(docker exec -i "$helper" sh -s < "$work/short.sh" 2> /dev/null)
    if [ "$short" = "post=422" ]; then
      break
    fi
    sleep 3
  done
  if docker exec "$main" grep -q 'Build succeeded' /tmp/s.log 2> /dev/null; then
    built=yes
  else
    built=no
  fi
  listed=$(status_of http://s-smoke:3000/articles)
  if [ "$short" = "post=422" ] && [ "$built" = yes ] && [ "$listed" = 200 ]; then
    pass W9 "$what_W9 (in $((SECONDS - began)) s)"
  else
    fail W9 "$what_W9" "validates :body lines: ${edited:-0}, last try: $short, Build succeeded logged: $built, GET /articles: $listed" srv
  fi

  new_app=$(docker exec "$main" timeout 420 bash -lc 'cd /workspace && cybertrain new shop > /tmp/new.log 2>&1 && cd shop && cybertrain spin build shop > /tmp/build.log 2>&1 && test -x build/bin/shop && echo NEW-APP-BUILT; tail -n 5 /tmp/new.log /tmp/build.log 2> /dev/null' 2>&1)
  case "$new_app" in
    *NEW-APP-BUILT*) pass W10 "$what_W10" ;;
    *) fail W10 "$what_W10" "$(printf '%s\n' "$new_app" | grep -v '^$' | tail -n 1)" "$main" ;;
  esac

  locked=$(docker exec "$main" bash -c 'if touch /opt/cybertrain/.smoke-probe 2> /tmp/t.err; then echo root=writable; elif grep -q "Read-only file system" /tmp/t.err; then echo root=read-only; else echo "root=$(cat /tmp/t.err)"; fi; awk "/^(CapEff|NoNewPrivs):/ {print \$1 \$2}" /proc/1/status; df -P -k /tmp /home/dev /workspace /opt/cybertrain-cache | awk "NR > 1 {print \$6 \"=\" \$2}"' 2>&1)
  missing=""
  for want in root=read-only CapEff:0000000000000000 NoNewPrivs:1 $tmpfs_sizes; do
    if ! printf '%s\n' "$locked" | grep -qxF "$want"; then
      missing="$missing $want"
    fi
  done
  if [ -z "$missing" ]; then
    pass W11 "$what_W11"
  else
    fail W11 "$what_W11" "missing:$missing; got: $(printf '%s' "$locked" | tr '\n' ' ')" "$main"
  fi
else
  fail W5 "$what_W5" "$detail" "$main"
  for id in W6 W7 W8 W9 W10 W11; do
    name="what_$id"
    fail "$id" "${!name}" "skipped: the session did not answer"
  done
fi

# ---- the two sessions that end by themselves --------------------------------

wait $watchers 2> /dev/null
watchers=""
# W12 ends at PLAYGROUND_ENDS_AT + 60 s (about 65 s after its start); W13 at
# its 61 s idle timeout once code-server is up. Leaving much sooner means the
# session crashed instead.
for check in "W12 w12 50 90 $w12" "W13 w13 55 240 $w13"; do
  set -- $check
  id=$1 name=$2 earliest=$3 latest=$4 started=$5
  what="what_$id"
  if [ "$started" = skipped ]; then
    fail "$id" "${!what}" "skipped: no test network or helper"
    continue
  elif [ "$started" = failed ]; then
    fail "$id" "${!what}" "docker run failed: $(first_line "$(cat "$work/$name.start" 2> /dev/null)")"
    continue
  fi
  result=$(cat "$work/$name.watch" 2> /dev/null)
  set -- $result
  if [ "${1:-}" = gone ] && [ "${4:-}" = yes ] && [ "$2" -ge "$earliest" ] && [ "$2" -le "$latest" ]; then
    pass "$id" "${!what} (after $2 s)"
  else
    fail "$id" "${!what}" "watch: ${result:-nothing}; expected gone after $earliest-$latest s, healthy first"
  fi
done

# ---- summary ---------------------------------------------------------------

echo "web-smoke: $passed passed, $failed failed"
if [ "$failed" -eq 0 ]; then
  exit 0
fi
for where in $show; do
  case "$where" in
    out:*)
      echo "--- output of ${where#out:} (last 40 lines)"
      tail -n 40 "$work/${where#out:}.out"
      ;;
    srv)
      echo "--- /tmp/s.log in the main session (last 40 lines)"
      docker exec "$main" tail -n 40 /tmp/s.log 2>&1
      ;;
    *)
      echo "--- docker logs $where (last 40 lines)"
      docker logs --tail 40 "$where" 2>&1
      ;;
  esac
done
exit 1
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/saeki/work/cybertrain
mkdir -p "$SDD/logs"
bash playground/web-smoke.sh; echo "exit=$?"
/bin/bash -n playground/web-smoke.sh && echo "parses with bash 3.2"
docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local . > "$SDD/logs/task1-build-sp1.log" 2>&1; echo "build exit=$?"
bash playground/web-smoke.sh cybertrain-playground:local > "$SDD/logs/task1-red.log" 2>&1; echo "exit=$?"
grep -E '^(web-smoke:|PASS)' "$SDD/logs/task1-red.log"; grep -c '^FAIL' "$SDD/logs/task1-red.log"; grep -n 'line [0-9]*:' "$SDD/logs/task1-red.log"
```

Run the build and the second smoke run in the background and poll their logs. Expected: `usage: bash playground/web-smoke.sh IMAGE` and `exit=2`; `parses with bash 3.2`; `build exit=0`; then `exit=1`, the lines `web-smoke: cybertrain-playground:local, expecting code-server 4.139.1 and cybertrain 0.2.1` and `web-smoke: 0 passed, 13 failed`, no `PASS` line, `13`, and no `line N:` error from bash. SP1's image has no code-server, no seed and no `CYBERTRAIN_HOST`, so every check fails (W12 and W13 fail once their sessions are judged, after at most 4 minutes).

- [ ] **Step 3: Write the files the stage copies**

Create `playground/web/settings.json` (spec §4.4, verbatim):

```jsonc
// code-server's User settings in the hosted playground (playground-web
// copies this file into the session's home). Lines marked "checked" were
// measured on code-server 4.139.1 / Code 1.139.1 in the VS Code web spike.
{
  // No first-run noise (checked).
  "workbench.startupEditor": "none",
  "workbench.secondarySideBar.defaultVisibility": "hidden",
  "workbench.welcomePage.walkthroughs.openOnInstall": false,
  "workbench.tips.enabled": false,
  "workbench.enableExperiments": false,
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "update.showReleaseNotes": false,
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,
  "extensions.ignoreRecommendations": true,
  "chat.disableAIFeatures": true,
  // .vscode/tasks.json starts the dev server when the folder opens. This is
  // application-scoped: a workspace file cannot set it (checked).
  "task.allowAutomaticTasks": "on",
  // Port 3000 opens in the editor's preview; other ports are not offered,
  // since only 3000 is routed (checked from a workspace file; from here: V9).
  "remote.portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "remote.otherPortsAttributes": { "onAutoForward": "ignore" },
  // A Ruby save is a ~1 minute rebuild: save on purpose (as in Codespaces).
  "files.autoSave": "off",
  // ERB views highlight as HTML with the built-in grammar (no extension).
  "files.associations": { "*.html.erb": "html" },
  // The guide opens rendered (V9).
  "workbench.editorAssociations": { "**/PLAYGROUND.md": "vscode.markdown.preview.editor" },
  "editor.minimap.enabled": false,
  "terminal.integrated.confirmOnKill": "never",
  "terminal.integrated.showExitAlert": false,
  "terminal.integrated.gpuAcceleration": "off",
  // Closing the tab loses nothing (the session runs on), so no "Leave site?".
  "window.confirmBeforeClose": "never"
}
```

Create `playground/web/tasks.json` (spec §4.5, verbatim):

```jsonc
// The hosted playground's dev server: started when the folder opens, in a
// terminal the visitor sees (the Codespaces image uses postAttachCommand
// instead). instancePolicy "silent": a page reload re-attaches the terminal
// and starts nothing (checked in the VS Code web spike).
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "cybertrain server",
      "type": "shell",
      "command": "playground-server",
      "isBackground": true,
      "problemMatcher": [],
      "presentation": {
        "reveal": "always",
        "panel": "dedicated",
        "focus": false,
        "clear": true,
        "showReuseMessage": false
      },
      "runOptions": {
        "runOn": "folderOpen",
        "instanceLimit": 1,
        "instancePolicy": "silent"
      }
    }
  ]
}
```

Create `playground/web/PLAYGROUND.md` (spec §4.8, verbatim):

````markdown
# cybertrain playground

This is the blog from the cybertrain tutorial, already set up: `cybertrain new blog`,
the article scaffold, the root route and the first migration (tutorial steps 02, 03,
04 and 07). The development server runs in the terminal below and the preview shows
the app.

This session ends at the time the terminal shows, and everything in it is deleted
then. To keep a file or a folder, right-click it in the Explorer and choose Download.

The preview does not reload by itself: after a change, press its reload button.

## Try this

1. **Edit a view.** Change the `<h1>` in `app/views/articles/index.html.erb`, save,
   reload the preview. Views are read from disk on every request, so there is
   nothing to build.
2. **Add a validation.** In `app/models/article.rb`, add this line inside the class
   and save:

   ```ruby
   validates :body, presence: true, length: { minimum: 10 }
   ```

   Ruby is compiled, so the terminal shows a rebuild. After about a minute the
   server restarts by itself: an article with a short body now fails with "Body is
   too short (minimum is 10 characters)". If a change does not compile, the previous
   build keeps serving and every page shows the compiler's message at the top.
3. **Carry on with the tutorial** from step 08, "Scaffold comments":
   https://saeki-mototsune.github.io/CyberTrain/tutorial.html#scaffold-comment
   Stop the server first (Ctrl-C in its terminal), run the step's commands in a new
   terminal, then start it again with `cybertrain server`.

The Source Control view shows what you changed: the app is a git repository with
one commit.

## Start a fresh app

```sh
cd ..
cybertrain new shop && cd shop
cybertrain g scaffold product name:string
cybertrain db migrate
cybertrain server
```

Stop the blog's server first: both use port 3000. `cybertrain new` needs no network
here, and the first `cybertrain server` of a new app compiles it (about a minute).
The new app has no root route, so `/` shows "Not Found": its pages start at
`/products`.

## Good to know

- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab.
  Inside the preview, pop-ups and `confirm()` dialogs do not work.
- The session has no network: `gem install`, `curl` to the internet and `git push`
  do not work. Only port 3000 can be previewed.
- Anyone with this page's address can use this session, terminal included: do not
  share it. The preview's address shows only the app.
- Closing the tab ends the session a few minutes later.
- Everything else is in the README: https://github.com/saeki-mototsune/cybertrain#readme
````

Its "Try this" and "Start a fresh app" sections must equal SP1's guide word for word:

```bash
sed -n '/^## Try this/,/^## Good to know/p' playground/PLAYGROUND.md > "$SDD/scratch/guide-sp1.md"
sed -n '/^## Try this/,/^## Good to know/p' playground/web/PLAYGROUND.md > "$SDD/scratch/guide-web.md"
diff "$SDD/scratch/guide-sp1.md" "$SDD/scratch/guide-web.md" && echo "common sections identical"
```

Expected: `common sections identical`.

Create `playground/web/playground-web` (spec §4.6 with the correction above), then `chmod 755 playground/web/playground-web`:

```bash
#!/usr/bin/env bash
# playground-web -- the entrypoint of the hosted playground's session image
# (playground/Dockerfile, stage web).
#
# The control plane (playground/control) runs the image with a read-only root
# file system and empty tmpfs mounts on /workspace, /opt/cybertrain-cache,
# /home/dev and /tmp, and sets
#   VSCODE_PROXY_URI         https://{{port}}-<preview id>.<domain>: where the
#                            editor's preview and Ports view open a port
#   PLAYGROUND_ENDS_AT       the session's end, in seconds since the epoch
#   PLAYGROUND_IDLE_TIMEOUT  seconds without a browser before code-server
#                            exits (more than 60; default 300)
# This script fills the tmpfs mounts from the image's seed, installs
# code-server's user settings, schedules two notices in the terminals and
# execs code-server, bounded by the session's end: the container stops (and
# --rm removes it) even when the control plane is not there to do it.
#
# By hand, for a look without the rest of the service (no time limit; the
# idle timeout still ends it about 6 minutes after the last tab closes):
#   docker run --rm -it --init -p 127.0.0.1:8080:8080 -p 127.0.0.1:3000:3000 \
#     -e 'VSCODE_PROXY_URI=http://localhost:{{port}}' cybertrain-playground-web:local
# then open http://localhost:8080/?folder=/workspace/blog
set -eu

seed=/opt/cybertrain-web/seed
ends_at=${PLAYGROUND_ENDS_AT:-}
idle=${PLAYGROUND_IDLE_TIMEOUT:-300}
case "$ends_at" in *[!0-9]*) echo "playground-web: PLAYGROUND_ENDS_AT is not a number" >&2; exit 2 ;; esac
case "$idle" in ''|*[!0-9]*) echo "playground-web: PLAYGROUND_IDLE_TIMEOUT is not a number" >&2; exit 2 ;; esac

# 1. The writable state. Empty tmpfs mounts get the image's copy (cp -a keeps
#    the times spin compares, so nothing rebuilds); a run without them finds
#    the image's own blog in place and copies nothing. A /workspace/blog that
#    exists but is not dev's means the image's WORKDIR lies inside the tmpfs
#    (runc made it, root-owned): say so instead of failing later.
if [ ! -e /workspace/blog/spin.toml ]; then
  if [ -e /workspace/blog ] && [ ! -w /workspace/blog ]; then
    echo "playground-web: /workspace/blog exists but is not writable (is the image's WORKDIR inside /workspace?)" >&2
    exit 1
  fi
  cp -a "$seed/workspace/." /workspace/
fi
if [ -z "$(ls -A /opt/cybertrain-cache)" ]; then cp -a "$seed/cybertrain-cache/." /opt/cybertrain-cache/; fi
if [ -z "$(ls -A "$HOME")" ]; then cp -a /etc/skel/. "$HOME/"; fi

# 2. code-server's user settings: task.allowAutomaticTasks and the other
#    application-scoped settings take effect only from here.
user_dir="$HOME/.local/share/code-server/User"
mkdir -p "$user_dir"
[ -e "$user_dir/settings.json" ] || cp /opt/cybertrain-web/settings.json "$user_dir/settings.json"

# 3. A notice in every open terminal 5 minutes and 1 minute before the end.
#    Writing to a terminal's device prints on its screen; it is not input.
#    Double fork: tini (--init) reaps the notifier, not code-server's timeout.
notice() {
  local tty
  for tty in /dev/pts/[0-9]*; do
    [ -w "$tty" ] && printf '\r\n\033[1;33m[playground] %s\033[0m\r\n' "$1" > "$tty" 2>/dev/null || true
  done
}
notice_at() { # SECONDS_BEFORE_THE_END MESSAGE
  local wait=$(( ends_at - $1 - $(date +%s) ))
  if [ "$wait" -gt 0 ]; then sleep "$wait"; notice "$2"; fi
}
if [ -n "$ends_at" ]; then
  ( ( notice_at 300 "This session ends in 5 minutes: it is deleted with its files. Download what you want to keep."
      notice_at 60 "This session ends in 1 minute." ) & )
fi

# 4. code-server. The router sends the preview straight to port 3000, so
#    code-server's own port proxy stays off.
args=(--bind-addr 0.0.0.0:8080 --auth none
      --disable-telemetry --disable-update-check --disable-workspace-trust
      --disable-getting-started-override --disable-proxy --disable-file-uploads
      --idle-timeout-seconds "$idle"
      /workspace/blog)
if [ -n "$ends_at" ]; then
  left=$(( ends_at + 60 - $(date +%s) ))
  [ "$left" -gt 0 ] || exit 0
  exec timeout --kill-after=10 "$left" code-server "${args[@]}"
fi
exec code-server "${args[@]}"
```

- [ ] **Step 4: Append the `web` stage to `playground/Dockerfile`**

Append exactly this after the file's last line (`CMD ["playground-server"]`), keeping one empty line between them:

```dockerfile

# ---------------------------------------------------------------------------
# The hosted playground's session image (SP2): the playground stage plus
# code-server. Only the control plane runs it (playground/control): a
# read-only root file system, empty tmpfs mounts on /tmp, /home/dev,
# /workspace and /opt/cybertrain-cache, and no network but its own internal
# one. Nothing here changes the playground stage, which Codespaces runs.
#
#   docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
FROM playground AS web

ARG TARGETARCH
ARG CODE_SERVER_VERSION=4.139.1
# sha256 of code-server-<version>-linux-<arch>.tar.gz on the GitHub release
# (the release API's "digest" of each asset).
ARG CODE_SERVER_SHA256_AMD64=53029be6c5781b7bca49b815fcc9a2a3fc111813ad8c9965b2c0f0d2985a0674
ARG CODE_SERVER_SHA256_ARM64=0edb4b60d9c4744b2dd14b0911e3c2e6dd8c6f3c13bd58bda23ae744e59e7df1

USER root
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) sum="$CODE_SERVER_SHA256_AMD64" ;; \
      arm64) sum="$CODE_SERVER_SHA256_ARM64" ;; \
      *) echo "playground/Dockerfile: no code-server for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    tarball="code-server-${CODE_SERVER_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSL -o "/tmp/$tarball" \
        "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/$tarball"; \
    echo "$sum  /tmp/$tarball" | sha256sum -c -; \
    mkdir /usr/lib/code-server; \
    tar -xzf "/tmp/$tarball" -C /usr/lib/code-server --strip-components 1 --no-same-owner; \
    rm "/tmp/$tarball"; \
    ln -s /usr/lib/code-server/bin/code-server /usr/local/bin/code-server; \
    test "$(HOME=/tmp/cs-home code-server --version | head -n 1 | cut -d ' ' -f 1)" = "$CODE_SERVER_VERSION"; \
    rm -rf /tmp/cs-home

# code-server's user settings (the entrypoint copies them into the session's
# home) and the session's entrypoint.
COPY playground/web/settings.json /opt/cybertrain-web/settings.json
COPY --chmod=0755 playground/web/playground-web /usr/local/bin/playground-web
# The router reaches the dev server at the session's own address, so the app
# listens on every interface (only the router shares the session's network).
# An empty gallery: an install could not download anything here (no network),
# and the visitor's browser then contacts no extension marketplace.
ENV CYBERTRAIN_HOST=0.0.0.0 \
    EXTENSIONS_GALLERY={}

USER dev
WORKDIR /workspace/blog
# The folderOpen task that starts the server in a visible terminal. It is the
# playground's, not the visitor's, so Source Control does not show it. The
# directory is made first so that dev owns it.
RUN mkdir .vscode
COPY --chown=dev:dev playground/web/tasks.json .vscode/tasks.json
# This environment's guide replaces the Codespaces one inside the one commit.
COPY --chown=dev:dev playground/web/PLAYGROUND.md PLAYGROUND.md
RUN echo '/.vscode/' >> .git/info/exclude \
 && git add PLAYGROUND.md \
 && git -c user.name="cybertrain playground" -c user.email="playground@cybertrain.invalid" \
        commit -q --amend --no-edit \
 && test -z "$(git status --porcelain)" \
 && test "$(git rev-list --count HEAD)" = 1

# What the entrypoint copies into the empty tmpfs mounts. cp -a keeps file
# times, so the copy is as fresh as the build (spin compares mtimes).
USER root
RUN mkdir -p /opt/cybertrain-web/seed \
 && cp -a /workspace /opt/cybertrain-web/seed/workspace \
 && cp -a /opt/cybertrain-cache /opt/cybertrain-web/seed/cybertrain-cache

USER dev
# The mount point itself, never a directory below it: a WORKDIR inside the
# /workspace tmpfs would make runc create it there, root-owned and empty,
# before the entrypoint runs, and the seed copy would then be skipped.
WORKDIR /workspace
EXPOSE 8080 3000
ENTRYPOINT ["/usr/local/bin/playground-web"]
CMD []
```

- [ ] **Step 5: Teach `playground-server` the hosted playground's URL and end time**

Three edits to `playground/playground-server`; line numbers are those of the file before this step (the quoted text is what counts). Replace lines 21-25:

```bash
if [ "${CODESPACES:-}" = "true" ] && [ -n "${CODESPACE_NAME:-}" ]; then
  url="https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/"
else
  url="http://localhost:${port}/"
fi
```

with:

```bash
if [ "${CODESPACES:-}" = "true" ] && [ -n "${CODESPACE_NAME:-}" ]; then
  url="https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/"
elif [[ -n "${VSCODE_PROXY_URI:-}" && "${VSCODE_PROXY_URI}" == *'{{port}}'* ]]; then
  # code-server (the hosted playground): its address for a port.
  url="${VSCODE_PROXY_URI//'{{port}}'/$port}"
  url="${url%/}/"
else
  url="http://localhost:${port}/"
fi
```

and replace the banner (lines 52-62, from `cat <<EOF` to its `EOF`):

```bash
cat <<EOF

  cybertrain playground
  App    ${url}
  Guide  ${app}/PLAYGROUND.md

  Views reload on the next request. A Ruby change rebuilds the app (about a
  minute), then the server restarts by itself. Reload the page to see either.
  Ctrl-C stops the server; run playground-server to start it again.

EOF
```

with:

```bash
# The hosted playground's control plane sets PLAYGROUND_ENDS_AT (seconds
# since the epoch): the banner says when the session and its files go.
ends=""
case "${PLAYGROUND_ENDS_AT:-}" in
  "" | *[!0-9]*) ;;
  *)
    left=$(( (PLAYGROUND_ENDS_AT - $(date +%s)) / 60 ))
    [ "$left" -ge 0 ] || left=0
    unit=minutes
    [ "$left" = 1 ] && unit=minute
    ends="  Ends   in ${left} ${unit} ($(date -u -d "@${PLAYGROUND_ENDS_AT}" +%H:%M) UTC): the session and its files are deleted then."
    ;;
esac

printf '\n  cybertrain playground\n  App    %s\n  Guide  %s\n' "$url" "${app}/PLAYGROUND.md"
if [ -n "$ends" ]; then
  printf '%s\n' "$ends"
fi
cat <<'EOF'

  Views reload on the next request. A Ruby change rebuilds the app (about a
  minute), then the server restarts by itself. Reload the page to see either.
  Ctrl-C stops the server; run playground-server to start it again.

EOF
```

and insert these two lines directly after line 11 (`#     started by hand is still compiling (about a minute after a Ruby edit).`), before `set -u`:

```bash
# In the hosted playground (playground/web) a VS Code task runs it when the
# folder opens; there VSCODE_PROXY_URI gives the app's URL.
```

Then `bash -n playground/playground-server && echo parses`. Expected: `parses`. The new branches act only when `VSCODE_PROXY_URI` holds `{{port}}` or `PLAYGROUND_ENDS_AT` is a number, so Codespaces and local Docker keep their banner (SP1's check C2 stays as it is).

- [ ] **Step 6: Build both targets**

```bash
cd /Users/saeki/work/cybertrain
test -d .git && git rev-parse --abbrev-ref HEAD
docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local . > "$SDD/logs/task1-build-web.log" 2>&1; echo "web exit=$?"
docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local . > "$SDD/logs/task1-build-playground.log" 2>&1; echo "playground exit=$?"
docker image inspect -f '{{.Config.WorkingDir}} {{json .Config.Entrypoint}} {{.Config.User}}' cybertrain-playground-web:local
```

Run the builds in the background. Do not run git commands in this checkout while a build reads `.git`. Expected: `web-playground-sp2`; `web exit=0` (the log shows `code-server-4.139.1-linux-arm64.tar.gz: OK` from `sha256sum -c`); `playground exit=0` (cached: the changed `playground-server` rebuilt the `playground` stage during the first build); then `/workspace ["/usr/local/bin/playground-web"] dev`. If `sha256sum -c` fails, download the tarball by hand (`curl -fsSL -o "$SDD/scratch/cs.tgz" https://github.com/coder/code-server/releases/download/v4.139.1/code-server-4.139.1-linux-arm64.tar.gz && shasum -a 256 "$SDD/scratch/cs.tgz"`), compare with the release's digest (`gh api repos/coder/code-server/releases/tags/v4.139.1 --jq '.assets[] | select(.name | test("linux-(amd64|arm64).tar.gz$")) | .name + " " + .digest'`) and report: never replace a checksum with an unverified value.

- [ ] **Step 7: Run both smoke tests**

```bash
bash playground/web-smoke.sh cybertrain-playground-web:local > "$SDD/logs/task1-web-smoke.log" 2>&1; echo "exit=$?"
bash playground/smoke.sh cybertrain-playground:local > "$SDD/logs/task1-smoke.log" 2>&1; echo "exit=$?"
cat "$SDD/logs/task1-web-smoke.log"; tail -n 1 "$SDD/logs/task1-smoke.log"
```

Run them one after the other in the background (they compete for the CPU otherwise). Expected `web-smoke` output, in this order (the seconds vary):

```
web-smoke: cybertrain-playground-web:local, expecting code-server 4.139.1 and cybertrain 0.2.1
PASS W1 code-server --version is 4.139.1
PASS W2 user dev (uid 1000), cybertrain 0.2.1, CYBERTRAIN_HOST=0.0.0.0 and EXTENSIONS_GALLERY={}
PASS W3 the blog is clean with one commit, PLAYGROUND.md is the hosted guide, .vscode/tasks.json is git-ignored and runs on folderOpen
PASS W4 the seed equals /workspace and /opt/cybertrain-cache, build/bin/blog's mtime included
PASS W5 hardened, code-server answers /healthz to another container on the session network (after 4 s)
PASS W6 started as the control plane starts it, /workspace/blog is the seeded copy, owned by dev, writable, with build/bin/blog's mtime (nothing compiles)
PASS W7 code-server's user settings are installed (task.allowAutomaticTasks on)
PASS W8 playground-server serves /articles to the network on port 3000 and its banner shows the preview URL and the end
PASS W9 on the read-only root a model edit rebuilds the app: a short body then answers 422 (in 52 s)
PASS W10 with no network, cybertrain new and a build work in /workspace
PASS W11 read-only root, no capabilities, no new privileges, four tmpfs mounts of the set sizes
PASS W12 a session past PLAYGROUND_ENDS_AT stops and is removed by itself (after 68 s)
PASS W13 with no browser ever, code-server's idle timeout ends the session (after 64 s)
web-smoke: 13 passed, 0 failed
```

and `smoke: 29 passed, 0 failed` with `exit=0` for both. What the checks settle: W5, W8-W10 V5 (nothing writes outside the four tmpfs mounts), W6 V6 and §15's correction 1, W13 V7 (`/healthz` does not count as activity, so the idle timeout runs from code-server's start), W12 V8, W5-W11 V22.

If a check fails: read the summary's log tails and fix the cause within the spec's meaning (for example, if W10 or W9 fails because something executes from the `noexec` mounts `/home/dev` or `/opt/cybertrain-cache`, add `exec` to that tmpfs line inside the hardened block, which spec §5.4 foresees, and say so in your report). Never weaken a check.

- [ ] **Step 8: Commit**

```bash
git add playground/web-smoke.sh playground/web/playground-web playground/web/settings.json playground/web/tasks.json playground/web/PLAYGROUND.md playground/Dockerfile playground/playground-server
git ls-files -s playground/web/playground-web
git commit -m "Playground: the hosted playground's session image (web stage) and its smoke test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from `git ls-files -s`: mode `100755`.

---

### Task 2: The router

**Files:**
- Create: `playground/router/Caddyfile`
- Create: `playground/router/Dockerfile`, `playground/router/Dockerfile.dockerignore`
- Create: `playground/router/pages/ended.html`, `playground/router/pages/app-down.html`, `playground/router/pages/unavailable.html`
- Test: `$SDD/scratch/router-check.sh` (throwaway, not committed): R1-R10 against one real, hardened session

**Interfaces:**
- Consumes: `cybertrain-playground-web:local` from Task 1 (the check's session).
- Produces: the image `ctplay-router:local` and the router's contract, which Tasks 3, 7 and 9 rely on: it listens on port 80; reads `PLAY_DOMAIN`, `PLAY_PUBLIC_URL`, `PLAY_SUBNET_POOL`, optional `PLAY_CONTROL_UPSTREAM` (default `ctplay-control:9292`) and `ROUTER_LOG_OUTPUT` (default `discard`); runs with `--dns 127.0.0.1 --sysctl net.ipv4.ip_forward=0`; sends `<32 hex>.<domain>` to `s-<id>:8080` and `3000-<32 hex>.<domain>` to `p-<id>:3000` with the headers of spec §6.3, the apex to the control plane, `/up` to `OK`; answers an unknown or ended editor host (and `foo.`, `www.`, any other host) with 404 "No session at this address", a preview host without an app with 502 "No app is answering here", an apex whose control plane does not answer with 503 "The playground is not available right now", the apex's `/internal/*` with 404, and closes connections that come from `PLAY_SUBNET_POOL`.

Facts this task relies on (verified by probe on 2026-10-02, spec §15, on Caddy 2.10.2 at run time and 2.11.4 for validation, with stand-in sessions): the `header_regexp` capture works in the upstream address and in header values; Docker's embedded DNS resolves the `s-`/`p-` aliases for the router only while it shares the session's network; a WebSocket upgrade passes (101) and code-server's Origin check still refuses another origin (403); `remote_ip` plus `abort` closes connections from the pool; `--internal` with `inhibit_ipv4` keeps the session off the host. This task re-checks them on the real files and the real session image.

Notes on the spec's text, applied below:
- Correction (spec §15, correction 2): `@apex_error` matches only 5xx (`expression {err.status_code} >= 500`); the spec's matcher caught the apex's own `error 404` for `/internal/*` and answered 503 "unavailable".
- Correction (spec §15, correction 4): both session upstreams have `transport http { keepalive off }`, so a request to a session that has just ended (or a router just detached from it) gets the 404 page instead of hanging on a pooled connection.
- Correction (spec §15, corrections 3 and 6): the router runs with `--dns 127.0.0.1` (the ids of ended sessions would otherwise go to the host's resolver, and a slow one delays the 404 page by about 3 s) and `--sysctl net.ipv4.ip_forward=0`. They are run-time options, set in Task 7's compose file and Task 9's Kamal config; the Dockerfile's comment says so.
- The image is `caddy:2.11.4-alpine`, the newest 2.x on Docker Hub on 2026-10-02 (the spec named `2.10-alpine` and said to pin the newest 2.x patch at implementation). If that tag cannot be pulled, use the newest `2.11.x-alpine` that can and say so.

- [ ] **Step 1: Write the failing test**

Create `$SDD/scratch/router-check.sh` with exactly this content (the session runs with the control plane's flags; a Caddy `respond` stands in for the control plane):

```bash
#!/usr/bin/env bash
# router-check.sh -- throwaway check of playground/router against one real,
# hardened session (Task 2 of the SP2 plan; not committed). Needs the images
# ctplay-router:local and cybertrain-playground-web:local. Port 18081.
set -u
sid=0123456789abcdef0123456789abcdef
pid=fedcba9876543210fedcba9876543210
p=ctrcheck
host=play.localhost:18081
base=http://127.0.0.1:18081
work=$(mktemp -d "${TMPDIR:-/tmp}/router-check.XXXXXX")
passed=0
failed=0

cleanup() {
  docker rm -f $p-router $p-control $p-session > /dev/null 2>&1
  docker network rm $p-n $p-front > /dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

check() { # ID WHAT OK DETAIL
  if [ "$3" = yes ]; then passed=$((passed + 1)); echo "PASS $1 $2"; else failed=$((failed + 1)); echo "FAIL $1 $2 ($4)"; fi
}
get() { # HOST PATH -> $code, $work/body, $work/head
  code=$(curl -s -o "$work/body" -D "$work/head" -w '%{http_code}' --max-time 10 -H "Host: $1" "$base$2")
}
header() {
  grep -i "^$1:" "$work/head" | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//'
}
has() {
  if grep -qF -- "$1" "$work/body"; then echo yes; else echo no; fi
}

# The production network shape (spec §5.4) and a session started with the
# control plane's flags.
docker network create --driver bridge --internal --subnet 10.250.255.0/28 \
  --opt com.docker.network.bridge.inhibit_ipv4=true $p-n > /dev/null || exit 1
docker network create $p-front > /dev/null || exit 1
docker run -d --init --pull never --name $p-session --hostname playground --network $p-n \
  --network-alias s-$sid --network-alias p-$pid \
  --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=256m,mode=1777 \
  --tmpfs /home/dev:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0755 \
  --tmpfs /workspace:rw,exec,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=0755 \
  --tmpfs /opt/cybertrain-cache:rw,nosuid,nodev,size=64m,uid=1000,gid=1000,mode=0755 \
  --memory 1536m --memory-swap 1536m --cpus 1 --pids-limit 512 \
  -e "VSCODE_PROXY_URI=http://{{port}}-$pid.$host" -e "PLAYGROUND_ENDS_AT=$(($(date +%s) + 1800))" \
  cybertrain-playground-web:local > /dev/null || exit 1
docker run -d --name $p-control --network $p-front --network-alias ctplay-control --entrypoint caddy \
  ctplay-router:local respond --listen :9292 --body control-standin > /dev/null || exit 1
docker run -d --name $p-router --network $p-front --dns 127.0.0.1 --sysctl net.ipv4.ip_forward=0 -p 127.0.0.1:18081:80 \
  -e PLAY_DOMAIN=play.localhost -e "PLAY_PUBLIC_URL=http://$host" -e PLAY_SUBNET_POOL=10.250.0.0/16 \
  -e ROUTER_LOG_OUTPUT=stderr ctplay-router:local > /dev/null || exit 1
docker network connect $p-n $p-router || exit 1

up=no
for i in $(seq 1 40); do
  get "$sid.$host" /healthz
  if [ "$code" = 200 ]; then up=yes; break; fi
  sleep 1
done
ok=no
if [ "$up" = yes ] && [ "$(has '"status"')" = yes ] && [ "$(header referrer-policy)" = no-referrer ] &&
  [ "$(header x-robots-tag)" = "noindex, nofollow" ] && [ "$(header x-content-type-options)" = nosniff ] &&
  header content-security-policy | grep -qF "frame-ancestors 'self'"; then ok=yes; fi
check R1 "the editor host reaches code-server, with the editor's headers" "$ok" \
  "status $code, $(tr -d '\r' < "$work/head" | grep -iE '^(referrer|x-robots|x-content|content-security)' | tr '\n' ' ')"

ws() {
  curl -s -i -N --http1.1 --max-time 4 -H "Host: $sid.$host" -H "Origin: $1" -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "$base/?reconnectionToken=check-$$&reconnection=false&skipWebSocketFrames=false" 2> /dev/null | head -n 1 | tr -d '\r'
}
own=$(ws "http://$sid.$host")
other=$(ws "http://evil.localhost:18081")
ok=no
case "$own|$other" in *" 101 "*"|"*" 403"*) ok=yes ;; esac
check R2 "a WebSocket upgrade passes (101), and code-server still refuses another origin (403)" "$ok" "own: $own; other: $other"

docker exec -d -u 1000:1000 $p-session bash -lc 'playground-server > /tmp/s.log 2>&1'
for i in $(seq 1 30); do
  get "3000-$pid.$host" /articles
  [ "$code" = 200 ] && break
  sleep 1
done
ok=no
if [ "$code" = 200 ] && [ "$(header cache-control)" = no-store ] && [ "$(header x-robots-tag)" = "noindex, nofollow" ] &&
  [ -z "$(header x-content-type-options)" ] && header content-security-policy | grep -qF 'frame-ancestors *.play.localhost:*'; then ok=yes; fi
check R3 "the preview host reaches port 3000, with the preview's headers and no nosniff" "$ok" \
  "status $code, Cache-Control: $(header cache-control), CSP: $(header content-security-policy), nosniff: $(header x-content-type-options)"

get "3000-$sid.$host" /
ok=no
if [ "$code" = 502 ] && [ "$(has 'No app is answering here')" = yes ] && [ "$(has "href=\"http://$host/\"")" = yes ] &&
  [ "$(header cache-control)" = no-store ] && [ "$(header x-robots-tag)" = "noindex, nofollow" ] && [ "$(header referrer-policy)" = no-referrer ]; then ok=yes; fi
check R4 "a preview id with no session gets the 502 app-down page, templated, with the error headers" "$ok" "status $code"

get "ffffffffffffffffffffffffffffffff.$host" /
a=$code
a_page=$(has 'No session at this address')
a_link=$(has "href=\"http://$host/\"")
get "foo.$host" /
b=$code
get "www.$host" /
c=$code
ok=no
if [ "$a" = 404 ] && [ "$a_page" = yes ] && [ "$a_link" = yes ] && [ "$b" = 404 ] && [ "$c" = 404 ]; then ok=yes; fi
check R5 "an unknown editor id, foo. and www. get the 404 ended page" "$ok" "unknown: $a (page $a_page, link $a_link), foo: $b, www: $c"

get "$host" /
a=$code
a_body=$(has control-standin)
get "$host" /internal/sessions
b=$code
docker stop $p-control > /dev/null
get "$host" /
c=$code
c_page=$(has 'The playground is not available right now')
ok=no
if [ "$a" = 200 ] && [ "$a_body" = yes ] && [ "$b" = 404 ] && [ "$c" = 503 ] && [ "$c_page" = yes ]; then ok=yes; fi
check R6 "the apex goes to the control plane; /internal/* is 404; a stopped control plane gives the 503 page" "$ok" \
  "apex: $a, /internal/sessions: $b, control stopped: $c"

router_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$p-n\").IPAddress}}" $p-router)
docker exec -u 1000:1000 $p-session curl -s -o /dev/null --max-time 5 -H 'Host: play.localhost' "http://$router_ip/"
rc=$?
check R7 "a connection from the session to the router gets nothing (curl exit 52)" \
  "$([ "$rc" = 52 ] && echo yes)" "curl exit $rc"

front_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$p-front\").IPAddress}}" $p-router)
get "$front_ip" /up
check R8 "kamal-proxy's health check (Host = the container's address) gets OK" \
  "$([ "$code" = 200 ] && [ "$(has OK)" = yes ] && echo yes)" "status $code"

dns=$(docker inspect -f '{{.HostConfig.Dns}}' $p-router)
forward=$(docker exec $p-router cat /proc/sys/net/ipv4/ip_forward 2>&1)
check R9 "the router asks no outside resolver (--dns 127.0.0.1) and forwards no packets (ip_forward 0)" \
  "$([ "$dns" = "[127.0.0.1]" ] && [ "$forward" = 0 ] && echo yes)" "Dns: $dns, ip_forward: $forward"

# The control plane's teardown order: the container first, then the router's
# attachment, then the network. The editor must answer 404 at once.
docker rm -f $p-session > /dev/null
began=$SECONDS
get "$sid.$host" /healthz
took=$((SECONDS - began))
first=$code
docker network disconnect -f $p-n $p-router > /dev/null
get "$sid.$host" /healthz
second=$code
ok=no
if [ "$first" = 404 ] && [ "$took" -le 5 ] && [ "$second" = 404 ]; then ok=yes; fi
check R10 "right after the session is removed its editor answers the 404 page within 5 s, also after the detach" "$ok" \
  "after rm: $first in $took s, after disconnect: $second"

echo "router-check: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
  docker logs --tail 40 $p-router 2>&1
  exit 1
fi
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/saeki/work/cybertrain
docker build -f playground/router/Dockerfile -t ctplay-router:local . > "$SDD/logs/task2-red.log" 2>&1; echo "build exit=$?"; tail -n 2 "$SDD/logs/task2-red.log"
bash "$SDD/scratch/router-check.sh"; echo "exit=$?"
```

Expected: the build fails because `playground/router/Dockerfile` does not exist (the error names that path); the check stops at the first `docker run` that needs `ctplay-router:local` (`Unable to find image` / `pull access denied`) with `exit=1` and removes what it created.

- [ ] **Step 3: Write the Caddyfile**

Create `playground/router/Caddyfile` (spec §6.1 with §15's corrections 2 and 4, the text the probe ran):

```caddyfile
# playground/router/Caddyfile -- the hosted playground's router (SP2).
#
# kamal-proxy terminates TLS and hands this Caddy every request for
# {$PLAY_DOMAIN} and *.{$PLAY_DOMAIN} as plain HTTP (locally the browser
# talks to it directly). Nothing here changes per session: a session is
# reachable exactly while a container with the network alias s-<editor id>
# or p-<preview id> shares a network with this router (the control plane
# attaches it) and answers. Never reloaded: a reload would close every
# editor's WebSocket.
{
	admin off
	auto_https off
	persist_config off
	log default {
		output {$ROUTER_LOG_OUTPUT:discard}
		level ERROR
	}
}

:80 {
	# route keeps the written order (Caddy would otherwise sort handle
	# blocks with path matchers ahead of the others).
	route {
		# A session container can reach this router on its own network. It
		# gets nothing: not another session, not the control plane.
		@from_session remote_ip {$PLAY_SUBNET_POOL}
		handle @from_session {
			abort
		}

		@editor {
			host *.{$PLAY_DOMAIN}
			header_regexp editor Host ^([0-9a-f]{32})\.
		}
		handle @editor {
			header {
				defer
				Referrer-Policy no-referrer
				X-Robots-Tag "noindex, nofollow"
				X-Content-Type-Options nosniff
				+Content-Security-Policy "frame-ancestors 'self'"
			}
			# No pooled connections: a reused one to a session that has just
			# ended (or a router just detached from it) would hang instead
			# of answering the "No session" page.
			reverse_proxy s-{re.editor.1}:8080 {
				transport http {
					keepalive off
				}
			}
		}

		@preview {
			host *.{$PLAY_DOMAIN}
			header_regexp preview Host ^3000-([0-9a-f]{32})\.
		}
		handle @preview {
			header {
				defer
				Referrer-Policy no-referrer
				X-Robots-Tag "noindex, nofollow"
				Cache-Control no-store
				+Content-Security-Policy "frame-ancestors *.{$PLAY_DOMAIN}:*"
			}
			reverse_proxy p-{re.preview.1}:3000 {
				transport http {
					keepalive off
				}
			}
		}

		@apex host {$PLAY_DOMAIN}
		handle @apex {
			handle /internal/* {
				error 404
			}
			handle {
				reverse_proxy {$PLAY_CONTROL_UPSTREAM:ctplay-control:9292}
			}
		}

		# kamal-proxy's health check (its Host is the container's address).
		handle /up {
			respond "OK" 200
		}

		handle {
			error 404
		}
	}

	handle_errors {
		header {
			Cache-Control no-store
			X-Robots-Tag "noindex, nofollow"
			Referrer-Policy no-referrer
		}
		root * /srv/pages
		# Only the control plane's own failures (5xx) get the "not available"
		# page; the apex's 404 (/internal/*) gets the 404 page below.
		@apex_error {
			host {$PLAY_DOMAIN}
			expression {err.status_code} >= 500
		}
		handle @apex_error {
			rewrite * /unavailable.html
			templates
			file_server {
				status 503
			}
		}
		@preview_error header_regexp Host ^3000-[0-9a-f]{32}\.
		handle @preview_error {
			rewrite * /app-down.html
			templates
			file_server {
				status 502
			}
		}
		handle {
			rewrite * /ended.html
			templates
			file_server {
				status 404
			}
		}
	}
}
```

- [ ] **Step 4: Write the pages, the Dockerfile and its build-context file**

The pages use Caddy's `templates` for `{{env "PLAY_PUBLIC_URL"}}`, load nothing from outside, follow the browser's light or dark scheme and keep a 16 px side margin.

Create `playground/router/pages/ended.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>No session at this address</title>
<style>
:root { --bg: #fafaf9; --fg: #1c1917; --muted: #57534e; --accent: #1d4ed8; }
@media (prefers-color-scheme: dark) { :root { --bg: #0a0a0a; --fg: #f5f5f4; --muted: #a8a29e; --accent: #93c5fd; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 36rem; margin: 0 auto; padding: 64px 16px; }
h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 16px; }
p { margin: 0 0 16px; }
a { color: var(--accent); }
code { font-family: ui-monospace, Menlo, Consolas, monospace; }
</style>
</head>
<body>
<main>
<h1>No session at this address</h1>
<p>Playground sessions last a limited time, end a few minutes after their tab is closed, and are deleted with their files. If you just started this one or the playground was just updated, reload in a few seconds.</p>
<p><a href="{{env "PLAY_PUBLIC_URL"}}/">Start a new session</a> · <a href="https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1" rel="noopener">Open in GitHub Codespaces</a></p>
</main>
</body>
</html>
```

Create `playground/router/pages/app-down.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>No app is answering here</title>
<style>
:root { --bg: #fafaf9; --fg: #1c1917; --muted: #57534e; --accent: #1d4ed8; }
@media (prefers-color-scheme: dark) { :root { --bg: #0a0a0a; --fg: #f5f5f4; --muted: #a8a29e; --accent: #93c5fd; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 36rem; margin: 0 auto; padding: 64px 16px; }
h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 16px; }
p { margin: 0 0 16px; }
a { color: var(--accent); }
code { font-family: ui-monospace, Menlo, Consolas, monospace; }
</style>
</head>
<body>
<main>
<h1>No app is answering here</h1>
<p>If your session is still running, start the server in its terminal with <code>playground-server</code>, then reload. Sessions also end after a limited time.</p>
<p><a href="{{env "PLAY_PUBLIC_URL"}}/">The playground</a></p>
</main>
</body>
</html>
```

Create `playground/router/pages/unavailable.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>The playground is not available right now</title>
<style>
:root { --bg: #fafaf9; --fg: #1c1917; --muted: #57534e; --accent: #1d4ed8; }
@media (prefers-color-scheme: dark) { :root { --bg: #0a0a0a; --fg: #f5f5f4; --muted: #a8a29e; --accent: #93c5fd; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 36rem; margin: 0 auto; padding: 64px 16px; }
h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 16px; }
p { margin: 0 0 16px; }
a { color: var(--accent); }
code { font-family: ui-monospace, Menlo, Consolas, monospace; }
</style>
</head>
<body>
<main>
<h1>The playground is not available right now</h1>
<p>Try again in a few minutes, or open it in <a href="https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1" rel="noopener">GitHub Codespaces</a>.</p>
</main>
</body>
</html>
```

Create `playground/router/Dockerfile`:

```dockerfile
# playground/router/Dockerfile -- the hosted playground's router (SP2): stock
# Caddy with a static Caddyfile and three static pages. Kamal builds it
# (playground/deploy/router.yml); playground/dev/compose.yml runs it locally.
# Run it with --dns 127.0.0.1: it needs no outside name, and the ids of ended
# sessions must not reach the host's resolver.
FROM caddy:2.11.4-alpine
COPY playground/router/Caddyfile /etc/caddy/Caddyfile
COPY playground/router/pages/ /srv/pages/
# Defaults for validation and local runs; Kamal sets the real values.
ENV PLAY_DOMAIN=play.localhost \
    PLAY_PUBLIC_URL=http://play.localhost:8080 \
    PLAY_SUBNET_POOL=10.250.0.0/16
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

Create `playground/router/Dockerfile.dockerignore` (BuildKit reads `<Dockerfile>.dockerignore` next to the Dockerfile; the context is the repository root):

```
# Build context of playground/router/Dockerfile (the repository root): only
# the router's own files.
*
!playground/router/
```

- [ ] **Step 5: Build the image**

```bash
docker build -f playground/router/Dockerfile -t ctplay-router:local . > "$SDD/logs/task2-build.log" 2>&1; echo "exit=$?"
grep -c 'Valid configuration' "$SDD/logs/task2-build.log"
docker run --rm --entrypoint caddy ctplay-router:local version
```

Expected: `exit=0`; `1` (the build's `caddy validate` step); a version line starting `v2.11.4`.

- [ ] **Step 6: Run the check**

```bash
bash "$SDD/scratch/router-check.sh" > "$SDD/logs/task2-check.log" 2>&1; echo "exit=$?"
cat "$SDD/logs/task2-check.log"
```

Expected (about a minute):

```
PASS R1 the editor host reaches code-server, with the editor's headers
PASS R2 a WebSocket upgrade passes (101), and code-server still refuses another origin (403)
PASS R3 the preview host reaches port 3000, with the preview's headers and no nosniff
PASS R4 a preview id with no session gets the 502 app-down page, templated, with the error headers
PASS R5 an unknown editor id, foo. and www. get the 404 ended page
PASS R6 the apex goes to the control plane; /internal/* is 404; a stopped control plane gives the 503 page
PASS R7 a connection from the session to the router gets nothing (curl exit 52)
PASS R8 kamal-proxy's health check (Host = the container's address) gets OK
PASS R9 the router asks no outside resolver (--dns 127.0.0.1) and forwards no packets (ip_forward 0)
PASS R10 right after the session is removed its editor answers the 404 page within 5 s, also after the detach
router-check: 10 passed, 0 failed
```

`docker ps -a --filter name=ctrcheck` and `docker network ls --filter name=ctrcheck` must then be empty. A failure prints the router's last log lines (`ROUTER_LOG_OUTPUT=stderr`); fix the cause in the router's files, rebuild, run again.

- [ ] **Step 7: Commit**

```bash
git add playground/router/Caddyfile playground/router/Dockerfile playground/router/Dockerfile.dockerignore playground/router/pages/ended.html playground/router/pages/app-down.html playground/router/pages/unavailable.html
git commit -m "Router: static Caddy routing by session alias, error pages, image

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Browser check of one hand-wired session (V1 re-check, V9, V10, V11, V19)

Before the control plane exists, one real session behind the real router, wired by hand exactly as the control plane will wire it, is opened in a real browser. What only a browser shows is settled here, so that a fallback changes the image or the router before later tasks pin them.

**Files:**
- Modify, only if a row of the checklist fails (Step 4 gives each edit): `playground/web/settings.json`, `playground/web/playground-web`, `playground/Dockerfile`, `playground/web-smoke.sh`, `playground/router/Caddyfile`; Create, only for the V9-ports fallback: `playground/web/workspace-settings.json`
- Test: the checklist below, in a browser; throwaway setup `$SDD/scratch/hand-wired.sh`; screenshots `$SDD/screens/task3-*.png`

**Interfaces:**
- Consumes: `cybertrain-playground-web:local` (Task 1) and `ctplay-router:local` (Task 2); `$SDD/scratch/router-check.sh` (Task 2) for the router fallback.
- Produces: the outcome line `V-OUTCOMES: V1=… V9-ports=… V9-guide=… V10=… V11-editor=… V11-preview=… V19=…` (each `ok` or `fallback`) at the end of your report, which Tasks 6, 7, 8 and 11 consume; when a fallback was applied, the changed files committed, a rebuilt image passing `web-smoke.sh` (13/13) and, for a router change, `router-check.sh` (10/10).

Known before this task (verified by probe on 2026-10-02 with a stand-in image, spec §15): with `--disable-proxy` and only `VSCODE_PROXY_URI`, the folderOpen task's server is detected, the Simple Browser opens by itself at `3000-<pid>`, the Ports view shows that URL, and the port's label and `openPreview` came from the user settings (a partial V9); the router's two `frame-ancestors` headers did not break the webview or the framed preview in Chromium (a partial V11). This task re-checks those with the real image and settles the rest: the guide rendered through the editor URL's `payload` (V9), the empty extension gallery (V10) and the terminal notices (V19).

Browser: use the Playwright MCP tools or the built-in browser tools (Chromium). For each row, take the screenshot named in the row and note what you saw in your report. `*.localhost` resolves to this machine in Chromium; the router listens on `127.0.0.1:18082` (start it through the sandbox bypass). The checks in this task: B5, B6, B7, B8, B9, B10, B12 of spec §8.5 (B1-B4, B11 and B13 are Task 8's; B14 is the owner's).

- [ ] **Step 1: Write the setup and the checklist**

Create `$SDD/scratch/hand-wired.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# hand-wired.sh up|down -- one real session behind the real router, wired by
# hand as the control plane will wire it (Task 3 of the SP2 plan; not
# committed). Needs cybertrain-playground-web:local and ctplay-router:local.
# The session ends by itself 420 s after `up` (PLAYGROUND_ENDS_AT), so the
# 5-minute notice comes 120 s after `up` and the container stops at about 480 s.
# NO_PROXY_URI=1: the control run, without VSCODE_PROXY_URI.
set -u
sid=0123456789abcdef0123456789abcdef
pid=fedcba9876543210fedcba9876543210
p=cthand
host=play.localhost:18082

down() {
  docker rm -f $p-router $p-control $p-session > /dev/null 2>&1
  docker network rm $p-n $p-front > /dev/null 2>&1
}

case "${1:-}" in
  down) down; exit 0 ;;
  up) down ;;
  *) echo "usage: bash hand-wired.sh up|down" >&2; exit 2 ;;
esac

docker network create --driver bridge --internal --subnet 10.250.254.0/28 \
  --opt com.docker.network.bridge.inhibit_ipv4=true $p-n > /dev/null || exit 1
docker network create $p-front > /dev/null || exit 1
ends=$(($(date +%s) + 420))
proxy_uri=(-e "VSCODE_PROXY_URI=http://{{port}}-$pid.$host")
if [ -n "${NO_PROXY_URI:-}" ]; then proxy_uri=(); fi
docker run -d --init --rm --pull never --name $p-session --hostname playground --network $p-n \
  --network-alias s-$sid --network-alias p-$pid \
  --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=256m,mode=1777 \
  --tmpfs /home/dev:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0755 \
  --tmpfs /workspace:rw,exec,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=0755 \
  --tmpfs /opt/cybertrain-cache:rw,nosuid,nodev,size=64m,uid=1000,gid=1000,mode=0755 \
  --memory 1536m --memory-swap 1536m --cpus 1 --pids-limit 512 \
  --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
  ${proxy_uri[@]+"${proxy_uri[@]}"} -e "PLAYGROUND_ENDS_AT=$ends" -e PLAYGROUND_IDLE_TIMEOUT=300 \
  cybertrain-playground-web:local > /dev/null || exit 1
docker run -d --name $p-control --network $p-front --network-alias ctplay-control --entrypoint caddy \
  ctplay-router:local respond --listen :9292 --body "control plane stand-in" > /dev/null || exit 1
docker run -d --name $p-router --network $p-front --dns 127.0.0.1 --sysctl net.ipv4.ip_forward=0 \
  -p 127.0.0.1:18082:80 -e PLAY_DOMAIN=play.localhost -e "PLAY_PUBLIC_URL=http://$host" \
  -e PLAY_SUBNET_POOL=10.250.0.0/16 -e ROUTER_LOG_OUTPUT=stderr ctplay-router:local > /dev/null || exit 1
docker network connect $p-n $p-router || exit 1

for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H "Host: $sid.$host" http://127.0.0.1:18082/healthz)" = 200 ] && break
  sleep 1
done
# The editor URL exactly as Play::Config#editor_url builds it (spec §5.2).
guide=$(printf 'vscode-remote://%s.%s/workspace/blog/PLAYGROUND.md' "$sid" "$host" | sed 's|:|%3A|g; s|/|%2F|g')
echo "editor:  http://$sid.$host/?folder=%2Fworkspace%2Fblog&payload=%5B%5B%22openFile%22%2C%22$guide%22%5D%5D"
echo "preview: http://3000-$pid.$host/"
echo "ends at: $(date -u -r "$ends" +%H:%M:%S 2> /dev/null || date -u -d "@$ends" +%H:%M:%S) UTC (the container stops about 60 s later)"
```

The checklist (each row: what to do in the browser, what passes; Step 4 gives the fallback for each V-row):

| # | Do | Pass when |
| --- | --- | --- |
| H1 (B5, V1, V9-guide) | Open the `editor:` URL that `up` printed; wait 25 s; screenshot `task3-01-first-view.png` | The workbench shows the blog's Explorer; `PLAYGROUND.md` open as a rendered Markdown preview (tab "Preview PLAYGROUND.md", headings rendered); the panel shows the terminal "cybertrain server" with the banner (`App    http://3000-fedcba9876543210fedcba9876543210.play.localhost:18082/`, `Guide`, `Ends   in 6 minutes …`) and `* Listening on http://0.0.0.0:3000`; the Simple Browser opened by itself beside the editor at `http://3000-fedcba9876543210fedcba9876543210.play.localhost:18082/` showing the article list. No Welcome tab, no Chat side bar, no "Restricted Mode", no trust dialog, no "allow automatic tasks" prompt, no Coder promo card |
| H2 (B9, V9-ports) | Click the Ports tab of the panel; screenshot `task3-02-ports.png`; then use the port's "Open in Browser" (globe icon) | Row `cybertrain (3000)`, forwarded address `http://3000-fedcba9876543210fedcba9876543210.play.localhost:18082/`, "Auto Forwarded"; Open in Browser opens a normal tab on the article list. In that tab, evaluating `confirm("playground")` with the tool's JavaScript evaluation shows a dialog (accept it) and returns `true`, unlike inside the preview's sandboxed frame |
| H3 (B6, V11) | Read the browser console of the editor's page (the tool's console messages) | No message about `frame-ancestors`, `X-Frame-Options` or a refused frame; the Markdown preview and the Simple Browser both rendered (H1). Ignore `vsda` 404s (code-server ships no vsda) |
| H4 (B7, V10) | Open the Extensions view (Ctrl+Shift+X); wait 5 s; screenshot `task3-03-extensions.png`; list the page's network requests | No marketplace list (an empty view or a message that no gallery is configured), no error dialog, the workbench still works; no request to `open-vsx.org` or `openvsx.eclipsecontent.org` |
| H5 (B8) | Open `app/views/articles/index.html.erb`; read the language in the status bar; at the end of the file type `ul>li*2` and press Tab; screenshot `task3-04-erb.png`; then undo (Ctrl+Z) and close without saving | The language is "HTML"; Emmet expands it to `<ul>` with two `<li></li>` |
| H6 (B12) | Right-click the `app` folder in the Explorer; screenshot `task3-05-menu.png`; choose "Download…" | The menu has "Download…" and no "Upload…"; the download starts (the tool reports a download, or the browser's download prompt appears; cancel it) |
| H7 (B10, V19) | Note the time `up` ran. At about 120 s after it, look at the "cybertrain server" terminal; screenshot `task3-06-notice.png`. At about 360 s, look again | A yellow line `[playground] This session ends in 5 minutes: it is deleted with its files. Download what you want to keep.` at about 120 s, and `[playground] This session ends in 1 minute.` at about 360 s |
| H8 (B10) | At about 480 s after `up` (the container stops itself 60 s after its end), screenshot `task3-07-ended.png`; then reload the page; screenshot `task3-08-reload.png` | First the workbench's reconnecting or "cannot reconnect" notice; after the reload the router's "No session at this address" page with "Start a new session" pointing to `http://play.localhost:18082/` |

- [ ] **Step 2: Run the control that must fail**

Without `VSCODE_PROXY_URI` the editor builds the preview's address from its own (disabled) proxy, so H1's preview row must fail; this shows the row tells the two apart.

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
NO_PROXY_URI=1 bash "$SDD/scratch/hand-wired.sh" up
```

Open the printed `editor:` URL, wait 25 s, screenshot `task3-00-control.png`. Expected: the banner's `App` line shows `http://localhost:3000/` and the Simple Browser (if it opens) points at `http://0123456789abcdef0123456789abcdef.play.localhost:18082/proxy/3000/` and shows `403` (code-server's proxy is disabled), not the article list. Record what you saw, then `bash "$SDD/scratch/hand-wired.sh" down`.

- [ ] **Step 3: Run the checklist**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
bash "$SDD/scratch/hand-wired.sh" up
```

Go through H1-H8 in order (H1-H6 fit in the first two minutes; H7 and H8 wait for the session's end). Then `bash "$SDD/scratch/hand-wired.sh" down`. Every row passing means `V-OUTCOMES: V1=ok V9-ports=ok V9-guide=ok V10=ok V11-editor=ok V11-preview=ok V19=ok`; skip Step 4.

- [ ] **Step 4: Apply the fallback for each failing row**

Make the edits for each failing row only, then rebuild and re-test as the row says, and redo the failed rows from a fresh `up`. Anything that fails outside these fallbacks: report it with the screenshot (and fix it only if the fix is within the spec's meaning).

**V1 fails** (the preview does not open by itself at the `3000-<pid>` host, or the Ports view shows another address; spec §3.5 (b)'s alternative): in `playground/web/playground-web` replace

```bash
# 4. code-server. The router sends the preview straight to port 3000, so
#    code-server's own port proxy stays off.
args=(--bind-addr 0.0.0.0:8080 --auth none
      --disable-telemetry --disable-update-check --disable-workspace-trust
      --disable-getting-started-override --disable-proxy --disable-file-uploads
      --idle-timeout-seconds "$idle"
      /workspace/blog)
```

with

```bash
# 4. code-server. The router sends the preview straight to port 3000; the
#    domain proxy is on only so that the editor builds the preview's address
#    from VSCODE_PROXY_URI (spec §3.5 (b)). The router never sends it a
#    preview request.
proxy_domain=${VSCODE_PROXY_URI:-}
proxy_domain=${proxy_domain#*://}
proxy_domain=${proxy_domain%%/*}
args=(--bind-addr 0.0.0.0:8080 --auth none
      --disable-telemetry --disable-update-check --disable-workspace-trust
      --disable-getting-started-override --disable-file-uploads
      --idle-timeout-seconds "$idle")
if [ -n "$proxy_domain" ]; then args+=(--proxy-domain "$proxy_domain"); fi
args+=(/workspace/blog)
```

Rebuild the `web` image and run `web-smoke.sh` (13 passed).

**V9-ports fails** (no label "cybertrain" or no automatic preview, though the server runs): in `playground/web/settings.json` delete these six lines

```jsonc
  // Port 3000 opens in the editor's preview; other ports are not offered,
  // since only 3000 is routed (checked from a workspace file; from here: V9).
  "remote.portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "remote.otherPortsAttributes": { "onAutoForward": "ignore" },
```

create `playground/web/workspace-settings.json`

```jsonc
// The blog's workspace settings in the hosted playground (copied to
// .vscode/settings.json, hidden from git like tasks.json): port 3000 opens in
// the editor's preview; other ports are not offered, since only 3000 is
// routed. User settings did not take them (plan Task 3, V9).
{
  "remote.portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "remote.otherPortsAttributes": { "onAutoForward": "ignore" }
}
```

and in `playground/Dockerfile` add after `COPY --chown=dev:dev playground/web/tasks.json .vscode/tasks.json`:

```dockerfile
COPY --chown=dev:dev playground/web/workspace-settings.json .vscode/settings.json
```

Rebuild and run `web-smoke.sh` (13 passed: W3 still sees a clean tree, since `/.vscode/` is excluded).

**V9-guide fails** (`PLAYGROUND.md` does not open, or opens as text): if it does not open at all, report it with the URL you used (the `payload` is the control plane's, spec §5.2). If it opens as text only, delete these two lines from `playground/web/settings.json` (the guide then opens as text, which spec §1.2 allows):

```jsonc
  // The guide opens rendered (V9).
  "workbench.editorAssociations": { "**/PLAYGROUND.md": "vscode.markdown.preview.editor" },
```

Rebuild and run `web-smoke.sh`.

**V10 fails** (a marketplace list still shows, an error appears, or a request goes to Open VSX): in `playground/Dockerfile` replace

```dockerfile
# The router reaches the dev server at the session's own address, so the app
# listens on every interface (only the router shares the session's network).
# An empty gallery: an install could not download anything here (no network),
# and the visitor's browser then contacts no extension marketplace.
ENV CYBERTRAIN_HOST=0.0.0.0 \
    EXTENSIONS_GALLERY={}
```

with

```dockerfile
# The router reaches the dev server at the session's own address, so the app
# listens on every interface (only the router shares the session's network).
# The extension gallery stays code-server's default (Open VSX): an empty one
# did not hide it cleanly (plan Task 3, V10). No install can download
# anything here anyway: the session has no network.
ENV CYBERTRAIN_HOST=0.0.0.0
```

and in `playground/web-smoke.sh` replace `what_W2="user dev (uid 1000), cybertrain $version, CYBERTRAIN_HOST=0.0.0.0 and EXTENSIONS_GALLERY={}"` with `what_W2="user dev (uid 1000), cybertrain $version, CYBERTRAIN_HOST=0.0.0.0, EXTENSIONS_GALLERY unset"` and `  *"user=dev:1000 cli=[cybertrain $version] host=0.0.0.0 gallery={}"*) pass W2 "$what_W2" ;;` with `  *"user=dev:1000 cli=[cybertrain $version] host=0.0.0.0 gallery=unset"*) pass W2 "$what_W2" ;;`. Rebuild and run `web-smoke.sh`. (Task 6 then uses the terms page's other sentence.)

**V11 fails** (the Markdown preview or the Simple Browser stays blank, or the console reports a refused frame): delete the header line of the side that breaks from `playground/router/Caddyfile`, the editor's `+Content-Security-Policy "frame-ancestors 'self'"` (V11-editor) or the preview's `+Content-Security-Policy "frame-ancestors *.{$PLAY_DOMAIN}:*"` (V11-preview); spec §6.3 calls their value small. Rebuild `ctplay-router:local`, remove the matching `header content-security-policy | grep …` condition from R1 or R3 in `$SDD/scratch/router-check.sh`, and run it (10 passed).

**V19 fails** (no notice in the terminal): in `playground/web/playground-web` delete the block from the line `# 3. A notice in every open terminal 5 minutes and 1 minute before the end.` through the `fi` that closes `if [ -n "$ends_at" ]; then` (the notifier), renumber `# 4. code-server.` to `# 3. code-server.`, and in the header comment replace `installs
# code-server's user settings, schedules two notices in the terminals and
# execs code-server` with `installs
# code-server's user settings and execs code-server`. The banner's `Ends` line remains the visitor's notice. Rebuild and run `web-smoke.sh`.

- [ ] **Step 5: Clean up, record the outcomes and commit what changed**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
bash "$SDD/scratch/hand-wired.sh" down
rm -rf .playwright-mcp
git status --short
```

If no fallback was needed, `git status --short` prints nothing and there is nothing to commit. Otherwise stage exactly the files the applied fallbacks changed, for example:

```bash
git add playground/web/settings.json playground/web/workspace-settings.json playground/Dockerfile
git commit -m "Playground: browser-check fallbacks (V9 ports from the workspace settings)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

End your report with the `V-OUTCOMES:` line and the list of screenshots.

---

### Task 4: Control plane foundations: settings, argv templates, Docker CLI, subnets, limits, probe

**Files:**
- Create: `playground/control/Gemfile`, `playground/control/Gemfile.lock` (generated), `playground/control/Rakefile`
- Create: `playground/control/lib/play.rb`, `playground/control/lib/play/config.rb`, `playground/control/lib/play/subnets.rb`, `playground/control/lib/play/templates.rb`, `playground/control/lib/play/docker_cli.rb`, `playground/control/lib/play/limits.rb`, `playground/control/lib/play/probe.rb`
- Test: `playground/control/test/test_helper.rb`, `playground/control/test/fakes.rb`, `playground/control/test/config_test.rb`, `playground/control/test/subnets_test.rb`, `playground/control/test/templates_test.rb`, `playground/control/test/limits_test.rb`, `playground/control/test/drift_test.rb`

**Interfaces:**
- Consumes: `playground/web-smoke.sh` as Task 1 committed it (the drift test reads its hardened block; if Task 1 reported a changed tmpfs option, make `Templates.hardening` produce the same token, or the drift test fails).
- Produces (Tasks 5-7 rely on these exact names):
  - `Play::Config.from_env(env = ENV)` / `Play::Config.new(hash)`; raises `Play::Config::Error` with messages such as `PLAY_PUBLIC_URL is required` and `PLAY_IDLE_TIMEOUT must be more than 60 seconds (got 60)`. Readers: `scheme`, `domain`, `port` (Integer or nil), `session_image`, `router_url`, `router_filters` (Array), `allowed_origins` (Array of `scheme://host[:port]`), `client_ip_header`, `max_sessions`, `max_sessions_per_ip`, `create_limit`, `create_window`, `ttl`, `idle_timeout`, `ready_timeout`, `reap_interval`, `subnet_pool`, `subnet_prefix`, `session_memory`, `session_cpus`, `session_pids`, `tmpfs_tmp`, `tmpfs_home`, `tmpfs_workspace`, `tmpfs_cache`, `runtime` (`""` when unset), `data_dir`, `codespaces_url`, `abuse_contact`; and `port_suffix` (`":8080"` or `""`), `public_origin`, `client_ip_env_key` (`"HTTP_CF_CONNECTING_IP"` or nil), `editor_url(sid)`, `proxy_uri(pid)`, `session_hosts_source` (`<scheme>://*.<domain><port>`). An empty variable counts as unset.
  - `Play::Templates` (module functions returning argv arrays that start with `"docker"`): `labels(handle, created, expires)`, `network_create(handle:, subnet:, created:, expires:)`, `network_connect(handle:, container:)`, `hardening(config)`, `session_run(config, handle:, sid:, pid:, created:, expires:)`, `remove_container(handle:)`, `network_containers(handle:)`, `network_disconnect(handle:, container:)`, `network_remove(handle:)`, `list_containers`, `list_networks`, `network_subnet(handle:)`, `list_routers(config)`, `stats(names)`, `image_inspect(config)`, `version`.
  - `Play::DockerCLI#run(argv, timeout:)` → `Play::DockerCLI::Result` (`status`, `stdout`, `stderr`, `ok?`); raises `Play::DockerCLI::Timeout` (message: the argv's first three words only); `Play::DockerCLI.redact(text, secrets = {})`.
  - `Play::Subnets.validate!(pool, prefix)`, `Play::Subnets.new(pool, prefix).first_free(taken)` → `"10.250.0.16/28"` or nil.
  - `Play::Limits.client_key(env, header_key)` (`"203.0.113.7"`, `"2001:db8:1:2::/64"`, else REMOTE_ADDR); `Play::Limits.new(limit:, window:, clock:)` with `retry_after(key)` (seconds, 0 = allowed) and `record(key)`.
  - `Play::Probe.new(config).ready?(sid)`; `Play::Clock` (`now`, `monotonic`, `sleep`); `Play::EventLog.new(io).event(name, **fields)` writing `play event=<name> key=value ...`.
  - Tests: `test/test_helper.rb`; `test/fakes.rb` with `FakeClock` and `PlayTestHelpers#play_config(env = {})` (Task 5 appends `FakeDocker` and `FakeProbe`, Task 6 `FakeSessions`); the command `BUNDLE_PATH="$SDD/bundle" bundle exec rake test` run in `playground/control`.

Notes on the spec's text, applied below:
- The argv templates are spec §5.4's, unchanged (the `inhibit_ipv4` option is now a measured fact, spec §15); `Templates.hardening` is the slice of the session's argv from `--user` to `--pids-limit`, which is what `web-smoke.sh` runs.
- `Config#editor_url` builds spec §5.2's URL (`folder` and `payload` encoded with `URI.encode_www_form_component`; the `vscode-remote://` authority carries the port only when `PLAY_PUBLIC_URL` has one). `session_hosts_source` serves Task 6's CSP correction.
- `Gemfile`: `rake` joins the test group (spec §8.1 runs `bundle exec rake test`); the precedent's `rackup` is left out (Puma loads `config.ru` itself).
- Configuration checks beyond spec §5.10's list (sizes like `256m`, the runtime name, the router filters, the header name, origins without a path) keep every value that reaches an argv in a known shape.

- [ ] **Step 1: Write the failing tests**

Create `playground/control/Gemfile`:

```ruby
source "https://rubygems.org"

# The hosted playground's control plane (playground/README.md). Kept small on
# purpose: this process holds the Docker socket.
gem "sinatra", "~> 4.1"
gem "puma", "~> 7.0"

group :test do
  gem "minitest"
  gem "rack-test"
  gem "rake"
end
```

Create `playground/control/Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

task default: :test
```

Create `playground/control/test/test_helper.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "play"
require_relative "fakes"
```

Create `playground/control/test/fakes.rb`:

```ruby
# frozen_string_literal: true

# Stand-ins for Docker, the readiness probe and the clocks (spec §8.2).

# Wall clock, monotonic clock and sleep that move only when told to.
class FakeClock
  attr_reader :monotonic

  def initialize(now: 1_800_000_000)
    @wall = now.to_f
    @monotonic = 1000.0
  end

  def now
    @wall.floor
  end

  def advance(seconds)
    @wall += seconds
    @monotonic += seconds
  end

  def sleep(seconds)
    advance(seconds)
  end
end

module PlayTestHelpers
  def play_config(env = {})
    @data_dir ||= Dir.mktmpdir("play-test")
    Play::Config.new({ "PLAY_PUBLIC_URL" => "https://play.example.test",
                       "PLAY_SESSION_IMAGE" => "ghcr.io/example/cybertrain-playground-web@sha256:0123",
                       "PLAY_ABUSE_CONTACT" => "abuse@example.test",
                       "PLAY_DATA_DIR" => @data_dir }.merge(env))
  end

  def teardown
    FileUtils.rm_rf(@data_dir) if @data_dir
    super
  end
end
```

Create `playground/control/test/config_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include PlayTestHelpers

  def error_for(env)
    assert_raises(Play::Config::Error) { play_config(env) }.message
  end

  def test_required_settings
    assert_equal "PLAY_PUBLIC_URL is required", error_for("PLAY_PUBLIC_URL" => "")
    assert_equal "PLAY_SESSION_IMAGE is required", error_for("PLAY_SESSION_IMAGE" => nil)
    assert_equal "PLAY_ABUSE_CONTACT is required", error_for("PLAY_ABUSE_CONTACT" => "")
  end

  def test_defaults
    c = play_config
    assert_equal [5, 1, 3, 600, 1800, 300, 30, 5], [c.max_sessions, c.max_sessions_per_ip, c.create_limit,
                                                   c.create_window, c.ttl, c.idle_timeout, c.ready_timeout,
                                                   c.reap_interval]
    assert_equal ["10.250.0.0/16", 28], [c.subnet_pool, c.subnet_prefix]
    assert_equal %w[1536m 1 256m 128m 256m 64m], [c.session_memory, c.session_cpus, c.tmpfs_tmp, c.tmpfs_home,
                                                  c.tmpfs_workspace, c.tmpfs_cache]
    assert_equal 512, c.session_pids
    assert_equal "", c.runtime
    assert_equal "http://ctplay-router", c.router_url
    assert_equal ["label=service=cybertrain-play-router", "label=role=web"], c.router_filters
    assert_nil c.client_ip_env_key
    assert_equal "https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1", c.codespaces_url
  end

  def test_numbers_are_checked
    assert_equal 'PLAY_MAX_SESSIONS must be a whole number above 0 (got "five")', error_for("PLAY_MAX_SESSIONS" => "five")
    assert_equal 'PLAY_TTL must be a whole number above 0 (got "0")', error_for("PLAY_TTL" => "0")
    assert_match(/PLAY_SESSION_MEMORY must be a size/, error_for("PLAY_SESSION_MEMORY" => "lots"))
    assert_match(/PLAY_SESSION_CPUS must be a number/, error_for("PLAY_SESSION_CPUS" => "0"))
    assert_match(/PLAY_RUNTIME must be a runtime name/, error_for("PLAY_RUNTIME" => "runsc --privileged"))
  end

  def test_idle_timeout_must_exceed_60
    assert_equal "PLAY_IDLE_TIMEOUT must be more than 60 seconds (got 60)", error_for("PLAY_IDLE_TIMEOUT" => "60")
    assert_equal 61, play_config("PLAY_IDLE_TIMEOUT" => "61").idle_timeout
  end

  def test_public_url_gives_scheme_domain_and_port
    c = play_config("PLAY_PUBLIC_URL" => "http://play.localhost:8080")
    assert_equal ["http", "play.localhost", 8080, ":8080"], [c.scheme, c.domain, c.port, c.port_suffix]
    assert_equal "http://play.localhost:8080", c.public_origin
    c = play_config("PLAY_PUBLIC_URL" => "https://Play.Example.TEST/")
    assert_equal ["https", "play.example.test", nil, ""], [c.scheme, c.domain, c.port, c.port_suffix]
    assert_match(/PLAY_PUBLIC_URL must be a scheme and a host/, error_for("PLAY_PUBLIC_URL" => "https://play.example.test/x"))
    assert_match(/PLAY_PUBLIC_URL must be a scheme and a host/, error_for("PLAY_PUBLIC_URL" => "play.example.test"))
  end

  def test_editor_url_and_proxy_uri
    sid = "0123456789abcdef0123456789abcdef"
    assert_equal "https://#{sid}.play.example.test/?folder=%2Fworkspace%2Fblog&payload=" \
                 "%5B%5B%22openFile%22%2C%22vscode-remote%3A%2F%2F#{sid}.play.example.test" \
                 "%2Fworkspace%2Fblog%2FPLAYGROUND.md%22%5D%5D", play_config.editor_url(sid)
    local = play_config("PLAY_PUBLIC_URL" => "http://play.localhost:8080")
    assert_equal "http://#{sid}.play.localhost:8080/?folder=%2Fworkspace%2Fblog&payload=" \
                 "%5B%5B%22openFile%22%2C%22vscode-remote%3A%2F%2F#{sid}.play.localhost%3A8080" \
                 "%2Fworkspace%2Fblog%2FPLAYGROUND.md%22%5D%5D", local.editor_url(sid)
    assert_equal "http://{{port}}-#{sid}.play.localhost:8080", local.proxy_uri(sid)
    assert_equal "http://*.play.localhost:8080", local.session_hosts_source
  end

  def test_allowed_origins
    assert_equal ["https://play.example.test"], play_config.allowed_origins
    c = play_config("PLAY_ALLOWED_ORIGINS" => "https://play.example.test, https://Saeki-Mototsune.github.io:443")
    assert_equal ["https://play.example.test", "https://saeki-mototsune.github.io"], c.allowed_origins
    assert_match(/PLAY_ALLOWED_ORIGINS must list origins/, error_for("PLAY_ALLOWED_ORIGINS" => "https://x.test/path"))
  end

  def test_client_ip_header
    assert_equal "HTTP_CF_CONNECTING_IP", play_config("PLAY_CLIENT_IP_HEADER" => "CF-Connecting-IP").client_ip_env_key
    assert_match(/PLAY_CLIENT_IP_HEADER must be a header name/, error_for("PLAY_CLIENT_IP_HEADER" => "X Bad"))
  end

  def test_pool_overlapping_dockers_defaults_stops_the_boot
    assert_equal "PLAY_SUBNET_POOL 172.20.0.0/16 overlaps Docker's default address pool 172.20.0.0/16",
                 error_for("PLAY_SUBNET_POOL" => "172.20.0.0/16")
  end
end
```

Create `playground/control/test/subnets_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class SubnetsTest < Minitest::Test
  def subnets
    Play::Subnets.new("10.250.0.0/16", 28)
  end

  def test_the_lowest_free_subnet
    assert_equal "10.250.0.0/28", subnets.first_free([])
    assert_equal "10.250.0.32/28", subnets.first_free(["10.250.0.0/28", "10.250.0.16/28"])
    assert_equal "10.250.0.16/28", subnets.first_free(["10.250.0.0/28", "10.250.0.32/28"])
  end

  def test_skips_what_overlaps_including_bigger_networks_and_refused_ranges
    assert_equal "10.250.1.0/28", subnets.first_free(["10.250.0.0/24"])
    assert_equal "10.250.0.16/28", subnets.first_free(["10.250.0.8/29", "10.250.0.0/29"])
    assert_equal "10.250.0.0/28", subnets.first_free(["192.0.2.0/24", "not a subnet"])
  end

  def test_none_left
    small = Play::Subnets.new("10.250.0.0/27", 28)
    assert_nil small.first_free(["10.250.0.0/28", "10.250.0.16/28"])
  end

  def test_pool_validation
    assert_nil Play::Subnets.validate!("10.250.0.0/16", 28)
    error = ->(pool, prefix) { assert_raises(Play::Config::Error) { Play::Subnets.validate!(pool, prefix) }.message }
    assert_equal "PLAY_SUBNET_POOL 192.168.64.0/20 overlaps Docker's default address pool 192.168.0.0/16",
                 error.call("192.168.64.0/20", 28)
    assert_equal "PLAY_SUBNET_POOL 172.0.0.0/8 overlaps Docker's default address pool 172.17.0.0/16",
                 error.call("172.0.0.0/8", 28)
    assert_equal "PLAY_SUBNET_PREFIX must be between 16 and 29 for 10.250.0.0/16 (got 30)", error.call("10.250.0.0/16", 30)
    assert_equal "PLAY_SUBNET_PREFIX must be between 16 and 29 for 10.250.0.0/16 (got 12)", error.call("10.250.0.0/16", 12)
    assert_match(/must be an IPv4 network/, error.call("fd00::/64", 72))
    assert_match(/must be an IPv4 network/, error.call("10.250.0.1", 28))
  end
end
```

Create `playground/control/test/templates_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class TemplatesTest < Minitest::Test
  include PlayTestHelpers

  H = "1f2e3d4c5b6a7980"
  SID = "0123456789abcdef0123456789abcdef"
  PID = "fedcba9876543210fedcba9876543210"

  def run_argv(env = {})
    Play::Templates.session_run(play_config(env), handle: H, sid: SID, pid: PID, created: 1_800_000_000,
                                                  expires: 1_800_001_800)
  end

  def test_network_create_is_the_spec_argv
    assert_equal ["docker", "network", "create", "--driver", "bridge", "--internal", "--subnet", "10.250.0.16/28",
                  "--opt", "com.docker.network.bridge.inhibit_ipv4=true",
                  "--label", "cybertrain-play.role=session", "--label", "cybertrain-play.handle=#{H}",
                  "--label", "cybertrain-play.created-at=1800000000", "--label", "cybertrain-play.expires-at=1800001800",
                  "ctplay-n-#{H}"],
                 Play::Templates.network_create(handle: H, subnet: "10.250.0.16/28", created: 1_800_000_000,
                                                expires: 1_800_001_800)
  end

  def test_session_run_is_the_spec_argv
    assert_equal ["docker", "run", "--detach", "--rm", "--init", "--pull", "never",
                  "--name", "ctplay-s-#{H}", "--hostname", "playground", "--network", "ctplay-n-#{H}",
                  "--network-alias", "s-#{SID}", "--network-alias", "p-#{PID}",
                  "--label", "cybertrain-play.role=session", "--label", "cybertrain-play.handle=#{H}",
                  "--label", "cybertrain-play.created-at=1800000000", "--label", "cybertrain-play.expires-at=1800001800",
                  "--user", "1000:1000", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--read-only",
                  "--tmpfs", "/tmp:rw,exec,nosuid,nodev,size=256m,mode=1777",
                  "--tmpfs", "/home/dev:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0755",
                  "--tmpfs", "/workspace:rw,exec,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=0755",
                  "--tmpfs", "/opt/cybertrain-cache:rw,nosuid,nodev,size=64m,uid=1000,gid=1000,mode=0755",
                  "--memory", "1536m", "--memory-swap", "1536m", "--cpus", "1", "--pids-limit", "512",
                  "--log-driver", "json-file", "--log-opt", "max-size=1m", "--log-opt", "max-file=1",
                  "--env", "VSCODE_PROXY_URI=https://{{port}}-#{PID}.play.example.test",
                  "--env", "PLAYGROUND_ENDS_AT=1800001800", "--env", "PLAYGROUND_IDLE_TIMEOUT=300",
                  "ghcr.io/example/cybertrain-playground-web@sha256:0123"],
                 run_argv
  end

  def test_session_run_never_carries_a_forbidden_flag
    argv = run_argv("PLAY_RUNTIME" => "runsc")
    forbidden = ["--privileged", "--cap-add", "-v", "--volume", "--mount", "-p", "--publish", "--publish-all", "-P",
                 "--pid", "--ipc", "--device", "--restart", "--userns", "--uts", "--network=host"]
    assert_empty argv & forbidden
    refute_includes argv.each_cons(2).to_a, ["--network", "host"]
    refute(argv.any? { |a| a.include?("seccomp=unconfined") || a.include?("apparmor=unconfined") })
    refute(argv.any? { |a| a.start_with?("--pid=", "--ipc=", "--privileged=") })
  end

  def test_runtime_only_when_set
    refute_includes run_argv, "--runtime"
    argv = run_argv("PLAY_RUNTIME" => "runsc")
    assert_equal "runsc", argv[argv.index("--runtime") + 1]
    assert_operator argv.index("--runtime"), :<, argv.index("--env")
  end

  def test_numbers_come_from_the_settings
    argv = run_argv("PLAY_SESSION_MEMORY" => "2g", "PLAY_SESSION_CPUS" => "0.5", "PLAY_SESSION_PIDS" => "256",
                    "PLAY_TMPFS_TMP" => "128m", "PLAY_TMPFS_HOME" => "64m", "PLAY_TMPFS_WORKSPACE" => "512m",
                    "PLAY_TMPFS_CACHE" => "32m", "PLAY_IDLE_TIMEOUT" => "600")
    assert_equal %w[2g 2g], [argv[argv.index("--memory") + 1], argv[argv.index("--memory-swap") + 1]]
    assert_equal "0.5", argv[argv.index("--cpus") + 1]
    assert_equal "256", argv[argv.index("--pids-limit") + 1]
    tmpfs = argv.each_cons(2).select { |flag, _| flag == "--tmpfs" }.map(&:last)
    assert_equal %w[size=128m size=64m size=512m size=32m], tmpfs.map { |t| t[/size=\w+/] }
    assert_includes argv, "PLAYGROUND_IDLE_TIMEOUT=600"
  end

  def test_a_local_public_url_keeps_its_port_in_the_proxy_uri
    argv = run_argv("PLAY_PUBLIC_URL" => "http://play.localhost:8080")
    assert_includes argv, "VSCODE_PROXY_URI=http://{{port}}-#{PID}.play.localhost:8080"
  end

  def test_teardown_and_listing_argvs
    assert_equal ["docker", "rm", "--force", "ctplay-s-#{H}"], Play::Templates.remove_container(handle: H)
    assert_equal ["docker", "network", "inspect", "--format", "{{range $id, $c := .Containers}}{{$id}} {{end}}",
                  "ctplay-n-#{H}"], Play::Templates.network_containers(handle: H)
    assert_equal ["docker", "network", "disconnect", "--force", "ctplay-n-#{H}", "abc123"],
                 Play::Templates.network_disconnect(handle: H, container: "abc123")
    assert_equal ["docker", "network", "rm", "ctplay-n-#{H}"], Play::Templates.network_remove(handle: H)
    assert_equal ["docker", "network", "connect", "ctplay-n-#{H}", "abc123"],
                 Play::Templates.network_connect(handle: H, container: "abc123")
    assert_equal ["docker", "ps", "--all", "--no-trunc", "--filter", "label=cybertrain-play.role=session", "--format",
                  "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Label \"cybertrain-play.handle\"}}\t" \
                  "{{.Label \"cybertrain-play.created-at\"}}\t{{.Label \"cybertrain-play.expires-at\"}}"],
                 Play::Templates.list_containers
    assert_equal ["docker", "network", "ls", "--no-trunc", "--filter", "label=cybertrain-play.role=session", "--format",
                  "{{.ID}}\t{{.Name}}\t{{.Label \"cybertrain-play.handle\"}}\t{{.Label \"cybertrain-play.created-at\"}}"],
                 Play::Templates.list_networks
    assert_equal ["docker", "network", "inspect", "--format", "{{(index .IPAM.Config 0).Subnet}}", "ctplay-n-#{H}"],
                 Play::Templates.network_subnet(handle: H)
    assert_equal ["docker", "ps", "--filter", "label=service=cybertrain-play-router", "--filter", "label=role=web",
                  "--filter", "status=running", "--format", "{{.ID}}"], Play::Templates.list_routers(play_config)
    assert_equal ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}",
                  "ctplay-s-a", "ctplay-s-b"], Play::Templates.stats(%w[ctplay-s-a ctplay-s-b])
    assert_equal ["docker", "image", "inspect", "--format", "{{.Id}}",
                  "ghcr.io/example/cybertrain-playground-web@sha256:0123"], Play::Templates.image_inspect(play_config)
    assert_equal ["docker", "version", "--format", "{{.Server.Version}}"], Play::Templates.version
  end
end
```

Create `playground/control/test/limits_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class LimitsTest < Minitest::Test
  def test_the_window_slides
    clock = FakeClock.new
    limits = Play::Limits.new(limit: 2, window: 600, clock: clock)
    assert_equal 0, limits.retry_after("203.0.113.7")
    limits.record("203.0.113.7")
    clock.advance(100)
    limits.record("203.0.113.7")
    assert_equal 500, limits.retry_after("203.0.113.7")
    assert_equal 0, limits.retry_after("203.0.113.8")
    clock.advance(500)
    assert_equal 0, limits.retry_after("203.0.113.7")
    limits.record("203.0.113.7")
    assert_equal 100, limits.retry_after("203.0.113.7")
  end

  def test_ipv4_key_from_the_header
    env = { "HTTP_CF_CONNECTING_IP" => "203.0.113.7", "REMOTE_ADDR" => "172.18.0.5" }
    assert_equal "203.0.113.7", Play::Limits.client_key(env, "HTTP_CF_CONNECTING_IP")
    assert_equal "172.18.0.5", Play::Limits.client_key(env, nil)
  end

  def test_ipv6_counts_per_64
    a = { "HTTP_CF_CONNECTING_IP" => "2001:db8:1:2:aaaa::1" }
    b = { "HTTP_CF_CONNECTING_IP" => "2001:DB8:1:2:bbbb::9" }
    assert_equal "2001:db8:1:2::/64", Play::Limits.client_key(a, "HTTP_CF_CONNECTING_IP")
    assert_equal "2001:db8:1:2::/64", Play::Limits.client_key(b, "HTTP_CF_CONNECTING_IP")
    mapped = { "HTTP_CF_CONNECTING_IP" => "::ffff:203.0.113.7" }
    assert_equal "203.0.113.7", Play::Limits.client_key(mapped, "HTTP_CF_CONNECTING_IP")
  end

  def test_a_broken_header_falls_back_to_remote_addr
    ["", "unknown", "203.0.113.7, 198.51.100.1", "10.0.0.0/8", "999.1.1.1", "2001:db8::1%eth0"].each do |bad|
      env = { "HTTP_CF_CONNECTING_IP" => bad, "REMOTE_ADDR" => "172.18.0.5" }
      assert_equal "172.18.0.5", Play::Limits.client_key(env, "HTTP_CF_CONNECTING_IP"), bad
    end
  end
end
```

Create `playground/control/test/drift_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

# playground/web-smoke.sh runs its session with the hardening flags between
# "# BEGIN hardened run" and "# END hardened run"; production runs
# Play::Templates.hardening. The two must not drift apart (spec §8.2).
class DriftTest < Minitest::Test
  include PlayTestHelpers

  SMOKE = File.expand_path("../../web-smoke.sh", __dir__)

  def test_the_smoke_tests_hardened_run_is_the_templates_hardening
    block = File.read(SMOKE)[/^# BEGIN hardened run\n(.*?)^# END hardened run$/m, 1]
    refute_nil block, "#{SMOKE} has no '# BEGIN hardened run' ... '# END hardened run' block"
    flags = block.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") || %w[hardened=( )].include?(line) }
    assert_equal Play::Templates.hardening(play_config), flags.flat_map(&:split)
  end
end
```

- [ ] **Step 2: Lock the bundle and run the tests to verify they fail**

```bash
cd /Users/saeki/work/cybertrain/playground/control
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
export BUNDLE_PATH="$SDD/bundle"
bundle lock --add-platform aarch64-linux x86_64-linux
bundle install
bundle exec rake test 2>&1 | grep -E 'LoadError|rake aborted'
```

Expected: `Writing lockfile to …/playground/control/Gemfile.lock`, `Bundle complete!`, then `…: cannot load such file -- play (LoadError)` and `rake aborted!`. The lockfile should resolve to sinatra 4.2.1, puma 7.2.1, rack 3.2.x, rack-protection 4.2.1, mustermann 3.1.1, tilt 2.9.x, minitest 6.0.x, rack-test 2.2.0, rake 13.4.x (newer patch releases are fine) and list the platforms `aarch64-linux`, `arm64-darwin-25` (this machine), `ruby` and `x86_64-linux`. For reference, on 2026-10-02 it was:

```
GEM
  remote: https://rubygems.org/
  specs:
    base64 (0.3.0)
    drb (2.2.3)
    logger (1.7.0)
    minitest (6.0.6)
      drb (~> 2.0)
      prism (~> 1.5)
    mustermann (3.1.1)
    nio4r (2.7.5)
    prism (1.9.0)
    puma (7.2.1)
      nio4r (~> 2.0)
    rack (3.2.7)
    rack-protection (4.2.1)
      base64 (>= 0.1.0)
      logger (>= 1.6.0)
      rack (>= 3.0.0, < 4)
    rack-session (2.1.2)
      base64 (>= 0.1.0)
      rack (>= 3.0.0)
    rack-test (2.2.0)
      rack (>= 1.3)
    rake (13.4.2)
    sinatra (4.2.1)
      logger (>= 1.6.0)
      mustermann (~> 3.0)
      rack (>= 3.0.0, < 4)
      rack-protection (= 4.2.1)
      rack-session (>= 2.0.0, < 3)
      tilt (~> 2.0)
    tilt (2.9.0)

PLATFORMS
  aarch64-linux
  arm64-darwin-25
  ruby
  x86_64-linux

DEPENDENCIES
  minitest
  puma (~> 7.0)
  rack-test
  rake
  sinatra (~> 4.1)

CHECKSUMS
  base64 (0.3.0) sha256=27337aeabad6ffae05c265c450490628ef3ebd4b67be58257393227588f5a97b
  bundler (4.0.20) sha256=7978a8ac648767f5e635bc522445b79e80a52b907a39a36c2d8085ed6bc762ae
  drb (2.2.3) sha256=0b00d6fdb50995fe4a45dea13663493c841112e4068656854646f418fda13373
  logger (1.7.0) sha256=196edec7cc44b66cfb40f9755ce11b392f21f7967696af15d274dde7edff0203
  minitest (6.0.6) sha256=153ea36d1d987a62942382b61075745042a2b3123b1cd48f4c3675af9cc7d6f1
  mustermann (3.1.1) sha256=4c6170c7234d5499c345562ba7c7dfe73e1754286dcc1abb053064d66a127198
  nio4r (2.7.5) sha256=6c90168e48fb5f8e768419c93abb94ba2b892a1d0602cb06eef16d8b7df1dca1
  prism (1.9.0) sha256=7b530c6a9f92c24300014919c9dcbc055bf4cdf51ec30aed099b06cd6674ef85
  puma (7.2.1) sha256=d7bf0e9cabd532e0d401e142cd94e3ac531e993610e2d80e6fbf9c26961414b0
  rack (3.2.7) sha256=93e13e1c24f93556671d85d2d79fa228c3485815c50d7e2f265b5330c6528fb7
  rack-protection (4.2.1) sha256=cf6e2842df8c55f5e4d1a4be015e603e19e9bc3a7178bae58949ccbb58558bac
  rack-session (2.1.2) sha256=595434f8c0c3473ae7d7ac56ecda6cc6dfd9d37c0b2b5255330aa1576967ffe8
  rack-test (2.2.0) sha256=005a36692c306ac0b4a9350355ee080fd09ddef1148a5f8b2ac636c720f5c463
  rake (13.4.2) sha256=cb825b2bd5f1f8e91ca37bddb4b9aaf345551b4731da62949be002fa89283701
  sinatra (4.2.1) sha256=b7aeb9b11d046b552972ade834f1f9be98b185fa8444480688e3627625377080
  tilt (2.9.0) sha256=da5735d0280bba96e9a91041bb14aee435ccad5c17b0fa519249ae543d9aa3a5

BUNDLED WITH
  4.0.20
```

- [ ] **Step 3: Implement**

Create `playground/control/lib/play.rb` (Task 5 adds `require_relative "play/sessions"` and Task 6 `require_relative "play/ctl"` at its end):

```ruby
# frozen_string_literal: true

# The hosted playground's control plane (spec
# docs/superpowers/specs/2026-10-02-web-playground-sp2-design.md, §5): the
# entry page, session creation, limits, the reaper and the stop switch.
# config.ru wires the pieces; bin/playctl reuses them for the operator.
module Play
  # Wall clock (Unix seconds), monotonic clock and sleep, in one object so
  # that tests can replace all three (test/fakes.rb, FakeClock).
  class Clock
    def now
      Time.now.to_i
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sleep(seconds)
      Kernel.sleep(seconds)
    end
  end

  # One event per line: `play event=<name> key=value ...` (spec §5.11).
  # Callers pass only handles, counts, reasons and redacted Docker output:
  # never a session id, a preview id, a session host name or an IP address.
  class EventLog
    def initialize(io)
      @io = io
      @mutex = Mutex.new
    end

    def event(name, **fields)
      line = +"play event=#{name}"
      fields.each { |key, value| line << " #{key}=#{format(value)}" }
      @mutex.synchronize do
        @io.puts(line)
        @io.flush
      end
    end

    private

    def format(value)
      text = value.to_s
      return text if text.match?(/\A[^\s"=\\]+\z/)

      "\"#{text.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }}\""
    end
  end
end

require_relative "play/config"
require_relative "play/subnets"
require_relative "play/templates"
require_relative "play/docker_cli"
require_relative "play/limits"
require_relative "play/probe"
```

Create `playground/control/lib/play/config.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "uri"

module Play
  # The control plane's settings, read once from the environment (spec
  # §5.10). Every value is checked here, so the rest of the code can trust
  # it; a missing or malformed value raises Config::Error, and config.ru
  # prints "error: <message>" and exits 1. An empty variable counts as unset.
  class Config
    class Error < StandardError; end

    DEFAULTS = {
      "PLAY_ROUTER_URL" => "http://ctplay-router",
      "PLAY_ROUTER_FILTERS" => "label=service=cybertrain-play-router,label=role=web",
      "PLAY_CLIENT_IP_HEADER" => "",
      "PLAY_MAX_SESSIONS" => "5",
      "PLAY_MAX_SESSIONS_PER_IP" => "1",
      "PLAY_CREATE_LIMIT" => "3",
      "PLAY_CREATE_WINDOW" => "600",
      "PLAY_TTL" => "1800",
      "PLAY_IDLE_TIMEOUT" => "300",
      "PLAY_READY_TIMEOUT" => "30",
      "PLAY_REAP_INTERVAL" => "5",
      "PLAY_SUBNET_POOL" => "10.250.0.0/16",
      "PLAY_SUBNET_PREFIX" => "28",
      "PLAY_SESSION_MEMORY" => "1536m",
      "PLAY_SESSION_CPUS" => "1",
      "PLAY_SESSION_PIDS" => "512",
      "PLAY_TMPFS_TMP" => "256m",
      "PLAY_TMPFS_HOME" => "128m",
      "PLAY_TMPFS_WORKSPACE" => "256m",
      "PLAY_TMPFS_CACHE" => "64m",
      "PLAY_RUNTIME" => "",
      "PLAY_DATA_DIR" => "/data",
      "PLAY_CODESPACES_URL" => "https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1"
    }.freeze
    REQUIRED = %w[PLAY_PUBLIC_URL PLAY_SESSION_IMAGE PLAY_ABUSE_CONTACT].freeze

    attr_reader :scheme, :domain, :port, :session_image, :router_url, :router_filters, :allowed_origins,
                :client_ip_header, :max_sessions, :max_sessions_per_ip, :create_limit, :create_window, :ttl,
                :idle_timeout, :ready_timeout, :reap_interval, :subnet_pool, :subnet_prefix, :session_memory,
                :session_cpus, :session_pids, :tmpfs_tmp, :tmpfs_home, :tmpfs_workspace, :tmpfs_cache, :runtime,
                :data_dir, :codespaces_url, :abuse_contact

    def self.from_env(env = ENV)
      new(env.to_h)
    end

    def initialize(env)
      @env = env
      parse_public_url(value("PLAY_PUBLIC_URL"))
      @session_image = matching("PLAY_SESSION_IMAGE", /\A\S+\z/, "an image reference")
      @abuse_contact = matching("PLAY_ABUSE_CONTACT", /\A[^\s@]+@[^\s@]+\z/, "an email address")
      @router_url = http_url("PLAY_ROUTER_URL")
      @router_filters = value("PLAY_ROUTER_FILTERS").split(",").map(&:strip).reject(&:empty?)
      if @router_filters.empty? || @router_filters.any? { |f| !f.match?(/\A[a-z_]+=\S+\z/) }
        raise Error, "PLAY_ROUTER_FILTERS must be docker ps filters such as label=role=web, separated by commas"
      end
      @allowed_origins = parse_origins(@env["PLAY_ALLOWED_ORIGINS"].to_s)
      @client_ip_header = matching("PLAY_CLIENT_IP_HEADER", /\A[A-Za-z0-9-]*\z/, "a header name such as CF-Connecting-IP")
      @max_sessions = whole("PLAY_MAX_SESSIONS")
      @max_sessions_per_ip = whole("PLAY_MAX_SESSIONS_PER_IP")
      @create_limit = whole("PLAY_CREATE_LIMIT")
      @create_window = whole("PLAY_CREATE_WINDOW")
      @ttl = whole("PLAY_TTL")
      @idle_timeout = whole("PLAY_IDLE_TIMEOUT")
      raise Error, "PLAY_IDLE_TIMEOUT must be more than 60 seconds (got #{@idle_timeout})" if @idle_timeout <= 60

      @ready_timeout = whole("PLAY_READY_TIMEOUT")
      @reap_interval = whole("PLAY_REAP_INTERVAL")
      @subnet_pool = value("PLAY_SUBNET_POOL")
      @subnet_prefix = whole("PLAY_SUBNET_PREFIX")
      Subnets.validate!(@subnet_pool, @subnet_prefix)
      @session_memory = size("PLAY_SESSION_MEMORY")
      @session_cpus = matching("PLAY_SESSION_CPUS", /\A(?=.*[1-9])\d+(\.\d+)?\z/, "a number of CPUs such as 1 or 0.5")
      @session_pids = whole("PLAY_SESSION_PIDS")
      @tmpfs_tmp = size("PLAY_TMPFS_TMP")
      @tmpfs_home = size("PLAY_TMPFS_HOME")
      @tmpfs_workspace = size("PLAY_TMPFS_WORKSPACE")
      @tmpfs_cache = size("PLAY_TMPFS_CACHE")
      @runtime = matching("PLAY_RUNTIME", /\A([a-z][a-z0-9_.-]*)?\z/, "a runtime name such as runsc, or empty")
      @data_dir = matching("PLAY_DATA_DIR", %r{\A/\S*\z}, "an absolute path")
      @codespaces_url = http_url("PLAY_CODESPACES_URL")
    end

    # ":8080" when PLAY_PUBLIC_URL names a port, "" for the scheme's default.
    def port_suffix
      port ? ":#{port}" : ""
    end

    def public_origin
      "#{scheme}://#{domain}#{port_suffix}"
    end

    # The Rack env key of PLAY_CLIENT_IP_HEADER (nil when unset: REMOTE_ADDR).
    def client_ip_env_key
      client_ip_header.empty? ? nil : "HTTP_#{client_ip_header.upcase.tr("-", "_")}"
    end

    # The address POST /sessions redirects to (spec §5.2): the editor opens
    # the blog and, rendered, its guide.
    def editor_url(sid)
      origin = "#{scheme}://#{sid}.#{domain}#{port_suffix}"
      guide = "vscode-remote://#{sid}.#{domain}#{port_suffix}/workspace/blog/PLAYGROUND.md"
      payload = JSON.generate([["openFile", guide]])
      "#{origin}/?folder=#{URI.encode_www_form_component("/workspace/blog")}&payload=#{URI.encode_www_form_component(payload)}"
    end

    # VSCODE_PROXY_URI of a session: where its editor opens port 3000.
    def proxy_uri(pid)
      "#{scheme}://{{port}}-#{pid}.#{domain}#{port_suffix}"
    end

    # Every session host, as a CSP source (the entry page's form-action).
    def session_hosts_source
      "#{scheme}://*.#{domain}#{port_suffix}"
    end

    private

    def value(name)
      raw = @env[name].to_s
      return raw unless raw.empty?
      raise Error, "#{name} is required" if REQUIRED.include?(name)

      DEFAULTS.fetch(name)
    end

    def matching(name, pattern, what)
      text = value(name)
      raise Error, "#{name} must be #{what} (got #{text.inspect})" unless text.match?(pattern)

      text
    end

    def whole(name)
      text = value(name)
      number = Integer(text, 10, exception: false)
      raise Error, "#{name} must be a whole number above 0 (got #{text.inspect})" unless number&.positive?

      number
    end

    def size(name)
      matching(name, /\A[1-9]\d*[kmg]\z/, "a size such as 256m")
    end

    def http_url(name)
      text = value(name)
      uri = URI.parse(text)
      raise Error, "#{name} must be an http or https URL (got #{text.inspect})" unless uri.is_a?(URI::HTTP) && uri.host

      text
    rescue URI::InvalidURIError
      raise Error, "#{name} must be an http or https URL (got #{text.inspect})"
    end

    def parse_public_url(text)
      uri = URI.parse(text)
      bare = uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? &&
             ["", "/"].include?(uri.path) && uri.query.nil? && uri.fragment.nil?
      raise Error, "PLAY_PUBLIC_URL must be a scheme and a host such as https://play.example (got #{text.inspect})" unless bare

      @scheme = uri.scheme
      @domain = uri.host.downcase
      @port = uri.port == uri.default_port ? nil : uri.port
    rescue URI::InvalidURIError
      raise Error, "PLAY_PUBLIC_URL must be a scheme and a host such as https://play.example (got #{text.inspect})"
    end

    def parse_origins(text)
      items = text.split(",").map(&:strip).reject(&:empty?)
      return [public_origin] if items.empty?

      items.map do |item|
        uri = URI.parse(item)
        unless uri.is_a?(URI::HTTP) && uri.host && uri.path.empty? && uri.query.nil? && uri.userinfo.nil?
          raise Error, "PLAY_ALLOWED_ORIGINS must list origins such as https://example.org (got #{item.inspect})"
        end

        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host.downcase}#{port}"
      rescue URI::InvalidURIError
        raise Error, "PLAY_ALLOWED_ORIGINS must list origins such as https://example.org (got #{item.inspect})"
      end
    end
  end
end
```

Create `playground/control/lib/play/subnets.rb`:

```ruby
# frozen_string_literal: true

require "ipaddr"
require "socket"

module Play
  # Cuts PLAY_SUBNET_POOL into /PLAY_SUBNET_PREFIX networks, one per session
  # (spec §5.5): explicit small subnets keep Docker's default address pools
  # (31 networks in all) out of the way.
  class Subnets
    # Docker's default local pools: 172.17-31.0.0/16 and 192.168.0.0/16.
    DOCKER_DEFAULT_POOLS = ((17..31).map { |n| "172.#{n}.0.0/16" } + ["192.168.0.0/16"]).map { |c| IPAddr.new(c) }.freeze
    # A /29 holds 8 addresses: the reserved ones, the session and two routers.
    MAX_PREFIX = 29

    def self.validate!(pool, prefix)
      net = parse_pool(pool)
      unless prefix.between?(net.prefix, MAX_PREFIX)
        raise Config::Error, "PLAY_SUBNET_PREFIX must be between #{net.prefix} and #{MAX_PREFIX} for #{pool} (got #{prefix})"
      end
      clash = DOCKER_DEFAULT_POOLS.find { |d| d.include?(net) || net.include?(d) }
      return unless clash

      raise Config::Error, "PLAY_SUBNET_POOL #{pool} overlaps Docker's default address pool #{clash}/#{clash.prefix}"
    end

    def self.parse_pool(pool)
      net = IPAddr.new(pool)
      raise IPAddr::InvalidAddressError unless net.ipv4? && pool.include?("/")

      net
    rescue IPAddr::Error
      raise Config::Error, "PLAY_SUBNET_POOL must be an IPv4 network such as 10.250.0.0/16 (got #{pool.inspect})"
    end

    def initialize(pool, prefix)
      @pool = self.class.parse_pool(pool)
      @prefix = prefix
    end

    # The lowest subnet of the pool that overlaps none of TAKEN (CIDR
    # strings: the session networks' subnets and the ones Docker refused),
    # or nil when the pool is used up.
    def first_free(taken)
      used = taken.filter_map do |cidr|
        IPAddr.new(cidr)
      rescue IPAddr::Error
        nil
      end
      step = 2**(32 - @prefix)
      (2**(@prefix - @pool.prefix)).times do |i|
        candidate = IPAddr.new(@pool.to_i + (i * step), Socket::AF_INET).mask(@prefix)
        next if used.any? { |u| u.include?(candidate) || candidate.include?(u) }

        return "#{candidate}/#{@prefix}"
      end
      nil
    end
  end
end
```

Create `playground/control/lib/play/templates.rb`:

```ruby
# frozen_string_literal: true

module Play
  # Every docker command line the control plane runs, as argv arrays (spec
  # §5.4). Pure functions: the only variable parts are the handle, the
  # session and preview ids, the subnet and the two times, all made by the
  # control plane, plus the operator's PLAY_* settings. No argument takes a
  # value from a visitor's request, and nothing goes through a shell.
  module Templates
    module_function

    def labels(handle, created, expires)
      ["--label", "cybertrain-play.role=session",
       "--label", "cybertrain-play.handle=#{handle}",
       "--label", "cybertrain-play.created-at=#{created}",
       "--label", "cybertrain-play.expires-at=#{expires}"]
    end

    def network_create(handle:, subnet:, created:, expires:)
      ["docker", "network", "create",
       "--driver", "bridge",
       "--internal",
       "--subnet", subnet,
       "--opt", "com.docker.network.bridge.inhibit_ipv4=true",
       *labels(handle, created, expires),
       "ctplay-n-#{handle}"]
    end

    def network_connect(handle:, container:)
      ["docker", "network", "connect", "ctplay-n-#{handle}", container]
    end

    # The flags that confine a session (spec §5.4), in one place.
    # playground/web-smoke.sh runs its session with exactly these
    # (# BEGIN hardened run ... # END hardened run); test/drift_test.rb
    # compares the two.
    def hardening(config)
      ["--user", "1000:1000",
       "--cap-drop", "ALL",
       "--security-opt", "no-new-privileges",
       "--read-only",
       "--tmpfs", "/tmp:rw,exec,nosuid,nodev,size=#{config.tmpfs_tmp},mode=1777",
       "--tmpfs", "/home/dev:rw,nosuid,nodev,size=#{config.tmpfs_home},uid=1000,gid=1000,mode=0755",
       "--tmpfs", "/workspace:rw,exec,nosuid,nodev,size=#{config.tmpfs_workspace},uid=1000,gid=1000,mode=0755",
       "--tmpfs", "/opt/cybertrain-cache:rw,nosuid,nodev,size=#{config.tmpfs_cache},uid=1000,gid=1000,mode=0755",
       "--memory", config.session_memory, "--memory-swap", config.session_memory,
       "--cpus", config.session_cpus,
       "--pids-limit", config.session_pids.to_s]
    end

    def session_run(config, handle:, sid:, pid:, created:, expires:)
      argv = ["docker", "run",
              "--detach", "--rm", "--init",
              "--pull", "never",
              "--name", "ctplay-s-#{handle}",
              "--hostname", "playground",
              "--network", "ctplay-n-#{handle}",
              "--network-alias", "s-#{sid}",
              "--network-alias", "p-#{pid}",
              *labels(handle, created, expires),
              *hardening(config),
              "--log-driver", "json-file", "--log-opt", "max-size=1m", "--log-opt", "max-file=1"]
      argv += ["--runtime", config.runtime] unless config.runtime.empty?
      argv + ["--env", "VSCODE_PROXY_URI=#{config.proxy_uri(pid)}",
              "--env", "PLAYGROUND_ENDS_AT=#{expires}",
              "--env", "PLAYGROUND_IDLE_TIMEOUT=#{config.idle_timeout}",
              config.session_image]
    end

    def remove_container(handle:)
      ["docker", "rm", "--force", "ctplay-s-#{handle}"]
    end

    def network_containers(handle:)
      ["docker", "network", "inspect", "--format", "{{range $id, $c := .Containers}}{{$id}} {{end}}", "ctplay-n-#{handle}"]
    end

    def network_disconnect(handle:, container:)
      ["docker", "network", "disconnect", "--force", "ctplay-n-#{handle}", container]
    end

    def network_remove(handle:)
      ["docker", "network", "rm", "ctplay-n-#{handle}"]
    end

    def list_containers
      ["docker", "ps", "--all", "--no-trunc", "--filter", "label=cybertrain-play.role=session",
       "--format", "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Label \"cybertrain-play.handle\"}}\t" \
                   "{{.Label \"cybertrain-play.created-at\"}}\t{{.Label \"cybertrain-play.expires-at\"}}"]
    end

    def list_networks
      ["docker", "network", "ls", "--no-trunc", "--filter", "label=cybertrain-play.role=session",
       "--format", "{{.ID}}\t{{.Name}}\t{{.Label \"cybertrain-play.handle\"}}\t{{.Label \"cybertrain-play.created-at\"}}"]
    end

    def network_subnet(handle:)
      ["docker", "network", "inspect", "--format", "{{(index .IPAM.Config 0).Subnet}}", "ctplay-n-#{handle}"]
    end

    def list_routers(config)
      ["docker", "ps", *config.router_filters.flat_map { |f| ["--filter", f] },
       "--filter", "status=running", "--format", "{{.ID}}"]
    end

    def stats(names)
      ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}", *names]
    end

    def image_inspect(config)
      ["docker", "image", "inspect", "--format", "{{.Id}}", config.session_image]
    end

    def version
      ["docker", "version", "--format", "{{.Server.Version}}"]
    end
  end
end
```

Create `playground/control/lib/play/docker_cli.rb`:

```ruby
# frozen_string_literal: true

require "open3"

module Play
  # The one place that runs `docker` (spec §5.4): an argv array straight to
  # the process (never a shell), a time limit after which the process is
  # killed, and redaction for anything that reaches the log (spec §5.11).
  class DockerCLI
    Result = Struct.new(:status, :stdout, :stderr) do
      def ok?
        status.zero?
      end
    end

    class Timeout < StandardError; end

    # TEXT for the log: each SECRETS value (name => value) becomes <name>,
    # any other 32-digit hex number <hex32>; whitespace runs collapse and the
    # result stops at 200 characters.
    def self.redact(text, secrets = {})
      out = text.to_s.dup
      secrets.each { |name, value| out = out.gsub(value, "<#{name}>") unless value.to_s.empty? }
      out = out.gsub(/\h{32}/, "<hex32>").gsub(/\s+/, " ").strip
      out[0, 200]
    end

    def run(argv, timeout:)
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        unless wait.join(timeout)
          begin
            Process.kill("KILL", wait.pid)
          rescue Errno::ESRCH
            nil
          end
          wait.join
          # Only the first words: the rest of an argv can hold a session id.
          raise Timeout, "#{argv.first(3).join(" ")} did not finish within #{timeout} s"
        end
        status = wait.value
        Result.new(status.exitstatus || (128 + status.termsig.to_i), out.value.to_s, err.value.to_s)
      end
    end
  end
end
```

Create `playground/control/lib/play/limits.rb`:

```ruby
# frozen_string_literal: true

require "ipaddr"

module Play
  # Per-client limits (spec §5.6): the client key of a request, and the
  # sliding window of successful creations per key.
  class Limits
    # The client of a Rack request: the address in HEADER_KEY (the Rack env
    # key of PLAY_CLIENT_IP_HEADER, such as HTTP_CF_CONNECTING_IP) when it
    # holds one, else REMOTE_ADDR. IPv4 counts per address, IPv6 per /64.
    def self.client_key(env, header_key)
      (header_key && key_for(env[header_key])) || key_for(env["REMOTE_ADDR"]) || "unknown"
    end

    def self.key_for(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A[0-9A-Fa-f:.]+\z/)

      ip = IPAddr.new(text)
      ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
      ip.ipv4? ? ip.to_s : "#{ip.mask(64)}/64"
    rescue IPAddr::Error
      nil
    end

    def initialize(limit:, window:, clock:)
      @limit = limit
      @window = window
      @clock = clock
      @hits = {}
      @mutex = Mutex.new
    end

    # Seconds until KEY may create again: 0 when it may now.
    def retry_after(key)
      @mutex.synchronize do
        hits = fresh(key)
        hits.size < @limit ? 0 : [(hits.first + @window - @clock.monotonic).ceil, 1].max
      end
    end

    # Counts one successful creation for KEY.
    def record(key)
      @mutex.synchronize do
        @hits[key] = fresh(key) << @clock.monotonic
        sweep if @hits.size > 1000
      end
    end

    private

    def fresh(key)
      now = @clock.monotonic
      hits = (@hits[key] || []).select { |t| now - t < @window }
      hits.empty? ? @hits.delete(key) : @hits[key] = hits
      hits
    end

    def sweep
      now = @clock.monotonic
      @hits.delete_if { |_, hits| now - hits.last >= @window }
    end
  end
end
```

Create `playground/control/lib/play/probe.rb`:

```ruby
# frozen_string_literal: true

require "net/http"
require "uri"

module Play
  # The readiness check of a new session (spec §5.7): GET /healthz through
  # the router with the editor's Host. A 200 whose body names a "status"
  # means the router is attached, Docker's DNS knows the alias and
  # code-server answers. code-server's /healthz does not count as activity,
  # so the check does not hold off its idle timeout.
  class Probe
    def initialize(config, timeout: 2)
      @uri = URI.join(config.router_url, "/healthz")
      @domain = config.domain
      @timeout = timeout
    end

    def ready?(sid)
      http = Net::HTTP.new(@uri.host, @uri.port, nil)
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout
      response = http.request(Net::HTTP::Get.new(@uri.request_uri, "Host" => "#{sid}.#{@domain}"))
      response.code == "200" && response.body.to_s.include?('"status"')
    rescue StandardError
      false
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/saeki/work/cybertrain/playground/control
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
BUNDLE_PATH="$SDD/bundle" bundle exec rake test 2>&1 | tail -n 1
for f in lib/play.rb lib/play/*.rb; do ruby -c "$f" > /dev/null || echo "syntax: $f"; done
```

Expected: `25 runs, 128 assertions, 0 failures, 0 errors, 0 skips` and no `syntax:` line. Run `bundle exec rake test` twice more: minitest shuffles the order, and the counts must not change.

- [ ] **Step 5: Commit**

```bash
cd /Users/saeki/work/cybertrain
git add playground/control/Gemfile playground/control/Gemfile.lock playground/control/Rakefile playground/control/lib/play.rb playground/control/lib/play/config.rb playground/control/lib/play/subnets.rb playground/control/lib/play/templates.rb playground/control/lib/play/docker_cli.rb playground/control/lib/play/limits.rb playground/control/lib/play/probe.rb playground/control/test/test_helper.rb playground/control/test/fakes.rb playground/control/test/config_test.rb playground/control/test/subnets_test.rb playground/control/test/templates_test.rb playground/control/test/limits_test.rb playground/control/test/drift_test.rb
git status --short playground/control
git commit -m "Control: settings, docker argv templates, docker CLI, subnets, limits, probe

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from `git status --short playground/control` before the commit: only `A` lines (no `.bundle/` or `vendor/`: the gems live in `$SDD/bundle`).

---

### Task 5: Sessions: creation, teardown, the reaper

**Files:**
- Create: `playground/control/lib/play/sessions.rb`
- Modify: `playground/control/lib/play.rb` (one `require_relative` at the end)
- Modify: `playground/control/test/fakes.rb` (append `FakeDocker` and `FakeProbe`)
- Test: `playground/control/test/sessions_test.rb`

**Interfaces:**
- Consumes: Task 4's `Play::Config`, `Play::Templates`, `Play::DockerCLI` (`Result`, `Timeout`, `redact`), `Play::Subnets`, `Play::Limits`, `Play::EventLog`, `FakeClock`, `PlayTestHelpers#play_config`.
- Produces (Task 6's routes and `playctl` rely on these):
  - `Play::Sessions.new(config:, docker:, probe:, clock:, log:, random: SecureRandom)`; `Play::Sessions.handle_for(sid)`.
  - `#create(client)` → `Play::Sessions::Created` (`editor_url`, `handle`) or `Play::Sessions::Refusal` (`reason`, `retry_after`, `message`, `ends_at`); reasons `:paused` (300 s), `:unavailable` (300 s, `message` "It is starting up", "Its session image is missing" or "It cannot reach Docker"), `:per_ip` (seconds left, `ends_at`), `:rate` (seconds until the window frees), `:full` (60 s), `:failed` (60 s).
  - `#status` → `{accepting:, paused:, live:, capacity:, ttl_seconds:}` (in that order); `#closed_message`; `#pause_message`; `#healthy?`; `#internal_list` → `[{handle:, state:, created_at:, expires_at:, client:, cpu:, memory:}]`; `#note_refusal(reason)`.
  - `#teardown(handle, reason:, created_at: nil)` → true when nothing is left; `#kill_all(reason: "killed")`; `#with_create_lock { }`; `#reap` → true when it reached Docker; `#start_reaper` (a thread); `#check_availability`; `#list_containers`, `#list_networks`, `#list_routers`, `#read_stats(names)`.
  - Log lines: `play event=created handle=<h> subnet=<cidr> ready_ms=<n> live=<n>/<cap>`, `play event=ended handle=<h> reason=<ttl|idle|exited|orphan|killed|failed> age_s=<n>`, `play event=refused reason=<reason> live=<n>/<cap>`, `play event=docker_error step=<step> handle=<h> status=<n> stderr="<redacted>"`, `play event=unavailable reason=<docker_unreachable|image_missing> …`, `play event=available`, `play event=suspect handle=<h> cpu=<n>%`, `play event=error step=create handle=<h> message="<redacted>"`.
  - Tests: `FakeDocker` (`on(key, *answers)`, `default(key, answer)`, `calls`, `calls_for(key)`, `keys`, `FakeDocker.ok(stdout)`, `FakeDocker.fail(stderr)`; keys `run`, `rm`, `stats`, `version`, `network create|connect|disconnect|inspect|rm|ls`, `image inspect`, `ps sessions`, `ps routers`), `FakeProbe.new(ready_after: n | nil)`.

How a creation goes (inside the host-wide lock `PLAY_DATA_DIR/create.lock` until the container runs): the per-client limits (memory only), `docker ps` (the cap counts `running` and `created` containers), the running routers (none: refuse before creating anything), the network on the lowest free /28 (a "Pool overlaps" answer marks that range unusable and tries the next, three tries), `docker network connect` for every router, `docker run`; then, outside the lock, `/healthz` through the router every 250 ms up to `PLAY_READY_TIMEOUT`. Any failure, an unexpected exception included, removes everything of the new session and logs `ended reason=failed`. The reaper's pass: list containers, networks and routers; remove expired (`ttl`) and not-running (`exited`) sessions; remove a network without a container when this process knows the session (`idle`: its container ended by itself, through code-server's idle timeout or the container's own end) or when it is at least 60 s old (`orphan`; a younger one may be another control plane's creation in progress during a deploy); attach every running router to every live session network once; forget what Docker no longer has and adopt live sessions this process did not start (client unknown); once a minute read `docker stats` and log one `suspect` line after ten samples in a row at 90 % CPU or more; honour the `kill-all` request file.

Notes on the spec's text, applied below:
- Correction: the routers are listed before the network is created (`ps sessions`, `ps routers`, `network ls`, `network create`, `network connect`, `run`), not after it as spec §8.2's list of calls says: spec §5.4 requires that nothing is created when no router runs, which needs the list first.
- The teardown keeps spec §5.4's order and the code says why (spec §15, correction 4): removing the container first closes the router's connections to it; detaching the router first left a pooled connection that hung for minutes. The test `test_teardown_disconnects_every_attachment_before_removing_the_network` pins the order.
- `Session` gains `cpu`, `memory` and `hot` (the CPU samples) beside spec §5.3's fields, for `playctl status` and the `suspect` line. Ids never enter a record.
- The reaper thread sets `abort_on_exception` on itself rather than process-wide (`Thread.abort_on_exception = true` in spec §5.1): the effect for the reaper is the same (an unexpected error ends the process, Docker restarts it, the first pass reconciles), and Puma's own threads keep their own error handling.
- A creation that raises an unexpected error is cleaned up and logged with its message redacted, never with the exception's raw text.

- [ ] **Step 1: Write the failing tests**

Append to `playground/control/test/fakes.rb`:

```ruby

# Answers each docker argv from a script keyed by its leading words ("run",
# "network create", "ps sessions", "ps routers", ...) and records every argv.
# An answer is a Play::DockerCLI::Result, :timeout (raises like a hung
# docker), or a Proc that gets the argv. Queued answers (#on) come first,
# then the default for the key (#default), then success with no output.
class FakeDocker
  attr_reader :calls

  def self.ok(stdout = "")
    Play::DockerCLI::Result.new(0, stdout, "")
  end

  def self.fail(stderr, status: 1)
    Play::DockerCLI::Result.new(status, "", stderr)
  end

  def initialize
    @calls = []
    @queued = Hash.new { |hash, key| hash[key] = [] }
    @defaults = {}
  end

  def on(key, *answers)
    @queued[key].concat(answers)
    self
  end

  def default(key, answer)
    @defaults[key] = answer
    self
  end

  def run(argv, timeout:)
    raise ArgumentError, "timeout must be positive" unless timeout.positive?

    @calls << argv
    key = self.class.key(argv)
    answer = @queued[key].empty? ? @defaults.fetch(key, self.class.ok) : @queued[key].shift
    answer = answer.call(argv) if answer.respond_to?(:call)
    raise Play::DockerCLI::Timeout, "#{argv.first(3).join(" ")} did not finish within #{timeout} s" if answer == :timeout

    answer
  end

  def self.key(argv)
    words = argv.drop(1)
    case words.first
    when "network", "image" then words.first(2).join(" ")
    when "ps" then argv.include?("label=cybertrain-play.role=session") ? "ps sessions" : "ps routers"
    else words.first
    end
  end

  def calls_for(key)
    @calls.select { |argv| self.class.key(argv) == key }
  end

  def keys
    @calls.map { |argv| self.class.key(argv) }
  end
end

# Ready on the Nth call (ready_after: N), or never (ready_after: nil).
class FakeProbe
  attr_reader :calls

  def initialize(ready_after: 1)
    @ready_after = ready_after
    @calls = []
  end

  def ready?(sid)
    @calls << sid
    !@ready_after.nil? && @calls.size >= @ready_after
  end
end
```

Create `playground/control/test/sessions_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"

class SessionsTest < Minitest::Test
  include PlayTestHelpers

  ROUTER = "f00dbabe00000001"

  def setup
    @docker = FakeDocker.new
    @docker.default("ps routers", FakeDocker.ok("#{ROUTER}\n"))
    @clock = FakeClock.new
    @probe = FakeProbe.new(ready_after: 2)
    @log = StringIO.new
  end

  def sessions(env = {})
    @sessions ||= Play::Sessions.new(config: play_config(env), docker: @docker, probe: @probe, clock: @clock,
                                     log: Play::EventLog.new(@log))
  end

  def container(handle, state, created: @clock.now - 100, expires: @clock.now + 1700)
    "c#{handle}\tctplay-s-#{handle}\t#{state}\t#{handle}\t#{created}\t#{expires}\n"
  end

  def network(handle, created: @clock.now - 100)
    "n#{handle}\tctplay-n-#{handle}\t#{handle}\t#{created}\n"
  end

  # [sid, pid] from the last `docker run`.
  def ids
    argv = @docker.calls_for("run").last
    argv.each_cons(2).select { |flag, _| flag == "--network-alias" }.map { |_, value| value[2..] }
  end

  def handle_of_last_network
    @docker.calls_for("network create").last.last.delete_prefix("ctplay-n-")
  end

  def assert_removed(handle)
    assert_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{handle}"]
    inspected = @docker.calls.include?(Play::Templates.network_containers(handle: handle))
    removed = @docker.calls.include?(["docker", "network", "rm", "ctplay-n-#{handle}"])
    assert inspected && removed, "the network ctplay-n-#{handle} was not removed"
  end

  # ---- creation ----------------------------------------------------------

  def test_create_lists_creates_attaches_runs_then_waits_for_the_router
    result = sessions.create("203.0.113.7")

    assert_kind_of Play::Sessions::Created, result
    assert_equal ["ps sessions", "ps routers", "network ls", "network create", "network connect", "run"], @docker.keys
    sid, pid = ids
    assert_match(/\A[0-9a-f]{32}\z/, sid)
    assert_match(/\A[0-9a-f]{32}\z/, pid)
    refute_equal sid, pid
    handle = Digest::SHA256.hexdigest(sid)[0, 16]
    assert_equal handle, result.handle
    assert_equal ["docker", "network", "connect", "ctplay-n-#{handle}", ROUTER], @docker.calls_for("network connect").first
    assert_includes @docker.calls_for("network create").first, "10.250.0.0/28"
    assert_equal sessions.config.editor_url(sid), result.editor_url
    assert_equal [sid, sid], @probe.calls
    assert_equal "play event=created handle=#{handle} subnet=10.250.0.0/28 ready_ms=250 live=1/5\n", @log.string
  end

  def test_the_next_session_gets_the_next_free_subnet
    @docker.default("network ls", FakeDocker.ok(network("a" * 16) + network("b" * 16)))
    @docker.on("network inspect", FakeDocker.ok("10.250.0.0/28\n"), FakeDocker.ok("10.250.0.32/28\n"))
    sessions.create("203.0.113.7")
    assert_includes @docker.calls_for("network create").first, "10.250.0.16/28"
  end

  def test_pool_overlaps_moves_on_and_gives_up_after_three
    overlap = FakeDocker.fail("Error response from daemon: invalid pool request: Pool overlaps with other one on this address space")
    @docker.on("network create", overlap, overlap)
    assert_kind_of Play::Sessions::Created, sessions.create("203.0.113.7")
    subnets = @docker.calls_for("network create").map { |argv| argv[argv.index("--subnet") + 1] }
    assert_equal ["10.250.0.0/28", "10.250.0.16/28", "10.250.0.32/28"], subnets

    @docker.on("network create", overlap, overlap, overlap)
    refusal = sessions.create("198.51.100.1")
    assert_equal :failed, refusal.reason
    assert_equal 6, @docker.calls_for("network create").size
    assert_empty(@docker.calls_for("run").drop(1))
  end

  # ---- refusals: no Docker call but the listings --------------------------

  def test_paused_refuses_without_touching_docker
    File.write(File.join(sessions.config.data_dir, "paused"), "maintenance until 14:00 UTC\n")
    refusal = sessions.create("203.0.113.7")
    assert_equal [:paused, 300, "Maintenance until 14:00 UTC"], [refusal.reason, refusal.retry_after, refusal.message]
    assert_empty @docker.calls
    assert_includes @log.string, "play event=refused reason=paused live=0/5\n"
  end

  def test_full_counts_starting_containers_too
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running") + container("b" * 16, "created")))
    refusal = sessions("PLAY_MAX_SESSIONS" => "2").create("203.0.113.7")
    assert_equal [:full, 60], [refusal.reason, refusal.retry_after]
    assert_equal ["ps sessions"], @docker.keys
  end

  def test_no_router_refuses_before_creating_anything
    @docker.default("ps routers", FakeDocker.ok(""))
    refusal = sessions.create("203.0.113.7")
    assert_equal [:unavailable, 300, "It is starting up"], [refusal.reason, refusal.retry_after, refusal.message]
    assert_equal ["ps sessions", "ps routers"], @docker.keys
  end

  def test_one_live_session_per_client_and_an_ipv6_64_is_one_client
    key = ->(ip) { Play::Limits.client_key({ "HTTP_CF_CONNECTING_IP" => ip }, "HTTP_CF_CONNECTING_IP") }
    assert_kind_of Play::Sessions::Created, sessions.create(key.call("2001:db8:1:2::a"))
    calls = @docker.calls.size
    @clock.advance(60)

    refusal = sessions.create(key.call("2001:db8:1:2:ffff::b"))
    assert_equal :per_ip, refusal.reason
    assert_equal 1740, refusal.retry_after
    assert_equal 1_800_001_800, refusal.ends_at
    assert_equal calls, @docker.calls.size
    assert_kind_of Play::Sessions::Created, sessions.create(key.call("2001:db8:1:3::a"))
  end

  def test_successful_creations_per_client_are_limited_in_a_sliding_window
    s = sessions("PLAY_CREATE_LIMIT" => "2", "PLAY_MAX_SESSIONS_PER_IP" => "5")
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
    @clock.advance(100)
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
    calls = @docker.calls.size

    refusal = s.create("203.0.113.7")
    assert_equal [:rate, 500], [refusal.reason, refusal.retry_after]
    assert_equal calls, @docker.calls.size
    @clock.advance(500)
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
  end

  def test_a_refused_attempt_does_not_count
    @docker.on("ps sessions", FakeDocker.ok(container("a" * 16, "running")))
    s = sessions("PLAY_MAX_SESSIONS" => "1", "PLAY_CREATE_LIMIT" => "1")
    assert_equal :full, s.create("203.0.113.7").reason
    assert_kind_of Play::Sessions::Created, s.create("203.0.113.7")
  end

  # ---- failures leave nothing behind ---------------------------------------

  def test_a_failing_step_removes_the_new_session
    {
      "network create" => FakeDocker.fail("Error response from daemon: failed to create network"),
      "network connect" => FakeDocker.fail("Error response from daemon: container not running"),
      "run" => FakeDocker.fail("docker: Error response from daemon: Conflict."),
      "run " => :timeout
    }.each do |step, answer|
      setup
      @docker.on(step.strip, answer)
      refusal = sessions.create("203.0.113.7")
      assert_equal [:failed, 60], [refusal.reason, refusal.retry_after], step
      assert_removed(handle_of_last_network)
      assert_match(/play event=docker_error step=\w+ handle=#{handle_of_last_network} status=-?\d+ /, @log.string)
      assert_match(/play event=ended handle=#{handle_of_last_network} reason=failed age_s=0/, @log.string)
      assert_empty sessions.internal_list, step
      @sessions = nil
    end
  end

  def test_not_ready_in_time_removes_the_session
    @probe = FakeProbe.new(ready_after: nil)
    refusal = sessions("PLAY_READY_TIMEOUT" => "30").create("203.0.113.7")
    assert_equal :failed, refusal.reason
    assert_equal 121, @probe.calls.size
    assert_removed(handle_of_last_network)
    assert_includes @log.string, "reason=failed"
  end

  def test_a_missing_image_pauses_creation_until_it_is_back
    @docker.on("run", FakeDocker.fail("docker: Error response from daemon: No such image: ghcr.io/example/web@sha256:0123"))
    refusal = sessions.create("203.0.113.7")
    assert_equal [:unavailable, 300, "Its session image is missing"], [refusal.reason, refusal.retry_after, refusal.message]
    assert_removed(handle_of_last_network)
    assert_includes @log.string, "play event=unavailable reason=image_missing image=ghcr.io/example/cybertrain-playground-web@sha256:0123"

    calls = @docker.calls.size
    assert_equal :unavailable, sessions.create("198.51.100.1").reason
    assert_equal calls, @docker.calls.size

    @clock.advance(10)
    sessions.reap
    assert_includes @log.string, "play event=available\n"
    assert_kind_of Play::Sessions::Created, sessions.create("198.51.100.1")
  end

  def test_no_log_line_names_a_session_or_preview_id
    @docker.on("run", lambda do |argv|
      FakeDocker.fail("docker: Error response from daemon: alias #{argv[argv.index("--network-alias") + 1]} " \
                      "env #{argv.find { |a| a.start_with?("VSCODE_PROXY_URI=") }} rejected")
    end)
    sessions.create("203.0.113.7")
    sid, pid = ids
    assert_kind_of Play::Sessions::Created, sessions.create("198.51.100.1")
    sid2, pid2 = ids
    @clock.advance(1800)
    sessions.reap

    assert_includes @log.string, "alias s-<sid> env VSCODE_PROXY_URI=https://{{port}}-<pid>.play.example.test rejected"
    [sid, pid, sid2, pid2].each { |secret| refute_includes @log.string, secret }
    refute_match(/\h{32}/, @log.string)
    refute_includes @log.string, "203.0.113.7"
    refute_includes @log.string, "198.51.100.1"
  end

  # ---- teardown -------------------------------------------------------------

  def test_teardown_counts_absent_as_done
    @docker.on("rm", FakeDocker.fail("Error response from daemon: No such container: ctplay-s-#{"a" * 16}"))
    @docker.on("network inspect", FakeDocker.fail("Error response from daemon: network ctplay-n-#{"a" * 16} not found"))
    assert sessions.teardown("a" * 16, reason: "killed")
    assert_equal ["rm", "network inspect"], @docker.keys
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=killed\n"
  end

  def test_teardown_disconnects_every_attachment_before_removing_the_network
    @docker.on("network inspect", FakeDocker.ok("#{ROUTER} 0123abcd "))
    assert sessions.teardown("a" * 16, reason: "ttl")
    assert_equal [["docker", "network", "disconnect", "--force", "ctplay-n-#{"a" * 16}", ROUTER],
                  ["docker", "network", "disconnect", "--force", "ctplay-n-#{"a" * 16}", "0123abcd"]],
                 @docker.calls_for("network disconnect")
    assert_equal ["rm", "network inspect", "network disconnect", "network disconnect", "network rm"], @docker.keys
  end

  def test_a_failed_teardown_keeps_the_labels_for_the_next_pass
    @docker.on("network rm", FakeDocker.fail("Error response from daemon: error while removing network: network ctplay-n-x has active endpoints"))
    refute sessions.teardown("a" * 16, reason: "ttl")
    assert_match(/play event=docker_error step=network_rm handle=a{16} status=1 stderr="Error response/, @log.string)
    refute_includes @log.string, "event=ended"
  end

  # ---- the reaper -------------------------------------------------------------

  def test_reap_removes_expired_and_stopped_sessions
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running", expires: @clock.now) +
                                                 container("b" * 16, "exited") + container("c" * 16, "running")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16) + network("b" * 16) + network("c" * 16)))
    assert sessions.reap
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=ttl age_s=100\n"
    assert_includes @log.string, "play event=ended handle=#{"b" * 16} reason=exited age_s=100\n"
    refute_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{"c" * 16}"]
  end

  def test_reap_removes_orphan_networks_older_than_a_minute_only
    @docker.default("network ls", FakeDocker.ok(network("a" * 16, created: @clock.now - 61) +
                                                network("b" * 16, created: @clock.now - 10)))
    sessions.reap
    assert_includes @log.string, "play event=ended handle=#{"a" * 16} reason=orphan age_s=61\n"
    refute_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{"b" * 16}"]
  end

  def test_a_session_whose_container_ended_by_itself_is_cleaned_up_as_idle
    created = sessions.create("203.0.113.7")
    @docker.default("network ls", FakeDocker.ok(network(created.handle, created: @clock.now)))
    sessions.reap
    assert_includes @log.string, "play event=ended handle=#{created.handle} reason=idle"
    assert_empty sessions.internal_list
  end

  def test_reap_attaches_every_running_router_once
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    @docker.default("ps routers", FakeDocker.ok("r1\nr2\n"))
    @docker.on("network connect", FakeDocker.ok, FakeDocker.fail("Error response from daemon: endpoint with name router already exists in network ctplay-n-x"))
    sessions.reap
    sessions.reap
    assert_equal [["docker", "network", "connect", "ctplay-n-#{"a" * 16}", "r1"],
                  ["docker", "network", "connect", "ctplay-n-#{"a" * 16}", "r2"]], @docker.calls_for("network connect")
    @docker.default("ps routers", FakeDocker.ok("r3\n"))
    sessions.reap
    assert_equal ["docker", "network", "connect", "ctplay-n-#{"a" * 16}", "r3"], @docker.calls_for("network connect").last
  end

  def test_a_restarted_control_plane_adopts_live_sessions_without_a_client
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running", created: 1_799_999_000, expires: 1_800_000_800)))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    sessions.reap
    assert_equal [{ handle: "a" * 16, state: "ready", created_at: 1_799_999_000, expires_at: 1_800_000_800, client: nil,
                    cpu: nil, memory: nil }], sessions.internal_list
    assert_equal 1, sessions.status[:live]
  end

  def test_the_kill_all_request_ends_everything_once
    path = File.join(sessions.config.data_dir, "kill-all")
    File.write(path, "")
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running")))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16) + network("b" * 16, created: @clock.now)))
    sessions.reap
    assert_includes @log.string, "handle=#{"a" * 16} reason=killed"
    assert_includes @log.string, "handle=#{"b" * 16} reason=killed"
    refute File.exist?(path)
    assert_empty @docker.calls_for("network connect")
  end

  def test_a_session_at_90_percent_cpu_ten_minutes_running_is_logged_once
    @docker.default("ps sessions", FakeDocker.ok(container("a" * 16, "running", expires: @clock.now + 3600)))
    @docker.default("network ls", FakeDocker.ok(network("a" * 16)))
    @docker.default("stats", FakeDocker.ok("ctplay-s-#{"a" * 16}\t99.8%\t420MiB / 1.5GiB\n"))
    11.times do
      sessions.reap
      @clock.advance(60)
    end
    assert_equal 11, @docker.calls_for("stats").size
    assert_equal ["play event=suspect handle=#{"a" * 16} cpu=99.8%"], @log.string.lines.map(&:chomp).grep(/suspect/)
    assert_equal [99.8, "420MiB / 1.5GiB"], sessions.internal_list.first.values_at(:cpu, :memory)
  end

  def test_up_is_healthy_while_the_reaper_reaches_docker
    refute sessions.healthy?
    assert sessions.reap
    assert sessions.healthy?
    @docker.default("ps sessions", FakeDocker.fail("Cannot connect to the Docker daemon at unix:///var/run/docker.sock"))
    @clock.advance(61)
    refute sessions.reap
    refute sessions.healthy?
  end

  def test_status_counts_live_sessions
    sessions.create("203.0.113.7")
    assert_equal({ accepting: true, paused: false, live: 1, capacity: 5, ttl_seconds: 1800 }, sessions.status)
    File.write(File.join(sessions.config.data_dir, "paused"), "")
    assert_equal({ accepting: false, paused: true, live: 1, capacity: 5, ttl_seconds: 1800 }, sessions.status)
    assert_equal "For maintenance", sessions.closed_message
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/saeki/work/cybertrain/playground/control
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
BUNDLE_PATH="$SDD/bundle" bundle exec rake test 2>&1 | grep -E 'runs,|uninitialized constant' | sort | uniq -c
```

Expected: `25 NameError: uninitialized constant Play::Sessions` and `1 50 runs, 128 assertions, 0 failures, 25 errors, 0 skips` (Task 4's 25 tests still pass).

- [ ] **Step 3: Implement**

Create `playground/control/lib/play/sessions.rb`:

```ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require "set"

module Play
  # The sessions (spec §5.3, §5.5-§5.9, §5.12): creation under the create
  # lock, teardown, the reaper that reconciles memory with Docker, and the
  # pause and kill-all switches. Docker is the truth (labels
  # cybertrain-play.*); the records here serve the limits, the status and the
  # operator. The session and preview ids live only inside #create: they are
  # in the argv of `docker run` and in the editor URL it returns, and never in
  # a record or a log line.
  class Sessions
    Session = Struct.new(:handle, :subnet, :created_at, :expires_at, :client, :state, :cpu, :memory, :hot)
    Created = Struct.new(:editor_url, :handle)
    Refusal = Struct.new(:reason, :retry_after, :message, :ends_at)

    CREATE_TIMEOUT = 30
    LIST_TIMEOUT = 10
    ORPHAN_GRACE = 60
    HEALTHY_WITHIN = 60
    AVAILABILITY_EVERY = 10
    STATS_EVERY = 60
    HOT_CPU = 90.0
    HOT_COUNT = 10
    PROBE_EVERY = 0.25
    LIVE = %i[creating ready].freeze
    ABSENT = /No such (container|network|object)|not found|is not connected/i
    OVERLAP = /Pool overlaps/i
    NO_IMAGE = /No such image/i
    ALREADY = /already exists/i

    attr_reader :config

    def self.handle_for(sid)
      Digest::SHA256.hexdigest(sid)[0, 16]
    end

    def initialize(config:, docker:, probe:, clock:, log:, random: SecureRandom)
      @config = config
      @docker = docker
      @probe = probe
      @clock = clock
      @log = log
      @random = random
      @subnets = Subnets.new(config.subnet_pool, config.subnet_prefix)
      @limits = Limits.new(limit: config.create_limit, window: config.create_window, clock: clock)
      @records = {}
      @connected = Hash.new { |hash, handle| hash[handle] = [] }
      @unusable = []
      @mutex = Mutex.new
      @unavailable = nil
      @last_reap_ok = nil
      @last_availability = nil
      @last_stats = nil
      FileUtils.mkdir_p(config.data_dir)
    end

    # ---- what the pages and the operator read ------------------------------

    def status
      live = live_count
      paused = !pause_message.nil?
      { accepting: !paused && @unavailable.nil? && live < @config.max_sessions,
        paused: paused, live: live, capacity: @config.max_sessions, ttl_seconds: @config.ttl }
    end

    # Why nothing can start right now (the pause message, or what is
    # missing), or nil.
    def closed_message
      pause_message || @unavailable
    end

    # The operator's message from playctl pause, or nil when not paused.
    def pause_message
      text = File.read(paused_path).strip
      text.empty? ? "For maintenance" : text[0].upcase + text[1..]
    rescue Errno::ENOENT
      nil
    end

    # True while the reaper has succeeded within the last minute (GET /up).
    def healthy?
      !@last_reap_ok.nil? && @clock.monotonic - @last_reap_ok <= HEALTHY_WITHIN
    end

    # The records for GET /internal/sessions (playctl status).
    def internal_list
      @mutex.synchronize do
        @records.values.sort_by(&:created_at).map do |s|
          { handle: s.handle, state: s.state.to_s, created_at: s.created_at, expires_at: s.expires_at,
            client: s.client, cpu: s.cpu, memory: s.memory }
        end
      end
    end

    # A refusal decided outside (POST /sessions from another origin).
    def note_refusal(reason)
      @log.event("refused", reason: reason, live: "#{live_count}/#{@config.max_sessions}")
    end

    # ---- creation ------------------------------------------------------------

    # Starts a session for CLIENT (Limits.client_key). Returns Created, whose
    # editor_url is the only copy of the session id, or a Refusal. Whatever
    # fails, nothing of the new session is left behind.
    def create(client)
      if (message = pause_message)
        return refuse(:paused, 300, message)
      end
      return refuse(:unavailable, 300, @unavailable) if @unavailable

      sid, pid = new_ids
      handle = self.class.handle_for(sid)
      begin
        refusal = with_create_lock { admit_and_start(client, handle, sid, pid) }
        return refusal if refusal

        wait_until_ready(handle, sid, client)
      rescue StandardError => e
        teardown(handle, reason: "failed")
        @log.event("error", step: "create", handle: handle,
                            message: DockerCLI.redact("#{e.class}: #{e.message}", "sid" => sid, "pid" => pid))
        refuse(:failed, 60)
      end
    end

    # Holds the host-wide create lock (PLAY_DATA_DIR/create.lock): threads of
    # this process, a second control plane during a deploy and playctl all
    # take it before they count or start sessions.
    def with_create_lock
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end

    # ---- teardown ------------------------------------------------------------

    # Removes the session HANDLE: its container, every attachment of its
    # network, the network. Each step counts "absent" as done. Returns true
    # when nothing is left; on false the labels stay and the reaper retries.
    def teardown(handle, reason:, created_at: nil)
      session = @mutex.synchronize do
        @records[handle]&.tap { |s| s.state = :ending }
      end
      return false unless remove_everything(handle)

      @mutex.synchronize do
        @records.delete(handle)
        @connected.delete(handle)
      end
      born = session&.created_at || created_at
      fields = { handle: handle, reason: reason }
      fields[:age_s] = @clock.now - born if born
      @log.event("ended", **fields)
      true
    end

    # Every labelled session (playctl kill-all, and the reaper when it finds
    # the kill-all request).
    def kill_all(reason: "killed")
      containers = list_containers
      networks = list_networks
      return false unless containers && networks

      handles = (containers.map { |c| c[:handle] } + networks.map { |n| n[:handle] }).uniq
      handles.map { |handle| teardown(handle, reason: reason) }.all?
    end

    # ---- the reaper ----------------------------------------------------------

    def start_reaper
      Thread.new do
        # An unexpected error ends the process; Docker restarts it and the
        # first pass reconciles (spec §5.1).
        Thread.current.abort_on_exception = true
        loop do
          reap
          @clock.sleep(@config.reap_interval)
        end
      end
    end

    # One pass (spec §5.8). Returns true when it reached Docker.
    def reap
      check_availability if @unavailable && due?(@last_availability, AVAILABILITY_EVERY)
      containers = list_containers
      networks = list_networks
      routers = list_routers
      return false unless containers && networks && routers

      now = @clock.now
      killing = File.exist?(kill_path)
      creating = @mutex.synchronize { @records.select { |_, s| s.state == :creating }.keys }
      done = true

      containers.each do |c|
        reason = if killing then "killed"
                 elsif c[:expires_at] <= now then "ttl"
                 elsif c[:state] != "running" && !creating.include?(c[:handle]) then "exited"
                 end
        done &= teardown(c[:handle], reason: reason, created_at: c[:created_at]) if reason
      end

      with_container = containers.to_set { |c| c[:handle] }
      networks.each do |n|
        next if with_container.include?(n[:handle])

        known = @mutex.synchronize { @records[n[:handle]] }
        reason = if killing then "killed"
                 elsif known && known.state != :creating then "idle"
                 elsif known.nil? && now - n[:created_at] >= ORPHAN_GRACE then "orphan"
                 end
        done &= teardown(n[:handle], reason: reason, created_at: n[:created_at]) if reason
      end

      alive = killing ? [] : containers.select { |c| c[:state] == "running" && c[:expires_at] > now }
      attach_routers(alive, routers)
      reconcile(containers, networks, alive)
      collect_stats(alive) if due?(@last_stats, STATS_EVERY)
      File.delete(kill_path) if killing && done
      @last_reap_ok = @clock.monotonic
      true
    end

    # Docker and the session image, checked at boot and every 10 s while
    # something is missing; creation is refused meanwhile.
    def check_availability
      @last_availability = @clock.monotonic
      version = docker(Templates.version, LIST_TIMEOUT)
      return unavailable!("It cannot reach Docker", "docker_unreachable", version) unless version.ok?

      image = docker(Templates.image_inspect(@config), LIST_TIMEOUT)
      return unavailable!("Its session image is missing", "image_missing", image) unless image.ok?

      @log.event("available") if @unavailable
      @unavailable = nil
      true
    end

    # ---- Docker listings (also used by playctl) -------------------------------

    def list_containers
      result = docker(Templates.list_containers, LIST_TIMEOUT)
      return listing_failed("ps", result) unless result.ok?

      result.stdout.lines.filter_map do |line|
        id, name, state, handle, created, expires = line.chomp.split("\t")
        next unless handle.to_s.match?(/\A\h{16}\z/)

        { id: id, name: name, state: state, handle: handle, created_at: created.to_i, expires_at: expires.to_i }
      end
    end

    def list_networks
      result = docker(Templates.list_networks, LIST_TIMEOUT)
      return listing_failed("network_ls", result) unless result.ok?

      result.stdout.lines.filter_map do |line|
        id, name, handle, created = line.chomp.split("\t")
        next unless handle.to_s.match?(/\A\h{16}\z/)

        { id: id, name: name, handle: handle, created_at: created.to_i }
      end
    end

    def list_routers
      result = docker(Templates.list_routers(@config), LIST_TIMEOUT)
      return listing_failed("routers", result) unless result.ok?

      result.stdout.split
    end

    # {container name => [cpu %, memory]} from one `docker stats` sample.
    def read_stats(names)
      return {} if names.empty?

      result = docker(Templates.stats(names), LIST_TIMEOUT)
      return listing_failed("stats", result) || {} unless result.ok?

      result.stdout.lines.to_h do |line|
        name, cpu, memory = line.chomp.split("\t")
        [name, [cpu.to_s.delete("%").to_f, memory.to_s]]
      end
    end

    private

    def paused_path
      File.join(@config.data_dir, "paused")
    end

    def kill_path
      File.join(@config.data_dir, "kill-all")
    end

    def lock_path
      File.join(@config.data_dir, "create.lock")
    end

    def live_count
      @mutex.synchronize { @records.count { |_, s| LIVE.include?(s.state) } }
    end

    def new_ids
      sid = @random.hex(16)
      pid = @random.hex(16)
      pid = @random.hex(16) while pid == sid
      [sid, pid]
    end

    def refuse(reason, retry_after, message = nil, ends_at = nil)
      note_refusal(reason)
      Refusal.new(reason, retry_after, message, ends_at)
    end

    # Inside the create lock: the limits, then the network, the routers and
    # the container. nil once the container runs, else a Refusal (after
    # removing whatever was made).
    def admit_and_start(client, handle, sid, pid)
      refusal = client_refusal(client)
      return refusal if refusal

      containers = list_containers
      return refuse(:failed, 60) unless containers
      return refuse(:full, 60) if containers.count { |c| %w[running created].include?(c[:state]) } >= @config.max_sessions

      routers = list_routers
      return refuse(:failed, 60) unless routers
      return refuse(:unavailable, 300, "It is starting up") if routers.empty?

      now = @clock.now
      session = Session.new(handle, nil, now, now + @config.ttl, client, :creating, nil, nil, 0)
      @mutex.synchronize { @records[handle] = session }
      refusal = start_session(session, sid, pid, routers)
      teardown(handle, reason: "failed") if refusal
      refusal
    end

    def client_refusal(client)
      mine = @mutex.synchronize { @records.values.select { |s| s.client == client && LIVE.include?(s.state) } }
      if mine.size >= @config.max_sessions_per_ip
        ends_at = mine.map(&:expires_at).min
        return refuse(:per_ip, [ends_at - @clock.now, 1].max, nil, ends_at)
      end
      wait = @limits.retry_after(client)
      wait.positive? ? refuse(:rate, wait) : nil
    end

    def start_session(session, sid, pid, routers)
      secrets = { "sid" => sid, "pid" => pid }
      return refuse(:failed, 60) unless create_network(session, secrets)

      routers.each do |router|
        result = docker(Templates.network_connect(handle: session.handle, container: router), CREATE_TIMEOUT)
        unless result.ok? || result.stderr.match?(ALREADY)
          docker_error("connect", session.handle, result, secrets)
          return refuse(:failed, 60)
        end
        @mutex.synchronize { @connected[session.handle] |= [router] }
      end

      run = Templates.session_run(@config, handle: session.handle, sid: sid, pid: pid,
                                           created: session.created_at, expires: session.expires_at)
      result = docker(run, CREATE_TIMEOUT)
      return nil if result.ok?

      docker_error("run", session.handle, result, secrets)
      return refuse(:failed, 60) unless result.stderr.match?(NO_IMAGE)

      unavailable!("Its session image is missing", "image_missing", result)
      refuse(:unavailable, 300, @unavailable)
    end

    # The lowest free subnet; a "Pool overlaps" answer (a network without our
    # labels holds that range) marks it unusable for this process and tries
    # the next, three times in all (spec §5.5).
    def create_network(session, secrets)
      networks = list_networks
      return false unless networks

      used = networks.filter_map { |n| subnet_of(n[:handle]) }
      3.times do
        subnet = @subnets.first_free(used + @unusable)
        return false unless subnet

        argv = Templates.network_create(handle: session.handle, subnet: subnet,
                                        created: session.created_at, expires: session.expires_at)
        result = docker(argv, CREATE_TIMEOUT)
        if result.ok?
          session.subnet = subnet
          return true
        end
        docker_error("network", session.handle, result, secrets)
        return false unless result.stderr.match?(OVERLAP)

        @unusable << subnet
      end
      false
    end

    def subnet_of(handle)
      known = @mutex.synchronize { @records[handle]&.subnet }
      return known if known

      result = docker(Templates.network_subnet(handle: handle), LIST_TIMEOUT)
      result.ok? ? result.stdout.strip : nil
    end

    def wait_until_ready(handle, sid, client)
      started = @clock.monotonic
      until @probe.ready?(sid)
        if @clock.monotonic - started >= @config.ready_timeout
          teardown(handle, reason: "failed")
          return refuse(:failed, 60)
        end
        @clock.sleep(PROBE_EVERY)
      end
      session = @mutex.synchronize { @records[handle]&.tap { |s| s.state = :ready } }
      return refuse(:failed, 60) unless session # ended meanwhile (kill-all)

      @limits.record(client)
      @log.event("created", handle: handle, subnet: session.subnet,
                            ready_ms: ((@clock.monotonic - started) * 1000).round,
                            live: "#{live_count}/#{@config.max_sessions}")
      Created.new(@config.editor_url(sid), handle)
    end

    # The order matters (spec §5.4, §15): the container goes first, and its
    # exit closes the router's connections to it; then every attachment,
    # then the network. Detaching the router from a running session first
    # left the router a pooled connection that hung for minutes.
    def remove_everything(handle)
      result = docker(Templates.remove_container(handle: handle), CREATE_TIMEOUT)
      return step_failed("rm", handle, result) unless result.ok? || result.stderr.match?(ABSENT)

      result = docker(Templates.network_containers(handle: handle), CREATE_TIMEOUT)
      return result.stderr.match?(ABSENT) || step_failed("inspect", handle, result) unless result.ok?

      result.stdout.split.each do |container|
        detached = docker(Templates.network_disconnect(handle: handle, container: container), CREATE_TIMEOUT)
        return step_failed("disconnect", handle, detached) unless detached.ok? || detached.stderr.match?(ABSENT)
      end
      result = docker(Templates.network_remove(handle: handle), CREATE_TIMEOUT)
      result.ok? || result.stderr.match?(ABSENT) || step_failed("network_rm", handle, result)
    end

    def attach_routers(alive, routers)
      alive.each do |c|
        missing = routers - @mutex.synchronize { @connected[c[:handle]].dup }
        missing.each do |router|
          result = docker(Templates.network_connect(handle: c[:handle], container: router), CREATE_TIMEOUT)
          if result.ok? || result.stderr.match?(ALREADY)
            @mutex.synchronize { @connected[c[:handle]] |= [router] }
          else
            docker_error("connect", c[:handle], result)
          end
        end
      end
    end

    # Forget what Docker no longer has; adopt live sessions this process did
    # not start (a restart, or the other control plane during a deploy).
    def reconcile(containers, networks, alive)
      seen = (containers.map { |c| c[:handle] } + networks.map { |n| n[:handle] }).to_set
      @mutex.synchronize do
        @records.delete_if { |handle, s| s.state != :creating && !seen.include?(handle) }
        alive.each do |c|
          @records[c[:handle]] ||= Session.new(c[:handle], nil, c[:created_at], c[:expires_at], nil, :ready, nil, nil, 0)
        end
      end
    end

    # Every minute: CPU and memory per session; ten samples in a row at 90 %
    # or more log one `suspect` line (spec §5.8). Nothing is stopped.
    def collect_stats(alive)
      @last_stats = @clock.monotonic
      read_stats(alive.map { |c| c[:name] }).each do |name, (cpu, memory)|
        handle = name.delete_prefix("ctplay-s-")
        hot = @mutex.synchronize do
          session = @records[handle]
          if session
            session.cpu = cpu
            session.memory = memory
            session.hot = cpu >= HOT_CPU ? session.hot.to_i + 1 : 0
          end
        end
        @log.event("suspect", handle: handle, cpu: format("%.1f%%", cpu)) if hot == HOT_COUNT
      end
    end

    def due?(last, every)
      last.nil? || @clock.monotonic - last >= every
    end

    def docker(argv, timeout)
      @docker.run(argv, timeout: timeout)
    rescue DockerCLI::Timeout => e
      DockerCLI::Result.new(-1, "", e.message)
    end

    def docker_error(step, handle, result, secrets = {})
      fields = { step: step }
      fields[:handle] = handle if handle
      fields[:status] = result.status
      fields[:stderr] = DockerCLI.redact(result.stderr, secrets)
      @log.event("docker_error", **fields)
    end

    def step_failed(step, handle, result)
      docker_error(step, handle, result)
      false
    end

    def listing_failed(step, result)
      docker_error(step, nil, result)
      nil
    end

    def unavailable!(message, reason, result)
      if @unavailable != message
        fields = { reason: reason }
        fields[:image] = @config.session_image if reason == "image_missing"
        fields[:stderr] = DockerCLI.redact(result.stderr)
        @log.event("unavailable", **fields)
      end
      @unavailable = message
      false
    end
  end
end
```

Append this line to `playground/control/lib/play.rb`, after `require_relative "play/probe"`:

```ruby
require_relative "play/sessions"
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/saeki/work/cybertrain/playground/control
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
for i in 1 2 3; do BUNDLE_PATH="$SDD/bundle" bundle exec rake test 2>&1 | tail -n 1; done
```

Expected, three times (minitest shuffles): `50 runs, 296 assertions, 0 failures, 0 errors, 0 skips`.

- [ ] **Step 5: Commit**

```bash
cd /Users/saeki/work/cybertrain
git add playground/control/lib/play/sessions.rb playground/control/lib/play.rb playground/control/test/fakes.rb playground/control/test/sessions_test.rb
git commit -m "Control: sessions: creation under the create lock, teardown, the reaper

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The control plane's HTTP surface, `playctl` and image

**Files:**
- Create: `playground/control/lib/play/app.rb`, `playground/control/views/layout.erb`, `playground/control/views/index.erb`, `playground/control/views/terms.erb`, `playground/control/views/refusal.erb`, `playground/control/config.ru`
- Create: `playground/control/lib/play/ctl.rb`, `playground/control/bin/playctl` (git mode 100755)
- Create: `playground/control/Dockerfile`, `playground/control/Dockerfile.dockerignore`
- Modify: `playground/control/lib/play.rb` (one `require_relative` at the end), `playground/control/test/fakes.rb` (append `FakeSessions`)
- Test: `playground/control/test/app_test.rb`, `playground/control/test/playctl_test.rb`; the image's boot check

**Interfaces:**
- Consumes: Task 5's `Play::Sessions` interface (listed there) and Task 4's `Play::Config`, `Play::Limits.client_key`, `Play::Clock`, `Play::EventLog`, `Play::DockerCLI`, `Play::Probe`. The `V10=` value of Task 3's `V-OUTCOMES` line (from the dispatch): with `V10=fallback`, replace `Your browser asks no extension marketplace.` in `views/terms.erb` with `Your browser may contact the Open VSX extension registry.` and the same sentence in `test_terms_robots_and_security_txt`.
- Produces: `Play::App.for(config:, sessions:)` (a Rack app); the routes of spec §5.2: `GET /`, `POST /sessions` (303 to the editor URL or a refusal page with `Retry-After`: 403 origin, 503 paused, unavailable, full or failed, 429 per client or rate), `GET /status.json`, `GET /terms`, `GET /robots.txt`, `GET /.well-known/security.txt`, `GET /up` (200 `OK` / 503), `GET /internal/sessions` (loopback only); page texts of spec §5.6 and §5.13 ("{free} of {cap} sessions are free.", "All {cap} sessions are in use: try again in a few minutes.", "The playground is paused. {Message}. Try again later, or use GitHub Codespaces.", "All {cap} playground sessions are in use right now.", "A session from your network address is already running", "Too many sessions from your network address", "The session could not be started", "Start a session from {domain}"); `bin/playctl status|pause [message]|resume|end <handle>|kill-all` (exit 0, 1, 2), which prints `paused: …`, `resumed: new sessions are accepted`, `ended <handle>`, `killed every session; the playground stays paused until playctl resume` and the status table ending `<n> of <cap> sessions; accepting` or `…; paused: <message>`; the image `ctplay-control:local` (Puma on 9292, `HEALTHCHECK` on `/up`; with a missing setting it prints `error: …` and exits 1). Task 7 starts it through compose.

Notes on the spec's text, applied below:
- Correction: Sinatra's `Rack::Protection` is turned off (`set :protection, false`). Its `HttpOrigin` compares `Origin` with the request's own scheme and host, and behind the router the scheme is `http` (Caddy sets `X-Forwarded-Proto: http`), so it would refuse every POST from `https://<DOMAIN>`; its `FrameOptions` would add `X-Frame-Options`, which spec §6.3 leaves out. The origin check of spec §5.2 and the headers of §5.13 replace it; `host_authorization` (a separate Sinatra setting) stays on with `[domain, "127.0.0.1", "localhost"]`.
- Correction: `Origin: null` counts as no `Origin`, and `Sec-Fetch-Site` decides (absent, `same-origin` or `none` pass). A browser sends `Origin: null` with a form POST from a page served with `Referrer-Policy: no-referrer` (Fetch standard, "append a request `Origin` header"), which is every page here: with spec §5.2's rule the entry page's own button would get 403 (Review Focus 1). A cross-site page still gets 403 (`Sec-Fetch-Site: cross-site`), and a same-site one too.
- Correction: the CSP's `form-action` is `'self' <scheme>://*.<domain><port>` instead of `'self'`: the 303 that answers the POST goes to the editor's host, and Chrome checks a form submission's redirects against `form-action` (Review Focus 1).
- `BUTTON_SCRIPT` also re-enables the button on `pageshow`, when a browser restores the entry page from its back-forward cache (Review Focus 5). The CSP hash is computed from the same constant.
- Spec §5.6's paused text takes its message from `playctl pause` (default "for maintenance"); "is starting up" (no router), "Its session image is missing" and "It cannot reach Docker" use the same page (spec §5.12).
- `bin/playctl` keeps its logic in `lib/play/ctl.rb` (a `lib/play/*.rb` file of spec §10) so that the tests drive it with a fake Docker; `kill-all` writes `paused` (keeping an existing message), writes the `kill-all` request for the running control plane, and removes every labelled session itself under the create lock.
- The image is spec §5.1's with `ruby:4.0.7-slim` (the newest 4.0 patch on Docker Hub on 2026-10-02; use the newest `4.0.x-slim` if that tag is gone) and a build-context file that leaves the tests out.

- [ ] **Step 1: Write the failing tests**

Append to `playground/control/test/fakes.rb`:

```ruby

# Play::Sessions as the routes see it (test/app_test.rb).
class FakeSessions
  attr_reader :clients, :refusals
  attr_accessor :result, :status_value, :closed, :healthy, :internal

  def initialize(config)
    @clients = []
    @refusals = []
    @result = Play::Sessions::Created.new(config.editor_url("0123456789abcdef0123456789abcdef"), "1f2e3d4c5b6a7980")
    @status_value = { accepting: true, paused: false, live: 2, capacity: 5, ttl_seconds: 1800 }
    @closed = nil
    @healthy = true
    @internal = []
  end

  def create(client)
    @clients << client
    @result
  end

  def status
    @status_value
  end

  def closed_message
    @closed
  end

  def healthy?
    @healthy
  end

  def internal_list
    @internal
  end

  def note_refusal(reason)
    @refusals << reason
  end
end
```

Create `playground/control/test/app_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "rack/test"
require "play/app"

class AppTest < Minitest::Test
  include PlayTestHelpers
  include Rack::Test::Methods

  SITE = "https://saeki-mototsune.github.io"

  def config
    @config ||= play_config("PLAY_ALLOWED_ORIGINS" => "https://play.example.test,#{SITE}",
                            "PLAY_CLIENT_IP_HEADER" => "CF-Connecting-IP")
  end

  def fake
    @fake ||= FakeSessions.new(config)
  end

  def app
    Play::App.for(config: config, sessions: fake)
  end

  def setup
    header "Host", "play.example.test"
  end

  def start(headers = {})
    post "/sessions", {}, { "HTTP_CF_CONNECTING_IP" => "203.0.113.7" }.merge(headers)
  end

  def refusal(reason, retry_after, message: nil, ends_at: nil)
    Play::Sessions::Refusal.new(reason, retry_after, message, ends_at)
  end

  # ---- the entry page ---------------------------------------------------------

  def test_entry_page_shows_the_free_sessions_and_the_button
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Try cybertrain in your browser, no account"
    assert_includes last_response.body, "3 of 5 sessions are free."
    assert_includes last_response.body, "Lasts: 30 minutes, then the session is deleted with its files"
    assert_includes last_response.body, '<form class="start" method="post" action="/sessions">'
    assert_includes last_response.body, "<script>#{Play::App::BUTTON_SCRIPT}</script>"
    assert_includes last_response.body, "mailto:abuse@example.test"
  end

  def test_entry_page_when_full_or_paused
    fake.status_value = fake.status_value.merge(live: 5, accepting: false)
    get "/"
    assert_includes last_response.body, "All 5 sessions are in use: try again in a few minutes."
    fake.closed = "Maintenance"
    get "/"
    assert_includes last_response.body, "The playground is paused. Maintenance. Try again later"
    refute_includes last_response.body, "<form"
  end

  def test_every_page_carries_the_security_headers
    get "/"
    script = "'sha256-#{[Digest::SHA256.digest(Play::App::BUTTON_SCRIPT)].pack("m0")}'"
    assert_equal "default-src 'none'; style-src 'unsafe-inline'; script-src #{script}; " \
                 "form-action 'self' https://*.play.example.test; frame-ancestors 'none'; base-uri 'none'",
                 last_response.headers["Content-Security-Policy"]
    assert_equal "no-referrer", last_response.headers["Referrer-Policy"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
    assert_equal "no-store", last_response.headers["Cache-Control"]
    assert_nil last_response.headers["X-Frame-Options"]
    assert_nil last_response.headers["X-XSS-Protection"]
  end

  # ---- POST /sessions ---------------------------------------------------------

  def test_start_redirects_to_the_editor
    start("HTTP_ORIGIN" => "https://play.example.test", "HTTP_SEC_FETCH_SITE" => "same-origin")
    assert_equal 303, last_response.status
    assert_equal fake.result.editor_url, last_response.headers["Location"]
    assert_equal "no-store", last_response.headers["Cache-Control"]
    assert_equal ["203.0.113.7"], fake.clients
  end

  def test_the_sites_button_may_start_a_session
    start("HTTP_ORIGIN" => SITE, "HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_equal 303, last_response.status
  end

  # The entry page is served with Referrer-Policy: no-referrer, so a browser
  # sends its form POST with Origin: null (Fetch, "append a request Origin
  # header"); Sec-Fetch-Site tells whether it came from this origin.
  def test_the_entry_pages_own_button_sends_origin_null_and_is_let_through
    start("HTTP_ORIGIN" => "null", "HTTP_SEC_FETCH_SITE" => "same-origin")
    assert_equal 303, last_response.status
    start("HTTP_ORIGIN" => "null", "HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_equal 403, last_response.status
  end

  def test_another_origin_is_refused_without_creating_anything
    start("HTTP_ORIGIN" => "https://evil.example", "HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_equal 403, last_response.status
    assert_includes last_response.body, "Start a session from play.example.test"
    assert_includes last_response.body, 'href="https://play.example.test/"'
    assert_empty fake.clients
    assert_equal [:origin], fake.refusals
  end

  def test_a_sibling_host_is_refused
    start("HTTP_SEC_FETCH_SITE" => "same-site")
    assert_equal 403, last_response.status
    start("HTTP_ORIGIN" => "https://3000-#{"f" * 32}.play.example.test", "HTTP_SEC_FETCH_SITE" => "same-site")
    assert_equal 403, last_response.status
  end

  def test_neither_origin_nor_fetch_metadata_is_let_through
    start
    assert_equal 303, last_response.status
  end

  def test_without_the_client_header_everyone_shares_the_peer_address
    post "/sessions", {}, { "REMOTE_ADDR" => "172.18.0.9" }
    assert_equal ["172.18.0.9"], fake.clients
  end

  def test_refusal_pages_and_retry_after
    ends_at = Time.utc(2027, 1, 2, 14, 32).to_i
    {
      refusal(:full, 60) => [503, "60", "All 5 playground sessions are in use right now."],
      refusal(:per_ip, 1740, ends_at: ends_at) => [429, "1740", "at the latest it ends at 14:32 UTC."],
      refusal(:rate, 500) => [429, "500", "Try again in 9 minutes."],
      refusal(:paused, 300, message: "Maintenance") => [503, "300", "Maintenance. Try again later, or use"],
      refusal(:unavailable, 300, message: "It is starting up") => [503, "300", "It is starting up. Try again later"],
      refusal(:failed, 60) => [503, "60", "Something went wrong on our side. Try again in a minute."]
    }.each do |result, (status, retry_after, text)|
      fake.result = result
      start("HTTP_ORIGIN" => "https://play.example.test")
      assert_equal status, last_response.status, result.reason
      assert_equal retry_after, last_response.headers["Retry-After"], result.reason
      assert_includes last_response.body, text, result.reason
      assert_equal "no-store", last_response.headers["Cache-Control"]
    end
  end

  # ---- the small endpoints ----------------------------------------------------

  def test_status_json
    get "/status.json"
    assert_equal 200, last_response.status
    assert_equal '{"accepting":true,"paused":false,"live":2,"capacity":5,"ttl_seconds":1800}', last_response.body
    assert_match %r{\Aapplication/json}, last_response.headers["Content-Type"]
    assert_equal "no-store", last_response.headers["Cache-Control"]
  end

  def test_up_follows_the_reaper
    header "Host", "127.0.0.1:9292"
    get "/up"
    assert_equal [200, "OK"], [last_response.status, last_response.body]
    fake.healthy = false
    get "/up"
    assert_equal 503, last_response.status
  end

  def test_internal_sessions_only_for_loopback
    fake.internal = [{ handle: "1f2e3d4c5b6a7980", client: "203.0.113.7" }]
    header "Host", "127.0.0.1:9292"
    get "/internal/sessions"
    assert_equal 200, last_response.status
    assert_equal '[{"handle":"1f2e3d4c5b6a7980","client":"203.0.113.7"}]', last_response.body
    get "/internal/sessions", {}, { "REMOTE_ADDR" => "172.18.0.4" }
    assert_equal 404, last_response.status
  end

  def test_other_host_names_are_refused
    header "Host", "3000-#{"f" * 32}.play.example.test"
    get "/"
    assert_equal 403, last_response.status
    header "Host", "play.example.test"
    get "/", {}, { "HTTP_X_FORWARDED_HOST" => "evil.example" }
    assert_equal 403, last_response.status
  end

  def test_terms_robots_and_security_txt
    get "/terms"
    assert_includes last_response.body, "Your browser asks no extension marketplace."
    assert_includes last_response.body, "abuse@example.test"
    get "/robots.txt"
    assert_equal "User-agent: *\nDisallow: /sessions\n", last_response.body
    get "/.well-known/security.txt"
    assert_match %r{\AContact: mailto:abuse@example.test\nExpires: \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\n}, last_response.body
    assert_includes last_response.body, "Policy: https://github.com/saeki-mototsune/cybertrain/blob/main/SECURITY.md\n"
  end
end
```

Create `playground/control/test/playctl_test.rb`:

```ruby
# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class PlayctlTest < Minitest::Test
  include PlayTestHelpers

  H = "a1b2c3d4e5f60718"

  def setup
    @docker = FakeDocker.new
    @out = StringIO.new
    @err = StringIO.new
    @clock = FakeClock.new
  end

  def ctl(internal: -> { {} })
    sessions = Play::Sessions.new(config: play_config, docker: @docker, probe: nil, clock: @clock,
                                  log: Play::EventLog.new(@out))
    Play::Ctl.new(sessions: sessions, out: @out, err: @err, internal: internal, clock: @clock)
  end

  def paused_path
    File.join(play_config.data_dir, "paused")
  end

  def test_pause_and_resume_write_and_remove_the_flag
    assert_equal 0, ctl.run(%w[pause maintenance until 14:00 UTC])
    assert_equal "maintenance until 14:00 UTC\n", File.read(paused_path)
    assert_includes @out.string, "paused: Maintenance until 14:00 UTC."
    assert_equal 0, ctl.run(["pause"])
    assert_equal "for maintenance\n", File.read(paused_path)
    assert_equal 0, ctl.run(["resume"])
    refute File.exist?(paused_path)
    assert_equal 0, ctl.run(["resume"])
    assert_empty @docker.calls
  end

  def test_end_tears_down_one_session
    assert_equal 0, ctl.run(["end", H])
    assert_equal ["rm", "network inspect", "network rm"], @docker.keys
    assert_includes @out.string, "play event=ended handle=#{H} reason=killed"
    assert_includes @out.string, "ended #{H}\n"
  end

  def test_end_takes_exactly_one_handle
    ["end", "end #{H} #{H}", "end ../etc", "end ctplay-s-#{H}", "end #{H.upcase}x"].each do |line|
      assert_equal 2, ctl.run(line.split), line
    end
    assert_includes @err.string, "usage: playctl status"
    assert_empty @docker.calls
  end

  def test_kill_all_pauses_requests_the_reaper_and_ends_everything
    @docker.default("ps sessions", FakeDocker.ok("c#{H}\tctplay-s-#{H}\trunning\t#{H}\t1\t2\n"))
    @docker.default("network ls", FakeDocker.ok("n#{H}\tctplay-n-#{H}\t#{H}\t1\n"))
    assert_equal 0, ctl.run(["kill-all"])
    assert_equal "for maintenance\n", File.read(paused_path)
    assert File.exist?(File.join(play_config.data_dir, "kill-all"))
    assert_includes @docker.calls, ["docker", "rm", "--force", "ctplay-s-#{H}"]
    assert_includes @out.string, "killed every session; the playground stays paused until playctl resume"
  end

  def test_kill_all_keeps_an_existing_pause_message
    File.write(paused_path, "incident\n")
    assert_equal 0, ctl.run(["kill-all"])
    assert_equal "incident\n", File.read(paused_path)
  end

  def test_status_lists_sessions_with_their_clients
    @docker.default("ps sessions", FakeDocker.ok("c#{H}\tctplay-s-#{H}\trunning\t#{H}\t#{@clock.now - 720}\t#{@clock.now + 1080}\n"))
    @docker.default("stats", FakeDocker.ok("ctplay-s-#{H}\t12.5%\t420MiB / 1.5GiB\n"))
    assert_equal 0, ctl(internal: -> { { H => { "client" => "203.0.113.7" } } }).run(["status"])
    lines = @out.string.lines.map(&:rstrip)
    assert_match(/\AHANDLE +STATE +AGE +LEFT +CPU +MEMORY +CLIENT\z/, lines[0])
    assert_equal "#{H}  running     12m    18m   12.5%  420MiB / 1.5GiB         203.0.113.7", lines[1]
    assert_equal "1 of 5 sessions; accepting", lines[2]
  end

  def test_unknown_command_is_a_usage_error
    assert_equal 2, ctl.run([])
    assert_equal 2, ctl.run(["start"])
  end

  def test_the_script_reports_a_missing_setting_and_bad_usage
    script = File.expand_path("../bin/playctl", __dir__)
    out, status = Open3.capture2e({ "PLAY_PUBLIC_URL" => nil }, RbConfig.ruby, script, "status")
    assert_equal [1, "error: PLAY_PUBLIC_URL is required\n"], [status.exitstatus, out]
    env = { "PLAY_PUBLIC_URL" => "https://play.example.test", "PLAY_SESSION_IMAGE" => "x@sha256:1",
            "PLAY_ABUSE_CONTACT" => "a@example.test", "PLAY_DATA_DIR" => play_config.data_dir }
    out, status = Open3.capture2e(env, RbConfig.ruby, script, "frobnicate")
    assert_equal 2, status.exitstatus
    assert_includes out, "usage: playctl status"
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/saeki/work/cybertrain/playground/control
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
BUNDLE_PATH="$SDD/bundle" bundle exec rake test 2>&1 | grep -E 'LoadError|rake aborted'
```

Expected: `…: cannot load such file -- play/app (LoadError)` and `rake aborted!` (the loader stops at `app_test.rb`'s `require "play/app"`).

- [ ] **Step 3: Implement the routes and pages**

Create `playground/control/lib/play/app.rb`:

```ruby
# frozen_string_literal: true

require "digest"
require "json"
require "rack/utils"
require "sinatra/base"
require_relative "../play"

module Play
  # The entry page, POST /sessions and the small endpoints (spec §5.2,
  # §5.13). A request is read for three headers only: Origin and
  # Sec-Fetch-Site (the origin check) and PLAY_CLIENT_IP_HEADER (the
  # client); no form field and no body.
  class App < Sinatra::Base
    # Disables the Start button while the session starts (no double submit);
    # pageshow enables it again when the browser restores the page from its
    # back-forward cache. The page works without it.
    BUTTON_SCRIPT = 'document.querySelectorAll("form.start").forEach(function(f){var b=f.querySelector("button");' \
                    'f.addEventListener("submit",function(){b.disabled=true;b.textContent="Starting…";});' \
                    'window.addEventListener("pageshow",function(){b.disabled=false;b.textContent=b.dataset.label;});});'
    SCRIPT_SOURCE = "'sha256-#{[Digest::SHA256.digest(BUTTON_SCRIPT)].pack("m0")}'"
    SECURITY_TXT_EXPIRES = (Time.now.utc + (365 * 86_400)).strftime("%Y-%m-%dT%H:%M:%SZ")
    REFUSAL_STATUS = { paused: 503, unavailable: 503, full: 503, failed: 503, per_ip: 429, rate: 429 }.freeze

    # Rack::Protection stays off: its HttpOrigin compares Origin with the
    # request's own scheme, which is http behind the router, and would refuse
    # every POST; its FrameOptions adds X-Frame-Options, which spec §6.3 does
    # not want. The origin check below and the headers in `before` replace it.
    set :protection, false
    set :show_exceptions, false
    set :views, File.expand_path("../../views", __dir__)

    # The app for CONFIG and SESSIONS. Host names other than PLAY_PUBLIC_URL's
    # (and 127.0.0.1 and localhost, for the health check and playctl) get 403.
    def self.for(config:, sessions:)
      set :host_authorization, { permitted_hosts: [config.domain, "127.0.0.1", "localhost"] }
      new(config: config, sessions: sessions)
    end

    def initialize(app = nil, config:, sessions:)
      super(app)
      @config = config
      @sessions = sessions
    end

    helpers do
      def h(text)
        Rack::Utils.escape_html(text.to_s)
      end

      def minutes(seconds)
        n = [(seconds / 60.0).ceil, 1].max
        n == 1 ? "1 minute" : "#{n} minutes"
      end
    end

    before do
      headers "Content-Security-Policy" => "default-src 'none'; style-src 'unsafe-inline'; script-src #{SCRIPT_SOURCE}; " \
                                           "form-action 'self' #{@config.session_hosts_source}; " \
                                           "frame-ancestors 'none'; base-uri 'none'",
              "Referrer-Policy" => "no-referrer",
              "X-Content-Type-Options" => "nosniff",
              "Cache-Control" => "no-store"
    end

    get "/" do
      erb :index, locals: { status: @sessions.status, closed: @sessions.closed_message }
    end

    post "/sessions" do
      unless origin_allowed?
        @sessions.note_refusal(:origin)
        status 403
        return erb(:refusal, locals: { reason: :origin, refusal: nil })
      end
      result = @sessions.create(Limits.client_key(request.env, @config.client_ip_env_key))
      redirect result.editor_url, 303 if result.is_a?(Sessions::Created)

      status REFUSAL_STATUS.fetch(result.reason)
      headers "Retry-After" => result.retry_after.to_s
      erb :refusal, locals: { reason: result.reason, refusal: result }
    end

    get "/status.json" do
      content_type :json
      JSON.generate(@sessions.status)
    end

    get "/terms" do
      erb :terms
    end

    get "/robots.txt" do
      content_type :text
      "User-agent: *\nDisallow: /sessions\n"
    end

    get "/.well-known/security.txt" do
      content_type :text
      "Contact: mailto:#{@config.abuse_contact}\nExpires: #{SECURITY_TXT_EXPIRES}\n" \
        "Policy: https://github.com/saeki-mototsune/cybertrain/blob/main/SECURITY.md\n"
    end

    get "/up" do
      content_type :text
      halt 503, "the reaper has not reached Docker within the last minute\n" unless @sessions.healthy?
      "OK"
    end

    # playctl status reads the clients from here; the router answers 404 for
    # /internal/* itself, and this route only for loopback peers.
    get "/internal/sessions" do
      halt 404, "Not Found" unless ["127.0.0.1", "::1"].include?(request.env["REMOTE_ADDR"])
      content_type :json
      JSON.generate(@sessions.internal_list)
    end

    not_found do
      content_type :text
      "Not Found\n"
    end

    private

    # Spec §5.2: an Origin must be one of PLAY_ALLOWED_ORIGINS; without one,
    # Sec-Fetch-Site must be absent, same-origin or none (same-site is
    # refused: a visitor's own app runs on a sibling host). Origin "null"
    # counts as absent: a browser sends it for a form POST from a page served
    # with Referrer-Policy: no-referrer, which is every page here.
    def origin_allowed?
      origin = request.env["HTTP_ORIGIN"].to_s
      return @config.allowed_origins.include?(origin) unless origin.empty? || origin == "null"

      ["", "same-origin", "none"].include?(request.env["HTTP_SEC_FETCH_SITE"].to_s)
    end
  end
end
```

Create `playground/control/views/layout.erb`:

```erb
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title><%= h(@title || "cybertrain playground") %></title>
<style>
:root { --bg: #fafaf9; --fg: #1c1917; --muted: #57534e; --line: #d6d3d1; --accent: #1d4ed8; --button-fg: #ffffff; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0a0a0a; --fg: #f5f5f4; --muted: #a8a29e; --line: #44403c; --accent: #93c5fd; --button-fg: #0a0a0a; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 40rem; margin: 0 auto; padding: 48px 16px 64px; }
h1 { font-size: 1.75rem; line-height: 1.25; margin: 0 0 16px; }
p, ul { margin: 0 0 16px; }
li { margin: 4px 0; }
a { color: var(--accent); }
.muted { color: var(--muted); font-size: 0.95rem; }
.state { font-weight: 600; }
form { margin: 24px 0; }
button { font: inherit; font-weight: 600; padding: 12px 22px; border: 0; border-radius: 8px; background: var(--accent); color: var(--button-fg); cursor: pointer; }
button:disabled { opacity: 0.6; cursor: progress; }
footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid var(--line); }
</style>
</head>
<body>
<main>
<%= yield %>
</main>
</body>
</html>
```

Create `playground/control/views/index.erb`:

```erb
<% @title = "Try cybertrain in your browser" %>
<h1>Try cybertrain in your browser, no account</h1>
<p>Start a session and VS Code opens in your browser on the blog from the tutorial: its development server running in a terminal and the app in the editor's preview. Edit a view and reload the preview; change Ruby and the app rebuilds itself in about a minute.</p>
<ul>
  <li>Lasts: <%= h(minutes(status[:ttl_seconds])) %>, then the session is deleted with its files</li>
  <li>Inside: Spinel, the cybertrain CLI and the blog; no network access</li>
  <li>At a time: <%= status[:capacity] %> sessions, one per network address</li>
  <li>Works best in: a desktop browser (Chrome, Edge or Firefox)</li>
</ul>
<% if closed %>
<p class="state">The playground is paused. <%= h(closed) %>. Try again later, or use GitHub Codespaces.</p>
<% else %>
<% free = [status[:capacity] - status[:live], 0].max %>
<% if free.positive? %>
<p class="state"><%= free %> of <%= status[:capacity] %> sessions are free.</p>
<% else %>
<p class="state">All <%= status[:capacity] %> sessions are in use: try again in a few minutes.</p>
<% end %>
<form class="start" method="post" action="/sessions">
  <button type="submit" data-label="Start a session">Start a session</button>
</form>
<script><%= Play::App::BUTTON_SCRIPT %></script>
<% end %>
<p>Anyone with a session's address can use it, terminal included, so do not share it. Do not put secrets or personal data in it.</p>
<footer class="muted">
  <p><a href="/terms">Terms and privacy</a> · <a href="<%= h(@config.codespaces_url) %>" rel="noopener">Open in GitHub Codespaces instead</a> (needs a GitHub account)</p>
  <p><a href="https://saeki-mototsune.github.io/CyberTrain/" rel="noopener">cybertrain</a> · <a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">GitHub</a> · Contact: <a href="mailto:<%= h(@config.abuse_contact) %>"><%= h(@config.abuse_contact) %></a></p>
</footer>
```

Create `playground/control/views/terms.erb` (the wording of spec §5.13; the owner approves it, spec §11.2 Q7; with `V10=fallback`, use the other sentence as the Interfaces say):

```erb
<% @title = "Terms and privacy · cybertrain playground" %>
<h1>Terms and privacy</h1>
<p>The playground is provided as is, for trying cybertrain. Sessions are temporary and deleted with their files when they end; nothing is backed up. We may end any session at any time.</p>
<p>Do not use it to host or send phishing, malware or spam, for illegal content, or to attack anything. Sessions have no network access.</p>
<p>What we keep: while a session runs, the network address that started it, in memory only, to enforce the limits. Server logs record when sessions start and end with an internal number, not your address. Cloudflare, our network provider, carries all traffic, including what you type, under its own privacy policy, and may set its own security cookies. Your browser asks no extension marketplace. This site sets no cookies; the app in the preview sets its own.</p>
<p>Report abuse or a security problem: <a href="mailto:<%= h(@config.abuse_contact) %>"><%= h(@config.abuse_contact) %></a>.</p>
<footer class="muted"><p><a href="/">Back to the playground</a></p></footer>
```

Create `playground/control/views/refusal.erb`:

```erb
<% case reason
   when :origin
     @title = "Start a session from #{@config.domain}" %>
<h1>Start a session from <%= h(@config.domain) %></h1>
<p><a href="<%= h(@config.public_origin) %>/">Go to <%= h(@config.domain) %></a></p>
<% when :paused, :unavailable
     @title = "The playground is paused" %>
<h1>The playground is paused</h1>
<p><%= h(refusal.message) %>. Try again later, or use <a href="<%= h(@config.codespaces_url) %>" rel="noopener">GitHub Codespaces</a>.</p>
<% when :full
     @title = "All sessions are in use" %>
<h1>All sessions are in use</h1>
<p>All <%= @config.max_sessions %> playground sessions are in use right now. A session lasts at most <%= h(minutes(@config.ttl)) %>, so one usually frees up within a few minutes: try again shortly.</p>
<form class="start" method="post" action="/sessions">
  <button type="submit" data-label="Try again">Try again</button>
</form>
<script><%= Play::App::BUTTON_SCRIPT %></script>
<p><a href="<%= h(@config.codespaces_url) %>" rel="noopener">Open in GitHub Codespaces</a> (needs a GitHub account)</p>
<% when :per_ip
     @title = "A session from your network address is already running" %>
<h1>A session from your network address is already running</h1>
<p><%= @config.max_sessions_per_ip == 1 ? "Only one session runs" : "Only #{@config.max_sessions_per_ip} sessions run" %> per network address. If it is yours, go back to its tab. If you closed the tab, it ends a few minutes later; at the latest it ends at <%= Time.at(refusal.ends_at).utc.strftime("%H:%M") %> UTC.</p>
<% when :rate
     @title = "Too many sessions from your network address" %>
<h1>Too many sessions from your network address</h1>
<p>Try again in <%= h(minutes(refusal.retry_after)) %>.</p>
<% else
     @title = "The session could not be started" %>
<h1>The session could not be started</h1>
<p>Something went wrong on our side. Try again in a minute.</p>
<% end %>
<footer class="muted"><p><a href="/">Back to the playground</a></p></footer>
```

Create `playground/control/config.ru`:

```ruby
# frozen_string_literal: true

# The hosted playground's control plane (playground/README.md): Puma in
# single mode, so the limits and the session records live in this one
# process. playground/control/Dockerfile runs it; locally,
# playground/dev/compose.yml.
$stdout.sync = true
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "play"
require "play/app"

begin
  config = Play::Config.from_env
rescue Play::Config::Error => e
  warn "error: #{e.message}"
  exit 1
end

sessions = Play::Sessions.new(config: config, docker: Play::DockerCLI.new, probe: Play::Probe.new(config),
                              clock: Play::Clock.new, log: Play::EventLog.new($stdout))
sessions.check_availability
sessions.start_reaper
run Play::App.for(config: config, sessions: sessions)
```

- [ ] **Step 4: Implement `playctl`**

Create `playground/control/lib/play/ctl.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "net/http"

module Play
  # bin/playctl, the operator's commands (spec §5.9). They act on Docker and
  # the flag files in PLAY_DATA_DIR directly, so they work whether or not the
  # control plane runs; only `status` asks the running process (GET
  # /internal/sessions on 127.0.0.1:9292) for the clients' addresses.
  class Ctl
    USAGE = <<~TEXT
      usage: playctl status
             playctl pause [message]
             playctl resume
             playctl end <handle>
             playctl kill-all
    TEXT
    INTERNAL_URL = "http://127.0.0.1:9292/internal/sessions"

    def initialize(sessions:, out:, err:, internal: nil, clock: Clock.new)
      @sessions = sessions
      @config = sessions.config
      @out = out
      @err = err
      @internal = internal || -> { fetch_internal }
      @clock = clock
    end

    # The exit status: 0 done, 1 failed, 2 bad usage.
    def run(argv)
      command, *rest = argv
      case command
      when "status" then status
      when "pause" then pause(rest.join(" ").strip)
      when "resume" then resume
      when "end" then end_one(rest)
      when "kill-all" then kill_all
      else usage
      end
    end

    private

    def usage
      @err.print USAGE
      2
    end

    def paused_path
      File.join(@config.data_dir, "paused")
    end

    def pause(message)
      write_paused(message.empty? ? "for maintenance" : message)
      @out.puts "paused: #{@sessions.pause_message}. Running sessions go on; playctl resume starts accepting again."
      0
    end

    def write_paused(message)
      tmp = "#{paused_path}.tmp"
      File.write(tmp, "#{message}\n")
      File.rename(tmp, paused_path)
    end

    def resume
      File.delete(paused_path) if File.exist?(paused_path)
      @out.puts "resumed: new sessions are accepted"
      0
    end

    def end_one(args)
      handle = args.first.to_s
      return usage unless args.size == 1 && handle.match?(/\A\h{16}\z/)

      if @sessions.teardown(handle, reason: "killed")
        @out.puts "ended #{handle}"
        0
      else
        @err.puts "playctl: #{handle} is not fully removed (see the docker_error line); the reaper retries"
        1
      end
    end

    def kill_all
      write_paused("for maintenance") unless @sessions.pause_message
      File.write(File.join(@config.data_dir, "kill-all"), "")
      if @sessions.with_create_lock { @sessions.kill_all }
        @out.puts "killed every session; the playground stays paused until playctl resume"
        0
      else
        @err.puts "playctl: some sessions are not fully removed (see the docker_error lines); the reaper retries"
        1
      end
    end

    def status
      containers = @sessions.list_containers
      unless containers
        @err.puts "playctl: docker ps failed (see the docker_error line)"
        return 1
      end
      known = @internal.call
      stats = @sessions.read_stats(containers.select { |c| c[:state] == "running" }.map { |c| c[:name] })
      now = @clock.now
      @out.puts format("%-16s  %-8s  %5s  %5s  %6s  %-22s  %s", "HANDLE", "STATE", "AGE", "LEFT", "CPU", "MEMORY", "CLIENT")
      containers.sort_by { |c| c[:created_at] }.each do |c|
        cpu, memory = stats[c[:name]]
        client = known.dig(c[:handle], "client") || "-"
        @out.puts format("%-16s  %-8s  %4dm  %4dm  %6s  %-22s  %s", c[:handle], c[:state], (now - c[:created_at]) / 60,
                         [(c[:expires_at] - now) / 60, 0].max, cpu ? format("%.1f%%", cpu) : "-", memory || "-", client)
      end
      state = (message = @sessions.pause_message) ? "paused: #{message}" : "accepting"
      @out.puts "#{containers.size} of #{@config.max_sessions} sessions; #{state}"
      0
    end

    def fetch_internal
      uri = URI(INTERNAL_URL)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = 2
      http.read_timeout = 2
      response = http.request(Net::HTTP::Get.new(uri.request_uri))
      return {} unless response.code == "200"

      JSON.parse(response.body).to_h { |entry| [entry["handle"], entry] }
    rescue StandardError
      {}
    end
  end
end
```

Create `playground/control/bin/playctl`, then `chmod 755 playground/control/bin/playctl`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/playctl -- the hosted playground's stop switch (spec §5.9):
#   playctl status | pause [message] | resume | end <handle> | kill-all
# On the server:  kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl status'
# Locally:        docker compose -f playground/dev/compose.yml exec control bin/playctl status
$stdout.sync = true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "play"

begin
  config = Play::Config.from_env
rescue Play::Config::Error => e
  warn "error: #{e.message}"
  exit 1
end
sessions = Play::Sessions.new(config: config, docker: Play::DockerCLI.new, probe: nil, clock: Play::Clock.new,
                              log: Play::EventLog.new($stdout))
exit Play::Ctl.new(sessions: sessions, out: $stdout, err: $stderr).run(ARGV)
```

Append this line to `playground/control/lib/play.rb`, after `require_relative "play/sessions"`:

```ruby
require_relative "play/ctl"
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/saeki/work/cybertrain/playground/control
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
for i in 1 2 3; do BUNDLE_PATH="$SDD/bundle" bundle exec rake test 2>&1 | tail -n 1; done
for f in config.ru bin/playctl lib/play/app.rb lib/play/ctl.rb; do ruby -c "$f" > /dev/null || echo "syntax: $f"; done
```

Expected, three times: `74 runs, 437 assertions, 0 failures, 0 errors, 0 skips`; no `syntax:` line.

- [ ] **Step 6: Build the image and check its boot**

Create `playground/control/Dockerfile`:

```dockerfile
# playground/control/Dockerfile -- the hosted playground's control plane (SP2).
# Kamal builds it (playground/deploy/control.yml); playground/dev/compose.yml
# runs it locally. It talks to the host's Docker through the mounted socket.
FROM ruby:4.0.7-slim
# build-essential: puma's native extension. The docker CLI is the static
# binary of the official cli image; the daemon is the host's.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
COPY --from=docker:28-cli /usr/local/bin/docker /usr/local/bin/docker
ENV RACK_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=test
WORKDIR /app
COPY playground/control/Gemfile playground/control/Gemfile.lock ./
RUN bundle install
COPY playground/control/ ./
EXPOSE 9292
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s \
  CMD ["ruby", "-rnet/http", "-e", "exit(Net::HTTP.get_response(URI('http://127.0.0.1:9292/up')).code == '200' ? 0 : 1)"]
# Single-mode puma: the limits and the session records live in this process.
CMD ["bundle", "exec", "puma", "-p", "9292", "-t", "4:16"]
```

Create `playground/control/Dockerfile.dockerignore`:

```
# Build context of playground/control/Dockerfile (the repository root): the
# control plane's own files, without its tests.
*
!playground/control/
playground/control/test/
```

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
docker build -f playground/control/Dockerfile -t ctplay-control:local . > "$SDD/logs/task6-build.log" 2>&1; echo "build exit=$?"
docker run --rm ctplay-control:local; echo "exit=$?"
docker run --rm -e PLAY_PUBLIC_URL=http://play.localhost:8080 -e PLAY_SESSION_IMAGE=x -e PLAY_ABUSE_CONTACT=a@example.test -e PLAY_IDLE_TIMEOUT=60 ctplay-control:local; echo "exit=$?"
docker run --rm --entrypoint ls ctplay-control:local /app /app/bin
```

Expected: `build exit=0` (the first build compiles puma's extension, about a minute); `error: PLAY_PUBLIC_URL is required` and `exit=1`; `error: PLAY_IDLE_TIMEOUT must be more than 60 seconds (got 60)` and `exit=1`; the listing shows `Gemfile`, `Gemfile.lock`, `bin`, `config.ru`, `lib`, `views` and no `test`, and `/app/bin` holds `playctl`. (Task 7 runs the image for real; here it only proves that a bad setting stops the boot.)

- [ ] **Step 7: Commit**

```bash
git add playground/control/lib/play/app.rb playground/control/views/layout.erb playground/control/views/index.erb playground/control/views/terms.erb playground/control/views/refusal.erb playground/control/config.ru playground/control/lib/play/ctl.rb playground/control/bin/playctl playground/control/lib/play.rb playground/control/test/fakes.rb playground/control/test/app_test.rb playground/control/test/playctl_test.rb playground/control/Dockerfile playground/control/Dockerfile.dockerignore
git ls-files -s playground/control/bin/playctl
git commit -m "Control: entry page and routes, playctl, image

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from `git ls-files -s`: mode `100755`.

---

### Task 7: The local stack and the end-to-end test

**Files:**
- Create: `playground/dev/compose.yml`, `playground/dev/e2e.sh`
- Modify: `.gitignore` (append the two local data directories)
- Test: `bash playground/dev/e2e.sh` (E1-E19)

**Interfaces:**
- Consumes: `cybertrain-playground-web:local` (Task 1; with any Task 3 fallback), the router's files (Task 2), the control plane's files and image recipe (Tasks 4-6). The `V11-editor=` and `V11-preview=` values of Task 3's `V-OUTCOMES` line: with `fallback`, drop the matching `contains "$csp" "frame-ancestors …"` condition from E3 (editor) or E5 (preview), since the router no longer sends that header.
- Produces: `docker compose -f playground/dev/compose.yml up --build -d` serving `http://play.localhost:8080/` (project `ctplay-dev`; `PLAY_PROJECT`, `PLAY_PORT`, `PLAY_TTL`, `PLAY_MAX_SESSIONS`, `PLAY_MAX_SESSIONS_PER_IP`, `PLAY_CREATE_LIMIT`, `PLAY_SUBNET_POOL`, `PLAY_SESSION_IMAGE` and `PLAY_DATA_HOST` override it); `bash playground/dev/e2e.sh` (project `ctplay-e2e` on 18080, exit 0/1/2, `e2e: N passed, M failed`), which Task 10's CI job runs with `PLAY_SESSION_IMAGE=cybertrain-playground-web:ci`; Task 8 uses the dev stack.

Notes on the spec's text, applied below:
- Correction (spec §15, corrections 3 and 6): the router service has `dns: [127.0.0.1]` and `sysctls: [net.ipv4.ip_forward=0]`.
- Correction: the control plane's data directory is `${PLAY_DATA_HOST:-./data}`, and `e2e.sh` uses `./data-e2e`: with the spec's fixed `./data`, the test's project shared the dev stack's `paused` and `kill-all` flags (a test interrupted while paused left the dev stack paused). `.gitignore` gets both directories.
- `e2e.sh` follows the spec's E1-E19 with these changes, each because the spec's form could not pass or prove the point: `PLAY_TTL=180` instead of 150, so that session 1 (created at E2) outlives the checks that need it on a slow CI runner, and E18 then measures that same session's end (its window is "within 15 s of `expires-at`"); the run order is E1-E7, E9, E10, E8 (E8 needs E10's second session), E11-E15, E18, E16, E17, E19; E8's "gateway" checks become the host's own addresses and a listener on the host (spec §15, correction 5: an `inhibit_ipv4` network has no gateway, `.1` is a container), plus a check that no host interface has an address in `10.250.0.0/16` (the measure that `inhibit_ipv4` is in force, which §15 asks the end-to-end test to keep checking), and a refused connection counts as a way out; E11 adds "a session just ended with `playctl end` answers the 404 page within 5 s" (§15, correction 4; Review Focus 2); E12 adds `Origin: null` from this origin, which must pass the origin check (it then meets the per-client limit: 429); E13 adds the router's DNS and `ip_forward`; E14 expects `"live":1` (one session is left at that point of the sequence, not two); E17 sends its POST from inside the control plane's container, since a stopped router leaves no way in from outside.
- It refuses to start (exit 2) while any playground session exists on this Docker: a second control plane would adopt or reap them (they share the labels).

- [ ] **Step 1: Write the failing test**

Create `playground/dev/e2e.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# playground/dev/e2e.sh -- the end-to-end test of the hosted playground: the
# router, the control plane and real sessions on this machine's Docker,
# through playground/dev/compose.yml as a separate project (ctplay-e2e, port
# 18080, data in playground/dev/data-e2e), brought up and removed by the
# script. Build the session image first:
#
#   docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
#   bash playground/dev/e2e.sh                    # PLAY_SESSION_IMAGE=... for another tag
#
# One line per check, "PASS <ID> <what>" or "FAIL <ID> <what> (<detail>)",
# then "e2e: N passed, M failed"; exit 0 when every check passes, 1 otherwise
# (after the last 40 log lines of the control plane and the router), 2 when
# it cannot start. It refuses to start while any playground session exists:
# a second control plane on the same Docker would adopt or reap them.
# playground/README.md lists the checks (E1-E19). Needs bash 3.2+, docker
# with compose v2, curl and sha256sum or shasum. About 5 minutes.
set -u

here=$(cd "$(dirname "$0")" && pwd)
export PLAY_PROJECT=ctplay-e2e PLAY_PORT=18080 PLAY_TTL=180 PLAY_MAX_SESSIONS=2 PLAY_MAX_SESSIONS_PER_IP=1 \
  PLAY_CREATE_LIMIT=2 PLAY_DATA_HOST=./data-e2e
export PLAY_SESSION_IMAGE=${PLAY_SESSION_IMAGE:-cybertrain-playground-web:local}
base=http://127.0.0.1:18080
domain=play.localhost:18080
entry_origin=http://play.localhost:18080
work=$(mktemp -d "${TMPDIR:-/tmp}/playground-e2e.XXXXXX") || exit 2
hostlisten=ctplay-e2e-hostlisten
passed=0
failed=0
code=""
secrets=""

dc() {
  docker compose -f "$here/compose.yml" "$@"
}

if command -v sha256sum > /dev/null 2>&1; then
  sha="sha256sum"
else
  sha="shasum -a 256"
fi

handle_of() {
  printf '%s' "$1" | $sha | cut -c 1-16
}

labelled() { # containers|networks
  if [ "$1" = containers ]; then
    docker ps -aq --filter label=cybertrain-play.role=session
  else
    docker network ls -q --filter label=cybertrain-play.role=session
  fi
}

count() {
  labelled "$1" | grep -c . | tr -d ' '
}

remove_sessions() {
  local ids n c
  ids=$(labelled containers)
  if [ -n "$ids" ]; then
    docker rm -f $ids > /dev/null 2>&1
  fi
  for n in $(labelled networks); do
    for c in $(docker network inspect -f '{{range $id, $x := .Containers}}{{$id}} {{end}}' "$n" 2> /dev/null); do
      docker network disconnect -f "$n" "$c" > /dev/null 2>&1
    done
    docker network rm "$n" > /dev/null 2>&1
  done
}

cleanup() {
  docker rm -f "$hostlisten" > /dev/null 2>&1
  dc down --remove-orphans > /dev/null 2>&1
  remove_sessions
  rm -rf "$here/data-e2e" "$work"
}

if ! docker image inspect "$PLAY_SESSION_IMAGE" > /dev/null 2>&1; then
  echo "e2e: no image $PLAY_SESSION_IMAGE (build it first, see the top of this script)" >&2
  exit 2
fi
if [ -n "$(labelled containers)$(labelled networks)" ]; then
  echo "e2e: playground sessions exist already (a dev stack?); stop it with" >&2
  echo "  docker compose -f playground/dev/compose.yml down   and remove the sessions (playground/README.md)" >&2
  exit 2
fi
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() {
  passed=$((passed + 1))
  echo "PASS $1 $2"
}

fail() {
  failed=$((failed + 1))
  echo "FAIL $1 $2 ($3)"
}

contains() { # TEXT PART
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# check ID WHAT OK DETAIL: PASS when OK is "yes".
check() {
  if [ "$3" = yes ]; then
    pass "$1" "$2"
  else
    fail "$1" "$2" "$4"
  fi
}

# get HOST PATH [curl options]: GET through the router with that Host;
# sets $code, and the body and headers are in $work/body and $work/head.
get() {
  local host=$1 path=$2
  shift 2
  code=$(curl -s -o "$work/body" -D "$work/head" -w '%{http_code}' --max-time 10 -H "Host: $host" "$@" "$base$path")
}

header() {
  grep -i "^$1:" "$work/head" | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//'
}

has() {
  if grep -qF -- "$1" "$work/body"; then echo yes; else echo no; fi
}

# start CLIENT [curl options]: POST /sessions as CLIENT (CF-Connecting-IP),
# from the entry page's origin unless the options say otherwise. Sets $code,
# $location, $sid, $handle and $pid (the last three empty unless 303).
start() {
  local client=$1
  shift
  local began=$SECONDS
  if [ "$#" -eq 0 ]; then
    set -- -H "Origin: $entry_origin" -H "Sec-Fetch-Site: same-origin"
  fi
  code=$(curl -s -o "$work/body" -D "$work/head" -w '%{http_code}' --max-time 40 -X POST \
    -H "Host: $domain" -H "CF-Connecting-IP: $client" "$@" "$base/sessions")
  took=$((SECONDS - began))
  location=$(header location)
  sid=$(printf '%s' "$location" | sed -n 's|^http://\([0-9a-f]\{32\}\)\.play\.localhost:18080/.*|\1|p')
  handle=""
  pid=""
  if [ -n "$sid" ]; then
    handle=$(handle_of "$sid")
    pid=$(docker exec "ctplay-s-$handle" printenv VSCODE_PROXY_URI 2> /dev/null | sed -n 's|.*{{port}}-\([0-9a-f]\{32\}\)\..*|\1|p')
    secrets="$secrets $sid $pid"
  fi
}

end_session() {
  dc exec -T control bin/playctl end "$1" > "$work/end.out" 2>&1
}

healthz() { # SID -> HTTP status of its editor's /healthz
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $1.$domain" "$base/healthz"
}

# inside SESSION-HANDLE COMMAND: runs COMMAND as the visitor (uid 1000) in it.
inside() {
  local h=$1
  shift
  docker exec -u 1000:1000 "ctplay-s-$h" bash -c "$*" 2>&1
}

echo "e2e: bringing up $PLAY_PROJECT on $base with $PLAY_SESSION_IMAGE"
rm -rf "$here/data-e2e"
if ! dc up --build -d > "$work/up.log" 2>&1; then
  tail -n 40 "$work/up.log"
  echo "e2e: docker compose up failed" >&2
  exit 2
fi
router=$(dc ps -q router)
control=$(dc ps -q control)
ready=no
for i in $(seq 1 90); do
  if [ "$(curl -s --max-time 2 -H "Host: $domain" "$base/status.json")" = '{"accepting":true,"paused":false,"live":0,"capacity":2,"ttl_seconds":180}' ]; then
    ready=yes
    break
  fi
  sleep 1
done
if [ "$ready" != yes ]; then
  dc logs --tail 40 control router
  echo "e2e: the stack did not come up within 90 s" >&2
  exit 2
fi

# ---- E1-E7: the entry page, a session, its editor and its preview ----------

get "$domain" /
st=$(curl -s --max-time 5 -H "Host: $domain" "$base/status.json")
ok=no
if [ "$code" = 200 ] && [ "$(has "2 of 2 sessions are free.")" = yes ] && contains "$st" '"live":0'; then ok=yes; fi
check E1 "the entry page says 2 of 2 sessions are free and status.json says live 0" "$ok" "GET / $code, status.json $st"

start 198.51.100.1
s1=$sid h1=$handle p1=$pid
ok=no
if [ "$code" = 303 ] && [ "$took" -le 30 ] &&
  printf '%s' "$location" | grep -Eq '^http://[0-9a-f]{32}\.play\.localhost:18080/\?folder=%2Fworkspace%2Fblog&payload=' &&
  [ -n "$p1" ]; then ok=yes; fi
check E2 "POST /sessions answers 303 to the editor within 30 s (took $took s)" "$ok" "status $code, Location: $location, preview id: ${p1:-none}"

get "$s1.$domain" "/?folder=%2Fworkspace%2Fblog"
csp=$(header content-security-policy)
ok=no
if [ "$code" = 200 ] && [ "$(has vscode-workbench-web-configuration)" = yes ] && [ "$(header referrer-policy)" = no-referrer ] &&
  [ "$(header x-robots-tag)" = "noindex, nofollow" ] && contains "$csp" "frame-ancestors 'self'"; then ok=yes; fi
check E3 "the editor answers 200 with the workbench and the editor's headers" "$ok" \
  "status $code, Referrer-Policy: $(header referrer-policy), X-Robots-Tag: $(header x-robots-tag), CSP: $csp"

ws() { # ORIGIN -> the status line of a WebSocket handshake to the editor
  curl -s -i -N --http1.1 --max-time 4 -H "Host: $s1.$domain" -H "Origin: $1" -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "$base/?reconnectionToken=e2e-$$&reconnection=false&skipWebSocketFrames=false" 2> /dev/null | head -n 1 | tr -d '\r'
}
good=$(ws "http://$s1.$domain")
evil=$(ws "http://evil.localhost:18080")
ok=no
if contains "$good" " 101 " && contains "$evil" " 403"; then ok=yes; fi
check E4 "the editor's WebSocket handshake is 101 from its own origin and 403 from another" "$ok" "own origin: $good; other: $evil"

docker exec -d -u 1000:1000 "ctplay-s-$h1" bash -lc 'playground-server > /tmp/s.log 2>&1'
for i in $(seq 1 30); do
  get "3000-$p1.$domain" /articles
  [ "$code" = 200 ] && break
  sleep 1
done
banner=$(docker exec "ctplay-s-$h1" cat /tmp/s.log 2> /dev/null)
csp=$(header content-security-policy)
ok=no
if [ "$code" = 200 ] && [ "$(header cache-control)" = no-store ] && [ "$(header x-robots-tag)" = "noindex, nofollow" ] &&
  contains "$csp" 'frame-ancestors *.play.localhost:*' && contains "$banner" "App    http://3000-$p1.$domain/"; then ok=yes; fi
check E5 "the preview answers /articles with no-store, noindex and frame-ancestors *.play.localhost:*; the banner names it" "$ok" \
  "status $code, Cache-Control: $(header cache-control), CSP: $csp, banner: $(printf '%s' "$banner" | grep 'App ' | head -n 1)"

jar="$work/jar"
get "3000-$p1.$domain" /articles/new -c "$jar"
token=$(sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p' "$work/body" | head -n 1)
cookie=$(header set-cookie)
title="E2E $(date +%s)"
posted=$(curl -s -o /dev/null -D "$work/head" -w '%{http_code}' --max-time 10 -H "Host: 3000-$p1.$domain" -b "$jar" -c "$jar" \
  --data-urlencode "authenticity_token=$token" --data-urlencode "article[title]=$title" \
  --data-urlencode "article[body]=A body that is long enough." "$base/articles")
article=$(header location)
get "3000-$p1.$domain" "${article:-/none}" -b "$jar"
ok=no
if [ "$posted" = 303 ] && printf '%s' "$article" | grep -Eq '^/articles/[0-9]+$' && [ "$code" = 200 ] &&
  [ "$(has "$title")" = yes ] && contains "$cookie" "SameSite=Lax" && ! contains "$cookie" "Secure"; then ok=yes; fi
check E6 "a form on the preview host: a Lax cookie without Secure, POST 303 to the article, which shows" "$ok" \
  "POST $posted, Location: $article, then $code; Set-Cookie: $cookie"

get "3000-$s1.$domain" /
crossed=$code
crossed_page=$(has "No app is answering")
get "$p1.$domain" /
ok=no
if [ "$crossed" = 502 ] && [ "$crossed_page" = yes ] && [ "$code" = 404 ] && [ "$(has "No session at this address")" = yes ]; then ok=yes; fi
check E7 "the two ids do not stand in for each other: 3000-<editor id> is the 502 page, <preview id> alone the 404 page" "$ok" \
  "3000-<sid>: $crossed, <pid>: $code"

# ---- E9: confinement, from inside session 1 ---------------------------------

confined=$(inside "$h1" 'echo uid=$(id -u); awk "/^(CapEff|NoNewPrivs):/ {print \$1 \$2}" /proc/1/status; if touch /opt/cybertrain/.e2e 2> /dev/null; then echo root=writable; else echo root=read-only; fi; touch /workspace/.e2e && echo workspace=writable; echo memory=$(cat /sys/fs/cgroup/memory.max); echo pids=$(cat /sys/fs/cgroup/pids.max); echo cpu=$(cat /sys/fs/cgroup/cpu.max); if [ -e /var/run/docker.sock ]; then echo socket=present; else echo socket=absent; fi')
missing=""
for want in uid=1000 CapEff:0000000000000000 NoNewPrivs:1 root=read-only workspace=writable memory=1610612736 pids=512 "cpu=100000 100000" socket=absent; do
  printf '%s\n' "$confined" | grep -qxF "$want" || missing="$missing [$want]"
done
ok=no
if [ -z "$missing" ]; then ok=yes; fi
check E9 "inside: uid 1000, no capabilities, no new privileges, read-only root, writable /workspace, 1536 MiB, 512 pids, 1 CPU, no Docker socket" \
  "$ok" "missing:$missing"

# ---- E10: the global cap ------------------------------------------------------

start 198.51.100.2
s2=$sid h2=$handle second=$code
start 198.51.100.3
third=$code
third_page=$(has "All 2 playground sessions are in use right now")
third_retry=$(header retry-after)
ok=no
if [ "$second" = 303 ] && [ "$third" = 503 ] && [ "$third_page" = yes ] && [ "$third_retry" = 60 ] &&
  [ "$(count containers)" = 2 ] && [ "$(count networks)" = 2 ]; then ok=yes; fi
check E10 "a second client gets a session, a third the 503 full page; Docker holds exactly 2 sessions" "$ok" \
  "second: $second, third: $third (Retry-After $third_retry), containers: $(count containers), networks: $(count networks)"

# ---- E8: no way out of session 1 ------------------------------------------------
# Run after E10, which makes the second session to try. "Connection refused"
# counts as a way out: something on that address answered.

router_image=$(docker inspect -f '{{.Image}}' "$router")
docker run -d --name "$hostlisten" --network host --entrypoint caddy "$router_image" \
  respond --listen :18099 --body host-listener > /dev/null 2>&1
host_ips=$(docker run --rm --network host --entrypoint ip "$router_image" -o -4 addr show 2> /dev/null |
  awk '{print $4}' | cut -d / -f 1 | grep -v '^127\.')
other_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"ctplay-n-$h2\").IPAddress}}" "ctplay-s-$h2" 2> /dev/null)
router_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"ctplay-n-$h1\").IPAddress}}" "$router" 2> /dev/null)
cat > "$work/escape.sh" <<'EOF'
other=$1
shift
leak() { echo "LEAK $1 ($2)"; }
tcp() {
  out=$(timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)
  rc=$?
  if [ "$rc" = 0 ]; then leak "$1:$2" connected; fi
  case "$out" in *"Connection refused"*) leak "$1:$2" "refused, so it answers" ;; esac
}
curl -s --max-time 5 -o /dev/null https://example.com && leak example.com https
getent hosts example.com > /dev/null && leak example.com "resolves"
getent hosts ctplay-control > /dev/null && leak ctplay-control "resolves"
tcp 1.1.1.1 80
tcp 169.254.169.254 80
for port in 22 80 443 2375; do tcp 172.17.0.1 "$port"; done
for ip in "$@"; do tcp "$ip" 18099; done
tcp "$other" 8080
tcp "$other" 3000
echo checked
EOF
escape=$(docker exec -i -u 1000:1000 "ctplay-s-$h1" bash -s -- "${other_ip:-0.0.0.0}" $host_ips < "$work/escape.sh" 2>&1)
inside "$h1" "curl -s --max-time 5 -o /dev/null -H 'Host: play.localhost' http://$router_ip/" > /dev/null
aborted=$?
bridge=$(printf '%s\n' "$host_ips" | grep -c '^10\.250\.' | tr -d ' ')
docker rm -f "$hostlisten" > /dev/null 2>&1
leaks=$(printf '%s\n' "$escape" | grep '^LEAK' | tr '\n' ' ')
ok=no
if contains "$escape" checked && [ -z "$leaks" ] && [ "$aborted" = 52 ] && [ "$bridge" = 0 ] && [ -n "$host_ips" ] && [ -n "$other_ip" ]; then ok=yes; fi
check E8 "from a session: no internet, DNS, metadata, host or other session; the router drops it; no session bridge has a host address" "$ok" \
  "leaks: ${leaks:-none}; router: curl exit $aborted (52 expected); host addresses in 10.250/16: $bridge; host addresses tried: $(printf '%s' "$host_ips" | tr '\n' ' ')"

# ---- E11-E13: per-client limits, origins, unknown hosts -----------------------

start 198.51.100.1
again=$code
again_retry=$(header retry-after)
end_session "$h2"
ended=$?
began=$SECONDS
gone_code=$(healthz "$s2")
gone_took=$((SECONDS - began))
start 198.51.100.9
r1=$code
end_session "$handle"
start 198.51.100.9
r2=$code
end_session "$handle"
start 198.51.100.9
r3=$code
r3_retry=$(header retry-after)
ok=no
if [ "$again" = 429 ] && [ -n "$again_retry" ] && [ "$ended" = 0 ] && [ "$gone_code" = 404 ] && [ "$gone_took" -le 5 ] &&
  [ "$r1" = 303 ] && [ "$r2" = 303 ] && [ "$r3" = 429 ] && [ -n "$r3_retry" ]; then ok=yes; fi
check E11 "the same client gets 429; a just-ended session answers the 404 page at once; a third creation in the window gets 429" "$ok" \
  "same client: $again (Retry-After $again_retry); playctl end: exit $ended, then $gone_code in $gone_took s; creations: $r1 $r2 $r3 (Retry-After $r3_retry)"

start 198.51.100.12 -H "Origin: http://evil.localhost"
o1=$code
start 198.51.100.12 -H "Sec-Fetch-Site: same-site"
o2=$code
start 198.51.100.1 -H "Origin: null" -H "Sec-Fetch-Site: same-origin"
o3=$code
ok=no
if [ "$o1" = 403 ] && [ "$o2" = 403 ] && [ "$o3" = 429 ]; then ok=yes; fi
check E12 "another origin and a same-site request get 403; Origin null from this origin passes the check" "$ok" \
  "evil origin: $o1, same-site: $o2, null from same-origin: $o3 (429 is the per-client limit, past the origin check)"

get "ffffffffffffffffffffffffffffffff.$domain" /
u1=$code
u1_page=$(has "No session at this address")
get "foo.$domain" /
u2=$code
get "$domain" /internal/sessions
u3=$code
dns=$(docker inspect -f '{{.HostConfig.Dns}}' "$router")
forward=$(docker exec "$router" cat /proc/sys/net/ipv4/ip_forward 2>&1)
ok=no
if [ "$u1" = 404 ] && [ "$u1_page" = yes ] && [ "$u2" = 404 ] && [ "$u3" = 404 ] && [ "$dns" = "[127.0.0.1]" ] &&
  [ "$forward" = 0 ]; then ok=yes; fi
check E13 "unknown hosts get the 404 page, /internal/* through the router is 404, the router asks no outside resolver and forwards nothing" "$ok" \
  "unknown id: $u1, foo: $u2, /internal/sessions: $u3, router DNS: $dns, ip_forward: $forward"

# ---- E14-E15: restarts ----------------------------------------------------------

docker restart -t 5 "$control" > /dev/null
back=no
for i in $(seq 1 10); do
  st=$(curl -s --max-time 2 -H "Host: $domain" "$base/status.json")
  if contains "$st" '"live":1,'; then back=yes; break; fi
  sleep 1
done
editor=$(healthz "$s1")
ok=no
if [ "$back" = yes ] && [ "$editor" = 200 ]; then ok=yes; fi
check E14 "after a control-plane restart status.json counts the live session within 10 s and its editor answers" "$ok" \
  "status.json: $st, editor: $editor"

dc up -d --force-recreate --no-deps router > /dev/null 2>&1
router=$(dc ps -q router)
began=$SECONDS
editor=000
while [ $((SECONDS - began)) -lt 15 ]; do
  editor=$(healthz "$s1")
  [ "$editor" = 200 ] && break
  sleep 1
done
took=$((SECONDS - began))
ok=no
if [ "$editor" = 200 ] && [ "$took" -le 10 ]; then ok=yes; fi
check E15 "a re-created router reaches the live session within 10 s (took $took s)" "$ok" "editor: $editor"

# ---- E18: the TTL, on session 1 (created at E2) ------------------------------------

expires=$(docker inspect -f '{{index .Config.Labels "cybertrain-play.expires-at"}}' "ctplay-s-$h1" 2> /dev/null)
now_status=200
while [ "$now_status" = 200 ] && [ "$(date +%s)" -lt $((${expires:-0} + 30)) ]; do
  sleep 2
  now_status=$(healthz "$s1")
done
late=$(($(date +%s) - ${expires:-0}))
sleep 3
ok=no
if [ "$now_status" = 404 ] && [ "$late" -le 15 ] && [ "$(count containers)" = 0 ] && [ "$(count networks)" = 0 ]; then ok=yes; fi
check E18 "session 1 ends at its TTL: its editor is the 404 page within 15 s of expires-at, no labelled container or network is left" "$ok" \
  "editor: $now_status, $late s after expires-at; containers: $(count containers), networks: $(count networks)"

# ---- E16-E17: the stop switch, and a failure that leaves nothing --------------------

dc exec -T control bin/playctl pause "e2e check" > /dev/null 2>&1
get "$domain" /
paused_page=$(has "The playground is paused. E2e check.")
start 198.51.100.16
paused_post=$code
dc exec -T control bin/playctl resume > /dev/null 2>&1
start 198.51.100.16
resumed=$code
dc exec -T control bin/playctl kill-all > /dev/null 2>&1
killed=$?
ok=no
if [ "$paused_page" = yes ] && [ "$paused_post" = 503 ] && [ "$resumed" = 303 ] && [ "$killed" = 0 ] &&
  [ "$(count containers)" = 0 ] && [ "$(count networks)" = 0 ]; then ok=yes; fi
check E16 "pause shows on the entry page and refuses with 503; resume accepts; kill-all leaves no session and no network" "$ok" \
  "paused page: $paused_page, paused POST: $paused_post, resumed POST: $resumed, kill-all: exit $killed, containers: $(count containers), networks: $(count networks)"
sleep 6
dc exec -T control bin/playctl resume > /dev/null 2>&1

# With the router stopped nothing reaches the control plane from outside, so
# the request comes from inside its own container (loopback, a permitted host).
dc stop router > /dev/null 2>&1
no_router=$(docker exec "$control" ruby -rnet/http -e 'r = Net::HTTP.new("127.0.0.1", 9292).post("/sessions", "", "Host" => "localhost", "CF-Connecting-IP" => "198.51.100.17"); print r.code' 2>&1)
ok=no
if [ "$no_router" = 503 ] && [ "$(count containers)" = 0 ] && [ "$(count networks)" = 0 ]; then ok=yes; fi
check E17 "with the router stopped a creation is refused with 503 and leaves nothing behind" "$ok" \
  "status $no_router, containers: $(count containers), networks: $(count networks)"
dc start router > /dev/null 2>&1

# ---- E19: the log holds no session id, preview id or client address ---------------

dc logs --no-log-prefix control > "$work/control.log" 2>&1
leaked=""
for secret in $secrets 198.51.100.; do
  if grep -qF -- "$secret" "$work/control.log"; then leaked="$leaked $secret"; fi
done
created=$(grep -c 'play event=created ' "$work/control.log" | tr -d ' ')
ok=no
if [ -z "$leaked" ] && [ "$created" -ge 4 ]; then ok=yes; fi
check E19 "the control plane's log names no session id, preview id or client address ($created creations logged)" "$ok" \
  "found:${leaked:- nothing}"

echo "e2e: $passed passed, $failed failed"
if [ "$failed" -eq 0 ]; then
  exit 0
fi
dc logs --tail 40 control router
exit 1
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/saeki/work/cybertrain
/bin/bash -n playground/dev/e2e.sh && echo "parses with bash 3.2"
bash playground/dev/e2e.sh; echo "exit=$?"
```

Expected: `parses with bash 3.2`; then `e2e: bringing up ctplay-e2e on http://127.0.0.1:18080 with cybertrain-playground-web:local`, compose's complaint that `playground/dev/compose.yml` does not exist (`no such file or directory`), `e2e: docker compose up failed` and `exit=2`. (If it says playground sessions exist already, remove them first: `docker ps -aq --filter label=cybertrain-play.role=session | xargs docker rm -f`, then their networks as in spec §5.9's fallback.)

- [ ] **Step 3: Write the compose file and the ignore rules**

Create `playground/dev/compose.yml`:

```yaml
# playground/dev/compose.yml -- the whole hosted playground on this machine,
# without Cloudflare or Kamal, at http://play.localhost:8080 (browsers resolve
# *.localhost to this machine). Build the session image first:
#   docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
#   docker compose -f playground/dev/compose.yml up --build
# playground/dev/e2e.sh brings up its own copy (project ctplay-e2e, port
# 18080, data in data-e2e/).
name: ${PLAY_PROJECT:-ctplay-dev}
services:
  router:
    build:
      context: ../..
      dockerfile: playground/router/Dockerfile
    environment:
      PLAY_DOMAIN: play.localhost
      PLAY_PUBLIC_URL: http://play.localhost:${PLAY_PORT:-8080}
      PLAY_SUBNET_POOL: ${PLAY_SUBNET_POOL:-10.250.0.0/16}
      ROUTER_LOG_OUTPUT: stderr
    # As in production (playground/deploy/router.yml.example): no outside
    # resolver, no IP forwarding.
    dns:
      - 127.0.0.1
    sysctls:
      - net.ipv4.ip_forward=0
    ports:
      - "127.0.0.1:${PLAY_PORT:-8080}:80"
    networks:
      default:
        aliases: [ctplay-router]
  control:
    build:
      context: ../..
      dockerfile: playground/control/Dockerfile
    environment:
      PLAY_PUBLIC_URL: http://play.localhost:${PLAY_PORT:-8080}
      PLAY_SESSION_IMAGE: ${PLAY_SESSION_IMAGE:-cybertrain-playground-web:local}
      PLAY_ROUTER_URL: http://ctplay-router
      PLAY_ROUTER_FILTERS: label=com.docker.compose.project=${PLAY_PROJECT:-ctplay-dev},label=com.docker.compose.service=router
      PLAY_CLIENT_IP_HEADER: CF-Connecting-IP
      PLAY_MAX_SESSIONS: ${PLAY_MAX_SESSIONS:-3}
      PLAY_MAX_SESSIONS_PER_IP: ${PLAY_MAX_SESSIONS_PER_IP:-1}
      PLAY_CREATE_LIMIT: ${PLAY_CREATE_LIMIT:-3}
      PLAY_TTL: ${PLAY_TTL:-1800}
      PLAY_SUBNET_POOL: ${PLAY_SUBNET_POOL:-10.250.0.0/16}
      PLAY_ABUSE_CONTACT: abuse@playground.invalid
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${PLAY_DATA_HOST:-./data}:/data
    networks:
      default:
        aliases: [ctplay-control]
```

Append to `.gitignore`:

```
# The hosted playground's local stack (playground/dev): the control plane's
# flags and lock, for the dev stack and for e2e.sh.
playground/dev/data/
playground/dev/data-e2e/
```

Then:

```bash
docker compose -f playground/dev/compose.yml config -q && echo "compose file valid"
git check-ignore playground/dev/data/x playground/dev/data-e2e/x
```

Expected: `compose file valid`; both paths printed.

- [ ] **Step 4: Bring the dev stack up once by hand**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
docker compose -f playground/dev/compose.yml up --build -d > "$SDD/logs/task7-up.log" 2>&1; echo "up exit=$?"
for i in $(seq 1 60); do curl -s --max-time 2 -H 'Host: play.localhost:8080' http://127.0.0.1:8080/status.json && break; sleep 1; done; echo
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: play.localhost:8080' http://127.0.0.1:8080/
docker compose -f playground/dev/compose.yml logs --no-log-prefix control | head -n 5
docker compose -f playground/dev/compose.yml down
```

Expected: `up exit=0` (the first build of both images takes a few minutes; run it in the background); `{"accepting":true,"paused":false,"live":0,"capacity":3,"ttl_seconds":1800}`; `200`; Puma's start lines and no `error:` and no `event=unavailable`. Then the stack is down again.

- [ ] **Step 5: Run the end-to-end test**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
bash playground/dev/e2e.sh > "$SDD/logs/task7-e2e.log" 2>&1; echo "exit=$?"
cat "$SDD/logs/task7-e2e.log"
docker ps -a --filter label=cybertrain-play.role=session -q | wc -l; docker network ls --filter label=cybertrain-play.role=session -q | wc -l
```

Run it in the background (about 6 minutes; E18 waits for session 1's end). Expected, in this order (the times vary):

```
e2e: bringing up ctplay-e2e on http://127.0.0.1:18080 with cybertrain-playground-web:local
PASS E1 the entry page says 2 of 2 sessions are free and status.json says live 0
PASS E2 POST /sessions answers 303 to the editor within 30 s (took 3 s)
PASS E3 the editor answers 200 with the workbench and the editor's headers
PASS E4 the editor's WebSocket handshake is 101 from its own origin and 403 from another
PASS E5 the preview answers /articles with no-store, noindex and frame-ancestors *.play.localhost:*; the banner names it
PASS E6 a form on the preview host: a Lax cookie without Secure, POST 303 to the article, which shows
PASS E7 the two ids do not stand in for each other: 3000-<editor id> is the 502 page, <preview id> alone the 404 page
PASS E9 inside: uid 1000, no capabilities, no new privileges, read-only root, writable /workspace, 1536 MiB, 512 pids, 1 CPU, no Docker socket
PASS E10 a second client gets a session, a third the 503 full page; Docker holds exactly 2 sessions
PASS E8 from a session: no internet, DNS, metadata, host or other session; the router drops it; no session bridge has a host address
PASS E11 the same client gets 429; a just-ended session answers the 404 page at once; a third creation in the window gets 429
PASS E12 another origin and a same-site request get 403; Origin null from this origin passes the check
PASS E13 unknown hosts get the 404 page, /internal/* through the router is 404, the router asks no outside resolver and forwards nothing
PASS E14 after a control-plane restart status.json counts the live session within 10 s and its editor answers
PASS E15 a re-created router reaches the live session within 10 s (took 5 s)
PASS E18 session 1 ends at its TTL: its editor is the 404 page within 15 s of expires-at, no labelled container or network is left
PASS E16 pause shows on the entry page and refuses with 503; resume accepts; kill-all leaves no session and no network
PASS E17 with the router stopped a creation is refused with 503 and leaves nothing behind
PASS E19 the control plane's log names no session id, preview id or client address (5 creations logged)
e2e: 19 passed, 0 failed
```

then `0` and `0` (the script removed everything; `docker compose -p ctplay-e2e ps` is empty). On Docker Desktop "the host" a session cannot reach is the Linux VM (spec §8.1); the real host is checked on the VPS (P6). A failure prints the last 40 log lines of the control plane and the router: fix the cause in the owning files (Tasks 1, 2, 4-6, or this task's), never by weakening a check, and say which task's file you changed and why.

- [ ] **Step 6: Commit**

```bash
git add playground/dev/compose.yml playground/dev/e2e.sh .gitignore
git status --short
git commit -m "Playground: the local stack (compose) and the end-to-end test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from `git status --short`: the three staged files only (no `playground/dev/data*`).

---

### Task 8: Browser checklist on the local stack (B1-B4, B11, B13)

The whole local stack in a real browser, starting where a visitor starts: the entry page's button.

**Files:**
- Modify, only if a row fails and the fix is within the spec's meaning: the file that owns the behaviour (say which, and why, in your report)
- Test: the checklist below, in a browser, against `docker compose -f playground/dev/compose.yml up` (`http://play.localhost:8080/`); screenshots `$SDD/screens/task8-*.png`

**Interfaces:**
- Consumes: the dev stack of Task 7; the `V9-guide=` value of Task 3's `V-OUTCOMES` line (with `fallback`, B1 expects `PLAYGROUND.md` open as text, not rendered).
- Produces: the results of B1-B4, B11 and B13 (and the Back-button row) in your report, which Task 11's documentation and Task 12's owner list use; the measured time from Start to the editor and from closing the tab to the session's end.

Browser: the Playwright MCP tools or the built-in browser tools (Chromium); Firefox only if your tools can drive it (B13; otherwise record "not checked locally", the owner checks Firefox and Safari on the real domain, spec §7.7 P5). Start the stack through the sandbox bypass. The stack's defaults: 3 sessions, 1 per client, 30 minutes; every request from the browser counts as the same client (no `CF-Connecting-IP` locally).

- [ ] **Step 1: Write the checklist**

| # | Do | Pass when |
| --- | --- | --- |
| U1 (B1, Review Focus 1) | Open `http://play.localhost:8080/`; screenshot `task8-01-entry.png`; press "Start a session" (the button, not a typed URL); note the time; wait for the editor; screenshot `task8-02-editor.png` at 25 s | The entry page says `3 of 3 sessions are free.`; the button turns into "Starting…"; the browser lands on `http://<32 hex>.play.localhost:8080/?folder=%2Fworkspace%2Fblog&payload=…` with no 403 page and no CSP error in the console; `PLAYGROUND.md` open rendered (as text with `V9-guide=fallback`); the "cybertrain server" terminal shows the banner (`App    http://3000-<32 hex>.play.localhost:8080/`, `Ends   in 29 minutes (…)`) and `* Listening on http://0.0.0.0:3000`; within 10 s of that line, untouched, the Simple Browser shows the article list. Record Start → editor and Start → preview in seconds |
| U2 (B2) | In the Simple Browser: New article, a title and a body of at least 10 characters, Create; screenshot `task8-03-created.png` | The article's page (a 303 to `/articles/<id>`), not 403: the `SameSite=Lax` cookie went round inside the real webview frame |
| U3 (B3) | Change the `<h1>` in `app/views/articles/index.html.erb`, save, press the preview's reload; then add `validates :body, presence: true, length: { minimum: 10 }` inside the class in `app/models/article.rb`, save, watch the terminal until the server restarts, and create an article with the body `short` | The new heading at once; the terminal shows the rebuild and the restart (record the seconds); the short body is refused with "Body is too short (minimum is 10 characters)" (422) |
| U4 (B4) | Reload the browser tab (F5); wait 15 s; screenshot `task8-04-reload.png`; in a new terminal run `pgrep -c -f '^/workspace/blog/build/bin/blog( \|$)'` | The terminal and the preview come back; no "Select an instance to terminate" prompt; `1` |
| U5 (Review Focus 5) | Press the browser's Back button (to the entry page); screenshot `task8-05-back.png` | The button reads "Start a session" and is enabled (the `pageshow` handler); pressing it now shows the 429 page "A session from your network address is already running" with "at the latest it ends at HH:MM UTC" (the editor's session is still yours) |
| U6 (B11) | Close the editor's tab; poll `curl -s -H 'Host: play.localhost:8080' http://127.0.0.1:8080/status.json` every 30 s for up to 10 minutes | `"live"` falls from 1 to 0 about 6 minutes after the tab closed (code-server's 300 s idle timeout after its heartbeat notices, then the reaper); record the minutes |
| U7 (B13) | If your tools can drive Firefox: repeat U1-U4 in Firefox with a fresh stack | As in Chromium; otherwise record "B13: not checked locally" |

- [ ] **Step 2: Run the control that must fail**

```bash
cd /Users/saeki/work/cybertrain
docker compose -f playground/dev/compose.yml up --build -d
docker compose -f playground/dev/compose.yml exec control bin/playctl pause "browser check"
```

Open `http://play.localhost:8080/`; screenshot `task8-00-paused.png`. Expected: "The playground is paused. Browser check. Try again later, or use GitHub Codespaces." and no "Start a session" button, so U1 cannot pass while paused. Then:

```bash
docker compose -f playground/dev/compose.yml exec control bin/playctl resume
```

Expected: `resumed: new sessions are accepted`; a reload of the entry page shows the button again.

- [ ] **Step 3: Run the checklist**

Go through U1-U7 in order. For U6, keep the stack running and do not open the editor's address again. Afterwards:

```bash
cd /Users/saeki/work/cybertrain
docker compose -f playground/dev/compose.yml exec control bin/playctl status
docker compose -f playground/dev/compose.yml exec control bin/playctl kill-all
docker compose -f playground/dev/compose.yml exec control bin/playctl resume
docker compose -f playground/dev/compose.yml logs --no-log-prefix control | grep -c 'event=created'
docker compose -f playground/dev/compose.yml down
rm -rf .playwright-mcp
```

Expected: the status table (no session left after U6, `0 of 3 sessions; accepting`); `killed every session; …`; `resumed: …`; at least `1`. If U1 lands on a 403 page or the console reports a `form-action` violation, Review Focus 1's corrections are missing: compare `lib/play/app.rb` with Task 6.

- [ ] **Step 4: Fix what failed**

For each failing row, find the owning file (image: Task 1's; router: Task 2's; control plane: Tasks 4-6's), fix it within the spec's meaning, rerun that file's tests (`web-smoke.sh`, the router check, `bundle exec rake test`, `e2e.sh`) and redo the row. A failure that needs a requirement changed: stop and report.

- [ ] **Step 5: Record and commit**

If nothing changed, there is nothing to commit; report the U1-U7 results, the measured seconds and minutes, and the screenshots. If a fix changed files, stage exactly those and commit, for example:

```bash
git add playground/control/lib/play/app.rb playground/control/test/app_test.rb
git commit -m "Control: <what the browser check showed>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Deployment files

**Files:**
- Create: `playground/deploy/router.yml.example`, `playground/deploy/control.yml.example`
- Create: `playground/deploy/session-image`, `playground/deploy/hooks/pre-deploy`, `playground/deploy/hooks/post-deploy` (all git mode 100755)
- Create: `playground/deploy/host/cybertrain-play-firewall` (git mode 100755), `playground/deploy/host/cybertrain-play-firewall.service`, `playground/deploy/host/daemon.json.example`
- Create: `.kamal/secrets`
- Modify: `.gitignore` (append the operator's files)
- Test: `$SDD/scratch/deploy-check.sh` (throwaway, not committed): D1-D10, without a server

**Interfaces:**
- Consumes: the router's contract (Task 2: port 80, `/up`, `PLAY_DOMAIN`, `PLAY_PUBLIC_URL`, `PLAY_SUBNET_POOL`, run with `--dns 127.0.0.1 --sysctl net.ipv4.ip_forward=0`); the control plane's settings (Task 4) and image (Task 6); `playground/router/Dockerfile` and `playground/control/Dockerfile` as the builders' Dockerfiles.
- Produces: the files the owner copies and fills (`<VPS_IP>`, `<DOMAIN>`, `<GHCR_OWNER>`, `<ABUSE_EMAIL>`), with `minimum_version: 2.12.0`; `playground/deploy/session-image [REPOSITORY]` (prints the pinned reference and writes `playground/deploy/.session-image`; `PLAY_SESSION_IMAGE_REF` set: that reference as it is); the hooks Kamal runs through `hooks_path: playground/deploy/hooks`; the firewall script and its unit; the secrets references `KAMAL_REGISTRY_PASSWORD`, `CERTIFICATE_PEM` (from the file `PLAY_ORIGIN_CERT`), `PRIVATE_KEY_PEM` (from `PLAY_ORIGIN_KEY`). Task 11's operator's guide documents them.

Verified on 2026-10-02 with the installed Kamal 2.12.0 (no server): both configs load; the router's proxy deploy arguments carry `--host="<DOMAIN>" --host="*.<DOMAIN>" --tls` with the custom certificate paths and `--target-timeout="60s"`; the router role's options render as `--network-alias "ctplay-router" --dns "127.0.0.1" --sysctl "net.ipv4.ip_forward=0"`; the control role has no proxy, `--network-alias "ctplay-control"` and `hooks_path`; Kamal uploads the certificate and key over SSH from the secrets' text, so multi-line PEM survives. What only the VPS can show is listed at the end of this task.

Notes on the spec's text, applied below:
- Correction: `.kamal/secrets` reads `$(test -n "$PLAY_ORIGIN_CERT" && cat "$PLAY_ORIGIN_CERT")` instead of `$(cat "${PLAY_ORIGIN_CERT:-/dev/null}")`. Kamal 2.12 parses the file with dotenv, which substitutes `${PLAY_ORIGIN_CERT` and leaves `:-/dev/null}` in the command, so `cat` fails and the certificate secret is empty: the first router deploy fails (Review Focus 3). The new form gives the PEM when the variable is set and an empty value without any error output when it is not (control-plane deploys need no certificate).
- Correction: the firewall's loop reads `while read -r range || [ -n "$range" ]`: Cloudflare's `https://www.cloudflare.com/ips-v4` has no final newline (15 ranges on 2026-10-02), and the spec's `while read -r range` dropped the last one, `131.0.72.0/22` (Review Focus 4).
- Correction (spec §15, corrections 3 and 6): the router role has `options: dns: 127.0.0.1` and `sysctl: net.ipv4.ip_forward=0`. Spec §15 says to remove the sysctl if Kamal refuses it on the server.
- Both configs get `minimum_version: 2.12.0` (spec §7.1 asks for it; 2.12.0 is the newest Kamal on rubygems.org on 2026-10-02 and the version checked here). `control.yml.example` says in comments that an empty `PLAY_RUNTIME` reaches the container as unset (Kamal renders `--env PLAY_RUNTIME` without a value) and how to run Kamal commands when GHCR cannot be reached.

- [ ] **Step 1: Write the failing test**

Create `$SDD/scratch/deploy-check.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# deploy-check.sh REPO WORK -- throwaway checks of the hosted playground's
# deployment files without a server (Task 9 of the SP2 plan; not committed).
# REPO is the repository root, WORK an empty scratch directory. Needs ruby,
# jq, git, and kamal 2.12.0 for the Kamal checks (SKIP without it).
set -u
repo=$(cd "$1" && pwd)
work=$2
passed=0
failed=0
skipped=0
mkdir -p "$work" || exit 2

check() { # ID WHAT OK DETAIL
  if [ "$3" = yes ]; then passed=$((passed + 1)); echo "PASS $1 $2"
  elif [ "$3" = skip ]; then skipped=$((skipped + 1)); echo "SKIP $1 $2 ($4)"
  else failed=$((failed + 1)); echo "FAIL $1 $2 ($4)"; fi
}

d=$repo/playground/deploy
ok=no
out=$(for f in "$d/router.yml.example" "$d/control.yml.example"; do ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$f" 2>&1 || echo "BAD $f"; done)
[ -f "$d/router.yml.example" ] && [ -f "$d/control.yml.example" ] && [ -z "$out" ] && ok=yes
check D1 "both Kamal configs parse as YAML" "$ok" "${out:-missing file}"

ok=no
out=$(sh -n "$d/session-image" 2>&1 && sh -n "$d/hooks/pre-deploy" 2>&1 && sh -n "$d/hooks/post-deploy" 2>&1 && bash -n "$d/host/cybertrain-play-firewall" 2>&1 && echo parsed)
[ "$out" = parsed ] && ok=yes
modes=$(cd "$repo" && git ls-files -s playground/deploy/session-image playground/deploy/hooks playground/deploy/host/cybertrain-play-firewall | awk '{print $1}' | sort -u | tr '\n' ' ')
check D2 "the scripts parse (sh -n, bash -n)" "$ok" "${out:-missing file}"
check D3 "the scripts are committed executable (100755)" "$([ "$modes" = "100755 " ] && echo yes)" "modes: ${modes:-not committed}"

ok=no
jq empty "$d/host/daemon.json.example" 2> /dev/null && [ "$(jq -r '."live-restore"' "$d/host/daemon.json.example")" = true ] && ok=yes
check D4 "daemon.json.example is JSON with live-restore" "$ok" "jq failed"

# The firewall with a recording iptables: Cloudflare's list has no final
# newline, and its last range must still be allowed.
fw=$work/firewall
mkdir -p "$fw/bin"
printf '#!/bin/sh\necho "iptables $*" >> "$FW_LOG"\ncase "$1" in -C|-N) exit 1 ;; esac\nexit 0\n' > "$fw/bin/iptables"
printf '#!/bin/sh\necho "default via 192.0.2.1 dev eth0 proto static"\n' > "$fw/bin/ip"
chmod 755 "$fw/bin/iptables" "$fw/bin/ip"
printf '173.245.48.0/20\n103.21.244.0/22\n131.0.72.0/22' > "$fw/cf"
: > "$fw/empty"
FW_LOG=$fw/log PATH=$fw/bin:$PATH CF_LIST=$fw/cf bash "$d/host/cybertrain-play-firewall" > "$fw/out" 2>&1
rc=$?
ranges=$(grep -c 'CTPLAY-EDGE -s .* -j RETURN' "$fw/log" 2> /dev/null)
order=$(grep -n 'physdev\|-s 10.250.0.0/16 -j DROP$' "$fw/log" | grep CTPLAY | cut -d : -f 1 | tr '\n' ' ')
ok=no
[ "$rc" = 0 ] && [ "$ranges" = 3 ] && grep -q 'CTPLAY-EDGE -s 131.0.72.0/22 -j RETURN' "$fw/log" &&
  grep -q 'INPUT 1 -s 10.250.0.0/16 -j DROP' "$fw/log" && grep -q 'DOCKER-USER 1 -j CTPLAY' "$fw/log" &&
  grep -q 'CTPLAY -d 169.254.169.254/32 -j DROP' "$fw/log" && ok=yes
check D5 "the firewall allows every Cloudflare range, the last one without a newline too, and drops the pool and metadata" "$ok" \
  "exit $rc, RETURN rules: ${ranges:-0}, physdev/drop lines: $order"
FW_LOG=$fw/log2 PATH=$fw/bin:$PATH CF_LIST=$fw/empty bash "$d/host/cybertrain-play-firewall" > "$fw/out2" 2>&1
rc=$?
ok=no
[ "$rc" = 1 ] && grep -q 'stay open to everyone' "$fw/out2" && ! grep -q 'CTPLAY-EDGE' "$fw/log2" && ok=yes
check D6 "with an empty Cloudflare list the firewall says so and exits 1" "$ok" "exit $rc: $(cat "$fw/out2")"

# The hooks, in a scratch repository, with a recording ssh.
h=$work/hooks
rm -rf "$h" && mkdir -p "$h/repo/playground/deploy/hooks" "$h/bin"
printf '#!/bin/sh\necho "ssh $*"\n' > "$h/bin/ssh" && chmod 755 "$h/bin/ssh"
cp "$d/hooks/pre-deploy" "$d/hooks/post-deploy" "$h/repo/playground/deploy/hooks/"
cp "$d/session-image" "$h/repo/playground/deploy/"
sed -e 's/<VPS_IP>/192.0.2.10/' -e 's/<DOMAIN>/play.example.dev/g' -e 's/<GHCR_OWNER>/example/' \
  -e 's/<ABUSE_EMAIL>/abuse@example.dev/' "$d/control.yml.example" > "$h/repo/playground/deploy/control.yml"
printf 'playground/deploy/control.yml\nplayground/deploy/.session-image\n' > "$h/repo/.gitignore"
(cd "$h/repo" && git init -q . && git add -A && git -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false commit -qm check)
cd "$h/repo" || exit 2
r1=$(KAMAL_COMMAND=rollback sh playground/deploy/hooks/pre-deploy 2>&1; echo "rc=$?")
r2=$(PATH=$h/bin:$PATH KAMAL_COMMAND=deploy KAMAL_HOSTS=192.0.2.10 sh playground/deploy/hooks/pre-deploy 2>&1; echo "rc=$?")
PLAY_SESSION_IMAGE_REF=ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:0123 sh playground/deploy/session-image > /dev/null
r3=$(PATH=$h/bin:$PATH KAMAL_COMMAND=deploy KAMAL_HOSTS=192.0.2.10,192.0.2.11 sh playground/deploy/hooks/pre-deploy 2>&1; echo "rc=$?")
echo dirty >> playground/deploy/session-image
r4=$(PATH=$h/bin:$PATH KAMAL_COMMAND=deploy KAMAL_HOSTS=192.0.2.10 sh playground/deploy/hooks/pre-deploy 2>&1; echo "rc=$?")
git checkout -q playground/deploy/session-image
r5=$(PATH=$h/bin:$PATH KAMAL_COMMAND=deploy KAMAL_HOSTS=192.0.2.10 sh playground/deploy/hooks/post-deploy 2>&1; echo "rc=$?")
cd "$repo" || exit 2
ok=no
case "$r1" in *rc=0) case "$r2" in *".session-image is missing"*rc=1) case "$r3" in *"ssh deploy@192.0.2.10 docker pull 'ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:0123'"*"ssh deploy@192.0.2.11"*rc=0) case "$r4" in *"uncommitted changes"*rc=1) case "$r5" in *"ssh deploy@192.0.2.10 docker images ghcr.io/saeki-mototsune/cybertrain-playground-web"*rc=0) ok=yes ;; esac ;; esac ;; esac ;; esac ;; esac
check D7 "pre-deploy skips rollbacks, needs .session-image and a clean tree, pulls on every host; post-deploy prunes" "$ok" \
  "rollback: $r1 | no ref: $r2 | pull: $(printf '%s' "$r3" | tr '\n' ' ') | dirty: $r4 | post: $r5"

if [ "$(kamal version 2> /dev/null)" = 2.12.0 ]; then
  k=$work/kamal
  rm -rf "$k" && mkdir -p "$k/.kamal" "$k/playground/deploy/hooks"
  cp "$repo/.kamal/secrets" "$k/.kamal/secrets"
  cp "$d/session-image" "$k/playground/deploy/"
  for f in router control; do
    sed -e 's/<VPS_IP>/192.0.2.10/' -e 's/<DOMAIN>/play.example.dev/g' -e 's/<GHCR_OWNER>/example/' \
      -e 's/<ABUSE_EMAIL>/abuse@example.dev/' "$d/$f.yml.example" > "$k/playground/deploy/$f.yml"
  done
  printf -- '-----BEGIN CERTIFICATE-----\nMIIBcheck\nsecond line\n-----END CERTIFICATE-----\n' > "$k/origin.pem"
  printf -- '-----BEGIN PRIVATE KEY-----\nMIIEcheck\n-----END PRIVATE KEY-----\n' > "$k/origin.key"
  (cd "$k" && git init -q . && git -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m check)
  out=$(cd "$k" && KAMAL_REGISTRY_PASSWORD=check PLAY_ORIGIN_CERT=$k/origin.pem PLAY_ORIGIN_KEY=$k/origin.key \
    PLAY_SESSION_IMAGE_REF=ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:0123 ruby -e '
    require "kamal"
    r = Kamal::Configuration.create_from(config_file: Pathname.new("playground/deploy/router.yml")).role("web")
    c = Kamal::Configuration.create_from(config_file: Pathname.new("playground/deploy/control.yml"))
    cr = c.role("web")
    puts "router-args=#{r.proxy.deploy_command_args(target: "x").grep(/\A(--host=|--tls\z|--target-timeout=)/).join(" ")}"
    puts "router-options=#{r.option_args.join(" ")}"
    puts "pem-lines=#{r.proxy.certificate_pem_content.lines.size} key-lines=#{r.proxy.private_key_pem_content.lines.size}"
    puts "control-proxy=#{cr.running_proxy?} control-options=#{cr.option_args.join(" ")} hooks=#{c.hooks_path}"
    puts "control-image=#{cr.env_args(c.primary_host).join(" ")[/PLAY_SESSION_IMAGE=\S+/]}"
  ' 2>&1)
  ok=no
  case "$out" in *'--host="play.example.dev" --host="*.play.example.dev" --tls --target-timeout="60s"'*'router-options=--network-alias "ctplay-router" --dns "127.0.0.1" --sysctl "net.ipv4.ip_forward=0"'*'pem-lines=4 key-lines=3'*'control-proxy=false control-options=--network-alias "ctplay-control" hooks=playground/deploy/hooks'*'PLAY_SESSION_IMAGE="ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:0123"'*) ok=yes ;; esac
  check D8 "Kamal 2.12 reads both configs: wildcard host, TLS, 60 s, router dns and sysctl, the multi-line PEM from .kamal/secrets, no proxy for the control plane" "$ok" \
    "$(printf '%s' "$out" | tr '\n' ' ')"
  out=$(cd "$k" && env -u PLAY_ORIGIN_CERT -u PLAY_ORIGIN_KEY KAMAL_REGISTRY_PASSWORD=check ruby -e '
    require "kamal"; s = Kamal::Secrets.new; print "[#{s["CERTIFICATE_PEM"]}][#{s["PRIVATE_KEY_PEM"]}]"' 2>&1)
  check D9 "without PLAY_ORIGIN_CERT and PLAY_ORIGIN_KEY the two secrets are empty, with no error output" \
    "$([ "$out" = "[][]" ] && echo yes)" "got: $out"
else
  check D8 "Kamal reads both configs" skip "kamal 2.12.0 is not installed here (gem install kamal -v 2.12.0)"
  check D9 "the secrets without the PEM variables" skip "kamal 2.12.0 is not installed here"
fi

ignored=$(cd "$repo" && git check-ignore playground/deploy/router.yml playground/deploy/control.yml playground/deploy/.session-image | wc -l | tr -d ' ')
check D10 "git ignores the operator's router.yml, control.yml and .session-image" "$([ "$ignored" = 3 ] && echo yes)" "ignored: $ignored of 3"

echo "deploy-check: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
kamal version
rm -rf "$SDD/scratch/deploy-check-work"
bash "$SDD/scratch/deploy-check.sh" . "$SDD/scratch/deploy-check-work"; echo "exit=$?"
```

Expected: `2.12.0` (if `kamal` is missing or another version, D8 and D9 print `SKIP`; say so in your report: the owner runs them after `gem install kamal -v 2.12.0`); ten `FAIL` lines (D1-D10: the files do not exist yet), `deploy-check: 0 passed, 10 failed, 0 skipped`, `exit=1`, and no bash error.

- [ ] **Step 3: Write the Kamal files**

Create `playground/deploy/router.yml.example`:

```yaml
# Kamal config of the hosted playground's router (SP2): a stock Caddy that
# kamal-proxy hands every request for <DOMAIN> and *.<DOMAIN>. Copy to
# playground/deploy/router.yml (git-ignored) and fill in the placeholders.
#
#   kamal setup  -c playground/deploy/router.yml   # once, before the control plane
#   kamal deploy -c playground/deploy/router.yml   # rarely: live editors reconnect (playground/deploy/README.md)
service: cybertrain-play-router
image: <GHCR_OWNER>/cybertrain-play-router
minimum_version: 2.12.0

servers:
  web:
    hosts:
      - <VPS_IP>
    options:
      network-alias: ctplay-router
      # No outside resolver: the router needs none, and the ids of ended
      # sessions must not reach the host's.
      dns: 127.0.0.1
      # It spans the kamal network and every session network: it forwards
      # nothing at the IP level (spec §15, correction 6).
      sysctl: net.ipv4.ip_forward=0

proxy:
  hosts:
    - <DOMAIN>
    - "*.<DOMAIN>"
  app_port: 80
  ssl:
    certificate_pem: CERTIFICATE_PEM
    private_key_pem: PRIVATE_KEY_PEM
  forward_headers: false
  # POST /sessions waits for the new session (up to PLAY_READY_TIMEOUT, 30 s).
  response_timeout: 60
  healthcheck:
    path: /up
    interval: 1
    timeout: 3

registry:
  server: ghcr.io
  username: <GHCR_OWNER>
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  context: .
  dockerfile: playground/router/Dockerfile

env:
  clear:
    PLAY_DOMAIN: <DOMAIN>
    PLAY_PUBLIC_URL: https://<DOMAIN>
    PLAY_SUBNET_POOL: 10.250.0.0/16

logging:
  options:
    max-size: 10m
    max-file: "3"

# Non-root deploy user in the docker group on the VPS.
ssh:
  user: deploy
```

Create `playground/deploy/control.yml.example`:

```yaml
# Kamal config of the hosted playground's control plane (SP2). Copy to
# playground/deploy/control.yml (git-ignored) and fill in the placeholders.
# Rendered through ERB: PLAY_SESSION_IMAGE pins the tested session image
# (CI's cybertrain-playground-web:latest) by digest at each deploy, and the
# pre-deploy hook pulls exactly that onto the host. Every Kamal command reads
# this file, so each one asks GHCR for the digest; when GHCR cannot be
# reached, set PLAY_SESSION_IMAGE_REF to the reference in
# playground/deploy/.session-image first.
#
#   kamal setup  -c playground/deploy/control.yml   # once, after the router
#   kamal deploy -c playground/deploy/control.yml   # any time: live sessions keep running
service: cybertrain-play
image: <GHCR_OWNER>/cybertrain-play-control
minimum_version: 2.12.0

servers:
  web:
    hosts:
      - <VPS_IP>
    proxy: false
    options:
      network-alias: ctplay-control

registry:
  server: ghcr.io
  username: <GHCR_OWNER>
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  context: .
  dockerfile: playground/control/Dockerfile

env:
  clear:
    PLAY_PUBLIC_URL: https://<DOMAIN>
    PLAY_SESSION_IMAGE: <%= `playground/deploy/session-image`.strip %>
    PLAY_ALLOWED_ORIGINS: https://<DOMAIN>,https://saeki-mototsune.github.io
    PLAY_CLIENT_IP_HEADER: CF-Connecting-IP
    PLAY_ROUTER_URL: http://ctplay-router
    PLAY_ROUTER_FILTERS: label=service=cybertrain-play-router,label=role=web
    PLAY_MAX_SESSIONS: "5"
    PLAY_MAX_SESSIONS_PER_IP: "1"
    PLAY_TTL: "1800"
    PLAY_SESSION_MEMORY: 1536m
    PLAY_SUBNET_POOL: 10.250.0.0/16
    # Empty reaches the container as unset (runc); runsc after the gVisor
    # measurement (playground/deploy/README.md).
    PLAY_RUNTIME: ""
    PLAY_ABUSE_CONTACT: <ABUSE_EMAIL>

volumes:
  - /var/run/docker.sock:/var/run/docker.sock
  - /var/lib/cybertrain-play:/data

hooks_path: playground/deploy/hooks

logging:
  options:
    max-size: 10m
    max-file: "3"

ssh:
  user: deploy
```

Create `.kamal/secrets` (Kamal reads this path; it holds references only, so it is committed):

```sh
# Kamal secrets of the hosted playground (playground/deploy/*.yml): references
# to the operator's environment and files only; nothing secret is committed.
# Kamal's parser substitutes $NAME but not ${NAME:-default}, hence `test -n`.
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
CERTIFICATE_PEM=$(test -n "$PLAY_ORIGIN_CERT" && cat "$PLAY_ORIGIN_CERT")
PRIVATE_KEY_PEM=$(test -n "$PLAY_ORIGIN_KEY" && cat "$PLAY_ORIGIN_KEY")
```

Create `playground/deploy/session-image` (spec §7.4, verbatim):

```sh
#!/bin/sh
# playground/deploy/session-image [REPOSITORY] -- prints the session image a
# control-plane deploy pins: REPOSITORY:latest (default
# ghcr.io/saeki-mototsune/cybertrain-playground-web, which CI pushes only
# after its smoke and end-to-end tests pass) resolved to its digest. Also
# writes it to playground/deploy/.session-image (git-ignored) for the
# pre-deploy hook. control.yml calls it through ERB whenever Kamal reads the
# config. PLAY_SESSION_IMAGE_REF set: that reference, as it is.
set -eu
repo=${1:-ghcr.io/saeki-mototsune/cybertrain-playground-web}
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "${PLAY_SESSION_IMAGE_REF:-}" ]; then
  ref=$PLAY_SESSION_IMAGE_REF
else
  digest=$(docker buildx imagetools inspect "$repo:latest" --format '{{.Manifest.Digest}}')
  case "$digest" in sha256:*) ;; *) echo "session-image: no digest for $repo:latest" >&2; exit 1 ;; esac
  ref="$repo@$digest"
fi
printf '%s\n' "$ref" > "$here/.session-image"
printf '%s' "$ref"
```

Create `playground/deploy/hooks/pre-deploy` (spec §7.4, verbatim):

```sh
#!/bin/sh
# Run by `kamal deploy -c playground/deploy/control.yml` (hooks_path). Pulls
# the session image that PLAY_SESSION_IMAGE names onto every host, so the
# control plane's `docker run --pull never` finds it. Any failure aborts the
# deploy: the control plane never goes live naming an image the host lacks.
# Rollbacks skip it: the older image is still on the host (post-deploy keeps
# three).
set -eu
[ "${KAMAL_COMMAND:-}" = "rollback" ] && exit 0
HOSTS="${KAMAL_HOSTS:?KAMAL_HOSTS must be set (this hook is run by kamal deploy)}"

git diff-index --quiet HEAD || {
  echo "pre-deploy: uncommitted changes: commit first (the control image is built from this tree)" >&2
  exit 1
}
ref_file=playground/deploy/.session-image
[ -s "$ref_file" ] || { echo "pre-deploy: $ref_file is missing (playground/deploy/session-image writes it)" >&2; exit 1; }
REF=$(cat "$ref_file")
SSH_USER=$(sed -n 's|^ *user: *\(.*\)|\1|p' playground/deploy/control.yml | head -n 1)
SSH_USER="${SSH_USER:-root}"

for HOST in $(echo "$HOSTS" | tr ',' ' '); do
  echo "pre-deploy: pulling $REF on $HOST"
  ssh "$SSH_USER@$HOST" "docker pull '$REF' > /dev/null && docker image inspect --format '{{.Id}}' '$REF'"
done
```

Create `playground/deploy/hooks/post-deploy` (spec §7.4, verbatim):

```sh
#!/bin/sh
# Run after `kamal deploy -c playground/deploy/control.yml`: keeps the three
# newest session images on every host. docker rmi refuses an image a live
# session uses, which is fine.
set -u
[ "${KAMAL_COMMAND:-}" = "deploy" ] || exit 0
SSH_USER=$(sed -n 's|^ *user: *\(.*\)|\1|p' playground/deploy/control.yml | head -n 1)
for HOST in $(echo "${KAMAL_HOSTS:-}" | tr ',' ' '); do
  ssh "${SSH_USER:-root}@$HOST" \
    "docker images ghcr.io/saeki-mototsune/cybertrain-playground-web --format '{{.ID}}' | awk '!seen[\$0]++' | tail -n +4 | xargs -r docker rmi > /dev/null 2>&1 || true"
done
```

Then `chmod 755 playground/deploy/session-image playground/deploy/hooks/pre-deploy playground/deploy/hooks/post-deploy`.

- [ ] **Step 4: Write the host files and the ignore rules**

Create `playground/deploy/host/cybertrain-play-firewall` (spec §7.5 with the newline correction), then `chmod 755` it:

```bash
#!/usr/bin/env bash
# cybertrain-play-firewall -- host rules of the hosted playground (SP2), run
# by cybertrain-play-firewall.service after Docker starts and whenever Docker
# restarts; safe to run again (it rebuilds its own chains).
#   POOL     the session subnet pool (PLAY_SUBNET_POOL)   default 10.250.0.0/16
#   EXT_IF   the public interface                         default: the default route's
#   CF_LIST  Cloudflare's IPv4 ranges, one per line        default /etc/cybertrain-play/cloudflare-ips-v4
#            (from https://www.cloudflare.com/ips-v4, which has no final newline)
# Session rules always apply. The Cloudflare-only rule for ports 80/443 needs
# a non-empty CF_LIST; without one the script says so and exits 1, leaving
# the ports open (per-IP limits can then be spoofed; the global cap holds).
set -uo pipefail
POOL=${POOL:-10.250.0.0/16}
EXT_IF=${EXT_IF:-$(ip -4 route show default | awk '{print $5; exit}')}
CF_LIST=${CF_LIST:-/etc/cybertrain-play/cloudflare-ips-v4}
status=0

chain() { iptables -N "$1" 2>/dev/null || iptables -F "$1"; }

# 1. A session never talks to the host itself (its bridge has no host address
#    with inhibit_ipv4; this covers the case where it has one).
iptables -C INPUT -s "$POOL" -j DROP 2>/dev/null || iptables -I INPUT 1 -s "$POOL" -j DROP

# 2. Forwarded traffic, checked before Docker's own rules (DOCKER-USER).
chain CTPLAY
iptables -A CTPLAY -d 169.254.169.254/32 -j DROP          # cloud metadata, from any container
if [ -s "$CF_LIST" ]; then
  chain CTPLAY-EDGE
  # `|| [ -n "$range" ]` keeps the last line, which has no newline.
  while read -r range || [ -n "$range" ]; do
    [ -n "$range" ] && iptables -A CTPLAY-EDGE -s "$range" -j RETURN
  done < "$CF_LIST"
  iptables -A CTPLAY-EDGE -j DROP
  for port in 80 443; do
    iptables -A CTPLAY -i "$EXT_IF" -p tcp -m conntrack --ctorigdstport "$port" --ctdir ORIGINAL -j CTPLAY-EDGE
  done
else
  echo "cybertrain-play-firewall: $CF_LIST is empty: ports 80/443 stay open to everyone" >&2
  status=1
fi
iptables -A CTPLAY -m physdev --physdev-is-bridged -j RETURN  # router <-> session on one bridge
iptables -A CTPLAY -s "$POOL" -j DROP                         # anything routed out of a session network
iptables -C DOCKER-USER -j CTPLAY 2>/dev/null || iptables -I DOCKER-USER 1 -j CTPLAY
exit "$status"
```

Create `playground/deploy/host/cybertrain-play-firewall.service` (spec §7.5, verbatim):

```ini
[Unit]
Description=cybertrain playground host firewall rules
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cybertrain-play-firewall

[Install]
WantedBy=multi-user.target
```

Create `playground/deploy/host/daemon.json.example` (spec §7.5, verbatim):

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
```

Append to `.gitignore`:

```
# The hosted playground's deployment (playground/deploy): the operator's
# filled-in Kamal configs and the pinned session image (session-image).
playground/deploy/router.yml
playground/deploy/control.yml
playground/deploy/.session-image
```

- [ ] **Step 5: Run the check to verify it passes**

D3 reads the git index, so stage the files first:

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
git add playground/deploy/router.yml.example playground/deploy/control.yml.example playground/deploy/session-image playground/deploy/hooks/pre-deploy playground/deploy/hooks/post-deploy playground/deploy/host/cybertrain-play-firewall playground/deploy/host/cybertrain-play-firewall.service playground/deploy/host/daemon.json.example .kamal/secrets .gitignore
rm -rf "$SDD/scratch/deploy-check-work"
bash "$SDD/scratch/deploy-check.sh" . "$SDD/scratch/deploy-check-work"; echo "exit=$?"
```

Expected:

```
PASS D1 both Kamal configs parse as YAML
PASS D2 the scripts parse (sh -n, bash -n)
PASS D3 the scripts are committed executable (100755)
PASS D4 daemon.json.example is JSON with live-restore
PASS D5 the firewall allows every Cloudflare range, the last one without a newline too, and drops the pool and metadata
PASS D6 with an empty Cloudflare list the firewall says so and exits 1
PASS D7 pre-deploy skips rollbacks, needs .session-image and a clean tree, pulls on every host; post-deploy prunes
PASS D8 Kamal 2.12 reads both configs: wildcard host, TLS, 60 s, router dns and sysctl, the multi-line PEM from .kamal/secrets, no proxy for the control plane
PASS D9 without PLAY_ORIGIN_CERT and PLAY_ORIGIN_KEY the two secrets are empty, with no error output
PASS D10 git ignores the operator's router.yml, control.yml and .session-image
deploy-check: 10 passed, 0 failed, 0 skipped
exit=0
```

Optional, if the image can be pulled: `docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable playground/deploy/session-image playground/deploy/hooks/pre-deploy playground/deploy/hooks/post-deploy playground/deploy/host/cybertrain-play-firewall`; report its findings and fix real bugs only (the scripts are the spec's text).

What only the VPS can verify (the owner's checks, spec §7.7 and §8.6; Task 11 writes them into the operator's guide): kamal-proxy accepting `*.<DOMAIN>` with the Origin CA certificate (P4), the `dns` and `sysctl` options on the server's Docker, `hooks_path` and the two hooks over real SSH, the firewall dropping direct connections to 80/443 (P3) and surviving a reboot (P14), the provider's metadata and private network (P6), `CF-Connecting-IP` passing kamal-proxy and Caddy (P7), the deploy overlap and the create lock (V23).

- [ ] **Step 6: Commit**

```bash
git status --short
git commit -m "Deploy: Kamal configs, secrets references, image pinning and hooks, host firewall

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from `git status --short` before the commit: the ten staged files (`A`, `M .gitignore`) and nothing else.

---

### Task 10: CI

**Files:**
- Modify: `.github/workflows/playground-image.yml` (the header comment, lines 1-5; append the `web` job after the `image` job)
- Create: `.github/workflows/playground-control.yml`, `.github/workflows/playground-uptime.yml`
- Test: `$SDD/scratch/ci-check.rb` (throwaway, not committed): structure of the three workflows; optionally `actionlint`

**Interfaces:**
- Consumes: `playground/web-smoke.sh` (Task 1), `playground/dev/e2e.sh` with `PLAY_SESSION_IMAGE` (Task 7), `playground/control`'s `bundle exec rake test` (Tasks 4-6).
- Produces: the workflow "Playground image" with jobs `image` (unchanged) and `web` (builds `--target web` for `linux/amd64` as `cybertrain-playground-web:ci`, runs `web-smoke.sh` and `e2e.sh`, pushes `ghcr.io/saeki-mototsune/cybertrain-playground-web` outside pull requests by SP1's tag rules); "Playground control plane" (unit tests on `playground/control/**` and `playground/web-smoke.sh`); "Playground uptime" (every 30 minutes, only when the repository variable `PLAYGROUND_URL` is set). None of them can run before the owner pushes (Task 12).

Notes on the spec's text, applied below:
- The `web` job reads both GitHub Actions cache scopes (`playground-image`, which the `image` job fills with the shared toolchain and playground layers, and its own `playground-web`) and writes only its own, so the two jobs never write one scope at once (spec §8.7 says "the same GHA cache").
- The `web` job repeats the `image` job's tag check (`v` + `Cybertrain::VERSION`), since the jobs run side by side and each pushes on its own.
- `playground-control.yml` also runs when `playground/web-smoke.sh` changes: the drift test reads it.

- [ ] **Step 1: Write the failing test**

Create `$SDD/scratch/ci-check.rb` with exactly this content:

```ruby
# ci-check.rb -- throwaway structural checks of the three playground
# workflows (Task 10 of the SP2 plan; not committed). Run at the repository root.
require "yaml"

failures = []
check = ->(ok, what) { ok ? puts("PASS #{what}") : (failures << what; puts("FAIL #{what}")) }
load_yaml = lambda do |path|
  YAML.load_file(path)
rescue StandardError => e
  puts "FAIL #{path} does not parse: #{e.message}"
  nil
end

image = load_yaml.call(".github/workflows/playground-image.yml") || {}
jobs = image["jobs"] || {}
check.call(jobs.keys == %w[image web], "playground-image.yml has the jobs image and web (in that order)")
web = jobs["web"] || {}
runs = (web["steps"] || []).map { |s| s["run"].to_s }.join("\n")
build = (web["steps"] || []).find { |s| s["uses"].to_s.start_with?("docker/build-push-action@v6") } || {}
check.call(web.dig("env", "IMAGE") == "ghcr.io/saeki-mototsune/cybertrain-playground-web", "the web job pushes ghcr.io/saeki-mototsune/cybertrain-playground-web")
check.call(build.dig("with", "target") == "web" && build.dig("with", "platforms") == "linux/amd64" &&
           build.dig("with", "tags") == "cybertrain-playground-web:ci" && build.dig("with", "load") == true,
           "the web job builds target web for linux/amd64 as cybertrain-playground-web:ci")
check.call(runs.include?("bash playground/web-smoke.sh cybertrain-playground-web:ci"), "the web job runs the web smoke test")
e2e = (web["steps"] || []).find { |s| s["run"].to_s.include?("bash playground/dev/e2e.sh") } || {}
check.call(e2e.dig("env", "PLAY_SESSION_IMAGE") == "cybertrain-playground-web:ci", "the web job runs the end-to-end test on the image it built")
push = (web["steps"] || []).find { |s| s["name"] == "Push the tested image" } || {}
check.call(push["if"] == "github.event_name != 'pull_request'", "the web job pushes only outside pull requests")
check.call(jobs.dig("image", "steps").to_a.any? { |s| s["run"].to_s.include?("bash playground/smoke.sh cybertrain-playground:ci") },
           "the image job still runs SP1's smoke test")

control = load_yaml.call(".github/workflows/playground-control.yml") || {}
on = control[true] || control["on"] || {}
paths = on.dig("pull_request", "paths").to_a
check.call(paths.include?("playground/control/**") && paths.include?("playground/web-smoke.sh") &&
           on.dig("push", "paths").to_a == paths, "playground-control.yml runs on playground/control/** and web-smoke.sh, for pull requests and pushes")
steps = control.dig("jobs", "test", "steps").to_a
check.call(steps.any? { |s| s["uses"].to_s.start_with?("ruby/setup-ruby@v1") && s.dig("with", "ruby-version") == "4.0" } &&
           steps.any? { |s| s["run"] == "bundle exec rake test" } &&
           control.dig("jobs", "test", "defaults", "run", "working-directory") == "playground/control",
           "playground-control.yml runs bundle exec rake test on Ruby 4.0 in playground/control")

uptime = load_yaml.call(".github/workflows/playground-uptime.yml") || {}
uon = uptime[true] || uptime["on"] || {}
check.call(uon["schedule"].to_a.first.to_h["cron"] == "*/30 * * * *", "playground-uptime.yml runs every 30 minutes")
check.call(uptime.dig("jobs", "status", "if") == "vars.PLAYGROUND_URL != ''", "playground-uptime.yml stays off until PLAYGROUND_URL is set")
check.call(uptime["permissions"] == {}, "playground-uptime.yml has no token permissions")

puts(failures.empty? ? "ci-check: ok" : "ci-check: #{failures.size} failed")
exit(failures.empty? ? 0 : 1)
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
ruby "$SDD/scratch/ci-check.rb"; echo "exit=$?"
```

Expected: `PASS the image job still runs SP1's smoke test`, `FAIL` for the eleven other checks (the `web` job and the two new workflows do not exist; the missing files also print `FAIL … does not parse: No such file or directory`), `ci-check: 11 failed`, `exit=1`.

- [ ] **Step 3: Extend the image workflow**

In `.github/workflows/playground-image.yml` replace the header comment (lines 1-5):

```yaml
# Builds the playground image (playground/Dockerfile, target playground) for
# linux/amd64, smoke-tests it (playground/smoke.sh) and, except on pull
# requests, pushes the tested image to GHCR: latest from main, X.Y.Z and
# latest from a tag vX.Y.Z, the given tag on a manual run.
# See playground/README.md.
```

with:

```yaml
# Builds the playground images for linux/amd64 and, except on pull requests,
# pushes the tested images to GHCR: latest from main, X.Y.Z and latest from a
# tag vX.Y.Z, the given tag on a manual run. Job image: target playground
# (Codespaces), smoke-tested by playground/smoke.sh. Job web: target web (the
# hosted playground's sessions), smoke-tested by playground/web-smoke.sh and
# end-to-end tested with the router and the control plane (playground/dev/e2e.sh).
# See playground/README.md.
```

Then append this job at the end of the file (it continues the `jobs:` mapping, indented by two spaces like `image:`):

```yaml

  # The hosted playground's session image (target web): the same build rules,
  # then its smoke test and the end-to-end test of the whole local stack
  # (router, control plane and real sessions) before anything is pushed.
  web:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    env:
      IMAGE: ghcr.io/saeki-mototsune/cybertrain-playground-web
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: The tag is v + Cybertrain::VERSION
        if: startsWith(github.ref, 'refs/tags/v')
        run: |
          version=$(sed -n 's/^ *VERSION = "\([^"]*\)".*/\1/p' cybertrain/version.rb | head -n 1)
          test "$GITHUB_REF_NAME" = "v$version" || { echo "tag $GITHUB_REF_NAME is not v$version (cybertrain/version.rb)"; exit 1; }

      - uses: docker/setup-buildx-action@v3

      - name: Tags and labels
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE }}
          flavor: |
            latest=false
          tags: |
            type=raw,value=latest,enable=${{ github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v')) }}
            type=semver,pattern={{version}},enable=${{ startsWith(github.ref, 'refs/tags/v') }}
            type=raw,value=${{ inputs.tag || 'manual' }},enable=${{ github.event_name == 'workflow_dispatch' }}

      - name: Build (linux/amd64, target web)
        uses: docker/build-push-action@v6
        with:
          context: .
          file: playground/Dockerfile
          target: web
          platforms: linux/amd64
          load: true
          provenance: false
          tags: cybertrain-playground-web:ci
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: |
            type=gha,scope=playground-image
            type=gha,scope=playground-web
          cache-to: type=gha,mode=max,scope=playground-web,ignore-error=true

      - name: Smoke test
        run: bash playground/web-smoke.sh cybertrain-playground-web:ci

      - name: End-to-end test
        env:
          PLAY_SESSION_IMAGE: cybertrain-playground-web:ci
        run: bash playground/dev/e2e.sh

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push the tested image
        if: github.event_name != 'pull_request'
        env:
          TAGS: ${{ steps.meta.outputs.tags }}
        run: |
          test -n "$TAGS" || { echo "no tag to push"; exit 1; }
          for tag in $TAGS; do
            docker tag cybertrain-playground-web:ci "$tag"
            docker push "$tag"
          done
```

- [ ] **Step 4: Write the two new workflows**

Create `.github/workflows/playground-control.yml`:

```yaml
# The hosted playground's control plane (playground/control): its unit tests,
# including the check that playground/web-smoke.sh runs sessions with the
# control plane's hardening flags. See playground/README.md.
name: Playground control plane

on:
  pull_request:
    paths:
      - "playground/control/**"
      - "playground/web-smoke.sh"
      - ".github/workflows/playground-control.yml"
  push:
    branches: [main]
    paths:
      - "playground/control/**"
      - "playground/web-smoke.sh"
      - ".github/workflows/playground-control.yml"

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    defaults:
      run:
        working-directory: playground/control
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "4.0"
          working-directory: playground/control
          bundler-cache: true

      - name: Unit tests
        run: bundle exec rake test
```

Create `.github/workflows/playground-uptime.yml`:

```yaml
# The hosted playground's outside check: every 30 minutes, GET
# <PLAYGROUND_URL>/status.json. A failed run makes GitHub mail its usual
# failure notice. Off until the repository variable PLAYGROUND_URL is set
# (Settings -> Secrets and variables -> Actions -> Variables), for example
# https://<DOMAIN>. See playground/deploy/README.md.
name: Playground uptime

on:
  schedule:
    - cron: "*/30 * * * *"
  workflow_dispatch:

permissions: {}

jobs:
  status:
    if: vars.PLAYGROUND_URL != ''
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: status.json answers
        env:
          PLAYGROUND_URL: ${{ vars.PLAYGROUND_URL }}
        run: curl -fsS --max-time 20 "$PLAYGROUND_URL/status.json"
```

- [ ] **Step 5: Run the check to verify it passes**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
ruby "$SDD/scratch/ci-check.rb"; echo "exit=$?"
```

Expected: twelve `PASS` lines, `ci-check: ok`, `exit=0`.

Optional, if the image can be pulled: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/playground-image.yml .github/workflows/playground-control.yml .github/workflows/playground-uptime.yml`; fix what it reports about these files (shellcheck notes inside `run:` blocks that SP1's job already has may stay; say so).

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/playground-image.yml .github/workflows/playground-control.yml .github/workflows/playground-uptime.yml
git commit -m "CI: the web image job (smoke and end-to-end tests), control-plane tests, uptime check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Documentation and the prepared launch change

**Files:**
- Modify: `playground/README.md` (nine edits below)
- Create: `playground/deploy/README.md` (the operator's guide, Japanese)
- Create: `SECURITY.md`
- Create: `playground/deploy/launch.patch` (generated: the site and README entry, not applied)
- Test: `$SDD/scratch/docs-check.sh` (throwaway, not committed): K1-K7; a browser look at the patched page

**Interfaces:**
- Consumes: the facts of Tasks 1-10 (names, commands, checks W1-W13 and E1-E19, the workflows); Task 8's results; Task 3's `V-OUTCOMES` line, which changes these sentences: `V10=fallback`: in `playground/README.md` the web stage's Environment row says "`CYBERTRAIN_HOST=0.0.0.0` (the router reaches port 3000 at the session's address); the extension gallery stays code-server's default, Open VSX (an install cannot download anything: no network)", and the W1-W4 row says "user `dev`, the CLI's version and `CYBERTRAIN_HOST=0.0.0.0`"; in the operator's guide B7 expects "Open VSX のギャラリーが出るが、インストールはネットワークが無いので失敗する". `V19=fallback`: drop "schedules the end-of-session notices, " from the entrypoint row and "notices 5 minutes and 1 minute before it, and " from the `PLAYGROUND_ENDS_AT` sentence; in the guide B10 expects only the end. `V9-ports=fallback`: the User settings row loses "port 3000 opens in the editor's preview", and a row `| Port settings | `/workspace/blog/.vscode/settings.json` ([web/workspace-settings.json](web/workspace-settings.json)), hidden from git: port 3000 opens in the editor's preview |` follows the task's row. `V9-guide=fallback`: the guide's B1 says "`PLAYGROUND.md`（テキスト）". `V1=fallback`: the guide's troubleshooting row "プレビューが開かない" adds "（code-server は `--proxy-domain` で動いています。プレビューのアドレスはそこから作られます）". `V11-*=fallback`: nothing in these files.
- Produces: the documentation the owner follows (`playground/deploy/README.md`, Japanese, the spec's §9.4 structure in nine parts and a troubleshooting table); `SECURITY.md` (spec §9.5); `playground/deploy/launch.patch`, which the owner applies after the live checks (`sed 's/<DOMAIN>/…/g' playground/deploy/launch.patch | git apply`); Task 12's final checks run `docs-check.sh`.

Notes on the spec's text, applied below:
- How the launch change is prepared (spec §9.1 says "prepare the entry's diff as the plan's last task, merge it after §7.7 passes"; the form is left open): the smallest thing is one patch file in the repository with `<DOMAIN>` placeholders, generated from scripted edits, checked to apply and to satisfy the site's content rule, and documented in the operator's guide (part 9). Nothing on the site or in README.md changes on this branch, so no link points at a service that is not live.
- Correction: the README paragraph of spec §9.2 gains the two claims the site's new section makes and the README did not ("when they are all in use, try again in a few minutes or open a codespace instead" and "terminal included"): `site/README.md`'s content rule requires every claim on the site to come from README.md.
- Correction: the CSS rule is `button.btn { font-family: inherit; line-height: inherit; border: 0; background: none; cursor: pointer; }` instead of spec §9.1's `button.btn { font: inherit; border: 0; cursor: pointer; }`: `font: inherit` would also reset `.btn`'s font size, weight and stretch (the element-and-class selector outranks `.btn`), so the button would not look like the link buttons beside it.
- Correction: the patch also updates `site/README.md`'s one-line description of `playground.html` ("the way into the hosted playground and the GitHub Codespaces playground"), which spec §10's list misses.
- The operator's guide folds in the corrections of Tasks 2 and 9 (the router's `dns`/`sysctl`, the secrets syntax, the firewall's last range), the way to run Kamal commands when GHCR cannot be reached (`PLAY_SESSION_IMAGE_REF`), and one warning of its own: `docker image prune` / `docker system prune` may remove the pinned session image, which has no tag, while no session runs.

- [ ] **Step 1: Write the failing test**

Create `$SDD/scratch/docs-check.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# docs-check.sh WORK -- throwaway checks of the SP2 documentation and of the
# prepared launch change (Task 11 of the SP2 plan; not committed). Run at the
# repository root; WORK is an empty scratch directory.
set -u
work=$1
mkdir -p "$work" || exit 2
passed=0
failed=0
check() { # ID WHAT OK DETAIL
  if [ "$3" = yes ]; then passed=$((passed + 1)); echo "PASS $1 $2"; else failed=$((failed + 1)); echo "FAIL $1 $2 ($4)"; fi
}

missing=""
for heading in "## The web stage (hosted playground)" "## The hosted playground" "### On this machine" "## Smoke test" "## Limitations"; do
  grep -qxF "$heading" playground/README.md 2> /dev/null || missing="$missing [$heading]"
done
for text in "| W1-W4 |" "| W12-W13 |" "word for word: change" "playground-control.yml" "deploy/README.md"; do
  grep -qF -- "$text" playground/README.md 2> /dev/null || missing="$missing [$text]"
done
check K1 "playground/README.md has the web stage, the hosted playground, the W table, CI and the two-guides rule" \
  "$([ -z "$missing" ] && echo yes)" "missing:$missing"

broken=$(ruby -e '
  ARGV.each do |file|
    next unless File.exist?(file)
    text = File.read(file, encoding: "UTF-8")
    text.scan(/\]\(([^)\s]+)\)/).flatten.each do |link|
      next if link.start_with?("http", "#", "mailto:")
      path = File.expand_path(link.split("#").first, File.dirname(file))
      puts "#{file} -> #{link}" unless File.exist?(path)
    end
  end' playground/README.md playground/deploy/README.md SECURITY.md)
check K2 "every relative link in playground/README.md, playground/deploy/README.md and SECURITY.md resolves" \
  "$([ -z "$broken" ] && [ -f playground/deploy/README.md ] && [ -f SECURITY.md ] && echo yes)" "${broken:-missing file}"

missing=""
for part in "## この文書で使う名前" "## 第 1 部: 用意するもの" "## 第 2 部: VPS" "## 第 3 部: Cloudflare" "## 第 4 部: Kamal" \
  "## 第 5 部: 公開前の確認" "## 第 6 部: 日々の運用" "## 第 7 部: 緊急停止と不正利用" "## 第 8 部: gVisor" \
  "## 第 9 部: 公開（サイトと README の入口）" "## トラブルシューティング"; do
  grep -qxF "$part" playground/deploy/README.md 2> /dev/null || missing="$missing [$part]"
done
for text in "PLAY_SESSION_IMAGE_REF=\$(cat playground/deploy/.session-image)" "kamal proxy boot_config set -c playground/deploy/router.yml --log-max-size=1m" \
  "sudo systemctl enable --now cybertrain-play-firewall" "| P14 |" "| B14 |"; do
  grep -qF -- "$text" playground/deploy/README.md 2> /dev/null || missing="$missing [$text]"
done
check K3 "the operator's guide has its parts, the stop switch without GHCR, the proxy log size, the firewall unit, P1-P14 and B1-B14" \
  "$([ -z "$missing" ] && echo yes)" "missing:$missing"

ok=no
grep -qF "Private Vulnerability" SECURITY.md 2> /dev/null && grep -qF "7 days" SECURITY.md && ok=yes
check K4 "SECURITY.md points to Private Vulnerability Reporting and promises an answer within 7 days" "$ok" "missing text"

leaks=$(git grep -n '<DOMAIN>' -- README.md site/ 2> /dev/null)
check K5 "the site and README.md carry no entry to the hosted playground yet" "$([ -z "$leaks" ] && echo yes)" "$leaks"

ok=no
if [ -f playground/deploy/launch.patch ] &&
  sed 's/<DOMAIN>/play.example.dev/g' playground/deploy/launch.patch | git apply --check 2> "$work/apply.err"; then ok=yes; fi
files=$(grep '^diff --git' playground/deploy/launch.patch 2> /dev/null | awk '{print $3}' | sed 's|^a/||' | sort | tr '\n' ' ')
check K6 "launch.patch applies to this tree (README.md, site/README.md, site/assets/style.css, site/playground.html)" \
  "$([ "$ok" = yes ] && [ "$files" = "README.md site/README.md site/assets/style.css site/playground.html " ] && echo yes)" \
  "files: $files; $(cat "$work/apply.err" 2> /dev/null)"

rm -rf "$work/launch" && mkdir -p "$work/launch" && cp README.md "$work/launch/" && cp -R site "$work/launch/site"
sed 's/<DOMAIN>/play.example.dev/g' playground/deploy/launch.patch 2> /dev/null | patch -s -p1 -d "$work/launch" > /dev/null 2>&1
rule=$(ruby -e '
  root = ARGV[0]
  def norm(text) = text.gsub(/\s+/, " ").downcase
  readme = File.read("#{root}/README.md", encoding: "UTF-8")[/^## Try it in the browser\n.*?(?=^## )/m] or abort "no README section"
  readme = norm(readme.delete("`"))
  html = File.read("#{root}/site/playground.html", encoding: "UTF-8")
  page = html.gsub(/<[^>]+>/, " ") + " " + html.scan(/(?:href|action)="([^"]+)"/).flatten.join(" ")
  page = norm(page.gsub("&nbsp;", " ").gsub("&rsquo;", "\x27").gsub("&amp;", "&").gsub("&middot;", " "))
  facts = [/a session ends 30 minutes after it starts and is deleted with everything in it/, /download (what|any file) you want to keep/,
           /has no network access/, /a few sessions run at a time, one per network address/,
           /when they are all in use, try again in a few minutes or open a codespace instead/,
           /anyone with a session\x27s address can use it, terminal included, so do not share it/,
           %r{https://play\.example\.dev/}, /no account/, %r{codespaces\.new/saeki-mototsune/cybertrain\?quickstart=1}]
  missing = facts.reject { |f| readme[f] && page[f] }
  toc = html.scan(/toc-n">(\d+)</).flatten.join(" ")
  steps = html.scan(/step-num" aria-hidden="true">(\d+)</).flatten.join(" ")
  puts "missing=#{missing.map(&:source).join("|")} toc=#{toc} steps=#{steps} form=#{html.include?(%q(action="https://play.example.dev/sessions"))}"
' "$work/launch" 2>&1)
check K7 "the patched README and playground page state the same facts (content rule), numbered 01-05, with the form posting to /sessions" \
  "$([ "$rule" = "missing= toc=01 02 03 04 05 steps=01 02 03 04 05 form=true" ] && echo yes)" "$rule"

echo "docs-check: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
rm -rf "$SDD/scratch/docs-check-work"
bash "$SDD/scratch/docs-check.sh" "$SDD/scratch/docs-check-work"; echo "exit=$?"
```

Expected: `FAIL` for K1, K2, K3, K4, K6 and K7 (no sections, no guide, no `SECURITY.md`, no patch), `PASS K5` (nothing on the site yet), `docs-check: 1 passed, 6 failed`, `exit=1`.

- [ ] **Step 3: Edit `playground/README.md`**

Nine replacements; each quoted old text occurs once.

In the introduction, replace

```markdown
[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) opens
it in GitHub Codespaces (the README's
["Try it in the browser"](../README.md#try-it-in-the-browser)); a hosted
playground built on this image is planned.
```

with

```markdown
[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) opens
it in GitHub Codespaces (the README's
["Try it in the browser"](../README.md#try-it-in-the-browser)). The hosted
playground, where a session needs no account, runs the same image with a
browser editor added ([below](#the-hosted-playground)); its address goes
here once it is public.
```

Replace the `- Files:` item

```markdown
- Files: [Dockerfile](Dockerfile) and
  [Dockerfile.dockerignore](Dockerfile.dockerignore) (its build context),
  [playground-server](playground-server) and [profile.sh](profile.sh) (the
  scripts), [routes.rb](routes.rb) and [PLAYGROUND.md](PLAYGROUND.md) (copied
  into the blog) and [smoke.sh](smoke.sh) (the smoke test).
```

with

```markdown
- Files: [Dockerfile](Dockerfile) and
  [Dockerfile.dockerignore](Dockerfile.dockerignore) (its build context),
  [playground-server](playground-server) and [profile.sh](profile.sh) (the
  scripts), [routes.rb](routes.rb) and [PLAYGROUND.md](PLAYGROUND.md) (copied
  into the blog) and [smoke.sh](smoke.sh) (the smoke test). The hosted
  playground adds [web/](web/) and [web-smoke.sh](web-smoke.sh) (the session
  image's files and smoke test), [router/](router/), [control/](control/),
  [dev/](dev/) (the local stack and its end-to-end test) and
  [deploy/](deploy/) (Kamal, the host and the operator's guide).
```

In "## Build it", replace

```markdown
- Always name the target: a later stage will add a browser editor after
  `playground`.
```

with

```markdown
- Always name the target: the `web` stage after `playground` adds the
  hosted playground's browser editor (below).
```

Insert directly before the line `## The scripts` (after the "What is inside" section and its paragraphs):

````markdown
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
| User settings | `/opt/cybertrain-web/settings.json` ([web/settings.json](web/settings.json)), copied into the session's home: no Welcome tab, chat or trust prompt; automatic tasks on; port 3000 opens in the editor's preview |
| The server's task | `/workspace/blog/.vscode/tasks.json` ([web/tasks.json](web/tasks.json)), hidden from git through `.git/info/exclude`: runs `playground-server` in a terminal when the folder opens |
| The guide | `/workspace/blog/PLAYGROUND.md` from [web/PLAYGROUND.md](web/PLAYGROUND.md), folded into the blog's one commit |
| The seed | `/opt/cybertrain-web/seed/{workspace,cybertrain-cache}`, copied with `cp -a` (file times kept, so nothing rebuilds) |
| Environment | `CYBERTRAIN_HOST=0.0.0.0` (the router reaches port 3000 at the session's address) and `EXTENSIONS_GALLERY={}` (no extension marketplace) |
| `WORKDIR` | `/workspace`, the tmpfs mount point itself: a directory below it would be created by runc on the empty tmpfs, root-owned, and hide the seed |

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

````

Insert directly before the line `## Smoke test` (after the "Codespaces" section):

````markdown
## The hosted playground

A visitor presses "Start a session" and, a few seconds later, VS Code
(code-server) opens in the browser on the blog, with its development server
running in a terminal and the app in the editor's preview: no account, a
limited time (30 minutes by default), no network inside, one session per
network address. Three parts, all in this directory:

| Part | What | Runs as |
| --- | --- | --- |
| [router/](router/) | Stock Caddy with a static [Caddyfile](router/Caddyfile) and three error pages: sends each host name to its session's container through a Docker network alias, and nothing to an ended one | Kamal service `cybertrain-play-router`, port 80 behind kamal-proxy |
| [control/](control/) | Ruby, Sinatra and Puma: the entry page, `POST /sessions`, the limits, the reaper and the stop switch `bin/playctl`. The only process with the Docker socket; every `docker` command line it runs is in [templates.rb](control/lib/play/templates.rb) | Kamal service `cybertrain-play`, no proxy |
| The `web` image | One container per session: read-only, no capabilities, on its own `--internal` network that only the router joins | Started and removed by the control plane |

Host names: the entry page at `<DOMAIN>`, an editor at
`<session id>.<DOMAIN>` and its app at `3000-<preview id>.<DOMAIN>`, two
separate 128-bit random numbers: whoever has the app's address has the app,
whoever has the editor's address has the session, terminal included. Logs
name a session only by its handle (the first 16 hex digits of the SHA-256 of
its id), never by an id or a network address.

### On this machine

```sh
docker build -f playground/Dockerfile --target web -t cybertrain-playground-web:local .
bash playground/web-smoke.sh cybertrain-playground-web:local         # the image (W1-W13)
docker compose -f playground/dev/compose.yml up --build -d
# Chrome or Firefox: http://play.localhost:8080/ -> Start a session
docker compose -f playground/dev/compose.yml exec control bin/playctl status
docker compose -f playground/dev/compose.yml exec control bin/playctl kill-all
docker compose -f playground/dev/compose.yml down
bash playground/dev/e2e.sh                                            # the whole stack (E1-E19)
(cd playground/control && bundle install && bundle exec rake test)    # the control plane's unit tests
```

- Browsers resolve `*.localhost` to this machine and treat `play.localhost`
  as the registrable domain, so an editor and its preview are one site, as
  in production.
- A browser sends no `CF-Connecting-IP`, so locally everyone is one client:
  one session at a time. The end-to-end test sets the header.
- Sessions are not part of the compose project: `playctl kill-all` removes
  them, and so does their own end (the container stops itself 60 seconds
  after it, and the next control plane removes the network). The
  end-to-end test refuses to start while any session exists.
- If `10.250.0.0/16` clashes with a VPN, set `PLAY_SUBNET_POOL` (both
  services read it).

Deployment and operation (Kamal, Cloudflare, the host's firewall, the stop
switch, abuse): [deploy/README.md](deploy/README.md), in Japanese.

````

In "## Smoke test", directly after the table's last row (the line starting `| B1-B3 | No network:`), append:

```markdown

`bash playground/web-smoke.sh IMAGE` tests the `web` stage the same way
(bash 3.2 or newer and docker; about 6 minutes: two compiles and an idle
timeout). Its session runs with the control plane's flags on an `--internal`
network of its own, where a helper container of the same image plays the
router. The flags between `# BEGIN hardened run` and `# END hardened run`
must equal `Play::Templates.hardening` (`control/test/drift_test.rb`
checks). `RUNTIME=runsc` adds `--runtime runsc`.

| ID | Checks |
| --- | --- |
| W1-W4 | The image as built: code-server's version; user `dev`, the CLI's version, `CYBERTRAIN_HOST=0.0.0.0` and `EXTENSIONS_GALLERY={}`; the blog is clean with one commit, the hosted guide and a git-ignored folderOpen task; the seed equals the originals |
| W5-W7 | A session started as the control plane starts it: `/healthz` answers another container; `/workspace/blog` is the seeded copy, dev's, writable, with the prebuilt binary's mtime; the user settings are installed |
| W8-W10 | `playground-server` serves port 3000 to the network and its banner shows the preview URL and the end; a model edit rebuilds on the read-only root (a short body then answers 422); with no network, `cybertrain new` and a build work in `/workspace` |
| W11 | Read-only root, no capabilities, no new privileges, the four tmpfs sizes |
| W12-W13 | A session stops and disappears by itself 60 seconds after `PLAYGROUND_ENDS_AT`, and at code-server's idle timeout when no browser ever came |
```

In "## CI and publishing", directly after the paragraph's last line (`Run workflow, on \`main\`).`), append:

```markdown

The same workflow's `web` job builds the `web` target for `linux/amd64`,
runs `web-smoke.sh` and the end-to-end test (`dev/e2e.sh`: the router and
the control plane built from this checkout, with real sessions), and pushes
`ghcr.io/saeki-mototsune/cybertrain-playground-web` by the same rules.
[.github/workflows/playground-control.yml](../.github/workflows/playground-control.yml)
runs the control plane's unit tests when `playground/control/` or
`web-smoke.sh` changes, and
[.github/workflows/playground-uptime.yml](../.github/workflows/playground-uptime.yml)
fetches `<PLAYGROUND_URL>/status.json` every 30 minutes once the repository
variable `PLAYGROUND_URL` is set.
```

In "## Owner's one-time steps", after item 2 (its last line is `   Actions minutes.`), append:

```markdown
3. Once the `web` job has pushed `cybertrain-playground-web` for the first
   time, do the same for that package (Public, connected to the
   repository). The hosted playground's own setup is in
   [deploy/README.md](deploy/README.md).
```

At the end of "## Limitations" (after the item ending `cannot be cloned (above).`), append:

```markdown
- The two guides, [PLAYGROUND.md](PLAYGROUND.md) (Codespaces and Docker) and
  [web/PLAYGROUND.md](web/PLAYGROUND.md) (the hosted playground), share
  their "Try this" and "Start a fresh app" sections word for word: change
  one, change the other.
- In the hosted playground the server runs as a task in a terminal: closing
  that terminal with its trash icon leaves the server running without one
  (the dev loop treats SIGHUP as a restart), as in Codespaces.
- A hosted session has no network: `gem install`, `curl` to the internet
  and `git push` fail there, and only port 3000 can be previewed.
```

Apply the `V-OUTCOMES` sentences of the Interfaces if any value is `fallback`.

- [ ] **Step 4: Write the operator's guide**

Create `playground/deploy/README.md` (Japanese, spec §9.4; with the `V-OUTCOMES` sentences of the Interfaces if any value is `fallback`):

````markdown
# ホスト型プレイグラウンドの運用ガイド

ログインなしで cybertrain を試せるホスト型プレイグラウンド（設計は
[docs/superpowers/specs/2026-10-02-web-playground-sp2-design.md](../../docs/superpowers/specs/2026-10-02-web-playground-sp2-design.md)）を、
新しい VPS に Cloudflare と Kamal で出して運用するための手順書です。上から順にコピペで進められるように
書いています。部品の中身と手元での動かし方は [playground/README.md](../README.md) にあります。

最終的な構成は次のとおりです。

```
ブラウザ ──HTTPS / WSS──▶ Cloudflare（Free。<DOMAIN> と *.<DOMAIN> をプロキシ）
                              │ HTTPS（Full (strict)、Origin CA のワイルドカード証明書）
                              ▼
VPS（Ubuntu 24.04、Docker、Kamal 2）
  kamal-proxy :443 ──▶ ルーター（Caddy :80、サービス cybertrain-play-router）
                         ├─ <DOMAIN>              → 制御面（Sinatra :9292、サービス cybertrain-play）
                         ├─ <sid>.<DOMAIN>        → そのセッションの code-server :8080
                         └─ 3000-<pid>.<DOMAIN>   → そのセッションの開発サーバー :3000
  制御面 ──docker CLI──▶ セッション 1 つごとに --internal のネットワーク（10.250.0.0/16 の /28）とコンテナ
  ホストのファイアウォール: セッションの範囲からホストとメタデータへの通信を落とす、80/443 は Cloudflare だけ
```

- セッションは 30 分（既定）で、ファイルごと消えます。タブを閉じると約 6 分後に終わります。
- セッションの URL は持参人払いの合鍵です。制御面のログはセッションをハンドル（id の SHA-256 の先頭 16 桁）
  でしか書きません。kamal-proxy の要求ログにはホスト名が残るので、ログを人に渡さないでください。

## この文書で使う名前

自分の値に読み替えてください。コマンド中にそのまま出てきます。

| 項目 | この文書での値 |
| --- | --- |
| プレイグラウンドのドメイン（Public Suffix List に載っていないもの） | `<DOMAIN>` |
| VPS の IPv4 アドレス | `<VPS_IP>` |
| GHCR の持ち主（GitHub のユーザー名） | `<GHCR_OWNER>` |
| 不正利用と脆弱性の窓口のメールアドレス | `<ABUSE_EMAIL>` |
| VPS のデプロイ用ユーザー | `deploy` |
| Kamal | `2.12.0`（設定ファイルの `minimum_version`） |

---

## 第 1 部: 用意するもの

### 1-1. ドメイン

Public Suffix List（https://publicsuffix.org/list/ ）に載っていない、登録可能なドメインを買います（例えば新しい
`.dev`）。載っているドメインではエディタとプレビューが別サイトになり、プレビューの中のフォームが Cookie を
失います。`mototsune.dev` の下は使いません。

### 1-2. Cloudflare

Free のアカウントにゾーンとしてドメインを足し、レジストラのネームサーバーを Cloudflare が示すものに替えます。
設定は第 3 部で行います。

### 1-3. VPS

東京、Ubuntu 24.04 LTS、IPv4 あり。1 セッションの実際の山は約 1 GiB、ホストの取り分は約 2 GiB です。

| VPS | 同時セッションの目安（`PLAY_MAX_SESSIONS`） | 全員が同時に Ruby を保存したときの再ビルド |
| --- | --- | --- |
| 8 GB / 4〜6 vCPU | 5 | 46 s × 5/4 ≈ 1 分（4 vCPU） |
| 12 GB / 6 vCPU（推奨） | 8 | 46 s × 8/6 ≈ 1 分 |
| 16 GB / 8 vCPU | 12 | 46 s × 12/8 ≈ 70 s |
| 24 GB / 8 vCPU | 16 | 46 s × 16/8 ≈ 90 s |

46 s は arm64 の計測です。x86 では第 5 部の P11 の値で読み替えます。KVM は要りません（gVisor の systrap は
VM の中で動きます）。

### 1-4. GitHub

- Kamal 用に `write:packages` の PAT（Personal access token）を作ります。ルーターと制御面のイメージを push し、
  VPS が pull します（この 2 つのパッケージは private のままで構いません）。
- CI が初めて `cybertrain-playground-web` を出したら、github.com/<GHCR_OWNER> の Packages でそのパッケージを
  Public にし、リポジトリに結び付けます（Package settings → Change visibility、Connect repository）。
- リポジトリの Settings → Code security で Private vulnerability reporting を有効にします（[SECURITY.md](../../SECURITY.md)）。

### 1-5. 手元の Kamal

```sh
gem install kamal -v 2.12.0
kamal version   # 2.12.0
```

---

## 第 2 部: VPS

ここは VPS の管理用ユーザー（sudo できるもの）で行います。

### 2-1. ユーザーと SSH

```sh
sudo adduser --disabled-password --gecos "" deploy
sudo install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
sudo tee /home/deploy/.ssh/authorized_keys < ~/.ssh/authorized_keys > /dev/null   # 自分の公開鍵
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys && sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

`/etc/ssh/sshd_config` で `PermitRootLogin no` と `PasswordAuthentication no` にして `sudo systemctl reload ssh`。

VPS の私設網の範囲がセッションのプール `10.250.0.0/16` と重ならないことを確かめます:

```sh
ip route
```

`10.250.` で始まる経路があれば、`PLAY_SUBNET_POOL` を別の範囲（例 `10.251.0.0/16`）にして、ルーターと制御面の
両方の設定（4-2）とファイアウォール（2-4 の `POOL`）に同じ値を書きます。

### 2-2. ufw

```sh
sudo ufw default deny incoming
sudo ufw allow 22/tcp          # できれば自分の IP からだけ: sudo ufw allow from <自分の IP> to any port 22 proto tcp
sudo ufw enable
```

Docker が公開する 80/443（IPv4）は ufw（INPUT）ではなく FORWARD を通るので、2-4 の規則で Cloudflare に絞ります。

### 2-3. Docker と daemon.json

Docker の公式 apt リポジトリから入れます（https://docs.docker.com/engine/install/ubuntu/ 。`kamal setup` に任せても
構いません）。何も動いていないうちに設定を置いて再起動します:

```sh
sudo install -m 0644 /dev/stdin /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
sudo systemctl restart docker
docker info | grep -i cgroup          # Cgroup Version: 2
sudo usermod -aG docker deploy
```

中身は [host/daemon.json.example](host/daemon.json.example) と同じです。`live-restore` で Docker の更新や再起動の
ときもコンテナ（セッションと Kamal のアプリ）が止まりません。

メモリの重ね売りに備えて、小さなスワップ（2 GB 程度）を置くことを勧めます:

```sh
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 2-4. ファイアウォールのスクリプトとユニット

手元のリポジトリから VPS へ写します:

```sh
scp playground/deploy/host/cybertrain-play-firewall playground/deploy/host/cybertrain-play-firewall.service deploy@<VPS_IP>:/tmp/
```

VPS の上で:

```sh
sudo install -d /etc/cybertrain-play
curl -fsS https://www.cloudflare.com/ips-v4 | sudo tee /etc/cybertrain-play/cloudflare-ips-v4 > /dev/null
sudo install -m 0755 /tmp/cybertrain-play-firewall /usr/local/sbin/cybertrain-play-firewall
sudo install -m 0644 /tmp/cybertrain-play-firewall.service /etc/systemd/system/cybertrain-play-firewall.service
sudo systemctl daemon-reload
sudo systemctl enable --now cybertrain-play-firewall
sudo iptables -S DOCKER-USER
sudo iptables -S CTPLAY
sudo iptables -S CTPLAY-EDGE | grep -c RETURN     # Cloudflare の範囲の数（cloudflare-ips-v4 の行の数と同じ）
```

- Cloudflare の一覧は最後の行に改行がありません。スクリプトは最後の行も読みます（2026-10 の一覧は 15 個）。
- 一覧が空だとスクリプトは「ports 80/443 stay open to everyone」と出して 1 で終わり、80/443 は誰にでも
  開いたままになります（`CF-Connecting-IP` を偽れ、アドレスごとの上限が破れます。全体の上限は残ります）。
- Docker を再起動するとユニットも走り直し、規則を作り直します。Cloudflare の範囲が変わったら一覧を取り直して
  `sudo systemctl restart cybertrain-play-firewall`。

### 2-5. データのディレクトリ

```sh
sudo install -d -m 0750 /var/lib/cybertrain-play
```

制御面の `/data` です（`paused`、`kill-all`、`create.lock`）。

---

## 第 3 部: Cloudflare

ダッシュボードで、上から順に設定します。

| どこで | 設定 | 値と理由 |
| --- | --- | --- |
| DNS → Records | `A <DOMAIN>` と `A *` | どちらも `<VPS_IP>`、Proxied（橙の雲）。AAAA は作りません（オリジンを IPv4 だけにして、ファイアウォールを 1 系統にします。訪問者には Cloudflare が IPv6 でも答えます）。一部だけをプロキシしないこと: Origin CA 証明書はブラウザに信頼されません |
| SSL/TLS → Overview | 暗号化モード | Full (strict) |
| SSL/TLS → Origin Server | Create Certificate | ECC、ホスト名 `<DOMAIN>` と `*.<DOMAIN>`、有効期限は最長（15 年）。表示された証明書（PEM）と秘密鍵を手元の安全な場所に保存します（例 `~/.secrets/cybertrain-play/origin.pem`、`origin.key`、`chmod 600`）。期限の通知は来ないので暦に書きます |
| SSL/TLS → Edge Certificates | Always Use HTTPS | on |
| SSL/TLS → Edge Certificates | Minimum TLS Version | 1.2 |
| Caching → Cache Rules | 規則を 1 つ | 条件「Hostname ends with `<DOMAIN>`」（または All incoming requests）、動作 Bypass cache。既定では css/js などの拡張子が保存され、編集した CSS がプレビューで古いままになります |
| Network | WebSockets | on（既定）。エディタが使います |
| Speed → Optimization ほか | Rocket Loader、Email Address Obfuscation、Automatic HTTPS Rewrites、Always Online | すべて off（前の 3 つは訪問者の HTML を書き換えます） |
| Security → Bots | Bot Fight Mode | off（確認の画面にエディタの XHR と WebSocket が答えられません） |

してはいけないこと:

- **Under Attack モード**: すべての要求に確認を挟み、エディタの WebSocket と XHR を壊します。必要なときは
  第 7 部の WAF 規則（入口だけ）を使います。
- キャッシュ、HTML の変換、Workers での書き換え。

HSTS は第 5 部の確認がすべて通った後で有効にします（SSL/TLS → Edge Certificates → HSTS: max-age 6 か月、
includeSubDomains、preload なし）。一度出すと戻せないので最後にします。

任意: Google Search Console でドメインを確認しておきます（DNS の TXT）。Safe Browsing の通知と再審査の窓口になります。

---

## 第 4 部: Kamal

ここからは手元のリポジトリの最上位で行います。

### 4-1. 秘密

秘密そのものはリポジトリに入れません。[.kamal/secrets](../../.kamal/secrets) は環境変数とファイルを参照するだけです。
デプロイする端末で毎回:

```sh
export KAMAL_REGISTRY_PASSWORD=<1-4 の PAT>
export PLAY_ORIGIN_CERT=~/.secrets/cybertrain-play/origin.pem
export PLAY_ORIGIN_KEY=~/.secrets/cybertrain-play/origin.key
```

複数行の PEM がそのまま kamal-proxy に届くことを、設定を読むだけで確かめられます:

```sh
ruby -e 'require "kamal"; s = Kamal::Secrets.new; c = s["CERTIFICATE_PEM"]; puts c.lines.first, c.lines.size'
```

`-----BEGIN CERTIFICATE-----` と 2 以上の行数が出れば届きます。

### 4-2. 設定ファイル

```sh
cp playground/deploy/router.yml.example playground/deploy/router.yml
cp playground/deploy/control.yml.example playground/deploy/control.yml
```

両方の `<VPS_IP>`、`<DOMAIN>`、`<GHCR_OWNER>`、`<ABUSE_EMAIL>` を埋めます（2 つのファイルは git が無視します）。
容量（1-3）に合わせて `control.yml` の `PLAY_MAX_SESSIONS` を決めます。確かめ:

```sh
kamal config -c playground/deploy/router.yml > /dev/null && echo router ok
kamal config -c playground/deploy/control.yml > /dev/null && echo control ok
cat playground/deploy/.session-image      # ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:...
```

`control.yml` を読むたびに `playground/deploy/session-image` が GHCR に `latest` のダイジェストを問い合わせて、
`PLAY_SESSION_IMAGE` に固定します（CI がスモークと E2E を通したものだけを `latest` にします）。

### 4-3. kamal-proxy のログ

ホスト名（= セッションの合鍵）を長く残さないように、最初の起動の前にログの大きさを絞ります:

```sh
kamal proxy boot_config set -c playground/deploy/router.yml --log-max-size=1m
```

### 4-4. 最初のデプロイ

順番はルーターが先です（制御面はルーターがいないと作成を断ります）。

```sh
kamal setup -c playground/deploy/router.yml
kamal setup -c playground/deploy/control.yml
```

`control.yml` の deploy では pre-deploy フックが、固定したセッションのイメージを VPS に pull します。作業ツリーに
コミットしていない変更があると止まります（制御面のイメージはこのツリーから作られます）。

---

## 第 5 部: 公開前の確認

### 5-1. VPS とドメイン（P1〜P14）

| # | 確かめること | 期待 |
| --- | --- | --- |
| P1 | `curl -sI https://<DOMAIN>/` | 200、`server: cloudflare`、入口の CSP |
| P2 | `curl -s https://<DOMAIN>/status.json` | `"accepting":true`、`"live":0` |
| P3 | 手元から `curl -sk --max-time 5 --resolve <DOMAIN>:443:<VPS_IP> https://<DOMAIN>/status.json`（IPv6 があれば `[<v6>]` でも） | どちらも時間切れ（Cloudflare 以外は届かない） |
| P4 | VPS の上で `curl -vk --resolve <DOMAIN>:443:127.0.0.1 https://<DOMAIN>/status.json` と `curl -vk --resolve x.<DOMAIN>:443:127.0.0.1 https://x.<DOMAIN>/` | 発行者が Cloudflare Origin の証明書が、apex と一段の名前の両方で出る |
| P5 | 実ブラウザ（5-2 の B1〜B14、Chrome、Firefox、Safari） | すべて |
| P6 | セッションを 1 つ作り、VPS で `docker exec -u 1000 ctplay-s-<handle> bash -c '…'` で外（`curl https://example.com`、`getent hosts example.com`）、メタデータ（`169.254.169.254`）、ホスト（sshd の 22、`<VPS_IP>` と docker0 の 172.17.0.1）、別のセッションのアドレスを試す | すべて失敗 |
| P7 | 同じブラウザで 2 つ目を作る | 429 のページ。`playctl status` に自分の IP（`CF-Connecting-IP` が届いている） |
| P8 | `curl -sI https://3000-<pid>.<DOMAIN>/` を 2 回 | `cf-cache-status` が `DYNAMIC` か `BYPASS` |
| P9 | エディタを 20 分放置 | 使えるまま、または自分で再接続する |
| P10 | `control.yml` を `PLAY_TTL: "300"` にして deploy し、1 つ作る | 5 分で消え、ネットワークも残らない。元に戻して deploy |
| P11 | 時間: 制御面のログの `ready_ms`、ワークベンチが出るまで、Ruby の編集から再起動まで、`docker stats` のメモリ | 5-3 に記録する。再ビルドが 120 秒を超えたら、ガイド・入口・サイトの「about a minute」を実測に合わせて直す |
| P12 | `playctl pause` → 入口と作成、`resume`、テスト用のセッションで `kill-all` | 第 7 部のとおり |
| P13 | `kamal app logs -c playground/deploy/control.yml` を P5〜P12 で使った sid（URL の最初のラベル）で検索 | 出ない。`kamal proxy logs` にはホスト名が出る（想定どおり） |
| P14 | VPS を再起動 | ファイアウォールの規則が戻る、ルーターと制御面が戻る、照合で残りが消える |

### 5-2. 実ブラウザ（B1〜B14）

| # | 確かめること | 期待 |
| --- | --- | --- |
| B1 | 入口 → Start a session | エディタに描画済みの `PLAYGROUND.md`、端末にバナーと `Listening`、10 秒以内に手を触れずにプレビューが記事一覧 |
| B2 | プレビューで記事を作る | 303 → 詳細ページ |
| B3 | ビューの編集と再読み込み、モデルの編集 | ビューは即、モデルは再ビルドの後で短い本文が 422 |
| B4 | ページの再読み込み | サーバーは 1 つ、"Select an instance" の確認なし、端末とプレビューが戻る |
| B5 | 最初の表示 | Welcome、Chat のサイドバー、信頼の確認、自動タスクの確認、Coder の宣伝がどれも出ない |
| B6 | 枠 | Markdown のプレビューと Simple Browser が描画される |
| B7 | 拡張機能のビュー | ギャラリーなし、DevTools のネットワークに `open-vsx.org` が無い |
| B8 | `.html.erb` | 言語が HTML、Emmet が効く |
| B9 | Ports ビュー | 3000 が正しい URL で出る。Open in Browser で通常のタブに開く |
| B10 | 終わりの予告と時間切れ（P10 の 5 分の設定で） | 黄色の予告の行、時間切れで再接続の表示 → 再読み込みで「No session at this address」 |
| B11 | タブを閉じる | 約 6 分で `status.json` の `live` が減る |
| B12 | エクスプローラ | フォルダの Download が動く。Upload は無い |
| B13 | Firefox と Safari | B1〜B4 |
| B14 | 20 分放置 | 使えるまま、または自分で再接続（P9） |

### 5-3. 記録

| 項目 | 値 |
| --- | --- |
| 作成から 303 まで（`ready_ms`） |  |
| ワークベンチが出るまで |  |
| Ruby の編集から再起動まで |  |
| エディタ接続中のメモリ（`docker stats`） |  |
| gVisor（第 8 部） |  |

確認が終わったら、Cloudflare で HSTS を有効にします（第 3 部）。

---

## 第 6 部: 日々の運用

### 6-1. 更新

制御面とセッションのイメージ: main に入れる → CI が web のイメージを試験して `latest` を出す →

```sh
kamal deploy -c playground/deploy/control.yml
```

ERB が新しいダイジェストを固定し、フックが pull します。動いているセッションは元のイメージで最後まで動き、
新しいセッションから新しいイメージになります。

### 6-2. ロールバック

```sh
kamal app containers -c playground/deploy/control.yml      # 版を見る
kamal rollback <version> -c playground/deploy/control.yml
```

古いダイジェストに戻ります（post-deploy フックが VPS にセッションのイメージを 3 世代残します）。

### 6-3. ルーターを出す

kamal-proxy が古いルーターを抜くとき、全エディタの WebSocket が切れます（VS Code が数秒で再接続します。
プレビューは再読み込みが要ることがあります）。できれば静かなときに:

```sh
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl pause "maintenance"'
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl status'   # 0 になるまで待つ（最長 30 分）
kamal deploy -c playground/deploy/router.yml
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl resume'
```

新しいルーターは 5 秒以内に制御面が全セッションのネットワークへつなぎます。

### 6-4. code-server の版上げ

`playground/Dockerfile` の `CODE_SERVER_VERSION` と 2 つのチェックサム（GitHub のリリースの各ファイルの sha256）を
替える PR → CI → 5-2 の確認表（設定の効く範囲が版で変わりうるため）→ 制御面の deploy。月に 1 度を目安に、
code-server、Caddy、ベースイメージの新しい版を確かめます。

### 6-5. 証明書

Origin CA を作り直したら、`PLAY_ORIGIN_CERT` / `PLAY_ORIGIN_KEY` のファイルを替えて
`kamal deploy -c playground/deploy/router.yml`（kamal-proxy は証明書をデプロイのときにだけ読みます）。

### 6-6. 容量を変える

プロバイダでプランを上げる（再起動を伴います）→ `control.yml` の `PLAY_MAX_SESSIONS` を 1-3 の表に合わせる →
`kamal deploy -c playground/deploy/control.yml`。他は何も変えません。ワークショップの日（NAT の向こうから大勢が
来る）は `PLAY_MAX_SESSIONS_PER_IP` も上げます。

### 6-7. ログと監視

| 見るもの | どうやって |
| --- | --- |
| 制御面の出来事 | `kamal app logs -c playground/deploy/control.yml -f`（`event=created`、`ended`（理由 `ttl` `idle` `exited` `orphan` `killed` `failed`）、`refused`、`docker_error`、`unavailable`、`suspect`） |
| 生きているセッション | `kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl status'` |
| 公開の状態 | `https://<DOMAIN>/status.json` |
| ルーター | 普段はログなし。調べるときは `router.yml` の `env.clear` に `ROUTER_LOG_OUTPUT: stderr` を足して出し直し、`kamal app logs -c playground/deploy/router.yml`。終わったら外して出し直す |
| kamal-proxy | `kamal proxy logs -c playground/deploy/router.yml`（ホスト名を含みます。人に渡さないこと） |
| ホスト | `df -h`、`docker system df`、プロバイダのグラフ。週に 1 度 |
| 外形監視（任意） | リポジトリの変数 `PLAYGROUND_URL` に `https://<DOMAIN>` を入れると、`.github/workflows/playground-uptime.yml` が 30 分ごとに `status.json` を取り、失敗すると GitHub が通知のメールを送ります |

### 6-8. ホストの掃除

古いセッションのイメージは post-deploy フックが 3 世代に保ちます。`docker system df` で使われていない volume が
溜まっていれば `docker volume prune -f`。`docker image prune` と `docker system prune` は使いません: セッションの
イメージはダイジェストで pull したタグの無いイメージで、セッションが 1 つも動いていないときに消されると、次の
作成から「Its session image is missing」で断り続けます（戻すには `kamal deploy -c playground/deploy/control.yml`）。

---

## 第 7 部: 緊急停止と不正利用

### 7-1. 停止スイッチ（playctl）

| コマンド | すること |
| --- | --- |
| `bin/playctl status` | セッションごとにハンドル、状態、経過、残り、CPU、メモリ、（動いていれば）クライアントのアドレス。全体の数、停止中か |
| `bin/playctl pause [message]` | 新しい作成を止め、入口にメッセージを出す。動いているセッションはそのまま |
| `bin/playctl resume` | 作成を再開する |
| `bin/playctl end <handle>` | そのセッションを片付ける |
| `bin/playctl kill-all` | 停止したうえで、全セッションを片付ける（再開は `resume`） |

実行の仕方:

```sh
kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl pause "maintenance"'
```

Kamal のコマンドはどれも `control.yml` を読み、そのたびに GHCR へダイジェストを問い合わせます。GHCR に届かない
ときは、前回のデプロイの値で固定してから実行します:

```sh
PLAY_SESSION_IMAGE_REF=$(cat playground/deploy/.session-image) kamal app exec -c playground/deploy/control.yml --reuse 'bin/playctl kill-all'
```

### 7-2. 制御面が動いていないとき

VPS の上で直接:

```sh
docker ps -aq --filter label=cybertrain-play.role=session | xargs -r docker rm -f
for n in $(docker network ls -q --filter label=cybertrain-play.role=session); do
  for c in $(docker network inspect -f '{{range $id, $x := .Containers}}{{$id}} {{end}}' "$n"); do
    docker network disconnect -f "$n" "$c"; done
  docker network rm "$n"
done
sudo touch /var/lib/cybertrain-play/paused
```

再開は `sudo rm /var/lib/cybertrain-play/paused`（または `playctl resume`）。

### 7-3. 不正利用の手順書

| 兆候 | すること |
| --- | --- |
| CPU を使い続けるセッション（`event=suspect` の行、`playctl status`） | `playctl status` でハンドルとアドレスを見て `playctl end <handle>`。繰り返すなら Cloudflare の Security → WAF → Tools の IP Access Rules でそのアドレスを Block |
| 多くのアドレスからの大量の作成 | WAF のカスタム規則「`(http.host eq "<DOMAIN>")` → Managed Challenge」（入口だけ。エディタとプレビューには掛けない）を有効にし、必要ならレート制限の規則（Free で 1 つ）「`POST /sessions`、同じ IP で 10 秒に 5 回」→ Block。まだ多ければ `playctl pause` |
| プレビューのホストのフィッシング・マルウェアの通報 | 30 分以内に消えているはず。`playctl status` で生きていれば `end`。分からなければ `kill-all`。通報者に返信する。Safe Browsing に載ったら Search Console で再審査を依頼する |
| Cloudflare からの不正利用の通知 | 上と同じ。ダッシュボードで返答する |
| 脱出・侵害の疑い | `playctl kill-all` → 両サービスを `kamal app stop -c playground/deploy/control.yml`、`kamal app stop -c playground/deploy/router.yml` → プロバイダのスナップショットで保全 → VPS を作り直す → 秘密を替える（GHCR の PAT、Origin CA は失効して作り直す）→ SECURITY.md の窓口で記録する |
| ディスクが埋まる | `docker system df`、6-8 の掃除（セッションのイメージは消さない）、ログの大きさ |

生きているログ（とくに kamal-proxy のもの）は、セッションの合鍵を含むので人に渡しません。

---

## 第 8 部: gVisor

最初の週に計測して、実行環境を runc から gVisor（`runsc`）に替えるかを決めます。

1. VPS で gVisor の apt リポジトリを足して入れます（https://gvisor.dev/docs/user_guide/install/ ）:
   `sudo apt-get install -y runsc`、`sudo runsc install`、`sudo systemctl reload docker`
   （再起動ではないので、動いているコンテナは止まりません）。
2. 計測（同じイメージ、同じ制限で runc と runsc を比べます）:

   VPS の上で、手元の `playground/deploy/.session-image` に書かれた参照を `img` に入れてから:

   ```sh
   img=ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:...
   docker run --rm --cpus 1 --memory 1536m --entrypoint bash "$img" -lc 'cd /workspace/blog && touch app/controllers/articles_controller.rb && /usr/bin/time -v cybertrain spin build blog'
   docker run --rm --cpus 1 --memory 1536m --runtime runsc --entrypoint bash "$img" -lc 'cd /workspace/blog && touch app/controllers/articles_controller.rb && /usr/bin/time -v cybertrain spin build blog'
   ```

   code-server の起動から `/healthz` まで、エディタ接続中のメモリも比べます。
3. 互換性: リポジトリのチェックアウトがある VPS か手元の Linux で
   `RUNTIME=runsc bash playground/web-smoke.sh <セッションのイメージ>` がすべて通ること。
4. 目安: 再ビルドが runc の 1.5 倍以内（約 70 s）で、スモークがすべて通れば、`control.yml` を
   `PLAY_RUNTIME: runsc` にして `kamal deploy -c playground/deploy/control.yml`。新しいセッションから gVisor に
   なります。ルーターは runc のままです。
5. 結果を 5-3 の表に書きます。採らない場合も数字と理由を残します（カーネル脱出の危険を受け入れる根拠になります）。

---

## 第 9 部: 公開（サイトと README の入口）

第 5 部が通ってから、サイトの playground ページと README に入口を足します。差分は
[launch.patch](launch.patch) に用意してあり、ドメインの所だけが `<DOMAIN>` になっています:

```sh
git switch -c web-playground-launch main
sed 's/<DOMAIN>/<実際のドメイン>/g' playground/deploy/launch.patch | git apply
git diff --stat      # README.md、site/README.md、site/assets/style.css、site/playground.html
python3 -m http.server -d site 8000   # http://localhost:8000/playground.html を見る
git add README.md site/README.md site/assets/style.css site/playground.html
git commit -m "Site: the hosted playground's entry"
```

サイトのボタンはそのまま `https://<DOMAIN>/sessions` に POST します（制御面の `PLAY_ALLOWED_ORIGINS` にサイトの
オリジン `https://saeki-mototsune.github.io` が入っています）。PR にしてマージすると Pages がサイトを出します。

---

## トラブルシューティング

| 症状 | 見る所 |
| --- | --- |
| エディタが「Cannot reconnect」 | セッションが終わった（時間切れ、タブを閉じて約 6 分）か、ルーターがつながっていない。VPS で `docker network inspect ctplay-n-<handle>` の Containers にルーターがいるか。制御面の刈り取りが 5 秒ごとにつなぎ直す |
| プレビューが開かない | 端末で開発サーバーが動いているか（`playground-server`）。Ports ビューの 3000 の URL が `https://3000-<pid>.<DOMAIN>/` か |
| 作成が 503 | `kamal app logs -c playground/deploy/control.yml` の `docker_error`（段 `network`、`connect`、`run`）と `unavailable`（`image_missing` ならセッションのイメージを pull し直す: `kamal deploy -c playground/deploy/control.yml`） |
| 入口が 503（"not available"） | 制御面が落ちている。`kamal app details -c playground/deploy/control.yml`、`kamal app logs ...` |
| Cloudflare の 52x | 521: オリジンが答えない（kamal-proxy が動いているか、ファイアウォールの一覧に Cloudflare の範囲が漏れていないか）。524: オリジンの応答が Cloudflare の待ち時間を超えた（作成なら `ready_ms` と `docker_error` を見る） |
| `kamal` のコマンドが設定を読むところで失敗する | GHCR に届かない: 7-1 の `PLAY_SESSION_IMAGE_REF` |
````

- [ ] **Step 5: Write `SECURITY.md`**

Create `SECURITY.md` at the repository's root (spec §9.5):

```markdown
# Security policy

## Reporting a vulnerability

Please report vulnerabilities through GitHub's Private Vulnerability
Reporting (this repository's Security tab → "Report a vulnerability"), not
in a public issue.

In scope: the framework (`cybertrain/`), the `cybertrain` CLI, the
playground images (`playground/`) and the hosted playground
([playground/README.md](playground/README.md)). Reports we especially
welcome:

- escaping a session's container;
- reaching another visitor's session;
- reaching the host, the control plane or a cloud metadata service from
  inside a session;
- getting around the session limits;
- leaks of a session's address, which works like a password: anyone who has
  it can use the session, terminal included.

Out of scope: running code of your choice inside your own session (that is
what a session is for), load by sheer volume, and Cloudflare's own
behaviour.

We aim to answer within 7 days. Please give us time to ship a fix before
you publish the details.
```

- [ ] **Step 6: Generate the launch patch**

Create `$SDD/scratch/launch_edits.py` with exactly this content:

```python
# launch_edits.py ROOT -- the hosted playground's entry on the site and in the
# README (spec §9.1, §9.2), with <DOMAIN> for the owner to fill in. Task 11 of
# the SP2 plan turns the result into playground/deploy/launch.patch.
import sys
root = sys.argv[1]
def edit(path, old, new):
    p = f"{root}/{path}"
    s = open(p, encoding="utf-8").read()
    n = s.count(old)
    if n != 1:
        sys.exit(f"{path}: expected the old text once, found it {n} times:\n{old}")
    open(p, "w", encoding="utf-8").write(s.replace(old, new))

H = "site/playground.html"
edit(H, '''<meta name="description" content="Open the CyberTrain tutorial blog in a GitHub Codespace: VS Code in your browser, the development server running, the app in the editor's preview. Or run the same image locally with Docker.">''',
'''<meta name="description" content="Open the CyberTrain tutorial blog in VS Code in your browser, with the development server running and the app in the editor's preview: on our playground server with no account, or in a GitHub Codespace. Or run the same image locally with Docker.">''')
edit(H, '''<meta property="og:description" content="The tutorial blog, already scaffolded and migrated, in VS Code in your browser. Needs a GitHub account; runs on your own Codespaces quota.">''',
'''<meta property="og:description" content="The tutorial blog, already scaffolded and migrated, in VS Code in your browser: on our playground server with no account, or on your own Codespaces quota.">''')
edit(H, '''with its development server running in a terminal and the app in the editor's preview. Nothing to install: GitHub Codespaces runs it on a cloud machine.</p>''',
'''with its development server running in a terminal and the app in the editor's preview: on our playground server with no account, or in a GitHub Codespace.</p>''')
edit(H, '''<div><dt>You need</dt><dd>A GitHub account</dd></div>
      <div><dt>It runs on</dt><dd>Your own Codespaces quota, on the default 2-core machine</dd></div>''',
'''<div><dt>You need</dt><dd>Nothing but a browser (or a GitHub account for Codespaces)</dd></div>
      <div><dt>It runs on</dt><dd>Our playground server for 30 minutes, or your own Codespaces quota</dd></div>''')
edit(H, '''      <li><a href="#open"><span class="toc-n">01</span>Open a codespace</a></li>
      <li><a href="#what-opens"><span class="toc-n">02</span>What opens</a></li>
      <li><a href="#try"><span class="toc-n">03</span>What to try</a></li>
      <li><a href="#docker"><span class="toc-n">04</span>Run it with Docker</a></li>''',
'''      <li><a href="#hosted"><span class="toc-n">01</span>Start a session</a></li>
      <li><a href="#open"><span class="toc-n">02</span>Open a codespace</a></li>
      <li><a href="#what-opens"><span class="toc-n">03</span>What opens</a></li>
      <li><a href="#try"><span class="toc-n">04</span>What to try</a></li>
      <li><a href="#docker"><span class="toc-n">05</span>Run it with Docker</a></li>''')
edit(H, '''  <section class="step" id="open" aria-labelledby="h-open">
    <p class="stage"><span class="stage-k">You are here<span class="sr-only">:</span></span>No install <span aria-hidden="true">&middot;</span> GitHub Codespaces</p>
    <h2 id="h-open"><span class="step-num" aria-hidden="true">01</span>Open a codespace</h2>''',
'''  <section class="step" id="hosted" aria-labelledby="h-hosted">
    <p class="stage"><span class="stage-k">You are here<span class="sr-only">:</span></span>No account <span aria-hidden="true">&middot;</span> 30 minutes</p>
    <h2 id="h-hosted"><span class="step-num" aria-hidden="true">01</span>Start a session</h2>
    <p class="why"><span class="why-k">Why</span><span class="why-t">The quickest way in: VS Code opens in your browser on our playground server, with nothing to sign in to.</span></p>
    <form class="cta-row" method="post" action="https://<DOMAIN>/sessions">
      <button class="btn btn-primary" type="submit">Start a session<span class="btn-arrow" aria-hidden="true">&rarr;</span></button>
      <a class="btn btn-ghost" href="https://<DOMAIN>/terms" rel="noopener">Terms and privacy</a>
    </form>
    <p class="note">A session ends 30 minutes after it starts and is deleted with everything in it: download any file you want to keep. It has no network access. A few sessions run at a time, one per network address; when they are all in use, try again in a few minutes or open a codespace instead. Anyone with a session's address can use it, terminal included, so do not share it.</p>
  </section>

  <section class="step" id="open" aria-labelledby="h-open">
    <h2 id="h-open"><span class="step-num" aria-hidden="true">02</span>Or open a codespace</h2>''')
edit(H, '''<h2 id="h-what-opens"><span class="step-num" aria-hidden="true">02</span>What opens</h2>''',
'''<h2 id="h-what-opens"><span class="step-num" aria-hidden="true">03</span>What opens</h2>''')
edit(H, '''<h2 id="h-try"><span class="step-num" aria-hidden="true">03</span>What to try</h2>''',
'''<h2 id="h-try"><span class="step-num" aria-hidden="true">04</span>What to try</h2>''')
edit(H, '''<h2 id="h-docker"><span class="step-num" aria-hidden="true">04</span>Run it with Docker</h2>''',
'''<h2 id="h-docker"><span class="step-num" aria-hidden="true">05</span>Run it with Docker</h2>''')

edit("site/assets/style.css", '''.btn:hover .btn-arrow { transform: translateX(3px); }
''', '''.btn:hover .btn-arrow { transform: translateX(3px); }
button.btn { font-family: inherit; line-height: inherit; border: 0; background: none; cursor: pointer; }
''')

edit("site/README.md", '''the playground page (`playground.html`, the way into
the GitHub Codespaces playground)''', '''the playground page (`playground.html`, the way into
the hosted playground and the GitHub Codespaces playground)''')

edit("README.md", '''## Try it in the browser

[Open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
to try cybertrain without installing anything:''', '''## Try it in the browser

**No account needed:** [start a session on the hosted playground](https://<DOMAIN>/).
VS Code opens in your browser on the same blog, with the development server
running and the app in the editor's preview. A session ends 30 minutes after it
starts and is deleted with everything in it (download what you want to keep); it
has no network access; a few sessions run at a time, one per network address,
and when they are all in use, try again in a few minutes or open a codespace
instead. Anyone with a session's address can use it, terminal included, so do
not share it.

Or [open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
to try cybertrain without installing anything:''')
print("all edits applied")
```

Then generate the patch from a clean tree and put the four files back:

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
git diff --quiet -- README.md site/ && echo "README.md and site/ are clean"
python3 "$SDD/scratch/launch_edits.py" .
git diff --stat -- README.md site/
git diff -- README.md site/ > playground/deploy/launch.patch
git checkout -- README.md site/README.md site/assets/style.css site/playground.html
git diff --quiet -- README.md site/ && echo "restored"
grep -c '<DOMAIN>' playground/deploy/launch.patch
```

Expected: `README.md and site/ are clean`; `all edits applied`; the stat lists `README.md`, `site/README.md`, `site/assets/style.css`, `site/playground.html`; `restored`; `3`.

Look at the patched page once in the browser: copy the site, apply the patch with a test domain, serve it (through the sandbox bypass) and compare the new button with the link buttons:

```bash
rm -rf "$SDD/scratch/launch-site" && mkdir -p "$SDD/scratch/launch-site" && cp README.md "$SDD/scratch/launch-site/" && cp -R site "$SDD/scratch/launch-site/site"
sed 's/<DOMAIN>/play.example.dev/g' playground/deploy/launch.patch | patch -p1 -d "$SDD/scratch/launch-site"
python3 -m http.server -d "$SDD/scratch/launch-site/site" 8765
```

Open `http://localhost:8765/playground.html#hosted`, screenshot `task11-01-launch.png` at a desktop width and `task11-02-launch-375.png` at 375 px. Expected: section 01 "Start a session" with a "Start a session →" button that has the same size, typeface and colours as the site's other primary buttons (no grey native button), the ghost "Terms and privacy" link beside it, the note below; the contents list numbered 01-05; section 02 "Or open a codespace" without the "You are here" line; no horizontal scroll at 375 px. Stop the server and `rm -rf .playwright-mcp`.

- [ ] **Step 7: Run the check to verify it passes**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
rm -rf "$SDD/scratch/docs-check-work"
bash "$SDD/scratch/docs-check.sh" "$SDD/scratch/docs-check-work"; echo "exit=$?"
```

Expected:

```
PASS K1 playground/README.md has the web stage, the hosted playground, the W table, CI and the two-guides rule
PASS K2 every relative link in playground/README.md, playground/deploy/README.md and SECURITY.md resolves
PASS K3 the operator's guide has its parts, the stop switch without GHCR, the proxy log size, the firewall unit, P1-P14 and B1-B14
PASS K4 SECURITY.md points to Private Vulnerability Reporting and promises an answer within 7 days
PASS K5 the site and README.md carry no entry to the hosted playground yet
PASS K6 launch.patch applies to this tree (README.md, site/README.md, site/assets/style.css, site/playground.html)
PASS K7 the patched README and playground page state the same facts (content rule), numbered 01-05, with the form posting to /sessions
docs-check: 7 passed, 0 failed
exit=0
```

Then read `playground/README.md` once from top to bottom: every claim must match what Tasks 1-10 built (names, ports, commands, check IDs); fix any sentence that does not.

- [ ] **Step 8: Commit**

```bash
git add playground/README.md playground/deploy/README.md SECURITY.md playground/deploy/launch.patch
git status --short
git commit -m "Docs: the hosted playground (README, operator's guide, SECURITY.md) and the prepared site entry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from `git status --short` before the commit: these four files only; `README.md` and `site/` unchanged.

---

### Task 12: Final checks and the owner's list

**Files:**
- Test only: no file changes unless a check fails (then fix the cause in the owning task's files and commit separately, saying which check failed)

**Interfaces:**
- Consumes: the whole branch after Tasks 1-11; the throwaway checks in `$SDD/scratch/` (`router-check.sh`, `deploy-check.sh`, `ci-check.rb`, `docs-check.sh`).
- Produces: a verified branch and, in your report, the results of every suite and the owner's list below. Nothing is pushed.

- [ ] **Step 1: The control plane's unit tests and the static checks**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
(cd playground/control && BUNDLE_PATH="$SDD/bundle" bundle exec rake test 2>&1 | tail -n 1)
rm -rf "$SDD/scratch/deploy-check-work" "$SDD/scratch/docs-check-work"
bash "$SDD/scratch/deploy-check.sh" . "$SDD/scratch/deploy-check-work" | tail -n 1
ruby "$SDD/scratch/ci-check.rb" | tail -n 1
bash "$SDD/scratch/docs-check.sh" "$SDD/scratch/docs-check-work" | tail -n 1
for f in playground/web-smoke.sh playground/dev/e2e.sh playground/web/playground-web playground/playground-server playground/deploy/host/cybertrain-play-firewall; do /bin/bash -n "$f" || echo "syntax: $f"; done
```

Expected: `74 runs, 437 assertions, 0 failures, 0 errors, 0 skips`; `deploy-check: 10 passed, 0 failed, 0 skipped`; `ci-check: ok`; `docs-check: 7 passed, 0 failed`; no `syntax:` line.

- [ ] **Step 2: Both images from scratch, and their smoke tests**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
docker build --no-cache -f playground/Dockerfile --target web -t cybertrain-playground-web:local . > "$SDD/logs/task12-build-web.log" 2>&1; echo "web exit=$?"
docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local . > "$SDD/logs/task12-build-playground.log" 2>&1; echo "playground exit=$?"
bash playground/web-smoke.sh cybertrain-playground-web:local > "$SDD/logs/task12-web-smoke.log" 2>&1; tail -n 1 "$SDD/logs/task12-web-smoke.log"
bash playground/smoke.sh cybertrain-playground:local > "$SDD/logs/task12-smoke.log" 2>&1; tail -n 1 "$SDD/logs/task12-smoke.log"
docker build --no-cache -f playground/router/Dockerfile -t ctplay-router:local . > "$SDD/logs/task12-build-router.log" 2>&1; echo "router exit=$?"
bash "$SDD/scratch/router-check.sh" | tail -n 1
```

Run each long command in the background, one after the other. Expected: `web exit=0`; `playground exit=0`; `web-smoke: 13 passed, 0 failed`; `smoke: 29 passed, 0 failed`; `router exit=0`; `router-check: 10 passed, 0 failed`. Record the cold build time and both smoke times.

- [ ] **Step 3: The end-to-end test from a clean state**

```bash
cd /Users/saeki/work/cybertrain
SDD=/Users/saeki/work/cybertrain/.superpowers/sdd/2026-10-02-web-playground-sp2
docker compose -f playground/dev/compose.yml down > /dev/null 2>&1
docker ps -aq --filter label=cybertrain-play.role=session | wc -l
docker image rm ctplay-e2e-router ctplay-e2e-control > /dev/null 2>&1
bash playground/dev/e2e.sh > "$SDD/logs/task12-e2e.log" 2>&1; echo "exit=$?"
tail -n 1 "$SDD/logs/task12-e2e.log"
```

Expected: `0` (no session left over; if not, remove them as `e2e.sh`'s refusal message says); `exit=0`; `e2e: 19 passed, 0 failed` (the router and control-plane images are built afresh by compose).

- [ ] **Step 4: Nothing secret, nothing live, nothing stray is committed**

```bash
cd /Users/saeki/work/cybertrain
git status --short
ls -d .playwright-mcp 2> /dev/null
git ls-files playground/deploy | sort
git grep -nE 'BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20}|github_pat_|xox[bp]-' -- . ':!docs/superpowers/'
git grep -nE '[0-9a-f]{32}' -- playground .github SECURITY.md .kamal | grep -vE '0123456789abcdef0123456789abcdef|fedcba9876543210fedcba9876543210|ffffffffffffffffffffffffffffffff' | grep -vi 'sha256' | head
git grep -n '<DOMAIN>' -- README.md site/
git grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' -- playground/deploy .kamal | grep -vE '10\.25[01]\.0\.0/16|169\.254\.169\.254|127\.0\.0\.1|172\.17\.0\.1'
git log --oneline web-playground-sp2 --not main | head -n 20
```

Expected: `git status --short` prints nothing (untracked `.superpowers/` stays ignored); no `.playwright-mcp`; the deploy listing shows `README.md`, `control.yml.example`, `hooks/post-deploy`, `hooks/pre-deploy`, `host/cybertrain-play-firewall`, `host/cybertrain-play-firewall.service`, `host/daemon.json.example`, `launch.patch`, `router.yml.example`, `session-image` (no `router.yml`, `control.yml` or `.session-image`); no private key or token; no 32-digit hex besides the tests' fixed ids and checksums; `<DOMAIN>` nowhere in `README.md` or `site/`; no IPv4 address in the deployment files besides the pool (and the guide's example alternative `10.251.0.0/16`), the metadata address, loopback and Docker's `172.17.0.1`; the branch's commits, one per task (plus Task 3's fallback commit if any).

- [ ] **Step 5: The owner's list**

Write this list into your report, with the numbers you measured (cold build, smoke times, end-to-end time, Start → editor, tab close → session end):

1. Answer spec §11.2's Q1 (the domain, not on the Public Suffix List, and the abuse address) and Q7 (the terms' wording in `playground/control/views/terms.erb`).
2. Push `web-playground-sp2` and open the pull request when satisfied (the workflows run for the first time then: the `web` job's amd64 build, `web-smoke.sh` and `e2e.sh` on a GitHub runner, and the control plane's tests); after the merge, make the `cybertrain-playground-web` package Public and connect it to the repository (playground/README.md, owner's step 3).
3. The deployment, in the order of `playground/deploy/README.md`: the domain and Cloudflare zone (part 1), the VPS with `deploy`, ufw, Docker, `daemon.json`, swap, the firewall unit with Cloudflare's list, `/var/lib/cybertrain-play` (part 2), Cloudflare's settings and the Origin CA certificate (part 3), Kamal 2.12.0, the secrets, the two configs, `kamal proxy boot_config set --log-max-size=1m`, `kamal setup` for the router then the control plane (part 4).
4. The checks only the VPS and the domain can do (part 5): P1-P14 and B1-B14 in Chrome, Firefox and Safari; they settle V12 (the `vscode-remote://` authority on 443), V13 (the wildcard host, the PEM, `dns`/`sysctl` options, hooks over SSH), V14 (kamal-proxy's log), V15 (`CF-Connecting-IP` through kamal-proxy and Caddy), V16 (WebSocket idle and reconnect through Cloudflare), V17 (x86 timings and memory), V23 (two control planes during a deploy and the create lock); then HSTS.
5. The gVisor measurement and decision (part 8, V18).
6. The launch: apply `playground/deploy/launch.patch` with the real domain on a branch from `main`, review the page, merge (part 9); optionally set `PLAYGROUND_URL` for the uptime check and verify the domain in Search Console.
7. Calendar: the Origin CA certificate's expiry; monthly, newer code-server, Caddy and base images (with the browser checklist again after a code-server bump).

---

## Spec coverage

| Spec | Where |
| --- | --- |
| §1 goals, §2 out of scope | Global Constraints; Tasks 1-11 build §1.1's six deliverables (the site entry as a patch, Task 11) |
| §3.1-3.4 parts, hosts, request paths | Tasks 1 (image), 2 (router), 4-6 (control plane), 7 (the whole path locally) |
| §3.5 decisions (a)-(g), §3.6 threat model | Tasks 2 (A1), 1 and 3 (B2, V1), 4-6 (C1, D1 seam `Play::Sessions`/`Templates`/`DockerCLI`), 4 and 7 (E1), 9 (F), 4 (`PLAY_RUNTIME`, G) |
| §4.1-4.10 web stage, flags, files, settings, task, entrypoint, `playground-server`, guide, `docker run` contract, the end | Task 1 (W1-W13); Task 3 (V1, V9, V10, V19 in a browser); Task 7 (E18) and Task 3 (H8) for §4.10 |
| §5.1 shape, Dockerfile, host authorization | Tasks 4 and 6 |
| §5.2 routes, origin check, editor URL | Task 6 (with the `Origin: null` and `form-action` corrections); Task 4 (`editor_url`) |
| §5.3 records, §5.5 subnets, §5.6 limits and texts, §5.7 readiness, §5.8 reaper, §5.12 failures | Tasks 4 and 5; texts in Task 6 |
| §5.4 argv templates | Task 4 (`templates_test.rb` pins every argv; `drift_test.rb` ties it to `web-smoke.sh`); teardown order in Task 5 |
| §5.9 `playctl`, §5.10 settings, §5.11 logs, §5.13 pages and headers | Task 6 (`playctl_test.rb`, `app_test.rb`); Task 4 (`config_test.rb`); Task 5 and E19 (logs) |
| §6.1-6.3 Caddyfile, pages, unknown sessions, headers | Task 2 (R1-R10); Task 7 (E3, E5, E7, E13) |
| §6.4 Cloudflare | Task 11 (operator's guide, part 3); owner |
| §7.1-7.5 Kamal services and configs, secrets, image pinning, hooks, firewall | Task 9 (D1-D10) |
| §7.6-7.12 operator's steps, checks, updates, capacity, logs, abuse, gVisor | Task 11 (guide parts 1-8); Task 12 (owner's list) |
| §8.1 compose, §8.4 E2E | Task 7 (E1-E19) |
| §8.2 unit tests | Tasks 4, 5, 6 (74 tests) |
| §8.3 web smoke | Task 1 (W1-W13) |
| §8.5 browser checks | Task 3 (B5-B10, B12), Task 8 (B1-B4, B11, B13); B14 owner (P9) |
| §8.6 VPS-only | Task 9's list, Task 11's guide, Task 12's owner list |
| §8.7 CI | Task 10 |
| §9.1-9.2 site and README entry | Task 11 (`launch.patch`, not applied) |
| §9.3 `playground/README.md`, §9.4 operator's guide, §9.5 `SECURITY.md` | Task 11 |
| §10 file table | Tasks 1, 2, 4-7, 9-11 (every row); plus `playground/dev/data*` ignore rules (Task 7), `site/README.md` in the patch (Task 11), the throwaway checks outside the repository |
| §11 owner's steps and questions | Task 12, Step 5 |
| §12.1 V1-V11, V19-V22 | V2, V3, V4, V20, V21, V22 verified by probe (§15) and re-checked in Tasks 2 and 7; V5-V8 Task 1; V1, V9, V10, V11 (Chromium), V19 Task 3; V11 (Firefox) Task 8 |
| §12.1 V12-V18, V23 | owner (Task 12, Step 5; guide part 5) |
| §15 corrections 1-7 | 1: Task 1; 2, 4 (keepalive): Task 2; 3, 6: Tasks 2, 7, 9; 4 (order): Task 5; 5: Task 7 (E8); 7: Task 2 (R10) |

Check IDs: W1-W13 Task 1; R1-R10 Task 2 (this plan's); H1-H8 Task 3 (B5-B10, B12); E1-E19 Task 7; U1-U7 Task 8 (B1-B4, B11, B13, and Review Focus 5); D1-D10 Task 9; K1-K7 Task 11; P1-P14 and B14 the owner.
