# Copied to test/dup_a.rb with dup_b.rb by script/test-command-e2e: two
# bundled files defining one top-level helper are refused.
def new_client
  Cybertrain::Test::Client.new(Cybertrain::Test.app)
end

test "a" do
  assert new_client
end
