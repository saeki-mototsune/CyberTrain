# Cybertrain::DB::MySQL::TestDatabase -- whether `cybertrain test` and
# Test::Database may empty a MySQL database (docs/design.md D82 and D83's
# guard on MySQL), shared by the MySQL bundle (cybertrain/test/
# bundle_mysql.rb) and Test::Database (through DB::Dialect's
# test_database_refusal and test_database_claim).
#
# A database is emptied only when all of these hold:
#   1. the environment is "test";
#   2. the URL's database name ends in "_test";
#   3. it holds the table MARKER_TABLE (what the bundle creates first in a
#      database it takes, as SQLite's bundle writes Test::Database::
#      TEST_MARKER into a file it creates), or it is empty, in which case
#      the table is created then.
# 1 and 2 are decided from the URL before anything connects
# (url_refusal); 3 on a connection (claim_refusal). No database is ever
# created or dropped: the user provides it (a managed MySQL often grants
# no CREATE DATABASE).
#
# Messages name the database by the URL without its password (Url#to_s,
# "mysql://app@db.internal:3306/shop_test"), in the SQLite refusals' form:
# "<who> <url>: <reason>".
require "cybertrain/cast"
require "cybertrain/db/error"
require "cybertrain/db/mysql/url"

module Cybertrain
  module DB
    module MySQL
      # @api private
      module TestDatabase
        # The table that marks a database as one `cybertrain test` took.
        MARKER_TABLE = "cybertrain_test_marker".freeze

        # The end of the refusal of a database with tables and no
        # MARKER_TABLE (SQLite's: Test::Database::NOT_CREATED).
        NOT_CREATED = "not a database cybertrain test created (it has tables and no cybertrain_test_marker table); " \
                      "empty it yourself or name another database".freeze

        # "" when env and the URL `target` name a database that may be
        # emptied (rules 1 and 2), else the refusal "<who> <url>: <reason>".
        # Nothing connects.
        # @param who [String] "Test::Database refuses to empty", "cybertrain test refuses to empty"
        # @param env [String]
        # @param target [String] the mysql:// URL
        # @return [String]
        def self.url_refusal(who, env, target)
          return "#{who} the database: #{Cybertrain::DB::Adapter::MISSING_URL}" if target.empty?

          fault = TestDatabase.url_fault(target)
          return "#{who} the database: #{fault}" unless fault.empty?

          url = MySQL::Url.parse(target)
          label = url.to_s
          return "#{who} #{label}: not a test database (env #{env})" unless env == "test"
          return "#{who} #{label}: not a test database (its name does not end in _test)" unless url.database.end_with?("_test")

          ""
        end

        # "" when the database `conn` is on may be emptied (rule 3): it holds
        # MARKER_TABLE, or it holds no table or view, and MARKER_TABLE is
        # created now (DDL: outside any transaction). Else the refusal
        # "<who> <url>: NOT_CREATED", and nothing is changed.
        # @param who [String]
        # @param conn [Cybertrain::DB::Connection]
        # @param target [String] the URL `conn` was opened on (for the message)
        # @return [String]
        def self.claim_refusal(who, conn, target)
          return "" if Dialect.table_exists?(conn, MARKER_TABLE)

          rows = conn.execute("SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()")
          if Cybertrain::Cast.int(rows[0]["n"]) > 0
            label = MySQL::Url.parse(target).to_s
            return "#{who} #{label}: #{NOT_CREATED}"
          end
          TestDatabase.mark(conn)
          ""
        end

        # Creates MARKER_TABLE when it is not there.
        # @param conn [Cybertrain::DB::Connection]
        # @return [nil]
        def self.mark(conn)
          conn.exec_script("CREATE TABLE IF NOT EXISTS #{MARKER_TABLE} (marker INT NOT NULL)" +
                           Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS)
          nil
        end

        # Drops every table of the database `conn` is on but MARKER_TABLE,
        # foreign key checks off around it: what the bundle does where
        # SQLite's deletes the file (then it migrates again).
        # @param conn [Cybertrain::DB::Connection]
        # @return [nil]
        def self.drop_all_but_marker(conn)
          Dialect.foreign_keys_off(conn)
          Dialect.table_names(conn).each do |name|
            next if name == MARKER_TABLE

            quoted = Dialect.quote_ident(name)
            conn.exec_script("DROP TABLE #{quoted}")
          end
          Dialect.foreign_keys_on(conn)
          nil
        end

        # The URL's fault ("" when it parses): Url's message, which never
        # holds the password. The rescue in this plain method (NOTES rules
        # 32/45).
        # @return [String]
        def self.url_fault(target)
          MySQL::Url.parse(target)
          ""
        rescue ArgumentError => e
          e.message
        end
      end
    end
  end
end
