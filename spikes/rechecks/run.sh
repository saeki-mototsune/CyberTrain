#!/usr/bin/env bash
# Runs every spikes/rechecks/*.rb under CRuby and Spinel and compares both
# outputs with the reviewed .expected file. See README.md in this directory.
#
# Every probe is run even after one fails, so one regression does not hide
# the others; the exit status is 1 when any probe failed. Outputs go to a
# fresh directory outside the repository (NOTES rule 98), printed first so
# the diagnostics can be found even when the run is interrupted.
#
# usage: spikes/rechecks/run.sh        (from any directory)
#   RECHECK_TIMEOUT=180  seconds allowed for each compile and each run
set -u

cd "$(dirname "$0")/../.." || exit 2
limit=${RECHECK_TIMEOUT:-180}
# GNU timeout; macOS has it as gtimeout (Homebrew coreutils) or not at all.
if command -v timeout > /dev/null; then bound="timeout $limit"
elif command -v gtimeout > /dev/null; then bound="gtimeout $limit"
else bound=""; echo "note: no timeout command, steps are not bounded"
fi
out=$(mktemp -d "${TMPDIR:-/tmp}/cybertrain-rechecks.XXXXXX") || exit 2
printf 'Recheck outputs: %s\n' "$out"
spinel --version
ruby --version

failed=""
for source in spikes/rechecks/*.rb; do
  name=$(basename "$source" .rb)
  ok=1
  if ! $bound ruby "$source" > "$out/$name.ruby.txt" 2>&1 ||
     ! diff -u "$source.expected" "$out/$name.ruby.txt"; then
    echo "FAIL $name: CRuby output differs from $source.expected"
    ok=0
  fi
  if ! $bound spinel "$source" -O 0 -o "$out/$name" > "$out/$name.compile.txt" 2>&1; then
    echo "FAIL $name: compile failed or timed out, see $out/$name.compile.txt"
    ok=0
  else
    if grep -qv -- ' -> ' "$out/$name.compile.txt"; then
      echo "warn $name: compiler output to review in $out/$name.compile.txt"
    fi
    if ! $bound "$out/$name" > "$out/$name.spinel.txt" 2>&1 ||
       ! diff -u "$source.expected" "$out/$name.spinel.txt"; then
      echo "FAIL $name: Spinel output differs, see $out/$name.spinel.txt"
      ok=0
    fi
  fi
  if [ "$ok" = 1 ]; then echo "ok   $name"; else failed="$failed $name"; fi
done

if [ -n "$failed" ]; then
  printf 'Failed:%s (outputs kept in %s)\n' "$failed" "$out"
  exit 1
fi
printf 'All rechecks match. Outputs: %s\n' "$out"
