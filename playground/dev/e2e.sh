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
# it cannot start. It refuses to start while any playground session exists or
# another control plane of this stack runs (a dev stack, say): two control
# planes on the same Docker would adopt or reap each other's sessions.
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
  trap '' INT TERM
  docker rm -f "$hostlisten" > /dev/null 2>&1
  dc down --remove-orphans > /dev/null 2>&1
  remove_sessions
  rm -rf "$here/data-e2e" "$work"
}

# The running control planes of this stack (a container whose environment
# sets PLAY_SESSION_IMAGE) outside this project: one would adopt or reap the
# test's sessions.
foreign_controls() {
  local ids
  ids=$(docker ps -q)
  if [ -n "$ids" ]; then
    docker inspect -f '{{.Name}} {{index .Config.Labels "com.docker.compose.project"}} {{range .Config.Env}}{{.}} {{end}}' $ids 2> /dev/null |
      awk -v project="$PLAY_PROJECT" '$2 != project && / PLAY_SESSION_IMAGE=/ { sub(/^\//, "", $1); print $1 }'
  fi
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
others=$(foreign_controls | tr '\n' ' ')
if [ -n "$others" ]; then
  echo "e2e: another control plane runs on this Docker: $others(its reaper would adopt this test's sessions); stop it first" >&2
  exit 2
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/playground-e2e.XXXXXX") || exit 2
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
# sets $code, and the body and headers are in $work/body and $work/head
# (emptied first: a request that gets no answer leaves nothing to match).
get() {
  local host=$1 path=$2
  shift 2
  : > "$work/body"
  : > "$work/head"
  code=$(curl -s -o "$work/body" -D "$work/head" -w '%{http_code}' --max-time 10 -H "Host: $host" "$@" "$base$path")
}

header() {
  grep -i "^$1:" "$work/head" | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//'
}

# header_all NAME: every value of a response header on one line (a header
# can come from the upstream and again from the router).
header_all() {
  grep -i "^$1:" "$work/head" | tr -d '\r' | sed 's/^[^:]*: *//' | tr '\n' ' '
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
  : > "$work/body"
  : > "$work/head"
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

end_session() { # HANDLE -> playctl end's exit status; its output, on one line, in $end_out
  local rc
  end_out=$(dc exec -T control bin/playctl end "$1" 2>&1)
  rc=$?
  end_out=$(printf '%s' "$end_out" | tr '\n' ' ')
  return $rc
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

# wait_live N: until status.json reports N live sessions. A session ended by
# playctl (another process) leaves the control plane's memory at the reaper's
# next pass, and until then its client still counts as having a session.
wait_live() {
  local i
  for i in $(seq 1 15); do
    contains "$(curl -s --max-time 2 -H "Host: $domain" "$base/status.json")" "\"live\":$1," && return 0
    sleep 1
  done
  return 1
}

echo "e2e: bringing up $PLAY_PROJECT on $base with $PLAY_SESSION_IMAGE"
rm -rf "$here/data-e2e"
# Made here, not by dockerd (which would make it root's on Linux, and the
# cleanup's rm could not remove it).
mkdir -p "$here/data-e2e"
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
csp=$(header_all content-security-policy)
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
csp=$(header_all content-security-policy)
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

# The bounding set (CapBnd) is what shows --cap-drop ALL: a non-root
# process has an empty effective set either way. ipv6=absent: no IPv6
# address but loopback's (the router drops sessions by IPv4 address only).
# /proc/net/if_inet6 is read, not tested with -s: procfs files have size 0.
confined=$(inside "$h1" 'echo uid=$(id -u); awk "/^(CapEff|CapBnd|NoNewPrivs):/ {print \$1 \$2}" /proc/1/status; if touch /opt/cybertrain/.e2e 2> /dev/null; then echo root=writable; else echo root=read-only; fi; touch /workspace/.e2e && echo workspace=writable; echo memory=$(cat /sys/fs/cgroup/memory.max); echo pids=$(cat /sys/fs/cgroup/pids.max); echo cpu=$(cat /sys/fs/cgroup/cpu.max); if [ -e /var/run/docker.sock ]; then echo socket=present; else echo socket=absent; fi; if awk "\$6 != \"lo\"" /proc/net/if_inet6 2> /dev/null | grep -q .; then echo ipv6=present; else echo ipv6=absent; fi')
missing=""
for want in uid=1000 CapEff:0000000000000000 CapBnd:0000000000000000 NoNewPrivs:1 root=read-only workspace=writable memory=1610612736 pids=512 "cpu=100000 100000" socket=absent ipv6=absent; do
  printf '%s\n' "$confined" | grep -qxF "$want" || missing="$missing [$want]"
done
ok=no
if [ -z "$missing" ]; then ok=yes; fi
check E9 "inside: uid 1000, no capabilities, no new privileges, read-only root, writable /workspace, 1536 MiB, 512 pids, 1 CPU, no Docker socket" \
  "$ok" "missing:$missing; observed: $(printf '%s' "$confined" | tr '\n' ' ')"

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
# Run after E10, which makes the second session to try. Only "no route" and
# a timeout count as blocked: a connection, "Connection refused" (something
# on that address answered) or any other failure counts as a way out. The
# probe first shows that it works: the router's address on the session's
# network refuses port 80 (the router listens only on its address on the
# compose network), which the probe tells from "no route" and a timeout.

router_image=$(docker inspect -f '{{.Image}}' "$router")
docker run -d --name "$hostlisten" --network host --entrypoint caddy "$router_image" \
  respond --listen :18099 --body host-listener > /dev/null 2>&1
host_ips=$(docker run --rm --network host --entrypoint ip "$router_image" -o -4 addr show 2> /dev/null |
  awk '{print $4}' | cut -d / -f 1 | grep -v '^127\.')
other_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"ctplay-n-$h2\").IPAddress}}" "ctplay-s-$h2" 2> /dev/null)
router_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"ctplay-n-$h1\").IPAddress}}" "$router" 2> /dev/null)
cat > "$work/escape.sh" <<'EOF'
router=$1
other=$2
shift 2
leak() { echo "LEAK $1 ($2)"; }
tcp() {
  out=$(timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)
  rc=$?
  case "$rc $out" in
    "124 "*) ;;
    *"Network is unreachable"* | *"No route to host"*) ;;
    "0 "*) leak "$1:$2" connected ;;
    *"Connection refused"*) leak "$1:$2" "refused, so it answers" ;;
    *) leak "$1:$2" "exit $rc: $(printf '%s' "$out" | head -n 1)" ;;
  esac
}
blocked() { # WHAT EXIT ALLOWED...: any other exit status counts as a way out
  what=$1
  rc=$2
  shift 2
  for allowed in "$@"; do
    [ "$rc" = "$allowed" ] && return 0
  done
  leak "$what" "exit $rc"
}
out=$(timeout 5 bash -c "exec 3<>/dev/tcp/$router/80" 2>&1)
rc=$?
case "$rc $out" in
  *"Connection refused"*) echo "probe works" ;;
  "0 "*) echo "router: connected" ;;
  *) echo "router: exit $rc: $(printf '%s' "$out" | head -n 1)" ;;
esac
# curl may only fail to resolve (6) or time out (28); getent only find nothing (2).
curl -s --max-time 5 -o /dev/null https://example.com
blocked "example.com https" $? 6 28
getent hosts example.com > /dev/null
blocked "example.com DNS" $? 2
getent hosts ctplay-control > /dev/null
blocked "ctplay-control DNS" $? 2
tcp 1.1.1.1 80
tcp 169.254.169.254 80
for port in 22 80 443 2375; do tcp 172.17.0.1 "$port"; done
for ip in "$@"; do tcp "$ip" 18099; done
tcp "$other" 8080
tcp "$other" 3000
echo checked
EOF
escape=$(docker exec -i -u 1000:1000 "ctplay-s-$h1" bash -s -- "${router_ip:-0.0.0.0}" "${other_ip:-0.0.0.0}" $host_ips < "$work/escape.sh" 2>&1)
inside "$h1" "curl -s --max-time 5 -o /dev/null -H 'Host: play.localhost' http://$router_ip/" > /dev/null
router_rc=$?
bridge=$(printf '%s\n' "$host_ips" | grep -c '^10\.250\.' | tr -d ' ')
docker rm -f "$hostlisten" > /dev/null 2>&1
leaks=$(printf '%s\n' "$escape" | grep '^LEAK' | tr '\n' ' ')
works=$(if contains "$escape" "probe works"; then echo yes; else printf '%s\n' "$escape" | grep '^router: ' | head -n 1; fi)
if contains "$escape" checked; then ran=complete; else ran="stopped: $(printf '%s\n' "$escape" | tail -n 3 | tr '\n' ' ')"; fi
ok=no
if [ "$ran" = complete ] && [ "$works" = yes ] && [ -z "$leaks" ] && [ "$router_rc" = 7 ] && [ "$bridge" = 0 ] && [ -n "$host_ips" ] &&
  [ -n "$other_ip" ]; then ok=yes; fi
check E8 "from a session: no internet, DNS, metadata, host or other session; the router refuses it; no session bridge has a host address" "$ok" \
  "probe: $ran, the router's port 80 refused: ${works:-no}; leaks: ${leaks:-none}; router: curl exit $router_rc (7 expected); host addresses in 10.250/16: $bridge; host addresses tried: $(printf '%s' "$host_ips" | tr '\n' ' ')"

# ---- E11-E13: per-client limits, origins, unknown hosts -----------------------

start 198.51.100.1
again=$code
again_retry=$(header retry-after)
end_session "$h2"
ended=$?
ended_out=$end_out
began=$SECONDS
gone_code=$(healthz "$s2")
gone_took=$((SECONDS - began))
start 198.51.100.9
r1=$code
# The router cut off from a session that still runs must answer the 404 page
# at once. This is what `keepalive off` on the session upstreams is for:
# without it the next request rides the pooled connection to a session the
# router can no longer reach, and hangs (healthz gives up after 5 s).
warm=$(healthz "$sid")
docker network disconnect "ctplay-n-$handle" "$router" > /dev/null 2>&1
began=$SECONDS
cut_code=$(healthz "$sid")
cut_took=$((SECONDS - began))
end_session "$handle"
ended2=$?
ended2_out=$end_out
if wait_live 1; then live2=yes; else live2=no; fi
start 198.51.100.9
r2=$code
end_session "$handle"
ended3=$?
ended3_out=$end_out
if wait_live 1; then live3=yes; else live3=no; fi
start 198.51.100.9
r3=$code
r3_retry=$(header retry-after)
r3_page=$(has "Too many sessions from your network address")
ok=no
if [ "$again" = 429 ] && [ -n "$again_retry" ] && [ "$ended" = 0 ] && [ "$gone_code" = 404 ] && [ "$gone_took" -le 5 ] &&
  [ "$r1" = 303 ] && [ "$warm" = 200 ] && [ "$cut_code" = 404 ] && [ "$cut_took" -le 3 ] && [ "$ended2" = 0 ] &&
  [ "$live2" = yes ] && [ "$r2" = 303 ] && [ "$ended3" = 0 ] && [ "$live3" = yes ] && [ "$r3" = 429 ] && [ -n "$r3_retry" ] &&
  [ "$r3_page" = yes ]; then ok=yes; fi
check E11 "the same client gets 429; a just-ended session and one the router was cut from answer the 404 page at once; a third creation in the window gets 429" "$ok" \
  "same client: $again (Retry-After $again_retry); playctl end: exit $ended ($ended_out), then $gone_code in $gone_took s; router cut from a live session: $warm, then $cut_code in $cut_took s; creations: $r1 $r2 $r3 (Retry-After $r3_retry, the rate page: $r3_page); the ends between them: exit $ended2 ($ended2_out), exit $ended3 ($ended3_out); status.json back to one live session after each: $live2, $live3"

start 198.51.100.12 -H "Origin: http://evil.localhost"
o1=$code
start 198.51.100.12 -H "Sec-Fetch-Site: same-site"
o2=$code
start 198.51.100.1 -H "Origin: null" -H "Sec-Fetch-Site: same-origin"
o3=$code
# No route takes a request body. The control plane refuses a small one itself
# (the guard's 413). A large one is refused before anything reads it: with a
# declared length by the router or by Puma's own limit (whichever answers
# first, both correct); chunked always by the router, which is what its
# limit is for (Puma would buffer a chunked body to disk before the
# application could refuse it). "Expect:" sends the body at once, as a
# browser does.
head -c 1048576 /dev/zero > "$work/body-1m"
post_body() { # curl options -> the status of a POST /sessions that carries a body (its answer in $work/body)
  : > "$work/body"
  : > "$work/head"
  curl -s -o "$work/body" -w '%{http_code}' --max-time 10 -X POST -H "Host: $domain" -H "CF-Connecting-IP: 198.51.100.13" \
    -H "Origin: $entry_origin" -H "Sec-Fetch-Site: same-origin" -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Expect:' "$@" "$base/sessions"
}
b_small=$(post_body --data 'a=b')
small_page=$(has "No request body is accepted.")
b_large=$(post_body --data-binary "@$work/body-1m")
b_chunked=$(post_body -H 'Transfer-Encoding: chunked' --data-binary "@$work/body-1m")
chunked_page=$(has "Request body too large")
b_status=$(curl -s --max-time 2 -H "Host: $domain" "$base/status.json")
ok=no
if [ "$o1" = 403 ] && [ "$o2" = 403 ] && [ "$o3" = 429 ] && [ "$b_small" = 413 ] && [ "$small_page" = yes ] &&
  [ "$b_large" = 413 ] && [ "$b_chunked" = 413 ] && [ "$chunked_page" = yes ] && contains "$b_status" '"live":1,'; then ok=yes; fi
check E12 "another origin and a same-site request get 403; Origin null from this origin passes the check; a request body is refused with 413" "$ok" \
  "evil origin: $o1, same-site: $o2, null from same-origin: $o3 (429 is the per-client limit, past the origin check); bodies: small $b_small (the guard's page: $small_page), 1 MiB $b_large, 1 MiB chunked $b_chunked (the router's page: $chunked_page); then $b_status"

get "ffffffffffffffffffffffffffffffff.$domain" /
u1=$code
u1_page=$(has "No session at this address")
get "foo.$domain" /
u2=$code
# The router's own 404 page: the control plane answers /internal/* to an
# outside peer with a 404 too, a plain "Not Found".
get "$domain" /internal/sessions
u3=$code
u3_page=$(has "No session at this address")
dns=$(docker inspect -f '{{.HostConfig.Dns}}' "$router")
forward=$(docker exec "$router" cat /proc/sys/net/ipv4/ip_forward 2>&1)
ok=no
if [ "$u1" = 404 ] && [ "$u1_page" = yes ] && [ "$u2" = 404 ] && [ "$u3" = 404 ] && [ "$u3_page" = yes ] &&
  [ "$dns" = "[127.0.0.1]" ] && [ "$forward" = 0 ]; then ok=yes; fi
check E13 "unknown hosts get the 404 page, /internal/* through the router is 404, the router asks no outside resolver and forwards nothing" "$ok" \
  "unknown id: $u1, foo: $u2, /internal/sessions: $u3 (the router's page: $u3_page), router DNS: $dns, ip_forward: $forward"

# ---- E14-E15: restarts ----------------------------------------------------------

docker restart -t 5 "$control" > /dev/null 2>&1
restarted=$?
back=no
for i in $(seq 1 10); do
  st=$(curl -s --max-time 2 -H "Host: $domain" "$base/status.json")
  if contains "$st" '"live":1,'; then back=yes; break; fi
  sleep 1
done
editor=$(healthz "$s1")
ok=no
if [ "$restarted" = 0 ] && [ "$back" = yes ] && [ "$editor" = 200 ]; then ok=yes; fi
check E14 "after a control-plane restart status.json counts the live session within 10 s and its editor answers" "$ok" \
  "docker restart: exit $restarted, status.json: $st, editor: $editor"

old_router=$router
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
if [ -n "$router" ] && [ "$router" != "$old_router" ] && [ "$editor" = 200 ] && [ "$took" -le 10 ]; then ok=yes; fi
check E15 "a re-created router reaches the live session within 10 s (took $took s)" "$ok" \
  "editor: $editor, router container: $(printf '%.12s' "${old_router:-none}") then $(printf '%.12s' "${router:-none}")"

# ---- E18: the TTL, on session 1 (created at E2) ------------------------------------

# The window has two sides: an end more than 5 s early (the allowance for the
# VM's clock against this one's) is not the TTL either. The TTL itself is
# read from the session's two labels.
born=$(docker inspect -f '{{index .Config.Labels "cybertrain-play.created-at"}}' "ctplay-s-$h1" 2> /dev/null)
expires=$(docker inspect -f '{{index .Config.Labels "cybertrain-play.expires-at"}}' "ctplay-s-$h1" 2> /dev/null)
ttl=$((${expires:-0} - ${born:-0}))
now_status=200
while [ "$now_status" = 200 ] && [ "$(date +%s)" -lt $((${expires:-0} + 30)) ]; do
  sleep 2
  now_status=$(healthz "$s1")
done
late=$(($(date +%s) - ${expires:-0}))
sleep 3
ok=no
if [ "$now_status" = 404 ] && [ "$ttl" = "$PLAY_TTL" ] && [ "$late" -ge -5 ] && [ "$late" -le 15 ] && [ "$(count containers)" = 0 ] &&
  [ "$(count networks)" = 0 ]; then ok=yes; fi
check E18 "session 1 ends at its TTL: its editor is the 404 page within 15 s of expires-at, no labelled container or network is left" "$ok" \
  "editor: $now_status, $late s after expires-at (-5 to 15 expected); expires-at minus created-at: $ttl s ($PLAY_TTL expected); containers: $(count containers), networks: $(count networks)"

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
resumed_again=$?

# With the router stopped nothing reaches the control plane from outside, so
# the request comes from inside its own container (loopback, a permitted host).
# The refusal must give the missing router as its reason ("It is starting
# up"), not the pause that kill-all left (had the resume failed).
dc stop router > /dev/null 2>&1
no_router=$(docker exec "$control" ruby -rnet/http -e 'r = Net::HTTP.new("127.0.0.1", 9292).post("/sessions", "", "Host" => "localhost", "CF-Connecting-IP" => "198.51.100.17"); print r.code, (r.body.to_s.include?("It is starting up") ? " starting up" : " another reason")' 2>&1)
ok=no
if [ "$resumed_again" = 0 ] && [ "$no_router" = "503 starting up" ] && [ "$(count containers)" = 0 ] && [ "$(count networks)" = 0 ]; then ok=yes; fi
check E17 "with the router stopped a creation is refused with 503 and leaves nothing behind" "$ok" \
  "playctl resume: exit $resumed_again; status and reason: $no_router; containers: $(count containers), networks: $(count networks)"
dc start router > /dev/null 2>&1

# ---- E19: the log holds no session id, preview id or client address ---------------

dc logs --no-log-prefix control > "$work/control.log" 2>&1
leaked=""
for secret in $secrets 198.51.100.; do
  if grep -qF -- "$secret" "$work/control.log"; then leaked="$leaked $secret"; fi
done
# Nor any other id: a standalone token of 32 hex digits (handles have 16).
if grep -Eq '(^|[^0-9a-f])[0-9a-f]{32}([^0-9a-f]|$)' "$work/control.log"; then leaked="$leaked [a 32-hex token]"; fi
# The run makes exactly five sessions, and the list searched for holds both
# ids of each (an id this script missed would not be searched for).
ids=$(printf '%s\n' $secrets | grep -c . | tr -d ' ')
created=$(grep -c 'play event=created ' "$work/control.log" | tr -d ' ')
ok=no
if [ -z "$leaked" ] && [ "$created" -eq 5 ] && [ "$ids" -eq $((2 * created)) ]; then ok=yes; fi
check E19 "the control plane's log names no session id, preview id or client address ($created creations logged)" "$ok" \
  "found:${leaked:- nothing}; ids searched for: $ids (2 per creation expected), creations logged: $created (5 expected)"

echo "e2e: $passed passed, $failed failed"
if [ "$failed" -eq 0 ]; then
  exit 0
fi
dc logs --tail 40 control router
exit 1
