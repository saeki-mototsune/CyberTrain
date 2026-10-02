# frozen_string_literal: true

require_relative "test_helper"

# playground/web-smoke.sh runs its session with the hardening flags between
# "# BEGIN hardened run" and "# END hardened run"; production runs
# Play::Templates.hardening. The two must not drift apart (spec §8.2).
class DriftTest < Minitest::Test
  include PlayTestHelpers

  SMOKE = File.expand_path("../../web-smoke.sh", __dir__)

  def test_the_smoke_tests_hardened_run_is_the_templates_hardening
    block = File.read(SMOKE)[/^# BEGIN hardened run\n(.*?)^# END hardened run$/m, 1]
    refute_nil block, "#{SMOKE} has no '# BEGIN hardened run' ... '# END hardened run' block"
    flags = block.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") || %w[hardened=( )].include?(line) }
    assert_equal Play::Templates.hardening(play_config), flags.flat_map(&:split)
  end
end
