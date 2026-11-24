#!/bin/sh
# Compile and run every program in this directory under the compiler first on PATH.
# usage: [PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH] sh run.sh [outdir]
cd "$(dirname "$0")" || exit 1
out=${1:-${TMPDIR:-/tmp}/step3-out}
mkdir -p "$out"
spinel --version 2>&1 | head -1
for f in class_alias reopen_alias reopen_main_alias reopen_main_real module_alias const_reopen_alias const_reopen_real const_module_level const_original other_members; do
  echo "== $f"
  if spinel -I . $f.rb -o "$out/$f" 2>&1 | tail -15; then :; fi
  if [ -x "$out/$f" ]; then "$out/$f"; else echo "NO BINARY"; fi
done
