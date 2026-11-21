# spinel-http, phase 1 (spike, then cutting the ties in place) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the HTTP layer builds under upstream Spinel, then make `cybertrain/http/` depend on nothing else in cybertrain, still inside this repository and still under `Cybertrain::`, with cybertrain's behaviour unchanged.

**Architecture:** Steps 1 and 2 of the spec's section 9. Each tie of the spec's section 7 is cut with the pattern the layer already uses for `Request.inflater`: the HTTP layer defines a base class or a class-level slot with a plain default, and cybertrain installs its own at load. `script/check-http-layer`, which already guards the boundary, is tightened to allow nothing outside `cybertrain/http/`. Steps 3 to 5 (the new repository, pointing cybertrain at it, publishing) get their own plan once this one has landed, since the spike's answers shape them.

**Tech Stack:** Ruby compiled by Spinel (the fork `2026.11.15.7033`, and upstream matz/spinel `2026.10.25`), `spin test` snapshot tests, CRuby for the `script/` checks, wrk for throughput.

**Spec:** `docs/superpowers/specs/2026-11-21-spinel-http-extraction-design.md` (approved 2026-11-21). Read it first; this plan does not repeat its reasons.

## Global Constraints

- Every existing test keeps asserting what it asserts today. Renaming a method in a test (say `body_scope` to `body_log_context`) is allowed; changing an expected value or deleting a test is not, with one exception: Task 5's neutral `PortInUse` messages in `test/server.rb`.
- Anti-goal 1's line: on one machine, wrk on `/up` and `/articles` of examples/blog, median of 5 runs, within 3% of the baseline; examples/blog's cold and incremental builds, median of 3, within 5%. Past that, stop and report to the maintainer before landing (spec decision 4).
- No application code changes (anti-goal 2): `request.preferred_locale(available)`, `Cybertrain::Params#permit`/`require`/`expect`, `rescue Cybertrain::PortInUse`, and every message `cybertrain server` prints stay as they are.
- No new names in the HTTP layer that carry a cybertrain concept (anti-goal 3): no `log_scope`, `I18n`, `Config`, `CYBERTRAIN_*` in `cybertrain/http/`.
- Spinel rules from `spikes/NOTES.md` apply as everywhere: no `is_a?` on exceptions (rule 47), `Class#name` has no namespace (rule 46), save-yield-ensure for thread slots (rule 103), ivar class-level defaults in the `Params.max_page` shape.
- Every commit passes `script/gate` (the pre-commit hook runs it). Commit messages end with the session's attribution lines.

## Review Focus

1. **A streamed response (SSE, `Controller#stream`) still logs under its request's id** after the RequestId middleware has returned. Pinned by `test/response_stream.rb`'s existing scope assertions (renamed, Task 2) and a new case in Task 2 that sets a context, ends the request, and checks the writer thread saw it.
2. **A handler exception on a keep-alive connection is logged with that request's id, and the next request on the same connection is logged with none.** Task 2 adds this case to `test/server.rb`.
3. **A nested params hash (`article[tags][]`, `user[address][city]`) built by Query or Multipart still answers `permit`/`expect`** on its nested children, since children are created inside the HTTP layer. Task 3's test.
4. **A required parameter that is missing still answers 400, not 500,** under the compiled build, once `ParameterMissing` is no longer named by the HTTP layer. Task 3's test.
5. **A program that requires only `cybertrain/http/server` builds and serves under both Spinels**: no hidden load-order dependence on the rest of cybertrain (a slot nobody installed, a constant only cybertrain defines). Task 6's `test/http_standalone.rb`.

---

### Task 0: Baseline measurement

**Files:**
- Create: `script/measure-http-layer`

**Interfaces:**
- Produces: `script/measure-http-layer OUT.json`, a bash script used again in Task 7. It writes `{"commit": "...", "build_cold_s": [..3], "build_incremental_s": [..3], "rps_up": [..5], "rps_articles": [..5], "median": {...}}`.

- [ ] **Step 1: Write the script.** It works in a `cp -a` of `examples/blog` under `tmp/measure/`, with `spin.toml` pointed at the checkout (`cybertrain = { path = "<repo>" }`, the way `script/preview-e2e` does it). Cold build: `rm -rf build && cybertrain build`, 3 times. Incremental build: touch `app/controllers/articles_controller.rb`, then `cybertrain build`, 3 times. Serve the built binary in production mode on a free port, seed 20 articles through the form (as `bench/run` does), then `wrk -t2 -c32 -d10s` on `/up` and on `/articles`, 5 times each. Install wrk with `apt-get install -y wrk` if it is missing; stop with a message if that fails.
- [ ] **Step 2: Run it on the base commit.** Run: `script/measure-http-layer tmp/measure/baseline.json`. Expected: a JSON file with 3 + 3 build times and 5 + 5 throughput numbers, all non-zero.
- [ ] **Step 3: Commit the script** (not the JSON: `tmp/` is ignored). Record the baseline medians in the commit message.

### Task 1: Spike (throwaway)

**Files:**
- Create: `spikes/spinel-http/README.md`, `spikes/spinel-http/hello.rb`, `spikes/spinel-http/subclass_log.rb`, `spikes/spinel-http/reopen_params.rb`, `spikes/spinel-http/const_alias.rb`, `spikes/spinel-http/spin.toml` (package `spinel-http-spike`, `cybertrain = { path = "../.." }`)
- Modify: `docs/superpowers/specs/2026-11-21-spinel-http-extraction-design.md` (a new section 11, "Spike results")

Each program has its run commands and output in its header comment, as `spikes/phase5/time_now.rb` does. They are records, not tests.

- [ ] **Step 1: Build upstream Spinel.** `git clone -q --depth 1 --branch 2026.10.25 https://github.com/matz/spinel ~/spinel-upstream-src && cd ~/spinel-upstream-src && make deps && make -j$(nproc) && make install PREFIX=$HOME/.spinel-upstream/2026.10.25`. These are the same four steps `cybertrain/cli/toolchain.rb:317-320` runs for the fork. Expected: `$HOME/.spinel-upstream/2026.10.25/bin/spinel --version` prints a 2026.10.25 build.
- [ ] **Step 2: `hello.rb`.** `require "cybertrain/http/server"`, a `Hello < Cybertrain::HttpHandler` answering `200 "hello"`, `Server.new(Hello.new, port: 0)`, start it, make one request with `TCPSocket`, print the status line and body, stop it. Build and run it under both compilers (`PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH spin run hello`, then with the fork). Expected under the fork: `HTTP/1.1 200 OK` and `hello`. Under upstream, record every compile error or wrong output, and the NOTES rule or fork fix it maps to (`docs/spinel-feedback.md`, `spikes/NOTES.md`).
- [ ] **Step 3: `subclass_log.rb`.** A base `HttpLog` (`info`/`warn`/`error(msg)`, a `swap_context(ctx)` answering the previous `HttpLogContext`) and a `HttpLogContext` base with no behaviour; a subclass `MyLog < HttpLog` and `MyScope < HttpLogContext` carrying a `request_id` String; a class-level slot (`@switch = HttpLogSwitch.new` in the `Params.max_page` shape) replaced at load by a subclass. Check, under both compilers: a `MyScope` stored in an `HttpLogContext`-typed ivar and handed back to `MyLog#swap_context` keeps its `request_id` (no static-type loss; no `is_a?`, rule 47); the replaced slot is the one called from another thread.
- [ ] **Step 4: `reopen_params.rb`.** A `Params` class in one file with `set_path` and `child!` (children built with `Params.new`), reopened in a second file that adds `permit`; parse `a[b][c]=1` into it, call `permit` on the nested child. Same under both compilers?
- [ ] **Step 5: `const_alias.rb`.** `module SpinelHttp; class Server; end; class QueryInvalid < StandardError; end; end` and `module Cybertrain; Server = SpinelHttp::Server; QueryInvalid = SpinelHttp::QueryInvalid; end`. Check: `Cybertrain::Server.new` works; `rescue Cybertrain::QueryInvalid` catches a raised `SpinelHttp::QueryInvalid`; what `e.class.name` prints (rule 46). This answers a step-4 question now, while the spike is open.
- [ ] **Step 6: Write section 11 of the spec**: one line per question with the answer under each compiler, the list of upstream failures, and the mechanism this plan's tasks use: the class-level switch (Task 2), reopening (Task 3), constant alias or subclass (the next plan).
- [ ] **Step 7: Decide whether to go on.** Stop and report to the maintainer, with section 11, if any of these hold. (a) `hello.rb` fails under upstream in a way no change inside `cybertrain/http/` can avoid (G1 then waits on an upstream release). (b) Step 3's context loses its type under either compiler. (c) Step 4's reopening fails. In that case propose moving the whole `Params` (with `permit`/`require`/`expect`, minus `filtered_inspect`) into the HTTP layer, a change to the spec's section 6. Otherwise continue.
- [ ] **Step 8: Commit** `spikes/spinel-http/` and the spec's section 11.

### Task 2: Logging and the log context

**Files:**
- Create: `cybertrain/http/log.rb`
- Modify: `cybertrain/http/server.rb` (the `logger:` default, `run_writer_scoped`, `classify_scoped`), `cybertrain/http/body_writer.rb:41-47` (`write_scoped`), `cybertrain/http/request.rb:100-134` (`log_scope`), `cybertrain/http/response.rb` (`@body_scope` at 105, 136, 152, 164, 181, 309, 414), `cybertrain/http/client_error.rb` (`classify`'s `logger` parameter type), `cybertrain/logger.rb`, `cybertrain/middleware/request_id.rb:79`, `cybertrain/roles/server.rb:62`, `cybertrain/test/client.rb:421`
- Test: `test/response_stream.rb`, `test/server.rb`, `test/http_log.rb` (new) and their `.expected`

**Interfaces:**
- Produces (in `cybertrain/http/log.rb`, all under `Cybertrain`, renamed to `SpinelHttp` in the next plan):
  - `class HttpLogContext`, with no methods. `HttpLogContext::NONE` is the shared empty one.
  - `class HttpLog`, with `debug(msg)`, `info(msg)`, `warn(msg)`, `error(msg)`, each `-> nil`. The base writes `"#{level}: #{msg}\n"` to `$stderr` and drops `debug`.
  - `class HttpLogSwitch`, the thread's context: `current -> HttpLogContext` (base: `NONE`) and `swap(ctx) -> HttpLogContext` (base: answers `NONE`, stores nothing).
  - `HttpLogSwitch.installed -> HttpLogSwitch` and `HttpLogSwitch.installed = (switch)`, a class-level slot defaulting to the base.
  - `Request#log_context` and `Request#log_context=(ctx)` (`HttpLogContext`), replacing `log_scope`.
  - `Response#body_log_context -> HttpLogContext`, replacing `body_scope`. Captured with `HttpLogSwitch.installed.current` where `Logger.current_scope` is read today.
  - `BodyWriter.write_scoped(writer, sink, ctx)` and the server's scoped runs swap through `HttpLogSwitch.installed.swap`.
  - `Server.new(..., logger: HttpLog.new, ...)`: the default no longer names `Cybertrain.logger`.
- Produces (cybertrain side):
  - `Logger < HttpLog` and `Logger::Scope < HttpLogContext`.
  - `Logger::ScopeSwitch < HttpLogSwitch`, whose `current` answers `Logger.current_scope` and whose `swap(ctx)` calls `Logger.swap_scope` with the mechanism Task 1 step 3 settled. `NONE` maps to `Logger::NO_SCOPE`.
  - `cybertrain/logger.rb` installs `Logger::ScopeSwitch.new` at load.
  - `roles/server.rb` passes `logger: Cybertrain.logger` explicitly.

- [ ] **Step 1: Write the failing tests.** In `test/http_log.rb`, compiled without the rest of the framework (`require "cybertrain/http/log"` only):
  - `HttpLogSwitch.installed.current.equal?(HttpLogContext::NONE)`;
  - a subclass switch installed, then `swap(ctx)` from a second thread answers the previous context, and `current` there is `ctx`;
  - `HttpLog.new.error("x")` prints `error: x` on stderr (capture via `$stderr` reassignment as `test/logger_flush.rb` does).

  In `test/server.rb`, a keep-alive case (Review Focus 2): a handler that sets `request.log_context` to a test context carrying `"req-1"` and raises; a logger subclass that records `[line, HttpLogSwitch.installed.current]`. Expected: the error line was recorded under `"req-1"`, and a second request on the same socket that does not raise records `NONE`.

  In `test/response_stream.rb`, rename `body_scope` to `body_log_context` and keep the `equal?` assertions (`Logger::NO_SCOPE` stays what the cybertrain switch answers for none). Add the Review Focus 1 case: a streamed response's writer thread, run through `BodyWriter.write_scoped`, sees `Logger.current_scope.scope_request_id == "req-1"`.
- [ ] **Step 2: Run them to see them fail.** Run: `spin test test/http_log.rb test/server.rb test/response_stream.rb`. Expected: compile errors naming `HttpLog`, `log_context` and `body_log_context`.
- [ ] **Step 3: Implement `cybertrain/http/log.rb` and the http-layer changes** listed under Interfaces. Do not `require "cybertrain/logger"` anywhere in `cybertrain/http/`.
- [ ] **Step 4: Implement the cybertrain side** listed under Interfaces, plus `request_id.rb:79` (`request.log_context = scope`) and `cybertrain/test/client.rb:421`.
- [ ] **Step 5: Run the tests to see them pass.** Run: `spin test test/http_log.rb test/server.rb test/response_stream.rb test/request_id.rb test/logger_tls.rb test/log_tags_background.rb`. Expected: all pass, and the snapshots differ only by the new cases.
- [ ] **Step 6: Run the full suite.** Run: `script/test-shard 0 1` (the whole suite in one shard). Expected: every test passes.
- [ ] **Step 7: Commit.**

### Task 3: Params core into the HTTP layer; strong parameters stay

**Files:**
- Create: `cybertrain/http/params.rb` (the structure: `initialize`, `[]`, `list`, `nested`, `key?`, `upload`, `upload?`, `max_page` with its setter, `int`, `page_number`, `clamp_int`, `parse_int`, `int_text?`, `set_value`, `add_list_value`, `child!`, `set_upload`, `set_upload_path`, `set_path`, `merge!`, `to_h`, `empty?`, `inspect`, `lists`, `children`, `raw_values`, `upload_map`, `replace_list!`, `copy_strings`)
- Modify: `cybertrain/params.rb`, which keeps `ParameterMissing`, `require`, `permit`, `expect` and their helpers, `filtered_inspect`, `filtered_or`, `permitted_by`, `permitted_hash`. It reopens `class Params` and requires `cybertrain/http/params`. Also `cybertrain/http/query.rb:1-2,112`, `cybertrain/http/client_error.rb:61`, `script/check-client-faults`, `script/check-http-layer` (drop `cybertrain/params.rb` from `allowed`).
- Test: `test/params_split.rb` (new), `test/query.rb`, `test/multipart.rb`, `test/params.rb`, `test/params_limits.rb` (existing; unchanged in what they assert)

**Interfaces:**
- Consumes: Task 1's step 4 verdict. If reopening failed, Task 1 step 7 has stopped the plan.
- Produces: `Cybertrain::Params`, defined in `cybertrain/http/params.rb` and reopened in `cybertrain/params.rb`. Its full class is unchanged for every caller.
- Produces: `ClientError.extra_faults -> Array<String>` and `ClientError.extra_faults=(names)`, a class-level slot defaulting to `[]`. `status_for_name` consults `CLIENT_FAULTS + extra_faults`. `CLIENT_FAULTS` loses `"Cybertrain::Params::ParameterMissing"`, and `cybertrain/params.rb` adds it to `extra_faults` at load.

- [ ] **Step 1: Write the failing test** `test/params_split.rb`:
  - `Query.parse("a[b][c]=1&a[t][]=x&a[t][]=y")` → `.nested("a").permit(b: [:c], t: [])` answers `{"b" => {"c" => "1"}, "t" => ["x", "y"]}` (Review Focus 3: the nested child Query built still permits);
  - `Query.parse("a=1").require(:missing)` raises `Cybertrain::Params::ParameterMissing`, and `ClientError.status_for(e) == 400` (Review Focus 4);
  - a multipart body with a file `user[avatar]` and a text field `user[name]=ann` (reuse `test/multipart.rb`'s builder) → `.nested("user").upload?("avatar")` is true, and `.nested("user").permit(:name)` answers `{"name" => "ann"}` (`permit` never returns uploads, as today).
- [ ] **Step 2: Run it** with `spin test test/params_split.rb`. Expected: PASS already, since this is a refactor; the test pins behaviour before the move. Then run `ruby script/check-http-layer` after removing `cybertrain/params.rb` from `allowed`. Expected: FAIL, naming `cybertrain/params.rb`.
- [ ] **Step 3: Move the structure methods** into `cybertrain/http/params.rb` and reopen in `cybertrain/params.rb`. Add the `extra_faults` slot. Update `script/check-client-faults` so it requires `cybertrain/params` and checks `CLIENT_FAULTS + extra_faults`.
- [ ] **Step 4: Run** `ruby script/check-http-layer && ruby script/check-client-faults && spin test test/params_split.rb test/query.rb test/query_extras.rb test/multipart.rb test/multipart_app.rb test/params_limits.rb test/params.rb`. Expected: all pass.
- [ ] **Step 5: Commit.**

### Task 4: Locale negotiation

**Files:**
- Modify: `cybertrain/http/request.rb:228-260` and `script/check-http-layer` (empty `LAZY`). Add a reopening of `Request` in `cybertrain/i18n.rb` (beside `I18n.default_locale`).
- Test: `test/http_request.rb` (the existing locale cases), `test/i18n*.rb`

**Interfaces:**
- Produces: `Request#negotiate_locale(available, default) -> String` in the HTTP layer. It is the body of today's `preferred_locale`, with `default` wherever it reads `I18n.default_locale`.
- Produces: `Request#preferred_locale(available) -> String` in `cybertrain/i18n.rb`, which is `negotiate_locale(available, I18n.default_locale)`. Applications call it unchanged.

- [ ] **Step 1: Write the failing test.** In `test/http_request.rb`, add `negotiate_locale(["en", "ja"], "fr")` on a request without Accept-Language → `"fr"`, and with `Accept-Language: ja;q=0.9, en;q=0.8` → `"ja"`. Run `spin test test/http_request.rb`. Expected: FAIL (undefined method).
- [ ] **Step 2: Implement** as under Interfaces, and empty `LAZY` in `script/check-http-layer`.
- [ ] **Step 3: Run** `ruby script/check-http-layer && spin test test/http_request.rb` and every `test/i18n*.rb`. Expected: all pass, and the existing `preferred_locale` cases are unchanged.
- [ ] **Step 4: Commit.**

### Task 5: Messages that name cybertrain settings

**Files:**
- Modify: `cybertrain/http/server.rb:24-37` (`PortInUse`), `cybertrain/roles/server.rb:168` (the `rescue PortInUse`), `cybertrain/http/request.rb:831` (the inflater message, which names `require "cybertrain"`)
- Test: `test/server.rb` (neutral texts), `test/application.rb` (unchanged: it proves `cybertrain server` prints what it prints today)

**Interfaces:**
- Produces: `PortInUse#reason -> String`, one of the constants below. The message reads `"port #{port} on #{host} #{reason}"` as today. The neutral constants in the HTTP layer are:
  - `IN_USE = "is already in use"`
  - `PERMISSION_DENIED`, unchanged
  - `REUSE_PORT_HOST = "cannot be bound with reuse_port: the host is not an address of this machine"`
  - `REUSE_PORT_NAME = "cannot be bound with reuse_port: the host names several addresses"`
  - `NOT_LISTENING`, unchanged
- Produces: `ServerRole.port_message(e) -> String` in `cybertrain/roles/server.rb`. It answers today's exact text: the neutral message plus `" (stop the other server or set PORT)"`, `" (check CYBERTRAIN_HOST)"` or `" (set CYBERTRAIN_HOST to one of them)"` by `reason`.
- The inflater's message becomes `"gzip request bodies are not decoded: no inflater is installed (require the gzip support)"`. That text is the HTTP layer's; cybertrain always installs one, so no cybertrain output changes.

- [ ] **Step 1: Update `test/server.rb`'s expected messages** to the neutral texts. Run `spin test test/server.rb test/application.rb`. Expected: `server.rb` FAILS on the old texts, `application.rb` passes.
- [ ] **Step 2: Implement** as under Interfaces.
- [ ] **Step 3: Run** `spin test test/server.rb test/application.rb test/http_gunzip.rb`. Expected: all pass, and `test/application.rb.expected` has not changed (`git diff --exit-code test/application.rb.expected`).
- [ ] **Step 4: Commit.**

### Task 6: The layer stands alone, under both Spinels

**Files:**
- Create: `test/http_standalone.rb` and its `.expected`
- Modify: `script/check-http-layer` (`allowed = []`; update its header comment), whatever in `cybertrain/http/` Task 1 step 2 listed as failing under upstream, `spikes/NOTES.md` (one rule per upstream workaround, in its format, with the upstream issue or "not reported yet"), `.github/workflows/ci.yml` (a job `http-upstream`)

**Interfaces:**
- Consumes: Task 1 step 2's list of upstream failures.
- Produces: the CI job `http-upstream`. It builds `$SPINEL_UPSTREAM_TAG` (`2026.10.25`, an env at the top of the workflow next to `SPINEL_TAG`) with the four steps of Task 1 step 1, cached by tag like `setup-spinel`. Then it runs `spin test` on exactly these files: `test/http_standalone.rb`, `test/http_log.rb`, `test/http_parser.rb`, `test/http_request.rb`, `test/http_response.rb`, `test/query.rb`, `test/query_extras.rb`, `test/cookies.rb`, `test/sse.rb`, `test/multipart.rb`, `test/uploaded_file.rb`, `test/http_gunzip.rb`, `test/server.rb`. These are the files that move in the next plan.

- [ ] **Step 1: Write `test/http_standalone.rb`** (Review Focus 5). `require "cybertrain/http/server"`, `"cybertrain/http/multipart"` and `"cybertrain/http/gzip_ffi"` only. A handler answers the query value `name`, a multipart field `f`, and a gzip JSON body's length. Serve on port 0, make the three requests with `TCPSocket`, print each status and body, and stop. Expected output: `200 alice`, `200 hello`, `200 11`.
- [ ] **Step 2: Run** `ruby script/check-http-layer` with `allowed = []`. Expected: PASS (Tasks 2 to 4 removed `logger.rb` and `params.rb`). Then run `spin test test/http_standalone.rb` under the fork. Expected: PASS.
- [ ] **Step 3: Run the job's file list under upstream:** `PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH spin test <the files above>`. Expected: the failures Task 1 listed, and no others.
- [ ] **Step 4: Fix each failure inside `cybertrain/http/`**, one commit each, each with its NOTES rule. After each fix, run the same file under the fork too.
- [ ] **Step 5: Run the list under both compilers.** Expected: all pass. Add the `http-upstream` job, and check it with `script/lint-workflows`.
- [ ] **Step 6: Commit.**

### Task 7: Measure, document, open the pull request

**Files:**
- Modify: `docs/superpowers/specs/2026-11-21-spinel-http-extraction-design.md` (section 11: the measurement), `docs/design.md` (D-entry: "the HTTP layer depends on nothing else in cybertrain", which names `HttpLog`, `HttpLogSwitch`, the `Params` split, `negotiate_locale`, `extra_faults`, `PortInUse#reason`), and the YARD comments of every changed public method.

- [ ] **Step 1: Run** `script/measure-http-layer tmp/measure/after.json` on the same machine as the baseline. Expected: every median within the Global Constraints line. If one is past it, stop and report to the maintainer with both JSON files before Step 2.
- [ ] **Step 2: Run the whole suite** (`script/test-shard 0 1`), `script/test-cruby`, `script/gate`. Expected: all pass.
- [ ] **Step 3: Write the D-entry and section 11's measurement lines. Commit.**
- [ ] **Step 4: Push** the branch and open a pull request that follows `.github/PULL_REQUEST_TEMPLATE.md`. List the baseline and after medians, the upstream workarounds, and the mechanisms the spike chose.
