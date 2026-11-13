# "Keep me signed in" and the idle limit (cybertrain generate
# authentication): a sign-in lasts session_absolute_max_age (two weeks)
# unless the box was checked (auth_remember_for, 30 days), and ends
# either way after auth_idle_timeout (7 days) without a request. The
# tests move the clock with travel_to rather than wait; it is frozen
# first, so that `15.days.from_now` is fifteen days after the sign-in.
# A session meant to live is used every six days, inside the idle limit.
require "test_helper"

# start_new_session_for is private (the Authentication concern's): a
# controller made for these tests calls it, as an action would.
class LifetimeProbeController < ApplicationController
  def probe_start(user, remember)
    start_new_session_for(user, remember: remember)
  end
end

class RememberMeTest < ActionDispatch::IntegrationTest
  setup do
    freeze_time
  end

  # A cookie that already carries a start (a browser that signed in
  # before, or the account page's restart after a new password, on day
  # 13 of its sign-in) starts again: SessionStore stamps this request's
  # time, so the new sign-in gets its whole limit.
  test "a sign-in restarts the lifetime of a cookie that already has one" do
    ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
    ctx.session = Cybertrain::Session.new
    ctx.session["_issued_at"] = Time.current.to_i - 13.days
    assert ctx.session.issued_at > 0
    LifetimeProbeController.new(ctx).probe_start(users(:one), false)
    assert_equal 0, ctx.session.issued_at
  end

  # Signed in while auth_remember_for is 31 days, then set back to its
  # 30: the cookie holds 31, so on day 30 it is the Session row's own
  # limit that ends the sign-in, and the row is gone.
  test "a remembered session survives day 15 and ends after day 30" do
    remember_for = Cybertrain.config.auth_remember_for
    Cybertrain.config.auth_remember_for = 31.days
    sign_in_as users(:one), remember: true
    Cybertrain.config.auth_remember_for = remember_for
    assert_redirected_to "/"
    assert_equal true, Session.first.remember
    assert session_cookie_of(response).end_with?("; Max-Age=2678400"), session_cookie_of(response)
    travel_to 6.days.from_now do
      assert signed_in?
    end
    travel_to 12.days.from_now do
      assert signed_in?
    end
    travel_to 15.days.from_now do
      assert signed_in?
    end
    travel_to 21.days.from_now do
      assert signed_in?
    end
    travel_to 27.days.from_now do
      assert signed_in?
    end
    cookie = cookie_header
    first = Session.last
    travel_to 30.days.from_now - 1.minute do
      assert signed_in?
    end
    travel_to 30.days.from_now do
      refute signed_in?
      # Ended: the row is gone.
      assert_nil Session.find_by(id: first.id)
    end
    travel_to 31.days.from_now do
      refute replayed_signed_in?(cookie)
    end
    # A sign-in whose limit was lowered to 15 days since (the cookie
    # still holds its 30) ends on day 15, its row with it, and a longer
    # limit set afterwards does not bring back a copy of the cookie.
    begin
      sign_in_as users(:one), remember: true
      started = Session.last
      cookie = cookie_header
      Cybertrain.config.auth_remember_for = 15.days
      travel_to 6.days.from_now do
        assert signed_in?
      end
      travel_to 12.days.from_now do
        assert signed_in?
      end
      travel_to 15.days.from_now do
        refute signed_in?
        assert_nil Session.find_by(id: started.id)
        Cybertrain.config.auth_remember_for = 60.days
        refute replayed_signed_in?(cookie)
      end
    ensure
      Cybertrain.config.auth_remember_for = remember_for
    end
  end

  test "an unremembered session ends after day 14" do
    sign_in_as users(:one)
    assert_redirected_to "/"
    assert_equal false, Session.first.remember
    travel_to 6.days.from_now do
      assert signed_in?
    end
    travel_to 12.days.from_now do
      assert signed_in?
    end
    travel_to 14.days.from_now - 1.minute do
      assert signed_in?
    end
    travel_to 14.days.from_now do
      refute signed_in?
    end
    # Day 15, where a remembered one is alive.
    sign_in_as users(:one)
    travel_to 6.days.from_now do
      assert signed_in?
    end
    travel_to 12.days.from_now do
      assert signed_in?
    end
    travel_to 15.days.from_now do
      refute signed_in?
    end
  end

  test "an unremembered session still ends with session_absolute_max_age off" do
    absolute = Cybertrain.config.session_absolute_max_age
    max_age = Cybertrain.config.session_max_age
    remember_for = Cybertrain.config.auth_remember_for
    begin
      # Off (0): the limit is session_max_age (two weeks), stamped on
      # the cookie and checked on the row. Signed in while it is 15
      # days, then set back to 14, so that the cookie still holds its
      # 15 on day 14 and the row's check alone ends the sign-in.
      Cybertrain.config.session_absolute_max_age = 0
      Cybertrain.config.session_max_age = 15.days
      user = users(:one)
      sign_in_as user
      assert_redirected_to "/"
      started = Session.last
      Cybertrain.config.session_max_age = 14.days
      refute session_cookie_of(response).empty?
      refute session_cookie_of(response).include?("Max-Age")
      travel_to 6.days.from_now do
        assert signed_in?
      end
      travel_to 12.days.from_now do
        assert signed_in?
      end
      travel_to 14.days.from_now - 1.minute do
        assert signed_in?
      end
      travel_to 14.days.from_now do
        refute signed_in?
        assert_nil Session.find_by(id: started.id)
      end
      # The stamp itself.
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

  # Used a minute short of seven days after the sign-in, then left
  # alone for seven days: ended (well inside the two weeks of an
  # unremembered sign-in).
  test "seven idle days end a session" do
    [true, false].each do |remember|
      sign_in_as users(:one), remember: remember
      started = Session.last
      travel_to 7.days.from_now - 1.minute do
        assert signed_in?
      end
      cookie = cookie_header
      travel_to 14.days.from_now - 1.minute do
        refute signed_in?
        # Ended: the row is gone, so turning the idle limit off
        # afterwards does not bring back a copy of the cookie.
        assert_nil Session.find_by(id: started.id)
        idle = Cybertrain.config.auth_idle_timeout
        begin
          Cybertrain.config.auth_idle_timeout = 0
          refute replayed_signed_in?(cookie)
        ensure
          Cybertrain.config.auth_idle_timeout = idle
        end
      end
    end
    # A row with no last_active_at is idle since created_at.
    sign_in_as users(:one), remember: true
    started = Session.last
    started.update_columns(last_active_at: nil)
    travel_to 7.days.from_now - 1.minute do
      assert signed_in?
      refute Session.find(started.id).last_active_at.nil?
    end
    Session.find(started.id).update_columns(last_active_at: nil)
    travel_to 7.days.from_now do
      refute signed_in?
      assert_nil Session.find_by(id: started.id)
    end
    # auth_idle_timeout 0: no idle limit, the absolute one alone (on
    # the row: lowered to 29 days after the sign-in, while the cookie
    # holds its 30).
    idle = Cybertrain.config.auth_idle_timeout
    remember_for = Cybertrain.config.auth_remember_for
    begin
      Cybertrain.config.auth_idle_timeout = 0
      sign_in_as users(:one), remember: true
      started = Session.last
      Cybertrain.config.auth_remember_for = 29.days
      travel_to 29.days.from_now - 1.minute do
        assert signed_in?
      end
      travel_to 29.days.from_now do
        refute signed_in?
        assert_nil Session.find_by(id: started.id)
      end
    ensure
      Cybertrain.config.auth_idle_timeout = idle
      Cybertrain.config.auth_remember_for = remember_for
    end
  end

  test "last_active_at is touched at most once a minute" do
    before = Time.current.to_i
    sign_in_as users(:one)
    started = Session.first.last_active_at
    refute started.nil?
    assert started.to_i >= before
    # Used 30 seconds later: a request does not write the row.
    travel 30.seconds
    updated_at = Session.first.updated_at.to_i
    assert signed_in?
    assert_equal before, Session.first.last_active_at.to_i
    # 61 seconds after the last write: the request moves it to now, and
    # leaves updated_at alone.
    travel 31.seconds
    assert signed_in?
    assert_equal before + 61, Session.first.last_active_at.to_i
    assert_equal updated_at, Session.first.updated_at.to_i
  end

  test "an unremembered sign-in sets a cookie without Max-Age" do
    sign_in_as users(:one)
    assert_redirected_to "/"
    cookie = session_cookie_of(response)
    refute cookie.empty?
    refute cookie.include?("Max-Age")
    refute cookie.include?("Expires")
    # The box checked, the same cookie lasts auth_remember_for.
    sign_in_as users(:one), remember: true
    cookie = session_cookie_of(response)
    assert cookie.end_with?("; Max-Age=2592000"), cookie
    refute cookie.include?("Expires")
  end

  private

  # Whether this browser is signed in: the nav names the user.
  def signed_in?
    get "/session/new"
    response.body.include?("<span>one@example.com</span>")
  end

  # The session cookie this browser holds now, as a request header.
  def cookie_header
    name = Cybertrain.config.session_cookie_name
    "#{name}=#{cookies[name]}"
  end

  # Whether a copy of an old cookie (kept by whoever had it) signs in.
  def replayed_signed_in?(cookie)
    get "/session/new", headers: { "cookie" => cookie }
    response.body.include?("<span>one@example.com</span>")
  end

  # The Set-Cookie line of the session cookie in res ("" when none).
  def session_cookie_of(res)
    prefix = "#{Cybertrain.config.session_cookie_name}="
    found = ""
    res.cookies.each { |line| found = line if line.start_with?(prefix) }
    found
  end

  # The cookie session start_new_session_for leaves for user.
  def stamped_session(user, remember)
    ctx = Cybertrain::Context.new(Cybertrain::Request.new("POST", "/session", {}, ""))
    ctx.session = Cybertrain::Session.new
    LifetimeProbeController.new(ctx).probe_start(user, remember)
    ctx.session
  end
end
