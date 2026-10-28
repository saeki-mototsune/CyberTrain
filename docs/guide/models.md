# Models and the database

## Migrations

A migration in `db/migrate/<version>_<name>.rb` is a `Cybertrain::Migration::Base`
subclass. Its `change` records schema operations (`create_table`,
`add_column`, `add_index`, `rename_column`, `add_reference`, `remove_column`,
`remove_index`, `drop_table`); `cybertrain db migrate` applies each pending
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

## Querying beyond `where`

The generated relations cover `where` / `where_sql` / `order` / `limit` /
`offset` / `count` / `exists?` / `delete_all`. For the counters, statistics
and search boxes most applications also need, there are typed additions
(issue #74, `docs/design.md` D22) rather than a query builder; each takes
SQL column names, checked and quoted (anything else is an `ArgumentError`),
and binds every value:

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...; returns rows written
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   (also pluck_str, pluck_float)
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # hour buckets
Stat.where(project_id: 1).sum_int(:calls)                 # also sum_float
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- `upsert`'s `update` values and `count_by_sql`'s expression are SQL text, like
  `order_sql`: never build them from request data. An empty `update` is
  `DO NOTHING`. `upsert` and `increment` load no model and run no
  validation or callback, and fill in no timestamps.
- `count_by` keys are Strings (through `Cast.str`), ascending; NULL and `""`
  share the key `""`. With a `limit` / `offset`, `count_by`, `sum_*` and
  `increment` work on that window, as `count` and `delete_all` do.
- `where_like` is a substring match (case-insensitive for ASCII, as SQLite's
  LIKE is). A prefix search writes its own pattern:
  `Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`.
- For hand-written SQL, `Cybertrain::Cast.binds(a, b, c)` builds the bind
  Array `execute` takes (a Time as UTC ISO 8601 text, booleans as 1/0):
  `Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`.
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` narrow a parsed JSON value to
  a Hash / Array, or a fresh empty one when it is not one (a Time is checked
  first, spikes/NOTES.md rule 8). They return a typed shallow copy, not `v`
  itself; `Cast.empty_hash` / `Cast.empty_array` are the seeded empty
  containers.

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
`ArgumentError`. `paginate @page, path` renders `<nav class="pager">` with a
"Newer" link (`rel="prev"`), "Page N" and an "Older" link (`rel="next"`),
each left out when there is no such page; the links keep the current query
string with `page` replaced (page 1 drops it), re-encoded and escaped, so a
search or filter survives paging, and a path with its own query string
(`"/search?q=x"`) uses that one instead. Offset pagination only: keyset
pagination (`after: id`) for very large tables is not built yet. The scaffold's
index view lists every record; add the three lines above to page it.
