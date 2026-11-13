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
    FIXTURE_SQL = [
      "INSERT INTO \"articles\" (\"id\", \"title\", \"body\", \"created_at\", \"updated_at\") VALUES (980190962, 'Hello Rails', 'I am on Rails! This is my first article.', '2024-03-10 09:00:00.000000', '2024-03-10 09:00:00.000000')",
      "INSERT INTO \"articles\" (\"id\", \"title\", \"body\", \"created_at\", \"updated_at\") VALUES (298486374, 'Second article', 'Another article, with no comments.', '2024-03-11 09:00:00.000000', '2024-03-11 09:00:00.000000')",
      "INSERT INTO \"comments\" (\"id\", \"article_id\", \"commenter\", \"body\", \"created_at\", \"updated_at\") VALUES (980190962, 980190962, 'Alice', 'Great post!', ?, ?)",
      "INSERT INTO \"users\" (\"id\", \"email_address\", \"password_digest\", \"admin\", \"failed_attempts\", \"created_at\", \"updated_at\") VALUES (980190962, 'one@example.com', '$pbkdf2-sha256$i=1000$TVm7F1wtCGC7XYu9N8eYxA$w9Wrwn06gGtWMp-GYualC8a_eoTmb5JpsR6vWNEjWhw', 1, 0, ?, ?)",
      "INSERT INTO \"users\" (\"id\", \"email_address\", \"password_digest\", \"admin\", \"failed_attempts\", \"created_at\", \"updated_at\") VALUES (298486374, 'two@example.com', '$pbkdf2-sha256$i=1000$Di4aRryuOtDWZbLp5uVIfg$et5GPodQhaZphHt0ZPOqWLCSZu2oHhGJaLaK0ybh6Ps', 0, 0, ?, ?)"
    ].freeze
    FIXTURE_TIMESTAMPS = [0, 0, 2, 2, 2].freeze
    LABELS_articles = ["one", "two"].freeze
    IDS_articles = [980190962, 298486374].freeze
    LABELS_comments = ["one"].freeze
    IDS_comments = [980190962].freeze
    LABELS_users = ["one", "two"].freeze
    IDS_users = [980190962, 298486374].freeze
  end

  # One accessor per fixture file: posts(:one) is Post.find(one's id).
  module TestFixtures
    def self.articles(label) = Article.find(Cybertrain::Test.fixture_id("articles", label, TestData::LABELS_articles, TestData::IDS_articles))
    def self.comments(label) = Comment.find(Cybertrain::Test.fixture_id("comments", label, TestData::LABELS_comments, TestData::IDS_comments))
    def self.users(label) = User.find(Cybertrain::Test.fixture_id("users", label, TestData::LABELS_users, TestData::IDS_users))
  end
end

# The accessors in a class-form test.
class ActiveSupport::TestCase
  def articles(label) = Gen::TestFixtures.articles(label)
  def comments(label) = Gen::TestFixtures.comments(label)
  def users(label) = Gen::TestFixtures.users(label)
end

# The accessors in a top-level-form test.
def articles(label) = Gen::TestFixtures.articles(label)
def comments(label) = Gen::TestFixtures.comments(label)
def users(label) = Gen::TestFixtures.users(label)
