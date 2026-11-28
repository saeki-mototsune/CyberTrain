require "cybertrain/cast"
require "cybertrain/db/base"

module Cybertrain
  module Scheduler
    # Cybertrain::Scheduler::Timetable -- the scheduler's persisted
    # timetable: one row per task name with when it last ran and when it
    # runs next, so that a restart or a change of leader continues the
    # timetable instead of starting it again.
    #
    # The rows live in `cybertrain_schedules`, which the framework creates
    # itself (`CREATE TABLE IF NOT EXISTS`, on first use) and leaves out of
    # `db/schema.rb`, like `cybertrain_jobs` and `cybertrain_leases`. Times
    # are epoch seconds; `last_run_at` is NULL until the task first runs.
    # @api public
    module Timetable
      # The table is the adapter's (DB::Dialect.timetable_table_sql), created by
      # DB::Dialect.framework_table_install.
      TABLE = "cybertrain_schedules"

      # The row writes are the adapter's (DB::Dialect.timetable_write_sql:
      # a last run of 0 is stored as NULL, never ran; a row is never moved
      # backwards: an update needs a later last run, or the same one and a
      # next run no earlier, as a leader that lost the lease while a task
      # ran writes after the new leader. DB::Dialect.timetable_insert_missing_sql:
      # a new task's row, left alone when one exists).

      # The DB.generation the table was last ensured for; -1 for never (as
      # Job's and Lease's).
      @installed_generation = -1

      # Creates the table if it is missing. The other methods call it once
      # per connected database.
      # @return [nil]
      # @api public
      def self.install!
        DB.with { |c| DB::Dialect.framework_table_install(c, TABLE, DB::Dialect.timetable_table_sql) }
        # A CREATE inside a transaction that rolls back is undone, so only
        # one outside a transaction is remembered (as Job.install! does).
        @installed_generation = DB.generation if DB.outside_transaction?
        nil
      end

      # install! unless it already ran since the last DB.connect.
      def self.ensure_installed
        install! unless @installed_generation == DB.generation
        nil
      end

      # Every row, by task name: `[last_run_at, next_run_at]`, with 0 for a
      # task that has not run yet.
      # @return [Hash{String => Array<Integer>}]
      # @raise [Cybertrain::DB::Error] when the database is not reachable
      # @api public
      def self.read_all
        ensure_installed
        out = { "" => [0, 0] }
        out.delete("")
        rows = DB.with { |c| c.execute("SELECT name, last_run_at, next_run_at FROM cybertrain_schedules ORDER BY name") }
        rows.each do |row|
          pair = Array.new(0) { 0 }
          pair << Cast.int(row["last_run_at"])
          pair << Cast.int(row["next_run_at"])
          out[Cast.str(row["name"])] = pair
        end
        out
      end

      # Records a task's last and next run (inserting its row or replacing
      # it). A row is never moved backwards: a write whose last run is
      # earlier than the row's, or the same with an earlier next run, is
      # ignored.
      # @param name [String] the task's name
      # @param last_run_at [Integer] epoch seconds; 0 when it has not run
      # @param next_run_at [Integer] epoch seconds
      # @param now [Integer] epoch seconds, stored as updated_at
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the database is not reachable
      # @api public
      def self.write(name, last_run_at, next_run_at, now)
        ensure_installed
        binds = Cast.binds(name, last_run_at, next_run_at, now)
        sql = DB::Dialect.timetable_write_sql
        DB.with { |c| c.execute(sql, binds) }
        nil
      end

      # Inserts a row for a task that has none (never run, next run
      # `next_run_at`); an existing row is left as it is.
      # @param name [String] the task's name
      # @param next_run_at [Integer] epoch seconds
      # @param now [Integer] epoch seconds, stored as updated_at
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the database is not reachable
      # @api public
      def self.write_missing(name, next_run_at, now)
        ensure_installed
        binds = Cast.binds(name, next_run_at, now)
        sql = DB::Dialect.timetable_insert_missing_sql
        DB.with { |c| c.execute(sql, binds) }
        nil
      end

      # Deletes the rows whose name is not in names.
      # @param names [Array<String>] the names to keep
      # @return [Integer] how many rows were deleted
      # @raise [Cybertrain::DB::Error] when the database is not reachable
      # @api public
      def self.prune(names)
        ensure_installed
        sql = +"DELETE FROM cybertrain_schedules"
        unless names.empty?
          sql << " WHERE name NOT IN ("
          i = 0
          while i < names.size
            sql << ", " if i > 0
            sql << "?"
            i += 1
          end
          sql << ")"
        end
        binds = Array.new(0) { "" }
        names.each { |n| binds << n }
        count = 0
        DB.with do |c|
          c.execute(sql, binds)
          count = c.changes
        end
        count
      end
    end
  end
end
