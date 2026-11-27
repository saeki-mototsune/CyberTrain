# The MySQL adapter's Cybertrain::DB::Adapter: which adapter the program
# was built with, and what DB.connect is given. The Dialect (the SQL that
# differs from SQLite's, cybertrain/db/sqlite/dialect.rb) joins it here in
# a later task.
require "cybertrain/db/error"

module Cybertrain
  module DB
    # Cybertrain::DB::Adapter (MySQL). Chosen by the entry a program
    # requires (cybertrain/db/mysql); nothing branches on it at run time.
    module Adapter
      # What an application on MySQL is told when DATABASE_URL is empty:
      # the boot stops (Application#acquire_boot_resources, through
      # connect_target) before anything connects.
      MISSING_URL = "DATABASE_URL is not set (mysql://user:password@host:3306/name)"

      # "mysql" (SQLite: "sqlite"). Not `name` (spikes/NOTES.md rule 66).
      # @return [String]
      def self.adapter_name
        "mysql"
      end

      # What DB.connect opens for `config`: the server's URL,
      # config.database_url (from DATABASE_URL). An empty one stops the
      # boot with MISSING_URL; the URL itself is never in a message (its
      # faults are named by Url, without the password).
      # @param config [Cybertrain::Config]
      # @return [String]
      # @raise [Cybertrain::DB::Error] when config.database_url is empty
      def self.connect_target(config)
        url = config.database_url
        raise Error, MISSING_URL if url.empty?

        url
      end
    end
  end
end
