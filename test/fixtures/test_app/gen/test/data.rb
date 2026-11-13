# gen/test/data.rb, written by `spin run gen` from db/schema.rb and
# test/fixtures/*.yml. Do not edit: the tables `cybertrain test` clears
# before each test, the fixtures it then inserts, and their accessors.
require "cybertrain/test/test_case"
require "cybertrain/test/database"

module Gen
  module TestData
    TABLES = [
      "articles",
      "users"
    ].freeze
    FIXTURE_SQL = [
      "INSERT INTO \"articles\" (\"id\", \"title\", \"body\", \"author_id\", \"published\", \"published_at\", \"price\", \"created_at\", \"updated_at\") VALUES (980190962, 'First post', 'A body.', 663665735, 1, '2026-11-01 09:00:00.000000', 4.50, ?, ?)",
      "INSERT INTO \"articles\" (\"id\", \"title\", \"author_id\", \"created_at\", \"updated_at\") VALUES (298486374, 'Second post', 663665735, ?, ?)",
      "INSERT INTO \"users\" (\"id\", \"name\", \"email\", \"created_at\", \"updated_at\") VALUES (663665735, 'Alice', 'alice@example.com', ?, ?)"
    ].freeze
    FIXTURE_TIMESTAMPS = [2, 2, 2].freeze
    LABELS_articles = ["one", "two"].freeze
    IDS_articles = [980190962, 298486374].freeze
    LABELS_users = ["alice"].freeze
    IDS_users = [663665735].freeze
  end

  # One accessor per fixture file: posts(:one) is Post.find(one's id).
  module TestFixtures
    def self.articles(label) = Article.find(Cybertrain::Test.fixture_id("articles", label, TestData::LABELS_articles, TestData::IDS_articles))
    def self.users(label) = User.find(Cybertrain::Test.fixture_id("users", label, TestData::LABELS_users, TestData::IDS_users))
  end
end

# The accessors in a class-form test.
class ActiveSupport::TestCase
  def articles(label) = Gen::TestFixtures.articles(label)
  def users(label) = Gen::TestFixtures.users(label)
end

# The accessors in a top-level-form test.
def articles(label) = Gen::TestFixtures.articles(label)
def users(label) = Gen::TestFixtures.users(label)
