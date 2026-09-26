require "cybertrain/test"
require_relative "fixtures/embed_app/gen/views"

# The literals gen/views.rb emits read back, compiled by Spinel, to the
# same bytes as the files they came from. Also runs under CRuby.

test "every embedded view equals its file byte for byte" do
  ["layouts/application.html.erb", "pages/hello.html.erb"].each do |key|
    assert_equal File.read("test/fixtures/embed_app/app/views/#{key}"), Gen::Views::SOURCES[key]
  end
  assert_equal 2, Gen::Views::SOURCES.size
end

test "an embedded build defaults CYBERTRAIN_ENV to production" do
  assert_equal "production", ENV["CYBERTRAIN_ENV"]
end

Cybertrain::Test.run!
