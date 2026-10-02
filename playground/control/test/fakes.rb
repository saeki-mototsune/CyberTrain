# frozen_string_literal: true

# Stand-ins for Docker, the readiness probe and the clocks (spec §8.2).

# Wall clock, monotonic clock and sleep that move only when told to.
class FakeClock
  attr_reader :monotonic

  def initialize(now: 1_800_000_000)
    @wall = now.to_f
    @monotonic = 1000.0
  end

  def now
    @wall.floor
  end

  def advance(seconds)
    @wall += seconds
    @monotonic += seconds
  end

  def sleep(seconds)
    advance(seconds)
  end
end

module PlayTestHelpers
  def play_config(env = {})
    @data_dir ||= Dir.mktmpdir("play-test")
    Play::Config.new({ "PLAY_PUBLIC_URL" => "https://play.example.test",
                       "PLAY_SESSION_IMAGE" => "ghcr.io/example/cybertrain-playground-web@sha256:0123",
                       "PLAY_ABUSE_CONTACT" => "abuse@example.test",
                       "PLAY_DATA_DIR" => @data_dir }.merge(env))
  end

  def teardown
    FileUtils.rm_rf(@data_dir) if @data_dir
    super
  end
end
