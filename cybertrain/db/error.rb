module Cybertrain
  module DB
    # Raised for every failed database call, on either adapter (a failed
    # statement's message is the database's own followed by `(sql: ...)`:
    # SQLite's text, or MySQL's with "(MySQL CODE, SQLSTATE)"; a failed
    # open names the SQLite path or the MySQL server, never its password),
    # and for misuse of the layer: not connected, a closed connection or
    # pool, a missing database file, an applied version with no migration.
    # The classes below narrow it; each is an Error.
    #
    # An application meets it when the database refuses a statement a model
    # or a query sent: a NOT NULL, unique or foreign key constraint, a
    # missing column, a full disk, a lock that outlasted the busy timeout
    # (SQLite) or innodb_lock_wait_timeout (MySQL). Unhandled
    # in an action it is a 500. Rescue it around one statement (a unique
    # index as the last word on a duplicate), map it with
    # `rescue_from Cybertrain::DB::Error, with: :database_error`, or name it
    # in a job's `retry_on`. Inside a {Cybertrain::DB.transaction} block do
    # not rescue it and carry on: let it leave the block.
    # @api public
    class Error < StandardError
    end

    # A unique or primary key constraint refused a statement (a duplicate).
    # The message is the database's own, as for {Error}. An {Error}, so
    # rescuing {Error} still catches it.
    # @api public
    class UniqueViolation < Error
    end

    # A foreign key constraint refused a statement (a missing parent or a
    # row still referenced). An {Error}.
    # @api public
    class ForeignKeyViolation < Error
    end

    # The database rolled a statement or transaction back to break a lock
    # cycle; the caller may run the transaction again. An {Error}.
    # @api public
    class Deadlock < Error
    end

    # A statement gave up waiting for a lock. An {Error}.
    # @api public
    class LockTimeout < Error
    end

    # The connection to the database was lost (the server went away). An
    # {Error}.
    # @api public
    class ConnectionLost < Error
    end

    # The names of the subclasses of {Error} above. Code that compares a
    # class by name (`rescue_from`, a String given to `assert_raises`) asks
    # {.error_subclass?}, so that a handler or an expectation for
    # Cybertrain::DB::Error covers them as the `rescue` clause does.
    ERROR_SUBCLASSES = [
      "Cybertrain::DB::UniqueViolation", "Cybertrain::DB::ForeignKeyViolation",
      "Cybertrain::DB::Deadlock", "Cybertrain::DB::LockTimeout", "Cybertrain::DB::ConnectionLost"
    ].freeze

    # Whether the class named `name` is a subclass of {Error}.
    # @api private
    def self.error_subclass?(name)
      ERROR_SUBCLASSES.include?(name)
    end
  end
end
