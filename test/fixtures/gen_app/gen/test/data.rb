# gen/test/data.rb, written by `spin run gen` from db/schema.rb and
# test/fixtures/*.yml. Do not edit: the tables `cybertrain test` clears
# before each test, the fixtures it then inserts, and their accessors.
require "cybertrain/test/test_case"
require "cybertrain/test/database"

module Gen
  module TestData
    TABLES = [
      "comments",
      "posts"
    ].freeze
    FIXTURE_SQL = [
      "INSERT INTO \"comments\" (\"id\", \"post_id\", \"commenter\", \"body\", \"approved\", \"extras\", \"seen_on\", \"created_at\", \"updated_at\") VALUES (115582124, 980190962, 'Ann', 'Nice post', 1, '{\"stars\":5}', '2026-11-02', ?, ?)",
      "INSERT INTO \"posts\" (\"id\", \"title\", \"body\", \"price\", \"meta\", \"published_on\", \"created_at\", \"updated_at\") VALUES (980190962, 'First post', 'A body long enough.', 4.50, '{\"tags\":[\"a\"]}', '2026-11-01', '2026-11-01 09:00:00.000000', ?)",
      "INSERT INTO \"posts\" (\"id\", \"title\", \"created_at\", \"updated_at\") VALUES (42, 'Second post', ?, ?)"
    ].freeze
    FIXTURE_TIMESTAMPS = [2, 1, 2].freeze
    LABELS_comments = ["greeting"].freeze
    IDS_comments = [115582124].freeze
    LABELS_posts = ["one", "two"].freeze
    IDS_posts = [980190962, 42].freeze
  end

  # One accessor per fixture file: posts(:one) is Post.find(one's id).
  module TestFixtures
    def self.comments(label) = Comment.find(Cybertrain::Test.fixture_id("comments", label, TestData::LABELS_comments, TestData::IDS_comments))
    def self.posts(label) = Post.find(Cybertrain::Test.fixture_id("posts", label, TestData::LABELS_posts, TestData::IDS_posts))
  end
end

# The accessors in a class-form test.
class ActiveSupport::TestCase
  def comments(label) = Gen::TestFixtures.comments(label)
  def posts(label) = Gen::TestFixtures.posts(label)
end

# The accessors in a top-level-form test.
def comments(label) = Gen::TestFixtures.comments(label)
def posts(label) = Gen::TestFixtures.posts(label)
