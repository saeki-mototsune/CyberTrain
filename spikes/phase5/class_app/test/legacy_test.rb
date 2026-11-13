# The top-level form, bundled beside the classes: Test::Client's positional
# get / post and the top-level two-argument assert_response.
test "the top-level form beside the classes" do
  client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
  assert_response client.get("/articles"), :success
  assert_response client.post("/articles", { "article[title]" => "y" }), :redirect
  assert_equal "One", articles(:one).title.sub("First", "One")
  assert_equal 3, users(:alice).articles.count # the two fixtures and the one posted
end
