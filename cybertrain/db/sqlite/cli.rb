require "cybertrain/db/error"
require "cybertrain/db/base"
require "cybertrain/db/cli"
require "cybertrain/db/normalizer"
require "cybertrain/config"
require "cybertrain/cast"
require "securerandom"

module Cybertrain
  module DB
    # Cybertrain::DB::CLI's SQLite part (cybertrain/db/cli.rb has what the
    # adapters share; cybertrain/core requires this file, and
    # cybertrain/db/mysql/cli.rb is MySQL's, method for method).
    #
    # The database is Cybertrain.config.database_path once the app has
    # loaded its config (config/app.rb calling Cybertrain.configure);
    # otherwise the same defaults Config uses, read from ENV on every call:
    # ENV["CYBERTRAIN_DATABASE"], or "storage/#{env}.sqlite3" with env from
    # ENV["CYBERTRAIN_ENV"] || "development".
    module CLI
      def self.usage
        puts "usage: db (migrate|rollback [N]|status|schema|schema:dump|create|backup PATH [--force]|backup DIR/ [--keep N]|vacuum|normalize)"
        1
      end

      # An empty CYBERTRAIN_DATABASE counts as unset (it would otherwise
      # resolve to the app root directory itself).
      def self.database_path
        return Cybertrain.config.database_path if Cybertrain.config_loaded?

        Config.default_database_path(Config.default_env)
      end

      # An absolute CYBERTRAIN_DATABASE is used as is; a relative one (and
      # the storage/<env>.sqlite3 default) is relative to the app root.
      # SQLite's own names -- ":memory:" and "file:" URIs -- are not files
      # under the root and pass through unchanged.
      def self.resolved_path(root)
        path = database_path
        return path if path.start_with?("/") || sqlite_name?(path)
        "#{root}/#{path}"
      end

      # ":memory:" and "file:..." name a database without naming a file on
      # disk, so nothing checks for or creates one.
      def self.sqlite_name?(path)
        path == ":memory:" || path.start_with?("file:")
      end

      def self.create(root)
        path = resolved_path(root)
        if !sqlite_name?(path) && File.exist?(path)
          puts "database already exists: #{path}"
          return 0
        end
        ConfigFiles.make_directory(File.dirname(path)) unless sqlite_name?(path)
        Connection.new(path).close
        puts "created #{path}"
        0
      end

      # `db drop` is not a command on SQLite (delete the file): the answer
      # to an unknown command.
      def self.drop(root)
        puts "unknown command: drop"
        usage
        1
      end

      # The database migrate runs on: the file, created with its directory
      # when it is missing.
      def self.open_for_migrate(root)
        path = resolved_path(root)
        ConfigFiles.make_directory(File.dirname(path)) unless sqlite_name?(path)
        Connection.new(path)
      end

      # What `db schema` says the dump was read from: the database's path.
      def self.schema_source(root)
        resolved_path(root)
      end

      # Rewrites 0.4's "...T...Z" datetime cells into the stored format
      # (Normalizer); one line per DATETIME column. Exits 1 when a skipped
      # table still holds cells that need normalization, so a deploy does not
      # start the new binaries on old-format rows.
      # Needs SQLite 3.37.0 or newer (PRAGMA table_list); an older linked
      # SQLite is refused with "db normalize failed: ..." and exit 1 before
      # anything is read or written.
      def self.normalize(root)
        connection = open_existing(root)
        status = 0
        begin
          Normalizer.run(connection).each do |row|
            if row[2].to_i < 0
              why = row[3].to_i == Normalizer::WITHOUT_ROWID ? "without rowid" : "declares _rowid_"
              left = row[4].to_i
              if left > 0
                puts "skipped #{row[0]}.#{row[1]}: #{why} (#{left} rows still need normalization)"
                status = 1
              else
                puts "skipped #{row[0]}.#{row[1]}: #{why}"
              end
            else
              puts "normalized #{row[0]}.#{row[1]}: #{row[2]} rows (#{row[3]} unreadable left alone)"
            end
          end
        ensure
          connection.close
        end
        puts "done"
        status
      end

      # rollback/status/schema/schema:dump never create a database file by
      # accident: a plain path is checked here for a clear message, and the
      # connection is opened without OPEN_CREATE so that SQLite refuses a
      # missing file named any other way (a "file:" URI) as well. An
      # in-memory database is fresh on every open anyway.
      def self.open_existing(root)
        path = resolved_path(root)
        unless sqlite_name?(path) || File.exist?(path)
          raise Error, "database does not exist: #{path} (run `db migrate` or `db create`)"
        end
        Connection.new(path, create: false)
      end

      # ---- backup and vacuum (issue #76, docs/design.md D30) -------------

      # The oldest SQLite with VACUUM INTO (3.27.0), in the form of
      # sqlite3_libversion_number.
      VACUUM_INTO_VERSION = 3_027_000

      # `db backup PATH [--force]` and `db backup DIR/ [--keep N]`: a
      # consistent copy of the database while the server keeps running
      # (VACUUM INTO reads one snapshot; under WAL writers go on). A target
      # ending in "/" or naming an existing directory gets a dated file,
      # DIR/<name>-<YYYYmmddTHHMMSSZ>.sqlite3 (UTC), and --keep N then
      # deletes the oldest such files beyond N; nothing else in DIR is
      # touched. A plain PATH that exists is refused unless --force. now is
      # a UTC Time (a parameter so that a test can name the file).
      def self.backup(root, args, name, now)
        target = ""
        force = false
        keep = 0
        i = 0
        while i < args.size
          arg = args[i]
          if arg == "--force"
            force = true
          elsif arg == "--keep"
            count = i + 1 < args.size ? args[i + 1] : ""
            # Cast.digits? is true for "", hence the empty check; nine
            # digits at most keeps to_i in range (NOTES rule 25).
            if count.empty? || count.size > 9 || !Cast.digits?(count) || count.to_i < 1
              raise Error, "--keep needs a positive number, got #{count.inspect}"
            end
            keep = count.to_i
            i += 1
          elsif arg.start_with?("--")
            raise Error, "unknown option #{arg}"
          elsif target.empty?
            target = arg
          else
            raise Error, "unexpected argument #{arg.inspect}"
          end
          i += 1
        end
        raise Error, "usage: db backup PATH [--force] | db backup DIR/ [--keep N]" if target.empty?

        source = backup_source(root)
        directory = target.end_with?("/") || File.directory?(target)
        raise Error, "--keep needs a directory target (DIR/), got #{target}" if keep > 0 && !directory

        prefix = name.empty? ? File.basename(source, ".sqlite3") : name
        if directory
          dir = target.end_with?("/") && target.size > 1 ? target[0, target.size - 1] : target
          # Backups hold password digests and session tokens: a directory
          # made here is the owner's alone.
          ConfigFiles.make_directory(dir, 0o700)
          stamp = now.strftime("%Y%m%dT%H%M%SZ")
          file = "#{prefix}-#{stamp}.sqlite3"
          path = File.join(dir, file)
          backup_to(source, path, force)
          puts "backed up #{source} to #{path}"
          prune_backups(dir, prefix, keep) if keep > 0
        else
          backup_to(source, target, force)
          puts "backed up #{source} to #{target}"
        end
        0
      end

      # The database file a backup or vacuum works on: it must exist and be
      # a file. ":memory:" and "file:" URIs are refused (nothing on disk to
      # copy, or no plain path to compare a target with).
      def self.backup_source(root)
        path = resolved_path(root)
        raise Error, "the database is #{path}, not a file on disk" if sqlite_name?(path)
        raise Error, "database does not exist: #{path} (run `db migrate` or `db create`)" unless File.file?(path)

        path
      end

      # Writes the copy into a temporary directory next to target, made
      # with mode 0700 (the copy holds password digests and tokens: nobody
      # else can reach a file inside it, whatever mode SQLite creates it
      # with), VACUUM INTO a fresh name in there (SQLite must create the
      # file itself: macOS's SQLite refuses a pre-created empty one with
      # "output file already exists"), chmods it to 0600, fsyncs it and
      # renames it over target, so target is either what it was or the whole
      # new copy, never a partial one. On any failure the temporary
      # directory and its contents go and the error is re-raised. The rescue
      # sits in this plain method (NOTES rules 32/45).
      def self.backup_to(source, target, force)
        raise Error, "#{target} is a directory" if File.directory?(target)
        parent = File.dirname(target)
        raise Error, "no such directory: #{parent}" unless File.directory?(parent)
        raise Error, "#{target} already exists (pass --force to replace it)" if File.exist?(target) && !force
        # VACUUM INTO would read a "file:" name as a URI (OPEN_URI).
        raise Error, "the target must be a plain path, not #{target}" if target.start_with?("file:")
        if File.expand_path(target) == File.expand_path(source)
          raise Error, "the target is the database itself (#{source})"
        end

        suffix = "#{Process.pid}-#{SecureRandom.hex(4)}"
        holder = "#{target}.tmp-#{suffix}"
        Dir.mkdir(holder, 0o700)
        # mkdir's mode is cut by the umask; the directory is empty until the
        # chmod lands, so nothing is exposed in between.
        File.chmod(0o700, holder)
        tmp = "#{holder}/copy"
        begin
          vacuum_into(source, tmp)
          # SQLite created the file under the umask; the mode must not
          # depend on that.
          File.chmod(0o600, tmp)
          sync_file(tmp)
          File.rename(tmp, target)
        rescue StandardError => e
          remove_temporary(holder, tmp)
          raise e
        end
        remove_temporary(holder, tmp)
        nil
      end

      # VACUUM INTO on a connection of its own (outside any transaction, as
      # SQLite requires), with the file name bound as a parameter.
      def self.vacuum_into(source, tmp)
        connection = Connection.new(source, create: false)
        begin
          version = sqlite_version_number(connection)
          if version < VACUUM_INTO_VERSION
            raise Error, "backup needs SQLite 3.27.0 or newer for VACUUM INTO (this binary has #{sqlite_version_text(version)})"
          end
          connection.execute("VACUUM INTO ?", [tmp])
        ensure
          connection.close
        end
        nil
      end

      # SELECT sqlite_version() ("3.45.1") as 3045001, the form of
      # sqlite3_libversion_number. Indexes, not `a, b, c = text.split(".")`
      # (NOTES rule 12).
      def self.sqlite_version_number(connection)
        rows = connection.execute("SELECT sqlite_version() AS v")
        text = rows.empty? ? "" : Cast.str(rows[0]["v"])
        parts = text.split(".")
        number = 0
        j = 0
        while j < 3
          part = j < parts.size ? parts[j] : "0"
          part = "0" if part.empty? || part.size > 4 || !Cast.digits?(part)
          number = number * 1000 + part.to_i
          j += 1
        end
        number
      end

      def self.sqlite_version_text(number)
        "#{number / 1_000_000}.#{(number / 1000) % 1000}.#{number % 1000}"
      end

      # Flushes the copy to disk before the rename makes it the backup.
      def self.sync_file(path)
        f = File.open(path, File::RDWR)
        f.fsync
        f.close
        nil
      end

      # The temporary copy, whatever SQLite left beside it, and the directory
      # that held them.
      def self.remove_temporary(holder, tmp)
        [tmp, "#{tmp}-journal", "#{tmp}-wal", "#{tmp}-shm"].each do |f|
          File.delete(f) if File.exist?(f)
        end
        Dir.rmdir(holder) if Dir.exist?(holder)
        nil
      end

      # Deletes the oldest dated backups of prefix in dir beyond keep. Only
      # names of exactly the shape `backup` writes count (their timestamps
      # sort as text), so another application's backups, a temporary file
      # being written and anything else in dir stay.
      def self.prune_backups(dir, prefix, keep)
        names = Array.new(0) { "" }
        Dir.children(dir).each do |entry|
          names << entry if dated_backup?(entry, prefix)
        end
        names.sort!
        excess = names.size - keep
        k = 0
        while k < excess
          path = File.join(dir, names[k])
          File.delete(path)
          puts "removed #{path}"
          k += 1
        end
        nil
      end

      # Whether entry is "<prefix>-YYYYmmddTHHMMSSZ.sqlite3". Read through a
      # local (NOTES rule 62).
      def self.dated_backup?(entry, prefix)
        s = entry.to_s
        head = "#{prefix}-"
        tail = ".sqlite3"
        return false unless s.bytesize == head.bytesize + 16 + tail.bytesize
        return false unless s.start_with?(head) && s.end_with?(tail)

        from = head.bytesize
        k = 0
        while k < 16
          b = s.getbyte(from + k).to_i
          ok = if k == 8
                 b == 84 # T
               elsif k == 15
                 b == 90 # Z
               else
                 b >= 48 && b <= 57
               end
          return false unless ok
          k += 1
        end
        true
      end

      # `db vacuum`: VACUUM (rebuilds the file without its free pages), then
      # PRAGMA wal_checkpoint(TRUNCATE), which copies the rebuilt pages from
      # the WAL into the database file, truncates the file to its new size
      # and empties the WAL, so the disk really gets the space back. Prints
      # the size on disk (database plus WAL) before and after.
      def self.vacuum(root)
        path = backup_source(root)
        sizes = vacuum_database(path)
        puts "vacuumed #{path}: #{sizes[0]} -> #{sizes[1]} bytes"
        if sizes[2] != 0
          puts "the checkpoint could not finish (another connection is reading); the WAL shrinks at a later checkpoint"
        end
        0
      end

      # [bytes before, bytes after, the checkpoint's busy flag (0: done)].
      def self.vacuum_database(path)
        before = disk_bytes(path)
        busy = 0
        connection = Connection.new(path, create: false)
        begin
          connection.exec_script("VACUUM")
          rows = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
          busy = Cast.int(rows[0]["busy"]) unless rows.empty?
        ensure
          connection.close
        end
        [before, disk_bytes(path), busy]
      end

      # The database file plus its WAL, in bytes.
      def self.disk_bytes(path)
        wal = "#{path}-wal"
        total = File.size(path)
        total += File.size(wal) if File.exist?(wal)
        total
      end

      # ---- what Main says and runs for the database ---------------------

      # The `db` lines of `./<name> help` (Main.usage). The continuation
      # lines up under "migrate" whatever the name.
      # @param name [String] the binary's name
      # @return [String]
      def self.usage_lines(name)
        indent = "".ljust(name.size + 23)
        "  ./#{name} db COMMAND        migrate | rollback [N] | status | schema | schema:dump | create\n" \
          "#{indent}backup PATH [--force] | backup DIR/ [--keep N] | vacuum | normalize\n"
      end

      # What `help` says `dbconsole` does.
      # @return [String]
      def self.console_description
        "open the sqlite3 shell on the database"
      end

      # The client `dbconsole` runs (Main.run_dbconsole).
      # @return [String]
      def self.console_program
        "sqlite3"
      end

      # Its arguments: the database path, with "./" before one that starts
      # with "-" so that sqlite3 does not take it for an option.
      # @param config [Cybertrain::Config]
      # @return [Array<String>]
      def self.console_args(config)
        path = config.database_path
        [path.start_with?("-") ? "./#{path}" : path]
      end

      # What is added to its environment: nothing.
      # @param config [Cybertrain::Config]
      # @return [Hash{String => String}]
      def self.console_env(config)
        env = { "" => "" }
        env.delete("")
        env
      end
    end
  end
end
