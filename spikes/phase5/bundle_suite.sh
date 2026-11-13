#!/bin/bash
# Phase 5a spike, item 6 (spec section 16): the framework's own top-level-
# form test programs (test/*.rb) concatenated into one program, to see how
# many compile together, what stops the rest (rules 41, 63, duplicate
# top-level names), and the compile time and binary size against D34's
# 14-minute full compile. A record, not a test; nothing in phase 5 depends
# on the number (spec section 17).
#
# Each file's `Cybertrain::Test.run!` line is dropped, its
# `require_relative "x"` is rebased onto test/ (the bundle is written
# elsewhere), and the files are written one after the other, wrapped in
# nothing, with one `Cybertrain::Test.run!` at the end. FILES (default: every
# test/*.rb, sorted) narrows the set: FILES="test/a.rb test/b.rb".
#
# With ITERATE=1, each refusal's line is mapped back to its file (the
# `#@bundled-file@ test/x.rb` markers), that file is dropped, and the bundle is
# built again, until it builds or MAX_ROUNDS (default 60) is reached; the
# dropped files and their refusals are listed in OUT_DIR/dropped.txt.
#
# usage (from the repository root, Spinel 2026.11.04.7026 on PATH):
#   spikes/phase5/bundle_suite.sh [OUT_DIR]           (default $TMPDIR/bundle)
#   ITERATE=1 spikes/phase5/bundle_suite.sh [OUT_DIR]
#
# Run (Spinel 2026.11.04.7026, 2026-11-12, from the repository root, a
# 4-vCPU 16 GB cloud machine shared with other builds):
#   ITERATE=1 spikes/phase5/bundle_suite.sh $TMPDIR/bundle
# Output: 195 files, 62,441 lines; 88 top-level method names defined in
# more than one file and 36 top-level constants assigned in more than one.
# Nine files were refused one at a time, each in 32 to 45 s, all for the
# same reason: a class of one name defined with two superclasses ("superclass
# mismatch for class PostsController (Controller here, ApplicationController
# at line 12158)"), the test programs' own PostsController / PagesController
# / AccountsController beside test/fixtures/gen_app's: controller_views,
# app_helpers, application, dev_application, force_ssl, http_caching,
# i18n_views, multipart_app, rate_limit. The remaining 186 files (59,287
# lines; 84 duplicate method names, 34 duplicate constants) pass every
# check that refuses early: duplicate top-level methods and constants are
# not refused (the later definition wins, as in CRuby). Their type
# analysis then ran for 326 s in the iterating run and 772 s in a second,
# single run (FILES=<the 186>), at least 1.76 GB resident when sampled, and
# was killed by the kernel's OOM killer both times, with other builds
# holding most of the machine's memory. So no compile time or binary size
# was measured; whether rules 41 / 63 stop the 186 is not known. A
# dedicated machine is needed for the figure (D34's full compile: 14 min).
set -u
root=$(pwd)
out=${1:-${TMPDIR:-/tmp}/bundle}
mkdir -p "$out"
files=${FILES:-$(ls test/*.rb | sort)}
bundle="$out/all_tests.rb"
: > "$bundle"
n=0
for f in $files; do
  n=$((n + 1))
  echo "#@bundled-file@ $f" >> "$bundle"
  sed -e '/^[[:space:]]*Cybertrain::Test\.run![[:space:]]*$/d' \
      -e "s|^\\([[:space:]]*\\)require_relative \"|\\1require_relative \"$root/test/|" \
      "$f" >> "$bundle"
  echo >> "$bundle"
done
echo "Cybertrain::Test.run!" >> "$bundle"
echo "$n files, $(wc -l < "$bundle") lines in $bundle"

# Top-level names defined in more than one file (a later `def` replaces an
# earlier one under CRuby; the bundle of spec section 8 refuses them).
grep -H -E '^def [a-z_][A-Za-z0-9_]*[?!]?' $files | sed -E 's/^([^:]*):def ([a-z_][A-Za-z0-9_]*[?!]?).*/\2 \1/' |
  sort | awk '{c[$1]++; f[$1]=f[$1]" "$2} END {for (k in c) if (c[k] > 1) d++; print d+0, "top-level method names defined in more than one file"}'
grep -H -E '^[A-Z][A-Z0-9_]* *=' $files | sed -E 's/^([^:]*):([A-Z][A-Z0-9_]*).*/\2 \1/' |
  sort | awk '{c[$1]++} END {for (k in c) if (c[k] > 1) d++; print d+0, "top-level constants assigned in more than one file"}'

flags="--strict-require -I $root"
start=$(date +%s)
spinel $flags "$bundle" -o "$out/all_tests" > "$out/build.log" 2>&1
status=$?
end=$(date +%s)
echo "build status $status in $((end - start)) s"
[ -f "$out/all_tests" ] && echo "binary $(stat -c %s "$out/all_tests") bytes"
grep -E 'error|refus|spinel:' "$out/build.log" | head -40

[ "${ITERATE:-0}" = "1" ] || exit $status
rounds=0
: > "$out/dropped.txt"
while [ $status -ne 0 ] && [ $rounds -lt "${MAX_ROUNDS:-60}" ]; do
  rounds=$((rounds + 1))
  # The refusal's line in the bundle, or, when it is in a file the bundle
  # requires, the bundle line it names ("... at line N").
  msg=$(grep -m1 -E "^spinel: " "$out/build.log")
  line=$(echo "$msg" | grep -oE "all_tests\.rb:[0-9]+:" | head -1 | grep -oE "[0-9]+")
  [ -z "$line" ] && line=$(echo "$msg" | grep -oE "at line [0-9]+" | head -1 | grep -oE "[0-9]+")
  if [ -z "$line" ]; then
    echo "round $rounds: a refusal with no line; stopping"; tail -5 "$out/build.log"; break
  fi
  bad=$(head -n "$line" "$bundle" | grep '^#@bundled-file@ ' | tail -1 | sed 's/^#@bundled-file@ //')
  echo "$bad: $msg" >> "$out/dropped.txt"
  files=$(echo "$files" | tr ' ' '\n' | grep -v -x "$bad")
  : > "$bundle"
  for f in $files; do
    echo "#@bundled-file@ $f" >> "$bundle"
    sed -e '/^[[:space:]]*Cybertrain::Test\.run![[:space:]]*$/d' \
        -e "s|^\\([[:space:]]*\\)require_relative \"|\\1require_relative \"$root/test/|" \
        "$f" >> "$bundle"
    echo >> "$bundle"
  done
  echo "Cybertrain::Test.run!" >> "$bundle"
  start=$(date +%s)
  spinel $flags "$bundle" -o "$out/all_tests" > "$out/build.log" 2>&1
  status=$?
  end=$(date +%s)
  echo "round $rounds: dropped $bad; $(echo "$files" | wc -w) files; build status $status in $((end - start)) s"
done
[ -f "$out/all_tests" ] && [ $status -eq 0 ] && echo "binary $(stat -c %s "$out/all_tests") bytes"
