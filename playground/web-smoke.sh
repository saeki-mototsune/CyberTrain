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

# No browser ever attaches to the main session: with playground-web's default
# idle timeout (300 s) code-server would end it while W9 and W10 still wait on
# a slow host, so its idle timeout is the session's 1800 s.
main_up=no
if [ "$helper_ok" != yes ]; then
  detail="no test network or helper: $(first_line "$(cat "$work/net.out" "$work/helper.start" 2> /dev/null)")"
elif session main s-smoke -e "PLAYGROUND_ENDS_AT=$(($(date +%s) + 1800))" -e "PLAYGROUND_IDLE_TIMEOUT=1800"; then
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

  # As uid 1000 the session's effective set is empty even without
  # --cap-drop ALL (execve clears it for a non-root user): the bounding set
  # is what shows the drop.
  locked=$(docker exec "$main" bash -c 'if touch /opt/cybertrain/.smoke-probe 2> /tmp/t.err; then echo root=writable; elif grep -q "Read-only file system" /tmp/t.err; then echo root=read-only; else echo "root=$(cat /tmp/t.err)"; fi; awk "/^(CapEff|CapBnd|NoNewPrivs):/ {print \$1 \$2}" /proc/1/status; df -P -k /tmp /home/dev /workspace /opt/cybertrain-cache | awk "NR > 1 {print \$6 \"=\" \$2}"' 2>&1)
  missing=""
  for want in root=read-only CapEff:0000000000000000 CapBnd:0000000000000000 NoNewPrivs:1 $tmpfs_sizes; do
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
