# Phase 4a (the web layer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver part 4a of phase 4: `namespace` / `scope` / `resource` blocks / `param:` / redirect routes / query strings in path helpers, formats and `respond_to`, controller and model concerns with `helper_method`, the controller additions (`params.expect`, `send_data`, HTTP caching, `rate_limit` options on the cache, CSP with nonces, a cookie jar, an encrypted session, every status symbol, `force_ssl`, host checks, `Permissions-Policy`), the view additions (number helpers, forms, layouts, Turbo helpers, `time_tag` / `image_tag` / `current_page?`, collections) and digested assets with an import map.

**Architecture:** Rails' vocabulary everywhere, the framework's own mechanism wherever Spinel forbids Rails': the routes DSL grows inside `Gen::Mapper` and the router only learns the optional format; concerns are expanded by gen from a lexical scan (their `included do` bodies spliced into a generated reopening of the including class, loaded after the application's files); every name-to-method step is a generated `case` (helper methods, layouts, rate-limit keys, the asset manifest); openssl becomes part of every program, so the encrypted session and cookies use the existing `Encryptor`; assets are digested by `spin run gen` into `public/assets/` with the manifest compiled into the binary.

**Tech Stack:** Ruby compiled by Spinel 2026.11.04.7026 (also run under CRuby), SQLite via FFI, Spinel's openssl package (now always linked), the runtime's vendored `Digest::SHA256`, the existing `Gen::*` scanners and emitters, `Template::Helpers`, `Cybertrain::Cache`, `Cybertrain::Turbo`, the test receivers and `Test::Client`.

**Spec:** docs/superpowers/specs/2026-11-10-phase4-web-layer-design.md — sections 2 to 7, the 4a rows of sections 10 to 14, acceptance items 1 to 8 of section 15. Part 4b (sections 8, 9; acceptance 9 to 12) is not in this plan.

**Execution notes:** Task 1 first: its results amend spec §12 and every later task reads them. Tasks touching disjoint files may run in parallel worktrees, as phase 3 did: **group P1 = Tasks 11, 15, 18** (after Task 10) and **group P2 = Tasks 12, 16** (after group P1); every other task runs alone in the order given. A parallel task still runs `script/test-shard 0 1` after merging, and never two Spinel builds in one build directory at once.

## Plan decisions

Where the spec leaves a choice open that the code forces, the plan decides here (decision — reason):

1. Nested route blocks keep the explicit receiver (`namespace :admin do |admin| admin.resources :articles end`) — Spinel compiles only the top level of `Routes.draw` with `instance_eval` (routes_dsl.rb, `Routes.draw`'s comment); the spec's receiverless examples are written that way in the guides.
2. Asset digest: 8 lowercase hex characters (SHA-256's first 4 bytes) — Propshaft's short digest is 8 characters and every example in spec §7 shows 8; "8 bytes" in §7.1 is read as 8 characters (see the gaps in the handback).
3. The kept-digest history lives in `public/assets/.manifest` (text, one line per logical path), not in `gen/assets.rb` — `gen/assets.rb` stays a pure function of the sources so `spin run gen -- --check` is deterministic in a fresh clone; `public/assets/` is git-ignored (`cybertrain build` and CI run gen).
4. `request.format` comes from a fixed table of Rails' registered MIME extensions (`html text js css ics csv vcf vtt png jpeg gif bmp tiff svg webp mpeg mp3 ogg m4a webm mp4 otf ttf woff woff2 xml rss atom yaml multipart_form url_encoded_form json pdf zip gzip turbo_stream`, `jpg` → `:jpeg`, `htm` → `:html`, `txt` → `:text`); any other extension is still split off and reported as `:unknown` — no `to_sym` on request input (Symbols are never collected); `:unknown` matches no `respond_to` arm (406), as Rails' unregistered formats do.
5. A dynamic segment of a route that takes a format never captures a `.` (Rails' default `[^/.?]+`): `/articles/3.json.bak` does not match `/articles/:id(.:format)` (404) — the default follows Rails (§3, §14).
6. `respond_to`'s collector is the framework class `Cybertrain::FormatCollector`, which runs the first matching declaration's block at the moment it is declared, so no block is ever stored — `request.format` is known before the action runs; the spike (item 1) proves it from two controllers whose blocks render differently, and only on failure does gen write the spec's `case request.format` rewrite.
7. A controller's `content_security_policy do |p| ... end` (class level) and `c.content_security_policy do |p| ... end` (config) run their block once, at load, into a `Cybertrain::ContentSecurityPolicy` value stored by class name — data, not a stored block (rule 88), with no generated code needed.
8. Concern expansion: gen splices each `included do ... end` body, verbatim, into `gen/concerns.rb`, which reopens every including class and is required **last** by `gen/app.rb`; the controller's runtime lists keep the include's position through `Controller.concern_insert_at(callbacks_index, rescues_index)` / `Controller.concern_insert_done` (indices counted lexically: the declarations above the `include` line) — the generated file cannot load before the application's class file, which defines the class.
9. Model concerns use the same splice with `Model.model_concern_insert_at(validators_index)` / `Model.model_concern_insert_done`; model callbacks from a concern are appended after the model's own (the order of `before_save` blocks across a concern boundary is not something Rails documents either).
10. `around_action` in a concern's `included` block (listed in spec §4.1) is refused by gen with "around_action is not supported (no around callbacks in Cybertrain::Controller)" — the framework has no around callbacks and §5 adds none.
11. `ActiveSupport::Concern` is a module whose singleton methods `included(base = nil, &block)` and `class_methods(&block)` do nothing; under CRuby too the blocks never run, so both runtimes behave alike and only gen's splice gives them effect.
12. `class_methods do def x ... end end` becomes, in `gen/concerns.rb`, `module AdminGate; def self.x ...; end` plus `def self.x(...) = AdminGate.x(...)` in each including class — `(...)` forwarding is already emitted for model delegations.
13. Generated path helpers take a trailing positional `options = {}` (`def article_path(article, options = {})`): Ruby turns braceless keywords at the call into that Hash; `**opts` is not used in generated code (the spike's item 2 compiles a call with keywords).
14. Query-string values: nil omits the key, an Array gives `key[]=v` per element, a Hash value raises `ArgumentError, "path helper option :q must be a String, Symbol, number, boolean or Array (got Hash)"`; keys keep the order given; `format:` goes before the query, `anchor:` after it.
15. `Params#permit` and `#expect` return `Hash{String => Object}` (values String, `Array<String>`, or a nested Hash of the same) — one return type per name (rule 34), and a model's generated `write_attribute` already narrows each value with `Cast`.
16. `TimeZone`'s private parser method `expect(byte)` is renamed `expect_byte` — `Params#expect` takes the Rails name.
17. Rate-limit counts: fixed windows aligned to the epoch, key `"rate-limit:#{controller_path}:#{name}:#{key}:#{now / within}"` through `Cache.increment(key, expires_in: within)`; `Retry-After` = `within - now % within` — `Cache.increment` returns only the count, and an aligned window needs no expiry lookup.
18. Cookie and session keys: `Crypto.derive_key(secret_key_base, label) -> String` (32 raw bytes, HMAC-SHA256 of the label), labels `"cybertrain session"`, `"cybertrain signed cookie"`, `"cybertrain encrypted cookie"`; the encrypted payload binds its purpose as AES-GCM additional data (`"session"`, `"cookie:#{name}"`), so a value cannot be moved between cookies.
19. Session cookie value: urlsafe Base64 without padding of `nonce(12) + ciphertext + tag(16)`; a cookie over 4096 bytes is refused on write with `Session::CookieOverflow` and treated as absent on read (Rails' `CookieOverflow` limit).
20. `cookies.permanent` writes `Max-Age=631139040` (20 ActiveSupport years); `cookies[:x] = { expires: time }` writes `Expires=<httpdate>`; jar writes go straight to the response, replacing an earlier `Set-Cookie` of the same name.
21. `force_ssl` answers 301 for GET/HEAD and 307 otherwise (Rails' `ActionDispatch::SSL`), reads `X-Forwarded-Proto` whatever `trusted_proxy` says (a spoofed header only skips the spoofer's own redirect), exempts the health path, and sends `Strict-Transport-Security: max-age=63072000; includeSubDomains` (Rails' default HSTS).
22. Host checks: `CYBERTRAIN_HOSTS` entries are appended to `Config#allowed_hosts`; the check runs when `development?` or `Config#hosts_from_env` is non-empty; `CYBERTRAIN_ALLOWED_HOSTS` keeps its development-only meaning (both lists end in `allowed_hosts`).
23. `permissions_policy` is a String field (`"camera=(), microphone=(), geolocation=()"`, `""` sends none), installed on `Response.default_permissions_policy` at boot like `Request.trusted_proxy` — the HTTP layer cannot read `Config`.
24. Reason phrases follow RFC 9110 for every Rack code (413 "Content Too Large", 422 "Unprocessable Content"); the old symbols `:unprocessable_entity` and `:payload_too_large` stay as aliases.
25. The builder's attribute order stays the house order (`type`, `name`, `id`, `value`, then options), options of a `<select>` are joined with `"\n"` and written `<option selected="selected" value="x">`, as Rails does; no `data-disable-with`.
26. `turbo_frame_tag` writes `loading` only when given (Rails); `form_with local:` is accepted and ignored (Turbo era).
27. Number helpers accept Integer, Float and a numeric String (decimal columns are Float since D42); rounding is half-up on the digits of `Float#to_s` (what Rails gets from `BigDecimal(value.to_s)`).
28. The import map's `preload:` defaults to true (importmap-rails 2); `pin_all_from` maps `index.js` to the directory name.
29. A logical asset path found under two roots is a gen error naming both files (Propshaft silently takes the first).
30. The Dockerfile's build stage gains `libssl-dev` and the runtime stage `libssl3t64` — every application now links OpenSSL; the current images have neither (see the gaps in the handback).

## Global Constraints

- **Closer to Rails, then easier to understand** decides every judgement call (spec §0): Rails' names, defaults, file layout and output; compatibility with 0.4 applications carries low weight (§14 lists each break).
- **No computed `send`, `public_send`, `const_get` or `constantize`** (spikes/NOTES.md rule 1): namespaced controllers, helper methods, layouts, rate-limit keys, concern expansion and the asset manifest are generated `case` tables.
- **One return type per method name across the program** (rules 10, 34, 41): every new public name has a row in `script/check-reserved-names`' name-homes table (seeded in Task 1 with this plan's homes, so parallel tasks never edit it; a name the plan did not foresee is added by its task, which then runs outside any parallel group) listing the files allowed to define it; `select`, `format`, `expect`, `layout`, `cookies`, `t`, `l`, `html`, `json`, `turbo_stream`, `permit` are the first candidates; a clash takes the distinct name the task names.
- **No stored block run through a base-class receiver** (rule 88): `respond_to` and per-controller CSP run their block at once; nothing new stores a block on `Cybertrain::Controller` or `Cybertrain::Model`.
- **Rule 62 framework-wide**: once Task 12 makes `require "cybertrain"` load `cybertrain/encryptor` (openssl), every method that scans a String byte by byte reads its parameter through a fresh local (`s = text.to_s`), and `spinel prog.rb -c -o /tmp/x.c && grep -c 'sp_raise_nomethod(sp_nomethod_msg("getbyte"' /tmp/x.c` (and `"each_byte"`) prints 0 for test/application.rb's program and the blog's server.
- Other Spinel rules in play: nullable ivars through nil-capable casts (7); seed polymorphic containers (9/46); threads through a method (21); `rescue` in a non-yielding method (32/45); messages built into a local before `raise` (58); a yield's value into a local before a method call (90).
- **Never skip, delete or weaken a test** to make a task pass; a snapshot changes only where behaviour changed on purpose.
- Every task ends with: `ruby script/gate` green, `ruby script/check-reserved-names` green, `script/api-docs` clean, the task's `spin test test/<x>.rb` programs green (snapshots through `script/regen-snapshot test/<x>.rb` for SQLite/FFI programs), fixtures under `test/fixtures/gen_app/gen/**` and `test/fixtures/gen_namespaced/gen/**` regenerated when an emitter changed (their tests rewrite stale fixtures and fail once), `docs/api/stubs/generated_app.rb` mirroring every newly emitted method, and `script/test-shard 0 1` (whole suite) green.
- Toolchain: `export PATH=/root/.cybertrain/spinel/2026.11.04.7026/lib/spinel:$PATH`; `spin test test/<x>.rb`; `script/regen-snapshot test/<x>.rb`; blog: `cd examples/blog && spin run gen && spin test && spin run gen -- --check`.
- Commits end with the two trailer lines `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01ScPEggU9WUkFSWQD5AVWtS`; no model identifier in code, comments or commit subjects (CONTRIBUTING.md).
- Messages, header values, status codes and option names are the spec's verbatim where it fixes them, else this plan's.

## Review Focus

1. **A dotted segment that is not a format** (`GET /files/report.v2` on `get "/files/:name"`, `GET /articles/3.json.bak`): the first splits into `name = "report"`, `request.format == :unknown` and an implicit render answers 406, not 500; the second does not match (404); with `format: false` the whole `report.v2` is the segment. Pinned in Task 3's test "a dotted segment that is not a registered format".
2. **`Accept` with q-values or wildcards** (`text/html;q=0.9, application/json`, `application/json;q=0`, `*/*`, `application/json, */*`): position decides (`text/html` first → `:html`), `q=0` excludes a type, `*/*` alone is `:html`, an empty or absent header is `:html`. Pinned in Task 3's test "Accept with q-values and wildcards".
3. **A tampered, truncated, foreign or oversized encrypted session cookie** (one flipped Base64 byte, a 0.4 signed cookie, an encrypted cookie copied from `cookies.encrypted[:x]` into the session's name, a 5,000-byte cookie): each loads as an empty session without raising, and a session whose dump would exceed 4096 bytes raises `Session::CookieOverflow` at write. Pinned in Task 12's test "foreign and damaged session cookies load empty".
4. **A concern included twice, or in a namespaced controller** (`include AdminGate` in `ApplicationController` and again in `Admin::ArticlesController`; a namespaced controller in nested `module Admin` form including it): the callbacks run once, in the ancestor's position, and the generated reopening opens `module Admin` itself. Pinned in Task 5's test "a concern included by an ancestor and again is expanded once".
5. **A CSS `url()` with a query or fragment, quotes, `data:` or an absolute URL** (`url("../fonts/x.woff2?v=3#iefix")`, `url(data:image/png;base64,...)`, `url(https://cdn/x.png)`, `url(#clip)`): the path part is digested and the suffix kept; the others are left as written without a warning. Pinned in Task 18's test "url() suffixes, quotes and non-asset references".

---

### Task 1: The spike (spec §12 items 1–5) and the name-homes guard

**Files:**
- Create: `spikes/phase4/spin.toml` (package `phase4-spike`, `cybertrain = { path = "../.." }`), `spikes/phase4/respond_to.rb`, `spikes/phase4/admin_controllers.rb`, `spikes/phase4/concern_class_methods.rb`, `spikes/phase4/openssl_session.rb`, `spikes/phase4/asset_digest.rb`, `spikes/phase4/asset_case.rb` (programs kept as the record, each with its commands and output in the header comment, as spikes/phase3/ has; not tests)
- Modify: `script/check-reserved-names` (a NAME_HOMES table: method name → the files allowed to `def` it; the check greps `cybertrain/**/*.rb` and `cybertrain/generator/*_emitter.rb`'s emitted `def` lines and fails, naming file and line, for a definer outside the list), `docs/superpowers/specs/2026-11-10-phase4-web-layer-design.md` §12 ("**Results (2026-11-1x, Spinel 2026.11.04.7026, programs kept in spikes/phase4/ …):**"), `spikes/NOTES.md` (new rules numbered after 91, with "Rules by topic" entries), `docs/spinel-feedback.md` (a row per Spinel limit found)

**Interfaces:**
- Produces: the five verdicts with the fallback taken for any failure (later tasks read amended §12 first): item 1 → Task 8, item 2 → Tasks 2, 4, 5, item 3 → Task 5, item 4 → Task 12, item 5 → Task 18; `NAME_HOMES` seeded once, with today's definers **and** the homes this plan gives each name, so later tasks (some in parallel) never edit the table: `format` → console/printer.rb, http/request.rb; `expect` → mailer.rb, params.rb (time_zone.rb's is renamed in Task 11); `select` → template/form_builder.rb; `layout` → cli/templates.rb (a `def self.`), controller.rb; `cookies` → controller.rb; `signed`, `encrypted`, `permanent` → cookie_jar.rb; `html`, `json`, `turbo_stream`, `csv`, `xml`, `text`, `any` → format_collector.rb plus `json` → schema/table.rb, `turbo_stream` → controller.rb; `permit` → params.rb; `t`, `l` → none yet (4b).

- [ ] **Step 1: Write the six programs.**
  (1) `respond_to.rb`: a `FormatCollector` (methods `html(&b)`, `json(&b)`, `turbo_stream(&b)`, `any(&b)`, each running its block at once when it matches the format it was built with and none matched before) used from two `Cybertrain::Controller` subclasses whose `json` blocks call `render json:` with an ivar and whose `html` arm is blockless; and, beside it, a generated-style per-controller collector that stores the blocks and runs them after the `respond_to` block returns; through `Test::Client` with `Accept: application/json` and without. (2) `admin_controllers.rb`: `module Admin; class ArticlesController < ApplicationController` and `class Admin::ReportsController < ApplicationController` (after `module Admin` exists), both instantiated from a `Router` built the way gen/routes.rb builds it, plus a path helper `def admin_article_path(article, options = {})` called as `admin_article_path(a, page: 2, format: :json)`. (3) `concern_class_methods.rb`: `module ActiveSupport; module Concern; def included(base = nil, &block) = nil; def class_methods(&block) = nil; end; end`, a concern with `extend ActiveSupport::Concern`, `included do before_action :require_admin, only: [:index]; helper_method :admin?; rescue_from ArgumentError, with: :bad end` and `class_methods do def per_page = 50 end`, included in a controller; the reopening gen would write (`module AdminGate; def self.per_page = 50; end`, `def self.per_page(...) = AdminGate.per_page(...)`) and an action reading `self.class.per_page`. (4) `openssl_session.rb`: `require "cybertrain"` plus `require "cybertrain/encryptor"`, an application with a session round trip (write in one request, read in the next) through `Application#call` and `Response#to_http`; compiled with `spinel $(spin flags) openssl_session.rb -c -o /tmp/s.c`, grepped for the `getbyte` and `each_byte` NoMethodError switches. (5) `asset_digest.rb`: in a program shaped like bin/gen.rb, `File.binread` of a 1 MB file and `Digest::SHA256.digest`, timed. (6) `asset_case.rb`: a generated module with a 200-arm `case` from logical to digested path, compiled; time and binary size recorded.
- [ ] **Step 2: Run each** with `spin run` (or the `spinel` lines in its header) from `spikes/phase4/`, record the output in the header.
- [ ] **Step 3: Write the name-homes check** in `script/check-reserved-names` and run `ruby script/check-reserved-names` (green: the seeded rows list today's definers, e.g. `json` → `cybertrain/schema/table.rb`, `expect` → `cybertrain/mailer.rb`, `cybertrain/time_zone.rb`, `format` → `cybertrain/console/printer.rb`).
- [ ] **Step 4: Amend spec §12** with each result and the fallback taken (item 1: the immediate collector, else the storing one, else gen's `case request.format` rewrite; item 2: the compact form refused by gen with "use `module Admin` / `class ArticlesController` nesting"; item 3: `ModuleName.per_page`, gen refusing `class_methods do`; also record whether the `included do` body compiled — if not, `ActiveSupport::Concern` gains no-op singleton stubs for every declaration Task 5 splices); add NOTES rules and spinel-feedback rows for new findings.
- [ ] **Step 5: Gate and commit**: "Phase 4a spike: respond_to collectors, both Admin:: forms, concern class_methods, openssl in every program, asset digests and a 200-arm manifest; the name-homes check".

---

### Task 2: Routes DSL — `namespace`, `scope`, `resource` blocks, `controller:`, `on:`, `param:`

**Files:**
- Modify: `cybertrain/generator/routes_dsl.rb` (`RouteSpec` gains `helper_args` (Array<String>, the helper's parameter names in segment order, filled by the Mapper) and `takes_format` (Boolean, default true, set by Task 3); `Mapper` gains `@module_prefix` ("admin/") and `@scope_kind` alongside `save_scope` / `restore_scope`; `namespace(name, &block)`, `scope(path = "", module: "", as: "", &block)`, `resources(name, only:, except:, controller: "", param: :id, &block)`, `resource(name, only:, except:, controller: "", &block)`, `get/post/patch/put/delete(path, to: "", as: "", on: nil)`; `jobs_page` accepted inside `namespace` / path `scope` (prefix applied; still one per application, still refused inside `resources`)), `cybertrain/generator/routes_emitter.rb` (`arg_names` uses `spec.helper_args` when non-empty)
- Modify fixtures: `test/fixtures/gen_app/config/routes.rb` gains `scope "/v1", as: "v1" do |v| v.get "/about", to: "pages#about" end` and `resource :profile, controller: "pages", only: [:show] do |r| r.get :refresh, on: :member end` (`PagesController` gains `show` and `refresh`); `test/fixtures/gen_namespaced/config/routes.rb` becomes `namespace :admin do |admin| admin.resources :users, only: [:index, :show], param: :login end`
- Test: `test/gen_routes.rb` (grown), `test/gen_routes_compiles.rb` and `test/gen_namespaced.rb` (grown: the same routes through the compiled router — `GET /v1/about`, `GET /profile/refresh`, `GET /admin/users/ann` with `params[:login] == "ann"` and `admin_user_path("ann") == "/admin/users/ann"`)

**Interfaces:**
- Produces: `Mapper#namespace`, `#scope`, the `controller:` / `param:` / block / `on:` options; `RouteSpec#helper_args`, `#takes_format`, `RouteSpec#controller` now possibly `"admin/articles"`.

- [ ] **Step 1: Write the failing tests** (route lines as `route_lines` prints them):

```ruby
test "namespace prefixes path, helper and controller, and nests" do
  Cybertrain::Routes.reset!
  Cybertrain::Routes.draw do
    namespace :admin do |admin|
      admin.resources :articles, only: [:index, :destroy]
      admin.namespace :reports do |reports|
        reports.get "/daily", to: "daily#show"
      end
      admin.jobs_page "/jobs", before_action: :require_admin
    end
  end
  lines = route_lines(Cybertrain::Routes.specs)
  assert_includes lines, "GET /admin/articles admin/articles#index admin_articles"
  assert_includes lines, "DELETE /admin/articles/:id admin/articles#destroy admin_article"
  assert_includes lines, "GET /admin/reports/daily admin/reports/daily#show admin_reports_daily"
  assert_equal "/admin/jobs", Cybertrain::Routes.jobs_page_spec.jobs_path
  assert_equal "Admin::ArticlesController", Cybertrain::Routes.specs[0].controller_class
end
test "scope path, module and as each change one thing and combine" do
  # scope "dashboard" { get "/stats", to: "stats#index" } -> GET /dashboard/stats stats#index stats
  # scope module: "admin" { resources :users, only: [:index] } -> GET /users admin/users#index users
  # scope as: "admin" { get "/stats", to: "stats#index" } -> GET /stats stats#index admin_stats
  # scope "/x", module: "y", as: "z" { get "/a", to: "p#a" } -> GET /x/a y/p#a z_a
end
test "resource takes controller: and a block with member routes and nested resources" do
  # resource :session, controller: "auth/sessions" do |s|
  #   s.get :refresh, on: :member
  #   s.resource :settings, only: [:edit, :update]
  #   s.resources :devices, only: [:index]
  # end
  # -> GET /session/refresh auth/sessions#refresh refresh_session
  #    GET /session/settings/edit settings#edit edit_session_settings
  #    PATCH /session/settings settings#update session_settings
  #    GET /session/devices devices#index session_devices
  #    GET /session/new auth/sessions#new new_session ... (Rails order kept)
end
test "resources controller: and param:" do
  # resources :indicators, param: :key, controller: "metrics" do |i| i.resources :points, only: [:index] end
  # -> GET /indicators/:indicator_key/points points#index indicator_points (helper_args ["indicator"])
  #    GET /indicators/:key metrics#show indicator (helper_args ["indicator"])
end
test "on: :collection and on: :member inside resources" do
  # resources :posts do |p| p.get :search, on: :collection; p.post :publish, on: :member end
  # -> GET /posts/search posts#search search_posts ; POST /posts/:id/publish posts#publish publish_post
end
test "misuse is refused with a message" do
  # namespace inside resources -> ArgumentError "namespace must be used outside resources"
  # on: :member at the top level -> ArgumentError "on: :member must be used inside resources or resource"
  # param: "Key" -> ArgumentError "param: must be a lowercase name (got \"Key\")"
  # a second jobs_page inside a namespace -> the existing "already drawn" message
end
```

- [ ] **Step 2: Run** `ruby -I. test/gen_routes.rb` (CRuby) and `spin test test/gen_routes.rb`: FAIL (`undefined method 'namespace'`).
- [ ] **Step 3: Implement** in the files above. `namespace :x` = `scope("/x", module: "x", as: "x")`; module prefix applies to every controller drawn inside (`to:` and `controller:` included, as Rails); a singular `resource` block sets `@path_prefix = "#{path}"`, `@name_prefix = "#{route_name}_"` and mode `"resource"`, where `on: :member` draws at the resource's path and `on: :collection` is refused; `param:` replaces `:id` in member paths and becomes `:<singular>_<param>` for children; `helper_args` names a resource's param segment after its singular and a custom `:x` segment `x`.
- [ ] **Step 4: Run** both again (PASS); `spin test test/gen_routes_compiles.rb test/gen_namespaced.rb` (each rewrites its stale fixture and fails once; run again: PASS).
- [ ] **Step 5: Gate and commit**: "Routes: namespace, scope (path, module, as), resource blocks, controller:, on:, param:, jobs_page inside a namespace".

---

### Task 3: Formats in the router, `Request#format`, redirect routes

**Files:**
- Modify: `cybertrain/router.rb` (`Route#initialize(verb, pattern, name, handler, takes_format = true)`; `Route#match(verb, path_segments)` also tries the last segment split at its last `.` when `takes_format` (the head must be non-empty and, for a dynamic segment, dot-free; the tail `[A-Za-z0-9_]{1,20}`) and reports the extension through `Route#matched_extension -> String` ("" none; set per match, read immediately by `Router#call`); `Router#add(verb, pattern, name = "", takes_format = true, &handler)`; `Router#call` sets `ctx.request.format_extension = ext`; `Router.redirect_to(ctx, target, status)` (fills `%{name}` from `ctx.route_params` through `Router.escape_segment`, answers `status` with `Location`, empty body)), `cybertrain/http/request.rb` (`attr_reader :format_extension` / `format_extension=`; `Request#format -> Symbol` (memoised): the registered Symbol of the extension (plan decision 4) or `:unknown`; with no extension, `Accept` parsed by position: `:turbo_stream` when `text/vnd.turbo-stream.html` is present, else `:json` when `application/json` is present and `text/html` is not before it, else `:html`; an entry with `q=0` is ignored; `Request.format_for_extension(ext) -> Symbol` the `case` table; `Request.mime_type(format) -> String` the reverse for content types: `:html` → `"text/html; charset=utf-8"`, `:json` → `"application/json; charset=utf-8"`, `:turbo_stream` → `"text/vnd.turbo-stream.html; charset=utf-8"`, `:csv` → `"text/csv; charset=utf-8"`, `:xml` → `"application/xml; charset=utf-8"`, `:text` → `"text/plain; charset=utf-8"`, `:js` → `"text/javascript; charset=utf-8"`, others `"application/octet-stream"`), `cybertrain/generator/routes_dsl.rb` (`format: true` keyword on `get`/`post`/`patch`/`put`/`delete`/`resources`/`resource`/`root`, stored on `RouteSpec#takes_format`; `Mapper#redirect(path, status: 301) -> RedirectSpec` (`Gen::RedirectSpec` with `redirect_target`, `redirect_status`; status outside 300–308 → `ArgumentError, "redirect status: must be a 3xx code (got 200)"`; a `%{name}` the route's pattern lacks → `ArgumentError, "redirect(\"/posts/%{slug}\"): %{slug} is not a segment of /posts/:id/show"`); `to:` accepts a String or a RedirectSpec), `cybertrain/generator/routes_emitter.rb` (`router.add("GET", "/old", "", true) { |ctx| Cybertrain::Router.redirect_to(ctx, "/new", 301) }`; the format argument emitted only when false)
- Test: `test/router.rb` (grown), `test/http_request.rb` (grown), `test/gen_routes.rb` (grown), `test/gen_routes_compiles.rb` (grown, through the gen_app fixture: `test/fixtures/gen_app/config/routes.rb` gains `get "/old-posts/:id", to: redirect("/posts/%{id}")` and `get "/files/:name", to: "pages#file", format: false`)

**Interfaces:**
- Consumes: Task 2's `RouteSpec#takes_format`.
- Produces: `Request#format -> Symbol`, `Request#format_extension -> String`, `Request.format_for_extension`, `Request.mime_type`, `Router.redirect_to`, `Router#add(verb, pattern, name, takes_format)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/router.rb
test "an extension on the last segment is the format" do
  ctx = dispatch(sample_router, "GET", "/posts/3.json")
  assert_equal "show 3", ctx.response.body
  assert_equal :json, ctx.request.format
  assert_equal "json", ctx.request.format_extension
end
test "a route with format: false keeps the dot" do
  router = Cybertrain::Router.new
  router.add("GET", "/files/:name", "file", false) { |c| c.response.body = c.params[:name].to_s }
  assert_equal "report.v2", dispatch(router, "GET", "/files/report.v2").response.body
end
test "a dotted segment that is not a registered format" do
  router = Cybertrain::Router.new
  router.get("/files/:name", "file") { |c| c.response.body = "#{c.params[:name]} #{c.request.format}" }
  assert_equal "report unknown", dispatch(router, "GET", "/files/report.v2").response.body
  assert_equal 404, dispatch(sample_router, "GET", "/posts/3.json.bak").response.status
  assert_equal 404, dispatch(sample_router, "GET", "/posts/.json").response.status
end
test "a literal last segment with a dot matches whole first" do
  # router.get("/robots.txt") -> GET /robots.txt matches, format :text
end
test "redirect_to fills and escapes segments" do
  # route "/posts/:id/show" handler Router.redirect_to(ctx, "/posts/%{id}", 301); GET /posts/a%20b/show
  # -> 301, Location "/posts/a%20b", body ""; with status 302 -> 302
end
# test/http_request.rb
test "Accept decides the format when there is no extension" do
  assert_equal :html, req_with_accept("").format
  assert_equal :html, req_with_accept("*/*").format
  assert_equal :turbo_stream, req_with_accept("text/vnd.turbo-stream.html, text/html, application/xhtml+xml").format
  assert_equal :json, req_with_accept("application/json").format
  assert_equal :json, req_with_accept("application/json, */*").format
end
test "Accept with q-values and wildcards" do
  assert_equal :html, req_with_accept("text/html;q=0.9, application/json").format
  assert_equal :html, req_with_accept("application/json;q=0, text/html").format
  assert_equal :html, req_with_accept("application/json;q=0").format
  assert_equal :json, req_with_accept("text/*, application/json;q=0.1").format   # text/* is not text/html
end
test "extensions map to Rails' registered formats" do
  assert_equal :jpeg, Cybertrain::Request.format_for_extension("jpg")
  assert_equal :text, Cybertrain::Request.format_for_extension("txt")
  assert_equal :unknown, Cybertrain::Request.format_for_extension("v2")
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", Cybertrain::Request.mime_type(:turbo_stream)
end
```
- [ ] **Step 2: Run** `spin test test/router.rb test/http_request.rb test/gen_routes.rb`: FAIL.
- [ ] **Step 3: Implement** as listed; `Request#format`'s Accept scan reads the header through a fresh local (rule 62).
- [ ] **Step 4: Run** the three plus `spin test test/gen_routes_compiles.rb` (redirect and `format: false` through the fixture; regen the fixture once) and `spin test test/static.rb` (a dotted file name is still served by Static before the router).
- [ ] **Step 5: Gate and commit**: "Router: the optional format extension, request.format from the extension or Accept, redirect routes".

---

### Task 4: Path helpers — query strings, `format:`, `anchor:` (R-7)

**Files:**
- Modify: `cybertrain/generator/routes_emitter.rb` (every helper `def x_path(a, b, options = {})` returning `Cybertrain::Gen.with_options("<path expr>", options)`; `x_url` likewise; `path_for(name, args, options = {})`; `url_resolver` → `->(name, args, options) { path_for(name, args, options) }`), `cybertrain/generator/url_support.rb` (`Cybertrain::Gen.with_options(path, options) -> String`: `format:` → `.json` appended, then the remaining keys in given order as `key=value` with `URI.encode_www_form_component`, nil omitted, Arrays as `key%5B%5D=v`, then `anchor:` as `#` + the escaped value; plan decision 14's error for a Hash), `cybertrain/views.rb` (`url_resolver` contract: three arguments), `cybertrain/template/helpers.rb` (`route(name, args, kwargs)` passes the template's keywords; `url_for(target, kwargs)` keeps a String target and appends options), `cybertrain/application.rb` / `cybertrain/cli/templates.rb` (`bin_app` unchanged: it already passes `Gen::Routes.url_resolver`), `docs/api/stubs/generated_app.rb`
- Test: `test/gen_routes_compiles.rb` (grown), `test/helpers.rb` (grown), `test/views_detached.rb` (grown)

**Interfaces:**
- Consumes: Task 2's `helper_args`, Task 3's format.
- Produces: `Gen.with_options(path, options)`; helpers `x_path(*segments, options = {})`; `Views.url_resolver.call(name, args, options)`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "unused keywords become the query string, in order, escaped" do
  assert_equal "/posts/3?page=2", post_path(3, page: 2)
  assert_equal "/posts?q=a+b&sort=new", posts_path(q: "a b", sort: :new)
  assert_equal "/posts", posts_path(q: nil)
  assert_equal "/posts?tag%5B%5D=a&tag%5B%5D=b", posts_path(tag: ["a", "b"])
end
test "format: and anchor:" do
  assert_equal "/posts/3.json", post_path(3, format: :json)
  assert_equal "/posts/3.json?page=2#comments", post_path(3, page: 2, format: "json", anchor: "comments")
end
test "a Hash value is refused" do
  assert_raises("ArgumentError") { posts_path(q: { "a" => "b" }) }
end
# test/helpers.rb (template): <%= post_path(@post, page: 2) %> -> /posts/3?page=2 ; <%= url_for("/x", format: :csv) %> -> /x.csv
```

- [ ] **Step 2: Run** `spin test test/gen_routes_compiles.rb test/helpers.rb`: FAIL.
- [ ] **Step 3: Implement**; regen the gen_app and gen_namespaced fixtures.
- [ ] **Step 4: Run** the two plus `spin test test/views_detached.rb test/app_helpers.rb test/gen_namespaced.rb`.
- [ ] **Step 5: Gate and commit**: "Path helpers: query strings from unused keywords, format:, anchor:".

---

### Task 5: Controller concerns, the nested `module` form, `gen/concerns.rb`

**Files:**
- Create: `cybertrain/active_support.rb` (`module ActiveSupport; module Concern; def included(base = nil, &block) = nil; def class_methods(&block) = nil; end; end`, required by cybertrain.rb; stubs per Task 1's verdict), `cybertrain/generator/concern_scan.rb` (`Gen::ConcernInfo` (`concern_file`, `concern_name`, `included_body` (Array<String> lines), `class_method_lines` (Array<String>), `concern_includes` (Array<String>), `concern_ivars`, `concern_callbacks`, `concern_defs` (HelperDef list for Task 6), `concern_line`); `ConcernScan.scan_dir(dir) -> Array<ConcernInfo>` over `app/controllers/concerns/**/*.rb` and any module-only file under `app/controllers` (and, for Task 7, `app/models/concerns`); `ConcernScan.expand(names, concerns) -> Array<ConcernInfo>` depth first, each once, `ArgumentError, "concern cycle: AdminGate includes Auditing includes AdminGate"` for a cycle, `ArgumentError, "app/controllers/articles_controller.rb:3: include Missing: no concern named Missing in app/controllers/concerns"` for an unknown name), `cybertrain/generator/concerns_emitter.rb` (`ConcernsEmitter.emit(controller_infos, concern_infos) -> String` for `gen/concerns.rb`: per concern with class methods `module X; def self.m ...; end`; per including class (namespaced classes opened as nested modules, via `ControllersEmitter.class_source`'s wrapper) `concern_insert_at(callbacks_index, rescues_index)`, the spliced `included` lines, `concern_insert_done`, and `def self.m(...) = X.m(...)` per class method)
- Modify: `cybertrain/generator/controller_scan.rb` (`ControllerInfo` gains `includes` (Array<String>), `include_positions` (Array<Integer>: per include, the count of `before_action` / `after_action` / `rate_limit` / `prepend_before_action` lines above it in that class), `rescue_positions` (the count of `rescue_from` lines above it); the scan tracks `module A` / `module A::B` lines and closes them on an `end` at the same indentation, so `module Admin` + `class ArticlesController < ApplicationController` yields `Admin::ArticlesController`; a superclass written bare inside a module resolves to `Admin::X` when the scan found that class, else to the top-level name), `cybertrain/generator/controllers_emitter.rb` (an including controller's `run_callback` arms and `view_assigns` include those of its expanded concerns; a superclass resolved to the top level is emitted `::ApplicationController` as today), `cybertrain/controller.rb` (`Controller.concern_insert_at(callbacks_index, rescues_index) -> nil`, `Controller.concern_insert_done -> nil`: while set for `self.name`, `add_callback` and `rescue_from` insert at the index and advance it; `Controller.helper_method(*names) = nil` and `Controller.layout(...) = nil` no-op declarations gen reads (Tasks 6, 9)), `cybertrain/generator/manifest.rb` (concerns first: `app/controllers/concerns/**` before `application_controller`; `app/models/concerns/**` before the models; `require_relative "concerns"` last), `cybertrain/generator/runner.rb` (`gen/concerns.rb` output), `cybertrain.rb` (`require "cybertrain/active_support"`)
- Create fixtures: `test/fixtures/gen_app/app/controllers/concerns/admin_gate.rb` (the spec §4.1 concern, with `class_methods do def per_page = 50 end`), `test/fixtures/gen_app/app/controllers/concerns/auditing.rb` (includes `AdminGate`'s sibling `Stamped`, depth-first case), `test/fixtures/gen_app/app/controllers/concerns/stamped.rb`, `test/fixtures/gen_namespaced/app/controllers/admin/reports_controller.rb` (nested `module Admin` form, `include AdminGate`), `test/fixtures/gen_namespaced/app/controllers/concerns/admin_gate.rb`
- Test: `test/gen_concerns.rb` (new, compiled with the gen_app fixture), `test/gen_controllers.rb` (grown: scan results), `test/gen_namespaced.rb` (grown), `test/gen_manifest.rb` (grown)

**Interfaces:**
- Produces: `Gen::ConcernScan`, `Gen::ConcernInfo`, `Gen::ConcernsEmitter.emit`, `gen/concerns.rb`; `Controller.concern_insert_at` / `concern_insert_done`; `Controller.helper_method`, `Controller.layout` (no-ops); `ControllerInfo#includes`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/gen_concerns.rb
test "before_action from a concern runs at the include's position" do
  # PostsController: before_action :set_post (line 2), include AdminGate (line 3), before_action :log_visit (line 4)
  # GET /posts/1 as non-admin -> 404 "Not Found", and the recorded order is ["set_post", "require_admin"] (log_visit not reached)
end
test "class_methods are callable through self.class" do
  # an action rendering plain: self.class.per_page.to_s -> "50"; AdminGate.per_page -> 50
end
test "nested concerns expand depth first; a cycle is refused by name" do
  # ConcernScan.expand(["Auditing"], infos).map(&:concern_name) == ["Stamped", "Auditing"]
  # a two-concern cycle -> ArgumentError "concern cycle: A includes B includes A"
end
test "a concern included by an ancestor and again is expanded once" do
  # ApplicationController includes Stamped; PostsController includes Stamped too: the callback list holds it once
end
test "@x in a concern method is a view assign of the includer" do
  # PostsController.new(ctx).view_assigns.keys includes "audited_at" (assigned in Auditing#audit)
end
# test/gen_namespaced.rb
test "a nested module Admin controller is scanned as Admin::ReportsController and dispatches" do
  # scan -> class_name "Admin::ReportsController", superclass "ApplicationController"; GET /admin/reports 200 through gen/routes
  # it includes AdminGate: gen/concerns.rb contains "module Admin\n  class ReportsController\n" and its require_admin runs once
end
```

- [ ] **Step 2: Run** `spin test test/gen_concerns.rb test/gen_namespaced.rb`: FAIL.
- [ ] **Step 3: Implement** as listed. A `class Admin::X` compact line stays accepted unless Task 1 refused it, in which case `ControllerScan` raises `ArgumentError, "app/controllers/admin/x_controller.rb:1: write module Admin / class XController (Spinel cannot compile the compact class Admin::XController form)"`.
- [ ] **Step 4: Run** the two plus `spin test test/gen_controllers.rb test/gen_manifest.rb test/gen_routes_compiles.rb test/gen_runner_models.rb` (fixtures regenerated once).
- [ ] **Step 5: Gate and commit**: "Controller concerns: ActiveSupport::Concern, included and class_methods expanded into gen/concerns.rb at the include's position; the nested module form".

---

### Task 6: `helper_method`

**Files:**
- Modify: `cybertrain/generator/controller_scan.rb` (`ControllerInfo#helper_methods` (Array<String>), from `helper_method :a, :b` lines in the class and its concerns' `included` bodies; `ControllerInfo#defs` (HelperDef per `def`, parsed with `HelperScan.parse_def`)), `cybertrain/generator/controllers_emitter.rb` (per controller declaring helper methods: `def helper_method?(name) = case name when "admin?", "current_user" then true else super end` and `def call_helper_method(name, args, kwargs)` with HelpersEmitter's arity / keyword arms reaching the controller's method; a name not defined in the controller's chain or its concerns → `ArgumentError, "helper_method :admin? in Admin::ArticlesController: no def admin? in the controller, its parents or its concerns"`; a name in `HelperScan::RESERVED_HELPER_NAMES`, ending in `_path`/`_url`, or defined by an `app/helpers` module → `ArgumentError, "helper_method :link_to: link_to is a framework helper"` / `"... is defined in PricesHelper"`), `cybertrain/controller.rb` (base `helper_method?(name) = false`, `call_helper_method(name, args, kwargs) = nil` — base stubs called on `self`, not through a stored block, so rule 88 does not apply), `cybertrain/template/helpers.rb` (in `helper_call`'s `else`, after the component's view methods and before the route helpers: `return @controller.call_helper_method(name, args, kwargs) if !@controller.nil? && @controller.helper_method?(name)`), `cybertrain/generator/runner.rb` (passes the app helper names to the emitter for the clash check), `docs/api/stubs/generated_app.rb`
- Test: `test/helper_method.rb` (new, compiled, gen_app fixture: `PostsController` gains `helper_method :viewer_name, :price_label` with `def viewer_name = "ann"` and `def price_label(cents, currency: "USD")`; views under `test/fixtures/views/helper_method/`), `test/gen_controllers.rb` (grown: the refusals)

**Interfaces:**
- Consumes: Task 5's concern expansion and `Controller.helper_method`.
- Produces: `Controller#helper_method?(name) -> Boolean`, `Controller#call_helper_method(name, args, kwargs) -> Object`.

- [ ] **Step 1: Write the failing tests** ("a template calls a helper_method with positional and keyword arguments" → `"ann USD 1.50"`; "a component rendered by the template reaches it too"; "a helper_method declared in a concern's included block works"; "a helper_method named like a framework helper, an app helper, or an undefined method is refused with its message"; "a template outside a request (Views.render_partial) raises undefined helper for it").
- [ ] **Step 2: Run** `spin test test/helper_method.rb test/gen_controllers.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both plus `spin test test/app_helpers.rb test/component_render.rb test/gen_concerns.rb`.
- [ ] **Step 5: Gate and commit**: "helper_method: controller methods callable from templates and components, refused when they shadow a helper".

---

### Task 7: Model concerns (M-6)

**Files:**
- Modify: `cybertrain/generator/model_scan.rb` (`ModelScan.scan_dir` reads `app/models/concerns/**/*.rb` through `ConcernScan` and treats each expanded concern's `included` lines as model lines at the `include`: scopes, associations, `encrypts`, `validates ... uniqueness:` and `validate` lines feed `ModelInfo` as if written there; a concern's `def`s join `defined_methods` and `view_methods`), `cybertrain/generator/concerns_emitter.rb` (model reopenings: `model_concern_insert_at(validators_index)`, the spliced lines, `model_concern_insert_done`), `cybertrain/model.rb` (`Model.model_concern_insert_at(validators_index) -> nil`, `Model.model_concern_insert_done -> nil`, honoured by `validates`), `cybertrain/generator/manifest.rb` (already orders model concerns first, Task 5)
- Create fixture: `test/fixtures/gen_app/app/models/concerns/visible.rb` (`included do; validates :title, presence: true; scope :visible, -> { where(hidden: 0) }; end`; `def visible? = hidden == 0`), `test/fixtures/gen_app/app/models/post.rb` gains `include Visible` (the fixture schema gains `t.integer :hidden, default: 0, null: false`)
- Test: `test/gen_model_concerns.rb` (new, compiled with SQLite)

**Interfaces:**
- Consumes: Task 5's `ConcernScan`, `ConcernsEmitter`.
- Produces: model concern expansion; `Model.model_concern_insert_at` / `model_concern_insert_done`.

- [ ] **Step 1: Write the failing tests** ("validates from a model concern" → `Post.new.valid?` false with `title` "can't be blank"; "scope from a model concern" → `Post.visible.count`; "a concern's instance method is a view method" → `post.visible?` in a template; "a model concern included twice is expanded once"; "an unknown model concern is refused with file and line").
- [ ] **Step 2: Run** `spin test test/gen_model_concerns.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it plus `spin test test/gen_models.rb test/gen_models_compiles.rb test/gen_runner_models.rb test/validators.rb`.
- [ ] **Step 5: Gate and commit**: "Model concerns: included blocks of app/models/concerns expanded into the model as written at the include".

---

### Task 8: `respond_to`, implicit rendering by format, 406

**Files:**
- Create: `cybertrain/format_collector.rb` (`Cybertrain::FormatCollector`: `initialize(format)`; `html(&block)`, `json(&block)`, `turbo_stream(&block)`, `csv(&block)`, `xml(&block)`, `text(&block)`, `any(&block)` each returning nil; `matched_format -> Symbol` (`:none` until one matched); `matched_without_block? -> Boolean`), required by controller.rb (or the Task 1 fallback's generated collector)
- Modify: `cybertrain/controller.rb` (`respond_to(&block) -> nil`: builds the collector for `request.format`, yields it, then: nothing matched → `head_not_acceptable` (406, `text/plain; charset=utf-8`, body `"Not Acceptable"`); matched without a block → `render_template(action_name, format: matched)`; `render_template(name, locals = {}, layout: true, format: :html)` looks up `"<path>/<name>.<format>.erb"` for a non-html format (no layout for `:turbo_stream`, content type `Request.mime_type(format)`); `default_render(action)` for a non-html request format renders `<action>.<format>.erb` when it exists, else answers 406; `:html` unchanged), `cybertrain/template/engine.rb` (`exists?` / `template` accept an explicit `.turbo_stream.erb` key unchanged; the `.html.erb` default stays)
- Test: `test/controller_formats.rb` (new, compiled; hand-written controllers and templates under `test/fixtures/views/formats/`: `articles/show.html.erb`, `articles/create.turbo_stream.erb`, `articles/index.csv.erb`)

**Interfaces:**
- Consumes: Task 3's `Request#format`, `Request.mime_type`.
- Produces: `Controller#respond_to`, `FormatCollector`, `render_template(..., format:)`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "respond_to picks html, json or turbo_stream" do
  assert_equal "<p>Hello</p>", client.get("/articles/1").body.strip
  json = client.get("/articles/1.json")
  assert_equal "application/json; charset=utf-8", json.header("content-type")
  assert_equal "{\"id\":1,\"title\":\"Hello\"}", json.body
  ts = client.get("/articles/1", { "accept" => "text/vnd.turbo-stream.html, text/html" })
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", ts.header("content-type")
end
test "a format the action does not list is 406" do
  res = client.get("/articles/1.xml")
  assert_equal 406, res.status
  assert_equal "Not Acceptable", res.body
end
test "implicit rendering: create.turbo_stream.erb without a layout; index.csv.erb" do
  # POST /articles with Accept turbo-stream -> body starts with "<turbo-stream action=\"append\"", no layout markup
  # GET /articles.csv -> "text/csv; charset=utf-8", body "id,title\n1,Hello\n"
end
test "an unregistered extension reaches the action and an implicit render is 406" do
  # GET /articles/1.v2 (route /articles/:id) -> params[:id] == "1", request.format == :unknown, 406 "Not Acceptable"
end
test "json without a template and without render is 406" do
  # GET /articles.json on an action that renders nothing for json -> 406
end
test "blocks see ivars and stop at the first match" do
  # format.json { render json: @article.as_json }; format.any { render plain: "any" }: Accept json -> the json body, not "any"
end
```

- [ ] **Step 2: Run** `spin test test/controller_formats.rb`: FAIL.
- [ ] **Step 3: Implement** (with Task 1's chosen collector form).
- [ ] **Step 4: Run** it plus `spin test test/controller.rb test/controller_views.rb test/template_integration.rb`; `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "respond_to and rendering by format: the request's format picks the block or the <action>.<format>.erb template; 406 otherwise".

---

### Task 9: Per-controller layouts (V-9)

**Files:**
- Modify: `cybertrain/generator/controller_scan.rb` (`ControllerInfo#layouts` (Array of `Gen::LayoutDecl` with `layout_name` ("frame", "" for `false`), `layout_method` ("" or a method name), `layout_only`, `layout_except` (Array<String>)), from `layout "x"`, `layout false`, `layout :method`, `layout "x", only: [...]` / `except: [...]` lines in the class and its concerns), `cybertrain/generator/controllers_emitter.rb` (per controller with layouts: `def controller_layout(action) -> String`: the declarations in order, first applicable wins; a method form `chosen = frame_or_application; chosen == false ? "" : "layouts/#{chosen}"`; else `super`), `cybertrain/controller.rb` (base `controller_layout(action) = Views.layout_name`; `render_template` uses `controller_layout(@action_name)`; `render(..., layout: DEFAULT_LAYOUT)` where `DEFAULT_LAYOUT = [true, ""][0]` (boxed like DEFAULT_STATUS): `true` → the controller's layout, `false` → none, a String `"x"` → `"layouts/x"`), `docs/api/stubs/generated_app.rb`
- Test: `test/controller_views.rb` (grown), `test/gen_controllers.rb` (grown); layouts `test/fixtures/views/layouts/frame.html.erb`, `admin.html.erb`

**Interfaces:**
- Consumes: Task 5 (concerns' `layout` lines).
- Produces: `Controller#controller_layout(action) -> String` ("" = none).

- [ ] **Step 1: Write the failing tests** ("layout by name" → the `frame` layout's marker; "layout :method returning false renders bare, returning \"frame\" uses it"; "layout \"admin\", only: [:index] applies to index only"; "render layout: \"frame\" per call wins; render layout: false is bare"; "a Turbo-Frame request picks the frame layout through a two-line method"; "a layout declared in a concern applies").
- [ ] **Step 2: Run** `spin test test/controller_views.rb test/gen_controllers.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both plus `spin test test/gen_concerns.rb test/jobs_page.rb test/template_integration.rb`.
- [ ] **Step 5: Gate and commit**: "Layouts per controller: layout name, false, method, only:/except:, and render layout:".

---

### Task 10: Status symbols, `send_data`, HTTP caching (C-9, C-2, C-3)

**Files:**
- Modify: `cybertrain/controller.rb` (`STATUS_SYMBOLS` = every Rack 3 symbol: 100 `continue` to 511 `network_authentication_required` — `continue switching_protocols processing early_hints ok created accepted non_authoritative_information no_content reset_content partial_content multi_status already_reported im_used multiple_choices moved_permanently found see_other not_modified use_proxy temporary_redirect permanent_redirect bad_request unauthorized payment_required forbidden not_found method_not_allowed not_acceptable proxy_authentication_required request_timeout conflict gone length_required precondition_failed content_too_large uri_too_long unsupported_media_type range_not_satisfiable expectation_failed misdirected_request unprocessable_content locked failed_dependency too_early upgrade_required precondition_required too_many_requests request_header_fields_too_large unavailable_for_legal_reasons internal_server_error not_implemented bad_gateway service_unavailable gateway_timeout http_version_not_supported variant_also_negotiates insufficient_storage loop_detected not_extended network_authentication_required` plus the aliases `payload_too_large`, `request_entity_too_large`, `unprocessable_entity`, `request_uri_too_long`, `requested_range_not_satisfiable`; `send_data(data, filename: "", type: "application/octet-stream", disposition: "attachment", status: DEFAULT_STATUS) -> nil`; `fresh_when(etag: nil, last_modified: nil, public: false) -> nil`; `stale?(etag: nil, last_modified: nil, public: false) -> Boolean`; `expires_in(seconds, public: false) -> nil`), `cybertrain/http/response.rb` (`STATUS_TEXT` for every code above, RFC 9110 phrases; plan decision 24), `cybertrain/http/uploaded_file.rb` (`UploadedFile.content_disposition_utf8(disposition, filename) -> String`: ASCII fallback replaces each non-ASCII or control character with `?` (Rails' transliteration default), escapes `"` and `\` with a backslash; `filename*` percent-encodes every byte outside RFC 5987's attr-char; `filename: ""` writes the bare disposition), `cybertrain/http/request.rb` (`Request.http_date(time) -> String` `"%a, %d %b %Y %H:%M:%S GMT"`, `Request.parse_http_date(text) -> Integer` epoch or -1)
- Test: `test/controller_status.rb` (grown), `test/send_data.rb` (new), `test/http_caching.rb` (new), `test/http_response.rb` (grown: phrases)

**Interfaces:**
- Produces: `send_data`, `fresh_when`, `stale?`, `expires_in`, the full status table, `Request.http_date`, `Request.parse_http_date`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controller_status.rb
test "every Rack symbol, old aliases included" do
  assert_equal 402, Cybertrain::Controller.status_code(:payment_required)
  assert_equal 422, Cybertrain::Controller.status_code(:unprocessable_content)
  assert_equal 422, Cybertrain::Controller.status_code(:unprocessable_entity)
  assert_equal 451, Cybertrain::Controller.status_code(:unavailable_for_legal_reasons)
  assert_equal "Unprocessable Content", Cybertrain::Response.status_text(422)
end
# test/send_data.rb
test "send_data writes RFC 6266 Content-Disposition" do
  # send_data "a,b\n", filename: "résumé.csv", type: "text/csv"
  # -> 200, content-type "text/csv", content-disposition "attachment; filename=\"r?sum?.csv\"; filename*=UTF-8''r%C3%A9sum%C3%A9.csv"
  # disposition: "inline", filename: "a \"b\".txt" -> "inline; filename=\"a \\\"b\\\".txt\"; filename*=UTF-8''a%20%22b%22.txt"
  # no filename -> "attachment"
end
# test/http_caching.rb
test "fresh_when answers 304 to a matching If-None-Match" do
  # etag: "v1" -> ETag W/"<first 32 hex of SHA-256 of \"v1\">"; replay with if-none-match: that value -> 304, empty body
  # etag: @post -> computed from "posts/#{to_param}-#{updated_at.to_i}"; a list "\"x\", W/\"…\"" and "*" both match
end
test "If-Modified-Since and stale?" do
  # last_modified: t -> Last-Modified Request.http_date(t); if-modified-since >= t -> 304; earlier -> 200 and stale? true
  # an unparseable If-Modified-Since -> 200
end
test "Cache-Control from fresh_when and expires_in" do
  # fresh_when -> "max-age=0, private, must-revalidate"; public: true -> "max-age=0, public, must-revalidate"
  # expires_in 300 -> "max-age=300, private"; public: true -> "max-age=300, public"; expires_in then fresh_when keeps expires_in's
end
```

- [ ] **Step 2: Run** `spin test test/controller_status.rb test/send_data.rb test/http_caching.rb test/http_response.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them plus `spin test test/send_blob.rb test/client.rb test/error_pages.rb`; regen snapshots whose phrase changed (422/413 only).
- [ ] **Step 5: Gate and commit**: "Controllers: every Rack status symbol, send_data with RFC 6266 filenames, fresh_when / stale? / expires_in".

---

### Task 11: `params.expect` and nested `permit` (C-1) — group P1

**Files:**
- Modify: `cybertrain/params.rb` (`permit(*keys) -> Hash{String => Object}`: a Symbol/String key permits a scalar; `key: []` permits a list of Strings; `key: [:a, :b]` permits a nested Params by the same rules; Ruby collects the trailing `tags: [], meta: [:source]` into one Hash argument, so the signature stays `permit(*keys)`; `expect(spec) -> Hash{String => Object}` where `spec` is `{ article: [:title, tags: []] }` (one key): missing key, an empty nested value, or a value of the wrong shape (a String where a nested Hash is expected, a nested Hash where a list is) raises `ParameterMissing, "param is missing or the value is empty or invalid: article"`; a bare Symbol (`expect(:id)`) returns `{ "id" => "3" }`, a Hash like every other call (one return type), and raises the same message for a missing or non-String value), `cybertrain/time_zone.rb` (private `expect(byte)` renamed `expect_byte`)
- Test: `test/params.rb` (grown), `test/time_zone.rb` (re-run only)

**Interfaces:**
- Produces: `Params#expect(spec) -> Hash{String => Object}`, `Params#permit(*keys) -> Hash{String => Object}`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "expect returns the permitted shape" do
  p = params_from("article[title]=Hi&article[tags][]=a&article[tags][]=b&article[meta][source]=rss&article[admin]=1")
  h = p.expect(article: [:title, tags: [], meta: [:source]])
  assert_equal "Hi", h["title"]
  assert_equal ["a", "b"], h["tags"]
  assert_equal({ "source" => "rss" }, h["meta"])
  refute h.key?("admin")
end
test "expect raises 400's ParameterMissing for a missing key or a wrong shape" do
  assert_raises("ParameterMissing") { params_from("x=1").expect(article: [:title]) }
  assert_raises("ParameterMissing") { params_from("article=flat").expect(article: [:title]) }
  assert_raises("ParameterMissing") { params_from("article[title][]=x").expect(article: [meta: [:source]]) }
  msg = assert_raises("ParameterMissing") { params_from("").expect(article: [:title]) }
  assert_equal "param is missing or the value is empty or invalid: article", msg
end
test "require(...).permit gains the nested and array forms" do
  h = params_from("post[title]=T&post[ids][]=1").require(:post).permit(:title, ids: [])
  assert_equal ["1"], h["ids"]
end
test "a list sent where a scalar is permitted is dropped, not coerced" do
  assert_equal({}, params_from("post[title][]=x").require(:post).permit(:title))
end
```

- [ ] **Step 2: Run** `spin test test/params.rb`: FAIL.
- [ ] **Step 3: Implement**; `ruby script/check-reserved-names` (green against Task 1's rows).
- [ ] **Step 4: Run** `spin test test/params.rb test/time_zone.rb test/controller.rb test/cli_scaffold.rb test/params_limits.rb`.
- [ ] **Step 5: Gate and commit**: "params.expect and nested permit: lists and nested hashes, 400 on a missing or misshapen key".

---

### Task 12: openssl in every program, the encrypted session, the cookie jar (5.1, C-7, C-8) — group P2

**Files:**
- Create: `cybertrain/cookie_jar.rb` (`Cybertrain::CookieJar`: `initialize(request_cookies, response)`; `[](name) -> String?`; `[]=(name, value)` (a String, or a Hash with `value:`, `expires:` (Time), `max_age:` (Integer), `path:` ("/"), `httponly:` (true), `secure:` (Config#session_secure), `same_site:` ("Lax")); `delete(name, path: "/") -> String?` (writes `Max-Age=0`); `permanent -> PermanentCookieJar`; `signed -> SignedCookieJar`; `encrypted -> EncryptedCookieJar`; each view jar has `[]`, `[]=`, `delete` and (permanent) `signed` / `encrypted`; signed value `"<urlsafe base64>--<64 hex HMAC>"` under `Crypto.derive_key(secret, "cybertrain signed cookie")`, a bad signature reads nil; encrypted value `Encryptor#seal_bytes` under `Crypto.derive_key(secret, "cybertrain encrypted cookie")` with AAD `"cookie:#{name}"`, a bad value reads nil)
- Modify: `cybertrain.rb` (`require "cybertrain/encryptor"`, `require "cybertrain/cookie_jar"`), `cybertrain/encryptor.rb` (header comment: loaded by every program now; `Encryptor#seal_bytes(text, aad) -> String` raw `nonce + ciphertext + tag`; `Encryptor#open_bytes(raw, aad) -> String?` nil when nothing authenticates; `encrypt` / `decrypt` unchanged), `cybertrain/crypto.rb` (`Crypto.derive_key(secret, label) -> String` 32 raw bytes; header comment amended), `cybertrain/session.rb` (`Session.load(cookie_value, key)` / `Session.dump(session, key)` take the derived session key (32 bytes); payload `Base64.urlsafe_encode64(seal_bytes(JSON, "session"), padding: false)`; anything that does not decode, authenticate or parse — a 0.4 signed cookie included — loads as `Session.new`; a cookie value over 4096 bytes loads empty without decrypting; `Session::CookieOverflow < StandardError`), `cybertrain/middleware/session_store.rb` (derives the key once from `secret:`; builds `ctx.cookie_jar = CookieJar.new(parsed, ctx.response)` from the cookies it already parses; raises `Session::CookieOverflow, "session cookie is #{n} bytes, over the 4096 a browser keeps (store less in the session)"` when `name=value` would exceed 4096 bytes), `cybertrain/context.rb` (`attr_accessor :cookie_jar`), `cybertrain/controller.rb` (`cookies -> CookieJar`: `ctx.cookie_jar`, or a jar over `request.cookie_header` when the middleware is absent), `cybertrain/http/response.rb` (`replace_cookie(name, set_cookie) -> nil`: drops earlier Set-Cookie values starting `"#{name}="`), `cybertrain/http/cookies.rb` (`serialize(..., expires: nil)` writes `Expires=<Request.http_date>` for a Time), `cybertrain/generator/manifest.rb` (no longer emits `require "cybertrain/encryptor"`; keeps `Config.encryption_required = true`), every byte scanner rule 62 flags (fresh local)
- Test: `test/session.rb` (rewritten cases: encrypted round trip), `test/cookie_jar.rb` (new), `test/openssl_dispatch.rb` (grown: a full-stack session round trip in the program that requires openssl), `test/csrf_chain.rb`, `test/flash.rb`, `test/gen_manifest.rb` (re-run; snapshots regenerated)

**Interfaces:**
- Consumes: Task 10's `Request.http_date`.
- Produces: `Controller#cookies -> CookieJar`, `CookieJar` and its views, `Crypto.derive_key`, `Encryptor#seal_bytes` / `#open_bytes`, `Session::CookieOverflow`, `Response#replace_cookie`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/session.rb
test "the session cookie is encrypted and round-trips" do
  key = Cybertrain::Crypto.derive_key("s" * 64, "cybertrain session")
  s = Cybertrain::Session.new; s[:user_id] = 5
  value = Cybertrain::Session.dump(s, key)
  refute value.include?("user_id")
  refute Base64.urlsafe_decode64(value + "=" * ((4 - value.size % 4) % 4)).include?("user_id")
  assert_equal "5", Cybertrain::Session.load(value, key)[:user_id]
end
test "foreign and damaged session cookies load empty" do
  # one flipped character; truncated to 20 bytes; a 0.4 "<b64>--<hmac>" cookie; a value from cookies.encrypted[:x];
  # a 5000-byte value; the right value under another secret -> each Session.load(...).keys == []
end
test "a session larger than a cookie is refused at write" do
  # SessionStore with session["blob"] = "x" * 5000 -> raises Session::CookieOverflow with the message above
end
# test/cookie_jar.rb (through Test::Client and a controller)
test "plain, permanent, signed and encrypted cookies" do
  # cookies[:theme] = "dark" -> Set-Cookie "theme=dark; Path=/; HttpOnly; SameSite=Lax"; next request reads "dark"
  # cookies[:theme] = { value: "x", expires: Time.utc(2030,1,1), httponly: false } -> "Expires=Tue, 01 Jan 2030 00:00:00 GMT", no HttpOnly
  # cookies.permanent[:p] = "1" -> "Max-Age=631139040"; cookies.delete(:theme) -> "theme=; Path=/; ... Max-Age=0"
  # cookies.signed[:uid] = "7" -> readable as "7"; tampered -> nil; cookies.encrypted[:card] = "4242" -> value lacks "4242", reads back "4242"
  # an encrypted value copied to another cookie name reads nil; two writes of one name leave one Set-Cookie
end
```

- [ ] **Step 2: Run** `spin test test/session.rb test/cookie_jar.rb test/openssl_dispatch.rb`: FAIL.
- [ ] **Step 3: Implement**; then compile test/application.rb's program to C (`spinel $(spin flags) test/application.rb -c -o /tmp/app.c`) and grep both rule-62 patterns; narrow each flagged method with a fresh local until both counts are 0; record the count found in the commit body.
- [ ] **Step 4: Run** the three plus `spin test test/csrf.rb test/csrf_chain.rb test/csrf_conditional.rb test/flash.rb test/application.rb test/encryptor.rb test/boot_encryption.rb test/gen_manifest.rb test/cli_authentication.rb`; regen their snapshots.
- [ ] **Step 5: Gate and commit**: "Encrypted session (AES-256-GCM, key from secret_key_base) and the cookie jar (plain, permanent, signed, encrypted); openssl in every program".

---

### Task 13: `rate_limit` options and the shared store (C-4)

**Files:**
- Modify: `cybertrain/controller.rb` (`Controller.rate_limit(to:, within:, only: [], except: [], by: :client_ip, with: nil, if: nil, unless: nil, name: "", store: :cache, redirect_to: "", alert: "")`: `by:` `:client_ip` / `:remote_addr` or a method name; `with:` a method that answers instead of the 429; `if:` / `unless:` method names; `store: :cache` (default) or `:memory`; anything else `ArgumentError, "rate_limit store: must be :cache or :memory (got :redis)"`; `apply_rate_limit` builds plan decision 17's key, counts through `Cache.increment` (`:memory` keeps `RateLimit#hit`), and when over: `run_callback(with)` if given, else today's 429 / redirect; base stubs `rate_limit_key(name) -> String` and `rate_limit_condition?(name) -> Boolean` raising `UnknownCallback`), `cybertrain/rate_limit.rb` (holds the declaration's `by_method`, `with_method`, `if_method`, `unless_method`, `limit_name`, `memory_store?`; header comment: counts shared through the cache by default), `cybertrain/generator/controller_scan.rb` (picks up `by:`, `with:`, `if:`, `unless:` Symbols of `rate_limit` lines: `with:` names join the `run_callback` list; `by:` and condition names are recorded separately), `cybertrain/generator/controllers_emitter.rb` (`def rate_limit_key(name) = case name when :user_key then user_key.to_s ... else super end` and `def rate_limit_condition?(name)` likewise with `!!`), `cybertrain.rb` (`require "cybertrain/cache"`: the default store needs it), `docs/api/stubs/generated_app.rb`
- Test: `test/rate_limit.rb` (grown), `test/rate_limit_store.rb` (new, compiled with SQLite: two processes)

**Interfaces:**
- Consumes: `Cache.increment(key, by:, expires_in:)` (phase 3), Task 5's scan.
- Produces: the new `rate_limit` keywords, `rate_limit_key`, `rate_limit_condition?`.

- [ ] **Step 1: Write the failing tests** ("by: a method keys the count by its value" → two users each get `to` requests; "with: answers instead of 429" → the method's `render plain: "slow down", status: :too_many_requests`; "if: false skips the limit; unless: true skips it"; "two limits with name: on one action count apart"; "store: :memory keeps the per-process counter"; "Retry-After is the rest of the aligned window" with `Cache.clock` pinned; test/rate_limit_store.rb "the count is shared across two processes": the program, run with `RATE_LIMIT_CHILD=1`, makes two requests and exits; the parent spawns `build/test/rate_limit_store` with that variable through `Process.spawn` / `Process.wait` (rule 75), then makes `to - 1` requests and gets a 429 on the next).
- [ ] **Step 2: Run** `spin test test/rate_limit.rb test/rate_limit_store.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both plus `spin test test/cache.rb test/gen_controllers.rb test/cli_authentication.rb`.
- [ ] **Step 5: Gate and commit**: "rate_limit: by:, with:, if:/unless:, name:, counts shared through the cache (store: :memory for the old counter)".

---

### Task 14: Content Security Policy, `Permissions-Policy`, `force_ssl`, host checks (C-5, C-11, §10)

**Files:**
- Create: `cybertrain/content_security_policy.rb` (`Cybertrain::ContentSecurityPolicy`: one method per directive — `default_src script_src style_src img_src font_src connect_src media_src object_src frame_src frame_ancestors child_src worker_src manifest_src base_uri form_action report_uri` — each `(*sources) -> nil`; Symbols `:self`, `:none`, `:unsafe_inline`, `:unsafe_eval`, `:strict_dynamic`, `:report_sample` → `'self'` etc., `:data`, `:https`, `:blob`, `:ws`, `:wss` → `data:` etc., Strings as written; `header_value(nonce, nonce_directives) -> String` (directives in declaration order joined `"; "`, `'nonce-<n>'` appended to each listed nonce directive); `dup_policy -> ContentSecurityPolicy`), `cybertrain/middleware/content_security_policy_header.rb` (`ContentSecurityPolicyHeader < Middleware`: after the app, unless the response already has a CSP header (send_blob's), writes `Content-Security-Policy` (or `-Report-Only`) from `ctx.csp_policy || app policy` with `ctx.csp_nonce` when nonce directives are set), `cybertrain/middleware/ssl_redirect.rb` (`SslRedirect < Middleware`: plan decision 21; redirect target `https://#{host}#{path}#{?query}`), `test/fixtures/views/csp/*`
- Modify: `cybertrain/config.rb` (`content_security_policy(&block) -> nil` (builds and yields a policy, keeps it in `@content_security_policy`), `content_security_policy_value -> ContentSecurityPolicy?`, `attr_accessor :content_security_policy_report_only` (false), `:content_security_policy_nonce_directives` (`Array<String>`, seeded empty), `:permissions_policy` (`"camera=(), microphone=(), geolocation=()"`), `:force_ssl` (`CYBERTRAIN_FORCE_SSL`, `"1"`/`"true"` → true), `hosts_from_env` (`CYBERTRAIN_HOSTS` entries, also appended to `allowed_hosts`), `host_check? -> Boolean`; boot errors: `"CYBERTRAIN_FORCE_SSL must be 1, true, 0, false or empty (got \"yes\")"`, `"content_security_policy_nonce_directives: \"scripts-src\" is not a directive"`, `"CYBERTRAIN_HOSTS: \"https://x\" is not a host name (no scheme, path or wildcard)"`), `cybertrain/controller.rb` (`Controller.content_security_policy(&block) -> nil`: copies the app policy, yields it, stores it by class name; `Controller.policy_for(klass)` walks the chain; `process` sets `ctx.csp_policy`), `cybertrain/context.rb` (`csp_policy`, `csp_nonce` (lazy: `Base64.strict_encode64(SecureRandom.random_bytes(16))`)), `cybertrain/http/response.rb` (`Response.default_permissions_policy` / `=`; `to_http` and `to_http_head` add `Permissions-Policy` unless set or empty), `cybertrain/middleware/host_authorization.rb` (`initialize(app, allowed_hosts, exempt_path = "")`: the exempt path passes whatever the host), `cybertrain/application.rb` (`build_stack`: HostAuthorization when `c.host_check?` (health path exempt), SslRedirect when `c.force_ssl` inside it, ContentSecurityPolicyHeader inside RequestLogger; boot installs `Response.default_permissions_policy`; `front_app`'s development wrapper passes the exempt path), `cybertrain/template/helpers.rb` (`csp_meta_tag` → `<meta name="csp-nonce" content="NONCE">` ("" without a policy); `javascript_tag(nonce: true) { }` → `<script nonce="NONCE">…</script>`; `content_security_policy_nonce` → the nonce), `cybertrain/generator/helper_scan.rb` (`RESERVED_HELPER_NAMES` += `csp_meta_tag javascript_tag content_security_policy_nonce`)
- Test: `test/csp.rb` (new), `test/host_authorization.rb` (grown), `test/force_ssl.rb` (new), `test/http_response.rb` (grown), `test/config_settings.rb` (grown)

**Interfaces:**
- Produces: `Config#content_security_policy`, the nonce helpers, `Context#csp_nonce`, `Config#force_ssl`, `Config#host_check?`, `Config#permissions_policy`, `Response.default_permissions_policy`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/csp.rb
test "the policy is written per response with a fresh nonce" do
  # config: default_src :self; script_src :self, "https://cdn.jsdelivr.net"; style_src :self; nonce dirs %w[script-src style-src]
  # header == "default-src 'self'; script-src 'self' https://cdn.jsdelivr.net 'nonce-N'; style-src 'self' 'nonce-N'"
  # two requests -> two different N; <%= csp_meta_tag %> and <%= javascript_tag(nonce: true) do %>x<% end %> carry the same N
end
test "report-only, off by default, and a controller's own policy" do
  # report_only -> header name Content-Security-Policy-Report-Only; no config -> no header
  # class EmbedController: content_security_policy { |p| p.frame_ancestors "https://a.example" } -> that directive added for its actions only
end
# test/force_ssl.rb
test "force_ssl redirects http and sends HSTS" do
  # GET http://example.com/a?b=1 -> 301 Location https://example.com/a?b=1; POST -> 307
  # x-forwarded-proto: https -> 200 with Strict-Transport-Security "max-age=63072000; includeSubDomains"; GET /up over http -> 200
end
# test/host_authorization.rb
test "CYBERTRAIN_HOSTS turns the check on outside development; the health path is exempt" do
  # production config with hosts_from_env ["app.example"]: Host app.example -> 200, evil.example -> 403 "Blocked host", evil.example GET /up -> 200
  # production without CYBERTRAIN_HOSTS -> no check; development keeps checking every path but /up
end
# test/http_response.rb
test "Permissions-Policy is a default header" do
  # to_http includes "Permissions-Policy: camera=(), microphone=(), geolocation=()"; set_header wins; "" sends none
end
```

- [ ] **Step 2: Run** `spin test test/csp.rb test/force_ssl.rb test/host_authorization.rb test/http_response.rb test/config_settings.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them plus `spin test test/application.rb test/health.rb test/send_blob.rb test/dev_application.rb test/stream_endpoint.rb`.
- [ ] **Step 5: Gate and commit**: "CSP with nonces, Permissions-Policy by default, force_ssl with HSTS, host checks from CYBERTRAIN_HOSTS with the health path exempt".

---

### Task 15: `Cybertrain::NumberHelper` (V-6) — group P1

**Files:**
- Create: `cybertrain/number_helper.rb` (`module Cybertrain::NumberHelper` with module functions `number_with_precision(number, precision: 3, delimiter: "", separator: ".", strip_insignificant_zeros: false) -> String`, `number_with_delimiter(number, delimiter: ",", separator: ".") -> String`, `number_to_human(number, precision: 3, units: {}) -> String` (significant digits, insignificant zeros stripped, units `Thousand Million Billion Trillion Quadrillion`; `units:` keys `:unit :thousand :million :billion :trillion :quadrillion`), `number_to_percentage(number, precision: 3) -> String`, `number_to_currency(number, unit: "$", precision: 2, format: "%u%n") -> String` (a negative number formats `"-%u%n"`), `number_to_human_size(number) -> String` (base 1024, 3 significant digits, `Byte`/`Bytes KB MB GB TB PB EB`); accepted inputs plan decision 27; anything else `ArgumentError, "number_to_currency: \"abc\" is not a number"`)
- Modify: `cybertrain.rb` (require it), `cybertrain/template/helpers.rb` (`helper_call` arms for the six names, keywords checked with `helper_keywords!`; the existing `number_with_delimiter(args)` delegates), `cybertrain/generator/helper_scan.rb` (`RESERVED_HELPER_NAMES` += the five new names)
- Test: `test/number_helper.rb` (new, CRuby-runnable), `test/helpers.rb` (grown: template calls)

**Interfaces:**
- Produces: `Cybertrain::NumberHelper.*` (Ruby) and the six template helpers.

- [ ] **Step 1: Write the failing tests** (Rails' documented examples):

```ruby
N = Cybertrain::NumberHelper
test "number_with_precision" do
  assert_equal "111.235", N.number_with_precision(111.2345)
  assert_equal "111.23", N.number_with_precision(111.2345, precision: 2)
  assert_equal "13.00000", N.number_with_precision(13, precision: 5)
  assert_equal "389", N.number_with_precision(389.32314, precision: 0)
  assert_equal "13", N.number_with_precision(13, precision: 5, strip_insignificant_zeros: true)
  assert_equal "1.111,23", N.number_with_precision(1111.2345, precision: 2, separator: ",", delimiter: ".")
end
test "number_with_delimiter" do
  assert_equal "12,345,678", N.number_with_delimiter(12345678)
  assert_equal "123,456", N.number_with_delimiter("123456")
  assert_equal "12,345,678.05", N.number_with_delimiter(12345678.05)
  assert_equal "12.345.678", N.number_with_delimiter(12345678, delimiter: ".")
  assert_equal "98 765 432,98", N.number_with_delimiter(98765432.98, delimiter: " ", separator: ",")
end
test "number_to_human" do
  assert_equal "123", N.number_to_human(123)
  assert_equal "1.23 Thousand", N.number_to_human(1234)
  assert_equal "12.3 Thousand", N.number_to_human(12345)
  assert_equal "1.23 Million", N.number_to_human(1234567)
  assert_equal "1.23 Billion", N.number_to_human(1234567890)
  assert_equal "1.23 Trillion", N.number_to_human(1234567890123)
  assert_equal "1.23 Quadrillion", N.number_to_human(1234567890123456)
  assert_equal "1230 Quadrillion", N.number_to_human(1234567890123456789)
  assert_equal "490 Thousand", N.number_to_human(489939, precision: 2)
  assert_equal "489.9 Thousand", N.number_to_human(489939, precision: 4)
  assert_equal "500 lt", N.number_to_human(500000, units: { unit: "ml", thousand: "lt" })
end
test "number_to_percentage" do
  assert_equal "100.000%", N.number_to_percentage(100)
  assert_equal "100%", N.number_to_percentage(100, precision: 0)
  assert_equal "302.24399%", N.number_to_percentage(302.24398923423, precision: 5)
end
test "number_to_currency" do
  assert_equal "$1,234,567,890.50", N.number_to_currency(1234567890.50)
  assert_equal "$1,234,567,890.51", N.number_to_currency(1234567890.506)
  assert_equal "$1,234,567,890.506", N.number_to_currency(1234567890.506, precision: 3)
  assert_equal "-$1,234,567,890.50", N.number_to_currency(-1234567890.50)
  assert_equal "1,234,567,890.50 €", N.number_to_currency(1234567890.50, unit: "€", format: "%n %u")
end
test "number_to_human_size" do
  assert_equal "1 Byte", N.number_to_human_size(1)
  assert_equal "123 Bytes", N.number_to_human_size(123)
  assert_equal "1.21 KB", N.number_to_human_size(1234)
  assert_equal "12.1 KB", N.number_to_human_size(12345)
  assert_equal "1.18 MB", N.number_to_human_size(1234567)
  assert_equal "1.15 GB", N.number_to_human_size(1234567890)
  assert_equal "1.12 TB", N.number_to_human_size(1234567890123)
  assert_equal "1.1 PB", N.number_to_human_size(1234567890123456)
  assert_equal "1.07 EB", N.number_to_human_size(1234567890123456789)
end
```

- [ ] **Step 2: Run** `ruby -I. test/number_helper.rb` and `spin test test/number_helper.rb`: FAIL.
- [ ] **Step 3: Implement** with this rounding (the one algorithm the tests do not determine): take the digits of `Float#to_s` (expanding an `e+NN` / `e-NN` form) or of `Integer#to_s`; round half up at the wanted decimal place on those digits; for significant precision, locate the first non-zero digit first; never compute with `Float#round`.
- [ ] **Step 4: Run** both runtimes plus `spin test test/helpers.rb`; `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "NumberHelper: precision, delimiter, human, percentage, currency and human size, from Ruby and templates".

---

### Task 16: Forms (V-7) — group P2

**Files:**
- Modify: `cybertrain/template/form_builder.rb` (`initialize(model, scope = "")`; `call_method` arms `select`, `collection_select`, `radio_button`, `datetime_local_field`, `time_field`, `range_field`, `color_field`, `search_field`, `telephone_field` (`type="tel"`), `url_field`; `check_box(..., include_hidden: false)`; `select(:field, choices, include_blank:, prompt:, selected:, disabled:, multiple:)` — choices an Array of values, of `[label, value]` pairs or a Hash `{ "Group" => [...] }` (`<optgroup label="Group">`); `multiple: true` names `article[tags][]`, adds `multiple="multiple"` and a leading hidden `""`; `collection_select(:field, records, :value_method, :label_method)` reads each through `read_attribute`, else `call_view_method`, else `ArgumentError, "collection_select: Article has no attribute or view method 'nope'"`), `cybertrain/template/helpers.rb` (`form_with` gains `scope:` (name prefix; with `model:` it replaces the model's), `model: [:admin, @article]` (namespaced action through `nested_url`, field names from the last record), `local:` accepted; standalone `select_tag(name, option_tags, include_blank:, prompt:, multiple:)`, `options_for_select(container, selected = nil)`, `options_from_collection_for_select(collection, value_method, text_method, selected = nil)`, `label_tag(name, text = nil)`, `text_field_tag(name, value = nil, **attrs → kwargs)`, `hidden_field_tag(name, value)`, `submit_tag(value = "Save changes")`), `cybertrain/generator/helper_scan.rb` (`RESERVED_HELPER_NAMES` += the seven)
- Test: `test/form_builder.rb` (grown), `test/form_tags.rb` (new)

**Interfaces:**
- Produces: the builder fields and the standalone tag helpers.

- [ ] **Step 1: Write the failing tests** (exact HTML):

```ruby
test "select with values, pairs, groups, blank, prompt, selected, disabled" do
  assert_equal "<select name=\"article[status]\" id=\"article_status\"><option value=\"draft\">draft</option>\n<option selected=\"selected\" value=\"published\">published</option></select>",
               field(article(status: "published"), :select, [:status, ["draft", "published"]])
  # pairs [["Draft", "d"]] -> <option value="d">Draft</option>; include_blank: true -> leading <option value="" label=" "></option>
  # prompt: "Pick" -> leading <option value="">Pick</option>; disabled: "d" -> disabled="disabled"; a Hash -> <optgroup label="G">…</optgroup>
  # multiple: true -> <input name="article[tags][]" type="hidden" value="" autocomplete="off"><select name="article[tags][]" id="article_tags" multiple="multiple">
end
test "radio_button, check_box include_hidden: false, the new input types" do
  # radio_button(:status, "draft") on status "draft" -> <input type="radio" name="article[status]" id="article_status_draft" value="draft" checked="checked">
  # check_box(:published, include_hidden: false) -> no hidden input; telephone_field -> type="tel"; datetime_local_field -> type="datetime-local"
end
test "form_with scope: and a namespaced model" do
  # form_with(url: "/search", scope: :q) + f.text_field(:term) -> name="q[term]" id="q_term"
  # form_with(model: [:admin, @article]) -> action="/admin/articles/3", hidden _method patch, name="article[title]"
end
# test/form_tags.rb: select_tag("order", options_for_select([["Newest", "new"], ["Oldest", "old"]], "old"))
#   -> <select name="order" id="order"><option value="new">Newest</option>\n<option selected="selected" value="old">Oldest</option></select>
# options_from_collection_for_select(@authors, :id, :name, 2); label_tag(:term) -> <label for="term">Term</label>
# text_field_tag(:term, "x", placeholder: "Search") -> <input type="text" name="term" id="term" value="x" placeholder="Search">
# hidden_field_tag(:t, "1"); submit_tag -> <input type="submit" name="commit" value="Save changes">
```

- [ ] **Step 2: Run** `spin test test/form_builder.rb test/form_tags.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both plus `spin test test/helpers.rb test/cli_scaffold_views.rb test/template_integration.rb`.
- [ ] **Step 5: Gate and commit**: "Forms: select, collection_select, radio buttons, the remaining field types, form_with scope: and namespaced models, the standalone tag helpers".

---

### Task 17: Turbo helpers, `time_tag`, `current_page?`, collections (V-10, V-11, V-13)

**Files:**
- Create: `cybertrain/template/turbo_stream_builder.rb` (`Template::TurboStreamBuilder`: `initialize(helpers, interp, env)`; `call_method(name_sym, args, kwargs) -> SafeString` for `replace update append prepend before after remove` with `(target, partial:, locals:, html:)` — exactly one of a block, `partial:`, `html:` for all but `remove`), `cybertrain/turbo_stream_renderer.rb` (`Cybertrain::TurboStreams`: the controller-side builder `replace(target, partial: "", locals: {}, html: nil) -> SafeString` etc., rendering partials through the controller's helpers)
- Modify: `cybertrain/template/helpers.rb` (`turbo_frame_tag(id_or_record, src:, loading:, target:)` with a block → `<turbo-frame id="article_3" src="/x" loading="lazy" target="_top">…</turbo-frame>` (attributes only when given); `turbo_stream` → the builder (`call_object_method` routes `TurboStreamBuilder` receivers); `time_tag(time, text = nil, format:)` → `<time datetime="2026-11-10T12:00:00Z">Tue, 10 Nov 2026 12:00:00 +0000</time>` (a Date: `datetime="2026-11-10"`, text `2026-11-10`; `format: :short` `"%d %b %H:%M"`, `:long` `"%B %d, %Y %H:%M"`, a String is a strftime pattern); `current_page?(path)` (GET/HEAD only; compares the request path, and the query too when the argument has one); `render partial:, collection:, as:, spacer_template:` and `render @records` (partial `<route key>/<singular>`; locals `<as>` and `<as>_counter` from 0; spacer rendered between items; an empty collection renders `""`); `render component: "comment", collection: @comments` (each item as the component's collection keyword, `comment_counter:` when declared)), `cybertrain/controller.rb` (`turbo_stream -> TurboStreams`; `render(turbo_stream: …)` — a SafeString or an Array of them, joined, content type `text/vnd.turbo-stream.html; charset=utf-8`), `cybertrain/generator/components_emitter.rb` (`def self.with_collection(items) -> Cybertrain::ComponentCollection` for a component whose only required keyword is named after it), `cybertrain/component.rb` (`Cybertrain::ComponentCollection` with `render_collection_with(helpers, interp) -> SafeString`), `cybertrain/views.rb` (`Views.render_component` accepts a ComponentCollection), `cybertrain/generator/helper_scan.rb` (`RESERVED_HELPER_NAMES` += `turbo_frame_tag turbo_stream time_tag current_page?`)
- Test: `test/turbo_helpers.rb` (new), `test/collections.rb` (new), `test/helpers.rb` (grown: time_tag, current_page?), `test/component_render.rb` and `test/gen_components.rb` (grown)

**Interfaces:**
- Consumes: Task 8's turbo_stream format.
- Produces: the template helpers above, `Controller#turbo_stream`, `render turbo_stream:`, `Klass.with_collection`.

- [ ] **Step 1: Write the failing tests** ("turbo_frame_tag with a record and options"; "turbo_stream.replace with partial and locals, append with html:, remove(target)" → `<turbo-stream action="remove" target="comment_7"></turbo-stream>`; "render turbo_stream: [..] in a controller sets the content type"; "time_tag for Time, Date, text and format:"; "current_page? path only, with query, false on POST"; "render partial: collection: with as:, counter and spacer" → `"<li>0 a</li><hr><li>1 b</li>"`; "render @comments picks comments/_comment"; "CommentComponent.with_collection(items) and render component: collection:").
- [ ] **Step 2: Run** `spin test test/turbo_helpers.rb test/collections.rb test/helpers.rb test/component_render.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them plus `spin test test/turbo.rb test/gen_components.rb test/views_detached.rb test/template_blocks.rb`.
- [ ] **Step 5: Gate and commit**: "Views: Turbo frame and stream helpers, render turbo_stream:, time_tag, current_page?, partial and component collections".

---

### Task 18: Assets in gen — digests, CSS `url()`, retention, import map (A-1, A-5) — group P1

**Files:**
- Create: `cybertrain/generator/asset_scan.rb` (`Gen::AssetFile` (`logical_path`, `source_path`, `asset_digest` (8 hex), `digested_path`); `AssetScan.scan(root) -> Array<AssetFile>` over `app/assets/*/` (each subdirectory a root), `app/javascript`, `vendor/javascript`, dotfiles and `.keep` skipped, plan decision 29's refusal `ArgumentError, "asset application.js is both app/javascript/application.js and vendor/javascript/application.js"`; `AssetScan.digested_name(logical, digest) -> String` (`logo.svg` → `logo-1a2b3c4d.svg`, `app.js.map` → `app-1a2b3c4d.js.map`, `LICENSE` → `LICENSE-1a2b3c4d`); `AssetScan.rewrite_css(css, css_logical, files) -> [String, Array<String>]` (the rewritten CSS and its warnings): each `url(...)` (quoted or not) whose target is not `data:`, `http:`, `https:`, `//`, `#` or `%23` is resolved against the CSS file's directory (a leading `/` against the roots), its `?…` / `#…` suffix kept, and replaced by `/assets/<digested>`; an unknown target stays as written with the warning `"warning: app/assets/stylesheets/application.css: url(missing.png) is not an asset; left as written"`; CSS digests are computed after rewriting, CSS files in dependency order, a cycle `ArgumentError, "CSS url() cycle: a.css -> b.css -> a.css"`), `cybertrain/generator/importmap_reader.rb` (`Gen::ImportmapPin` (`pin_name`, `pin_target` (logical path or URL), `pin_preload`); `ImportmapReader.read(text, files) -> Array<ImportmapPin>`: lines `pin "name"`, `pin "name", to: "x", preload: false`, `pin_all_from "app/javascript/controllers", under: "controllers", preload: true`; any other code line `ArgumentError, "config/importmap.rb:4: only pin and pin_all_from lines are read"`; a `to:` logical path not in the assets `ArgumentError, "config/importmap.rb:2: pin \"x\": x.js is not an asset"`), `cybertrain/generator/assets_emitter.rb` (`AssetsEmitter.emit(files, pins) -> String` for `gen/assets.rb`: `require "cybertrain/assets"`, then `module Gen::Assets` with `def self.digest_path(logical)` (a `case` returning `"/assets/<digested>"`, `""` unknown), `def self.importmap_json` (compact JSON, pins in order, `</` written `\u003c/`), `def self.preload_paths` (Array<String>), `def self.resolver = ->(name) { digest_path(name) }`, and `Cybertrain::Assets.install(Gen::Assets.resolver, Gen::Assets.importmap_json, Gen::Assets.preload_paths)` at the end; `AssetsEmitter.sync_public(root, files) -> Array<String>` (writes `public/assets/<digested>` (rewritten content for CSS), reads and rewrites `public/assets/.manifest` (`<logical> <current> <previous> <previous>` per line), keeps 3 versions per logical path and deletes older digested files it lists; returns the log lines))
- Modify: `cybertrain/generator/runner.rb` (`gen/assets.rb` output; `sync_public` only when not `--check`; `--check` compares `gen/assets.rb` only), `cybertrain/generator/manifest.rb` (`require_relative "assets"` after `routes`), `cybertrain/dev.rb` (`WATCHED` += `"app/assets/**/*"`, `"app/javascript/**/*"`, `"vendor/javascript/**/*"`; `config/importmap.rb` is already under `config/**/*.rb`)
- Create: `cybertrain/assets.rb` (runtime: `Cybertrain::Assets.install(resolver, importmap_json, preload_paths) -> nil` and the readers Task 19 uses; an application with no assets gets an empty table)
- Test: `test/gen_assets.rb` (new, compiled; fixture `test/fixtures/assets_app/` with `app/assets/stylesheets/application.css`, `app/assets/images/logo.svg`, `app/assets/fonts/x.woff2`, `app/javascript/application.js`, `app/javascript/controllers/hello_controller.js`, `vendor/javascript/chart.js`, `config/importmap.rb`; the program copies the fixture to a temporary directory before running gen on it), `test/dev_watcher.rb` (grown: an asset change triggers a rebuild)

**Interfaces:**
- Produces: `gen/assets.rb` (`Gen::Assets.digest_path`, `.importmap_json`, `.preload_paths`, `.resolver`), `public/assets/<name>-<8 hex>.<ext>`, `public/assets/.manifest`, `Cybertrain::Assets.install`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "files are digested with the first 8 hex of their SHA-256" do
  files = Cybertrain::Gen::AssetScan.scan(TMP)
  logo = files.find { |f| f.logical_path == "logo.svg" }
  assert_equal Digest::SHA256.hexdigest(File.binread("#{TMP}/app/assets/images/logo.svg"))[0, 8], logo.asset_digest
  assert_equal "logo-#{logo.asset_digest}.svg", logo.digested_path
  assert_equal "controllers/hello_controller.js", files.find { |f| f.source_path.end_with?("hello_controller.js") }.logical_path
end
test "url() suffixes, quotes and non-asset references" do
  css, warnings = rewrite(%(a{b:url("../images/logo.svg")} c{d:url(../fonts/x.woff2?v=3#iefix)} e{f:url(data:image/png;base64,AA)} g{h:url(https://cdn/x.png)} i{j:url(#clip)} k{l:url(missing.png)}))
  assert_includes css, %(url("/assets/logo-#{digest("logo.svg")}.svg"))
  assert_includes css, "url(/assets/x-#{digest("x.woff2")}.woff2?v=3#iefix)"
  assert_includes css, "url(data:image/png;base64,AA)"
  assert_includes css, "url(https://cdn/x.png)"
  assert_includes css, "url(#clip)"
  assert_includes css, "url(missing.png)"
  assert_equal 1, warnings.size
end
test "a CSS digest changes when an image it names changes" do
end
test "three versions are kept, older ones deleted" do
  # run sync 4 times with a changed application.css: public/assets holds the last 3 digests of it, the first is gone,
  # .manifest's line is "application.css <d4> <d3> <d2>"; an undigested public/assets/keep.txt is untouched
end
test "the import map, preloads and the emitted case" do
  # importmap_json == {"imports":{"application":"/assets/application-<d>.js","@hotwired/turbo":"https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js","controllers/hello_controller":"/assets/controllers/hello_controller-<d>.js"}}
  # preload_paths excludes a pin with preload: false; a non-pin line and an unknown to: are refused with their line
end
test "gen --check compares gen/assets.rb only" do
end
```

- [ ] **Step 2: Run** `spin test test/gen_assets.rb`: FAIL.
- [ ] **Step 3: Implement** (Task 1's item 5 numbers decide whether digests stream through `File.binread` whole; files are read once each).
- [ ] **Step 4: Run** it plus `spin test test/gen_manifest.rb test/gen_runner_models.rb test/dev_watcher.rb test/dev_application.rb`; regen fixtures (`gen/assets.rb` appears in each fixture app).
- [ ] **Step 5: Gate and commit**: "Assets: digests at gen time, CSS url() rewriting, three versions kept, the import map, gen/assets.rb".

---

### Task 19: Asset helpers, `javascript_importmap_tags`, `image_tag`, immutable serving (A-2, §7.2–7.4)

**Files:**
- Modify: `cybertrain/assets.rb` (`Assets.path(logical) -> String`: the digested path; an unknown name raises `Assets::UnknownAsset, "asset \"logo.png\" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)"` in development and test, and in production logs that line once per name and returns `"/assets/logo.png"`; `Assets.kept_file?(file_name) -> Boolean` (current or listed in `public/assets/.manifest`, read once at boot by `Assets.load_kept(public_root)`); `Assets.importmap_json`, `Assets.preload_paths`), `cybertrain/template/helpers.rb` (`asset_path(name)`; `stylesheet_link_tag(name, media: "", nonce: false)` → `<link rel="stylesheet" href="/assets/application-<d>.css">` (`.css` added when missing; `media="…"`, `nonce="…"` when given / true); `javascript_include_tag(name, nonce: false)` → `<script src="/assets/legacy-<d>.js"></script>`; `image_tag(source, alt: "", size: "", class: "")` → `<img src="/assets/logo-<d>.svg" alt="Logo" width="16" height="16" class="x">` (`size: "16x16"` or `"16"`; a source starting with `/` or a scheme is used as written; no automatic alt); `javascript_importmap_tags(entry = "application")` → `<script type="importmap" data-turbo-track="reload">{json}</script>` + `\n<link rel="modulepreload" href="…">` per preload + `\n<script type="module">import "application"</script>`, each with `nonce="N"` when a CSP nonce exists), `cybertrain/middleware/static.rb` (`IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable"` for a file under `/assets/` whose name `Assets.kept_file?`; everything else `CACHE_CONTROL` `"public, max-age=3600"` as today), `cybertrain/application.rb` (boot calls `Assets.load_kept(c.public_root)`), `cybertrain/generator/helper_scan.rb` (`RESERVED_HELPER_NAMES` += `asset_path stylesheet_link_tag javascript_include_tag image_tag javascript_importmap_tags`)
- Test: `test/assets.rb` (new, compiled: installs a hand-written resolver and import map), `test/static.rb` (grown)

**Interfaces:**
- Consumes: Task 18's `Gen::Assets` / `Assets.install`; Task 14's `Context#csp_nonce`.
- Produces: the five helpers, `Assets.path`, `Assets.kept_file?`, `Static`'s immutable header.

- [ ] **Step 1: Write the failing tests** ("asset_path and the tag helpers" with exact HTML; "javascript_importmap_tags with and without a nonce"; "an unknown asset raises in test and logs once in production, then emits the undigested path"; static.rb: "a current or kept digest is immutable" → `Cache-Control: public, max-age=31536000, immutable`; "an undigested file under public/assets keeps max-age=3600"; "a digest-shaped name gen did not write keeps max-age=3600").
- [ ] **Step 2: Run** `spin test test/assets.rb test/static.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both plus `spin test test/helpers.rb test/csp.rb test/application.rb`.
- [ ] **Step 5: Gate and commit**: "Asset helpers, import map tags and a year of immutable caching for digested files".

---

### Task 20: `cybertrain new`, the Dockerfile and deploy templates

**Files:**
- Modify: `cybertrain/cli/new_app.rb` (adds `app/assets/stylesheets/application.css` (today's `style_css` content), `app/assets/images/.keep`, `app/javascript/application.js` (`// Entry point for the import map: import "@hotwired/turbo"` commented), `config/importmap.rb` (`pin "application"` and a commented Turbo pin, the spec §7.3 line); `public/style.css` no longer written), `cybertrain/cli/templates.rb` (layout: `<%= stylesheet_link_tag "application" %>`, `<%= javascript_importmap_tags %>`, `<%= csp_meta_tag %>`; error pages keep a plain inline `<style>` (they are static); `config_app`: the commented CSP block of spec §5 C-5 and `# c.permissions_policy = "camera=(), microphone=(), geolocation=()"`; `gitignore` += `/public/assets/`; `env_example` += commented `CYBERTRAIN_FORCE_SSL=1` and `CYBERTRAIN_HOSTS=app.example.com`; `dockerfile`: `libssl-dev` in the build stage's apt line, `libssl3t64` in the runtime stage's; `deploy_yml`: `asset_path: /app/public/assets` with a comment on bridging the previous release's digests; `ci_workflow` unchanged unless Task 1 found it lacks OpenSSL headers), `examples/blog/Dockerfile` (same two packages)
- Test: `test/cli_new.rb` (snapshot), `test/cli_build.rb` (re-run: dist/public carries public/assets)

- [ ] **Step 1: Change the templates, regenerate the snapshot** (`spin test --regen test/cli_new.rb` or `script/regen-snapshot`) **and review the diff** (only the new files and lines).
- [ ] **Step 2: Run** `spin test test/cli_new.rb test/cli_build.rb test/cli_scaffold.rb test/cli_authentication.rb`.
- [ ] **Step 3: Gate and commit**: "cybertrain new: app/assets, app/javascript, config/importmap.rb, the CSP block; OpenSSL in the images; Kamal asset_path".

---

### Task 21: examples/blog (acceptance item 7)

**Files:**
- Create: `examples/blog/app/assets/stylesheets/application.css` (from `public/style.css`, which is deleted, with one `url(../images/logo.svg)`), `examples/blog/app/assets/images/logo.svg`, `examples/blog/app/javascript/application.js` (`import "@hotwired/turbo"`), `examples/blog/config/importmap.rb` (`pin "application"`, the Turbo pin of spec §7.3), `examples/blog/app/controllers/concerns/admin_gate.rb` (`extend ActiveSupport::Concern`; `included do before_action :require_admin; helper_method :admin? end`; `class_methods do def per_page = 20 end`), `examples/blog/app/controllers/admin/articles_controller.rb` (`module Admin` / `class ArticlesController < ApplicationController`, `include AdminGate`; `index` lists `Article.order(created_at: :desc).limit(self.class.per_page)`, `destroy` deletes and redirects to `admin_articles_path`, status `:see_other`), `examples/blog/app/views/admin/articles/index.html.erb` (a delete `button_to` per article; `time_tag` dates; `number_with_delimiter` count), `examples/blog/app/views/comments/create.turbo_stream.erb` (`turbo_stream.append "comments", html: render(component: "comment", comment: @comment)` and a form reset)
- Modify: `examples/blog/config/routes.rb` (`resources :articles` gains nothing but formats by default; `namespace :admin do |admin| admin.resources :articles, only: [:index, :destroy]; admin.jobs_page "/jobs", before_action: :require_admin end`; `/admin/login` unchanged), `examples/blog/app/controllers/application_controller.rb` (`require_admin` and a private `admin?` stay here — the jobs page's controller inherits them; AdminGate declares the gate and the helper), `examples/blog/app/controllers/articles_controller.rb` (`index` and `show` answer html and json through `respond_to`, json via `render json: @articles.map(&:as_json)` / `@article.as_json`; `index` reads `params[:order]` ("new"/"old")), `examples/blog/app/controllers/comments_controller.rb` (`create`: `respond_to do |format| format.turbo_stream; format.html { redirect_to … } end`), `examples/blog/app/views/articles/index.html.erb` (`select_tag "order", options_for_select(...)` in a GET form; `number_with_delimiter` for the counts), `examples/blog/app/views/articles/show.html.erb` (`time_tag`; `admin?` shows an admin link), `examples/blog/app/views/layouts/application.html.erb` (`stylesheet_link_tag`, `javascript_importmap_tags`, `csp_meta_tag`), `examples/blog/config/app.rb` (CSP: `default_src :self`, `script_src :self, "https://cdn.jsdelivr.net"`, `style_src :self`, `img_src :self, :data`, nonce directives `%w[script-src style-src]`), `examples/blog/.gitignore` (`/public/assets/`), `examples/blog/README.md` (assets, admin namespace, formats)
- Regenerate `examples/blog/gen/**` (`spin run gen`)
- Test: `examples/blog/test/articles.rb` (grown: `/articles.json` and `/articles/:id.json` bodies; `/articles.xml` → 406; the layout links `/assets/application-<8 hex>.css` and that path answers 200 with `immutable`; the import map names Turbo's URL; the CSP header carries a nonce matching the page's `csp-nonce` meta; the order `select`; `/admin/articles` 404 without the token, 200 with the `x-admin-token` header, listing articles; `DELETE /admin/articles/:id` with the token removes it; `/admin/jobs` under the namespace guarded as before), `examples/blog/test/comments.rb` (grown: posting with `Accept: text/vnd.turbo-stream.html` answers 200 `text/vnd.turbo-stream.html` with `<turbo-stream action="append" target="comments">`; without it, the 303 as today)

- [ ] **Step 1: Write the failing tests.** **Step 2: Run** `cd examples/blog && spin run gen && spin test` (FAIL). **Step 3: Implement and regenerate**; snapshots from the compiled output. **Step 4: Run** `spin test`, `spin run gen -- --check`, the rule-62 grep on `spinel $(spin flags) bin/blog.rb -c -o /tmp/blog.c` (0 and 0), root `ruby script/gate`. **Step 5: Commit**: "blog: digested stylesheet, Turbo through the import map, an admin namespace behind the AdminGate concern, JSON and Turbo Stream formats, number and time helpers, CSP with nonces".

---

### Task 22: Documents — design.md D58–D63, guides and translations, section 18

**Files:**
- Modify: `docs/design.md` (D58 routing, D59 formats and `respond_to`, D60 concerns and `helper_method`, D61 the controller additions and the encrypted session, D62 the view additions, D63 assets and the import map — each dated, with "why", the Spinel constraint and the rejected alternatives; D7 and D8 lose the "outside the MVP" items now built and D8's "the openssl package is not used" paragraph is amended; D15's concern paragraph and D25's session cookie paragraph amended; section 8's list shrinks; section 13 gets the dated entry with the new test programs and NOTES rules), `docs/guide/requests.md` (routing, formats, `respond_to`, concerns, `helper_method`, `params.expect`, `send_data`, caching, `rate_limit`, cookies, CSP, `force_ssl`, hosts, the 0.4 upgrade notes of §14), `docs/guide/template-language.md` (number helpers, forms, layouts, Turbo helpers, `time_tag` / `image_tag` / `current_page?`, collections), new `docs/guide/assets.md` (sources and logical paths, digests and retention, CSS `url()`, helpers, import map, serving, moving `public/style.css`, the Kamal `asset_path`) and its line in `docs/guide/index.md`, `docs/guide/configuration.md` (`CYBERTRAIN_FORCE_SSL`, `CYBERTRAIN_HOSTS`, the CSP fields, `permissions_policy`), `docs/guide/install.md` (OpenSSL headers required for every application; Homebrew OpenSSL on macOS), `docs/guide/how-it-works.md` (gen/concerns.rb, gen/assets.rb), `docs/guide/tutorial.md` where its stylesheet step changes; each English change in `docs/guide/{fr,ja,ru,zh}/` with `script/check-guide-i18n --update-sha <files>`; `docs/deploy.md` and `docs/deploy.en.md` (`asset_path`, OpenSSL in the image), `README.md` (feature list), the framework files' header comments touched (session.rb, crypto.rb, encryptor.rb, rate_limit.rb, static.rb), `spikes/NOTES.md` (Task 1's rules cross-checked), `docs/spinel-feedback.md`, the spec's new "## 18. Implementation notes" (4a: what differed from the spec, the plan decisions taken, rule numbers, test counts from `script/test-shard 0 1` and the blog)
- Test: `ruby script/gate` (guide i18n, docs i18n, version mentions), `script/api-docs`, `script/guide-pages`

- [ ] **Step 1: Write the documents.** **Step 2: Run** the checks and `script/test-shard 0 1`; record the counts in §18. **Step 3: Commit**: "Phase 4a documents: design.md D58 to D63, the requests, template-language, assets, configuration and install guides with translations, deploy notes, README, spec section 18".

---

## Execution order and verification

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → {11 ∥ 15 ∥ 18} → {12 ∥ 16} → 13 → 14 → 17 → 19 → 20 → 21 → 22. Task 8 needs 3; 9 needs 5; 13 needs 5 and 12's `cybertrain.rb` changes; 17 needs 8; 19 needs 14 and 18; 21 needs everything before it. Every task ends with `ruby script/gate`, `ruby script/check-reserved-names`, `script/api-docs` and the whole `script/test-shard 0 1` green; after Task 21 `cd examples/blog && spin test` and `spin run gen -- --check` pass too, which with Task 22 is acceptance item 8.
