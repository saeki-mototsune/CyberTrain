#!/usr/bin/env bash
# playground/smoke.sh IMAGE -- the smoke test of a playground image
# (playground/Dockerfile, target playground). CI runs it on every build
# before anything is pushed (.github/workflows/playground-image.yml); after a
# local build:
#
#   bash playground/smoke.sh cybertrain-playground:local
#
# One line per check, "PASS <ID> <what>" or "FAIL <ID> <what> (<detail>)",
# then "smoke: N passed, M failed". After a failure it prints the last 40
# lines of every container or command involved and exits 1; it exits 0 when
# every check passes and 2 without an IMAGE. Groups: G the image as built,
# A the default command serving the blog to the host and the edit loop,
# D playground-server started again, C the Codespaces settings, F the boot
# check of CYBERTRAIN_SESSION_SAME_SITE, E a cp -a copy of the blog, B no
# network. playground/README.md lists every check.
#
# The host needs bash 3.2 or newer (no associative arrays, no date +%N:
# macOS's /bin/bash works), docker and curl. The expected version is read
# from ../cybertrain/version.rb. Every container it starts is removed when it
# exits.
set -u

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: bash playground/smoke.sh IMAGE" >&2
  exit 2
fi
image=$1
here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n 's/^ *VERSION = "\([^"]*\)".*/\1/p' "$here/../cybertrain/version.rb" | head -n 1)
if [ -z "$version" ]; then
  echo "smoke: no VERSION in $here/../cybertrain/version.rb" >&2
  exit 2
fi

prefix="playground-smoke-$$"
work=$(mktemp -d "${TMPDIR:-/tmp}/playground-smoke.XXXXXX") || exit 2
containers=""
passed=0
failed=0
show=""
out=""
rc=0
detail=""

cleanup() {
  # One container name per word: the unquoted expansion is intended.
  if [ -n "$containers" ]; then
    docker rm -f $containers > /dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

what_G1="the user is dev, uid 1000"
what_G2="cybertrain version prints cybertrain $version"
what_G3="cybertrain doctor exits 0"
what_G4="CYBERTRAIN_HOME and XDG_CACHE_HOME point under /opt and CYBERTRAIN_HOST is unset"
what_G5="the blog's spin.toml depends on the tag v$version"
what_G6="the blog is a clean git repository with one commit that tracks PLAYGROUND.md"
what_G7="no tmp/secret_key is baked in and build/bin/blog is executable"
what_A1="GET /articles through the published port answers 200 (default command, CYBERTRAIN_HOST=0.0.0.0)"
what_A2="the log shows the boot banner of $version listening on http://0.0.0.0:3000"
what_A3="starting compiled nothing (build/bin/blog keeps the image's mtime)"
what_A4="GET / answers 200 with <h1>Articles</h1>"
what_A5="GET /articles/new has a CSRF token and a SameSite=Lax session cookie without Secure or Partitioned"
what_A6="POST /articles with the token and the cookie answers 303 to the new article, whose page shows it"
what_A7="POST /articles without token or cookie answers 403"
what_A8="a view edit shows on the next request"
what_A9="a model edit rebuilds and restarts the server: a short body then answers 422"
what_A10="the running container generated tmp/secret_key"
what_D1="a second playground-server exits 0 saying the server is already running"
what_D2="exactly one app server process runs"
what_C1="with CODESPACES=true the session cookie is SameSite=None; Secure; Partitioned"
what_C2="with CODESPACES=true the banner shows https://smoke-3000.app.github.dev/"
what_F1="CYBERTRAIN_SESSION_SAME_SITE=lax stops the server at boot and names the valid values"
what_E1="a cp -a copy of the blog started by playground-server compiles nothing"
what_B1="with no network, git ls-remote of the repository URL lists refs/tags/v$version (the mirror)"
what_B2="with no network, cybertrain new works in /tmp and locks the blog's commit"
what_B3="with no network, the new app builds"

pass() {
  passed=$((passed + 1))
  echo "PASS $1 $2"
}

# fail ID WHAT DETAIL [WHERE]: WHERE is a container name, or out:ID for the
# saved output of `run_once ... ID`; its last lines are printed at the end.
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
# $out (its stdout and stderr, also kept in $work/ID.out) and $rc (its exit
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

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null)" = "true" ]
}

# The host port docker published for the container's port 3000.
host_port() {
  docker port "$1" 3000/tcp 2> /dev/null | head -n 1 | sed 's/.*://'
}

# up_inside CONTAINER SECONDS: waits until GET /articles answers 200 inside
# CONTAINER, whose server listens on 127.0.0.1. Sets $detail when it fails.
up_inside() {
  local began=$SECONDS
  while [ $((SECONDS - began)) -lt "$2" ]; do
    if [ "$(docker exec "$1" curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:3000/articles 2> /dev/null)" = "200" ]; then
      return 0
    fi
    if ! running "$1"; then
      detail="the container exited"
      return 1
    fi
    sleep 0.5
  done
  detail="no 200 from /articles within $2 s"
  return 1
}

# The authenticity_token of the form saved in file $1.
form_token() {
  sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p' "$1" 2> /dev/null | head -n 1
}

# header FILE NAME: the value of the first NAME header in curl's -D dump FILE.
header() {
  grep -i "^$2:" "$1" 2> /dev/null | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//'
}

echo "smoke: $image, expecting cybertrain $version"

# ---- G: the image as built -------------------------------------------------

run_once 30 G1 "$image" sh -c 'echo "$(id -un) $(id -u)"'
if [ "$rc" = 0 ] && [ "$out" = "dev 1000" ]; then
  pass G1 "$what_G1"
else
  fail G1 "$what_G1" "got: $(first_line "$out")" out:G1
fi

run_once 30 G2 "$image" cybertrain version
if [ "$rc" = 0 ] && [ "$out" = "cybertrain $version" ]; then
  pass G2 "$what_G2"
else
  fail G2 "$what_G2" "exit $rc: $(first_line "$out")" out:G2
fi

run_once 60 G3 "$image" cybertrain doctor
if [ "$rc" = 0 ]; then
  pass G3 "$what_G3"
else
  fail G3 "$what_G3" "exit $rc" out:G3
fi

run_once 30 G4 "$image" sh -c 'echo "${CYBERTRAIN_HOME-}|${XDG_CACHE_HOME-}|${CYBERTRAIN_HOST-unset}"'
if [ "$rc" = 0 ] && [ "$out" = "/opt/cybertrain|/opt/cybertrain-cache|unset" ]; then
  pass G4 "$what_G4"
else
  fail G4 "$what_G4" "got: $(first_line "$out")" out:G4
fi

dependency="cybertrain = { git = \"https://github.com/saeki-mototsune/cybertrain\", ref = \"v$version\" }"
run_once 30 G5 "$image" grep -F "$dependency" /workspace/blog/spin.toml
if [ "$rc" = 0 ]; then
  pass G5 "$what_G5"
else
  fail G5 "$what_G5" "no line: $dependency" out:G5
fi

run_once 30 G6 "$image" sh -c 'cd /workspace/blog && echo "status=[$(git status --porcelain)] commits=$(git rev-list --count HEAD) guide=$(git ls-files PLAYGROUND.md)"'
if [ "$rc" = 0 ] && [ "$out" = "status=[] commits=1 guide=PLAYGROUND.md" ]; then
  pass G6 "$what_G6"
else
  fail G6 "$what_G6" "got: $(first_line "$out")" out:G6
fi

run_once 30 G7 "$image" sh -c 'if [ -e /workspace/blog/tmp/secret_key ]; then echo "tmp/secret_key exists"; exit 1; fi; if [ ! -x /workspace/blog/build/bin/blog ]; then echo "build/bin/blog is missing or not executable"; exit 1; fi'
if [ "$rc" = 0 ]; then
  pass G7 "$what_G7"
else
  fail G7 "$what_G7" "$(first_line "$out")" out:G7
fi

# The prebuilt binary's mtime, which A3 and E1 compare against.
run_once 30 mtime "$image" stat -c %Y /workspace/blog/build/bin/blog
image_mtime=""
if [ "$rc" = 0 ]; then
  image_mtime=$out
fi

# ---- A: the default command, reached from the host, and the edit loop ------

main="$prefix-main"
main_up=no
title=""
base=""
if start main -p 127.0.0.1::3000 -e CYBERTRAIN_HOST=0.0.0.0 "$image"; then
  launched=$SECONDS
  port=$(host_port "$main")
  base="http://127.0.0.1:$port"
  detail="no 200 within 30 s"
  while [ $((SECONDS - launched)) -lt 30 ]; do
    if [ -n "$port" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$base/articles")" = "200" ]; then
      main_up=yes
      break
    fi
    if ! running "$main"; then
      detail="the container exited"
      break
    fi
    sleep 0.5
  done
else
  detail="docker run failed: $(first_line "$(cat "$work/main.start")")"
fi

if [ "$main_up" = yes ]; then
  pass A1 "$what_A1"

  logs=$(docker logs "$main" 2>&1)
  case "$logs" in
    *"=> Booting cybertrain $version"*"* Listening on http://0.0.0.0:3000"*) pass A2 "$what_A2" ;;
    *) fail A2 "$what_A2" "the banner lines are not in docker logs" "$main" ;;
  esac

  running_mtime=$(docker exec "$main" stat -c %Y /workspace/blog/build/bin/blog 2> /dev/null)
  if [ -n "$image_mtime" ] && [ "$running_mtime" = "$image_mtime" ]; then
    pass A3 "$what_A3"
  else
    fail A3 "$what_A3" "image: ${image_mtime:-unknown}, running: ${running_mtime:-unknown}" "$main"
  fi

  code=$(curl -s -o "$work/a4.html" -w '%{http_code}' --max-time 5 "$base/")
  if [ "$code" = 200 ] && grep -qF '<h1>Articles</h1>' "$work/a4.html"; then
    pass A4 "$what_A4"
  else
    fail A4 "$what_A4" "status $code" "$main"
  fi

  jar="$work/session.jar"
  code=$(curl -s -c "$jar" -D "$work/a5.head" -o "$work/a5.html" -w '%{http_code}' --max-time 5 "$base/articles/new")
  token=$(form_token "$work/a5.html")
  cookie=$(header "$work/a5.head" set-cookie)
  case "$cookie" in
    *"; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600") cookie_ok=yes ;;
    *) cookie_ok=no ;;
  esac
  if [ "$code" = 200 ] && [ "${#token}" -ge 32 ] && [ "$cookie_ok" = yes ]; then
    pass A5 "$what_A5"
  else
    fail A5 "$what_A5" "status $code, token of ${#token} characters, Set-Cookie: $cookie" "$main"
  fi

  title="Smoke $(date +%s)"
  code=$(curl -s -b "$jar" -c "$jar" -D "$work/a6.head" -o /dev/null -w '%{http_code}' --max-time 5 \
    --data-urlencode "authenticity_token=$token" \
    --data-urlencode "article[title]=$title" \
    --data-urlencode "article[body]=A body that is long enough." \
    "$base/articles")
  location=$(header "$work/a6.head" location)
  shown=000
  case "$location" in
    /articles/[0-9]*) shown=$(curl -s -b "$jar" -o "$work/a6.html" -w '%{http_code}' --max-time 5 "$base$location") ;;
  esac
  if [ "$code" = 303 ] && [ "$shown" = 200 ] && grep -qF "$title" "$work/a6.html"; then
    pass A6 "$what_A6"
  else
    fail A6 "$what_A6" "status $code, Location: $location, then $shown" "$main"
    title=""
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --data-urlencode "article[title]=No token" "$base/articles")
  if [ "$code" = 403 ]; then
    pass A7 "$what_A7"
  else
    fail A7 "$what_A7" "status $code" "$main"
  fi

  docker exec "$main" sh -c 'echo "<p id=\"smoke-view-edit\">view edit</p>" >> /workspace/blog/app/views/articles/index.html.erb'
  seen=no
  for attempt in 1 2 3 4 5 6; do
    if curl -s --max-time 2 "$base/articles" | grep -qF 'smoke-view-edit'; then
      seen=yes
      break
    fi
    sleep 0.5
  done
  if [ "$seen" = yes ]; then
    pass A8 "$what_A8"
  else
    fail A8 "$what_A8" "the edit did not show within 3 s" "$main"
  fi

  docker exec "$main" sed -i 's/^class Article$/&\n  validates :body, presence: true, length: { minimum: 10 }/' /workspace/blog/app/models/article.rb
  edited=$(docker exec "$main" grep -c 'validates :body' /workspace/blog/app/models/article.rb 2> /dev/null)
  short=000
  deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    rm -f "$work/a9.jar" "$work/a9.html"
    probe=$(curl -s -c "$work/a9.jar" -o "$work/a9.html" -w '%{http_code}' --max-time 5 "$base/articles/new")
    probe_token=$(form_token "$work/a9.html")
    if [ "$probe" = 200 ] && [ -n "$probe_token" ]; then
      short=$(curl -s -b "$work/a9.jar" -o /dev/null -w '%{http_code}' --max-time 5 \
        --data-urlencode "authenticity_token=$probe_token" \
        --data-urlencode "article[title]=Short body $(date +%s)" \
        --data-urlencode "article[body]=short" \
        "$base/articles")
      if [ "$short" = 422 ]; then
        break
      fi
    fi
    sleep 3
  done
  logs=$(docker logs "$main" 2>&1)
  case "$logs" in
    *"Build succeeded"*) built=yes ;;
    *) built=no ;;
  esac
  listed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base/articles")
  if [ "$short" = 422 ] && [ "$built" = yes ] && [ "$listed" = 200 ]; then
    pass A9 "$what_A9"
  else
    fail A9 "$what_A9" "validates :body lines: ${edited:-0}, short body: $short, Build succeeded logged: $built, GET /articles: $listed" "$main"
  fi

  if docker exec "$main" test -s /workspace/blog/tmp/secret_key; then
    pass A10 "$what_A10"
  else
    fail A10 "$what_A10" "no tmp/secret_key in the container" "$main"
  fi

  # ---- D: playground-server started again ----------------------------------

  again=$(docker exec "$main" timeout 10 playground-server 2>&1)
  again_rc=$?
  case "$again" in
    *"already running"*) said=yes ;;
    *) said=no ;;
  esac
  if [ "$again_rc" = 0 ] && [ "$said" = yes ]; then
    pass D1 "$what_D1"
  else
    fail D1 "$what_D1" "exit $again_rc: $(first_line "$again")" "$main"
  fi

  servers=$(docker exec "$main" pgrep -c -f '^/workspace/blog/build/bin/blog( |$)' 2> /dev/null)
  if [ "$servers" = 1 ]; then
    pass D2 "$what_D2"
  else
    fail D2 "$what_D2" "pgrep counted ${servers:-nothing}" "$main"
  fi
else
  fail A1 "$what_A1" "$detail" "$main"
  for id in A2 A3 A4 A5 A6 A7 A8 A9 A10 D1 D2; do
    name="what_$id"
    fail "$id" "${!name}" "skipped: the dev server did not come up"
  done
fi

# ---- C: the Codespaces settings --------------------------------------------

codespace="$prefix-codespace"
if start codespace -e CODESPACES=true -e CODESPACE_NAME=smoke -e GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=app.github.dev "$image"; then
  if up_inside "$codespace" 30; then
    cookie=$(docker exec "$codespace" curl -s -D - -o /dev/null --max-time 5 http://127.0.0.1:3000/articles/new 2> /dev/null |
      grep -i '^set-cookie:' | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//')
    case "$cookie" in
      *"; Path=/; HttpOnly; SameSite=None; Max-Age=1209600; Secure; Partitioned") pass C1 "$what_C1" ;;
      *) fail C1 "$what_C1" "Set-Cookie: $cookie" "$codespace" ;;
    esac
  else
    fail C1 "$what_C1" "$detail" "$codespace"
  fi
else
  fail C1 "$what_C1" "docker run failed: $(first_line "$(cat "$work/codespace.start")")"
fi
case "$(docker logs "$codespace" 2>&1)" in
  *"https://smoke-3000.app.github.dev/"*) pass C2 "$what_C2" ;;
  *) fail C2 "$what_C2" "the URL is not in the banner" "$codespace" ;;
esac

# ---- F: the boot check -----------------------------------------------------

run_once 60 F1 -e CYBERTRAIN_SESSION_SAME_SITE=lax "$image"
case "$out" in
  *'must be Lax, Strict or None (got "lax")'*) named=yes ;;
  *) named=no ;;
esac
# The container must end by itself: 124 means run_once removed it at 60 s.
if [ "$rc" != 0 ] && [ "$rc" != 124 ] && [ "$named" = yes ]; then
  pass F1 "$what_F1"
else
  fail F1 "$what_F1" "exit $rc" out:F1
fi

# ---- E: a cp -a copy of the blog -------------------------------------------
# The premise of the Codespaces fallback that copies the blog to /workspaces.

copy="$prefix-copy"
if start copy "$image" bash -c 'cp -a /workspace/blog /tmp/blog-copy && exec playground-server /tmp/blog-copy'; then
  if up_inside "$copy" 30; then
    copy_mtime=$(docker exec "$copy" stat -c %Y /tmp/blog-copy/build/bin/blog 2> /dev/null)
    if [ -n "$image_mtime" ] && [ "$copy_mtime" = "$image_mtime" ]; then
      pass E1 "$what_E1"
    else
      fail E1 "$what_E1" "image: ${image_mtime:-unknown}, copy: ${copy_mtime:-unknown}" "$copy"
    fi
  else
    fail E1 "$what_E1" "$detail" "$copy"
  fi
else
  fail E1 "$what_E1" "docker run failed: $(first_line "$(cat "$work/copy.start")")"
fi

# ---- B: no network ---------------------------------------------------------

run_once 30 B1 --network none "$image" git ls-remote https://github.com/saeki-mototsune/cybertrain
case "$out" in
  *"refs/tags/v$version"*) tagged=yes ;;
  *) tagged=no ;;
esac
if [ "$rc" = 0 ] && [ "$tagged" = yes ]; then
  pass B1 "$what_B1"
else
  fail B1 "$what_B1" "exit $rc: $(first_line "$out")" out:B1
fi

# B2 and B3 share one container: B3 builds the app B2 creates. The script
# runs inside it and prints one "B2 ..." and one "B3 ..." line.
offline='
began=$SECONDS
cd /tmp || exit 1
if ! cybertrain new offline > /tmp/smoke-new.log 2>&1; then
  echo "B2 FAIL cybertrain new offline failed: $(tail -n 2 /tmp/smoke-new.log | tr "\n" " ")"
  echo "B3 FAIL skipped: there is no app"
  exit 0
fi
took=$((SECONDS - began))
cd offline || exit 1
if [ "$took" -gt 180 ]; then
  echo "B2 FAIL cybertrain new took $took s (limit 180 s)"
elif ! grep -qF "ref = \"v$SMOKE_VERSION\"" spin.toml; then
  echo "B2 FAIL spin.toml has no ref = \"v$SMOKE_VERSION\""
elif ! cmp -s spin.lock /workspace/blog/spin.lock; then
  echo "B2 FAIL spin.lock differs from /workspace/blog/spin.lock"
else
  echo "B2 PASS"
fi
if cybertrain spin build offline > /tmp/smoke-build.log 2>&1 && [ -x build/bin/offline ]; then
  echo "B3 PASS"
else
  echo "B3 FAIL cybertrain spin build offline failed: $(tail -n 2 /tmp/smoke-build.log | tr "\n" " ")"
fi
'
run_once 420 B23 --network none -e "SMOKE_VERSION=$version" "$image" bash -c "$offline"
for id in B2 B3; do
  name="what_$id"
  line=$(printf '%s\n' "$out" | grep "^$id " | head -n 1)
  if [ "$line" = "$id PASS" ]; then
    pass "$id" "${!name}"
  else
    reason=${line#"$id FAIL "}
    if [ -z "$reason" ]; then
      reason="exit $rc"
    fi
    fail "$id" "${!name}" "$reason" out:B23
  fi
done

# ---- summary ---------------------------------------------------------------

echo "smoke: $passed passed, $failed failed"
if [ "$failed" -eq 0 ]; then
  exit 0
fi
for where in $show; do
  case "$where" in
    out:*)
      echo "--- output of ${where#out:} (last 40 lines)"
      tail -n 40 "$work/${where#out:}.out"
      ;;
    *)
      echo "--- docker logs $where (last 40 lines)"
      docker logs --tail 40 "$where" 2>&1
      ;;
  esac
done
exit 1
