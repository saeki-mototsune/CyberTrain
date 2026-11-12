# "Keep me signed in" and the idle limit (cybertrain generate
# authentication): a sign-in lasts session_absolute_max_age (two weeks)
# unless the box was checked (auth_remember_for, 30 days), and ends
# either way after auth_idle_timeout (7 days) without a request. The
# tests move the Session row's created_at and last_active_at back in
# time rather than wait; the cookie's own limit (the stamp
# start_new_session_for writes) is the framework's to enforce. Run with
# `cybertrain spin test`; its snapshot comes from the compiled binary
# (the database is FFI).
require_relative "support/app_test"

DAY = 24 * 60 * 60

def new_client
  Session.all.delete_all
  User.all.delete_all
  Cybertrain::Test::Client.new(APP)
end

# Signs client in through the form as AppTest.sign_in does, the box
# checked or not.
def sign_in_with(client, remember)
  Cybertrain::RateLimit.reset_all!
  client.get("/session/new")
  fields = { "authenticity_token" => AppTest.form_token(client),
             "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" }
  fields["remember_me"] = "1" if remember
  client.post("/session", fields)
end

# The first (in these tests, the browser's only) Session row, as if
# started `started` seconds ago and last used `idle` seconds ago.
def backdate(started, idle)
  now = Time.current.to_i
  Session.first.update_columns(created_at: Time.at(now - started).utc, last_active_at: Time.at(now - idle).utc)
  nil
end

# Whether client is still signed in: the nav names the user.
def signed_in?(client)
  client.get("/session/new").body.include?("<span>ann@example.com</span>")
end

# The session cookie client holds now, as a request header.
def cookie_header(client)
  name = Cybertrain.config.session_cookie_name
  "#{name}=#{client.cookies[name]}"
end

# Whether a copy of an old cookie (kept by whoever had it) signs in.
def replayed_signed_in?(client, cookie)
  client.get("/session/new", { "cookie" => cookie }).body.include?("<span>ann@example.com</span>")
end

# The Set-Cookie line of the session cookie in res ("" when none).
def session_cookie(res)
  prefix = "#{Cybertrain.config.session_cookie_name}="
  found = ""
  res.cookies.each { |line| found = line if line.start_with?(prefix) }
  found
end

# start_new_session_for is private (the Authentication concern's): a
# controller made for these tests calls it, as an action would.
class LifetimeProbeController < ApplicationController
  def probe_start(user, remember)
    start_new_session_for(user, remember: remember)
  end
end

# The cookie session start_new_session_for leaves for user.
def stamped_session(user, remember)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
  ctx.session = Cybertrain::Session.new
  LifetimeProbeController.new(ctx).probe_start(user, remember)
  ctx.session
end

# A cookie that already carries a start (a browser that signed in
# before, or the account page's restart after a new password, on day
# 13 of its sign-in) starts again: SessionStore stamps this request's
# time, so the new sign-in gets its whole limit.
test "a sign-in restarts the lifetime of a cookie that already has one" do
  new_client
  user = AppTest.user
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
  ctx.session = Cybertrain::Session.new
  ctx.session["_issued_at"] = Time.current.to_i - 13 * DAY
  assert ctx.session.issued_at > 0
  LifetimeProbeController.new(ctx).probe_start(user, false)
  assert_equal 0, ctx.session.issued_at
end

test "a remembered session is alive on day 15 and ended after day 30" do
  client = new_client
  AppTest.user
  res = sign_in_with(client, true)
  assert_redirected_to res, "/"
  assert_equal true, Session.first.remember
  assert session_cookie(res).end_with?("; Max-Age=2592000"), session_cookie(res)
  backdate(15 * DAY, 0)
  assert signed_in?(client)
  backdate(30 * DAY - 60, 0)
  assert signed_in?(client)
  cookie = cookie_header(client)
  backdate(30 * DAY, 0)
  refute signed_in?(client)
  # Ended: the row is gone, so a longer limit set afterwards does not
  # bring back a copy of the cookie.
  assert_equal 0, Session.count
  remember_for = Cybertrain.config.auth_remember_for
  begin
    Cybertrain.config.auth_remember_for = 60 * DAY
    refute replayed_signed_in?(client, cookie)
  ensure
    Cybertrain.config.auth_remember_for = remember_for
  end
end

test "an unremembered session ends after day 14" do
  client = new_client
  AppTest.user
  res = sign_in_with(client, false)
  assert_redirected_to res, "/"
  assert_equal false, Session.first.remember
  backdate(14 * DAY - 60, 0)
  assert signed_in?(client)
  backdate(14 * DAY, 0)
  refute signed_in?(client)
  # Day 15, where a remembered one is alive.
  client = new_client
  AppTest.user
  sign_in_with(client, false)
  backdate(15 * DAY, 0)
  refute signed_in?(client)
end

test "an unremembered session still ends with session_absolute_max_age off" do
  absolute = Cybertrain.config.session_absolute_max_age
  max_age = Cybertrain.config.session_max_age
  remember_for = Cybertrain.config.auth_remember_for
  begin
    # Off (0): the limit is session_max_age (two weeks), stamped on
    # the cookie and checked on the row.
    Cybertrain.config.session_absolute_max_age = 0
    client = new_client
    user = AppTest.user
    res = sign_in_with(client, false)
    assert_redirected_to res, "/"
    refute session_cookie(res).empty?
    refute session_cookie(res).include?("Max-Age")
    backdate(14 * DAY - 60, 0)
    assert signed_in?(client)
    backdate(14 * DAY, 0)
    refute signed_in?(client)
    # The stamp itself (each probe adds a Session row of its own, so
    # no backdate follows).
    stamped = stamped_session(user, false)
    assert_equal 1_209_600, stamped.lifetime_limit
    assert stamped.browser_session?
    # session_max_age not positive either: two weeks all the same.
    Cybertrain.config.session_max_age = 0
    assert_equal 1_209_600, stamped_session(user, false).lifetime_limit
    # A limit of its own is stamped as it is; a remembered sign-in
    # takes auth_remember_for and a Max-Age (not a browser session).
    Cybertrain.config.session_absolute_max_age = 3600
    assert_equal 3600, stamped_session(user, false).lifetime_limit
    remembered = stamped_session(user, true)
    assert_equal 2_592_000, remembered.lifetime_limit
    refute remembered.browser_session?
    # auth_remember_for not positive (set at run time, past boot's
    # check): the same chain as an unremembered sign-in, still
    # persistent.
    Cybertrain.config.auth_remember_for = 0
    remembered = stamped_session(user, true)
    assert_equal 3600, remembered.lifetime_limit
    refute remembered.browser_session?
    Cybertrain.config.session_absolute_max_age = 0
    Cybertrain.config.session_max_age = 0
    assert_equal 1_209_600, stamped_session(user, true).lifetime_limit
  ensure
    Cybertrain.config.session_absolute_max_age = absolute
    Cybertrain.config.session_max_age = max_age
    Cybertrain.config.auth_remember_for = remember_for
  end
end

test "both end after 7 idle days" do
  [true, false].each do |remember|
    client = new_client
    AppTest.user
    sign_in_with(client, remember)
    backdate(8 * DAY, 7 * DAY - 60)
    assert signed_in?(client)
    cookie = cookie_header(client)
    backdate(8 * DAY, 7 * DAY)
    refute signed_in?(client)
    # Ended: the row is gone, so turning the idle limit off afterwards
    # does not bring back a copy of the cookie.
    assert_equal 0, Session.count
    idle = Cybertrain.config.auth_idle_timeout
    begin
      Cybertrain.config.auth_idle_timeout = 0
      refute replayed_signed_in?(client, cookie)
    ensure
      Cybertrain.config.auth_idle_timeout = idle
    end
  end
  # A row with no last_active_at is idle since created_at.
  client = new_client
  AppTest.user
  sign_in_with(client, true)
  now = Time.current.to_i
  Session.first.update_columns(created_at: Time.at(now - 7 * DAY + 60).utc, last_active_at: nil)
  assert signed_in?(client)
  refute Session.first.last_active_at.nil?
  Session.first.update_columns(created_at: Time.at(now - 7 * DAY).utc, last_active_at: nil)
  refute signed_in?(client)
  assert_equal 0, Session.count
  # auth_idle_timeout 0: no idle limit, the absolute one alone.
  idle = Cybertrain.config.auth_idle_timeout
  begin
    Cybertrain.config.auth_idle_timeout = 0
    client = new_client
    AppTest.user
    sign_in_with(client, true)
    backdate(29 * DAY, 29 * DAY)
    assert signed_in?(client)
    backdate(30 * DAY, 29 * DAY)
    refute signed_in?(client)
  ensure
    Cybertrain.config.auth_idle_timeout = idle
  end
end

test "last_active_at is touched at most once a minute" do
  client = new_client
  AppTest.user
  before = Time.current.to_i
  sign_in_with(client, false)
  started = Session.first.last_active_at
  refute started.nil?
  assert started.to_i >= before
  # Used 30 seconds ago: a request does not write the row.
  now = Time.current.to_i
  Session.first.update_columns(last_active_at: Time.at(now - 30).utc)
  updated_at = Session.first.updated_at.to_i
  assert signed_in?(client)
  assert_equal now - 30, Session.first.last_active_at.to_i
  # Used 61 seconds ago: the request moves it to now, and leaves
  # updated_at alone.
  Session.first.update_columns(last_active_at: Time.at(now - 61).utc)
  assert signed_in?(client)
  assert Session.first.last_active_at.to_i >= now
  assert_equal updated_at, Session.first.updated_at.to_i
end

test "an unremembered sign-in sets a cookie without Max-Age" do
  client = new_client
  AppTest.user
  res = sign_in_with(client, false)
  assert_redirected_to res, "/"
  cookie = session_cookie(res)
  refute cookie.empty?
  refute cookie.include?("Max-Age")
  refute cookie.include?("Expires")
  # The box checked, the same cookie lasts auth_remember_for.
  client = new_client
  AppTest.user
  res = sign_in_with(client, true)
  cookie = session_cookie(res)
  assert cookie.end_with?("; Max-Age=2592000"), cookie
  refute cookie.include?("Expires")
end

Cybertrain::Test.run!
