# Cybertrain::DB -- SQLite access: one process-wide connection pool.
#
#   Cybertrain::DB.connect("storage/development.sqlite3")
#   rows = Cybertrain::DB.with { |c| c.execute("SELECT * FROM posts WHERE id = ?", [1]) }
require "cybertrain/db/error"
require "cybertrain/db/sqlite_ffi"
require "cybertrain/db/connection"
require "cybertrain/db/pool"

module Cybertrain
  module DB
    # A module-level ivar, not @@pool: see spikes/NOTES.md rule 18.
    @pool = nil

    def self.connect(path, size: 4)
      disconnect
      @pool = Pool.new(path, size)
    end

    def self.pool
      @pool
    end

    def self.connected?
      !@pool.nil?
    end

    # Returns the block's value. Forward the block with &block: re-yielding
    # from an inner block loses the value under Spinel.
    def self.with(&block)
      current = @pool
      raise Error, "not connected: call Cybertrain::DB.connect first" if current.nil?
      current.with(&block)
    end

    def self.disconnect
      current = @pool
      current.close_all unless current.nil?
      @pool = nil
    end
  end
end
