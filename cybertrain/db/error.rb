module Cybertrain
  module DB
    # Raised for every failed SQLite call (a failed statement's message ends
    # with the SQL; a failed open names the path) and for misuse of the
    # layer: not connected, a closed connection, a missing database file, an
    # applied version with no migration.
    class Error < StandardError
    end
  end
end
