# Shared by the test/mysql programs of the framework's services (jobs.rb,
# cache.rb, lease.rb, stream.rb, timetable.rb; each one
# `require_relative "support/services"` after "support/tables"). Not a
# test program itself: script/test-mysql runs test/mysql/*.rb only.
#
# Their SQLite originals start a test on a fresh `:memory:` database with
# DB.connect, where every framework table is missing until a service's
# first use creates it. MySQLServices.fresh_db is that start on the server
# CYBERTRAIN_TEST_MYSQL_URL names: it connects DB's pool and drops the
# framework tables and the program's own (MySQLTestTables.drop, by name),
# so the next use creates them again (DB.connect moves DB.generation, which
# every service's ensure_installed reads) and their AUTO_INCREMENT starts
# at 1 again, as SQLite's ids do in a new database.
module MySQLServices
  # The tables the framework creates itself (DB::SchemaDumper leaves them
  # out). test/mysql/dialect.rb makes its own, smaller, ones of the same
  # names, which must not be taken for the framework's.
  FRAMEWORK_TABLES = ["cybertrain_jobs", "cybertrain_cache", "cybertrain_leases", "cybertrain_messages",
                      "cybertrain_schedules", "cybertrain_feeds"].freeze

  # @param url [String] CYBERTRAIN_TEST_MYSQL_URL
  # @param own [Array<String>] the other tables the program creates
  # @return [nil]
  def self.fresh_db(url, own)
    # Two connections: a test may hold one in a transaction, or use one
    # per thread, while the other answers.
    Cybertrain::DB.connect(url, size: 2)
    names = Array.new(0) { "" }
    FRAMEWORK_TABLES.each { |name| names << name }
    own.each { |name| names << name }
    Cybertrain::DB.with { |c| MySQLTestTables.drop(c, names) }
    nil
  end

  # The dumped table names among `names`, in their order: what a
  # SchemaDumper of the shared database lists of this program's tables
  # (the SQLite originals compare the whole list of a database that holds
  # nothing else).
  # @param names [Array<String>]
  # @return [String] the names joined with ","
  def self.dumped(names)
    found = Cybertrain::DB.with { |c| Cybertrain::DB::SchemaDumper.table_names(c) }
    out = Array.new(0) { "" }
    names.each { |name| out << name if found.include?(name) }
    out.join(",")
  end
end
