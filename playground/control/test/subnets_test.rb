# frozen_string_literal: true

require_relative "test_helper"

class SubnetsTest < Minitest::Test
  def subnets
    Play::Subnets.new("10.250.0.0/16", 28)
  end

  def test_the_lowest_free_subnet
    assert_equal "10.250.0.0/28", subnets.first_free([])
    assert_equal "10.250.0.32/28", subnets.first_free(["10.250.0.0/28", "10.250.0.16/28"])
    assert_equal "10.250.0.16/28", subnets.first_free(["10.250.0.0/28", "10.250.0.32/28"])
  end

  def test_skips_what_overlaps_including_bigger_networks_and_refused_ranges
    assert_equal "10.250.1.0/28", subnets.first_free(["10.250.0.0/24"])
    assert_equal "10.250.0.16/28", subnets.first_free(["10.250.0.8/29", "10.250.0.0/29"])
    assert_equal "10.250.0.0/28", subnets.first_free(["192.0.2.0/24", "not a subnet"])
  end

  def test_taken_subnets_may_carry_whitespace
    assert_equal "10.250.0.16/28", subnets.first_free(["10.250.0.0/28\n"])
    assert_equal "10.250.0.32/28", subnets.first_free([" 10.250.0.0/28", "10.250.0.16/28 \n"])
  end

  def test_none_left
    small = Play::Subnets.new("10.250.0.0/27", 28)
    assert_nil small.first_free(["10.250.0.0/28", "10.250.0.16/28"])
  end

  def test_pool_validation
    assert_nil Play::Subnets.validate!("10.250.0.0/16", 28)
    error = ->(pool, prefix) { assert_raises(Play::Config::Error) { Play::Subnets.validate!(pool, prefix) }.message }
    assert_equal "PLAY_SUBNET_POOL 192.168.64.0/20 overlaps Docker's default address pool 192.168.0.0/16",
                 error.call("192.168.64.0/20", 28)
    assert_equal "PLAY_SUBNET_POOL 172.0.0.0/8 overlaps Docker's default address pool 172.17.0.0/16",
                 error.call("172.0.0.0/8", 28)
    assert_equal "PLAY_SUBNET_PREFIX must be between 16 and 29 for 10.250.0.0/16 (got 30)", error.call("10.250.0.0/16", 30)
    assert_equal "PLAY_SUBNET_PREFIX must be between 16 and 29 for 10.250.0.0/16 (got 12)", error.call("10.250.0.0/16", 12)
    assert_match(/must be an IPv4 network/, error.call("fd00::/64", 72))
    assert_match(/must be an IPv4 network/, error.call("10.250.0.1", 28))
  end
end
