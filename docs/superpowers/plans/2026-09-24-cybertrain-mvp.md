# cybertrain MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build cybertrain, a Rails-like web framework compiled by Spinel, far enough that the `examples/blog` app (Articles + Comments, server-rendered HTML, SQLite) builds with `spin build` into one binary and its integration tests pass in CI.

**Architecture:** A `spin` library package written in the Spinel Ruby subset. Runtime metaprogramming is replaced by (1) build-time code generation from `db/schema.rb` and `config/routes.rb` into committed plain Ruby under `gen/`, (2) runtime data tables for validations/callbacks, and (3) a runtime-interpreted ERB-syntax template language. HTTP is a pure-Ruby HTTP/1.1 server on `TCPServer` with one green thread per connection; the DB is SQLite through FFI.

**Tech Stack:** Spinel `2026.09.12` (`spinel`, `spin`), Spinel stdlib packages (`socket`, `json`, `openssl`, `securerandom`, `uri`, `strscan`, `stringio`), SQLite 3 via `ffi_func`, GitHub Actions.

**Spec:** `docs/design.md` (Japanese; authoritative). Spike verdicts: `spikes/NOTES.md`.

## Global Constraints

- Everything under `cybertrain/`, `bin/`, `test/`, `examples/` must compile with `spinel --require-gate` (what `spin build`/`spin test` use). Verify with `spin test` (framework) or `spin build` (apps), never with CRuby alone.
- No `eval`, `method_missing`, `define_method`/`send` with computed names, `Class.new`, `instance_variable_get` with computed names, `ObjectSpace`, `autoload`, `Object#extend` at runtime, class reopening outside a class body. Literal-name `send`/`define_method`, `instance_exec(&blk)`, open classes in files, and `case obj when SomeClass` are fine.
- String literals are frozen. Build output with `buf = +""` or `String.new` and `<<`.
- Typed containers: an `Array` or `Hash` must hold one element type; mixing widens to a polymorphic value. Prefer separate typed containers (e.g. `Params` keeps `@values`, `@lists`, `@children`) over one mixed Hash.
- A method called with different argument types at different call sites gets a polymorphic parameter; dispatch inside such methods must narrow with `case x when String ... when Array ...` before calling type-specific methods (see the `assert_includes` note in `cybertrain/test.rb`).
- Every file is a `require "cybertrain/<path>"` feature. Files require what they use. `cybertrain.rb` is maintained by the integrator only.
- Tests are `test/<name>.rb` programs using `cybertrain/test` (`test "..." do ... end`, `assert_equal`, `assert`, `refute`, `assert_nil`, `assert_includes`, `assert_raises("ClassName") { }`, `flunk`) ending with `Cybertrain::Test.run!`. Output must be deterministic (no timings, ports, pids, object ids). Generate the snapshot with `spin test --regen test/<name>.rb` and commit both files.
- Public API vocabulary follows Rails where the spec says so; exact signatures in each task's **Interfaces** block are binding for neighbouring tasks.
- Commit messages: imperative summary line, body explains why. End with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Task protocol (applies to every task)

1. Read `docs/design.md` sections named in the task and `spikes/NOTES.md`.
2. Write the test program first (the task lists its cases); run `spin test test/<name>.rb` and watch it fail to compile or fail.
3. Implement the minimal code; keep files focused (one class/module per file).
4. `spin test test/<name>.rb` until green; then `spin test` (everything) must stay green.
5. Report the exact public signatures you shipped if they differ from the plan.

## File structure (framework package = repo root)

```
cybertrain.rb                      entry: requires every runtime feature (integrator-owned)
cybertrain/version.rb
cybertrain/test.rb                 Cybertrain::Test harness (exists)
cybertrain/test/client.rb          Cybertrain::Test::Client in-process HTTP client + response assertions
cybertrain/html.rb                 Cybertrain::Html.escape / .out, Cybertrain::SafeString
cybertrain/logger.rb               Cybertrain::Logger, Cybertrain.logger
cybertrain/http/request.rb         Cybertrain::Request
cybertrain/http/response.rb        Cybertrain::Response
cybertrain/http/parser.rb          Cybertrain::HttpParser (request head parsing)
cybertrain/http/query.rb           Cybertrain::Query (query/form decoding, key splitting)
cybertrain/http/cookies.rb         Cybertrain::Cookies (parse / Set-Cookie serialize)
cybertrain/http/server.rb          Cybertrain::Server (TCPServer, green thread per connection)
cybertrain/params.rb               Cybertrain::Params (typed nested params, require/permit)
cybertrain/context.rb              Cybertrain::Context (request, response, params, route data)
cybertrain/middleware.rb           Cybertrain::Middleware base class
cybertrain/middleware/static.rb    Cybertrain::Static
cybertrain/middleware/request_logger.rb   Cybertrain::RequestLogger
cybertrain/middleware/method_override.rb  Cybertrain::MethodOverride
cybertrain/router.rb               Cybertrain::Route, Cybertrain::Router
cybertrain/app.rb                  Cybertrain::App (default middleware stack)
--- later waves (M2+) ---
cybertrain/controller.rb  cybertrain/session.rb  cybertrain/flash.rb  cybertrain/middleware/session.rb  cybertrain/middleware/csrf.rb
cybertrain/template/{lexer,parser,ast,value,interpreter,helpers,form_builder,engine}.rb
cybertrain/model.rb  cybertrain/relation.rb  cybertrain/validations.rb  cybertrain/errors.rb
cybertrain/db/{adapter,sqlite,pool,migration,migrator,schema_dumper}.rb
cybertrain/generator/{schema_reader,models,routes_reader,routes,view_assigns,manifest,runner}.rb
cybertrain/dev/{watcher,rebuild}.rb   bin/cybertrain.rb   examples/blog/
```

---

## Wave M1 — HTTP foundation

Tasks 1, 2, 3 have no dependencies on each other and run in parallel. Tasks 4 and 5 depend on 1–3 and run in parallel with each other. `cybertrain/context.rb` and `cybertrain/middleware.rb` are pre-created by the integrator so that Task 5 can start alongside Task 4.

### Task 1: HTML escaping, SafeString, Logger

**Files:**
- Create: `cybertrain/html.rb`, `cybertrain/logger.rb`
- Test: `test/html.rb`, `test/logger.rb`

**Interfaces:**
- Produces:
  ```ruby
  module Cybertrain::Html
    def self.escape(str)      # String -> String: & < > " ' become &amp; &lt; &gt; &quot; &#39;
    def self.safe(str)        # String -> SafeString
    def self.out(value)       # nil -> ""; SafeString -> its string; String -> escape; Integer/Float/true/false -> to_s
  end
  class Cybertrain::SafeString
    def initialize(str); def to_s; def to_str; def html_safe?; def ==(other); def +(other) # other String|SafeString -> SafeString (escapes plain String)
  end
  class Cybertrain::Logger
    def initialize(io = STDOUT, level = :info)   # levels :debug < :info < :warn < :error
    def debug(msg); def info(msg); def warn(msg); def error(msg)   # prints "[INFO] msg" when enabled
    attr_accessor :level
  end
  module Cybertrain
    def self.logger; def self.logger=(l)   # process-wide logger (default Logger.new(STDOUT))
  end
  ```

- [ ] **Step 1: Write `test/html.rb`** covering: escape of all five characters, escape leaves safe text untouched, `out(nil) == ""`, `out(SafeString) ` unescaped, `out("<b>")` escaped, `out(42) == "42"`, `SafeString + "x<"` escapes the plain half, `html_safe?` true.
- [ ] **Step 2: Write `test/logger.rb`** using `require "stringio"`: a `StringIO` sink receives `[INFO] hello` for `info`, nothing for `debug` at level `:info`, `[WARN]`/`[ERROR]` lines; `Cybertrain.logger` returns the same object twice; `Cybertrain.logger = custom` swaps it.
- [ ] **Step 3: Run both tests, watch them fail; implement `cybertrain/html.rb` and `cybertrain/logger.rb`.** Implement `escape` with a single pass over bytes/chars appending to a mutable buffer (fast path: return the input when it contains none of the five characters).
- [ ] **Step 4: `spin test --regen test/html.rb test/logger.rb`, then `spin test` green.**

### Task 2: Request, Response, HttpParser

**Files:**
- Create: `cybertrain/http/request.rb`, `cybertrain/http/response.rb`, `cybertrain/http/parser.rb`
- Test: `test/http_request.rb`, `test/http_response.rb`, `test/http_parser.rb`

**Interfaces:**
- Produces:
  ```ruby
  class Cybertrain::HttpParser
    class ParseError < StandardError; end
    HEAD_END = "\r\n\r\n"
    def self.head_end(buffer)            # String -> Integer|nil : index of HEAD_END or nil when incomplete
    def self.parse_head(head)            # String (up to and excluding HEAD_END) -> RequestHead; raises ParseError on bad request line, bad header line, unsupported version
  end
  class Cybertrain::RequestHead
    attr_reader :method, :target, :http_version, :headers   # headers: Hash<String,String>, names lowercased, values stripped, duplicates joined with ", "
    def initialize(method, target, http_version, headers)
  end
  class Cybertrain::Request
    attr_reader :method, :path, :query_string, :headers, :body, :remote_addr, :http_version
    def initialize(method, target, headers, body, remote_addr = "", http_version = "HTTP/1.1")  # target "/a/b?x=1" splits into path and query_string ("" when absent)
    def override_method!(m)              # used by MethodOverride; m upper-cased
    def header(name)                     # case-insensitive lookup -> String|nil
    def content_length                   # Integer, 0 when absent/invalid
    def content_type                     # String ("" when absent), media type only (before ";")
    def keep_alive?                      # HTTP/1.1: true unless "connection: close"; HTTP/1.0: only when "connection: keep-alive"
    def get?; def post?; def head?; def patch?; def put?; def delete?
    def form?                            # content_type == "application/x-www-form-urlencoded"
    def json?                            # content_type == "application/json"
    def cookie_header                    # String ("" when absent)
  end
  class Cybertrain::Response
    STATUS_TEXT = { 200 => "OK", 201 => "Created", 204 => "No Content", 301 => "Moved Permanently", 302 => "Found", 303 => "See Other", 304 => "Not Modified", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 411 => "Length Required", 413 => "Payload Too Large", 422 => "Unprocessable Entity", 500 => "Internal Server Error" }
    attr_accessor :status, :body          # Integer, String
    attr_reader :headers, :cookies        # Hash<String,String>, Array<String> (Set-Cookie values)
    def initialize                        # status 200, body "", headers {}
    def set_header(name, value)
    def header(name)                      # case-insensitive -> String|nil
    def content_type=(value)              # sets "Content-Type"
    def add_cookie(set_cookie_value)
    def redirect(location, status = 302)  # sets status + Location, marks performed
    def performed?; def performed!        # true once render/redirect happened (controllers use this)
    def status_text                       # STATUS_TEXT[status] or "Unknown"
    def to_http(head_only = false)        # "HTTP/1.1 200 OK\r\n" + headers (always Content-Length: body bytesize; Content-Type default "text/html; charset=utf-8" when unset) + one Set-Cookie line per cookie + "\r\n" + body (omitted when head_only)
  end
  ```

- [ ] **Step 1: Write the three test programs.** Parser: complete GET head with 3 headers (mixed-case names, extra spaces), incomplete buffer returns nil, `head_end` index correct, bad request line raises `ParseError`, HTTP/1.0 accepted, "HTTP/2.0" raises. Request: path/query split, `header("HOST")` lookup, `content_length` parsing, `keep_alive?` for 1.1/1.0 with and without Connection headers, method predicates, `override_method!`. Response: defaults, `to_http` exact bytes for a small body, `head_only` omits body but keeps Content-Length, cookies emitted as separate `Set-Cookie:` lines, `redirect` sets 302 + Location + performed.
- [ ] **Step 2: Watch them fail; implement.** Header parsing: split on the first ":"; reject lines without ":". Percent-decoding is NOT done here (Query does it).
- [ ] **Step 3: `spin test --regen` the three, `spin test` green.**

### Task 3: Params, Query, Cookies

**Files:**
- Create: `cybertrain/params.rb`, `cybertrain/http/query.rb`, `cybertrain/http/cookies.rb`
- Test: `test/params.rb`, `test/query.rb`, `test/cookies.rb`

**Interfaces:**
- Produces:
  ```ruby
  class Cybertrain::Params
    class ParameterMissing < StandardError; end
    def initialize
    def [](key)                 # key Symbol|String -> String|nil (scalar only)
    def list(key)               # -> Array<String> ([] when absent)
    def nested(key)             # -> Params (a fresh empty Params when absent; not stored)
    def key?(key)               # scalar, list or nested present
    def keys                    # Array<String> in insertion order (scalars, then lists, then nested)
    def require(key)            # -> Params; raises ParameterMissing, "param is missing or the value is empty: <key>" when absent or when it has no keys
    def permit(*keys)           # -> Hash<String,String>: only listed scalar keys that are present
    def set_value(key, value); def add_list_value(key, value); def child!(key)   # child! returns the (created) nested Params
    def set_path(path, value)   # path Array<String> from Query.split_key; a trailing "" means "append to list"
    def merge!(other)           # other Params; other wins on conflicts
    def to_h                    # Hash<String,String> of scalars
    def empty?
    def inspect                 # deterministic, e.g. {"id"=>"1", "tags"=>["a","b"], "post"=>{"title"=>"x"}}
  end
  module Cybertrain::Query
    def self.parse(str)         # String -> Params ; "a=1&b[]=2&b[]=3&post[title]=hi&flag" ; '+' -> space, %XX decoded (URI.decode_www_form_component); "flag" becomes "flag" => ""
    def self.split_key(key)     # "post[tags][]" -> ["post","tags",""] ; "id" -> ["id"]
    def self.encode(pairs)      # Hash<String,String> -> "a=1&b=x+y" (URI.encode_www_form_component)
  end
  module Cybertrain::Cookies
    def self.parse(header)      # "a=1; b=2" -> Hash<String,String> (values percent-decoded)
    def self.serialize(name, value, path: "/", max_age: -1, http_only: true, same_site: "Lax", secure: false)  # -> "name=value; Path=/; HttpOnly; SameSite=Lax" (+ "; Max-Age=N" when max_age >= 0, "; Secure" when secure); value percent-encoded
  end
  ```

- [ ] **Step 1: Write the test programs** (parse of the sample string above, nested/list access, `require` success + failure message, `permit` ignoring unknown and non-scalar keys, `merge!`, `split_key` cases including malformed `a[` treated as a plain key, `encode` round trip, cookie parse/serialize with all options).
- [ ] **Step 2: Implement with three typed Hashes inside Params** (`@values Hash<String,String>`, `@lists Hash<String,Array<String>>`, `@children Hash<String,Params>`) plus `@order Array<String>` for `keys`.
- [ ] **Step 3: `spin test --regen`, `spin test` green.**

### Task 4: Middleware stack, Router, App, in-process test client

**Files:**
- Modify (pre-created skeletons): `cybertrain/context.rb`, `cybertrain/middleware.rb`
- Create: `cybertrain/router.rb`, `cybertrain/middleware/static.rb`, `cybertrain/middleware/request_logger.rb`, `cybertrain/middleware/method_override.rb`, `cybertrain/app.rb`, `cybertrain/test/client.rb`
- Test: `test/router.rb`, `test/middleware.rb`, `test/static.rb`, `test/client.rb`

**Interfaces:**
- Consumes: `Cybertrain::Request`, `Cybertrain::Response` (Task 2), `Cybertrain::Params`, `Cybertrain::Query` (Task 3), `Cybertrain::Logger` (Task 1).
- Produces:
  ```ruby
  class Cybertrain::Context
    attr_reader :request, :response
    attr_accessor :params        # Params (assembled by Router: query, then form body when request.form?, then route params — later wins)
    attr_accessor :route_params  # Hash<String,String>
    attr_accessor :route_name    # String ("" when unmatched)
    def initialize(request)      # response = Response.new; params = Params.new; route_params = {}
  end
  class Cybertrain::Middleware
    attr_accessor :app           # Middleware|nil (next in chain)
    def initialize(app = nil)
    def call(ctx)                # default: @app.call(ctx) if @app; returns nil
  end
  class Cybertrain::Route
    attr_reader :verb, :pattern, :segments, :name, :handler   # segments: Array<String>; dynamic ones start with ":"
    def initialize(verb, pattern, name, handler)              # handler: Proc(ctx) ; pattern "/posts/:id/edit"
    def match(verb, path_segments)                            # -> Hash<String,String>|nil; verb "HEAD" matches "GET" routes
    def path(params)                                          # Hash<String,String> -> "/posts/1/edit"; raises ArgumentError when a segment is missing
  end
  class Cybertrain::Router < Cybertrain::Middleware
    def initialize
    def add(verb, pattern, name = "", &handler)  # -> Route ; handler receives the Context
    def get(pattern, name = "", &h); def post(...); def patch(...); def put(...); def delete(...)
    def routes                                   # Array<Route>
    def path_for(name, params = {})              # String|nil
    def call(ctx)                                # split path on "/", ignore empty segments, first match wins; on match: ctx.route_params/route_name/params, then handler.call(ctx); no match: 404 with body "Not Found", content type text/plain
    def self.split_path(path)                    # "/posts/1/" -> ["posts","1"] (percent-decoded segments)
  end
  class Cybertrain::Static < Cybertrain::Middleware
    def initialize(app, root = "public")         # GET/HEAD only; rejects ".." segments; serves File.read(root + path) with content type from EXTENSIONS table (html css js png jpg jpeg gif svg ico txt json woff2 map); adds "Cache-Control: public, max-age=3600"; otherwise passes through
  end
  class Cybertrain::RequestLogger < Cybertrain::Middleware
    def initialize(app, logger = Cybertrain.logger)   # logs 'Started GET "/posts" for 127.0.0.1' before and "Completed 200 in 3ms" after (elapsed = integer milliseconds from Time.now)
  end
  class Cybertrain::MethodOverride < Cybertrain::Middleware
    def initialize(app)   # for POST: if form body or query has _method in patch/put/delete -> request.override_method!
  end
  class Cybertrain::App < Cybertrain::Middleware
    def initialize(router, public_root: "public", logging: true, logger: Cybertrain.logger)   # stack: RequestLogger? -> Static -> MethodOverride -> router
    def call(ctx)         # runs the stack
    def router            # Router
  end
  class Cybertrain::Test::Client
    def initialize(app)   # app: Middleware (an App or Router)
    attr_reader :response, :cookies                 # last Response; Hash<String,String> cookie jar carried between requests (from Set-Cookie name=value)
    def get(path, headers = {}); def post(path, params = {}, headers = {}); def patch(...); def put(...); def delete(...)   # params Hash<String,String> -> form body; returns Response
    def request(method, path, body = "", headers = {})   # generic; sets Content-Type form for post/patch/put/delete when body from params
    def follow_redirect!                            # GET the Location of the last response
  end
  def assert_response(response, expected)   # Integer, or :ok 200, :created 201, :no_content 204, :redirect any 3xx, :see_other 303, :bad_request 400, :forbidden 403, :not_found 404, :unprocessable_entity 422, :error 500
  def assert_redirected_to(response, path)  # 3xx and Location == path
  ```

- [ ] **Step 1: Tests.** Router: static and dynamic matching, first-match precedence, HEAD→GET, trailing slash, percent-decoded segments, `path_for`, `Route#path` error, 404 body, params assembly order (query < form < route). Middleware: a chain of two custom middlewares (subclasses) that append to `ctx.response.body` proves ordering. Static: create a temp file under a temp root (`Dir.mktmpdir` if available, else `tmp/static_test/`), serve it with the right content type, 404 fallthrough, `..` rejected, HEAD has no body. Client: cookie jar carries `Set-Cookie` into the next request's `Cookie` header, `follow_redirect!`, `assert_response(:not_found)` on unknown path, `MethodOverride` turns a POST with `_method=delete` into DELETE.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: `spin test --regen` the four tests, `spin test` green.**

### Task 5: HTTP server

**Files:**
- Create: `cybertrain/http/server.rb`
- Test: `test/server.rb`

**Interfaces:**
- Consumes: `HttpParser`, `Request`, `Response` (Task 2), `Context`, `Middleware` (pre-created), `Cybertrain.logger` (Task 1). Read `spikes/05_http_server/` and `spikes/NOTES.md` for the socket primitives, timeout mechanism and error classes that compile.
- Produces:
  ```ruby
  class Cybertrain::Server
    def initialize(app, host: "127.0.0.1", port: 3000, read_timeout: 15, max_head_bytes: 65536, max_body_bytes: 10_485_760, logger: Cybertrain.logger)
    def start          # bind + listen + spawn the accept thread; returns once listening
    def run            # start then block until stop
    def stop           # close the listener; accept thread exits
    def port           # Integer: the bound port (useful with port: 0)
    def host
  end
  ```
  Per connection (green thread): loop { read until HttpParser.head_end (cap max_head_bytes → 431/400 and close); parse_head; read exactly Content-Length body bytes (cap → 413 and close; `Transfer-Encoding: chunked` → 411 and close); build Request with remote_addr from `peeraddr`; ctx = Context.new(req); app.call(ctx) with `rescue StandardError` → status 500, body "Internal Server Error", logger.error("#{e.class.name}: #{e.message}"); set "Connection: keep-alive|close"; write `to_http(req.head?)`; break unless keep_alive }. Idle keep-alive connections time out after `read_timeout` seconds (spike-proven primitive). Socket errors (`Errno::ECONNRESET`, `Errno::EPIPE`, `EOFError`, `IOError`) close the connection quietly.

- [ ] **Step 1: `test/server.rb`.** Start on port 0 with a tiny Router (GET /hello → "hi", POST /echo → body back with request content type, GET /boom raises). Using `TCPSocket` in-process: (a) two keep-alive requests on one socket get two responses; (b) `Connection: close` closes the socket after one; (c) HEAD /hello returns headers with Content-Length 2 and no body; (d) POST /echo with Content-Length body; (e) malformed request line → 400; (f) /boom → 500 and the connection stays usable for a following /hello; (g) `stop` makes the port refuse connections. Print only status lines/bodies, never the port.
- [ ] **Step 2: Implement; run under `SPINEL_WORKERS=1` and default; both must pass.**
- [ ] **Step 3: `spin test --regen test/server.rb`, `spin test` green.**

### Integration (integrator)

- [ ] Update `cybertrain.rb` to require every M1 feature; `spin test` green; commit "Add the HTTP foundation (M1)".

---

## Wave M2a — Controller, session, generator core, schema data

Runs after Wave M1 is integrated. Tasks 6–9 are independent of each other. The integrator adds `attr_accessor :session, :flash` to `Cybertrain::Context` before the wave starts.

Findings from spike 2 that every task here obeys: `instance_exec(&stored_block)` does not compile; non-literal `send`/`respond_to?` must never be used; from an instance method `self.class.foo` is only safe when `foo` is overridden in every subclass, so class-level registries are keyed by `self.name` (a String) and inheritance is walked with an explicit class argument (`k = klass; while k; ...; k = k.superclass; end`); `Method` objects must not be stored in collections (store lambdas).

### Task 6: Controller base

**Files:**
- Create: `cybertrain/controller.rb`, `cybertrain/callback.rb`
- Test: `test/controller.rb`

**Interfaces:**
- Consumes: `Context`, `Response` (`performed?`, `performed!`, `redirect`, `STATUS_TEXT`), `Params`, `Cybertrain::Html`, `JSON` (`require "json"`).
- Produces:
  ```ruby
  class Cybertrain::Callback
    attr_reader :kind, :name, :block, :only, :except   # kind :before|:after; name Symbol|nil; block Proc|nil taking (controller); only/except Array<Symbol>
    def initialize(kind, name, block, only, except)
    def applies?(action)   # false when only is non-empty and excludes action, false when except includes action
  end
  class Cybertrain::RescueHandler
    attr_reader :class_name, :with, :block   # class_name String (exact match on e.class.name); with Symbol|nil; block Proc|nil taking (controller, exception)
  end
  class Cybertrain::MissingTemplate < StandardError; end
  class Cybertrain::UnknownCallback < StandardError; end
  class Cybertrain::Controller
    CALLBACKS = {}   # Hash<String, Array<Callback>> keyed by class name
    RESCUES = {}     # Hash<String, Array<RescueHandler>>
    def self.before_action(name = nil, only: [], except: [], &block)   # registers under self.name; name Symbol or block { |c| ... }
    def self.after_action(name = nil, only: [], except: [], &block)
    def self.rescue_from(klass, with: nil, &block)                    # stores klass.name; block { |c, e| ... }
    def self.chain_for(klass)      # Array<Callback>: base-most class first, walking klass.superclass up to (and including) Cybertrain::Controller
    def self.rescues_for(klass)    # Array<RescueHandler>: most specific class first
    attr_reader :ctx, :request, :response, :params, :action_name
    def initialize(ctx)
    def process(action)            # sets @action_name; runs before callbacks in chain order (each may render/redirect; stop when performed?); yields self for the action body; calls default_render(action) unless performed?; runs after callbacks; rescues StandardError through rescues_for (handled -> return, else re-raise); returns nil
    def run_callback(name)         # base implementation raises UnknownCallback, "unknown callback :#{name} in #{self.class.name} (run `spin run gen`)"; gen/controllers.rb overrides per controller with `case name when :set_post then set_post ... else super end`
    def default_render(action)     # base raises MissingTemplate; the template engine (Wave M2b) overrides it
    def render(template = nil, plain: nil, html: nil, json: nil, status: 200, content_type: nil)   # exactly one of plain/html/json/template; plain -> text/plain; html -> String|SafeString as text/html; json -> Hash|Array|String (String is sent as-is) via JSON.generate as application/json; template Symbol -> render_template(template) (M2b); status Integer|Symbol; marks performed
    def render_template(name)      # base raises MissingTemplate (M2b overrides)
    def redirect_to(location, status: 302)   # status Integer|Symbol; marks performed
    def head(status)               # Integer|Symbol; empty body; marks performed
    def performed?
    def session; def flash         # ctx.session / ctx.flash (nil when the middleware is absent)
    def self.status_code(value)    # Integer passthrough; Symbol via STATUS_SYMBOLS = { ok: 200, created: 201, no_content: 204, moved_permanently: 301, found: 302, see_other: 303, bad_request: 400, forbidden: 403, not_found: 404, unprocessable_entity: 422, internal_server_error: 500 }
  end
  ```

- [ ] **Step 1: `test/controller.rb`.** Define `ApplicationController < Cybertrain::Controller` with `before_action :authenticate` and a `rescue_from(RuntimeError, with: :boom_handler)`, and `PostsController < ApplicationController` with `before_action :set_post, only: [:show, :edit]`, `before_action(except: [:index]) { |c| c.response.set_header("X-Block", "1") }`, `after_action :stamp`, plus a hand-written `run_callback(name)` `case` exactly as gen/controllers.rb would emit (with `else super`). Cases: callback order base→subclass; `only`/`except`; a before callback that redirects halts the chain and the action does not run; `render plain:`; `render json: {"a" => 1}` gives `{"a":1}` with application/json; `render html:` escapes String but not SafeString; `head :no_content`; `redirect_to "/x", status: :see_other`; an action that raises RuntimeError is handled by `boom_handler` (renders 500 text); an action raising ArgumentError (no handler) propagates out of `process` (assert_raises); no render at all raises MissingTemplate; an unknown callback name raises UnknownCallback; after callbacks run after the action; `status_code(:not_found) == 404`.
- [ ] **Step 2: Implement; `spin test --regen test/controller.rb`; `spin test` green.**

### Task 7: Session, Flash, CSRF

**Files:**
- Create: `cybertrain/session.rb`, `cybertrain/flash.rb`, `cybertrain/middleware/session_store.rb`, `cybertrain/middleware/csrf_protection.rb`, `cybertrain/crypto.rb`
- Modify: `cybertrain/context.rb` (nothing if the integrator already added the accessors)
- Test: `test/session.rb`, `test/flash.rb`, `test/csrf.rb`

**Interfaces:**
- Consumes: `Middleware`, `Context` (`session`, `flash` accessors), `Cookies`, `Request#cookie_header`, `Response#add_cookie`, `Params`, `require "openssl"` (`OpenSSL::HMAC.hexdigest("SHA256", key, data)`), `require "securerandom"`, `require "base64"`, `require "json"`.
- Produces:
  ```ruby
  module Cybertrain::Crypto
    def self.hmac_hex(secret, data)             # OpenSSL::HMAC.hexdigest("SHA256", secret, data)
    def self.secure_compare(a, b)               # constant-time String compare
    def self.random_token(bytes = 32)           # SecureRandom.hex(bytes)
  end
  class Cybertrain::Session
    def initialize(data = {})                   # Hash<String,String>
    def [](key); def []=(key, value); def delete(key); def key?(key); def keys; def clear; def to_h   # keys Symbol|String, values String
    def changed?
    def self.load(cookie_value, secret)         # "payload--hex" ; payload = Base64 urlsafe of JSON object of strings; bad/missing signature or JSON -> empty Session
    def self.dump(session, secret)              # -> cookie value
  end
  class Cybertrain::SessionStore < Cybertrain::Middleware
    def initialize(app, secret:, cookie_name: "_cybertrain_session", max_age: 1209600)   # before: ctx.session = Session.load(...) and ctx.flash = Flash.load(ctx.session); after: Flash.store(ctx.flash, ctx.session); when session.changed? add Set-Cookie (HttpOnly, SameSite=Lax, Path=/)
  end
  class Cybertrain::Flash
    def initialize
    def [](key)                                 # current-request values (from previous request or flash.now); Symbol|String -> String|nil
    def []=(key, value)                         # queued for the NEXT request
    def now                                     # FlashNow with []= and [] writing/reading the current values
    def keys; def empty?; def each { |k, v| }   # current values, insertion order
    def self.load(session)                      # reads session["_flash"] (JSON object) into current values and deletes the key
    def self.store(flash, session)              # writes queued values to session["_flash"] as JSON when any
  end
  class Cybertrain::FlashNow
    def initialize(flash); def [](key); def []=(key, value)
  end
  class Cybertrain::CsrfProtection < Cybertrain::Middleware
    TOKEN_KEY = "_csrf_token"; PARAM = "authenticity_token"; HEADER = "x-csrf-token"
    def initialize(app)
    def self.token_for(session)                 # creates and stores a token when absent; returns it
    def call(ctx)                               # GET/HEAD/OPTIONS pass; otherwise param or header must secure_compare the session token, else 403 with body "Invalid authenticity token" and the chain stops
  end
  ```

- [ ] **Step 1: tests.** Session: round trip dump/load, tampered signature loads empty, wrong secret loads empty, garbage loads empty, `changed?` semantics. Flash: value set in request 1 visible in request 2 and gone in request 3 (drive `load`/`store` with one Session object across simulated requests), `flash.now` visible only in the current request, `each` order. CSRF: a POST without token → 403 and inner app not called; with the right token via param → passes; via header → passes; wrong token → 403; GET always passes. SessionStore: a chain SessionStore → custom middleware setting `ctx.session["user"] = "alice"` produces a Set-Cookie whose value loads back to `{"user"=>"alice"}`; a request carrying that cookie sees the value; an unchanged session sets no cookie.
- [ ] **Step 2: Implement. Store all session values as Strings only (design D8).**
- [ ] **Step 3: `spin test --regen` the three, `spin test` green.**

### Task 8: Generator core — routes DSL, route emitter, controller scan, manifest, runner

**Files:**
- Create: `cybertrain/generator.rb` (requires the parts), `cybertrain/generator/routes_dsl.rb`, `cybertrain/generator/routes_emitter.rb`, `cybertrain/generator/controller_scan.rb`, `cybertrain/generator/controllers_emitter.rb`, `cybertrain/generator/manifest.rb`, `cybertrain/generator/runner.rb`, `cybertrain/generator/inflector.rb`
- Test: `test/gen_routes.rb`, `test/gen_controllers.rb`, `test/gen_manifest.rb`, `test/gen_routes_compiles.rb` plus fixtures under `test/fixtures/gen_app/` (a tiny app tree: `app/controllers/application_controller.rb`, `app/controllers/posts_controller.rb`, `config/routes.rb`)

**Interfaces:**
- Consumes: `Router#add(verb, pattern, name, &handler)`, `Controller#process`, `Controller#run_callback`, `Cybertrain::Model#to_param` (M2b; until then generated URL helpers accept Integer|String and anything responding to `to_param`).
- Produces:
  ```ruby
  module Cybertrain::Inflector
    def self.camelize(str)       # "posts_controller" -> "PostsController"; "create_posts" -> "CreatePosts"
    def self.underscore(str)     # "PostsController" -> "posts_controller"
    def self.singularize(str)    # "posts" -> "post", "comments" -> "comment", "people" -> "person", "categories" -> "category" (rule table + irregulars; document that unknown words get the rules only)
    def self.pluralize(str)
  end
  class Cybertrain::Gen::RouteSpec
    attr_reader :verb, :pattern, :controller, :action, :name   # "GET", "/posts/:id/edit", "posts", "edit", "edit_post"
    def initialize(verb, pattern, controller, action, name)
    def handler_source           # 'PostsController.new(ctx).process(:edit) { |c| c.edit }'
    def helper_name              # "edit_post" ("" when unnamed)
  end
  module Cybertrain::Routes                      # the DSL entry used by config/routes.rb: Cybertrain::Routes.draw do ... end
    def self.draw(&block)                        # evaluates the block against a Mapper and stores the specs in Cybertrain::Routes.specs
    def self.specs                               # Array<RouteSpec>
    def self.reset!
  end
  class Cybertrain::Gen::Mapper
    def root(to)                                 # "posts#index" -> GET "/" name "root"
    def get(path, to:, as: ""); def post(...); def patch(...); def put(...); def delete(...)   # as: defaults to the path with "/" and ":" removed and "/" -> "_" ("/about" -> "about")
    def resources(name, only: [], except: [], &block)   # standard 7 actions; nesting via block: /posts/:post_id/comments ; names: posts, new_post, edit_post, post; nested: post_comments, new_post_comment, edit_post_comment, post_comment
    def member(&block); def collection(&block)   # inside resources: get "preview" -> /posts/:id/preview as preview_post ; collection: /posts/search as search_posts
  end
  module Cybertrain::Gen::RoutesEmitter
    def self.emit(specs)   # -> String: the gen/routes.rb source. It defines: module Gen; module Routes; def self.build(router) ... router.add(...) { |ctx| <handler_source> } ...; router; end; end; module UrlHelpers; def posts_path; "/posts"; end; def post_path(post); "/posts/#{Cybertrain::Gen.param(post)}"; end; def <name>_url(...); Cybertrain.url_root + <name>_path(...); end; ... ; def self.path_for(name, args) case name when "post_path" then ... end; end; end; class Cybertrain::Controller; include Gen::UrlHelpers; end
  end
  module Cybertrain::Gen
    def self.param(value)   # Integer -> to_s; String -> itself; anything else -> value.to_param (models); used by generated helpers
  end
  class Cybertrain::Gen::ControllerInfo
    attr_reader :file, :class_name, :superclass_name, :ivars, :callbacks   # ivars Array<String> unique in first-seen order; callbacks Array<String> (symbol names after before_action/after_action/around_action and rescue_from ... with:)
  end
  module Cybertrain::Gen::ControllerScan
    def self.scan_source(file, source)   # -> ControllerInfo|nil (nil when no `class X < Y` line)
    def self.scan_dir(dir)               # -> Array<ControllerInfo> sorted by file
  end
  module Cybertrain::Gen::ControllersEmitter
    def self.emit(infos)   # -> gen/controllers.rb source: for each info `class <Name>; def view_assigns; { "post" => @post, ... }; end; def run_callback(name); case name; when :set_post then set_post; ...; else super; end; end; end` (an ivar-less controller still gets an empty `{}` view_assigns; view_assigns values are the raw ivars — the template engine wraps them)
  end
  module Cybertrain::Gen::Manifest
    def self.emit(root)    # -> gen/app.rb source: require_relative lines, in order: "models/*" under gen/, "routes", "controllers", then ../app/models/*.rb (sorted), ../app/controllers/application_controller.rb first then the rest sorted, ../app/helpers/*.rb if present
  end
  module Cybertrain::Gen::Runner
    def self.run(root, argv)   # writes gen/routes.rb (from Cybertrain::Routes.specs), gen/controllers.rb, gen/app.rb; prints one "wrote <path>" line per file; returns 0; `--check` writes nothing and exits 1 with "stale: <path>" when a file would change
  end
  ```

- [ ] **Step 1: tests.** `gen_routes.rb`: draw the blog routes (`root "posts#index"; resources :posts do resources :comments, only: [:create, :destroy] end; get "/about", to: "pages#about"`) and assert the ordered list of `verb pattern controller#action name` lines, then assert the emitted source contains the exact handler lines and helper methods (`def edit_post_path(post)`, `def post_comments_path(post)`), and `path_for("post_path", ["7"]) == "/posts/7"` semantics by compiling the fixture (next test). `gen_controllers.rb`: scan fixture sources (with `@post =`, `@post ||=`, `before_action :set_post, only: [:show]`, `rescue_from RecordNotFound, with: :nf`) and assert `ivars == ["post", "posts"]`, `callbacks == ["set_post", "nf"]`, and the emitted source text. `gen_manifest.rb`: emit for the fixture tree and assert the require_relative order. `gen_routes_compiles.rb`: `require_relative "fixtures/gen_app/gen/routes"` and `.../gen/controllers"` (checked-in outputs of the emitters for the fixture, regenerated by the test itself by comparing emitter output with the file's content — fail with "fixture stale" if different) together with fixture controllers, build a Router through `Gen::Routes.build`, and drive it with `Cybertrain::Test::Client` to prove generated dispatch, `run_callback`, and URL helpers compile and behave.
- [ ] **Step 2: Implement.** The DSL executes at generator run time inside `bin/gen.rb`, which does `require "cybertrain/generator"; require_relative "../config/routes"; exit(Cybertrain::Gen::Runner.run(".", ARGV))`.
- [ ] **Step 3: `spin test --regen` all four, `spin test` green.**

### Task 9: Schema and migration data model

**Files:**
- Create: `cybertrain/schema.rb`, `cybertrain/schema/table.rb`, `cybertrain/schema/definition.rb`, `cybertrain/schema/dumper.rb`, `cybertrain/migration.rb`
- Test: `test/schema.rb`, `test/migration.rb`

**Interfaces:**
- Produces:
  ```ruby
  class Cybertrain::Schema::Column
    attr_reader :name, :type, :null, :default, :limit     # type Symbol in [:string, :text, :integer, :float, :boolean, :datetime, :date]; default String|nil (SQL literal text as written in the DSL, e.g. "0", "'x'", "false"); null true/false
  end
  class Cybertrain::Schema::Index;      attr_reader :table, :columns, :unique, :name  end   # name "index_<table>_on_<cols joined by _and_>"
  class Cybertrain::Schema::ForeignKey; attr_reader :from_table, :column, :to_table  end
  class Cybertrain::Schema::Table
    attr_reader :name, :columns, :indexes, :foreign_keys   # primary key "id" integer is implicit and NOT in columns
    def column(name)                                        # Column|nil
    def references                                          # Array<ForeignKey>
  end
  class Cybertrain::Schema::TableDef                        # the `t` in create_table blocks
    def string(name, null: true, default: nil, limit: 0); def text(...); def integer(...); def float(...); def boolean(...); def datetime(...); def date(...)
    def references(name, null: false, foreign_key: true)    # adds "<name>_id" integer + index + FK to pluralize(name)
    def timestamps                                          # created_at, updated_at datetime null: false
  end
  class Cybertrain::Schema::Definition
    attr_reader :tables, :version                           # tables Array<Table> sorted by name
    def create_table(name, &block)                          # yields TableDef
    def add_index(table, columns, unique: false)            # columns Array<Symbol|String>
    def add_foreign_key(from_table, to_table, column: "")   # column defaults to singularize(to_table) + "_id"
    def table(name)                                         # Table|nil
  end
  module Cybertrain::Schema
    def self.define(version: "0", &block)                   # yields a Definition, stores it as Cybertrain::Schema.current, returns it
    def self.current; def self.reset!
  end
  module Cybertrain::Schema::Dumper
    def self.to_ruby(definition)   # -> the db/schema.rb text in Rails style: Cybertrain::Schema.define(version: "...") do |s| ... s.create_table "posts" do |t| t.string "title", null: false ... t.timestamps end ... s.add_index ... s.add_foreign_key ... end  (deterministic: tables and columns in definition order, indexes then foreign keys sorted)
  end
  class Cybertrain::Migration::Operation
    attr_reader :kind, :table, :name, :type, :null, :default, :limit, :to_table, :columns, :unique, :new_name   # kind in [:create_table, :drop_table, :add_column, :remove_column, :rename_column, :add_index, :remove_index, :add_reference, :add_foreign_key]; create_table carries a Table
  end
  class Cybertrain::Migration::Base
    def change; def up; def down                            # subclasses override change (or up/down)
    def create_table(name, &block); def drop_table(name); def add_column(table, name, type, null: true, default: nil, limit: 0); def remove_column(table, name); def rename_column(table, from, to); def add_index(table, columns, unique: false); def remove_index(table, columns); def add_reference(table, name, null: false, foreign_key: true); def add_foreign_key(from, to, column: "")
    def operations                                          # Array<Operation> recorded by running change/up
    def self.version(v); def self.version_string           # class-level version declared in the file: `version "20260924120000"`
    def inverse(op)                                         # Operation for down of a change-recorded op (create_table -> drop_table, add_column -> remove_column, add_index -> remove_index, rename -> reverse); raises IrreversibleMigration for others
  end
  module Cybertrain::Migration
    class IrreversibleMigration < StandardError; end
    def self.register(version, migration)                   # Array<[version String, Base]> ordered by version; gen/migrations.rb (Task 14) emits the register calls
    def self.all; def self.reset!
  end
  ```

- [ ] **Step 1: tests.** Schema: define the blog schema (posts with title/body/timestamps, comments with references :post and commenter/body), assert columns/types/null/defaults, the implicit `post_id` column + index + foreign key, `Dumper.to_ruby` round trip (dump → evaluate the dumped text? not possible at runtime; instead assert the exact dumped text against a heredoc). Migration: a `CreatePosts` subclass with `change` recording create_table + add_index, `operations` order, `inverse` of each kind, IrreversibleMigration for remove_column, `register`/`all` ordering by version.
- [ ] **Step 2: Implement; snapshots; `spin test` green.**
