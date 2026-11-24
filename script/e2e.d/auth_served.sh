# script/auth-e2e's served scenarios (signup, invite, confirmable), sourced
# after lib.sh and auth.sh: a new app with a scaffold and the generator,
# build_and_test, then its binary served and driven over HTTP, one function
# a part, in the order run_served calls them. They share run_served's
# locals (bash's are visible to the functions it calls): base, port, jar,
# reset_jar, setup_token, mails and reset_mail.

# shellcheck shell=bash

# A new app, a scaffold and `generate authentication FLAG`: the files and
# routes it writes.
served_generate() {
  step "app in $WORK"
  cd "$WORK" || exit 1
  cybertrain new shop --path "$ROOT" > new.log 2>&1 || { cat new.log >&2; fail "cybertrain new"; }
  cd shop || exit 1
  test -f spin.lock || fail "cybertrain new wrote no spin.lock"
  cybertrain generate scaffold product name:string > /dev/null || fail "generate scaffold"
  # flag is run_served's; unquoted, so that an empty one is no argument.
  # shellcheck disable=SC2086,SC2154
  cybertrain generate authentication $flag > generate.log || { cat generate.log >&2; fail "generate authentication $flag"; }
  test -f app/controllers/concerns/authentication.rb || fail "no Authentication concern"
  test -f app/mailers/passwords_mailer.rb || fail "no PasswordsMailer"
  grep -q '^  resources :passwords, param: :token, only: \[:new, :create, :edit, :update\]$' config/routes.rb || fail "no password reset routes"
  test -f app/controllers/accounts_controller.rb || fail "no AccountsController"
  grep -q '^  resource :account, only: \[:edit, :update, :destroy\]$' config/routes.rb || fail "no account route"
  grep -q '^  c.setting_string :base_url, env: "SHOP_BASE_URL", default: ""$' config/app.rb || fail "no base_url setting"
  grep -q '^  include Authentication$' app/controllers/application_controller.rb || fail "ApplicationController does not include Authentication"
  grep -q '^  jobs_page "/admin/jobs", before_action: :require_admin, skip_before_action: :require_authentication$' config/routes.rb || fail "the jobs page is not drawn"
  if [ "$VARIANT" = "invite" ]; then
    test ! -e app/controllers/registrations_controller.rb || fail "--invite-only wrote a sign-up page"
  fi
  if [ "$VARIANT" = "confirmable" ]; then
    test -f app/controllers/confirmations_controller.rb || fail "no ConfirmationsController"
    test -f app/mailers/confirmations_mailer.rb || fail "no ConfirmationsMailer"
    test -f test/controllers/confirmations_controller_test.rb || fail "no test/controllers/confirmations_controller_test.rb"
    grep -q '^  resources :confirmations, param: :token, only: \[:new, :create, :show\]$' config/routes.rb || fail "no confirmation routes"
    grep -q 't.datetime "confirmed_at"' db/migrate/*_create_users.rb || fail "no users.confirmed_at"
    grep -q 't.string "unconfirmed_email"' db/migrate/*_create_users.rb || fail "no users.unconfirmed_email"
  else
    test ! -e app/controllers/confirmations_controller.rb || fail "$VARIANT wrote a ConfirmationsController"
  fi
}

# dist/shop migrated and served on a free port, the SMTP receiver beside it.
served_start() {
  step "serve dist/shop"
  cd dist || exit 1
  export CYBERTRAIN_SECRET_KEY_BASE="$SECRET"
  ./shop migrate > migrate.log 2>&1 || { cat migrate.log >&2; fail "./shop migrate"; }
  port=$(free_port)
  base="http://127.0.0.1:$port"
  # The mails go to the receiver; their links start with SHOP_BASE_URL. The
  # reset's is the one mail of signup and invite; confirmable has the
  # sign-up's before it and the new address's after it.
  mails=1
  reset_mail=1
  if [ "$VARIANT" = "confirmable" ]; then
    mails=3
    reset_mail=2
  fi
  start_smtp_receiver "$PWD" "$mails"
  start_server "$PWD/server.log" env PORT="$port" SHOP_BASE_URL="$base" CYBERTRAIN_SMTP_HOST=127.0.0.1 \
    CYBERTRAIN_SMTP_PORT="$(cat smtp.port)" CYBERTRAIN_SMTP_TLS=none CYBERTRAIN_SMTP_FROM=noreply@example.com ./shop
  wait_for_up "$base" "$port"
  grep -q "production environment" "$SERVER_LOG" || fail "the server log does not say it runs in the production environment"
}

# The pages a visitor sees signed out; with --invite-only, /setup and its token.
served_signed_out() {
  local status page css
  setup_token=""
  status=$(curl -sS -o page.html -w '%{http_code}' "$base/session/new")
  page=$(cat page.html)
  expect_equal "GET /session/new" "200" "$status"
  expect_contains "GET /session/new" "<h1>Sign in</h1>" "$page"
  expect_contains "GET /session/new" '<form action="/session" method="post">' "$page"
  expect_contains "GET /session/new" 'type="password" name="password"' "$page"
  # The layout links the digested stylesheet, served as immutable.
  css=$(printf '%s' "$page" | grep -o '/assets/application-[0-9a-f]\{8\}\.css' | head -n 1)
  [ -n "$css" ] || fail "GET /session/new: no digested stylesheet linked"
  curl -fsS -D css.h -o /dev/null "$base$css" || fail "GET $css"
  grep -qi '^cache-control:.*immutable' css.h || fail "GET $css: no immutable cache-control: $(cat css.h)"
  expect_equal "GET /products, signed out" "303 $base/session/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$base/products")"
  # The jobs page runs require_admin alone: a visitor gets the same 404 as
  # a path no route has, not a redirect that shows the page exists.
  # (In production both bodies are public/404.html.)
  status=$(curl -sS -o page.html -w '%{http_code}' "$base/admin/jobs")
  expect_equal "GET /admin/jobs, signed out" "404" "$status"
  status=$(curl -sS -o missing.html -w '%{http_code}' "$base/admin/no-such-page")
  expect_equal "GET /admin/no-such-page" "404" "$status"
  cmp -s page.html missing.html || fail "GET /admin/jobs, signed out: the body differs from a missing page's"
  if [ "$VARIANT" = "invite" ]; then
    expect_equal "GET /sign_up" "404" "$(curl -sS -o /dev/null -w '%{http_code}' "$base/sign_up")"
    grep -q ' WARN no user exists yet' "$SERVER_LOG" || fail "no first-run warning in the server log"
    # /setup wants the one-time token the warning prints; without it, with
    # a wrong one or through a proxy it is a 404.
    setup_token=$(sed -n 's/.*open \/setup?token=\([0-9a-f]\{32\}\) from this machine.*/\1/p' "$SERVER_LOG" | head -n 1)
    [ -n "$setup_token" ] || fail "no /setup token in the first-run warning"
    expect_contains "GET /setup?token=..." "Set up" "$(curl -fsS "$base/setup?token=$setup_token")"
    expect_equal "GET /setup, no token" "404" "$(curl -sS -o /dev/null -w '%{http_code}' "$base/setup")"
    expect_equal "GET /setup, a wrong token" "404" \
      "$(curl -sS -o /dev/null -w '%{http_code}' "$base/setup?token=0123456789abcdef0123456789abcdef")"
    expect_equal "GET /setup through a proxy" "404" \
      "$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 203.0.113.7' "$base/setup?token=$setup_token")"
  else
    expect_contains "GET /sign_up" "<h1>Sign up</h1>" "$(curl -fsS "$base/sign_up")"
  fi
}

# --confirmable: a sign-up refused until its mailed link is opened.
served_confirmable_signup() {
  local page token mail link signup_jar confirm_token
  step "sign up, refused until the mailed link is opened, then sign in"
  signup_jar="$PWD/signup-cookies.txt"
  page=$(curl -fsS -c "$signup_jar" -b "$signup_jar" "$base/sign_up")
  token=$(form_token "$page")
  [ -n "$token" ] || fail "no authenticity_token on /sign_up"
  expect_equal "POST /sign_up" "303 $base/session/new" \
    "$(post_status "$signup_jar" "$base/sign_up" "authenticity_token=$token" "user[email_address]=dee@example.com" \
       "user[password]=dee-pw-dee-pw" "user[password_confirmation]=dee-pw-dee-pw")"
  page=$(curl -fsS -c "$signup_jar" -b "$signup_jar" "$base/session/new")
  expect_contains "the sign-in page after signing up" "A link to confirm your email address was sent to it." "$page"
  case "$page" in *"<span>dee@example.com</span>"*) fail "signing up signed the new user in" ;; esac
  # A wrong password gets the usual message; the right one, the
  # confirmation's, with the link to the form that mails it again.
  token=$(form_token "$page")
  expect_equal "POST /session, unconfirmed, wrong password" "303 $base/session/new" \
    "$(post_status "$signup_jar" "$base/session" "authenticity_token=$token" "email_address=dee@example.com" "password=wrong-password")"
  page=$(curl -fsS -c "$signup_jar" -b "$signup_jar" "$base/session/new")
  expect_contains "POST /session, unconfirmed, wrong password" "Try another email address or password." "$page"
  case "$page" in *"Confirm your email address first"*) fail "a wrong password got the confirmation message" ;; esac
  token=$(form_token "$page")
  expect_equal "POST /session, unconfirmed" "303 $base/session/new" \
    "$(post_status "$signup_jar" "$base/session" "authenticity_token=$token" "email_address=dee@example.com" "password=dee-pw-dee-pw")"
  page=$(curl -fsS -c "$signup_jar" -b "$signup_jar" "$base/session/new")
  expect_contains "POST /session, unconfirmed" "Confirm your email address first: open the link in the mail we sent you." "$page"
  expect_contains "POST /session, unconfirmed" '<a href="/confirmations/new">Send the confirmation link again</a>' "$page"
  await_mail 1
  mail=$(cat mail-1.txt)
  expect_contains "the confirmation mail" "Subject: Confirm your email address" "$mail"
  expect_contains "the confirmation mail" "To: dee@example.com" "$mail"
  link=$(printf '%s' "$mail" | tr -d '\r' | grep -o "$base/confirmations/[^ ]*" | head -n 1)
  [ -n "$link" ] || fail "the confirmation mail has no link starting with $base/confirmations/: $mail"
  # Opened, the link confirms and signs nobody in; once used, it is spent.
  expect_equal "GET the confirmation link" "303 $base/session/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$signup_jar" -b "$signup_jar" "$link")"
  page=$(curl -fsS -c "$signup_jar" -b "$signup_jar" "$base/session/new")
  expect_contains "GET the confirmation link" "Your email address has been confirmed." "$page"
  case "$page" in *"<span>dee@example.com</span>"*) fail "the confirmation link signed the user in" ;; esac
  expect_equal "GET the confirmation link again" "303 $base/confirmations/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -b "$signup_jar" "$link")"
  confirm_token=${link#*/confirmations/}
  if grep -qF "$confirm_token" "$SERVER_LOG"; then
    fail "the confirmation token is in the server log"
  fi
  grep -qF 'Started GET "/confirmations/[FILTERED]"' "$SERVER_LOG" || fail "no filtered confirmation request line in the server log"
  token=$(form_token "$page")
  expect_equal "POST /session, confirmed" "303 $base/" \
    "$(post_status "$signup_jar" "$base/session" "authenticity_token=$token" "email_address=dee@example.com" "password=dee-pw-dee-pw")"
  expect_contains "signed in after confirming" "<span>dee@example.com</span>" \
    "$(curl -fsS -c "$signup_jar" -b "$signup_jar" "$base/session/new")"
}

# The user command: created, made admin, an unknown address refused.
served_user_command() {
  local out missing
  step "./shop user"
  if [ "$VARIANT" = "invite" ]; then
    # The password from stdin, then from the command line.
    expect_equal "./shop user ann@example.com, the password on stdin" "created ann@example.com" \
      "$(printf 's3cr3t-s3cr3t\n' | ./shop user ann@example.com)"
    expect_equal "./shop user ann@example.com pw-pw-pw-pw" "updated ann@example.com" \
      "$(./shop user ann@example.com pw-pw-pw-pw)"
    # A user exists: /setup is gone, even with the token.
    expect_equal "GET /setup?token=... once a user exists" "404" \
      "$(curl -sS -o /dev/null -w '%{http_code}' "$base/setup?token=$setup_token")"
  else
    expect_equal "./shop user ann@example.com pw-pw-pw-pw" "created ann@example.com" \
      "$(./shop user ann@example.com pw-pw-pw-pw)"
  fi
  expect_equal "./shop user admin ann@example.com" "admin ann@example.com" \
    "$(./shop user admin ann@example.com)"
  missing=0
  out=$(./shop user admin bob@example.com) || missing=$?
  expect_equal "./shop user admin bob@example.com" "error: no user bob@example.com" "$out"
  expect_equal "./shop user admin bob@example.com (status)" "1" "$missing"
}

# Signed in as an admin, the jobs page; no longer one, a 404.
served_admin() {
  local page token status
  step "sign in, the jobs page as an admin"
  jar="$PWD/cookies.txt"
  page=$(curl -fsS -c "$jar" -b "$jar" "$base/session/new")
  token=$(form_token "$page")
  [ -n "$token" ] || fail "no authenticity_token on /session/new"
  expect_equal "POST /session" "303 $base/" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$jar" -b "$jar" \
       --data-urlencode "authenticity_token=$token" --data-urlencode "email_address=ann@example.com" \
       --data-urlencode "password=pw-pw-pw-pw" "$base/session")"
  status=$(curl -sS -o page.html -w '%{http_code}' -b "$jar" "$base/admin/jobs")
  expect_equal "GET /admin/jobs as an admin" "200" "$status"
  expect_contains "GET /admin/jobs as an admin" "<h1>Jobs</h1>" "$(cat page.html)"
  expect_equal "./shop user unadmin ann@example.com" "unadmin ann@example.com" \
    "$(./shop user unadmin ann@example.com)"
  expect_equal "GET /admin/jobs, no longer an admin" "404" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -b "$jar" "$base/admin/jobs")"
}

# A password reset by mail, with a forged Host; the link spent, the token filtered.
served_password_reset() {
  local page token cookie known unknown mail link action reset_token
  step "password reset by mail"
  # The address form is sent with a forged Host (evil.example): the answer
  # is the same for an address no user has, and the link takes
  # SHOP_BASE_URL, never the Host. Production's session cookie is Secure,
  # which curl keeps over http only for 127.0.0.1, so it is passed by hand
  # next to the forged Host.
  reset_jar="$PWD/reset-cookies.txt"
  page=$(curl -fsS -c "$reset_jar" -b "$reset_jar" "$base/passwords/new")
  expect_contains "GET /passwords/new" "<h1>Forgot your password?</h1>" "$page"
  token=$(form_token "$page")
  [ -n "$token" ] || fail "no authenticity_token on /passwords/new"
  cookie=$(awk -F '\t' 'NF >= 7 { print $6 "=" $7 }' "$reset_jar" | paste -sd ';' -)
  [ -n "$cookie" ] || fail "no session cookie from /passwords/new"
  known=$(curl -sS -o known.html -w '%{http_code} %{redirect_url}' -H "Host: evil.example" -H "Cookie: $cookie" \
    --data-urlencode "authenticity_token=$token" --data-urlencode "email_address=Ann@Example.com" "$base/passwords")
  unknown=$(curl -sS -o unknown.html -w '%{http_code} %{redirect_url}' -H "Host: evil.example" -H "Cookie: $cookie" \
    --data-urlencode "authenticity_token=$token" --data-urlencode "email_address=nobody@example.com" "$base/passwords")
  expect_equal "POST /passwords (registered)" "303 $base/session/new" "$known"
  expect_equal "POST /passwords (unknown)" "$known" "$unknown"
  cmp -s known.html unknown.html || fail "POST /passwords: the bodies differ between a registered and an unknown address"
  await_mail "$reset_mail"
  mail=$(cat "mail-$reset_mail.txt")
  expect_contains "the reset mail" "Subject: Reset your password" "$mail"
  expect_contains "the reset mail" "To: ann@example.com" "$mail"
  link=$(printf '%s' "$mail" | tr -d '\r' | grep -o "$base/passwords/[^ ]*/edit" | head -n 1)
  [ -n "$link" ] || fail "the reset mail has no link starting with $base/passwords/: $mail"
  case "$link" in *evil.example*) fail "the reset link took the forged Host: $link" ;; esac
  page=$(curl -fsS -c "$reset_jar" -b "$reset_jar" "$link")
  expect_contains "GET the mail's link" "<h1>Choose a new password</h1>" "$page"
  token=$(form_token "$page")
  action=${link%/edit}
  expect_equal "PUT the new password" "303 $base/session/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$reset_jar" -b "$reset_jar" \
       --data-urlencode "_method=put" --data-urlencode "authenticity_token=$token" \
       --data-urlencode "password=n3w-pw-n3w-pw" --data-urlencode "password_confirmation=n3w-pw-n3w-pw" "$action")"
  # Spent: the link answers with the address form now.
  expect_equal "GET the mail's link again" "303 $base/passwords/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -b "$reset_jar" "$link")"
  # The token never reaches the log: the request lines write it [FILTERED].
  reset_token=${link#*/passwords/}
  reset_token=${reset_token%/edit}
  [ -n "$reset_token" ] || fail "no token in the reset link: $link"
  if grep -qF "$reset_token" "$SERVER_LOG"; then
    fail "the reset token is in the server log"
  fi
  grep -qF 'Started GET "/passwords/[FILTERED]/edit"' "$SERVER_LOG" || fail "no filtered reset request line in the server log"
  grep -qE 'Started (POST|PUT) "/passwords/\[FILTERED\]"' "$SERVER_LOG" || fail "no filtered PUT line in the server log"
  # The reset ended the session signed in before it.
  expect_equal "GET /products with the session from before the reset" "303 $base/session/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -b "$jar" "$base/products")"
  page=$(curl -fsS -c "$reset_jar" -b "$reset_jar" "$base/session/new")
  token=$(form_token "$page")
  expect_equal "POST /session with the new password" "303 $base/" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$reset_jar" -b "$reset_jar" \
       --data-urlencode "authenticity_token=$token" --data-urlencode "email_address=ann@example.com" \
       --data-urlencode "password=n3w-pw-n3w-pw" "$base/session")"
}

# The account page: a new address and password, which sign a second browser
# out, then the account deleted with the password.
served_account() {
  local page token status mail link other_jar
  step "the account page: a new address and password, then the account deleted"
  # A second browser signed in as ann, which the new password ends.
  other_jar="$PWD/other-cookies.txt"
  page=$(curl -fsS -c "$other_jar" -b "$other_jar" "$base/session/new")
  token=$(form_token "$page")
  expect_equal "POST /session (a second browser)" "303 $base/" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$other_jar" -b "$other_jar" \
       --data-urlencode "authenticity_token=$token" --data-urlencode "email_address=ann@example.com" \
       --data-urlencode "password=n3w-pw-n3w-pw" "$base/session")"
  status=$(curl -sS -o page.html -w '%{http_code}' -c "$reset_jar" -b "$reset_jar" "$base/account/edit")
  page=$(cat page.html)
  expect_equal "GET /account/edit" "200" "$status"
  expect_contains "GET /account/edit" "<h1>Account</h1>" "$page"
  expect_contains "GET /account/edit" '<a href="/account/edit">Account</a>' "$page"
  token=$(form_token "$page")
  [ -n "$token" ] || fail "no authenticity_token on /account/edit"
  # A wrong current password changes nothing.
  status=$(curl -sS -o page.html -w '%{http_code}' -c "$reset_jar" -b "$reset_jar" \
    --data-urlencode "_method=patch" --data-urlencode "authenticity_token=$token" \
    --data-urlencode "user[current_password]=wrong-password" --data-urlencode "user[email_address]=ann@new.example" \
    "$base/account")
  expect_equal "PATCH /account with a wrong current password" "422" "$status"
  expect_contains "PATCH /account with a wrong current password" "That is not your current password." "$(cat page.html)"
  # The right one: a new address and a new password.
  expect_equal "PATCH /account" "303 $base/account/edit" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$reset_jar" -b "$reset_jar" \
       --data-urlencode "_method=patch" --data-urlencode "authenticity_token=$token" \
       --data-urlencode "user[current_password]=n3w-pw-n3w-pw" --data-urlencode "user[email_address]=ann@new.example" \
       --data-urlencode "user[password]=th1rd-pw-th1rd" --data-urlencode "user[password_confirmation]=th1rd-pw-th1rd" \
       "$base/account")"
  page=$(curl -fsS -c "$reset_jar" -b "$reset_jar" "$base/account/edit")
  if [ "$VARIANT" = "confirmable" ]; then
    # The new address waits for the link mailed to it; the old one is in use.
    expect_contains "GET /account/edit after the change" "A link to confirm the new address was sent to it." "$page"
    expect_contains "GET /account/edit after the change" "<span>ann@example.com</span>" "$page"
    expect_contains "GET /account/edit after the change" "Waiting for confirmation: ann@new.example" "$page"
    await_mail 3
    mail=$(cat mail-3.txt)
    expect_contains "the new address's mail" "Subject: Confirm your email address" "$mail"
    expect_contains "the new address's mail" "To: ann@new.example" "$mail"
    link=$(printf '%s' "$mail" | tr -d '\r' | grep -o "$base/confirmations/[^ ]*" | head -n 1)
    [ -n "$link" ] || fail "the new address's mail has no link starting with $base/confirmations/: $mail"
    expect_equal "GET the new address's link (signed in)" "303 $base/account/edit" \
      "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$reset_jar" -b "$reset_jar" "$link")"
    page=$(curl -fsS -c "$reset_jar" -b "$reset_jar" "$base/account/edit")
    expect_contains "GET /account/edit after the confirmation" "Your email address has been confirmed." "$page"
  else
    expect_contains "GET /account/edit after the change" "Your account has been updated." "$page"
  fi
  expect_contains "GET /account/edit after the change" "<span>ann@new.example</span>" "$page"
  # The other browser is signed out; this one stays signed in.
  expect_equal "GET /products from the other browser" "303 $base/session/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -b "$other_jar" "$base/products")"
  expect_equal "GET /products from this browser" "200" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -b "$reset_jar" "$base/products")"
  # Deleted with the password: this browser is signed out, and the address
  # signs in no more.
  token=$(form_token "$page")
  expect_equal "DELETE /account" "303 $base/" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$reset_jar" -b "$reset_jar" \
       --data-urlencode "_method=delete" --data-urlencode "authenticity_token=$token" \
       --data-urlencode "password=th1rd-pw-th1rd" "$base/account")"
  expect_equal "GET /account/edit after the deletion" "303 $base/session/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$reset_jar" -b "$reset_jar" "$base/account/edit")"
  page=$(curl -fsS -c "$reset_jar" -b "$reset_jar" "$base/session/new")
  token=$(form_token "$page")
  expect_equal "POST /session after the deletion" "303 $base/session/new" \
    "$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$reset_jar" -b "$reset_jar" \
       --data-urlencode "authenticity_token=$token" --data-urlencode "email_address=ann@new.example" \
       --data-urlencode "password=th1rd-pw-th1rd" "$base/session")"
}
