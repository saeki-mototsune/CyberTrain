require "test_helper"

# The top-level form, bundled beside the class form: top-level setup and
# teardown around each test of this file.
setup do
  Article.all.delete_all
  User.all.delete_all
  User.create(name: "Bo", email: "bo@example.com")
end

teardown do
  Article.all.delete_all
end

test "shows an article" do
  author = User.find_by(name: "Bo")
  article = Article.create(title: "Hello", body: "A body.", author_id: author.id)
  client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
  response = client.get("/articles/#{article.id}")
  assert_response response, :success
  assert_equal "Hello by Bo", response.body
end

test "the configured zone" do
  assert_equal "Asia/Tokyo", Time.zone.zone_name
end

Cybertrain::Test.run!
