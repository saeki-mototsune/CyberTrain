#!/bin/bash
# Phase 5b spike, item 9 (spec section 16; plan D3): the logger's lock
# under two workers. A record, not a test.
#
# What it asks: does a Logger whose `log` builds the line and does one
# `STDOUT.write` + `flush` inside `Logger::LOCK.synchronize`
# (logger_locked.rb) serve examples/blog, request log on, on two cores with
# SPINEL_WORKERS=2, as well as the same Logger without the lock
# (logger_unlocked.rb)? Rule 57 found a lock taken on every request
# stalling requests for seconds in this configuration.
# Pass: all five locked runs complete with no stall (a request over 1 s)
# and no dead server, and their median requests per second is at least 95%
# of the unlocked median. Fallback (D3): no lock, each line one write cut
# to 4,096 bytes.
#
# What it does: extracts the framework at FRAMEWORK_REV (git archive:
# cybertrain/, cybertrain.rb,
# spin.toml, the gemspec, bin/, exe/) and examples/blog into
# $TMPDIR/logger_lock/<variant>/, the variant's Logger over
# cybertrain/logger.rb, and builds the blog there with `cybertrain build`
# (each build under the shared build lock); migrates a fresh database and
# seeds 30 articles and 10 comments on the first with sqlite3; then, under
# the lock, serves both variants (`taskset -c 0,1`, SPINEL_WORKERS=2,
# CYBERTRAIN_LOG_LEVEL=info, which at 19668bc nothing reads yet: info is
# production's default, so the request log is on either way; stdout into
# a pipe read by awk, which counts the lines and keeps the first four),
# five runs each, alternating locked/unlocked so drift on a shared machine
# falls on both. bench/run builds its own copy of the blog, so it cannot
# serve these variants; the load is wrk against them when wrk is
# installed, otherwise load.rb (CRuby, on CPUs 2-3): 8 keep-alive
# connections from 8 threads (two processes of four, so the client is not
# held to one core by CRuby's lock), GET / and /articles/1 in turn, 10 s a
# run after a 3 s warm-up, a request over 1 s counted as a stall. Each run
# line also gives the server's CPU use over the run (of 200%) and whether
# it is alive and answering.
#
# usage (from the repository root, TMPDIR set to a scratch directory):
#   spikes/phase5/logger_lock/run.sh build locked
#   spikes/phase5/logger_lock/run.sh build unlocked
#   spikes/phase5/logger_lock/run.sh bench
# Output (2026-11-13, framework 19668bc, Spinel 2026.11.04.7026, a shared
# 4-vCPU cloud machine, wrk not installed; builds 165 s and 163 s,
# 9,039,408 and 9,039,360 bytes; `nm` shows cst_Cybertrain__Logger__LOCK
# in the locked binary only):
#   run 1 locked: rps 1565 stalls 0 errors 0 max_ms 21.6 ... server_cpu 185% alive yes
#   run 1 unlocked: rps 1558 stalls 0 errors 0 max_ms 24.1 ... server_cpu 184% alive yes
#   run 2 locked: rps 1590 stalls 0 errors 0 max_ms 27.1 ... server_cpu 184% alive yes
#   run 2 unlocked: rps 1575 stalls 0 errors 0 max_ms 28.4 ... server_cpu 184% alive yes
#   run 3 locked: rps 1716 stalls 0 errors 0 max_ms 24.7 ... server_cpu 184% alive yes
#   run 3 unlocked: rps 1590 stalls 0 errors 0 max_ms 34.8 ... server_cpu 185% alive yes
#   run 4 locked: rps 1572 stalls 0 errors 0 max_ms 32.3 ... server_cpu 185% alive yes
#   run 4 unlocked: rps 1581 stalls 0 errors 0 max_ms 25.4 ... server_cpu 184% alive yes
#   run 5 locked: rps 1639 stalls 0 errors 0 max_ms 23.6 ... server_cpu 184% alive yes
#   run 5 unlocked: rps 1617 stalls 0 errors 0 max_ms 27.6 ... server_cpu 185% alive yes
#   locked: 170574 lines on stdout; stderr 0 lines
#   unlocked: 167986 lines on stdout; stderr 0 lines
# (every answer a 200; "..." is the status codes per loader process; the
# first stdout lines are the boot banner, then two request lines per
# request.) Medians: locked 1,590 rps, unlocked 1,581 rps (100.6%); no
# stall, no error, no dead server; the server used its two cores (184 to
# 185%), so the load was server-bound, not client-bound.
# Verdict: PASS, no fallback: D3's Logger::LOCK around the one write and
# flush stays. A likely difference from rule 57 (not measured apart): the
# lock is held only for the write of a line already built, not around
# other work. Not measured: wrk's higher request rates, where rule 57's
# stalls showed (bench/run with wrk, 16 connections). A first bench run stopped in its summary
# step (a script error) and left both servers running; the EXIT trap now
# stops them.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HERE="$ROOT/spikes/phase5/logger_lock"
WORK="${TMPDIR:-$ROOT/tmp}/logger_lock"
mkdir -p "$WORK"
LOCK="${BUILD_LOCK:-$WORK/build.lock}"
# The framework the measurement used. A later framework calls Logger
# methods the two spike Loggers do not have.
FRAMEWORK_REV="${FRAMEWORK_REV:-19668bc}"
SECONDS_PER_RUN="${SECONDS_PER_RUN:-10}"
RUNS="${RUNS:-5}"
SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')

build() {
  local variant=$1 fw="$WORK/$1"
  rm -rf "$fw"
  mkdir -p "$fw/examples"
  git -C "$ROOT" archive "$FRAMEWORK_REV" cybertrain cybertrain.rb spin.toml cybertrain.gemspec bin exe examples/blog \
    | tar -xf - -C "$fw"
  cp "$HERE/logger_$variant.rb" "$fw/cybertrain/logger.rb"
  local started=$(date +%s)
  (cd "$fw/examples/blog" && flock "$LOCK" ruby -I"$fw" "$fw/bin/cybertrain.rb" build)
  echo "build $variant: $(( $(date +%s) - started )) s (with the wait for the lock), $(stat -c %s "$fw/examples/blog/dist/blog") bytes"
}

prepare() {
  local variant=$1 run="$WORK/$1/run"
  rm -rf "$run"
  mkdir -p "$run/storage" "$run/tmp"
  cp "$WORK/$variant/examples/blog/dist/blog" "$run/"
  cp -r "$WORK/$variant/examples/blog/dist/public" "$run/"
  (cd "$run" && CYBERTRAIN_ENV=production CYBERTRAIN_SECRET_KEY_BASE=$SECRET ./blog migrate > /dev/null)
  local db="$run/storage/production.sqlite3" t="2026-11-13 00:00:00.000000"
  {
    echo "BEGIN;"
    for i in $(seq 1 30); do
      echo "INSERT INTO articles (title, body, created_at, updated_at) VALUES ('Article $i', 'Body $i of an article.', '$t', '$t');"
    done
    for j in $(seq 1 10); do
      echo "INSERT INTO comments (commenter, body, article_id, created_at, updated_at) VALUES ('Reader $j', 'Comment $j.', 1, '$t', '$t');"
    done
    echo "COMMIT;"
  } | sqlite3 "$db"
}

cpu_ticks() { awk '{print $14 + $15}' "/proc/$1/stat"; }

# serve VARIANT PORT: starts the server, waits for its first answer; sets PID.
serve() {
  local variant=$1 port=$2 run="$WORK/$1/run"
  rm -f "$run/stdout.fifo"
  mkfifo "$run/stdout.fifo"
  awk -v s="$run/sample.txt" -v l="$run/lines.txt" 'NR <= 4 { print > s } END { print NR > l }' < "$run/stdout.fifo" &
  (cd "$run" && CYBERTRAIN_ENV=production CYBERTRAIN_SECRET_KEY_BASE=$SECRET CYBERTRAIN_LOG_LEVEL=info \
     SPINEL_WORKERS=2 PORT=$port exec taskset -c 0,1 ./blog > stdout.fifo 2> stderr.log) &
  PID=$!
  SERVER_PIDS="$SERVER_PIDS $PID"
  for _ in $(seq 1 500); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" && return 0
    sleep 0.02
  done
  echo "server $variant did not answer"; exit 1
}

load() {
  local port=$1 secs=$2
  if command -v wrk > /dev/null; then
    taskset -c 2,3 wrk -t2 -c8 -d"${secs}s" --latency "http://127.0.0.1:$port/" | grep -E "Requests/sec|Socket errors|Latency  "
  else
    taskset -c 2,3 ruby "$HERE/load.rb" "$port" "$secs" 4 > "$WORK/load.a" &
    local a=$!
    taskset -c 2,3 ruby "$HERE/load.rb" "$port" "$secs" 4 > "$WORK/load.b"
    wait $a
    ruby -e 'a, b = ARGV[0, 2].map { |f| File.read(f) }
      n = a[/requests (\d+)/, 1].to_i + b[/requests (\d+)/, 1].to_i
      s = a[/stalls (\d+)/, 1].to_i + b[/stalls (\d+)/, 1].to_i
      e = a[/errors (\d+)/, 1].to_i + b[/errors (\d+)/, 1].to_i
      m = [a[/max_ms ([\d.]+)/, 1].to_f, b[/max_ms ([\d.]+)/, 1].to_f].max
      puts format("rps %.0f stalls %d errors %d max_ms %.1f codes %s %s", n / ARGV[2].to_f, s, e, m,
                  a[/codes (.*)/, 1], b[/codes (.*)/, 1])' "$WORK/load.a" "$WORK/load.b" "$secs"
  fi
}

bench() {
  if command -v wrk > /dev/null; then
    echo "wrk is installed: the measure is bench/run --configs 2cpu --runs $RUNS, run separately"
  else
    echo "wrk is not installed: load.rb, 8 connections from 8 threads in two CRuby processes"
  fi
  local v
  for v in locked unlocked; do prepare "$v"; done
  # Neither server outlives a failed step, a failed start included.
  SERVER_PIDS=""
  trap 'kill $SERVER_PIDS 2> /dev/null || true' EXIT
  serve locked 3301; local pid_locked=$PID
  serve unlocked 3302; local pid_unlocked=$PID
  for v in locked unlocked; do
    local port=3301; [ "$v" = unlocked ] && port=3302
    load "$port" 3 > /dev/null  # warm-up
  done
  for r in $(seq 1 "$RUNS"); do
    for v in locked unlocked; do
      local port=3301 pid=$pid_locked
      [ "$v" = unlocked ] && port=3302 pid=$pid_unlocked
      local before=$(cpu_ticks "$pid")
      local line=$(load "$port" "$SECONDS_PER_RUN")
      local after=$(cpu_ticks "$pid")
      local alive=yes; kill -0 "$pid" 2> /dev/null || alive=NO
      curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/" || alive="$alive, no answer"
      echo "run $r $v: $line server_cpu $(( (after - before) * 100 / $(getconf CLK_TCK) / SECONDS_PER_RUN ))% alive $alive"
    done
  done
  kill "$pid_locked" "$pid_unlocked"
  wait 2> /dev/null || true
  for v in locked unlocked; do
    echo "$v: $(cat "$WORK/$v/run/lines.txt") lines on stdout; stderr $(wc -l < "$WORK/$v/run/stderr.log") lines; the first:"
    sed "s/^/  /" "$WORK/$v/run/sample.txt"
  done
}

case "${1:-}" in
  build) build "$2" ;;
  bench) flock "$LOCK" "$0" bench-locked ;;
  bench-locked) bench ;;
  *) echo "usage: $0 build locked|unlocked | bench"; exit 2 ;;
esac
