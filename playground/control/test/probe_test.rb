# frozen_string_literal: true

require_relative "test_helper"

# How Play::Probe sets up its request, with Net::HTTP replaced: no port is
# opened.
class ProbeTest < Minitest::Test
  include PlayTestHelpers

  SID = "0123456789abcdef0123456789abcdef"

  # Stands in for Net::HTTP: records the settings and the request.
  class FakeHTTP
    attr_accessor :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :args, :sent

    def initialize(*args)
      @args = args
    end

    def request(req)
      @sent = req
      Struct.new(:code, :body).new("200", '{"status":"alive"}')
    end
  end

  # Net::HTTP.new makes FakeHTTP objects while the block runs.
  def with_fake_http
    made = []
    meta = Net::HTTP.singleton_class
    meta.alias_method(:new_outside_probe_test, :new)
    meta.remove_method(:new)
    meta.define_method(:new) { |*args| FakeHTTP.new(*args).tap { |http| made << http } }
    yield made
  ensure
    meta.remove_method(:new)
    meta.alias_method(:new, :new_outside_probe_test)
    meta.remove_method(:new_outside_probe_test)
  end

  def test_one_attempt_bounded_by_the_timeout_to_the_routers_bare_address
    with_fake_http do |made|
      assert Play::Probe.new(play_config("PLAY_ROUTER_URL" => "http://[fd00::1]:8080")).ready?(SID)
      http = made.fetch(0)
      assert_equal ["fd00::1", 8080, nil], http.args
      assert_equal [2, 2, 2, 0], [http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries]
      assert_equal ["/healthz", "#{SID}.play.example.test"], [http.sent.path, http.sent["Host"]]
    end
  end
end
