# Phase 2 of the Rails-gap programme: the data layer

Date: 2026-11-06. Status: agreed with the maintainer (fifteen questions and a
self-review, 2026-11-06); the plan follows.

## 0. Context and scope

The programme (docs/design.md D1, revised 2026-11-05) delivers the 120 items
of the fin_dash survey in five phases. Phase 1 landed on 2026-11-05 (D36 to
D41). This document is **phase 2, the data layer**: the programme paragraph
names "decimal / json / datetime columns, Range `where`, multi-column `pluck`,
bulk upsert, aggregates, `includes`, validators, associations, encryption".
The survey's chapters 8 (database and models) and 9 (numbers and time) hold
these and a few neighbours; the cut agreed for phase 2 is:

- **In:** the nine named items (survey D-2, D-3, D-4, Q-1, Q-2, Q-3, Q-4, Q-5,
  M-1, M-2, M-3); the `date` column type and time parsing (D-7, N-3, N-4),
  which share the `Cast` work with datetime; the small Relation methods
  (Q-6 `where.not` / `or`, Q-7 `distinct`, Q-8 `update_all` / `find_each` /
  `find_or_create_by` / `find_by!` / `none`, M-5's `update_columns`); the
  `scope` macro (M-4); schema and migration additions (D-6 `on_delete`,
  partial and expression indexes; D-8 `change_column`, `rename_table`,
  `change_column_default`, `change_column_null`, `reversible`); the procedure
  for taking over a SQLite file that Rails created (D-5).
- **Out** (section 15): BigDecimal as a value type (N-1, decided against in
  section 2.1), ActiveSupport's time helpers (N-2, to phase 5 with frozen
  time), several databases (D-9), keyset pagination (Q-10), `select` (Q-7),
  enum / `normalizes` / dirty tracking (M-5), concerns (M-6), statistics
  (N-5), polymorphic associations, `has_many :through`, nested `includes`,
  `joins`.

Two criteria decided every judgement call, in this order: **closer to Rails**
(vocabulary, defaults, what a Rails developer types) and **easier to
understand** (fewer framework-only names, nothing hidden). Compatibility with
applications built on CyberTrain 0.4 was given low weight: the framework is
alpha, and each break is listed in section 16 so the applications can be
updated in one pass.

Where Spinel forbids the Rails mechanism, the Rails vocabulary is kept and
the mechanism is the framework's established one: build-time generation from
a lexical scan into `case` tables (D4, D8, D9, D38), never a computed `send`
(spikes/NOTES.md rule 1). One Spinel rule shapes most of this document: **a
method name has one return type across the whole program** (NOTES 10, 34,
41). Rails' `maximum(:views)` answering an Integer for one column and a
Float for another, or `group(:x).sum(:y)` answering a Hash where `sum(:y)`
answers a number, cannot be written; the typed names below (`sum_int`,
`sum_float_by`) are the consequence, not a taste.

## 1. The decisions in one table

| # | Question | Decision |
| --- | --- | --- |
| Q1 | Scope | The nine named items plus their neighbours listed above; the rest to later phases or out |
| Q2 | `t.decimal` in Ruby | `Float`, rounded to `scale` on save; `DECIMAL(p,s)` in SQL; BigDecimal revisited when Spinel's bigdecimal can be built from Float / String and round |
| Q3 | `t.json` in Ruby | `Hash<String, Object>` (object root only); `JSON` in SQL; `Cast.hash` rules for anything else |
| Q4 | datetime | Rails' stored format `YYYY-MM-DD HH:MM:SS.ffffff` (UTC, microseconds); reads accept `T` / space, fractions, `Z` / `±HH:MM`; `as_json` writes `2026-10-05T09:00:00.000Z`; existing `T…Z` rows are rewritten by an explicit `db normalize` |
| Q5 | `t.date` and parsing | `Date` (Spinel's `date` package, spiked first); `Time.iso8601` / `Time.rfc2822` / `Time.strptime` as class methods on `Time` (spiked; `Cast` is the fallback home) |
| Q6 | Relation additions | Range `where` (Integer ends; `where_between` for Time, Date, Float and String), `where.not`, `or`, `distinct`, `update_all`, `destroy_all`, `find_each`, `find_or_create_by`, `find_or_initialize_by`, `find_by!`, `none`, `update_columns`; `where("sql ?", …)` and `order(col: :desc)` forms; no `select` |
| Q7 | Multi-column pluck | `pluck(*columns)` → rows of column-typed cells; one column is an `ArgumentError` pointing at `pluck_str` / `pluck_int` / `pluck_float`; `pick` |
| Q8 | Bulk writes | `insert_all` / `insert_all!` / `upsert_all` in one multi-row statement per chunk, `RETURNING id` by default, timestamps filled, one transaction |
| Q9 | Aggregates | Typed names: `minimum_int` / `_float` / `_time`, `maximum_*`, `average`; grouped `*_by(group, col)` → `Hash<String, T>`; four `_sql` expression forms; `having_sql` |
| Q10 | Associations | Declared in `app/models` and scanned lexically; `has_many` returns a Relation; `has_one`, `dependent:`, `counter_cache:`, `optional:` (declared `belongs_to` is required by default); `on_delete:` in the schema |
| Q11 | `includes` | Preload in one extra query per association, one level, for `has_many`, `has_one` and `belongs_to`; `preload` is an alias |
| Q12 | Validators | `inclusion`, `exclusion`, `format`, `numericality`, `uniqueness`, fuller `length`, `allow_nil`, `on:`, `message:`; `validate :method` and `if:` / `unless:` Symbols through a generated `case` |
| Q13 | Encryption | `Cybertrain::Encryptor` (AES-256-GCM, OpenSSL::Cipher), key in `CYBERTRAIN_ENCRYPTION_KEY`, `encrypts :column` scanned lexically; no deterministic mode |
| Q14 | Schema and migrations | `decimal`, `json`, `bigint`, `precision:`; `on_delete:`; partial and expression indexes dumped from `sqlite_master.sql`; `rename_table`, `change_column*`, `remove_reference`, `remove_foreign_key` by table rebuild; `reversible`; `db schema` dump and a documented Rails takeover |
| Q15 | Acceptance | A spike task first; the blog gains declared associations, `includes`, a uniqueness validation and a Range `where`; new tests per area; D42 to D50 |
| R1 to R7 | Self-review | `where.not` over `where_not`; `where` takes SQL strings and `order` takes a Hash; every Relation method also on the model class; `scope`; `db normalize` over a hidden migration; `Time.iso8601` over `Cast`; four `_sql` aggregates only |

## 2. Column types and casting

### 2.1 `decimal` (survey D-2, N-1)

- Schema DSL: `t.decimal :price, precision: 18, scale: 8, null:, default:`.
  SQL: `DECIMAL(18,8)` (NUMERIC affinity, which is what Rails' SQLite adapter
  writes; Rails binds a BigDecimal as `to_f`, so an existing fin_dash
  database holds REAL values and loses nothing when read as Float).
  `precision` without `scale` is allowed; neither is required. The dumper
  reads `DECIMAL(p,s)` / `NUMERIC(p,s)` back as `t.decimal` with both.
- Model attribute: `Float` (NOT NULL) / `Float | nil` through `Cast.float` /
  `float_or_nil`, as a `float` column. On save (`to_row`, `insert_all`,
  `upsert_all`, `update_all`, `update_columns`) the value is rounded with
  `Float#round(scale)` when the column has a scale, so what Rails shows after
  assignment (`BigDecimal#round(scale)`) is what is stored. `precision` is
  used in the DDL only.
- `JSON.parse(text, decimal_class: BigDecimal)` stays unsupported: JSON
  numbers are Float.
- Why not BigDecimal: Spinel's `bigdecimal` package is a pure-Ruby class with
  `+ - * /` only, no construction from Float or String parsing, no `round(n)`,
  no comparison beyond `==`, no Infinity / NaN, and it has not been shown to
  compile inside a framework program. The decision is recorded in D42 with
  the condition for revisiting it. The guide's models page gets a paragraph
  on Float rounding (sums of prices accumulate binary error; round at the
  edge, or store minor units in an integer column).

### 2.2 `json` (D-3)

- Schema DSL: `t.json :meta, null:, default:`. SQL: `JSON` (Rails' SQLite
  type name; the dumper maps `JSON` to `:json`). A default is the JSON text
  (`default: "{}"`).
- Model attribute: `Hash<String, Object>` for NOT NULL, `Hash | nil` for
  nullable. Read: the TEXT cell goes through `JSON.parse` then `Cast.hash`
  (NOT NULL) or the new `Cast.hash_or_nil` (nullable, nil for NULL). A
  non-object root, invalid JSON or `""` follows `Cast.hash`'s rule: `{}`
  (or nil for nullable); no exception. Write: `JSON.generate(hash)` as TEXT.
  Nested values are boxed as every JSON value is under Spinel (D22, NOTES
  71): readers narrow with `Cast.int(meta["n"])`, `Cast.hash(meta["sub"])`,
  `Cast.array(meta["list"])`.
- `where(meta: …)` on a json column raises `ArgumentError` from the generated
  column check (as `where` on an encrypted column does, section 10).
- `as_json` nests the Hash; `pluck` of a json column answers the stored text
  (section 4).
- Arrays at the root are not supported in phase 2 (recorded in section 15):
  store them in a `text` column and read with `Cast.array`.

### 2.3 `datetime` (D-4, N-3)

**Stored format.** `YYYY-MM-DD HH:MM:SS.ffffff`: UTC, a space, six fraction
digits, no suffix. This is exactly what Rails writes to SQLite, so a database
Rails created needs no conversion, and one column holds one format. The old
CyberTrain format `YYYY-MM-DDTHH:MM:SSZ` sorted *after* every Rails-format
value regardless of date (byte 10: `T` 0x54 > space 0x20), which broke
`ORDER BY` and range `WHERE` on mixed columns.

- `Cast.sql_datetime(time)` writes it (`time.getutc.strftime("%Y-%m-%d
  %H:%M:%S.%6N")`). Every writer uses it: `Connection#bind` for a Time,
  `Model.now_string`, the job, lease and stream tables, migrations'
  `execute` binds through `Cast.to_sql`.
- Precision: microseconds. The C reader `cybertrain_sqlite_column_epoch`
  (db/sqlite_ffi.rb) returns the epoch in **microseconds** as an Integer
  (`-1` when the text is not a datetime); `execute_models` builds
  `Time.at(us / 1_000_000, us % 1_000_000).utc`. It accepts both `T` and
  space, any number of fraction digits (0 to 9, truncated to 6), and `Z` or
  `±HH:MM` / `±HHMM`, applying the offset.
- `Cast.parse_time(text)` (behind `Cast.time_or_nil`) accepts the same
  shapes plus RFC 2822 (`Thu, 05 Nov 2026 09:00:00 +0000`, with the English
  day and month names). Fractions and offsets are no longer discarded.
- `Cast.iso8601(time)` is now the **display** format and matches Rails'
  `as_json`: `2026-10-05T09:00:00.000Z` (milliseconds, `Z`). `as_json`,
  `to_json` and `Cast.str(time)` use it. The storage and display formats are
  two methods on purpose.
- Existing rows in the old format: **`./app db normalize`** rewrites every
  DATETIME cell of every table (a declared type starting with `DATETIME`,
  as `Connection.datetime_decl?` reads it) that is **not already in the
  canonical format** (checked with `GLOB` and a `[0-9]` class at every digit
  position, `[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]`;
  `LIKE`'s `_` would accept `2026-10-05 09:00:00.12345Z` as canonical): each
  such cell is read, parsed with `Cast.parse_time` (so `T…Z` rows, short
  fractions and offset-bearing values all land on the same UTC six-digit
  text) and written back with `Cast.sql_datetime`, row by row, located by
  `_rowid_` (no `id` column is needed, and a duplicated `id` cannot make one
  UPDATE touch two rows; a `WITHOUT ROWID` table, or one declaring a column
  named `_rowid_` in any letter case, generated columns included, is
  reported and skipped), in one transaction; a cell `parse_time` cannot read
  is left alone and counted separately. It prints the count per table and
  column. A skipped table is not silently left behind: its non-canonical
  cells are still counted, the CLI prints `skipped t.c: without rowid (N rows
  still need normalization)`, and **the command exits 1 when any skipped
  column still has such cells**, so the deploy procedure below stops before
  the new binaries start; those tables are rewritten by hand (`UPDATE` by
  primary key) and `db normalize` is run again. It is idempotent and safe to
  run twice. The deploy
  guides say: stop the old binaries, `db migrate`, `db normalize` once,
  start the new ones. This is an explicit command, not a hidden step in `db
  migrate`: an alpha release can ask for one command, and nothing in the
  migrator gets a reserved version row.

### 2.4 `date` (D-7, N-4)

- Model attribute: the standard `Date` (Spinel's `date` package). NOT NULL
  → `Date`, nullable → `Date | nil`, through the new `Cast.date` /
  `Cast.date_or_nil` (`YYYY-MM-DD` text ↔ `Date.new(y, m, d)`; anything else
  is nil, or `Date.new(1970, 1, 1)` for a NOT NULL cell that fails to parse,
  so a corrupt cell does not take the row down).
- Stored format `YYYY-MM-DD`, unchanged. `Connection#bind` binds a Date as
  that text; `where(day: date)` works; `where(day: d1..d2)` works (section
  3.1).
- Uses in the framework: `Date#to_s`, `strftime`, `year` / `month` / `day`,
  `+` / `-` (days), `<=>`. The spike (section 14) checks these compile in a
  framework program; if `date` does not compile, the column stays a String
  and D42 records why.
- `Date.parse`'s free-form input is not used; `Cast.date_or_nil` is strict.

### 2.5 `bigint`

`t.bigint :x` is accepted and writes `BIGINT`; SQLite's INTEGER is 64-bit, so
it is the same column, and the dumper writes it back as `t.integer` (BIGINT
already maps to `:integer`). The guide says so in one sentence.

### 2.6 Time parsing on `Time` (N-3, R6)

The framework defines, in `cybertrain/time_ext.rb` (required by
`cybertrain.rb`):

- `Time.iso8601(text)` → Time (UTC), raising `ArgumentError` on anything
  `Cast.parse_time` rejects.
- `Time.rfc2822(text)` → Time, same contract.
- `Time.strptime(text, format)` → Time: directives `%Y %m %d %H %M %S %L %z
  %Z %b %B %a %A %j %s %%` and literal separators; any other directive raises
  `ArgumentError` naming it. `%Z` accepts `UTC`, `GMT` and `Z` only.

These are the Ruby / Rails spellings. The spike checks that Spinel accepts
class methods added to `Time` from Ruby source (its own `Time.parse` reads
numeric ISO 8601 only, and a literal `Time.strptime` was refused at compile
time, so the refusal may be by name); if it does not, the same three live on
`Cast` (`Cast.time_iso8601`, `Cast.time_rfc2822`, `Cast.strptime`) and D42
says so. Millisecond epochs need no helper: `Time.at(ms / 1000.0)` is exact
for any realistic epoch in a double.

## 3. The query API

All methods below are on the generated `<Model>Relation`; **every one also
exists on the model class** as `def self.x(...) = all.x(...)` (R3), so
`Article.pluck(:id, :title)`, `Article.includes(:comments)`,
`Article.where.not(draft: true)`, `Article.find_each { }` and
`Article.maximum_time(:created_at)` read as in Rails. The generator emits the
delegations from one list, so a method added to Relation is added to the
class in the same place. Relations keep mutating `self` (relation.rb); a
copy-on-write relation is not part of this phase.

### 3.1 `where` (Q-1, Q-6, R1, R2)

- `where(hash)` as today, plus a **Range** value with Integer ends: `a..b`
  → `` `c` >= ? AND `c` <= ? ``, `a...b` → `>= ? AND < ?`, `a..` → `>= ?`,
  `..b` → `<= ?` (`...b` → `< ?`). **Only Integer ends** (spike result,
  section 14): under Spinel a Range of Time or Date raises `TypeError` when
  it is built, and a Float or String Range held in a Hash value is not
  matched by `when Range`, so `where(created_at: from..to)` cannot exist.
  Time, Date, Float and String bounds are written as
  **`where_between(:created_at, from, to)`** (`nil` for an open end, both
  ends inclusive; `where_between(:c, from, to, exclude_end: true)` for
  `<`), or as the String form `where("created_at >= ? AND created_at < ?",
  from, to)`. The ends go through `bind_for` (a Time becomes the stored
  format, a Date its text). D43 records the reason; the guide shows
  `where_between` next to Rails' Range form.
- `where(sql, *binds)`: a String first argument is a SQL fragment with `?`
  placeholders, as Rails' `where("views > ?", 10)`. The method takes one
  parameter typed `Hash | String` plus a splat; a `case` picks the branch.
  `where_sql(sql, binds)` stays as the explicit spelling.
- `where()` with no argument returns `self`; **`not(hash)`** on the Relation
  negates: `IS NOT NULL`, `!= ?`, `NOT IN (…)`, `NOT (… AND …)` for a Range.
  So `Article.where.not(draft: true)` is written as in Rails. `def not` and
  `rel.not(...)` are legal Ruby (Rails' `WhereChain#not` is the same); the
  spike checks Spinel's parser accepts them, and `where_not(hash)` is the
  fallback.
- `or(other)`: `other` is a Relation of the same model; the result's WHERE is
  `(A) OR (B)` with the binds concatenated, where A and B are the two
  conjunctions. `other` carrying an order, limit, offset, distinct or
  includes that differs raises `ArgumentError` (Rails' rule).
- An encrypted or json column as a `where` key raises `ArgumentError` from
  the generated check.

### 3.2 `order`

`order(hash)` is added: `order(created_at: :desc, id: :asc)` with Symbol keys
checked against the columns and `:asc` / `:desc` values. The existing
`order("col DESC")` list form stays.

### 3.3 Other additions (Q-7, Q-8, M-5)

- `distinct`: a flag. `pluck*` and `exists?` emit `SELECT DISTINCT`; `count`
  becomes `SELECT COUNT(*) FROM (SELECT DISTINCT …)`. For the aggregates
  (section 5) the flag applies to the **aggregate's input**, `SUM(DISTINCT
  price)` / `AVG(DISTINCT …)` (`SELECT DISTINCT SUM(price)` would dedupe the
  one result row, not the inputs); `MIN` / `MAX` ignore it. `to_a` is
  unaffected (rows are distinct by id).
- `update_all(hash)` → `UPDATE t SET … WHERE …`, the limit / offset window as
  an id subselect (as `delete_all`), values through the save-time casts
  (decimal rounding, json, Time, Blob), `updated_at` untouched (Rails);
  returns the number of rows.
- `destroy_all`: loads the records and `destroy`s each (callbacks,
  `dependent:`); returns the records.
- `find_each(batch: 1000) { |record| }`: keyset by id (`WHERE id > ? ORDER BY
  id LIMIT n`); any order on the relation is ignored (Rails). A yielding
  method on the relation, as `each` is.
- `find_or_create_by(hash)`, `find_or_initialize_by(hash)`: `find_by` then
  `create` / `new` with the hash's attributes.
- `find_by!(hash)`: `find_by` or `RecordNotFound`.
- `none`: a relation whose WHERE is `1 = 0`.
- `ids`: `pluck_int(:id)`.
- Instance `update_columns(hash)`: `UPDATE` of those columns only, no
  callbacks, no validations, `updated_at` untouched, the ivars updated.
- `Model.create!(attrs)`: `create` that raises `RecordInvalid`.
- `select` is not added: a record missing columns would show NOT NULL
  columns as `0` / `""`, and Rails' `MissingAttributeError` has no
  equivalent in a generated class. `pluck` covers the use.

### 3.4 `scope` (M-4, R4)

`scope :recent, -> { order(created_at: :desc) }` and `scope :since, ->(t) {
where("created_at > ?", t) }` in `app/models/article.rb` are read lexically
by the generator (D38's scanner), which **copies the lambda's parameter list
and body text** into two generated methods: `def self.recent = all.recent`
on the model class and `def recent = order(created_at: :desc)` on the
Relation (the body runs with the relation as the implicit receiver, which is
where `where` / `order` / `limit` live). Chaining works: `Article.recent.since(t)`.
Nothing is evaluated at generation time; a body that is not valid in a
Relation (it names a local, calls a model instance method) fails at Spinel
compile time with the generated file and line in the message. Scope names
that collide with a Relation method or a column raise at generation.

## 4. `pluck` and `pick` (Q-2)

- `pluck(*columns)` → `Array<Array<Cell>>`, a row per record, one cell per
  column, in the order asked. `Cell` is the union `Integer | Float | String |
  true | false | Time | Date | nil`, seeded as `Cast.binds` seeds its array
  (NOTES 9). Cells are **cast by column type**: integer → Integer, float and
  decimal → Float, boolean → true / false, datetime → Time (microseconds),
  date → Date, string / text → String, NULL → nil; **json and binary stay
  the stored String** (JSON text, bytes). The generated Relation knows the
  column types (as it knows `binary_column?` since D40), so no decltype
  inspection is needed.
- Exactly one column raises `ArgumentError` with a message naming
  `pluck_str` / `pluck_int` / `pluck_float` (and `ids`). Rails answers a flat
  Array for one column and nested Arrays for several; one return type per
  method name forbids both, and `[[1], [2]]` would be a silent trap.
- `pick(*columns)` → the first row (`Array<Cell>`) or nil, with `limit(1)`.
- Column names only, checked with `checked_column`; an expression is written
  with `DB.with { |c| c.execute(sql, binds) }`.
- `distinct` applies.

## 5. Aggregates (Q-4)

Following `sum_int` / `sum_float` / `count_by` / `count_by_sql` (D22):

| Method | Returns |
| --- | --- |
| `minimum_int(col)`, `maximum_int(col)` | `Integer \| nil` |
| `minimum_float(col)`, `maximum_float(col)` | `Float \| nil` |
| `minimum_time(col)`, `maximum_time(col)` | `Time \| nil` (datetime columns) |
| `average(col)` | `Float \| nil` (`AVG`) |
| `sum_int_by(group, col)`, `sum_float_by`, `minimum_int_by`, `minimum_float_by`, `minimum_time_by`, `maximum_int_by`, `maximum_float_by`, `maximum_time_by`, `average_by` | `Hash<String, T>`: the key is the group column's value as text (`count_by`'s convention), T as the ungrouped method |
| `sum_float_sql(expr)`, `minimum_float_sql(expr)`, `maximum_float_sql(expr)`, `average_sql(expr)` | `Float \| nil`; `expr` is raw SQL as in `count_by_sql` |
| `having_sql(sql, binds = [])` | a chain method; applies to the `_by` methods (`GROUP BY … HAVING …`) |

With `distinct` set, every aggregate above is written over distinct inputs
(`SUM(DISTINCT col)`, `AVG(DISTINCT expr)`, also inside the `_by` forms);
`MIN` and `MAX` are the same either way. `group` is not a separate flag: a
flag that changes a method's return type cannot exist. An aggregate over an expression *and* a group, or one that
needs a second table (`joins`), is written with `DB.with`. The guide's models
page shows the Rails spelling next to each name once.

## 6. Bulk writes (Q-3)

Class methods on the generated model (they need the column types); the body
is in `Model` as `insert_all_into(table, rows, …)`.

- `Model.insert_all(rows, returning: [:id], record_timestamps: true)`:
  `INSERT INTO t (cols) VALUES (…), (…) ON CONFLICT DO NOTHING RETURNING id`.
  Returns `Array<Hash<String, Cell>>`, the RETURNING rows, so `.size` is the
  number of rows actually inserted (duplicates are skipped silently, as in
  Rails); `returning: []` returns an empty Array; `returning: [:id, :title]`
  returns those columns cast by type.
- `Model.insert_all!(rows, …)`: the same without `DO NOTHING`; a constraint
  violation raises the connection's error.
- `Model.upsert_all(rows, unique_by: [:id], update_only: nil, returning:
  [:id], record_timestamps: true)`: `ON CONFLICT (unique_by) DO UPDATE SET c =
  excluded.c` for the **columns the rows supply**, minus `id`, the
  `unique_by` columns and `created_at` (or only those of `update_only` that
  the rows supply). A column absent from the rows is never in the SET, so an
  upsert of `id` and `title` leaves `body` as it was. `updated_at =
  excluded.updated_at` is added only when `record_timestamps` is true and the
  column exists (the rows then carry it, section below); with
  `record_timestamps: false` it is touched only if the rows supply it.
- `rows` is `Array<Hash<Symbol, value>>`; every row must have the same key
  set or `ArgumentError`. Values take the save-time casts (section 2:
  Time → stored format, Hash → JSON text, binary → Blob, decimal → rounded,
  Date → text). Columns absent from the rows are left to the table DEFAULT
  (`save` writes every column; bulk writes name only the given ones, as
  Rails does).
- Timestamps: with `record_timestamps: true` (the default), when the table has
  `created_at` / `updated_at` and a row lacks them, both are filled with one
  `now` per call; with `record_timestamps: false` nothing is filled and the
  rows' own values, if any, are written as given.
- Chunking: rows per statement = `sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1)
  / columns` (a new FFI binding; the default is 32766, older builds 999).
  All chunks run in **one transaction** (`DB.transaction`, joining an open
  one), so a failure in chunk 3 leaves nothing of chunks 1 and 2 (inside a
  transaction the caller opened, the caller's rollback decides).
- No callbacks, no validations, no `encrypts` (an encrypted column in a bulk
  row raises `ArgumentError`): the guide says so.
- `RETURNING` needs SQLite 3.35 (2021-03); the spike reads
  `sqlite3_libversion` of the bundled library and the plan pins the minimum.

## 7. Associations (M-2, D-6)

### 7.1 Declarations

The generator scans `app/models/*.rb` (the D38 scanner) for

```ruby
has_many :comments, dependent: :destroy, class_name: "Comment", foreign_key: :article_id
has_one :profile, dependent: :destroy, class_name:, foreign_key:
belongs_to :author, class_name: "User", foreign_key: :author_id, optional: true, counter_cache: true
```

with literal options only. A declaration whose foreign key column does not
exist in the schema, or whose `class_name` is not a model, fails the
generation with the file and line. Foreign keys without a declaration keep
producing `belongs_to` / `has_many` as today (D10), so a schema alone still
gives associations; a declaration refines or renames one. `has_one` on a
foreign key suppresses the generated `has_many` for it.

### 7.2 What is generated

- **`has_many` returns the generated Relation** (`CommentRelation.new(…)
  .where(article_id: @id)`), not an Array: `article.comments.where(…)`,
  `.count`, `.order(…)`, `includes` all work. `read_association` (templates)
  returns `to_a`, so templates are unchanged. Application code that used
  Array methods on the result (`map`, `select`, `[]`) adds `.to_a`
  (section 16).
- `belongs_to`: `def author` answers from the preload cache when it is
  valid, otherwise `User.find_by(id: @author_id)`. The cache is three ivars
  set only by `includes` (section 8): `@author_loaded` (Boolean; a separate
  flag, because SQLite lets an explicit id be any Integer, so no Integer
  sentinel is safe), `@author_loaded_key` (the foreign key value the preload
  ran for) and `@author_record` (the parent, **or nil when the preload found
  none**). It is used when `@author_loaded && @author_loaded_key ==
  @author_id`, so a parent that does not exist is answered as nil without a
  query, and a reassigned `author_id` never answers the stale parent even
  though the writer is a plain `attr_accessor` (NOTES 43 forbids a custom
  `author_id=`). `reload` resets every cache and preload.
- `has_one`: `def profile` follows the same shape with `@profile_loaded`
  (Boolean) and `@profile_record` (`Profile | nil`): a preloaded owner with
  no profile answers nil from the cache, so a list of owners without
  profiles stays at two queries. Without a preload,
  `Profile.find_by(user_id: @id)`.
- `dependent:` is applied inside `destroy`, before the row's DELETE, in one
  `DB.transaction` (joining an open one): `:destroy` loads the children and
  `destroy`s each (their callbacks and their own `dependent:` run);
  `:delete_all` runs one `DELETE`; `:nullify` runs one `UPDATE … SET fk =
  NULL`. `has_one` takes the same three. No `dependent:` keeps today's
  behaviour (the database's foreign key decides, see 7.3).
- `counter_cache: true` on `belongs_to`: `after_create` increments and
  `after_destroy` decrements `<children>_count` on the parent with
  `increment`. A **moved child** is counted too: inside the save's
  `DB.transaction` (joining an open one) a generated `before_update` hook
  reads the persisted foreign key straight from the database (`SELECT
  author_id FROM posts WHERE id = ?`) into `@author_id_was`, valid for that
  save only, and `after_update` compares it with `@author_id`; when they
  differ it decrements the old parent and increments the new one. There is
  no long-lived snapshot: two instances of one child, or a rolled-back save,
  cannot leave a stale key behind. The read, the UPDATE and the two
  increments run in that one transaction.
  The column must exist (generation error otherwise).
- A declared `belongs_to` without `optional: true` adds a presence validation
  on the foreign key (Rails 5 default). Undeclared, foreign-key-derived
  associations add nothing (the column's NOT NULL is the rule).

### 7.3 Schema side: `on_delete`

`t.references :article, on_delete: :cascade | :nullify | :restrict`,
`add_reference(…, on_delete:)` and `add_foreign_key(…, on_delete:)` write
`ON DELETE CASCADE | SET NULL | RESTRICT`; `Schema::ForeignKey` gains
`on_delete`; the dumper reads `PRAGMA foreign_key_list`'s `on_delete` column
and writes the option back (omitted for `NO ACTION`). `dependent: :destroy`
and `on_delete: :cascade` are both offered and the guide says which to pick
(callbacks need the former; speed and other writers favour the latter).

### 7.4 Not in phase 2

`polymorphic: true` (two uses in fin_dash; the reader's return type would be
a union of model classes, which a generated method cannot carry; the
application writes `target_article` / `target_user` readers), `has_many
:through`, a scope lambda on `has_many` (chain on the returned Relation
instead), `inverse_of`, `dependent: :restrict_with_error`.

## 8. `includes` (Q-5)

- `includes(*names)` (and `preload`, an alias) on the generated Relation and
  model class; `names` are Symbol literals checked by a generated `case`
  (unknown → `ArgumentError`). One level only in phase 2 (`includes(comments:
  :author)` is section 15).
- `to_a` loads the rows, then for each name runs **one** query: `has_many` /
  `has_one` → `Child.where(fk: ids)`, `belongs_to` → `Parent.where(id:
  parent_ids)`, with the id list chunked at the variable limit; the results
  are distributed into the records' preload slots.
- `has_many`: the record's `@comments_preloaded` (an Array) is set; the
  Relation that `comments` returns is created **preloaded**: `to_a`, `each`,
  `first`, `last`, `size`, `empty?` answer from memory; `count` runs SQL
  (Rails); any chain method (`where`, `order`, `limit`, `includes`, …) drops
  the preload and the relation queries as usual.
- `belongs_to` / `has_one`: `@author_loaded` + `@author_loaded_key` +
  `@author_record` and `@profile_loaded` + `@profile_record` are set for **every** record in the
  batch, with a nil record where the query found no row (section 7.2), so a
  missing parent or profile costs no further query.
- Templates: `read_association` returns the preloaded `to_a`, so a loop over
  `@articles` with `article.comments.size` runs two queries instead of N+1,
  with no template change.
- `eager_load` and `joins` are not added.

## 9. Validators (M-1)

### 9.1 `validates`

```ruby
validates :title, presence: true, length: { minimum: 3, maximum: 120 }, uniqueness: true
validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
validates :views, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create, message: "is taken"
```

- Options: `presence`, `length` (`minimum`, `maximum`, `is`, `in`),
  `inclusion` / `exclusion` (`in:` an Array, or a Range of Integers; other
  Ranges cannot be built under Spinel, section 3.1), `format` (`with:`, `without:` Regexp),
  `numericality` (`only_integer`, `greater_than`,
  `greater_than_or_equal_to`, `less_than`, `less_than_or_equal_to`,
  `equal_to`, `other_than`; a String attribute is parsed as a number first,
  Rails' behaviour), `uniqueness` (`true` or `{ scope:, case_sensitive: }`),
  and on every rule `allow_nil:`, `allow_blank:`, `on: :create | :update`,
  `message:`. The rules are run-time `Validator` objects in
  `VALIDATORS[model]` as today; no generation.
- Uniqueness: the generated model defines `unique_value_taken?(attr, value,
  scope_attr, scope_value, exclude_id)` (`where(attr: value)[.where(scope:
  …)].where.not(id: exclude_id).exists?`), with a `Model` stub (NOTES 3); the
  Validator calls it on the record. `case_sensitive: false` compares
  `LOWER(col) = LOWER(?)`; the default is case-sensitive, which is SQLite's
  BINARY collation.
- Messages are Rails' English defaults ("is not included in the list", "is
  reserved", "is invalid", "is not a number", "must be an integer", "must be
  greater than 0", "has already been taken", "is the wrong length (should be
  n characters)"); `message:` overrides. i18n is phase 4.
- Context: `valid?` and `save` derive `:create` / `:update` from
  `new_record?`; rules with `on:` run in their context only. `valid?(context)`
  is not added.

### 9.2 `validate :method` and conditions

- `validate :check_dates, :check_totals, on: :update, if: :published?,
  unless: :imported?` in a model file is scanned lexically; the generator
  emits `run_custom_validations(context)` on the model, a `case`-free
  sequence of `check_dates if …` calls to the literal method names (D8's
  callback pattern). `valid?` runs it after the declared rules.
- `if:` / `unless:` on `validates` and `validate` take **Symbol method
  names only**; the generator emits `validation_condition?(name)` as a
  `case` over the names it saw, and the Validator calls it. A lambda is
  rejected at generation with a message that says to name a method.
- Not added: `validates_with`, `validates_each`, `confirmation` (phase 4
  with authentication), `acceptance`, `errors.added?`.

## 10. Encryption (M-3)

- `Cybertrain::Encryptor.new(key)` with `encrypt(plaintext) → String` and
  `decrypt(payload) → String`: AES-256-GCM through `OpenSSL::Cipher` (Spinel's
  openssl package offers aes-128-gcm and aes-256-gcm only, which is what an
  authenticated encryption of a column wants), a fresh 12-byte random nonce
  per call, the payload `"1:" + Base64(nonce ‖ ciphertext ‖ tag)` (the
  leading `1` is the payload format version). A wrong key, a changed byte or
  an unknown version raises `Cybertrain::Encryptor::Error`. (Amended after
  implementation, section 18: openssl stays opt-in. `require "cybertrain"`
  does not link it; cybertrain/encryptor.rb is required by gen/app.rb when a
  model declares `encrypts`, and by hand for `Crypto.encrypt`, as
  cybertrain/net/tls.rb is for outbound TLS.)
- `Cybertrain::Crypto.encrypt(text)` / `decrypt(text)` use the configured key.
- Keys: `CYBERTRAIN_ENCRYPTION_KEY`, 64 hex characters (32 bytes), read into
  `Config#encryption_key`. It is **not derived from `secret_key_base`**:
  rotating the session secret must not make stored data unreadable (Rails
  keeps them apart for the same reason). `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS`
  (comma-separated hex keys) is tried for decryption only, so a key can be
  rotated by re-saving. An application that declares `encrypts` without a
  key fails at boot with the configuration check (one that only calls
  `Crypto.encrypt` raises `Encryptor::Error` at the call instead; amended,
  section 18), `cybertrain/config.rb`'s existing validation, naming the variable and how
  to make one: `cybertrain secret` prints a hex key (the existing command
  prints a session secret; it gains `--hex 32`, or the guide shows `openssl
  rand -hex 32`). `cybertrain new` writes the variable, commented, into
  `.env.example`.
- Models: `encrypts :api_key` in `app/models/*.rb` is scanned; the generated
  `load_row` decrypts (`Crypto.decrypt(Cast.str_or_nil(row["api_key"]))`,
  nil stays nil) and `to_row` encrypts. The column is `text` (payload length
  varies; Rails recommends text too). `where(api_key: …)` raises
  `ArgumentError` from the generated column check; `pluck(:api_key)` answers
  the ciphertext (documented). `update_all` / `insert_all` / `upsert_all` on
  an encrypted column raise `ArgumentError`.
- Not in phase 2: `deterministic: true` (searchable encryption), compatibility
  with Rails' `ActiveRecord::Encryption` envelope (its key derivation
  differs; a migration re-encrypts, and the guide shows the loop).
- The spike (section 14) compiles an `OpenSSL::Cipher` round trip in a
  framework program and checks a flipped byte fails `final`.

## 11. Schema DSL, migrations, dumper, and taking over a Rails database

### 11.1 Schema DSL and dumper (D-2, D-3, D-6)

- Types: `t.decimal :x, precision:, scale:` (2.1), `t.json :x` (2.2),
  `t.bigint :x` (2.5), `t.datetime :x, precision: 6` (accepted, ignored).
  `Schema::Column` gains `precision` and `scale`; `sqlite_ddl.sql_type`,
  `SchemaDumper.column_type` and `Schema::Dumper.to_ruby` learn the new
  names and options; the generator's `cast_for` / `bind_expression` /
  `initial_value` learn `:decimal` (Float), `:json` (Hash), `:date` (Date).
- Foreign keys: `on_delete:` (7.3).
- Indexes: `add_index :t, :c, where: "deleted_at IS NULL"` (partial),
  `add_index :t, "LOWER(email)", name:` (a String column spec is an
  expression), `t.references :x, index: false`. The dumper reads the `sql`
  text of each index from `sqlite_master` to recover `WHERE …` and
  expression columns (`PRAGMA index_info` names them NULL), and writes
  `where:` and the expression back. The ddl escapes nothing inside an
  expression: it is the author's SQL, as `execute` is.
- The dumper's skip list gains `ar_internal_metadata` (Rails' metadata
  table).

### 11.2 Migrations (D-8)

- `rename_table(old, new)`: `ALTER TABLE … RENAME TO …`, reversible.
- `change_column(table, column, type, null:, default:, limit:, precision:,
  scale:)`, `change_column_default(table, column, from:, to:)`,
  `change_column_null(table, column, null, default = nil)`,
  `remove_reference(table, name)`, `remove_foreign_key(from, to, column:)`:
  all through one `SqliteDDL.rebuild_table(definition, table)` that follows
  SQLite's documented procedure (create `<table>_new` from the new
  definition, `INSERT INTO … SELECT` the common columns, drop the old table,
  rename, recreate the indexes **and the table's triggers** from their
  `sqlite_master.sql`, and restore the table's `sqlite_sequence` high-water
  mark captured before the drop when it is above the copied rows' maximum,
  so `AUTOINCREMENT` never reuses a deleted id). `change_column_null(table,
  column, false, default)`'s fourth argument **backfills** the existing NULL
  cells (`UPDATE t SET c = ? WHERE c IS NULL`) before the copy and is never
  written as the column's DEFAULT (Rails' contract). Foreign keys follow SQLite's procedure to
  the letter: `PRAGMA foreign_keys = OFF` is a no-op inside a transaction,
  so for a version that contains a rebuild the **migrator turns it off
  before `BEGIN`**, runs `PRAGMA foreign_key_check` before `COMMIT` (a
  violation rolls the version back with the offending rows in the message),
  and turns it back on after. With enforcement left on, dropping the old
  table would fire `ON DELETE CASCADE` on its children and the check would
  then find nothing wrong (`defer_foreign_keys` does not prevent that).
  `remove_column` keeps its current implementation.
- Reversibility: `rename_table` inverts; `change_column_default` and
  `change_column_null` invert when `from:` / `to:` (or the `default`
  argument) make the previous state known, otherwise `IrreversibleMigration`
  on rollback; `change_column`, `remove_reference` and `remove_foreign_key`
  are irreversible inside `change` (write `up` / `down`), as in Rails.
- `reversible do |dir| dir.up { execute "…" } dir.down { execute "…" } end`:
  recorded as two operations, one per direction.
- `Operation` keeps its one-class shape; the new kinds are new `kind` values.

### 11.3 Taking over a SQLite file Rails created (D-5)

A section in the migrations guide, with the test in 11.4 as proof:

1. Copy the Rails SQLite file to `db/<env>.sqlite3`.
2. Run **`./app db schema`** (new: writes `db/schema.rb` from the database
   with the dumper that `db migrate` uses; it takes no other action).
   `db migrate` then reports nothing to do.
3. Do not copy Rails' `db/migrate/*.rb`; new migrations start from here. The
   Rails versions already in `schema_migrations` (the table has the same
   shape in both: `version TEXT PRIMARY KEY`) are ignored by the migrator
   when no file carries them (the plan adds a test that an applied version
   without a file is neither run nor reported).
4. What needs no conversion: datetimes (2.3), booleans (Rails writes 1 / 0;
   older `t` / `f` is in `Cast::TRUE_STRINGS`), decimals (REAL, read as
   Float), json (TEXT, read as Hash), `datetime(6)` / `decimal(18,8)` /
   `varchar` / `bigint` / `json` type names (the dumper maps them).
5. Limits: a table without `id` (`id: false`, join tables) is not modelled
   and is reached with `DB.with`; `ar_internal_metadata` is left alone;
   encrypted columns are re-encrypted (section 10).

### 11.4 Tests for this section

`test/schema_dumper_rails.rb` builds a database with the DDL Rails 8.1
writes (`"created_at" datetime(6) NOT NULL`, `"price" decimal(18,8)`,
`"meta" json`, `"views" bigint DEFAULT 0 NOT NULL`, a `WHERE` index, an
expression index, `ON DELETE CASCADE`, `ar_internal_metadata`,
`schema_migrations` rows) and checks the dumped `db/schema.rb` loads and
round-trips. `test/migration_rebuild.rb` covers each rebuilt operation and
its rollback.

## 12. Configuration added

| Variable | Config reader | Default | Meaning |
| --- | --- | --- | --- |
| `CYBERTRAIN_ENCRYPTION_KEY` | `encryption_key` | unset | 64 hex chars; required when `encrypts` or `Crypto.encrypt` is used |
| `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` | `encryption_keys_previous` | `[]` | comma-separated hex keys tried for decryption |

No other setting changes. The `db` CLI gains `db schema` (11.3) and `db
normalize` (2.3).

## 13. Documentation and design.md changes

- design.md: D42 column types and casting (decimal as Float with the
  BigDecimal condition, json as Hash, the datetime format change and `db
  normalize`, Date, `Time.iso8601` family); D43 the query API (`where`
  forms, `where.not`, `or`, Range, class delegations, `scope`, the small
  methods); D44 `pluck` / `pick` cells; D45 typed aggregates (why not
  `maximum(:x)`); D46 bulk writes; D47 declared associations, `has_many` as
  Relation, `dependent:`, `includes`; D48 validators and the generated
  validation `case`s; D49 encryption; D50 schema and migration additions,
  the table rebuild, and the Rails takeover. Section 1's programme paragraph
  marks phase 2 delivered and section 13 of this spec is appended after
  implementation (as phase 1's section 13).
- docs/guide/models.md (and the fr / ja / ru / zh translations with
  `source_sha256` updated by `script/check-guide-i18n --update-sha`):
  column types, casting, every new query method with its Rails spelling,
  associations, validations, `scope`, `encrypts`. docs/guide/migrations.md:
  the new helpers, `reversible`, `db schema`, the Rails takeover.
  docs/guide/configuration.md: the two variables. docs/deploy.md and
  deploy.en.md: the `db normalize` step for upgrades from 0.4.
- README's feature list; the "Not available" comments in model.rb and
  migration.rb shrink to what remains.
- spikes/NOTES.md: new rules from the spike (section 14), numbered after
  the current last rule.

## 14. Spinel constraints that shape the implementation, and the spike

The plan's first task compiles one small program with the pinned Spinel and
records each answer in spikes/NOTES.md:

1. `Date`: `Date.new`, `to_s`, `strftime`, `year` / `month` / `day`, `+` /
   `-`, `<=>`, `==`, inside a class that also uses `Time` (2.4).
2. Beginless and endless Range literals (`1..`, `..5`), `Range#begin` /
   `end` / `exclude_end?` on a `Range` held in a polymorphic Hash value (3.1).
3. `def not(hash)` on a class and `obj.where.not(x: 1)` call syntax (3.1).
4. Class methods added to `Time` from Ruby source (`def self.iso8601`), and
   whether a method literally named `strptime` is refused (2.6).
5. `OpenSSL::Cipher.new("aes-256-gcm")` round trip, `auth_tag` check on a
   flipped byte, inside a program that also requires `cybertrain` (10).
6. `RETURNING` and `sqlite3_limit(SQLITE_LIMIT_VARIABLE_NUMBER)` against the
   bundled SQLite (`sqlite3_libversion`) (6).
7. A method with one parameter typed `Hash | String` plus a splat
   (`where(cond, *binds)`), dispatching with `case cond when Hash … when
   String` (3.1).

**Results (2026-11-06, Spinel 2026.11.04.7026, programs kept in the plan's
task 1 and recorded in spikes/NOTES.md):**

1. `Date`: passes. `Date.new`, `to_s`, `strftime`, `year` / `month` / `day`,
   `+` / `-`, `<`, `==` all work beside `Time` in one class.
2. Ranges: open and closed **Integer** ranges work, including `begin` / `end`
   / `exclude_end?` on a Range read from a polymorphic Hash value. A Range
   of `Time` or `Date` raises `TypeError: no implicit conversion of Time
   into Integer` at construction (`t1..t2` and `Range.new(t1, t2)` alike);
   a Float or String Range reads back directly but is **not matched by
   `when Range`** once held in a Hash value or passed through a boxed
   parameter. Fallback taken: section 3.1's `where_between`; `inclusion:
   { in: }` takes Integer ranges only (9.1). Reported in
   docs/spinel-feedback.md as a new item.
3. `def not(hash)` and `rel.where.not(x: 1)`: pass.
4. Class methods added to `Time` (`iso8601`, `rfc2822`, and one literally
   named `strptime`): pass; the earlier refusal was of the missing method,
   not of the name. `Time.at(ms / 1000.0)` is exact.
5. `OpenSSL::Cipher.new("aes-256-gcm")` with `cybertrain` required: passes;
   a flipped ciphertext byte fails `final`. Keys and nonces must be raw
   bytes (`Crypto.random_token` answers hex, so `Encryptor` derives bytes
   from the hex configuration value with `[hex].pack("H*")`).
6. The bundled SQLite is **3.45.1**; `RETURNING` works for a multi-row
   `INSERT` and for `ON CONFLICT … DO UPDATE`; a 1000-bind statement runs;
   `ffi_func :sqlite3_limit, [:ptr, :int, :int], :int` compiles and answers
   `SQLITE_LIMIT_VARIABLE_NUMBER` = 250000 on this build (the chunking in
   section 6 still asks the library, since another build may differ).
7. A parameter typed `Hash | String` with a splat, dispatched by `case`:
   passes.

Each fallback named in this document is taken when its check fails; item 2
is the one taken, and sections 3.1 and 9.1 were amended accordingly.

Rules already known that bound the design: one return type per method name
(NOTES 10 / 34 / 41, sections 3 to 5); `attr_accessor` only on generated
models (43, section 7.2); no computed `send` (1, sections 3.4 and 9.2);
seeded polymorphic containers (9, 46, 71, sections 4 and 6); `when Time`
before `when Array` and a Range arm beside them (8); a nullable ivar set
through a cast that can answer nil (7, every new column type); JSON values
boxed (62 / 71, section 2.2); `self.class` only through generated per-model
methods (3 / 4, `unique_value_taken?`, `run_custom_validations`).

## 15. Out of scope for phase 2 (recorded so nothing is lost)

BigDecimal as a value type (N-1; condition in 2.1); ActiveSupport time
helpers `5.minutes`, `Time.current`, `beginning_of_*`, `in_time_zone` (N-2;
phase 5 with frozen time, after a spike on adding methods to Integer and
Time); several databases (D-9); keyset pagination helpers (Q-10, `where` with
a Range and `order` cover it); `select` (Q-7); `enum`, `normalizes`, dirty
tracking (`changed?`, `saved_change_to_*`), `update_column` singular (M-5;
`update_columns` is in); concerns (M-6; plain modules); statistics and
`matrix` (N-5); polymorphic associations, `has_many :through`, scoped
`has_many`, `inverse_of`; nested `includes`, `eager_load`, `joins`;
`deterministic:` encryption and Rails' encryption envelope; JSON arrays at a
json column's root; `validates_with`, `validates_each`, `confirmation`,
`acceptance`; `valid?(context)`; `create_join_table`; `change_column` in a
reversible `change`.

## 16. Compatibility changes for applications on 0.4

Listed once so an application is updated in one pass; each is also in the
guide's upgrade notes.

1. `has_many` returns a Relation, not an Array: add `.to_a` before Array-only
   methods (`map`, `select`, `[]`, `+`).
2. datetime storage format: run `./app db normalize` once after upgrading;
   until then mixed columns sort by format.
3. `as_json` / `to_json` write times as `2026-10-05T09:00:00.000Z` (was
   `…:00Z`): JSON snapshots change.
4. `t.date` attributes are `Date`, not `String`: `article.day.strftime` still
   works; string concatenation needs `to_s`.
5. A declared `belongs_to` without `optional: true` validates presence of
   the foreign key (undeclared ones are unchanged).
6. `where(x: a..b)` with Integer ends is now a range condition (it was a
   text equality that never matched); Time and Date bounds use
   `where_between`.
7. `Cast.iso8601` is the display format; code that used it to build SQL text
   switches to `Cast.sql_datetime`.

## 17. Acceptance

1. The spike's seven checks are recorded in spikes/NOTES.md and every
   fallback decision is reflected in this document before the feature work.
2. `spin test` passes with the new programs (`test/cast_types.rb`,
   `test/db_normalize.rb`, `test/relation_where.rb`, `test/pluck.rb`,
   `test/aggregates.rb`, `test/bulk_writes.rb`, `test/associations.rb`,
   `test/includes.rb`, `test/validators.rb`, `test/encryptor.rb`,
   `test/scopes.rb`, `test/migration_rebuild.rb`,
   `test/schema_dumper_rails.rb`, `test/time_ext.rb`; `test/gen_models.rb`
   grown for the scanned declarations) and the existing ones, snapshots
   reviewed; `script/gate` passes; the blog's tests pass.
3. examples/blog gains one end-to-end use of each: `has_many :comments,
   dependent: :destroy` and `validates :title, uniqueness: true` on
   `Article`; `Article.includes(:comments)` on the index page (the comment
   count stops being N+1); a date-range filter on the index
   (`where(created_at: from..to)`); a `scope :recent`. No decimal, json,
   encrypted or bulk-written column is added to the blog (nothing to store;
   the `test/` programs cover them, as phase 1 did for BLOB).
4. A manual check, recorded in the pull request: a SQLite file made with
   Rails 8.1 (`rails new`, one model with decimal, json, datetime and date
   columns, a partial index, a few rows) is taken over with `./app db
   schema`, `./app console` reads `Model.first`, and `Model.where(created_at:
   1.day.ago..)` (as a Time range) answers the right rows.
5. docs/design.md D42 to D50, the guides and their four translations, README
   and the deploy guides are updated as section 13 says.

## 18. Implementation notes (2026-11-07, after Tasks 1 to 17 landed)

What differed from the plan or from this document, and why; each is recorded
in the code and in docs/design.md D42 to D50 too.

- Spike (section 14): item 2 was the one fallback taken, as amended above
  (Integer Ranges only, `where_between`; NOTES rule 86, docs/spinel-feedback.md
  Q). Rule 87 records that class methods added to `Time` compile. Rule 88 is
  new, found while writing declared associations: a stored block called with
  a base-class receiver runs the base class's stub, not the override, so the
  generated counter-cache hooks have no stub on `Model`.
- Column types: a declared type whose upcased text starts with `DATETIME`
  (`datetime(6)`) is a datetime everywhere, through one
  `Connection.datetime_decl?`. A NOT NULL date reads through `Cast.date` but
  every write goes through `Cast.date_or_nil`, so invalid input stays nil, and
  every NOT NULL date column gets a generated presence validation (a defaulted
  one starts at its default), superseding the earlier "nil persists as
  1970-01-01". `round_scale` passes non-finite Floats through. `t.bigint` is
  dumped back as `t.bigint` (limit 8), not as `t.integer` (2.5).
- `db normalize` (2.3): rows are located by `_rowid_`, the canonical check is
  a `GLOB` with a `[0-9]` class per digit, `WITHOUT ROWID` is read from
  `PRAGMA table_list` (so SQLite 3.37.0 or newer, refused clearly below it),
  a table declaring `_rowid_` in any case (`PRAGMA table_xinfo`) is skipped,
  and the command exits 1 while a skipped table holds pending cells. Trailing
  text after a datetime (` UTC`) reads as nil and is counted as unreadable.
- Query API: a String `where` fragment is parenthesized, an Array bind in it
  and an unknown argument type raise; `or` wraps as `((a) OR (b))`;
  `exists?` under `distinct` probes `*`; `update_all` rounds decimals;
  `update_columns` assigns before its UPDATE (as Rails); `find_or_create_by`
  on a narrowed relation creates from the given Hash only (Rails also merges
  the relation's equality conditions), accepted for alpha and documented.
- `scope`: one line, nothing after the closing brace (a trailing comment is
  refused), no parentheses or commas in a default, the body parenthesized in
  the generated method, and reserved names (`ModelScan::RESERVED_SCOPE_NAMES`,
  `raise` and Object / Kernel names included) refused with a one-line
  message. There is no `test/scopes.rb` (17, item 2): scopes are covered in
  `test/gen_models.rb` and examples/blog.
- `pluck` / aggregates: the template interpreter's private `pick` was renamed
  `pick_indices` (rule 34); NULL and `""` share the group key `""`; a
  windowed distinct aggregate reads the first n distinct values; a relation
  with `having_sql` refuses the non-grouped readers, and a grouped reader
  under a limit or offset refuses `having_sql`.
- Bulk writes: an `update_only` name the rows do not supply is skipped; `ON
  CONFLICT DO NOTHING` consumes ids for skipped duplicates (as Rails); an
  unknown column raises before writing; an encrypted column is refused as a
  row key and in `returning:`, `unique_by:` and `update_only:`.
- Associations: every `belongs_to` caches and every `has_many` returns a
  Relation, foreign-key-derived ones included (compatibility change 1). A
  declared `belongs_to` adds `validates_foreign_key` (nil, blank or 0 is
  blank) rather than `presence` (7.2), since a NOT NULL integer key starts at
  0. `counter_cache:` is accepted on `belongs_to` only; the moved-child read
  happens in a `before_update` inside the save's transaction, the destroy
  decrement reads the key from the row, the parent's own save leaves the
  counter out of its UPDATE, and a parent destroyed with `dependent: :destroy`
  issues one harmless decrement per child. `has_one` answers the first child
  by id. The association planning and emission moved into
  generator/association_emitter.rb. `includes` orders preloaded children by
  id and does not set a preloaded child's parent.
- Validators: `validates(*args)` with a trailing options Hash (the plan's
  `*attrs, options = {}` is not valid Ruby); `unique_value_taken?` takes six
  arguments (`case_sensitive` reaches the query), queries `IS NULL` for nil,
  and `uniqueness` on an encrypted column is refused at generation; `on:`
  takes one Symbol; `if:` / `unless:` inside a rule's Hash, `:if =>` and
  `"if":` are refused; a name must be a `def` in the model file, a column or
  an association; `allow_blank:` now also applies to `presence` on the same
  line; messages have no singular form ("1 characters").
- Encryption (section 10, amended above): openssl stays opt-in.
  cybertrain/encryptor.rb is required by gen/app.rb when a model declares
  `encrypts` (which also sets `Config.encryption_required`) and by hand for
  `Crypto.encrypt`; config.rb keeps only the String checks, run at every
  boot. A malformed `_PREVIOUS` entry fails boot, the key is stripped,
  `decrypt("")` answers `""`, `where_like` and `where_between` refuse the
  column too, plaintext rows written before `encrypts` raise on read, and
  `to_json` includes the text (as Rails). The guide's re-encrypt step is an
  application command (`Main.command`) with raw SQL, not the plan's `DB.with`
  plus `update_columns` or a migration: loading a plaintext row through the
  model raises, and a migration cannot read rows into Ruby. The CLI flag is `cybertrain secret --hex`, without a length.
- Migrations (Tasks 15 and 16 went to one implementer and one review):
  `change_column_default` requires `to:`, and `from:` (`nil` included) makes
  it reversible; rolling back `change_column_null(..., true)` needs the
  default argument; only `execute` goes inside `reversible`'s blocks, each
  in written order; the live table is dumped before each rebuild; the
  RENAME runs inside `PRAGMA legacy_alter_table = ON` so views and triggers
  naming the table survive; expression defaults keep their parentheses; a
  foreign key violation raises `DB::Error` (there is no Migration error
  class). A rebuild refuses, by a token scan of the `CREATE TABLE` text
  (`MATCH` and `ON CONFLICT` clauses could pass it), CHECK, inline UNIQUE,
  COLLATE, generated columns, ON UPDATE, ON DELETE SET DEFAULT, DEFERRABLE, a
  foreign key to a non-id column, an untyped column, a primary key other than
  `id`, WITHOUT ROWID and STRICT; a plain `id INTEGER PRIMARY KEY` gains
  AUTOINCREMENT. `rename_table` keeps index names (Rails renames them).
  `PRAGMA foreign_key_check` covers the whole database, so a pre-existing
  violation elsewhere blocks a rebuilding version (as Rails).
- Expression indexes (11.1): the String column spec exists in the schema DSL
  (`db/schema.rb`, with `name:` required); the migration helper `add_index`
  takes an Array of columns only, so a migration creates one with `execute`,
  and the dump keeps it.
- Class delegations (section 3, R3): `DELEGATED` first lacked `where_sql`,
  `pluck_str` / `pluck_int` / `pluck_float`, `count_by`, `count_by_sql`,
  `sum_int`, `sum_float` and `increment`; the Task 18 review found it and
  they were added (test/gen_models_compiles.rb calls each through the class).
  Not delegated: `or`, `not`, `page`, `to_sql`, `to_a`, `each`, `size`,
  `empty?`.
- SQLite version: "the bundled SQLite" above means the library the spike
  ran against. CyberTrain links the system libsqlite3; `db normalize` checks
  for 3.37.0 and refuses below it, and the bulk writes' `RETURNING` (3.35.0)
  is not checked: an older library refuses the statement with its own error.
- Tables without `id` (11.3, item 5): the Task 18 review found that the
  dumper gave every table an implicit id and the generator a model. Now a
  table whose primary key is not an `id` column dumps as `create_table "x",
  id: false` with every column, `SqliteDDL` writes no id for it, and the
  generator makes no model of it (and no `has_many` pointing at it), printing
  `skipped x: no id column`.
- Takeover (11.3): step 1's path is `storage/<env>.sqlite3` (the default
  `database_path`), not `db/<env>.sqlite3`. `db schema` prints `wrote
  <root>/db/schema.rb from <path>`; `db status` lists a version without a
  file as `applied (no file)`.
- Documentation (section 13): there is no docs/guide/migrations.md; the
  migration helpers, `reversible`, `db schema` and the takeover are sections
  of docs/guide/models.md, so no new page needs four translations and
  navigation entries. The Encryptor's `require` is documented in the models
  and install guides. `test/boot_encryption.rb` was added (a child process
  boots with and without the key).
- Test counts (2026-11-07, Spinel 2026.11.04.7026): `script/test-shard 0 1`
  (the full `spin test`) passes 147 of 147 programs; `cd examples/blog &&
  spin test` passes its 2 programs, 30 tests and 157 assertions
  (`articles.rb` 18 / 96, `comments.rb` 12 / 61).
- Acceptance item 4 (17.4), the manual check against a SQLite file made by
  Rails 8.1, was not run here: this environment has no Ruby with Rails.
  `test/schema_dumper_rails.rb` stands in for it with the DDL Rails 8.1
  writes (`datetime(6)`, `decimal(18,8)`, `json`, `bigint`, a partial and an
  expression index, `ON DELETE CASCADE`, `ar_internal_metadata`,
  `schema_migrations` rows); the live check is left to the maintainer.
