#!/bin/sh
# Step 1: a git dependency of a library, reached through a path dependency of an app.
# usage: [PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH] sh gitdep.sh WORKDIR
# WORKDIR must be a new or empty directory outside any repository.
set -e
w=$(cd "$1" && pwd)
cd "$w"
spin new demo-lib --lib >/dev/null
mkdir demo-lib/demo-lib
printf 'require "demo-lib/a"\n' > demo-lib/demo-lib.rb
printf 'module DemoLib\n  def self.hello\n    "hello from demo-lib"\n  end\nend\n' > demo-lib/demo-lib/a.rb
(cd demo-lib && git add -A && git -c user.email=a@b -c user.name=x commit -qm init && git tag v0.0.1)
git clone -q --bare demo-lib demo-lib.git
spin new mid --lib >/dev/null
mkdir mid/mid
printf '[package]\nname = "mid"\nversion = "0.1.0"\n\n[dependencies]\ndemo-lib = { git = "file://%s/demo-lib.git", ref = "v0.0.1" }\n' "$w" > mid/spin.toml
printf 'require "mid/b"\n' > mid/mid.rb
printf 'require "demo-lib/a"\n\nmodule Mid\n  def self.greet\n    DemoLib.hello + " via mid"\n  end\nend\n' > mid/mid/b.rb
spin new app >/dev/null
printf '[package]\nname = "app"\nversion = "0.0.0"\n\n[dependencies]\nmid = { path = "../mid" }\n' > app/spin.toml
printf 'require "mid"\nputs Mid.greet\n' > app/bin/app.rb
mkdir -p app/test
cp app/bin/app.rb app/test/t.rb
cd app
spin lock
cat spin.lock
spin build
./build/bin/app
spin test
spin list --json
