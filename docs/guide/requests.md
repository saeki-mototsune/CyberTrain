# Requests

What a controller gets from a request and what the framework checks before
it runs: the routes and their formats, `respond_to`, concerns and
`helper_method`, strong parameters, downloads and HTTP caching, cookies and
the encrypted session, rate limiting and the client address behind a proxy,
the Content Security Policy, `force_ssl` and host checks, the parameterised
headers, and how query strings and request bodies are parsed and bounded.

## Routing

`config/routes.rb` uses Rails' routing DSL; `spin run gen` evaluates it and
writes `gen/routes.rb` (the route table, the dispatcher and the `*_path` /
`*_url` helpers). At the top level a call needs no receiver; a nested block
names the receiver it is given, because Spinel evaluates only the top level
of `Routes.draw` without one:

```ruby
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  namespace :admin do |admin|
    admin.resources :articles, only: [:index, :destroy]
    admin.jobs_page "/jobs", before_action: :require_admin
  end
end
```

`namespace :admin` prefixes the paths with `/admin` and the helpers with
`admin_` (`admin_articles_path`, `admin_article_path(article)`), and its
controllers are `Admin::ArticlesController` in
`app/controllers/admin/articles_controller.rb`, with their views in
`app/views/admin/articles/`. Namespaces nest. A namespaced controller may be
written as nesting (`module Admin` / `class ArticlesController <
ApplicationController`) or in the compact form (`class
Admin::ArticlesController`, once `module Admin` exists); the scan reads
both. `jobs_page` inside a namespace takes its prefix.

`scope` changes one part at a time, and the three combine as in Rails:

```ruby
scope "/dashboard" do |s|          # the path prefix only
  s.get "/stats", to: "stats#show"
end
scope module: "billing" do |s|     # the controller module only: Billing::InvoicesController
  s.resources :invoices
end
scope "/v1", as: "v1" do |v|       # the path and the helper prefix: v1_about_path
  v.get "/about", to: "pages#about"
end
```

`namespace` and `scope` must be used outside `resources` blocks (gen
refuses them inside one).

### Singular resources, `controller:` and `param:`

`resource` (singular) takes a block and `controller:`, as `resources` does.
The block adds member routes and nested resources, with Rails' paths and
names:

```ruby
resource :profile, controller: "pages", only: [:show] do |r|
  r.get :refresh, on: :member       # GET /profile/refresh, refresh_profile_path
end
resources :indicators, param: :key  # /indicators/:key, params[:key]
```

`on: :member` and `on: :collection` place a custom route as the `member`
and `collection` blocks do; a singular resource has no collection.
`param: :key` names the member segment (`params[:key]`), and nested
resources under it use `:indicator_key`; `indicator_path(ind)` still reads
`ind.to_param`, which the model overrides to return the key. A custom
route's `:id` and `:x_id` segments keep their earlier helper argument names
(`get "/users/:id"` gives `user_path(user)`).

### Redirects and query strings

`get "/old", to: redirect("/new")` answers 301 (`redirect("/new", status:
302)` for another code); `%{name}` in the target is the segment's value,
escaped: `get "/old-posts/:id", to: redirect("/posts/%{id}")`. A redirect
route has no helper unless it says `as:`. The block form of `redirect` is
not supported; a controller action computes a target.

Keyword arguments of a path helper go to the query string, in the order
given and escaped: `article_path(a, page: 2)` is `/articles/3?page=2`, a nil
value leaves its key out, an Array gives `key[]=v` per item and a Hash value
raises `ArgumentError`. `format: :json` adds the extension
(`/articles/3.json`) and `anchor: "c4"` the fragment (`#c4`, last).
Keywords never fill a path segment: segments are positional arguments
(`post_path(3)`, not `post_path(id: 3)`). `url_for("/x", format: :csv)`
appends the same options to a String.

## Formats and `respond_to`

Every route matches an optional extension on its last segment:
`/articles/3.json` gives `params[:id] == "3"` and `request.format == :json`.
In a route that takes a format a dynamic segment never captures a `.`
(Rails' default), so `/articles/3.json.bak` is a 404. A route whose segment
holds a dot for its own reason says `format: false` (on `get` and the other
verbs, `resources`, `resource` and `root`):

```ruby
get "/files/:name", to: "files#show", format: false   # /files/report.v2 is name "report.v2"
```

`request.format` is a Symbol: the extension's, from Rails' registered
types (`:html`, `:json`, `:csv`, `:xml`, `:pdf`, `:turbo_stream`, ...;
`jpg` is `:jpeg`, `htm` `:html`, `txt` `:text`), and `:unknown` for any
other extension. Without an extension it comes from `Accept`:
`:turbo_stream` when it lists `text/vnd.turbo-stream.html`, `:json` when it
lists `application/json` and not `text/html` before it, `:html` otherwise
(a type with `q=0` is left out).

```ruby
def show
  @article = Article.find(params[:id])
  respond_to do |format|
    format.html
    format.json { render json: @article.as_json }
    format.turbo_stream
  end
end
```

The collector (`Cybertrain::FormatCollector`) has `html`, `json`,
`turbo_stream`, `csv`, `xml`, `text` and `any`. The first declaration that
matches runs its block at once, so the block sees the action's instance
variables; one without a block renders the action's template for that
format (`show.html.erb` in the layout, `show.turbo_stream.erb` without
one). When none matches the answer is `406 Not Acceptable`. `any` matches
any format but `:unknown`. Turbo submits a form asking for
`text/vnd.turbo-stream.html, text/html`: such a request has the format
`:turbo_stream`, and an action without `format.turbo_stream` answers
through its `format.html`, as in Rails (a `.turbo_stream` extension asks for
that format only). The same fallback covers any `Accept` that lists
`text/html` or `*/*` next to a non-html format, so a client that sends
`application/json, text/plain, */*` to an action with only an html
template gets the html and not a 406. The fallback runs the block a second
time, for html, so a statement in it other than the `format.` lines runs
twice: keep the block to the `format.` lines. An entry with `q=0` refuses
its type: `application/json, text/html;q=0` gets no html, with or without
`*/*` beside it.

A response whose format came from `Accept` (no extension, an `Accept`
header sent) carries `Vary: Accept`, merged into a `Vary` the action set,
so a browser or cache never hands the html of a URL to a request for its
JSON or Turbo Stream; a path with an extension gets none.

Without `respond_to`, an action renders `<action>.<format>.erb` when it
exists (`create.turbo_stream.erb`, no layout, the format's content type)
and answers 406 when it does not; html is as before. JSON has no templates:
an action answers JSON with `render json:`. Inside a block, `render :edit`
renders the template of the format that block matched (`edit.turbo_stream.erb`
in `format.turbo_stream`).

A controller builds Turbo Stream answers with `turbo_stream` (turbo-rails'
builder: `replace`, `update`, `append`, `prepend`, `before`, `after`, each
a target and one of `partial:` with `locals:` or `html:`, and `remove`):

```ruby
render turbo_stream: [turbo_stream.remove(@comment), turbo_stream.update("count", html: @count.to_s)]
```

## Concerns and `helper_method`

A controller concern is a module in `app/controllers/concerns/`, as in
Rails:

```ruby app/controllers/concerns/admin_gate.rb
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 20
  end
end
```

A controller that writes `include AdminGate` gets what the `included`
block declares (`before_action`, `skip_before_action`, `after_action`,
`helper_method`, `rate_limit`, `rescue_from`, `layout`), at the place of the
`include` and in the order written, and `self.class.per_page` works in its
actions. Concerns may include concerns: gen expands them depth first, each
once, and refuses a cycle by name (`concern cycle: A includes B includes
A`). `include A, B` includes B first, as Ruby does, so B's `included` block
and callbacks come before A's. `around_action` is refused (there are no around callbacks). The
`@x =` assignments in a concern's methods are the controller's view
variables.

Spinel compiles the never-run `included` and `class_methods` blocks, so
gen expands them itself instead: it writes each concern to
`gen/concerns/<path under app/>` with the two blocks blanked (the
application's files load those copies), and `gen/concerns.rb` reopens every
including class with the spliced declarations and a forwarder per
`class_methods` method. Two rules follow. A `class_methods` method may not
share its name with an instance method of the concern, of an including
class or of its ancestors (Spinel would define both as instance methods,
spikes/NOTES.md rule 93); gen refuses it, naming both places (`file:line`
of the instance method). And an `include` of a module that is not a concern
(`include Comparable`, a name with no file under `app/*/concerns`) is left
to Ruby as it is, so a misspelt concern name is a `NameError` when the
application loads, not a gen message. gen looks a name up as Ruby does, the
class's own modules first, so `include Gate` inside `module Admin` brings in
`Admin::Gate`. A name that reaches no concern but ends in a concern's name
(`include Gate` where only `Admin::Gate` exists) stops gen: Ruby would
include some other module or raise, and the concern's `included` block
would be lost.

Model concerns live in `app/models/concerns/` and work the same way: their
`included` block may hold any of the model's class-level declarations
(`validates`, `validate`, `scope`, `belongs_to`, `has_many`, `has_one`,
`encrypts`, callbacks, `normalizes`), treated as written in the model at
the `include`. A concern's callbacks run after the model's own of the same
kind, and an `include` inside a model concern's `included` block brings that
concern in. A model concern's `class_methods` name may not be a scope of
the model or a class method every model has (`recent` beside `scope :recent`,
`where`); gen refuses it.

`helper_method :current_user, :admin?` in a controller, or in a concern's
`included` block, makes those controller methods callable from that
controller's templates, and from the components and partials they render,
with their arguments. gen refuses a name that is a framework helper, ends
in `_path` or `_url`, is defined by a module in `app/helpers`, has no `def`
in the controller, its parents or its concerns, or whose parameters a
template cannot pass (`*rest`, `**opts`, `...`).

## Parameters: `params.expect` and nested `permit`

```ruby
def article_params
  params.expect(article: [:title, :body, tags: [], meta: [:source]])
end
# => {"title" => "Hi", "body" => "...", "tags" => ["a", "b"], "meta" => {"source" => "rss"}}
```

`permit` takes the same forms: a key permits a String, `key: []` a list of
Strings and `key: [...]` a nested level. A filter that is not an Array
(`permit(meta: :source)`, `expect(article: :title)`) or that holds an Array
(`[[:title]]`) raises `ArgumentError`: it is a mistake in the code, not a
bad request, so it is not a 400. A value of the wrong kind, an
unlisted key and an upload are dropped. `expect` returns the level under
its one key, and raises `Params::ParameterMissing` (answered 400) when that
key is absent, of the wrong kind, or permits nothing. `params.expect(:id)`
reads one String and answers `{"id" => "3"}`; `params.expect(tags: [])`
answers a non-empty list the same way. Both return `Hash{String =>
Object}`: values are Strings, Arrays of Strings or nested Hashes, so
narrow a value with `Cybertrain::Cast.str` (or `.to_s`) before calling
String methods on it.

## Downloads, HTTP caching and status codes

`send_data(bytes, filename: "report.csv", type: "text/csv", disposition:
"attachment")` answers with the bytes and a `Content-Disposition` that
carries the name both quoted and as RFC 5987's `filename*`, so accents and
quotes survive; `disposition: "inline"` shows it in the browser. It sends
the bytes under the `type` given, so it is for data the application made;
an upload a user sent goes through `send_blob`, which never lets a browser
run it.

```ruby
def show
  @post = Post.find(params[:id])
  fresh_when etag: @post, last_modified: @post.updated_at
end

def feed
  @posts = Post.order(created_at: :desc).limit(20).to_a
  return unless stale?(etag: @posts.first)
  expires_in 300, public: true
end
```

`fresh_when` sets a weak `ETag` (from a String, or a record's table,
`to_param` and `updated_at`) and `Last-Modified`, and answers `304 Not
Modified` when the request's `If-None-Match` (or, without it,
`If-Modified-Since`) shows the client has the current version; `stale?`
does the same and returns whether the action should render. Only GET and
HEAD get a 304. `Cache-Control` is `max-age=0, private, must-revalidate`
(`public` with `public: true`) unless `expires_in seconds` set
`max-age=<seconds>` first. There is no automatic ETag on other responses.
`If-None-Match: *` matches whatever the action validated, an `ETag` or
only a `Last-Modified`.

The ETag is made from the key you give, the request's format and a digest
of the build (the asset digests and import map, and the views in a
`cybertrain build` binary), so the html and the JSON of one URL never share
one, and a deploy that changes the assets or the views revalidates every
client. Two consequences. In development, without `--embed-views`, the
templates are read from disk and are not in the digest: a view edit can
still get a `304` until a record changes or the page is reloaded without
its cached copy. And the key names what the page shows, not who sees it:
content that differs per user needs the user in the key (`etag:
"posts/#{@post.id}-#{@post.updated_at.to_i}-#{current_user.id}"`), or it
is shown to the wrong person. Do not make a page `public` when it carries a
CSP nonce (`content_security_policy` with nonces, `javascript_importmap_tags`):
a shared cache gives every visitor the same page, and so the same nonce,
which then protects nothing.

`status:` and `head` take every Rack symbol (`:unauthorized`,
`:payment_required`, `:unprocessable_content`, `:too_many_requests`, ...,
with the old `:unprocessable_entity` and `:payload_too_large` as aliases),
and the reason phrases are RFC 9110's (413 "Content Too Large", 422
"Unprocessable Content").

## Cookies and the session

```ruby
cookies[:theme] = "dark"
cookies[:theme] = { value: "dark", expires: Time.now + 86_400, same_site: "Strict" }
cookies.permanent[:locale] = "ja"
cookies.signed[:user_id] = "5"     # readable by the client, not changeable
cookies.encrypted[:card] = "4242"  # neither readable nor changeable
cookies.signed[:user_id]           # => "5", or nil when it was changed
cookies.delete(:theme)
```

A write takes a String, or a Hash with `value:`, `expires:` (a Time),
`max_age:`, `path:`, `httponly:`, `secure:` and `same_site:`. Cookies are
written `Path=/`, `HttpOnly` and `SameSite=Lax`, and `Secure` when the
session cookie is (in production, or with `force_ssl`), unless the write
says otherwise. `permanent` writes a 20-year `Max-Age`. A signed value is
HMAC-SHA256 under a key derived from `secret_key_base`; an encrypted one is
AES-256-GCM under another; each is bound to its cookie's name, so it does
not verify or open under another name, and one that was changed reads nil.
A value read after a write in the same request is the written one.

The session cookie is encrypted and authenticated with AES-256-GCM, as
Rails' cookie store, under its own key derived from `secret_key_base`: the
client can neither read nor change it. A cookie that does not decrypt (a
changed, foreign or older signed one) loads as an empty session, and so
does one over 4096 bytes; a session whose cookie would pass 4096 bytes, or a
jar cookie whose `name=value` does, raises `Session::CookieOverflow` when it
is written. Values stay Strings.
Rotating `secret_key_base` signs everyone out, as before.

## Rate limiting and the client address

`rate_limit` in a controller caps how often one client may call some
actions, counted before the action runs. It needs
`require "cybertrain/rate_limit"` (which loads the cache) in
`bin/<app>.rb` and `bin/db.rb`; `cybertrain generate authentication` adds
it:

```ruby
class SessionsController < ApplicationController
  # a 303 back to the form, with flash[:alert], once exhausted
  rate_limit to: 10, within: 3 * 60, only: [:create],
             redirect_to: "/session/new", alert: "Try again later."
end

class ApiKeysController < ApplicationController
  rate_limit to: 100, within: 60, only: [:create, :update]   # 429 Too Many Requests + Retry-After
  rate_limit to: 5, within: 60, only: [:create], by: :account_key, with: :slow_down, name: "account"
end
```

Each declaration counts at most `to` requests per window of `within`
seconds for each client and controller, then answers 429 with a
`Retry-After` header (the seconds left in the window), or redirects when
given `redirect_to:`. The other options name controller methods: `by:` the
key (`:client_ip` by default, `:remote_addr` for the connection's peer, or
a method such as `account_key`, whose nil or `""` raises rather than count
every client together), `with:` what to answer instead (when it renders
nothing, the 429 follows), `if:` / `unless:` when the limit applies (a
skipped request is not counted). A controller with two limits gives each
its own `name:` (gen refuses a second limit with the same name in one
controller, its parents' included, and a name holding `:`). `within:` is in
seconds and `only:`/`except:` take Arrays.

The counts live in `Cybertrain::Cache`, in the application's database, so
every process serving the app counts together and the counts survive a
restart; the windows are fixed and aligned to the clock (`now / within`).
`store: :memory` keeps the old per-process counter: each process counts on
its own, in a table of at most 10,000 keys (when it is full, expired
windows and then the oldest ones make room), lost on restart, with a
window that opens with a key's first request and a lock taken by every
request to a limited action (name the actions with `only:`). In a test,
`Cybertrain::RateLimit.reset_all!` forgets every count (the memory tables
and the cache's rate-limit rows); `Cybertrain::Cache.clock = -> { n }`
fixes the cache store's clock, and `Cybertrain::RateLimit.current_time = n`
the memory store's (`-1` restores it).

### The client address behind a proxy

The address counted is `request.client_ip` (`by: :remote_addr` counts the
connection's peer instead). It is `request.remote_addr` unless
`config.trusted_proxy` is on (`CYBERTRAIN_TRUSTED_PROXY=1`) **and** the
connection comes from loopback, that is, from a reverse proxy on the same
host (nginx, Caddy, kamal-proxy); then it is the last address in
`X-Forwarded-For`, the one the proxy appended. Earlier entries are whatever
the client sent and are never used, and a last entry that is empty, longer
than 45 bytes or not printable ASCII gives `remote_addr`. Without the
setting, every visitor behind such a proxy shares its address, and ten bad
passwords lock everyone out; with it, a client connecting directly from
elsewhere still cannot choose its own address. `request.loopback?` tells
whether the connection comes from this machine (127.0.0.0/8, `::1`,
`::ffff:127.x.x.x`), for pages only an operator on the server should
reach; behind a proxy on the same host every request is loopback, so check
`client_ip` too there. Design: [docs/design.md](../design.md) D26.

A proxy that reaches the app over a network, not loopback, is listed by
address instead: `config.trusted_proxies`, from `CYBERTRAIN_TRUSTED_PROXIES`,
takes comma-separated IPv4 or IPv6 addresses or CIDRs
(`CYBERTRAIN_TRUSTED_PROXIES=172.16.0.0/12,10.0.0.0/8`, or a single
`172.18.0.2`). A connection from inside one of them gets the same treatment
as a loopback one above: the last `X-Forwarded-For` address, validated the
same way. An IPv4 entry also matches the IPv4-mapped form of its addresses
(`::ffff:172.18.0.2`), and a peer's `%zone` is ignored. An entry that is not
an address or CIDR, or has a prefix past `/32` (IPv4) or `/128` (IPv6),
stops the server at boot. `CYBERTRAIN_TRUSTED_PROXY=1` is the shorthand for
`127.0.0.0/8,::1`, and the two add up.

This is the Kamal case: kamal-proxy runs in its own Docker container and connects from its address on the Docker
network, so the `config/deploy.yml` that `cybertrain new` writes sets
`CYBERTRAIN_TRUSTED_PROXIES: 172.16.0.0/12` (Docker's default range; change
it if your networks use another, `docker network inspect kamal`). Leave
Kamal's `proxy.forward_headers` unset: with `ssl: true`, kamal-proxy sets
`X-Forwarded-For` itself rather than passing on the client's. List only
networks that clients cannot connect from: anyone inside a listed network
can choose the address a rate limit counts.

## Content Security Policy, `force_ssl` and hosts

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
    p.style_src :self
    p.img_src :self, :data
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
end
```

The policy is off until `config/app.rb` declares one, as in Rails. Then
every response carries `Content-Security-Policy`
(`Content-Security-Policy-Report-Only` with
`c.content_security_policy_report_only = true`), with a fresh nonce per
request in the nonce directives; a 304 carries none, so a cached page keeps
the nonce its scripts were written with. `csp_meta_tag`,
`javascript_tag(nonce: true)`, `javascript_importmap_tags` and
`stylesheet_link_tag(nonce: true)` write that nonce
([The template language](template-language.md#helpers-and-the-form-builder)).
Symbols are the keywords and schemes (`:self` is `'self'`, `:data` is
`data:`); a String source holding a space, `;`, `,` or a control
character is refused when it is declared. A controller adjusts a copy for
its actions, and its subclasses inherit it:

```ruby
class EmbedController < ApplicationController
  content_security_policy do |p|
    p.frame_ancestors "https://partner.example"
  end
end
```

Every response also carries `Permissions-Policy: camera=(),
microphone=(), geolocation=()` unless it sets its own;
`c.permissions_policy` replaces the value, `""` sends none.

`CYBERTRAIN_FORCE_SSL=1` (`config.force_ssl`) redirects http to https,
301 for GET and HEAD and 307 for the rest, and adds
`Strict-Transport-Security: max-age=63072000; includeSubDomains` to https
responses. Behind a TLS-terminating proxy a request is https when it says
`X-Forwarded-Proto: https`, a header read whatever `trusted_proxy` says (a
client that forges it only skips its own redirect). `request.base_url`
believes it only from a trusted proxy, so set `CYBERTRAIN_TRUSTED_PROXY` or
`CYBERTRAIN_TRUSTED_PROXIES` too, or the URLs the app builds stay http.
The redirect takes its host from a well-formed `Host` (a malformed one is a
400), and an http GET or HEAD of the health path is never redirected. With
`force_ssl` on, the session and the cookie jar write `Secure` cookies.

Host checks extend the development guard: `CYBERTRAIN_HOSTS`
(comma-separated host names, no scheme, port or wildcard) is appended to
`allowed_hosts`, after the loopback names, in every environment.
Development checks as before; production and test check only when
`CYBERTRAIN_HOSTS` is set. A refused `Host` answers 403 `Blocked host` and
is logged; a GET or HEAD of the health path passes whatever the Host, so a
load balancer probing by address still reaches the health check.

## Parameterised headers

API clients often send `Scheme k1=v1, k2="v2"` headers (`Authorization:
Digest ...`, a vendor `X-Example-Auth`) or `k1=v1;k2=v2, k3` lists
(`Forwarded`, `Prefer`). `request.header_params(name)` parses one into a
`Hash` of lowercase names to values, so an API controller does not split it
by hand:

```ruby
# Authorization: Digest username="Mufasa", realm="api@example.com", nc=00000001, qop=auth
auth = request.header_params("authorization")
auth["username"]                         # => "Mufasa"
request.header_scheme("authorization")   # => "Digest"

# Forwarded: for=192.0.2.60;proto=https;by=203.0.113.43
request.header_params("forwarded")["proto"]   # => "https"

# Prefer: respond-async, wait=5
request.header_params("prefer").key?("respond-async")   # => true
```

`,` and `;` both separate parameters and the first occurrence of a name
wins; a quoted value is unquoted (`\"` and `\\` undone), an unquoted one
has the spaces around it trimmed, and a name without `=` maps to `""`. A
leading scheme word (`Digest`, `Bearer`) is not a parameter:
`request.header_scheme(name)` returns it (`""` when there is none). A header
that is missing or longer than 8 KiB gives `{}`. Values are the bytes as sent,
never percent-decoded and possibly not valid UTF-8. A `Bearer <token>` or
`Basic <base64>` credential is not a parameter: check the scheme, then read
the credential from `request.header("authorization")`. Design:
[docs/design.md](../design.md) D31.

## Query strings and bodies

`Query.parse`, `Query.value_of`, `Query.decode` and `request.form_value` /
`query_value` raise `Cybertrain::QueryMalformed` (a `StandardError` under
`Cybertrain::QueryInvalid`, not an `ArgumentError`), answered 400, on:

- a malformed percent-escape, on both runtimes;
- an invalid UTF-8 byte sequence, raw (whatever the String's tag) or
  percent-encoded (Rails likewise answers 400 for an invalid parameter
  encoding);
- a raw byte that only an escape would complete (`a=\xC3%A9`).

`Cookies.parse` keeps such a value raw instead. A path with an invalid
sequence (raw, or percent-decoded in a segment) is a 400 as well
(`request.path_segments`); a malformed escape in a path stays literal, a 404
by non-match. Request parameters nest at most 32 levels and 4096 pairs, and
are a 400 past that. Upgrade note: app code that rescued `ArgumentError`
around these calls should rescue `Cybertrain::QueryInvalid` instead.

The request keeps no parameter tree of its own (the Router builds `params`,
the middleware read one key); an app that wants the whole tree parses it
itself, `Query.parse(request.utf8_query_string)`, and owns the result.

Rack leaves a gzip request body as it is. Here a body sent with
`Content-Encoding: gzip` (an SDK or API client past a few kilobytes) is
`request.decoded_body`, inflated once through the system zlib under a ceiling
on the output: 10 MiB by default, and an endpoint that expects more passes
its own, `request.decoded_body(limit)`. A corrupt body or an encoding other
than gzip/identity is `Cybertrain::BodyUndecodable`, one that would inflate
past the limit `Cybertrain::BodyTooLarge`, both `QueryInvalid`s answered 400.
`request.body` stays the bytes as sent.

## Upgrading an application from 0.4

What changes for an application written for 0.4 (the full list is section
14 of [the design](../superpowers/specs/2026-11-10-phase4-web-layer-design.md)):

- Every session ends once: the encrypted cookie does not read the old
  signed one, so users sign in again. Code that calls `Session.load` or
  `Session.dump` passes the derived key, `Crypto.derive_key(secret,
  SessionStore::SESSION_KEY_LABEL)`; the raw secret raises
  `Encryptor::Error`.
- Every application links OpenSSL ([Installing](install.md#requirements));
  a Dockerfile `cybertrain new` wrote earlier needs `libssl-dev` in its
  build stage and `libssl3t64` in its runtime stage.
- A dynamic segment no longer captures a `.` in a route that takes a
  format: an id with dots needs `format: false` on its route.
- A hand-written `url_resolver` lambda takes three arguments, `->(name,
  args, options)`; one that passes `Gen::Routes.url_resolver` needs only
  `spin run gen`.
- `params.permit` returns `Hash{String => Object}`: call `Cast.str` or
  `.to_s` on a value before using it as a String.
- `rate_limit` counts in the cache: `store: :memory` keeps the old
  per-process counter, two limits in one controller need their own
  `name:`, a `by:` method answering nil or `""` raises, and a `with:`
  method that renders nothing is followed by the 429.
- The number helpers raise for a value that is not a number (nil renders
  `""` in a template, as before), and for a precision outside 0 to 100.
- `include A, B` in a controller or model includes B first, as Ruby does; an
  `include` of a module that is not a concern is left to Ruby.
- Every ETag changes once (it now holds the request's format and a build
  digest), a response negotiated by `Accept` sends `Vary: Accept`, and the
  html fallback covers any `Accept` that lists `text/html` or `*/*`. A
  request that may fall back to html (`application/json, text/html`) has
  an ETag of its own, apart from the one of a request for that format
  alone; `text/html;q=0` in `Accept` gets no html fallback (406 where the
  action has only html), also beside `*/*`; and `If-None-Match: *` gets a
  304 from a response validated by `last_modified:` alone.
- `permit` and `expect` raise `ArgumentError` for a filter that is not an
  Array; a `layout` that names a missing layout raises `MissingTemplate`
  (the default `application` layout stays optional); a jar cookie over 4096
  bytes raises `Session::CookieOverflow`.
- `public/style.css` keeps working; moving it to `app/assets/stylesheets/`
  is optional ([Assets](assets.md#moving-publicstylecss)).
- Validation messages come from the bundled dictionary
  ([Internationalization](i18n.md#models-and-validation-messages)), with
  the same English text except three: a message on `:base` is no longer
  prefixed "Base", an attribute ending in `_id` is named without "id"
  ("Article can't be blank", not "Article id can't be blank"), and a
  length limit of 1 reads "1 character". Tests that compare these
  messages change.
- `time_tag` without `format:`, or with a format name, formats through
  `I18n.l` (the same English text as before in an English page).
- gen writes `gen/locales.rb` (empty without `config/locales/`) and loads
  `app/mailers/**/*.rb`; `cybertrain new` writes `config/locales/en.yml`,
  which an older application can add.
- `allow_unauthenticated_access` is a framework method now; the one 0.4's
  generator wrote into `ApplicationController` keeps working and takes
  precedence. Running `cybertrain generate authentication` again adds
  password reset, lockout, remember me, the account page and admin users,
  and prints diffs for the files 0.4 wrote
  ([Upgrading from 0.4](authentication.md#upgrading-from-04)).
