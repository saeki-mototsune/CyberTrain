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
