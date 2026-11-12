# Models and the database

What a model does beyond the scaffold: migrations, column types, queries,
associations, validations, encrypted columns, paging, transactions, the rules
column names and `order` clauses follow under Spinel, and taking over a
database that Rails created.

## Migrations

A migration in `db/migrate/<version>_<name>.rb` is a `Cybertrain::Migration::Base`
subclass. Its `change` records schema operations (`create_table`,
`add_column`, `add_index`, `rename_column`, `add_reference`, `remove_column`,
`remove_index`, `drop_table`, and the ones under [Changing a
table](#changing-a-table)); `cybertrain db migrate` applies each pending
version in its own transaction and rewrites `db/schema.rb` from the database,
and `cybertrain db rollback [N]` runs the inverse of `change`. When `change`
holds an operation with no automatic inverse, write `down` (and `up`).

A schema change that needs a data step to be safe uses `execute(sql, binds =
[])`. It runs at its place in the migration, on the migrator's own
connection and in the same transaction as the version's schema operations,
so the column added before it exists when it runs, and a failure undoes the
whole version:

```ruby
class AddRetentionDaysToBackups < Cybertrain::Migration::Base
  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]   # existing rows keep "forever"
  end

  def down
    remove_column "backups", "retention_days"
  end
end
```

Without binds the SQL may be several `;`-separated statements; with binds
it is one statement with `?` placeholders. `execute` has no inverse: rolling
back a `change` that executes SQL, with no `down` of its own, stops with
`version N is irreversible: it executes SQL in change; write down` before
anything is reverted. A data statement never appears in `db/schema.rb`,
which is dumped from the database. Recording a migration runs nothing, so
the statement runs exactly once per `migrate` of its version.

### Indexes and foreign keys

`add_index` takes `where:` for a partial index; `t.references` takes
`on_delete:` and `index: false`, and `add_reference` takes `on_delete:` and
always adds the index:

```ruby
create_table "comments" do |t|
  t.references :article, on_delete: :cascade   # ON DELETE CASCADE
  t.references :author, null: true, on_delete: :nullify, index: false
  t.text "body"
  t.timestamps
end
add_index "comments", ["body"], where: "body IS NOT NULL"
```

`on_delete:` is `:cascade`, `:nullify` (the column must be nullable) or
`:restrict`; the default writes no `ON DELETE` clause (SQLite's `NO ACTION`).
[`dependent:` or `on_delete:`](#dependent-or-on_delete) says which to use.
An expression index (`LOWER(email)`) has no migration helper: create it with
`execute "CREATE UNIQUE INDEX index_users_on_lower_email ON users (LOWER(email))"`.
`db/schema.rb` dumps it back as `s.add_index "users", "LOWER(email)", unique:
true, name: "index_users_on_lower_email"`, and the dump keeps a partial
index's `where:` as well.

### Changing a table

```ruby
class TidyPosts < Cybertrain::Migration::Base
  def up
    rename_table :posts, :articles
    change_column :articles, :views, :bigint, null: false, default: "0"
    change_column_default :articles, :state, from: nil, to: "'draft'"
    change_column_null :articles, :title, false, "untitled"
    remove_reference :articles, :legacy_owner
    remove_foreign_key :articles, :authors
  end

  def down
    # write the reverse of each step
  end
end
```

- `rename_table` is `ALTER TABLE ... RENAME TO`, and the foreign keys that
  point at the table follow it. Its indexes keep their names (Rails renames
  them to the new table).
- The other five rebuild the table, as SQLite has no `ALTER COLUMN`: a new
  table is created from the changed definition, the rows are copied, the old
  table is dropped and the new one renamed, and its indexes, triggers and
  `AUTOINCREMENT` high-water mark are put back. Views and triggers on other
  tables that name it keep working.
- `change_column` declares the column afresh: options it is not given (a
  default, `null: false`) are dropped, as in Rails.
- `change_column_default` needs `to:` (SQL literal text, `nil` to drop the
  default); `from:` names the previous default and makes it reversible.
- `change_column_null`'s fourth argument is a value written into the NULL
  cells before `NOT NULL` is added; it never becomes the column's default.
- `remove_foreign_key :articles, :authors` drops the key and keeps the
  column and its index (`column:` names another column than `author_id`).

`rename_table`, and `change_column_default` with `from:`, reverse themselves
inside `change`; so does `change_column_null`, except that rolling back
`null: true` needs the fourth argument for the cells that became NULL since.
`change_column`, `remove_reference` and `remove_foreign_key` are irreversible
in `change`: write `up` and `down`.

<details><summary>What a rebuild refuses, and foreign keys during one — CHECK, COLLATE, generated columns and the rest</summary>

A rebuild declares the table from what `db/schema.rb` can say. Before it
touches a table it reads the table's `CREATE TABLE` text and refuses one with
anything the schema does not model (`rebuilding posts would drop a CHECK
constraint: rewrite the migration with execute`), and the version rolls back. That
covers a `CHECK` or inline `UNIQUE` constraint (a unique index is fine),
`COLLATE`, a generated column, `ON UPDATE`, `ON DELETE SET DEFAULT`,
`DEFERRABLE`, a foreign key to a column other than `id`, a column with no
type, a primary key other than `id`, and `WITHOUT ROWID` or `STRICT` tables.
The check is a scan of the SQL text for those words, not a parser, so read
the dumped schema of a hand-made table before rebuilding it. A plain
`id INTEGER PRIMARY KEY` comes back as `AUTOINCREMENT`, which keeps every
row and id. Exact type spellings are normalized (`datetime(6)` becomes
`DATETIME`).

A version that rebuilds runs with `PRAGMA foreign_keys` off (it cannot be
turned off inside a transaction, so the migrator does it around the version)
and runs `PRAGMA foreign_key_check` before committing: a violation rolls the
version back and names the rows. The check covers the whole database, so a
violation already present in another table also stops the version, as it
does in Rails.

</details>

### Data steps both ways: `reversible`

```ruby
class BackfillSlugs < Cybertrain::Migration::Base
  def change
    add_column "posts", "slug", :string
    reversible do |dir|
      dir.up { execute "UPDATE posts SET slug = lower(title)" }
      dir.down { execute "UPDATE posts SET slug = NULL" }
    end
  end
end
```

`dir.up`'s statements run on migrate and `dir.down`'s on rollback, each in
the order written. Only `execute` goes inside the blocks. Not available:
`create_join_table`, `change_table`, `rename_index`, `add_timestamps`.

`cybertrain db status` lists every version; one in `schema_migrations` with no
file under `db/migrate` (a database another tool migrated) is `applied (no
file)`, and the migrator neither runs nor rolls it back. `cybertrain db
schema` writes `db/schema.rb` from the database without migrating
([Taking over a database Rails created](#taking-over-a-database-rails-created)).

## Column types

| Schema DSL | SQL | Ruby attribute |
| --- | --- | --- |
| `t.string`, `t.text` | `VARCHAR(n)` / `VARCHAR`, `TEXT` | String |
| `t.integer`, `t.bigint`, `t.references` | `INTEGER`, `BIGINT` | Integer |
| `t.float` | `FLOAT` | Float |
| `t.decimal :price, precision: 18, scale: 8` | `DECIMAL(18,8)` | Float, rounded to the scale when stored, exact to 15 significant digits |
| `t.boolean` | `BOOLEAN` | true / false |
| `t.datetime` | `DATETIME` | Time (UTC, microseconds) |
| `t.date` | `DATE` | Date |
| `t.json :meta, default: "{}"` | `JSON` | Hash with String keys |
| `t.binary` | `BLOB` | String of bytes ([Binary columns](#binary-columns)) |

A nullable column's attribute may also be nil. `new`, `update` and
`write_attribute` cast what they are given (`"42"` into an integer column is
`42`, `"2026-10-05"` into a date column is a Date); the plain writer
`post.price = ...` does not. SQLite's INTEGER is 64-bit, so `t.bigint` is an
integer column under another name. `t.datetime :x, precision: 6` is accepted;
every datetime keeps microseconds.

### Decimals are Floats

Rails reads a `decimal` column as a BigDecimal; here it is a Float in a
`DECIMAL(p,s)` column, with this contract (`docs/design.md` D73):

- **Exact to 15 significant digits.** With `precision:` 15 or less, every
  value of `scale:` fractional digits inside the declared precision is stored
  and read back as itself. Past 15 digits it is the nearest Float:
  `decimal(18,8)` is exact up to 9,999,999.99999999, not to its declared ten
  integer digits.
- **Rounded to the scale where it is stored** (`save`, `update`,
  `update_columns`, `update_all`, the bulk writes), half away from zero on
  the decimal digits: 1.005 at scale 2 is 1.01, as Rails stores it, and the
  same under CRuby and Spinel.
- **Out of range is a validation error.** For a decimal column with a
  precision `spin run gen` writes a `numericality` validation, so `save`
  answers false for a value beyond the precision, for Infinity and for NaN
  instead of storing it.
- **Sums are Float sums.** Round a total at the edge with
  `Cybertrain::Cast.round_scale(total, 2)`, not `total.round(2)`.

Keep money in minor units in an integer column (`price_cents`): Integer
arithmetic and `sum_int` are exact. Read a form field with
`(Cybertrain::Cast.round_scale(params[:price], 2) * 100).round` and show it
with `number_to_currency(price_cents / 100.0)`. Upgrade note: a tie that the
compiled framework used to round down (1.005 stored as 1.0) is now stored
rounded up, for new writes only, and the generated validation refuses values
that were stored before; D73 has the steps for moving a decimal column to
minor units.

### JSON columns

A `json` column holds an object, read as a `Hash` (`{}` for a NOT NULL column
whose text is not a JSON object, nil for a nullable one) and written with
`JSON.generate`. Its values are boxed, as every parsed JSON value is under
Spinel, so read them through `Cybertrain::Cast`:

```ruby
event.meta = { "attempts" => 2, "tags" => ["a", "b"] }
event.save
Cybertrain::Cast.int(event.meta["attempts"])   # => 2
Cybertrain::Cast.array(event.meta["tags"])     # => ["a", "b"]
```

Assigned text that is not valid JSON becomes `{}`. An Array at the root is
not supported: store it in a `text` column and read it with `Cast.array`.
`where` on a json column raises `ArgumentError`, and `pluck` answers its
stored text.

### Datetimes and `db normalize`

A datetime is stored as Rails stores it in SQLite, `2026-10-05 09:00:00.000000`
(UTC, a space, six fraction digits), and reads with a `T` or a space, any
fraction, and `Z` or an offset. JSON (`as_json`, `to_json`) writes Rails'
display form, `2026-10-05T09:00:00.000Z`. In raw SQL, `Cybertrain::Cast.sql_datetime(time)`
gives the stored text and `Cast.iso8601(time)` the display text.

CyberTrain 0.4 stored `2026-10-05T09:00:00Z`, which sorts after every
Rails-format value whatever the date. Once after upgrading, rewrite the old
cells:

```console
$ cybertrain db normalize
normalized articles.created_at: 12 rows (0 unreadable left alone)
normalized articles.updated_at: 12 rows (0 unreadable left alone)
done
```

It rewrites every cell of every `DATETIME` column (`datetime(6)` included)
that is not already in the stored format, row by row in one transaction, and
is safe to run twice. A cell it cannot read as a time (trailing text such as
` UTC`) is left alone and counted. A `WITHOUT ROWID` table, or one with a
column named `_rowid_`, is skipped; when it still holds old cells the command
prints `skipped t.c: without rowid (N rows still need normalization)` (or
`declares _rowid_`) and exits 1, so update those rows by hand and run it
again. It needs SQLite 3.37.0 or newer: CyberTrain links the system's
libsqlite3 (`sqlite3 --version` shows it), and with an older one the command
stops with `db normalize failed: ...` before reading anything. In
production run `./<app> db normalize` between `migrate` and starting the new
binaries ([deploying the upgrade](../deploy.en.md#upgrading-the-framework)).

### Dates

A `date` column is a `Date` (`Date.new(2026, 10, 5)`), stored as
`2026-10-05`; `where(day: date)` binds it as that text. Assigned text must be
`YYYY-MM-DD`: anything else (or blank) reads back nil. A NOT NULL date column
gets a generated presence validation, so `save` returns false with "can't be
blank" instead of the database refusing the row; one with a default starts
with it. `Cybertrain::Cast.date_or_nil(params[:from])` reads a date parameter
the same way.

### Parsing times

`Time.iso8601(text)`, `Time.rfc2822(text)` and `Time.strptime(text, format)`
are there under their Ruby names, each raising `ArgumentError` on text it
cannot read. `strptime` takes `%Y %m %d %H %M %S %L %z %Z %b %B %a %A %j %s
%%` (`%Z` only `UTC`, `GMT` or `Z`). `Time.at(ms / 1000.0)` turns a
millisecond epoch into a Time.

## Conditions and finders

The query methods of the generated relation are class methods too (all but
`or`, `not`, `page` and `to_sql`, and the Array-like `to_a`, `each`, `size`,
`empty?`), so the Rails spelling works as written: `Article.where.not(body:
nil)`, `Article.find_each { }`, `Article.pluck(:id, :title)`,
`Article.pluck_int(:id)`.

| Rails | CyberTrain |
| --- | --- |
| `where(views: 1..10)`, `where(views: 10..)` | The same, for Integer ends only |
| `where(created_at: from..to)` | `where_between(:created_at, from, to)` (`exclude_end: true` for `...`; nil for an open end) |
| `where("views > ?", 10)` | The same |
| `where.not(state: "draft")`, `a.or(b)` | The same |
| `order(created_at: :desc)` | The same |
| `distinct`, `none`, `ids` | The same |
| `find_by!`, `find_or_create_by`, `find_or_initialize_by` | The same |
| `update_all`, `destroy_all`, `find_each(batch_size: 500)` | `update_all`, `destroy_all`, `find_each(batch: 500)` |
| `create!`, `record.update_columns(views: 0)` | The same |

- A Range in a `where` Hash takes Integer ends: under Spinel a Range of
  Times or Dates cannot be built, and a Float or String Range is not matched
  as one, so those bounds go through `where_between`, whose Time and Date
  bounds are compared as the stored text (which orders as the instant does).
- A String condition is wrapped in parentheses, so an `OR` in it stays inside.
  Its binds are scalars: `where("id IN (?)", ids)` raises; write
  `where(id: ids)`.
- `a.or(b)` is `((a) OR (b))`; the two must agree on order, limit, offset and
  `distinct`.
- `where` on a json or encrypted column raises `ArgumentError`.
- `distinct` makes the column readers return each value once and the
  aggregates read distinct inputs (`SUM(DISTINCT x)`); `count` and `to_a` are
  unchanged, since every row has its own id.
- `update_all(hash)` casts and rounds as `save` stores, except that `""`
  binds NULL in a numeric, boolean, date or json column (where `save` would
  store 0 / false / `{}`), leaves `updated_at` alone and runs no callback; `destroy_all` destroys each record, callbacks
  and `dependent:` included.
- `update_all_sql(sql, binds = [])` sets columns with an SQL `SET` list, for a
  value computed from the row (`User.where(id: id).update_all_sql("failed_attempts = failed_attempts + ?", [1])`);
  every expression reads the row as it was, `?` takes the binds in order,
  and, as `update_all`, it loads no model and runs no callback.
- `find_each` walks by id in batches and ignores the relation's order,
  limit and offset, as Rails does.
- `find_or_create_by` on a narrowed relation creates the record from the
  Hash it is given only; Rails also takes the relation's equality
  conditions. Pass every attribute the new record needs.
- `update_columns` assigns the values, then runs one UPDATE of those columns:
  no validation, no callback, `updated_at` untouched.

## Scopes

```ruby
# app/models/article.rb
class Article
  scope :recent, -> { order(created_at: :desc) }
  scope :since, ->(time) { where("created_at > ?", time) }
end

Article.recent.since(Time.now - 86_400).limit(5).to_a
```

The generator reads each `scope` line as text and copies the lambda's
parameters and body into a method of the model's relation (`def since(time) =
(where("created_at > ?", time))`) and a class method that delegates to it, so
scopes chain like any query. Nothing is evaluated at generation time: a body
that names something the relation lacks fails when Spinel compiles
`gen/models`, at the generated line.

A scope is one line at class level: a `->` lambda with plain or defaulted
positional parameters, nothing after its closing `}` (not even a comment),
and no parentheses or commas in a default value. A scope named like a column,
another scope, a query method (`where`, `count`, `first`) or an `Object`
method (`hash`, `then`, `raise`) stops the generator with the file, line and
reason.

## Querying beyond `where`

Past the conditions above, the counters, statistics and search boxes most
applications need come as typed methods (`docs/design.md` D22, D44, D45)
rather than a query builder; each takes SQL column names, checked and quoted
(anything else is an `ArgumentError`), and binds every value:

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...; returns rows written
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1 (by: n for another step)
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   (also pluck_str, pluck_float)
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # hour buckets
Stat.where(project_id: 1).sum_int(:calls)                 # also sum_float
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- Each is typed, because a Spinel method has one return type: `pluck_str` /
  `pluck_int` / `pluck_float` read one column only, `sum_int` / `sum_float`
  sum one, and `count_by` returns a `Hash{String => Integer}`.
- `upsert`'s `update` values and `count_by_sql`'s expression are SQL text, like
  `order_sql`: never build them from request data. An empty `update` is
  `DO NOTHING`. `upsert` and `increment` load no model and run no
  validation or callback, and fill in no timestamps; `upsert` casts each
  value as `save` stores it.
- `count_by` keys are Strings (through `Cast.str`), ascending; NULL and `""`
  share the key `""`. With a `limit` / `offset`, `count_by`, `sum_*` and
  `increment` work on that window, as `count` and `delete_all` (through a
  subselect) do.
- `where_like` escapes `\`, `%` and `_` in the text for you, and is a
  substring match (case-insensitive for ASCII, as SQLite's LIKE is). A prefix search writes its own pattern:
  `Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`.
- For hand-written SQL, `Cybertrain::Cast.binds(a, b, c)` builds the bind
  Array `execute` takes (a Time in the stored datetime format, a Date as
  `YYYY-MM-DD`, booleans as 1/0):
  `Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`.
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` narrow a parsed JSON value to
  a Hash / Array, or a fresh empty one when it is not one (a Time is checked
  first, spikes/NOTES.md rule 8). They return a typed shallow copy, not `v`
  itself; `Cast.empty_hash` / `Cast.empty_array` are the seeded empty
  containers.

### Several columns: `pluck` and `pick`

```ruby
Reading.order(:id).pluck(:observed_at, :value)   # => [[2026-10-01 09:00:00 UTC, 1.0], ...]
Reading.order(:id).pick(:id, :value)             # => [1, 1.0], or nil
```

`pluck` takes two or more columns and answers one Array per row, each cell
cast by its column's type: an Integer, a Float (float and decimal), `true` /
`false`, a UTC Time, a Date, a String (string, text, json and binary columns
answer the stored text or bytes; an encrypted column its payload), or nil.
One column raises `ArgumentError` pointing at `pluck_str` / `pluck_int` /
`pluck_float` / `ids`: Rails answers a flat Array for one column and nested
Arrays for several, and one method cannot return both. `pick` is the first
row (`LIMIT 1`) or nil. Only column names are taken; an expression goes
through `DB.with`.

### Aggregates

| Rails | CyberTrain |
| --- | --- |
| `minimum(:views)`, `maximum(:views)` | `minimum_int`, `maximum_int` (`Integer` or nil) |
| `maximum(:price)` on a float or decimal | `minimum_float`, `maximum_float` |
| `maximum(:created_at)` | `minimum_time`, `maximum_time` (a UTC Time or nil) |
| `average(:value)` | `average(:value)` (a Float or nil) |
| `group(:kind).sum(:value)` | `sum_float_by(:kind, :value)` (also `sum_int_by`) |
| `group(:kind).maximum(:created_at)` | `maximum_time_by(:kind, :created_at)`, and `_by` for each reader above |
| `sum("price * quantity")` | `sum_float_sql("price * quantity")`, also `minimum_float_sql`, `maximum_float_sql`, `average_sql` |
| `group(:kind).having("SUM(value) > ?", 2)` | `having_sql("SUM(value) > ?", [2.0]).sum_float_by(:kind, :value)` |

- The names carry the type for the same reason as `pluck_int`: Rails'
  `maximum` answers an Integer for one column and a Time for another.
- The `_by` readers answer a `Hash{String => T}` keyed by the group column's
  value as text, ascending, as `count_by` does; NULL and `""` share the key
  `""`.
- `having_sql` applies to the grouped readers; any other reader of a
  relation with one raises, as does a grouped reader with a limit or offset.
- The `_sql` expressions and `having_sql` are trusted SQL, like `order_sql`.
- Under `distinct` the aggregates read distinct inputs (`AVG(DISTINCT x)`);
  with a limit as well, the window is the first n distinct values.
- An aggregate over an expression *and* a group, or over two tables, is
  written with `DB.with`.

## Bulk writes

```ruby
Article.insert_all([{ title: "One", body: "..." }, { title: "Two", body: "..." }]).size  # => 2
Article.insert_all!(rows)                                 # a duplicate raises
Article.upsert_all([{ id: 1, title: "Renamed" }])         # body keeps its value
Article.upsert_all(rows, unique_by: [:slug], update_only: [:title], returning: [:id, :title])
```

`insert_all` writes many rows in multi-row `INSERT` statements with
`ON CONFLICT DO NOTHING`, skipping a row that collides with an existing one;
`insert_all!` raises instead; `upsert_all` updates the colliding row with
`ON CONFLICT (unique_by) DO UPDATE`. The result is the `RETURNING` rows (by
default `[{"id" => 3}, ...]`), cast by type, so `.size` is the number written.

- Every row has the same keys, or `ArgumentError` before anything is
  written; an unknown column, or rows with no keys (`[{}]`), raise the same
  way. Columns no row names take
  the table's DEFAULT.
- Values take the casts `save` gives them (a Time in the stored format, a Hash
  as JSON, a decimal rounded to its scale, a Date as text).
- `upsert_all` updates the columns the rows supply, except `id`, the
  `unique_by` columns and `created_at`; `update_only:` narrows that list, and
  a name in it that the rows do not supply is skipped.
- `returning:`, `unique_by:` and `update_only:` take an Array or one name
  (`returning: :id`); `false` is none; any other value raises
  `ArgumentError`.
- `created_at` / `updated_at` get one `now` for the whole call when the table
  has them and the rows do not, unless `record_timestamps: false`.
- The statements are cut to SQLite's bind limit and run in one transaction
  (joining one already open), so a failure leaves nothing of the call;
  inside a transaction you opened, your rollback decides.
- No validation, callback or encryption runs: an encrypted column in a row
  raises `ArgumentError`. As in Rails, a skipped duplicate still uses up an
  id.
- `RETURNING` needs SQLite 3.35.0 or newer (the system library CyberTrain
  links); an older one refuses the statement with its own syntax error
  (`Cybertrain::DB::Error`).

## Associations

A foreign key gives both sides an association without a line of code
(`t.references :article` gives `Comment#article` and `Article#comments`). The
model file can declare them too, to rename one or add options:

```ruby
# app/models/article.rb
class Article
  has_many :comments, dependent: :destroy
  has_one :cover, class_name: "Image", foreign_key: :article_id
end

# app/models/comment.rb
class Comment
  belongs_to :article
  belongs_to :author, class_name: "User", optional: true, counter_cache: true
end
```

- `has_many` returns the children's relation, so it chains:
  `@article.comments.where(approved: true).count`,
  `@article.comments.find(params[:id])`. Add `.to_a` for an Array; templates
  iterate it as one.
- `has_one` reads one child (the first by id when there are several), nil
  when there is none; it replaces the `has_many` the foreign key would give.
- `belongs_to` reads the parent and keeps it until the foreign key changes
  or `reload`.
- A declared `belongs_to` without `optional: true` makes the record invalid
  while its key is nil, blank or 0 ("can't be blank" on `article_id`, the
  generated `validates_foreign_key :article_id`), so `save` returns false
  before the database refuses the row. Associations that come from a
  foreign key alone add no validation.
- Options are literals: `class_name:` (a String or Symbol), `foreign_key:`,
  `dependent:` (`has_many` and `has_one`), `optional:` and `counter_cache:`
  (`belongs_to`). Each macro is alone on its line, at class level, with no
  trailing comment; a model, column or option that does not exist stops the
  generator with the file and line.
- Not available: `has_many :through`, polymorphic associations, a scope
  lambda on `has_many` (chain on the relation it returns), `inverse_of`,
  `dependent: :restrict_with_error`.

### `dependent:` or `on_delete:`

`dependent:` runs inside `destroy`, before the parent's DELETE and in the
same transaction: `:destroy` loads each child and destroys it (its callbacks
and its own `dependent:` run), `:delete_all` runs one DELETE, `:nullify` one
UPDATE setting the key to NULL. `on_delete:` on the foreign key
([Indexes and foreign keys](#indexes-and-foreign-keys)) has SQLite do it,
whoever deletes the row. Use `dependent: :destroy` when the children have
callbacks, counters or children of their own; use `on_delete: :cascade` for
speed, and when other programs write to the database. Without either, the
foreign key refuses to delete a parent that still has children.

### Counter caches

`belongs_to :post, counter_cache: true` keeps `posts.comments_count` (or
`<has_many name>_count`) in step: +1 after a child is created, -1 after one
is destroyed, and both sides when a child moves to another parent, each
change in the child's own transaction. The column must exist (an integer
with `default: "0"`). The parent's own `save` leaves it out of its UPDATE,
since its copy may be stale. A parent destroyed with `dependent: :destroy`
decrements itself once per child before it goes, which is harmless.

### Preloading with `includes`

```ruby
@articles = Article.recent.includes(:comments).to_a   # two queries
```

```erb
<% @articles.each do |article| %>
  <%= article.title %> (<%= article.comments.size %>)
<% end %>
```

`includes(*names)` (and `preload`, the same) runs one more query per
association when the records load (`Comment.where(article_id: ids)` for a
`has_many` or `has_one`, the parents by id for a `belongs_to`), so a loop
over `article.comments` or `comment.article` runs no query of its own. A
record with no children gets an empty list and a missing parent is nil, with
no further query. On a preloaded `has_many`, `to_a`, `each`, `first`, `last`,
`size` and `empty?` answer from memory (the children in id order); `count`
and `exists?` still query, and a chain method (`where`, `order`, ...) drops
the preload and queries as usual. One level only (`includes(comments:
:author)` is not there), and a preloaded child does not have its parent set
(`comment.article` reads it). `eager_load` and `joins` are not available.

## Validations

```ruby
class Article
  validates :title, presence: true, length: { minimum: 3, maximum: 120 }, uniqueness: true
  validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
  validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
  validates :views, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create
  validates :summary, presence: true, if: :published?

  def published? = state == "published"
end
```

The messages are Rails' defaults, from the bundled dictionary in the
request's locale: "can't be blank", "is too short (minimum is 3
characters)", "is the wrong length (should be 5 characters)", "is not
included in the list", "is reserved", "is invalid", "is not a number",
"must be an integer", "must be greater than or equal to 0", "has already
been taken" in English, "を入力してください" in Japanese. A limit of 1 reads
"1 character". `message:` replaces one, on the line or inside a rule's
Hash; `config/locales/` can replace them for every model or for one
([Models and validation messages](i18n.md#models-and-validation-messages)).
`errors.full_messages` names each attribute by
`Post.human_attribute_name(:title)` ("Title"; `author_id` is "Author"),
and writes a message on `:base` alone.

- `length` takes `minimum`, `maximum`, `is` and `in` (an Integer Range).
- `inclusion` and `exclusion` take an Array, or a Range of Integers (Spinel
  builds no other Range); `1...5` takes 4.5 on a float column, as in Rails.
- `numericality` parses a String first (`"12"` passes); a Float fails
  `only_integer`, as in Rails.
- `uniqueness` asks the database for another row with the value
  (`LOWER(col) = LOWER(?)` with `case_sensitive: false`, `IS NULL` for nil),
  scoped by `scope:`. It cannot be used on an encrypted column.
- `allow_nil:` and `allow_blank:` skip a nil or blank value for every rule on
  their line, `presence` included; `on: :create` or `on: :update` (one Symbol)
  runs the line for a new or a saved record only.
- An unknown option or a value of the wrong kind raises `ArgumentError` when
  the model loads.

### Custom validations and conditions

```ruby
class Booking
  validate :ends_after_start, on: :update, unless: :imported?

  def ends_after_start
    errors.add(:ends_on, "must be after the start") if ends_on < starts_on
  end

  def imported? = source == "import"
end
```

`validate :method` lines run after the `validates` rules, in order. `if:` and
`unless:` (on both) take a Symbol naming a method of the model, a column or
an association; the generator writes the table that calls it, since Spinel
has no `send`. A lambda, `:if => :x` and `"if": :x` stop the generator with a
message saying to name a method, and so does a `validate` name the model
file does not define. `validates_with`, `validates_each`, `confirmation`,
`acceptance` and `valid?(context)` are not available.

## Encrypted columns

```ruby
# app/models/account.rb
class Account
  encrypts :api_key
end
```

`encrypts` names string or text columns (text is the better choice: the
stored payload is longer than the text). The generated model encrypts the
value when it writes the row and decrypts it when it reads one, so
`account.api_key` is the text and the table holds `1:` followed by Base64 of
a random nonce, the AES-256-GCM ciphertext and its tag. Two saves of one
value store different payloads, so the column cannot be searched:

- `where`, `where_like`, `where_between`, `update_all`, `increment`,
  `upsert`, `uniqueness` and the bulk writes refuse it (`ArgumentError`);
  `pluck` answers the payload.
- `to_json` and `as_json` include the decrypted text, as in Rails; leave the
  column out of what a page renders.
- An empty stored value reads as `""`, so a NOT NULL column added with
  `default: "''"` stays readable before its rows are saved again.
- Not available: `deterministic: true`, and reading the payloads of Rails'
  `ActiveRecord::Encryption` (its key derivation and format differ).

### Keys and rotation

A model with `encrypts` makes the application require openssl and makes boot
fail unless `CYBERTRAIN_ENCRYPTION_KEY` holds 64 hex characters (make one
with `cybertrain secret --hex`; [the variables](configuration.md#configuration-and-environment-variables)).
The key is not derived from `CYBERTRAIN_SECRET_KEY_BASE`, so rotating the
session secret leaves the data readable; lose the encryption key and the
data is gone. To rotate it, put the new key in `CYBERTRAIN_ENCRYPTION_KEY` and
the old one in `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` (comma-separated; tried
for reading only), then write every record again:

```ruby
Account.find_each { |account| account.update_columns(api_key: account.api_key) }
```

Code that calls `Cybertrain::Crypto.encrypt(text)` / `Crypto.decrypt(payload)`
itself, in an application with no `encrypts`, adds
`require "cybertrain/encryptor"` to `bin/<app>.rb` and sets the key.

### Encrypting a column that already holds text

Rows written before `encrypts` was added hold plain text, and reading one
raises `Cybertrain::Encryptor::Error`. Encrypt them once with SQL, from an
application command (`./<app> encrypt_api_keys`):

```ruby
# bin/<app>.rb
Cybertrain::Main.command("encrypt_api_keys", "encrypt accounts.api_key written before encrypts") do |_argv|
  Cybertrain::DB.transaction do |c|
    c.execute("SELECT id, api_key FROM accounts WHERE api_key IS NOT NULL AND api_key NOT LIKE '1:%'").each do |row|
      payload = Cybertrain::Crypto.encrypt(Cybertrain::Cast.str(row["api_key"]))
      c.execute("UPDATE accounts SET api_key = ? WHERE id = ?", [payload, Cybertrain::Cast.int(row["id"])])
    end
  end
  0
end
```

The `NOT LIKE '1:%'` keeps a second run from encrypting a payload again;
drop it if plain values can start with `1:`. Values that Rails encrypted are
first decrypted in the Rails application, then encrypted here the same way.

## Pagination

A list page reads the page number from `?page=N`, windows the relation, and
renders the links:

```ruby
# app/controllers/articles_controller.rb
def index
  @articles = Article.all.order("created_at DESC")
  @page = @articles.page(params.page_number, per: 20)
end
```

```erb
<%# app/views/articles/index.html.erb %>
<% @articles.each do |article| %>
  <p><%= link_to article.title, article %></p>
<% end %>
<%= paginate @page, articles_path %>
```

`params.page_number` is the 1-based `page` parameter, 1 when it is absent or
not a number, clamped to `1..max_page` (`config.max_page`, 10000 by default,
`CYBERTRAIN_MAX_PAGE`); it never hands unbounded text to `String#to_i`, which
raises `RangeError` past 2**63-1 under Spinel. `params.int(:per, default: 20,
min: 1, max: 100)` is the same bounded read for any key (an optional `-` and
at most 18 digits, else the default; clamped to `min..max`).

`relation.page(n, per: 50)` sets `LIMIT per OFFSET (n - 1) * per` on the
relation (replacing an earlier `limit`/`offset`, so call it last), clamps `n`
the same way, so the offset never passes `(max_page - 1) * per`, and returns a
`Cybertrain::Page`: `number`, `per`, `row_offset`, `next?` (asked with one
`SELECT 1 ... LIMIT per + 1` over the window, no `COUNT(*)`), `prev?`,
`next_number`, `prev_number`. The rows stay on the relation, so
`@articles.each` yields typed `Article`s; `per` outside 1..1000 is an
`ArgumentError`.

`paginate @page, path` renders `<nav class="pager">` with a
"Newer" link (`rel="prev"`), "Page N" and an "Older" link (`rel="next"`),
each left out when there is no such page; the links keep the current query
string with `page` replaced (page 1 drops it), re-encoded and escaped, so a
search or filter survives paging, and a path with its own query string
(`"/search?q=x"`) uses that one instead.

Offset pagination only: keyset
pagination (`after: id`) for very large tables is not built yet. The scaffold's
index view lists every record; add the three lines above to page it.

## Transactions

`Cybertrain::DB.transaction { |c| ... }` (or `Article.transaction`, the same
thing under the Rails name) checks a connection out, runs `BEGIN`, yields the
connection, `COMMIT`s when the block returns and rolls back and re-raises
when it raises. `immediate: true` runs `BEGIN IMMEDIATE`, which takes
SQLite's write lock at the start: use it for a transaction that reads and
then writes, so a concurrent writer makes it wait at `BEGIN` rather than fail
with "database is locked" at its first write. While the block runs,
everything on that thread that goes through the pool (`save`, `update`,
`destroy`, Relation queries, `DB.with`) uses the transaction's connection, so
it is part of the transaction:

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

Where it differs from Rails' `transaction`, and what to avoid:

- It returns nil rather than the block's value.
- It is left by raising, and the exception is re-raised after the rollback
  (Rails leaves one with `raise ActiveRecord::Rollback`).
- A `DB.transaction` nested in the block joins the outer one: only the
  outermost commits, a raise anywhere rolls everything back, and there are
  no savepoints (no `requires_new: true`).
- `c.transaction { }` cannot be called on the yielded `c` under Spinel: nest
  `DB.transaction`, or use the block-free form below.
- A `DB.transaction` called inside a `DB.with` block (which is not a
  transaction) checks out a second connection: on a one-connection pool
  (`:memory:` included) it then waits forever. Open the transaction first and
  do the work inside it.
- Don't rescue a database error inside the block and carry on. After
  "database or disk is full", an I/O error or a lock timeout, SQLite may roll
  the whole transaction back by itself. Every later statement in the block
  then raises `Cybertrain::DB::Error` ("the enclosing transaction is no longer
  open") instead of committing on its own, and the transaction raises when the
  block ends. Let the error leave the block, and retry the whole transaction
  if you need to. A transaction opened with `c.exec_script("BEGIN")` is
  treated the same way until `COMMIT`, `END` or `ROLLBACK` ends it; a
  `ROLLBACK` then succeeds without doing anything, because SQLite has
  already rolled the transaction back.

Code that must keep its `rescue` in a plain method uses the block-free form,
`c.begin!(immediate: true)` ... `c.commit!`, with `c.rollback!` in the rescue.

## Column names

A column name must be an ASCII identifier (`[A-Za-z_][A-Za-z0-9_]*`), where
Rails takes any. A schema with a non-ASCII column name (`名前`, `prénom`)
generated under CRuby before PR #10, and `spin run gen` refuses it now, so
rename the column when upgrading (a name like `first-name` was never a method
name).

A column named like a method the generated class or the framework calls on a
record (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`,
...) or like a Ruby keyword (`end`, `class`, `begin`) generates under
`<column>_column` (`hash_column`: reader, writer and ivar), with a note in the
generated file. Its two names are used like this:

- Its SQL name keeps working in `read_attribute`, params and
  `attributes["hash"]`.
- A template reaches it under either name (`post.hash`, `post.hash_column`),
  except `errors` and `to_param`, which a template resolves as the model
  methods: use `post.errors_column` there.
- The query API (`where`, `order`, `find_by`) always takes the SQL column
  name (`Post.where(hash: 1)`); the Ruby name is the reader/writer and the
  template name only.

A column named like another Object method (`display`, `tap`, `methods`)
generates under its own name with a note. `cybertrain generate scaffold`
refuses keywords and reserved names (it would have to call a renamed reader)
and accepts a shadowing name with a note, like the generator.

An association whose plain name a column, another association or a `Model`
method already owns (Rails lets one shadow `errors`) is emitted under a
fallback name, with a comment in the generated file:
`<table>_as_<column stem>` for a `has_many` (`comments_as_article`),
`<stem>_as_<column>` for a `belongs_to` (`author_as_author_id`).

## Binary columns

`t.binary` makes a `BLOB` column, for bytes that are not text: a thumbnail,
a compressed snapshot, a key. The attribute is a String holding exactly the
stored bytes, NUL bytes and bytes above 127 included, or `nil` for a `NULL`
(the column is nullable unless declared `null: false`, so a photo saved
before the column was added has no thumbnail: check for `nil` before
`bytesize`):

```ruby
# db/migrate/20261105090000_add_thumbnail_to_photos.rb
class AddThumbnailToPhotos < Cybertrain::Migration::Base
  def change
    add_column "photos", "thumbnail", :binary
  end
end
```

```ruby
photo.thumbnail = File.binread("thumb.webp")
photo.save
Photo.find(photo.id).thumbnail.bytesize   # the same bytes back
```

- The generated model binds a binary column as a BLOB on save, and
  `Photo.where(thumbnail: bytes)` binds the bytes as a BLOB too (a TEXT bind
  never equals a stored BLOB); every other
  String still binds as TEXT, which stops at a NUL byte. In raw SQL, wrap the
  bytes in `Cybertrain::DB::Blob.new(bytes)` to bind them as a BLOB
  (`c.execute("INSERT INTO photos (thumbnail) VALUES (?)", [Cybertrain::DB::Blob.new(bytes)])`).
- A BLOB cell read with raw SQL is a String of its bytes;
  `Cybertrain::Cast.binary(value)` narrows it (`""` for `NULL`).
- `db/schema.rb` dumps the column back as `t.binary`, and the console prints
  a binary value as `<N bytes>`.
- Keep large files out of the database: an upload ([Add a file
  upload](tutorial.md#attachments)) is a file under `storage/uploads/`, while
  a BLOB is read into memory whole with its row and makes every backup and
  the WAL larger.

## Ordering

Where Rails' `order` takes any SQL (`order("lower(title)")`,
`order("posts.title")`, `order(params[:sort])`), `order` here takes only
`column [ASC|DESC]` lists, each column quoted, and raises `ArgumentError` on
anything else: a 500, since the string is the developer's.

Request data must go through an allowlist first, because a well-formed term
can still name a missing column (a 500 from SQLite) or a column the client
must not sort by:

```ruby
SORTS = { "title" => "title", "newest" => "created_at DESC" }
Post.order(SORTS.fetch(params[:sort].to_s, "id"))
```

Raw ORDER BY text goes through `order_sql` (`Post.order_sql("lower(title)")`,
also on a relation), which must never see request data.

## Taking over a database Rails created

A SQLite file that a Rails 8 application created can be read as it is:

1. Copy it to the application's database path, `storage/development.sqlite3`
   by default (`storage/<env>.sqlite3`, or wherever `CYBERTRAIN_DATABASE`
   points).
2. Run `cybertrain db schema` (`./<app> db schema` with a built binary). It
   writes `db/schema.rb` from the database, with the dumper `db migrate`
   uses, prints `wrote .../db/schema.rb from <path>`, and does nothing else.
   `cybertrain db migrate` then finds nothing to apply and generates the
   models.
3. Do not copy Rails' `db/migrate/*.rb`: new migrations start from here. The
   Rails versions already in `schema_migrations` (the same table in both)
   have no file here, so the migrator neither runs nor rolls them back, and
   `db status` lists them as `applied (no file)`.
4. What needs no conversion: datetimes (Rails' format is the stored one),
   booleans (`1` / `0`, and older `t` / `f`), decimals (Rails writes REAL
   values; they read as Floats), json (TEXT, read as a Hash), and the type
   names Rails writes (`datetime(6)`, `decimal(18,8)`, `varchar`, `bigint`,
   `json`). Partial and expression indexes and `ON DELETE` actions are dumped
   too.
5. Limits: a table whose primary key is not an `id` column (a join table) is
   dumped as `create_table "articles_tags", id: false` and gets no model
   (`spin run gen` prints `skipped articles_tags: no id column`); reach it
   with `DB.with`. An `id` primary key that is not an integer (Rails'
   `id: :uuid` or `id: :string`) is dumped the same way, its `id` kept as a
   plain column without the PRIMARY KEY. `ar_internal_metadata` is left
   alone; a table whose `CREATE TABLE` holds what the schema does not model
   cannot be changed with the rebuilding helpers ([Changing a
   table](#changing-a-table)); columns Rails encrypted are re-encrypted
   ([Encrypting a column that already holds text](#encrypting-a-column-that-already-holds-text)).

Then write `app/models/*.rb` with the validations, associations and scopes
the Rails models had, in the shapes this page shows.

## Upgrading from 0.4

Each change below is a one-pass edit to an application written for
CyberTrain 0.4:

1. A `has_many` reader returns a relation, not an Array: add `.to_a` before
   an Array-only method (`map`, `select`, `[]`, `+`). Templates are
   unchanged.
2. Datetimes are stored in Rails' format: run `db normalize` once after
   upgrading ([Datetimes and `db normalize`](#datetimes-and-db-normalize));
   until then a column mixing the two formats sorts by format.
3. `as_json` and `to_json` write times as `2026-10-05T09:00:00.000Z` (it was
   `2026-10-05T09:00:00Z`): JSON snapshots in tests change.
4. A `t.date` attribute is a `Date`, not a String: `strftime` still works,
   concatenation needs `to_s`. A NOT NULL date column now validates presence.
5. A declared `belongs_to` without `optional: true` validates its foreign
   key; undeclared ones are unchanged.
6. `where(x: a..b)` with Integer ends is a range condition (it was an
   equality with the Range's text, which never matched); Time and Date
   bounds use `where_between`.
7. `Cybertrain::Cast.iso8601` is the display format: code that built SQL
   text with it switches to `Cast.sql_datetime`, and `Cast.binds` binds a
   Time in the stored format.
8. `allow_blank: true` on a `validates` line also lets `presence` on that
   line pass a blank value, as in Rails (it applied to `length` only).
9. A column named like a method every model now has (`update_columns`,
   `destroy_dependents`, `run_custom_validations`, ...) is generated as
   `<column>_column` ([Column names](#column-names)).
10. A `belongs_to` reader keeps the parent it read until the foreign key
    changes (it read it again on every call): call `reload` to see a change
    another process made.
