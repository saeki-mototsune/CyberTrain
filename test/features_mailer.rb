require "cybertrain/core"
require "cybertrain/mailer"
require "cybertrain/test"

# The core and cybertrain/mailer alone (the optional-subsystems design,
# docs/superpowers/specs/2026-11-13-optional-subsystems-design.md, section
# 3): it compiles without jobs (so no deliver_later), streams, feeds, the
# cache or rate limiting; the mailer registers no feature; Mailer is
# defined and checks an address before connecting anywhere. It links
# SQLite through FFI (the core's database), so its snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).

test "no feature is registered: the mailer needs no hook" do
  assert_equal 0, Cybertrain::Features.feature_count
end

test "Mailer is defined and checks an address" do
  assert_equal "Cybertrain::Mailer", Cybertrain::Mailer.name
  assert_equal "", Cybertrain::Mailer.address_problem("ada@example.com")
  refute Cybertrain::Mailer.address_problem("not an address").empty?
end

Cybertrain::Test.run!
