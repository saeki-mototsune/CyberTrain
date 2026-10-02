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

# Answers each docker argv from a script keyed by its leading words ("run",
# "network create", "ps sessions", "ps routers", ...) and records every argv.
# An answer is a Play::DockerCLI::Result, :timeout (raises like a hung
# docker), or a Proc that gets the argv. Queued answers (#on) come first,
# then the default for the key (#default), then success with no output.
class FakeDocker
  attr_reader :calls

  def self.ok(stdout = "")
    Play::DockerCLI::Result.new(0, stdout, "")
  end

  def self.fail(stderr, status: 1)
    Play::DockerCLI::Result.new(status, "", stderr)
  end

  def initialize
    @calls = []
    @queued = Hash.new { |hash, key| hash[key] = [] }
    @defaults = {}
  end

  def on(key, *answers)
    @queued[key].concat(answers)
    self
  end

  def default(key, answer)
    @defaults[key] = answer
    self
  end

  def run(argv, timeout:)
    raise ArgumentError, "timeout must be positive" unless timeout.positive?

    @calls << argv
    key = self.class.key(argv)
    answer = @queued[key].empty? ? @defaults.fetch(key, self.class.ok) : @queued[key].shift
    answer = answer.call(argv) if answer.respond_to?(:call)
    raise Play::DockerCLI::Timeout, "#{argv.first(3).join(" ")} did not finish within #{timeout} s" if answer == :timeout

    answer
  end

  def self.key(argv)
    words = argv.drop(1)
    case words.first
    when "network", "image" then words.first(2).join(" ")
    when "ps" then argv.include?("label=cybertrain-play.role=session") ? "ps sessions" : "ps routers"
    else words.first
    end
  end

  def calls_for(key)
    @calls.select { |argv| self.class.key(argv) == key }
  end

  def keys
    @calls.map { |argv| self.class.key(argv) }
  end
end

# Ready on the Nth call (ready_after: N), or never (ready_after: nil).
class FakeProbe
  attr_reader :calls

  def initialize(ready_after: 1)
    @ready_after = ready_after
    @calls = []
  end

  def ready?(sid)
    @calls << sid
    !@ready_after.nil? && @calls.size >= @ready_after
  end
end
