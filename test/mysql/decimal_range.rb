require "cybertrain/test"
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require_relative "support/tables"
require "cybertrain/model"
require "cybertrain/schema"
require "cybertrain/encryptor"

# docs/compatibility.md's row "A decimal outside the column's precision":
# SQLite stores what the writers without validations hand it (the Float;
# test/decimal_contract.rb's "the writers without validations store a value
# outside the range"); MySQL's strict sql_mode refuses it with error 1264
# ("Out of range value").
# test/mysql/models_gen_app.rb ports the rest of test/decimal_contract.rb
# and points here. The same fixture models (test/fixtures/gen_app:
# posts.price a DECIMAL(10,2)), against the server CYBERTRAIN_TEST_MYSQL_URL
# names (script/test-mysql runs this program). Without it the guide's
# "refused" would outlive the connection losing STRICT_ALL_TABLES: MySQL
# would then store 99999999.99 with a warning and every other program would
# still pass.
require_relative "../fixtures/gen_app/db/schema"
require_relative "../fixtures/gen_app/gen/models/comment"
require_relative "../fixtures/gen_app/gen/models/post"
require_relative "../fixtures/gen_app/gen/concerns/models/concerns/visible"
require_relative "../fixtures/gen_app/app/models/comment"
require_relative "../fixtures/gen_app/app/models/post"

Cast = Cybertrain::Cast

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

# posts and comments as test/mysql/models_gen_app.rb creates them (the
# fixture's Post has_many :comments).
TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"
CREATE_TABLES_SQL =
  "CREATE TABLE posts (id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255) NOT NULL, body MEDIUMTEXT, " \
  "views INT NOT NULL DEFAULT 0, price DECIMAL(10,2), comments_count INT NOT NULL DEFAULT 0, meta JSON, " \
  "published_on DATE, secret_note MEDIUMTEXT, thumbnail LONGBLOB, hidden INT NOT NULL DEFAULT 0, " \
  "created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL, UNIQUE KEY posts_title (title))" \
  "#{TABLE_OPTIONS};" \
  "CREATE TABLE comments (id BIGINT AUTO_INCREMENT PRIMARY KEY, post_id BIGINT NOT NULL, " \
  "commenter VARCHAR(255) NOT NULL, body MEDIUMTEXT NOT NULL, approved TINYINT(1) DEFAULT FALSE, " \
  "extras JSON NOT NULL, seen_on DATE NOT NULL, due_on DATE NOT NULL DEFAULT '2026-01-01', " \
  "created_at DATETIME(6) NOT NULL, updated_at DATETIME(6) NOT NULL, KEY index_comments_on_post_id (post_id), " \
  "FOREIGN KEY (post_id) REFERENCES posts(id))#{TABLE_OPTIONS};"

Cybertrain.config.encryption_key = "8f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
Cybertrain::DB.connect(URL, size: 1)
# Dropped first, by name, with any table of the other test/mysql programs
# that references one of them (test/mysql/support/tables.rb).
Cybertrain::DB.with { |c| MySQLTestTables.drop(c, ["comments", "posts"]) }
Cybertrain::DB.with { |c| c.exec_script(CREATE_TABLES_SQL) }

def reset_tables
  Cybertrain::DB.with { |c| c.exec_script("DELETE FROM comments; DELETE FROM posts;") }
end

# The stored DECIMAL's text; "NULL" for none, "(no row)" without the row.
def stored(title)
  rows = Cybertrain::DB.with do |c|
    c.execute("SELECT CAST(price AS CHAR) AS tx FROM posts WHERE title = ?", [title])
  end
  return "(no row)" if rows.empty?

  text = Cast.str_or_nil(rows[0]["tx"])
  text.nil? ? "NULL" : text
end

OUT_OF_RANGE = "Out of range value for column 'price'"
CODE = "(MySQL 1264, 22003)"

test "update_columns and update_all are refused a value outside the precision (1264)" do
  reset_tables
  post = Post.create(title: "r", price: "1.00")
  message = assert_raises("Cybertrain::DB::Error") { post.update_columns(price: 123456789012.5) }
  assert_includes message, OUT_OF_RANGE
  assert_includes message, CODE
  message = assert_raises("Cybertrain::DB::Error") { Post.where(title: "r").update_all(price: 123456789012.5) }
  assert_includes message, OUT_OF_RANGE
  assert_includes message, CODE
  # One past DECIMAL(10,2)'s largest value, which SQLite stores.
  message = assert_raises("Cybertrain::DB::Error") { Post.where(title: "r").update_all(price: "100000000.00") }
  assert_includes message, CODE
  assert_equal "1.00", stored("r")
end

test "insert_all is refused a value outside the precision and writes none of its rows" do
  reset_tables
  message = assert_raises("Cybertrain::DB::Error") do
    Post.insert_all([{ title: "i1", price: "1.00" }, { title: "i2", price: 123456789012.5 }])
  end
  assert_includes message, OUT_OF_RANGE
  assert_includes message, CODE
  assert_equal 0, Post.count
end

# Not here yet: Infinity and NaN. A DECIMAL holds neither, and through
# insert_all (a Float bound as a binary DOUBLE) MySQL 8.0.46 stores 0.00 for
# each, with no error, where SQLite stores Inf and NULL; checked on
# 2026-11-28. The adapter is to refuse a non-finite Float bind before it is
# sent, with a test of its own beside that change.

Cybertrain::Test.run!
