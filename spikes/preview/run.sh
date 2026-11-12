#!/usr/bin/env bash
# Throwaway spike (spikes/NOTES.md "CRuby preview spike, 2026-11"): copies
# examples/blog outside the repository, migrates it and starts its server
# under CRuby with spikes/preview/shim.rb, then measures the time from
# process start to the first 200 on GET /articles, and checks that a POST
# /articles with the form's CSRF token and cookie answers 303.
#
# usage: spikes/preview/run.sh [WORKDIR]     (from any directory)
#   WORKDIR  scratch directory (default: a fresh mktemp -d); never the tree
#   PORT     port to serve on (default 3999)
#   COLD=1   empty the shim's compile cache first (counts the cc runs)
set -u

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/cybertrain-preview.XXXXXX")}
port=${PORT:-3999}
mkdir -p "$work"
# Absolute: the script changes directory into the copied blog below.
work=$(cd "$work" && pwd)
export CYBERTRAIN_PREVIEW_CACHE="$work/ffi-cache"
[ "${COLD:-0}" = 1 ] && rm -rf "$CYBERTRAIN_PREVIEW_CACHE"
printf 'work: %s\n' "$work"

rm -rf "$work/blog"
cp -r "$repo/examples/blog" "$work/blog"
cd "$work/blog" || exit 2
rm -f storage/*.sqlite3*
ruby -I"$repo" -I. -r "$repo/spikes/preview/shim" bin/blog.rb migrate > "$work/migrate.log" 2>&1 || {
  cat "$work/migrate.log"; exit 1; }

if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
  echo "port $port already answers: stop that server first"; exit 2
fi
now_ms() { date +%s%3N; }
start=$(now_ms)
ruby -I"$repo" -I. -r "$repo/spikes/preview/shim" bin/blog.rb "$port" > "$work/server.log" 2>&1 &
pid=$!
trap 'kill $pid 2> /dev/null' EXIT
code=000
for _ in $(seq 1 1000); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/articles" 2> /dev/null)
  [ "$code" = 200 ] && break
  kill -0 $pid 2> /dev/null || break
  sleep 0.005
done
first=$(now_ms)
printf 'GET /articles: %s, %d ms from process start\n' "$code" $((first - start))

jar="$work/jar.txt"
rm -f "$jar"
token=$(curl -s -c "$jar" "http://127.0.0.1:$port/articles/new" |
  grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')
post=$(curl -s -b "$jar" -c "$jar" -o /dev/null -w '%{http_code} %{redirect_url}' \
  -F "authenticity_token=$token" -F 'article[title]=Spike título' \
  -F 'article[body]=A body written under CRuby through the Fiddle shim.' \
  "http://127.0.0.1:$port/articles")
printf 'POST /articles: %s\n' "$post"
show=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/articles/1")
printf 'GET /articles/1: %s\n' "$show"
[ "$code" = 200 ] && [ "${post%% *}" = 303 ] && [ "$show" = 200 ]
