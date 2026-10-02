# frozen_string_literal: true

require_relative "test_helper"

class LimitsTest < Minitest::Test
  def test_the_window_slides
    clock = FakeClock.new
    limits = Play::Limits.new(limit: 2, window: 600, clock: clock)
    assert_equal 0, limits.retry_after("203.0.113.7")
    limits.record("203.0.113.7")
    clock.advance(100)
    limits.record("203.0.113.7")
    assert_equal 500, limits.retry_after("203.0.113.7")
    assert_equal 0, limits.retry_after("203.0.113.8")
    clock.advance(500)
    assert_equal 0, limits.retry_after("203.0.113.7")
    limits.record("203.0.113.7")
    assert_equal 100, limits.retry_after("203.0.113.7")
  end

  def test_more_hits_than_the_limit_wait_until_enough_have_left_the_window
    clock = FakeClock.new
    limits = Play::Limits.new(limit: 2, window: 600, clock: clock)
    limits.record("203.0.113.7")
    clock.advance(100)
    limits.record("203.0.113.7")
    clock.advance(100)
    limits.record("203.0.113.7") # creations that passed retry_after together overshoot the limit
    assert_equal 500, limits.retry_after("203.0.113.7")
    clock.advance(499)
    assert_equal 1, limits.retry_after("203.0.113.7")
    clock.advance(1)
    assert_equal 0, limits.retry_after("203.0.113.7")
  end

  def test_ipv4_key_from_the_header
    env = { "HTTP_CF_CONNECTING_IP" => "203.0.113.7", "REMOTE_ADDR" => "172.18.0.5" }
    assert_equal "203.0.113.7", Play::Limits.client_key(env, "HTTP_CF_CONNECTING_IP")
    assert_equal "172.18.0.5", Play::Limits.client_key(env, nil)
  end

  def test_ipv6_counts_per_64
    a = { "HTTP_CF_CONNECTING_IP" => "2001:db8:1:2:aaaa::1" }
    b = { "HTTP_CF_CONNECTING_IP" => "2001:DB8:1:2:bbbb::9" }
    assert_equal "2001:db8:1:2::/64", Play::Limits.client_key(a, "HTTP_CF_CONNECTING_IP")
    assert_equal "2001:db8:1:2::/64", Play::Limits.client_key(b, "HTTP_CF_CONNECTING_IP")
    mapped = { "HTTP_CF_CONNECTING_IP" => "::ffff:203.0.113.7" }
    assert_equal "203.0.113.7", Play::Limits.client_key(mapped, "HTTP_CF_CONNECTING_IP")
  end

  def test_a_broken_header_falls_back_to_remote_addr
    ["", "unknown", "203.0.113.7, 198.51.100.1", "10.0.0.0/8", "999.1.1.1", "2001:db8::1%eth0"].each do |bad|
      env = { "HTTP_CF_CONNECTING_IP" => bad, "REMOTE_ADDR" => "172.18.0.5" }
      assert_equal "172.18.0.5", Play::Limits.client_key(env, "HTTP_CF_CONNECTING_IP"), bad
    end
  end
end
