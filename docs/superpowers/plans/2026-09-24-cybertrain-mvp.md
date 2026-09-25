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
    def initialize(io = nil, level = :info)   # levels :debug < :info < :warn < :error; io nil -> writes to STDOUT
    def debug(msg); def info(msg); def warn(msg); def error(msg)   # prints "[INFO] msg" when enabled
    attr_accessor :level
  end
  module Cybertrain
    def self.logger; def self.logger=(l)   # process-wide logger (default Logger.new)
  end
  ```

  Spinel quirk: never construct `Logger.new(STDOUT)` or `Logger.new(STDERR)`
  explicitly, and never let a program build both a `Logger.new` (default,
  writes to STDOUT internally) and a `Logger.new(some_stringio)` while
  passing an explicit IO literal at either call site -- Spinel cannot union
  a real IO handle with StringIO behind one polymorphic `@io.puts` call
  site. Always call `Logger.new` (no args, or `Logger.new(nil, level)`) for
  stdout logging, and `Logger.new(some_io_or_stringio, level)` only for a
  StringIO/file sink. See `spikes/NOTES.md` rule 18.

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

---

## Wave M2b — Database, models, templates

Runs after Wave M2a is integrated. Three independent chains run in parallel: **10 → 14**, **11a → 11b**, **12 → 13**. Everything here follows `spikes/NOTES.md` rules 1–17; the spike programs named in each task are the proven shapes (copy their patterns, not their code).

### Task 10: SQLite connection and pool

**Files:**
- Create: `cybertrain/db.rb`, `cybertrain/db/sqlite_ffi.rb`, `cybertrain/db/connection.rb`, `cybertrain/db/pool.rb`
- Test: `test/db_sqlite.rb`
- Reference: `spikes/06_sqlite_pool/sqlite3_lib.rb`, `spikes/06_sqlite_pool/adapter.rb`, `spikes/06_sqlite_pool/pool_test.rb`

**Interfaces:**
- Produces:
  ```ruby
  module Cybertrain::DB::SQLite3           # ffi_lib "sqlite3"; every ffi_func/ffi_const the connection needs (open_v2, close, prepare_v2, step, reset, finalize, bind_int64/double/text/null, column_count/name/type/int64/double/text, changes, last_insert_rowid, errmsg, exec; malloc/free; ffi_read_ptr :read_ptr, 0). prepare/step/exec are blocking: true. bind_text passes -1 (SQLITE_TRANSIENT) as the destructor.
  class Cybertrain::DB::Error < StandardError; end
  class Cybertrain::DB::Connection
    def initialize(path)                  # OPEN_READWRITE|OPEN_CREATE; then PRAGMA journal_mode=WAL (not for ":memory:"), busy_timeout=5000, foreign_keys=ON. Out-pointers use malloc(8) scratch per call, never a static ffi_buffer.
    attr_reader :path
    def execute(sql, binds = [])          # -> Array<Hash<String, value>>; value Integer|Float|String|nil; TEXT copied out with `txt + ""`; binds dispatched: nil -> bind_null, Integer -> bind_int64, Float -> bind_double, true/false -> 1/0, Time -> ISO8601 UTC string, else to_s -> bind_text. Raises Error "<errmsg> (sql: <sql>)" on any non-OK rc; always finalizes the statement (ensure).
    def exec_script(sql)                  # sqlite3_exec for multi-statement DDL; raises Error
    def changes                           # Integer rows changed by the last statement
    def last_insert_id                    # Integer
    def transaction                       # yields; BEGIN before, COMMIT after, ROLLBACK and re-raise on exception; nested calls just yield (depth counter)
    def close; def closed?
  end
  class Cybertrain::DB::Pool
    def initialize(path, size = 4)        # opens `size` Connections into a SizedQueue
    def with                              # yields a Connection; checks it back in an ensure block
    def size; def close_all
  end
  module Cybertrain::DB
    def self.connect(path, size: 4)       # creates and installs the process-wide pool; returns it
    def self.pool; def self.pool=(p); def self.connected?
    def self.with(&block)                 # pool.with
    def self.disconnect
  end
  ```

- [ ] **Step 1: `test/db_sqlite.rb`.** Using `:memory:` for most cases and `tmp/db_sqlite_test.sqlite3` (deleted first) for the pool: create table; insert with Integer/Float/String/nil/true/Time binds and read them back with the right Ruby types (`Integer`, `Float`, `String`, nil, `1`, the ISO string); unicode text round trip; `changes` after UPDATE; `last_insert_id`; a syntax error raises `DB::Error` including the SQL; `transaction` commits; `transaction` rolls back when the block raises (count unchanged) and re-raises; nested transaction; `PRAGMA table_info(posts)` and `PRAGMA foreign_key_list(comments)` rows; `SELECT name, sql FROM sqlite_master`; pool: 8 threads × 100 inserts through `DB.with`, final count 800; `DB.connect`/`DB.with`/`DB.disconnect`.
- [ ] **Step 2: Implement.** Run the pool case both with default `SPINEL_WORKERS` and `SPINEL_WORKERS=1`.
- [ ] **Step 3: `spin test --regen test/db_sqlite.rb`; `spin test` green.**

### Task 11a: Model runtime base — Cast, Errors, Validator, Model, Relation

**Files:**
- Create: `cybertrain/cast.rb`, `cybertrain/errors.rb`, `cybertrain/validator.rb`, `cybertrain/model.rb`, `cybertrain/relation.rb`
- Test: `test/model.rb` (defines hand-written `Post`/`PostRelation`/`Comment`/`CommentRelation` exactly as Task 11b will generate them — this test is the executable specification of the generated shape)
- Reference: `spikes/04_relation_typing/orm5.rb`

**Interfaces:**
- Consumes: `Cybertrain::DB` (Task 10), `require "json"`.
- Produces:
  ```ruby
  module Cybertrain::Cast
    def self.int(v); def self.int_or_nil(v); def self.str(v); def self.str_or_nil(v); def self.float(v); def self.float_or_nil(v); def self.bool(v); def self.bool_or_nil(v)   # bool accepts true/false/1/0/"1"/"0"/"true"/"false"/"on"/""
    def self.time_or_nil(v)     # Time -> itself; Integer -> Time.at(v).utc; String "YYYY-MM-DDTHH:MM:SSZ" or "YYYY-MM-DD HH:MM:SS" -> Time.utc(...); else nil
    def self.to_sql(v)          # Time -> "YYYY-MM-DDTHH:MM:SSZ" (UTC); true/false -> 1/0; nil/Integer/Float/String pass through
    def self.iso8601(time)      # Time -> String
  end
  class Cybertrain::Errors
    def initialize; def add(attr, message); def [](attr); def any?; def empty?; def count; def clear; def key?(attr); def keys
    def full_messages           # ["Title can't be blank"]: humanized attr (capitalize, underscores to spaces) + " " + message
    def each                    # yields (attr Symbol, message String) in insertion order
  end
  class Cybertrain::Validator
    attr_reader :attr, :kind, :minimum, :maximum, :allow_blank   # kind :presence | :length ; minimum/maximum Integer (-1 when unset)
    def validate(record)        # appends to record.errors: presence -> "can't be blank" when value nil or blank String; length -> "is too short (minimum is N characters)" / "is too long (maximum is N characters)" (skips nil unless presence also fails)
  end
  class Cybertrain::RecordNotFound < StandardError; end
  class Cybertrain::RecordInvalid < StandardError; end
  class Cybertrain::Model
    VALIDATORS = {}   # Hash<String, Array<Validator>> keyed by model_name
    CALLBACKS = {}    # Hash<String, Array<Proc>> keyed by "#{model_name}:#{kind}" ; kinds before_validation, before_save, after_save, before_create, after_create, before_update, after_update, before_destroy, after_destroy ; blocks take the record
    def self.validates(attr, presence: false, length: nil)     # length: Hash<Symbol,Integer> with :minimum/:maximum ; registers under self.name
    def self.before_save(&b); def self.after_save(&b); def self.before_create(&b); def self.after_create(&b); def self.before_update(&b); def self.after_update(&b); def self.before_destroy(&b); def self.after_destroy(&b); def self.before_validation(&b)
    def self.validators_for(model_name); def self.callbacks_for(model_name, kind)
    # --- abstract hooks the generated subclass overrides (stubs are mandatory: NOTES rule 3) ---
    def self.table_name = ""; def self.column_names = [] ; def model_name = ""      # model_name returns a String literal per generated class
    def read_attribute(name) = nil; def write_attribute(name, value) = nil; def assign_attributes(attrs) = self   # attrs Hash with String or Symbol keys (normalize with k.to_s)
    def to_row = {}              # Hash<String, value> of every column except id, values through Cast.to_sql
    def load_row(row) = nil      # sets every ivar from a DB row (casts) and marks persisted
    def read_association(name) = nil; def call_view_method(name) = nil
    # --- concrete ---
    attr_reader :id, :errors     # id Integer (0 when new)
    def initialize               # @id = 0; @persisted = false; @errors = Errors.new (generated initialize(attrs = {}) calls super() then assigns)
    def set_id(v); def mark_persisted!
    def persisted?; def new_record?; def to_param   # id.to_s
    def valid?                   # before_validation callbacks, errors.clear, run validators_for(model_name)
    def save                     # before_save; valid? or return false; before_create/before_update; INSERT (sets id, created_at/updated_at when columns exist) or UPDATE ... WHERE id = ?; after_create/after_update; after_save; true
    def save!                    # raises RecordInvalid with errors.full_messages.join(", ")
    def update(attrs)            # assign_attributes then save
    def destroy                  # before_destroy; DELETE; @persisted = false; after_destroy; true
    def reload                   # re-select by id and load_row
    def ==(other)                # same class name and same non-zero id
    def attributes               # Hash<String, value> including id (via read_attribute over column_names)
    def as_json; def to_json     # attributes with Time as ISO8601; JSON.generate
    def self.now_string          # Cast.iso8601(Time.now.utc)
  end
  class Cybertrain::Relation
    def initialize(table)        # @wheres Array<String>, @binds Array<value> (seeded typed: [0]; then clear), @order "" , @limit -1, @offset 0
    def add_where(hash)          # Hash<Symbol, value>: nil -> "col IS NULL", Array -> "col IN (?,?)", else "col = ?"; returns nil
    def add_where_sql(sql, binds) # raw fragment + binds; returns nil
    def set_order(order); def set_limit(n); def set_offset(n)   # return nil (subclass wrappers return self)
    def to_sql                   # SELECT * FROM t [WHERE a AND b] [ORDER BY o] [LIMIT n] [OFFSET m]
    def binds
    def rows                     # DB.with { |c| c.execute(to_sql, binds) }
    def count                    # SELECT COUNT(*) with the same WHERE
    def exists?; def delete_all  # -> Integer
    def first_row                # rows of limit(1) -> Hash|nil
    def last_row                 # ORDER BY id DESC when no order
  end
  ```
  The generated per-model shape that `test/model.rb` hand-writes (Task 11b emits exactly this):
  ```ruby
  class PostRelation < Cybertrain::Relation
    def where(h) = (add_where(h); self); def where_sql(s, b = []) = (add_where_sql(s, b); self)
    def order(o) = (set_order(o); self); def limit(n) = (set_limit(n); self); def offset(n) = (set_offset(n); self)
    def to_a; out = Array.new(0) { Post.new }; rows.each { |r| out << Post.from_row(r) }; out; end
    def each(&blk) = to_a.each(&blk)
    def first; r = first_row; return nil if r.nil?; Post.from_row(r); end
    def last;  r = last_row;  return nil if r.nil?; Post.from_row(r); end
    def find_by(h) = where(h).first
    def find(id); rec = where(id: id).first; raise Cybertrain::RecordNotFound, "Couldn't find Post with id=#{id}" if rec.nil?; rec; end
    def size = count
  end
  class Post < Cybertrain::Model
    def self.table_name = "posts"
    def self.column_names = ["id", "title", "body", "created_at", "updated_at"]
    def model_name = "Post"
    attr_accessor :title, :body, :created_at, :updated_at
    def initialize(attrs = {}); super(); @title = ""; @body = nil; @created_at = nil; @updated_at = nil; assign_attributes(attrs); end
    def self.from_row(row); rec = Post.new; rec.load_row(row); rec; end
    def load_row(row); set_id(Cybertrain::Cast.int(row["id"])); @title = Cybertrain::Cast.str(row["title"]); @body = Cybertrain::Cast.str_or_nil(row["body"]); @created_at = Cybertrain::Cast.time_or_nil(row["created_at"]); @updated_at = Cybertrain::Cast.time_or_nil(row["updated_at"]); mark_persisted!; nil; end
    def read_attribute(name); case name; when :id then @id; when :title then @title; when :body then @body; when :created_at then @created_at; when :updated_at then @updated_at; else nil; end; end
    def write_attribute(name, value); case name; when :title then @title = Cybertrain::Cast.str(value); when :body then @body = Cybertrain::Cast.str_or_nil(value); when :created_at then @created_at = Cybertrain::Cast.time_or_nil(value); when :updated_at then @updated_at = Cybertrain::Cast.time_or_nil(value); end; nil; end
    def assign_attributes(attrs); attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }; self; end   # NOTE: k.to_s.to_sym on a literal-free name — Spinel interns at runtime; verify it compiles, else write_attribute takes a String and the case uses strings
    def to_row; { "title" => Cybertrain::Cast.to_sql(@title), "body" => Cybertrain::Cast.to_sql(@body), "created_at" => Cybertrain::Cast.to_sql(@created_at), "updated_at" => Cybertrain::Cast.to_sql(@updated_at) }; end
    def self.all = PostRelation.new("posts"); def self.where(h) = all.where(h); def self.order(o) = all.order(o); def self.limit(n) = all.limit(n)
    def self.find(id) = all.find(id); def self.find_by(h) = all.find_by(h); def self.first = all.first; def self.last = all.last; def self.count = all.count
    def self.create(attrs = {}); rec = Post.new(attrs); rec.save; rec; end
    def comments = CommentRelation.new("comments").where(post_id: @id).to_a     # has_many from comments.post_id
    def read_association(name); case name; when :comments then comments; else nil; end; end
    def call_view_method(name); case name; when :summary then summary; else nil; end; end   # arity-0 defs found in app/models/post.rb
  end
  ```
  **Decide the `write_attribute` key type early:** if `k.to_s.to_sym` does not compile or interns wrongly, make `write_attribute(name)` take a String and the `case` compare Strings; `read_attribute(name)` keeps Symbols (the template interpreter calls it with Symbols).

- [ ] **Step 1: `test/model.rb`.** Connect to `:memory:`, create the posts/comments tables with raw SQL, then: `Post.new(title: "x").save` inserts and sets id/created_at; `Post.find(id)` returns typed record; `Post.find(999)` raises RecordNotFound with message; `where` chaining `order`/`limit`/`offset`; `first` on empty → nil; `count`/`exists?`; validations (`validates :title, presence: true, length: { minimum: 3 }` declared in the test on Post): `save` false + `errors.full_messages`, `save!` raises RecordInvalid; `update`; `destroy`; `reload`; `before_save { |r| r.title = r.title.strip }` runs; `after_create` runs once; `comments` association through `comments.post_id`; `to_json` exact string; `==`; `to_param`; nullable `body` round trips nil and String; `created_at` is a Time after reload; `assign_attributes` with String keys from `Params#permit`.
- [ ] **Step 2: Implement; snapshot; `spin test` green.**

### Task 11b: Model generator

**Files:**
- Create: `cybertrain/generator/models_emitter.rb`, `cybertrain/generator/model_scan.rb`
- Modify: `cybertrain/generator/runner.rb` (write `gen/models/<model>.rb` per table when `Cybertrain::Schema.current` is set), `cybertrain/generator/manifest.rb` (already lists gen/models/*)
- Test: `test/gen_models.rb`, `test/gen_models_compiles.rb` (+ fixture `test/fixtures/gen_app/db/schema.rb`, `test/fixtures/gen_app/app/models/post.rb`, and the checked-in emitted `test/fixtures/gen_app/gen/models/*.rb` regenerated-and-compared by the test)

**Interfaces:**
- Consumes: `Cybertrain::Schema::Definition/Table/Column/ForeignKey` (Task 9), `Cybertrain::Inflector` (Task 8), the exact class shape specified in Task 11a.
- Produces:
  ```ruby
  module Cybertrain::Gen::ModelScan
    def self.scan_source(file, source)   # -> ModelInfo(class_name, view_methods Array<String> = names of `def name` with no parameters and not starting with "self.", excluding names that collide with column names)
    def self.scan_dir(dir)               # Array<ModelInfo>
  end
  module Cybertrain::Gen::ModelsEmitter
    def self.model_class_name(table)     # "posts" -> "Post" (singularize + camelize)
    def self.emit(table, definition, view_methods)   # -> source of gen/models/<singular>.rb: `<Model>Relation` + `<Model>` exactly as Task 11a specifies; column types map: string/text -> str (null: false) or str_or_nil; integer -> int / int_or_nil; float -> float / float_or_nil; boolean -> bool / bool_or_nil; datetime/date -> time_or_nil / str_or_nil(date); belongs_to for each FK column `x_id` -> `def x` (find_by id) ; has_many for each other table's FK pointing here -> `def <plural>`; read_association case over both; call_view_method case over view_methods (empty case body `else nil` when none)
    def self.file_name(table)            # "posts" -> "post.rb"
  end
  ```

- [ ] **Step 1: tests.** `gen_models.rb`: from the blog schema assert the emitted source for `posts` and `comments` contains the exact lines for `model_name`, `column_names`, casts per column, `def post` / `def comments`, the `read_association` case, and `call_view_method` with a scanned `summary`. `gen_models_compiles.rb`: require the checked-in fixture outputs plus the fixture `app/models/post.rb` (which reopens `Post` with `validates :title, presence: true` and `def summary = title[0, 3]`), connect `:memory:`, create tables from `Cybertrain::Schema` via raw SQL in the test, and drive create/find/association/`call_view_method(:summary)`/`to_json` to prove the generated code compiles and runs.
- [ ] **Step 2: Implement; snapshots; `spin test` green.**

### Task 12: Template engine core

**Files:**
- Create: `cybertrain/template.rb`, `cybertrain/template/lexer.rb`, `cybertrain/template/ast.rb`, `cybertrain/template/parser.rb`, `cybertrain/template/inode.rb`, `cybertrain/template/interpreter.rb`, `cybertrain/template/engine.rb`
- Test: `test/template_lexer.rb`, `test/template_parser.rb`, `test/template_interpreter.rb`, `test/template_engine.rb` (+ fixtures under `test/fixtures/views/`)
- Reference: `spikes/03_value_interpreter/interp_mono.rb`, `tparse.rb` and design.md section 7 (the language)

**Interfaces:**
- Consumes: `Cybertrain::Html.escape`, `Cybertrain::SafeString`, `Cybertrain::Model` hooks (`read_attribute`, `read_association`, `call_view_method`, `persisted?`, `new_record?`, `to_param`, `errors`), `Cybertrain::Errors`, `Cybertrain::Params`.
- Produces:
  ```ruby
  class Cybertrain::Template::SyntaxError < StandardError; end     # message "<name>:<line>: <what>"
  class Cybertrain::Template::RuntimeError < StandardError; end    # "<name>:<line>: undefined method 'x' for String" etc.
  class Cybertrain::Template::Token; attr_reader :kind, :text, :line   # kinds :text, :code, :output, :output_raw, :comment
  module Cybertrain::Template::Lexer; def self.tokenize(source, name)  # handles <% %>, <%= %>, <%== %>, <%# %>, <%- -%> trimming, %%> escape; a "locals: (a:, b:)" comment on line 1 is exposed via Template#locals
  # AST (class-per-node, parser output): Node base; TextNode(text); OutputNode(expr, raw); IfNode(cond, then_nodes, elsif_pairs, else_nodes); UnlessNode; EachNode(iter_expr, vars Array<String>, body_nodes); BlockCallNode(call_expr, params Array<String>, body_nodes) for `helper(...) do |f| ... end` (and `<%= form_with ... do |f| %>`); expressions: StrLit, IntLit, FloatLit, SymLit, NilLit, TrueLit, FalseLit, ArrayLit(items), HashLit(pairs Array<[String, expr]>), IVar(name), LVar(name), Call(recv|nil, name String, args, kwargs Array<[String, expr]>, safe_nav), BinOp(op String, left, right), NotNode(expr), Ternary(cond, a, b), Interp(parts Array<expr|StrLit>), IndexNode(recv, index)
  module Cybertrain::Template::Parser; def self.parse(tokens, name) # -> Array<Node> (body); expression grammar per design.md section 7 with Ruby precedence (?: < || < && < == != < < > <= >= < + - < * / % < unary ! < call/index/&.); `if/elsif/else/unless/end`, `x.each do |a, b| ... end`, `x.each_with_index`, `helper(...) do |f| ... end`; anything else raises SyntaxError with line
  class Cybertrain::Template::INode      # monomorphic node: kind Integer, str String, int Integer, flt Float, sym Symbol, a INode, b INode, c INode, kids Array<INode>, kids2 Array<INode>, names Array<String>, pairs Array<String> ; constants K_TEXT, K_OUT, K_OUT_RAW, K_IF, K_UNLESS, K_EACH, K_BLOCK_CALL, K_STR, K_INT, K_FLOAT, K_SYM, K_NIL, K_TRUE, K_FALSE, K_ARRAY, K_HASH, K_IVAR, K_LVAR, K_CALL, K_AND, K_OR, K_EQ, K_NEQ, K_LT, K_GT, K_LE, K_GE, K_ADD, K_SUB, K_MUL, K_DIV, K_MOD, K_NOT, K_TERNARY, K_INTERP, K_INDEX ; LEAF / NO_KIDS sentinels (never nil children)
  module Cybertrain::Template::Compile; def self.convert(nodes)  # Array<Node> -> Array<INode>
  class Cybertrain::Template::Template; attr_reader :name, :nodes, :locals, :source_path   # locals Array<String> from the strict-locals comment ("" for none)
  class Cybertrain::Template::Interpreter
    def initialize(helpers)              # helpers: Cybertrain::Template::HelperBase (Task 13 defines the concrete one; this task ships HelperBase with `call(name, args, kwargs, block, interp, env)` raising RuntimeError "undefined helper", `block` being an INode body or nil)
    def render(template, env)            # env Hash<String, value> ("post" => rec, "posts" => [..], "f" => builder ...); returns String (the output buffer, `+""`)
    def eval_expr(node, env)             # -> value
    def call_method(recv, name_sym, name_str, args, kwargs, node)   # dispatch table: String (upcase downcase capitalize strip size length empty? to_s to_i include? start_with? end_with? + ==), Integer/Float (+ - * / % to_s zero? positive? abs), true/false/nil (to_s nil? !), Time (year month day hour min sec strftime to_s) — Time BEFORE Array — Array (size length empty? first last any? include? join reverse), Hash ([] key? size empty? fetch), SafeString (to_s html_safe?), Errors (any? empty? count full_messages [] key?), Params ([] key?), Model (persisted? new_record? to_param errors id, then read_attribute(sym) unless nil, then read_association(sym) unless nil, then call_view_method(sym); a nil result for an unknown name raises RuntimeError "undefined method 'x' for Post" only when name is not a column — implement via a `respond_to_name?` hook: Model gets `def attribute_or_method?(sym) = false` stub that generated code overrides); unknown -> RuntimeError
    def truthy?(v)                       # Ruby truthiness
    def to_output(v)                     # nil -> "", SafeString -> raw, String -> escape, other -> escape(to_s)
  end
  class Cybertrain::Template::Engine
    def initialize(root, cache: true)    # root "app/views"
    def template(name)                   # "posts/show.html.erb" or "posts/show" (adds .html.erb) -> Template; parses on first use; when cache is false re-reads when File.mtime changed; raises Cybertrain::Template::MissingTemplate (define it here) with the looked-up path
    def exists?(name)
    def render(name, env, helpers)       # -> String
    def render_with_layout(name, layout, env, helpers)   # renders name, then layout with env["__content"] = output; the layout's `<%= yield %>` reads it (parser treats bare `yield` as Call name "yield"; interpreter resolves to env["__content"]) and `<%= yield :title %>` / `content_for` read env["__content_title"] set by the content_for helper
    def clear_cache!
  end
  ```

- [ ] **Step 1: tests.** Lexer: all tag kinds, trimming, line numbers, locals comment. Parser: precedence (`a + b * c`, `!x && y`, `a == b ? "x" : "y"`), calls with args/kwargs/safe-nav, each with two vars, if/elsif/else, unless, block call, syntax errors with line numbers (`<% if %>` without end, unknown token). Interpreter: literals, string interpolation, ivar/lvar lookup, arithmetic/comparison/boolean ops with truthiness, each over Array and Hash (`|k, v|`), Time methods (Time before Array!), Model dispatch through a hand-written Post (`read_attribute`, `read_association`, `call_view_method`), `errors.full_messages`, unknown method → RuntimeError with template line, escaping vs raw, nil prints "". Engine: fixtures under `test/fixtures/views/` (`posts/index.html.erb` with a loop, `layouts/application.html.erb` with `yield`, `posts/_form.html.erb` with a strict-locals comment), cache off re-reads after a rewrite (write a temp copy, render, modify, render again), MissingTemplate.
- [ ] **Step 2: Implement. Precompute the method Symbol per call node at parse time. Keep frequent kinds first in the dispatch chain (K_TEXT, K_OUT, K_CALL, K_LVAR, K_IVAR).**
- [ ] **Step 3: `spin test --regen` the four; `spin test` green.**

### Task 13: View helpers, form builder, controller rendering

**Files:**
- Create: `cybertrain/template/helpers.rb`, `cybertrain/template/form_builder.rb`, `cybertrain/views.rb`
- Modify: `cybertrain/controller.rb` (`render_template`, `default_render`, `render partial:`, `view_assigns` hook)
- Test: `test/helpers.rb`, `test/form_builder.rb`, `test/controller_views.rb` (+ fixtures under `test/fixtures/views/`)

**Interfaces:**
- Consumes: Task 12 (`Interpreter`, `Engine`, `HelperBase`, `INode`), Task 6 (`Controller`), Task 7 (`Flash`, `CsrfProtection.token_for`), `Cybertrain::Html`, `Cybertrain::Model`.
- Produces:
  ```ruby
  module Cybertrain::Views
    def self.engine; def self.engine=(e); def self.configure(root, cache:)   # process-wide Engine
    def self.url_resolver=(lambda); def self.url_resolver                  # ->(name String, args Array<value>) { String } installed by the app from generated code (Gen::Routes.path_for); default raises "no routes"
    def self.layout_name; def self.layout_name=(n)                          # "layouts/application"
  end
  class Cybertrain::Template::Helpers < Cybertrain::Template::HelperBase
    def initialize(controller)   # controller Cybertrain::Controller|nil (nil in unit tests)
    def call(name, args, kwargs, block, interp, env)   # dispatch by name String:
      # "h"/"escape" -> String ; "raw" -> SafeString ; "link_to"(text, path, class:, method:, data_confirm:) -> SafeString <a> (method: :delete -> data-turbo-method? no: emits a <form> button like button_to; keep `method:` unsupported → SyntaxError) ; "button_to"(text, path, method: :post) -> SafeString <form method="post" action=...><input type="hidden" name="_method" value="delete"><input type="hidden" name="authenticity_token" ...><button>text</button></form> ; "form_with"(model:, url:, method:, class:) with block -> renders <form> + hidden _method/authenticity_token + block body with env["f"] = FormBuilder (the block's single param name is used); "render"(partial String, **locals) -> renders "<dir>/_<partial>" where dir = current template dir (env["__template_dir"]), locals merged into a copy of env (strict locals enforced: missing required local raises) ; "pluralize"(n, word) ; "truncate"(s, length: 30) ; "number_with_delimiter"(n) ; "time_ago_in_words"(t) ; "content_for"(name Symbol) with block -> stores env["__content_<name>"] and returns "" ; "yield"(name?) ; "csrf_meta_tags" ; "csrf_token" ; "flash" -> the Flash object ; "params" ; "request_path" ; any "<x>_path"/"<x>_url" -> Views.url_resolver.call(name, args); "url_for"(model or String) -> polymorphic via url_resolver with name derived from the model: "#{underscore(model_name)}_path"
      # unknown -> RuntimeError "undefined helper 'x'"
  end
  class Cybertrain::FormBuilder
    def initialize(model, helpers)   # model Cybertrain::Model|nil
    def call_method(name_sym, args, kwargs)   # used by the interpreter for `f.xxx`: label(attr, text = humanized), text_field(attr, class:, placeholder:), text_area(attr, rows: 4), hidden_field(attr), number_field, check_box(attr), submit(text = "Save Post"/"Update Post" by persisted?) ; inputs are named "<param_key>[attr]" where param_key = underscore(model_name); values from model.read_attribute(attr) escaped; fields for attrs with errors get class "field_with_errors"
  end
  class Cybertrain::Controller
    def view_assigns                 # base returns {} (Hash<String, value> seeded typed); gen/controllers.rb overrides
    def view_env(extra)              # view_assigns + extra + "flash"/"params"/"__template_dir"/"__controller_path"
    def controller_path              # "posts" from "PostsController" (Inflector.underscore minus _controller); "admin/posts" is out of scope
    def render_template(name, locals = {})   # Engine.render_with_layout("#{controller_path}/#{name}", Views.layout_name (if exists), env, Helpers.new(self)); sets text/html, performed
    def default_render(action)       # render_template(action.to_s)
    def render(template = nil, plain:, html:, json:, status:, content_type:, partial: nil, locals: {}, layout: true)   # extended: `render :new, status: :unprocessable_entity`, `render partial: "form", locals: {...}` (no layout), `layout: false`
  end
  ```

- [ ] **Step 1: tests.** Helpers: `link_to` escaping of text and attribute; `button_to` emits hidden `_method` and token; `pluralize(1, "comment")`/`(2, ...)`; `truncate`; `time_ago_in_words` buckets; `render "form", post: rec` with strict locals; `content_for`/`yield :title`; `url_resolver` stub called with name and args for `post_path(post)` and `edit_post_path(post)` and `posts_path`. FormBuilder: `form_with(model: new_post)` → `action="/posts" method="post"`; persisted → `action="/posts/7"` + hidden `_method=patch`; `text_field :title` value escaping; error class; `submit` default labels. Controller views: a `PostsController` whose `show` sets `@post` and does nothing else → implicit render of `test/fixtures/views/posts/show.html.erb` inside the layout; `render :new, status: :unprocessable_entity`; `render partial:`; `layout: false`; MissingTemplate → error propagates as `Cybertrain::Template::MissingTemplate`.
- [ ] **Step 2: Implement; snapshots; `spin test` green.**

### Task 14: Migrator, schema dumper, migrations manifest, `bin/db`

**Files:**
- Create: `cybertrain/db/sqlite_ddl.rb`, `cybertrain/db/migrator.rb`, `cybertrain/db/schema_dumper.rb`, `cybertrain/generator/migrations_emitter.rb`, `cybertrain/db/cli.rb`
- Modify: `cybertrain/generator/runner.rb` (also writes `gen/migrations.rb` from `db/migrate/*.rb` file names)
- Test: `test/migrator.rb`, `test/schema_dumper.rb`, `test/gen_migrations.rb`

**Interfaces:**
- Consumes: Task 9 (`Schema::*`, `Migration::*`), Task 10 (`DB::Connection`), Task 8 (`Inflector`).
- Produces:
  ```ruby
  module Cybertrain::DB::SqliteDDL
    def self.create_table(table)            # Schema::Table -> "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, ..., FOREIGN KEY (post_id) REFERENCES posts(id))" ; types: string/text -> TEXT, integer -> INTEGER, float -> REAL, boolean -> INTEGER, datetime/date -> TEXT
    def self.statements(op)                 # Migration::Operation -> Array<String> (create_table also emits its indexes; add_column -> ALTER TABLE ADD COLUMN; remove_column -> ALTER TABLE DROP COLUMN; rename_column -> ALTER TABLE RENAME COLUMN; add_index/remove_index; add_reference -> add column + index; drop_table; add_foreign_key -> raises IrreversibleMigration "SQLite cannot add a foreign key to an existing table; declare it in create_table")
  end
  class Cybertrain::DB::Migrator
    def initialize(connection)              # ensures schema_migrations(version TEXT PRIMARY KEY)
    def applied_versions                    # Array<String> sorted
    def pending(migrations)                 # Array<[version, migration]>
    def migrate(migrations)                 # runs each pending migration's change/up ops inside a transaction, records the version; prints "== <version> <ClassName>: migrating" / "done"; returns count
    def rollback(migrations, steps = 1)     # inverse ops of the last applied versions (uses down when defined)
    def status(migrations)                  # Array<[status "up"/"down", version, name]>
  end
  module Cybertrain::DB::SchemaDumper
    def self.dump(connection)               # introspects sqlite_master + PRAGMA table_info/index_list/index_info/foreign_key_list into a Schema::Definition (excluding schema_migrations, sqlite_* tables); version = max applied version
    def self.dump_to_ruby(connection)       # Schema::Dumper.to_ruby(dump(connection))
  end
  module Cybertrain::Gen::MigrationsEmitter
    def self.emit(root)                     # gen/migrations.rb: for each db/migrate/<version>_<name>.rb sorted: require_relative "../db/migrate/<file>" and Cybertrain::Migration.register("<version>", <CamelName>.new)
  end
  module Cybertrain::DB::CLI
    def self.run(argv, root = ".")          # subcommands: migrate | rollback [N] | status | schema:dump | create ; DB path from Cybertrain.config (Task 15) or ENV["CYBERTRAIN_DATABASE"] or "storage/#{env}.sqlite3"; after migrate/rollback writes db/schema.rb via SchemaDumper; returns exit code. bin/db.rb in an app: require "cybertrain"; require_relative "../gen/migrations"; exit(Cybertrain::DB::CLI.run(ARGV))
  end
  ```

- [ ] **Step 1: tests.** Migrator: two migrations (create posts; create comments with references) on `:memory:`: `migrate` applies both, `applied_versions`, `status`, second `migrate` is a no-op, `rollback` drops comments, re-migrate; the SQL for each operation kind (assert `SqliteDDL.statements` strings). SchemaDumper: after migrating, `dump` reproduces the tables/columns/null/indexes/foreign keys and `dump_to_ruby` equals the expected schema.rb text (heredoc). gen_migrations: emitter output for two fixture file names.
- [ ] **Step 2: Implement; snapshots; `spin test` green.**

---

## Wave M3 — Application boot, dev loop, CLI, example app

Runs after Wave M2b is integrated. Order: **15** first (everything else boots through it), then **16** and **17** in parallel, then **18**, then **19**.

### Task 15: Config and Application boot

**Files:**
- Create: `cybertrain/config.rb`, `cybertrain/application.rb`
- Modify: `cybertrain/db/cli.rb` (use `Cybertrain.config.database_path` when available)
- Test: `test/application.rb`

**Interfaces:**
- Consumes: every middleware, `Router`, `Server`, `DB`, `Views`, `Gen::Routes.build`/`path_for` (generated, referenced only through arguments).
- Produces:
  ```ruby
  class Cybertrain::Config
    attr_accessor :env, :host, :port, :database_path, :secret_key_base, :views_root, :public_root, :layout, :log_level, :session_cookie_name, :session_max_age, :pool_size, :static_files, :csrf
    def initialize            # env = ENV["CYBERTRAIN_ENV"] || "development"; host "127.0.0.1"; port 3000 (ENV["PORT"]); database_path "storage/#{env}.sqlite3" (ENV["CYBERTRAIN_DATABASE"]); secret_key_base ENV["CYBERTRAIN_SECRET_KEY_BASE"] or "" ; views_root "app/views"; public_root "public"; layout "layouts/application"; log_level :info; session_cookie_name "_cybertrain_session"; session_max_age 1209600; pool_size 4; static_files true; csrf true
    def development?; def test?; def production?
    def resolve_secret!       # production: raise "CYBERTRAIN_SECRET_KEY_BASE is not set" when empty; other envs: read or create tmp/secret_key (64 hex chars)
  end
  module Cybertrain
    def self.config; def self.configure { |c| }   # config/app.rb calls Cybertrain.configure do |c| c.port = 3000 end
    def self.env
  end
  class Cybertrain::Application
    def initialize(router:, url_resolver:, config: Cybertrain.config)   # router: Cybertrain::Router already filled by Gen::Routes.build; url_resolver: lambda
    def stack                 # Middleware: RequestLogger (unless log_level :none) -> Static (if static_files) -> MethodOverride -> SessionStore -> CsrfProtection (if csrf) -> router
    def boot                  # config.resolve_secret!; DB.connect(config.database_path, size: pool_size) unless connected; Views.configure(views_root, cache: !development?); Views.url_resolver = url_resolver; Views.layout_name = layout; Cybertrain.logger.level = log_level; returns self
    def call(ctx)             # stack.call(ctx) (for tests)
    def server                # Cybertrain::Server.new(stack, host:, port:)
    def run                   # boot; server.run (Task 16 wraps this with the dev loop)
  end
  ```
  The generated app's `bin/server.rb`:
  ```ruby
  require "cybertrain"
  require_relative "../config/app"
  require_relative "../gen/app"
  app = Cybertrain::Application.new(router: Gen::Routes.build(Cybertrain::Router.new), url_resolver: ->(name, args) { Gen::Routes.path_for(name, args) })
  app.run
  ```

- [ ] **Step 1: `test/application.rb`.** Config defaults per env (set `ENV` is read-only in Spinel? verify; otherwise construct Config and assign); `resolve_secret!` creates `tmp/secret_key` in test env and raises in production with empty secret; `Application#call` through the full stack with a hand-built Router: a GET renders, a POST without CSRF token is 403, a POST with the token (fetched via a GET route that returns `csrf_token`) passes; session cookie round trip through `Test::Client`; static file served from a temp public root.
- [ ] **Step 2: Implement; snapshot; `spin test` green.**

### Task 16: Development loop — watcher, rebuild, self-exec, dev error page

**Files:**
- Create: `cybertrain/dev.rb`, `cybertrain/dev/watcher.rb`, `cybertrain/dev/rebuilder.rb`, `cybertrain/dev/reexec.rb`, `cybertrain/dev/error_page.rb`
- Modify: `cybertrain/application.rb` (`run` installs the dev loop in development)
- Test: `test/dev_watcher.rb`, `test/dev_error_page.rb` (rebuild/exec are exercised manually and by `examples/blog` in Task 18)
- Reference: `spikes/07_process_control/08_full_loop_gen1.rb`, `09_full_loop_gen2.rb`

**Interfaces:**
- Produces:
  ```ruby
  class Cybertrain::Dev::Watcher
    def initialize(globs, interval = 0.5)   # Array<String> of Dir.glob patterns
    def snapshot                            # Hash<String, Integer> path -> mtime as Integer
    def changed?                            # compares with the previous snapshot, updates it, returns true when any path was added/removed/modified
    def start { |changed_paths| }           # spawns a Thread polling every interval; yields the changed paths
    def stop
  end
  class Cybertrain::Dev::Rebuilder
    def initialize(root, target = "server", log_path = "tmp/rebuild.log")
    def rebuild                             # system("spin run gen > log 2>&1 && spin build #{target} >> log 2>&1"); returns true/false; stores File.read(log) into last_output
    attr_reader :last_output, :last_failed
  end
  module Cybertrain::Dev::Reexec            # ffi_source shim sp_reexec(path, arg) as in the spike; def self.exec_self(binary_path, port) never returns on success
  class Cybertrain::Dev::ErrorPage < Cybertrain::Middleware
    def initialize(app, rebuilder = nil)    # rescues StandardError from the inner app -> 500 with an HTML page: exception class, message, request line, and for Cybertrain::Template::RuntimeError/SyntaxError the template name and line; when rebuilder.last_failed, prepends a red "Build failed" banner with rebuilder.last_output (escaped) to every response body of type text/html
  end
  class Cybertrain::Application
    def run   # development: wrap stack in Dev::ErrorPage; start Watcher over app/**/*.rb, config/**/*.rb, db/schema.rb, gen/**/*.rb; on change -> Rebuilder#rebuild; on success Process.kill("HUP", Process.pid); trap("HUP") { server.stop; Dev::Reexec.exec_self(File.expand_path($0), server.port.to_s) }; production: plain server.run. SIGTERM: server.stop then exit 0 in both.
  end
  ```

- [ ] **Step 1: tests.** Watcher: temp dir with two files, `changed?` false at first, true after touching one (write a new content), true after adding a file, false again afterwards. ErrorPage: an inner middleware raising `RuntimeError, "boom"` yields 500 HTML containing "RuntimeError" and "boom" escaped; a Template::RuntimeError message "posts/show.html.erb:12: undefined method" appears with the line; a rebuilder stub with `last_failed = true` injects the banner into a 200 HTML response and not into a JSON response.
- [ ] **Step 2: Implement; snapshots; `spin test` green. Then verify manually with `examples/blog` in Task 18 (edit a controller, see the rebuild + re-exec in the log, request the changed page).**

### Task 17: The `cybertrain` CLI — `new` and `generate scaffold`

**Files:**
- Create: `bin/cybertrain.rb`, `cybertrain/cli.rb`, `cybertrain/cli/new_app.rb`, `cybertrain/cli/scaffold.rb`, `cybertrain/cli/templates.rb`
- Test: `test/cli_new.rb`, `test/cli_scaffold.rb`

**Interfaces:**
- Produces:
  ```ruby
  module Cybertrain::CLI
    def self.run(argv)   # "new NAME [--path DIR|--version V]" | "generate scaffold NAME field:type ... [parent:references]" | "version" | "help"; returns exit code
  end
  module Cybertrain::CLI::NewApp
    def self.create(name, framework_dep)   # writes: spin.toml ([dependencies] cybertrain = { path = "<abs or rel path>" } or version), .gitignore (build/ storage/*.sqlite3* tmp/ log/), config/app.rb, config/routes.rb (`Cybertrain::Routes.draw do\nend`), db/schema.rb (`Cybertrain::Schema.define(version: "0") do |s|\nend`), db/migrate/.keep, app/controllers/application_controller.rb, app/models/.keep, app/views/layouts/application.html.erb (with csrf_meta_tags, flash rendering, yield), app/helpers/.keep, public/404.html, public/500.html, public/style.css (small stylesheet used by scaffold views), storage/.keep, tmp/.keep, gen/.keep, bin/server.rb, bin/gen.rb, bin/db.rb, test/.keep, README.md; prints "create <path>" per file
  end
  module Cybertrain::CLI::Scaffold
    def self.generate(root, name, fields)  # fields Array<"title:string">; writes db/migrate/<timestamp>_create_<plural>.rb (create_table with columns + references + timestamps), app/models/<name>.rb (validates presence for the first string field), app/controllers/<plural>_controller.rb (index show new edit create update destroy with before_action :set_<name>, strong params, redirects with notice, `status: :unprocessable_entity` on failure), app/views/<plural>/{index,show,new,edit,_form}.html.erb, and inserts `  resources :<plural>` after `Cybertrain::Routes.draw do` in config/routes.rb (idempotent); timestamp from Time.now.utc.strftime("%Y%m%d%H%M%S") unless ENV["CYBERTRAIN_TIMESTAMP"] is set (tests set it)
  end
  ```
  Distribution: `spin install` (in the framework repo) builds `bin/cybertrain.rb` and copies it to `~/.local/bin/cybertrain`; CI runs `spin build` to prove it compiles.

- [ ] **Step 1: tests.** `cli_new.rb`: create into a temp dir, assert the file list and that `config/routes.rb`/`bin/server.rb` contents match the plan. `cli_scaffold.rb`: on a fresh temp app run scaffold `post title:string body:text` and `comment commenter:string body:text post:references` with a fixed timestamp; assert the migration text, the controller text (exact), the route lines inserted once even when run twice, and the view files exist with the expected form fields.
- [ ] **Step 2: Implement; snapshots; `spin test` green.**

### Task 18: `examples/blog` — the acceptance app

**Files:**
- Create: `examples/blog/**` produced by `cybertrain new blog` + two scaffolds, then edited to match Rails' Getting Started: `Article` (title, body; validates title presence, body length minimum 10), `Comment` (commenter, body, article:references), nested `resources :articles do resources :comments, only: [:create, :destroy] end`, comments form and list on `articles/show.html.erb`, `root "articles#index"`.
- Test: `examples/blog/test/articles.rb`, `examples/blog/test/comments.rb` (integration through `Cybertrain::Test::Client` against the app's stack with a test database `storage/test.sqlite3` migrated in the test setup via `Cybertrain::DB::Migrator`).
- Modify: `.github/workflows/ci.yml` already runs `spin run gen`, the freshness diff, and `spin test` for the example.

- [ ] **Step 1: Generate the app with the CLI, `spin run gen`, `spin run db migrate`, `spin build`, run `build/bin/server` and exercise it with curl: index, new, create (with the CSRF token from the form), show, edit, update, destroy, comment create/destroy, validation failure re-renders the form with errors, flash notices appear after redirects, 404 for a missing article.**
- [ ] **Step 2: Write the two integration tests covering every flow in Step 1; commit `gen/` outputs.**
- [ ] **Step 3: Dev loop smoke: start with `CYBERTRAIN_ENV=development spin run server`, edit `app/views/articles/index.html.erb` (no rebuild) and `app/controllers/articles_controller.rb` (rebuild + re-exec), confirm both changes are served.**

### Task 19: Documentation

- [ ] Rewrite `README.md`: what cybertrain is, requirements, `spin install` for the CLI, `cybertrain new`, the blog walkthrough (Rails Getting Started mapped 1:1), the template language subset, the Spinel constraints that shape the API (`before_action :sym` via generated dispatch, callbacks with explicit receiver, no console, no reloading of Ruby without rebuild), deployment (binary + `app/views` + `public` + `storage`), and a "differences from Rails" table. Keep `docs/design.md` as the design record; add `docs/template-language.md` (the grammar from design.md section 7 in English with examples).
