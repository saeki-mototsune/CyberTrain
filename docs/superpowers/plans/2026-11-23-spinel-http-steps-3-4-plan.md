# spinel-http steps 3 and 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move cybertrain's HTTP layer into its own Spinel library, saeki-mototsune/spinel-http (module `SpinelHttp`), release it as a tagged git version, and make cybertrain depend on it without any application changing its code.

**Architecture:** spinel-http is a spin library: `spin.toml` plus `spinel-http.rb` and `spinel-http/*.rb` at the repository root, so a program writes `require "spinel-http/server"`. Multipart and gzip stay optional requires. cybertrain declares `spinel-http = { git = "https://github.com/saeki-mototsune/spinel-http", ref = "v0.1.0" }` and pins it with `spin.lock`. It keeps each public name and require path: each moved file becomes a shim that requires the new file and sets a constant alias (`Cybertrain::Server = SpinelHttp::Server`).

**Tech Stack:** Spinel. Fork 2026.11.15.7033 is what cybertrain builds with; upstream matz/spinel 2026.10.25 is at `~/.spinel-upstream/2026.10.25`. Also spin (packages, `spin test`, `spin lock`) and GitHub Actions.

**Spec:** `docs/design.md` D91. The binding text is its bullets "Decided with the maintainer, and binding on steps 3 to 5", "Known limits" and "Still to do, from the design (steps 3 to 5)". Earlier history is in `git show 5874a49:docs/superpowers/specs/2026-11-21-spinel-http-extraction-design.md`.

## Global Constraints

- **Upstream first.** spinel-http must build and pass its tests under upstream Spinel 2026.10.25 and under the fork. A workaround that upstream needs is taken even when it costs cybertrain something, but only within the measurement line. If upstream fails in a way spinel-http cannot work around, stop and report to the maintainer.
- **No application change.** No cybertrain application changes its code, or its `spin.toml` beyond what `cybertrain` writes for it. These stay exactly as they are:
  - `preferred_locale`;
  - `Params#permit`, `#require` and `#expect`;
  - `rescue Cybertrain::PortInUse`;
  - every message `cybertrain server` prints;
  - `require "cybertrain/http/gzip_ffi"`, which docs/guide/external-services.md documents.
- **No cybertrain concept in spinel-http's API or comments.** That excludes `log_scope`, `format_extension`, `I18n`, `Config`, `CYBERTRAIN_*` and names such as ContextHandler, Controller and RequestId.
- **Upstream workarounds are recorded in spinel-http's own NOTES.md**, each with the upstream issue, in the style of spikes/NOTES.md. Rule 126 (statement, then assert) moves there.
- **Measurement line:** wrk median within 3%, build median within 5%, measured in the same session, interleaved A,B,A,B. Past the line, report to the maintainer before landing.
- **NOTES rule 34:** one method name has one return type across the whole program. This now spans both repositories.
- **Pushing:** the builder pushes branches and tags to spinel-http, and the maintainer approved that. `spin publish` (step 5) is the maintainer's, so do not run it.
- **cybertrain's own conventions apply to cybertrain changes:** CONTRIBUTING.md, `script/gate`, `.githooks/commit-msg`, and `.expected` snapshots for every test.

## Review Focus

1. **Reopening through an alias.** cybertrain/params.rb, i18n.rb and logger.rb reopen `Cybertrain::Params`, `Request` and the log classes. Once these are aliases of `SpinelHttp::` classes, a reopening must add methods to the same class object, and must not create a new `Cybertrain::Params`. The spike, Task 0, proves this; Task 5's tests pin it.
2. **`Class#name` changes.** Once aliased, `Cybertrain::Params::ParameterMissing.name` answers `"SpinelHttp::Params::ParameterMissing"`. String-based fault lists, such as `CLIENT_FAULTS`, `extra_faults` and `job_scan.rb`, would silently stop matching and turn a 400 into a 500. Task 5 tests a missing parameter → 400 and a malformed query → 400 through the full cybertrain stack.
3. **A cybertrain app built from a git checkout or a path dependency** must still find spinel-http, transitively, through spin.lock, with `cybertrain new` writing nothing new. Task 5 runs the CLI end-to-end tests: test/cli_new.rb, test/cli_build.rb and the setup-cybertrain action.
4. **A server with neither multipart nor gzip loaded.** A multipart POST must get a 415 client fault and `multipart_boundary` must answer `""`. A gzip body must get the existing "no inflater is installed" fault. Task 3 tests both.
5. **Rule 34 across the two repositories.** A method name defined in spinel-http with one return type and in cybertrain with another would compile but miscompile. Task 5 makes `script/check-reserved-names` read spinel-http's source as well.

---

### Task 0: Spike: the mechanisms steps 3–4 rely on

Throwaway programs in a scratch directory outside both repositories. Record the results in `spikes/spinel-http/step3/README.md` in cybertrain, one line per question with the compiler, the command and the result. Compile everything under both the fork and upstream.

**Files:**
- Create: `spikes/spinel-http/step3/README.md` and one small program per question in that directory.

**Interfaces:**
- Produces: answers that Tasks 1–5 depend on. If any answer is "no" under either compiler, STOP and report. This is the maintainer's stop condition.

- [ ] **Step 1: Git dependency resolution.** Make a local bare git repo holding a library `demo-lib`, with `demo-lib.rb` and `demo-lib/a.rb`. Make it a git dependency (`{ git = "file:///…", ref = "v0.0.1" }`) of a library `mid`, and make `mid` a path dependency of an app. In the app, `require "demo-lib/a"` from a file of `mid`. Run `spin lock`, `spin build` and `spin test`. Expected: it builds and spin.lock lists demo-lib.
- [ ] **Step 2: Class alias.** `module A; class K; def x = 1; end; end`, then `module B; K = A::K; end`. Check:
  - `B::K.new.x == 1`;
  - `class Sub < B::K; end` works;
  - `rescue B::E` catches `A::E`;
  - `B::K.name == "A::K"`;
  - `B::K.equal?(A::K)`.
- [ ] **Step 3: Reopening through an alias.** After the Step 2 alias, write `module B; class K; def y = 2; end; end`. Expected: `A::K.new.y == 2`, which means the same class object, not a new `B::K`. Also try the form cybertrain/params.rb actually uses; read that file and reproduce its `module Cybertrain; class Params` shape. If plain reopening through an alias fails, try `A::K.class_eval`-free alternatives that Spinel supports, such as reopening `A::K` by its real name, and record which one works.
- [ ] **Step 4: Module alias and module methods.** `module A; module M; def self.f = 3; end; end`, then `module B; M = A::M; end`. Expected: `B::M.f == 3`. This covers `Cookies` and `Key`. Also check that a module-level `attr_accessor` slot set through `B::M` is seen through `A::M`. This covers class-level slots such as `Params.max_page` and `ClientError.extra_faults`.
- [ ] **Step 5: Run and record.** Run each program under the fork and under upstream (`PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH`). Write the README table. Commit it on cybertrain's branch:

```bash
git add spikes/spinel-http/step3
git commit -m "spikes: spinel-http step 3, aliases, reopening and git dependencies under both compilers"
```

### Task 1: spinel-http repository scaffold, test helper and CI

**Files** (all under `/home/user/spinel-http`, branch `main`; the repository is empty):
- Create: `spin.toml` (`name = "spinel-http"`, `version = "0.1.0"`, no dependencies).
- Create: `spinel-http.rb`: requires `spinel-http/server`, the usual entry point.
- Create: `test/support/check.rb`: the assertion helper.
- Create: `test/check.rb` and `test/check.rb.expected`.
- Create: `NOTES.md` (upstream workaround rules), `README.md` (a stub, finished in Task 4), `LICENSE` (copied from cybertrain's) and `.gitignore` (`build/`).
- Create: `script/check-standalone`, `.github/workflows/ci.yml` and `.github/actions/setup-spinel/action.yml`.

**Interfaces:**
- Produces: `SpinelHttpTest` in `test/support/check.rb`, used by every spinel-http test from Task 2 on:
  - `SpinelHttpTest.test(name) { ... }`;
  - `assert(cond, msg = "")`, `assert_equal(expected, actual)`, `assert_nil(value)`, `assert_includes(collection, item)`, `assert_raises(klass) { ... }`;
  - `SpinelHttpTest.summary`.
- Output format: the same lines cybertrain/test prints, so moved `.expected` files keep their shape:
  - `ok   <name>` for each test;
  - `FAIL <name>: <message>` for each failure;
  - finally `<n> tests, <m> assertions, <f> failures`.

  Read `cybertrain/test/assertions.rb` for the exact formats, and copy only these five assertions and the reporting. Do not copy cybertrain's helper wholesale, because it names cybertrain.
- Produces: `script/check-standalone` (Ruby, standard library only). It fails when any `spinel-http/**/*.rb` requires a path outside `spinel-http/`, other than Ruby's standard library and FFI names on an allowlist (`socket`, `json`, `zlib`, `digest`, `stringio`). Port it from cybertrain's `script/check-http-layer`.

- [ ] **Step 1: Write the helper's own test.** `test/check.rb` passes one test of each assertion and reaches the summary. Its `.expected` holds the `ok` lines and `5 tests, 5 assertions, 0 failures`.
- [ ] **Step 2: Run it under both compilers.** Run `spin test test/check.rb` under the fork and then under upstream. Expected: matches the `.expected`.
- [ ] **Step 3: CI.** `.github/workflows/ci.yml` has two jobs, `fork` and `upstream`, both on `ubuntu-26.04`:
  - Both run `script/check-standalone` and then `spin test`.
  - `upstream`: build and cache matz/spinel at tag `2026.10.25`, copying cybertrain's `http-upstream` job steps; `timeout-minutes: 30`.
  - `fork`: install the fork the way cybertrain's `.github/actions/setup-spinel` does, which you copy; `timeout-minutes: 45`.
  - Install apt packages `zlib1g-dev`, plus anything else Task 2's tests link.
  - Pin actions by SHA, as cybertrain's ci.yml does.
- [ ] **Step 4: Commit and push.**

```bash
git -C /home/user/spinel-http add -A && git -C /home/user/spinel-http commit -m "Scaffold: spin.toml, test helper, standalone check, CI under upstream and the fork"
git -C /home/user/spinel-http push -u origin main
```

Expected: both CI jobs pass on GitHub.

### Task 2: Move the core files into spinel-http as SpinelHttp

**Files:**
- Create in spinel-http, moved from `cybertrain/http/` with `module Cybertrain` becoming `module SpinelHttp` and requires becoming `require "spinel-http/<file>"`: `server.rb`, `handler.rb`, `parser.rb`, `body_writer.rb`, `header_name.rb`, `stream_failure.rb`, `client_error.rb`, `extra_faults.rb`, `request.rb`, `response.rb`, `query.rb`, `cookies.rb`, `sse.rb`, `ip_address.rb`, `uploaded_file.rb`, `gzip_decoder.rb`, `log.rb`, `params.rb`, `key.rb`.
- Not moved: `parameter_filter.rb`, which stays in cybertrain (D91), and `multipart.rb` / `gzip_ffi.rb`, which Task 3 moves.
- Create in spinel-http, ported from cybertrain's `test/` onto `SpinelHttpTest`, layer-only parts only: `test/http_log.rb`, `test/http_parser.rb`, `test/http_request.rb`, `test/http_response.rb`, `test/query.rb`, `test/cookies.rb`, `test/sse.rb`, `test/uploaded_file.rb`, `test/server.rb`, `test/params.rb`, `test/key.rb`, each with its `.expected`.
- Modify `NOTES.md` in spinel-http: rule 1 is cybertrain's NOTES rule 126 (a nil-returning call as a statement, then assert), citing matz/spinel #10260.
- cybertrain is untouched in this task.

**Interfaces:**
- Consumes: `SpinelHttpTest` (Task 1); the Task 0 results.
- Produces: every public name cybertrain has today under `Cybertrain::`, now under `SpinelHttp::` with the same name and the same methods. Examples: `SpinelHttp::Server`, `HttpHandler`, `Request`, `Response`, `Query`, `Params`, `Key`, `Cookies`, `ClientError`, `PortInUse`, `HttpLog`, `HttpLogContext`, `HttpLogSwitch`, `StreamFailure`, `UploadedFile`, `GzipDecoder`, `IpAddress`, `Sse`. Use the exact current names; list them with `grep -h "^\s*\(class\|module\) " cybertrain/http/*.rb`.
- Every class-level slot keeps its name and default:
  - `Params.max_page`;
  - `ClientError.extra_faults`;
  - `Request.inflater`;
  - `HttpLogSwitch.installed_switch`;
  - `SpinelHttp.stream_failure` / `stream_failure=`. This one is a module method; record its exact current name from `stream_failure.rb`.

- [ ] **Step 1: Port the tests.** For each test file above, keep only the cases that need nothing outside `cybertrain/http/`. Drop cases that need `cybertrain/params`, `i18n`, `context_handler`, `middleware` or `cybertrain/test`'s integration helpers; Task 5 keeps those in cybertrain. Rename `Cybertrain::` to `SpinelHttp::`. Port the expected output, with test counts adjusted to the cases kept.
- [ ] **Step 2: Run.** `spin test` in spinel-http. Expected: FAIL, because `spinel-http/...` does not exist yet.
- [ ] **Step 3: Move and rename the files.** Copy the files from cybertrain at `origin/main` into `spinel-http/`. Rename the module. Reword every comment that names a cybertrain concept or file into the layer's own terms; D91's "Known limits" lists the files whose comments still do. `ClientError`'s built-in fault list must name `SpinelHttp::` classes.
- [ ] **Step 4: Run the checks under both compilers.**
  - `script/check-standalone`: passes.
  - `spin test` under the fork and under upstream: every test matches its `.expected`.
  - `grep -rn -i "cybertrain" spinel-http/ test/ README.md`: prints nothing.
- [ ] **Step 5: Commit and push.** Commit "Move the HTTP layer from cybertrain as SpinelHttp", then push. Expected: CI passes.

### Task 3: Multipart and gzip as optional requires

**Files:**
- Create in spinel-http: `spinel-http/multipart.rb`, moved from `cybertrain/http/multipart.rb`.
- Create in spinel-http: `spinel-http/gzip.rb`, moved from `cybertrain/http/gzip_ffi.rb`. It keeps the zlib FFI and installs the decoder and `Request.inflater` at load.
- Modify: `spinel-http/request.rb`. Replace the direct `Multipart.boundary_from` and `Multipart.parse` calls with a class-level parser slot, `Request.multipart_parser`, whose default is a null parser.
- Tests in spinel-http:
  - `test/multipart.rb`, ported, layer-only cases;
  - `test/http_gunzip.rb`, ported;
  - `test/standalone.rb`, ported from cybertrain's `test/http_standalone.rb`: requires server, multipart and gzip;
  - `test/bare.rb`, new: requires only `spinel-http/server`.

**Interfaces:**
- Produces:
  - `require "spinel-http/multipart"` installs `Request.multipart_parser`;
  - `require "spinel-http/gzip"` installs the gzip inflater and the `GzipDecoder`;
  - cybertrain's shims in Task 5 require both, so cybertrain applications see no change.
- Behaviour without multipart loaded (D91): `Request#multipart_form` raises a client fault that the server answers with **415**, and `Request#multipart_boundary` answers `""`.
- Behaviour without gzip loaded: a `Content-Encoding: gzip` body gets the existing message "gzip request bodies are not decoded: no inflater is installed (require the gzip support)". Reword the parenthesis to name `require "spinel-http/gzip"`.

- [ ] **Step 1: Write `test/bare.rb`.** Start a server on a free port with a handler that reads `request.multipart_form` for one route and `request.body` for another, then assert:
  - a `multipart/form-data` POST → status `415`;
  - `multipart_boundary == ""` for that request;
  - a gzip-encoded POST → status `400`, and the body contains `no inflater is installed`;
  - a plain GET → `200`.
- [ ] **Step 2: Run it.** `spin test test/bare.rb` should FAIL, because the parser slot does not exist yet.
- [ ] **Step 3: Add the parser slot, move the two files, update `test/standalone.rb`.**
- [ ] **Step 4: Run the checks.**
  - `spin test` under the fork and under upstream: everything passes.
  - `script/check-standalone`: passes.
- [ ] **Step 5: Commit and push.** Commit "Multipart and gzip behind their own requires", then push. Expected: CI passes.

### Task 4: README, release v0.1.0

**Files** (in spinel-http):
- Modify: `README.md`. It covers:
  - what the library is;
  - the hello-world server: a complete `bin/hello.rb` that answers `hello`, with the `spin.toml` dependency line;
  - the optional requires (`spinel-http/multipart`, `spinel-http/gzip`, which links zlib);
  - the supported compilers (upstream 2026.10.25 and later, and the fork);
  - how to run the tests;
  - a pointer to NOTES.md.
- Create: `examples/hello/` (`spin.toml` with a path dependency `../..`, and `bin/hello.rb`). CI builds it and curls it in a third step of the `upstream` job.

- [ ] **Step 1: Add the CI step.** It builds `examples/hello`, starts it and runs `curl -fsS http://127.0.0.1:$PORT/`. Expected output: `hello`.
- [ ] **Step 2: Write the example and the README.** The README's code block is the example's file, verbatim.
- [ ] **Step 3: Push and tag.**

```bash
git -C /home/user/spinel-http push
git -C /home/user/spinel-http tag -a v0.1.0 -m "spinel-http 0.1.0"
git -C /home/user/spinel-http push origin v0.1.0
```

  Expected: CI passes on `main`, and the tag `v0.1.0` exists on GitHub.

### Task 5: cybertrain depends on spinel-http

**Files** (cybertrain, branch `claude/wonderful-shannon-1c9jev`):
- `spin.toml`: add `[dependencies]` with `spinel-http = { git = "https://github.com/saeki-mototsune/spinel-http", ref = "v0.1.0" }`. Run `spin lock`, which writes `spin.lock`; commit it.
- Every moved `cybertrain/http/<file>.rb`, including `multipart.rb` and `gzip_ffi.rb`, becomes a shim:
  - it requires `spinel-http/<file>`, or `spinel-http/gzip` for `gzip_ffi`;
  - it sets one constant alias per public name, e.g. `Server = SpinelHttp::Server`, inside `module Cybertrain`, using the form Task 0 proved;
  - it carries nothing else.
- Keep `cybertrain/http/parameter_filter.rb`. Keep `cybertrain/key.rb` as a require of the `cybertrain/http/key` shim.
- Reopenings: `cybertrain/params.rb`, `cybertrain/i18n.rb`, `cybertrain/logger.rb`, and any other file that reopens a moved class (`grep -rln "class \(Params\|Request\|Response\|HttpLog\)" cybertrain/`) reopen it in the form Task 0 proved.
- Fault names: `ParameterMissing` registration in `cybertrain/params.rb`, `cybertrain/job_scan.rb`, and any other string naming a moved class (`grep -rn '"Cybertrain::' cybertrain/ script/`) names what `Class#name` answers now.
- Scripts:
  - `script/check-http-layer` is deleted, because its rule now lives in spinel-http's `script/check-standalone`. Remove it from `script/gate`.
  - `script/check-core-closure` follows `require "spinel-http/..."` into spin's resolved checkout of spinel-http. Take the path from `spin list --json`.
  - `script/check-reserved-names` scans spinel-http's source too, from the same path, so rule 34 spans both. It gets rows for names the move puts in both.
  - `script/check-client-faults` resolves the new names.
- `.github/workflows/ci.yml`: the `http-upstream` job is removed, because spinel-http's own CI runs those programs. Also remove its entries from CONTRIBUTING's "What CI runs" and from D34's tenth-runner note.
- Tests in cybertrain:
  - delete the files Task 2 and Task 3 moved wholesale;
  - keep the cybertrain-integration cases of `http_request.rb` (preferred_locale), `multipart.rb` and `params_split.rb` (strong parameters), `server.rb` (ContextHandler, RequestId, log scopes), `http_params_fault.rb`, `key_text.rb` and `test/cruby/dev_server.rb`, under the same file names;
  - update the counts in their `.expected` files.
- New test `test/spinel_http_aliases.rb` and its `.expected`, asserting:
  - `Cybertrain::Server.equal?(SpinelHttp::Server)`, and the same for each aliased name;
  - `Cybertrain::Params.new` responds to `permit` (the reopening reached the shared class);
  - a missing required parameter → `400` through `ContextHandler`;
  - a malformed query → `400`;
  - `rescue Cybertrain::PortInUse` catches a port conflict, and `ServerRunner.port_message` still prints the `PORT` / `CYBERTRAIN_HOST` hint.

**Interfaces:**
- Consumes: spinel-http v0.1.0 (Tasks 2–4); the Task 0 alias and reopening forms.
- Produces: an unchanged public surface for applications.

- [ ] **Step 1: Write `test/spinel_http_aliases.rb`.** Run it: FAIL, because the dependency is absent.
- [ ] **Step 2: Add the dependency, the shims, the reopenings and the fault names.** Run `spin lock`.
- [ ] **Step 3: Update the scripts, CI and the kept tests, and delete the moved tests.**
- [ ] **Step 4: Run the checks.**
  - `script/gate`: passes.
  - `spin test test/spinel_http_aliases.rb test/http_request.rb test/multipart.rb test/params_split.rb test/server.rb test/http_params_fault.rb test/key_text.rb`: all match their `.expected`.
  - `script/test-cruby`: passes.
  - `spin test test/cli_new.rb test/cli_build.rb test/cli_framework_version.rb`: passes. These prove an app finds spinel-http transitively and that `cybertrain new` writes nothing new.
- [ ] **Step 5: Run the whole suite once.** `script/test-shard 0 1` passes; record the count. The full suite is slow, so run it once here and leave repeats to CI.
- [ ] **Step 6: Commit and push.** Commit "cybertrain depends on spinel-http v0.1.0; the HTTP layer's names stay as aliases" and push.

### Task 6: Docs, measurement, design record

**Files:**
- Modify: `docs/design.md`.
  - Turn D91's "Still to do" into what was done, and leave step 5 to the maintainer.
  - Record Task 0's answers.
  - Add the measurement: A = `origin/main` at the start of this plan, B = this branch's head, interleaved A1, B1, A2, B2 with `script/measure-http-layer --rev`, reported as in D91 (pooled medians and per-pair table).
  - Past the line, stop and report.
- Modify: `CONTRIBUTING.md`:
  - the two-step release: tag spinel-http, bump `ref` in cybertrain's `spin.toml`, `spin lock`;
  - how to work on both at once, with a temporary `path` dependency that is never committed;
  - remove the upstream repro section, which moves to spinel-http's README.
- Modify: `spikes/NOTES.md` rule 126 and `docs/spinel-feedback.md` F, both pointing to spinel-http's NOTES.md rule 1.
- Modify: `docs/guide/external-services.md` and any guide naming `cybertrain/http/` internals. The documented requires stay and still work.
- Delete: `docs/superpowers/plans/2026-11-23-spinel-http-steps-3-4-plan.md`. This plan's decisions live in D91 once the work merges, per the convention since 5d7d260.

- [ ] **Step 1: Run the measurement.** It takes about 2.5 hours, so run it in the background. Compare against the line.
- [ ] **Step 2: Write the docs.** `script/gate` and `script/api-docs` pass.
- [ ] **Step 3: Commit and push.** Expected: cybertrain CI passes, including the end-to-end jobs that build applications from a git checkout.
