# script/auth-e2e's upgrade04 scenarios, sourced after lib.sh and auth.sh:
# today's generator over test/fixtures/auth_04_app (a sign-up app v0.4.1
# generated), each scenario in its own copy under $WORK (copy_04_app).
#
#   upgrade04_patch        the printed diffs applied with patch -p1, 0.4's
#                          replaced tests deleted (upgrade04_patched_copy),
#                          then build_and_test
#   upgrade04_force        the same with --force, which deletes them itself;
#                          not built: its add-columns migration's version is
#                          checked to be its own and the latest, then its
#                          tree is compared, file for file, with a patched
#                          copy's, which upgrade04_patch builds and tests
#                          (the two are one leg)
#   upgrade04_confirmable  --confirmable over a copy migrated by 0.4's
#                          migrations with a user in it

# shellcheck shell=bash

# `upgrade04_patched_copy NAME`: a copy of the fixture, today's generator
# run over it, its printed diffs applied with patch and the test files it
# names as replaced deleted; nothing built.
upgrade04_patched_copy() {
  step "a copy of the 0.4 app, run over and patched ($1)"
  copy_04_app "$1"
  cybertrain generate authentication > generate.out 2>&1 || { cat generate.out >&2; fail "generate authentication"; }
  # Left alone until patched: the files 0.4 wrote that today's generator
  # writes otherwise, and the 0.4 block in ApplicationController.
  for f in app/controllers/application_controller.rb app/controllers/sessions_controller.rb app/models/user.rb \
           app/views/sessions/new.html.erb test/authentication.rb test/support/app_test.rb; do
    cmp -s "$f" "$FIXTURE_04/$f" || fail "$f changed before the diffs were applied"
  done
  grep -q '^manual  app/controllers/application_controller.rb: ' generate.out || fail "no diff for application_controller.rb"
  grep -q '^next: apply the diffs above, or re-run with --force for files you never edited$' generate.out || fail "no closing next: line"
  ls db/migrate/*_add_authentication_columns.rb > /dev/null 2>&1 || fail "no add-columns migration"
  patch -p1 < generate.out > patch.log 2>&1 || { cat patch.log >&2; fail "patch -p1 < the generator's output"; }
  grep -q '^  include Authentication$' app/controllers/application_controller.rb || fail "patched ApplicationController does not include Authentication"
  if grep -q 'def require_authentication' app/controllers/application_controller.rb; then
    fail "patched ApplicationController still has 0.4's block"
  fi
  grep -q '^  jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication$' config/routes.rb || fail "the jobs page is not drawn after patching"
  # 0.4's top-level tests, named as replaced (patch deletes nothing).
  grep -q '^manual  test/authentication.rb: replaced by test/controllers/sessions_controller_test.rb; delete it$' generate.out || fail "test/authentication.rb is not named as replaced"
  delete_replaced generate.out
  expect_upgrade_tests
}

upgrade04_patch() {
  upgrade04_patched_copy patched
  build_and_test
}

# `expect_add_columns_version DIR`: DIR (a db/migrate) holds exactly one
# *_add_authentication_columns.rb, its 14-digit version is no other file's
# there, and it sorts after every other file's version (the migrator runs
# them in that order, and 0.4's must have run first). Fails with the
# versions otherwise.
expect_add_columns_version() {
  local dir=$1 f v version versions=""
  local adds=("$dir"/*_add_authentication_columns.rb)
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    f=${f##*/}
    versions+=" ${f%%_*}"
  done
  if [ "${#adds[@]}" -ne 1 ] || [ ! -e "${adds[0]}" ]; then
    fail "$dir: not exactly one *_add_authentication_columns.rb (versions:$versions)"
  fi
  f=${adds[0]##*/}
  version=${f%%_*}
  [[ $version =~ ^[0-9]{14}$ ]] || fail "$dir: $f's version is not 14 digits (versions:$versions)"
  for f in "$dir"/*; do
    [ "$f" != "${adds[0]}" ] || continue
    v=${f##*/}
    v=${v%%_*}
    [ "$v" != "$version" ] || fail "$dir: the add-columns migration's version $version is ${f##*/}'s too (versions:$versions)"
    [[ $v < $version ]] || fail "$dir: the add-columns migration's version $version does not sort after ${f##*/}'s, $v (versions:$versions)"
  done
}

# --force must leave the tree patch leaves: the same files with the same
# bytes, but for the generator's output and patch's log, which only the
# patched copy has, and the add-columns migration's timestamp, which is the
# second each run wrote it in. Every other difference fails. Since the
# comparison rewrites that timestamp away and no migrator runs on this
# copy, its version is checked first (expect_add_columns_version): one
# such migration, a version no other migration has, after 0.4's. The
# compiled tree is then upgrade04_patch's, so this builds nothing.
upgrade04_force() {
  step "a fresh copy, run over with --force"
  copy_04_app forced
  cybertrain generate authentication --force > generate.out 2>&1 || { cat generate.out >&2; fail "generate authentication --force"; }
  if grep -q '^manual  ' generate.out; then
    fail "--force left diffs to apply: $(grep '^manual  ' generate.out)"
  fi
  grep -q '^  include Authentication$' app/controllers/application_controller.rb || fail "--force did not include Authentication"
  test ! -e test/authentication.rb || fail "--force left 0.4's test/authentication.rb"
  test ! -e test/support/app_test.rb || fail "--force left 0.4's test/support/app_test.rb"
  expect_upgrade_tests
  upgrade04_patched_copy reference
  step "the --force copy's add-columns migration: its own version, the latest"
  expect_add_columns_version "$WORK/forced/db/migrate"
  step "the --force copy against the patched one"
  same_tree "--force against patch" "$WORK/reference" "$WORK/forced" -x ./generate.out -x ./patch.log \
    -r 's#^\./db/migrate/[0-9]\{14\}_add_authentication_columns\.rb$#./db/migrate/TIMESTAMP_add_authentication_columns.rb#'
}

upgrade04_confirmable() {
  step "a copy with a 0.4 user in its database, run over with --confirmable"
  copy_04_app populated
  cybertrain db migrate > migrate-04.log 2>&1 || { cat migrate-04.log >&2; fail "db migrate (0.4's migrations)"; }
  local db=storage/development.sqlite3
  test -f "$db" || fail "no $db after 0.4's migrations"
  sqlite3 "$db" "INSERT INTO users (email_address, password_digest, created_at, updated_at) VALUES ('old@example.com', 'x', '2026-09-25 12:00:00.000000', '2026-09-25 12:00:00.000000')" \
    || fail "insert a 0.4 user"
  cybertrain generate authentication --confirmable > generate.out 2>&1 || { cat generate.out >&2; fail "generate authentication --confirmable"; }
  grep -q "confirmed_at = COALESCE(created_at" db/migrate/*_add_authentication_columns.rb || fail "the add-columns migration does not confirm the users there"
  grep -q '^IMPORTANT: app/controllers/sessions_controller.rb: ' generate.out || fail "no closing IMPORTANT line for sessions_controller.rb"
  # Every diff but the sessions controller's: what a user whose patch
  # rejected that hunk (an edited file) is left with.
  awk '/^manual  [^ ]*: / { skip = ($2 == "app/controllers/sessions_controller.rb:") } !skip' generate.out > others.diff
  awk '/^manual  [^ ]*: / { keep = ($2 == "app/controllers/sessions_controller.rb:") } keep' generate.out > sessions.diff
  grep -q '^+++ b/app/controllers/sessions_controller.rb$' sessions.diff || fail "no sessions controller diff to hold back"
  if grep -q '^+++ b/app/controllers/sessions_controller.rb$' others.diff; then
    fail "the sessions controller diff was not held back"
  fi
  patch -p1 < others.diff > patch.log 2>&1 || { cat patch.log >&2; fail "patch -p1 < every diff but the sessions controller's"; }
  cmp -s app/controllers/sessions_controller.rb "$FIXTURE_04/app/controllers/sessions_controller.rb" || fail "the sessions controller changed"
  cybertrain db migrate > migrate.log 2>&1 || { cat migrate.log >&2; fail "db migrate (the add-columns migration)"; }
  expect_equal "the 0.4 user after the migration" "old@example.com|0|0|2026-09-25 12:00:00.000000|" \
    "$(sqlite3 "$db" "SELECT email_address, admin, failed_attempts, confirmed_at, unconfirmed_email FROM users")"
  # 0.4's SessionsController#create calls start_new_session_for for any
  # right password: the concern's own check must refuse the account. Run
  # alone (-n), as the other tests need the sessions controller's diff.
  delete_replaced generate.out
  cat > test/integration/unconfirmed_backstop_test.rb <<'RUBY'
require "test_helper"

class UnconfirmedBackstopTest < ActionDispatch::IntegrationTest
  test "an unconfirmed account gets no session, whichever sessions controller asks" do
    user = User.new(email_address: "new@example.com")
    user.password = "s3cr3t-s3cr3t"
    user.save!
    assert_equal false, user.confirmed?
    post "/session", params: { email_address: "new@example.com", password: "s3cr3t-s3cr3t" }
    assert_equal 0, Session.count
    get "/session/new"
    refute response.body.include?("<span>new@example.com</span>")
    user.update_columns(confirmed_at: Time.current)
    post "/session", params: { email_address: "new@example.com", password: "s3cr3t-s3cr3t" }
    assert_equal 1, Session.count
    get "/session/new"
    assert_includes response.body, "<span>new@example.com</span>"
  end
end
RUBY
  # The one test's program compiles the app with 0.4's sessions controller;
  # its release build is not made (the fully patched copy's is, below).
  step "the one test, every diff but the sessions controller's applied"
  out=$(cybertrain test test/integration/unconfirmed_backstop_test.rb 2>&1) || { printf '%s\n' "$out" | tail -n 40 >&2; fail "an unconfirmed account signed in through 0.4's sessions controller"; }
  expect_contains "test/integration/unconfirmed_backstop_test.rb" "1 test, 5 assertions, 0 failures" "$out"

  step "the sessions controller's diff applied too: every test"
  patch -p1 < sessions.diff > patch.log 2>&1 || { cat patch.log >&2; fail "patch -p1 < the sessions controller's diff"; }
  expect_upgrade_tests
  test -f test/controllers/confirmations_controller_test.rb || fail "no test/controllers/confirmations_controller_test.rb"
  # Migrated already: the sessions controller's diff adds no migration, and
  # the database is the one checked above.
  build_check_test
}
