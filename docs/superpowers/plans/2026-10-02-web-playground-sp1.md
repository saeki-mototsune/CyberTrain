# Web playground SP1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Anyone can try cybertrain from a browser: a public, smoke-tested image `ghcr.io/saeki-mototsune/cybertrain-playground` (toolchain, offline framework mirror, prebuilt tutorial blog) that GitHub Codespaces opens from a one-click link on the site and in the README, plus the framework settings the editor's cross-site preview needs (`CYBERTRAIN_HOST`, `CYBERTRAIN_SESSION_SAME_SITE`, `CYBERTRAIN_SESSION_PARTITIONED`), released as 0.2.1.

**Architecture:** The framework reads three new environment variables in `Config` and stays vendor-neutral; `Cookies.serialize` forces `Secure` for `SameSite=None` and `Partitioned`, and `Application#boot` refuses an invalid SameSite. `playground/Dockerfile` builds three stages (`cli-src` → `toolchain` → `playground`) from the repository root, with a one-commit framework mirror made from `.git` through a bind mount, and a profile script that turns the cookie settings on only when `CODESPACES=true`. `.devcontainer/devcontainer.json` points Codespaces at the published image; a workflow builds it for linux/amd64, runs `playground/smoke.sh` and pushes only the image it tested.

**Tech Stack:** Spinel `2026.09.12` (`spin`, `spinel`), the cybertrain CLI gem on Ruby 3.2+, Ubuntu 24.04, Docker BuildKit (Dockerfile syntax 1), bash 3.2+ with docker and curl for the smoke test, GitHub Actions (docker/build-push-action v6, docker/metadata-action v5), GHCR, GitHub Codespaces (devcontainer.json), the static site in `site/`.

**Spec:** `docs/superpowers/specs/2026-10-02-web-playground-sp1-design.md` (Japanese; authoritative)

## Global Constraints

- Work on branch `web-playground` in the primary checkout `/Users/saeki/work/cybertrain` (a regular clone whose `.git` is a directory). Never create a git worktree for any task: the image build bind-mounts `.git` and stops in a worktree by design.
- Order: Task 1 → Task 2 → Task 3 (their files are disjoint, but they run the same framework test programs, such as `test/integration_m1.rb`, in this one working tree, so one at a time); Task 4 (only `playground/smoke.sh`, no spin) may run beside Tasks 1-3; Task 5 needs Tasks 1-4 committed; Task 6 needs Task 5; Tasks 7 and 8 need Task 6 and may run beside each other (disjoint files, no shared test programs); Task 9 needs Tasks 7-8; Task 10 is last. Parallel tasks share this checkout and take turns at their commit step.
- Stage files by path (`git add <path>...`), never `git add -A` or `git add .` (the checkout holds an untracked `.playwright-mcp/`). Never amend a pushed commit or force-push.
- Commit subjects follow `git log` ("Area: what changed", no trailing period). Every commit message ends with the Co-Authored-By trailer your own session specifies; the commands below show `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` — replace it if yours differs.
- Nothing is pushed to GitHub and no pull request is opened without the repository owner's explicit go-ahead in chat (Task 9 and Task 10 say when and how to ask).
- Every file under `cybertrain/` must compile under Spinel 2026.09.12 (`spikes/NOTES.md`): `""` is the unset sentinel, never `nil` (rule 11); the SameSite check is a chain of `==`, never `include?` (rules 14, 29); the new method names `default_host`, `default_session_same_site`, `default_session_partitioned`, `session_same_site`, `session_partitioned` and `session_same_site_error` must not exist on any other class (rules 10, 34, 41); no lambda literal as a keyword argument in framework code (rule 42).
- The CLI files listed in `cybertrain.gemspec` (`cybertrain/version.rb`, `cybertrain/cli.rb`, `cybertrain/cli/*.rb`, `cybertrain/generator/inflector.rb`) must keep running under CRuby 3.2+.
- The framework never reads `CODESPACES`; only the image's profile script turns the cookie settings on, only when `CODESPACES=true`, and never over a value already set.
- `CYBERTRAIN_HOST`: unset or empty → `"127.0.0.1"`; any other value goes to `TCPServer.new` unvalidated. The image never sets it; local Docker passes `-e CYBERTRAIN_HOST=0.0.0.0`.
- `CYBERTRAIN_SESSION_SAME_SITE`: unset or empty → `"Lax"`; exactly `Lax`, `Strict` or `None`, case-sensitive. Any other value, from the environment or `config/app.rb`, makes `Application#boot` print `error: CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got "<value>")` and exit 1.
- `CYBERTRAIN_SESSION_PARTITIONED`: true only for `1` or `true`; every other value is false, never an error.
- `SameSite=None` and `Partitioned` each force `Secure`, enforced once in `Cookies.serialize`; `Config#session_secure` keeps its value and means "Secure even without them". Session `Set-Cookie` endings: default `; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600`; in a codespace `; Path=/; HttpOnly; SameSite=None; Max-Age=1209600; Secure; Partitioned`.
- Version `0.2.1`, in `cybertrain/version.rb` and `spin.toml` together (CI checks they match). Leave `test/cli_new.rb` lines 175-176 (`--ref v0.2.0`, an explicit argument) and the records under `docs/superpowers/` unchanged (ticking this plan's checkboxes aside).
- Tests: `spin test test/<name>.rb ...` with at most 6 files in the foreground; the full `spin test` (66 programs, over 180 s) runs in the background with its output in a log file. Never edit an `.expected` by hand. CRuby-portable programs (`session`, `cli_new`, `cli_toolchain`) are regenerated with `spin test --regen test/<name>.rb`; programs that link SQLite or diverge under CRuby (`cookies`, `application`, `version`) with `script/regen-snapshot test/<name>.rb`, which snapshots the compiled binary (spikes/NOTES.md rule 23).
- Image name `ghcr.io/saeki-mototsune/cybertrain-playground` (published for linux/amd64 only); local tag `cybertrain-playground:local`, built at the repository root with `docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local .` (linux/arm64 on the Apple Silicon development machine, about 3 minutes cold). The blog in the image builds against the HEAD commit (the mirror) while the CLI comes from the working tree: commit framework changes before building.
- Image layout, which SP2 relies on: user `dev`, uid/gid 1000, HOME `/home/dev`; `CYBERTRAIN_HOME=/opt/cybertrain`; `XDG_CACHE_HOME=/opt/cybertrain-cache`; mirror `/opt/cybertrain-mirror/cybertrain.git` with two `insteadOf` rules in `/etc/gitconfig`; blog `/workspace/blog`; `/usr/local/bin/playground-server [APP_DIR]`; `/etc/profile.d/cybertrain-playground.sh`; port 3000; stages `toolchain` and `playground`.
- Smoke test: `bash playground/smoke.sh IMAGE` runs on bash 3.2+ with docker and curl (no associative arrays, no `date +%N`, no `mapfile`, no host `timeout`); exit 0 when every check passes, 1 on any failure, 2 on bad usage.
- Docker is needed in Tasks 4, 5, 6, 9 and 10. If `docker` cannot reach the daemon from the command sandbox, ask for permission to run Docker commands outside it; never work around the sandbox.
- Deep link: `https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1` (another branch: `https://codespaces.new/saeki-mototsune/CyberTrain/tree/<branch>?quickstart=1`).
- Site (Task 8): static, works without JavaScript; existing classes only — no new colours, no external requests (no badge images), and no new CSS except the one layout rule Task 8 adds (`.step > .cta-row { margin-top: 28px; }`: the page puts a button row inside a step, which the tutorial never did); gold only where the existing pages already use it (BRAND.md: the logo's light bar); every claim and command on `site/playground.html` appears in README.md's "Try it in the browser" (site/README.md content rule); README and site wording stay identical in meaning.

## Review Focus

1. Coming back to a codespace GitHub idle-stopped (after 30 minutes by default): when the same container starts again, the dev server comes back by itself, undisturbed by the lock file and `tmp/secret_key` left from the first run, the articles made before are still listed, and exactly one server runs. Pinned by smoke check D3 (Task 5, Step 1).
2. A server the visitor starts by hand in a new codespace terminal (PLAYGROUND.md's tutorial step 08, or "Start a fresh app"): that terminal, whether bash runs as a login or an interactive shell, already has `CYBERTRAIN_SESSION_SAME_SITE=None` and `CYBERTRAIN_SESSION_PARTITIONED=1`, so its forms work in the preview instead of answering 403. Pinned by smoke check C3 (Task 5, Step 1).
3. A browser reload (a reattach) while such a hand-started server holds port 3000 without playground-server's lock: `postAttachCommand` leaves it alone, saying the port is in use and exiting 0, and never starts a second server that dies on the busy port. Pinned by smoke check D4 (Task 5, Step 1).
4. "Start a fresh app" exactly as PLAYGROUND.md says (`cd ..` from the blog, so in `/workspace`) with no network: `cybertrain new` succeeds there and the new app builds. Pinned by smoke checks B2 and B3 running in `/workspace` instead of `/tmp` (Task 5, Step 1).
5. A production app (`session_secure` true) shown in another site's frame with `CYBERTRAIN_SESSION_SAME_SITE=None` and `CYBERTRAIN_SESSION_PARTITIONED=1`: its session cookie carries `Secure` exactly once, followed by `Partitioned`. Pinned by `test "serialize writes Secure once when secure, same_site None and partitioned are all set"` in `test/cookies.rb` (Task 1, Step 1).

---

### Task 1: `Cookies.serialize` and `SessionStore`: SameSite=None, Partitioned and Secure

**Files:**
- Modify: `cybertrain/http/cookies.rb` (`serialize`, lines 26-34)
- Modify: `cybertrain/middleware/session_store.rb` (comment and `initialize`, lines 12-20; the `Cookies.serialize` call in `call`, lines 32-33)
- Test: `test/cookies.rb`, `test/cookies.rb.expected` (snapshot from the compiled binary)
- Test: `test/session.rb`, `test/session.rb.expected` (snapshot from CRuby)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Cybertrain::Cookies.serialize(name, value, path: "/", max_age: -1, http_only: true, same_site: "Lax", secure: false, partitioned: false)` → String. Attribute order `Path`, `HttpOnly`, `SameSite`, `Max-Age`, `Secure`, `Partitioned`; `; Secure` is written once when `secure || partitioned || same_site == "None"`, `; Partitioned` when `partitioned`. The output for every existing call is unchanged.
- Produces: `Cybertrain::SessionStore.new(app, secret:, cookie_name: "_cybertrain_session", max_age: 1209600, secure: false, same_site: "Lax", partitioned: false)`, which passes `same_site:` and `partitioned:` to `Cookies.serialize`. Task 2 calls it with `same_site: c.session_same_site, partitioned: c.session_partitioned`.

- [ ] **Step 1: Write the failing tests**

In `test/cookies.rb`, insert these three tests between the last test (ends at line 43) and `Cybertrain::Test.run!` (line 45):

```ruby
test "serialize with same_site None adds Secure even when secure is false" do
  value = Cybertrain::Cookies.serialize("s", "v", same_site: "None")
  assert_equal "s=v; Path=/; HttpOnly; SameSite=None; Secure", value
end

test "serialize with partitioned appends Partitioned and implies Secure" do
  lax = Cybertrain::Cookies.serialize("s", "v", partitioned: true)
  assert_equal "s=v; Path=/; HttpOnly; SameSite=Lax; Secure; Partitioned", lax
  none = Cybertrain::Cookies.serialize("s", "v", max_age: 60, same_site: "None", partitioned: true)
  assert_equal "s=v; Path=/; HttpOnly; SameSite=None; Max-Age=60; Secure; Partitioned", none
end

# Production (secure: true) inside another site's frame: one Secure, not two.
test "serialize writes Secure once when secure, same_site None and partitioned are all set" do
  value = Cybertrain::Cookies.serialize("s", "v", max_age: 60, same_site: "None", secure: true, partitioned: true)
  assert_equal "s=v; Path=/; HttpOnly; SameSite=None; Max-Age=60; Secure; Partitioned", value
end
```

In `test/session.rb`, insert this test directly before `test "an unchanged session sets no cookie" do` (line 223):

```ruby
test "SessionStore passes same_site and partitioned to its Set-Cookie" do
  store = Cybertrain::SessionStore.new(SessionWriter.new, secret: SECRET, same_site: "None", partitioned: true)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
  store.call(ctx)
  assert ctx.response.cookies[0].end_with?("; SameSite=None; Max-Age=1209600; Secure; Partitioned")
end

```

The three existing `serialize` tests stay as they are: the default output does not change.

- [ ] **Step 2: Run them to verify they fail**

Run: `spin test test/cookies.rb test/session.rb`

Expected: `FAIL cookies.rb`, whose `--- actual` part ends with

```
FAIL serialize with same_site None adds Secure even when secure is false: expected "s=v; Path=/; HttpOnly; SameSite=None; Secure", got "s=v; Path=/; HttpOnly; SameSite=None"
FAIL serialize with partitioned appends Partitioned and implies Secure: expected "s=v; Path=/; HttpOnly; SameSite=Lax; Secure; Partitioned", got "s=v; Path=/; HttpOnly; SameSite=Lax"
FAIL serialize writes Secure once when secure, same_site None and partitioned are all set: expected "s=v; Path=/; HttpOnly; SameSite=None; Max-Age=60; Secure; Partitioned", got "s=v; Path=/; HttpOnly; SameSite=None; Max-Age=60; Secure"
10 tests, 10 assertions, 3 failures
```

(the compiled program ignores the unknown `partitioned:` keyword), then `FAIL session.rb`, whose actual output has `ERR  SessionStore passes same_site and partitioned to its Set-Cookie: ArgumentError: unknown keyword: :same_site` and `16 tests, 38 assertions, 1 failures`; last line `0/2 passed`.

- [ ] **Step 3: Implement**

Line numbers here are those of the files before this step.

In `cybertrain/http/cookies.rb`, replace `serialize` (lines 26-34) with:

```ruby
    # same_site "None" and partitioned both require Secure (browsers drop
    # such a cookie without it), so either adds Secure whatever `secure`
    # says, and Secure is written once.
    def self.serialize(name, value, path: "/", max_age: -1, http_only: true, same_site: "Lax", secure: false,
                       partitioned: false)
      out = +"#{name}=#{URI.encode_www_form_component(value)}"
      out << "; Path=#{path}"
      out << "; HttpOnly" if http_only
      out << "; SameSite=#{same_site}"
      out << "; Max-Age=#{max_age}" if max_age >= 0
      out << "; Secure" if secure || partitioned || same_site == "None"
      out << "; Partitioned" if partitioned
      out
    end
```

In `cybertrain/middleware/session_store.rb`, replace lines 12-20 (the comment and `initialize`) with:

```ruby
    # secure: true adds the Secure attribute, so browsers only send the
    # cookie back over HTTPS (Config#session_secure: on in production).
    # same_site is the SameSite value, "Lax", "Strict" or "None"
    # (Config#session_same_site); partitioned adds Partitioned (CHIPS,
    # Config#session_partitioned). "None" with Partitioned keeps the session
    # working inside another site's frame, such as an editor's preview; both
    # add Secure too (Cookies.serialize).
    def initialize(app, secret:, cookie_name: "_cybertrain_session", max_age: 1209600, secure: false,
                   same_site: "Lax", partitioned: false)
      super(app)
      @secret = secret
      @cookie_name = cookie_name
      @max_age = max_age
      @secure = secure
      @same_site = same_site
      @partitioned = partitioned
    end
```

and replace the two lines of the `Cookies.serialize` call in `call` (lines 32-33) with:

```ruby
        set_cookie = Cookies.serialize(@cookie_name, Session.dump(ctx.session, @secret),
                                       max_age: @max_age, secure: @secure, same_site: @same_site,
                                       partitioned: @partitioned)
```

- [ ] **Step 4: Regenerate the snapshots and run the tests**

```bash
script/regen-snapshot test/cookies.rb
spin test --regen test/session.rb
git diff test/cookies.rb.expected test/session.rb.expected
spin test test/cookies.rb test/session.rb test/client.rb test/csrf.rb test/csrf_chain.rb test/integration_m1.rb
```

Correction to spec §3.7: `test/cookies.rb` is not CRuby-portable. Under CRuby its test "parse of a malformed percent-escape does not raise ..." raises `ArgumentError` (the divergence it documents), so `--regen` would write a snapshot the compiled program can never match; its snapshot comes from the binary. `test/session.rb` is CRuby-portable (its CRuby output equals the committed snapshot).

Expected diff: `test/cookies.rb.expected` gains exactly

```
ok   serialize with same_site None adds Secure even when secure is false
ok   serialize with partitioned appends Partitioned and implies Secure
ok   serialize writes Secure once when secure, same_site None and partitioned are all set
```

after `ok   serialize omits Max-Age when negative and HttpOnly/Secure when off`, and its last line becomes `10 tests, 11 assertions, 0 failures`. `test/session.rb.expected` gains `ok   SessionStore passes same_site and partitioned to its Set-Cookie` before `ok   an unchanged session sets no cookie`, and its last line becomes `16 tests, 39 assertions, 0 failures`. No other line changes. The `spin test` run ends with `6/6 passed`.

- [ ] **Step 5: Commit**

```bash
git add cybertrain/http/cookies.rb cybertrain/middleware/session_store.rb test/cookies.rb test/cookies.rb.expected test/session.rb test/session.rb.expected
git commit -m "Cookies: SameSite=None and Partitioned imply Secure; SessionStore takes same_site and partitioned

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `Config` settings from the environment, the boot check and the stack wiring

**Files:**
- Modify: `cybertrain/config.rb` (whole file below: header comment, `attr_accessor`, three class methods, `initialize`, `session_same_site_error`)
- Modify: `cybertrain/application.rb` (`boot`, after the embedded-views check at lines 91-95; `build_stack`, the `SessionStore.new` call at lines 284-285)
- Test: `test/application.rb`, `test/application.rb.expected` (snapshot from the compiled binary: the program links SQLite)

**Interfaces:**
- Consumes: `SessionStore.new(..., same_site:, partitioned:)` from Task 1.
- Produces: `Cybertrain::Config.default_host` → String, `Config.default_session_same_site` → String, `Config.default_session_partitioned` → Boolean; `Config#host` (default from `default_host`), `Config#session_same_site` (String), `Config#session_partitioned` (Boolean), all with setters; `Config#session_same_site_error` → `""` for `"Lax"`, `"Strict"`, `"None"`, otherwise `CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got "<value>")`.
- Produces: `Application#boot` prints `error: <session_same_site_error>`, flushes STDOUT and exits 1 when the error is not empty, after the embedded-views check and before `resolve_secret!`. `build_stack` passes `same_site: c.session_same_site, partitioned: c.session_partitioned` to `SessionStore`. Task 5's image (smoke check F1) relies on the boot message.

- [ ] **Step 1: Write the failing tests**

In `test/application.rb`, make four edits (line numbers are those of the file before these edits).

Replace line 52 (`CONFIG_ENV = [...]`) with:

```ruby
CONFIG_ENV = ["CYBERTRAIN_ENV", "PORT", "CYBERTRAIN_DATABASE", "CYBERTRAIN_SECRET_KEY_BASE", "SPINEL_WORKERS",
              "CYBERTRAIN_HOST", "CYBERTRAIN_SESSION_SAME_SITE", "CYBERTRAIN_SESSION_PARTITIONED"]
```

In `test "config defaults in development"`, directly after `refute c.session_secure` (line 102), add:

```ruby
  assert_equal "Lax", c.session_same_site
  refute c.session_partitioned
```

Directly after `test "an empty CYBERTRAIN_DATABASE counts as unset"` (it ends at line 136), add:

```ruby

test "CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE and CYBERTRAIN_SESSION_PARTITIONED override the defaults" do
  clear_config_env
  ENV["CYBERTRAIN_HOST"] = "0.0.0.0"
  ENV["CYBERTRAIN_SESSION_SAME_SITE"] = "None"
  ENV["CYBERTRAIN_SESSION_PARTITIONED"] = "1"
  c = Cybertrain::Config.new
  ENV["CYBERTRAIN_SESSION_PARTITIONED"] = "true"
  with_true = Cybertrain::Config.new
  restore_config_env
  assert_equal "0.0.0.0", c.host
  assert_equal "None", c.session_same_site
  assert c.session_partitioned
  assert with_true.session_partitioned
end

test "empty CYBERTRAIN_HOST and CYBERTRAIN_SESSION_SAME_SITE count as unset; only 1 and true turn partitioning on" do
  clear_config_env
  ENV["CYBERTRAIN_HOST"] = ""
  ENV["CYBERTRAIN_SESSION_SAME_SITE"] = ""
  ENV["CYBERTRAIN_SESSION_PARTITIONED"] = ""
  empty = Cybertrain::Config.new
  ENV["CYBERTRAIN_SESSION_PARTITIONED"] = "0"
  zero = Cybertrain::Config.new
  ENV["CYBERTRAIN_SESSION_PARTITIONED"] = "false"
  word_false = Cybertrain::Config.new
  ENV["CYBERTRAIN_SESSION_PARTITIONED"] = "yes"
  yes = Cybertrain::Config.new
  restore_config_env
  assert_equal "127.0.0.1", empty.host
  assert_equal "Lax", empty.session_same_site
  refute empty.session_partitioned
  refute zero.session_partitioned
  refute word_false.session_partitioned
  refute yes.session_partitioned
end

test "session_same_site_error is empty for Lax, Strict and None and names the valid values otherwise" do
  c = Cybertrain::Config.new
  c.session_same_site = "Lax"
  assert_equal "", c.session_same_site_error
  c.session_same_site = "Strict"
  assert_equal "", c.session_same_site_error
  c.session_same_site = "None"
  assert_equal "", c.session_same_site_error
  c.session_same_site = "lax"
  assert_equal "CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got \"lax\")",
               c.session_same_site_error
end
```

Directly after `test "log_level :none, static_files and csrf switch their middleware off"` (it ends at line 258), add (it builds the Application the way that test does and drives the existing `/visit` route, which writes the session):

```ruby

test "the stack's session cookie follows session_same_site and session_partitioned" do
  c = Cybertrain::Config.new
  c.log_level = :none
  c.static_files = false
  c.csrf = false
  c.secret_key_base = "framed-secret"
  c.session_same_site = "None"
  c.session_partitioned = true
  framed = Cybertrain::Application.new(router: router, url_resolver: ->(name, args) { "/framed/#{name}" }, config: c)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/visit", {}, ""))
  framed.call(ctx)
  assert ctx.response.cookies[0].end_with?("; SameSite=None; Max-Age=1209600; Secure; Partitioned")
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `spin test test/application.rb`

Expected: `FAIL application.rb`: either `FAIL application.rb (build failed)` after a compiler error naming `session_same_site`, `session_partitioned` or `session_same_site_error`, or `ERR` lines (NoMethodError) for `config defaults in development` and the four new tests; last line `0/1 passed`.

- [ ] **Step 3: Implement**

Replace `cybertrain/config.rb` with:

```ruby
require "cybertrain/crypto"

module Cybertrain
  # The application's settings. Defaults come from the environment
  # (CYBERTRAIN_ENV, PORT, CYBERTRAIN_DATABASE, CYBERTRAIN_SECRET_KEY_BASE,
  # SPINEL_WORKERS, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
  # CYBERTRAIN_SESSION_PARTITIONED); config/app.rb then adjusts them:
  #
  #   Cybertrain.configure do |c|
  #     c.port = 3000
  #   end
  class Config
    SECRET_LENGTH = 64

    attr_accessor :env, :host, :port, :database_path, :secret_key_base, :views_root, :public_root, :layout,
                  :log_level, :session_cookie_name, :session_max_age, :session_secure, :session_same_site,
                  :session_partitioned, :pool_size, :static_files, :csrf, :workers, :secret_key_path

    # "storage/<env>.sqlite3" unless CYBERTRAIN_DATABASE names a path (an
    # empty one counts as unset). Shared with DB::CLI.
    def self.default_database_path(env)
      configured = ENV["CYBERTRAIN_DATABASE"] || ""
      configured.empty? ? "storage/#{env}.sqlite3" : configured
    end

    def self.default_env
      ENV["CYBERTRAIN_ENV"] || "development"
    end

    # CYBERTRAIN_HOST, or "127.0.0.1" when it is unset or empty. Not
    # validated: TCPServer.new gets it as it is ("0.0.0.0" listens on every
    # interface, which a container needs).
    def self.default_host
      configured = ENV["CYBERTRAIN_HOST"] || ""
      configured.empty? ? "127.0.0.1" : configured
    end

    # CYBERTRAIN_SESSION_SAME_SITE, or "Lax" when it is unset or empty.
    def self.default_session_same_site
      configured = ENV["CYBERTRAIN_SESSION_SAME_SITE"] || ""
      configured.empty? ? "Lax" : configured
    end

    # True only for CYBERTRAIN_SESSION_PARTITIONED=1 or =true; any other
    # value is false, not an error.
    def self.default_session_partitioned
      configured = ENV["CYBERTRAIN_SESSION_PARTITIONED"] || ""
      configured == "1" || configured == "true"
    end

    def initialize
      @env = Config.default_env
      @host = Config.default_host
      @port = (ENV["PORT"] || "3000").to_i
      @database_path = Config.default_database_path(@env)
      @secret_key_base = ENV["CYBERTRAIN_SECRET_KEY_BASE"] || ""
      @secret_key_path = "tmp/secret_key"
      @views_root = "app/views"
      @public_root = "public"
      @layout = "layouts/application"
      @log_level = :info
      @session_cookie_name = "_cybertrain_session"
      @session_max_age = 1209600
      # The session cookie's Secure attribute: on in production, which is
      # expected to sit behind a TLS-terminating proxy; off elsewhere, where
      # the server is reached over plain http://. SameSite=None and
      # Partitioned add Secure whatever this says (Cookies.serialize).
      @session_secure = production?
      # SameSite of the session cookie: "Lax", "Strict" or "None" (boot checks
      # it). "None" is for an app shown inside another site's frame, such as an
      # editor's preview; it always adds Secure (Cookies.serialize).
      @session_same_site = Config.default_session_same_site
      # Partitioned (CHIPS): with None, the cookie survives third-party cookie
      # blocking inside such a frame. Adds Secure too.
      @session_partitioned = Config.default_session_partitioned
      @pool_size = 4
      @static_files = true
      @csrf = true
      @workers = (ENV["SPINEL_WORKERS"] || "1").to_i
    end

    def development?
      @env == "development"
    end

    def test?
      @env == "test"
    end

    def production?
      @env == "production"
    end

    # The error Application#boot reports (and exits 1 on) when
    # session_same_site is not a value browsers accept; "" when it is one.
    # Case-sensitive, since the value goes into the header as it is; a chain
    # of ==, not include? (spikes/NOTES.md rules 14 and 29).
    def session_same_site_error
      value = @session_same_site
      return "" if value == "Lax" || value == "Strict" || value == "None"

      "CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got \"#{value}\")"
    end

    # The secret sessions are signed with. Production must set it
    # (CYBERTRAIN_SECRET_KEY_BASE); other environments read secret_key_path,
    # creating it with a random 64-hex-digit key the first time.
    def resolve_secret!
      return @secret_key_base unless @secret_key_base.empty?
      raise "CYBERTRAIN_SECRET_KEY_BASE is not set" if production?

      secret = File.exist?(@secret_key_path) ? File.read(@secret_key_path).strip : ""
      if secret.length != SECRET_LENGTH
        secret = Crypto.random_token(SECRET_LENGTH / 2)
        Config.make_directory(File.dirname(@secret_key_path))
        File.write(@secret_key_path, "#{secret}\n")
      end
      @secret_key_base = secret
    end

    # mkdir -p.
    def self.make_directory(dir)
      return nil if dir == "" || dir == "." || File.directory?(dir)

      make_directory(File.dirname(dir))
      Dir.mkdir(dir)
      nil
    end
  end

  # Module-level ivar, not @@config: spikes/NOTES.md rule 18. Created on
  # first use so it reads the environment of the running process.
  @config = nil

  def self.config
    current = @config
    if current.nil?
      current = Config.new
      @config = current
    end
    current
  end

  def self.config=(config)
    @config = config
  end

  # True once something has created or assigned the process-wide config.
  def self.config_loaded?
    !@config.nil?
  end

  def self.configure(&block)
    block.call(config)
    nil
  end

  def self.env
    config.env
  end
end
```

In `cybertrain/application.rb` (line numbers of the file before these edits), in `boot`, directly after the `end` that closes the embedded-views check (line 95) and before `c.resolve_secret!`, insert:

```ruby
      # config/app.rb has run by now, so the environment variable and
      # `c.session_same_site = ...` are checked together.
      same_site_error = c.session_same_site_error
      unless same_site_error.empty?
        puts "error: #{same_site_error}"
        STDOUT.flush
        exit(1)
      end
```

and in `build_stack` replace the `SessionStore.new` call (lines 284-285) with:

```ruby
      app = SessionStore.new(app, secret: c.resolve_secret!, cookie_name: c.session_cookie_name,
                                  max_age: c.session_max_age, secure: c.session_secure,
                                  same_site: c.session_same_site, partitioned: c.session_partitioned)
```

- [ ] **Step 4: Regenerate the snapshot and run the tests**

```bash
script/regen-snapshot test/application.rb
git diff test/application.rb.expected
spin test test/application.rb test/dev_application.rb test/main.rb test/integration_m1.rb test/template_integration.rb test/session.rb
```

Expected: `test/application.rb.expected` gains four lines and a new last line; the whole file is now:

```
ok   config defaults in development
ok   environment variables override the config defaults
ok   an empty CYBERTRAIN_DATABASE counts as unset
ok   CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE and CYBERTRAIN_SESSION_PARTITIONED override the defaults
ok   empty CYBERTRAIN_HOST and CYBERTRAIN_SESSION_SAME_SITE count as unset; only 1 and true turn partitioning on
ok   session_same_site_error is empty for Lax, Strict and None and names the valid values otherwise
ok   resolve_secret! creates the secret key file in the test env and reuses it
ok   resolve_secret! keeps an explicit secret_key_base
ok   resolve_secret! raises in production when the secret is empty
ok   Cybertrain.configure fills the process-wide config
ok   DB::CLI.database_path follows Cybertrain.config once it is loaded
ok   the stack is RequestLogger, Static, MethodOverride, SessionStore, CsrfProtection, Router
ok   log_level :none, static_files and csrf switch their middleware off
ok   the stack's session cookie follows session_same_site and session_partitioned
ok   production puts ErrorPages outermost
ok   production refuses to boot without embedded views
ok   production boots on the embedded table, development on app/views
ok   boot connects the database, configures views and resolves the secret
ok   a GET renders a template inside the layout
ok   a POST without the CSRF token is forbidden
ok   a POST with the token from the page passes
ok   a _method=delete POST reaches the DELETE route
ok   the session cookie round trips
ok   a static file is served from the public root
ok   path helpers in templates call the url_resolver
ok   a method-returned Gen::Routes-style url_resolver keeps its route names
ok   the server listens on the configured host and port
27 tests, 101 assertions, 0 failures
```

The `spin test` run ends with `6/6 passed`. The boot check's `exit(1)` is not unit-tested (it would end the test program); smoke check F1 (Task 4) runs it in the real binary.

- [ ] **Step 5: Commit**

```bash
git add cybertrain/config.rb cybertrain/application.rb test/application.rb test/application.rb.expected
git commit -m "Config: CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE and CYBERTRAIN_SESSION_PARTITIONED; boot rejects an invalid SameSite

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Version 0.2.1 and the framework's documentation

**Files:**
- Modify: `cybertrain/version.rb` (line 2), `spin.toml` (line 4)
- Modify: `README.md` (line 153; the configuration table and the paragraph after it, lines 504-517; Releasing, lines 618-619)
- Modify: `docs/deploy.md` (lines 160, 237, 326, 334, 737), `site/index.html` (lines 227, 241, 318), `site/tutorial.html` (lines 142, 164, 300)
- Modify: `docs/design.md` (D14, after line 219)
- Modify: `cybertrain/cli/templates.rb` (`config_app`, lines 116-118), `examples/blog/config/app.rb` (lines 1-3)
- Test: `test/integration_m1.rb` (line 18), `test/version.rb.expected` (binary), `test/cli_new.rb.expected` and `test/cli_toolchain.rb.expected` (CRuby)

**Interfaces:**
- Consumes: the variables and attributes Task 2 added (documented here); nothing in code.
- Produces: `Cybertrain::VERSION == "0.2.1"` and `version = "0.2.1"` in `spin.toml`. `cybertrain new` now writes `ref = "v0.2.1"`, which Task 5's image (smoke checks G2, G5, B1, B2) expects. Task 7 appends step 4 to the README's Releasing list that this task edits.

- [ ] **Step 1: Write the failing test**

In `test/integration_m1.rb`, line 18, change `assert_equal "0.2.0", Cybertrain::VERSION` to:

```ruby
  assert_equal "0.2.1", Cybertrain::VERSION
```

- [ ] **Step 2: Run it to verify it fails**

Run: `spin test test/integration_m1.rb`
Expected: `FAIL integration_m1.rb`; its actual output has `FAIL the entry point exposes every M1 feature: expected "0.2.1", got "0.2.0"` and `8 tests, 30 assertions, 1 failures`; last line `0/1 passed`.

- [ ] **Step 3: Bump the version everywhere it is written**

`git grep -n '0\.2\.0' -- . ':!docs/superpowers/'` (re-run on 2026-10-02) lists exactly the places spec §3.9 names. Every `0.2.0` in these six files is the release version, so replace them all:

```bash
perl -pi -e 's/0\.2\.0/0.2.1/g' cybertrain/version.rb spin.toml README.md docs/deploy.md site/index.html site/tutorial.html
git diff --stat
```

Expected: `cybertrain/version.rb` 1 line, `spin.toml` 1, `README.md` 3 (lines 153, 618, 619), `docs/deploy.md` 5, `site/index.html` 3 (line 241 holds two occurrences), `site/tutorial.html` 3, plus `test/integration_m1.rb` from Step 1.

- [ ] **Step 4: Regenerate the snapshots that print the version**

```bash
spin test --regen test/cli_new.rb test/cli_toolchain.rb
script/regen-snapshot test/version.rb
git diff test/cli_new.rb.expected test/cli_toolchain.rb.expected test/version.rb.expected
```

`test/version.rb` requires the whole framework (SQLite through FFI), so its snapshot comes from the binary; the two CLI tests are CRuby-portable. Expected diff, and nothing else: `test/version.rb.expected` becomes `0.2.1`; `test/cli_new.rb.expected` line 200 `cybertrain 0.2.1` and lines 206, 245, 283 `        git tag v0.2.1 of https://github.com/saeki-mototsune/cybertrain`; `test/cli_toolchain.rb.expected` line 5 `note: old/spinel is release 2026.09.08; cybertrain 0.2.1 is pinned to Spinel 2026.09.12 and keeps its own copy in home/spinel/2026.09.12`.

- [ ] **Step 5: Document the three settings**

In `README.md`, replace the table's last row and the paragraph after it (lines 510-517):

```markdown
| `SPINEL_WORKERS` | `workers` | `1` |

Other attributes with fixed, overridable defaults: `host` (`"127.0.0.1"`),
`views_root` (`"app/views"`), `public_root` (`"public"`), `layout`
(`"layouts/application"`), `log_level` (`:info`), `session_cookie_name`,
`session_max_age` (2 weeks), `session_secure` (`true` in production, which
marks the session cookie `Secure`; `false` elsewhere), `pool_size` (4),
`static_files`/`csrf` (`true`).
```

with:

```markdown
| `SPINEL_WORKERS` | `workers` | `1` |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`; `0.0.0.0` listens on every interface (containers) |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`; also `Strict` or `None` (`None` always adds `Secure`); anything else stops the server at boot |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`; `1` or `true` adds `Partitioned` (and `Secure`) |

Use `None` (with `CYBERTRAIN_SESSION_PARTITIONED=1`) only for an app shown
inside another site's frame, such as the playground's Codespaces preview; the
browser must reach the app over HTTPS.

Other attributes with fixed, overridable defaults: `views_root`
(`"app/views"`), `public_root` (`"public"`), `layout`
(`"layouts/application"`), `log_level` (`:info`), `session_cookie_name`,
`session_max_age` (2 weeks), `session_secure` (`true` in production, which
marks the session cookie `Secure`; `false` elsewhere, though `SameSite=None`
and `Partitioned` add `Secure` anyway), `pool_size` (4), `static_files`/`csrf`
(`true`).
```

In `docs/design.md`, directly after line 219 (`- セッション Cookie: production では `Secure` 属性を付ける（`Config#session_secure`、既定は `production?`）。`), insert this line:

```markdown
- セッション Cookie の SameSite は `Config#session_same_site`（既定 `Lax`、`CYBERTRAIN_SESSION_SAME_SITE`、`Lax`/`Strict`/`None` 以外は起動時エラー）、`Partitioned` は `Config#session_partitioned`（既定 false、`CYBERTRAIN_SESSION_PARTITIONED`）。`None` か `Partitioned` のときは `session_secure` に関係なく `Secure`。待ち受けアドレスは `Config#host`（既定 `127.0.0.1`、`CYBERTRAIN_HOST`）。（2026-10-02、web playground SP1）
```

In `cybertrain/cli/templates.rb` (`config_app`), replace lines 116-118:

```ruby
          # Application settings; see Cybertrain::Config for every option.
          # Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
          # CYBERTRAIN_SECRET_KEY_BASE) are read before this block runs.
```

with:

```ruby
          # Application settings; see Cybertrain::Config for every option.
          # Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
          # CYBERTRAIN_SECRET_KEY_BASE, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
          # CYBERTRAIN_SESSION_PARTITIONED) are read before this block runs.
```

In `examples/blog/config/app.rb`, replace lines 1-3 with the same comment without the indentation (it mirrors the template's output; comments only, so `gen/` does not change):

```ruby
# Application settings; see Cybertrain::Config for every option.
# Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
# CYBERTRAIN_SECRET_KEY_BASE, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
# CYBERTRAIN_SESSION_PARTITIONED) are read before this block runs.
```

- [ ] **Step 6: Run the tests and the checks**

```bash
spin test test/integration_m1.rb test/version.rb test/cli_new.rb test/cli_toolchain.rb
version=$(ruby -I. -e 'require "cybertrain/version"; print Cybertrain::VERSION'); grep -q "^version = \"$version\"$" spin.toml && echo "spin.toml matches $version"
git grep -n '0\.2\.0' -- . ':!docs/superpowers/'
(cd examples/blog && spin run gen > /dev/null && git diff --exit-code -- gen/ && echo "examples/blog gen/ unchanged")
```

Expected: `4/4 passed`; `spin.toml matches 0.2.1`; the grep prints only `test/cli_new.rb:175` and `test/cli_new.rb:176`; `examples/blog gen/ unchanged`.

- [ ] **Step 7: Commit**

```bash
git add cybertrain/version.rb spin.toml README.md docs/deploy.md docs/design.md site/index.html site/tutorial.html cybertrain/cli/templates.rb examples/blog/config/app.rb test/integration_m1.rb test/version.rb.expected test/cli_new.rb.expected test/cli_toolchain.rb.expected
git commit -m "Version 0.2.1; document CYBERTRAIN_HOST and the session cookie's SameSite and Partitioned

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `playground/smoke.sh`, the image's test harness

**Files:**
- Create: `playground/smoke.sh`
- Test: the harness itself (usage, and a clean failure against an image without the playground)

**Interfaces:**
- Consumes: the image layout and the `Set-Cookie` endings in the Global Constraints; `cybertrain/version.rb` (it reads `VERSION` from `../cybertrain/version.rb` relative to itself).
- Produces: `bash playground/smoke.sh IMAGE` → one `PASS <ID> <what>` or `FAIL <ID> <what> (<detail>)` line per check (26 checks: G1-G7, A1-A10, D1-D2, C1-C2, F1, E1, B1-B3), then `smoke: N passed, M failed`; exit 0 when all pass, 1 otherwise, 2 for bad usage. Task 5 adds D3, D4 and C3 and moves B2 to `/workspace` by editing these exact lines: `what_D2="exactly one app server process runs"`, `what_C2="with CODESPACES=true the banner shows https://smoke-3000.app.github.dev/"`, `what_B2="with no network, cybertrain new works in /tmp and locks the blog's commit"`, the D2 block ending in `fail D2 "$what_D2" "pgrep counted ${servers:-nothing}" "$main"`, `  for id in A2 A3 A4 A5 A6 A7 A8 A9 A10 D1 D2; do`, the comment lines `# ---- C: the Codespaces settings ...` and `# ---- F: the boot check ...`, and `cd /tmp || exit 1`. Task 6's workflow runs `bash playground/smoke.sh cybertrain-playground:ci`.

The spec's check table (§8.2) has 26 rows, not 25: G1-G7 (7), A1-A10 (10), D1-D2 (2), C1-C2 (2), F1, E1, B1-B3 (3).

- [ ] **Step 1: Write the failing test**

The harness is trusted only once two behaviours hold, so they are its tests:

```bash
bash playground/smoke.sh; echo "exit=$?"
docker pull ubuntu:24.04 && bash playground/smoke.sh ubuntu:24.04 > "${TMPDIR:-/tmp}/smoke-negative.log" 2>&1; echo "exit=$?"
```

The first must print `usage: bash playground/smoke.sh IMAGE` and `exit=2`. The second runs every check against an image that lacks the playground: it must end with `exit=1`, report `smoke: 0 passed, 26 failed`, and show no bash error (no line matching `smoke.sh: line [0-9]*:`).

- [ ] **Step 2: Run them to verify they fail**

Run: `bash playground/smoke.sh; echo "exit=$?"`
Expected: `bash: playground/smoke.sh: No such file or directory` and `exit=127`.

- [ ] **Step 3: Implement**

Create `playground/smoke.sh` (the time limits of spec §8.2 are enforced by `run_once` and the polling loops, since macOS hosts have no `timeout`; inside containers `timeout` exists and bounds D1):

```bash
#!/usr/bin/env bash
# playground/smoke.sh IMAGE -- the smoke test of a playground image
# (playground/Dockerfile, target playground). CI runs it on every build
# before anything is pushed (.github/workflows/playground-image.yml); after a
# local build:
#
#   bash playground/smoke.sh cybertrain-playground:local
#
# One line per check, "PASS <ID> <what>" or "FAIL <ID> <what> (<detail>)",
# then "smoke: N passed, M failed". After a failure it prints the last 40
# lines of every container or command involved and exits 1; it exits 0 when
# every check passes and 2 without an IMAGE. Groups: G the image as built,
# A the default command serving the blog to the host and the edit loop,
# D playground-server started again, C the Codespaces settings, F the boot
# check of CYBERTRAIN_SESSION_SAME_SITE, E a cp -a copy of the blog, B no
# network. playground/README.md lists every check.
#
# The host needs bash 3.2 or newer (no associative arrays, no date +%N:
# macOS's /bin/bash works), docker and curl. The expected version is read
# from ../cybertrain/version.rb. Every container it starts is removed when it
# exits.
set -u

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: bash playground/smoke.sh IMAGE" >&2
  exit 2
fi
image=$1
here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n 's/^ *VERSION = "\([^"]*\)".*/\1/p' "$here/../cybertrain/version.rb" | head -n 1)
if [ -z "$version" ]; then
  echo "smoke: no VERSION in $here/../cybertrain/version.rb" >&2
  exit 2
fi

prefix="playground-smoke-$$"
work=$(mktemp -d "${TMPDIR:-/tmp}/playground-smoke.XXXXXX") || exit 2
containers=""
passed=0
failed=0
show=""
out=""
rc=0
detail=""

cleanup() {
  # One container name per word: the unquoted expansion is intended.
  if [ -n "$containers" ]; then
    docker rm -f $containers > /dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

what_G1="the user is dev, uid 1000"
what_G2="cybertrain version prints cybertrain $version"
what_G3="cybertrain doctor exits 0"
what_G4="CYBERTRAIN_HOME and XDG_CACHE_HOME point under /opt and CYBERTRAIN_HOST is unset"
what_G5="the blog's spin.toml depends on the tag v$version"
what_G6="the blog is a clean git repository with one commit that tracks PLAYGROUND.md"
what_G7="no tmp/secret_key is baked in and build/bin/blog is executable"
what_A1="GET /articles through the published port answers 200 (default command, CYBERTRAIN_HOST=0.0.0.0)"
what_A2="the log shows the boot banner of $version listening on http://0.0.0.0:3000"
what_A3="starting compiled nothing (build/bin/blog keeps the image's mtime)"
what_A4="GET / answers 200 with <h1>Articles</h1>"
what_A5="GET /articles/new has a CSRF token and a SameSite=Lax session cookie without Secure or Partitioned"
what_A6="POST /articles with the token and the cookie answers 303 to the new article, whose page shows it"
what_A7="POST /articles without token or cookie answers 403"
what_A8="a view edit shows on the next request"
what_A9="a model edit rebuilds and restarts the server: a short body then answers 422"
what_A10="the running container generated tmp/secret_key"
what_D1="a second playground-server exits 0 saying the server is already running"
what_D2="exactly one app server process runs"
what_C1="with CODESPACES=true the session cookie is SameSite=None; Secure; Partitioned"
what_C2="with CODESPACES=true the banner shows https://smoke-3000.app.github.dev/"
what_F1="CYBERTRAIN_SESSION_SAME_SITE=lax stops the server at boot and names the valid values"
what_E1="a cp -a copy of the blog started by playground-server compiles nothing"
what_B1="with no network, git ls-remote of the repository URL lists refs/tags/v$version (the mirror)"
what_B2="with no network, cybertrain new works in /tmp and locks the blog's commit"
what_B3="with no network, the new app builds"

pass() {
  passed=$((passed + 1))
  echo "PASS $1 $2"
}

# fail ID WHAT DETAIL [WHERE]: WHERE is a container name, or out:ID for the
# saved output of `run_once ... ID`; its last lines are printed at the end.
fail() {
  failed=$((failed + 1))
  echo "FAIL $1 $2 ($3)"
  if [ "$#" -ge 4 ]; then
    case " $show " in
      *" $4 "*) ;;
      *) show="$show $4" ;;
    esac
  fi
}

first_line() {
  printf '%s\n' "$1" | head -n 1
}

# run_once SECONDS ID [docker run options] IMAGE [COMMAND...]: a one-shot
# container (docker run --rm, named $prefix-ID) given at most SECONDS. Sets
# $out (its stdout and stderr, also kept in $work/ID.out) and $rc (its exit
# status; 124 when it ran out of time and was removed).
run_once() {
  local limit=$1 id=$2
  shift 2
  local name="$prefix-$id"
  local log="$work/$id.out"
  local began=$SECONDS
  containers="$containers $name"
  docker run --rm --name "$name" "$@" < /dev/null > "$log" 2>&1 &
  local pid=$!
  rc=""
  while kill -0 "$pid" 2> /dev/null; do
    if [ $((SECONDS - began)) -ge "$limit" ]; then
      docker rm -f "$name" > /dev/null 2>&1
      wait "$pid" 2> /dev/null
      echo "(timed out after $limit s)" >> "$log"
      rc=124
      break
    fi
    sleep 0.5
  done
  if [ -z "$rc" ]; then
    wait "$pid"
    rc=$?
  fi
  out=$(cat "$log")
}

# start ID [docker run options] IMAGE [COMMAND...]: a detached container named
# $prefix-ID, run with --init. Returns docker run's exit status; its output is
# in $work/ID.start.
start() {
  local id=$1
  shift
  containers="$containers $prefix-$id"
  docker run -d --init --name "$prefix-$id" "$@" > "$work/$id.start" 2>&1
}

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null)" = "true" ]
}

# The host port docker published for the container's port 3000.
host_port() {
  docker port "$1" 3000/tcp 2> /dev/null | head -n 1 | sed 's/.*://'
}

# up_inside CONTAINER SECONDS: waits until GET /articles answers 200 inside
# CONTAINER, whose server listens on 127.0.0.1. Sets $detail when it fails.
up_inside() {
  local began=$SECONDS
  while [ $((SECONDS - began)) -lt "$2" ]; do
    if [ "$(docker exec "$1" curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:3000/articles 2> /dev/null)" = "200" ]; then
      return 0
    fi
    if ! running "$1"; then
      detail="the container exited"
      return 1
    fi
    sleep 0.5
  done
  detail="no 200 from /articles within $2 s"
  return 1
}

# The authenticity_token of the form saved in file $1.
form_token() {
  sed -n 's/.*name="authenticity_token" value="\([^"]*\)".*/\1/p' "$1" 2> /dev/null | head -n 1
}

# header FILE NAME: the value of the first NAME header in curl's -D dump FILE.
header() {
  grep -i "^$2:" "$1" 2> /dev/null | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//'
}

echo "smoke: $image, expecting cybertrain $version"

# ---- G: the image as built -------------------------------------------------

run_once 30 G1 "$image" sh -c 'echo "$(id -un) $(id -u)"'
if [ "$rc" = 0 ] && [ "$out" = "dev 1000" ]; then
  pass G1 "$what_G1"
else
  fail G1 "$what_G1" "got: $(first_line "$out")" out:G1
fi

run_once 30 G2 "$image" cybertrain version
if [ "$rc" = 0 ] && [ "$out" = "cybertrain $version" ]; then
  pass G2 "$what_G2"
else
  fail G2 "$what_G2" "exit $rc: $(first_line "$out")" out:G2
fi

run_once 60 G3 "$image" cybertrain doctor
if [ "$rc" = 0 ]; then
  pass G3 "$what_G3"
else
  fail G3 "$what_G3" "exit $rc" out:G3
fi

run_once 30 G4 "$image" sh -c 'echo "${CYBERTRAIN_HOME-}|${XDG_CACHE_HOME-}|${CYBERTRAIN_HOST-unset}"'
if [ "$rc" = 0 ] && [ "$out" = "/opt/cybertrain|/opt/cybertrain-cache|unset" ]; then
  pass G4 "$what_G4"
else
  fail G4 "$what_G4" "got: $(first_line "$out")" out:G4
fi

dependency="cybertrain = { git = \"https://github.com/saeki-mototsune/cybertrain\", ref = \"v$version\" }"
run_once 30 G5 "$image" grep -F "$dependency" /workspace/blog/spin.toml
if [ "$rc" = 0 ]; then
  pass G5 "$what_G5"
else
  fail G5 "$what_G5" "no line: $dependency" out:G5
fi

run_once 30 G6 "$image" sh -c 'cd /workspace/blog && echo "status=[$(git status --porcelain)] commits=$(git rev-list --count HEAD) guide=$(git ls-files PLAYGROUND.md)"'
if [ "$rc" = 0 ] && [ "$out" = "status=[] commits=1 guide=PLAYGROUND.md" ]; then
  pass G6 "$what_G6"
else
  fail G6 "$what_G6" "got: $(first_line "$out")" out:G6
fi

run_once 30 G7 "$image" sh -c 'if [ -e /workspace/blog/tmp/secret_key ]; then echo "tmp/secret_key exists"; exit 1; fi; if [ ! -x /workspace/blog/build/bin/blog ]; then echo "build/bin/blog is missing or not executable"; exit 1; fi'
if [ "$rc" = 0 ]; then
  pass G7 "$what_G7"
else
  fail G7 "$what_G7" "$(first_line "$out")" out:G7
fi

# The prebuilt binary's mtime, which A3 and E1 compare against.
run_once 30 mtime "$image" stat -c %Y /workspace/blog/build/bin/blog
image_mtime=""
if [ "$rc" = 0 ]; then
  image_mtime=$out
fi

# ---- A: the default command, reached from the host, and the edit loop ------

main="$prefix-main"
main_up=no
title=""
base=""
if start main -p 127.0.0.1::3000 -e CYBERTRAIN_HOST=0.0.0.0 "$image"; then
  launched=$SECONDS
  port=$(host_port "$main")
  base="http://127.0.0.1:$port"
  detail="no 200 within 30 s"
  while [ $((SECONDS - launched)) -lt 30 ]; do
    if [ -n "$port" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$base/articles")" = "200" ]; then
      main_up=yes
      break
    fi
    if ! running "$main"; then
      detail="the container exited"
      break
    fi
    sleep 0.5
  done
else
  detail="docker run failed: $(first_line "$(cat "$work/main.start")")"
fi

if [ "$main_up" = yes ]; then
  pass A1 "$what_A1"

  logs=$(docker logs "$main" 2>&1)
  case "$logs" in
    *"=> Booting cybertrain $version"*"* Listening on http://0.0.0.0:3000"*) pass A2 "$what_A2" ;;
    *) fail A2 "$what_A2" "the banner lines are not in docker logs" "$main" ;;
  esac

  running_mtime=$(docker exec "$main" stat -c %Y /workspace/blog/build/bin/blog 2> /dev/null)
  if [ -n "$image_mtime" ] && [ "$running_mtime" = "$image_mtime" ]; then
    pass A3 "$what_A3"
  else
    fail A3 "$what_A3" "image: ${image_mtime:-unknown}, running: ${running_mtime:-unknown}" "$main"
  fi

  code=$(curl -s -o "$work/a4.html" -w '%{http_code}' --max-time 5 "$base/")
  if [ "$code" = 200 ] && grep -qF '<h1>Articles</h1>' "$work/a4.html"; then
    pass A4 "$what_A4"
  else
    fail A4 "$what_A4" "status $code" "$main"
  fi

  jar="$work/session.jar"
  code=$(curl -s -c "$jar" -D "$work/a5.head" -o "$work/a5.html" -w '%{http_code}' --max-time 5 "$base/articles/new")
  token=$(form_token "$work/a5.html")
  cookie=$(header "$work/a5.head" set-cookie)
  case "$cookie" in
    *"; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600") cookie_ok=yes ;;
    *) cookie_ok=no ;;
  esac
  if [ "$code" = 200 ] && [ "${#token}" -ge 32 ] && [ "$cookie_ok" = yes ]; then
    pass A5 "$what_A5"
  else
    fail A5 "$what_A5" "status $code, token of ${#token} characters, Set-Cookie: $cookie" "$main"
  fi

  title="Smoke $(date +%s)"
  code=$(curl -s -b "$jar" -c "$jar" -D "$work/a6.head" -o /dev/null -w '%{http_code}' --max-time 5 \
    --data-urlencode "authenticity_token=$token" \
    --data-urlencode "article[title]=$title" \
    --data-urlencode "article[body]=A body that is long enough." \
    "$base/articles")
  location=$(header "$work/a6.head" location)
  shown=000
  case "$location" in
    /articles/[0-9]*) shown=$(curl -s -b "$jar" -o "$work/a6.html" -w '%{http_code}' --max-time 5 "$base$location") ;;
  esac
  if [ "$code" = 303 ] && [ "$shown" = 200 ] && grep -qF "$title" "$work/a6.html"; then
    pass A6 "$what_A6"
  else
    fail A6 "$what_A6" "status $code, Location: $location, then $shown" "$main"
    title=""
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --data-urlencode "article[title]=No token" "$base/articles")
  if [ "$code" = 403 ]; then
    pass A7 "$what_A7"
  else
    fail A7 "$what_A7" "status $code" "$main"
  fi

  docker exec "$main" sh -c 'echo "<p id=\"smoke-view-edit\">view edit</p>" >> /workspace/blog/app/views/articles/index.html.erb'
  seen=no
  for attempt in 1 2 3 4 5 6; do
    if curl -s --max-time 2 "$base/articles" | grep -qF 'smoke-view-edit'; then
      seen=yes
      break
    fi
    sleep 0.5
  done
  if [ "$seen" = yes ]; then
    pass A8 "$what_A8"
  else
    fail A8 "$what_A8" "the edit did not show within 3 s" "$main"
  fi

  docker exec "$main" sed -i 's/^class Article$/&\n  validates :body, presence: true, length: { minimum: 10 }/' /workspace/blog/app/models/article.rb
  edited=$(docker exec "$main" grep -c 'validates :body' /workspace/blog/app/models/article.rb 2> /dev/null)
  short=000
  deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    rm -f "$work/a9.jar" "$work/a9.html"
    probe=$(curl -s -c "$work/a9.jar" -o "$work/a9.html" -w '%{http_code}' --max-time 5 "$base/articles/new")
    probe_token=$(form_token "$work/a9.html")
    if [ "$probe" = 200 ] && [ -n "$probe_token" ]; then
      short=$(curl -s -b "$work/a9.jar" -o /dev/null -w '%{http_code}' --max-time 5 \
        --data-urlencode "authenticity_token=$probe_token" \
        --data-urlencode "article[title]=Short body $(date +%s)" \
        --data-urlencode "article[body]=short" \
        "$base/articles")
      if [ "$short" = 422 ]; then
        break
      fi
    fi
    sleep 3
  done
  logs=$(docker logs "$main" 2>&1)
  case "$logs" in
    *"Build succeeded"*) built=yes ;;
    *) built=no ;;
  esac
  listed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base/articles")
  if [ "$short" = 422 ] && [ "$built" = yes ] && [ "$listed" = 200 ]; then
    pass A9 "$what_A9"
  else
    fail A9 "$what_A9" "validates :body lines: ${edited:-0}, short body: $short, Build succeeded logged: $built, GET /articles: $listed" "$main"
  fi

  if docker exec "$main" test -s /workspace/blog/tmp/secret_key; then
    pass A10 "$what_A10"
  else
    fail A10 "$what_A10" "no tmp/secret_key in the container" "$main"
  fi

  # ---- D: playground-server started again ----------------------------------

  again=$(docker exec "$main" timeout 10 playground-server 2>&1)
  again_rc=$?
  case "$again" in
    *"already running"*) said=yes ;;
    *) said=no ;;
  esac
  if [ "$again_rc" = 0 ] && [ "$said" = yes ]; then
    pass D1 "$what_D1"
  else
    fail D1 "$what_D1" "exit $again_rc: $(first_line "$again")" "$main"
  fi

  servers=$(docker exec "$main" pgrep -c -f '^/workspace/blog/build/bin/blog( |$)' 2> /dev/null)
  if [ "$servers" = 1 ]; then
    pass D2 "$what_D2"
  else
    fail D2 "$what_D2" "pgrep counted ${servers:-nothing}" "$main"
  fi
else
  fail A1 "$what_A1" "$detail" "$main"
  for id in A2 A3 A4 A5 A6 A7 A8 A9 A10 D1 D2; do
    name="what_$id"
    fail "$id" "${!name}" "skipped: the dev server did not come up"
  done
fi

# ---- C: the Codespaces settings --------------------------------------------

codespace="$prefix-codespace"
if start codespace -e CODESPACES=true -e CODESPACE_NAME=smoke -e GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=app.github.dev "$image"; then
  if up_inside "$codespace" 30; then
    cookie=$(docker exec "$codespace" curl -s -D - -o /dev/null --max-time 5 http://127.0.0.1:3000/articles/new 2> /dev/null |
      grep -i '^set-cookie:' | head -n 1 | tr -d '\r' | sed 's/^[^:]*: *//')
    case "$cookie" in
      *"; Path=/; HttpOnly; SameSite=None; Max-Age=1209600; Secure; Partitioned") pass C1 "$what_C1" ;;
      *) fail C1 "$what_C1" "Set-Cookie: $cookie" "$codespace" ;;
    esac
  else
    fail C1 "$what_C1" "$detail" "$codespace"
  fi
else
  fail C1 "$what_C1" "docker run failed: $(first_line "$(cat "$work/codespace.start")")"
fi
case "$(docker logs "$codespace" 2>&1)" in
  *"https://smoke-3000.app.github.dev/"*) pass C2 "$what_C2" ;;
  *) fail C2 "$what_C2" "the URL is not in the banner" "$codespace" ;;
esac

# ---- F: the boot check -----------------------------------------------------

run_once 60 F1 -e CYBERTRAIN_SESSION_SAME_SITE=lax "$image"
case "$out" in
  *'must be Lax, Strict or None (got "lax")'*) named=yes ;;
  *) named=no ;;
esac
if [ "$rc" != 0 ] && [ "$named" = yes ]; then
  pass F1 "$what_F1"
else
  fail F1 "$what_F1" "exit $rc" out:F1
fi

# ---- E: a cp -a copy of the blog -------------------------------------------
# The premise of the Codespaces fallback that copies the blog to /workspaces.

copy="$prefix-copy"
if start copy "$image" bash -c 'cp -a /workspace/blog /tmp/blog-copy && exec playground-server /tmp/blog-copy'; then
  if up_inside "$copy" 30; then
    copy_mtime=$(docker exec "$copy" stat -c %Y /tmp/blog-copy/build/bin/blog 2> /dev/null)
    if [ -n "$image_mtime" ] && [ "$copy_mtime" = "$image_mtime" ]; then
      pass E1 "$what_E1"
    else
      fail E1 "$what_E1" "image: ${image_mtime:-unknown}, copy: ${copy_mtime:-unknown}" "$copy"
    fi
  else
    fail E1 "$what_E1" "$detail" "$copy"
  fi
else
  fail E1 "$what_E1" "docker run failed: $(first_line "$(cat "$work/copy.start")")"
fi

# ---- B: no network ---------------------------------------------------------

run_once 30 B1 --network none "$image" git ls-remote https://github.com/saeki-mototsune/cybertrain
case "$out" in
  *"refs/tags/v$version"*) tagged=yes ;;
  *) tagged=no ;;
esac
if [ "$rc" = 0 ] && [ "$tagged" = yes ]; then
  pass B1 "$what_B1"
else
  fail B1 "$what_B1" "exit $rc: $(first_line "$out")" out:B1
fi

# B2 and B3 share one container: B3 builds the app B2 creates. The script
# runs inside it and prints one "B2 ..." and one "B3 ..." line.
offline='
began=$SECONDS
cd /tmp || exit 1
if ! cybertrain new offline > /tmp/smoke-new.log 2>&1; then
  echo "B2 FAIL cybertrain new offline failed: $(tail -n 2 /tmp/smoke-new.log | tr "\n" " ")"
  echo "B3 FAIL skipped: there is no app"
  exit 0
fi
took=$((SECONDS - began))
cd offline || exit 1
if [ "$took" -gt 180 ]; then
  echo "B2 FAIL cybertrain new took $took s (limit 180 s)"
elif ! grep -qF "ref = \"v$SMOKE_VERSION\"" spin.toml; then
  echo "B2 FAIL spin.toml has no ref = \"v$SMOKE_VERSION\""
elif ! cmp -s spin.lock /workspace/blog/spin.lock; then
  echo "B2 FAIL spin.lock differs from /workspace/blog/spin.lock"
else
  echo "B2 PASS"
fi
if cybertrain spin build offline > /tmp/smoke-build.log 2>&1 && [ -x build/bin/offline ]; then
  echo "B3 PASS"
else
  echo "B3 FAIL cybertrain spin build offline failed: $(tail -n 2 /tmp/smoke-build.log | tr "\n" " ")"
fi
'
run_once 420 B23 --network none -e "SMOKE_VERSION=$version" "$image" bash -c "$offline"
for id in B2 B3; do
  name="what_$id"
  line=$(printf '%s\n' "$out" | grep "^$id " | head -n 1)
  if [ "$line" = "$id PASS" ]; then
    pass "$id" "${!name}"
  else
    reason=${line#"$id FAIL "}
    if [ -z "$reason" ]; then
      reason="exit $rc"
    fi
    fail "$id" "${!name}" "$reason" out:B23
  fi
done

# ---- summary ---------------------------------------------------------------

echo "smoke: $passed passed, $failed failed"
if [ "$failed" -eq 0 ]; then
  exit 0
fi
for where in $show; do
  case "$where" in
    out:*)
      echo "--- output of ${where#out:} (last 40 lines)"
      tail -n 40 "$work/${where#out:}.out"
      ;;
    *)
      echo "--- docker logs $where (last 40 lines)"
      docker logs --tail 40 "$where" 2>&1
      ;;
  esac
done
exit 1
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
/bin/bash -n playground/smoke.sh && bash -n playground/smoke.sh && echo "parses"
bash playground/smoke.sh; echo "exit=$?"
bash playground/smoke.sh ubuntu:24.04 > "${TMPDIR:-/tmp}/smoke-negative.log" 2>&1; echo "exit=$?"
grep -c '^PASS ' "${TMPDIR:-/tmp}/smoke-negative.log"
grep -c '^FAIL ' "${TMPDIR:-/tmp}/smoke-negative.log"
grep '^smoke: ' "${TMPDIR:-/tmp}/smoke-negative.log"
grep -E 'smoke\.sh: line [0-9]+:' "${TMPDIR:-/tmp}/smoke-negative.log"; echo "bash errors grep exit=$?"
docker ps -a --filter name=playground-smoke- --format '{{.Names}}'
```

Expected: `parses` (on macOS `/bin/bash` is bash 3.2; on Linux both are bash 5); the usage line and `exit=2`; `exit=1`; `0`; `26`; `smoke: ubuntu:24.04, expecting cybertrain 0.2.1` (`0.2.0` if Task 3 has not run yet) and `smoke: 0 passed, 26 failed`; `bash errors grep exit=1` (no bash error lines); no container left (the last command prints nothing). A1 reports `(the container exited)` and A2-A10, D1-D2 report `(skipped: the dev server did not come up)`. With `ubuntu:24.04` already pulled the run takes under a minute.

- [ ] **Step 5: Commit**

```bash
git add playground/smoke.sh
git commit -m "Playground: smoke test for the image

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The playground image

**Files:**
- Create: `playground/Dockerfile`, `playground/Dockerfile.dockerignore`
- Create: `playground/routes.rb`, `playground/PLAYGROUND.md`
- Create: `playground/playground-server` (git mode 755), `playground/profile.sh`
- Modify: `playground/smoke.sh` (checks D3, D4, C3; B2 and B3 run in `/workspace`)
- Test: `bash playground/smoke.sh cybertrain-playground:local`

**Interfaces:**
- Consumes: Tasks 1-3 committed (the image's mirror is HEAD: the boot check, the cookie settings and version 0.2.1 come from it); `playground/smoke.sh` from Task 4 and its lines named there.
- Produces: the local image `cybertrain-playground:local` with the layout in the Global Constraints; `playground-server [APP_DIR]` (prints `playground-server: the dev server is already running: <url>` when its lock is held, `playground-server: port <port> is already in use, so no second server is started: <url>` when the port is busy, both exit 0); `/workspace/blog/PLAYGROUND.md`; the default command `playground-server`. Task 6 points `.devcontainer/devcontainer.json` at the published image and runs `playground/Dockerfile` in CI; Task 9 edits `PLAYGROUND.md` and the banner if a live-check row fails.

- [ ] **Step 1: Write the failing checks (Review Focus 1-4)**

Make these edits to `playground/smoke.sh`.

After the line `what_D2="exactly one app server process runs"` add:

```bash
what_D3="after a container restart (Codespaces' idle stop and resume) the server is back, once, with the earlier article"
what_D4="playground-server leaves a server started by hand alone: it says the port is in use, exits 0, and one server runs"
```

After the line `what_C2="with CODESPACES=true the banner shows https://smoke-3000.app.github.dev/"` add:

```bash
what_C3="with CODESPACES=true, interactive and login bash shells get the cookie settings"
```

Replace the line `what_B2="with no network, cybertrain new works in /tmp and locks the blog's commit"` with:

```bash
what_B2="with no network, cybertrain new works in /workspace (next to the blog) and locks the blog's commit"
```

Replace

```bash
    fail D2 "$what_D2" "pgrep counted ${servers:-nothing}" "$main"
  fi
else
```

with

```bash
    fail D2 "$what_D2" "pgrep counted ${servers:-nothing}" "$main"
  fi

  # Codespaces stops an idle codespace and starts the same container again:
  # the lock file and tmp/secret_key from the first run are still there.
  docker restart -t 10 "$main" > /dev/null 2>&1
  restarted=$SECONDS
  port=$(host_port "$main")
  base="http://127.0.0.1:$port"
  back=no
  while [ $((SECONDS - restarted)) -lt 30 ]; do
    if [ -n "$port" ] && [ "$(curl -s -o "$work/d3.html" -w '%{http_code}' --max-time 2 "$base/articles")" = "200" ]; then
      back=yes
      break
    fi
    if ! running "$main"; then
      break
    fi
    port=$(host_port "$main")
    base="http://127.0.0.1:$port"
    sleep 0.5
  done
  kept=yes
  if [ -n "$title" ] && ! grep -qF "$title" "$work/d3.html" 2> /dev/null; then
    kept=no
  fi
  servers=$(docker exec "$main" pgrep -c -f '^/workspace/blog/build/bin/blog( |$)' 2> /dev/null)
  if [ "$back" = yes ] && [ "$kept" = yes ] && [ "$servers" = 1 ]; then
    pass D3 "$what_D3"
  else
    fail D3 "$what_D3" "answered 200: $back, article kept: $kept, servers: ${servers:-none}" "$main"
  fi
else
```

Replace `  for id in A2 A3 A4 A5 A6 A7 A8 A9 A10 D1 D2; do` with:

```bash
  for id in A2 A3 A4 A5 A6 A7 A8 A9 A10 D1 D2 D3; do
```

Directly before the line `# ---- C: the Codespaces settings --------------------------------------------` insert:

```bash
# A server started by hand (PLAYGROUND.md's tutorial step restarts it with
# `cybertrain server`) holds port 3000 without playground-server's lock; the
# next attach runs playground-server, which must leave it alone.
manual="$prefix-manual"
if start manual "$image" bash -c 'cd /workspace/blog && exec cybertrain server'; then
  if up_inside "$manual" 30; then
    again=$(docker exec "$manual" timeout 10 playground-server 2>&1)
    again_rc=$?
    servers=$(docker exec "$manual" pgrep -c -f '^/workspace/blog/build/bin/blog( |$)' 2> /dev/null)
    case "$again" in
      *"is already in use"*) said=yes ;;
      *) said=no ;;
    esac
    if [ "$again_rc" = 0 ] && [ "$said" = yes ] && [ "$servers" = 1 ]; then
      pass D4 "$what_D4"
    else
      fail D4 "$what_D4" "exit $again_rc, servers: ${servers:-none}: $(first_line "$again")" "$manual"
    fi
  else
    fail D4 "$what_D4" "$detail" "$manual"
  fi
else
  fail D4 "$what_D4" "docker run failed: $(first_line "$(cat "$work/manual.start")")"
fi

```

Directly before the line `# ---- F: the boot check -----------------------------------------------------` insert:

```bash
# A terminal the visitor opens, interactive or login bash, must carry the
# same settings, or a server started by hand answers 403 in the preview.
run_once 30 C3 -e CODESPACES=true "$image" bash -c 'bash -ic "echo IC=\$CYBERTRAIN_SESSION_SAME_SITE/\$CYBERTRAIN_SESSION_PARTITIONED" 2> /dev/null; bash -lc "echo LC=\$CYBERTRAIN_SESSION_SAME_SITE/\$CYBERTRAIN_SESSION_PARTITIONED" 2> /dev/null'
case "$out" in
  *"IC=None/1"*) interactive=yes ;;
  *) interactive=no ;;
esac
case "$out" in
  *"LC=None/1"*) login=yes ;;
  *) login=no ;;
esac
if [ "$rc" = 0 ] && [ "$interactive" = yes ] && [ "$login" = yes ]; then
  pass C3 "$what_C3"
else
  fail C3 "$what_C3" "interactive: $interactive, login: $login" out:C3
fi

```

Replace `cd /tmp || exit 1` (inside the `offline=` script) with `cd /workspace || exit 1`. The smoke test now has 29 checks.

- [ ] **Step 2: Run them to verify they fail**

```bash
/bin/bash -n playground/smoke.sh && echo "parses"
docker image inspect cybertrain-playground:local > /dev/null 2>&1 && echo "an old image exists" || echo "no image yet"
bash playground/smoke.sh cybertrain-playground:local 2>&1 | grep '^smoke: '
```

Expected: `parses`; `no image yet`; `smoke: 0 passed, 29 failed` (every `docker run` fails: there is no such image yet). If an image with that tag already exists from an earlier attempt, the counts differ; go on.

- [ ] **Step 3: Write the Dockerfile and its build-context file**

Create `playground/Dockerfile` (spec §4.1, verbatim):

```dockerfile
# syntax=docker/dockerfile:1
#
# The cybertrain playground image: Ubuntu 24.04, the cybertrain CLI and
# Spinel built from this checkout, a bare mirror of this repository for
# `cybertrain new`, and the tutorial blog prebuilt in /workspace/blog.
# .devcontainer/devcontainer.json (GitHub Codespaces) runs it; CI publishes
# it as ghcr.io/saeki-mototsune/cybertrain-playground. See playground/README.md.
#
#   docker build -f playground/Dockerfile --target playground -t cybertrain-playground .
#
# Always name the target: a later stage adds a browser editor.
# The context is the repository root and must hold the .git directory (a
# clone, not a git worktree, whose .git is a file): the mirror is made from
# it through a bind mount, so .git never lands in a layer.

ARG BASE_IMAGE=ubuntu:24.04

# ---------------------------------------------------------------------------
# Exactly the files cybertrain.gemspec packages, so that a change to the
# framework alone keeps the gem and Spinel layers cached. A file added to
# spec.files must be added here too (gem build fails otherwise).
FROM scratch AS cli-src
COPY cybertrain.gemspec README.md /src/
COPY exe/cybertrain /src/exe/
COPY cybertrain/version.rb cybertrain/cli.rb /src/cybertrain/
COPY cybertrain/cli/ /src/cybertrain/cli/
COPY cybertrain/generator/inflector.rb /src/cybertrain/generator/

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS toolchain

LABEL org.opencontainers.image.source="https://github.com/saeki-mototsune/cybertrain" \
      org.opencontainers.image.title="cybertrain-playground" \
      org.opencontainers.image.description="Try cybertrain without installing it: Spinel, the cybertrain CLI and the tutorial blog, prebuilt." \
      org.opencontainers.image.licenses="MIT"

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    CYBERTRAIN_HOME=/opt/cybertrain \
    XDG_CACHE_HOME=/opt/cybertrain-cache \
    PATH=/opt/cybertrain/bin:${PATH}

# Ruby 3.2 for the CLI, a C toolchain, make, git, curl and the SQLite headers
# (what `cybertrain doctor` checks); gcc + libc6-dev rather than
# build-essential (no g++). procps: ps/pgrep for terminals and smoke.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git gcc make libc6-dev libsqlite3-dev procps ruby \
 && rm -rf /var/lib/apt/lists/*

# User dev, uid/gid 1000 (ubuntu:24.04 ships "ubuntu" with 1000: removed
# first). Nothing the prebuilt app needs lives in its home directory.
RUN set -eux; \
    if getent passwd 1000 >/dev/null; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi; \
    if getent group 1000 >/dev/null; then groupdel "$(getent group 1000 | cut -d: -f1)"; fi; \
    groupadd --gid 1000 dev; \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev; \
    install -d -o dev -g dev /opt/cybertrain /opt/cybertrain-cache /opt/cybertrain-mirror /workspace

# `cybertrain new` writes git = "https://github.com/saeki-mototsune/cybertrain";
# these rules make git (and so spin) clone the mirror below instead.
RUN git config --system url."file:///opt/cybertrain-mirror/cybertrain.git".insteadOf \
        "https://github.com/saeki-mototsune/cybertrain" \
 && git config --system --add url."file:///opt/cybertrain-mirror/cybertrain.git".insteadOf \
        "https://github.com/saeki-mototsune/cybertrain.git"

# The CLI gem, built from this checkout's cybertrain.gemspec (not rubygems.org).
RUN --mount=type=bind,from=cli-src,source=/src,target=/tmp/cli-src \
    cd /tmp/cli-src \
 && gem build cybertrain.gemspec --output /tmp/cybertrain.gem \
 && gem install --local --no-document /tmp/cybertrain.gem \
 && rm /tmp/cybertrain.gem \
 && cybertrain version

USER dev
WORKDIR /home/dev

# Spinel (Cybertrain::SPINEL_TAG) into $CYBERTRAIN_HOME: the slow step
# (41.5 s on 10 CPUs in the spike).
RUN cybertrain setup && cybertrain doctor

# The framework mirror: this checkout's HEAD as a one-commit bare repository
# with the tag v<VERSION> forced onto it, so an image built from an untagged
# commit still resolves ref = "v<VERSION>". Owned by dev, the user who clones it.
RUN --mount=type=bind,source=.git,target=/tmp/checkout.git \
    set -eu; \
    if [ ! -d /tmp/checkout.git/objects ]; then \
      echo "playground/Dockerfile: the build context needs this repository's .git directory (a clone, not a worktree)" >&2; \
      exit 1; \
    fi; \
    version="$(ruby -e 'require "cybertrain/version"; print Cybertrain::VERSION')"; \
    mirror=/opt/cybertrain-mirror/cybertrain.git; \
    git init -q --bare --initial-branch=main "$mirror"; \
    git -C "$mirror" -c safe.directory='*' fetch -q --depth 1 --no-tags /tmp/checkout.git "+HEAD:refs/heads/main"; \
    git -C "$mirror" tag -f "v$version" main; \
    git -C "$mirror" rev-parse --verify -q "refs/tags/v$version" >/dev/null

# ---------------------------------------------------------------------------
FROM toolchain AS playground

USER root
COPY playground/profile.sh /etc/profile.d/cybertrain-playground.sh
COPY --chmod=0755 playground/playground-server /usr/local/bin/playground-server
# Interactive non-login shells read /etc/bash.bashrc only.
RUN echo '[ -r /etc/profile.d/cybertrain-playground.sh ] && . /etc/profile.d/cybertrain-playground.sh' >> /etc/bash.bashrc

USER dev
WORKDIR /workspace
# Tutorial step 02 (spin lock clones the mirror, then spin run gen).
RUN cybertrain new blog
WORKDIR /workspace/blog
# Step 03.
RUN cybertrain generate scaffold article title:string body:text
# Step 04: the root route.
COPY --chown=dev:dev playground/routes.rb config/routes.rb
# Step 07, then one full build: gen/ is current and build/bin/{gen,db,blog}
# exist, so the first `cybertrain server` compiles nothing. spin's freshness
# test compares mtimes: never copy this tree with anything but `cp -a`.
RUN cybertrain db migrate
RUN cybertrain spin run gen && cybertrain spin build blog
COPY --chown=dev:dev playground/PLAYGROUND.md PLAYGROUND.md
# One commit, so the Source Control view shows the visitor's own changes.
RUN git init -q -b main \
 && git add -A \
 && git -c user.name="cybertrain playground" -c user.email="playground@cybertrain.invalid" \
        commit -q -m "Tutorial steps 02-04 and 07: new, scaffold article, root route, db migrate" \
 && test -z "$(git status --porcelain)"

EXPOSE 3000
CMD ["playground-server"]
```

Create `playground/Dockerfile.dockerignore` (spec §4.2; BuildKit reads `<Dockerfile name>.dockerignore` beside the Dockerfile given with `-f` instead of the root `.dockerignore`, so this allowlist affects only this build):

```
# Build context of playground/Dockerfile (the repository root). Only what the
# image uses is sent. .git stays: the image's framework mirror is made from
# it through a bind mount (never copied into a layer).
*
!.git
!README.md
!cybertrain.gemspec
!exe/
!cybertrain/
!playground/
```

- [ ] **Step 4: Write the blog's route file and guide**

Create `playground/routes.rb` (tutorial step 04):

```ruby
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
```

Create `playground/PLAYGROUND.md` (spec §5.2, verbatim; it is copied to `/workspace/blog/PLAYGROUND.md` and holds no absolute path, so the Codespaces fallback that moves the blog needs no edit):

````markdown
# cybertrain playground

This is the blog from the cybertrain tutorial, already set up: `cybertrain new blog`,
the article scaffold, the root route and the first migration (tutorial steps 02, 03,
04 and 07). The development server runs in the terminal below and the preview shows
the app.

The preview does not reload by itself: after a change, press its reload button.

## Try this

1. **Edit a view.** Change the `<h1>` in `app/views/articles/index.html.erb`, save,
   reload the preview. Views are read from disk on every request, so there is
   nothing to build.
2. **Add a validation.** In `app/models/article.rb`, add this line inside the class
   and save:

   ```ruby
   validates :body, presence: true, length: { minimum: 10 }
   ```

   Ruby is compiled, so the terminal shows a rebuild. After about a minute the
   server restarts by itself: an article with a short body now fails with "Body is
   too short (minimum is 10 characters)". If a change does not compile, the previous
   build keeps serving and every page shows the compiler's message at the top.
3. **Carry on with the tutorial** from step 08, "Scaffold comments":
   https://saeki-mototsune.github.io/CyberTrain/tutorial.html#scaffold-comment
   Stop the server first (Ctrl-C in its terminal), run the step's commands in a new
   terminal, then start it again with `cybertrain server`.

The Source Control view shows what you changed: the app is a git repository with
one commit.

## Start a fresh app

```sh
cd ..
cybertrain new shop && cd shop
cybertrain g scaffold product name:string
cybertrain db migrate
cybertrain server
```

Stop the blog's server first: both use port 3000. `cybertrain new` needs no network
here, and the first `cybertrain server` of a new app compiles it (about a minute).

## Good to know

- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab.
  Inside the preview, pop-ups and `confirm()` dialogs do not work.
- When you are done, delete the codespace at https://github.com/codespaces: its
  storage counts against your quota for as long as it exists.
- Everything else is in the README: https://github.com/saeki-mototsune/cybertrain#readme
````

- [ ] **Step 5: Write the start script and the profile script**

Create `playground/playground-server` (spec §6.2, verbatim):

```bash
#!/usr/bin/env bash
# playground-server [APP_DIR]
#
# Starts `cybertrain server` for the playground's app (default
# /workspace/blog) in the foreground of this terminal. GitHub Codespaces runs
# it from postAttachCommand on every attach, so a second run must not start a
# second server: it prints where the app is and exits 0.
set -u

app="${1:-/workspace/blog}"
port="${PORT:-3000}"

# The toolchain on PATH; in a codespace, the cookie settings the editor's
# preview needs (SameSite=None; Secure; Partitioned).
. /etc/profile.d/cybertrain-playground.sh

if [ "${CODESPACES:-}" = "true" ] && [ -n "${CODESPACE_NAME:-}" ]; then
  url="https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/"
else
  url="http://localhost:${port}/"
fi

# One server per port. `cybertrain server` inherits the lock and holds it
# until it exits.
exec 9>"/tmp/playground-server-${port}.lock"
if ! flock -n 9; then
  echo "playground-server: the dev server is already running: ${url}"
  exit 0
fi
if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
  echo "playground-server: port ${port} is already in use, so no second server is started: ${url}"
  exit 0
fi
if [ ! -f "${app}/spin.toml" ]; then
  echo "playground-server: ${app} is not a cybertrain app (no spin.toml)" >&2
  exit 1
fi

cat <<EOF

  cybertrain playground
  App    ${url}
  Guide  ${app}/PLAYGROUND.md

  Views reload on the next request. A Ruby change rebuilds the app (about a
  minute), then the server restarts by itself. Reload the page to see either.
  Ctrl-C stops the server; run playground-server to start it again.

EOF

# Open the guide once per container, when this terminal has VS Code's `code`.
marker="${app}/tmp/.playground-guide-opened"
if [ -f "${app}/PLAYGROUND.md" ] && [ ! -e "$marker" ] && command -v code >/dev/null 2>&1; then
  timeout 5 code --reuse-window "${app}/PLAYGROUND.md" >/dev/null 2>&1 && touch "$marker"
fi

cd "$app" || exit 1
exec cybertrain server
```

Create `playground/profile.sh` (spec §6.3, verbatim; POSIX sh, since `/etc/profile` also runs under sh):

```sh
# /etc/profile.d/cybertrain-playground.sh -- installed by playground/Dockerfile.
# The toolchain lives under /opt, so the home directory holds nothing the
# prebuilt app needs (playground/README.md).
export CYBERTRAIN_HOME=/opt/cybertrain
export XDG_CACHE_HOME=/opt/cybertrain-cache
case ":${PATH}:" in
  *:/opt/cybertrain/bin:*) ;;
  *) PATH="/opt/cybertrain/bin:${PATH}"; export PATH ;;
esac
# In a GitHub Codespace the editor's preview is an iframe inside a webview on
# another site (vscode-cdn.net): a SameSite=Lax session cookie is dropped
# there and every form POST gets 403. Codespaces sets CODESPACES=true.
# Defaults only: a value already set (for a test) wins.
if [ "${CODESPACES:-}" = "true" ]; then
  export CYBERTRAIN_SESSION_SAME_SITE="${CYBERTRAIN_SESSION_SAME_SITE:-None}"
  export CYBERTRAIN_SESSION_PARTITIONED="${CYBERTRAIN_SESSION_PARTITIONED:-1}"
fi
```

Then set the git mode the spec asks for (the Dockerfile's `COPY --chmod=0755` does not depend on it):

```bash
chmod 755 playground/playground-server
```

- [ ] **Step 6: Build the image**

```bash
cd /Users/saeki/work/cybertrain
test -d .git && git rev-parse --abbrev-ref HEAD
git status --short -- cybertrain cybertrain.gemspec exe spin.toml
time docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local .
```

Expected: `web-playground`; the status command prints nothing (the framework the blog builds against is the HEAD commit, so it must be committed; the new `playground/` files need not be); the build succeeds (about 3 minutes cold on the Apple Silicon machine: Spinel's build is the slow step; later builds reuse it). Do not run git commands in this checkout while the build reads `.git`.

If the mirror step fails with `detected dubious ownership` from git, the `-c safe.directory='*'` on the fetch did not reach git's upload-pack: stop and report the full error (the spike never ran this exact step; spec §4.1 notes the mirror is dev-owned to avoid the check on later clones).

- [ ] **Step 7: Run the smoke test**

```bash
time bash playground/smoke.sh cybertrain-playground:local
```

Expected, in this order (about 4-6 minutes; A9 and B3 each compile the app once):

```
smoke: cybertrain-playground:local, expecting cybertrain 0.2.1
PASS G1 the user is dev, uid 1000
PASS G2 cybertrain version prints cybertrain 0.2.1
PASS G3 cybertrain doctor exits 0
PASS G4 CYBERTRAIN_HOME and XDG_CACHE_HOME point under /opt and CYBERTRAIN_HOST is unset
PASS G5 the blog's spin.toml depends on the tag v0.2.1
PASS G6 the blog is a clean git repository with one commit that tracks PLAYGROUND.md
PASS G7 no tmp/secret_key is baked in and build/bin/blog is executable
PASS A1 GET /articles through the published port answers 200 (default command, CYBERTRAIN_HOST=0.0.0.0)
PASS A2 the log shows the boot banner of 0.2.1 listening on http://0.0.0.0:3000
PASS A3 starting compiled nothing (build/bin/blog keeps the image's mtime)
PASS A4 GET / answers 200 with <h1>Articles</h1>
PASS A5 GET /articles/new has a CSRF token and a SameSite=Lax session cookie without Secure or Partitioned
PASS A6 POST /articles with the token and the cookie answers 303 to the new article, whose page shows it
PASS A7 POST /articles without token or cookie answers 403
PASS A8 a view edit shows on the next request
PASS A9 a model edit rebuilds and restarts the server: a short body then answers 422
PASS A10 the running container generated tmp/secret_key
PASS D1 a second playground-server exits 0 saying the server is already running
PASS D2 exactly one app server process runs
PASS D3 after a container restart (Codespaces' idle stop and resume) the server is back, once, with the earlier article
PASS D4 playground-server leaves a server started by hand alone: it says the port is in use, exits 0, and one server runs
PASS C1 with CODESPACES=true the session cookie is SameSite=None; Secure; Partitioned
PASS C2 with CODESPACES=true the banner shows https://smoke-3000.app.github.dev/
PASS C3 with CODESPACES=true, interactive and login bash shells get the cookie settings
PASS F1 CYBERTRAIN_SESSION_SAME_SITE=lax stops the server at boot and names the valid values
PASS E1 a cp -a copy of the blog started by playground-server compiles nothing
PASS B1 with no network, git ls-remote of the repository URL lists refs/tags/v0.2.1 (the mirror)
PASS B2 with no network, cybertrain new works in /workspace (next to the blog) and locks the blog's commit
PASS B3 with no network, the new app builds
smoke: 29 passed, 0 failed
```

A failure prints the container's last 40 log lines after the summary; fix the cause and rebuild. Never weaken a check to make it pass. If E1 fails (a `cp -a` copy rebuilds), stop and report it: it is the premise of the Codespaces fallback 1 (spec §6.5).

- [ ] **Step 8: Commit**

```bash
git add playground/Dockerfile playground/Dockerfile.dockerignore playground/routes.rb playground/PLAYGROUND.md playground/playground-server playground/profile.sh playground/smoke.sh
git ls-files -s playground/playground-server
git commit -m "Playground: the image (Dockerfile, start script, profile, prebuilt tutorial blog)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected from `git ls-files -s`: mode `100755`.

---

### Task 6: Codespaces configuration and the image workflow

**Files:**
- Create: `.devcontainer/devcontainer.json`
- Create: `.github/workflows/playground-image.yml`
- Test: `npx --yes @devcontainers/cli@0 read-configuration`, a YAML parse, and a local `devcontainer up` on the Task 5 image

**Interfaces:**
- Consumes: `playground/Dockerfile` (target `playground`) and `playground/smoke.sh` (Task 5); the local image `cybertrain-playground:local`.
- Produces: the repository's default dev container (`image` `ghcr.io/saeki-mototsune/cybertrain-playground:latest`, `remoteUser` `dev`, `workspaceFolder` `/workspace/blog`, `postAttachCommand` `{ "server": "playground-server" }`, port 3000 with `"onAutoForward": "openPreview"`); the workflow "Playground image" (`IMAGE: ghcr.io/saeki-mototsune/cybertrain-playground`; local test tag `cybertrain-playground:ci`; the lines Task 9 edits: `    branches: [main]` and the `type=raw,value=latest,enable=...` line).

- [ ] **Step 1: Write the failing test**

The two files must exist and parse:

```bash
npx --yes @devcontainers/cli@0 read-configuration --workspace-folder . > /dev/null && echo "devcontainer.json parses"
ruby -ryaml -e 'YAML.load_file(".github/workflows/playground-image.yml"); puts "workflow parses"'
```

- [ ] **Step 2: Run it to verify it fails**

Expected: the CLI exits non-zero with `Dev container config (.../.devcontainer/devcontainer.json) not found.`; Ruby fails with `No such file or directory` for the workflow.

- [ ] **Step 3: Write `.devcontainer/devcontainer.json`**

Spec §6.1, verbatim:

```jsonc
{
  "name": "cybertrain playground",
  "image": "ghcr.io/saeki-mototsune/cybertrain-playground:latest",
  "remoteUser": "dev",
  "workspaceFolder": "/workspace/blog",
  "postCreateCommand": "",
  "postAttachCommand": { "server": "playground-server" },
  "forwardPorts": [3000],
  "portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "customizations": {
    "vscode": {
      "settings": { "files.autoSave": "off" }
    }
  }
}
```

- [ ] **Step 4: Write `.github/workflows/playground-image.yml`**

Spec §8.1, verbatim:

```yaml
# Builds the playground image (playground/Dockerfile, target playground) for
# linux/amd64, smoke-tests it (playground/smoke.sh) and, except on pull
# requests, pushes the tested image to GHCR: latest from main, X.Y.Z and
# latest from a tag vX.Y.Z, the given tag on a manual run.
# See playground/README.md.
name: Playground image

on:
  pull_request:
    paths:
      - "playground/**"
      - ".devcontainer/**"
      - "cybertrain/**"
      - "cybertrain.gemspec"
      - "spin.toml"
      - "exe/**"
      - ".github/workflows/playground-image.yml"
  push:
    branches: [main]
    # GitHub does not evaluate path filters for tag pushes: every v* tag builds.
    tags: ["v*"]
    paths:
      - "playground/**"
      - ".devcontainer/**"
      - "cybertrain/**"
      - "cybertrain.gemspec"
      - "spin.toml"
      - "exe/**"
      - ".github/workflows/playground-image.yml"
  workflow_dispatch:
    inputs:
      tag:
        description: "Tag to push to ghcr.io/saeki-mototsune/cybertrain-playground (latest, X.Y.Z or a test name)"
        required: true
        default: "test"

permissions:
  contents: read
  packages: write

concurrency:
  group: playground-image-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  IMAGE: ghcr.io/saeki-mototsune/cybertrain-playground

jobs:
  image:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: devcontainer.json parses
        run: npx --yes @devcontainers/cli@0 read-configuration --workspace-folder . > /dev/null

      - uses: docker/setup-buildx-action@v3

      - name: Tags and labels
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE }}
          flavor: |
            latest=false
          tags: |
            type=raw,value=latest,enable=${{ github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v')) }}
            type=semver,pattern={{version}},enable=${{ startsWith(github.ref, 'refs/tags/v') }}
            type=raw,value=${{ inputs.tag || 'manual' }},enable=${{ github.event_name == 'workflow_dispatch' }}

      - name: Build (linux/amd64, target playground)
        uses: docker/build-push-action@v6
        with:
          context: .
          file: playground/Dockerfile
          target: playground
          platforms: linux/amd64
          load: true
          tags: cybertrain-playground:ci
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha,scope=playground-image
          cache-to: type=gha,mode=max,scope=playground-image

      - name: Smoke test
        run: bash playground/smoke.sh cybertrain-playground:ci

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push the tested image
        if: github.event_name != 'pull_request'
        env:
          TAGS: ${{ steps.meta.outputs.tags }}
        run: |
          test -n "$TAGS" || { echo "no tag to push"; exit 1; }
          for tag in $TAGS; do
            docker tag cybertrain-playground:ci "$tag"
            docker push "$tag"
          done
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
npx --yes @devcontainers/cli@0 read-configuration --workspace-folder . > /dev/null && echo "devcontainer.json parses"
ruby -ryaml -e 'YAML.load_file(".github/workflows/playground-image.yml"); puts "workflow parses"'
grep -n 'context: \.$\|target: playground\|platforms: linux/amd64\|bash playground/smoke.sh cybertrain-playground:ci' .github/workflows/playground-image.yml
```

Expected: `devcontainer.json parses`; `workflow parses`; four matching lines.

- [ ] **Step 6: Bring the dev container up locally on the Task 5 image (spec §10.2, item 3)**

The devcontainer CLI uses a local image of the configured name and pulls only when there is none, so a local tag stands in for the not-yet-published image (spec §10.2 places this after the first publish; with the local tag it needs none). The CLI mounts the repository under `/workspaces/<name>`, so this does not stand in for Codespaces' handling of `workspaceFolder` (Task 9, L2 does).

```bash
docker tag cybertrain-playground:local ghcr.io/saeki-mototsune/cybertrain-playground:latest
npx --yes @devcontainers/cli@0 up --workspace-folder . --skip-post-attach | tail -n 1
npx --yes @devcontainers/cli@0 exec --workspace-folder . sh -c 'id -un; pwd'
npx --yes @devcontainers/cli@0 exec --workspace-folder . playground-server > "${TMPDIR:-/tmp}/devcontainer-server.log" 2>&1 &
code=000; for i in $(seq 1 30); do code=$(npx --yes @devcontainers/cli@0 exec --workspace-folder . curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/articles); [ "$code" = 200 ] && break; sleep 1; done; echo "$code"
```

Expected: the `up` line contains `"outcome":"success"`; `dev` and `/workspace/blog`; `200`. If `up` instead tries to pull and fails with `denied` or `not found`, skip the rest of this step: Task 9 runs the same check on the published image.

Clean up (removing the container also ends the `exec` left running in the background):

```bash
docker rm -f $(docker ps -aq --filter "label=devcontainer.local_folder=$(pwd)")
docker image rm ghcr.io/saeki-mototsune/cybertrain-playground:latest
```

The last command removes only that tag; `cybertrain-playground:local` stays.

- [ ] **Step 7: Commit**

```bash
git add .devcontainer/devcontainer.json .github/workflows/playground-image.yml
git commit -m "Playground: Codespaces dev container and the image workflow (build, smoke test, push)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: README entry and `playground/README.md`

**Files:**
- Modify: `README.md` (new section "Try it in the browser" between the Status paragraph and "## Requirements", lines 35-37; the first item of "Learn more"; step 4 of "Releasing", after step 3)
- Create: `playground/README.md`
- Test: heading, link and section-order checks below

**Interfaces:**
- Consumes: the facts of Tasks 5 and 6 (image name and tags, devcontainer settings, workflow triggers, smoke checks D1-D4, C1-C3, B2 in `/workspace`); step 3 of the README's "Releasing" as Task 3 left it (`3. `gem build cybertrain.gemspec && gem push cybertrain-0.2.1.gem`.`).
- Produces: the README section whose sentences back every claim on `site/playground.html` (Task 8) and the strings Task 9 may replace: `in the editor's preview. The app is a git repository with one commit, so Source`, `server restarts by itself; the preview does not reload by itself. `cybertrain new``, the bullet starting `- Inside the preview, pop-ups and `confirm()` dialogs do not work; the Ports`, and `on the next reload; a Ruby edit is a full rebuild, about a minute, after which the`. In `playground/README.md`, Task 9 may replace the bullets starting ``- `workspaceFolder`:``, ``- `postAttachCommand`:``, ``- `forwardPorts` and `portsAttributes`:``, `- The Ports view's "Open in Browser"`, `- "Rebuild Container"` and `- A Ruby edit is a full rebuild (about a minute)`, and appends a "### Live check" subsection to "## Codespaces".

- [ ] **Step 1: Write the failing test**

```bash
grep -n '^## Try it in the browser$' README.md
grep -c 'codespaces.new/saeki-mototsune/CyberTrain?quickstart=1' README.md
grep -n 'CyberTrain/playground.html' README.md
grep -n '^4\. The tag also publishes the playground image$' README.md
test -f playground/README.md && echo "playground/README.md exists"
```

- [ ] **Step 2: Run it to verify it fails**

Expected: no output from the greps except `0` from `grep -c`, and no `exists` line.

- [ ] **Step 3: Add the README section**

In `README.md`, replace

```markdown
Rails" below.

## Requirements
```

(the end of the Status paragraph, lines 35-37) with the section of spec §7.4 between them:

````markdown
Rails" below.

## Try it in the browser

[Open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
to try cybertrain without installing anything: VS Code opens in your browser with
Spinel 2026.09.12, the `cybertrain` CLI and the blog from the walkthrough below
already created (`cybertrain new blog`, the article scaffold, the root route and
the first migration, built once so the server starts without compiling), its
development server running in a terminal and the app, showing the article list,
in the editor's preview. The app is a git repository with one commit, so Source
Control shows what you change. `PLAYGROUND.md` in the app lists what to try, from
editing a view to carrying on with the walkthrough's comments. A view edit shows
on the next reload; a Ruby edit is a full rebuild, about a minute, after which the
server restarts by itself; the preview does not reload by itself. `cybertrain new`
works there with no network.

- A GitHub account is required, and the codespace runs on your own Codespaces
  quota: GitHub's free plan includes 120 core-hours and 15 GB-month of storage a
  month, about 60 hours on the default 2-core machine the playground uses. GitHub
  stops an idle codespace after 30 minutes by default; its storage counts until
  you delete it.
- Inside the preview, pop-ups and `confirm()` dialogs do not work; the Ports
  view's "Open in Browser" shows the app in a normal tab.
- The same image runs locally (it is published for linux/amd64; on arm64, build
  it from a checkout):

  ```sh
  docker run --rm -it --init -p 3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  Then open http://localhost:3000. [playground/README.md](playground/README.md)
  describes the image, building it and the Codespaces setup.

## Requirements
````

- [ ] **Step 4: Update "Learn more" and "Releasing"**

In "Learn more", replace

```markdown
- [Homepage](https://saeki-mototsune.github.io/CyberTrain/) and
  [tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html) —
```

with

```markdown
- [Homepage](https://saeki-mototsune.github.io/CyberTrain/),
  [tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html) and
  [playground](https://saeki-mototsune.github.io/CyberTrain/playground.html) —
```

In "Releasing", directly after the line `3. `gem build cybertrain.gemspec && gem push cybertrain-0.2.1.gem`.` add:

```markdown
4. The tag also publishes the playground image
   `ghcr.io/saeki-mototsune/cybertrain-playground:X.Y.Z` (and `latest`) through
   [.github/workflows/playground-image.yml](.github/workflows/playground-image.yml);
   check that run.
```

- [ ] **Step 5: Write `playground/README.md`**

Spec §7.5 gives its outline (ten parts); this is the full text. Correction to §7.5 item 3: the build does use rubygems.org — `cybertrain setup` runs Spinel's `make deps`, which downloads the prism and rbs gems from it (Spinel's Makefile; the container spike's finding); only the cybertrain gem itself comes from the checkout. The live-check results (§7.5 item 6) are added in Task 9.

````markdown
# The playground image

`ghcr.io/saeki-mototsune/cybertrain-playground` is cybertrain ready to try
without installing anything: Ubuntu 24.04 with the `cybertrain` CLI and
Spinel built from this repository, a mirror of the framework so that
`cybertrain new` needs no network, and the tutorial's blog in
`/workspace/blog`, created, scaffolded, migrated and built once.
[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) opens
it in GitHub Codespaces (the README's
["Try it in the browser"](../README.md#try-it-in-the-browser)); a hosted
playground that runs the same image is planned.

- Tags: `latest` is the latest tested build of `main`; `X.Y.Z` comes from the
  release tag `vX.Y.Z`, which also moves `latest`; a manual run of the
  workflow pushes the tag it is given.
- Platform: `linux/amd64` only. On an arm64 machine, build it yourself
  (below).
- Files: [Dockerfile](Dockerfile) and
  [Dockerfile.dockerignore](Dockerfile.dockerignore) (its build context),
  [playground-server](playground-server) and [profile.sh](profile.sh) (the
  scripts), [routes.rb](routes.rb) and [PLAYGROUND.md](PLAYGROUND.md) (copied
  into the blog) and [smoke.sh](smoke.sh) (the smoke test).

## Run it

```sh
docker run --rm -it --init -p 3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
```

Then open http://localhost:3000. The default command, `playground-server`,
runs the blog's development server in the foreground; Ctrl-C stops it. For a
shell instead:

```sh
docker run --rm -it ghcr.io/saeki-mototsune/cybertrain-playground bash
```

- `--init` puts a small init process at PID 1 that passes Ctrl-C and
  `docker stop` on and reaps processes: the server runs as `cybertrain
  server` → `spin run blog` → the app's binary.
- `CYBERTRAIN_HOST=0.0.0.0` makes the server listen on every interface,
  which `-p` needs. The server listens on 127.0.0.1 by default and the image
  leaves it so: GitHub Codespaces forwards 127.0.0.1, and nothing else needs
  to reach the server there.

## Build it

From a regular clone of this repository (not a git worktree), at its root:

```sh
docker build -f playground/Dockerfile --target playground -t cybertrain-playground .
```

- Always name the target: a later stage will add a browser editor after
  `playground`.
- The build context is the repository root and must contain the `.git`
  directory: the framework mirror is made from it through a bind mount, so
  `.git` never lands in a layer. In a git worktree `.git` is a file, and the
  build stops with "the build context needs this repository's .git
  directory".
- The mirror holds the checkout's HEAD commit, so the blog builds against
  the committed framework, while the CLI is built from the working tree:
  commit framework changes before building.
- It builds on arm64 too: the image is for the architecture of the machine
  that builds it.
- The build needs the network: Ubuntu's package mirrors, github.com (Spinel's
  source) and rubygems.org (Spinel's `make deps` downloads the prism and rbs
  gems). The `cybertrain` gem itself is built from this checkout's
  `cybertrain.gemspec`, not downloaded.
- A clean build took 156 s on 10 CPUs (Apple M5, linux/arm64), 41.5 s of it
  building Spinel.

Then run the smoke test: `bash playground/smoke.sh cybertrain-playground`
(below).

## What is inside

| What | Where |
| --- | --- |
| User | `dev`, uid/gid 1000, home `/home/dev`; nothing the blog needs to start or rebuild lives in the home directory |
| Spinel | `CYBERTRAIN_HOME=/opt/cybertrain` (its `bin/` first on `PATH`), owned by dev |
| spin's cache | `XDG_CACHE_HOME=/opt/cybertrain-cache`, owned by dev; `cybertrain new` and rebuilds write it |
| Framework mirror | `/opt/cybertrain-mirror/cybertrain.git`, owned by dev, with two `insteadOf` rules in `/etc/gitconfig` |
| The blog | `/workspace/blog`, owned by dev: a git repository with one commit, already built |
| Start script | `/usr/local/bin/playground-server [APP_DIR]` |
| Profile | `/etc/profile.d/cybertrain-playground.sh`, also read by interactive shells through `/etc/bash.bashrc` |
| Port | 3000, on 127.0.0.1 unless `CYBERTRAIN_HOST` says otherwise |
| Written at run time outside the app | `/tmp` (spin's temporary files) and `/opt/cybertrain-cache`; inside the app, `tmp/`, `storage/`, `build/` and `gen/` |

Stages: `cli-src` (internal: exactly the files `cybertrain.gemspec`
packages, so that a change to the framework alone keeps the gem and Spinel
layers cached), `toolchain` (packages, the user, the CLI gem, Spinel, the
mirror) and `playground` (the scripts and the blog).

The blog is the tutorial after steps 02, 03, 04 and 07 (`cybertrain new
blog`, the article scaffold, the root route, `cybertrain db migrate`) plus
one full build: `gen/` is current and `build/bin/{gen,db,blog}` exist, so
the first `cybertrain server` compiles nothing. spin decides what is fresh
by file times, so copy the blog only with `cp -a` (or `tar`), which keep
them.

Not baked in: `tmp/secret_key` (each container makes its own on first start,
so no two visitors share a key), `CYBERTRAIN_HOST` and the Codespaces
variables (set at run time), the VS Code server (Codespaces installs it),
seed data, `sudo` and editor extensions.

The mirror is this checkout's HEAD as a one-commit bare repository with the
tag `v<VERSION>` forced onto it. A new app's `spin.toml` points at
`https://github.com/saeki-mototsune/cybertrain`, tag `v<VERSION>`, and the
`insteadOf` rules send that URL, with or without `.git`, to the mirror, so
`cybertrain new` works with no network. Every clone of a URL that starts
with `https://github.com/saeki-mototsune/cybertrain` gets the mirror,
including other repositories whose names start that way; to reach GitHub
itself:

```sh
GIT_CONFIG_NOSYSTEM=1 git clone https://github.com/saeki-mototsune/cybertrain
```

## The scripts

**`playground-server [APP_DIR]`** starts `cybertrain server` for APP_DIR
(default `/workspace/blog`) in the foreground of the terminal it runs in.

- It is safe to run again. A second run finds the first one's lock
  (`/tmp/playground-server-3000.lock`, held by the server until it exits)
  and says "the dev server is already running"; a server started some other
  way, such as `cybertrain server` by hand, is found by connecting to the
  port, or, while it is still compiling and does not listen yet, by its
  process (any `cybertrain server` of the same user, whatever its port). In
  each case it prints the app's URL and exits 0 without starting anything.
  Codespaces runs it on every attach.
- The banner shows the app's URL (in a codespace the forwarded
  `https://<codespace>-3000.app.github.dev/`, elsewhere
  `http://localhost:3000/`), where the guide is, and how long edits take.
- When VS Code's `code` command works in its terminal, it opens
  `PLAYGROUND.md` once per container (the marker is
  `tmp/.playground-guide-opened`, which git ignores); otherwise the banner is
  the only pointer.
- `PORT` changes the port, as it does for `cybertrain server`.

**`/etc/profile.d/cybertrain-playground.sh`** (from `profile.sh`) puts
`/opt/cybertrain/bin` on `PATH` and sets `CYBERTRAIN_HOME` and
`XDG_CACHE_HOME` for every shell, login or not. In a codespace
(`CODESPACES=true`) it also defaults `CYBERTRAIN_SESSION_SAME_SITE=None` and
`CYBERTRAIN_SESSION_PARTITIONED=1`. The editor's preview shows the app in an
iframe inside a webview on another site (`vscode-cdn.net`), where a
`SameSite=Lax` session cookie is neither stored nor sent, so every form POST
would fail the CSRF check with 403; `SameSite=None; Secure` works there, and
`Partitioned` keeps it working in browsers that block third-party cookies.
These are the framework's own variables (the README's "Configuration and
environment variables"); the framework does not look at `CODESPACES`
itself. A value already set wins, which allows a control run:
`CYBERTRAIN_SESSION_SAME_SITE=Lax CYBERTRAIN_SESSION_PARTITIONED=0 playground-server`.

## Codespaces

[.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json) is the
repository's default dev container configuration:

- `image`: `ghcr.io/saeki-mototsune/cybertrain-playground:latest`, the latest build of `main` that passed the smoke test.
- `remoteUser`: `dev`.
- `workspaceFolder`: `/workspace/blog`, the prebuilt blog, outside the clone of this repository under `/workspaces`.
- `postCreateCommand`: empty, so no setup step runs.
- `postAttachCommand`: `playground-server`, on every attach (it is safe to run again).
- `forwardPorts` and `portsAttributes`: port 3000, labelled `cybertrain`, opened in the editor's preview (`onAutoForward: openPreview`) when the server starts listening.
- `files.autoSave: off`: the development server rebuilds the app on every save of a Ruby file, and delayed auto-save would start a minute-long rebuild at every pause in typing.
- No `hostRequirements`: the default 2-core machine, which costs the visitor the least quota.

The link is `https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1`
(the default branch; `https://codespaces.new/saeki-mototsune/CyberTrain/tree/<branch>?quickstart=1`
for another branch). `quickstart=1` resumes the visitor's codespace if there
is one, or offers a single "Create codespace" button, and always opens VS
Code in the browser.

- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab. Inside the preview, pop-ups and `confirm()` dialogs do not work.
- "Rebuild Container" starts again from the image: edits under `/workspace/blog` are lost, since only `/workspaces` survives a rebuild.
- A codespace's storage counts against the visitor's quota until it is deleted at https://github.com/codespaces.

## Smoke test

```sh
bash playground/smoke.sh IMAGE
```

It needs bash 3.2 or newer, docker and curl. It prints one PASS or FAIL line
per check, then `smoke: N passed, M failed`, and exits 0 only when every
check passes; CI runs it on every build before pushing. Most of its time
goes to three compiles of up to a minute each: the model edit (A9), the
server started by hand (D4) and the offline app (B3).

| ID | Checks |
| --- | --- |
| G1-G7 | The image as built: user `dev` (uid 1000); `cybertrain version`; `cybertrain doctor`; `CYBERTRAIN_HOME` and `XDG_CACHE_HOME` set, `CYBERTRAIN_HOST` not; the blog's `spin.toml` points at `v<VERSION>`; the blog is a clean one-commit git repository that tracks `PLAYGROUND.md`; no `tmp/secret_key`, an executable `build/bin/blog` |
| A1-A10 | The default command with `CYBERTRAIN_HOST=0.0.0.0`, reached from the host: `GET /articles`; the boot banner; nothing compiled at start; `GET /` shows `<h1>Articles</h1>`; a CSRF token and a `SameSite=Lax` cookie; creating an article (303, then its page); 403 without a token; a view edit shows on the next request; a model edit rebuilds and restarts the server (a short body then answers 422); `tmp/secret_key` generated |
| D1-D4 | `playground-server` again: it exits 0 saying "already running"; one server process; after a container restart (idle stop and resume) the server is back with the data; a server started by hand is left alone, while it is still compiling and once it listens |
| C1-C3 | `CODESPACES=true`: the cookie is `SameSite=None; Secure; Partitioned`; the banner shows the forwarded URL; interactive and login shells get the cookie settings |
| F1 | `CYBERTRAIN_SESSION_SAME_SITE=lax` stops the server at boot, naming the valid values |
| E1 | A `cp -a` copy of the blog starts without compiling |
| B1-B3 | No network: the repository URL reaches the mirror; `cybertrain new` in `/workspace` locks the blog's commit; the new app builds |

## CI and publishing

[.github/workflows/playground-image.yml](../.github/workflows/playground-image.yml)
("Playground image") runs on pull requests and pushes to `main` that touch
`playground/`, `.devcontainer/`, `cybertrain/`, `cybertrain.gemspec`,
`spin.toml`, `exe/` or the workflow itself, on every `v*` tag (GitHub does
not apply path filters to tags), and by hand. It checks that
`devcontainer.json` parses, builds the `playground` target for `linux/amd64`
with the GitHub Actions cache (a change to the framework alone rebuilds only
the mirror and the blog), runs the smoke test and then, except on pull
requests, pushes the image it tested: `latest` from `main`, `X.Y.Z` and
`latest` from a tag `vX.Y.Z`, and the given tag from a manual run (Actions →
Playground image → Run workflow, on `main`).

## Owner's one-time steps

1. After the first push, open the package `cybertrain-playground` (the
   Packages tab of github.com/saeki-mototsune) and make sure its visibility
   is **Public** (Package settings → Change visibility) and that it is
   connected to the repository (Connect repository). Codespaces cannot pull
   a private image for anyone else.
2. Optional: Codespaces prebuilds (repository Settings → Codespaces → Set up
   prebuild; branch `main`, configuration `.devcontainer/devcontainer.json`,
   as few regions as will do). The owner pays for the prebuild's storage and
   Actions minutes.

## Limitations

- `linux/amd64` only; on arm64, build the image from a checkout.
- No live reload: reload the page after a change.
- A Ruby edit is a full rebuild (about a minute); a view edit needs none.
- The blog's `spin.lock` pins the commit the image was built from, which for
  an image built from `main` can differ from the commit GitHub's
  `v<VERSION>` tag points at.
- Inside the image, clones of any URL that starts with
  `https://github.com/saeki-mototsune/cybertrain` go to the mirror (above).
````

- [ ] **Step 6: Run the checks to verify they pass**

```bash
grep -n '^## Try it in the browser$' README.md
grep -c 'codespaces.new/saeki-mototsune/CyberTrain?quickstart=1' README.md
grep -n 'CyberTrain/playground.html' README.md
grep -n '^4\. The tag also publishes the playground image$' README.md
grep -n '^## ' README.md | head -n 2
ruby -e '
%w[README.md playground/README.md].each do |doc|
  File.read(doc, encoding: "UTF-8").scan(/\]\(([^)\s]+)\)/).flatten.each do |target|
    next if target.start_with?("http://", "https://", "#", "mailto:")
    path = File.expand_path(target.split("#").first, File.dirname(doc))
    puts "#{doc}: missing #{target}" unless File.exist?(path)
  end
end
puts "links checked"'
```

Expected: the heading line; `1`; the Learn more line; the step 4 line; the first two `## ` headings are `## Try it in the browser` and `## Requirements`; `links checked` with no `missing` line.

- [ ] **Step 7: Commit**

```bash
git add README.md playground/README.md
git commit -m "Docs: README \"Try it in the browser\" and playground/README.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Site: the playground page and its links

**Files:**
- Create: `site/playground.html`
- Modify: `site/index.html` (primary nav, lines 38-40; hero buttons, lines 56-59)
- Modify: `site/tutorial.html` (primary nav, lines 39-40; the end of Step 00, lines 113-114)
- Modify: `site/README.md` (the first paragraph names the pages)
- Modify: `site/assets/style.css` (one layout rule after line 389, `.step .sub + .code`)
- Test: a link, id, class and `aria-current` check over the three pages

**Interfaces:**
- Consumes: README.md's "Try it in the browser" (Task 7), whose sentences back every claim on the page; the classes in `site/assets/style.css`; the head and site header of `site/tutorial.html` and the footer of `site/index.html`.
- Produces: `site/playground.html` with the strings Task 9 may replace: in the description meta `the app in the editor's preview. Or run`; in `.doc-intro` `and the app in the editor's preview.`; `<li>The app in the editor's preview, showing the article list.</li>`; `a full rebuild, about a minute, after which the server restarts by itself.`; and the note `<p class="note">The preview does not reload by itself: press its reload button after a change. Inside the preview, pop-ups and <code>confirm()</code> dialogs do not work; the Ports view's &ldquo;Open in Browser&rdquo; shows the app in a normal tab.</p>`.

- [ ] **Step 1: Write the failing test**

Save this checker as `${TMPDIR:-/tmp}/site_check.rb` (it is not committed):

```ruby
# The three pages: every relative link and asset exists, every #fragment
# names an id in its page, playground.html uses only classes that
# assets/style.css defines, and its one aria-current="page" link is Playground.
def read(path) = File.read(path, encoding: "UTF-8")

ok = true
pages = %w[index.html tutorial.html playground.html]
ids = pages.to_h { |page| [page, read("site/#{page}").scan(/\bid="([^"]+)"/).flatten] }
pages.each do |page|
  read("site/#{page}").scan(/href="([^"]+)"/).flatten.each do |href|
    next if href.start_with?("http://", "https://")
    file, fragment = href.split("#", 2)
    file = page if file.nil? || file.empty?
    unless File.exist?("site/#{file}")
      puts "#{page}: #{href} does not exist"
      ok = false
      next
    end
    if fragment && ids.key?(file) && !ids[file].include?(fragment)
      puts "#{page}: #{file} has no id #{fragment}"
      ok = false
    end
  end
end
css = read("site/assets/style.css")
html = read("site/playground.html")
html.scan(/class="([^"]+)"/).flatten.flat_map(&:split).uniq.each do |name|
  next if css.match?(/\.#{Regexp.escape(name)}(?![\w-])/)
  puts "playground.html: class #{name} is not in style.css"
  ok = false
end
current = html.scan(/<a [^>]*aria-current="page"[^>]*>([^<]*)</).flatten
unless current == ["Playground"]
  puts "playground.html: aria-current=\"page\" links: #{current.inspect}"
  ok = false
end
puts(ok ? "site check: ok" : "site check: FAILED")
exit(ok ? 0 : 1)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ruby "${TMPDIR:-/tmp}/site_check.rb"`
Expected: `No such file or directory @ rb_sysopen - site/playground.html` (`Errno::ENOENT`).

- [ ] **Step 3: Build `site/playground.html`**

Spec §7.2: the `<head>` of `tutorial.html` with four lines replaced, the header of `tutorial.html` with `Playground` added to the nav as the current page, the footer of `index.html`, and the page's own `<main>`. The spec does not name the `<body>` class; this keeps `tutorial.html`'s `class="tutorial"`, because `style.css` keys the small-screen scroll padding of the sticky contents on `body.tutorial` (line 664). Save this script as `${TMPDIR:-/tmp}/build_playground_page.rb` and run `ruby "${TMPDIR:-/tmp}/build_playground_page.rb"` once, before Step 4 edits the two navs (it is not committed):

```ruby
# Builds site/playground.html: the <head> and site header of
# site/tutorial.html (with this page's title, descriptions and nav), the
# page's own <main> below, and the footer of site/index.html.
def read(path) = File.read(path, encoding: "UTF-8")

def replace_once(text, pattern, replacement)
  count = text.scan(pattern).size
  abort "expected one match of #{pattern.inspect}, found #{count}" unless count == 1
  text.sub(pattern) { replacement }
end

tutorial = read("site/tutorial.html")
index = read("site/index.html")
header_end = tutorial.index("\n</header>\n") or abort "site/tutorial.html: no site header"
head = tutorial[0, header_end + "\n</header>\n".length]
footer_start = index.index("<footer class=\"site-footer\">") or abort "site/index.html: no footer"
footer = index[footer_start..]

head = replace_once(head, %r{<title>[^<]*</title>},
                    %(<title>Try it in your browser · CyberTrain</title>))
head = replace_once(head, /<meta name="description" content="[^"]*">/,
                    %(<meta name="description" content="Open the CyberTrain tutorial blog in a GitHub Codespace: VS Code in your browser, the development server running, the app in the editor's preview. Or run the same image locally with Docker.">))
head = replace_once(head, /<meta property="og:title" content="[^"]*">/,
                    %(<meta property="og:title" content="Try CyberTrain in your browser">))
head = replace_once(head, /<meta property="og:description" content="[^"]*">/,
                    %(<meta property="og:description" content="The tutorial blog, already scaffolded and migrated, in VS Code in your browser. Needs a GitHub account; runs on your own Codespaces quota.">))
nav = <<'NAV'.chomp
      <ul>
        <li><a href="index.html#how-it-works">How it works</a></li>
        <li><a href="tutorial.html">Tutorial</a></li>
        <li><a href="playground.html" aria-current="page">Playground</a></li>
        <li><a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">GitHub<span class="ext" aria-hidden="true">&#8599;</span></a></li>
      </ul>
NAV
head = replace_once(head, %r{      <ul>\n.*?\n      </ul>}m, nav)

main = <<'HTML'
<main id="main">

<div class="wrap">
  <header class="doc-hero">
    <p class="crumb"><a href="index.html">CyberTrain</a><span aria-hidden="true"> / </span><span>Playground</span></p>
    <h1>Try it in your&nbsp;browser</h1>
    <p class="doc-intro">The blog from the <a href="tutorial.html">tutorial</a>, already created, scaffolded and migrated, opens in VS Code in your browser, with its development server running in a terminal and the app in the editor's preview. Nothing to install: GitHub Codespaces runs it on a cloud machine.</p>
    <dl class="doc-meta">
      <div><dt>You need</dt><dd>A GitHub account</dd></div>
      <div><dt>It runs on</dt><dd>Your own Codespaces quota, on the default 2-core machine</dd></div>
      <div><dt>You get</dt><dd>VS Code, Spinel <code>2026.09.12</code>, the <code>cybertrain</code> CLI and the blog</dd></div>
    </dl>
  </header>
</div>

<div class="wrap doc">
  <nav class="toc" aria-label="Playground sections">
    <details class="toc-d" open>
      <summary class="toc-sum"><span class="toc-title">On this page</span><span class="toc-count" data-count aria-hidden="true"></span><span class="toc-chev" aria-hidden="true"></span></summary>
      <div class="toc-bar" aria-hidden="true"><span data-bar></span></div>
    <ol>
      <li><a href="#open"><span class="toc-n">01</span>Open a codespace</a></li>
      <li><a href="#what-opens"><span class="toc-n">02</span>What opens</a></li>
      <li><a href="#try"><span class="toc-n">03</span>What to try</a></li>
      <li><a href="#docker"><span class="toc-n">04</span>Run it with Docker</a></li>
      <li class="toc-x"><a href="#where-next"><span class="toc-n">&rarr;</span>Where next</a></li>
    </ol>
    </details>
  </nav>

  <article class="doc-body">

  <section class="step" id="open" aria-labelledby="h-open">
    <p class="stage"><span class="stage-k">You are here<span class="sr-only">:</span></span>One click <span aria-hidden="true">&middot;</span> GitHub Codespaces</p>
    <h2 id="h-open"><span class="step-num" aria-hidden="true">01</span>Open a codespace</h2>
    <p class="why"><span class="why-k">Why</span><span class="why-t">VS Code in your browser, on a cloud machine that runs on your own GitHub quota.</span></p>
    <div class="cta-row">
      <a class="btn btn-primary" href="https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1" rel="noopener">Open in GitHub Codespaces<span class="btn-arrow" aria-hidden="true">&rarr;</span></a>
      <a class="btn btn-ghost" href="tutorial.html">Read the tutorial</a>
    </div>
    <p class="note">A GitHub account is required, and the codespace runs on your own Codespaces quota: GitHub's free plan includes 120 core-hours and 15&nbsp;GB-month of storage a month, about 60 hours on the default 2-core machine the playground uses. GitHub stops an idle codespace after 30 minutes by default; its storage counts until you delete it.</p>
  </section>

  <section class="step" id="what-opens" aria-labelledby="h-what-opens">
    <h2 id="h-what-opens"><span class="step-num" aria-hidden="true">02</span>What opens</h2>
    <ul class="points">
      <li>The blog with tutorial steps 02, 03, 04 and 07 done: <code>cybertrain new blog</code>, the article scaffold, the root route and the first migration, built once so the server starts without compiling.</li>
      <li>A terminal running <code>cybertrain server</code>.</li>
      <li>The app in the editor's preview, showing the article list.</li>
      <li><code>PLAYGROUND.md</code>, the short guide to what to try.</li>
      <li>Source Control: the app is a git repository with one commit, so it shows exactly what you change.</li>
    </ul>
  </section>

  <section class="step" id="try" aria-labelledby="h-try">
    <h2 id="h-try"><span class="step-num" aria-hidden="true">03</span>What to try</h2>
    <ul class="points">
      <li><strong>Edit a view.</strong> It shows on the next reload: views are read from disk on every request.</li>
      <li><strong>Add a validation.</strong> Ruby is compiled, so a Ruby change is a full rebuild, about a minute, after which the server restarts by itself.</li>
      <li><strong>Carry on with the tutorial</strong> from <a href="tutorial.html#scaffold-comment">step 08, Scaffold comments</a>.</li>
      <li><strong>Start a fresh app.</strong> <code>cybertrain new</code> works in the codespace with no network.</li>
    </ul>
    <p class="note">The preview does not reload by itself: press its reload button after a change. Inside the preview, pop-ups and <code>confirm()</code> dialogs do not work; the Ports view's &ldquo;Open in Browser&rdquo; shows the app in a normal tab.</p>
  </section>

  <section class="step" id="docker" aria-labelledby="h-docker">
    <h2 id="h-docker"><span class="step-num" aria-hidden="true">04</span>Run it with Docker</h2>
    <p class="why"><span class="why-k">Why</span><span class="why-t">The same image runs on your own machine.</span></p>
    <figure class="code" data-lang="shell">
<figcaption><span class="code-path">terminal &mdash; any directory</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="Code: run the playground image"><code><span class="ln cmd">docker run --rm -it --init -p 3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground</span></code></pre>
</figure>
    <p>Then open <code>http://localhost:3000</code>. The published image is <code>linux/amd64</code>; on an arm64 machine, build it from a checkout as <a href="https://github.com/saeki-mototsune/CyberTrain/blob/main/playground/README.md" rel="noopener"><code>playground/README.md</code></a> describes.</p>
  </section>

  <section class="step step-last" id="where-next" aria-labelledby="h-where-next">
    <h2 id="h-where-next"><span class="step-num" aria-hidden="true">&rarr;</span>Where next</h2>
    <ul class="next-list">
      <li><a href="tutorial.html"><span class="next-t">The tutorial</span><span class="next-d">The blog from <code>cybertrain new</code> to <code>cybertrain build</code>.</span></a></li>
      <li><a href="https://github.com/saeki-mototsune/CyberTrain/blob/main/playground/README.md" rel="noopener"><span class="next-t"><code>playground/README.md</code></span><span class="next-d">The image, building it, and the Codespaces setup.</span></a></li>
      <li><a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener"><span class="next-t">CyberTrain on GitHub</span><span class="next-d">The source, the README and releases.</span></a></li>
      <li><a href="index.html"><span class="next-t">CyberTrain home</span><span class="next-d">Overview, features and how it works.</span></a></li>
    </ul>
  </section>

  </article>
</div>

</main>
HTML

File.write("site/playground.html", head + "\n" + main + footer)
puts "wrote site/playground.html"
```

Expected: `wrote site/playground.html`.

- [ ] **Step 4: Link the page from the other two pages and describe it in `site/README.md`**

In `site/index.html` and `site/tutorial.html`, add `Playground` to the primary nav between Tutorial and GitHub. In `site/index.html` replace

```html
        <li><a href="tutorial.html">Tutorial</a></li>
        <li><a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">GitHub<span class="ext" aria-hidden="true">&#8599;</span></a></li>
```

with

```html
        <li><a href="tutorial.html">Tutorial</a></li>
        <li><a href="playground.html">Playground</a></li>
        <li><a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">GitHub<span class="ext" aria-hidden="true">&#8599;</span></a></li>
```

and in `site/tutorial.html` replace

```html
        <li><a href="tutorial.html" aria-current="page">Tutorial</a></li>
        <li><a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">GitHub<span class="ext" aria-hidden="true">&#8599;</span></a></li>
```

with

```html
        <li><a href="tutorial.html" aria-current="page">Tutorial</a></li>
        <li><a href="playground.html">Playground</a></li>
        <li><a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">GitHub<span class="ext" aria-hidden="true">&#8599;</span></a></li>
```

In `site/index.html`, make the hero's buttons three (lines 56-59); replace

```html
          <a class="btn btn-primary" href="tutorial.html">Get started<span class="btn-arrow" aria-hidden="true">&rarr;</span></a>
          <a class="btn btn-ghost" href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">View on GitHub</a>
```

with

```html
          <a class="btn btn-primary" href="tutorial.html">Get started<span class="btn-arrow" aria-hidden="true">&rarr;</span></a>
          <a class="btn btn-ghost" href="playground.html">Try it in your browser</a>
          <a class="btn btn-ghost" href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">View on GitHub</a>
```

The closer and the footer of `index.html` stay as they are.

In `site/tutorial.html`, at the end of Step 00, replace

```html
    </details>
  </section>

  <section class="step" id="install" aria-labelledby="h-install">
```

with

```html
    </details>
    <p class="note">No machine to install on? The <a href="playground.html">playground</a> opens this blog in a GitHub Codespace with steps 02, 03, 04 and 07 already done.</p>
  </section>

  <section class="step" id="install" aria-labelledby="h-install">
```

In `site/README.md` (the spec's file list omits it, but its first paragraph names the pages), replace

```markdown
The CyberTrain homepage (`index.html`) and the getting-started tutorial
(`tutorial.html`): static HTML and CSS with no build step, no framework and
no third-party requests. `assets/site.js` only adds copy buttons and the
active tutorial step; every page works with JavaScript off.
```

with

```markdown
The CyberTrain homepage (`index.html`), the getting-started tutorial
(`tutorial.html`) and the playground page (`playground.html`, the way into
the GitHub Codespaces playground): static HTML and CSS with no build step, no
framework and no third-party requests. `assets/site.js` only adds copy
buttons and marks the current step in the contents lists; every page works
with JavaScript off.
```

In `site/assets/style.css`, directly after the line `.step .sub + .code { margin-top: 18px; }` (line 389), add the one new rule this task is allowed (a button row inside a step: `.cta-row` has a top margin only in the hero and the closer, lines 104 and 324, so without it the two buttons of section 01 sit directly under the "Why" line):

```css
.step > .cta-row { margin-top: 28px; }
```

- [ ] **Step 5: Run the checks to verify they pass**

```bash
ruby "${TMPDIR:-/tmp}/site_check.rb"
grep -c 'href="playground.html"' site/index.html site/tutorial.html
grep -c 'aria-current="page"' site/playground.html
grep -n '<body class="tutorial">\|<title>Try it in your browser · CyberTrain</title>' site/playground.html
git diff --stat -- site/assets
git diff -U0 -- site/assets/style.css | grep '^[+-][^+-]'
```

Expected: `site check: ok`; `site/index.html:2` and `site/tutorial.html:2`; `1`; both lines; `site/assets/style.css | 1 +` as the only change under `site/assets`; and the single added line `+.step > .cta-row { margin-top: 28px; }`.

Then look at the page: `python3 -m http.server -d site 8000` (the command in `site/README.md`) and open http://localhost:8000/playground.html at 1280 px and at 375 px wide (a screenshot from a browser tool is enough), and http://localhost:8000/index.html at 375 px. Check: no colour or element that `index.html` and `tutorial.html` do not already use; no horizontal scroll at 375 px; the contents list collapses below 900 px and jumps to each section; the three hero buttons wrap cleanly. In section 01 the button row must sit clearly below the "Why" line and the note clearly below the buttons, with spacing that matches the steps of `tutorial.html`; if 28 px looks uneven next to the 18-20 px gaps around it, change only that one value and say so in your report. Add no other CSS. Stop the server with Ctrl-C.

- [ ] **Step 6: Commit**

```bash
git add site/playground.html site/index.html site/tutorial.html site/README.md site/assets/style.css
git commit -m "Site: the playground page, Playground in the nav, the hero button and a hint in tutorial step 00

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Live check in a real codespace (spec §10.3, §11)

Steps are marked **[OWNER]** (only the repository owner can do it, or must approve it in chat) or **[EXECUTOR]**. Never type credentials; a browser signed in to GitHub is the owner's, and an agent may operate it only with the owner's permission in chat.

**Files:**
- Modify (temporarily): `.github/workflows/playground-image.yml` (the "TEMP: live check" commit, reverted in Step 9)
- Modify, only if a row of the decision table fails: `.devcontainer/devcontainer.json`, `playground/PLAYGROUND.md`, `playground/playground-server`, `README.md`, `site/playground.html`, `playground/README.md`
- Modify: `playground/README.md` (the "### Live check" results)
- Test: the L1-L12 checklist below

**Interfaces:**
- Consumes: everything from Tasks 1-8; in particular the exact strings listed under "Produces" in Tasks 5 (banner), 7 (README and `playground/README.md`) and 8 (`site/playground.html`), quoted again below where they are replaced.
- Produces: `ghcr.io/saeki-mototsune/cybertrain-playground:latest`, public, published from this branch; the results table in `playground/README.md`; a branch with no temporary trigger left (`git grep -n web-playground -- .github/` prints nothing).

- [ ] **Step 1: [EXECUTOR] The temporary trigger**

`workflow_dispatch` works only once the workflow is on the default branch, so for the live check a push to this branch publishes `latest` (the first `latest`, so nothing is overwritten). In `.github/workflows/playground-image.yml` replace

```yaml
    branches: [main]
```

with

```yaml
    branches: [main, web-playground] # TEMP: live check -- remove before merging
```

and replace

```yaml
            type=raw,value=latest,enable=${{ github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v')) }}
```

with

```yaml
            type=raw,value=latest,enable=${{ github.event_name == 'push' && (github.ref == 'refs/heads/main' || github.ref == 'refs/heads/web-playground' || startsWith(github.ref, 'refs/tags/v')) }}
```

Then:

```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/playground-image.yml"); puts "workflow parses"'
git add .github/workflows/playground-image.yml
git commit -m "TEMP: live check: publish latest from web-playground

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git rev-parse HEAD
```

Note the printed SHA: Step 9 reverts exactly this commit.

- [ ] **Step 2: [OWNER] Go-ahead to push**

Ask the owner in chat, and wait for a clear yes:

> May I push branch `web-playground` to origin? It holds the temporary "TEMP: live check" commit, so the "Playground image" workflow will build, smoke-test and publish `ghcr.io/saeki-mototsune/cybertrain-playground:latest` from this branch (a first run without cache takes 10-15 minutes). During the live check I would also push this branch again after any fallback fix and to remove the temporary trigger. No pull request yet.

- [ ] **Step 3: [EXECUTOR] Push and wait for the image**

```bash
git push -u origin web-playground
gh auth status
gh run list --workflow playground-image.yml --branch web-playground --limit 1
gh run watch "$(gh run list --workflow playground-image.yml --branch web-playground --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Expected: the run succeeds; its "Smoke test" step ends with `smoke: 29 passed, 0 failed` and "Push the tested image" pushes `ghcr.io/saeki-mototsune/cybertrain-playground:latest`. If `gh auth status` reports an invalid token, ask the owner to run `gh auth refresh -h github.com` themselves (never handle tokens) or to report the run's result from the repository's Actions page. A failed smoke step on amd64: read the step's log, fix the cause in this branch, commit, push again (covered by the go-ahead), and wait again.

- [ ] **Step 4: [OWNER] Make the package public**

Ask the owner: open github.com/saeki-mototsune → Packages → `cybertrain-playground` → Package settings; make sure the visibility is **Public** (Change visibility) and that the package is connected to the repository `saeki-mototsune/cybertrain` (Connect repository if not). Then **[EXECUTOR]** check anonymously, without touching any stored credentials:

```bash
token=$(curl -s "https://ghcr.io/token?scope=repository:saeki-mototsune/cybertrain-playground:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
  https://ghcr.io/v2/saeki-mototsune/cybertrain-playground/manifests/latest
```

Expected: `200`. Anything else means the package is not public yet: ask the owner again.

Then bring the dev container up on the published image (spec §10.2, item 3; on the Apple Silicon machine the linux/amd64 image runs under emulation, which is fine here). The CLI mounts the repository under `/workspaces/<name>`, so this checks the image and the configuration, not Codespaces' handling of `workspaceFolder` (L2 does):

```bash
docker image rm ghcr.io/saeki-mototsune/cybertrain-playground:latest 2> /dev/null
npx --yes @devcontainers/cli@0 up --workspace-folder . --skip-post-attach | tail -n 1
npx --yes @devcontainers/cli@0 exec --workspace-folder . sh -c 'id -un; pwd; uname -m'
npx --yes @devcontainers/cli@0 exec --workspace-folder . playground-server > "${TMPDIR:-/tmp}/devcontainer-server.log" 2>&1 &
code=000; for i in $(seq 1 60); do code=$(npx --yes @devcontainers/cli@0 exec --workspace-folder . curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/articles); [ "$code" = 200 ] && break; sleep 1; done; echo "$code"
docker rm -f $(docker ps -aq --filter "label=devcontainer.local_folder=$(pwd)")
```

Expected: the `up` line contains `"outcome":"success"`; `dev`, `/workspace/blog` and `x86_64`; `200`. The first command only drops a stale local tag, so that `up` pulls the published image; removing the container also ends the background `exec`. `--skip-post-attach` is needed because the CLI (0.89.0) runs `postAttachCommand` inside `up` and waits for it, and `playground-server` is a foreground server (found in Task 6; spec §10.2 says otherwise).

- [ ] **Step 5: [OWNER] Run the live checklist L1-L12**

In Chrome with a new browser profile (no `app.github.dev` cookies), the owner signs in to GitHub and opens `https://codespaces.new/saeki-mototsune/CyberTrain/tree/web-playground?quickstart=1` (the branch's `devcontainer.json` is used). About 20 minutes, under one core-hour. Write down what each row asks for; Step 8 records it.

| # | Do | Pass when | If not |
| --- | --- | --- | --- |
| L1 | Note the time; on the create page press **Create codespace**; note when the editor shows and when the preview shows the article list | The create page offers one "quick start" button and names the owner's account as the one billed; record both times in seconds | Record only; over 2 minutes to the preview: say so in the results (prebuilds are the owner's optional step) |
| L2 | Look at the Explorer and Source Control; in a new terminal run `pwd; ls -ld /workspaces; touch /workspaces/.probe && rm /workspaces/.probe && echo writable` | The Explorer root is BLOG with the app's files; `pwd` prints `/workspace/blog`; Source Control shows the blog repository with 0 changes; record the `ls`/`touch` output | The editor opens elsewhere or errors: Step 6, Fallback 1, then redo L2-L5. If `/workspaces` is not writable for `dev` either, stop and report to the owner: the Codespaces button cannot ship in SP1 |
| L3 | Look at the `server` terminal; in a new terminal run `uname -m; echo $CODESPACES; echo $CYBERTRAIN_SESSION_SAME_SITE $CYBERTRAIN_SESSION_PARTITIONED` | The banner and `* Listening on http://127.0.0.1:3000`; then `x86_64`, `true`, `None 1` | Variables missing: Step 6, fix for L3 |
| L4 | Touch nothing for 10 seconds after the Listening line | The preview opens by itself and shows the article list | Blank or stuck on "Verifying session": open Ports → port 3000 → Open in Browser once, then reload the preview. If that makes it work, it is the known private-port problem: Step 6, Fallback 2. Otherwise stop and report to the owner |
| L5 | In the preview: New article, a title and a body of 10 or more characters, Create. In DevTools on the preview's frame: `location.ancestorOrigins`. In a terminal: `curl -s -D - -o /dev/null http://127.0.0.1:3000/articles/new \| grep -i set-cookie`. Control: Ctrl-C the server, run `CYBERTRAIN_SESSION_SAME_SITE=Lax CYBERTRAIN_SESSION_PARTITIONED=0 playground-server`, create again; then Ctrl-C and run `playground-server` | 303 to the article's page (no 403); `ancestorOrigins` lists a `vscode-cdn.net` origin; the cookie line ends `SameSite=None; Max-Age=1209600; Secure; Partitioned`; the control run answers 403 (the problem is real) | 403 with the default settings: record the cookie line and `ancestorOrigins`, stop and report to the owner (the design's premise does not hold) |
| L6 | Repeat L4 and L5's create in Firefox and in Safari | Creating an article works in each | For each failing browser: Step 6, browser note |
| L7 | Change the `<h1>` in `app/views/articles/index.html.erb`, save, reload the preview. Then add `validates :body, presence: true, length: { minimum: 10 }` to `app/models/article.rb`, save, and time from the save to the new `=> Booting cybertrain 0.2.1` in the server terminal | The view edit shows; record the rebuild seconds | Over 120 s: Step 6, rebuild time |
| L8 | Reload the browser tab; then close it and reopen the codespace from github.com/codespaces. Each time, in a terminal: `pgrep -c -f '^/workspace/blog/build/bin/blog( \|$)'` | `1` each time; a new terminal says "already running", or the old terminal is restored | A second server: record `ps -eo pid,ppid,args --forest`, stop and report to the owner |
| L9 | github.com/codespaces → the codespace's menu → Stop codespace; then open it again | The server starts again; the article from L5 is still listed | Stop and report to the owner (adding `postStartCommand` is the owner's call) |
| L10 | Whether `PLAYGROUND.md` opened by itself at the first attach | Record only | Record only; the banner points to the guide either way |
| L11 | Ctrl-C the blog's server; run `cd .. && cybertrain new shop && cd shop && cybertrain g scaffold product name:string && cybertrain db migrate && cybertrain server`; then open the preview for port 3000 (Ports view → port 3000 → Preview in Editor) and create a product | Every command succeeds; creating a product answers 303, not 403 (Review Focus 2) | Record the failing output, stop and report to the owner |
| L12 | github.com/codespaces → Delete | Deleted | — |

With Fallback 1 in place, L2 expects `pwd` = `/workspaces/blog` and L8 counts `pgrep -c -f '^/workspaces/blog/build/bin/blog( \|$)'`.

Added by the whole-branch review (2026-10-02), recorded with the rows above:

- L1/L3: note whether the first server start compiled anything (the Listening line should follow the banner within seconds).
- L3: also run `id` and expect `uid=1000(dev)`; if Codespaces remapped the user, `/workspace/blog` and `/opt/*` belong to someone else, and the remedy is `"updateRemoteUserUID": false` in `devcontainer.json`.
- L2: also run `git -C /workspaces/* remote -v` and record the clone's URL (the image's two `insteadOf` rules match only the lower-case `https://github.com/saeki-mototsune/cybertrain`).
- L8: also close the `server` terminal with its trash icon, then count the servers again: the framework's dev loop treats SIGHUP as a restart request, so the app may survive as an orphan that keeps port 3000 and playground-server's lock. Record what happens; if a server survives without a terminal, add a line to `PLAYGROUND.md`'s "Good to know" on how to stop it (`pkill -f build/bin/`) as a Step 6 fix.
- Step 3: after the first push, look at the package page for `unknown/unknown` rows (none expected with `provenance: false`).
- Step 8: also record the smoke test's total time locally and on CI.

- [ ] **Step 6: [EXECUTOR] Apply the fallback for each failing row**

Skip this step when every row passed. Otherwise make the edits for each failing row, then: `bash -n playground/playground-server` if it changed; rebuild and smoke-test locally if `PLAYGROUND.md` or `playground-server` changed (`docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local . && bash playground/smoke.sh cybertrain-playground:local`, expect `smoke: 29 passed, 0 failed`); commit with the message given; push (covered by Step 2's go-ahead; the temporary trigger republishes `latest`); wait for the run as in Step 3; delete the old codespace, create a new one from the same link and redo the rows that changed.

**Fallback 1 (L2: `workspaceFolder` outside `/workspaces`).** Replace `.devcontainer/devcontainer.json` with spec §6.5's alternative:

```jsonc
{
  "name": "cybertrain playground",
  "image": "ghcr.io/saeki-mototsune/cybertrain-playground:latest",
  "remoteUser": "dev",
  "workspaceFolder": "/workspaces/blog",
  "onCreateCommand": "test -e /workspaces/blog || cp -a /workspace/blog /workspaces/blog",
  "postCreateCommand": "",
  "postAttachCommand": { "server": "playground-server /workspaces/blog" },
  "forwardPorts": [3000],
  "portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "customizations": {
    "vscode": {
      "settings": { "files.autoSave": "off" }
    }
  }
}
```

In `playground/README.md`, replace the bullet that starts ``- `workspaceFolder`: `/workspace/blog`,`` with

```markdown
- `workspaceFolder`: `/workspaces/blog`. Codespaces did not open the editor in `/workspace/blog` (live check L2), so `onCreateCommand` copies the prebuilt blog there with `cp -a`, which keeps the file times, so nothing is rebuilt.
```

the bullet ``- `postAttachCommand`: `playground-server`, on every attach (it is safe to run again).`` with

```markdown
- `postAttachCommand`: `playground-server /workspaces/blog`, on every attach (it is safe to run again).
```

and the bullet `- "Rebuild Container" starts again from the image: edits under `/workspace/blog` are lost, since only `/workspaces` survives a rebuild.` with

```markdown
- The blog lives under `/workspaces`, so edits survive "Rebuild Container".
```

Commit: `Playground: open the blog from /workspaces in Codespaces (live check L2)`.

**Fallback 2 (L4: the preview does not load a private port).** In `.devcontainer/devcontainer.json` replace `"onAutoForward": "openPreview"` with `"onAutoForward": "openBrowser"`. Then the wording moves from "the preview" to "a new tab" (spec §6.5, variant B); the banner fits both and stays. In `playground/PLAYGROUND.md` replace

```markdown
04 and 07). The development server runs in the terminal below and the preview shows
the app.
```

with

```markdown
04 and 07). The development server runs in the terminal below and the app opened in a
new browser tab (if it did not, use the Ports view's "Open in Browser" on port 3000).
```

replace `The preview does not reload by itself: after a change, press its reload button.` with `The page does not reload by itself: after a change, reload its tab.`; replace `   reload the preview. Views are read from disk on every request, so there is` with `   reload the app's tab. Views are read from disk on every request, so there is`; and replace

```markdown
- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab.
  Inside the preview, pop-ups and `confirm()` dialogs do not work.
```

with

```markdown
- If the app's tab did not open (a pop-up blocker), use the Ports view's "Open in
  Browser" on port 3000.
```

In `README.md` replace `in the editor's preview. The app is a git repository with one commit, so Source` with `in a new browser tab. The app is a git repository with one commit, so Source`; replace `server restarts by itself; the preview does not reload by itself. `cybertrain new`` with `server restarts by itself; the app's tab does not reload by itself. `cybertrain new``; and replace

```markdown
- Inside the preview, pop-ups and `confirm()` dialogs do not work; the Ports
  view's "Open in Browser" shows the app in a normal tab.
```

with

```markdown
- If the app's tab did not open (a pop-up blocker), use the Ports view's "Open
  in Browser" on port 3000.
```

In `site/playground.html` replace `the app in the editor's preview. Or run` with `the app in a new browser tab. Or run`; `and the app in the editor's preview. Nothing to install` with `and the app in a new browser tab. Nothing to install`; `<li>The app in the editor's preview, showing the article list.</li>` with `<li>The app in a new browser tab, showing the article list.</li>`; and

```html
<p class="note">The preview does not reload by itself: press its reload button after a change. Inside the preview, pop-ups and <code>confirm()</code> dialogs do not work; the Ports view's &ldquo;Open in Browser&rdquo; shows the app in a normal tab.</p>
```

with

```html
<p class="note">The app's tab does not reload by itself: reload it after a change. If the app's tab did not open (a pop-up blocker), use the Ports view's &ldquo;Open in Browser&rdquo; on port 3000.</p>
```

In `playground/README.md` replace the bullet that starts ``- `forwardPorts` and `portsAttributes`:`` with

```markdown
- `forwardPorts` and `portsAttributes`: port 3000, labelled `cybertrain`, opened in a new browser tab (`onAutoForward: openBrowser`) when the server starts listening: the editor's preview did not load the private forwarded port (live check L4). The cookie settings stay, since they work in a tab too and in a preview the visitor opens by hand.
```

and the bullet that starts `- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab.` with

```markdown
- If the app's tab did not open (a pop-up blocker), use the Ports view's "Open in Browser" on port 3000.
```

Commit: `Playground: open the app in a browser tab instead of the preview (live check L4)`.

**Fix for L3 (the cookie variables missing in a new terminal).** First record, in that terminal, `echo $0; shopt login_shell; grep -n cybertrain-playground /etc/bash.bashrc; ls -l /etc/profile.d/cybertrain-playground.sh`. Then add to `.devcontainer/devcontainer.json`, after the `"remoteUser": "dev",` line:

```jsonc
  "remoteEnv": {
    "CYBERTRAIN_SESSION_SAME_SITE": "None",
    "CYBERTRAIN_SESSION_PARTITIONED": "1"
  },
```

and to `playground/README.md`, after the ``- `remoteUser`: `dev`.`` bullet:

```markdown
- `remoteEnv`: the two cookie variables, because Codespaces terminals did not read the profile script (live check L3).
```

Commit: `Playground: set the cookie variables in remoteEnv (live check L3)`. This remedy is this plan's choice (the spec says only "find the path and fix it"): name it, with what you recorded, in your report to the owner.

**Browser note (L6).** For each browser in which creating an article failed (written `<browser>` below: `Firefox`, `Safari`, or `Firefox and Safari`), in `README.md` directly after the bullet about pop-ups (or its Fallback 2 replacement) add:

```markdown
- In <browser>, use the Ports view's "Open in Browser" instead of the preview.
```

in `site/playground.html` append ` In <browser>, use the Ports view's &ldquo;Open in Browser&rdquo; instead of the preview.` inside the `<p class="note">` of section 03, before `</p>`; and in `playground/PLAYGROUND.md` under "Good to know", after the first bullet, add `- In <browser>, use the Ports view's "Open in Browser" instead of the preview.` Commit: `Playground: Ports view note for <browser> (live check L6)`.

**Rebuild time (L7 over 120 s).** Round the measured seconds to whole minutes (written `N` below, for example `about two minutes`) and replace, in one commit: in `README.md`, `a Ruby edit is a full rebuild, about a minute, after which the` → `a Ruby edit is a full rebuild, about N minutes, after which the`; in `site/playground.html`, `a full rebuild, about a minute, after which` → `a full rebuild, about N minutes, after which`; in `playground/PLAYGROUND.md`, `After about a minute the` → `After about N minutes the` and `compiles it (about a minute)` → `compiles it (about N minutes)`; in `playground/playground-server`, the two banner lines `  Views reload on the next request. A Ruby change rebuilds the app (about a` and `  minute), then the server restarts by itself. Reload the page to see either.` → `  Views reload on the next request. A Ruby change rebuilds the app (about N` and `  minutes), then the server restarts by itself. Reload the page to see either.`; in `playground/README.md`, `would start a minute-long rebuild at every pause in typing` → `would start a rebuild of about N minutes at every pause in typing` and `- A Ruby edit is a full rebuild (about a minute); a view edit needs none.` → `- A Ruby edit is a full rebuild (about N minutes); a view edit needs none.` Commit: `Playground: rebuild time from the live check (L7)`.

- [ ] **Step 7: [OWNER] Recheck after any fix**

For every fix pushed in Step 6, the owner deletes the old codespace, creates a new one from the same link once the run from Step 3 has republished `latest`, and redoes the rows that changed (Fallback 1: L2-L5; Fallback 2: L4-L5; L3 fix: L3, L5; L7 wording: L7). Skip when Step 6 was skipped.

- [ ] **Step 8: [EXECUTOR] Record the results**

At the end of the "## Codespaces" section of `playground/README.md` (after the bullet about deleting a codespace, before "## Smoke test"), add this subsection, filling every Result cell with what was observed and measured (seconds where the row asks for a time) and naming any fallback applied:

```markdown
### Live check

On <date>, from branch `web-playground`, on the default 2-core machine, in Chrome <version> (a new profile), Firefox <version> and Safari <version>:

| # | What | Result |
| --- | --- | --- |
| L1 | Link → editor → preview | Quick start page with one button, billed to the visitor: <yes/no>; editor after <s> s, preview after <s> s |
| L2 | `workspaceFolder` outside `/workspaces` | Explorer root, `pwd`, Source Control: <observed>; `/workspaces`: <ls -ld output>, <writable or not> |
| L3 | Terminals and variables | `uname -m` <value>, `CODESPACES` <value>, cookie variables <values> |
| L4 | Automatic preview of the private port | <opened by itself / needed Open in Browser first / did not load> |
| L5 | Cookie and CSRF in the preview | Create: <303 or 403>; `ancestorOrigins`: <origin>; Set-Cookie ends <...>; control run with Lax: <403 or other> |
| L6 | Firefox, Safari | Firefox: <works/fails>; Safari: <works/fails> |
| L7 | Edit loop | View edit on reload: <yes/no>; save to restart after a Ruby edit: <s> s |
| L8 | `postAttachCommand` again | Reload: <servers>; reopen: <servers> |
| L9 | Stop and resume | <server back, article kept / what happened> |
| L10 | Guide opened by itself | <yes/no> |
| L11 | A fresh app | <all commands passed; product created with 303 / what failed> |
| L12 | Clean-up | Codespace deleted |

Fallbacks applied: <none, or the Step 6 commits by name>.
```

```bash
git add playground/README.md
git commit -m "Playground: live check results in playground/README.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 9: [EXECUTOR] Remove the temporary trigger and push**

Revert the SHA noted in Step 1:

```bash
git revert --no-commit <the SHA from Step 1>
git diff --cached --stat
git commit -m "Remove the TEMP live-check trigger from the playground image workflow

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git grep -n 'web-playground' -- .github/
git push
```

Expected: the staged diff touches only `.github/workflows/playground-image.yml` (2 lines); `git grep` prints nothing; the push succeeds (covered by Step 2's go-ahead). With the trigger gone, this push runs `ci.yml` only and publishes nothing.

---

### Task 10: Final checks before the pull request

**Files:**
- Test only: no file changes unless a check fails (then fix the cause in the task's files and commit separately)

**Interfaces:**
- Consumes: the whole branch after Task 9.
- Produces: a verified branch and, with the owner's go-ahead, the pull request.

- [ ] **Step 1: Run the full framework suite in the background**

```bash
spin test > "${TMPDIR:-/tmp}/spin-test-full.log" 2>&1; echo "exit=$?" >> "${TMPDIR:-/tmp}/spin-test-full.log"
```

Run it in the background (it takes over 180 s) and carry on with Steps 3 and 4, which do not use spin; start Step 2 once this log has its `exit=` line. Then `tail -n 3 "${TMPDIR:-/tmp}/spin-test-full.log"`. Expected: `66/66 passed` and `exit=0`.

- [ ] **Step 2: The example app and generated code**

```bash
cd examples/blog && spin test && spin run gen > /dev/null && git diff --exit-code -- gen/ && echo "gen/ is fresh"; cd ../..
```

Expected: `2/2 passed` and `gen/ is fresh`.

- [ ] **Step 3: Version, gem and trigger checks**

```bash
git grep -n '0\.2\.0' -- . ':!docs/superpowers/'
version=$(ruby -I. -e 'require "cybertrain/version"; print Cybertrain::VERSION'); grep -q "^version = \"$version\"$" spin.toml && echo "spin.toml matches $version"
gem build cybertrain.gemspec --output "${TMPDIR:-/tmp}/cybertrain-check.gem"
git grep -n 'web-playground' -- .github/
jq empty .devcontainer/devcontainer.json && echo "devcontainer.json is valid JSON"
git status --short | grep -v '^??'
```

Expected: only `test/cli_new.rb:175` and `test/cli_new.rb:176`; `spin.toml matches 0.2.1`; `Successfully built RubyGem` with `Version: 0.2.1`; nothing from the trigger grep; `devcontainer.json is valid JSON` (the same `jq empty` check the workflow runs); nothing from the last command (no modified tracked file; untracked entries such as `.playwright-mcp/` are filtered out).

- [ ] **Step 4: The site content rule**

Save as `${TMPDIR:-/tmp}/content_rule.rb` and run `ruby "${TMPDIR:-/tmp}/content_rule.rb"`:

```ruby
# Every fact and command of site/playground.html must be in README.md's
# "Try it in the browser" (site/README.md's content rule), with the same
# wording where a live-check fallback changed it.
def read(path) = File.read(path, encoding: "UTF-8")

readme = read("README.md")[/^## Try it in the browser\n.*?(?=^## )/m] or abort "README.md: no section"
readme = readme.delete("`").gsub(/\s+/, " ").downcase
html = read("site/playground.html")
# The text without tags, plus every link target (the Codespaces link is an href).
page = html.gsub(/<[^>]+>/, " ") + " " + html.scan(/href="([^"]+)"/).flatten.join(" ")
page = page.gsub("&nbsp;", " ").gsub("&ldquo;", "\"").gsub("&rdquo;", "\"").gsub("&rsquo;", "'").gsub("&amp;", "&")
page = page.gsub(/\s+/, " ").downcase
facts = [
  %r{codespaces\.new/saeki-mototsune/cybertrain\?quickstart=1},
  /spinel 2026\.09\.12/,
  /a github account is required/,
  /120 core-hours and 15 gb-month of storage a month/,
  /about 60 hours on the default 2-core machine the playground uses/,
  /stops an idle codespace after 30 minutes by default/,
  /its storage counts until you delete it/,
  /a git repository with one commit/,
  /a full rebuild, about (a minute|\w+ minutes)/,
  /the server restarts by itself/,
  /(the preview|the app's tab) does not reload by itself/,
  /(pop-ups and confirm\(\) dialogs do not work|if the app's tab did not open \(a pop-up blocker\))/,
  /open in browser/,
  /with no network/,
  %r{docker run --rm -it --init -p 127\.0\.0\.1:3000:3000 -e cybertrain_host=0\.0\.0\.0 ghcr\.io/saeki-mototsune/cybertrain-playground},
  %r{linux/amd64},
  %r{http://localhost:3000},
  %r{playground/readme\.md}
]
missing = facts.reject { |fact| readme[fact] && page[fact] && readme[fact] == page[fact] }
missing.each { |fact| puts "not the same in README.md and site/playground.html: #{fact.source}" }
puts(missing.empty? ? "content rule: ok (#{facts.size} facts)" : "content rule: FAILED")
exit(missing.empty? ? 0 : 1)
```

Expected: `content rule: ok (18 facts)`. Then compare the two by eye once: every sentence of the page's sections 01-04 must say what the README section says (the site rule binds meaning, not only these phrases).

- [ ] **Step 5: The smoke test on a fresh build**

```bash
time docker build --no-cache -f playground/Dockerfile --target playground -t cybertrain-playground:local .
bash playground/smoke.sh cybertrain-playground:local 2>&1 | tail -n 1
```

Expected: the build succeeds; `smoke: 29 passed, 0 failed`.

- [ ] **Step 6: [OWNER] Go-ahead, push and the pull request**

Ask the owner in chat, with the results of Steps 1-5, and wait for a clear yes:

> All final checks pass (spin test 66/66, examples/blog 2/2, smoke 29/29 on a fresh build, the live check recorded in playground/README.md, no temporary trigger). May I push `web-playground` and open the pull request into `main`?

Then:

```bash
git push
gh pr create --base main --head web-playground --title "Web playground SP1: shared image, Codespaces, site entry, cookie settings (0.2.1)" --body "$(cat <<'EOF'
## Summary
- Framework 0.2.1: `CYBERTRAIN_HOST`, `CYBERTRAIN_SESSION_SAME_SITE` (Lax, Strict or None; checked at boot) and `CYBERTRAIN_SESSION_PARTITIONED`; `SameSite=None` and `Partitioned` imply `Secure`.
- `playground/`: the image `ghcr.io/saeki-mototsune/cybertrain-playground` (toolchain, offline framework mirror, prebuilt tutorial blog), `playground-server`, the Codespaces profile and `smoke.sh` (29 checks).
- `.devcontainer/devcontainer.json` and `.github/workflows/playground-image.yml`: build linux/amd64, smoke-test, push only the tested image.
- Entry points: `site/playground.html`, the nav, the hero button and a hint in tutorial step 00, the README's "Try it in the browser", `playground/README.md`.

## Test plan
- [x] `spin test` 66/66; `examples/blog` 2/2; generated code fresh
- [x] `bash playground/smoke.sh` on a fresh `--no-cache` build: 29 passed
- [x] Codespaces live check L1-L12 from this branch (results in playground/README.md)
- [ ] CI and "Playground image" green on this pull request

Spec: docs/superpowers/specs/2026-10-02-web-playground-sp1-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Use the pull-request attribution line your session specifies if it differs from the last line above.

After the merge, the owner's own steps (spec §11, not part of this plan): Pages publishes the site and the `main` run pushes `latest` again; `git tag v0.2.1 && git push origin v0.2.1`, then check that the tag's "Playground image" run pushed `0.2.1` and `latest` (if it did not run: Run workflow with tag `0.2.1`, then with `latest`); `gem build cybertrain.gemspec && gem push cybertrain-0.2.1.gem`; optionally set up Codespaces prebuilds.

---

## Spec coverage

| Spec | Task |
| --- | --- |
| §3.1-3.6 the three variables, Secure rules, boot check, signatures | 1 (`Cookies.serialize`, `SessionStore`), 2 (`Config`, `Application`) |
| §3.7 tests | 1, 2; `integration_m1` in 3; boot `exit(1)` by smoke F1 (4, 5) |
| §3.8 README table, D14, template and example comments | 3 |
| §3.9 version 0.2.1 and every place it is written | 3 |
| §4.1-4.6 Dockerfile, build context, mirror, labels, layout | 5 |
| §5.1-5.2 the blog's route file and `PLAYGROUND.md` | 5 |
| §6.1 devcontainer.json | 6 |
| §6.2-6.3 `playground-server`, profile script | 5 |
| §6.4 deep link | 7, 8 (links), 9 (L1) |
| §6.5 fallbacks 1 and 2, variant B wording | 9 (Step 6) |
| §7.1-7.3 site page, nav, hero, tutorial hint | 8 |
| §7.4 README section, Learn more, Releasing | 7 (version numbers in 3) |
| §7.5 `playground/README.md` | 7 (live-check results in 9) |
| §8.1 workflow | 6 (temporary trigger in 9) |
| §8.2 smoke test | 4 (26 checks), 5 (D3, D4, C3; B2 and B3 in `/workspace`) |
| §9 file table | 1-8; plus `site/README.md` (8), which describes the pages |
| §10.1 automated | 1-6, 10 |
| §10.2 local build, smoke, devcontainer CLI | 5, 6 (Step 6) |
| §10.3 live checklist and decision table | 9 |
| §11 owner's steps | 9 (1-4), 10 (5-8 after the merge) |
| §12 risks | Global Constraints, 5 (Step 6 note), 9 |
