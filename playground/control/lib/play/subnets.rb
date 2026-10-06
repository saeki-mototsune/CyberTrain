# frozen_string_literal: true

require "ipaddr"
require "socket"

module Play
  # Cuts PLAY_SUBNET_POOL into /PLAY_SUBNET_PREFIX networks, one per session
  # (spec §5.5): explicit small subnets keep Docker's default address pools
  # (31 networks in all) out of the way.
  class Subnets
    # Docker's default local pools: 172.17-31.0.0/16 and 192.168.0.0/16.
    DOCKER_DEFAULT_POOLS = ((17..31).map { |n| "172.#{n}.0.0/16" } + ["192.168.0.0/16"]).map { |c| IPAddr.new(c) }.freeze
    # A /29 holds 8 addresses: the reserved ones, the session and two routers.
    MAX_PREFIX = 29

    def self.validate!(pool, prefix)
      net = parse_pool(pool)
      unless prefix.between?(net.prefix, MAX_PREFIX)
        raise Config::Error, "PLAY_SUBNET_PREFIX must be between #{net.prefix} and #{MAX_PREFIX} for #{pool} (got #{prefix})"
      end
      clash = DOCKER_DEFAULT_POOLS.find { |d| d.include?(net) || net.include?(d) }
      return unless clash

      raise Config::Error, "PLAY_SUBNET_POOL #{pool} overlaps Docker's default address pool #{clash}/#{clash.prefix}"
    end

    def self.parse_pool(pool)
      net = IPAddr.new(pool)
      raise IPAddr::InvalidAddressError unless net.ipv4? && pool.include?("/")

      net
    rescue IPAddr::Error
      raise Config::Error, "PLAY_SUBNET_POOL must be an IPv4 network such as 10.250.0.0/16 (got #{pool.inspect})"
    end

    def initialize(pool, prefix)
      @pool = self.class.parse_pool(pool)
      @prefix = prefix
    end

    # The lowest subnet of the pool that overlaps none of TAKEN (CIDR
    # strings: the session networks' subnets and the ones Docker refused;
    # whitespace around them, such as docker's trailing newline, is
    # ignored), or nil when the pool is used up.
    def first_free(taken)
      used = taken.filter_map do |cidr|
        IPAddr.new(cidr.to_s.strip)
      rescue IPAddr::Error
        nil
      end
      step = 2**(32 - @prefix)
      (2**(@prefix - @pool.prefix)).times do |i|
        candidate = IPAddr.new(@pool.to_i + (i * step), Socket::AF_INET).mask(@prefix)
        next if used.any? { |u| u.include?(candidate) || candidate.include?(u) }

        return "#{candidate}/#{@prefix}"
      end
      nil
    end
  end
end
