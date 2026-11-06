# Phase 2 (the data layer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver phase 2 of the Rails-gap programme: decimal / json / datetime / date columns, Rails' datetime storage format, the fuller query API (`where.not`, `or`, `where_between`, `scope`, `pluck`, typed aggregates, bulk writes), declared associations with `includes`, the validators, `encrypts`, and the schema / migration additions with a Rails SQLite takeover, as docs/superpowers/specs/2026-11-06-phase2-data-layer-design.md specifies.

**Architecture:** Column types and casting come first (`Cast`, the C epoch reader, the schema DSL and dumper), because every later task binds or reads values through them. The generator (`models_emitter.rb`, `model_scan.rb`) then learns the new column types and the lexically scanned macros (`has_many`, `validate`, `encrypts`, `scope`) and emits `case` tables and per-model helpers; the base classes (`Relation`, `Model`, `Validator`) gain the behaviour those helpers feed. Each task ends with a test program under `test/` whose snapshot is regenerated, and the blog and the documents close the phase.

**Tech Stack:** Ruby compiled by Spinel 2026.11.04.7026 (`spin test`, `script/regen-snapshot`, `script/gate`), SQLite 3.45.1 through the existing FFI module, OpenSSL::Cipher (aes-256-gcm) from Spinel's openssl package, Spinel's `date` package.

**Spec:** docs/superpowers/specs/2026-11-06-phase2-data-layer-design.md (sections are cited as "spec N.M").

## Global Constraints

- Toolchain on PATH before any command: `export PATH=/root/.cybertrain/spinel/2026.11.04.7026/lib/spinel:$PATH`. Tests that link SQLite or FFI cannot run under CRuby: their snapshot is regenerated with `script/regen-snapshot test/<name>.rb` (which fails when the program fails) and reviewed with `git diff test/<name>.rb.expected`. Text-only generator tests (`test/gen_models.rb`, `test/gen_runner_models.rb`) run under both.
- `ruby script/gate` must pass before every commit (the pre-commit hook runs it; it checks, among other things, that every `test/*.rb` has its `.expected`).
- Spinel rules from spikes/NOTES.md that every task obeys: no computed `send` (rule 1); one return type per method name across the program (10, 34, 41); generated models use `attr_accessor`, never `def x=` (43); nullable ivars go through a cast that can answer nil (7); seed polymorphic containers (`[nil, 0, 0.0, ""]` then `clear`, `{ "" => 0 }` then `delete`) (9, 46); `when Time` before `when Array` (8); a `DB.with` block reads locals, never ivars (relation.rb:31); a String built in a callee is not appended to reliably, so emitters return Strings (models_emitter.rb:57 comment); JSON values are boxed and narrowed with `Cast.hash` / `Cast.array` (62, 71).
- Spike results (spec 14) are facts, not options: Ranges carry Integer ends only; `def not` and `where.not` compile; class methods may be added to `Time`; `OpenSSL::Cipher` works with raw-byte keys; the bundled SQLite is 3.45.1 with `RETURNING`; a `Hash | String` parameter dispatches by `case`.
- Stored datetime format is exactly `YYYY-MM-DD HH:MM:SS.ffffff` (UTC, space, six digits, no suffix); the display format is `YYYY-MM-DDTHH:MM:SS.mmmZ`.
- Encryption payload is `"1:" + Base64(nonce ‖ ciphertext ‖ tag)` with a 12-byte nonce; the key variable is `CYBERTRAIN_ENCRYPTION_KEY` (64 hex characters), the rotation variable `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` (comma-separated).
- Commit messages: imperative subject, a body that says why, and the trailers this session uses (`Co-Authored-By` and `Claude-Session`). No model identifiers in commits or code.
- Documentation changed by a task is updated in the same task (YARD comments, "Not available" lists); the guides and their four translations are one task at the end (Task 18) so `script/check-guide-i18n` runs once.

## Review Focus

Five conditions the spec implies but no task's tests would otherwise cover; each has its test added to the owning task.

1. A datetime cell written by Rails with a fraction of fewer than six digits (`2026-10-05 09:00:00.12`) or with a `+09:00` offset must read as the right instant (Task 2).
2. A `where.not(id: [])` (empty Array) must match every row, the complement of `where(id: [])`'s `1 = 0` (Task 7).
3. `insert_all` with rows whose key sets differ must raise `ArgumentError` before any row is written (Task 10).
4. `includes(:comments)` on a relation that loads zero records must run one query, not two, and must not raise (Task 12).
5. A `change_column_null(..., false)` on a table whose children reference it with `ON DELETE CASCADE` must leave the children intact (the rebuild runs with foreign keys off) (Task 15).

---

### Task 1: Record the spike in NOTES and spinel-feedback

**Files:**
- Modify: `spikes/NOTES.md` (rules 86 and 87 before line 955 `## Numbers worth remembering`; the "Rules by topic" index at 85-103)
- Modify: `docs/spinel-feedback.md` (new item Q after P at line 1669; a row in "What can go upstream" (118) and in "Status at a glance" (145))

**Interfaces:**
- Produces: the rule numbers every later task cites in comments: **86** (Range ends), **87** (class methods added to core classes from Ruby source).

- [ ] **Step 1: Write rule 86**

Text (fit the file's style, two-space continuation): "86. A Range under Spinel 2026.11.04.7026 carries Integer ends only. `t1..t2` or `Range.new(t1, t2)` with Time or Date ends raises `TypeError: no implicit conversion of Time into Integer` when the Range is built; a Float or String Range reads back directly (`(1.5..2.5).begin`) but once held in a Hash value or passed through a boxed parameter it is not matched by `when Range`. So `where(col: a..b)` accepts Integer ends only and other bounds go through `where_between(col, from, to)` (relation.rb); a validator's `inclusion: { in: }` takes an Integer Range or an Array (docs/spinel-feedback.md Q)."

- [ ] **Step 2: Write rule 87**

"87. Class methods added to a core class from Ruby source compile and dispatch: `class Time; def self.iso8601(text) ...` is reached by `Time.iso8601(s)`, including a method literally named `strptime`, whose earlier compile-time refusal was of the missing method, not of the name (cybertrain/time_ext.rb). Instance methods are a different matter (rule 62)."

- [ ] **Step 3: Index both rules**

Add 86 to "Polymorphic values and narrowing" and "Typing of ivars, locals, containers and return values"; add 87 to "A method name shared by unrelated classes, or with a builtin".

- [ ] **Step 4: Add item Q to docs/spinel-feedback.md**

Heading `### Q. A Range of Time or Date raises at construction; a Float or String Range is not a Range once boxed`, under the Daicho section's successor or a new `## Found in phase 2 of the Rails-gap programme (2026-11-06)` section: the two reduced programs from the spike (a `test "..."` block each, as the spike wrote them), what the build does, what CyberTrain does instead (`where_between`), and "not reported upstream yet". Add the Q row to both tables (upstream table: workaround `where_between` and the Integer-only `where`; status table: `**yes**` in the 2026.11.04.7026 column, `not checked` elsewhere).

- [ ] **Step 5: Gate and commit**

Run: `ruby script/gate` → `gate: passed`. Commit: "Record the phase 2 spike: Range ends are Integers only (rule 86), Time gains class methods (rule 87), spinel-feedback Q".

---

### Task 2: Casting: Rails' datetime format, microseconds, offsets, RFC 2822, Date, hash_or_nil

**Files:**
- Modify: `cybertrain/cast.rb` (`iso8601` 130, `parse_time` 149, `time_or_nil` 108, `to_sql` 121, `str` 35, `str_or_nil` 44; add `sql_datetime`, `date`, `date_or_nil`, `hash_or_nil`, `json_text`, `round_scale`)
- Modify: `cybertrain/db/sqlite_ffi.rb` (`cybertrain_sqlite_column_epoch` 112-142: return microseconds, accept fractions and offsets)
- Modify: `cybertrain/db/connection.rb` (`bind` 505-518: Time → `Cast.sql_datetime`, add `when Date`; `read_row` 526-562: microseconds → `Time.at(us / 1_000_000, us % 1_000_000).utc`)
- Modify: `cybertrain/model.rb` (`now_string` 176 → `Cast.sql_datetime(Time.now.utc)`; `as_json` 482 keeps `Cast.iso8601`)
- Modify: `cybertrain.rb` (`require "date"` before `cybertrain/cast` is loaded; find where cast.rb is required and add it there)
- Test: `test/cast_types.rb` (new), plus regenerated snapshots of the programs whose output changes (`test/model.rb`, `test/integration_m1.rb`, `test/db_sqlite.rb`, `test/jobs.rb`, `test/stream.rb`, `test/lease.rb` and any other that prints a stored datetime: run the whole suite after the change and review every changed `.expected`)

**Interfaces:**
- Produces: `Cast.sql_datetime(time) -> String` (storage format); `Cast.iso8601(time) -> String` (display, `.mmmZ`); `Cast.parse_time(text) -> Time | nil` (ISO 8601 with `T`/space, 0-9 fraction digits, `Z` / `±HH:MM` / `±HHMM`; RFC 2822); `Cast.time_or_nil(v)` (Time, Integer seconds, String); `Cast.date(v) -> Date` (`Date.new(1970, 1, 1)` when unparsable), `Cast.date_or_nil(v) -> Date | nil` (Date, String `YYYY-MM-DD`, else nil); `Cast.hash_or_nil(v) -> Hash | nil` (`Cast.hash` rules, nil for nil / `""`); `Cast.json_text(v) -> String | nil` (`JSON.generate` of a Hash, nil for nil); `Cast.round_scale(v, scale) -> Float` (`v.to_f.round(scale)`, `scale < 0` leaves it). `Cast.to_sql(v)`: Time → `sql_datetime`, Date → `to_s`, Hash → `json_text`, as before otherwise. The C function `cybertrain_sqlite_column_epoch(stmt, col)` answers epoch **microseconds** (`-1` when not a datetime).

- [ ] **Step 1: Write the failing test `test/cast_types.rb`**

Tests (names and assertions; `DB.connect(":memory:", size: 1)` and a `CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, at DATETIME, day DATE)` through `exec_script` where a connection is needed):

```ruby
test "sql_datetime writes Rails' format in UTC with microseconds" do
  t = Time.utc(2026, 10, 5, 9, 0, 0, 123456)
  assert_equal "2026-10-05 09:00:00.123456", Cast.sql_datetime(t)
  assert_equal "2026-10-05 09:00:00.000000", Cast.sql_datetime(Time.utc(2026, 10, 5, 9))
end
test "iso8601 is the display format with milliseconds and Z" do
  assert_equal "2026-10-05T09:00:00.123Z", Cast.iso8601(Time.utc(2026, 10, 5, 9, 0, 0, 123456))
end
test "parse_time reads both separators, any fraction length, Z and offsets" do
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 120000), Cast.parse_time("2026-10-05 09:00:00.12")
  assert_equal Time.utc(2026, 10, 5, 0, 0, 0), Cast.parse_time("2026-10-05T09:00:00+09:00")
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0), Cast.parse_time("2026-10-05T09:00:00Z")
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 123456), Cast.parse_time("2026-10-05T09:00:00.1234567-00:00")
  assert_nil Cast.parse_time("2026-13-05 09:00:00")
end
test "parse_time reads RFC 2822" do
  assert_equal Time.utc(2026, 11, 5, 9, 0, 0), Cast.parse_time("Thu, 05 Nov 2026 09:00:00 +0000")
  assert_equal Time.utc(2026, 11, 5, 0, 0, 0), Cast.parse_time("Thu, 05 Nov 2026 09:00:00 +0900")
end
test "a stored datetime round-trips through the connection with microseconds" do
  # INSERT a Time through bind, SELECT it with execute (text) and execute_models (Time)
  # assert the text is "2026-10-05 09:00:00.123456" and the Time has usec 123456
end
test "the epoch reader accepts a Rails fraction, an old T...Z value and an offset" do
  # insert the three texts with raw SQL, read with execute_models: all three are Times at the right instant
end
test "date, date_or_nil, hash_or_nil, json_text, round_scale" do
  assert_equal "2026-10-05", Cast.date("2026-10-05").to_s
  assert_equal "1970-01-01", Cast.date("not a date").to_s
  assert_nil Cast.date_or_nil(nil)
  assert_equal 5, Cast.date_or_nil("2026-10-05").day
  assert_nil Cast.hash_or_nil(nil)
  assert_equal({}, Cast.hash_or_nil("[1]"))
  assert_equal 1, Cast.int(Cast.hash_or_nil('{"n": 1}')["n"])
  assert_equal '{"a":1}', Cast.json_text({ "a" => 1 })
  assert_nil Cast.json_text(nil)
  assert_equal 1.23, Cast.round_scale(1.2345, 2)
  assert_equal 1.2345, Cast.round_scale(1.2345, -1)
end
test "a Date binds as its text and reads back from a DATE column" do
  # INSERT Date.new(2026, 10, 5) through bind; SELECT day: "2026-10-05"
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `spin test test/cast_types.rb` → compile error (no `sql_datetime`).

- [ ] **Step 3: Implement**

`cast.rb`: the methods above; `parse_time` scans bytes as today, then an optional `.` + digits (take the first six, pad to six), then `Z` / `±HH:MM` / `±HHMM` (apply the offset by subtracting it from the UTC fields: build `Time.utc(...)` then `- offset_seconds`), and a second parser `parse_rfc2822` tried when byte 3 is `,` (English day and month names, `+HHMM`). `sqlite_ffi.rb`: extend the C function with the fraction (up to 9 digits, truncate to 6) and the offset, return `seconds * 1000000 + usec`; keep `-1` for anything else; update the comment. `connection.rb`: `bind` and `read_row` as the interface says (keep the `seconds >= 0` test on the microsecond value). `model.rb`: `now_string`.

- [ ] **Step 4: Run the test and the whole suite**

Run: `script/regen-snapshot test/cast_types.rb` → `1 file changed`; `spin test` → review every `.expected` that changed: only datetime text (`T…Z` → space format, `.000Z` in JSON) may differ. Regenerate those with `script/regen-snapshot`.

- [ ] **Step 5: Gate and commit**

"Cast: store datetimes in Rails' format with microseconds; parse fractions, offsets and RFC 2822; Date, hash_or_nil, json_text"

---

### Task 3: `Time.iso8601`, `Time.rfc2822`, `Time.strptime`

**Files:**
- Create: `cybertrain/time_ext.rb`
- Modify: `cybertrain.rb` (require it after `cybertrain/cast`)
- Test: `test/time_ext.rb` (new; CRuby-portable, no DB)

**Interfaces:**
- Consumes: `Cast.parse_time` (Task 2).
- Produces: `Time.iso8601(text) -> Time`, `Time.rfc2822(text) -> Time` (both raise `ArgumentError, "invalid date: #{text}"` when `Cast.parse_time` answers nil); `Time.strptime(text, format) -> Time` with directives `%Y %m %d %H %M %S %L %z %Z %b %B %a %A %j %s %%` and literal separators; an unknown directive raises `ArgumentError, "unsupported strptime directive %q"`; `%Z` accepts `UTC`, `GMT`, `Z`; the result is UTC.

- [ ] **Step 1: Write the failing test**

```ruby
test "Time.iso8601 and rfc2822" do
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 500000), Time.iso8601("2026-10-05T09:00:00.5Z")
  assert_equal Time.utc(2026, 11, 5, 9), Time.rfc2822("Thu, 05 Nov 2026 09:00:00 +0000")
  assert_includes assert_raises("ArgumentError") { Time.iso8601("yesterday") }, "invalid date"
end
test "Time.strptime directives" do
  assert_equal Time.utc(2026, 10, 5, 9, 7, 3), Time.strptime("05/10/2026 09:07:03", "%d/%m/%Y %H:%M:%S")
  assert_equal Time.utc(2026, 10, 5, 0, 0, 0, 250000), Time.strptime("2026-10-05 000.250", "%Y-%m-%d 000.%L")
  assert_equal Time.utc(2026, 10, 5, 0, 0, 0), Time.strptime("2026-10-05 09:00 +0900", "%Y-%m-%d %H:%M %z")
  assert_equal Time.utc(2026, 11, 5), Time.strptime("Nov 5 2026", "%b %d %Y")
  assert_equal 1759654800, Time.strptime("1759654800", "%s").to_i
  assert_equal Time.utc(2026, 1, 10), Time.strptime("2026 010", "%Y %j")
  assert_includes assert_raises("ArgumentError") { Time.strptime("x", "%q") }, "%q"
end
```

- [ ] **Step 2: Run to verify it fails** (`spin test test/time_ext.rb` → no method `iso8601`).

- [ ] **Step 3: Implement `cybertrain/time_ext.rb`**: `class Time` with the three class methods; `strptime` walks the format byte by byte, reading digits for numeric directives (`%d` and `%m` accept one or two digits), names case-insensitively for `%b`/`%B`/`%a`/`%A`, and builds `Time.utc` then applies `%z`.

- [ ] **Step 4: Run** (`spin test test/time_ext.rb` → pass; `spin test --regen test/time_ext.rb` if it is CRuby-portable, else regen-snapshot).

- [ ] **Step 5: Gate and commit**: "Time.iso8601, Time.rfc2822 and Time.strptime as class methods (rule 87)".

---

### Task 4: `db normalize`

**Files:**
- Modify: `cybertrain/db/cli.rb` (`dispatch` 38-65: `when "normalize"`; `usage` 67; new `def self.normalize(root)`)
- Create: `cybertrain/db/normalizer.rb` (`DB::Normalizer.run(connection) -> Array<[table, count]>`)
- Modify: `cybertrain/cli.rb` USAGE text if it lists db subcommands
- Test: `test/db_normalize.rb` (new)

**Interfaces:**
- Produces: `Cybertrain::DB::Normalizer.run(connection)`: for every table in `sqlite_master` (type `table`, name not `sqlite_%`), for every column whose `PRAGMA table_info` type upcases to `DATETIME`, runs one `UPDATE t SET c = substr(c,1,10) || ' ' || substr(c,12,8) || '.000000' WHERE c LIKE '____-__-__T__:__:__Z'` and collects `[table, changes]`; the whole run is one transaction; it prints `normalized <table>.<column>: <n> rows` lines in the CLI and `done`.

- [ ] **Step 1: Write the failing test**

```ruby
test "normalize rewrites T...Z datetimes once, leaves Rails-format rows, and is idempotent" do
  # table posts(created_at DATETIME, note TEXT) with rows "2026-10-05T09:00:00Z", "2026-10-05 09:00:00.123456", note "2026-10-05T09:00:00Z"
  # run → [["posts", 1]]; created_at values: "2026-10-05 09:00:00.000000", "2026-10-05 09:00:00.123456"; note untouched
  # run again → [["posts", 0]]
end
test "normalized values sort with Rails-format values by time" do
  # ORDER BY created_at returns the 09:00:00.000000 row before the 09:00:00.123456 row
end
```

- [ ] **Step 2: Run to verify it fails.** **Step 3: Implement.** **Step 4: Run** (`script/regen-snapshot test/db_normalize.rb`; also `spin test test/db_cli.rb` for the usage line). **Step 5: Gate and commit**: "db normalize rewrites 0.4's T...Z datetimes into Rails' format".

---

### Task 5: Schema DSL, DDL and dumpers: decimal, json, bigint, precision, on_delete, partial and expression indexes, `db schema`

**Files:**
- Modify: `cybertrain/schema/table.rb` (`Column` 9: add `precision`, `scale`; `Index` 24: add `where` (String, "" none) and `expression` (String, "" none; `columns` empty when set); `ForeignKey` 47: add `on_delete` (Symbol, `:no_action` default); `TableDef` 134: `decimal(name, precision: 0, scale: -1, null:, default:)`, `json(name, null:, default:)`, `bigint(name, ...)` (type `:integer`, sql `BIGINT` recorded as `limit: 8`), `datetime(..., precision: 0)` accepted and ignored, `references(..., on_delete: :no_action, index: true)`)
- Modify: `cybertrain/schema/definition.rb` (`add_index(table, columns, unique:, name:, where: "")` where `columns` may be a String expression; `add_foreign_key(from, to, column:, on_delete: :no_action)`)
- Modify: `cybertrain/db/sqlite_ddl.rb` (`sql_type` 132: `:decimal` → `DECIMAL(p,s)` / `DECIMAL(p)` / `DECIMAL`, `:json` → `JSON`, integer with limit 8 → `BIGINT`; `create_table` 20 and `add_reference_statements` 101: `ON DELETE CASCADE | SET NULL | RESTRICT`; `index_sql` 145: expression and `WHERE`)
- Modify: `cybertrain/db/schema_dumper.rb` (`column_type` 87: `DECIMAL`/`NUMERIC` → `:decimal` with precision/scale from the parens, `JSON` → `:json`, `BIGINT` → `:integer` limit 8; `add_indexes` 121: read `sql` from `sqlite_master` for each index, parse `WHERE ...` and an expression column list; `add_foreign_keys` 138: `on_delete` from `PRAGMA foreign_key_list`; skip `ar_internal_metadata` with the other system tables)
- Modify: `cybertrain/schema/dumper.rb` (`column_options` 45: `precision:`, `scale:`; `index_options` 74: `where:`; expression indexes written as `s.add_index "t", "LOWER(email)", name: ...`; `add_foreign_key` with `on_delete:` when not `:no_action`; `t.bigint` for integer limit 8)
- Modify: `cybertrain/migration.rb` (`add_column` 268 and `Operation.for_add_column` 83: `precision:`, `scale:`; `add_index` 305: `where:`; `add_reference` 333 / `add_foreign_key` 381: `on_delete:`)
- Modify: `cybertrain/db/cli.rb` (`when "schema"` → `write_schema` from the existing database and print the path; usage)
- Test: `test/schema.rb` (grown), `test/schema_dumper.rb` (grown), `test/schema_dumper_rails.rb` (new), `test/migration.rb` (grown for the new options), `test/db_cli.rb` (usage)

**Interfaces:**
- Produces: `Schema::Column#precision -> Integer` (0 none), `#scale -> Integer` (-1 none); `Schema::Index#where -> String`, `#expression -> String`; `Schema::ForeignKey#on_delete -> Symbol` (`:no_action | :cascade | :nullify | :restrict`); `TableDef#decimal`, `#json`, `#bigint`; column type Symbols `:decimal` and `:json` seen by the generator (Task 6) and the dumpers.

- [ ] **Step 1: Write the failing tests**

In `test/schema.rb`: `t.decimal "price", precision: 18, scale: 8` → column type `:decimal`, precision 18, scale 8; `t.json "meta"` → `:json`; `t.bigint "views"` → `:integer` limit 8; `t.references :post, on_delete: :cascade` → foreign key `on_delete == :cascade`; `s.add_index "users", "LOWER(email)", name: "index_users_on_lower_email"` → `expression == "LOWER(email)"`; `s.add_index "posts", ["deleted_at"], where: "deleted_at IS NULL"` → `where`. DDL (`SqliteDDL.create_table`) contains `price DECIMAL(18,8)`, `meta JSON`, `views BIGINT`, `FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE`; `index_sql` gives `CREATE INDEX index_users_on_lower_email ON users (LOWER(email))` and `... ON posts (deleted_at) WHERE deleted_at IS NULL`.

New `test/schema_dumper_rails.rb`: build an in-memory database with the DDL Rails 8.1 writes:

```sql
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
INSERT INTO schema_migrations VALUES ('20260101000000');
CREATE TABLE "accounts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "email" varchar NOT NULL, "balance" decimal(18,8) DEFAULT 0, "meta" json, "views" bigint DEFAULT 0 NOT NULL, "active" boolean DEFAULT 1 NOT NULL, "born_on" date, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_accounts_on_lower_email" ON "accounts" (LOWER(email));
CREATE INDEX "index_accounts_on_views" ON "accounts" ("views") WHERE active = 1;
CREATE TABLE "entries" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "account_id" integer NOT NULL, "body" text, CONSTRAINT "fk_rails_1" FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") ON DELETE CASCADE);
CREATE INDEX "index_entries_on_account_id" ON "entries" ("account_id");
```

Assert `SchemaDumper.dump_to_ruby(conn)` contains `t.decimal "balance", precision: 18, scale: 8, default: "0"`, `t.json "meta"`, `t.bigint "views", null: false, default: "0"`, `t.date "born_on"`, `t.datetime "created_at", null: false`, `s.add_index "accounts", "LOWER(email)", unique: true, name: "index_accounts_on_lower_email"`, `s.add_index "accounts", ["views"], name: "index_accounts_on_views", where: "active = 1"`, `s.add_foreign_key "entries", "accounts", column: "account_id", on_delete: :cascade`, does not contain `ar_internal_metadata`; then that the dumped text, evaluated as `Cybertrain::Schema.define` (write it to a temp file and `load` under CRuby is not available: instead re-parse by building the same `Definition` through the DSL in the test and comparing `Schema::Dumper.to_ruby` of both for equality).

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement** (dumper index parsing: from the index's `sql`, take the text between the first `(` after `ON <table>` and its matching `)` as the column list; if it is not a comma list of quoted or bare identifiers it is an expression; `WHERE ` after the `)` is the partial predicate). **Step 4: Run and regenerate** the four snapshots. **Step 5: Gate and commit**: "Schema: decimal, json, bigint, on_delete, partial and expression indexes, in the DSL, the DDL and both dumpers; db schema".

---

### Task 6: Generated models learn decimal, json and date; per-model `column_type`

**Files:**
- Modify: `cybertrain/generator/models_emitter.rb` (`cast_for` 525: `:decimal` → `float`/`float_or_nil`, `:json` → `hash`/`hash_or_nil`, `:date` → `date`/`date_or_nil`; `bind_expression` 544: decimal → `Cybertrain::Cast.round_scale(Cybertrain::Cast.to_sql(@x), scale)` when scale >= 0, json → `Cybertrain::Cast.json_text(@x)`, date → `Cybertrain::Cast.to_sql(@x)`; `initial_value` 556: json NOT NULL → `Cybertrain::Cast.empty_hash`, date → `nil`, decimal as float; `emit_binary_columns` 231 → `emit_column_types`: generated `def column_type(name)` (a `case` over the SQL column names answering `:integer | :float | :decimal | :boolean | :datetime | :date | :json | :binary | :string | :text`, else `:unknown`), `def decimal_scale(name)` (the scale, else -1) and keep `binary_column?` as `column_type(name) == :binary`)
- Modify: `cybertrain/relation.rb` (base `column_type(name) = :unknown`, `decimal_scale(name) = -1`; `binary_column?` 86 unchanged)
- Modify: `test/fixtures/gen_app/db/schema.rb` (posts gains `t.decimal "price", precision: 10, scale: 2`, `t.json "meta"`, `t.date "published_on"`) and regenerate `test/fixtures/gen_app/gen/**` with `Gen::Runner` (the way `test/gen_runner_models.rb` does)
- Test: `test/gen_models.rb` (grown: the new `cast_for` lines and the `column_type` case), `test/gen_models_compiles.rb` (grown: decimal rounding on save, json Hash round trip, date round trip, `column_type(:price) == :decimal`), `test/gen_runner_models.rb` (`fixture_schema` restated)

**Interfaces:**
- Produces: on every generated `<Model>Relation`: `column_type(name) -> Symbol`, `decimal_scale(name) -> Integer`; model attributes typed `Float` / `Hash` / `Date` per spec 2.

- [ ] **Step 1: Write the failing tests** (text lines in `gen_models.rb`; in `gen_models_compiles.rb`: `Post.create(price: 1.005, meta: { "a" => 1 }, published_on: Date.new(2026, 10, 5))` then `Post.first.price == 1.01` (round half up at scale 2: use `1.015 → 1.02`, pick a value whose rounding is unambiguous), `Post.first.meta["a"]` through `Cast.int` is 1, `Post.first.published_on.to_s == "2026-10-05"`, `Post.all.column_type("price") == :decimal`).
- [ ] **Step 2: Run to verify they fail** (fixture stale). **Step 3: Implement**, regenerate the fixture. **Step 4: Run** `gen_models`, `gen_runner_models`, regen-snapshot `gen_models_compiles`. **Step 5: Gate and commit**: "Generated models: decimal as Float with scale rounding, json as Hash, date as Date; column_type and decimal_scale per model".

---

### Task 7: Relation: `where` forms, `where.not`, `where_between`, `or`, `order(hash)`, `distinct`, `update_all`, `destroy_all`, `find_each`, finders, `none`, `ids`, `update_columns`, `create!`, class delegations

**Files:**
- Modify: `cybertrain/relation.rb` (`add_where` 56: Integer Range arm before `else`; new `add_where_not(hash)`, `add_where_between(column, from, to, exclude_end)`, `merge_or(other)`, `set_order_hash(hash)`, `set_distinct`; `update_all(hash)`; `none` state (`@none` flag → `1 = 0`); `ids`; `select_sql` 564: `SELECT DISTINCT` when flagged; `count` 195 over a subquery when distinct)
- Modify: `cybertrain/generator/models_emitter.rb` (`emit_relation` 177: `def where(cond = nil, *binds)` (nil → self; Hash → `add_where`; String → `add_where_sql(cond, binds)`), `def not(h) = (add_where_not(h); self)`, `where_between(c, from, to, exclude_end: false)`, `or(other)`, `order(o)` (String or Hash by `case`), `distinct`, `none`, `find_each(batch: 1000, &blk)`, `find_or_create_by(h)`, `find_or_initialize_by(h)`, `find_by!(h)`, `destroy_all`; `emit_persistence` 330: one list `DELEGATED = %w[where where_like where_between order order_sql limit offset distinct none includes pluck pick ids find find_by find_by! find_or_create_by find_or_initialize_by first last count exists? update_all delete_all destroy_all find_each minimum_int ... having_sql]` emitted as `def self.x(...) = all.x(...)` (the aggregate names arrive in Task 9, `includes` in Task 12: add them to the list in those tasks); `self.create!(attrs)`)
- Modify: `cybertrain/model.rb` (`update_columns(hash)` instance: `UPDATE` of the given columns through `to_row`'s expressions for those columns, then `write_attribute` each; `create!` is generated; "Not available" 43-47 shrinks)
- Test: `test/relation_where.rb` (new; hand-written model shape as test/query_extras.rb), `test/gen_models.rb` (grown: the new relation methods and the delegation list), `test/gen_models_compiles.rb` (grown: `Post.where.not(...)`, `Post.pluck` arrives in Task 9)

**Interfaces:**
- Consumes: `Cast.to_sql` (Task 2), `column_type` (Task 6: `where` on a `:json` column raises `ArgumentError, "where on a json column (meta) is not supported"`).
- Produces: on Relation: `where(cond = nil, *binds)`, `not(hash)`, `where_between(column, from, to, exclude_end: false)` (nil for an open end; raises `ArgumentError` when both are nil), `or(other)` (raises `ArgumentError, "or: the relations differ in order, limit, offset or distinct"`), `order(String | Hash)`, `distinct`, `none`, `ids -> Array<Integer>`, `update_all(hash) -> Integer`, `destroy_all -> Array<Model>`, `find_each(batch: 1000) { |rec| }`, `find_or_create_by(h)`, `find_or_initialize_by(h)`, `find_by!(h)`; on Model: `update_columns(hash) -> true`, `Model.create!(attrs)`.

- [ ] **Step 1: Write the failing test `test/relation_where.rb`** with a hand-written `Event` model (table events: name TEXT, views INTEGER, kind TEXT, at DATETIME) and its relation written in the generated shape:

```ruby
test "where with an Integer Range and open ranges" do
  # views 1,5,10 → where(views: 1..5).count == 2; where(views: 5..) == 2; where(views: ..5) == 2; where(views: 1...5) == 1
end
test "where with a SQL string and binds, and where_sql still works" do
  # where("views > ?", 4).count == 2
end
test "where.not negates equality, nil, arrays and ranges" do
  # where.not(kind: "a"), where.not(kind: nil) → IS NOT NULL, where.not(views: [1, 5]) → 1 row, where.not(views: 1..5) → 1 row
  # where.not(id: []) matches every row (Review Focus 2)
end
test "where_between on a datetime column, inclusive, exclusive and open-ended" do
  # at: three Times; where_between(:at, t1, t2).count, exclude_end: true, (nil, t2), (t1, nil); both nil raises ArgumentError
end
test "or joins two relations and refuses a different order" do
  # Event.where(kind: "a").or(Event.where(views: 10)).count == 3; .or(Event.order(views: :desc)) raises
end
test "order with a Hash, distinct pluck and count" do
  # order(views: :desc).pluck_int(:views) == [10, 5, 1]; distinct.pluck_str(:kind) has 2 entries; distinct.count == 2 when a where narrows to duplicates (count uses the subquery)
end
test "update_all, update_columns, destroy_all, none, ids, find_each" do
  # update_all(kind: "z") == 3 and updated_at untouched (no column here; assert the changed rows only)
  # rec.update_columns(views: 99): row has 99, rec.views == 99, no callback ran (a before_save counter stays)
  # none.count == 0 and none.to_a.empty?; ids == [1, 2, 3]; find_each(batch: 2) yields 3 records in id order
  # destroy_all returns 3 records and the table is empty (an after_destroy counter reaches 3)
end
test "find_or_create_by, find_or_initialize_by, find_by!, create!" do
  # find_by!(name: "none") raises RecordNotFound; create! with an invalid record raises RecordInvalid
end
```

- [ ] **Step 2: Run to verify it fails.** **Step 3: Implement** in relation.rb, models_emitter.rb and model.rb; update `test/model.rb`'s hand-written PostRelation only if a test there needs the new shape. **Step 4: Run** `relation_where` (regen-snapshot), `gen_models`, `gen_models_compiles`, `model`, `query_extras`. **Step 5: Gate and commit**: "Relation: where strings and Integer ranges, where.not, where_between, or, order Hash, distinct, update_all, destroy_all, find_each, finders; every query method on the model class".

---

### Task 8: `scope`

**Files:**
- Modify: `cybertrain/generator/model_scan.rb` (`ModelInfo` 4: add `scopes` (Array<ScopeInfo>); new `class ScopeInfo` with `name`, `params` (String, the text inside `(...)`, "" for none), `body` (String), `line`; `scan_source` 29 recognises `scope :name, -> { body }` and `scope :name, ->(a, b) { body }` on **one line**; a `scope` line that is not of that shape raises `ModelScan::Error, "#{file}:#{line}: scope must be a one-line lambda: scope :name, ->(args) { ... }"`; a scope whose name is a column, a Relation method or a repeated scope raises)
- Modify: `cybertrain/generator/models_emitter.rb` (relation: `def #{name}(#{params}) = #{body}`; model: `def self.#{name}(#{params}) = all.#{name}(#{args})`; `emit` 57 takes the ModelInfo's scopes; `view_methods_for` 26 pattern for the lookup)
- Modify: `cybertrain/model.rb` (`def self.scope(name, body) = nil`, documented as read by the generator; the "Not available" line about `scope` goes)
- Modify: `test/fixtures/gen_app/app/models/post.rb` (`scope :recent, -> { order(created_at: :desc) }` and `scope :min_views, ->(n) { where("views >= ?", n) }`), regenerate the fixture
- Test: `test/gen_models.rb` (grown: scan + emitted lines + the three error messages), `test/gen_models_compiles.rb` (`Post.recent.first`, `Post.min_views(2).count`, `Post.recent.min_views(2)` chains)

- [ ] **Step 1: Write the failing tests.** **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run and regenerate.** **Step 5: Gate and commit**: "scope: one-line lambdas copied by the generator into class and relation methods".

---

### Task 9: `pluck` / `pick` cells and the typed aggregates

**Files:**
- Modify: `cybertrain/relation.rb` (`pluck(*columns)`, `pick(*columns)`: `select_sql` of the checked columns through `execute`, each cell cast by `column_type` (integer `Cast.int_or_nil`, float/decimal `float_or_nil`, boolean `bool_or_nil`, datetime `time_or_nil`, date `date_or_nil`, else the String or nil); one column raises `ArgumentError, "pluck takes two or more columns; use pluck_str, pluck_int, pluck_float or ids for one"`; `minimum_int/float/time`, `maximum_int/float/time`, `average`, their `_by(group, column)` forms, `sum_int_by`, `sum_float_by`, `average_by`, `sum_float_sql`, `minimum_float_sql`, `maximum_float_sql`, `average_sql`, `having_sql(sql, binds = [])`; `aggregate_cell` 507 gains the `DISTINCT` keyword inside the function when flagged; `grouped_counts` 524 generalised to `grouped_cell(func, expr, cast)`)
- Modify: `cybertrain/generator/models_emitter.rb` (the delegation list gains every name above)
- Test: `test/pluck.rb` (new), `test/aggregates.rb` (new), `test/gen_models.rb` (delegations)

**Interfaces:**
- Consumes: `column_type` (Task 6), `distinct` (Task 7).
- Produces: `pluck(*columns) -> Array<Array<Integer | Float | String | true | false | Time | Date | nil>>`, `pick(*columns) -> Array | nil`; aggregates as spec 5 (`Integer | nil`, `Float | nil`, `Time | nil`, `Hash<String, T>`).

- [ ] **Step 1: Write the failing tests** (`test/pluck.rb`: a `Reading` model with integer, float, decimal (scale 2), boolean, datetime, date, json, text columns, its relation overriding `column_type`; `pluck(:observed_at, :value)` gives `[[Time, Float], ...]` in order, booleans are `true`/`false`, a json cell is the stored String, a NULL is nil, `pick(:id, :value)` is the first row and nil when empty, `pluck(:id)` raises with "pluck_int"; `distinct.pluck(:kind, :flag)` dedupes. `test/aggregates.rb`: `minimum_int(:views)`, `maximum_float(:value)`, `maximum_time(:observed_at)`, `average(:value)`, nil on an empty relation; `sum_float_by(:kind, :value) == { "a" => 3.0, "b" => 1.5 }`, `maximum_time_by`, `average_by`; `sum_float_sql("value * 2")`; `having_sql("SUM(value) > ?", [2.0])` narrows a `_by`; `distinct.sum_int(:views)` with duplicate values sums distinct inputs.)
- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run and regenerate.** **Step 5: Gate and commit**: "pluck and pick with column-typed cells; typed minimum, maximum, average, grouped and expression forms; having_sql".

---

### Task 10: Bulk writes

**Files:**
- Modify: `cybertrain/db/sqlite_ffi.rb` (`ffi_func :sqlite3_limit, [:ptr, :int, :int], :int`)
- Modify: `cybertrain/db/connection.rb` (`variable_limit -> Integer` = `sqlite3_limit(@db, 9, -1)`, cached after the first call; `in_transaction? -> Boolean` = `sqlite3_get_autocommit(@db) == 0`)
- Modify: `cybertrain/db.rb` (`DB.in_transaction?` through `with`; `DB.transaction` joins an open one when `in_transaction?` is true if it does not already)
- Modify: `cybertrain/model.rb` (`self.insert_all_into(table, rows, columns_types, scales, encrypted, returning, record_timestamps, on_conflict, unique_by, update_only) -> Array<Hash<String, Cell>>`; shared by the three generated class methods; chunk size = `variable_limit / column_count`; `RETURNING` columns cast by type)
- Modify: `cybertrain/generator/models_emitter.rb` (`emit_persistence`: `self.insert_all(rows, returning: [:id], record_timestamps: true)`, `self.insert_all!(rows, ...)`, `self.upsert_all(rows, unique_by: [:id], update_only: nil, returning: [:id], record_timestamps: true)`, each passing the table and a `COLUMN_TYPES` Hash the emitter writes as a constant `{ "price" => :decimal, ... }` plus `DECIMAL_SCALES` and `ENCRYPTED_COLUMNS` (Task 14 fills the last; empty here))
- Test: `test/bulk_writes.rb` (new; hand-written model with the constants), `test/gen_models.rb` (constants and methods emitted)

**Interfaces:**
- Consumes: `Cast.round_scale`, `Cast.json_text`, `Cast.sql_datetime`, `DB::Blob` (Task 2, D40).
- Produces: the three class methods per spec 6; `DB.in_transaction?`; `Connection#variable_limit`.

- [ ] **Step 1: Write the failing test**

```ruby
test "insert_all returns the ids of the rows it inserted and skips duplicates" do
  # unique index on code; insert_all([{code: "a"}, {code: "b"}]).size == 2; insert_all([{code: "a"}, {code: "c"}]).size == 1
end
test "insert_all! raises on a duplicate" do ... end
test "insert_all fills created_at and updated_at once per call, and not with record_timestamps: false" do ... end
test "rows with different keys raise before anything is written" do  # Review Focus 3
  assert_raises("ArgumentError") { Item.insert_all([{ code: "x" }, { code: "y", qty: 1 }]) }
  assert_equal 0, Item.count
end
test "upsert_all updates only the supplied columns and keeps created_at" do
  # upsert_all([{code: "a", qty: 5}], unique_by: [:code]); body unchanged, qty 5, created_at unchanged, updated_at moved
end
test "upsert_all with update_only and returning" do ... end
test "a call with more binds than the variable limit is chunked inside one transaction" do
  # 3 columns, rows = variable_limit / 3 + 10 → all inserted; a bad row in the last chunk (NOT NULL violation) → nothing inserted (count 0)
end
test "decimal rounding, json text, Date text and Time format in bulk rows" do ... end
```

- [ ] **Step 2: Run to verify it fails.** **Step 3: Implement.** **Step 4: Run and regenerate.** **Step 5: Gate and commit**: "insert_all, insert_all! and upsert_all in chunked multi-row statements with RETURNING, timestamps and one transaction".

---

### Task 11: Declared associations: `has_many` as a Relation, `has_one`, `belongs_to` options, `dependent:`, `counter_cache:`

**Files:**
- Modify: `cybertrain/generator/model_scan.rb` (`ModelInfo` gains `associations` (Array<AssociationInfo>): `kind` (`:has_many | :has_one | :belongs_to`), `name`, `class_name` ("" → inferred), `foreign_key` ("" → inferred), `dependent` (Symbol, `:none`), `optional` (Boolean), `counter_cache` (Boolean), `line`; the scanner reads the three macros with literal options; unknown options raise `ModelScan::Error`)
- Modify: `cybertrain/generator/models_emitter.rb` (`emit_dispatch` 428: declared associations override the foreign-key-derived ones by foreign key; `has_many` → `def comments = preloaded_or(CommentRelation.new("comments").where(article_id: @id))` style (spec 7.2; the preload hook arrives in Task 12, emit the plain Relation here); `belongs_to` → cache ivars `@author_loaded_id = -1`, `@author_record = nil` in `initialize`, reader per spec 7.2; `has_one` → `@profile_loaded = false`, `@profile_record = nil`; `read_association` returns `to_a` for has_many; declared `belongs_to` without `optional: true` adds `validates :author_id, presence: true` to the generated class body; `counter_cache: true` adds `@author_id_persisted` set in `load_row` and `after_save`, and the three callbacks registered in the class body as blocks calling generated `counter_cache_created` / `counter_cache_destroyed` / `counter_cache_moved`; `dependent:` → generated `def destroy_dependents` (`:destroy` → `comments.to_a.each(&:destroy)`, `:delete_all` → `CommentRelation.new("comments").where(article_id: @id).delete_all`, `:nullify` → `update_all(article_id: nil)`); the generation fails with file and line when the foreign key column or `class_name` does not exist, or when `counter_cache` names a missing `<children>_count` column)
- Modify: `cybertrain/model.rb` (`destroy` 429: `DB.transaction` around `destroy_dependents` and the DELETE unless `DB.in_transaction?`; stub `destroy_dependents = nil`; `has_many`, `has_one`, `belongs_to` class methods as documented no-ops read by the generator; `reload` 445 clears the caches through a generated `reset_association_caches` stub)
- Modify: `test/fixtures/gen_app/app/models/post.rb` (`has_many :comments, dependent: :destroy`), create `test/fixtures/gen_app/app/models/comment.rb` (`belongs_to :post, counter_cache: true`), fixture schema posts gains `t.integer "comments_count", null: false, default: "0"`; regenerate the fixture
- Test: `test/gen_models.rb` (scan results, emitted lines, the error messages), `test/gen_models_compiles.rb` (`post.comments` is a Relation: `.where(...).count` works; `comment.post` cached rule; `post.destroy` removes comments; `comments_count` follows create, destroy and a moved comment; `Comment.new.valid?` fails on `post_id` presence), `test/associations.rb` (new; hand-written shape for `has_one` and `dependent: :nullify`, `:delete_all`)

**Interfaces:**
- Consumes: `DB.in_transaction?` (Task 10), `update_all` / `delete_all` (Task 7).
- Produces: generated readers per spec 7.2; `destroy_dependents`, `reset_association_caches`; the cache ivars Task 12 fills: `@<assoc>_preloaded` (has_many), `@<assoc>_loaded_id` + `@<assoc>_record` (belongs_to), `@<assoc>_loaded` + `@<assoc>_record` (has_one).

- [ ] **Step 1: Write the failing tests.** **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run and regenerate.** **Step 5: Gate and commit**: "Declared associations: has_many returns a Relation; has_one; belongs_to optional:, counter_cache:; dependent: inside destroy's transaction".

---

### Task 12: `includes` / `preload`

**Files:**
- Modify: `cybertrain/relation.rb` (`@includes` Array<Symbol>; `preloaded(records)` sets `@preloaded = records` so `to_a`-based readers answer from memory and any chain method clears it; base `includes_names` check hook `preload_association(name, records) = nil` stub; `select_sql` unchanged)
- Modify: `cybertrain/generator/models_emitter.rb` (relation: `def includes(*names)` validating each Symbol by a generated `case` (`ArgumentError, "unknown association #{name} for Article"`), `preload` alias; `to_a` runs `preload_association(name, out)` for each; generated `preload_association` per association: has_many → `CommentRelation.new("comments").where(article_id: ids).to_a` (ids chunked at `variable_limit`), grouped by foreign key into each record's `@comments_preloaded`; belongs_to → `User.where(id: parent_ids).to_a` indexed by id into `@author_loaded_id = @author_id`, `@author_record = found or nil`; has_one similarly with `@profile_loaded = true`; the has_many reader returns `CommentRelation...where(...).preloaded(@comments_preloaded)` when the ivar is set; model delegation list gains `includes`, `preload`)
- Modify: `cybertrain/db/connection.rb` (`statements_run -> Integer`, incremented in `run_statement`, for tests)
- Test: `test/includes.rb` (new, on the compiled fixture models as `test/gen_models_compiles.rb` loads them, or grown inside it): N posts with comments → `Post.includes(:comments).to_a` then each `post.comments.size` and `first` cost no further statement (`statements_run` delta is 2); `post.comments.count` runs SQL; `post.comments.where(...)` runs SQL and drops the preload; `Comment.includes(:post)` sets the parent cache, a comment whose post is missing answers nil without a query; `Post.includes(:nothing)` raises; `Post.where(id: -1).includes(:comments).to_a` runs one statement and is empty (Review Focus 4); `read_association(:comments)` on a preloaded post answers the Array without a statement.

- [ ] **Step 1: Write the failing test.** **Step 2: Run to verify it fails.** **Step 3: Implement.** **Step 4: Run and regenerate.** **Step 5: Gate and commit**: "includes: one-level preload of has_many, has_one and belongs_to in one query per association".

---

### Task 13: Validators

**Files:**
- Modify: `cybertrain/validator.rb` (fields: `attr`, `kind` (`:presence | :length | :inclusion | :exclusion | :format | :numericality | :uniqueness | :custom`), `minimum`, `maximum`, `exact_length` (-1), `in_list` (Array<String|Integer>, seeded), `range_min`/`range_max` (Integer, open = nil → use a `has_range` flag), `pattern` (Regexp | nil), `without` (Regexp | nil), `only_integer`, `greater_than`, `greater_than_or_equal_to`, `less_than`, `less_than_or_equal_to`, `equal_to`, `other_than` (Float | nil each), `scope_attr` (Symbol | nil), `case_sensitive` (true), `allow_nil`, `allow_blank`, `on` (Symbol | nil), `message` (""), `condition_if` (Symbol | nil), `condition_unless` (Symbol | nil); `validate(record, context)`: skips by `on`, `condition_if` / `condition_unless` through `record.validation_condition?(name)`, `allow_nil` / `allow_blank`; one `case @kind` branch each; messages per spec 9.1; uniqueness calls `record.unique_value_taken?(@attr, value, @scope_attr, scope_value, record.id, @case_sensitive)`)
- Modify: `cybertrain/model.rb` (`self.validates(*attrs, options = {})` building Validators from the options Hash by `case` narrowing; `self.validate(*names, options = {}) = nil` (generator-read); `valid?` 356 passes the context (`new_record? ? :create : :update`) and calls `run_custom_validations(context)`; stubs `unique_value_taken?(...) = false`, `validation_condition?(name) = true`, `run_custom_validations(context) = nil`; `Errors` unchanged)
- Modify: `cybertrain/generator/model_scan.rb` (`validate :a, :b, on:, if:, unless:` lines → `ModelInfo#custom_validations` (name, on, if, unless, line); `validates` lines are not scanned except to collect their `if:` / `unless:` Symbols into `ModelInfo#condition_methods`; a lambda in `if:` raises `ModelScan::Error, "...: if: and unless: take a Symbol method name"`)
- Modify: `cybertrain/generator/models_emitter.rb` (generated `unique_value_taken?` through `where`/`where.not`/`exists?` with `LOWER()` when not case-sensitive; `run_custom_validations(context)` as a sequence of `check_x if …` lines; `validation_condition?(name)` as a `case` over the collected Symbols)
- Modify: `test/fixtures/gen_app/app/models/post.rb` (`validates :title, uniqueness: true, length: { maximum: 40 }`, `validates :views, numericality: { greater_than_or_equal_to: 0 }`, `validate :title_not_reserved, if: :published?` with the two methods), regenerate
- Test: `test/validators.rb` (new; hand-written model overriding `unique_value_taken?` and `validation_condition?`): one test per option with its Rails message; `on: :create` runs only on a new record; `allow_nil`; `message:` override; `inclusion: { in: 1..5 }`; `format: { with:, without: }`; `numericality` on a String attribute `"12"` passes, `"abc"` fails with "is not a number", `only_integer` fails `"1.5"` with "must be an integer". `test/gen_models.rb` (scan + emitted case), `test/gen_models_compiles.rb` (uniqueness end to end with `case_sensitive: false`, the custom validation and its `if:`).

- [ ] **Step 1: Write the failing tests.** **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run and regenerate** (also `test/model.rb`, whose validation tests must still pass). **Step 5: Gate and commit**: "Validators: inclusion, exclusion, format, numericality, uniqueness, fuller length, allow_nil, on:, message:; validate :method and if:/unless: through generated case tables".

---

### Task 14: Encryption

**Files:**
- Create: `cybertrain/encryptor.rb` (`class Cybertrain::Encryptor`: `Error < StandardError`; `initialize(key_bytes, previous = [])`; `encrypt(text) -> String`; `decrypt(payload) -> String`; `self.from_hex(hex) -> String` of 32 bytes or raise `Error, "encryption key must be 64 hex characters"`)
- Modify: `cybertrain/crypto.rb` (`self.encrypt(text)` / `self.decrypt(text)` through `Cybertrain.config`'s encryptor; `self.encryption_key_hex -> String` = 64 hex chars from `random_token(32)`)
- Modify: `cybertrain/config.rb` (`attr_accessor :encryption_key` (hex String, `ENV["CYBERTRAIN_ENCRYPTION_KEY"] || ""`), `:encryption_keys_previous` (Array<String> from the comma list); `encryption_error -> String` ("" or "CYBERTRAIN_ENCRYPTION_KEY must be 64 hex characters; make one with `cybertrain secret --hex`" when set but malformed; the "set but unused" case is fine); `encryptor -> Encryptor` memoised, raising `Encryptor::Error, "CYBERTRAIN_ENCRYPTION_KEY is not set; ..."` when empty)
- Modify: `cybertrain/application.rb` (boot: `fail_boot` on `encryption_error`; when the generated app declares encrypted columns (`Cybertrain::ENCRYPTED_MODELS` constant emitted into gen/app.rb, or a generated `App.encrypts_columns?`), require the key at boot)
- Modify: `cybertrain/cli.rb` (`secret` subcommand: prints `Crypto.random_token`-style session secret; `secret --hex` prints `Crypto.encryption_key_hex`; USAGE)
- Modify: `cybertrain/cli/new_app.rb` + `cybertrain/cli/templates.rb` (`.env.example` with `# CYBERTRAIN_SECRET_KEY_BASE=` and `# CYBERTRAIN_ENCRYPTION_KEY=  # cybertrain secret --hex` lines)
- Modify: `cybertrain/generator/model_scan.rb` (`encrypts :a, :b` → `ModelInfo#encrypted`), `models_emitter.rb` (`load_row`: `Cybertrain::Crypto.decrypt_or_nil(Cast.str_or_nil(row["api_key"]))`; `to_row`: `Cybertrain::Crypto.encrypt_or_nil(@api_key)`; `ENCRYPTED_COLUMNS` constant filled; `column_type` unchanged (`:text`); `where` on the column raises through a generated `encrypted_column?(name)`; bulk writes raise on it), `cybertrain/model.rb` (`self.encrypts(*attrs) = nil`)
- Modify: `cybertrain/crypto.rb` (`decrypt_or_nil`, `encrypt_or_nil` for nil-safe generated code)
- Modify: `test/fixtures/gen_app/app/models/post.rb` (`encrypts :secret_note`), fixture schema posts gains `t.text "secret_note"`, regenerate
- Test: `test/encryptor.rb` (new): round trip; payload starts with `"1:"`; two encryptions differ (nonce); a flipped byte raises `Encryptor::Error`; a wrong key raises; a previous key decrypts; `from_hex` rejects 63 characters; `Crypto.encrypt` without a key raises the configuration message. `test/gen_models_compiles.rb`: with `ENV`-free config set in the test (`Cybertrain.config.encryption_key = hex`), `Post.create(secret_note: "k")`, the raw column text starts with `1:`, `Post.first.secret_note == "k"`, `Post.where(secret_note: "k")` raises. `test/cli_new.rb` and `test/config_settings.rb` snapshots.

- [ ] **Step 1: Write the failing tests.** **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run and regenerate.** **Step 5: Gate and commit**: "Encryptor (AES-256-GCM) with key rotation; encrypts :column in generated models; cybertrain secret --hex".

---

### Task 15: Migrations: `rename_table`, `change_column*`, `remove_reference`, `remove_foreign_key`, `reversible`, foreign keys off around a rebuild

**Files:**
- Modify: `cybertrain/migration.rb` (`Operation` kinds `:rename_table`, `:change_column`, `:change_column_default`, `:change_column_null`, `:remove_reference`, `:remove_foreign_key`, `:reversible_up`, `:reversible_down`; fields reuse `name`/`new_name`/`type`/`null`/`default`/`limit`/`precision`/`scale`/`to_table`; `Base#rename_table(old, new)`, `change_column(table, column, type, null: true, default: nil, limit: 0, precision: 0, scale: -1)`, `change_column_default(table, column, from: nil, to: nil)` (`to:` required), `change_column_null(table, column, null, default = nil)`, `remove_reference(table, name)`, `remove_foreign_key(from, to, column: "")`, `reversible { |dir| dir.up { } dir.down { } }` where `dir` is a small `Direction` object whose `up`/`down` take blocks that call `execute`, recorded as the two kinds; `inverse` 404: rename_table swaps, change_column_default swaps `from`/`to` when both given, change_column_null flips when a default (or none needed) is known, the rest raise `IrreversibleMigration`; `Operation#rebuilds? -> Boolean` for the five rebuild kinds)
- Modify: `cybertrain/db/sqlite_ddl.rb` (`rebuild_table(definition_after, table_name) -> Array<String>`: `CREATE TABLE <t>_new ...` from the new `Schema::Table`, `INSERT INTO <t>_new (common) SELECT common FROM <t>`, `DROP TABLE <t>`, `ALTER TABLE <t>_new RENAME TO <t>`, the table's `CREATE INDEX` statements; `statements(op)` 30 for the new kinds; the migrator keeps a `Schema::Definition` mirror of the database (it already loads `Schema.current` for `add_reference` folding: use `DB::SchemaDumper.dump(connection)` before the version to get the live definition, apply the operation to it, and rebuild from the result))
- Modify: `cybertrain/db/migrator.rb` (`apply_version` 119: when any op `rebuilds?`, run `PRAGMA foreign_keys = OFF` before `transaction`, `PRAGMA foreign_key_check` before the commit (raise `Migration::Error, "foreign key check failed after rebuilding #{table}: #{rows}"` on rows, which rolls back), `PRAGMA foreign_keys = ON` in an `ensure`; `pending`/`status` ignore applied versions without a file (Task 16 tests it))
- Test: `test/migration_rebuild.rb` (new): each new helper changes the live schema as `PRAGMA table_info` / `foreign_key_list` / `index_list` report, data survives (`INSERT` before, `SELECT` after), indexes are recreated, `rollback` restores for the reversible ones and raises `IrreversibleMigration` for the rest; `reversible` runs the right block each way; **Review Focus 5**: parent `posts`, child `comments` with `ON DELETE CASCADE` and two rows → `change_column_null :posts, :title, false` keeps both comments; `test/migration.rb` (grown: the Operation shapes and `inverse`).

- [ ] **Step 1: Write the failing tests.** **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run and regenerate** (`migration_rebuild`, `migration`, `migrator`, `gen_migrations`). **Step 5: Gate and commit**: "Migrations: rename_table, change_column, change_column_default, change_column_null, remove_reference, remove_foreign_key by table rebuild with foreign keys off; reversible".

---

### Task 16: Taking over a Rails SQLite file

**Files:**
- Modify: `cybertrain/db/migrator.rb` (`pending` 26 / `status` 98: an applied version with no migration file is listed under "applied (no file)" by `status` and never run or counted as pending)
- Modify: `cybertrain/db/cli.rb` (`schema` from Task 5 prints `wrote db/schema.rb from <path>`)
- Test: `test/migrator.rb` (grown: a `schema_migrations` row `"20250101000000"` with no file → `pending` empty, `status` output names it), `test/schema_dumper_rails.rb` (grown: after `dump_to_ruby`, `Migrator#pending` on the same connection with no migrations is empty)
- Docs: the guide section is Task 18; this task adds the `## Taking over a database Rails created` section text to `docs/guide/models.md` only (the five steps of spec 11.3), so Task 18 translates it with the rest.

- [ ] **Step 1: Write the failing tests.** **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run and regenerate.** **Step 5: Gate and commit**: "Migrator ignores applied versions without a file; the Rails takeover procedure in the models guide".

---

### Task 17: examples/blog

**Files:**
- Modify: `examples/blog/app/models/article.rb` (`has_many :comments, dependent: :destroy` replaces the `before_destroy` block; `validates :title, uniqueness: true`; `scope :recent, -> { order(created_at: :desc) }`)
- Modify: `examples/blog/app/models/comment.rb` (`belongs_to :article`)
- Modify: `examples/blog/app/controllers/articles_controller.rb` (`index`: `@articles = Article.recent.includes(:comments)`, narrowed with `where_between(:created_at, from, to)` when `params[:from]` / `params[:to]` parse as dates (`Cast.date_or_nil`, converted to `Time.utc` at midnight; `to` exclusive of the next day) and `.to_a`)
- Modify: `examples/blog/app/views/articles/index.html.erb` (a `form_with url: articles_path, method: :get` with two `date_field`s `from` / `to`; a Comments column `article.comments.size`)
- Regenerate `examples/blog/gen/**` with the blog's generator (`cd examples/blog && spin run gen` or the documented command)
- Test: `examples/blog/test/articles.rb` (grown): the index shows the comment count after two comments; destroying an article removes its comments; a duplicate title is refused with "has already been taken"; the date filter leaves out an article created outside the range (set `created_at` through `update_columns`); `Article.recent.first` is the newest.

- [ ] **Step 1: Write the failing tests.** **Step 2: Run to verify they fail** (`cd examples/blog && spin test`). **Step 3: Implement and regenerate.** **Step 4: Run** (`spin test` in the blog, snapshots regenerated with the blog's script if it has one, else `spin test --regen` for CRuby-portable programs and the manual capture otherwise). **Step 5: Gate and commit**: "blog: declared associations with dependent: :destroy, includes on the index, a uniqueness validation, a date range filter, a recent scope".

---

### Task 18: Documents, design.md, guides and translations, README, deploy notes

**Files:**
- Modify: `docs/design.md` (D42 to D50 per spec 13, each with the "why" and the Spinel constraint; the programme paragraph at line 102 marks phase 2 delivered; the "Not built"/"Not available" statements that this phase changes)
- Modify: `docs/guide/models.md` (column types and casting incl. the Float note and the datetime format; every new query method with the Rails spelling beside it; associations, `dependent:` vs `on_delete:`, `includes`; validations; `scope`; `encrypts`; migrations' new helpers and `reversible`; `db schema`, `db normalize`; upgrade notes = spec 16), `docs/guide/configuration.md` (the two variables), `docs/guide/{fr,ja,ru,zh}/models.md` and `configuration.md` (translated; then `script/check-guide-i18n --update-sha` on each), `docs/deploy.md` and `docs/deploy.en.md` (the `db normalize` step), `README.md` (feature list), `cybertrain/model.rb` and `cybertrain/migration.rb` "Not available" comments (final state), `spikes/NOTES.md` (any rule found during implementation)
- Modify: `docs/superpowers/specs/2026-11-06-phase2-data-layer-design.md` (append "## 18. Implementation notes" as phase 1's section 13 did: what differed, rule numbers, test counts)

- [ ] **Step 1: Write the documents.** **Step 2: Run** `script/check-guide-i18n` (all four languages pass), `ruby script/gate`, the full `spin test` and the blog's tests; record the counts in the implementation notes. **Step 3: The manual check of spec 17.4** (a SQLite file made by Rails 8.1) needs a Ruby with Rails, which this environment lacks: record in the pull request that `test/schema_dumper_rails.rb` stands in for it, with the DDL Rails writes, and leave the live check to the maintainer. **Step 4: Commit**: "Phase 2 documents: design.md D42 to D50, the models and configuration guides with translations, deploy notes, README".

---

## Execution order and verification

Tasks 1 to 6 are sequential (each later task casts or types through the earlier). Tasks 7, 8, 9, 10 depend on 6 and on each other only through the delegation list (7 creates it; 8, 9, 12 add to it), so they run in order 7 → 8 → 9 → 10. Task 11 needs 7 and 10; 12 needs 11; 13 needs 7 (`where.not`) and 11 (the fixture); 14 needs 10 (`ENCRYPTED_COLUMNS`); 15 and 16 need 5; 17 needs 11, 12, 13; 18 is last. Every task ends with `ruby script/gate` passing and its snapshots reviewed; after Task 17 the whole `spin test` and `cd examples/blog && spin test` pass, which is acceptance item 2 of the spec.
