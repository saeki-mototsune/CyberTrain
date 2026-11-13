# What Task 8's gen/test/data.rb would hold for test/fixtures/users.yml
# (alice) and articles.yml (one, two), hand-written: the tables, one INSERT
# per row with Rails' CRC-32 ids, and the fixture accessors.
module Gen
  module TestData
    TABLES = %w[articles users].freeze
    FIXTURE_SQL = [
      "INSERT INTO \"users\" (\"id\", \"name\", \"created_at\", \"updated_at\") VALUES (663665735, 'Alice', '2026-11-01 09:00:00', '2026-11-01 09:00:00')",
      "INSERT INTO \"articles\" (\"id\", \"user_id\", \"title\", \"created_at\", \"updated_at\") VALUES (980190962, 663665735, 'First', '2026-11-01 09:00:00', '2026-11-01 09:00:00')",
      "INSERT INTO \"articles\" (\"id\", \"user_id\", \"title\", \"created_at\", \"updated_at\") VALUES (298486374, 663665735, 'Second', '2026-11-01 09:00:00', '2026-11-01 09:00:00')"
    ].freeze
    LABELS_articles = %w[one two].freeze
    IDS_articles = [980_190_962, 298_486_374].freeze
    LABELS_users = %w[alice].freeze
    IDS_users = [663_665_735].freeze

    def self.fixture_id(set, label, labels, ids)
      i = labels.index(label.to_s)
      if i.nil?
        text = "No fixture named '#{label}' found for fixture set '#{set}'"
        raise ArgumentError, text
      end
      ids[i]
    end

    def self.clear_and_load
      Cybertrain::DB.with do |c|
        c.execute("PRAGMA foreign_keys = OFF")
        c.execute("BEGIN")
        TABLES.each { |t| c.execute("DELETE FROM \"#{t}\"") }
        FIXTURE_SQL.each { |sql| c.execute(sql) }
        c.execute("COMMIT")
        c.execute("PRAGMA foreign_keys = ON")
      end
      nil
    end

    def self.reset_hook = -> { Gen::TestData.clear_and_load }
  end

  module TestFixtures
    def self.articles(label) = Article.find(Gen::TestData.fixture_id("articles", label, Gen::TestData::LABELS_articles, Gen::TestData::IDS_articles))
    def self.users(label) = User.find(Gen::TestData.fixture_id("users", label, Gen::TestData::LABELS_users, Gen::TestData::IDS_users))
  end
end

# Instance forwarders (class form) beside User#articles (has_many).
class ActiveSupport::TestCase
  def articles(label) = Gen::TestFixtures.articles(label)
  def users(label) = Gen::TestFixtures.users(label)
end

# Top-level forwarders (top-level form).
def articles(label) = Gen::TestFixtures.articles(label)
def users(label) = Gen::TestFixtures.users(label)
