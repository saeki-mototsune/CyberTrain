# Phase 1 of the Rails-gap programme: realtime delivery, view components and helpers, concurrent jobs, process roles, BLOB columns, a console

Date: 2026-11-05. Status: agreed in the grilling session of 2026-11-05 (8
questions answered by the maintainer; the remaining judgement calls were
delegated with the rule "pick whatever is closer to Rails and better for the
developer", and are marked "(delegated)" below).

## 0. Context and scope

A survey dated 2026-11-05 ("fin_dash を Rails から CyberTrain へ移行するための
不足機能") listed 120 things CyberTrain lacks for porting fin_dash, a Rails
8.1 market dashboard: 14 of them need framework changes ("必須"), 47 are
large, 59 small. The maintainer decided:

- **D1 ("porting existing Rails applications is out of scope") is
  withdrawn.** CyberTrain now aims to be a Rails replacement for new and
  existing applications, within Spinel's constraints. docs/design.md is
  revised accordingly (section 9 below).
- The 120 items are delivered in **five phases**, each with its own design
  document, plan and pull request, in dependency order:
  1. **This document.** The 14 "必須" items, which unblock everything else:
     browser delivery (RT-1 to RT-6), view components, application helpers,
     template grammar and `tag` (V-1 to V-4), concurrent jobs (J-1, with
     J-7), process roles (P-1), BLOB columns (D-1), a console (O-1).
  2. Data layer: decimal / json / datetime columns, Range `where`,
     multi-column `pluck`, bulk upsert, aggregates, `includes`, validators,
     associations, symmetric encryption.
  3. Jobs, delivery and outbound: cron schedules, job classes, retry
     policies, a failed-jobs page, a cache store, HTTP client (gzip,
     redirects, large and streamed bodies), feed timers and restarts.
  4. Web layer: `namespace`, `resource` blocks, formats, assets (digests,
     importmap), forms, number formatting, i18n, authentication extras
     (bcrypt, reset, lockout).
  5. Tests and operations: setup / teardown, frozen time, component tests,
     assertions, error reporting, log tags.

Everything below is phase 1. Items from later phases are named only where a
phase-1 design must leave room for them.

Two criteria decided every judgement call: **closer to Rails** (vocabulary,
defaults, file layout) and **better developer experience** (fewer steps,
fewer surprises). Where Spinel forbids the Rails mechanism, the Rails
vocabulary is kept and the mechanism is the framework's established one:
build-time generation from a lexical scan into `case` tables (design.md D4,
D8, D9), never a computed `send` (spikes/NOTES.md rule 2).

## 1. The decisions in one table

| # | Question | Decision |
| --- | --- | --- |
| Q1 | How to cut the 120 items | Five phases in dependency order; this is phase 1 |
| Q2 | Delivery transport | Both Server-Sent Events and a WebSocket server, on one pub/sub |
| Q3 | Cross-process medium | A SQLite table (`cybertrain_messages`), polled every 100 ms |
| Q4 | Subscription authorisation | Signed stream names only (as Turbo); the endpoint checks a signature, never a session |
| Q5 | Rendering outside a request | Yes: `Views.render_partial`, Turbo Stream builders, `Stream.broadcast_*_to` |
| Q6 | Application helpers and components | The generator scans `app/helpers` and `app/components` and emits `case` tables |
| Q7 | Template grammar | `case/when`, block-taking enumerable methods, a `tag` builder; no constants |
| Q8 | Process roles | Subcommands `server` / `worker` / `feeds`; several workers per database (heartbeats, a scheduler lease) |
| (delegated) | Job concurrency | A pool of `job_threads` (default 3) green threads per worker process; `Job.handle(kind, concurrency: n)` |
| (delegated) | BLOB columns | `t.binary`; a String of bytes in Ruby; `DB::Blob` marks a bind as a blob |
| (delegated) | Console | `./app console` runs the template expression language over the generated models; `./app dbconsole` opens `sqlite3` |

## 2. Realtime delivery

### 2.1 Streaming responses (RT-2)

Today `Response` is one String and the Server writes `to_http` once. A
response can now carry a **body writer** instead of a body:

```ruby
class Cybertrain::Response
  # Set by Controller#stream; nil for an ordinary response.
  attr_reader :body_writer   # BodyWriter | nil
  def streaming? = !@body_writer.nil?
end

class Cybertrain::BodyWriter          # base class, typed like Middleware / Background::Service
  def write_body(sink) = nil           # called on the connection thread after the head is sent
end

class Cybertrain::Sink                 # wraps the socket for a writer
  def write(bytes)                     # one chunk (Transfer-Encoding: chunked framing is the Sink's job)
  def closed?                          # true once the client went away (EPIPE / ECONNRESET / EOF seen)
  def wait_closed(seconds)             # true if the client closed within the wait (wait_readable + readpartial EOF)
end
```

- `Server#respond`: when `response.streaming?`, it sends the head with
  `Transfer-Encoding: chunked` (HTTP/1.1) or no framing and `Connection:
  close` (HTTP/1.0), then calls `body_writer.write_body(sink)`, then the
  terminating chunk, then closes the connection (no keep-alive after a
  stream; one stream per connection is what every client does). Exceptions
  from the writer are logged `[ERROR]` and end the connection; nothing can
  be sent to the client at that point.
- Controller API, Rails' `ActionController::Live` shape without the module:
  ```ruby
  def events
    stream(content_type: "text/event-stream") do |out|   # out: Cybertrain::Sink
      out.write("data: hello\n\n")
    end
  end
  ```
  `stream` marks the response performed (like `render`). `Cybertrain::SSE`
  (`SSE.event(data, event: "", id: "", retry_ms: 0)` -> String; `retry` is a
  Ruby keyword, so the field is `retry_ms`) formats
  events; a controller writes `out.write(SSE.event(json))`.
- A streaming response has no `Content-Length`; `head?` requests get the
  head only. The HTTP parser is untouched (inbound chunked bodies stay 411).

### 2.2 The stream pub/sub (RT-3, RT-4)

`cybertrain/stream.rb`, module `Cybertrain::Stream`:

```ruby
Stream.broadcast(name, payload)          # name: String; payload: String (JSON or HTML). Returns the message id.
Stream.name_for(record)                  # "articles:12" (table_name + ":" + id); a String passes through
Stream.sign(names)                       # Array<String> -> token "articles:12,alerts--<hmac hex>" (base64url of the names, then "--", then HMAC-SHA256 hex of that with Config#secret)
Stream.verify(token)                     # token -> Array<String> | nil (nil on a bad or missing signature; names are validated: 1..200 bytes, no control characters, at most 16 per token)
Stream.install!                          # CREATE TABLE IF NOT EXISTS cybertrain_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, stream TEXT NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL) + INDEX (stream, id)
Stream.prune(before)                     # DELETE WHERE created_at < before; the poller runs it every 60 s with Config#stream_retention (default 60 s)
```

- Every broadcast goes through the table, also from the web process itself:
  with two web processes both must deliver, and the table gives one order
  and one id space. Latency is bounded by the poll interval.
- **The poller** (`Stream::Poller`, one thread per process that has
  subscribers, started lazily by the first subscription and stopped with the
  server) keeps `last_id`, **initialised to the current `MAX(id)` (0 on an
  empty table) when the poller starts**: a fresh subscription receives only
  rows written after it, never the backlog within retention, unless it asks
  for a replay (below). Every `Config#stream_poll_ms` (default 100) it
  runs `SELECT MAX(id) FROM cybertrain_messages`; when it is larger than
  `last_id` it reads `SELECT id, stream, payload FROM cybertrain_messages
  WHERE id > ? ORDER BY id` and hands each row to the in-process hub. A
  `PRAGMA data_version` check was considered and rejected: its value is per
  connection, and the pool hands out any connection, so it cannot be
  compared across polls. `MAX(id)` on the primary key is an O(1) B-tree
  descent and needs no dedicated connection.
- **The hub** (`Stream::Hub`): `subscribe(names) -> Subscriber`,
  `unsubscribe(subscriber)`, `deliver(id, stream, payload)`. A `Subscriber`
  owns a `Queue` of `Message` (id, stream, payload) and the set of names it
  listens to. Delivery pushes onto every matching queue; the connection
  thread pops with a timeout (`Queue#pop(timeout:)` if Spinel has it,
  otherwise a `ConditionVariable` wait: the implementer checks and records
  the result in spikes/NOTES.md). A queue longer than
  `Config#stream_max_backlog` (1000) messages drops the subscriber: the
  connection is closed and the client reconnects (as Action Cable does when
  a client cannot keep up).
- `Last-Event-ID` (SSE) or `?after=<id>` (WebSocket) replays the rows with
  `id > given` for the subscribed streams from the table (within retention)
  before live delivery, so a reconnecting EventSource misses nothing that is
  still in the table. **The handoff is ordered so that no row is lost or
  doubled**: the connection first calls `Hub#subscribe` (its queue starts
  filling with live rows), then runs the replay query, then sets `boundary =
  max(given, last replayed id)` and drains its queue skipping every message
  with `id <= boundary`. A row inserted between the replay query and the
  subscription cannot exist (the subscription came first); a row both
  replayed and delivered live is dropped by the boundary. Acceptance: a
  fresh connection with no `Last-Event-ID` receives only rows broadcast
  after it connected; a reconnect with `Last-Event-ID` receives each row
  with a larger id exactly once, including one broadcast between the replay
  query and the first live event.

### 2.3 The delivery endpoint: SSE and WebSocket (RT-1, RT-5)

One middleware, `Stream::Endpoint`, mounted by `Application#build_stack` at
`Config#stream_path` (default `"/cybertrain/stream"`, `""` turns the whole
feature off). It answers two kinds of request at that path:

- **`GET` with `Accept: text/event-stream`** (or without `Upgrade`): a
  streaming response (2.1) in SSE format. Query: `s=<token>` (repeatable),
  `mode=raw|json`. The response carries `Cache-Control: no-store`,
  `X-Accel-Buffering: no`. A comment line `: ping` goes out every
  `Config#stream_ping_interval` seconds (15) so proxies keep the connection.
- **`GET` with `Upgrade: websocket`**: RFC 6455 server handshake (the key
  from `websocket/frame.rb`'s `accept_key`), then a frame loop on the same
  connection thread: `wait_readable` before every read (NOTES rule 20),
  ping every `stream_ping_interval` seconds, pong answered, close handshake
  with code 1000 on server stop and 1008 on a bad token, text frames from
  the client parsed as JSON control messages (below), binary frames
  ignored, messages above `Config#stream_max_message` (65536 bytes)
  rejected with 1009. Masked frames from the client are unmasked with the
  existing `Frame.unmask`; frames to the client are unmasked
  (`Frame.encode(opcode, payload, nil)`: the encoder gets a `nil` mask key
  option, the one change to frame.rb). Extensions and subprotocols are not
  negotiated (a request for `permessage-deflate` is answered without it,
  which RFC 6455 allows).
- Both transports share **two modes**:
  - `mode=raw` (default): the payload goes out verbatim. SSE: `data:` lines
    and an `id:`; no `event:` field, so Turbo's `<turbo-stream-source>`
    (which listens to the default `message` event) and Turbo over
    WebSocket (which takes `event.data` as `<turbo-stream>` HTML) both work
    unchanged. This is the Turbo path.
  - `mode=json`: an envelope `{"stream":"indicators","id":123,"data":"..."}`
    per message (SSE: `event: <stream name>` as well, so
    `addEventListener(name, ...)` dispatches by stream). Over WebSocket the
    client may also send `{"subscribe":"<token>"}` and
    `{"unsubscribe":"<token>"}` to change its streams; the server answers
    `{"subscribed":[names]}` / `{"error":"bad token"}`. This is the path for
    hand-written JavaScript (fin_dash's indicator and order-book channels).
- **Authorisation is the signature** (Q4). A token names the streams a page
  may read; the page that could render the token had the right to read
  them. A per-user stream is `Stream.name_for(current_user)` rendered only
  for that user. The endpoint never reads the session or the database for
  authorisation. Tokens do not expire (as Turbo's); rotating
  `Config#secret` invalidates all of them.
- Connection limits: `Config#stream_max_connections` (default 1000) per
  process; above it the endpoint answers 503 (SSE) or closes with 1013 (WS).
- The endpoint is served only by the `server` role, and only when
  `stream_path` is non-empty. `Test::Client` can drive the SSE path with a
  bounded number of events (`client.get_stream(path, events: 3)` returns
  after 3 events or a timeout) and the WebSocket path through the existing
  `WebSocket::Client` against a `Server` started on an ephemeral port
  (`test/stream_endpoint.rb`).

### 2.4 Template helpers for subscribing (RT-6, client side)

Built into `Template::Helpers`, named as turbo-rails names them:

| Helper | Output |
| --- | --- |
| `turbo_stream_from(*streamables)` | `<turbo-stream-source src="/cybertrain/stream?s=TOKEN"></turbo-stream-source>` (one element, one token for all names; path from `Config#stream_path`; `ws: true` keyword gives a `ws://` / `wss://` URL built from `request.base_url`) |
| `signed_stream_name(*streamables)` | the token, for hand-written JavaScript |
| `stream_source_path(*streamables, mode: "json")` | the SSE / WS URL with `mode=json`, for hand-written JavaScript |

A streamable is a String (used as is) or a Model (`Stream.name_for`).

### 2.5 Rendering outside a request, Turbo Stream builders, broadcast shortcuts (RT-6, server side)

```ruby
Cybertrain::Views.render_partial("articles/article", article: article)   # -> String (HTML), no request
Cybertrain::Views.render_component(CardComponent.new(title: "x"))        # -> String

Cybertrain::Turbo.replace(target, html)   # <turbo-stream action="replace" target="..."><template>html</template></turbo-stream>
Cybertrain::Turbo.update / append / prepend / before / after (target, html)
Cybertrain::Turbo.remove(target)
Cybertrain::Turbo.refresh                 # <turbo-stream action="refresh"></turbo-stream>
# target: a String or a Model (dom_id)

Cybertrain::Stream.broadcast_replace_to(stream, target:, partial:, locals: {})   # renders, wraps, broadcasts; also component:
Cybertrain::Stream.broadcast_update_to / append_to / prepend_to / before_to / after_to
Cybertrain::Stream.broadcast_remove_to(stream, target:)
Cybertrain::Stream.broadcast_refresh_to(stream)
```

- `Views.render_partial` builds the application's helpers (3.1) with **no
  controller**. `Template::Helpers` holds `@controller` as `Controller |
  nil`; the helpers that need a request (`csrf_token`, `csrf_meta_tags`,
  `params`, `flash`, `request_path`, `url_for` of an absolute URL, `*_url`
  helpers, `turbo_stream_from ws: true`) raise
  `Cybertrain::Views::OutsideRequest, "csrf_token needs a request"`. Path
  helpers (`article_path`) work: `Views.url_resolver` is process-wide.
- The locals Hash is `Hash<Symbol, polymorphic>` as `render "x", post:`
  takes today; strict locals are checked as in a request.
- This also lifts D27's "no templates for mail bodies": a mailer can call
  `Views.render_partial("mail/welcome", user: u)` (HTML mail itself stays
  phase 3).

## 3. Views: application helpers, components, grammar, `tag`

### 3.1 Application helpers (V-2)

Rails: modules under `app/helpers` are mixed into the view. CyberTrain keeps
the layout and the module form; the generator supplies the dispatch.

- `app/helpers/**/*.rb` holds plain modules:
  ```ruby
  module PricesHelper
    def price(value, unit: "USD", precision: 2)
      Cybertrain::Html.tag("span", class: "price") { "#{Cast.float(value).round(precision)} #{unit}" }
    end
  end
  ```
- `Gen::HelperScan` reads the files lexically (as `ControllerScan` does):
  `module Name` lines and public `def name(params)` lines (not `def self.`,
  not after `private`). The parameter list is parsed into: required
  positionals, optional positionals (`a = expr`), required keywords (`k:`),
  optional keywords (`k: expr`), `&block`. `*rest`, `**opts` and
  `...` are reported as a generator error naming the file and line ("helper
  parameters must be named; templates pass values by position or
  keyword"). The same `def` name in two helper modules is an error too (as
  Rails' silent override is a classic bug).
- `Gen::HelpersEmitter` writes `gen/helpers.rb`:
  ```ruby
  class ApplicationHelpers < Cybertrain::Template::Helpers
    include PricesHelper
    def app_helper_call(name, args, kwargs, block, interp, env)
      case name
      when "price"
        helper_arity!(name, args, 1, 1)
        if kwargs.key?("unit") && kwargs.key?("precision") then price(args[0], unit: kwargs["unit"], precision: kwargs["precision"])
        elsif kwargs.key?("unit") then price(args[0], unit: kwargs["unit"])
        elsif kwargs.key?("precision") then price(args[0], precision: kwargs["precision"])
        else price(args[0])
        end
      else super
      end
    end
  end
  Cybertrain::Views.helpers_builder = ->(controller) { ApplicationHelpers.new(controller) }
  ```
  Optional parameters keep Ruby's semantics (an omitted keyword gets the
  method's own default) by emitting one arm per subset of the optional
  parameters that are present; a `def` with more than 3 optional parameters
  (8 arms) is a generator error asking to split it. Arguments arrive as the
  template's polymorphic values; helpers narrow them with `Cast` (`Cast.str`,
  `Cast.int`, `Cast.float`, `Cast.model`, `Cast.array`) or `case`. A `&block`
  parameter receives a block that returns the captured template content as
  a `SafeString` (`interp.capture(block, env)`); `yield` in the helper takes
  no arguments.
- `Template::Helpers#helper_call`'s `else` branch calls
  `app_helper_call`, whose base implementation raises `undefined helper`.
  Controllers and `Views.render_partial` build helpers through
  `Views.helpers_builder` (a lambda returning `Template::Helpers`, default
  `->(c) { Template::Helpers.new(c) }`); `gen/app.rb` requires
  `gen/helpers.rb`, which sets it. Dispatch through the base class, as
  `Middleware` and `Background::Service` do.
- Helpers written in Ruby call the framework through Ruby-shaped APIs, not
  the template-facing `(args, kwargs)` methods: `Cybertrain::Html.tag`,
  `Html.escape`, `Html.safe_join`, `Html.class_names`, `Html.dom_id`,
  `SafeString.of`, the generated URL helpers (`Gen::UrlHelpers` is included
  into `ApplicationHelpers`), and `link_to_path(text, path, attrs = {})` /
  `button_to_path` (new Ruby-shaped forms of the two template helpers).
- `cybertrain generate helper NAME` writes an empty module and a test; the
  scaffold is unchanged.

### 3.2 Components (V-1)

ViewComponent's shape: a class with keyword arguments and a template beside
it.

- `app/components/card_component.rb`:
  ```ruby
  class CardComponent < Cybertrain::Component
    def initialize(title:, value: 0, tone: "neutral")
      @title = title
      @value = value
      @tone = tone
    end

    def value_text = @value.to_s
    def tone_class = "card--#{@tone}"
  end
  ```
  and `app/components/card_component.html.erb`:
  ```erb
  <%= tag.div(class: class_names("card", tone_class)) do %>
    <h3><%= title %></h3><p><%= value_text %></p><%= content %>
  <% end %>
  ```
- `Gen::ComponentScan` picks up, per file: the class line (`class X <
  Cybertrain::Component` or `< ApplicationComponent`), `@x =` assignments
  (ControllerScan's regex: these become the template's locals, as a
  controller's ivars do), arity-0 public `def`s (ModelScan's regex: these
  become callable by name), and the `initialize` keyword parameters (for
  the construction arm). `Gen::ComponentsEmitter` writes
  `gen/components.rb`: per component `def view_assigns` (`{"title" =>
  @title, ...}`), `def call_view_method(name)` (`case name when :value_text
  then value_text ...`), and the table
  ```ruby
  module Gen::Components
    def self.build(name, kwargs)        # kwargs: Hash<String, polymorphic> from the template
      case name
      when "card" then CardComponent.new(title: kwargs.fetch("title"), ...)   # optional keywords: subset arms, as 3.1
      else raise Cybertrain::Component::Unknown, "no component 'card' (app/components/card_component.rb, then `spin run gen`)"
      end
    end
  end
  ```
  Construction from a template passes polymorphic values; the component
  narrows them in `initialize` if it needs a type.
- Template side: `<%= render component: "card", title: "x", value: v %>`
  and, with content, `<%= render component: "card", title: "x" do %> ...
  <% end %>` (the block becomes the component's `content`, a `SafeString`,
  `""` when absent). Constants stay out of templates (Q7), so the component
  is named by its snake-case string as a partial is; `render "x"` stays the
  partial. From Ruby: `Views.render_component(CardComponent.new(...))`,
  `component.render_in(view)` is not offered (there is no view object).
- Rendering: `Component#render_with(helpers, content)` resolves the template
  `components/card_component` (`Views` gets a second root, `app/components`,
  for names starting with `components/`; `ViewsEmitter` embeds
  `app/components/**/*.erb` under that prefix), builds the env from
  `view_assigns` plus `"content"`, and renders without layout. A component
  renders other components and partials. Depth counts against
  `max_render_depth` like partials.
- `cybertrain generate component NAME [attr...]` writes the class, the
  template and a test (`Test` gets `render_component` in 3.5).

### 3.3 Template grammar additions (V-3)

Parser, INode and interpreter changes (docs/guide/template-language.md is
updated with every rule below):

- **`case`**: `<% case expr %><% when a, b %>…<% when c %>…<% else %>…<% end %>`.
  Whitespace-only text between `case` and the first `when` is allowed and
  dropped. Comparison is the interpreter's `==` (`compare` for numbers,
  value equality for strings and symbols, identity otherwise). `when` with
  no `case` is a `SyntaxError` naming the line; `then` stays reserved.
- **Blocks on method calls**: a call with a receiver may take `{ |x| expr }`
  or `do |x| … end` (one or two parameters). Which methods accept them is
  fixed per type:
  - Array: `map`, `select`, `reject`, `find`, `any?`, `all?`, `none?`,
    `sum`, `sort_by`, `min_by`, `max_by`, `group_by`, `each_slice(n)`,
    `count`, plus `each`/`each_with_index` as today. `each_with_object` and
    `inject` are left out: templates cannot mutate an accumulator, and the
    error is the ordinary "undefined method".
  - Hash: `map`, `select`, `reject`, `any?`, `all?`, `sum`, `sort_by`, `find`
    (two parameters: key, value).
  - Without a block: Array `sum`, `min`, `max`, `sort`, `uniq`, `compact`,
    `flatten`, `take(n)`, `drop(n)`, `each_slice(n)` (returns an Array of
    Arrays), `zip`, `with_index`-free `each_with_index` as today; Hash
    `to_a`, `sort_by` with block only.
  - `{ }` blocks hold one expression; `do … end` blocks hold statements and
    their value is the last `<%= %>`-free expression statement, or the
    captured text when the block is used for its output (`tag` and helper
    blocks). Rule: for enumerable methods the block's **value** is the last
    statement's value; for `tag.*`, `render component:` and helper calls the
    block's **output** is captured. The parser knows which from the method
    name on the receiverless/`tag` side; the interpreter raises
    `"map's block must have a value"` when a `do` block's last statement is
    not an expression.
  - `sum` of an empty Array is `0`; `sum` mixing Integer and Float gives a
    Float; `sum` of Strings is a `RuntimeError` (use `join`).
  - Block parameters shadow and are removed after, as `each`'s are.
- **`tag` builder** (V-4): `tag` with no receiver evaluates to a
  `Html::TagBuilder` value; `tag.div(...)`, `tag.span("text", class: "x")`,
  `tag.input(type: "text", disabled: true)`, `tag.path(d: "…")`: any element
  name (`[a-z][a-z0-9-]*`, so SVG and custom elements work; `tag.p`,
  `tag.a`), rendered through `Html.tag(name, attrs, content)`:
  - Void elements (`area base br col embed hr img input link meta source
    track wbr`) render `<br>` with no closing tag; content for them is a
    `RuntimeError`.
  - Attributes: String keys and Symbol keys; `nil` and `false` drop the
    attribute; `true` renders the bare attribute (`disabled`); `data:` and
    `aria:` Hashes nest to `data-key="v"` (underscores become dashes, as
    Rails); Array values join with a space (`class: ["a", "b"]`); every value
    is escaped with `Html.escape` (a `SafeString` value is escaped too, as
    Rails does for attribute values).
  - Content: the positional String argument (escaped) or the block's output
    (`SafeString`, not escaped again).
  - `tag.div` without content or block renders `<div></div>`.
- **New built-in helpers**: `content_tag(name, content, attrs)`,
  `safe_join(array, sep = "")`, `class_names(*values)` (Strings, Arrays,
  `{ "name" => cond }` Hashes; Rails' `token_list` semantics),
  `dom_id(record, prefix = "")` (positional, as Rails: `dom_id(@article)` is
  `"article_12"`, a new record `"new_article"`, `dom_id(@article, "edit")`
  `"edit_article_12"`), and the three from 2.4. `Html.dom_id(record, prefix =
  "")` is the Ruby-side form.
- Constants, `while`, `def`, `return`, `rescue` stay out; the error messages
  are unchanged.

### 3.4 What does not change

Partials, layouts, `content_for`, `form_with`, strict locals, escaping, the
per-type method table for scalars, `link_to` / `button_to`, and the
development error page. The 128-literal rule and the "no computed `send`"
rule stand: every new dispatch is a `case` on a literal name.

### 3.5 Tests for views

`Cybertrain::Test` gains `render_partial(name, locals)` and
`render_component(component, content: "")` (thin wrappers around `Views`)
so an application can snapshot-test a component without a controller
(T-5's `render_inline`). `assert_includes` on the String is the assertion.

## 4. Jobs: concurrency (J-1, J-7)

Rails' Solid Queue runs several job threads per worker process. CyberTrain
does the same with green threads:

- `Config#job_threads` (`CYBERTRAIN_JOB_THREADS`, default 3, at least 1): the
  worker starts that many **job threads**, each looping: claim one due job
  (`Job.work_one`), run it, repeat; with nothing due, sleep
  `Config#job_poll_interval` (default lowered from 5 to **1** second: a job
  enqueued by a request should start within a second, as it does on Rails).
  `Job.work_one` is unchanged in shape; its claim is already exclusive.
- The **scheduler thread** keeps only the recurring tasks and the
  housekeeping ticks (job recovery, message pruning, lease renewal). It no
  longer runs jobs, so a long job never delays a `Scheduler.every` task; a
  long *task* still delays other tasks (tasks that take time should
  `Job.enqueue`; the README says so). Cron and timers are phase 3.
- **Per-kind concurrency** (J-7): `Job.handle(kind, concurrency: n) { ... }`
  (default 0 = unlimited). The claim transaction first reads `SELECT kind,
  COUNT(*) FROM cybertrain_jobs WHERE state = 'running' GROUP BY kind` and
  excludes the kinds at their limit from the `SELECT ... queued` (`AND kind
  NOT IN (?, ?)`), so a paid-API job never runs twice at once across all
  worker processes.
- **Heartbeats and recovery, for several worker processes** (Q8): the table
  gains `claimed_by TEXT` and `heartbeat_at INTEGER` (`install!` adds them
  with `ALTER TABLE ... ADD COLUMN` when `PRAGMA table_info` lacks them, so
  an existing database upgrades in place). A claim writes `claimed_by =
  "<hostname>:<pid>:<boot epoch>"` and `heartbeat_at = now`. A **heartbeat
  thread** per worker process runs `UPDATE cybertrain_jobs SET heartbeat_at
  = ? WHERE state = 'running' AND claimed_by = ?` every
  `Config#job_heartbeat_interval` seconds (30). `Job.recover!(now)` requeues
  only `running` rows whose `heartbeat_at IS NULL OR heartbeat_at < now -
  Config#job_heartbeat_stale` (300 s); the scheduler runs it at start and
  every 60 s in every process that runs jobs, leader or not. The `IS NULL`
  arm covers rows that were `running` when the table was upgraded (they have
  no heartbeat and their process is from before the upgrade); every claim
  made by the new code writes a heartbeat, so a NULL is never a live job. A
  worker's own rows are recovered by the next worker if it dies.
- **Shutdown**: on SIGTERM the job threads finish their current job and
  stop; `Job.stop!` waits up to `Config#job_drain_timeout` (10 s, like the
  server's) and then returns, leaving still-running rows to heartbeat
  recovery (they are marked `running` with a stale heartbeat within 5
  minutes). Solid Queue does the same with `shutdown_timeout`.
- Spinel: a job thread is started through a method (`spawn_job_thread(i,
  generation)`, NOTES rule 21); the handler's exceptions are rescued in a
  plain method (rules 32 / 45); `Job::HANDLERS` keeps the concurrency limit
  as an Integer field on `Handler`.
- `test/jobs.rb` grows: concurrency limit honoured, heartbeat written,
  recovery by staleness only, two "processes" (two claimed_by values) in one
  test; `test/job_threads.rb` starts real threads against a temporary
  database and checks that a slow job does not delay a fast one.

## 5. Process roles (P-1)

`Main.run` learns two subcommands beside `server`:

| Command | Runs | Notes |
| --- | --- | --- |
| `./app server [PORT]` | HTTP, and (unless `CYBERTRAIN_WORKER=0`) the scheduler, the job threads, the subscriptions, the stream poller | Unchanged default: one process does everything, as `rails server` with Solid Queue in Puma |
| `./app worker` | the scheduler (lease-gated), the job threads, heartbeats, recovery | No port. Several may share a database |
| `./app feeds [NAME...]` | the WebSocket subscriptions, all or the named ones | No port, no jobs. One container per feed, as fin_dash runs them. An unknown name is a boot error listing the registered ones |

- `Application#run_worker` and `#run_feeds(names)`: `boot` (config checks,
  DB connect), a banner (`=> worker: 3 job threads, 4 scheduled tasks`),
  `trap("TERM")`, start, wait on a `Queue`/flag until the trap fires, stop
  (same order as `serve`). `migrate`, `db`, `Main.command` and
  `Test::Client` start nothing, as before. `Main.server?(argv)` stays what
  it is; `Main.worker?(argv)` and `Main.feeds?(argv)` are added for
  applications that check the role in `bin/<app>.rb`.
- **The scheduler lease**: `cybertrain_leases (name TEXT PRIMARY KEY, holder
  TEXT NOT NULL, expires_at INTEGER NOT NULL)`. Every tick, a process that
  runs the scheduler calls `Lease.acquire("scheduler", holder, now, ttl:
  Config#scheduler_lease_ttl)` (30 s): `INSERT ... ON CONFLICT(name) DO
  UPDATE SET holder = excluded.holder, expires_at = excluded.expires_at
  WHERE cybertrain_leases.holder = excluded.holder OR
  cybertrain_leases.expires_at < ?`, success when `changes == 1`. Only the
  holder runs due tasks; the others tick and try again. A tick that cannot
  reach the database logs and retries. `Scheduler.leader?` is readable (the
  health check keeps reporting `last_tick`; a non-leader still ticks).
  `Job.recover!` and the heartbeat run in every worker process (they are
  idempotent). `Stream.prune` has one owner, the stream poller (2.2), which
  runs in every process that delivers to browsers; a deployment with only
  `worker` processes and no `server` has no readers and is not a target.
- `WebSocket.start!(config, only: names)`: with an empty list every
  subscription starts; otherwise the named ones. `Background::Service`
  gets `service_start_only(config, names)` with a default that calls
  `service_start`.
- `Config#worker` keeps its meaning for `server`. A `server` with
  `CYBERTRAIN_WORKER=0` still runs the stream poller (it delivers to its
  browsers).
- `cybertrain new` writes the roles into `config/deploy.yml` (Kamal: `web`,
  `worker` with `cmd: ./app worker`, commented `feeds`) and the Dockerfile
  stays one image. `docs/deploy.md` gets a "Roles" section with systemd
  units for `worker` and `feeds`.

## 6. BLOB columns (D-1)

- Schema DSL: `t.binary :body` -> `body BLOB`; the dumper writes it back as
  `t.binary`. Migrations: `add_column :t, :c, :binary` works as other types.
- Generated model attribute: typed as `String` / `String | nil`
  (`string_or_nil` in `models_emitter`), holding the raw bytes. On save the
  generated `attributes_for_save` wraps binary columns in
  `Cybertrain::DB::Blob.new(bytes)`, which `Connection#bind` binds with
  `sqlite3_bind_blob(stmt, i, ptr, bytes, SQLITE_TRANSIENT)`. Every other
  String still binds as text, so existing columns are unchanged.
- Reading: `read_row` sees `SQLITE3::BLOB` and reads `sqlite3_column_blob` +
  `sqlite3_column_bytes` through a `:binstr` FFI function
  (`cybertrain_sqlite_column_blob`, the pattern of `GzipFFI.cybertrain_bytes_at`),
  returning a String with the exact bytes (NUL included; rule 60's `<<`
  copy). Raw SQL callers get the same String; `Cast.binary(value)` narrows
  (`""` for nil).
- Raw binds: `c.execute("INSERT ... VALUES (?)", [Cybertrain::DB::Blob.new(bytes)])`.
- `Cast.binds` accepts `Blob`. The playground and `db` CLI print a BLOB
  cell as `<N bytes>`.
- `test/db_blob.rb`: round trip of 0, 1 and 70,000 bytes including NUL and
  bytes above 127, through a model and through raw SQL; the dumper output.

## 7. Console (O-1)

Spinel has no `eval`, so `rails console` cannot be. Two commands get close:

- **`./app dbconsole`**: `Process.spawn("sqlite3", database_path)` and
  `Process.wait` (NOTES rule 75 says `spawn` compiles); exit code passed
  through; a missing `sqlite3` is reported ("install the sqlite3 CLI").
  Rails' `dbconsole`.
- **`./app console`**: a read-eval-print loop over the **template expression
  language** (section 3.3's grammar, plus two console-only additions),
  evaluated by the same interpreter with a `Console::Helpers`:
  - Model classes are reachable by name: the parser's `constants:` option
    (console only) turns `Article` into a constant node, which
    `Console::Helpers#constant(name)` resolves through the generated
    `Gen::Console.scope(name)` table in `gen/console.rb` (`case name when
    "Article" then Article.all ... else raise "no model 'X'"`), returning
    that model's `Relation`.
  - On a `Relation` value (base class, so one `case` arm serves every
    model): `where(k: v, ...)`, `where_sql(sql, binds)`, `order(:col)` /
    `order(col: :desc)`, `limit(n)`, `offset(n)`, `first`, `last`, `find(id)`,
    `find_by(k: v)`, `count`, `exists?`, `to_a`, `pluck_str/int/float(:col)`,
    `delete_all`, `page(n)`. On a `Model` value: attributes and view methods
    (as templates), `update(k: v)`, `destroy`, `save`, `errors`,
    `attributes`. `Article.create(title: "x")` goes through
    `Gen::Console.create(name, hash)`.
  - Console-only commands: `sql "SELECT ..."` prints rows as a table;
    `tables` lists tables; `help`; `exit` / `quit` / Ctrl-D.
  - Output: a `Model` prints as `#<Article id: 1, title: "x", created_at:
    2026-11-05 10:00:00 UTC>` (every column, `inspect`-style values, 80
    bytes per value cut with `…`); an Array prints one element per line with
    a count; a Relation prints its `to_sql` and `count`; scalars print
    `inspect`. `_` holds the last value.
  - `gets`-based line reading (no readline); a line that does not parse
    prints the `SyntaxError` and continues; a line that raises prints `Class:
    message` and continues. `CYBERTRAIN_ENV=production` prints a warning
    banner (as Rails does) and otherwise behaves the same.
- Both run with a pool of one and never start the scheduler (they are
  `Main` built-ins, dispatched before `server?`).

## 8. Configuration added

| Key | Env | Default | Used by |
| --- | --- | --- | --- |
| `stream_path` | `CYBERTRAIN_STREAM_PATH` | `/cybertrain/stream` | 2.3; `""` disables |
| `stream_poll_ms` | | 100 | 2.2 |
| `stream_retention` | | 60 | 2.2 |
| `stream_ping_interval` | | 15 | 2.3 |
| `stream_max_connections` | | 1000 | 2.3 |
| `stream_max_message` | | 65536 | 2.3 |
| `stream_max_backlog` | | 1000 | 2.2 |
| `job_threads` | `CYBERTRAIN_JOB_THREADS` | 3 | 4 |
| `job_poll_interval` | | 1 (was 5) | 4 |
| `job_heartbeat_interval` | | 30 | 4 |
| `job_heartbeat_stale` | | 300 | 4 |
| `job_drain_timeout` | | 10 | 4 |
| `scheduler_lease_ttl` | | 30 | 5 |

Each gets a validation line in `Config#scheduler_error` / a new
`Config#stream_error` reported by `boot`.

## 9. Documentation and design.md changes

- **design.md**: D1 is revised ("2026-11-05: porting Rails applications is
  in scope; the five-phase programme, this document"); 2.3 and section 8
  drop "a WebSocket server", "arbitrary Ruby in templates" (partly: the
  grammar grows, constants stay out), "rails console" (replaced by the
  expression console); D5 gains streaming responses; D9 gains components,
  application helpers, `case`, blocks, `tag`; D28 gains job threads,
  heartbeats, concurrency; D33 gains `feeds` and `only:`; new **D35**
  (streaming responses and the stream endpoint), **D36** (the stream
  pub/sub and Turbo), **D37** (application helpers and components), **D38**
  (process roles and the scheduler lease), **D39** (BLOB), **D40** (the
  console). Section 13 gets a 2026-11-05 entry.
- **Guides**: new `docs/guide/realtime.md` (SSE, WebSocket, Turbo,
  broadcasting from jobs, the JavaScript side with `EventSource` and
  `WebSocket` examples); `template-language.md` (case, blocks, tag,
  components, helpers); `background-and-operations.md` (roles, threads,
  heartbeats, console, dbconsole); `models.md` (binary); `testing.md`
  (render_partial / render_component, stream tests). The guide's other
  languages (`fr`, `ja`, `ru`, `zh`) get the new pages translated in the
  same pull request, since `script/check-guide-i18n` gates on it.
- **README**: the "Not built" sentence is rewritten.
- **spikes/NOTES.md**: every new Spinel finding gets the next rule number.

## 10. Spinel constraints that shape the implementation

- No computed dispatch: every name-to-method step is a generated `case`
  (3.1, 3.2, 7) or a `case` on a literal in the interpreter (3.3).
- Blocks: stored blocks are called with `.call` from plain methods, never
  `instance_exec` (rule 2); threads start through a method whose parameters
  the block captures (rule 21); no new `rescue` in a yielding method
  (rules 32 / 45).
- Typed containers: registries are constants seeded with their element
  type (rule 9, rule 64); `Hash<String, polymorphic>` for template
  environments and kwargs; `Relation` and `Model` base classes for the
  console's values.
- Names: no method name shared with a different return type across the
  framework (rules 10 / 34 / 41 / 62): `service_start`, `sub_name`,
  `write_body`, `stream_*` style prefixes are kept for new classes.
- Bytes: binary strings are built with `<<` (rule 60) and sliced with
  `byteslice`; FFI byte returns go through `:binstr`.
- Every `readpartial` is preceded by `wait_readable` (rule 20): the
  WebSocket server loop, the SSE disconnect check and the Sink.

## 11. Out of scope for phase 1 (recorded so nothing is lost)

Cron and time-of-day schedules, job classes with `perform`, per-class retry
policies, a jobs page, `limits_concurrency` beyond the per-kind limit,
feed timers and automatic restart of a dead feed thread, HTML mail, Turbo
helpers inside templates (`turbo_frame_tag`, `turbo_stream.replace`: phase
4's V-10), component collections (`with_collection`), i18n, the asset
pipeline, `namespace` routes, decimal / json / datetime columns, Range
`where`, `includes`, a WebSocket client-side JavaScript library (the
browser's `EventSource` and `WebSocket` are documented instead),
`permessage-deflate`, HTTP/2.

## 12. Acceptance

1. `spin test` passes with the new programs (`test/stream.rb`,
   `test/stream_endpoint.rb`, `test/websocket_server.rb`,
   `test/response_stream.rb`, `test/turbo.rb`, `test/views_detached.rb`,
   `test/gen_helpers.rb`, `test/gen_components.rb`,
   `test/template_case.rb`, `test/template_blocks.rb`, `test/template_tag.rb`,
   `test/jobs.rb` (grown), `test/job_threads.rb`, `test/lease.rb`,
   `test/main_roles.rb`, `test/db_blob.rb`, `test/console.rb`,
   `test/cli_generate_helper.rb`, `test/cli_generate_component.rb`) and the
   existing ones, snapshots reviewed.
2. `examples/blog` gains one end-to-end use of each: a `CommentComponent`,
   a `comments_helper.rb` with `comment_author`, `turbo_stream_from
   @article` on the article page with `Stream.broadcast_append_to` from
   `CommentsController#create`, a `t.binary` column is **not** added to the
   blog (nothing to store); its integration tests cover the component and
   the broadcast (`Stream` rows), and `script/gate` passes.
3. A manual check, recorded in the pull request: two browser tabs on the
   blog article page; a comment posted in one appears in the other without
   reload, over SSE; the same with `ws: true`; `./blog worker` and
   `./blog server` with `CYBERTRAIN_WORKER=0` share the database and a job
   enqueued by the server runs in the worker; `./blog console` runs
   `Article.where(title: "x").count`.
