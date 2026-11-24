# What script/auth-e2e's scenarios share, sourced after lib.sh: the
# build-and-test of an app, the SMTP receiver, and the copies of
# test/fixtures/auth_04_app the upgrade04 scenarios start from.

# shellcheck shell=bash

# `start_smtp_receiver DIR COUNT`: the framework's test SMTP receiver
# (script/e2e.d/smtp_receiver.rb), in the background, for COUNT messages;
# its port lands in DIR/smtp.port, each message (Subject, To, a blank line,
# the text part) in DIR/mail-N.txt as it arrives (await_mail N waits for it).
start_smtp_receiver() {
  ruby -I"$ROOT" "$ROOT/script/e2e.d/smtp_receiver.rb" "$1/smtp.port" "$1/mail" "$2" > "$1/smtp.log" 2>&1 &
  # shellcheck disable=SC2034 # lib.sh's stop_server reads it
  SMTP_PID=$!
  for _ in $(seq 1 40); do
    [ -f "$1/smtp.port" ] && return 0
    sleep 0.25
  done
  fail "the SMTP receiver did not start"
}

# `await_mail N`: waits (at most two minutes) for the receiver's Nth message,
# DIR/mail-N.txt in the current directory.
await_mail() {
  for _ in $(seq 1 240); do
    [ -f "mail-$1.txt" ] && return 0
    sleep 0.5
  done
  cat smtp.log >&2
  fail "mail $1 did not reach the SMTP receiver"
}

# In the app's directory: db migrate, build, gen --check, then every test
# the app has, through `cybertrain test` (gen, one compile, one run).
build_and_test() {
  step "db migrate, db status"
  cybertrain db migrate > migrate.log 2>&1 || { cat migrate.log >&2; fail "db migrate"; }
  cybertrain db status > db-status.log 2>&1 || { cat db-status.log >&2; fail "db status"; }
  step "cybertrain build"
  cybertrain build > build.log 2>&1 || { tail -n 40 build.log >&2; fail "build"; }
  test -x dist/shop || fail "no dist/shop"
  step "gen --check"
  SPIN_DEBUG=1 cybertrain spin run gen -- --check > gen-check.log 2>&1 || { cat gen-check.log >&2; fail "spin run gen -- --check"; }
  step "cybertrain test"
  cybertrain test > test.log 2>&1 || { grep -v '^  ok ' test.log | tail -n 60 >&2; fail "cybertrain test"; }
  expect_contains "cybertrain test" " 0 failures" "$(tail -n 3 test.log)"
}

# The upgrade04 scenarios, each in its own copy of the fixture under $WORK:
# none reads what another left behind.
FIXTURE_04="$ROOT/test/fixtures/auth_04_app"

# `copy_04_app NAME`: test/fixtures/auth_04_app copied to $WORK/NAME, its
# framework this checkout; the current directory becomes the copy.
copy_04_app() {
  cp -R "$FIXTURE_04" "$WORK/$1"
  cd "$WORK/$1" || exit 1
  mkdir -p tmp
  sed -i.bak "s#path = \"../../..\"#path = \"$ROOT\"#" spin.toml spin.lock
  rm -f spin.toml.bak spin.lock.bak
  grep -qF "path = \"$ROOT\"" spin.toml || fail "spin.toml of $1 does not name $ROOT"
}

# The generated tests every upgraded copy must have, and pass.
UPGRADE_TESTS="test/test_helper.rb test/fixtures/users.yml test/support/session_test_helper.rb test/models/user_test.rb
  test/controllers/sessions_controller_test.rb test/controllers/registrations_controller_test.rb
  test/controllers/passwords_controller_test.rb test/controllers/accounts_controller_test.rb
  test/integration/remember_me_test.rb test/integration/lockout_test.rb test/integration/admin_test.rb"

expect_upgrade_tests() {
  for f in $UPGRADE_TESTS; do
    test -f "$f" || fail "no $f"
  done
}

# `delete_replaced OUTPUT`: deletes the files the generator's output names
# as replaced by its class-form tests (`manual  <path>: replaced by ...;
# delete it`), as its user is told to.
delete_replaced() {
  local names
  names=$(sed -n 's/^manual  \([^:]*\): replaced by .*; delete it$/\1/p' "$1")
  [ -n "$names" ] || fail "no replaced test files named in $1"
  for f in $names; do
    test -f "$f" || fail "$f, named as replaced, is not there"
    rm "$f"
  done
}
