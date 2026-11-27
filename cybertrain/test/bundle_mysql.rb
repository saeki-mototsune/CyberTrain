# Cybertrain::Test::Bundle on the MySQL adapter (cybertrain/test/bundle is the
# same with SQLite): cybertrain/test/bundle/common holds the runner,
# cybertrain/test/bundle/mysql the test database. Not compiled whole yet
# (cybertrain/mysql is completed by later tasks); test/mysql/test_database.rb
# compiles bundle/mysql's part.
require "cybertrain/mysql"
require "cybertrain/test/bundle/common"
require "cybertrain/test/bundle/mysql"
