# Shared by the test/mysql programs (each one
# `require_relative "support/tables"`). Not a test program itself:
# script/test-mysql runs test/mysql/*.rb only.
#
# MySQLTestTables.drop(conn, own) drops a program's own tables before it
# creates them, by name (DROP TABLE IF EXISTS), never by listing the
# database: CYBERTRAIN_TEST_MYSQL_URL may name a database that holds other
# tables. With them go the tables of the other test/mysql programs that
# hold a foreign key to one of them (REFERENCING, followed transitively):
# such a table, left behind by another program, keeps rows that name ids
# of a same-named table here, and would refuse this program's DELETEs.
# Everything is dropped with the session's foreign key checks off, and
# they are on again afterwards.
module MySQLTestTables
  # A table of these programs => the tables of these programs with a
  # foreign key to it (test/mysql/models.rb, models_gen_app.rb,
  # models_nested_includes.rb, models_through.rb, dialect.rb).
  REFERENCING = {
    "posts" => ["comments", "taggings"],
    "users" => ["profiles", "notes", "tasks", "audits"],
    "authors" => ["articles", "comments", "profiles", "posts"],
    "articles" => ["comments"],
    "comments" => ["likes"],
    "tags" => ["taggings"]
  }

  # `own` and every table that references one of them, transitively.
  def self.closure(own)
    names = Array.new(0) { "" }
    own.each { |name| names << name }
    i = 0
    while i < names.size
      children = REFERENCING[names[i]]
      unless children.nil?
        children.each { |child| names << child unless names.include?(child) }
      end
      i += 1
    end
    names
  end

  # @param conn [Cybertrain::DB::Connection]
  # @param own [Array<String>] the tables the program creates
  # @return [nil]
  def self.drop(conn, own)
    Cybertrain::DB::Dialect.foreign_keys_off(conn)
    MySQLTestTables.closure(own).each do |name|
      quoted = Cybertrain::DB::Dialect.quote_ident(name)
      conn.exec_script("DROP TABLE IF EXISTS #{quoted}")
    end
    Cybertrain::DB::Dialect.foreign_keys_on(conn)
    nil
  end
end
