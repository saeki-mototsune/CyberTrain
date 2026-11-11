# Phase 4 of the Rails-gap programme: the web layer

Date: 2026-11-10. Status: agreed with the maintainer (twelve questions and
one follow-up, 2026-11-10); the plans follow, one per part.

## 0. Context and scope

The programme (docs/design.md D1, revised 2026-11-05) delivers the 120 items
of the fin_dash survey in five phases. Phase 1 landed on 2026-11-05 (D36 to
D41), phase 2 on 2026-11-07 (D42 to D50), phase 3 on 2026-11-10 (D51 to
D57). This document is **phase 4**: the programme paragraph names
"`namespace`, `resource` blocks, formats, assets (digests, importmap), forms,
number formatting, i18n, authentication extras". The survey's chapters 5
(views), 6 (routing and controllers), 7 (assets) and 14 (authentication)
hold these; chapter 8's M-6 (model concerns) joins them because it shares
the controller concerns' mechanism.

Phase 4 is one design and **two plans and two pull requests**:

- **4a, the web layer proper:** routing (R-1 to R-5, R-7), formats and
  `respond_to` (R-4), concerns and `helper_method` (C-10, V-5, M-6), the
  controller additions (C-1 to C-5, C-7 to C-9, C-11), the view additions
  (V-6, V-7, V-9, V-10, V-11, V-13) and assets (A-1, A-2, A-5).
- **4b, i18n and authentication:** translations (V-8, AU-7) and the
  authentication generator's additions (AU-2 to AU-6). 4b comes second
  because its screens use 4a's forms and every string goes through `t()`.

**Out** (section 13): bcrypt verification (AU-1: an application that brings
bcrypt hashes migrates them itself), `mount` (R-6: the phase 3 jobs page
replaces Mission Control), shipping Turbo / Stimulus / chart libraries
(A-3, A-4: files in `vendor/javascript` or a CDN pin), HTTP/2 and
compression (A-6: the reverse proxy), the PWA files (A-7: static files),
jbuilder (V-12: `method_missing`), time zone conversion in templates
(V-14), `allow_browser` (C-6).

The criteria of phases 2 and 3 decide every judgement call here as well, in
this order: **closer to Rails** (vocabulary, defaults, file layout, what a
Rails developer types) and **easier to understand**. Compatibility with
applications on 0.4 carries low weight (section 14 lists each break).

Where Spinel forbids the Rails mechanism, the Rails vocabulary is kept and
the mechanism is the framework's own: build-time generation from a lexical
scan into `case` tables (D4, D8, D38), never a computed `send` or a
`constantize` (spikes/NOTES.md rule 1), never a block stored on an object
and run through a base-class receiver (rule 88), one return type per method
name across the program (rules 10, 34, 41).

## 1. The decisions in one table

| # | Question | Decision |
| --- | --- | --- |
| Q1 | Split | One design, two plans and PRs: 4a (routing, controllers, views, assets, concerns) then 4b (i18n, authentication) |
| Q2 | Assets | Digests at build time (`spin run gen`), Rails 8's layout (`app/assets`, `app/javascript`, `vendor/javascript`, `config/importmap.rb`), a generated manifest, `/assets/*` served a year `immutable` |
| Q3 | Formats | Every route takes an optional `(.:format)`; the format comes from the extension, else `Accept` (Turbo Stream and JSON only), else html; `respond_to`; `*.turbo_stream.erb`; 406 for an unhandled format |
| Q4 | Routing | `namespace`, `scope` (path, `module:`, `as:`), `resource` blocks and `controller:`, `param:`, `redirect("/x/%{id}")`, query strings from path helpers; Rails' names throughout |
| Q5 | Concerns | `app/controllers/concerns` with `extend ActiveSupport::Concern`, `included do`, `class_methods do`, expanded lexically into the including controller; `helper_method` registers controller methods as template helpers |
| Q6 | Controllers | `params.expect`, `send_data`, `fresh_when` / `stale?` / `expires_in`, `rate_limit` options and a shared store, CSP with nonces, a cookie jar, an encrypted session cookie, every status symbol, `force_ssl`, host checks, `Permissions-Policy` |
| Q7 | Views | `Cybertrain::NumberHelper`, the form builder's `select` family and radio buttons, per-controller layouts, Turbo frame and stream helpers, `time_tag` / `image_tag` / `current_page?`, partial collections |
| Q8 | i18n | `config/locales/*.yml` read by gen (a YAML subset) into `gen/locales.rb`; `t`, `l`, lazy lookup, `count:` plurals for en / fr / ru / ja / zh; English and Japanese bundled |
| Q9 | bcrypt | Out: applications with bcrypt hashes migrate them themselves |
| Q10 | Authentication | Generated into the application (as Rails 8 does): password reset, optional confirmation (`--confirmable`), lockout, account pages, remember me, an admin flag with `require_admin` |
| Q11 | Model concerns | In 4a, with the controller concerns' mechanism |
| Q12 | Acceptance | The blog uses each feature (section 15); tests, guides with translations, design.md and section 18 updated |
| Q13 | Session encryption | On by default; every application links OpenSSL; the key is derived from `secret_key_base` |

# Part 4a

## 2. Routing (R-1 to R-3, R-5, R-7)

All of it is in the routes DSL (`cybertrain/generator/routes_dsl.rb`),
evaluated by gen; the router itself only gains the format (section 3).

### 2.1 `namespace`

```ruby
namespace :admin do |admin|
  admin.resources :articles, only: [:index, :destroy]
  admin.jobs_page "/jobs", before_action: :require_admin
end
```

- Paths are prefixed with `/admin`; helpers with `admin_` (`admin_articles_path`,
  `admin_article_path(a)`); the controller is `Admin::ArticlesController` in
  `app/controllers/admin/articles_controller.rb`; its views are in
  `app/views/admin/articles/`.
- Namespaces nest (`namespace :admin do namespace :reports do`).
- A controller may be written `module Admin; class ArticlesController <
  ApplicationController` or `class Admin::ArticlesController <
  ApplicationController`; the scan accepts both. If Spinel refuses the
  compact form (spike item 2), gen refuses it with a message that names the
  nested form.
- `jobs_page` inside a namespace takes the namespace's prefix.

### 2.2 `scope`

- `scope "dashboard" do ... end`: the path prefix only; controllers and
  helper names are unchanged.
- `scope module: "admin" do ... end`: the controller module only.
- `scope as: "admin" do ... end`: the helper prefix only.
- The three combine (`scope "/x", module: "y", as: "z"`), as in Rails.

### 2.3 Singular `resource` with a block and `controller:`

```ruby
resource :session, controller: "auth/sessions" do |session|
  session.get :refresh, on: :member
  session.resource :settings, only: [:edit, :update]
end
```

`resource` takes `controller:` and a block, like `resources`. A block adds
member routes (`get :refresh`) and nested singular or plural resources;
nested paths and helper names follow Rails (`/session/settings/edit`,
`edit_session_settings_path`). `resources` gains `controller:` too.

### 2.4 `param:`

`resources :indicators, param: :key` gives `/indicators/:key`, `params[:key]`
and helper calls that take the key: `indicator_path(ind)` reads
`ind.to_param` as today, and `to_param` is what an application overrides
to return the key. Nested resources under it use `:indicator_key`.

### 2.5 Redirect routes

`get "/old", to: redirect("/new")` answers 301 (`redirect("/new", status:
302)` for another code). `%{name}` in the target is replaced by the
segment's value, escaped: `get "/posts/:id/show", to:
redirect("/posts/%{id}")`. The block form that computes the target is out
(it would be a stored block run per request, rule 88); a controller action
does that.

### 2.6 Query strings from path helpers (R-7)

Keyword arguments a route's pattern does not use go to the query string, in
the order given, escaped: `decision_path(horizon: "1d")` →
`/decision?horizon=1d`; `article_path(a, page: 2)` → `/articles/3?page=2`.
`format:` is special (section 3). `anchor:` adds `#...`. Values are
`to_s`'d; nil omits the key.

## 3. Formats and `respond_to` (R-4)

- **Routes.** Every route matches an optional extension on its last segment:
  `/articles/3.json` gives `id = "3"`, `format = "json"`. A segment that
  holds a dot for its own reason (`/files/report.v2`) keeps working only
  when the route opts out with `format: false`; the default follows Rails.
  `resources ..., format: false` and `get ..., format: false` are accepted.
- **The request's format.** `request.format` is a Symbol: the extension if
  there is one, else `:turbo_stream` when `Accept` contains
  `text/vnd.turbo-stream.html`, `:json` when it contains
  `application/json` (and not `text/html` first), else `:html`. Only these
  three are recognised from `Accept`; any extension is accepted and
  reported as its Symbol (`:csv`, `:xml`) for `respond_to` to match.
- **`respond_to`.**

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

  `format.html` / `format.turbo_stream` without a block render the
  action's template for that format; with a block, the block runs. A
  format the action does not list answers `406 Not Acceptable`. The
  collector is a generated, per-action object (spike item 1 decides between
  storing the blocks and a `case` the generator writes); it never stores a
  block on a base-class receiver.
- **Implicit rendering by format.** With no `respond_to`, an action renders
  `<action>.<format>.erb` when it exists (`create.turbo_stream.erb`, no
  layout, content type `text/vnd.turbo-stream.html`); `.html.erb` is the
  html case as today. For `:json` without a template the action must
  render (JSON templates are out with jbuilder).
- **Helpers.** `article_path(a, format: :json)` → `/articles/3.json`;
  `url_for` likewise.

## 4. Concerns and `helper_method` (C-10, V-5, M-6)

### 4.1 Controller concerns

```ruby
# app/controllers/concerns/admin_gate.rb
module AdminGate
  extend ActiveSupport::Concern

  included do
    before_action :require_admin
    helper_method :admin?
  end

  class_methods do
    def per_page = 50
  end

  def admin? = Current.user&.admin?
  def require_admin = (render plain: "Not Found", status: :not_found unless admin?)
end
```

- gen scans `app/controllers/concerns/**/*.rb` (and any module file under
  `app/controllers`). A controller that writes `include AdminGate` gets,
  in its generated callback and view-assign tables, everything the
  concern's `included do ... end` declares — `before_action`,
  `skip_before_action`, `after_action`, `around_action`, `helper_method`,
  `rate_limit`, `rescue_from`, `layout` — in the order written, at the
  position of the `include`.
- `@x =` assignments in the concern's methods count as the controller's
  view assigns (D15's scan, extended).
- `class_methods do ... end` becomes the module's singleton methods that
  the including class can call through a generated delegator
  (`self.class.per_page` works in an action). Spike item 3 checks the shape.
- `ActiveSupport::Concern` exists as an empty marker module so that `extend
  ActiveSupport::Concern` compiles. `ActiveSupport` as a whole does not.
- Concerns may include concerns; gen expands them depth first and refuses a
  cycle by name.

### 4.2 Model concerns (M-6)

The same expansion for `app/models/concerns/**/*.rb`: `included do` may hold
any of phase 2's class-level declarations (`validates`, `validate`,
`scope`, `belongs_to`, `has_many`, `has_one`, `encrypts`, callbacks,
`normalizes`); they are treated as written in the including model, at the
`include`. Instance methods are ordinary module methods.

### 4.3 `helper_method`

`helper_method :current_user, :crypto_market` in a controller (or a concern's
`included` block) makes those names callable from that controller's
templates and from components rendered by them. gen writes a dispatch
entry per name in the controller's helper table; the template call reaches
the controller instance's method with its arguments. A helper method name
that is also a framework or application helper is refused by gen.

## 5. Controller additions (C-1 to C-5, C-7 to C-9, C-11)

- **C-1 `params.expect` / nested `permit`.**
  `params.expect(article: [:title, :body, tags: [], meta: [:source]])`
  returns the permitted Hash, raises `ActionController::ParameterMissing`'s
  counterpart (400) when the key is missing or the shape is wrong.
  `params.require(:x).permit(...)` gains the same nested and array forms.
  Values are String, Array of String, or a nested permitted Hash.
- **C-2 `send_data`.** `send_data(bytes, filename:, type:, disposition:
  "attachment" | "inline")` with a correct `Content-Disposition` (RFC 6266,
  UTF-8 `filename*`). `send_blob` stays for attachments.
- **C-3 HTTP caching.** `fresh_when(etag: obj_or_string, last_modified:
  time, public: false)` and `stale?(...)` (true when the response must be
  rendered) answer 304 to a matching `If-None-Match` / `If-Modified-Since`
  (weak ETags of `to_param` + `updated_at` for a model, or of the String).
  `expires_in(seconds, public: true)` writes `Cache-Control`. No automatic
  ETag on every response.
- **C-4 `rate_limit`.** Adds `by: :method_name` (the key comes from a
  controller method, e.g. the user id), `with: :method_name` (what to do
  when limited, instead of 429), `if:` / `unless:` (method names), `name:`
  (two limits on one action). Counts move to `Cybertrain::Cache` (phase 3)
  so they are shared across processes; `store: :memory` keeps the
  per-process counter.
- **C-5 Content Security Policy.** In `config/app.rb`:

  ```ruby
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net"
    p.style_src :self
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
  c.content_security_policy_report_only = true
  ```

  The header is written per response with a fresh nonce when nonce
  directives are set; `csp_meta_tag`, `javascript_tag(nonce: true) { }`,
  `javascript_importmap_tags` and `stylesheet_link_tag(nonce: true)` use
  it; controllers can override with `content_security_policy do |p| ...
  end` (a generated per-controller policy, not a stored block). Off by
  default, as in Rails; `cybertrain new` writes the commented block.
- **C-7 Cookies.** `cookies[:theme]` reads, `cookies[:theme] = "dark"` or
  `= { value:, expires:, path:, httponly:, secure:, same_site: }` writes,
  `cookies.delete(:theme)`, `cookies.permanent`, `cookies.signed[:x]`
  (HMAC with a key derived from `secret_key_base`), `cookies.encrypted[:x]`
  (AES-256-GCM, section 5.1's key derivation).
- **C-8 Encrypted session.** See 5.1.
- **C-9 Status symbols.** Every Rack symbol (`:unauthorized`,
  `:payment_required`, `:unprocessable_content`, `:too_many_requests`,
  ...) in `status:` and `head`.
- **C-11 Defaults and transport.** `Permissions-Policy` joins the default
  headers (`camera=(), microphone=(), geolocation=()` unless configured);
  `config.force_ssl` redirects http to https (by `X-Forwarded-Proto` behind
  a proxy) and writes `Strict-Transport-Security`. Host checks extend the
  existing development guard (`HostAuthorization` over
  `Config#allowed_hosts`, today in development only) rather than adding a
  second list: `CYBERTRAIN_HOSTS` (comma-separated) is appended to
  `allowed_hosts` in every environment; development keeps checking as now
  (its loopback names plus those entries); production and test check only
  when `CYBERTRAIN_HOSTS` is set (empty, the default, means no check, as
  Rails' production default). The health path is exempt in every
  environment (Rails' `host_authorization exclude:`), so a load balancer
  probing by IP still reaches `HealthCheck`; the exemption is the path
  alone, so development's protection of every other path is unchanged.
  A refused host answers 403.

### 5.1 The encrypted session cookie (Q13)

- The session cookie is encrypted and authenticated with AES-256-GCM, as
  Rails' default cookie store. The key is derived from `secret_key_base`
  (HMAC-SHA256 with a fixed purpose label), so no new variable is needed;
  rotating `secret_key_base` signs everyone out, as it does today.
- `require "cybertrain"` loads the encryptor, so every application links
  Spinel's openssl package (libssl / libcrypto). On macOS that means
  Homebrew's OpenSSL for every application (docs/guide/install.md already
  asks for it for https and `encrypts`); the generated Dockerfile's build
  stage gains `libssl-dev` and its runtime stage `libssl3t64`.
- Rule 62 (a boxed `getbyte` dispatches into the openssl package's own once
  openssl is in the program) then applies framework-wide: spike item 4
  greps the C output of a full program, as phase 3 did for gzip, and every
  byte scanner that reads a boxed String reads it through a fresh local.
- The upgrade breaks every existing session once (the old signed cookie
  does not decrypt and is treated as absent): users sign in again. Section
  14 records it.

## 6. View additions (V-6, V-7, V-9 to V-11, V-13)

- **V-6 `Cybertrain::NumberHelper`.** `number_with_precision(n, precision:,
  delimiter:, separator:, strip_insignificant_zeros:)`,
  `number_with_delimiter(n, delimiter:, separator:)`, `number_to_human(n,
  precision:, units:)`, `number_to_percentage(n, precision:)`,
  `number_to_currency(n, unit:, precision:, format:)`,
  `number_to_human_size(n)`. Callable from templates and, as module
  functions, from Ruby (fin_dash's models call `ActiveSupport::NumberHelper`
  28 times). 4a's formats are English; 4b reads separators, units and
  currency from the locale. Integer, Float and BigDecimal (phase 2's
  decimal columns) are accepted; the return is a String.
- **V-7 Forms.**
  - `form_with(model:, url:, scope:, method:, local:, data:)`: `scope:` sets
    the name prefix (`url: search_path, scope: :q` → `q[term]`); `model:
    [:admin, @article]` takes the namespaced path.
  - Builder additions: `select(:field, choices, include_blank:, prompt:,
    selected:, disabled:, multiple:)` with choices as an Array of values, of
    `[label, value]` pairs or a grouped Hash (`<optgroup>`);
    `collection_select(:field, records, :value_method, :label_method)`;
    `radio_button(:field, value)`; `check_box(:field, include_hidden:
    false)`; `date_field`, `datetime_local_field`, `time_field`,
    `number_field`, `range_field`, `color_field`, `search_field`,
    `telephone_field`, `url_field`, `email_field`, `hidden_field` (those not
    already there).
  - Standalone `select_tag`, `options_for_select`,
    `options_from_collection_for_select`, `label_tag`, `text_field_tag`,
    `hidden_field_tag`, `submit_tag`.
  - Out: `fields_for` and nested attributes (no
    `accepts_nested_attributes_for` in the model layer).
- **V-9 Layouts.** `layout "frame"`, `layout :method_name` (the method
  returns a layout name or `false`), `layout "x", only: [...] / except:`, in
  a controller or concern; `render layout: "x"` per call. fin_dash's "frame
  layout when the request has `Turbo-Frame`" is a two-line method.
- **V-10 Turbo.** `turbo_frame_tag(id_or_record, src:, loading: :lazy,
  target:)`; `turbo_stream.replace / update / append / prepend / before /
  after / remove(target, partial:, locals:, html:)` in templates and as
  `render turbo_stream: [...]` in controllers, built on phase 1's stream
  rendering; `turbo_stream_from` stays.
- **V-11.** `time_tag(time, text = nil, format:)`, `image_tag(source, alt:,
  size:, class:)` (assets, section 7), `current_page?(path)`.
- **V-13 Collections.** `render partial: "comment", collection: @comments,
  as: :comment, spacer_template: "divider"`, `render @comments` (partial
  name from the model's class), with the `<name>_counter` local; components
  gain `Klass.with_collection(items)`.

## 7. Assets (A-1, A-2, A-5)

### 7.1 Sources and the build

- Sources: `app/assets/stylesheets/`, `app/assets/images/`, `app/assets/**`
  generally, `app/javascript/**`, `vendor/javascript/**`; the logical path
  is the path below those roots (`application.css`, `logo.svg`,
  `controllers/hello_controller.js`).
- `spin run gen` digests each file (SHA-256, its first 8 hex characters, as
  Propshaft's short digest) and writes `public/assets/<logical
  name>-<digest>.<ext>`. Old digests are kept so that a page loaded before
  a deploy, or an old process still running during a rolling deploy, can
  fetch what its HTML names: for each logical file gen keeps the current
  digest and the two before it, and deletes older ones (Propshaft's
  `assets:clean` keeps three versions likewise). A deploy that builds a
  fresh image (Kamal, Docker) carries only the current digests in the
  image, so the deploy notes add Kamal's `asset_path: /app/public/assets`,
  which bridges the previous release's files into the new container for
  the switch-over. CSS `url(...)` references to other assets are rewritten to
  their digested paths (Propshaft's compiler); an unknown reference is left
  as written with a warning.
- `gen/assets.rb` holds the manifest as a generated `case` from logical to
  digested path, compiled into the binary. The deployed program needs only
  `public/assets/`.
- The development loop's change detector watches the asset roots, so a
  saved CSS file re-runs gen and the page loads the new digest.

### 7.2 Helpers

`asset_path("logo.svg")` → `/assets/logo-1a2b3c4d.svg`;
`stylesheet_link_tag("application", media:, nonce:)`;
`javascript_include_tag("legacy")`; `image_tag("logo.svg")` (section 6). An
unknown logical name raises in development and test and logs once in
production (then emits the undigested path).

### 7.3 importmap

```ruby
# config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
pin_all_from "app/javascript/controllers", under: "controllers"
```

- gen reads the file lexically (`pin name, to:, preload:`; `pin_all_from
  dir, under:, preload:`) and writes the import map into the manifest; a
  `to:` without a scheme is a logical asset path.
- `javascript_importmap_tags("application")` writes the
  `<script type="importmap">` (with the CSP nonce when one is set), the
  `<link rel="modulepreload">` lines for preloaded pins and `<script
  type="module">import "application"</script>`.
- Out: the `bin/importmap pin` downloader (copy files into
  `vendor/javascript` or pin a URL).

### 7.4 Serving

`Static` serves a file under `/assets/` whose name carries a digest gen
wrote (current digests in `gen/assets.rb`; kept ones listed in
`public/assets/.manifest`, so `gen --check` stays a pure function of the
sources) with `Cache-Control: public,
max-age=31536000, immutable`; everything else in `public/`, including an
undigested file an application keeps under `public/assets/`, as today
(`max-age=3600`). A digested file is never rewritten in place, so no ETag
is needed. All of `public/assets/` is build output: the `.gitignore` that
`cybertrain new` writes lists `/public/assets/` (the `.manifest` is inside
it), and `cybertrain build` and the image build run gen, so an undigested
file an application keeps there is committed with `git add -f`.

# Part 4b

## 8. i18n (V-8, AU-7)

- **Dictionaries.** `config/locales/**/*.yml` in Rails' shape
  (`ja: { activerecord: { errors: ... } }`). gen reads them with a YAML
  subset parser: nested mappings, plain / single- / double-quoted scalars
  (with `\n`, `\"`, `\u` escapes), `|` and `>` block scalars, sequences of
  scalars (day and month names), comments. Anchors, aliases, tags, flow
  collections other than `[a, b]` of scalars, and multi-document files are
  refused with file and line. The result is `gen/locales.rb`: a generated
  lookup from `"ja.posts.index.title"` to its String (or Array), compiled in.
- **API.** `t("key", name: "x", count: n, default: "...")` (also
  `I18n.t`), `%{name}` interpolation, `count:` choosing among `zero` /
  `one` / `few` / `many` / `other` by the locale's rule; lazy lookup
  `t(".title")` in a template resolves to `<controller path>.<action>.title`
  (and to the partial's path in a partial); `l(time_or_date, format:
  :short)` with `time.formats` / `date.formats` from the dictionary;
  `I18n.locale` (per request, thread-local), `I18n.default_locale`,
  `I18n.available_locales`, `I18n.with_locale(:ja) { }`.
- **Configuration.** `c.i18n_default_locale = :ja` and
  `c.i18n_available_locales = [:en, :ja]` in `config/app.rb`; an
  application sets the request's locale in a `before_action` (from a param,
  a cookie, `Accept-Language` via `http_accept_language`'s simple
  `request.preferred_locale(available)`).
- **Plural rules** for en, fr, ru, ja, zh (CLDR), the five languages of the
  guide's translations.
- **Bundled dictionaries**, English and Japanese: validation messages
  (phase 2's validators), `time_ago_in_words` / `distance_of_time_in_words`,
  `number.*` (4a's helpers read separators, units and currency from them),
  `date` / `time` formats and names, `pluralize`, the form builder's
  default submit text, the jobs page, and 4b's authentication screens. An
  application's file overrides any key.
- **Missing keys.** The default locale is tried next; then, in development
  and test, `<span class="translation_missing" title="translation missing:
  ja.foo">Foo</span>` (Rails' default); in production the humanised last
  key segment. `config.i18n_raise_on_missing = true` raises instead (for
  tests).
- **Models.** `Model.human_attribute_name(:title)` and the model name come
  from `activerecord.attributes` / `activerecord.models`, used by labels and
  error messages, as in Rails.

## 9. Authentication additions (AU-2 to AU-6)

`cybertrain generate authentication` (users and sessions tables, sign-in,
sign-out, sign-up or invite-only, D25) gains the following, all written into
the application as Rails 8's generator does; the framework supplies only the
pieces (tokens, mail, the cache-backed counters).

- **Password reset (AU-2).** `PasswordsController` (`new`, `create`,
  `edit`, `update`), `PasswordsMailer.reset(user)` sent with
  `deliver_later`, views. The token is `user.password_reset_token`: signed,
  expiring after 15 minutes, and bound to the current password hash so it
  stops working once the password changes. `create` answers the same
  ("if the address is registered, a link was sent") whether or not the
  address exists. Updating the password ends every other session (D25).
- **Confirmation, optional (AU-2).** `--confirmable` adds `confirmed_at`, a
  confirmation mail on sign-up, sign-in refused until confirmed (with a
  "send again" form), and an email change that takes effect only when the
  new address confirms.
- **Lockout (AU-3).** `failed_attempts` and `locked_until` columns; 10
  failures lock the account for an hour (`c.auth_lockout_attempts`,
  `c.auth_lockout_period`); a locked account answers the same message as a
  wrong password; a successful sign-in or a password reset clears the
  count. The existing per-IP `rate_limit` stays.
- **Account pages (AU-4).** `AccountsController` with `edit` (email and
  password change; the current password is required for either),
  `update`, and `destroy` (requires the password; deletes the user and
  their sessions).
- **Remember me (AU-5).** A "keep me signed in" box. The session row
  gains `remember` (boolean) and `last_active_at`. Checked: the cookie
  persists for `c.auth_remember_for` (30 days) and the row's absolute limit
  is `auth_remember_for` instead of `Config#session_max_age` (two weeks,
  D25), so a remembered user is not signed out on day 14. Unchecked: a
  browser-session cookie (no `Expires`) and the absolute limit stays
  `session_max_age`. Either way a session unused for
  `c.auth_idle_timeout` (7 days) ends (`last_active_at`, updated at most
  once a minute). The framework's cookie-level `session_max_age` check
  reads the per-session limit the generated code stamps, so the two limits
  do not disagree.
- **Admin (AU-6).** `users.admin` (boolean, default false), `user.admin?`,
  and a generated `require_admin` before_action in `Authentication` that
  answers 404 unless the current user is an admin; the jobs page
  (`jobs_page ..., before_action: :require_admin`) uses it. The user command
  gains `admin USER` / `unadmin USER`.
- **Text (AU-7).** Every string in the generated views, mails and flash
  messages goes through `t()`; the bundled English and Japanese
  dictionaries cover them.

# Both parts

## 10. Configuration added

| Variable | `Config` field | Default | Meaning |
| --- | --- | --- | --- |
| `CYBERTRAIN_FORCE_SSL` | `force_ssl` | `false` | redirect to https and send HSTS |
| `CYBERTRAIN_HOSTS` | `allowed_hosts` (appended) | `""` | comma-separated allowed `Host` values; outside development, set means checked (section 5) |
| — | `content_security_policy` (block), `content_security_policy_report_only`, `content_security_policy_nonce_directives` | off | section 5 |
| — | `permissions_policy` | camera, microphone, geolocation off | section 5 |
| `CYBERTRAIN_I18N_DEFAULT_LOCALE` | `i18n_default_locale` | `en` | 4b |
| — | `i18n_available_locales`, `i18n_raise_on_missing` | `[default]`, false | 4b |
| `CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS` | `auth_lockout_attempts` | `10` | 4b |
| `CYBERTRAIN_AUTH_LOCKOUT_PERIOD` | `auth_lockout_period` | `3600` | seconds, 4b |
| `CYBERTRAIN_AUTH_REMEMBER_FOR` | `auth_remember_for` | `2592000` | seconds, 4b |
| `CYBERTRAIN_AUTH_IDLE_TIMEOUT` | `auth_idle_timeout` | `604800` | seconds, 4b |

Each is validated at boot. No new secret: cookie and session keys derive
from `secret_key_base`.

## 11. Documentation and design.md changes

- design.md: 4a adds D58 routing (namespace, scope, resource blocks,
  `param:`, redirects, query strings), D59 formats and `respond_to`, D60
  concerns and `helper_method`, D61 the controller additions and the
  encrypted session, D62 the view additions, D63 assets and importmap; 4b
  adds D64 i18n and D65 the authentication additions. D7, D8, D15, D25
  and section 8 are amended where they say "not built"; section 13 gets the
  dated entries.
- Guides: requests.md (routing, formats, concerns, controller additions,
  cookies, CSP), template-language.md (the helpers, forms, collections,
  Turbo helpers), a new assets.md, a new i18n.md (4b), the authentication
  section of requests.md or a new authentication.md (4b),
  configuration.md, tutorial.md where it changes; each with fr / ja / ru /
  zh and `script/check-guide-i18n --update-sha`. install.md: OpenSSL for
  every application.
- README's feature list; `cybertrain new` writes `app/assets/stylesheets/
  application.css`, `app/javascript/application.js`, `config/importmap.rb`,
  the CSP comment block and (4b) `config/locales/en.yml`.
- spikes/NOTES.md for rules found; docs/spinel-feedback.md for Spinel
  limits found.
- This spec gets "## 18. Implementation notes" after each part.

## 12. Spinel constraints and the spike

Constraints applied above: no computed send (rule 1) — namespaced
controllers, helper methods, concern expansion and the asset manifest are
generated `case` tables; one return type per name (10 / 34 / 41) — new
names are checked by `script/check-reserved-names` (`select`, `format`,
`expect`, `layout`, `cookies`, `t`, `l` exist on other receivers and are
the first candidates for a clash); no stored block through a base receiver
(88) — `respond_to` and per-controller CSP; rule 62 framework-wide once
openssl is always linked.

The spike (each plan's first task) checks on the pinned Spinel:

1. **4a** `respond_to` with blocks on a generated collector: the blocks
   reach the controller's instance variables and `render`; fallback, gen
   rewrites the `respond_to` body into a `case request.format` (the source
   stays Rails-shaped).
2. **4a** `module Admin; class ArticlesController < ApplicationController`
   and `class Admin::ArticlesController`, both instantiated from generated
   route handlers; fallback, the compact form is refused by gen.
3. **4a** A concern's `class_methods` called as `self.class.per_page` from
   an action; fallback, `ModuleName.per_page` is the documented spelling.
4. **4a** The whole framework with openssl always linked: the rule 62 grep
   over the C output, and the session round trip.
5. **4a** SHA-256 of a 1 MB file in the gen program, and a 200-entry asset
   `case`, compiled (time and binary size recorded).
6. **4b** The YAML subset parser on rails-i18n's `ja.yml` and `en.yml`
   (taken as fixtures) and a 2,000-key generated lookup, compiled.

**Results (2026-11-10, Spinel 2026.11.04.7026, programs kept in
spikes/phase4/ with their commands and output in each header):**

1. **PASS** (spikes/phase4/respond_to.rb). The immediate
   `Cybertrain::FormatCollector` (each arm runs its block as it is
   declared when it matches and no arm matched before) works from two
   controllers whose `json` blocks render different instance variables;
   the blockless `html` arm leaves the implicit render to draw the
   template; `any` matches an unlisted format and no match answers 406. The
   per-controller storing collector works too. `turbo_stream` defined on
   three receivers with three return types (the collector's arm, nil; a
   controller's builder, a TurboStreams; a template builder's, another
   object), the controller's called inside the collector's block, builds
   and answers correctly: **PASS**. Fallback taken: none; the framework
   collector is used (plan decision 6), and the controller keeps
   `turbo_stream` for its builder. (Had the three-receiver `turbo_stream`
   failed: FormatCollector keeps `turbo_stream`, the controller's builder
   is reached as `turbo_stream_actions`, and the template's as
   `turbo_stream` only inside templates, through the interpreter's
   dispatch with no Ruby method.)
2. **PASS** (spikes/phase4/admin_controllers.rb). `module Admin; class
   ArticlesController < ApplicationController` and `class
   Admin::ReportsController < ApplicationController` (after `module Admin`
   exists) both run from route handlers written as gen/routes.rb writes
   them, inherit ApplicationController's callbacks, and answer
   `Admin::ArticlesController` / `admin/articles` for their name and
   `controller_path`. `def admin_article_path(article, options = {})`
   called as `admin_article_path(a, page: 2, format: :json)` builds
   `/admin/articles/3.json?page=2`. Fallback taken: none; gen accepts both
   spellings (the compact form is not refused).
3. **PASS, with a stub** (spikes/phase4/concern_class_methods.rb).
   `self.class.per_page` in an action answers 50 through what gen writes
   (`module AdminGate; def self.per_page = 50; end` and `def
   self.per_page(...) = AdminGate.per_page(...)` in the including class),
   and the spliced `before_action` / `helper_method` / `rescue_from` take
   effect. The `included do ... end` body did **not** compile as written:
   it never runs, but Spinel compiles its implicit-self calls against the
   concern module and refuses `before_action` there (the by-design
   ahead-of-time NoMethodError of spikes/NOTES.md rule 84; rule 92).
   Fallback taken: `ActiveSupport::Concern` gains no-op stubs, instance
   methods of the module and so singleton methods of every concern that
   extends it, for every declaration Task 5 splices (the spike's three,
   `before_action`, `helper_method` and `rescue_from`, compiled with stubs
   taking the framework declaration's parameters and returning nil).
   `ModuleName.per_page` is not needed as the documented spelling, and gen
   does not refuse `class_methods do`. Also found (rule 93): a `def` inside
   the never-called `class_methods` block is compiled as an instance
   method of the concern, so of every including class, which CRuby never
   defines; so a `class_methods` method must not share its name with an
   instance method of the concern or of an including class (for Task 5's
   gen to refuse).
4. **PASS** (spikes/phase4/openssl_session.rb). With `require
   "cybertrain"` and `cybertrain/encryptor` in one program, a session
   written by one request is read by the next through `Application#call`
   and `Response#to_http` (a tampered cookie reads as empty), and the C
   has no `getbyte` or `each_byte` NoMethodError switch (both greps print
   0). In the same program `format` answering a Symbol (Request#format)
   beside Console::Printer.format's String, and `expect` answering a Hash
   (Params#expect) beside Mailer.expect's nil, build and answer
   correctly: **PASS**. Fallback taken: none; `Request#format` and
   `Params#expect` keep the Rails names and Mailer's `expect` keeps its
   name. (Had they failed: `Request#format` → `request_format`, and
   Mailer's private `expect` renamed `expect_reply`, `Params#expect`
   keeping Rails' name.)
5. **PASS** (spikes/phase4/asset_digest.rb, asset_case.rb). In a program
   shaped like bin/gen.rb, `File.binread` of a 1 MB file takes 1.4 ms and
   `Digest::SHA256.digest` of it 0.8 ms (1.1 ms for both, mean of 10;
   CRuby 3.3.6: 5.0 ms), and the digest matches CRuby's. A generated
   200-arm `case` from logical to digested path compiles in 1.3 s to a
   429 KB binary (a 1-arm one: 1.2 s, 385 KB) and answers in 293 ns a
   lookup (the arms are tried in order). Fallback taken: none.

## 13. Out of scope (recorded so nothing is lost)

AU-1 bcrypt; R-6 `mount`; A-3 / A-4 bundled JavaScript libraries; A-6
compression and HTTP/2; A-7 PWA helpers; V-12 jbuilder; V-14 time zones in
templates; C-6 `allow_browser`; `fields_for` and nested attributes; JSON
templates; `bin/importmap pin`; Sass / Tailwind builds (a separate CSS
build may write into `app/assets/builds/`, which the digester picks up);
model-level translations of enum values beyond `human_attribute_name`;
OAuth and two-factor authentication.

## 14. Compatibility changes for applications on 0.4

- Every existing session ends once at the upgrade (encrypted cookie).
- Every application links OpenSSL (macOS: Homebrew's OpenSSL); a
  Dockerfile generated by 0.4 needs `libssl-dev` (build stage) and
  `libssl3t64` (runtime stage) added.
- `params.permit(...)` returns `Hash{String => Object}` (values String,
  Array of String or a nested Hash) instead of `Hash{String => String}`;
  code that called String methods on its values without `Cybertrain::Cast.str` or
  `.to_s` needs one.
- Nested route blocks keep the explicit receiver the DSL already uses
  (`namespace :admin do |admin| admin.resources :articles end`): Spinel
  evaluates only the top level of `Routes.draw` receiver-less.
- A route segment containing a dot now splits off a format unless the route
  says `format: false`.
- `public/style.css` keeps working; moving it to `app/assets` is optional
  and the guide shows how.
- `rate_limit` counts move to the cache (`store: :memory` for the old
  behaviour), shared by every process through `Cybertrain::Cache`. A
  second limit with the same name in one controller's chain (parents
  included) is refused, so two limits need their own `name:`; a `by:`
  method answering nil or `""` raises; a `with:` method that renders
  nothing is followed by the 429.
- A dynamic segment no longer captures a dot in a route that takes a
  format (`/x/:id` with `/x/1.2.json`, or `/x/a.b`): such a route says
  `format: false` to keep dots in its segments.
- A `url_resolver` lambda takes three arguments, `->(name, args, options)`;
  a hand-written resolver must accept the options. `post_path(id: 3)`
  (the keyword form of a segment) is not supported: segments are
  positional.
- The session cookie is AES-256-GCM encrypted, so the 0.4 signed sessions
  end once (users sign in again). `Session.load` and `Session.dump` take a
  key derived from `secret_key_base` (`Crypto.derive_key(secret,
  SessionStore::SESSION_KEY_LABEL)`); the raw secret raises
  `Encryptor::Error`.
- The template number helpers raise `ArgumentError` for a value that is
  not an Integer, a Float, a numeric String or nil, and for a precision
  outside 0 to 100; nil renders `""` in a template, as 0.4's
  `number_with_delimiter` did. `Cybertrain::NumberHelper` called from Ruby
  raises for nil too.
- A model or controller that includes a module that is not a concern (no
  file under `app/models/concerns` or `app/controllers/concerns` has its
  name) keeps that `include` as plain Ruby: `include Comparable` works, and
  a misspelt concern name is a `NameError` when the application loads
  rather than a gen message. A name is looked up as Ruby looks it up, the
  class's modules first (`include Gate` inside `module Admin` is
  `Admin::Gate`); one that reaches no concern but ends in a concern's name
  stops gen. `include A, B` includes B first, as Ruby does.
- An action that answers by `Accept` sends `Vary: Accept`, and every ETag
  changes once on upgrade (it now carries the format and a build digest).
  `params.permit` and `expect` raise `ArgumentError` for a filter that is
  not an Array (`permit(meta: :source)`) and for an Array inside one.
  `layout "x"` or `render layout: "x"` naming a layout that does not
  exist raises `MissingTemplate` (only the default `application` layout is
  optional). `cookies` raise `Session::CookieOverflow` for a value over
  4096 bytes. In development a view edit can still get a 304 until a
  record changes or the page is reloaded without the cached copy: only
  `--embed-views` puts the templates in the digest. `Static` does not
  serve a dotfile under `/assets`, and an asset directory that is a
  symlink stops gen.
- `layout`: the first applicable declaration wins (Rails: the last one
  replaces the earlier ones).
- `Static` does not serve a file whose real path leaves `public/`, so a
  Capistrano-style `public/assets` symlinked to a shared directory must be
  a mount instead.
- `cybertrain new` ignores all of `/public/assets/`: digested files are
  build output.
- `X-Forwarded-Proto` is honoured by `force_ssl` whatever `trusted_proxy`
  says (as Rails and Rack do); `request.base_url` still believes it only
  from a trusted proxy.
- Concerns load from `gen/concerns/**` (copies with their `included` and
  `class_methods` blocks blanked), not from the application's source:
  `spin run gen` must have run after a concern changes.
- 4b: the authentication generator keeps its rule of never overwriting an
  application's files. Re-run on an application generated earlier, it
  writes the new files that are missing (the passwords and accounts
  controllers, mailer, views, the migration adding `admin`,
  `failed_attempts`, `locked_until`, `remember`, `last_active_at`) and
  prints, for each existing file it would have changed
  (`sessions_controller.rb`, `authentication.rb`, `user.rb`,
  `sessions/new.html.erb`), the lines to add by hand; the guide's upgrade
  section shows the same diff. `cybertrain generate authentication
  --force` overwrites them instead, for an application that never edited
  them.
- 4b: English validation messages now come from the bundled dictionary;
  their text is unchanged.

## 15. Acceptance

**4a**

1. Routing: `namespace` (nested), `scope` (path, module, as), `resource`
   blocks and `controller:`, `param:`, redirect routes, query strings and
   `format:` in helpers, each tested in the routes DSL and through the
   compiled router.
2. Formats: the extension, `Accept` and default paths; `respond_to` with
   html / json / turbo_stream; 406; implicit `*.turbo_stream.erb`.
3. Concerns: `before_action` and `helper_method` from a concern;
   `class_methods`; nested concerns and a refused cycle; a model concern
   with `validates` and `scope`.
4. Controllers: `params.expect` (nested, arrays, missing key → 400),
   `send_data`, `fresh_when` / `stale?` → 304, `expires_in`, `rate_limit`
   `by:` / `with:` / `if:` across two processes, CSP with nonce in the
   header and in tags, the cookie jar (plain, signed, encrypted), the
   encrypted session round trip and a tampered cookie refused, status
   symbols, `force_ssl`, `hosts`.
5. Views: every NumberHelper function against Rails' documented examples;
   the builder's new fields and the `select` family; layouts by name,
   method and `only:`; Turbo frame and stream helpers; collections with
   counter and spacer.
6. Assets: digests, CSS `url()` rewriting, the manifest, the helpers,
   `javascript_importmap_tags`, the immutable header, the dev loop picking
   up a change.
7. The blog: `app/assets/stylesheets/application.css` digested, Turbo
   pinned in `config/importmap.rb`; `namespace :admin` with
   `/admin/articles` (list and delete) behind an `AdminGate` concern with
   `helper_method :admin?`, the jobs page under the namespace;
   `/articles.json` and `/articles/:id.json` through `respond_to`; comment
   creation answering Turbo Stream (`create.turbo_stream.erb`);
   `number_with_delimiter` for counts, `time_tag` for dates, a `select`
   for the search order; CSP with nonces on.
8. The full suite, the blog's tests, `gen --check`, the gate, the guides
   and their translations, design.md and this spec's section 18.

**4b**

9. i18n: the YAML subset (and its refusals with line numbers), `t` with
   interpolation, `count:` in all five plural rules, lazy lookup in
   templates and partials, `l`, fallback and the missing-key span,
   `with_locale`, translated validation messages and
   `human_attribute_name`, number helpers by locale.
10. Authentication: reset (token expiry, single use after a password
    change, same answer for unknown addresses, mail through the SMTP
    receiver), `--confirmable`, lockout and its reset, account pages,
    remember me (a remembered session alive on day 15 and ended after day
    30, an unremembered one ended after day 14, both ended after 7 idle
    days), `require_admin`; the upgrade path of section 14: re-running the
    generator on an application generated by 0.4 adds the missing files and
    prints the manual changes, and with them applied the 0.4 application
    passes the same tests.
11. The blog: English and Japanese (`?locale=ja`, else `Accept-Language`),
    translated validation errors; users from the authentication generator,
    with `BLOG_ADMIN_TOKEN` replaced by an admin user guarding `/admin`.
12. As item 8.

## 18. Implementation notes (2026-11-11, after part 4a's Tasks 1 to 21 landed)

What differed from the plan or from this document in part 4a, and why;
each is recorded in the code and in docs/design.md D58 to D63 too. Part 4b
adds its own notes here.

- The spike (section 12): no fallback was taken; item 3 needed
  `ActiveSupport::Concern`'s no-op stubs (spikes/NOTES.md rule 92) and
  found rule 93. Task 7 then found the stubs not enough: Spinel refuses the
  bare `where` inside a model concern's `scope :visible, -> { where(...) }`
  however `scope` is stubbed, and a controller concern's `before_action {
  ... }` is the same shape. So gen writes each concern to
  `gen/concerns/<path under app/>` with its `included` and
  `class_methods` blocks blanked line for line, the application loads
  those copies, and `gen/concerns.rb` splices the blocks' bodies (section
  4.1's splice, for controller and model concerns alike). Gen implements
  rule 93's refusal: a `class_methods` name an instance method of the
  concern, an including class, its ancestors or their concerns has is
  refused, naming both places.
- Plan decisions taken as written: 4 (the fixed extension table and
  `:unknown`), 6 (the immediate `FormatCollector`), 10 (`around_action` in
  a concern refused), 26 (`turbo_frame_tag` writes `loading` only when
  given; `form_with local:` accepted and ignored) and 27 (number helpers
  on the digits of the decimal text, half up). Plan decision 2's "8 bytes"
  remark is stale: section 7.1 says 8 hex characters, and that is what gen
  writes. Plan Review Focus #5's example, `url("../fonts/x.woff2?v=3#iefix")`,
  is stale too: under the logical-directory rule below, `../` from a
  stylesheet at a root's top climbs out of the roots and is left as
  written with a warning; the suffix rule it pins holds for a target that
  resolves (`url(b.css?v=1)`).
- Routing (section 2): `namespace` and `scope` inside a `resources` block
  are refused rather than nested. A redirect route is unnamed unless it
  says `as:` (deriving a name hits the `/old-posts/:id` → `old-post`
  invalid-identifier problem). A custom route's `:id` and `:x_id` segments
  keep 0.4's helper argument names. Keywords never fill a path segment
  (section 2.6's "keyword arguments a route's pattern does not use" is
  read as "every keyword goes to the query"). A `:param` name in a route
  or scope path must be a lowercase identifier.
- Formats (section 3): `Route#matched_extension` takes the path's segments
  (a Route is shared by every connection's thread), and the emitter writes
  the format argument only when it is `false`. A Turbo form post
  (`text/vnd.turbo-stream.html, text/html`) to an action without a
  `turbo_stream` declaration or template answers through its html one, as
  Rails does, where section 3 would have answered 406; a `.turbo_stream`
  extension still asks for that format only. The same fallback covers any
  `Accept` that lists `text/html` or `*/*` next to a non-html format (an
  axios `application/json, text/plain, */*` gets the html of an html-only
  action, not a 406). No format but html renders in a layout. `render :x`
  inside a block renders the template of the format that block matched
  (`x.turbo_stream.erb` in `format.turbo_stream`); the html fallback runs
  the block a second time, so its other statements run twice. A response
  negotiated by `Accept` carries `Vary: Accept` (an extension's does not),
  and the format joins the ETag, so a cached html copy is never revalidated
  for a JSON or Turbo Stream request.
- Concerns (section 4): besides the copies above, an `include` of a module
  that is not a concern is left to Ruby, for models as for controllers
  (it was refused at first); `include A, B` splices B's `included` body
  first, as Ruby runs it; a model concern's `class_methods` name may not be
  a scope of the model or a name in `ModelScan::RESERVED_SCOPE_NAMES`;
  an `include` inside a model concern's `included` body brings that
  concern in; include positions are counted lexically; a model concern's
  callbacks run after the model's own (plan decision 9). `helper_method` is refused for a
  framework helper's name, a `_path` / `_url` name, an application helper's
  name, a name with no `def` in the class, its parents or its concerns,
  and a `def` whose parameters a template cannot pass.
- Controllers (section 5): `params.expect(:id)` answers the one-entry Hash
  `{"id" => "3"}`, and the top-level list form `params.expect(tags: [])`
  answers `{"tags" => [...]}` (one return type). `fresh_when` lets a
  non-empty `If-None-Match` decide alone (RFC 9110 13.1.3) and answers 304
  to GET and HEAD only; a 304 carries no Content-Type, Content-Length,
  body or policy header (a fresh nonce on it would break a cached page's
  scripts). The ETag is the key, the request's format and a build digest
  (the asset digests and import map, plus the embedded views of an
  `--embed-views` build), so a deploy invalidates it; content that differs
  per user needs the user in the key (`etag: "posts/#{@post.id}-#{current_user.id}"`),
  and a page with a CSP nonce is not made `public`, as a shared cache
  would give every visitor one nonce. `permit` and `expect` refuse a filter
  that is not an Array with `ArgumentError`, a programmer's error and not
  a 400.
  `rate_limit` refuses a `name:` with `:` and a second limit of the same
  name in one controller's chain, raises for a `by:` method answering nil
  or `""`, and follows a `with:` method that renders nothing with the 429;
  the memory store's key is `"<path>:<name>:<key>"`. The CSP middleware is
  installed only when a policy is declared. `force_ssl` reads
  `X-Forwarded-Proto` whatever `trusted_proxy` says (plan decision 21),
  exempts only GET and HEAD of the health path, answers 400 to a missing
  or malformed `Host` rather than redirect to it, and makes cookies
  `Secure` (`Config#secure_cookies?`); a `CYBERTRAIN_HOSTS` entry with a
  port stops the boot, and `Config#checked_hosts` also takes hosts set in
  `config/app.rb`. The template helper `form_action` became
  `form_record_url`, as the policy's `form_action` returns nil (rule 34).
  `javascript_tag` writes no CDATA. The cookie jar's `signed` HMAC covers
  `"<name>=<value>"`, so a value does not verify under another name; a jar
  built without SessionStore raises for `signed` and `encrypted`; a cookie
  written through the jar raises `Session::CookieOverflow` over 4096 bytes
  of `name=value`. `Session.load` and `dump` take the derived key.
- Views (section 6): the number helpers raise for any value that is not
  numeric and cap the precision at 100 and the exponent at 400; nil
  renders `""` in a template, and `NumberHelper` called from Ruby raises
  for it. `f.select` has no public Ruby method (Kernel's and Enumerable's
  `select` return other types, rule 34): templates reach a private
  `select_field`. The hidden input of `multiple:` is written `<input
  type="hidden" name="..." value="" autocomplete="off">` (plan decision
  25's order), and `form_with data:` validates its keys. The template's
  Turbo Stream builder takes a block's output through
  `call_method_with_block`, so no block reaches it. `time_tag`'s `format:`
  is formatted directive by directive with literal patterns and raises on
  an unknown directive (rule 96), and on a width or flag that `strftime`
  would read differently (`%6L`, `%-T`, `%:Y`); a width on a number
  replaces its padding as `strftime` does. `collection:` takes no other
  keyword. A component's `with_collection` is
  generated for a component whose one required keyword is named after it
  (`ComponentCollection`), and a hand-written `def self.with_collection`
  is refused. The first applicable `layout` declaration wins; a layout
  method answering nil falls back to the parent's layout; `layout nil`, a
  lambda and a constant are refused.
- Assets (section 7): `url()` is resolved against the stylesheet's logical
  directory, as Propshaft resolves it (so the blog's stylesheet uses
  `url("logo.svg")`, not `url("../images/logo.svg")`); a symlinked file
  leading out of its tree or nowhere, and a path with a space or a control
  character, stop gen, as does an asset directory (`app/assets`, `app/javascript`,
  `vendor/javascript`) that is itself a symlink; an unknown import map
  option stops it too. Boot
  sets `Assets.raise_on_unknown = !production?` (Assets cannot read
  `Config`). `Static` refuses a file whose real path leaves `public/` and any dotfile
  under `/assets` (`.manifest`, a crashed run's temp file); other public
  dotfiles (`/.well-known`) are served.
  `image_tag` writes `alt=""` when given it and makes none up; a URL with a
  scheme, `//`, `data:` or `cid:` is written as given and `javascript:x`
  is looked up as an asset name. One file, `cybertrain/asset_manifest.rb`,
  reads `.manifest` for gen and boot. `Dev::WATCHED` moved to
  `cybertrain/dev/watched.rb`, which the watcher's CRuby test can load.
  `cybertrain new` ignores all of `/public/assets/` (section 7.4 amended).
- New Spinel rules: spikes/NOTES.md 92 to 98 (92 and 93 from the spike,
  94 from Task 5, 95 from Tasks 2 and 13, 96 and 97 from Task 17, 98 a
  tooling note); docs/spinel-feedback.md U to X.
- Tests: `spin test` has 177 programs (16 new: `assets`, `collections`,
  `controller_formats`, `cookie_jar`, `csp`, `force_ssl`, `form_tags`,
  `gen_assets`, `gen_concerns`, `gen_model_concerns`, `helper_method`,
  `http_caching`, `number_helper`, `rate_limit_store`, `send_data`,
  `turbo_helpers`), and examples/blog's two programs run 53 tests (36 and
  17). The whole suite (`script/test-shard 0 1`) passed 177 of 177 at 0e183e6, before the final fix wave, and again 177 of 177 at 3bdc03d, after it.
