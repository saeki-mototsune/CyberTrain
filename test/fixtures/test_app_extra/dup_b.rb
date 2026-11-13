def new_client
  Cybertrain::Test::Client.new(Cybertrain::Test.app)
end

test "b" do
  assert new_client
end
