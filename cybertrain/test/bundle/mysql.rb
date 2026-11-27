# Cybertrain::Test::Bundle's database on MySQL (cybertrain/test/bundle_mysql,
# the MySQL bundle, requires it after cybertrain/test/bundle/common; the
# program has the MySQL adapter): Bundle.refusal, whether the database
# DATABASE_URL names may be emptied, and Bundle.fresh_database, its tables
# dropped and migrated again. cybertrain/test/bundle/sqlite.rb is the same
# on SQLite.
#
# No database is created or dropped (only `cybertrain db create` / `db
# drop` do that): the user provides it, and the bundle empties it. The
# guard is DB::MySQL::TestDatabase's (cybertrain/db/mysql/test_database.rb):
# the environment "test", a database name that ends in "_test", and the
# table cybertrain_test_marker, which the bundle creates in an empty
# database; a database with tables and no marker is refused. Messages name
# the database by its URL without the password.
require "cybertrain/config"
require "cybertrain/migration"
require "cybertrain/db/migrator"
require "cybertrain/test/database"
require "cybertrain/test/bundle/common"

module Cybertrain
  module Test
    module Bundle
      # How the bundle's refusals begin on MySQL (SQLite's: "cybertrain test
      # refuses to delete", since it deletes the file).
      MYSQL_WHO = "cybertrain test refuses to empty"

      # Why boot must not empty the database config.database_url names (""
      # when it may), decided before anything connects: DATABASE_URL is
      # empty or not a MySQL URL, the environment is not test, or the
      # database's name does not end in "_test".
      # @return [String]
      def self.refusal
        c = Cybertrain.config
        Cybertrain::DB::MySQL::TestDatabase.url_refusal(MYSQL_WHO, c.env, c.database_url)
      end

      # Connects to config.database_url, claims the database (the marker
      # table there, or created in an empty database; else {Refused} and
      # nothing is changed), drops every other table and migrates
      # Migration.all, quietly: what {boot} runs after {refusal}. Each DDL
      # statement commits on its own (MySQL).
      # @return [nil]
      # @raise [Refused] when the database has tables and no marker table
      def self.fresh_database
        url = Cybertrain.config.database_url
        connection = Cybertrain::DB::Connection.new(url)
        problem = Cybertrain::DB::MySQL::TestDatabase.claim_refusal(MYSQL_WHO, connection, url)
        unless problem.empty?
          connection.close
          raise Refused, problem
        end
        Cybertrain::DB::MySQL::TestDatabase.drop_all_but_marker(connection)
        migrator = Cybertrain::DB::Migrator.new(connection)
        migrator.quiet!
        migrator.migrate(Cybertrain::Migration.all)
        connection.close
        nil
      end
    end
  end
end
