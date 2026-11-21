# spinel-http: the HTTP server as a package of its own

Date: 2026-11-21. Status: draft for the maintainer's approval. Section 2
records what the maintainer decided; everything marked *author's call* is a
proposal they can correct.

## 1. Why

cybertrain's HTTP layer (`cybertrain/http/`, 18 files, about 5,800 lines)
is a complete HTTP/1.1 server written for Spinel: keep-alive and
pipelining, a green thread per connection, graceful drain (D14),
`SO_REUSEPORT` (D35), streamed bodies and Server-Sent Events, multipart
uploads, cookies, trusted-proxy client IPs, gzip request bodies. Today a
Spinel user who wants a small API server or a tool with an HTTP endpoint
has to take all of cybertrain (routing, models, views, SQLite) to get it.

The goal is to publish that layer on
[spin-index](https://github.com/matz/spin-index) as `spinel-http`, for
**Spinel users who do not need Rails**, so that

```toml
[dependencies]
spinel-http = "0.1.0"
```

and a handler of a few lines give them a production-grade server.

## 2. Decided with the maintainer

1. Publish under the name **spinel-http**.
2. The audience is Spinel users who do not need a Rails-shaped framework.
3. **Approach A**: the code lives only in the `spinel-http` repository, and
   cybertrain depends on it through `spin.toml` (section 4).

## 3. Goals, non-goals, anti-goals

Goals

- G1. `spin add spinel-http` under **upstream Spinel** (matz/spinel's latest
  release when publishing; today `2026.10.25`) builds and serves. Without
  that the audience cannot use it, since they do not run the
  saeki-mototsune fork.
- G2. The same package builds under the fork release cybertrain pins
  (`Cybertrain::SPINEL_TAG`), and cybertrain runs on it with no behaviour
  change: every existing cybertrain test passes unchanged in what it
  asserts.
- G3. A small public surface: `Server`, the `Handler` base class,
  `Request`, `Response`, plus the parsers a server needs (query strings,
  forms, cookies, SSE). One page of README gets someone from `spin new` to
  a running server.
- G4. Published to spin-index by `spin publish`, a manual release step as
  for cybertrain (CONTRIBUTING.md, "Publishing to the spin index").

Non-goals

- Routing, middleware, sessions, CSRF, templates, i18n: they stay in
  cybertrain. A user of spinel-http routes on `request.path_segments` in
  their own handler.
- Rack compatibility, HTTP/2, TLS termination (a proxy does that, as it
  does for cybertrain today).
- The outbound client (`HttpClient`), WebSocket and the mailer: possible
  later packages, not this one.
- Publishing cybertrain itself to the index (its own decision, unchanged).

Anti-goals (a failure even if everything else works)

- cybertrain gets slower to build or to serve. The HTTP layer is on every
  request's path, and compile time is a measured concern
  ([optional subsystems](2026-11-13-optional-subsystems-design.md)).
  The `bench/` numbers and a scaffolded application's build time are
  measured before and after. *Author's call on the line*: on one machine,
  each `bench/` scenario's median of 5 runs within 3% of before, and a
  scaffolded application's cold and incremental builds (median of 3)
  within 5%; anything past that is reported to the maintainer before it
  lands.
- A cybertrain application has to change its own code, or its
  `spin.toml` beyond what `cybertrain` writes for it.
- spinel-http carries cybertrain concepts in its API (a `log_scope`, a
  `format_extension`, `I18n`), so it reads as "cybertrain's internals,
  exported".

## 4. Approaches (the maintainer picked A)

- **A. cybertrain depends on spinel-http.** One source of the server; every
  cybertrain test exercises it. Costs: a change to the HTTP layer is a
  spinel-http release, then a cybertrain lock update; spinel-http must
  build under two Spinels. *Picked*: one source means outside fixes reach
  cybertrain, and the HTTP layer is stable enough that two-step releases
  are rare.
- B. Copy once, grow apart. Fastest to publish, nothing changes for
  cybertrain, but every fix is made twice and the two drift.
- C. Develop in CyberTrain, mirror to a publishing repository by script.
  The namespace (`Cybertrain::` versus spinel-http's) has to be rewritten
  on every sync, which is brittle and makes outside pull requests awkward.

## 5. Name, repository, namespace

- Index name **`spinel-http`**, repository
  **`https://github.com/saeki-mototsune/spinel-http`** (author's call on
  the owner). The index's convention is "name = the rubygems.org gem's
  name, repository `spinel-<name>`", and a shared name means "the same
  library". `http` on rubygems.org is http.rb, an HTTP *client*, so taking
  `http` would claim to be its port. `spinel-http` is not a gem name, so
  the package keeps the prefix in its name; `spin new --lib`'s comment
  (repository `spinel-spinel-http`) is a convention `spin publish` does not
  check, and the doubled prefix is not used.
- Entry `spinel-http.rb` (what `spin new spinel-http --lib` writes),
  files under `spinel_http/`, module **`SpinelHttp`** (author's call:
  Ruby's usual mapping of a hyphenated gem name, and no claim on a
  `Spinel` namespace the compiler project may want).
- License MIT, as cybertrain. Version starts at `0.1.0`.
- The repository has to be created by the maintainer (this session cannot
  create repositories).

## 6. What moves, what stays

Moves to spinel-http (renamed into `SpinelHttp`):

| File | Notes |
| --- | --- |
| `server.rb`, `handler.rb`, `parser.rb`, `body_writer.rb`, `header_name.rb`, `stream_failure.rb`, `client_error.rb` | the core. `PortInUse` messages lose `CYBERTRAIN_HOST`, `PORT` (section 7) |
| `request.rb`, `response.rb` | minus the cybertrain-only parts (section 7) |
| `query.rb`, `cookies.rb`, `sse.rb`, `ip_address.rb` | parsers a server needs |
| `multipart.rb`, `uploaded_file.rb` | behind `require "spinel-http/multipart"` (author's call: a small API server should not compile it) |
| `gzip_ffi.rb`, `gzip_decoder.rb` | behind `require "spinel-http/gzip"`: it links zlib (`ffi_lib "z"`), which the user's machine must have |
| the nested-params structure of `params.rb` that `Query` and `Multipart` fill | see section 7 |

cybertrain itself always requires both, so its applications keep gzip
request bodies and uploads with no change (*author's call*; anti-goal 2).
A plain `require` is the mechanism, not spin's `--features`, since that is
how cybertrain's own optional subsystems work.

Stays in cybertrain: `parameter_filter.rb` (log filtering, tied to
`Token` and the logger), `ContextHandler`, middleware, the router,
strong parameters (`require`/`permit`, `ParameterMissing`), locale
negotiation's default, request ids and log scopes, `Dev::ErrorPage`.

Tests move with their code: `test/server.rb`, `http_parser`,
`http_request`, `http_response`, `query`, `query_extras`, `cookies`,
`sse`, `multipart`, `uploaded_file`, `http_gunzip` (and their
`.expected`), adapted to the new names. Tests that exercise cybertrain on
top (`multipart_app`, `http_caching`, `cookie_jar`, the integration and
e2e scripts) stay. The `.expected` snapshot style (`spin test`) is kept,
since `spin publish` runs `spin test`.

## 7. Cutting the ties

Each tie the HTTP layer has to the rest of cybertrain, and how it is cut.
The pattern is one cybertrain already uses for `StreamFailure` and
`Request.inflater`: spinel-http defines a base class with a plain default,
and cybertrain installs a subclass at boot.

| Tie | Today | After |
| --- | --- | --- |
| Logging | `Logger` calls in server, request, response, body_writer | spinel-http defines `SpinelHttp::Log`, a sink with the few calls the server makes (a default that writes to stderr). cybertrain installs one that forwards to `Cybertrain::Logger` |
| Log scope | `Request#log_scope` (`Logger::Scope`): `Server#handle` logs a handler's exception under it (`classify_scoped`, the line must carry the request's id), and `Response#body_scope` carries `Logger.current_scope` to a streamed body's writer thread (`run_writer_scoped`) | *author's call*: spinel-http keeps both slots as an opaque **log context**: a base class `SpinelHttp::LogContext` with no behaviour, `Request#log_context` and `Response#body_log_context` hold one, and the `Log` sink is handed it with every line and asked to "enter" it on the writer thread. cybertrain's `Logger::Scope` becomes a subclass, so its behaviour (and every log line that carries a request id today) is unchanged. A general hook, since any user may want per-request fields in their log lines; rejected: moving the scope into `Context` (the server cannot see it, and those lines would lose the id) |
| Request id | `Request#request_id` | stays as a plain string attribute the server echoes as `X-Request-Id` when set: a general feature, not cybertrain's |
| Params | `Query.parse` fills a `Cybertrain::Params` | the structure (nested values, lists, uploads) moves as `SpinelHttp::Params`; cybertrain's strong-parameter methods are added on top. How (reopening the class, a subclass `Query` is told to build, or a wrapper) is settled by the spike (section 9), since what Spinel compiles well decides it |
| `I18n.default_locale` | `Request#preferred_locale` | the default becomes an argument: `preferred_locale(available, default)`; cybertrain passes `I18n.default_locale` |
| Formats | `format_extension=` set by the Router; `format`, `mime_type` | the Accept and MIME tables are general and move; the setter stays, documented as "set by your router" |
| `Html.escape` | query, cookies | a private copy of the byte-level escape in spinel-http |
| Error classes | `QueryInvalid` and friends under `Cybertrain::` | defined in `SpinelHttp`; cybertrain refers to them there. Constant aliases (`Cybertrain::QueryInvalid = SpinelHttp::QueryInvalid`) keep cybertrain's own code and applications' `rescue` lines working, if Spinel compiles them (spike) |
| Multipart limits | installed from `Config` by `Application#boot` | stays: a setter on `SpinelHttp::Multipart`, called by cybertrain's boot |
| Messages naming cybertrain settings | `PortInUse` names `CYBERTRAIN_HOST`, `PORT` | spinel-http's messages name the server's own arguments; cybertrain's `Application#serve` adds its setting names when it prints them |

`Cybertrain::Server`, `Request`, `Response` and `HttpHandler` remain
reachable under their current names, by constant alias or a thin
subclass, so neither cybertrain's code nor an application changes
(anti-goal 2). Which one is a spike question.

## 8. How cybertrain depends on it

- Until spinel-http is in the index: `spinel-http = { git =
  "https://github.com/saeki-mototsune/spinel-http", ref = "vX.Y.Z" }` in
  cybertrain's `spin.toml`, pinned by `spin.lock`, as applications pin
  cybertrain today. After: `spinel-http = "X.Y.Z"`.
- An application gets spinel-http transitively; `cybertrain new` writes
  nothing new. To check (step 2): that spin resolves a dependency's
  dependency through a git dependency, and that `spin flags` names
  spinel-http's directory, which `cybertrain test`, the preview runner
  and `script/check-core-closure` read.
- Checked 2026-11-21 with spin of the pinned fork: an application that
  depends by git on package A, which depends by git on package B, locks
  both (`spin.lock` gets `[lock.a]` and `[lock.b]`), and `spin flags`
  and `spin run` find B. So the transitive route works. An existing
  application that bumps only cybertrain's version gets spinel-http when it
  relocks, which the upgrade instructions (docs/deploy.md) already have it
  do; it must keep building with no other edit (anti-goal 2).
- The setup-cybertrain action and the blog and playground images fetch
  through spin, so they are expected to need no change; checked in step 4.
- Release order for a change to the HTTP layer: spinel-http release, then
  cybertrain bumps the version in `spin.toml` and relocks. Version policy:
  cybertrain names one exact spinel-http release (`"X.Y.Z"`), because the
  index selects the lowest release that satisfies a constraint, so a
  range would pin the oldest one for good (design.md, the 2026-11-14
  revision of the package decision).

## 9. Steps

1. **Spike, throwaway** (no tests beyond running it): copy `cybertrain/http/`
   and the files it reaches into a scratch package, stub the ties of
   section 7, build a hello-world handler under upstream `2026.10.25` and
   under the fork. It answers: does the HTTP layer compile under upstream
   at all, and which NOTES rules or fork-only fixes it relies on; whether
   constant aliases, class reopening and a subclass installed at boot
   compile and keep their static types. If upstream fails in ways a
   workaround in spinel-http cannot fix, stop and come back to the
   maintainer: G1 would then wait on an upstream release.
2. **Cut the ties inside CyberTrain** (section 7), still under
   `Cybertrain::`, with every test passing. This is worth doing even if
   publishing stalls, and it is the riskiest step for cybertrain, so it
   lands as its own pull request, with the bench and build-time
   comparison.
3. **Create spinel-http**: move the files and tests, rename into
   `SpinelHttp`, README with the hello-world server, CI running `spin test`
   under upstream and under the fork.
4. **Point cybertrain at it** by git tag: delete the moved files, add the
   aliases, the dependency, update `script/check-core-closure`, design.md
   (a new D-entry), the guides that list what is in the framework, and
   CONTRIBUTING (the two-step release). Bench and build time again.
5. **Publish**: `spin publish --repo https://github.com/saeki-mototsune/spinel-http`
   run by the maintainer **with upstream Spinel**, so the index's probe
   records the compiler the audience has. Then switch cybertrain's
   dependency to the index version.

## 10. Left to the builder

- The exact methods of `SpinelHttp::Log`, from the calls the server makes.
- Which mechanism carries strong parameters and the old constant names
  (section 7), from the spike.
- Workarounds needed for upstream Spinel, each recorded in spinel-http's
  own notes with the upstream issue, in the style of `spikes/NOTES.md`.
- Splitting `Request` (1,336 lines) further, if it helps; not required.
