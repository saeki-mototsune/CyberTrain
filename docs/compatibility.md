# Same names, different meanings: the compatibility contract

CyberTrain uses Rails' vocabulary and ERB's syntax, and it is not Rails:
the framework compiles ahead of time under Spinel, and its templates are a
language of their own. For someone porting an application, the dangerous
differences are not the missing features (those fail loudly) but the names
that exist on both sides and mean something else. This page is the list of
those, each with where it is explained and the test that pins it, the
contract of the template language, and the rule for changing any of it.

It adds no description of its own where one exists: the guides explain
([How it works](guide/how-it-works.md#differences-from-rails) has the
feature-by-feature table, [the template language
reference](guide/template-language.md#differences-from-rails-erb) the
template one), [docs/design.md](design.md) says why. This page says which
of those lines are contracts and how each is held.

## APIs whose meaning differs from Rails

"Pinned by" is the compiled test that fails if the behaviour changes.

| Name | In Rails | Here | Explained in | Pinned by |
| --- | --- | --- | --- | --- |
| `Model.transaction`, `DB.transaction` | returns the block's value; `raise ActiveRecord::Rollback` leaves quietly; `requires_new:` makes a savepoint | yields the connection and returns nil; leave it by raising (the exception propagates after the rollback); a nested call joins the outer transaction, with no savepoints; do not `break` or `return` out of the block | models guide, "Transactions"; D20 | test/db_transaction_api.rb, test/db_transaction.rb, test/db_rolled_back_transaction.rb |
| `DB.with` inside `DB.transaction` | n/a | uses the transaction's connection on the same thread, so a `save`, a `Job.enqueue`, a `Stream.broadcast` and a `Cache.write` in the block commit or roll back with it | D20, D74 | test/db_transaction_api.rb, test/jobs.rb |
| Relation chaining (`where`, `order`, `limit`, `includes`, ...) | every call returns a new relation; the receiver is unchanged | every call changes the receiver and returns it. Branch from a shared base with `base.dup.where(...)`, which copies the whole chain state | D43, D72 | test/relation_dup.rb, test/relation_where.rb |
| `t.decimal` columns | BigDecimal, exact | Float, rounded to the column's scale; exact only inside the range D73 states. Money belongs in an integer column of minor units | models guide, "Column types"; D42, D73 | test/cast_types.rb and the tests D73 names |
| `pluck`, `maximum`, `sum`, `group(...).sum` | one method, any type | the type is in the name: `pluck_int`, `maximum_int`, `sum_float_by` | models guide, "Querying beyond `where`"; D44, D45 | test/pluck.rb, test/aggregates.rb |
| `where(col: a..b)` | any Range | Integer Ranges; a Time or Date range is `where_between` | D43 | test/relation_where.rb |
| `order(...)` | any SQL string | `column [ASC\|DESC]` lists only; raw SQL is `order_sql`, request data goes through an allowlist | models guide, "Ordering" | test/query_extras.rb |
| `before_action { ... }`, `before_save { ... }` | the block runs with `self` as the controller or record | the block takes it: `before_action { \|c\| c.authenticate }` | how-it-works; D8 | test/controller.rb, test/controller_order.rb, test/model.rb |
| `def new` in a controller | an action | `def new_action` (the generated routes call the action by that name) | how-it-works | test/gen_routes.rb, test/controller.rb |
| `layout "x"` declared twice | the last wins | the first declaration that applies wins | template language, "Per-controller layouts" | test/controller_views.rb |
| `session[:key] = value` | any marshalled object | Strings only | requests guide, "Cookies and the session" | test/session.rb |
| `config.filter_parameters` | Symbols, Regexps, lambdas | Strings matched by substring, case-insensitively | configuration guide | test/middleware.rb |
| `skip_forgery_protection` | per controller | CSRF runs before routing: exempt by path with `csrf_exempt_prefixes` | configuration guide | test/csrf.rb, test/csrf_chain.rb |
| `Rails.cache.fetch` | any object | Strings; `fetch_hash`, `fetch_array`, `fetch_int` for the rest | operations guide, "The cache store"; D54 | test/cache.rb |
| `perform_later(args)` | any serializable arguments, GlobalID | one Hash of JSON values; delivered at least once | operations guide; D28, D51, D68 | test/jobs.rb, test/job_threads.rb |
| Concerns | included at run time | expanded by `spin run gen` into the including classes | requests guide, "Concerns and `helper_method`"; D60 | test/gen_concerns.rb, test/gen_model_concerns.rb |
| ERB | Ruby | a template language with ERB's tags (below) | template language reference; D9 | test/template_*.rb |

A row is added when a new API takes a Rails name with a different meaning,
in the pull request that adds the API.

## The same application on SQLite and on MySQL

An application chooses its database when it is built: SQLite with
`require "cybertrain"`, MySQL 8.0 with `require "cybertrain/mysql"`
([configuration guide, "MySQL"](guide/configuration.md#mysql); D96). Its
code is the same on both, and models, migrations, the tests and the
framework's services answer the same. These are the differences kept on
purpose, each pinned by a MySQL test that `script/test-mysql` compiles and
runs against a server (CI's `mysql-tests` job):

| Behaviour | SQLite | MySQL | Explained in | Pinned by |
| --- | --- | --- | --- | --- |
| A `json` column's stored text | as written (`{"k":[1,2]}`) | normalised by the server (`{"k": [1, 2]}`); reads give the same Hash | models guide, "MySQL"; D96 | test/mysql/bulk_writes.rb, test/mysql/connection.rb |
| `LIKE`, `where_like` | case-insensitive for ASCII | case-sensitive (the `utf8mb4_0900_bin` collation, which makes `where`, `uniqueness` and unique indexes compare as SQLite does) | models guide, "MySQL" | test/mysql/relation.rb |
| Error messages (a duplicate, a NULL, a foreign key) | SQLite's wording | the server's wording, with `(MySQL <code>, <state>)`; the classes (`DB::UniqueViolation`, `DB::ForeignKeyViolation`, ...) are the same | models guide, "MySQL"; D96 | test/mysql/connection.rb, test/mysql/bulk_writes.rb, test/db_error_classes.rb |
| A migration that fails half way | rolled back whole | the statements before the failing one stay applied (MySQL's DDL commits), the error says how many, the version is not recorded | models guide, "MySQL"; D96 | test/mysql/migrations.rb |
| `db/schema.rb` from the same migrations | the options as written | as MySQL holds them: a string's `limit: 255` dropped; `precision: 10, scale: 0` dumped as a plain `t.decimal`, a precision without a scale given `scale: 0`; a `t.bigint` named `*_id` dumped as `t.integer`; a decimal's default with its scale (`"0.00"`); a foreign key without an index given one, named after the column | models guide, "MySQL"; D96 | test/mysql/schema_dump.rb |
| A default on a `text` or `json` column in `db/schema.rb` | as written | MySQL's expression text (`(_utf8mb4'{}')`) | models guide, "MySQL" | (not yet pinned) |
| An expression index (`execute "CREATE INDEX ..."`) | `ON users (LOWER(email))` | `ON users ((LOWER(email)))`, the expression in parentheses of its own (the single form is error 1064); dumped as MySQL spells it, ``(lower(`email`))`` | models guide, "MySQL" | test/mysql/migrations.rb |
| `add_index ..., where:` | a partial index | refused by gen, with the file and line, before anything is written | models guide, "MySQL" | test/gen_dialect.rb, test/mysql/migrations.rb |
| A decimal outside the column's precision | stored as the Float (the writers without validations) | refused by the strict sql_mode (`Out of range value`, 1264) | models guide, "MySQL"; D96 | test/mysql/decimal_range.rb |
| `Model.upsert`'s `update:` | `calls + excluded.calls`, `MAX(a, b)` | a column of the table qualified (`stats.calls + excluded.calls`), `GREATEST(a, b)`; `excluded` is the new row on both | models guide, "MySQL" | test/mysql/dialect.rb (the qualified column; `GREATEST` is in no test yet) |
| `insert_all(..., returning:)` on a table with unique indexes | any rows | the rows must supply one unique index whole, or `DB::Error` before writing | models guide, "MySQL" | test/mysql/bulk_writes.rb |
| A framework table (jobs, streams, cache, ...) missing at its first use inside `DB.transaction` | created inside the transaction | `DB::Error`, nothing committed: first use outside a transaction, or `install!` | configuration guide, "MySQL" | test/mysql/jobs.rb |
| Several processes or hosts on one database | one host (D74) | jobs, streams, leases and scheduled tasks guaranteed in one process only, until the roadmap's step 2 | configuration guide, "MySQL"; D96 | (not yet guaranteed) |

## The template language

The grammar, the callable methods per type and the helpers are the
[reference](guide/template-language.md). The contract behind it:

**What is supported is what the reference lists.** There is no fallback to
Ruby: a construct the grammar does not have and a method the per-type table
does not list are errors, never evaluated some other way.

**Every unsupported construct is rejected with a message that names the
template, the line and the construct.** The words Ruby has and templates do
not (`and`, `or`, `not`, `while`, `def`, `begin`, `rescue`, ...) and
constants each have their own message, not a generic parse error. A new
grammar feature comes with the message for its misuse.

**Errors come in three stages**, each with its own class:

| Stage | Class | When it surfaces |
| --- | --- | --- |
| Parsing | `Cybertrain::Template::SyntaxError` (`<template>:<line>: <what>`) | production: at boot, for every embedded template (the binary does not start with a template that does not parse); development and test: when the template is first rendered |
| Rendering | `Cybertrain::Template::RuntimeError` (the same shape; the template is the one being rendered, so a partial's error names the partial) | on the request |
| Lookup | `Cybertrain::Template::MissingTemplate` at the top level; inside a template it is relocated to a `RuntimeError` | on the request |

**Unknown names are errors, with one documented exception.**

| What is unknown | Result |
| --- | --- |
| a bare name that is neither a local nor a helper | `RuntimeError`: `undefined helper 'x'` |
| a method the receiver's type does not list | `RuntimeError`: `undefined method 'x' for <Type>` |
| an attribute, association or view method a generated model does not have | `RuntimeError`: `undefined method 'x' for <Model>` (D71). A name that exists and is nil renders empty. A hand-written `Cybertrain::Model` subclass that does not override `attribute_or_method?` keeps the old answer, nil |
| a local a partial's strict locals do not declare, or a declared one not passed | `RuntimeError`: `unknown local` / `missing local` |
| `@name` never assigned | nil, rendered empty: the exception, kept because a layout reads optional instance variables (`@title`) |
| a request-bound helper (`csrf_token`, `params`, `flash`, `*_url`) outside a request | `Cybertrain::Views::OutsideRequest`, not relocated, so `Views.render_partial`'s caller can rescue it |

### One template, three engines

A template reaches the interpreter three ways: read from `app/views` and
re-read when the file changes (development), read once and cached (test),
and from the table `spin run gen -- --embed-views` compiles into the
binary (production). They must mean the same thing, and
`test/template_parity.rb` holds them to it: the same pages render to the
same bytes in all three, and the same failing templates (runtime errors,
strict-locals errors, a missing template, eight kinds of syntax error)
fail with the same class and message. The differences that remain are
these, and no others:

- **The template's name in a message.** The embedded engine names a
  template by its table key (`pages/x.html.erb`); the file engines by the
  name asked for (`pages/x`) or, for a missing file, its path.
- **When a syntax error surfaces.** At boot in production, on first render
  elsewhere (the stage table above).
- **Picking up an edit.** Development only; the cached and embedded
  engines keep what they parsed.

## Changing a contract

A **compatibility change** is a change after which an application that
worked may behave differently without changing its own code: the meaning
of an existing API or template construct, an error where there was a
value (or the reverse), the text `spin run gen` emits for the same input
in a way the application can observe, a stored format (a column's
encoding, a table the framework owns), or a wire format (a cookie, a
header, the stream protocol).

1. **It is its own change.** An issue first, where the design is agreed;
   then a pull request that is not also a refactoring. A structural change
   and the behaviour change it enables are two commits at least, the
   structural one first and behaviour-preserving (as D71 did).
2. **It is recorded where it is decided.** The design.md decision has a
   "Compatibility" paragraph: what changes, who notices, how to find the
   affected code, what to do. The row on this page changes with it.
3. **It ships in a minor release, never a patch.** Before 1.0 a minor
   release (0.x to 0.x+1) may carry compatibility changes; a patch release
   (0.x.y to 0.x.y+1) carries none. The release notes are generated from
   pull request titles, so the title says "compatibility:" or names the
   change plainly.
4. **The upgrading guide gets the entry.** The release's section under
   "Notes by version" in [docs/guide/upgrading.md](guide/upgrading.md) says
   what changed and what to do, by topic, with the steps in the order to
   run them (as "From 0.4 to 0.5" does). The
   procedure on that page names no release and does not change; the guide
   of the topic describes the new behaviour only.
5. **Where it is possible, the old meaning is announced before it goes.**
   A change that can be detected at build time is a generator diagnostic
   first; one that can only be seen at run time is a boot-log warning for
   one minor release. Where neither is possible (the template unknown-name
   change was such a case: there is no place to warn from), the decision
   says so.
6. **A stored format changes with a command.** A conversion ships as a
   `db` subcommand or a migration helper (`db normalize` is the model),
   runs before the new binary serves, is safe to run twice, and the
   decision says whether the old binary can still read the result.
7. **Generated code changes are visible.** `spin run gen` rewrites the
   committed `gen/` files, so the diff is in the application's own pull
   request; a change to what is emitted says so in the release notes.

What is not a compatibility change: a new API, a new diagnostic for input
that never worked, a faster path, and anything behind `@api private`.
