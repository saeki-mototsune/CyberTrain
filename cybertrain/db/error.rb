module Cybertrain
  module DB
    # Raised for every failed SQLite call; the message ends with the SQL.
    class Error < StandardError
    end
  end
end
