# Phase 5b (operations: logs and error reporting) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver part 5b of phase 5: every log line carries its time (on the Clock), its level and its tags (`2026-11-11T12:00:00.123Z INFO [<request id>] message`), optionally as JSON lines; every request gets a request id (generated, or taken from a trusted proxy), echoed in `X-Request-Id`, readable as `request.request_id` and carried by every line logged during the request and by the jobs it enqueues; jobs, feeds and scheduled tasks tag their lines; `Cybertrain.error` reports exceptions (`report`, `handle`, `subscribe`), automatically for 500s, jobs, scheduled tasks, feeds and mail, off the request on a bounded queue, to subscribers and to a built-in Sentry-protocol sender behind `CYBERTRAIN_SENTRY_DSN`; the generators and the blog show it.

**Architecture:** The log line stays on the HTTP layer's side: `cybertrain/logger.rb` requires nothing outside it, so the Clock pushes a travel to the Logger (`Logger.follow_clock`) instead of the Logger reading the Clock, and the per-thread context (request id, method, path, `where`, tags) is a `Logger::Scope` object in one `Thread.current` slot (rule 102), swapped in and restored by whoever runs work on a thread (the `RequestId` middleware, the job executor, the scheduler, a feed thread, `tagged`). The error reporter lives outside the HTTP layer (`cybertrain/error_reporter.rb`): `report` reads the Scope and the Config on the caller's thread, builds an `ErrorEvent` of Strings, and queues it; one thread, started through a method on first need, hands events to the subscribers (objects, never blocks: rule 88) and to the sender, an object the Sentry file installs when gen/app.rb requires it.

**Tech Stack:** Ruby compiled by Spinel 2026.11.04.7026 (also run under CRuby 3.3), SQLite via FFI, `Cybertrain::Clock` and the 5a test helpers (`travel_to`, `freeze_time`, `Test.on_reset`, `Test.after_this_case`, `perform_enqueued_jobs`, `ActionDispatch::IntegrationTest`, `assert_raises(Class)`, `assert_match`), `Cybertrain::HttpClient`, `Cybertrain::Test::HttpReceiver`, `Cybertrain::Test::WebSocketReceiver`, `Cybertrain::ParameterFilter`, `Cybertrain::ClientError`, `Cybertrain::Crypto`.

**Spec:** docs/superpowers/specs/2026-11-11-phase5-tests-operations-design.md — Part 5b (sections 12 and 13), the 5b rows of section 14, section 15's 5b items (D85, D86), spike items 7 to 9 of section 16 (item 5's result, already recorded, decides the backtrace), sections 17 and 18 as they touch 5b, acceptance items 11 to 14 of section 19, section 20 and section 21 "Part 5a" (what 5a built, rules 104 to 110). Part 5a is not in this plan.

**Depends on phase 5a** (head 9866af2 of claude/phase5-design): `Cybertrain::Clock`, the 5a test helpers and `Test.on_reset`, `cybertrain/test/bundle.rb`'s `*_unless_given` defaults, `Mailer.deliveries`. Where this plan names a 5a name, it is the spelling at that head.

**Execution notes:** Task 1 first: its results amend spec §16 and decide D5, D9 and D12's branches. Then the groups of "Parallel groups" below: tasks in one group own disjoint files and meet only through the interfaces this plan fixes. Every compile runs under the build lock, one at a time, whatever the group.

## Pre-flight: the spec against the code at 9866af2

What sections 12 to 14 name, where it is today, and what 5b changes. Line numbers are at 9866af2.

| Spec names | Today | 5b |
| --- | --- | --- |
| `Cybertrain::Logger`, `debug` / `info` / `warn` / `error` / `fatal` | cybertrain/logger.rb:4-72: five levels (`LEVELS`, l.5), line `"[#{LEVEL}] msg"` (l.56), STDOUT `puts` + `flush` or `@io.write` (l.57-69), no lock, no time, no tags | Task 2: the line, JSON, one write under a lock; Task 3: the Scope, `tagged` |
| `Cybertrain.logger` / `logger=` | logger.rb:82-90, a module ivar (rule 18) | unchanged; tests keep swapping it, so format and lock are class-level (D3) |
| HTTP layer boundary | script/check-http-layer:20 allows `cybertrain/params.rb` and `cybertrain/logger.rb` besides `cybertrain/http/*`; the server logs through `Cybertrain.logger` (http/server.rb:102, 277, 337, 441, 518; http/client_error.rb:23-25) | logger.rb stays loadable alone: no `require` of clock.rb (D2) |
| `Clock` (log time) | cybertrain/clock.rb:46 `now`, writers `travel_to` l.75, `travel_during` l.94-105, `travel_back` l.111; requires only date and time_zone | Task 2: the three writers call `Logger.follow_clock` |
| request log, "two lines (Started, Completed)" | middleware/request_logger.rb:37 Started, l.114-117 Completed (milliseconds on `Clock.monotonic`, l.38, 115) | texts unchanged; the Scope gives them the request id |
| `c.log_level`, `CYBERTRAIN_LOG_LEVEL` | config.rb:127-151 (`attr_reader`, `log_level_given?`, `log_level_unless_given`), default l.1093 `:info`; no environment variable; no validation (Logger#level= silently maps an unknown level to `:info`, logger.rb:25); `:none` drops RequestLogger (application.rb:506) and sets the Logger to `:error` (runtime.rb:81) | Task 2: the variable, validation, `:fatal` accepted |
| `c.log_format`, `CYBERTRAIN_LOG_FORMAT`, `c.log_tags` | do not exist | Task 2 (`log_format`), Task 4 (`log_tags`) |
| log silencing in tests (5a) | test/bundle.rb:142-163: `log_level_unless_given(:none)`, `mail_delivery_method_unless_given`, `force_ssl_unless_given`, `hosts_from_env_unless_given` | Task 4 adds `sentry_dsn_unless_given("")` (D14) |
| `Cybertrain::Middleware::RequestId` | does not exist; middleware classes are `Cybertrain::<Name> < Middleware` in cybertrain/middleware/*.rb (request_logger.rb:15, error_pages.rb:14) | Task 5: `Cybertrain::RequestId` (D6) |
| request id source | none anywhere (`grep -rn request_id cybertrain` is empty) | Task 5 |
| trusted proxy check | `Request.trusted_peer?(addr)` http/request.rb:1135; `Request#client_ip` l.1188; `Config#trusted_proxy` config.rb:213, `trusted_proxies` l.229, installed by Runtime.apply (runtime.rb:76-77) | reused as is |
| `request.request_id` | does not exist; `Request` readers at http/request.rb:56-113 | Task 5: `attr_accessor :request_id` ("") |
| stack order | application.rb:485-513 `build_stack`: HostAuthorization → SslRedirect → ErrorPages (production) → RequestLogger → CSP → Stream::Endpoint → HealthCheck → Static → MethodOverride → SessionStore → CsrfProtection → router; development's `front_app` (roles/server.rb:234-243) wraps the stack in Dev::ErrorPage and a second HostAuthorization | Task 5: RequestId outermost of both (D6) |
| `ErrorPages` | middleware/error_pages.rb:21-33 rescues everything, `ClientError.classify` logs `"Class: message"` at error for a 500 (client_error.rb:20-28) and `reset_to` clears headers (http/response.rb:179-183) | Task 9 reports there; Task 5 re-adds the echo after it |
| `Dev::ErrorPage` | dev/error_page.rb:37-53, outside the stack | Task 5: echo; no report of its own (D7) |
| `Application#call` | application.rb:243-247 (Test::Client's path, test/client.rb:446, no rescue: the exception reaches the test) | goes through the stack's RequestId, which reports (D7) |
| Server's bare-app path | http/server.rb:524-535 `handle` → `error_response` (a new Response) | Task 5: echo `request.request_id` when set; nothing reported (the HTTP layer cannot reach the reporter; the stack's RequestId already did) |
| `ContextHandler` | context_handler.rb:16-21 | unchanged |
| `where` = `ArticlesController#create` | nothing records the controller and action on the Context; `Controller#run_action` controller.rb:1397 sets `@action_name`; `Class#name` is namespaced under the pinned Spinel (NOTES rule 46, revised) | Task 5: `Context#controller_action`, also written into the Scope |
| `rescue_from` | controller.rb:1534 `rescue_with_handler`: a matching handler swallows the exception, a client fault becomes a 400 there, anything else re-raises | unchanged: neither reaches a report |
| jobs: `Job.run_handler`, discards | job/executor.rb:211-220 `run_handler` (two rescue arms), `retry_later` l.223-244 and `discard` l.247-258 (what generated `retry_on` / `discard_on` arms and the mail job call, gen/jobs.rb, mailer/later.rb:111-123), `finish` l.147-186 logs `job 42 (WelcomeJob) attempt 1 of 5 failed: ...`; `finish_in_flight` l.123-128 (a plain method with `ensure`) | Task 6: the job Scope around `finish`; Task 9: reports in all three |
| `cybertrain_jobs.request_id`, "the existing `ALTER_COLUMNS` path" | job/store.rb:33-47 `TABLE_SQL`, l.51-55 `ALTER_COLUMNS` (claimed_by, heartbeat_at, concurrency_key), `insert` l.73-85, `claim` l.433-482 and `claim_after` l.490-522 SELECT `id, kind, payload, attempts`; `Job::Run.new` job.rb:125 (six parameters); `Job.enqueue` job.rb:412-422 | Task 6 |
| job kind as tag | a class job's kind is its class name (gen/jobs.rb `job_kind` → `"NotifyCommentJob"`); a block job's kind is its string (job.rb:236); the mail job's is `"cybertrain mail"` (mailer/later.rb:19) | `[NotifyCommentJob 42]`, `[cybertrain mail 7]` |
| scheduled tasks, "the two rescue sites" | scheduler.rb:538-550 `run_task` and l.455-463 `schedule_next`; other rescues (timetable l.470-500, lease l.508-518, recovery l.528) are infrastructure | Task 6 tags `run_task`; Task 9 reports both sites only |
| feeds | websocket.rb:782 `spawn_feed`, l.792-798 `run_feed_logged` (thread death, rescue Exception), on_open / on_message / on_tick rescues l.940-963; supervisor give-up background/supervisor.rb:269 (`fatal`, no exception object), l.336 `supervise_tick` | Task 6 tags; Task 9 reports l.794, 940-963 and the give-up |
| mail | `deliver_later` is a job of kind `"cybertrain mail"`; its failures go through `Job.retry_later` / `Job.discard` (mailer/later.rb:104-128) | covered by the job sites, `where` `"cybertrain mail"` (D10) |
| stream endpoints | stream/endpoint.rb, stream/websocket_server.rb and http/server.rb:518 (`stream error: ...`) log only | unchanged, not reported (not in §13.2) |
| `Cybertrain.error`, `ErrorReporter`, `ErrorSubscriber`, `ErrorEvent` | do not exist; method names in use: `error` (logger.rb:41, template/parser.rb:89), `report` (cli/toolchain.rb:820), `handle` (job.rb:236, http/server.rb:524), `subscribe` (websocket.rb:451 → Subscription, stream/hub.rb:244 → Subscriber), `release` (lease.rb:82 → nil), `error_message` (db/connection.rb:897, i18n.rb:663, both String), `drain` (http/server.rb:271) | Task 7; NAME_HOMES rows in Task 1; spike item 8 |
| `HttpClient` (`timeout: 3, deadline: 5`) | http_client.rb:393 `initialize(timeout:, deadline:, max_body:, allow_private: Cybertrain.config.http_allow_private, redirects:)`, `post(url, body, content_type:, headers:)` l.429; `BlockedAddressError` for private addresses unless allowed | used as is by Task 10 |
| "https needs `cybertrain/net/tls`, which every application links since phase 4" | not so: `require "cybertrain"` loads neither http_client.rb nor net/tls.rb (only websocket.rb and websocket/client.rb require http_client; net/tls.rb is required by nothing in the framework); libssl itself is linked through encryptor.rb | Task 10: the sender file requires both, and gen/app.rb requires the sender (D4) |
| `Test::HttpReceiver` | test/http_receiver.rb: `start`, `url`, `received_request(wait)`, `received_requests(count, wait)`, `ReceivedRequest#http_method` / `http_target` / `http_path` / `http_header` / `http_body`; plaintext on 127.0.0.1; stopped after each test (5a `after_this_case`) | Task 10: `Test::SentryReceiver` on it |
| backtraces | NOTES rule 107: release build `[]`, `--debug` `file:line:in 'Mod.meth'` frames with `<main>` at line 1; CRuby 3.3 quotes with a backtick, 3.4 and Spinel with `'` | Task 10 attaches frames when non-empty (D13) |
| `SecureRandom.uuid` | not used anywhere; `SecureRandom.random_bytes` and `.hex` are (crypto.rb:35, 80) | Task 5: `Crypto.uuid` from 16 random bytes (D8) |
| `JSON.generate` for log lines | CRuby's raises `JSON::GeneratorError` on invalid UTF-8 | Task 2: the Logger's own escaper (D3) |
| Runtime settings | runtime.rb:66-94 `apply` (logger level l.81), `reset!` l.121-140, `describe` l.156-166 (compared by test/runtime.rb) | Task 2: `Logger.json_lines`, `describe` gains `log_format=` |
| Config validation | config/validation.rb:26-73 `validation_error` chain | Task 2 `log_error`; Task 4 extends it and adds `reporting_error` |
| test reset hooks | test_help.rb registers `RateLimit` and locale resets with `Test.on_reset` | Task 3 (the Scope), Task 7 (the reporter) |
| roles' stops ("the server's graceful stop waits up to 2 seconds") | roles/server.rb:124-126 (`Job.stop!`, `Background.stop_all`), roles/worker.rb:64, roles/feeds.rb:90 and 104 | Task 10: each role drains the reports (D11) |
| direct STDOUT writes | banners and refusals: roles.rb:62-87, roles/server.rb:217-228 and 283, roles/feeds.rb:59-61, application.rb:298-299, main.rb:140-156 and 245, db/migrator.rb:56/98/170; command output: cli/**, job/cli.rb, db/cli.rb, console | stay direct: command output and boot banners, not log lines (Rails and Puma print banners plainly); nothing else in the runtime writes to STDOUT or STDERR |
| line text in tests and docs | `"[INFO] ..."` asserted in 20 test programs (`grep -lE "\[(INFO|ERROR|WARN|DEBUG|FATAL)\]" test/*.rb`), 4 snapshots print log lines to stdout (test/application.rb.expected:22-26, config_settings:4-9, integration_m1:1, logger_tls:1-2), cybertrain/cli/authentication_tests.rb:1714, 1738, 1760, 2358, 2975, 2986 (generated tests), examples/blog/test/controllers/accounts_controller_test.rb:388 and passwords_controller_test.rb:118, 142, 164; guides: authentication, background-and-operations, configuration, external-services, realtime, tutorial | Task 2 (code and tests), Task 12 (guides) |
| generators | cli/templates.rb `env_example` l.93-129, `config_app` l.208-271, `deploy_yml` l.517, `kamal_secrets` l.629; gen/app.rb by generator/manifest.rb (runner.rb:145, 173) | Task 8 (templates), Task 10 (gen/app.rb) |
| design numbers | design.md ends at D84 (l.1411); D85 and D86 are free (spec §15 and §21) | Task 12 |

## Global Constraints

- **Closer to Rails, then easier to understand** decides every judgement call (spec §0): Rails' names (`Cybertrain.error.report` / `handle` / `subscribe`, `request.request_id`, `X-Request-Id`, `log_tags`, `tagged`), defaults and output; compatibility with 0.4 applications carries low weight (§18 lists each break; D15 adds two).
- **The HTTP layer loads alone** (script/check-http-layer): `cybertrain/logger.rb` and `cybertrain/http/*.rb` require nothing outside `cybertrain/http/`, `params.rb` and `logger.rb`, and name no constant they do not load. The reporter, the Config and the Clock are on the other side; the Logger learns the travelled time through `Logger.follow_clock` (D2). `ruby script/check-http-layer` stays green with its allowed list unchanged.
- **No computed `send`**, no `instance_exec` (rules 1, 2); **no stored block** run through a base-class receiver (rule 88): subscribers and the sender are objects with an overridden method (`ErrorSubscriber#report`, `ErrorReporter::Sender#deliver_event`), the base classes carry the stubs (rule 3).
- **One return type per method name across the program** (rules 10, 34, 41): Task 1 seeds every NAME_HOMES row below; spike item 8 compiles the clash-prone names beside their namesakes; a name the plan did not foresee is added by its task. Event readers are prefixed (D9); Scope readers are `scope_*`.
- **Per-thread state** only through the one `Thread.current[Logger::SCOPE_KEY]` slot (rule 102, spike item 7); module-level ivars and constants, never `@@` (rules 18, 64), for the Logger's switches and lock and the reporter.
- Other Spinel rules in play: threads started through a method (21); `Queue#pop(timeout:)` for the reporter's wait (85); no lock on every request unless spike item 9 allows the Logger's (57); save-yield-ensure in a module function for `tagged` and `handle` (90, 103); a rescue in a plain non-yielding method (32, 45); `rescue JSON::NestingError, JSON::ParserError, StandardError => e` wherever everything is caught (33, 61), plus the `NotImplementedError, SystemStackError, ScriptError` arm where a thread must survive (as job/executor.rb:217); an exception is read (`class.name`, `message`, `backtrace`) only where it was rescued, never a `.new` one (53); exception classes compared by name through `ClientError.status_for`, never `is_a?` (47, 54, 104); every byte scan (the JSON escaper, the `X-Request-Id` check, the DSN parser, the frame parser, the rate parser) reads its parameter through a fresh local (62); no parameter defaulting to nil that a caller gives a Time (109: `occurred_at` is always passed); no statement `case` on a plain Integer in framework code (110: level and status checks are Hash lookups or `if` chains); seeded containers (9).
- **No `Time.now`** in framework code (5a's scan in test/clock.rb): wall time is `Clock.now` (log time, `occurred_at`, the dedupe and drop windows), durations and waits `Clock.monotonic`.
- **The Logger and the reporter never raise into their caller**: a failure inside `report`, a subscriber or the sender is logged and swallowed; nothing the reporter logs is reported.
- **Never skip, delete or weaken a test** to make a task pass; a snapshot changes only where behaviour changed on purpose, and each task names the snapshots it changes.
- **An option that is not implemented is refused with a message, never ignored**: an unknown level, format or tag, a Proc in `log_tags`, a DSN that does not parse, a rate outside 0 to 1 stop boot (spec §14).
- **The landing rule (learned in 5a):** a change to a framework file is compiled in every test program that loads that file, not only in the task's own tests (`ruby -I. -e 'require "x"; puts $LOADED_FEATURES'` lists what a CRuby-runnable program loads; for the others, `grep -l` the require chains). logger.rb, clock.rb, config.rb, http/request.rb, controller.rb and job/*.rb are loaded by nearly every program: a task that changes one of them runs `script/test-shard 0 1` (the whole suite) before it commits. Every compile runs under the shared build lock (`flock <lock> <command>`), one at a time.
- Every task ends with: `ruby script/gate` green, `ruby script/check-reserved-names` green, `ruby script/check-http-layer` green, `script/api-docs` clean, its own `spin test test/<x>.rb` programs green (snapshots through `script/regen-snapshot test/<x>.rb` for SQLite/FFI programs, `spin test --regen` for the others), the landing rule above, and `docs/api/stubs/generated_app.rb` mirroring any newly emitted method. Documents are checked with `ruby script/gate`, `script/api-docs`, `script/check-guide-i18n` and `script/guide-pages`.
- Toolchain: `export PATH=/root/.cybertrain/spinel/2026.11.04.7026/lib/spinel:$PATH`; `spin test test/<x>.rb`; `script/regen-snapshot test/<x>.rb`; CRuby: `ruby -I. test/<x>.rb`; blog: `cd examples/blog && spin run gen && cybertrain test && spin run gen -- --check` (`ruby -I../.. ../../exe/cybertrain test` before the gem is installed).
- Commits carry no model identifier in code, comments or commit subjects (CONTRIBUTING.md); the executor adds the trailers. Messages, option names and output lines are the spec's verbatim where it fixes them, else this plan's.

## Decisions

The plan's rulings where the spec leaves a choice the code forces, or where the code disagrees with the spec.

- **D1. Files.** `cybertrain/logger.rb` (the line, the Scope, `tagged`); `cybertrain/middleware/request_id.rb` (`Cybertrain::RequestId`); `cybertrain/sentry_dsn.rb` (`Cybertrain::SentryDsn`, no requires: Config's validation and the sender both read it); `cybertrain/error_reporter.rb` (`ErrorEvent`, `ErrorSubscriber`, `ErrorReporter`, `ErrorReporter::Sender`, `Cybertrain.error`; required by cybertrain.rb and by every file that reports); `cybertrain/error_reporter/sentry.rb` (`ErrorReporter::SentrySender`; requires `cybertrain/http_client` and `cybertrain/net/tls`; installs itself when loaded); `cybertrain/test/sentry_receiver.rb` (`Test::SentryReceiver`, `Test::SentryEnvelope`; required by `cybertrain/test_help.rb`).
- **D2. The log time without the Clock.** logger.rb keeps a module ivar `@clock_micros` (Integer, -1 for real time, rule 7) set by `Logger.follow_clock(micros)`; `Logger.timestamp` formats `@clock_micros` when it is not -1, else `Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)`, as `%Y-%m-%dT%H:%M:%S.%LZ` in UTC. clock.rb requires logger.rb and calls `Logger.follow_clock` after every write of its state: `travel_to` (the instant), `travel_during` (the instant, and in its `ensure` the restored instant or -1), `travel_back` (-1). Rejected: adding clock.rb and time_zone.rb to the HTTP layer's allowed list (it would carry the zone database into a liftable library), and redefining a Logger method from clock.rb (a second definition of one method, a Spinel question with no gain).
- **D3. The line.** Text: `"<time> <LEVEL>"`, then `" [<tag>]"` for each tag in order, then `" <message>"`, then `"\n"` unless the message ends in one. JSON (`Logger.json_lines` true): `{"time":"…","level":"INFO",` then `"request_id":"…",` only when the request id is among the line's tags, then `"tags":[…],"message":"…"}` and `"\n"`; the tags exclude the request id. Strings are quoted by `Logger.json_quote` (the Logger's own, not `JSON.generate`, which raises on invalid UTF-8 under CRuby): `"` `\` as `\"` `\\`, `\n` `\r` `\t` as themselves escaped, other bytes below 0x20 and 0x7F as `\u00XX`, and when the text is not valid UTF-8 every byte at or above 0x80 as `\ufffd`. The format switch (`Logger.json_lines`), the lock (`Logger::LOCK`) and the clock are class-level, so a test that swaps `Cybertrain.logger` keeps them. Each line is one `write` of the whole String (plus `flush` for STDOUT) under `LOCK`, built before the lock is taken; spike item 9 decides whether the lock stays (fallback: no lock, and a line over 4,096 bytes is shortened: in text mode the line is cut to 4,096 bytes ending in `" [truncated]\n"`; in JSON mode the message is capped before `Logger.json_quote`, with `" [truncated]"` as its last characters, so the line keeps its closing quote and brace and stays valid JSON, and the 100 KB test of Review Focus 4 then expects the capped message in both modes).
- **D4. Linking the Sentry sender.** gen/app.rb's first line becomes `require "cybertrain/error_reporter/sentry"` (generator/manifest.rb), so every application binary and its `cybertrain test` bundle link HttpClient and TLS; framework test programs that do not load a gen/app.rb do not pay for them. A booted Application whose `sentry_dsn` is set while no SentrySender is installed logs once at warn: `CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender (require "cybertrain/error_reporter/sentry")`.
- **D5. The Scope.** `Logger::Scope.new(request_id, request_method, request_path, where, tags, id_tag, context)`: Strings, `tags` an `Array<String>` (the line's tags in order), `id_tag` the index of the request id among them (-1 when it is not shown), `context` a `Hash{String => String}`; readers `scope_request_id`, `scope_request_method`, `scope_request_path`, `scope_where`, `scope_tags`, `scope_id_tag`, `scope_context`; one writer `scope_where=` (the controller's); `with_tags(more) -> Scope` (a copy with tags appended, `id_tag` kept). `Logger::NO_SCOPE` is the empty Scope; `Logger.current_scope -> Scope` answers it when the slot is nil; `Logger.swap_scope(scope) -> Scope` stores nil for `NO_SCOPE` and answers the previous Scope. Whoever runs work on a thread swaps a Scope in and swaps the previous one back in an `ensure` of a plain method. Spike item 7 decides the slot's content: one Scope object (this design) or, its fallback, the spec's String and Array under two keys, or the Context fallback of §16 item 7.
- **D6. RequestId's place and name.** `Cybertrain::RequestId < Middleware` (the siblings' convention; the spec's `Middleware::RequestId` would nest a subclass inside its superclass), outermost in `build_stack` (outside HostAuthorization and SslRedirect, so their 403 and redirect carry the id) and, in development, outermost in `front_app` too; a RequestId that finds `request.request_id` already set neither sets the id nor swaps the Scope, but still reports what escapes the stack (D7), so the two in development make one id and one report. It sets `request.request_id`, swaps in the request's Scope (`request_path` already `ParameterFilter.filter_path(path)`, D8), calls the stack, re-raises what escapes it, sets `X-Request-Id` on `ctx.response` after the stack returned or raised, and swaps the Scope back.
- **D7. Who reports a request's 500.** The outermost layer that sees the exception, as the spec says, but placed where the code allows: `ErrorPages` (production) reports what it rescues; RequestId reports what escapes the stack (development, test, a stack without ErrorPages); `Dev::ErrorPage` sits outside the stack and reports nothing (the stack's RequestId already did); the Server's bare-app path (http/server.rb:524) cannot reach the reporter and needs not. Either way: once, and only when `ClientError.status_for(e) >= 500`. `Dev::ErrorPage` and `Server#handle` re-add `X-Request-Id` from `request.request_id` after replacing the response.
- **D8. The request id.** Generated by `Crypto.uuid` (16 `SecureRandom.random_bytes`, byte 6 = `(b & 0x0f) | 0x40`, byte 8 = `(b & 0x3f) | 0x80`, lower-case hex in 8-4-4-4-12), not `SecureRandom.uuid` (unused so far under Spinel). Accepted from the request's `X-Request-Id` only when `Request.trusted_peer?(request.remote_addr)` and `RequestId.accepted?(value)`: 1 to 255 bytes, each `[A-Za-z0-9-]` (a repeated header arrives joined with `", "` and fails). `request_path` everywhere in reports is `ParameterFilter.filter_path(request.path)`, the request log's own masking (a password-reset token in the path), never the query.
- **D9. Event readers.** Every `ErrorEvent` reader carries the `error_` prefix, extending the spec's `error_class` / `error_message` to the whole table, because `where` (Relation), `release` (Lease), `backtrace` (Exception) and `context` would otherwise share names with other types: `error_class`, `error_message`, `error_where`, `error_request_id`, `error_request_method`, `error_request_path`, `error_environment`, `error_release`, `error_handled` (Boolean), `error_context` (`Hash{String => String}`), `error_backtrace` (`Array<String>`), `error_occurred_at` (Time). Decided by the maintainer on 2026-11-13 (see the end); the spec's table lists the unprefixed names.
- **D10. Report sites.** Requests: D7. Jobs: `Executor.run_handler`'s two rescue arms (the default policy), `Executor.retry_later` (`retry_on`) and `Executor.discard` (`discard_on`, and the mail job's discards), each with the exception still at hand; `where` the job's kind, context `job.id`, `job.attempt` (from the Scope) and `job.max_attempts` (`Cybertrain.config.job_max_attempts`, the policy's `attempts_limit`, or the attempt number for a discard). Mail: no site of its own; the mail job's kind `"cybertrain mail"` is its `where`. Scheduled tasks: `run_task` and `schedule_next`, `where` `schedule:<name>`. Feeds: `run_feed_logged`, the on_open / on_message / on_tick rescues, `where` `feed:<name>`; the supervisor's give-up has no exception object, so it is `report_message("Cybertrain::Background::FeedFailed", <the fatal line's text>, "feed:<name>")` (`FeedFailed < StandardError` is defined for its name and never raised). The existing log lines stay, word for word.
- **D11. Delivery.** `QUEUE_LIMIT = 100`, `DEDUPE_SECONDS = 60`, `DROP_LOG_SECONDS = 60`. Dedupe keys `"<class>\n<message>\n<where>"` against `Clock.now` (so a test travels past the window); the key is the spec's (§13.4 and §20: "keyed by class, message and `where`"; "a job failure is reported on every failed attempt (dedupe collapses repeats)"), so two attempts of one job, or two jobs of one kind, failing alike within the window make one queued event, and Task 9's test of every attempt travels past the window between attempts; the table of recent keys drops expired keys whenever it passes 1,000 entries. A full queue drops the event and counts it; the delivery thread logs `error reports dropped: <n>` at warn when the count is non-zero and the last such line is at least 60 seconds old (`Clock.now`), then zeroes it. The delivery thread starts, through a method, on the first queued event; an event is queued only when a subscriber exists or the sender `sends?`; otherwise `report` returns at once and no thread starts. Each role's stop (server, worker, feeds) calls `Cybertrain.error.drain_reports(2.0)` after its services stopped.
- **D12. `handle` and `tagged` answer the block's value** (Rails), through rule 103's form; spike item 8 (and 7 for `tagged`) compiles blocks answering a String, an Integer and nil in one program. Fallback: both answer nil, and the guide says so.
- **D13. Backtraces** (spike item 5, rule 107): the event carries `e.backtrace` when it is non-empty (CRuby, a `--debug` build), else `[]`. The sender turns it into `stacktrace.frames`, oldest first, each `{"filename":…,"lineno":…,"function":…}` parsed from `file:line:in 'method'` or `` file:line:in `method' ``; a frame that does not parse is `{"filename":"<the line>"}`; an empty backtrace sends no `stacktrace` key.
- **D14. Tests never send to a real Sentry.** `cybertrain test`'s boot empties `sentry_dsn` unless config/app.rb assigned it (`c.sentry_dsn_unless_given("")`, as 5a's force_ssl and hosts). The sender reads `Cybertrain.config.sentry_dsn` (and `error_sample_rate`) each time it delivers, parsing a DSN text once (cached by text), so a test points it at a `Test::SentryReceiver` by assignment and restores it in `teardown`. `CYBERTRAIN_LOG_LEVEL` likewise does not count as given: an exported level does not unsilence the bundle (config/app.rb does).
- **D15. Two upgrade notes beyond §18**: generated authentication tests (and any test) that assert `"[ERROR] …"` in a captured log assert the message and the level separately; an exported `CYBERTRAIN_SENTRY_DSN` is ignored by `cybertrain test`.
- **D16. NOTES rules** found here take 111 onwards, with "Rules by topic" entries; spinel-feedback items continue after AO.

## NAME_HOMES rows (Task 1)

Added to script/check-reserved-names (existing definers verified at 9866af2; `NAME_CANDIDATES` += `error report handle subscribe tagged request_id release`):

| Name | Files allowed to define it |
| --- | --- |
| `error` | `cybertrain/logger.rb cybertrain/template/parser.rb cybertrain/error_reporter.rb` (Logger#error nil, Parser#error raises, `Cybertrain.error` an ErrorReporter) |
| `report` | `cybertrain/cli/toolchain.rb cybertrain/error_reporter.rb` (Toolchain.report prints; ErrorReporter#report and ErrorSubscriber#report nil) |
| `handle` | `cybertrain/job.rb cybertrain/http/server.rb cybertrain/error_reporter.rb` |
| `subscribe` | `cybertrain/websocket.rb cybertrain/stream/hub.rb cybertrain/error_reporter.rb` |
| `tagged` | `cybertrain/logger.rb` |
| `request_id` | `cybertrain/http/request.rb` |
| `release` | `cybertrain/lease.rb cybertrain/config.rb` |
| `error_message` | `cybertrain/db/connection.rb cybertrain/i18n.rb cybertrain/error_reporter.rb` (all String) |
| `info` | `cybertrain/cli/toolchain.rb cybertrain/logger.rb` |
| `drain` | `cybertrain/http/server.rb` (the reporter's is `drain_reports`) |

## Review Focus

1. **A request's or a job's context leaking into the next one on the same thread** (a keep-alive connection whose first request raises in the test environment, so RequestId re-raises; a job whose handler raises past `run_handler`'s arms; a `tagged` block left by `assert_raises`): the next request's lines and reports carry only its own id, the next job's only its own tag, and after each the thread's `Logger.current_scope` is the one before. Pinned in Task 5's test "a raising request leaves no Scope behind on its thread", Task 6's "a failing job, then a job enqueued outside a request" and Task 3's "tagged restores the tags after a raise".
2. **A secret in the path of a reported request** (a password reset link `/passwords/<signed token>/edit` that raises; a query `?token=…&password=…`): the event's `error_request_path` is the request log's masked path and no event field holds the token or the query. Pinned in Task 9's test "a reset link's token and the query never reach a report".
3. **`X-Request-Id` values a client or a proxy really sends** (from a trusted proxy: `"abc-123"`, 255 bytes, 256 bytes, `""`, `"abc 123"`, `"abc\r\nX-Evil: 1"`, two headers joined `"a, b"`, non-ASCII; from an untrusted peer: a valid one): only the first two are used; every other request gets a fresh UUID, and the log line never carries the raw value. Pinned in Task 5's test "X-Request-Id from a trusted proxy is used only when well-formed".
4. **Log text that breaks a line format** (a visitor's title with `"\n"`, `"\e[31m"`, `"\xFF"`, `"日本"` logged by the application; a message of 100 KB): in JSON mode each is one valid JSON line (escapes, `\ufffd`, UTF-8 kept); in text mode the bytes are written as given (Rails does the same); a 100 KB line is one write. Pinned in Task 2's test "messages with control bytes, invalid UTF-8 and non-ASCII are one valid JSON line".
5. **A Sentry endpoint that misbehaves while errors keep coming** (refuses connections, answers 429, accepts and never answers, sits on a private address without `http_allow_private`; a subscriber that raises): `report` returns at once on the caller's thread, each failure is one warn line, the queue fills and drops rather than blocks, and the next event still reaches a working receiver. Pinned in Task 10's test "a refusing, a rate-limiting and a silent Sentry never block or raise" and Task 7's "a raising subscriber is logged, the others still receive".

---

### Task 1: The spike (spec §16 items 7–9) and the name homes

**Files:**
- Create: `spikes/phase5/thread_scope.rb` (item 7), `spikes/phase5/error_names.rb` (item 8), `spikes/phase5/logger_lock/` (item 9: `run.sh`, and `logger_locked.rb` / `logger_unlocked.rb`, the two Logger variants swapped into a copy of the blog by the script) — kept as the record, commands and output in each header; not tests
- Modify: `script/check-reserved-names` (the NAME_HOMES rows and candidates above), spec §16 ("**Results (2026-11-1x, Spinel 2026.11.04.7026, …)**" for items 7–9, after 5a's results), `spikes/NOTES.md` (D16), `docs/spinel-feedback.md` (a row per limit found)

**Interfaces:**
- Produces: item 7 → Tasks 3, 5, 6 (the Scope object in one slot, the two-key form, or the Context fallback); item 8 → Tasks 3, 4, 7, 9, 10 (Rails' names or §16's fallback names `Cybertrain.error_reporter`, `report_error`, `handle_errors`, `add_subscriber`; `c.release` or `c.app_release`; `handle` / `tagged` answering the block's value or nil; `context:` with Symbol keys or String keys only); item 9 → Task 2 (lock or the 4,096-byte fallback).

- [ ] **Step 1: Item 7, `thread_scope.rb`.** With `require "cybertrain"`, the db pool holding a Connection under its `Thread.current` key and `I18n.locale` set per thread (as spikes/phase4b/thread_locale.rb does): a `Scope`-shaped class (String ivars, an `Array<String>` ivar, a `Hash{String => String}` ivar, prefixed readers) stored in `Thread.current[:cybertrain_log_scope]`; four threads spawned through a method (rule 21), each stores its own, `sleep 0`, reads it back through a method that answers a NO_SCOPE constant for nil, and prints its request id and tags; run with `SPINEL_WORKERS=1` and `SPINEL_WORKERS=4`. Then the two-key form (a String under one key, an `Array<String>` under another). Then `tagged`'s shape: an instance method `def tagged(*tags) = Mod.tagged_during(tags) { yield }` over a module function that saves the slot, sets a copy with the tags, yields into a local and restores in `ensure`, nested three deep, the innermost block raising and rescued by a rescuing yielder (`assert_raises`'s shape), with blocks answering a String, an Integer and nil. Pass: every thread prints its own values under both worker counts, the slot is restored after the raise, each block value comes back. Fallbacks in order: the two-key form; then §16's (the request id on the Context; `tagged` answers nil if only the values fail).
- [ ] **Step 2: Item 8, `error_names.rb`.** In one program with the whole framework, `require "cybertrain/websocket"` and `require "cybertrain/lease"`: `module Cybertrain; def self.error = @reporter` answering an `ErrorReporter` beside `Logger#error(msg)` and `Template::Parser#error`, each called; `ErrorReporter#report(e, handled: true, context: {})` and `ErrorSubscriber#report(event)` overridden by two subclasses (one answering nil, one answering an Array, `EVENTS << event`) beside `CLI::Toolchain.report` (`require "cybertrain/cli/toolchain"`); `ErrorReporter#handle(context: {}) { }` (a rescuing yielder, rule 103) beside `Job.handle(kind) { }`, with blocks answering a String, an Integer and nil and one whose only statement is `raise`, called from a method body and from a block nested in a block (rule 45); `ErrorReporter#subscribe(obj)` beside `WebSocket.subscribe(...)` (a Subscription) and `Stream::Hub#subscribe(names)` (a Subscriber); `Config#release` (a String) beside `Lease.release` (nil); `report(e, context: { "order_id" => 7 })` and `report(e, context: { order_id: "x" })` in one program, each key read back as a String. Pass: it compiles and answers as CRuby does. Fallbacks: §16 item 8's names for the method that fails (each failing name alone); `c.app_release` for `release`; a nil answer for `handle` (D12); String keys only for `context:` (the guide says so).
- [ ] **Step 3: Item 9, `logger_lock/run.sh`.** The blog built with `cybertrain build` twice (the request log on: `CYBERTRAIN_LOG_LEVEL=info`), once with a Logger whose `log` builds the line and does one `STDOUT.write` + `flush` inside `Logger::LOCK.synchronize`, once without the lock; served under `taskset -c 0,1` with `SPINEL_WORKERS=2`, stdout to a pipe read by `cat > /dev/null`. Load: `bench/run --configs 2cpu --runs 5` when `wrk` is installed; otherwise the script's own CRuby loader (8 keep-alive connections over 127.0.0.1 from 8 threads, GET `/` and `/articles/1`, 10 s per run, five runs, a request over 1 s counted as a stall). Record requests per second and stalls per run for both. Pass: all five locked runs complete with no stall and no dead server, and their median is at least 95% of the unlocked median. Fallback: D3's unlocked form with the 4,096-byte cut.
- [ ] **Step 4: Rows.** Add the NAME_HOMES rows and candidates; `ruby script/check-reserved-names` green.
- [ ] **Step 5: Amend spec §16** with each item's result and the branch taken; NOTES rules (111 onwards) and spinel-feedback rows for anything that failed.
- [ ] **Step 6: Gate and commit**: "Phase 5b spike: a per-thread log scope, Rails.error's names beside their namesakes, the logger's lock under two workers; name homes for the logger and the error reporter".

---

### Task 2: The log line: time, level, JSON lines, one write (§12.1, §12.5, §14's level and format rows; acceptance 11 in part)

**Files:**
- Modify: `cybertrain/logger.rb` (D2, D3: `LEVEL_NAMES = { debug: "DEBUG", info: "INFO", warn: "WARN", error: "ERROR", fatal: "FATAL" }`, `LOCK = Mutex.new`, `@json_lines = false`, `@clock_micros = -1`; `Logger.json_lines -> Boolean`, `Logger.json_lines=(on) -> nil`, `Logger.follow_clock(micros) -> nil`, `Logger.timestamp -> String`, `Logger.format_line(level_name, tags, id_tag, msg) -> String` (text or JSON per `json_lines`; Task 3 passes the Scope's tags), `Logger.json_quote(text) -> String` (with its quotes), `Logger.write_line(io, line) -> nil` (the one locked write); `log` builds the line before the lock; the header comment and the `@io` notes kept), `cybertrain/clock.rb` (requires `cybertrain/logger`; D2's calls in `travel_to`, `travel_during` and its `ensure`, `travel_back`), `cybertrain/config.rb` (`log_level` from `CYBERTRAIN_LOG_LEVEL` through `Config.default_log_level` (`"debug"` … `"none"` to the Symbol, any other text `text.to_sym` for the error), not counted as given (D14); `attr_accessor :log_format` (Symbol, `CYBERTRAIN_LOG_FORMAT`, `:text`, an unknown text kept as its Symbol); the `log_level` comment loses "Lines go to standard output as `[INFO] ...`"), `cybertrain/config/validation.rb` (`log_error -> String` first in `validation_error`: `"log_level must be :debug, :info, :warn, :error, :fatal or :none (got :verbose)"`, `"log_format must be :text or :json (got :xml)"`), `cybertrain/runtime.rb` (`apply`: `Logger.json_lines = config.log_format == :json`; `reset!`: false; `describe` ends `… log_level=info log_format=text time_zone=UTC`), comments that quote `[ERROR]` / `[WARN]` (scheduler.rb:33, config.rb's setting docs, background/supervisor.rb)
- Modify (the line's shape, D15): every test asserting `"[LEVEL] …"` (the 20 programs of `grep -lE "\[(INFO|ERROR|WARN|DEBUG|FATAL)\]" test/*.rb`: compare the message part, or freeze the clock and compare the whole line); the four snapshots that print log lines (test/application.rb, test/config_settings.rb, test/integration_m1.rb, test/logger_tls.rb: freeze the clock where the lines are written, `2026-11-11T12:00:00.000Z WARN Blocked host: …`); `cybertrain/cli/authentication_tests.rb` (each `assert_includes log.string, "[ERROR] <text>"` becomes `assert_includes log.string, " ERROR "` and `assert_includes log.string, "<text>"`) and its snapshots `test/cli_authentication*.rb.expected`; `examples/blog/test/controllers/accounts_controller_test.rb`, `passwords_controller_test.rb` (the same change)
- Test: `test/logger.rb` (rewritten expectations), `test/logger_lines.rb` (new, CRuby-runnable: requires `cybertrain/logger`, `cybertrain/test`), `test/logger_threads.rb` (new, compiled), `test/config_settings.rb`, `test/config_validation.rb`, `test/runtime.rb` (grown)

**Interfaces:**
- Consumes: Task 1's item 9 verdict; 5a's `Clock` and `travel_to` / `freeze_time`.
- Produces: `Logger.format_line`, `json_quote`, `json_lines=`, `follow_clock`, `timestamp`, `write_line`; `Config#log_format`, `Config#log_error`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/logger_lines.rb
def sink_logger(level = :info) = Cybertrain::Logger.new(SINK, level)   # SINK = StringIO.new, cleared per test
test "the line: UTC time with milliseconds, the level in capitals, the message, every level" do
  logger = sink_logger(:debug)
  travel_to(Time.utc(2026, 11, 11, 12)) do
    logger.debug("d"); logger.info("i"); logger.warn("w"); logger.error("e"); logger.fatal("f")
  end
  assert_equal "2026-11-11T12:00:00.000Z DEBUG d\n2026-11-11T12:00:00.000Z INFO i\n" \
               "2026-11-11T12:00:00.000Z WARN w\n2026-11-11T12:00:00.000Z ERROR e\n" \
               "2026-11-11T12:00:00.000Z FATAL f\n", SINK.string
end
test "real time has milliseconds and follows travel_back" do
  sink_logger.info("x")
  assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z INFO x\n\z/, SINK.string)
  travel_to(Time.utc(2001, 9, 9, 1, 46, 40)) { travel_to(Time.utc(2030, 1, 1)) { sink_logger.info("in") }; sink_logger.info("out") }
  assert_includes SINK.string, "2030-01-01T00:00:00.000Z INFO in\n2001-09-09T01:46:40.000Z INFO out\n"
end
test "a level below the logger's is silent; a message ending in a newline gets no second one" do
  logger = sink_logger(:warn)
  freeze_time
  logger.info("no"); logger.warn("yes\n")
  assert_equal 1, SINK.string.count("\n")
end
test "JSON lines: time, level, tags, message" do
  Cybertrain::Logger.json_lines = true
  travel_to(Time.utc(2026, 11, 11, 12)) { sink_logger.info("Completed 200 in 12ms") }
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","tags":[],"message":"Completed 200 in 12ms"}\n), SINK.string
ensure
  Cybertrain::Logger.json_lines = false
end
test "format_line puts the request id apart from the other tags in JSON, in place in text" do
  travel_to(Time.utc(2026, 11, 11, 12)) do
    tags = ["WelcomeJob 42", "3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c"]
    assert_equal "2026-11-11T12:00:00.000Z ERROR [WelcomeJob 42] [3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c] boom\n",
                 Cybertrain::Logger.format_line("ERROR", tags, 1, "boom")
    Cybertrain::Logger.json_lines = true
    assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"ERROR","request_id":"3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c","tags":["WelcomeJob 42"],"message":"boom"}\n),
                 Cybertrain::Logger.format_line("ERROR", tags, 1, "boom")
  end
ensure
  Cybertrain::Logger.json_lines = false
end
test "messages with control bytes, invalid UTF-8 and non-ASCII are one valid JSON line" do   # Review Focus 4
  q = ->(s) { Cybertrain::Logger.json_quote(s) }
  assert_equal %("a\\"b\\\\c\\nd\\te\\r\\u0001\\u001b[31m\\u007f"), q.call("a\"b\\c\nd\te\r\u0001\e[31m\x7f")
  assert_equal %("x\\ufffdy"), q.call("x\xFFy".b)
  assert_equal %("日本"), q.call("日本")
  long = "z" * 100_000
  Cybertrain::Logger.json_lines = true
  sink_logger.info("title: a\nb #{long}")
  assert_equal 1, SINK.string.count("\n")
  assert_includes SINK.string, %("message":"title: a\\nb #{long}"}\n)
ensure
  Cybertrain::Logger.json_lines = false
end
```

```ruby
# test/logger_threads.rb (compiled)
test "lines from several threads never interleave" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  threads = (0...4).map { |t| spawn_writer(logger, t) }   # 200 lines each of "t<t> " + "x" * 3000, spawned through a method (rule 21)
  threads.each(&:join)
  lines = sink.string.split("\n")
  assert_equal 800, lines.size
  assert lines.all? { |l| l.match?(/\A\S+Z INFO t[0-3] x{3000}\z/) }
end
```

Config and runtime (grown files): "log_level from CYBERTRAIN_LOG_LEVEL" (`debug` → `:debug`, `none` → `:none`, `verbose` → `log_error` is the message above, and `log_level_given?` stays false); "log_format from CYBERTRAIN_LOG_FORMAT" (`json` → `:json`, `xml` → the message above; an assigned `:json` boots); "Runtime.apply installs the format and reset! puts it back" (`Logger.json_lines` true after `apply` with `:json`, false after `reset!`; `Runtime.describe` ends `log_level=info log_format=json time_zone=UTC`).

- [ ] **Step 2: Run** `ruby -I. test/logger_lines.rb`, `spin test test/logger_lines.rb test/logger_threads.rb test/logger.rb test/config_settings.rb test/config_validation.rb test/runtime.rb`: FAIL.
- [ ] **Step 3: Implement** as in Files; then update the line-shape assertions and the four snapshots; `ruby script/check-http-layer` (logger.rb still requires nothing).
- [ ] **Step 4: Run** the tests above (PASS), then the landing rule: `script/test-shard 0 1` (logger.rb and clock.rb are in every program), `script/auth-e2e signup` (the generated tests' assertions), `cd examples/blog && cybertrain test`.
- [ ] **Step 5: Gate and commit**: "Log lines with the time on the Clock, the level and the message; JSON lines; CYBERTRAIN_LOG_LEVEL and CYBERTRAIN_LOG_FORMAT; one write per line".

---

### Task 3: The per-thread Scope and `tagged` (§12.2 "thread-local", §12.4, acceptance 11's `tagged`)

**Files:**
- Modify: `cybertrain/logger.rb` (D5: `Logger::Scope`, `SCOPE_KEY = :cybertrain_log_scope`, `NO_SCOPE`, `Logger.current_scope -> Scope`, `Logger.swap_scope(scope) -> Scope`, `Logger.reset_scope -> nil`, `Logger.tagged_during(tags) { } -> the block's value` (module function, save-yield-ensure, rule 103), `Logger#tagged(*tags) { } -> the block's value` forwarding to it; `log` passes `current_scope.scope_tags` and `scope_id_tag` to `format_line`; item 7's fallback shapes if Task 1 took them), `cybertrain/test_help.rb` (`Test::Help.log_scope_reset` → `Logger.reset_scope`, registered with `Test.on_reset`: spec §20's "resets … the log tags")
- Test: `test/logger_scope.rb` (new, compiled), `test/test_lifecycle.rb` (grown: the reset)

**Interfaces:**
- Consumes: Task 2's `format_line`.
- Produces: the Scope API every later task uses.

- [ ] **Step 1: Write the failing tests**

```ruby
test "tagged adds tags for the block and restores them, also after a raise" do
  logger = Cybertrain::Logger.new(SINK)
  travel_to(Time.utc(2026, 11, 11, 12)) do
    logger.tagged("billing") do
      logger.info("a")
      logger.tagged("x", "y") { logger.info("b") }
      assert_raises(RuntimeError) { logger.tagged("inner") { raise "boom" } }
      logger.info("c")
    end
    logger.info("d")
  end
  assert_equal "2026-11-11T12:00:00.000Z INFO [billing] a\n2026-11-11T12:00:00.000Z INFO [billing] [x] [y] b\n" \
               "2026-11-11T12:00:00.000Z INFO [billing] c\n2026-11-11T12:00:00.000Z INFO d\n", SINK.string
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end
test "tagged answers the block's value" do
  logger = Cybertrain::Logger.new(SINK)
  assert_equal "s", logger.tagged("t") { "s" }
  assert_equal 3, logger.tagged("t") { 3 }
  assert_nil logger.tagged("t") { nil }
end
test "a Scope's request id and tags reach the line; tagged keeps the request id apart in JSON" do
  id = "3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c"
  scope = Cybertrain::Logger::Scope.new(id, "GET", "/articles", "", [id], 0, {})
  saved = Cybertrain::Logger.swap_scope(scope)
  Cybertrain::Logger.json_lines = true
  logger = Cybertrain::Logger.new(SINK)
  travel_to(Time.utc(2026, 11, 11, 12)) { logger.tagged("billing") { logger.info("charged 300") } }
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","request_id":"#{id}","tags":["billing"],"message":"charged 300"}\n), SINK.string
ensure
  Cybertrain::Logger.json_lines = false
  Cybertrain::Logger.swap_scope(saved)
end
test "a Scope set on one thread is not seen on another" do
  saved = Cybertrain::Logger.swap_scope(Cybertrain::Logger::Scope.new("r1", "", "", "", ["r1"], 0, {}))
  other = run_on_thread { Cybertrain::Logger.current_scope.scope_request_id }   # a method spawning the thread (rule 21)
  assert_equal "", other
  assert_equal "r1", Cybertrain::Logger.current_scope.scope_request_id
ensure
  Cybertrain::Logger.swap_scope(saved)
end
```

test/test_lifecycle.rb: a case that swaps in a Scope and does not restore it, then a case asserting `Logger.current_scope` is `NO_SCOPE`.

- [ ] **Step 2: Run** `spin test test/logger_scope.rb test/test_lifecycle.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS), `ruby script/check-http-layer`, then `script/test-shard 0 1` (logger.rb).
- [ ] **Step 5: Gate and commit**: "A per-thread log scope with the request id and tags; Cybertrain.logger.tagged".

---

### Task 4: Configuration for tags and reporting (§14's `log_tags`, `sentry_dsn`, `error_sample_rate`, `release` rows)

**Files:**
- Create: `cybertrain/sentry_dsn.rb` (`Cybertrain::SentryDsn.problem(text) -> String` ("" when it parses), `SentryDsn.parse(text) -> SentryDsn` (raises `ArgumentError` with the problem), readers `dsn_public_key`, `dsn_project_id`, `dsn_endpoint`; `scheme://key[:secret]@host[:port][/path]/<digits>`, the secret ignored, the endpoint `scheme://host[:port][/path]/api/<id>/envelope/`; a byte scan, no regexp)
- Modify: `cybertrain/config.rb` (`log_tags` (`Array<Symbol>`, `[:request_id]`, assigned in `initialize`, rule 73); `sentry_dsn` (String, `CYBERTRAIN_SENTRY_DSN`, `""`) with `sentry_dsn=` recording given and `sentry_dsn_unless_given(value)` (D14); `error_sample_rate` (Float, `CYBERTRAIN_ERROR_SAMPLE_RATE`, `1.0`; the text kept for the error); `release` (String, `CYBERTRAIN_RELEASE`, `""`, or Task 1's fallback name); each with its YARD doc), `cybertrain/config/validation.rb` (`log_error` also checks `log_tags`; `reporting_error -> String` after `mail_delivery_error`), `cybertrain/test/bundle.rb` (`c.sentry_dsn_unless_given("")` beside 5a's defaults)
- Modify: `script/test-command-e2e` (a variant exporting `CYBERTRAIN_SENTRY_DSN`; test/fixtures/test_app gains a test printing `Cybertrain.config.sentry_dsn.inspect`)
- Test: `test/config_settings.rb`, `test/config_validation.rb` (grown), `test/sentry_dsn.rb` (new, CRuby-runnable), `script/test-command-e2e`

**Interfaces:**
- Produces: `Config#log_tags`, `#sentry_dsn`, `#sentry_dsn_unless_given`, `#error_sample_rate`, `#release`, `#reporting_error`; `SentryDsn`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "a DSN's key, project and endpoint" do
  d = Cybertrain::SentryDsn.parse("https://abc@o1.ingest.sentry.io/42")
  assert_equal ["abc", "42", "https://o1.ingest.sentry.io/api/42/envelope/"], [d.dsn_public_key, d.dsn_project_id, d.dsn_endpoint]
  assert_equal "http://127.0.0.1:9000/sentry/api/7/envelope/", Cybertrain::SentryDsn.parse("http://k@127.0.0.1:9000/sentry/7").dsn_endpoint
  assert_equal "abc", Cybertrain::SentryDsn.parse("https://abc:secret@h/1").dsn_public_key
end
test "what a DSN may not be" do
  { "ftp://a@h/1" => "the scheme must be https or http", "https://h/1" => "no public key before the @",
    "https://a@/1" => "no host", "https://a@h/" => "no project id", "https://a@h" => "no project id",
    "https://a@h/x1" => "the project id must be digits", "https://a@h/1?x=1" => "a query or a fragment is not allowed" }.each do |text, why|
    assert_equal why, Cybertrain::SentryDsn.problem(text)
  end
end
test "the reporting settings from the environment and their checks" do
  # CYBERTRAIN_SENTRY_DSN=https://h/1 -> "sentry_dsn must look like https://<public key>@<host>/<project id>: no public key before the @"
  # CYBERTRAIN_ERROR_SAMPLE_RATE=0.25 -> 0.25; =x -> "error_sample_rate must be a number from 0.0 to 1.0 (got \"x\")";
  #   c.error_sample_rate = 1.5 -> "... (got 1.5)"
  # CYBERTRAIN_RELEASE=abc123 -> "abc123"
  # c.log_tags = [:request_id, :remote_ip] boots; [:user_agent] -> "log_tags may hold :request_id and :remote_ip (got :user_agent)"
  # defaults: log_tags [:request_id], sentry_dsn "", error_sample_rate 1.0, release ""
end
test "cybertrain test empties an exported DSN unless config/app.rb assigned one" do   # test-command-e2e variant
  # CYBERTRAIN_SENTRY_DSN=https://k@sentry.example/1 cybertrain test  -> a test printing Cybertrain.config.sentry_dsn sees ""
end
```

- [ ] **Step 2: Run** `ruby -I. test/sentry_dsn.rb`, `spin test test/sentry_dsn.rb test/config_settings.rb test/config_validation.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS), `script/test-command-e2e`, then `script/test-shard 0 1` (config.rb).
- [ ] **Step 5: Gate and commit**: "Config: log_tags, sentry_dsn, error_sample_rate and release, validated at boot; cybertrain test ignores an exported DSN".

---

### Task 5: The request id (§12.2, §12.4's request tags; acceptance 11's request-id items)

**Files:**
- Create: `cybertrain/middleware/request_id.rb` (D6, D8: `Cybertrain::RequestId < Middleware`; `HEADER = "X-Request-Id"`; `initialize(app, log_tags = Cybertrain.config.log_tags)`; `call(ctx) -> nil`; `RequestId.accepted?(value) -> Boolean`; `RequestId.scope_for(request, id, log_tags) -> Logger::Scope` (tags in `log_tags` order: the id for `:request_id`, `request.client_ip` for `:remote_ip`; `id_tag` the id's index or -1); `call` keeps its rescue in its own body (no yield), re-raises with `raise e`)
- Modify: `cybertrain/http/request.rb` (`attr_accessor :request_id`, `""` in `initialize`, documented `@api public`), `cybertrain/http/server.rb` (`handle`'s rescue: the error response gets `X-Request-Id` when `request.request_id` is not empty), `cybertrain/dev/error_page.rb` (after rendering, the header from `ctx.request.request_id`), `cybertrain/context.rb` (`attr_accessor :controller_action`, `""`), `cybertrain/controller.rb` (`run_action`: `@ctx.controller_action = "#{self.class.name}##{action}"` and the current Scope's `scope_where=` when it is not `NO_SCOPE`), `cybertrain/application.rb` (requires `cybertrain/middleware/request_id`; `RequestId.new(app, c.log_tags)` outermost in `build_stack`; the stack comment), `cybertrain/roles/server.rb` (`front_app` wraps a RequestId outermost in development), `cybertrain/crypto.rb` (`Crypto.uuid -> String`)
- Modify (request ids in captured output): tests whose stdout or exact assertions now carry an id set `c.log_tags = []` there (test/application.rb's blocked-host lines and the others the landing run finds)
- Test: `test/request_id.rb` (new, compiled, a booted Application with `ThingsController` actions `show` (logs `"in action"`, renders `request.request_id`), `boom` (raises `RuntimeError, "boom"`), `bad` (a missing required parameter), `scope_where` (renders `Logger.current_scope.scope_where`)), `test/dev_error_page.rb`, `test/server.rb`, `test/crypto.rb` (grown)

**Interfaces:**
- Consumes: Task 3's Scope, Task 4's `log_tags`.
- Produces: `request.request_id`, `Context#controller_action`, `RequestId.scope_for`, `Crypto.uuid`, the echo; Task 9 adds the report in `RequestId#call`'s rescue.

- [ ] **Step 1: Write the failing tests**

```ruby
UUID = /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/
test "every request gets a UUID, echoed and readable as request.request_id" do
  r1 = client.get("/things/show"); r2 = client.get("/things/show")   # Test::Client#get(path, headers = {})
  assert_match UUID, r1.header("X-Request-Id")
  assert_equal r1.header("X-Request-Id"), r1.body
  assert_not_equal r1.header("X-Request-Id"), r2.header("X-Request-Id")
end
test "X-Request-Id from a trusted proxy is used only when well-formed" do   # Review Focus 3
  Cybertrain::Request.trusted_proxy = true                                   # the client's peer_address is 127.0.0.1
  assert_equal "abc-123", client.get("/things/show", { "X-Request-Id" => "abc-123" }).header("X-Request-Id")
  assert_equal "a" * 255, client.get("/things/show", { "X-Request-Id" => "a" * 255 }).header("X-Request-Id")
  ["a" * 256, "", "abc 123", "abc_123", "abc\r\nX-Evil: 1", "a, b", "日本"].each do |v|
    assert_match UUID, client.get("/things/show", { "X-Request-Id" => v }).header("X-Request-Id")
  end
  client.peer_address = "203.0.113.9"                                       # an untrusted peer
  assert_match UUID, client.get("/things/show", { "X-Request-Id" => "abc-123" }).header("X-Request-Id")
end
test "every line logged in the request carries the id, the application's own included" do
  log = capture_log { client.get("/things/show") }        # Cybertrain.logger swapped to a StringIO logger, freeze_time
  id = last_response.header("X-Request-Id")
  lines = log.lines.map { |l| l.chomp.sub(/\A\S+ /, "") }       # the time dropped
  assert_equal ["INFO [#{id}] Started GET \"/things/show\" for 127.0.0.1", "INFO [#{id}] in action"], lines[0, 2]
  assert lines[2].start_with?("INFO [#{id}] Completed 200 in "), lines[2]
end
test "log_tags orders the request's tags; [] turns them off" do
  # [:remote_ip, :request_id] -> "INFO [127.0.0.1] [<id>] in action"; [] -> "INFO in action"; the header is sent either way
end
test "the id is echoed on error responses" do
  # a client fault (/things/bad) 400; a HostAuthorization 403; the production stack with test/fixtures/error_pages' 500.html
  # and /things/boom; Dev::ErrorPage over /things/boom; Server#handle's bare path (a bare app behind a RequestId that raises) -> each has a UUID header
end
test "a raising request leaves no Scope behind on its thread" do   # Review Focus 1
  assert_raises(RuntimeError) { client.get("/things/boom") }         # test env: Application#call lets it reach the test
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
  log = capture_log { client.get("/things/show") }
  assert_equal 1, log.scan(/\[[0-9a-f-]{36}\]/).uniq.size
end
test "the controller and action are the request's where" do
  assert_equal "ThingsController#scope_where", client.get("/things/scope_where").body
end
test "Crypto.uuid is a version 4 UUID" do
  assert_match UUID, Cybertrain::Crypto.uuid
end
```

- [ ] **Step 2: Run** `spin test test/request_id.rb test/crypto.rb test/dev_error_page.rb test/server.rb`: FAIL.
- [ ] **Step 3: Implement**; fix the outputs the new tags change (`log_tags = []` where a test prints or compares lines).
- [ ] **Step 4: Run** them (PASS), `ruby script/check-http-layer` (request.rb and server.rb stay inside the layer), `script/test-shard 0 1` (request.rb, controller.rb, application.rb).
- [ ] **Step 5: Gate and commit**: "Request ids: generated or taken from a trusted proxy, echoed in X-Request-Id, request.request_id, carried by every line of the request; log_tags".

---

### Task 6: Tags outside requests: jobs, feeds and scheduled tasks; `cybertrain_jobs.request_id` (§12.3; acceptance 11's job, feed and schedule items)

**Files:**
- Modify: `cybertrain/job/store.rb` (`TABLE_SQL` ends `…, concurrency_key TEXT NOT NULL DEFAULT '', request_id TEXT NOT NULL DEFAULT '');`; `ALTER_COLUMNS` += `["request_id", "ALTER TABLE cybertrain_jobs ADD COLUMN request_id TEXT NOT NULL DEFAULT ''"]`; `insert(kind, payload, run_at, key, request_id)`; `claim` and `claim_after` SELECT and pass `request_id`), `cybertrain/job.rb` (`Job.enqueue` passes `Logger.current_scope.scope_request_id`; `Run#initialize(…, run_now, run_request_id = "")` and `attr_reader :run_request_id` `@api public`), `cybertrain/job/executor.rb` (`Executor.job_scope(run) -> Logger::Scope`: tags `["<kind> <id>"]` plus the recorded id when it is not empty and `Cybertrain.config.log_tags` includes `:request_id` (`id_tag` 1, else -1), `where` the kind, context `{"job.id" => id, "job.attempt" => attempts}`; `finish_in_flight` swaps it in before `finish` and back in its `ensure`), `cybertrain/scheduler.rb` (`run_task` swaps in a Scope with the tag and `where` `schedule:<name>` and back in an `ensure`), `cybertrain/websocket.rb` (`run_feed_logged` swaps in `feed:<name>` first; the thread ends with it)
- Test: `test/log_tags_background.rb` (new, compiled with SQLite; a `WelcomeJob`-shaped class job as test/job_helpers.rb declares jobs, a scheduler task, a feed against `Test::WebSocketReceiver`), `test/jobs.rb`, `test/job_threads.rb`, `test/scheduler.rb`, `test/websocket_subscription.rb` (snapshots where lines changed)

**Interfaces:**
- Consumes: Task 3's Scope, Task 4's `log_tags`.
- Produces: `Run#run_request_id`, the recorded column, the job / schedule / feed Scopes (their `where` and context feed Task 9).

- [ ] **Step 1: Write the failing tests**

```ruby
RID = "3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c"
test "a job enqueued in a request records its id, and the job's lines carry both tags" do
  id = with_scope(RID) { WelcomeJob.perform_later("user_id" => 1) }   # with_scope: swap in RequestId.scope_for-shaped Scope, swap back
  assert_equal RID, request_id_of(id)
  log = capture_log { travel_to(Time.utc(2026, 11, 11, 12)) { perform_enqueued_jobs } }
  assert_includes log, "2026-11-11T12:00:00.000Z INFO [WelcomeJob #{id}] [#{RID}] welcome 1\n"            # the handler's own line
  assert_includes log, "2026-11-11T12:00:00.000Z INFO [WelcomeJob #{id}] [#{RID}] job #{id} (WelcomeJob) done\n"
end
test "a failing job, then a job enqueued outside a request" do   # Review Focus 1
  failing = with_scope(RID) { BoomJob.perform_later }
  quiet = WelcomeJob.perform_later("user_id" => 2)
  log = capture_log { travel_to(Time.utc(2026, 11, 11, 12)) { perform_enqueued_jobs } }
  assert_includes log, "ERROR [BoomJob #{failing}] [#{RID}] job #{failing} (BoomJob) attempt 1 of 5 failed: RuntimeError: boom; retrying in "
  assert_includes log, "INFO [WelcomeJob #{quiet}] welcome 2\n"
  assert_equal "", request_id_of(quiet)
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end
test "an older cybertrain_jobs gets request_id on first use" do
  # create the table with 9866af2's TABLE_SQL, insert a row, Job.ensure_installed: the column exists, the old row reads ""
end
test "log_tags without :request_id leaves the job's request tag off" do
  # c.log_tags = [] -> "INFO [WelcomeJob <id>] welcome 1"
end
test "a scheduled task's lines carry [schedule:<name>]" do
  # Scheduler.every(60, "nightly") { Cybertrain.logger.info("pruned") }; Scheduler.run_task(task) -> "INFO [schedule:nightly] pruned"
end
test "a feed thread's lines carry [feed:<name>]" do
  # WebSocket.subscribe("prices", receiver.url).on_message { |conn, msg| Cybertrain.logger.info("tick #{msg}") }; the receiver sends "1"
  # -> "INFO [feed:prices] tick 1"
end
```

- [ ] **Step 2: Run** `spin test test/log_tags_background.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it (PASS) plus `spin test test/jobs.rb test/job_threads.rb test/job_helpers.rb test/scheduler.rb test/websocket_subscription.rb test/mailer_job.rb test/test_mail_jobs.rb`, then `script/test-shard 0 1` (job/*.rb).
- [ ] **Step 5: Gate and commit**: "Job, feed and scheduled-task tags on log lines; a job enqueued in a request records the request id".

---

### Task 7: `Cybertrain.error`: report, handle, subscribe, the event and its delivery (§13.1, §13.3, §13.4's queue, dedupe and shutdown; acceptance 12 in part)

**Files:**
- Create: `cybertrain/error_reporter.rb` (requires logger, clock, config; `ErrorEvent` (D9: `initialize` with the twelve fields in D9's order, readers only); `ErrorSubscriber` (`report(event) -> nil`, the stub); `ErrorReporter::Sender` (`sends? -> Boolean` false, `deliver_event(event) -> Boolean` false); `ErrorReporter` with `QUEUE_LIMIT`, `DEDUPE_SECONDS`, `DROP_LOG_SECONDS`, `NO_CONTEXT` (a seeded empty `Hash{String => String}`), and `report(error, handled: true, context: NO_CONTEXT) -> nil`, `handle(context: NO_CONTEXT) { } -> the block's value or nil` (D12; `JSON::NestingError, JSON::ParserError, StandardError` reported with `handled: true`), `subscribe(subscriber) -> nil`, `report_unhandled(error, where, context) -> nil` (`@api private`; `handled` false; `where` "" means the Scope's), `report_message(error_class, message, where, context) -> nil` (`@api private`), `drain_reports(seconds = 2.0) -> Boolean` (true once the queue is empty and nothing is in flight; waits on `Clock.monotonic`), `sender -> Sender`, `sender=(sender) -> nil`, `reset! -> nil` (`@api private`: drains, empties the recent keys and the drop count), `dropped_count -> Integer`, `delivery_started? -> Boolean` (both `@api private`, for tests); the event built on the caller's thread from the exception (class name, message, backtrace or `[]`), the Scope (request id, method, path, `where`, context merged under the caller's keys), `Cybertrain.config.env` and `release`, `Clock.now`; context values through `to_s`; the delivery thread (D11) hands each event to every subscriber (each call in a plain rescuing method: `error subscriber <Class> failed: <Class>: <message>` at error), then to `sender.deliver_event` when `sender.sends?`; `module Cybertrain; def self.error`, the instance in a module ivar)
- Modify: `cybertrain.rb` (`require "cybertrain/error_reporter"`), `cybertrain/test_help.rb` (`Test::Help.error_reporter_reset` → `Cybertrain.error.reset!`, registered with `Test.on_reset`)
- Test: `test/error_reporter.rb` (new, compiled; `Collect < Cybertrain::ErrorSubscriber` appending to `EVENTS`)

**Interfaces:**
- Consumes: Task 3's Scope, Task 4's `release`.
- Produces: the reporter API Tasks 9, 10, 11 use.

- [ ] **Step 1: Write the failing tests**

```ruby
test "report records an exception the application rescued, with the request's fields" do
  Cybertrain.error.subscribe(Collect.new)
  Cybertrain.config.release = "abc123"
  scope = Cybertrain::Logger::Scope.new("r-1", "POST", "/orders", "OrdersController#create", ["r-1"], 0, {})
  saved = Cybertrain::Logger.swap_scope(scope)
  travel_to(Time.utc(2026, 11, 11, 12)) do
    begin
      raise ArgumentError, "bad"
    rescue ArgumentError => e
      assert_nil Cybertrain.error.report(e, context: { "order_id" => 7 })
    end
  end
  Cybertrain::Logger.swap_scope(saved)
  assert Cybertrain.error.drain_reports(2.0)
  ev = EVENTS.last
  assert_equal ["ArgumentError", "bad", "OrdersController#create", "r-1", "POST", "/orders", "test", "abc123", true,
                { "order_id" => "7" }, Time.utc(2026, 11, 11, 12)],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id, ev.error_request_method,
                ev.error_request_path, ev.error_environment, ev.error_release, ev.error_handled, ev.error_context, ev.error_occurred_at]
end
test "outside a request the request fields and where are empty" do
  # report(e) with no Scope -> error_where "", error_request_id "", error_request_method "", error_request_path ""
end
test "handle answers the block's value, or nil after reporting what it raised" do
  assert_equal "ok", Cybertrain.error.handle { "ok" }
  assert_equal 3, Cybertrain.error.handle { 3 }
  assert_nil Cybertrain.error.handle(context: { "feed" => "prices" }) { raise "parse" }
  assert_nil Cybertrain.error.handle { JSON.parse("{") }
  Cybertrain.error.drain_reports(2.0)
  assert_equal [["RuntimeError", true, { "feed" => "prices" }], ["JSON::ParserError", true, {}]],
               EVENTS.last(2).map { |e| [e.error_class, e.error_handled, e.error_context] }
end
test "a raising subscriber is logged, the others still receive, nothing is reported for it" do   # Review Focus 5
  Cybertrain.error.subscribe(Raising.new); Cybertrain.error.subscribe(Collect.new)
  log = capture_log { report_runtime("x"); Cybertrain.error.drain_reports(2.0) }
  assert_includes log, "ERROR error subscriber Raising failed: RuntimeError: subscriber bug"
  assert_equal 1, EVENTS.size
end
test "the same class, message and where is queued once a minute" do
  freeze_time
  2.times { report_runtime("same") }; report_runtime("other")
  travel 61; report_runtime("same")
  Cybertrain.error.drain_reports(2.0)
  assert_equal ["same", "other", "same"], EVENTS.map(&:error_message)
end
test "a full queue drops and counts, logged at most once a minute" do
  # Blocking < ErrorSubscriber: pushes to STARTED, then RELEASE.pop(timeout: 10)
  freeze_time
  report_runtime("e0"); STARTED.pop(timeout: 5)           # e0 is in flight, the queue is empty
  (1..104).each { |i| report_runtime("e#{i}") }            # 100 queued, 4 dropped
  assert_equal 4, Cybertrain.error.dropped_count
  log = capture_log { 105.times { RELEASE << true }; Cybertrain.error.drain_reports(5.0) }
  assert_equal 1, log.scan("WARN error reports dropped: 4").size
  assert_equal 101, EVENTS.size                            # Blocking appends to EVENTS once released
end
test "with no subscriber and no sender nothing is queued and no thread starts" do
  # a fresh ErrorReporter: report(e) answers nil, delivery_started? false
end
test "reports in one test are not deduplicated against the previous test's" do
  report_runtime("again"); Cybertrain.error.drain_reports(2.0); assert_equal 1, EVENTS.size  # (the previous test reported "same")
end
```

- [ ] **Step 2: Run** `spin test test/error_reporter.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it (PASS) plus `spin test test/test_lifecycle.rb test/harness.rb`, then `script/test-shard 0 1` (cybertrain.rb).
- [ ] **Step 5: Gate and commit**: "Cybertrain.error: report, handle and subscribe; error events of Strings delivered off the request, deduplicated, on a bounded queue".

---

### Task 8: What `cybertrain new` writes for logs and reporting (§11's operations side, §14)

**Files:**
- Modify: `cybertrain/cli/templates.rb` (`env_example`: a block "Logs and error reports. Settings, except the DSN, which is kept out of the repository like a secret" with `# CYBERTRAIN_LOG_LEVEL=info`, `# CYBERTRAIN_LOG_FORMAT=json`, `# CYBERTRAIN_SENTRY_DSN=https://<public key>@<host>/<project id>`, `# CYBERTRAIN_ERROR_SAMPLE_RATE=1.0`, `# CYBERTRAIN_RELEASE=` each with a one-line comment; `config_app`: commented `# c.log_format = :json if c.production?`, `# c.log_tags = [:request_id]`, and a commented `Cybertrain.error.subscribe(...)` example after the block; `deploy_yml`: under `clear:` a commented `# CYBERTRAIN_LOG_FORMAT: json`, under `secret:` a commented `# - CYBERTRAIN_SENTRY_DSN`; `kamal_secrets`: a commented `# CYBERTRAIN_SENTRY_DSN=$CYBERTRAIN_SENTRY_DSN`)
- Test: `test/cli_new.rb` (snapshot and an exact `assert_includes` of the env block), `script/generators-e2e` (the generated application still boots and passes `cybertrain test`)

**Interfaces:**
- Consumes: Task 4's names.

- [ ] **Step 1: Write the failing tests** ("new writes the logging and reporting variables, all commented" → `.env.example` contains `"# CYBERTRAIN_SENTRY_DSN=https://<public key>@<host>/<project id>\n"` and the four others; `config/app.rb` contains `"# c.log_format = :json if c.production?"`; `config/deploy.yml` contains `"# - CYBERTRAIN_SENTRY_DSN"`; nothing uncommented, so a new application's behaviour is unchanged).
- [ ] **Step 2: Run** `spin test test/cli_new.rb`: FAIL.
- [ ] **Step 3: Implement**; regenerate the snapshot.
- [ ] **Step 4: Run** it (PASS) and `script/generators-e2e`.
- [ ] **Step 5: Gate and commit**: "cybertrain new: the log and error-report variables in .env.example, config/app.rb and the Kamal files".

---

### Task 9: What is reported automatically (§13.2; acceptance 12's sources, 4xx and `rescue_from`, the absent fields)

**Files:**
- Modify: `cybertrain/middleware/request_id.rb` (its rescue reports before re-raising: `Cybertrain.error.report_unhandled(e, RequestId.where_for(ctx), NO_CONTEXT)` when `ClientError.status_for(e) >= 500`; `RequestId.where_for(ctx) -> String` = `ctx.controller_action`, or `"request"` when empty), `cybertrain/middleware/error_pages.rb` (the same after `classify` answers 500; requires `cybertrain/error_reporter`), `cybertrain/job/executor.rb` (D10: `run_handler`'s two arms, `retry_later`, `discard`), `cybertrain/scheduler.rb` (`run_task`, `schedule_next`), `cybertrain/websocket.rb` (`run_feed_logged`, the three callback rescues), `cybertrain/background.rb` (`FeedFailed < StandardError`), `cybertrain/background/supervisor.rb` (the give-up: `report_message`), each file requiring `cybertrain/error_reporter` (rule 84)
- Test: `test/error_reporting_sources.rb` (new, compiled with SQLite: an Application with `ThingsController#boom` (raises `RuntimeError, "boom"`), `#bad` (a missing parameter, 400), `#rescued` (raises `Handled`, which `rescue_from Handled` renders), `#token` at `/passwords/:token/edit` (raises); jobs `BoomJob` (default policy), `RetryJob` (`retry_on RuntimeError, attempts: 3`), `DiscardJob` (`discard_on ArgumentError`); a scheduler task `nightly` that raises; a feed `prices` whose `on_message` raises; a `deliver_later` to `"not an address"` with `mail_delivery_method :test`), `test/error_pages.rb`, `test/dev_error_page.rb` (grown)

**Interfaces:**
- Consumes: Tasks 5, 6, 7.

- [ ] **Step 1: Write the failing tests**

```ruby
test "a request's 500 is reported once, with where, method and path; the existing log line stays" do
  log = capture_log { assert_raises(RuntimeError) { client.get("/things/boom?page=2&password=hunter2") } }
  ev = only_event                                          # drain_reports, then exactly one event
  assert_equal ["RuntimeError", "boom", "ThingsController#boom", "GET", "/things/boom", false, {}],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_method, ev.error_request_path, ev.error_handled, ev.error_context]
  assert_equal last_request_id, ev.error_request_id
  assert_includes log, "ERROR [#{last_request_id}] RuntimeError: boom"
end
test "production's ErrorPages and development's error page report it once too" do
  # production stack (env production, public 500.html): /things/boom -> 500 page, one event
  # front_app with Dev::ErrorPage: one event, and the page still renders
end
test "no report for a 4xx or a rescue_from" do
  client.get("/things/bad"); client.get("/things/rescued")
  assert_equal 0, events_after_drain.size
end
test "a reset link's token and the query never reach a report" do   # Review Focus 2
  token = Cybertrain::Token.issue("reset", 7, 900, "digest")
  assert_raises(RuntimeError) { client.get("/passwords/#{token}/edit?token=#{token}") }
  ev = only_event
  assert_equal "/passwords/[FILTERED]/edit", ev.error_request_path
  refute all_strings(ev).any? { |s| s.include?(token) }     # every String field, context keys and values, backtrace
end
test "no params, headers, cookies or client address in an event" do
  # post /things/boom with a form field secret=s3, a header X-Api-Key: k9, a cookie c=v7, from 203.0.113.9 via a trusted proxy
  # -> no String of the event contains "s3", "k9", "v7" or "203.0.113.9"
end
test "every failed job attempt is reported, with the job's context and its request id" do
  id = with_scope(RID) { BoomJob.perform_later }
  perform_enqueued_jobs
  ev = only_event
  assert_equal ["BoomJob", RID, false, { "job.id" => id.to_s, "job.attempt" => "1", "job.max_attempts" => "5" }],
               [ev.error_where, ev.error_request_id, ev.error_handled, ev.error_context]
  # RetryJob: job.max_attempts "3"; DiscardJob: one event, the row discarded
end
test "a deliver_later that fails is reported as cybertrain mail" do
  # deliver_later checks the fields before enqueueing, so the failing row is enqueued as it would be by an older
  # process: Job.enqueue("cybertrain mail", JSON.generate({ "to" => "a b@example.com", "subject" => "S", "body" => "b" }));
  # perform_enqueued_jobs -> Mailer#deliver's ArgumentError -> Job.discard -> one event, where "cybertrain mail",
  # error_class "ArgumentError"
end
test "scheduled tasks and feeds" do
  # Scheduler.run_task(nightly) -> where "schedule:nightly"; a cron that Cron.next_after cannot satisfy -> where "schedule:<name>"
  # feed prices: on_message raises -> where "feed:prices"; Supervisor give-up (feed_restart_limit 1) -> error_class
  # "Cybertrain::Background::FeedFailed", error_message "feed prices restarted 1 times in 600 s; exiting", where "feed:prices"
end
```

- [ ] **Step 2: Run** `spin test test/error_reporting_sources.rb test/error_pages.rb test/dev_error_page.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS) plus `spin test test/jobs.rb test/scheduler.rb test/websocket_subscription.rb test/background.rb test/feeds_exit.rb test/mailer_job.rb`, then `script/test-shard 0 1` (job/*.rb, the middleware).
- [ ] **Step 5: Gate and commit**: "Reported automatically: a request's 500, every failed job attempt and discard, scheduled tasks, feeds and mail; never a 4xx or a rescue_from".

---

### Task 10: The Sentry sender, `Test::SentryReceiver` and the stop's wait (§13.4; acceptance 12's sample rate, envelope, auth header, path prefix and backtrace)

**Files:**
- Create: `cybertrain/error_reporter/sentry.rb` (requires `cybertrain/error_reporter`, `cybertrain/sentry_dsn`, `cybertrain/http_client`, `cybertrain/net/tls`; `ErrorReporter::SentrySender < ErrorReporter::Sender`: `sends? -> Boolean` (`!Cybertrain.config.sentry_dsn.empty?`), `deliver_event(event) -> Boolean` (sampled by `error_sample_rate` with a draw from 4 random bytes; parses the DSN text once per text; `HttpClient.new(timeout: 3, deadline: 5).post(endpoint, body, content_type: "application/x-sentry-envelope", headers: { "X-Sentry-Auth" => … })` in a plain rescuing method; a non-2xx answer logs `error report not sent: Sentry answered <status>`, an exception `error report not sent: <Class>: <message>`, both at warn, no retry), `SentrySender.sampled?(rate, draw) -> Boolean` (`draw < rate`, draw in 0.0…1.0), `SentrySender.auth_header(key) -> String`, `SentrySender.envelope(event, dsn_text, event_id) -> String` (three lines: `{"event_id":…,"sent_at":…,"dsn":…}`, `{"type":"event","content_type":"application/json","length":<bytes>}`, the event JSON; built with `Logger.json_quote`), `SentrySender.frames_json(backtrace) -> String` (D13); last line `Cybertrain.error.sender = Cybertrain::ErrorReporter::SentrySender.new`), `cybertrain/test/sentry_receiver.rb` (`Test::SentryReceiver < Test::HttpReceiver` (`max: 50`, answers `200 {"id":"…"}`), `dsn(project = "1", prefix = "") -> String` (`"http://public@127.0.0.1:<port><prefix>/<project>"`), `received_events(count, wait = 5.0) -> Array<SentryEnvelope>`; `Test::SentryEnvelope`: `sentry_path`, `sentry_auth`, `sentry_content_type`, `sentry_body` (Strings), `sentry_field(path) -> String` (a dotted path into the event's JSON, `"exception.values.0.type"`; `""` when absent; numbers and booleans as their JSON text), `sentry_header_field(name) -> String` (the envelope header's))
- Modify: `cybertrain/generator/manifest.rb` (D4: gen/app.rb's first line), regenerated `gen/app.rb` of `examples/blog`, `test/fixtures/gen_app`, `test/fixtures/gen_namespaced`, `test/fixtures/test_app` and every other fixture application `spin run gen -- --check` covers; `cybertrain/test_help.rb` (requires the receiver); `cybertrain/application.rb` (D4's warning in the boot's apply stage); `cybertrain/roles/server.rb`, `roles/worker.rb`, `roles/feeds.rb` (D11's `drain_reports(2.0)` after the services stopped); check that the bundle's `gen/tests.rb` loads `gen/app.rb` (else `cybertrain/generator/tests_emitter.rb` requires the sender too)
- Test: `test/sentry.rb` (new, compiled: `require "cybertrain"`, `cybertrain/error_reporter/sentry`, `cybertrain/test/sentry_receiver`), `test/application.rb` (grown: the warning, in a program without the sender), the generator snapshots that print gen/app.rb

**Interfaces:**
- Consumes: Task 4's `SentryDsn` and settings, Task 7's `Sender` and `drain_reports`.
- Produces: `Test::SentryReceiver` for Task 11 and applications.

- [ ] **Step 1: Write the failing tests**

```ruby
setup: receiver = Cybertrain::Test::SentryReceiver.new; receiver.start
       Cybertrain.config.sentry_dsn = receiver.dsn("42"); Cybertrain.config.http_allow_private = true
       Cybertrain.config.release = "abc123"
test "one envelope per event, with Sentry's auth header" do
  freeze_time at Time.utc(2026, 11, 11, 12); report "boom" (RuntimeError) inside a Scope ("r-1", "GET", "/things/boom", "ThingsController#boom")
    with context { "order_id" => 7 }, handled false (report_unhandled)
  env = receiver.received_events(1)[0]
  assert_equal "/api/42/envelope/", env.sentry_path
  assert_equal "Sentry sentry_version=7, sentry_key=public, sentry_client=cybertrain/#{Cybertrain::VERSION}", env.sentry_auth
  assert_equal "application/x-sentry-envelope", env.sentry_content_type
  assert_match(/\A\h{32}\z/, env.sentry_field("event_id"))
  assert_equal env.sentry_field("event_id"), env.sentry_header_field("event_id")
  { "timestamp" => "2026-11-11T12:00:00.000Z", "platform" => "ruby", "level" => "error", "environment" => "test",
    "release" => "abc123", "transaction" => "ThingsController#boom", "exception.values.0.type" => "RuntimeError",
    "exception.values.0.value" => "boom", "exception.values.0.mechanism.handled" => "false", "tags.request_id" => "r-1",
    "request.method" => "GET", "request.url" => "/things/boom", "extra.order_id" => "7" }.each { |k, v| assert_equal v, env.sentry_field(k) }
end
test "a DSN with a path prefix" do
  Cybertrain.config.sentry_dsn = receiver.dsn("7", "/sentry"); report "x"
  assert_equal "/sentry/api/7/envelope/", receiver.received_events(1)[0].sentry_path
end
test "the sample rate thins what is sent, never what subscribers see" do
  assert Cybertrain::ErrorReporter::SentrySender.sampled?(0.25, 0.24)
  refute Cybertrain::ErrorReporter::SentrySender.sampled?(0.25, 0.25)
  refute Cybertrain::ErrorReporter::SentrySender.sampled?(0.0, 0.0)
  assert Cybertrain::ErrorReporter::SentrySender.sampled?(1.0, 0.999)
  Cybertrain.config.error_sample_rate = 0.0; report "unsent" with a Collect subscriber
  Cybertrain.error.drain_reports(2.0)
  assert_equal 0, receiver.received_count; assert_equal 1, EVENTS.size
end
test "frames, oldest first, when the build has a backtrace" do
  assert_equal %([{"filename":"x.rb","lineno":1,"function":"<main>"},{"filename":"app/models/a.rb","lineno":3,"function":"A#b"}]),
               Cybertrain::ErrorReporter::SentrySender.frames_json(["app/models/a.rb:3:in 'A#b'", "x.rb:1:in `<main>'"])
  assert_equal %([{"filename":"weird"}]), Cybertrain::ErrorReporter::SentrySender.frames_json(["weird"])
  # a reported exception: stacktrace present iff e.backtrace is non-empty (empty in a release build, rule 107)
end
test "a refusing, a rate-limiting and a silent Sentry never block or raise" do   # Review Focus 5
  # a DSN on a closed port: report returns at once; drain; one "WARN error report not sent: ...RefusedError..." line
  # a receiver answering 429: "WARN error report not sent: Sentry answered 429"
  # a receiver that accepts and never answers: the delivery ends within the 5 s deadline (Clock.monotonic), the next
  #   event reaches a working receiver
  # http_allow_private false with a 127.0.0.1 DSN: "...BlockedAddressError..." and nothing raised
end
test "drain_reports gives up after its seconds" do
  # a silent receiver: drain_reports(2.0) answers false after 2 to 3 s
end
```

test/application.rb: "a DSN without the sender linked warns at boot" → booting with `sentry_dsn = "https://k@h/1"` logs `WARN CYBERTRAIN_SENTRY_DSN is set, but this program does not link the Sentry sender (require "cybertrain/error_reporter/sentry")`.

- [ ] **Step 2: Run** `spin test test/sentry.rb test/application.rb`: FAIL.
- [ ] **Step 3: Implement**; regenerate every fixture's gen/app.rb and `examples/blog/gen/app.rb`; `spin run gen -- --check` in each.
- [ ] **Step 4: Run** them (PASS) plus `spin test test/gen_app.rb test/gen_namespaced.rb test/main_roles.rb` (and whatever compiles a fixture's gen/app.rb), `script/test-command-e2e`, `script/generators-e2e`, then `script/test-shard 0 1`.
- [ ] **Step 5: Gate and commit**: "A Sentry-protocol sender behind CYBERTRAIN_SENTRY_DSN, sampled, bounded and never retried; Test::SentryReceiver; each role's stop waits up to 2 s for the reports".

---

### Task 11: The blog: request ids in its log, its errors reported (acceptance 13)

**Files:**
- Modify: `examples/blog/app/jobs/notify_comment_job.rb` (`comment = Comment.find(comment_id)` before logging, so a deleted comment fails the job: `retry_on` then reports it), `examples/blog/config/app.rb` (a comment on `log_tags` and the DSN beside the `log_level` line), `examples/blog/README.md` (a "Logs and error reports" section: the line, `X-Request-Id`, `CYBERTRAIN_LOG_FORMAT=json`, `CYBERTRAIN_SENTRY_DSN` in `config/deploy.yml`'s secrets), `examples/blog/gen/**` (regenerated)
- Create: `examples/blog/test/integration/logging_test.rb`, `examples/blog/test/integration/error_reporting_test.rb`
- Test: the blog's suite

**Interfaces:**
- Consumes: Tasks 5, 6, 9, 10 and 5a's IntegrationTest, fixtures, `perform_enqueued_jobs`.

- [ ] **Step 1: Write the failing tests**

```ruby
class LoggingTest < ActionDispatch::IntegrationTest
  test "a comment's request id is in its own lines and in the job it enqueued" do
    log = StringIO.new
    with_logger(log) do                                     # swaps Cybertrain.logger for Cybertrain::Logger.new(log), restores it
      post article_comments_path(articles(:one)), params: { comment: { commenter: "Ann", body: "Hi" } }
      rid = response.header("X-Request-Id")
      assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, rid)
      assert_includes log.string, " INFO [#{rid}] Started POST \"/articles/#{articles(:one).id}/comments\""
      perform_enqueued_jobs
      assert_match(/ INFO \[NotifyCommentJob \d+\] \[#{rid}\] new comment \d+ on article #{articles(:one).id}\n/, log.string)
    end
  end
end
class ErrorReportingTest < ActionDispatch::IntegrationTest
  setup do
    @receiver = Cybertrain::Test::SentryReceiver.new
    @receiver.start
    @saved = [Cybertrain.config.sentry_dsn, Cybertrain.config.http_allow_private]
    Cybertrain.config.sentry_dsn = @receiver.dsn("1")
    Cybertrain.config.http_allow_private = true
  end
  teardown do
    Cybertrain.config.sentry_dsn, Cybertrain.config.http_allow_private = @saved
  end
  test "an article page that fails is reported" do
    hide_table("comments") do                                # ALTER TABLE comments RENAME TO comments_hidden; back in ensure
      assert_raises(Cybertrain::DB::Error) { get article_path(articles(:one)) }
    end
    ev = @receiver.received_events(1)[0]
    assert_equal ["ArticlesController#show", "Cybertrain::DB::Error", "GET", "/articles/#{articles(:one).id}"],
                 ["transaction", "exception.values.0.type", "request.method", "request.url"].map { |k| ev.sentry_field(k) }
  end
  test "a failing job is reported with its attempt" do
    NotifyCommentJob.perform_later("comment_id" => 999_999, "article_id" => articles(:one).id)
    perform_enqueued_jobs                                    # the block-less form: a failed attempt does not fail the test
    ev = @receiver.received_events(1)[0]
    assert_equal ["NotifyCommentJob", "Cybertrain::RecordNotFound", "1", "3"],
                 ["transaction", "exception.values.0.type", "extra.job.attempt", "extra.job.max_attempts"].map { |k| ev.sentry_field(k) }
  end
end
```

(`extra.job.attempt` addresses the key `"job.attempt"`: `sentry_field` tries the longest key first at each level.)

- [ ] **Step 2: Run** `cd examples/blog && spin run gen && cybertrain test test/integration`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cybertrain test` (every blog test passes), `spin run gen -- --check`, root `ruby script/gate`.
- [ ] **Step 5: Commit**: "blog: request ids in its log and in the jobs a request enqueues; its failing pages and jobs reported to a Sentry receiver".

---

### Task 12: Documents — design.md D85 and D86, the guides and translations, spec §21 "Part 5b" (§15, acceptance 14)

**Files:**
- Modify: `docs/design.md` (D85 "The log line, tags and the request id (2026-11-1x, phase 5b)": the line and JSON, the Scope in one thread slot, the Clock pushing to the Logger and why (the HTTP layer), RequestId outermost and idempotent, the recorded job request id, spike items 7 and 9; D86 "Error reporting and the Sentry sender (2026-11-1x, phase 5b)": the API, the sites (D7, D10), the event of Strings and why (rules 46, 47, 53, 54), the queue, dedupe, sampling, the sender linked through gen/app.rb, backtraces per rule 107, rejected alternatives (a synchronous subscriber call as Rails does, `JSON.generate` for log lines, the HTTP layer reporting); each dated with "why" and the Spinel constraint; D14's logging bullet amended; D32 (`Test::SentryReceiver`); section 8 keeps "error pages with stack traces" out; section 13's dated entry with the new test programs and rules; D1's programme paragraph records phase 5 as delivered), `docs/guide/background-and-operations.md` (new sections "Logs" (the line, levels, `CYBERTRAIN_LOG_LEVEL`, JSON lines, `tagged`, tags of jobs, feeds and tasks, the request id and trusted proxies) and "Error reporting" (`report`, `handle`, `subscribe` and the event's readers, what is reported automatically, what is never sent, the queue and dedupe, `CYBERTRAIN_SENTRY_DSN`, `CYBERTRAIN_RELEASE`, `CYBERTRAIN_ERROR_SAMPLE_RATE`, GlitchTip, backtraces only in `--debug` builds), and the upgrade notes of §18 and D15), `docs/guide/configuration.md` (§14's 5b rows), `docs/guide/requests.md` (`request.request_id`, `X-Request-Id`), `docs/guide/testing.md` (`Test::SentryReceiver`, asserting log lines, the DSN ignored by `cybertrain test`), every guide that shows a `[INFO]` / `[ERROR]` / `[WARN]` line (authentication, external-services, realtime, tutorial), `docs/deploy.md`, `docs/deploy.en.md`, `docs/deploy-kamal.md` (the reporting variables, `CYBERTRAIN_LOG_FORMAT=json`); each guide change mirrored in `docs/guide/{fr,ja,ru,zh}/` with `script/check-guide-i18n --update-sha <files>`; `README.md` (feature list: log tags and request ids, error reporting to Sentry); `spikes/NOTES.md` and `docs/spinel-feedback.md` cross-checked; the spec's "## 21. Implementation notes" gains "### Part 5b" (the spike's branches, D1–D16 where they go beyond the spec, new rule numbers, the counts from `script/test-shard 0 1` and the blog)
- Test: `ruby script/gate`, `script/api-docs`, `script/check-guide-i18n`, `script/guide-pages`, `script/check-docs-i18n`; `grep -rnE "\[(INFO|ERROR|WARN)\] " docs/guide docs/deploy*.md README.md examples/blog/README.md` prints nothing

- [ ] **Step 1: Write the documents.** **Step 2: Run** the checks, `script/test-shard 0 1`, `script/test-command-e2e`, `script/generators-e2e`, `script/auth-e2e signup invite confirmable upgrade04`, `cd examples/blog && cybertrain test && spin run gen -- --check`; record the counts in §21. **Step 3: Commit**: "Phase 5b documents: design.md D85 and D86, logs and error reporting in the operations guide with translations, configuration, requests, testing and deploy pages, README, spec section 21".

---

## Execution order and verification

1 → 2 → {3, 4} → {5, 6, 7, 8} → {9, 10} → 11 → 12. Task 2 needs 1 (item 9); 3 and 4 need 2; 5 needs 3 and 4; 6 needs 3 and 4; 7 needs 3 and 4; 8 needs 4; 9 needs 5, 6 and 7; 10 needs 4 and 7 (and 5's application.rb change landed); 11 needs 9 and 10; 12 needs everything. Every task ends with the Global Constraints' checks; after Task 11, `cd examples/blog && cybertrain test` and `spin run gen -- --check` pass too, which with Task 12 is acceptance item 14.

## Parallel groups

Tasks in one group own disjoint files (listed) and depend on each other only through the interfaces this plan fixes; each runs in its own worktree and the group merges in task order, re-running `script/test-shard 0 1` once on the merged result. Compiles from every worktree take the one build lock, so a group saves editing and review time, not compile time.

| Group | Tasks | Files each owns | Why not wider |
| --- | --- | --- | --- |
| S1 | 1 | `spikes/phase5/thread_scope.rb`, `error_names.rb`, `logger_lock/`; script/check-reserved-names; spec §16; NOTES; spinel-feedback | its verdicts change Tasks 2–10 |
| S2 | 2 | cybertrain/logger.rb, clock.rb, config.rb, config/validation.rb, runtime.rb; the line-shape tests and snapshots; cli/authentication_tests.rb; the blog's two controller tests | touches most test programs' expectations |
| A | 3, 4 | 3: logger.rb, test_help.rb, test/logger_scope.rb, test/test_lifecycle.rb · 4: config.rb, config/validation.rb, sentry_dsn.rb, cybertrain/test/bundle.rb, script/test-command-e2e, test/sentry_dsn.rb, test/config_*.rb | — |
| B | 5, 6, 7, 8 | 5: middleware/request_id.rb, http/request.rb, http/server.rb, dev/error_page.rb, context.rb, controller.rb, application.rb, roles/server.rb, crypto.rb, test/request_id.rb, test/crypto.rb, test/dev_error_page.rb, test/server.rb, test/application.rb · 6: job.rb, job/store.rb, job/executor.rb, scheduler.rb, websocket.rb, test/log_tags_background.rb and the job / scheduler / websocket snapshots · 7: error_reporter.rb, cybertrain.rb, test_help.rb, test/error_reporter.rb · 8: cli/templates.rb, test/cli_new.rb | test_help.rb is Task 7's alone here (Task 3 edited it in group A); if Task 5's landing run touches a job or scheduler snapshot, it hands the change to Task 6 |
| C | 9, 10 | 9: middleware/request_id.rb, middleware/error_pages.rb, job/executor.rb, scheduler.rb, websocket.rb, background.rb, background/supervisor.rb, test/error_reporting_sources.rb, test/error_pages.rb, test/dev_error_page.rb · 10: error_reporter/sentry.rb, test/sentry_receiver.rb, generator/manifest.rb and every regenerated gen/app.rb (examples/blog's included), test_help.rb, application.rb, roles/server.rb, roles/worker.rb, roles/feeds.rb, test/sentry.rb, test/application.rb | Task 10's roles/server.rb edit is in the stop path, Task 5's (group B) in `front_app`: different methods, and B has merged before C starts |
| S3 | 11 | examples/blog/** | needs the merged C |
| S4 | 12 | docs/**, README.md, the spec's §21, NOTES, spinel-feedback | needs everything |

## Self-review

- **Spec coverage.** §12.1 → Task 2 (and spike item 9 in Task 1); §12.2 → Tasks 3 (thread-local), 5; §12.3 → Task 6; §12.4 → Tasks 3 (`tagged`), 4 (`log_tags`), 5 (request tags); §12.5 → Task 2. §13.1 → Task 7 (names per spike item 8); §13.2 → Task 9; §13.3 → Tasks 7 (fields), 9 (absences), 10 (backtrace); §13.4 → Tasks 7 (queue, dedupe, drops), 10 (sender, sampling, shutdown). §14 → Tasks 2 (level, format), 4 (tags, DSN, rate, release), 8 (generators). §15 → Task 12. §16 items 7–9 → Task 1; item 5 → D13. §17 → nothing built (Proc log tags refused by Task 4's validation; `record` / `set_context` absent). §18 → Tasks 2 (line shape), 5 (`X-Request-Id`), 6 (`cybertrain_jobs.request_id`), 12 (the upgrade notes). §20's 5b details → D3, D8, D10, D11, D14 and the tasks' pinned values. Acceptance: 11 → Tasks 2, 3, 5, 6; 12 → Tasks 7, 9, 10; 13 → Task 11; 14 → Task 12.
- **No step that decides nothing:** every value a test pins is the spec's (the line, the JSON keys, the header, the envelope fields, the windows, the queue size, the timeouts) or a decision above (D3's escapes, D8's validation, D9's readers, D10's contexts, the messages of Tasks 2, 4 and 10).
- **Names:** `Logger::Scope` and its `scope_*` readers, `Logger.current_scope` / `swap_scope` / `NO_SCOPE`, `RequestId.scope_for` / `where_for`, `Run#run_request_id`, `ErrorEvent#error_*`, `ErrorReporter#report_unhandled` / `report_message` / `drain_reports` / `reset!`, `Sender#sends?` / `deliver_event`, `SentryDsn.problem` / `parse`, `Test::SentryReceiver#dsn` / `received_events`, `SentryEnvelope#sentry_field` are used with one spelling in every task.
- **Review Focus:** five items, each pinned in the task that owns the code.
- **Proportion:** twelve tasks; the largest (2) is mostly the line-shape updates the format forces, kept in one task so the tree is never half-migrated.

## Decided by the maintainer (2026-11-13)

The plan was approved as written, with the recommendation taken on both open items:

1. **D9, the event's reader names.** Every reader takes the `error_` prefix (`event.error_where`, `event.error_request_id`, …); the Sentry payload keeps Sentry's own keys.
2. **Acceptance 13's "test-only route".** No test-only route: Task 11 makes an existing page fail by renaming the `comments` table for the test's duration (restored in `ensure`), and `NotifyCommentJob` looks its comment up, so a deleted comment fails the job.

The base is `main` at d3b8875 (phase 5a merged as pull request 229); where this plan says "9866af2", read that commit as part of `main`.
