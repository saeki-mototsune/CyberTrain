# cybertrain/core/mysql: the core with the MySQL adapter and no SQLite
# (cybertrain/core is the same with SQLite).
require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/core/common"
# The database commands' MySQL part (cybertrain/db/cli.rb, which the core
# requires, is what the adapters share).
require "cybertrain/db/mysql/cli"
