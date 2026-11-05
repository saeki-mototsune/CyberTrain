# Phase 1: realtime delivery, components and helpers, concurrent jobs, process roles, BLOB, console — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give CyberTrain the 14 framework-level features the fin_dash survey marked "必須": SSE and WebSocket delivery on a SQLite-backed pub/sub, Turbo Streams, application helpers and view components, `case`/blocks/`tag` in templates, a job thread pool with heartbeats, `worker` / `feeds` process roles, BLOB columns, and an expression console.

**Architecture:** Six work packages (A to F). A to E are independent of each other at the code level (their shared edits are disjoint `when` arms and `Config` keys, merged by the integrator); F integrates, documents and verifies on the merged branch. Every new name-to-method step is a generated or literal `case` (no computed `send`); every new long-lived thread starts through a method whose parameters its block captures; every new table is created by an `install!` with `CREATE TABLE IF NOT EXISTS`.

**Tech Stack:** Spinel (pinned `Cybertrain::SPINEL_TAG` 2026.11.04.7026, `export PATH="/root/.cybertrain/bin:$PATH"`), SQLite through the existing FFI, `spin test` snapshot programs under `test/`.

**Spec:** `docs/superpowers/specs/2026-11-05-phase1-realtime-views-processes-design.md` (read it first; section numbers below refer to it).

## Global Constraints

- Everything under `cybertrain/` except `cybertrain/cli*` compiles under Spinel: no `eval`, `method_missing`, `define_method` / `send` with computed names, `Class.new`, `instance_exec(&stored)`, `instance_variable_get`. Read `spikes/NOTES.md` "Rules by topic" before writing a file; cite a rule number in a comment where you follow it.
- Registries are constants seeded with their element type then emptied (`Array.new(0) { X.new(...) }`, `{ "" => "" }.tap { |h| h.delete("") }`; NOTES rules 9 and 64).
- Threads start through a method: `def spawn_x(a, b); Thread.new { run_x(a, b) }; end` (rule 21). Every `readpartial` is preceded by `wait_readable(timeout)` (rule 20). No new `rescue` clause in a method that yields (rules 32 / 45); rescue in a plain method that calls the stored block with `.call`.
- No method name reused with a different return type anywhere in the framework (rules 10 / 34 / 41): prefix new accessors (`sub_name`, `service_start`, `write_body`, `stream_*`). `script/check-reserved-names` must pass if `cybertrain/model.rb` grows a method.
- `cybertrain/http/*` must not require anything outside `cybertrain/http/*`, `cybertrain/params`, `cybertrain/http/query`, `cybertrain/logger` (`script/check-http-layer`).
- Tests are `test/<name>.rb` programs with a committed `test/<name>.rb.expected` snapshot made by `script/regen-snapshot test/<name>.rb`; a test that needs FFI (SQLite, zlib) only runs compiled. Run one with `spin test test/<name>.rb`; a program that needs only pure Ruby can be checked first with `ruby -I. test/<name>.rb`.
- Generated files are committed: after a generator change run `ruby -I. exe/cybertrain` is not enough; regenerate `examples/blog/gen/` (`cd examples/blog && spin run gen`) and the fixtures `test/fixtures/*/gen` (their tests say how).
- `script/gate` (trailing whitespace, final newline, `ruby -c`, snapshot pairs, i18n checks) must pass before each commit; `script/install-hooks` installs it as the pre-commit hook.
- Commit messages: imperative, one line, body only when needed; never mention a model name.
- Default values are the spec's section 8 table, verbatim.

## Review Focus

Inputs the spec implies but no task's tests cover unless added here (each has its test added to the owning task):

1. A client that opens an SSE connection and sends nothing, then disconnects without a FIN while the server is blocked waiting for messages: the connection thread must end within one ping interval, not leak (C3: `test/stream_endpoint.rb` "a disconnected SSE client is noticed at the next ping").
2. A token whose names are valid but whose signature was made with a different secret: 403 for SSE, close 1008 for WebSocket, no row read (C3).
3. `tag.script("alert(1)")` and `tag.div(onclick: "x")`: content is escaped, attribute names are validated (`[a-zA-Z_:][-a-zA-Z0-9_:.]*`), an invalid attribute name raises (A3).
4. Two worker processes recovering the same stale row: exactly one requeue counted, and a row whose handler is mid-run with a fresh heartbeat is never requeued (D2).
5. A BLOB of exactly `max_body_bytes`-sized data is not the concern; a BLOB containing `\0` in its first byte and a text column holding the bytes `"\xff\xfe"` (invalid UTF-8) round-trip byte for byte (E1).

---

## Package A: template grammar, `tag` builder, built-in helpers (spec 3.3, 3.4)

**Files:**
- Modify: `cybertrain/template/lexer.rb` (`{`, `}`, `|` tokens if missing; `case`, `when` keywords become statements, not reserved errors)
- Modify: `cybertrain/template/parser.rb` (case statement; block on any call; `{ |x| expr }`)
- Modify: `cybertrain/template/ast.rb`, `cybertrain/template/inode.rb` (new node kinds `K_CASE`, block slot on `K_CALL`)
- Modify: `cybertrain/template/interpreter.rb` (`exec_case`, `array_method` / `hash_method` with blocks, `call_object_method` signature)
- Modify: `cybertrain/template/helpers.rb` (`tag`, `content_tag`, `safe_join`, `class_names`, `dom_id` arms; `TagBuilder` dispatch in `call_object_method`)
- Modify: `cybertrain/html.rb` (`Html.tag`, `Html.attributes`, `Html.safe_join`, `Html.class_names`, `Html.dom_id`, `Html::TagBuilder`, `VOID_ELEMENTS`)
- Modify: `docs/guide/template-language.md` (every new rule; translations are F's)
- Test: `test/template_case.rb`, `test/template_blocks.rb`, `test/template_tag.rb`, `test/html_tag.rb` (pure Ruby: runs under CRuby and Spinel)

**Interfaces:**
- Produces: `Cybertrain::Html.tag(name, attrs = {}, content = nil) { ... } -> SafeString` (block output wins over `content`; attrs `Hash<String|Symbol, polymorphic>`), `Html.safe_join(items, sep = "") -> SafeString`, `Html.class_names(*values) -> String`, `Html.dom_id(record, prefix = "") -> String`, `Html::TagBuilder` (a value with no state; `Html::TAG_BUILDER` the one instance), `Html::VOID_ELEMENTS`.
- Produces: `HelperBase#call_object_method(recv, name_sym, name_str, args, kwargs, block, interp, env)` (block, interp, env added; `block` is the `INode` or nil, captured with `interp.capture(block, env)`). `Helpers#call_object_method` updated to the new arity (FormBuilder arms ignore the block).
- Produces for B: the parser accepts a block after `render component: "x", ...` exactly as after any helper call (no change needed in B).

### Task A1: `case` / `when` statements

- [ ] **Step 1: Write `test/template_case.rb`** (pattern: `test/template_integration.rb`'s `render_string` helper). Assertions: `case :a when :a, :b` prints the first branch; `when` on Integer `1` vs Float `1.0` matches (compare); `else` taken; no `else` and no match prints nothing; `case` on a String against Symbols does not match; `<% when %>` outside `case` is a `SyntaxError` naming the line; blank text between `case` and `when` is dropped; nested `case` inside `each`.
- [ ] **Step 2: Run** `ruby -I. test/template_case.rb`; expected: SyntaxError "'case' is not supported in templates".
- [ ] **Step 3: Implement**: lexer/parser produce `Ast::Case(subject, whens: [[values], nodes], else_nodes)`, converted to `INode` kind `K_CASE` with `ikids = [subject, when1_values_node, when1_body, ..., else_body]` (document the slot layout in a comment); `Interpreter#exec_case(n, env)` evaluates the subject once and compares with the existing `compare`-or-`==` rule from `call_method`'s `==`.
- [ ] **Step 4: Run** under CRuby, then `script/regen-snapshot test/template_case.rb`, then `spin test test/template_case.rb`; expected PASS both.
- [ ] **Step 5: Commit** "Template: case/when statements".

### Task A2: blocks on enumerable methods

- [ ] **Step 1: Write `test/template_blocks.rb`**: `items.map { |x| x * 2 }.join(",")`; `select`/`reject`/`find`/`any?`/`all?`/`none?` with `{ }`; `sum { |x| x.price }` on models (use the existing fake model from template_integration); `sum` of `[]` is `0`, `[1, 2.5]` is `3.5`, `["a"]` raises "sum: use join for Strings"; `sort_by`/`min_by`/`max_by`; `group_by { |x| x.kind }` then `each do |kind, list|`; `each_slice(2)` with and without a block; `each_with_object` is not in the table (templates cannot mutate an accumulator) and raises the ordinary `"undefined method 'each_with_object' for Array"`; Hash `map { |k, v| }`, `select { |k, v| }`, `sort_by { |k, v| v }`; blockless `min`, `max`, `sort`, `uniq`, `compact`, `flatten`, `take(2)`, `drop(1)`; `do |x| ... end` block whose last statement is `<% y = x %>` raises "map's block must end in a value"; a block on a String method is a `SyntaxError` ("String#upcase takes no block"); block parameter shadowing restored after the call.
- [ ] **Step 2: Run** `ruby -I. test/template_blocks.rb`; expected: SyntaxError "blocks are only supported on each, each_with_index and helper calls".
- [ ] **Step 3: Implement**: parser attaches an optional block (`{ |a, b| expr }` or `do |a, b| statements end`) to `K_CALL`; interpreter `call_method` gets `block` and `env`; `array_method` / `hash_method` gain the methods above, evaluating the block through a new `Interpreter#block_value(block, env, a, b = nil)` (binds params like `exec_each`, returns the last statement's value, raises when a statement is not an expression); `call_object_method` grows to the Interfaces signature; `Helpers#call_object_method` adapts.
- [ ] **Step 4: Run** CRuby, regen snapshot, `spin test test/template_blocks.rb`; also `spin test test/template_integration.rb test/controller_views.rb` must still pass unchanged.
- [ ] **Step 5: Commit** "Template: blocks on Array and Hash methods".

### Task A3: `Html.tag` and the `tag` builder

- [ ] **Step 1: Write `test/html_tag.rb`** (pure Ruby, `require "cybertrain/html"` only): `Html.tag("div")` is `<div></div>`; `Html.tag("br")` is `<br>`; `Html.tag("br", {}, "x")` raises "br is a void element"; `Html.tag("a", { href: "/x?a=1&b=2", class: ["btn", nil, "big"], disabled: true, hidden: false, data: { turbo_frame: "f", id: 3 }, aria: { label: "x" } }, "Go")` is `<a href="/x?a=1&amp;b=2" class="btn big" disabled data-turbo-frame="f" data-id="3" aria-label="x">Go</a>`; content `"<b>"` is escaped; a block's SafeString is not; `SafeString` attribute value **is** escaped; attribute name `"on click"` raises ArgumentError; element name `"Div"` and `"div x"` raise; `Html.safe_join(["<a>", SafeString.of("<b>")], ", ")` is `&lt;a&gt;, <b>`; `Html.class_names("a", ["b", nil], { "c" => true, "d" => false }, "")` is `"a b c"`; `Html.dom_id(record)` → `"article_12"`, new record → `"new_article"`, `Html.dom_id(record, "edit")` → `"edit_article_12"` (the prefix is positional, as Rails' `dom_id(record, prefix = nil)`; the default is `""`).
- [ ] **Step 2: Run** `ruby -I. test/html_tag.rb`; expected NoMethodError `tag`.
- [ ] **Step 3: Implement** in `cybertrain/html.rb` per spec 3.3 (`VOID_ELEMENTS`, `Html.tag`, `Html.attributes(attrs) -> String`, `Html.safe_join`, `Html.class_names`, `Html.dom_id` using `record.model_name` snake-cased with the existing `Gen::Inflector`, and `Html::TagBuilder`).
- [ ] **Step 4: Write `test/template_tag.rb`**: `<%= tag.div(class: "c") do %>hi <%= name %><% end %>`; `<%= tag.span "t", class: "x" %>`; `<%= tag.input type: "text", name: "q" %>`; `<%= tag.path d: "M0 0" %>`; `<%= tag.br %>`; `tag.br do %>x<% end` raises; `<%= content_tag "p", "<i>", class: "n" %>` escapes; `<%= safe_join([tag.b("a"), "<"], " ") %>`; `<%= class_names("a", { "b" => true }) %>`; `<%= dom_id(@article) %>` and `<%= dom_id(@article, "edit") %>`; `tag.script("alert(1)")` prints escaped content; `tag.div(onclick: "x")` renders the attribute (allowed; it is the author's), `tag.div("on click": "x")` raises.
- [ ] **Step 5: Implement** the arms in `Helpers#helper_call` (`"tag"` returns `Html::TAG_BUILDER`; `content_tag`, `safe_join`, `class_names`, `dom_id`) and a `when Html::TagBuilder` arm in `Helpers#call_object_method` that calls `Html.tag(name_str, kwargs, positional String, block captured through interp)`.
- [ ] **Step 6: Run** all four tests under CRuby, regen snapshots, `spin test` on them; commit "Template: tag builder, content_tag, safe_join, class_names, dom_id".

### Task A4: guide update

- [ ] **Step 1:** Add to `docs/guide/template-language.md`: a "case" subsection under Statements, a "Blocks" subsection (which methods, value vs output rule, no mutation), the `tag` subsection under Helpers, the four helpers in the helper table, and drop `case`/`when` from the reserved-word sentence. Run `script/check-guide-i18n`; it will fail on the translations: note in the commit that F translates. (If the gate blocks the commit, run `script/gate FILE` on the Ruby files only and commit the guide in F instead.)
- [ ] **Step 2: Commit** "Guide: case, blocks and tag in templates".

---

## Package B: application helpers, components, rendering outside a request (spec 3.1, 3.2, 3.5, 2.5's `Views` part)

**Files:**
- Create: `cybertrain/generator/helper_scan.rb`, `cybertrain/generator/helpers_emitter.rb`, `cybertrain/generator/component_scan.rb`, `cybertrain/generator/components_emitter.rb`, `cybertrain/generator/console_emitter.rb`, `cybertrain/component.rb`, `cybertrain/cli/helper.rb`, `cybertrain/cli/component.rb`
- Modify: `cybertrain/generator/runner.rb` (emit `gen/helpers.rb`, `gen/components.rb`, `gen/console.rb`), `cybertrain/generator/manifest.rb` (require them), `cybertrain/generator/views_emitter.rb` (embed `app/components/**/*.erb` as `components/<file>`), `cybertrain/views.rb` (`helpers_builder`, `components_root`, `render_partial`, `render_component`), `cybertrain/template/engine.rb` (second root), `cybertrain/template/helpers.rb` (`@controller` nullable, `app_helper_call`, `render component:`, `link_to_path`, `button_to_path`), `cybertrain/controller.rb` (use `Views.helpers_builder`), `cybertrain/cli.rb` (`generate helper`, `generate component`), `cybertrain.gemspec` (new CLI files), `cybertrain/test.rb` (`render_partial`, `render_component`)
- Test: `test/gen_helpers.rb`, `test/gen_components.rb`, `test/views_detached.rb`, `test/cli_generate_helper.rb`, `test/cli_generate_component.rb`, fixtures under `test/fixtures/gen_app/app/helpers` and `app/components`

**Interfaces:**
- Produces: `Cybertrain::Views.helpers_builder` / `helpers_builder=` (lambda `(Controller | nil) -> Template::Helpers`, default builds `Template::Helpers`); `Views.render_partial(name, locals = {}) -> String`; `Views.render_component(component, content = "") -> String`; `Cybertrain::Views::OutsideRequest < StandardError`; `Cybertrain::Component` (base: `view_assigns -> Hash<String, polymorphic>` default `{}`, `call_view_method(name) -> polymorphic | nil`, `component_name -> String` ("card" for `CardComponent`), `content` / `content=`); `Cybertrain::Component::Unknown < StandardError`.
- Produces (generated, consumed by E's console): `Gen::Console.scope(name) -> Cybertrain::Relation` (raises `Cybertrain::Console::UnknownModel`), `Gen::Console.records(relation) -> Array<Cybertrain::Model>` (`case relation when ArticleRelation then relation.to_a ...`), `Gen::Console.create(name, attrs) -> Cybertrain::Model` (`attrs: Hash<Symbol, polymorphic>`), `Gen::Console::MODEL_NAMES -> Array<String>`. `Cybertrain::Console::UnknownModel` is defined by E in `cybertrain/console.rb`; B's emitter references it by name only.
- Produces (generated): `ApplicationHelpers < Cybertrain::Template::Helpers` with `app_helper_call`; `Gen::Components.build(name, kwargs) -> Cybertrain::Component`.
- Consumes from A: nothing at the code level (component templates in fixtures may use `tag` only after the merge; keep fixtures to today's grammar).

### Task B1: `HelperScan` and `HelpersEmitter`

- [ ] **Step 1: Write `test/gen_helpers.rb`** (pure Ruby: scan strings, compare emitted source): a module with `def price(value, unit: "USD", precision: 2)` emits 4 arms in the order (both, unit, precision, none) and an `helper_arity!(name, args, 1, 1)` guard; `def badge(text, kind = "info", &block)` emits 2 arms passing `{ interp.capture(block, env) }`; `def a(*rest)` raises `Gen::HelperScan::Error` "app/helpers/x.rb:3: helper parameters must be named"; the same `def` in two modules raises naming both files; `def self.x` and anything after a `private` line are skipped; a module with no helpers still gets `include`d; the output ends with the `Views.helpers_builder =` line; a tree with no `app/helpers` emits a class with only `super`.
- [ ] **Step 2: Run** `ruby -I. test/gen_helpers.rb`; expected LoadError.
- [ ] **Step 3: Implement** `Gen::HelperScan.scan_dir(dir) -> Array<HelperModule(name, file, defs: Array<HelperDef(name, line, required, optional, keywords_required, keywords_optional, block)>)>` and `Gen::HelpersEmitter.emit(modules) -> String` as spec 3.1 shows; more than 3 optional parameters raises with the "split it" message.
- [ ] **Step 4: Run**, snapshot, commit "Generator: scan app/helpers and emit gen/helpers.rb".

### Task B2: `Views.helpers_builder`, `app_helper_call`, `link_to_path`

- [ ] **Step 1: Extend `test/controller_views.rb`** (or a new `test/app_helpers.rb` compiled with a hand-written `ApplicationHelpers` subclass): a template calling `<%= shout("hi") %>` reaches the subclass's `app_helper_call`; an unknown name still says "undefined helper 'nope'"; `link_to_path("x", "/p", class: "c")` from a Ruby helper returns `<a class="c" href="/p">x</a>`.
- [ ] **Step 2: Implement**: `Template::Helpers#app_helper_call(name, args, kwargs, block, interp, env)` raising the existing undefined-helper error; `helper_call`'s `else` calls it; `Views.helpers_builder` default lambda; `Controller#render_template` and `#render_partial` call `Views.helpers_builder.call(self)`; `Helpers#link_to_path(text, path, attrs = {})` and `button_to_path(text, path, method: "post", attrs = {})` built on the existing private renderers; `Gen::UrlHelpers` is included by the emitted `ApplicationHelpers` (emitter line `include Gen::UrlHelpers if defined?(Gen::UrlHelpers)` is not possible under Spinel: emit the `include` unconditionally; `gen/routes.rb` is always required first by the manifest).
- [ ] **Step 3: Run**, snapshot, commit "Views: helpers_builder and app_helper_call".

### Task B3: `Component`, `ComponentScan`, `ComponentsEmitter`, `render component:`

- [ ] **Step 1: Write `test/gen_components.rb`** (pure Ruby, like B1): a `CardComponent < Cybertrain::Component` with `initialize(title:, value: 0)`, `@title = title`, `@value = value`, `def value_text`, emits `view_assigns` with both ivars, `call_view_method` with `:value_text`, and `Gen::Components.build` arms (2, for the optional keyword); a class not inheriting from `Cybertrain::Component` or `ApplicationComponent` is skipped; a positional `initialize` parameter raises "component parameters must be keywords"; a file without a matching `.html.erb` raises naming the expected path; `component_name` is derived (`CardComponent` → `"card"`, `Admin::UserRowComponent` → `"admin/user_row"`); the output ends with the line `Cybertrain::Views.component_builder = ->(name, kwargs) { Gen::Components.build(name, kwargs) }` (asserted literally, as B1 asserts the `helpers_builder` line); a tree with no `app/components` still emits the module and that line, with a `build` that always raises.
- [ ] **Step 2: Implement** `cybertrain/component.rb`, `Gen::ComponentScan.scan_dir`, `Gen::ComponentsEmitter.emit` (ending with the `Views.component_builder =` assignment above).
- [ ] **Step 3: Write `test/component_render.rb`** (compiled: a hand-written component class and `Gen::Components` table in the test, `Views.configure` on a temp dir with `app/views` and `app/components`): `<%= render component: "card", title: "T", value: 2 %>` renders the component template with `title`, `value_text` and empty `content`; with a block, `content` holds the captured HTML; unknown component raises `Component::Unknown` with the file hint; nesting a component in a component and a partial in a component works; depth counts toward `max_render_depth`.
- [ ] **Step 4: Implement**: `Views.components_root` / `Engine` second root for names starting with `components/`; `ViewsEmitter` embeds `app/components/**/*.erb` as `components/<relative path>`; `Helpers#render_helper` handles `component:` by `Gen::Components`-free dispatch: **the table is reached through `Views.component_builder` (lambda `(String, Hash<String, polymorphic>) -> Component`, set by `gen/components.rb`)**, then `Component#render_with(helpers, content, interp) -> SafeString`.
- [ ] **Step 5: Run**, snapshots, commit "Components: Cybertrain::Component, generator and render component:".

### Task B4: rendering outside a request

- [ ] **Step 1: Write `test/views_detached.rb`** (compiled; `Views.configure` on a temp dir): `Views.render_partial("articles/article", article: a)` returns the HTML; a partial using `csrf_token` raises `Views::OutsideRequest, "csrf_token needs a request"`; `params`, `flash`, `request_path`, `*_url` raise too; `article_path(a)` works (set `Views.url_resolver` in the test); `Views.render_component(CardComponent.new(title: "x"), "<b>c</b>")` returns the HTML with the content unescaped.
- [ ] **Step 2: Implement**: `Template::Helpers#initialize(controller)` accepts `nil` (`@controller` typed `Controller | nil`; each request-bound helper goes through `def request_controller(helper_name)` that raises `OutsideRequest`); `Views.render_partial` and `render_component` build helpers with `Views.helpers_builder.call(nil)` and render with no layout; `Test.render_partial` / `Test.render_component` delegate.
- [ ] **Step 3: Run**, snapshot, commit "Views: render partials and components outside a request".

### Task B5: `ConsoleEmitter`, runner and manifest wiring, fixtures

- [ ] **Step 1: Extend `test/gen_app.rb`** (whatever test covers `Runner`/`Manifest` today; see `test/fixtures/gen_app`): the manifest requires `gen/routes`, `gen/helpers`, `gen/components`, `gen/console` in that order before the controllers; `gen/console.rb` for two models emits `scope` / `records` / `create` arms and `MODEL_NAMES`; a tree with no models emits a `Gen::Console` whose `scope` always raises.
- [ ] **Step 2: Implement** `Gen::ConsoleEmitter.emit(models) -> String` (the model list the runner already has) and the runner / manifest wiring; add `app/helpers/prices_helper.rb` and `app/components/card_component.{rb,html.erb}` to `test/fixtures/gen_app`; regenerate the fixture's `gen/` and `examples/blog/gen/` (`cd examples/blog && spin run gen`; its new `gen/helpers.rb`, `gen/components.rb`, `gen/console.rb` are committed).
- [ ] **Step 3: Run** `spin test test/gen_app.rb test/cli_build.rb` and the blog's tests (`cd examples/blog && spin test`); commit "Generator: emit gen/helpers.rb, gen/components.rb and gen/console.rb".

### Task B6: `cybertrain generate helper` / `component`

- [ ] **Step 1: Write `test/cli_generate_helper.rb` and `test/cli_generate_component.rb`** in the style of `test/cli_scaffold.rb`: `generate helper prices` writes `app/helpers/prices_helper.rb` with an empty `module PricesHelper` and a test file; `generate component card title value:integer` writes the class with `initialize(title:, value:)`, ivars, a template that prints each attribute, and `test/components/card.rb` calling `Cybertrain::Test.render_component`; existing files are refused unless `--force`.
- [ ] **Step 2: Implement** `cybertrain/cli/helper.rb`, `cybertrain/cli/component.rb`, the `when "helper"` / `"component"` arms in `cli.rb`'s `run_generate`, the gemspec entries, and the `help` text lines.
- [ ] **Step 3: Run** (`ruby -I. test/cli_generate_*.rb` run under CRuby; snapshot), `script/gate`, commit "CLI: generate helper and generate component".

---

## Package C: streaming responses, stream pub/sub, SSE and WebSocket endpoint, Turbo (spec 2.1 to 2.5)

**Files:**
- Create: `cybertrain/http/body_writer.rb` (`BodyWriter`, `Sink`), `cybertrain/http/sse.rb` (`SSE.event`), `cybertrain/http/websocket_server.rb` (handshake + frame loop over a `Sink`-like socket wrapper; HTTP layer only, uses `cybertrain/websocket/frame.rb` — allowed: move `frame.rb` under `cybertrain/http/`? **No**: `check-http-layer` forbids; instead `websocket_server.rb` lives in `cybertrain/stream/` and the HTTP layer only exposes the raw socket to a `BodyWriter` through `Sink#socket`), `cybertrain/stream.rb`, `cybertrain/stream/hub.rb`, `cybertrain/stream/poller.rb`, `cybertrain/stream/endpoint.rb`, `cybertrain/stream/websocket_server.rb`, `cybertrain/turbo.rb`
- Modify: `cybertrain/http/response.rb` (`body_writer`, `streaming?`, `to_http_head`), `cybertrain/http/server.rb` (`respond` streams), `cybertrain/controller.rb` (`stream(content_type:) { |out| }`), `cybertrain/config.rb` (section 8 `stream_*` keys + `stream_error`), `cybertrain/application.rb` (mount `Stream::Endpoint`, start/stop the poller with the server), `cybertrain/template/helpers.rb` (`turbo_stream_from`, `signed_stream_name`, `stream_source_path`), `cybertrain/websocket/frame.rb` (`encode` with `nil` mask), `cybertrain/test/client.rb` (`get_stream`)
- Test: `test/response_stream.rb`, `test/sse.rb`, `test/stream.rb`, `test/stream_endpoint.rb`, `test/websocket_server.rb`, `test/turbo.rb`

**Interfaces:**
- Produces: `Cybertrain::BodyWriter#write_body(sink)`; `Cybertrain::Sink#write(bytes)`, `#closed?`, `#wait_closed(seconds) -> Boolean`, `#socket` (for the WebSocket loop); `Response#body_writer=(writer)`, `#streaming?`; `Controller#stream(content_type: "text/event-stream", status: 200) { |out| }`; `Cybertrain::SSE.event(data, event: "", id: "", retry_ms: 0) -> String`.
- Produces: `Cybertrain::Stream.broadcast(name, payload) -> Integer`, `.name_for(record_or_string) -> String`, `.sign(names) -> String`, `.verify(token) -> Array<String> | nil`, `.install!`, `.prune(before)`, `.broadcast_replace_to(stream, target:, html: "", partial: "", locals: {}, component: nil)` and the other actions of spec 2.5; `Stream::Hub` (`subscribe(names) -> Subscriber`, `unsubscribe(sub)`, `deliver(id, stream, payload)`), `Stream::Subscriber#pop(timeout) -> Message | nil`, `Stream::Message(id, stream, payload)`; `Stream::Poller.start!(config)` / `.stop!` / `.running?`; `Stream::Endpoint < Middleware`.
- Produces: `Cybertrain::Turbo.replace/update/append/prepend/before/after(target, html) -> SafeString`, `.remove(target)`, `.refresh`; `target` a String or Model (`Html.dom_id` from A — **until A merges, C uses `"#{record.model_name.downcase}_#{record.id}"` in a private `Turbo.target_id` and F swaps it for `Html.dom_id`**).
- Consumes from B (at F time): `Views.render_partial(name, locals)`, `Views.render_component(component)`. C's `broadcast_*_to` with `partial:` / `component:` call them by name and wrap what they return in `SafeString.of` before handing it to a Turbo builder (rendered markup is markup, not text to escape; a plain `html:` String is escaped, a SafeString passes); C tests the `html:` path and the `partial:` path (`test/stream.rb`: a broadcast with `partial:` over an embedded `_row.html.erb` keeps the partial's elements and escapes its locals), F's blog test checks the `component:` path end to end (the `<turbo-stream>` payload holds the component's elements unescaped).

### Task C1: streaming responses

- [ ] **Step 1: Write `test/response_stream.rb`** (compiled, in the style of `test/server.rb`: a real `Server` on port 0, raw `TCPSocket` client): a handler whose `Response` has a `BodyWriter` writing three chunks sends `Transfer-Encoding: chunked`, no `Content-Length`, `Connection: close`, the three chunks framed, the `0\r\n\r\n` terminator, and the server closes; an HTTP/1.0 request gets no framing and the socket closes after the body; `HEAD` gets the head only; a writer that raises after one chunk: the connection is closed and `[ERROR]` logged, the server still answers the next connection; `Sink#wait_closed(0.2)` returns true after the client closes.
- [ ] **Step 2: Implement** `body_writer.rb`, `Response` additions (`to_http_head(head_only)` reused by `to_http`), `Server#respond` streaming branch (per spec 2.1), `Controller#stream` (sets content type, `body_writer`, `performed!`).
- [ ] **Step 3: Write `test/sse.rb`** (pure Ruby): `SSE.event("a\nb", event: "x", id: "7", retry_ms: 3000)` is `"event: x\nid: 7\nretry: 3000\ndata: a\ndata: b\n\n"`; defaults omit the fields; an `event` or `id` with a newline raises.
- [ ] **Step 4: Run**, snapshots (`script/check-http-layer` must pass), commit "HTTP: streaming responses (BodyWriter, Sink), SSE formatting, Controller#stream".

### Task C2: `Stream` table, signing, hub, poller, Turbo builders

- [ ] **Step 1: Write `test/stream.rb`** (compiled, temp SQLite): `Stream.broadcast("a", "x")` returns increasing ids and writes a row; `sign(["articles:1", "alerts"])` round-trips through `verify`; a token with a flipped signature byte, an empty token, 17 names, a 201-byte name, a name with `\n` all verify to `nil`; `name_for(record)` is `"articles:12"` and a String passes through; `Hub`: two subscribers on overlapping names each receive their messages in id order, `pop(0.05)` returns nil when idle, `unsubscribe` stops delivery, the 1001st undelivered message drops the subscriber (`Subscriber#dropped?`); `Poller.run_once(hub)` (the tick, callable in tests) delivers only rows with `id > last_id`, and `Poller.start!` / a test-side `Poller.reset!(hub)` initialise `last_id` to the current `MAX(id)` (0 on an empty table), so rows written before the poller started are never delivered live; `prune(now - 60)` deletes the old rows; `Stream.replay(names, after_id) -> Array<Message>` returns the backlog; **handoff**: `Hub#subscribe` first, then `replay(names, after)`, then `Subscriber#skip_through!(boundary)` where `boundary = max(min(after, cursor), largest replayed id)` (`cursor` being the poller `last_id` the subscriber captured at subscribe) drops queued messages with `id <= boundary`: a row inserted between the replay query and the first `pop` (insert it in the test between the two calls and run `Poller.run_once`) is received exactly once, and a row replayed and also delivered live is received once.
- [ ] **Step 2: Implement** `cybertrain/stream.rb`, `stream/hub.rb`, `stream/poller.rb` per spec 2.2 (poller thread started via a method, by `Application#serve` before `srv.start` binds the listener and never lazily; `Poller.start!` and `run_once` call `Stream.ensure_installed` first, so a fresh database without `cybertrain_messages` boots (test: start the poller against an empty temp database); `last_id` initialised to `MAX(id)`; `Hub#subscribe` sets the new `Subscriber#boundary` to the poller's `last_id` under the hub lock, `last_id` advances to a row's id only after `deliver` for it returned and under that same lock, and `deliver` skips `id <= boundary` per subscriber; `Config#stream_poll_ms` sleep, `MAX(id)` check, the poller is the one owner of `prune`, every 60 s). Tests: a row broadcast after `subscribe` but before the next tick is delivered; one polled before `subscribe` is not; one broadcast before `subscribe` and not yet polled is delivered (the boundary is the poller's cursor, so it arrives at most one poll interval late); a replay that returns no rows (`after` at the current head, and `after` below a pruned range) leaves `boundary = min(after, cursor)` and live delivery continues from there; an `after` above the current head (`Last-Event-ID: 999999`) is clamped to the subscription's cursor, so the next broadcast row is still delivered (test it).
- [ ] **Step 3: Write `test/turbo.rb`** (pure Ruby): each action's exact HTML (`<turbo-stream action="replace" target="article_1"><template>…</template></turbo-stream>`), `remove` has no template, `refresh` has neither, a Model target becomes its dom id, `html` is escaped unless `SafeString`; `Stream.broadcast_replace_to("s", target: "t", html: "<p>x</p>")` writes one row whose payload is the Turbo HTML (compiled part, in `test/stream.rb`).
- [ ] **Step 4: Implement** `cybertrain/turbo.rb` and the `broadcast_*_to` methods.
- [ ] **Step 5: Run**, snapshots, commit "Stream: SQLite-backed pub/sub, signed names, hub, poller; Turbo Stream builders".

### Task C3: the SSE endpoint and the template helpers

- [ ] **Step 1: Write `test/stream_endpoint.rb`** (compiled; a `Server` on port 0 with the `Application` stack or a minimal stack containing `Stream::Endpoint`, a `Poller` running): GET `/cybertrain/stream?s=TOKEN` answers `200 text/event-stream`, `Cache-Control: no-store`, `X-Accel-Buffering: no`; after `Stream.broadcast("a", "hello")` the client reads `id: N\ndata: hello\n\n` within 1 s; `mode=json` adds `event: a` and the JSON envelope; `Last-Event-ID: 0` replays the backlog first (subscribe, then replay, then live: a row broadcast between the replay and the first live event arrives exactly once, in id order); without `Last-Event-ID` a fresh connection gets no row the poller had already delivered when it connected, but does get a row broadcast before it connected and not yet polled (broadcast, connect, then let the poller tick), and every row broadcast after; a bad token → 403 with no body; a token signed with another secret → 403; `stream_max_connections` reached → 503; the poller not running (stop it in the test) → 503 `stream poller is not running`; a client that closes its socket while idle: the connection count drops within `stream_ping_interval` (set to 1 in the test) — Review Focus 1 and 2; the `: ping` comment appears after the interval; `stream_path = ""` → the path 404s.
- [ ] **Step 2: Implement** `stream/endpoint.rb` (`Middleware`; SSE branch builds a `BodyWriter` subclass `SSEWriter` holding the subscriber; the loop: `pop(ping_interval)` → write event or `: ping`; `sink.wait_closed(0)` each turn; ends when the sink closes, the subscriber is dropped, or the poller stops), `Config` keys and `stream_error`, `Application#build_stack` mounting, poller start in `serve` before `srv.start` (also with `CYBERTRAIN_WORKER=0`) and stop in shutdown, `Test::Client#get_stream(path, events:, timeout: 2)` (drives the writer against an in-memory `Sink`).
- [ ] **Step 3: Extend `test/controller_views.rb`** or a new `test/stream_helpers.rb`: `turbo_stream_from("alerts", @article)` renders `<turbo-stream-source src="/cybertrain/stream?s=…"></turbo-stream-source>` whose token verifies to `["alerts", "articles:1"]`; `ws: true` gives `ws://host/cybertrain/stream?s=…` from `request.base_url`; `signed_stream_name` and `stream_source_path(..., mode: "json")`.
- [ ] **Step 4: Implement** the three helper arms.
- [ ] **Step 5: Run**, snapshots, commit "Stream: SSE endpoint, config, turbo_stream_from".

### Task C4: the WebSocket endpoint

- [ ] **Step 1: Write `test/websocket_server.rb`** (compiled; connect with the existing `Cybertrain::WebSocket::Client.connect("ws://127.0.0.1:PORT/cybertrain/stream?s=TOKEN&mode=json")`): the handshake succeeds (101, correct `Sec-WebSocket-Accept`); a broadcast arrives as a text frame with the JSON envelope; `mode=raw` delivers the payload verbatim; `{"subscribe": token2}` adds a stream and is answered with `{"subscribed":[…]}`; a bad subscribe token → `{"error":"bad token"}`; a ping from the client is answered with a pong; the server pings after `stream_ping_interval`; a bad token on connect → close 1008 after the handshake; a text frame above `stream_max_message` → close 1009; `Server#stop` sends close 1000 and the client's `receive` raises `ClosedError` with code 1000; a request with `Upgrade: websocket` but a wrong version header → 400; the connection count drops after close.
- [ ] **Step 2: Implement** `stream/websocket_server.rb` (`WebSocketWriter < BodyWriter`: `write_body(sink)` runs the whole session on `sink.socket`: `Frame.parse_header`, `Frame.unmask`, `Frame.encode(opcode, payload, nil)`, `wait_readable` before reads, a `Frame::Assembler`-style reassembly reused from the client) and the `Upgrade` branch in `Endpoint` (the head is written by the Server as a 101 with the accept key and no body framing: `Response#upgrade!(headers)` marks the response so `Server#respond` writes the head and hands the socket to the writer).
- [ ] **Step 3: Run**, snapshot (`spin test test/websocket_client.rb test/websocket_subscription.rb` unchanged), commit "Stream: WebSocket endpoint".

---

## Package D: job threads, heartbeats, concurrency, lease, process roles (spec 4, 5, 8)

**Files:**
- Create: `cybertrain/lease.rb`
- Modify: `cybertrain/job.rb`, `cybertrain/scheduler.rb`, `cybertrain/config.rb` (job and lease keys), `cybertrain/main.rb` (`worker`, `feeds`), `cybertrain/application.rb` (`run_worker`, `run_feeds`), `cybertrain/background.rb` (`service_start_only`), `cybertrain/websocket.rb` (`start!(config, only:)`), `cybertrain/cli/templates.rb` (Kamal `deploy.yml` roles), `docs/deploy.md`, `docs/deploy.en.md`, `docs/deploy-kamal.md` (a "Roles" section each; `script/check-docs-i18n` must pass), `README.md` "Background work" paragraph
- Test: `test/jobs.rb` (grown), `test/job_threads.rb`, `test/lease.rb`, `test/main_roles.rb`, `test/scheduler.rb` (lease gating)

**Interfaces:**
- Produces: `Job.handle(kind, concurrency: 0) { |payload| }`; `Job.start!(config)` / `Job.stop!` (the thread pool and heartbeat thread); `Job.recover!(now)` (staleness-based); `Job.process_label -> String` (`"host:pid:boot"`); `Job.running_count(kind) -> Integer`; `Cybertrain::Lease.acquire(name, holder, now, ttl:) -> Boolean`, `Lease.release(name, holder)`, `Lease.install!`; `Scheduler.leader? -> Boolean`; `Scheduler.start!(config)` no longer adds the jobs task (Job.start! does the jobs); `Main.worker?(argv)`, `Main.feeds?(argv)`; `Application#run_worker(argv)`, `#run_feeds(names)`; `Background::Service#service_start_only(config, names) -> Boolean`; `WebSocket.start!(config, only: [])`.
- Consumes: nothing from other packages.

### Task D1: Config keys and `Lease`

- [ ] **Step 1: Write `test/lease.rb`** (compiled, temp DB): `acquire("scheduler", "a", 100, ttl: 30)` true; `acquire(..., "b", 110, ttl: 30)` false; `acquire(..., "a", 110, ...)` true (renewal); `acquire(..., "b", 131, ...)` true (expired); `release("scheduler", "b")` then `"a"` acquires at once; `install!` is idempotent.
- [ ] **Step 2: Implement** `cybertrain/lease.rb` with the spec 5 `INSERT ... ON CONFLICT ... WHERE` statement and `changes == 1`; add `Config` keys `job_threads` (env `CYBERTRAIN_JOB_THREADS`), `job_heartbeat_interval`, `job_heartbeat_stale`, `job_drain_timeout`, `scheduler_lease_ttl`, lower `job_poll_interval` to 1, extend `scheduler_error` (each at least 1; `job_heartbeat_stale > job_heartbeat_interval`).
- [ ] **Step 3: Run**, snapshot (`test/config_settings.rb` banner snapshot will change: review it), commit "Lease table and the job/scheduler configuration keys".

### Task D2: heartbeats, claimed_by, concurrency limits, staleness recovery

- [ ] **Step 1: Extend `test/jobs.rb`**: after `work_one`, the row has `claimed_by = Job.process_label` and `heartbeat_at = now`; `Job.heartbeat!(now)` updates only this process's running rows; `recover!(now)` requeues a row with `heartbeat_at = now - 301` and leaves `now - 299` alone (Review Focus 4: two labels, one stale); `install!` on a pre-existing table without the columns adds them (create the old shape by hand first, with one `running` row in it): that legacy row has `heartbeat_at IS NULL` and `recover!(now)` requeues it at once, while a row the new code claimed a second ago is left alone; `Job.handle("paid", concurrency: 1)`: with one `paid` row running, `work_one` claims a queued `other` row and not the second `paid` row; a `Handler` with `concurrency: -1` raises ArgumentError.
- [ ] **Step 2: Implement** per spec 4 (`Handler#handler_concurrency`, the `GROUP BY kind` read inside the claim transaction, `NOT IN` with bound kinds, `ALTER TABLE` guarded by `PRAGMA table_info`, `recover!`'s predicate `state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)`).
- [ ] **Step 3: Run**, snapshot, commit "Jobs: claimed_by, heartbeats, staleness recovery, per-kind concurrency".

### Task D3: the job thread pool and shutdown

- [ ] **Step 1: Write `test/job_threads.rb`** (compiled, temp DB, real threads, short intervals): with `job_threads = 2`, a handler that sleeps 1 s and one that records the time: both claimed within 0.5 s of `Job.start!`; the fast one finishes before the slow one; `Job.stop!` with `job_drain_timeout = 1` returns within 1.5 s while a 3 s job runs and leaves its row `running`; `recover!` later requeues it once the heartbeat is stale; **fenced completion**: after that requeue a second `work_one` under another `claimed_by` label claims the row, and when the original handler finishes its `finish` changes nothing (the row keeps the second claimer's `claimed_by` and state) and logs a warning; the README's "Background work" paragraph states that delivery is at least once and handlers must be idempotent; the heartbeat thread wrote `heartbeat_at` at least once during a 2 s job with `job_heartbeat_interval = 1`; `Job.start!` twice is a no-op; `Scheduler.start!` no longer registers "cybertrain jobs" (`task_summary` without it).
- [ ] **Step 2: Implement** `Job.start!(config)` (N `spawn_job_thread(i, generation)` + `spawn_heartbeat(generation)`), `Job.stop!`, `run_job_loop(i, generation)` (`work_one(Time.now.to_i)` or sleep `job_poll_interval` in 0.1 s slices checking the stop flag), remove `Scheduler.add_job_task`; `Application#serve` calls `Job.start!` after `Scheduler.start!` when `config.worker`, and `Job.stop!` first on shutdown.
- [ ] **Step 3: Run**, snapshot, `spin test test/scheduler.rb test/jobs.rb`, commit "Jobs: a pool of job threads per worker process".

### Task D4: scheduler lease and recovery ticks

- [ ] **Step 1: Extend `test/scheduler.rb`**: every tick calls `Job.recover!` at most once a minute, independently of the lease (a non-leader tick recovers too); `run_due(now)` runs recurring tasks only when `Lease.acquire("scheduler", Scheduler.holder, now, ttl:)` succeeds (seed the lease for another holder: no task runs but recovery does; expire it: the task runs); `Scheduler.leader?` follows. `Stream.prune` is not the scheduler's: the stream poller is its one owner.
- [ ] **Step 2: Implement** in `Scheduler.run_due`; `Scheduler.holder` is `Job.process_label`.
- [ ] **Step 3: Run**, snapshot, commit "Scheduler: one leader per database through a lease".

### Task D5: `worker` and `feeds` roles

- [ ] **Step 1: Write `test/main_roles.rb`** (compiled; use `Main.run` with a stub router like `test/application.rb` does, and a `Thread` that calls `Application#request_stop_roles` after 0.3 s): `Main.worker?(["worker"])`, `Main.feeds?(["feeds", "x"])`; `./app worker` prints `=> worker: 3 job threads, 0 scheduled tasks` and returns 0 after the stop; `./app feeds nosuch` prints `error: unknown feed "nosuch" (registered: …)` and returns 1; `./app feeds` with no subscriptions prints a notice and returns 0; `help` lists `worker` and `feeds`; `server?` is false for both.
- [ ] **Step 2: Implement** `Main` built-in words `worker` and `feeds`, `Application#run_worker` / `#run_feeds(names)` per spec 5 (boot, banner, `trap("TERM")`, `Job.start!`, `Scheduler.start!`, `WebSocket.start!(config, only:)` through `Background.start_only(config, names)`, wait, stop), `Background::Service#service_start_only`, `WebSocket.start!(config, only: [])` and its name check (`WebSocket.unknown_feed(names) -> String`).
- [ ] **Step 3: Kamal / docs**: `cybertrain/cli/templates.rb` `deploy.yml` gains `roles: web: …, worker: cmd: ./<name> worker` and a commented `feeds` role; `docs/deploy.md` + `deploy.en.md` + `deploy-kamal.md` "Roles" section (systemd unit for `worker`; the upgrade order: stop every old process before starting the first new one, because a pre-upgrade worker writes no heartbeat and its running job would be requeued); README "Background work" paragraph mentions `job_threads` and the roles. `script/check-docs-i18n` passes.
- [ ] **Step 4: Run**, snapshots (`test/cli_new.rb` snapshot changes), commit "Process roles: ./app worker and ./app feeds".

---

## Package E: BLOB columns, console, dbconsole (spec 6, 7)

**Files:**
- Create: `cybertrain/console.rb`, `cybertrain/console/helpers.rb`, `cybertrain/console/printer.rb`, `cybertrain/db/blob.rb`
- Modify: `cybertrain/db/sqlite_ffi.rb` (`sqlite3_bind_blob`, `sqlite3_column_bytes`, `cybertrain_sqlite_column_blob` `:binstr`), `cybertrain/db/connection.rb` (`bind` Blob arm, `read_row` BLOB arm), `cybertrain/db/sqlite_ddl.rb` (`:binary` → `BLOB`), `cybertrain/db/schema_dumper.rb` (`BLOB` → `:binary`), `cybertrain/schema/table.rb` (`binary`), `cybertrain/migration.rb` (type accepted), `cybertrain/generator/models_emitter.rb` (`:binary` → `string_or_nil`, `to_row` wraps in `DB::Blob`), `cybertrain/cast.rb` (`binary`, `binds` accepts Blob), `cybertrain/template/parser.rb` (`constants:` option), `cybertrain/main.rb` (`console`, `dbconsole`), `cybertrain/db/cli.rb` (print `<N bytes>` for a BLOB cell, if the CLI prints rows)
- Test: `test/db_blob.rb`, `test/console.rb`, `test/main_console.rb`

**Interfaces:**
- Produces: `Cybertrain::DB::Blob.new(bytes)` (`#blob_bytes -> String`); `Cast.binary(v) -> String`; schema `t.binary :name`; generated attribute `String | nil`; `Cybertrain::Console.run(input_io, output_io, config) -> Integer` (exit code); `Cybertrain::Console::UnknownModel < StandardError`; `Main` built-ins `console`, `dbconsole`.
- Consumes (by name; defined by B's emitter, stubbed in E's tests): `Gen::Console.scope(name)`, `.records(relation)`, `.create(name, attrs)`, `Gen::Console::MODEL_NAMES`. Because `cybertrain/console.rb` is required only by `bin/<app>.rb` paths that have `gen/console.rb`, the console reaches the table through `Console.table = ->(name) { Gen::Console.scope(name) }`-style lambdas set in `gen/console.rb`: **`Console.scope_builder`, `Console.records_builder`, `Console.create_builder`, `Console.model_names`** (lambdas; E defines them with raising defaults; B's `gen/console.rb` sets them). Tell B's implementer this exact list in their brief.

### Task E1: BLOB columns

- [ ] **Step 1: Write `test/db_blob.rb`** (compiled, temp DB): `create_table :docs do |t| t.binary :body; t.string :note end` yields DDL `"body" BLOB`; `c.execute("INSERT INTO docs (body, note) VALUES (?, ?)", [Cybertrain::DB::Blob.new(bytes), "\xff\xfe".b])` with `bytes` = `"\0ab" + 70,000 random bytes` round-trips byte for byte (`bytesize` and `==`), `typeof(body)` is `blob`, `typeof(note)` is `text` (Review Focus 5); an empty blob round-trips as `""`; the dumper prints `t.binary "body"`; a generated model (hand-written in the test, as `test/db_integration.rb` does) with a binary attribute saves and reloads the bytes; `Cast.binary(nil)` is `""`.
- [ ] **Step 2: Implement** per spec 6 (`ffi_func :sqlite3_bind_blob, [:ptr, :int, :str, :int, :ptr], :int` with the byte length and `-1`; `cybertrain_sqlite_column_blob(stmt, col) -> :binstr` via `sp_ffi_bin_len` as `GzipFFI.cybertrain_bytes_at` does; `Connection#bind` `when DB::Blob`; `read_row` `when SQLite3::BLOB`; `Cast.binds`; `models_emitter` `:binary` arm). Note: `:str` FFI arguments are NUL-terminated by Spinel; if `sqlite3_bind_blob` through `:str` cuts at NUL, write a `ffi_source` C helper taking the bytes through `:str` + explicit length (check how `cybertrain_gunzip_bounded` passes a body with NULs) and record the finding as a NOTES rule.
- [ ] **Step 3: Run**, snapshot, `spin test test/db_sqlite.rb test/db_integration.rb test/cli_scaffold.rb`, commit "DB: binary (BLOB) columns".

### Task E2: the console

- [ ] **Step 1: Write `test/console.rb`** (compiled, temp DB with an `articles` table and a hand-written `Article` / `ArticleRelation` as `test/db_integration.rb` has, plus the four `Console.*_builder` lambdas set in the test): feeding lines through a `StringIO`: `Article.count` prints `0`; `Article.create(title: "x")` prints `#<Article id: 1, title: "x", …>`; `Article.where(title: "x").count` → `1`; `Article.find(1).title` → `"x"`; `Article.order(id: :desc).limit(1).to_a` prints one record and `1 record`; `_` holds the last value; `Article.find(9)` prints `Cybertrain::RecordNotFound: …` and the loop continues; `Nope.count` prints `UnknownModel: no model "Nope" (models: Article)`; `sql "SELECT count(*) AS n FROM articles"` prints a table; `tables`; `help`; a line that does not parse prints the SyntaxError; `exit` returns 0; EOF returns 0; `Article.find(1).update(title: "y")` then `Article.find(1).title` → `"y"`; `Article.find(1).destroy` → `true`; a 100-byte value is cut at 80 with `…`.
- [ ] **Step 2: Implement**: `Template::Parser` `constants: true` option producing a `K_CONST` node (the default keeps today's error); `Console::Helpers < Template::Helpers` (`helper_call` for `sql`, `tables`, `help`, `_`; `call_object_method` arms for `Cybertrain::Relation` and the record methods of spec 7, and a `constant(name)` hook the interpreter calls for `K_CONST`); `Console::Printer.format(value) -> String`; `Console.run(input, output, config)` reading with `gets`, printing the production warning when `config.production?`.
- [ ] **Step 3: Run**, snapshot, commit "Console: an expression console over the generated models".

### Task E3: `./app console` and `./app dbconsole`

- [ ] **Step 1: Write `test/main_console.rb`** (compiled; `Main.run("x", ["console"], ...)` with STDIN replaced by an `IO.pipe` holding `"exit\n"` — if `$stdin` cannot be reassigned under Spinel, `Console.run` takes the IO and `Main` passes `$stdin`; test `Console.run` directly and only check that `Main.run` returns 0 for `console` with an empty pipe): `help` lists `console` and `dbconsole`; `server?(["console"])` is false; `dbconsole` with `PATH` emptied prints `sqlite3 not found: install the sqlite3 CLI` and returns 1.
- [ ] **Step 2: Implement** the two built-in words in `Main` (pool of one, `DB.connect`, no scheduler); `dbconsole` with `Process.spawn("sqlite3", path)` + `Process.wait` and `$?.exitstatus` (NOTES rule 75), `Errno::ENOENT` → the message.
- [ ] **Step 3: Run**, snapshot, commit "Main: console and dbconsole".

---

## Package F: integration, blog example, docs, verification (spec 9, 12; runs after A to E are merged)

**Files:**
- Modify: `docs/design.md` (D1, 2.3, 8, D5, D9, D28, D33, new D36 to D41, section 13), `README.md`, `docs/guide/realtime.md` (new) and its `fr/ja/ru/zh` copies, `docs/guide/template-language.md` translations, `docs/guide/background-and-operations.md` (+ translations), `docs/guide/models.md` (+), `docs/guide/testing.md` (+), `docs/guide/index.md` / `README.md` under guide (link the new page), `spikes/NOTES.md`, `examples/blog/**`, `cybertrain/turbo.rb` (`Html.dom_id` swap), `cybertrain/version.rb` (0.5.0: a new subsystem) and `spin.toml`

### Task F1: merge and compile

- [ ] Merge A to E into the branch (worktree branches), resolve the `helper_call` / `Config` / `main.rb` / `application.rb` arms, then `spin test` (whole suite) and `script/gate`. Fix what the merge broke; a snapshot that changed through the merge is regenerated and read.
- [ ] Swap `Turbo.target_id` for `Html.dom_id`; run `spin test test/turbo.rb`.
- [ ] Commit "Merge phase 1 packages".

### Task F2: the blog example

- [ ] Add `examples/blog/app/helpers/comments_helper.rb` (`comment_author(comment)` → `tag.strong`), `app/components/comment_component.{rb,html.erb}` (renders one comment with `dom_id`), `turbo_stream_from @article` on `articles/show.html.erb` with the comment list wrapped in `<div id="comments">` (the broadcast's target: without it Turbo has nowhere to append), the Turbo script (`@hotwired/turbo` 8, pinned, with an integrity hash) in `layouts/application.html.erb` (what makes `<turbo-stream-source>` open its connection; the layout loaded no JavaScript before), `Stream.broadcast_append_to(@article, target: "comments", component: CommentComponent.new(comment: @comment))` in `CommentsController#create`; regenerate `gen/`; extend `test/comments.rb` (the component HTML on the page; the page carries the `<turbo-stream-source>`, the `#comments` target and the Turbo script tag; a `cybertrain_messages` row after the POST whose payload holds `<turbo-stream action="append" target="comments">`); `cd examples/blog && spin test`; `examples/blog/README.md` paragraph.
- [ ] Commit "Blog: a comment component, a helper and a Turbo Stream broadcast".

### Task F3: docs

- [ ] design.md per spec 9 (each new D in the "Decision / Reason / Rejected / Consequences" shape, 15 to 40 lines each); README "Not built" sentence → "Not built: an asset pipeline, i18n, mailer classes, HTTP/2"; `docs/guide/realtime.md` (SSE with `EventSource`, WebSocket with `WebSocket` and the JSON control messages, Turbo, broadcasting from a job, roles, the limits) and translations; the other guide pages' additions and translations; `script/check-guide-i18n`, `check-docs-i18n`, `check-version-mentions` pass; NOTES rules found by A to E consolidated and numbered.
- [ ] Commit "Docs: phase 1 (realtime, components, helpers, roles, BLOB, console)".

### Task F4: verification

- [ ] `spin test` (all), `cd examples/blog && spin test`, `script/gate`, `ruby script/check-reserved-names`, `ruby script/check-http-layer`; the manual check of spec 12.3 with the compiled blog: the two-browser-tab check (SSE, then `ws: true`) is done on a machine with a browser and recorded in the pull request body (the session running this plan has none, so it covers what the browser would show by other means: the blog test asserts the page's `<turbo-stream-source>`, its `#comments` target and the Turbo script tag, and the transport is driven directly: `cybertrain build` in `examples/blog`, two `curl -N` clients on the SSE path while a comment is posted, and the same comment received over WebSocket by a small compiled program (`script/ws-smoke.rb`, or a one-off `spin run` program in the scratch directory, connecting `Cybertrain::WebSocket::Client.connect` to `ws://127.0.0.1:PORT/cybertrain/stream?s=TOKEN` where TOKEN is cut out of the `<turbo-stream-source src="…?s=TOKEN">` element the article page rendered: the same signed token serves SSE and WebSocket, and the blog keeps its SSE element); `./dist/blog worker` + `./dist/blog server` with `CYBERTRAIN_WORKER=0`; `./dist/blog console`), recorded in the pull request body.
- [ ] Bump `Cybertrain::VERSION` and `spin.toml` to 0.5.0 if `script/check-version-mentions` allows; otherwise leave for the release commit.
