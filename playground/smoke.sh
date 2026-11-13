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
# D playground-server started again, C a codespace (CODESPACES=true),
# F the boot check of CYBERTRAIN_SESSION_SAME_SITE, E a cp -a copy of the
# blog, B no network. playground/README.md lists every check.
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
what_G8="cybertrain doctor prints the fiddle line as ok"
what_A1="GET /articles through the published port answers 200 (default command, CYBERTRAIN_HOST=0.0.0.0)"
what_A2="the log shows the boot banner of $version listening on http://0.0.0.0:3000"
what_A3="starting compiled nothing (build/bin/blog keeps the image's mtime)"
what_A11="the first start runs no C compiler: no cc, gcc, cc1, collect2 or ld process but a --version probe from the container's start until its startup build has finished, and build/bin/gen (gen runs under CRuby) and tmp/cybertrain-dev/ffi/*.so keep the image's mtimes"
what_A4="GET / answers 200 with <h1>Articles</h1>"
what_A5="GET /articles/new has a CSRF token and a SameSite=Lax session cookie without Secure or Partitioned"
what_A6="POST /articles with the token and the cookie answers 303 to the new article, whose page shows it"
what_A7="POST /articles without token or cookie answers 403"
what_A8="a view edit shows on the next request"
what_A9="a model edit answers 422 for a short body with X-Cybertrain-Runtime: cruby within 10 s, and with spinel afterwards"
what_A12="the CRuby child that serves the model edit compiles nothing: once it has inserted an article and listed the articles through SQLite (X-Cybertrain-Runtime: cruby), tmp/cybertrain-dev/ffi/*.so are still the image's, names and mtimes"
what_A10="the running container generated tmp/secret_key"
what_D1="a second playground-server exits 0 saying the server is already running"
what_D2="one supervisor and one child run"
what_D3="after a container restart (Codespaces' idle stop and resume) the server is back, once, with the earlier article"
what_D4="playground-server leaves a server started by hand alone: it says a server is already starting before it listens and the port is in use once it listens, exits 0 both times, and one supervisor and one child run"
what_C1="with CODESPACES=true the session cookie keeps the default, SameSite=Lax without Secure or Partitioned"
what_C2="with CODESPACES=true the banner shows https://smoke-3000.app.github.dev/"
what_C3="with CODESPACES=true and PATH=/usr/bin:/bin, interactive and login bash shells find spin in /opt/cybertrain/bin"
what_C4="with VS Code's code command on PATH, playground-server opens PLAYGROUND.md and, once the server listens, the forwarded URL (code --openExternal)"
what_F1="CYBERTRAIN_SESSION_SAME_SITE=lax stops the app at boot under CRuby and as the compiled binary (tried as soon as the startup build finds it up to date): the server logs the valid values and that the binary failed, and answers 503 naming them for both instead of serving the app"
what_E1="a cp -a copy of the blog started by playground-server compiles nothing"
what_B1="with no network, git ls-remote of the repository URL lists refs/tags/v$version (the mirror)"
what_B2="with no network, cybertrain new works in /workspace (next to the blog) and locks the blog's commit"
what_B3="with no network, the new app builds"

# pass ID WHAT [MEASURED]: MEASURED, a few words of what was timed, goes
# after WHAT in parentheses (playground/README.md quotes such figures).
pass() {
  passed=$((passed + 1))
  echo "PASS $1 $2${3:+ ($3)}"
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

# The first non-blank line of $1, without its indentation.
first_text() {
  printf '%s\n' "$1" | grep -m 1 '[^ ]' | sed 's/^ *//'
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

# The processes of `cybertrain server`: the supervisor, the gem's Ruby script
# ("/usr/bin/ruby3.2 /usr/local/bin/cybertrain server [PORT]"; docker-init's
# arguments name `cybertrain server` too, hence the interpreter), and its one
# child, the blog under CRuby ("ruby -E UTF-8 -I... -r cybertrain/preview
# bin/blog.rb PORT") or the compiled binary ("build/bin/blog PORT"). Neither
# matches gen, `bin/blog.rb dev-address` or the build (`spin build blog`).
supervisor_pattern='^[^ ]*ruby[^ ]* [^ ]*/cybertrain server( |$)'
child_pattern='^([^ ]*ruby[^ ]* .* bin/blog\.rb|build/bin/blog) [0-9]+$'

# servers CONTAINER: waits up to 10 s for exactly one supervisor and one child
# (a handover from CRuby to the binary stops one child before it starts the
# next). Sets $servers to "supervisors: S, children: C" as last counted;
# returns 0 once both are 1.
servers() {
  local began=$SECONDS s c
  while :; do
    s=$(docker exec "$1" pgrep -c -f "$supervisor_pattern" 2> /dev/null)
    c=$(docker exec "$1" pgrep -c -f "$child_pattern" 2> /dev/null)
    servers="supervisors: ${s:-none}, children: ${c:-none}"
    if [ "$s" = 1 ] && [ "$c" = 1 ]; then
      return 0
    fi
    if [ $((SECONDS - began)) -ge 10 ]; then
      return 1
    fi
    sleep 0.5
  done
}

# built CONTAINER SECONDS: waits until the supervisor's first build has ended
# (its log says the binary serves, or that the build or the binary failed).
# Sets $detail when it does not within SECONDS.
built() {
  local began=$SECONDS
  while [ $((SECONDS - began)) -lt "$2" ]; do
    case "$(docker logs "$1" 2>&1)" in
      *"=> spinel: ready in "*) return 0 ;;
      *"=> spinel: build failed"*) detail="the startup build failed"; return 1 ;;
      *"=> spinel: the binary failed"*) detail="the compiled binary failed"; return 1 ;;
    esac
    if ! running "$1"; then
      detail="the container exited"
      return 1
    fi
    sleep 1
  done
  detail="the startup build did not end within $2 s"
  return 1
}

# The shim's compiled libraries in the blog at $1, one "NAME MTIME" line each
# (sorted), the way A11 and E1 compare them with the image's.
ffi_list='cd "$1/tmp/cybertrain-dev/ffi" 2> /dev/null && for f in *.so; do [ -e "$f" ] && echo "$f $(stat -c %Y "$f")"; done | sort'

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
doctor_out=$out
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

# The line `cybertrain doctor` (G3) prints for the library the CRuby preview
# needs; without it `cybertrain server` would run the compiled loop only.
fiddle_line=$(printf '%s\n' "$doctor_out" | grep '^fiddle ' | head -n 1)
if printf '%s\n' "$fiddle_line" | grep -Eq '^fiddle +ok '; then
  pass G8 "$what_G8"
else
  fail G8 "$what_G8" "got: ${fiddle_line:-no fiddle line}" out:G3
fi

# The prebuilt binary's mtime, which A3 and E1 compare against, and gen's,
# which A11 compares against (the supervisor runs gen under CRuby, bin/gen.rb,
# and builds only the blog's binary, so nothing rebuilds build/bin/gen).
run_once 30 mtime "$image" stat -c %Y /workspace/blog/build/bin/blog /workspace/blog/build/bin/gen
image_mtime=""
image_gen_mtime=""
if [ "$rc" = 0 ]; then
  image_mtime=$(printf '%s\n' "$out" | sed -n 1p)
  image_gen_mtime=$(printf '%s\n' "$out" | sed -n 2p)
fi

# The shim's libraries the image was built with, which A11 and E1 compare
# against. None at all would make the comparison say nothing.
run_once 30 ffi "$image" sh -c "$ffi_list" sh /workspace/blog
image_ffi=""
if [ "$rc" = 0 ]; then
  image_ffi=$out
fi

# ---- A: the default command, reached from the host, and the edit loop ------

main="$prefix-main"
main_up=no
title=""
base=""
# A11: every C compiler process from the container's start until the startup
# build has ended, 20 times a second, polled by a loop that the container's
# own command line starts before it execs the default command, so that no
# moment goes unpolled; A11 stops it with /tmp/smoke-compilers.stop, which
# also keeps it stopped after D3's restart. `cc --version` compiles nothing:
# the shim asks it once per CRuby child for its cache key, and spin may too.
poller='while [ ! -e /tmp/smoke-compilers.stop ]; do pgrep -a -x "cc|gcc|cc1|collect2|ld" >> /tmp/smoke-compilers.log; sleep 0.05; done'
if start main -p 127.0.0.1::3000 -e CYBERTRAIN_HOST=0.0.0.0 "$image" sh -c "($poller) & exec playground-server"; then
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

  # The supervisor serves from CRuby at once, runs gen under CRuby and then
  # builds in the background. The image's binary is newer than every Ruby
  # file of the blog and the framework, so that build is a plain `spin build
  # blog`, which finds it up to date in a fraction of a second, and the
  # binary takes the port over (`spin build blog -- --incremental` would
  # compile every time). Whether anything was compiled is known only once
  # that build has ended.
  startup_built=yes
  if ! built "$main" 300; then
    startup_built="no ($detail)"
  fi
  docker exec "$main" touch /tmp/smoke-compilers.stop > /dev/null 2>&1

  running_mtime=$(docker exec "$main" stat -c %Y /workspace/blog/build/bin/blog 2> /dev/null)
  ready_in=$(docker logs "$main" 2>&1 | sed -n 's/^=> spinel: ready in \([0-9.]*s\).*/\1/p' | head -n 1)
  if [ "$startup_built" = yes ] && [ -n "$image_mtime" ] && [ "$running_mtime" = "$image_mtime" ]; then
    pass A3 "$what_A3" "the binary served ${ready_in:-?} after the supervisor's first round began (its ready-in figure)"
  else
    fail A3 "$what_A3" "image: ${image_mtime:-unknown}, running: ${running_mtime:-unknown}, startup build ended: $startup_built" "$main"
  fi

  # One word per program that ran (its pgrep -a line, but for a --version
  # probe): the whole command lines run to pages. A probe is a cc or gcc line
  # that is `cc --version` or that has no arguments at all: pgrep -a prints
  # only the name, as `[cc]` (with ` <defunct>` once it has exited but not
  # been reaped), when the process's command line cannot be read, which is
  # the case in the instant a process exits; a probe caught there has lost
  # its `--version`. Not counting such a line is sound because every real
  # compile or link runs cc1, or collect2 and ld, and those count whatever
  # their line looks like, as does a cc or gcc line with any other arguments.
  compilers=$(docker exec "$main" cat /tmp/smoke-compilers.log 2> /dev/null | awk '
    { name = $2; unreadable = 0 }
    name ~ /^\[.*\]$/ { name = substr(name, 2, length(name) - 2); unreadable = 1 }
    {
      n = split(name, p, "/"); prog = p[n]
      if ((prog == "cc" || prog == "gcc") && (unreadable || NF == 2 || (NF == 3 && $3 == "--version"))) next
      print prog
    }' | sort -u | tr '\n' ' ' | sed 's/ $//')
  polled=$(docker exec "$main" test -e /tmp/smoke-compilers.log && echo yes)
  running_gen_mtime=$(docker exec "$main" stat -c %Y /workspace/blog/build/bin/gen 2> /dev/null)
  running_ffi=$(docker exec "$main" sh -c "$ffi_list" sh /workspace/blog 2> /dev/null)
  if [ "$startup_built" = yes ] && [ "$polled" = yes ] && [ -z "$compilers" ] &&
    [ -n "$image_gen_mtime" ] && [ "$running_gen_mtime" = "$image_gen_mtime" ] &&
    [ -n "$image_ffi" ] && [ "$running_ffi" = "$image_ffi" ]; then
    pass A11 "$what_A11"
  else
    fail A11 "$what_A11" "startup build ended: $startup_built, polled: ${polled:-no}, compilers: ${compilers:-none}, build/bin/gen in the image: ${image_gen_mtime:-unknown}, running: ${running_gen_mtime:-unknown}, ffi in the image: $(printf '%s' "${image_ffi:-none}" | tr '\n' ';'), running: $(printf '%s' "${running_ffi:-none}" | tr '\n' ';')" "$main"
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

  # The edit shows at once from the CRuby child (the header says which
  # runtime answered); the binary the background build makes then takes the
  # port over and answers the same.
  # A12: the startup build takes under a second, so the binary serves before
  # any CRuby child has used the shim, whose libraries are built at a
  # module's first call (the SQLite one at the first query). The child that
  # the edit starts is the first to use them: at its first 422 it inserts an
  # article and lists the articles, then the shim's libraries are compared
  # with the image's (none compiled, none rebuilt).
  cruby_insert=""
  cruby_list=""
  cruby_ffi=""
  docker exec "$main" sed -i 's/^class Article$/&\n  validates :body, presence: true, length: { minimum: 10 }/' /workspace/blog/app/models/article.rb
  edited=$(docker exec "$main" grep -c 'validates :body' /workspace/blog/app/models/article.rb 2> /dev/null)
  edited_at=$SECONDS
  cruby_after=""
  spinel_after=""
  last="no answer"
  deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    rm -f "$work/a9.jar" "$work/a9.html" "$work/a9.head"
    probe=$(curl -s -c "$work/a9.jar" -o "$work/a9.html" -w '%{http_code}' --max-time 5 "$base/articles/new")
    probe_token=$(form_token "$work/a9.html")
    if [ "$probe" = 200 ] && [ -n "$probe_token" ]; then
      short=$(curl -s -b "$work/a9.jar" -D "$work/a9.head" -o /dev/null -w '%{http_code}' --max-time 5 \
        --data-urlencode "authenticity_token=$probe_token" \
        --data-urlencode "article[title]=Short body $(date +%s)" \
        --data-urlencode "article[body]=short" \
        "$base/articles")
      runtime=$(header "$work/a9.head" x-cybertrain-runtime)
      last="$short from ${runtime:-no runtime header} after $((SECONDS - edited_at)) s"
      if [ "$short" = 422 ] && [ "$runtime" = cruby ] && [ -z "$cruby_after" ]; then
        cruby_after=$((SECONDS - edited_at))
        rm -f "$work/a12.head" "$work/a12-list.head"
        code=$(curl -s -b "$work/a9.jar" -c "$work/a9.jar" -D "$work/a12.head" -o /dev/null -w '%{http_code}' --max-time 5 \
          --data-urlencode "authenticity_token=$probe_token" \
          --data-urlencode "article[title]=CRuby insert $(date +%s)" \
          --data-urlencode "article[body]=A body that is long enough." \
          "$base/articles")
        cruby_insert="$code from $(header "$work/a12.head" x-cybertrain-runtime)"
        code=$(curl -s -D "$work/a12-list.head" -o /dev/null -w '%{http_code}' --max-time 5 "$base/articles")
        cruby_list="$code from $(header "$work/a12-list.head" x-cybertrain-runtime)"
        cruby_ffi=$(docker exec "$main" sh -c "$ffi_list" sh /workspace/blog 2> /dev/null)
      fi
      if [ "$short" = 422 ] && [ "$runtime" = spinel ]; then
        spinel_after=$((SECONDS - edited_at))
        break
      fi
    else
      last="GET /articles/new: $probe after $((SECONDS - edited_at)) s"
    fi
    if [ -z "$cruby_after" ]; then
      sleep 0.5
    else
      sleep 3
    fi
  done
  listed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base/articles")
  if [ -n "$cruby_after" ] && [ "$cruby_after" -le 10 ] && [ -n "$spinel_after" ] && [ "$listed" = 200 ]; then
    pass A9 "$what_A9" "cruby after $cruby_after s, spinel after $spinel_after s"
  else
    fail A9 "$what_A9" "validates :body lines: ${edited:-0}, 422 from cruby after: ${cruby_after:-never} s, from spinel after: ${spinel_after:-never} s, last: $last, GET /articles: $listed" "$main"
  fi

  if [ "$cruby_insert" = "303 from cruby" ] && [ "$cruby_list" = "200 from cruby" ] &&
    [ -n "$image_ffi" ] && [ "$cruby_ffi" = "$image_ffi" ]; then
    pass A12 "$what_A12"
  else
    fail A12 "$what_A12" "insert: ${cruby_insert:-not tried (no 422 from cruby)}, list: ${cruby_list:-not tried}, ffi in the image: $(printf '%s' "${image_ffi:-none}" | tr '\n' ';'), after: $(printf '%s' "${cruby_ffi:-none}" | tr '\n' ';')" "$main"
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

  if servers "$main"; then
    pass D2 "$what_D2"
  else
    fail D2 "$what_D2" "$servers" "$main"
  fi

  # Codespaces stops an idle codespace and starts the same container again:
  # the lock file and tmp/secret_key from the first run are still there.
  # The old server would pass the checks below too, so the restart must
  # succeed and give the container a new start time.
  started_before=$(docker inspect -f '{{.State.StartedAt}}' "$main" 2> /dev/null)
  docker restart -t 10 "$main" > /dev/null 2>&1
  restart_rc=$?
  restarted=$SECONDS
  started_after=$(docker inspect -f '{{.State.StartedAt}}' "$main" 2> /dev/null)
  restart_ok=no
  if [ "$restart_rc" = 0 ] && [ -n "$started_after" ] && [ "$started_after" != "$started_before" ]; then
    restart_ok=yes
  fi
  port=$(host_port "$main")
  base="http://127.0.0.1:$port"
  back=no
  while [ $((SECONDS - restarted)) -lt 30 ]; do
    if [ -n "$port" ] && [ "$(curl -s -o "$work/d3.html" -w '%{http_code}' --max-time 2 "$base/articles")" = "200" ]; then
      back=yes
      break
    fi
    if ! running "$main"; then
      break
    fi
    port=$(host_port "$main")
    base="http://127.0.0.1:$port"
    sleep 0.5
  done
  kept=yes
  if [ -n "$title" ] && ! grep -qF "$title" "$work/d3.html" 2> /dev/null; then
    kept=no
  fi
  once=no
  if servers "$main"; then
    once=yes
  fi
  if [ "$restart_ok" = yes ] && [ "$back" = yes ] && [ "$kept" = yes ] && [ "$once" = yes ]; then
    pass D3 "$what_D3"
  else
    fail D3 "$what_D3" "restarted: $restart_ok, answered 200: $back, article kept: $kept, $servers" "$main"
  fi
else
  fail A1 "$what_A1" "$detail" "$main"
  docker exec "$main" touch /tmp/smoke-compilers.stop > /dev/null 2>&1
  for id in A2 A3 A11 A4 A5 A6 A7 A8 A9 A12 A10 D1 D2 D3; do
    name="what_$id"
    fail "$id" "${!name}" "skipped: the dev server did not come up"
  done
fi

# A server started by hand (PLAYGROUND.md's tutorial steps start one with
# `cybertrain server`) never holds playground-server's lock, and until it has
# bound the port it does not hold that either; the next attach runs
# playground-server, which must leave it alone in both phases. The
# supervisor binds the port once `spin flags` and the app's address have
# answered, within a second or two, so this one is given a `spin` that waits
# while /tmp/hold-spin exists (beside a link to the real spinel, so that the
# toolchain check still finds spin next to the pinned spinel): it stays
# before the port until the hold is lifted.
manual="$prefix-manual"
held='mkdir -p /tmp/held && printf "%s\n" "#!/bin/sh" "while [ -e /tmp/hold-spin ]; do sleep 0.1; done" "exec /opt/cybertrain/bin/spin \"\$@\"" > /tmp/held/spin && chmod +x /tmp/held/spin && ln -s /opt/cybertrain/bin/spinel /tmp/held/spinel && touch /tmp/hold-spin && cd /workspace/blog && PATH=/tmp/held:$PATH exec cybertrain server'
if start manual "$image" bash -c "$held"; then
  phase=""
  # Its own process, the gem's Ruby script (docker-init's arguments name
  # `cybertrain server` too): playground-server must not run before it exists.
  waited=$SECONDS
  until docker exec "$manual" pgrep -f "$supervisor_pattern" > /dev/null 2>&1; do
    if [ $((SECONDS - waited)) -ge 30 ] || ! running "$manual"; then
      phase="before listening: no cybertrain server process within 30 s"
      break
    fi
    sleep 0.5
  done
  if [ -z "$phase" ] && docker exec "$manual" bash -c '(exec 3<>/dev/tcp/127.0.0.1/3000) 2> /dev/null'; then
    phase="before listening: the port already answers (the hold on spin did not work)"
  fi
  if [ -z "$phase" ]; then
    starting=$(docker exec "$manual" timeout 10 playground-server 2>&1)
    starting_rc=$?
    case "$starting" in
      *"is already starting"*) said=yes ;;
      *) said=no ;;
    esac
    if [ "$starting_rc" != 0 ] || [ "$said" != yes ]; then
      phase="before listening: exit $starting_rc: $(first_text "$starting")"
    fi
  fi
  docker exec "$manual" rm -f /tmp/hold-spin > /dev/null 2>&1
  if [ -z "$phase" ] && ! up_inside "$manual" 60; then
    phase="once the hold was lifted: $detail"
  fi
  if [ -z "$phase" ]; then
    again=$(docker exec "$manual" timeout 10 playground-server 2>&1)
    again_rc=$?
    case "$again" in
      *"is already in use"*) said=yes ;;
      *) said=no ;;
    esac
    if [ "$again_rc" != 0 ] || [ "$said" != yes ]; then
      phase="once listening: exit $again_rc: $(first_text "$again")"
    fi
  fi
  if [ -z "$phase" ] && ! servers "$manual"; then
    phase="once listening: $servers"
  fi
  if [ -z "$phase" ]; then
    pass D4 "$what_D4"
  else
    fail D4 "$what_D4" "$phase" "$manual"
  fi
else
  fail D4 "$what_D4" "docker run failed: $(first_line "$(cat "$work/manual.start")")"
fi

# ---- C: a codespace (CODESPACES=true) --------------------------------------

# A stand-in for VS Code's `code` command, which a codespace's terminal has:
# it logs its arguments to /tmp/code.log (C4).
codespace="$prefix-codespace"
fake_code='mkdir -p /tmp/fakebin && printf "%s\n" "#!/bin/sh" "echo \"\$*\" >> /tmp/code.log" > /tmp/fakebin/code && chmod +x /tmp/fakebin/code && PATH=/tmp/fakebin:$PATH exec playground-server'
if start codespace -e CODESPACES=true -e CODESPACE_NAME=smoke -e GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=app.github.dev "$image" bash -c "$fake_code"; then
  if up_inside "$codespace" 30; then
    cookie=$(docker exec "$codespace" curl -s -D - -o /dev/null --max-time 5 http://127.0.0.1:3000/articles/new 2> /dev/null |
      grep -i '^set-cookie:' | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//')
    case "$cookie" in
      *"; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600") pass C1 "$what_C1" ;;
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
# The opener polls the port every 0.25 s; give it a few seconds after C1.
calls=""
began=$SECONDS
while [ $((SECONDS - began)) -lt 10 ]; do
  calls=$(docker exec "$codespace" cat /tmp/code.log 2> /dev/null)
  case "$calls" in
    *"--openExternal https://smoke-3000.app.github.dev/"*) break ;;
  esac
  sleep 0.5
done
case "$calls" in
  *"--reuse-window /workspace/blog/PLAYGROUND.md"*"--openExternal https://smoke-3000.app.github.dev/"*) pass C4 "$what_C4" ;;
  *) fail C4 "$what_C4" "code was called with: $(printf '%s' "$calls" | tr '\n' ';')" "$codespace" ;;
esac

# A terminal the visitor opens, interactive or login bash, must find the
# toolchain. The image's PATH already holds /opt/cybertrain/bin, so the
# shells start without it: profile.sh has to put it back.
run_once 30 C3 -e CODESPACES=true "$image" env PATH=/usr/bin:/bin bash -c 'bash -ic "echo IC=\$(command -v spin)" 2> /dev/null; bash -lc "echo LC=\$(command -v spin)" 2> /dev/null'
case "$out" in
  *"IC=/opt/cybertrain/bin/spin"*) interactive=yes ;;
  *) interactive=no ;;
esac
case "$out" in
  *"LC=/opt/cybertrain/bin/spin"*) login=yes ;;
  *) login=no ;;
esac
if [ "$rc" = 0 ] && [ "$interactive" = yes ] && [ "$login" = yes ]; then
  pass C3 "$what_C3"
else
  fail C3 "$what_C3" "interactive: $interactive, login: $login" out:C3
fi

# ---- F: the boot check -----------------------------------------------------

# The app's boot check stops the child that serves it. The CRuby child
# boots first; the startup build finds the image's binary up to date within
# a second, so the supervisor tries the binary too: it stops at the same
# check ("=> spinel: the binary failed; serving the CRuby preview"), and the
# CRuby child it starts again stops as well. The supervisor outlives its
# children (it holds the port and waits for a change), so the server does
# not exit: its page says why the app is not served, the binary's reason
# after "the compiled binary also failed:". Both runtimes must refuse.
boot="$prefix-boot"
message='must be Lax, Strict or None (got &quot;lax&quot;)'
if start boot -e CYBERTRAIN_SESSION_SAME_SITE=lax "$image"; then
  logged=no
  binary_failed=no
  answer=""
  named=""
  began=$SECONDS
  while [ $((SECONDS - began)) -lt 300 ]; do
    logs=$(docker logs "$boot" 2>&1)
    case "$logs" in
      *'must be Lax, Strict or None (got "lax")'*) logged=yes ;;
    esac
    case "$logs" in
      *"=> spinel: the binary failed"*) binary_failed=yes ;;
    esac
    answer=$(docker exec "$boot" curl -s -o /tmp/f1.html -w '%{http_code}' --max-time 2 http://127.0.0.1:3000/articles 2> /dev/null)
    named=""
    # CRuby's reason is the text before the "the compiled binary also
    # failed" line and the binary's the text from it on: the message must be
    # in both parts, so that the binary's part alone cannot stand for CRuby.
    if [ "$answer" = 503 ] && docker exec "$boot" sed '/the compiled binary also failed/,$d' /tmp/f1.html 2> /dev/null | grep -qF "$message"; then
      named=cruby
      if docker exec "$boot" sed -n '/the compiled binary also failed/,$p' /tmp/f1.html 2> /dev/null | grep -qF "$message"; then
        named="cruby and the binary"
      fi
    fi
    if [ "$logged" = yes ] && [ "$binary_failed" = yes ] && [ "$named" = "cruby and the binary" ]; then
      break
    fi
    if ! running "$boot"; then
      break
    fi
    sleep 0.5
  done
  if [ "$logged" = yes ] && [ "$binary_failed" = yes ] && [ "$named" = "cruby and the binary" ]; then
    pass F1 "$what_F1"
  else
    fail F1 "$what_F1" "logged: $logged, the binary failed: $binary_failed, GET /articles: ${answer:-no answer}, the page names the values for: ${named:-neither}" "$boot"
  fi
else
  fail F1 "$what_F1" "docker run failed: $(first_line "$(cat "$work/boot.start")")"
fi

# ---- E: a cp -a copy of the blog -------------------------------------------
# The premise of playground/README.md's "copy the blog only with cp -a".

copy="$prefix-copy"
if start copy "$image" bash -c 'cp -a /workspace/blog /tmp/blog-copy && exec playground-server /tmp/blog-copy'; then
  # Once the startup build has ended, as A3 and A11: the binary is still the
  # image's (the startup build found it up to date after the copy), and the
  # shim's libraries came through the copy with their names and mtimes, for
  # the copy's first CRuby child after an edit to find (as A12's does).
  if up_inside "$copy" 30 && built "$copy" 300; then
    copy_mtime=$(docker exec "$copy" stat -c %Y /tmp/blog-copy/build/bin/blog 2> /dev/null)
    copy_ffi=$(docker exec "$copy" sh -c "$ffi_list" sh /tmp/blog-copy 2> /dev/null)
    if [ -n "$image_mtime" ] && [ "$copy_mtime" = "$image_mtime" ] && [ -n "$image_ffi" ] && [ "$copy_ffi" = "$image_ffi" ]; then
      pass E1 "$what_E1"
    else
      fail E1 "$what_E1" "image: ${image_mtime:-unknown}, copy: ${copy_mtime:-unknown}, ffi in the image: $(printf '%s' "${image_ffi:-none}" | tr '\n' ';'), copy: $(printf '%s' "${copy_ffi:-none}" | tr '\n' ';')" "$copy"
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
# runs inside it and prints one "B2 ..." and one "B3 ..." line. After a FAIL
# line it prints the last 40 lines of that step's log, each behind "  | ", so
# no log line starts with "B2 " or "B3 "; the summary shows them.
offline='
log_tail() { tail -n 40 "$1" | sed "s/^/  | /"; }
began=$SECONDS
cd /workspace || exit 1
if ! cybertrain new offline > /tmp/smoke-new.log 2>&1; then
  echo "B2 FAIL cybertrain new offline failed: $(tail -n 2 /tmp/smoke-new.log | tr "\n" " ")"
  log_tail /tmp/smoke-new.log
  echo "B3 FAIL skipped: there is no app"
  exit 0
fi
took=$((SECONDS - began))
cd offline || exit 1
if [ "$took" -gt 180 ]; then
  echo "B2 FAIL cybertrain new took $took s (limit 180 s)"
  log_tail /tmp/smoke-new.log
elif ! grep -qF "ref = \"v$SMOKE_VERSION\"" spin.toml; then
  echo "B2 FAIL spin.toml has no ref = \"v$SMOKE_VERSION\""
  log_tail /tmp/smoke-new.log
elif ! cmp -s spin.lock /workspace/blog/spin.lock; then
  echo "B2 FAIL spin.lock differs from /workspace/blog/spin.lock"
  log_tail /tmp/smoke-new.log
else
  echo "B2 PASS"
fi
if cybertrain spin build offline > /tmp/smoke-build.log 2>&1 && [ -x build/bin/offline ]; then
  echo "B3 PASS"
else
  echo "B3 FAIL cybertrain spin build offline failed: $(tail -n 2 /tmp/smoke-build.log | tr "\n" " ")"
  log_tail /tmp/smoke-build.log
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
