# Cybertrain::Test::Bundle on the MySQL adapter (cybertrain/test/bundle is the
# same with SQLite): cybertrain/test/bundle/common holds the runner,
# cybertrain/test/bundle/mysql the test database. test/mysql/bundle_boot.rb
# compiles it whole, with cybertrain/test_help, and boots it;
# test/mysql/test_database.rb tests bundle/mysql's part.
require "cybertrain/mysql"
require "cybertrain/test/bundle/common"
require "cybertrain/test/bundle/mysql"
