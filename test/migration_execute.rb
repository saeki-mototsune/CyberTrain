require "cybertrain/db/connection"
require "cybertrain/db/migrator"
require "cybertrain/db/schema_dumper"
require "cybertrain/test"

# Migration::Base#execute: a data statement recorded among the schema
# operations, run in order on the migrator's connection, in the version's
# transaction; irreversible in `change` unless the migration writes `down`.
#
# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class CreateBackups < Cybertrain::Migration::Base
  version "20260201000000"

  def change
    create_table "backups" do |t|
      t.string "name", null: false
    end
    create_table "audits" do |t|
      t.string "note", null: false
    end
  end
end

# The issue's example: existing rows keep "forever" (0), new rows get 90.
# The add_index after the execute must still run after it.
class AddRetentionDays < Cybertrain::Migration::Base
  version "20260201000100"

  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]
    add_index "backups", ["retention_days"]
  end
end

# The same with a hand-written down, which makes it reversible. The INSERT
# into audits shows that recording `up` during a rollback runs nothing.
class AddRetentionDaysWithDown < Cybertrain::Migration::Base
  version "20260201000100"

  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]
    execute "INSERT INTO audits (note) VALUES (?)", ["retention added"]
  end

  def down
    remove_column "backups", "retention_days"
  end
end

# The schema AddRetentionDays leaves, without the data step.
class AddRetentionDaysSchemaOnly < Cybertrain::Migration::Base
  version "20260201000100"

  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    add_index "backups", ["retention_days"]
  end
end

class SeedBackups < Cybertrain::Migration::Base
  version "20260201000200"

  def up
    execute "INSERT INTO backups (name) VALUES (?)", ["seeded"]
  end

  def down
    execute "DELETE FROM backups WHERE name = ?", ["seeded"]
  end
end

# No binds: a script of several statements.
class TwoStatements < Cybertrain::Migration::Base
  version "20260201000300"

  def up
    execute "INSERT INTO audits (note) VALUES ('one'); INSERT INTO audits (note) VALUES ('two')"
  end

  def down
    execute "DELETE FROM audits WHERE note IN ('one', 'two')"
  end
end

# A data step that fails takes the version's schema operations with it.
class BrokenDataStep < Cybertrain::Migration::Base
  version "20260201000400"

  def change
    add_column "backups", "label", :string
    execute "UPDATE no_such_table SET x = ?", [1]
  end
end

class AddNoteIndex < Cybertrain::Migration::Base
  version "20260201000500"

  def change
    add_index "audits", ["note"]
  end
end

# A database with CreateBackups applied, one row ("old") in backups, then
# `second` applied as version 20260201000100.
def migrated_with(second)
  connection = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrator.migrate([["20260201000000", CreateBackups.new]])
  connection.execute("INSERT INTO backups (name) VALUES (?)", ["old"])
  migrator.migrate([["20260201000000", CreateBackups.new], ["20260201000100", second]])
  connection
end

# -1 when there is no such row.
def retention_of(connection, name)
  rows = connection.execute("SELECT retention_days FROM backups WHERE name = ?", [name])
  rows.empty? ? -1 : rows[0]["retention_days"].to_s.to_i
end

def backup_columns(connection)
  connection.execute("PRAGMA table_info(backups)").map { |r| r["name"].to_s }
end

def audit_count(connection)
  connection.execute("SELECT COUNT(*) AS n FROM audits")[0]["n"].to_s.to_i
end

test "execute records an :execute operation in call order, with its binds cast, and runs nothing" do
  migration = AddRetentionDays.new
  migration.up
  kinds = migration.operations.map { |op| op.kind }
  assert_equal [:add_column, :execute, :add_index], kinds
  op = migration.operations[1]
  assert_equal "UPDATE backups SET retention_days = ?", op.exec_sql
  assert_equal 1, op.exec_binds.size
  assert_equal "", migration.operations[0].exec_sql
  assert_equal 0, migration.operations[0].exec_binds.size

  cast = AddRetentionDays.new
  cast.execute("UPDATE t SET a = ?, b = ?, c = ?, d = ?", [true, false, "x", nil])
  binds = cast.operations[0].exec_binds
  assert_equal 4, binds.size
  assert_equal "1", binds[0].to_s
  assert_equal "0", binds[1].to_s
  assert_equal "x", binds[2].to_s
  assert binds[3].nil?
end

test "execute in change runs after the add_column before it and before the add_index after it" do
  connection = migrated_with(AddRetentionDays.new)
  assert_equal 0, retention_of(connection, "old")
  connection.execute("INSERT INTO backups (name) VALUES (?)", ["new"])
  assert_equal 90, retention_of(connection, "new")
  indexes = connection.execute("PRAGMA index_list(backups)").map { |r| r["name"].to_s }
  assert_includes indexes, "index_backups_on_retention_days"
  connection.close
end

test "rolling back a change that executes SQL raises before reverting anything" do
  connection = migrated_with(AddRetentionDays.new)
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = [["20260201000000", CreateBackups.new], ["20260201000100", AddRetentionDays.new]]
  message = assert_raises("IrreversibleMigration") { migrator.rollback(migrations) }
  assert_equal "version 20260201000100 is irreversible: it executes SQL in change; write down", message
  assert_equal ["20260201000000", "20260201000100"], migrator.applied_versions
  assert_includes backup_columns(connection), "retention_days"

  # Two steps whose newest is reversible: the irreversible one below it
  # stops the rollback before the newest is reverted.
  migrations << ["20260201000500", AddNoteIndex.new]
  migrator.migrate(migrations)
  message = assert_raises("IrreversibleMigration") { migrator.rollback(migrations, 2) }
  assert_includes message, "version 20260201000100 is irreversible"
  assert_equal ["20260201000000", "20260201000100", "20260201000500"], migrator.applied_versions
  connection.close
end

test "a migration whose change executes SQL rolls back through its own down" do
  connection = migrated_with(AddRetentionDaysWithDown.new)
  assert_equal 0, retention_of(connection, "old")
  assert_equal 1, audit_count(connection)
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = [["20260201000000", CreateBackups.new], ["20260201000100", AddRetentionDaysWithDown.new]]
  assert_equal 1, migrator.rollback(migrations)
  refute backup_columns(connection).include?("retention_days")
  assert_equal ["20260201000000"], migrator.applied_versions
  # The rollback recorded up (to learn the forward operations) without
  # running its INSERT again.
  assert_equal 1, audit_count(connection)

  # Migrating again runs the data steps again, once.
  assert_equal 1, migrator.migrate(migrations)
  assert_equal 0, retention_of(connection, "old")
  assert_equal 2, audit_count(connection)
  connection.close
end

test "execute in an explicit up and down" do
  connection = migrated_with(AddRetentionDays.new)
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = [["20260201000000", CreateBackups.new], ["20260201000100", AddRetentionDays.new],
                ["20260201000200", SeedBackups.new], ["20260201000300", TwoStatements.new]]
  assert_equal 2, migrator.migrate(migrations)
  assert_equal 90, retention_of(connection, "seeded")
  assert_equal 2, audit_count(connection)
  assert_equal 1, migrator.rollback(migrations)
  assert_equal 0, audit_count(connection)
  assert_equal 1, migrator.rollback(migrations)
  assert_equal(-1, retention_of(connection, "seeded"))
  assert_equal 0, retention_of(connection, "old")
  assert_equal ["20260201000000", "20260201000100"], migrator.applied_versions
  connection.close
end

test "a failing execute rolls back the schema operations of its version" do
  connection = migrated_with(AddRetentionDays.new)
  migrator = Cybertrain::DB::Migrator.new(connection)
  migrations = [["20260201000000", CreateBackups.new], ["20260201000100", AddRetentionDays.new],
                ["20260201000400", BrokenDataStep.new]]
  message = assert_raises("Cybertrain::DB::Error") { migrator.migrate(migrations) }
  assert_includes message, "no_such_table"
  refute backup_columns(connection).include?("label")
  assert_equal ["20260201000000", "20260201000100"], migrator.applied_versions
  connection.close
end

test "schema:dump does not see the data step" do
  with_data = migrated_with(AddRetentionDays.new)
  schema_only = migrated_with(AddRetentionDaysSchemaOnly.new)
  dumped = Cybertrain::DB::SchemaDumper.dump_to_ruby(with_data)
  assert_equal Cybertrain::DB::SchemaDumper.dump_to_ruby(schema_only), dumped
  refute dumped.include?("UPDATE")
  with_data.close
  schema_only.close
end

Cybertrain::Test.run!
