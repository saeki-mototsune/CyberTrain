# Required by cybertrain/job.rb, after the registry it reads.
module Cybertrain
  module Job
    # The queue's rows: every SQL statement on `cybertrain_jobs` is here
    # (or, where the adapters differ, in DB::Dialect's job_* methods), and
    # nothing else is. A method is one storage operation (create the
    # table, insert a row, claim the oldest due row, write a claimed
    # attempt's outcome, touch heartbeats, requeue stale rows, count,
    # prune), atomic where the queue's guarantees need it: the claim is one
    # BEGIN IMMEDIATE transaction (on MySQL, BEGIN and a SELECT ... FOR
    # UPDATE of the row: DB::Dialect.job_claim_lock) and the outcome write
    # is one UPDATE fenced by the claim. It starts no thread, sleeps
    # nowhere, calls no handler and does not know whether a pool runs:
    # {Job::Executor} and {Job::Worker} call it, and it reads the registry ({Job::HANDLERS},
    # through Job's lookups) only for what a statement depends on, the
    # concurrency limits and keys. A claim carries its caller's ticket,
    # which the store hands back to {Job.claim_open?} once it holds the
    # write lock, without knowing what the ticket stands for (D78). The
    # public entry points and their
    # documentation are the `Job.*` methods of cybertrain/job.rb, which
    # delegate here.
    module Store
      TABLE = "cybertrain_jobs"

      # Times are Integer epoch seconds (UTC), not DATETIME text: the worker
      # compares run_at with `now` in SQL and needs no parsing. The index
      # serves the worker's "oldest due queued row" query.
      # claimed_by is the claiming process's {Job.process_label} and
      # heartbeat_at the last time that process said the job still runs
      # ({Job.heartbeat!}); both are NULL until the first claim.
      # concurrency_key is the row's {Job.concurrency_key_for}, written at
      # enqueue; "" for a kind with no key. request_id is the id of the
      # request the job was enqueued in (the enqueuing thread's log Scope),
      # the parent's for a job enqueued by a job, "" outside both; the
      # job's log lines carry it. A table made before these columns
      # existed gets them from install! (ALTER_COLUMNS), last, so an upgraded
      # table lists the same columns in the same order as a new one.
      # The CREATE TABLE and its (state, run_at) index are the adapter's
      # (DB::Dialect.job_table_sql), run by
      # DB::Dialect.framework_table_install.

      # The columns added after the table's first release, each with the
      # ALTER TABLE that adds it to an older table.
      ALTER_COLUMNS = [
        ["claimed_by", "ALTER TABLE cybertrain_jobs ADD COLUMN claimed_by TEXT"],
        ["heartbeat_at", "ALTER TABLE cybertrain_jobs ADD COLUMN heartbeat_at INTEGER"],
        ["concurrency_key", "ALTER TABLE cybertrain_jobs ADD COLUMN concurrency_key TEXT NOT NULL DEFAULT ''"],
        ["request_id", "ALTER TABLE cybertrain_jobs ADD COLUMN request_id TEXT NOT NULL DEFAULT ''"]
      ].freeze

      # Job.backfill_keys reads and keys this many rows at a time.
      BACKFILL_BATCH = 1000

      # The DB.generation the table was last ensured for; -1 for never.
      @installed_generation = -1

      # Test hook: how many outcome writes still fail on purpose.
      @failing_outcome_writes = 0

      # Inserts a `queued` row and returns its id ({Job.enqueue}, which has
      # checked the kind and derived the key, and passes the request id of
      # the enqueuing thread's Scope: a request's, a parent job's, or "").
      def self.insert(kind, payload, run_at, key, request_id)
        ensure_installed
        now = Clock.now.to_i
        binds = Cast.binds(kind, payload, run_at, now, now, key, request_id)
        id = 0
        DB.with do |c|
          c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, created_at, updated_at, concurrency_key, request_id) " \
                    "VALUES (?, ?, ?, ?, ?, ?, ?)", binds)
          id = c.last_insert_id
        end
        id
      end

      # {Job.backfill_keys}: keys the unkeyed `queued` rows of each keyed
      # kind, {BACKFILL_BATCH} rows at a time, each UPDATE only while the
      # row is still unkeyed. Returns how many rows were keyed.
      def self.backfill_keys(now)
        ensure_installed
        keyed = 0
        Job.keyed_kinds.each { |kind| keyed += backfill_kind(kind) }
        keyed
      end

      # backfill_keys for one kind: pages through its unkeyed queued rows by
      # id (a row left "" is not read twice), keying each batch in one
      # transaction.
      def self.backfill_kind(kind)
        name = Job.job_key_name(kind)
        keyed = 0
        after = 0
        left = Array.new(0) { "" }
        loop do
          rows = DB.with do |c|
            c.execute("SELECT id, payload FROM cybertrain_jobs WHERE kind = ? AND state = 'queued' " \
                      "AND concurrency_key = '' AND id > ? ORDER BY id LIMIT ?", Cast.binds(kind, after, BACKFILL_BATCH))
          end
          break if rows.empty?

          DB.transaction(immediate: true) do |c|
            rows.each do |row|
              id = Cast.int(row["id"])
              after = id
              key = Job.concurrency_key_for(kind, Cast.str(row["payload"]))
              if key.empty?
                left << id.to_s
              else
                c.execute("UPDATE cybertrain_jobs SET concurrency_key = ? WHERE id = ? AND concurrency_key = ''",
                          Cast.binds(key, id))
                keyed += c.changes
              end
            end
          end
          break if rows.size < BACKFILL_BATCH
        end
        unless left.empty?
          Cybertrain.logger.warn("#{left.size} queued job(s) of #{kind} have no #{name.inspect} field to key them by; " \
                                 "left in the \"\" bucket: ids #{capped_list(left)}")
        end
        keyed
      end

      # The most ids an unkeyable-row warning lists (a legacy table can hold
      # thousands of them, and the warning comes at every start).
      LISTED_IDS = 20

      # The first LISTED_IDS of items joined with ", ", and "... and N more"
      # when there are more.
      def self.capped_list(items)
        return items.join(", ") if items.size <= LISTED_IDS

        shown = items[0, LISTED_IDS].join(", ")
        "#{shown} ... and #{items.size - LISTED_IDS} more"
      end

      # {Job.install!}: creates the table and its indexes if they are
      # missing, and adds the columns an earlier release's table lacks.
      def self.install!
        DB.with { |c| DB::Dialect.framework_table_install(c, TABLE, DB::Dialect.job_table_sql) }
        add_missing_columns
        # The index the claim's per-key count and the backfill read, once
        # concurrency_key exists (after the ALTERs, for an older table).
        DB.with { |c| DB::Dialect.job_key_index(c) }
        # Only a CREATE outside a transaction is remembered: one inside a
        # transaction that rolls back is gone again
        # ({DB.outside_transaction?}).
        @installed_generation = DB.generation if DB.outside_transaction?
        nil
      end

      # The ALTER TABLEs of the ALTER_COLUMNS DB::Dialect.column_names does
      # not list. Two processes upgrading at once could both see a column missing:
      # outside a transaction the read and the ALTERs run under the write lock
      # (BEGIN IMMEDIATE), and a "duplicate column name" from a process that
      # still won the race (inside a caller's transaction, or an older
      # release's ALTER) is taken as "already there" and the check runs again.
      # (MySQL takes no table lock at BEGIN, so there the race is caught only
      # by this rescue; its message is "Duplicate column name", SQLite's
      # "duplicate column name", hence the comparison without case.)
      def self.add_missing_columns
        add_columns_once
      rescue Cybertrain::DB::Error => e
        raise e unless e.message.downcase.include?("duplicate column")

        add_columns_once
      end

      def self.add_columns_once
        if DB.outside_transaction?
          DB.transaction(immediate: true) { |c| alter_missing(c) }
        else
          DB.with { |c| alter_missing(c) }
        end
        nil
      end

      def self.alter_missing(conn)
        present = DB::Dialect.column_names(conn, "cybertrain_jobs")
        ALTER_COLUMNS.each do |pair|
          conn.execute(pair[1]) unless present.include?(pair[0])
        end
        nil
      end

      # install! unless it already ran since the last DB.connect.
      def self.ensure_installed
        install! unless @installed_generation == DB.generation
        nil
      end

      # {Job.recover!}: requeues the `running` rows whose heartbeat is NULL
      # or older than `now - stale`, after failing those whose stopped
      # attempt was their last (fail_exhausted). A row of a keyed kind is
      # requeued with its key written in the same UPDATE. Returns how many
      # rows were requeued.
      def self.requeue_stale(now, stale)
        ensure_installed
        fail_exhausted(now, stale)
        keyed = Job.keyed_kinds
        count = keyed.empty? ? 0 : recover_keyed(now, now - stale, keyed)
        binds = Cast.binds(now, now - stale)
        sql = +"UPDATE cybertrain_jobs SET state = 'queued', updated_at = ? WHERE state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)"
        append_kind_list(sql, binds, " AND kind NOT IN (", keyed)
        DB.with do |c|
          c.execute(sql, binds)
          count += c.changes
        end
        count
      end

      # The part of recover! for the `keyed` kinds: each stale running row
      # is requeued by its own UPDATE that writes its key, while it is still
      # running and stale. A row the derivation cannot key is requeued with
      # "" (its own bucket under the kind's limit), and those rows are listed
      # in one warn line with their ids. Returns how many it requeued.
      def self.recover_keyed(now, cutoff, keyed)
        binds = Cast.binds(cutoff)
        sql = +"SELECT id, kind, payload FROM cybertrain_jobs WHERE state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)"
        append_kind_list(sql, binds, " AND kind IN (", keyed)
        sql << " ORDER BY id"
        count = 0
        left = Array.new(0) { "" }
        DB.with do |c|
          rows = c.execute(sql, binds)
          rows.each do |row|
            id = Cast.int(row["id"])
            kind = Cast.str(row["kind"])
            key = Job.concurrency_key_for(kind, Cast.str(row["payload"]))
            c.execute("UPDATE cybertrain_jobs SET state = 'queued', concurrency_key = ?, updated_at = ? WHERE id = ? " \
                      "AND state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)",
                      Cast.binds(key, now, id, cutoff))
            changed = c.changes
            count += changed
            left << "#{id} (#{kind})" if changed > 0 && key.empty?
          end
        end
        unless left.empty?
          Cybertrain.logger.warn("#{left.size} requeued job(s) have no concurrency key field to key them by; " \
                                 "left in the \"\" bucket: ids #{capped_list(left)}")
        end
        count
      end

      # Appends `prefix` and one bound `?` per kind and ")" to sql, and the
      # kinds to binds; nothing when kinds is empty.
      def self.append_kind_list(sql, binds, prefix, kinds)
        return nil if kinds.empty?

        sql << prefix
        i = 0
        while i < kinds.size
          sql << ", " if i > 0
          sql << "?"
          binds << kinds[i]
          i += 1
        end
        sql << ")"
        nil
      end

      # The part of recover! for rows whose stopped attempt was their last
      # (the kind's {Job.recovery_limit}; the claim counted it): they become
      # `failed` with last_error "process stopped (heartbeat stale) during
      # attempt N of MAX", logged as a handler's last failure is, rather than
      # queued again, so a payload that kills its process is not retried for
      # ever. Each row is updated only while it is still stale and running
      # (another process may have recovered it in between). No kind's limit
      # is below Config#job_max_attempts, so the SELECT reads only rows at
      # that many attempts and each row is checked against its kind's limit.
      def self.fail_exhausted(now, stale)
        default = Cybertrain.config.job_max_attempts
        cutoff = now - stale
        ids = Array.new(0) { 0 }
        kinds = Array.new(0) { "" }
        messages = Array.new(0) { "" }
        DB.with do |c|
          rows = c.execute("SELECT id, kind, attempts FROM cybertrain_jobs WHERE state = 'running' " \
                           "AND (heartbeat_at IS NULL OR heartbeat_at < ?) AND attempts >= ? ORDER BY id",
                           Cast.binds(cutoff, default))
          rows.each do |row|
            kind = Cast.str(row["kind"])
            attempts = Cast.int(row["attempts"])
            max = Job.recovery_limit(kind)
            next if attempts < max

            id = Cast.int(row["id"])
            message = "process stopped (heartbeat stale) during attempt #{attempts} of #{max}"
            c.execute("UPDATE cybertrain_jobs SET state = 'failed', last_error = ?, updated_at = ? WHERE id = ? " \
                      "AND state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)",
                      Cast.binds(message, now, id, cutoff))
            next unless c.changes > 0

            ids << id
            kinds << kind
            messages << message
          end
        end
        i = 0
        while i < ids.size
          Cybertrain.logger.error("job #{ids[i]} (#{kinds[i]}) failed: #{messages[i]}")
          i += 1
        end
        nil
      end

      # {Job.heartbeat!}: marks as alive at `now` the `running` rows that
      # `label` claimed as one of `claims`, a flat list of the id and then
      # the attempt number of each attempt the caller has in flight. The
      # attempt is part of the predicate as it is of the outcome write's
      # (write_outcome): a row recovered and claimed again by the same
      # label is another claim, and an older attempt still running does
      # not keep it alive (D78). Returns how many rows it touched.
      # (The first design's statement was `WHERE state = 'running'
      # AND claimed_by = ?`; this adds the claims the caller has in flight.)
      def self.touch_heartbeats(now, label, claims)
        ensure_installed
        return 0 if claims.empty?

        binds = Cast.binds(now, label)
        sql = +"UPDATE cybertrain_jobs SET heartbeat_at = ? WHERE state = 'running' AND claimed_by = ? AND ("
        i = 0
        while i + 1 < claims.size
          sql << " OR " if i > 0
          sql << "(id = ? AND attempts = ?)"
          binds << claims[i]
          binds << claims[i + 1]
          i += 2
        end
        sql << ")"
        count = 0
        DB.with do |c|
          c.execute(sql, binds)
          count = c.changes
        end
        count
      end

      # {Job.running_count}.
      def self.running_count(kind)
        ensure_installed
        rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state = 'running' AND kind = ?", [kind]) }
        Cast.int(rows[0]["n"])
      end

      # What has reached its handler's limit, read on the claim's connection
      # inside its transaction from one count of the running rows per (kind,
      # concurrency_key). Returns the kinds limited without a key whose
      # running rows (of every key) reached the limit, and appends to `pairs`
      # the kind and key, one after the other, of each key of a keyed kind
      # at its limit ("" is a key like any other there).
      def self.kinds_at_limit(conn, pairs)
        full = Array.new(0) { "" }
        kinds = Array.new(0) { "" }
        counts = Array.new(0) { 0 }
        rows = conn.execute("SELECT kind, concurrency_key, COUNT(*) AS n FROM cybertrain_jobs WHERE state = 'running' " \
                            "GROUP BY kind, concurrency_key")
        rows.each do |r|
          kind = Cast.str(r["kind"])
          index = Job.handler_index(kind)
          next if index < 0

          handler = Job::HANDLERS[index]
          limit = handler.handler_concurrency
          next unless limit > 0

          n = Cast.int(r["n"])
          if handler.handler_concurrency_key.empty?
            at = kinds.index(kind)
            if at.nil?
              kinds << kind
              counts << n
            else
              counts[at] += n
            end
          elsif n >= limit
            pairs << kind
            pairs << Cast.str(r["concurrency_key"])
          end
        end
        i = 0
        while i < kinds.size
          full << kinds[i] if counts[i] >= Job::HANDLERS[Job.handler_index(kinds[i])].handler_concurrency
          i += 1
        end
        full
      end

      # Claims the oldest row due at `now` for `label`: the row becomes
      # `running` with one more attempt, `claimed_by` and a first
      # heartbeat, and comes back as the {Job::Run} of that attempt. When
      # nothing is due, or another claimer took the row, the Run's run_id
      # is -1 (a typed "none": NOTES rules 11/56) and nothing was written.
      # `ticket` is the caller's, opaque here: the claim asks
      # {Job.claim_open?} whether the caller still wants a row, and takes
      # none when it does not, once before it reads and again with the row
      # locked, before it writes (SQLite waits for its write lock at the
      # BEGIN IMMEDIATE, before the first question; MySQL at the SELECT,
      # between the two). The wait for the lock can be long (another
      # process's transaction), and what the caller checked before the wait
      # may no longer hold after it.
      def self.claim(now, label, ticket)
        ensure_installed
        # A read outside any transaction first: an idle thread then takes no
        # write lock (three BEGIN IMMEDIATEs a second per process otherwise,
        # each able to hold an OS worker in the busy handler while another
        # process writes).
        return no_run(label, now) unless due_exists?(now)

        run = no_run(label, now)
        # The claim is its own short BEGIN IMMEDIATE transaction: the SELECT
        # and the UPDATE run under the write lock, and the `state = 'queued'`
        # guard with the changes check refuses a row another claimer took.
        # The handler runs after the COMMIT, holding no lock.
        # With a concurrency limit, the kinds (and the keys of keyed kinds)
        # at their limit are read under the same lock and left out, so no two
        # claimers (threads or processes) can both take the last free slot.
        limited = Job.limits?
        DB.transaction(immediate: true) do |c|
          # On SQLite the write lock is held from here, so this is the
          # caller's last word on the claim; on MySQL the locks come with the
          # statements below, and the claim is asked again after them.
          if Job.claim_open?(ticket)
            # (MySQL takes row locks, not one write lock: the adapter makes
            # a limited claim wait for another's COMMIT before it counts.)
            DB::Dialect.job_claim_serialize(c, now) if limited
            pairs = Array.new(0) { "" }
            excluded = limited ? kinds_at_limit(c, pairs) : Array.new(0) { "" }
            # The SELECT leaves out the `excluded` kinds (one bound `?`
            # each, after run_at's) and then each (kind, key) of `pairs`
            # (two bound `?`s each).
            binds = Cast.binds(now)
            sql = +"SELECT id, kind, payload, attempts, request_id FROM cybertrain_jobs WHERE state = 'queued' AND run_at <= ?"
            append_kind_list(sql, binds, " AND kind NOT IN (", excluded)
            j = 0
            while j < pairs.size
              sql << " AND NOT (kind = ? AND concurrency_key = ?)"
              binds << pairs[j]
              binds << pairs[j + 1]
              j += 2
            end
            sql << " ORDER BY run_at, id LIMIT 1"
            sql << DB::Dialect.job_claim_lock
            found = c.execute(sql, binds)
            # Asked again once the SELECT returned: on MySQL the BEGIN above
            # took no lock, and the wait for one (job_claim_serialize's, or
            # the row lock of the SELECT's FOR UPDATE) came after the first
            # question; a stop requested during that wait is seen here,
            # before the row is taken. (On SQLite both questions run under
            # the write lock BEGIN IMMEDIATE took, and answer alike.)
            run = take_first(c, found, label, now) if Job.claim_open?(ticket)
          end
        end
        run
      end

      # Claims the queued row with the lowest id above `floor`, of `kind`
      # unless it is "" (a test's inline jobs, {Job.work_one_after}): a row
      # never attempted whatever its run_at, a retry only once its run_at
      # is due at `now`. As {claim} claims a due one: `running` with one
      # more attempt, `claimed_by`, a first heartbeat at `now`. The Run's
      # run_id is -1 when there is none. Ordered by id (enqueue order), not
      # by run_at as a worker claims. Concurrency limits are not consulted:
      # the caller runs one job at a time on its own thread, and its claim
      # is never withdrawn, so it carries no ticket.
      def self.claim_after(floor, kind, now, label)
        ensure_installed
        run = no_run(label, now)
        DB.transaction(immediate: true) do |c|
          sql = +"SELECT id, kind, payload, attempts, request_id FROM cybertrain_jobs WHERE state = 'queued' AND id > ? " \
                 "AND (attempts = 0 OR run_at <= ?)"
          binds = Cast.binds(floor, now)
          unless kind.empty?
            sql << " AND kind = ?"
            binds << kind
          end
          sql << " ORDER BY id LIMIT 1"
          sql << DB::Dialect.job_claim_lock
          run = take_first(c, c.execute(sql, binds), label, now)
        end
        run
      end

      # The Run that says nothing was claimed: run_id -1.
      def self.no_run(label, now)
        Run.new(-1, "", "", 0, label, now, "")
      end

      # Claims the first of `rows` (a claim SELECT's result) for `label` and
      # answers its Run, or {no_run} when there is no row or another claimer
      # took it. Must be called inside the caller's transaction, on its
      # connection (BEGIN IMMEDIATE on SQLite; on MySQL the claim SELECT's
      # FOR UPDATE holds the row): the SELECT and this UPDATE are one claim.
      def self.take_first(conn, rows, label, now)
        return no_run(label, now) if rows.empty?

        row = rows[0]
        id = Cast.int(row["id"])
        # (attempts is counted here; the outcome write and the heartbeat
        # are fenced by it.)
        conn.execute("UPDATE cybertrain_jobs SET state = 'running', attempts = attempts + 1, claimed_by = ?, " \
                     "heartbeat_at = ?, updated_at = ? WHERE id = ? AND state = 'queued'", Cast.binds(label, now, now, id))
        return no_run(label, now) unless conn.changes == 1

        Run.new(id, Cast.str(row["kind"]), Cast.str(row["payload"]), Cast.int(row["attempts"]) + 1, label, now,
                Cast.str(row["request_id"]))
      end

      # Whether some queued row is due at `now` (a plain read).
      def self.due_exists?(now)
        rows = DB.with { |c| c.execute("SELECT 1 AS one FROM cybertrain_jobs WHERE state = 'queued' AND run_at <= ? LIMIT 1", [now]) }
        !rows.empty?
      end

      # {Job.state_count}.
      def self.state_count(state)
        ensure_installed
        rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state = ?", [state]) }
        Cast.int(rows[0]["n"])
      end

      # {Job.prune_done}.
      def self.prune_done(before)
        ensure_installed
        count = 0
        DB.with do |c|
          c.execute("DELETE FROM cybertrain_jobs WHERE state = 'done' AND updated_at < ?", [before])
          count = c.changes
        end
        count
      end

      # {Job.prune_finished}.
      def self.prune_finished(before)
        ensure_installed
        count = 0
        DB.with do |c|
          c.execute("DELETE FROM cybertrain_jobs WHERE state IN ('failed', 'discarded') AND updated_at < ?", [before])
          count = c.changes
        end
        count
      end

      # Writes the outcome of the attempt claimed as (`label`, `attempts`)
      # in one UPDATE that only matches while the row is still `running`
      # under that claim: 1 when written, 0 when the row was reclaimed
      # (nothing written). A database error is raised to the caller, which
      # decides whether to try again ({Job::Executor.record_outcome}).
      def self.write_outcome(id, state, run_at, error, now, label, attempts)
        if @failing_outcome_writes > 0
          @failing_outcome_writes -= 1
          raise Cybertrain::DB::Error, "outcome write failed on purpose (test hook)"
        end
        binds = Cast.binds(state, run_at, error, now, id, label, attempts)
        written = 0
        DB.with do |c|
          c.execute("UPDATE cybertrain_jobs SET state = ?, run_at = ?, last_error = ?, updated_at = ? " \
                    "WHERE id = ? AND state = 'running' AND claimed_by = ? AND attempts = ?", binds)
          written = c.changes == 1 ? 1 : 0
        end
        written
      end

      # Makes the next `count` outcome writes raise, for tests of a database
      # that stays locked ({Job.fail_outcome_writes}).
      def self.fail_outcome_writes(count)
        @failing_outcome_writes = count
        nil
      end
    end
  end
end
