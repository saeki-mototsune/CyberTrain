module Cybertrain
  module DB
    # Raised for every failed SQLite call (a failed statement's message is
    # SQLite's own followed by `(sql: ...)`; a failed open names the path)
    # and for misuse of the layer: not connected, a closed connection or
    # pool, a missing database file, an applied version with no migration.
    #
    # An application meets it when SQLite refuses a statement a model or a
    # query sent: a NOT NULL, unique or foreign key constraint, a missing
    # column, a full disk, a lock that outlasted the busy timeout. Unhandled
    # in an action it is a 500. Rescue it around one statement (a unique
    # index as the last word on a duplicate), map it with
    # `rescue_from Cybertrain::DB::Error, with: :database_error`, or name it
    # in a job's `retry_on`. Inside a {Cybertrain::DB.transaction} block do
    # not rescue it and carry on: let it leave the block.
    # @api public
    class Error < StandardError
    end
  end
end
