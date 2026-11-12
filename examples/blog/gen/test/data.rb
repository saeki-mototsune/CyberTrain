# gen/test/data.rb, written by `spin run gen` from db/schema.rb and
# test/fixtures/*.yml. Do not edit: the tables `cybertrain test` clears
# before each test, the fixtures it then inserts, and their accessors.
require "cybertrain/test/test_case"
require "cybertrain/test/database"

module Gen
  module TestData
    TABLES = [
      "articles",
      "comments",
      "sessions",
      "users"
    ].freeze
    FIXTURE_SQL = Array.new(0) { "" }.freeze
    FIXTURE_TIMESTAMPS = Array.new(0) { 0 }.freeze
  end

  # One accessor per fixture file: posts(:one) is Post.find(one's id).
  module TestFixtures
  end
end

# The accessors in a class-form test.
class ActiveSupport::TestCase
end

# The accessors in a top-level-form test.
