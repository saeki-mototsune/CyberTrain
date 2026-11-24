# The mechanics the end-to-end scripts share (script/auth-e2e,
# script/generators-e2e, script/test-command-e2e, script/e2e-legs), sourced
# by each of them; not a script of its own. What a scenario checks stays in
# the script, or in a file beside this one named after it
# (script/e2e.d/auth*.sh); what is here only runs, reports and cleans up:
#
#   e2e_init NAME         the name every line starts with; ROOT, the checkout
#   e2e_scenario NAME     the scenario a line names, and its clock (`+Ns`)
#   step MESSAGE          one line of progress, with the seconds elapsed
#   fail MESSAGE          the failure, the server log's tail when a server
#                         ran, where the app was left; exit 1
#   expect_equal WHAT EXPECTED ACTUAL
#   expect_contains WHAT NEEDLE HAYSTACK
#   expect_header WHAT REGEXP FILE (case-insensitive, like header names)
#   e2e_use_cli           `cybertrain` is this checkout's CLI, or with
#                         CYBERTRAIN_E2E_CLI=gem the one on PATH
#   e2e_workdir NAME      a new scratch directory, in TMPDIR
#   free_port             a TCP port nothing listens on
#   start_server LOG CMD...  CMD in the background, its output in LOG
#   wait_for_up BASE PORT    until BASE/up.html answers (30 s at most)
#   stop_server           the server and the SMTP receiver, if running (on
#                         EXIT too)
#   form_token PAGE       the authenticity_token of the first form in PAGE
#   post_status JAR URL FIELD...  a url-encoded POST with the cookie jar:
#                         prints the status and the redirect
#   same_tree WHAT A B [-x PATH | -r SED]...
#                         fails unless two directories hold the same files
#                         with the same bytes, but for those named
#
# Every line a script prints carries the seconds since its scenario started,
# or since the script did when it has no scenarios, so a CI log shows where
# the minutes go. The first failure stops the script and leaves the
# scratch directory (E2E_LEFT) in place to look at.
#
# Bash only (arrays, `local`); the scripts set `set -euo pipefail`.

# shellcheck shell=bash

E2E_NAME=e2e
E2E_SCENARIO=""
E2E_STARTED=0
# The directory a failure names as left in place.
E2E_LEFT=""
# The running server's log, which a failure shows the end of.
SERVER_LOG=""
SERVER_PID=""
SMTP_PID=""

e2e_init() {
  E2E_NAME=$1
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  E2E_STARTED=$SECONDS
  trap stop_server EXIT
}

e2e_scenario() {
  E2E_SCENARIO=$1
  E2E_STARTED=$SECONDS
}

step() {
  if [ -n "$E2E_SCENARIO" ]; then
    echo "$E2E_NAME [$E2E_SCENARIO +$((SECONDS - E2E_STARTED))s]: $*"
  else
    echo "$E2E_NAME +$((SECONDS - E2E_STARTED))s: $*"
  fi
}

fail() {
  local who=$E2E_NAME
  [ -n "$E2E_SCENARIO" ] && who="$E2E_NAME [$E2E_SCENARIO]"
  echo "$who: FAIL: $*" >&2
  if [ -n "${SERVER_LOG:-}" ] && [ -f "$SERVER_LOG" ]; then
    echo "--- server log" >&2
    tail -n 40 "$SERVER_LOG" >&2
  fi
  [ -n "$E2E_LEFT" ] && echo "$who: the app is in $E2E_LEFT" >&2
  exit 1
}

# `expect_equal WHAT EXPECTED ACTUAL`
expect_equal() {
  [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"
}

# `expect_contains WHAT NEEDLE HAYSTACK`
expect_contains() {
  case "$3" in
    *"$2"*) ;;
    *) fail "$1: no '$2' in: $(printf '%s' "$3" | head -c 400)" ;;
  esac
}

# `expect_header WHAT REGEXP FILE`
expect_header() {
  grep -qi "$2" "$3" || { cat "$3" >&2; fail "$1: no header matching $2"; }
}

# The functions are defined here and called by the scripts.
# shellcheck disable=SC2317
e2e_use_cli() {
  case "${CYBERTRAIN_E2E_CLI:-checkout}" in
    checkout)
      cybertrain() {
        ruby -I"$ROOT" "$ROOT/exe/cybertrain" "$@"
      }
      ;;
    gem)
      command -v cybertrain > /dev/null || { echo "$E2E_NAME: CYBERTRAIN_E2E_CLI=gem, but no cybertrain on PATH" >&2; exit 2; }
      echo "$E2E_NAME: the installed gem's CLI, $(command -v cybertrain)"
      cybertrain() {
        command cybertrain "$@"
      }
      ;;
    *)
      echo "$E2E_NAME: CYBERTRAIN_E2E_CLI is checkout or gem, not $CYBERTRAIN_E2E_CLI" >&2
      exit 2
      ;;
  esac
}

# `e2e_workdir NAME`: prints the new directory's path.
e2e_workdir() {
  mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"
}

free_port() {
  ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; server.close'
}

start_server() {
  SERVER_LOG=$1
  shift
  "$@" > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
}

wait_for_up() {
  local up=""
  for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "$1/up.html" 2>/dev/null; then
      up=yes
      break
    fi
    sleep 0.5
  done
  [ -n "$up" ] || fail "the server did not answer on port $2"
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  if [ -n "$SMTP_PID" ]; then
    kill "$SMTP_PID" 2>/dev/null || true
    wait "$SMTP_PID" 2>/dev/null || true
    SMTP_PID=""
  fi
}

# The authenticity_token of the first form in a page.
form_token() {
  printf '%s' "$1" | sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p' | head -n 1
}

# `post_status JAR URL FIELD...`: POSTs the url-encoded fields with the
# cookie jar, and prints the status and the redirect.
post_status() {
  local jar=$1 url=$2
  shift 2
  local args=()
  for field in "$@"; do
    args+=(--data-urlencode "$field")
  done
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$jar" -b "$jar" "${args[@]}" "$url"
}

# `same_tree WHAT A B [-x PATH | -r SED]...`: directories A and B must hold
# the same files (regular files and symbolic links, by their path relative
# to the directory, `./...`) with the same bytes; directories themselves,
# empty ones included, are not compared. `-x PATH` leaves that path out of
# both; `-r SED` rewrites every path through the sed expression before the
# two lists are matched (for a name that differs by design, such as a
# timestamp), and each rewritten name must stand for one file on each side.
# Every difference is listed before the failure: the paths only one side
# has, then the files whose bytes differ, each with a diff.
same_tree() {
  local what=$1 a=$2 b=$3
  shift 3
  local excludes=(-e "") renames=(-e "")
  while [ $# -gt 0 ]; do
    case "$1" in
      -x) excludes+=(-e "$2") ;;
      -r) renames+=(-e "$2") ;;
      *) fail "same_tree: $1 is not -x or -r" ;;
    esac
    shift 2
  done
  local tab index_a index_b
  tab=$(printf '\t')
  index_a=$(mktemp)
  index_b=$(mktemp)
  tree_index "$a" > "$index_a"
  tree_index "$b" > "$index_b"
  local problems="" dup only name pa pb
  dup=$(cut -f 1 "$index_a" | uniq -d)
  [ -z "$dup" ] || problems+="more than one file in $a is named: $dup"$'\n'
  dup=$(cut -f 1 "$index_b" | uniq -d)
  [ -z "$dup" ] || problems+="more than one file in $b is named: $dup"$'\n'
  only=$(LC_ALL=C comm -3 <(cut -f 1 "$index_a") <(cut -f 1 "$index_b"))
  [ -z "$only" ] || problems+="only in $a (flush left) or in $b (indented):"$'\n'"$only"$'\n'
  while IFS=$'\t' read -r name pa pb; do
    if ! cmp -s "$a/$pa" "$b/$pb"; then
      # diff exits 1 on a difference: `|| true`, or set -e would end the
      # script here, before fail.
      problems+="differs: $name ($pa, $pb):"$'\n'"$(diff -u "$a/$pa" "$b/$pb" | head -n 40 || true)"$'\n'
    fi
  done < <(LC_ALL=C join -t "$tab" "$index_a" "$index_b")
  rm -f "$index_a" "$index_b"
  if [ -n "$problems" ]; then
    printf '%s' "$problems" >&2
    fail "$what: the trees differ (above)"
  fi
}

# same_tree's list of one directory: NAME<TAB>PATH a line, sorted by NAME,
# the path after the renames (excludes and renames are same_tree's locals;
# the empty -e of each matches nothing and changes nothing).
tree_index() {
  local path
  (cd "$1" && find . \( -type f -o -type l \)) | { grep -vxF "${excludes[@]}" || true; } |
    while IFS= read -r path; do
      printf '%s\t%s\n' "$(printf '%s\n' "$path" | sed "${renames[@]}")" "$path"
    done | LC_ALL=C sort -t "$(printf '\t')" -k 1,1
}
