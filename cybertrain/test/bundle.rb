# Cybertrain::Test::Bundle on the SQLite adapter: the whole framework
# (cybertrain/test/bundle/common holds the runner, cybertrain/test/bundle/
# sqlite the test database). bundle_mysql is the same with the MySQL
# adapter.
require "cybertrain"
require "cybertrain/test/bundle/common"
require "cybertrain/test/bundle/sqlite"
