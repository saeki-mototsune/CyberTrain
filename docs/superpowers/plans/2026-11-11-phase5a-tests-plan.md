# Phase 5a (tests) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver part 5a of phase 5: one clock that `travel_to` / `travel` / `freeze_time` move and every framework time follows, Integer durations and calendar-aware time helpers in a configured zone, Rails-shaped test classes (`ActiveSupport::TestCase`, `ActionDispatch::IntegrationTest`, `ViewComponent::TestCase`) with `setup` / `teardown`, a cleared database and YAML fixtures before every test, `cybertrain test` (an application's tests as one binary, filtered at run time), `render_inline` / `assert_select` / broadcast assertions, the remaining assertions, stored mail, inline jobs and receivers stopped after each test; the blog and every generator moved to that shape.

**Architecture:** Rails' vocabulary, the framework's mechanism: `Cybertrain::Clock` is the one seam (module ivars, Integer microseconds), `Time.current` / `Date.current` are class methods added to core classes (rule 87); gen reads `test/**` lexically and writes `gen/test/**` (class-form files rewritten into methods, rule 88), `gen/test/data.rb` (table list, fixture inserts, accessors) and `gen/tests.rb` (the bundle: a generated `case` over every test, rule 1), which `cybertrain test` compiles once and runs with run-time filters; the per-test lifecycle lives in `Cybertrain::Test` (`before_case` / `run_body` / `after_case`), never in generated code.

**Tech Stack:** Ruby compiled by Spinel 2026.11.04.7026 (also run under CRuby 3.3), SQLite via FFI, the `Gen::*` scanners and emitters, phase 4b's YAML subset reader (`Gen::LocaleYaml`), `Cybertrain::TimeZone`, `Test::Client`, the receivers, `Views.render_component` / `render_partial`, `Cybertrain::Stream`, `Cybertrain::Mailer`, `Cybertrain::Job`.

**Spec:** docs/superpowers/specs/2026-11-11-phase5-tests-operations-design.md — Part 5a (sections 2 to 11), the 5a rows of sections 14 and 15, spike items 1 to 6 of section 16, sections 17 and 18 as they touch 5a, acceptance items 1 to 10 of section 19, and section 20. Part 5b (sections 12, 13; acceptance 11 to 14; spike items 7 to 9) is not in this plan. Survey of the code with exact names and lines: the controller's scratchpad `phase5-survey.md` (its facts are restated where a task needs them).

**Depends on phase 4b being merged first** (`I18n`, `Gen::LocaleYaml`, `Cybertrain::Token`, `Cybertrain::MailMessage`, the per-session lifetime in `SessionStore`, the authentication generator with its `Authentication` concern and generated tests, `script/auth-e2e`, NOTES rules 101 to 103); wherever a task names a 4b name, it says "verify against the merged code" and uses the merged spelling.

**Execution notes:** Task 1 first: its results amend spec §16 and Tasks 2 and 4–15 take the branch it records. Every task runs alone in the order given: `cybertrain/test.rb`, `cybertrain/generator/runner.rb`, `script/check-reserved-names` and the e2e fixture application are shared by most of them. Never two Spinel builds in one build directory at once.

## Global Constraints

- **Closer to Rails, then easier to understand** decides every judgement call (spec §0): Rails' names, defaults, file layout and output; compatibility with 0.4 applications carries low weight (§18 lists each break).
- **No computed `send`, `public_send`, `const_get` or `constantize`** (spikes/NOTES.md rule 1): tests are dispatched by a generated `case`, fixtures are generated accessors, `assert_predicate` is not offered.
- **No stored block run through a base-class receiver** (rule 88), no `instance_exec` (rule 2): class-form tests become methods by gen's rewrite; top-level `setup` / `teardown` blocks and every hook take no receiver and are called as plain Procs created in a method (rule 82).
- **One return type per method name across the program** (rules 10, 34, 41): every new clash-prone name has a row in `script/check-reserved-names`' `NAME_HOMES`, seeded in Task 1 (a name the plan did not foresee is added by its task); names ending in `?` or `!` are not checked by the script, so the task's own test compiles them beside their namesakes.
- **Rule 62:** methods named like builtins (`hour`, `min`, `day`, `zone`, ...) on `ZonedTime` and Integer are taken only as spike item 2 allows; every new byte-scanning method (the HTML reader, the selector parser, the CRC-32, the fixture scan) reads its parameter through a fresh local (`s = text.to_s`).
- Other Spinel rules in play: nullable ivars through nil-capable casts, never a nullable `Time` ivar (7); seeded containers (9); threads through a method (21); `rescue JSON::NestingError, JSON::ParserError, StandardError => e` wherever everything is caught (33, 61); a lambda passed positionally (42); compare exception class names, never `is_a?` (46, 47); `ensure` only in a non-re-entrant method (45, 50, 69); a call to a class method nothing defines is a build error (84); a yield's value into a local (90); save-yield-ensure in a module function (101).
- **Never skip, delete or weaken a test** to make a task pass; a snapshot changes only where behaviour changed on purpose.
- **An option or form that is not implemented is refused with a message, never ignored** (`fixtures :articles`, a block given to `render_inline` or `assert_select`, an unknown `cybertrain test` option).
- **Generated files are committed and checked:** whenever an emitter changes, regenerate `gen/**` of `examples/blog`, `test/fixtures/gen_app`, `test/fixtures/gen_namespaced` and `test/fixtures/test_app` (Task 11), and keep a test that `spin run gen -- --check` reports a stale `gen/tests.rb` and `gen/test/**`.
- Every task ends with: `ruby script/gate` green, `ruby script/check-reserved-names` green, `script/api-docs` clean, the task's `spin test test/<x>.rb` programs green (snapshots through `script/regen-snapshot test/<x>.rb` for SQLite/FFI programs, `spin test --regen` for CRuby-runnable ones), `docs/api/stubs/generated_app.rb` mirroring every newly emitted method, and `script/test-shard 0 1` (whole suite) green. From Task 11 on, `script/test-command-e2e` (Task 11 creates it); from Task 17 on, `script/auth-e2e` as the task names.
- Toolchain: `export PATH=/root/.cybertrain/spinel/2026.11.04.7026/lib/spinel:$PATH`; `spin test test/<x>.rb`; `script/regen-snapshot test/<x>.rb`; CRuby: `ruby -I. test/<x>.rb`; blog: `cd examples/blog && spin run gen && cybertrain test && spin run gen -- --check` (`ruby -I../.. ../../exe/cybertrain test` before the gem is installed).
- Commits carry no model identifier in code, comments or commit subjects (CONTRIBUTING.md); the executor adds the trailers. Messages, option names and output lines are the spec's verbatim where it fixes them, else this plan's.

## Decisions

The plan's rulings where the spec leaves a choice the code forces. Each is a fact the tasks build on.

- **D1. Files.** `cybertrain/clock.rb` (`Cybertrain::Clock`, `Time.current`, `Time.zone`, `Date.current`; required by `cybertrain.rb`); `cybertrain/durations.rb` (Integer methods); `cybertrain/time_ext.rb` grows the calendar methods; `cybertrain/zoned_time.rb`; under `cybertrain/test/`: `time_helpers.rb` (the travel helpers, required by `cybertrain/test.rb`), `time_now.rb` (the `Time.now` override, spike item 1), `assertions.rb` (section 10's new assertions, required by `cybertrain/test.rb`), `test_case.rb` (`Test::Base`, `ActiveSupport::TestCase`), `database.rb` (the clear, the fixture load), `bundle.rb` (the bundle's runner and boot), `args.rb` (the run-time arguments, shared with the CLI), `integration.rb`, `html_reader.rb`, `select.rb` (`assert_select`), `broadcasts.rb`, `mail.rb`; `cybertrain/test_help.rb`; `cybertrain/test_files.rb` (which files are tests, shared by gen and the CLI); gen: `cybertrain/generator/crc32.rb`, `fixture_scan.rb`, `test_scan.rb`, `test_data_emitter.rb`, `tests_emitter.rb`; CLI: `cybertrain/cli/test_command.rb`.
- **D2. The zone lives on the Clock.** `Clock.zone -> TimeZone` / `Clock.zone=(zone)` (a module ivar, default `TimeZone.find("UTC")`); `Time.zone` answers it; boot installs `TimeZone.find(c.time_zone)` there, as boot installs `I18n.default_locale` (`Clock` cannot read `Config`).
- **D3. The order contract of one test** (spec §5.3), owned by `Cybertrain::Test` and nothing else:
  1. clear (bundle only), 2. fixtures (bundle only), 3. resets: every `Test.on_reset` hook in registration order (`Mailer.deliveries`, `RateLimit.reset_all!`, `I18n.locale`; 5b adds the log tags here), 4. `setup` (class form: `t.setup`, which calls `super` first; top-level form: the file's `setup do` blocks in declaration order), 5. the body, only if 1–4 raised nothing, 6. `teardown`, always (class form: `t.teardown`, its blocks in reverse, then `super`; top-level form: the file's `teardown do` blocks in reverse declaration order), 7. `Clock.travel_back`, then every `Test.after_this_case` callable (receivers' `stop`) in reverse registration order, then that list is emptied.
  Steps 3–7 run under `spin test` per file too; steps 1–2 only in the bundle (they need gen's table list). A failure at 1, 2, 3 or 4 is `ERR` with the step named; a teardown failure is reported after the body's; a failure at 7 is reported as an `ERR` line of its own step and does not stop the run.
- **D4. Hooks take no receiver.** `Test.on_reset(callable)` (registered once, at require time, by `cybertrain/test_help.rb` and later by 5b) and `Test.after_this_case(callable)` (one-shot, emptied at step 7) store lambdas created inside a method (rule 82) and call them with no argument (rule 2, rule 88).
- **D5. Output.** `spin test` per file keeps today's lines (`ok   name`, `FAIL name: message`, `ERR  name: Class: message`, `<n> tests, <n> assertions, <n> failures`); a multi-line message continues on the following lines. The bundle prints spec §8's shape: the file's path, then `  ok   Class: name` / `  FAIL Class: name (path:line)` / `  ERR  Class: name (path:line)` with each message line indented by 9 spaces (`in setup: RuntimeError: boom` for an ERR, the step first), the top-level form without `Class: `; then an empty line and `<n> test(s), <n> assertion(s), <n> failure(s)` with each word singular for 1 (`1 test, 1 assertion, 0 failures`). ERR counts as a failure.
- **D6. Integration requests** are instance methods of `ActionDispatch::IntegrationTest`: `get(path, params: {}, headers: {})` and `post` / `patch` / `put` / `delete` / `head`, each answering the `Cybertrain::Response` (as `Test::Client#get` does; Rails answers the status), `follow_redirect!`, `response`, `cookies`, `assert_response(expected)`, `assert_redirected_to(path)`. Nested `params:` are flattened to `"article[title]"` keys before `Query.encode`. The top-level `assert_response(response, expected)` and `assert_redirected_to(response, path)` stay. Spike item 3 compiles the two side by side; if they clash, gen rewrites `assert_response X` to `assert_response(response, X)` (and `assert_redirected_to` alike) in a class-form copy, and the class does not define them.
- **D7. The bundle's compile** is the command spike item 3 records (the expectation: `spinel gen/tests.rb $(spin flags) -I test -o build/test/tests`), so a top-level-form file's `require "test_helper"` resolves to the file the bundle already loaded; `CLI::TestCommand.compile_command(root) -> String` holds it.
- **D8. Fixture SQL.** One `INSERT INTO "<table>" (<columns>) VALUES (<literals>)` per row, a String literal with `'` doubled and NUL refused at gen time (`"<path>:<line>: a NUL byte is not allowed"`), `~` / `null` / an empty value as `NULL`, booleans `1` / `0`, datetimes as `Cast.sql_datetime`'s text; a filled `created_at` / `updated_at` is a `?` bound to `Model.now_string` at insert. The clear and the inserts run on one connection inside one `DB.with`: `PRAGMA foreign_keys = OFF`, `BEGIN`, the deletes, `DELETE FROM sqlite_sequence`, the inserts, `COMMIT`, `PRAGMA foreign_keys = ON` (the pragma is a no-op inside a transaction, so it brackets it).
- **D9. Class-level declarations.** `ActiveSupport::TestCase.fixtures(name)` accepts only `:all` and raises `ArgumentError, "fixtures :all is the only form: every fixture is loaded for every test"` otherwise. `Test::Base.test(name)`, `.setup` and `.teardown` (class methods, reached only when a class-form file was not rewritten) raise `ArgumentError, "class-form tests run with `cybertrain test FILE`; `spin test` runs top-level-form files only"` — subject to spike item 3 compiling a class method and an instance method of one name.
- **D10. Lines of top-level-form tests.** gen records, per top-level-form file, the line of each `test "<literal>"`; the runner gives a registered case the line of the literal with its exact name, and a computed name no line (`(path)` alone).
- **D11. `-n` and file arguments.** `-n NAME` keeps a test whose name or method name equals `NAME`; `-n /TEXT/` one whose name or method name contains `TEXT`; a file argument may be `./test/x_test.rb`, an absolute path inside the application, or a directory (every bundled file under it); anything else (an unknown option, a missing `-n` value, a path that is no bundled file) prints `usage: cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]` with the reason and exits 2.
- **D12. Inline jobs.** `perform_enqueued_jobs { }` reads `MAX(id)` of `cybertrain_jobs` before the block and afterwards calls the new `Job.work_one_after(floor) -> Boolean` (claims the lowest queued job with `id > floor`, whatever its `run_at`, and runs it on the calling thread) until it answers false, capped by `Test::Jobs::PERFORM_LIMIT`; it answers the number performed.
- **D13. Stored mail.** With `mail_delivery_method == :test`, `Mailer#deliver` runs today's checks, appends a `Cybertrain::MailMessage` (4b's class: verify its readers against the merged code) to `Mailer.deliveries` and answers `"250 2.0.0 stored in Mailer.deliveries"`. `CYBERTRAIN_MAIL_DELIVERY_METHOD` takes `test` or `smtp`; boot refuses anything else with `"mail_delivery_method must be :smtp or :test (got :letter_opener)"`.
- **D14. Block forms that are not offered** (`render_inline(c) { }`, `assert_select "ul" do`) are refused by gen in every bundled file, naming file and line, with spec §9.2's message (`"assert_select: the nested block form is not supported (selector: \"ul\")"`, `"render_inline: pass the content as content:, not a block"`), since a method that does not yield would otherwise drop the block silently.
- **D15. Re-running `generate authentication` on a 4b application** lists each test file an earlier version wrote that the class-form files replace (`test/authentication.rb`, `test/remember_me.rb`, `test/lockout.rb`, `test/passwords.rb`, `test/accounts.rb`, `test/admin.rb`, `test/confirmations.rb`, `test/support/app_test.rb`, `test/support/authentication_helpers.rb`; verify the list against the merged 4b generator) as `manual  <path>: replaced by <new path>; delete it`; `--force` deletes them.
- **D16. Seams 5b uses.** `Test.on_reset` (log tags), `Clock.now` (the log line's time), `Clock.monotonic` (the request's milliseconds), `Test.after_this_case`, `Test::HttpReceiver` and the integration client's exception path (`Application#call` in test) are left as they are for 5b; nothing in 5a formats a log line or reports an error.
- **D17. NOTES rules** found here take the next free numbers after the merged 4b's (verify the last number), with "Rules by topic" entries.
- **D18. The rewrite keeps every line.** Rather than moving `setup do` bodies into one method (which shifts lines whenever `super` is added), each block becomes a per-class method in place and the combined `setup` / `teardown` are appended to the class line after `;` (Task 9); `super` first and the blocks in order (setup), the blocks in reverse then `super` (teardown), as spec §5.2 requires. Spike item 3 compiles this exact shape.
- **D19. The bundle only ever touches a test database.** `gen/tests.rb` starts with `ENV["CYBERTRAIN_ENV"] = "test"` (assigned, never `||=`: an exported `development` or `production` must not survive) and `ENV.delete("CYBERTRAIN_DATABASE")` (an inherited override names some other environment's file); `CYBERTRAIN_TEST_DATABASE`, when set, becomes the database path instead. `Test::Bundle.boot` then refuses before deleting anything unless `Cybertrain.config.env == "test"` and the path it is about to delete is the test default (`storage/test.sqlite3` under the application) or the value of `CYBERTRAIN_TEST_DATABASE`: `"cybertrain test refuses to delete <path>: not a test database (env <env>)"`, exit status 2, nothing deleted. Task 11's end-to-end script seeds `storage/development.sqlite3` and a file named by an exported `CYBERTRAIN_DATABASE`, runs `CYBERTRAIN_ENV=development CYBERTRAIN_DATABASE=<file> cybertrain test`, and checks both files are byte-identical afterwards.
- **D20. Relative requires in a copy are rebased.** A file copied into `gen/test/` keeps its line numbers (D18), but each `require_relative "<target>"` in it is rewritten on its own line: the target is resolved against the ORIGINAL file's directory; when that target is itself a file gen copies (a rewritten support file or the helper), the require points at the copy, otherwise at the original file, written as a path relative to the copy's directory (`test/test_helper.rb`'s `require_relative "../config/app"` becomes `require_relative "../../config/app"` in `gen/test/test_helper.rb`). A `require_relative` whose argument is not a string literal is refused with file and line. Plain `require "x"` lines are left alone except `require "test_helper"` (D18).

## Review Focus

1. **The clock left frozen after a failure** (a test whose `setup` calls `freeze_time` then raises; a `travel_to` block nested in another whose inner block raises and is rescued by `assert_raises`): the next test runs on real time, and the outer block's instant is back after the inner one. Pinned in Task 6's test "a failing setup after freeze_time leaves the next test on real time" and Task 2's "nested travel_to restores the outer instant after a raise".
2. **Test names that collide or have no ASCII** (`"a b"` and `"a-b"` in one class, `"日本語"` and `"ロシア"` in one class, a name with an apostrophe or double quotes): the colliding pair is refused naming both lines; a non-ASCII name of its own becomes `test_` plus one underscore per character and runs; quotes are kept in the printed name. Pinned in Task 9's test "names that collide after the method-name rule, non-ASCII and quoted names".
3. **Fixture values a YAML writer produces** (`title: It's here`, `title: no`, `title: 123`, `body: "a\nb"`, `published_at: ~`, `title:` with nothing, a label `DEFAULTS`): each inserts as written (`It's here`, `"no"`, `"123"`, a newline, `NULL`, `NULL`) with no SQL breakage, and `DEFAULTS` is an ordinary label. Pinned in Task 8's test "values with quotes, YAML 1.1 words, newlines and nulls insert as written".
4. **HTML the framework's own templates contain** (`>` inside a quoted attribute, `</div>` inside a `<script>` string, `&amp;` in an `href`, `<br/>` and `<input ...>` unclosed, uppercase `<DIV>`, a `<!-- <p> -->` comment, a `<textarea>` holding `<b>`): parsed without a false "mismatched end tag"; the attribute value is decoded; `script` / `style` content is raw; `textarea` content is text. Pinned in Task 13's test "real-world well-formed HTML".
5. **How people name what to run** (`cybertrain test ./test/models/article_test.rb`, an absolute path, `test/models`, a typo `test/modles`, `-n` with no value, `--seed 1`): the first three select the same tests; the others exit 2 with the usage and the reason, without compiling. Pinned in Task 11's test "file, directory and option arguments".

---

### Task 1: The spike (spec §16 items 1–6) and the name homes

**Files:**
- Create: `spikes/phase5/spin.toml` (package `phase5-spike`, `cybertrain = { path = "../.." }`), `spikes/phase5/time_now.rb`, `spikes/phase5/durations.rb`, `spikes/phase5/assert_raises.rb`, `spikes/phase5/backtrace.rb`, `spikes/phase5/class_app/` (a minimal application: `spin.toml`, `config/app.rb`, `config/routes.rb` with `resources :articles`, `db/schema.rb` with `users` and `articles`, `app/models/user.rb` (`has_many :articles`), `app/models/article.rb` (`belongs_to :user`), `app/controllers/articles_controller.rb` (index, show, create), `app/components/card_component.rb`, `test/test_helper.rb`, and `tests.rb`, a hand-written program shaped like Task 10's `gen/tests.rb`), `spikes/phase5/bundle_suite.sh` (item 6) — programs kept as the record, commands and output in each header; not tests
- Modify: `script/check-reserved-names` (rows below; `NAME_CANDIDATES` += `current zone advance now render_inline setup teardown response travel_to travel_back hour day`), spec §16 ("**Results (2026-11-1x, Spinel 2026.11.04.7026, programs kept in spikes/phase5/ …):**" for items 1–6), `spikes/NOTES.md` (D17), `docs/spinel-feedback.md` (a row per limit found; a missing `Time.now` override or backtrace is written up)

**Interfaces:**
- Produces: the verdicts later tasks read — item 1 → Tasks 2, 6 (override or not; nested `travel_to` with `ensure` or the plain-stack fallback); item 2 → Tasks 4, 5 (Integer methods or `Cybertrain::Durations.minutes(5)`; `ZonedTime` readers `hour` or `local_hour`; `1.month` a build or a run-time error); item 3 → Tasks 6, 8, 9, 10, 12, 13 (class form or the top-level fallback; fixture accessor name; nested `params:`; D6's `assert_response`; D7's compile command; D9's class methods); item 4 → Tasks 7, 14, 15 (`assert_raises(Class)`; a method used with and without a block); items 5, 6 → recorded only.
- NAME_HOMES rows (homes are the files the tasks below create; existing definers verified with `grep -rn "def \(self\.\)\?<name>\b" cybertrain`): `now` → `cybertrain/net/socket.rb cybertrain/test/receiver.rb cybertrain/cache.rb cybertrain/flash.rb cybertrain/clock.rb`; `current` → `cybertrain/schema.rb cybertrain/clock.rb`; `zone` → `cybertrain/clock.rb cybertrain/zoned_time.rb`; `advance` → `cybertrain/template/parser.rb cybertrain/time_ext.rb`; `seconds minutes hours days weeks second minute week ago from_now` → `cybertrain/durations.rb`; `hour day` → `cybertrain/durations.rb cybertrain/zoned_time.rb`; `min sec month year wday yday utc_offset to_time to_date` → `cybertrain/zoned_time.rb`; `travel travel_to travel_back freeze_time` → `cybertrain/test/time_helpers.rb cybertrain/clock.rb`; `setup teardown` → `cybertrain/cli/toolchain.rb cybertrain/test.rb cybertrain/test/test_case.rb`; `test` → `cybertrain/test.rb cybertrain/test/test_case.rb`; `fixtures` → `cybertrain/test/test_case.rb`; `render_inline` → `cybertrain/test/views.rb`; `assert_select` → `cybertrain/test/select.rb`; `node_tag node_attr node_text node_html` → `cybertrain/test/html_reader.rb`; `deliveries` → `cybertrain/mailer.rb`; `response` → `cybertrain/test/client.rb cybertrain/context.rb cybertrain/controller.rb cybertrain/test/integration.rb`; `cookies` row += `cybertrain/test/integration.rb`; `assert_response assert_redirected_to` → `cybertrain/test/client.rb cybertrain/test/integration.rb`; `get post patch put delete head` → today's definers plus `cybertrain/test/integration.rb`.

- [ ] **Step 1: Item 1, `time_now.rb`.** With `require "cybertrain"`: `module Cybertrain; module Clock; @micros = 0; @travelling = false; ... end; end` and `class Time; def self.now = Cybertrain::Clock.now; end`; print `Time.now.to_i` before and after setting the clock to 1_000_000_000, from the program and from a framework call that reads `Time.now` (`Cybertrain::Model.now_string` before Task 3 moves it); compare `Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)` with the builtin `Time.now` (within 1 ms) and `Time.at(s, us).utc` round-tripping microseconds; then `travel_to(t1) { travel_to(t2) { raise "x" } rescue nil; print Clock.now }` with the save-yield-ensure form (rule 103), outer instant expected.
- [ ] **Step 2: Item 2, `durations.rb`.** `class Integer; def minutes = self * 60; def hour = self * 3600; def day ...; def ago = ...; end`; `5.minutes == 300`, `2.weeks.ago`, `3.days.from_now`; `Time#beginning_of_day`, `advance(months: 1)`, `months_ago`, `in_time_zone`; a `ZonedTime` with `hour`, `min`, `day`, `wday`, `zone` beside `Time#hour` on boxed receivers (`spinel durations.rb -c -o /tmp/d.c && grep -c 'sp_raise_nomethod(sp_nomethod_msg("hour"' /tmp/d.c`, also `"min"`, `"day"`, `"zone"`, `"advance"` beside `Template::Parser#advance`); `Time.current` and `Date.current` beside `Schema.current`; then a second file with `1.month` (build refusal or run-time `NoMethodError`).
- [ ] **Step 3: Item 3, `class_app/`.** `spin run gen`, then compile `tests.rb` (requires as D7; test classes in D18's rewritten shape; `class ApplicationIntegrationTest < ActionDispatch::IntegrationTest` with `setup` / `teardown` overrides, ivars, a private helper; `ArticlesControllerTest < ApplicationIntegrationTest` with `get article_path(@article)` and `post articles_path, params: { article: { title: "x" } }` beside `Test::Client#get` / `#post` positional; `assert_response :success` beside the top-level two-argument one; a fixture accessor `articles(:one)` as an instance method and a top-level method beside `User#articles`; a class method `self.setup` beside the instance `setup`; a `CardComponentTest < ViewComponent::TestCase` with `render_inline`; the generated `case` calling `before_case` / `run_body { }` / `after_case`); minimal stand-ins of Task 6's classes are written inside the spike. Record the exact compile command that links SQLite.
- [ ] **Step 4: Item 4, `assert_raises.rb`.** `assert_raises(ArgumentError) { }` and `assert_raises(Cybertrain::DB::Error) { }` matched by class name, answering the message; a top-level method called both with a block and without one (`block_given?` in it; the shape of `perform_enqueued_jobs` and `assert_broadcasts`).
- [ ] **Step 5: Item 5, `backtrace.rb`** under `spin build --debug` (or `spinel -g`): does `e.backtrace` answer `file:line:in 'method'` frames; compile time and a `bench/run`-style request rate against a release build.
- [ ] **Step 6: Item 6, `bundle_suite.sh`:** concatenate the framework's 184 programs into one (each file's `Cybertrain::Test.run!` dropped, files wrapped in nothing); count how many compile together, which rule (41, 63, duplicate names) stops the rest, compile time and binary size against D34's 14 minutes.
- [ ] **Step 7: Rows.** Add the NAME_HOMES rows and candidates above; `ruby script/check-reserved-names` green.
- [ ] **Step 8: Amend spec §16** with each item's result and the fallback taken (item 1: override, else no override and the guide's note; plain-stack nesting if `ensure` fails; item 2: methods, else `Cybertrain::Durations.minutes(5)` and `local_hour`; item 3: class form, else the top-level DSL with `setup` / `teardown` and generators writing that form, plus the narrower fallbacks of §16 item 3 and D6; item 4: Class form, else String only; separate block methods `perform_enqueued_jobs_during { }` / `assert_broadcasts_during(stream, n) { }` if a dual-form method fails, gen rewriting Rails' spelling to them); NOTES rules and spinel-feedback rows.
- [ ] **Step 9: Gate and commit**: "Phase 5a spike: Time.now override, methods on Integer and Time, the class-form rewrite, assert_raises with a class, debug backtraces, the bundled framework suite; name homes for the test and time helpers".

---

### Task 2: `Cybertrain::Clock`, `Time.current`, `Date.current` and the travel helpers (§2.1, §2.2, §2.4)

**Files:**
- Create: `cybertrain/clock.rb` (`module Cybertrain::Clock`: `now -> Time` (UTC), `real_now -> Time` (never travelled), `monotonic -> Float` (`CLOCK_MONOTONIC` seconds), `travel_to(time) -> nil` (drops sub-seconds, holds), `travel_back -> nil`, `travelling? -> Boolean`, `travelled_micros -> Integer`; state `@travelling` and `@micros` (Integer, rule 7); real time from `Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)` (item 1's form); `class Time; def self.current = Cybertrain::Clock.now; end`; `class Date; def self.current -> Date` (UTC date of `Clock.now` until Task 4 adds the zone)), `cybertrain/test/time_helpers.rb` (top-level `travel_to(time) { } -> nil`, `travel(seconds) { } -> nil`, `freeze_time { } -> nil`, `travel_back -> nil`: with a block, save `Clock.travelling?` / `travelled_micros`, set, `value = yield`, restore in `ensure` (rule 103; item 1's fallback otherwise); without a block, set and leave), `cybertrain/test/time_now.rb` (only if item 1 passed: `class Time; def self.now = Cybertrain::Clock.now; end`)
- Modify: `cybertrain.rb` (require `cybertrain/clock`), `cybertrain/test.rb` (require `cybertrain/clock` and `cybertrain/test/time_helpers`; `run!` calls `Cybertrain::Clock.travel_back` after each case — Task 6 moves it into step 7)
- Test: `test/clock.rb` (new, CRuby-runnable), `test/time_travel.rb` (new, compiled, requires `cybertrain/test/time_now` when it exists)

**Interfaces:**
- Produces: `Clock.now / real_now / monotonic / travel_to / travel_back / travelling?`, `Time.current`, `Date.current`, the four top-level helpers.

- [ ] **Step 1: Write the failing tests**

```ruby
test "Clock.now is real time until travel_to, then frozen without sub-seconds" do
  gap = (Cybertrain::Clock.now.to_f - Process.clock_gettime(Process::CLOCK_REALTIME)).abs
  assert gap < 0.01
  Cybertrain::Clock.travel_to(Time.utc(2026, 11, 11, 12, 0, 0.75))
  assert_equal Time.utc(2026, 11, 11, 12, 0, 0), Time.current
  assert_equal 0, Time.current.usec
  assert Cybertrain::Clock.travelling?
  Cybertrain::Clock.travel_back
  refute Cybertrain::Clock.travelling?
end
test "travel and freeze_time with and without blocks" do
  travel_to Time.utc(2026, 1, 1) do
    travel 90 do
      assert_equal Time.utc(2026, 1, 1, 0, 1, 30), Time.current
    end
    assert_equal Time.utc(2026, 1, 1), Time.current
    freeze_time
    assert_equal Time.utc(2026, 1, 1), Time.current
  end
  refute Cybertrain::Clock.travelling?
end
test "nested travel_to restores the outer instant after a raise" do
  travel_to Time.utc(2026, 1, 1) do
    assert_raises("RuntimeError") { travel_to(Time.utc(2030, 1, 1)) { raise "inner" } }
    assert_equal Time.utc(2026, 1, 1), Time.current
  end
end
test "a travel without a block lasts to the end of its test" do
  travel_to Time.utc(2026, 1, 1)
  assert_equal Time.utc(2026, 1, 1), Time.current
end
test "the clock is real again in the next test" do
  refute Cybertrain::Clock.travelling?
end
test "Date.current follows the clock" do
  travel_to(Time.utc(2026, 2, 28, 23, 59, 59)) { assert_equal Date.new(2026, 2, 28), Date.current }
end
test "Time.now follows a travel when the override is loaded" do   # test/time_travel.rb, item 1 passed
  travel_to(Time.utc(2001, 9, 9)) { assert_equal 999_993_600, Time.now.to_i }
end
# item 1 failed instead: travel_to(Time.utc(2001, 9, 9)) { assert Time.now.to_i > 1_700_000_000 }
```

- [ ] **Step 2: Run** `ruby -I. test/clock.rb`, `spin test test/clock.rb test/time_travel.rb`: FAIL (`uninitialized constant Cybertrain::Clock`).
- [ ] **Step 3: Implement** as in Files; `real_now` and `now` never call `Time.now`.
- [ ] **Step 4: Run** both (PASS), regenerate snapshots, plus `spin test test/harness.rb test/time_zone.rb`.
- [ ] **Step 5: Gate and commit**: "Cybertrain::Clock with Time.current and Date.current; travel_to, travel, freeze_time and travel_back".

---

### Task 3: Every framework time follows the Clock; the five seams go (§2.3, §18 first bullet, acceptance 1)

**Files:**
- Modify: each runtime site of `grep -rn "Time\.now" cybertrain --include=*.rb` outside `cybertrain/cli/` and `cybertrain/generator/` (45 lines today), by kind:
  - **current time → `Clock.now`** (or `Clock.now.to_i`): `model.rb:412` (`now_string`), `cache.rb` (`Cache.now` reads `Clock.now.to_i`; `clock=`, `system_clock`, `@clock` removed), `rate_limit.rb` (`current_time` reads the Clock; `current_time=` removed), `middleware/session_store.rb` (`fixed_now=` and its ivar removed; 4b's lifetime and idle checks included — verify against the merged code), `application.rb` (`status_now` / `status_now=` removed), `background/supervisor.rb` (`system_clock`, `supervisor_clock=` removed; the rows' age from `Clock.now`), `job.rb` (370 label, 417, 537, 582, `enqueue(kind, payload, run_at: Time.current)`, 638; `perform_in`), `job/cli.rb`, `jobs_page.rb` (5), `stream.rb:77`, `stream/poller.rb` (the prune's cut-off), `scheduler.rb` (304, 702), `websocket.rb` (682, 908, 913), `middleware/health_check.rb`, `mailer.rb:768`, `template/helpers.rb:125` (`time_ago_in_words`), `db/cli.rb:59`, `test/jobs.rb` (`perform_enqueued_jobs(now = Time.current)`), 4b's `token.rb` defaults (`now = Clock.now.to_i`; verify the method names against the merged code — the 4b plan says `generate`, the spec `issue`);
  - **waiting or measuring → `Clock.monotonic`**: `middleware/request_logger.rb` (34, 111: milliseconds from two monotonic readings), `http/server.rb` (272, 276), `stream/websocket_server.rb` (all six), `stream/endpoint.rb` (285, 288), `stream/hub.rb` (108, 123), `stream/poller.rb` (the interval between prunes), `test/client.rb` (`MemorySink`'s deadline);
  - **file ages → `Clock.real_now`**: `dev/rebuilder.rb:202`;
  - emitted code: `cybertrain/generator/jobs_emitter.rb:116` (`perform_in`'s `run_at: Time.current + seconds`; regenerate the fixtures' and the blog's `gen/jobs.rb`);
  - `cybertrain/cli/authentication.rb`: generated code reads `Time.current` (lockout, reset expiry, remember-me, `last_active_at`); its generated test's `Cache.clock = -> { 2_000_000_000 }` with the hand-written `ensure` becomes a `travel_to(Time.at(2_000_000_000)) do ... end` block (verify the merged file's text).
- Modify tests that set a removed seam: `test/cache.rb` (`CLOCK = [1000]` → `travel_to(Time.at(1000))` / `travel`), `test/rate_limit.rb`, `test/rate_limit_store.rb`, `test/session.rb` (`fixed_now` → `travel_to`), `test/background.rb`, `test/main_roles.rb`; snapshots regenerated
- Test: `test/clock_sites.rb` (new, compiled with SQLite: `script/regen-snapshot`), `test/clock.rb` (grown)

**Interfaces:**
- Consumes: Task 2's Clock.
- Produces: the framework on one clock; no seam API left.

- [ ] **Step 1: Write the failing tests** (`test/clock_sites.rb`: one database file, a `notes` table with timestamps and its hand-written model as `test/model.rb` writes them, a `NoopJob` declared as `test/job_helpers.rb` declares its jobs, and a booted application whose `/whoami` answers `"signed in"` or `"anonymous"` and whose `/sign_in?days=N` stamps the session with 4b's `stamp_lifetime!(N * 86_400, true)` and, with `&idle=1`, the idle limit — verify the merged names — and whose `/limited` action has `rate_limit to: 3, within: 60` on the memory store; `run_at_of(id)` reads the row):

```ruby
DAY = 86_400
test "model timestamps follow travel_to" do
  travel_to(Time.utc(2026, 11, 1, 9)) { assert_equal Time.utc(2026, 11, 1, 9), Note.create(title: "x").created_at }
end
test "a cache entry expires after travel" do
  freeze_time
  Cybertrain::Cache.write("k", "v", expires_in: 300)
  travel 299; assert_equal "v", Cybertrain::Cache.read("k")
  travel 2;   assert_nil Cybertrain::Cache.read("k")
end
test "a job's run_at and perform_in follow the clock" do
  travel_to(Time.at(1_000_000)) do
    assert_equal 1_000_000, run_at_of(Cybertrain::Job.enqueue("noop", "{}"))
    assert_equal 1_000_060, run_at_of(NoopJob.perform_in(60))
  end
end
test "a rate-limit window follows the clock" do
  travel_to(Time.at(5_000)) { assert_equal 5_000, Cybertrain::RateLimit.current_time }
  # and through a controller with `rate_limit to: 3, within: 60`: the 4th request at t is 429, a request at t + 61 is 200
  freeze_time
  3.times { client.get("/limited") }
  assert_equal 429, client.get("/limited").status
  travel 61
  assert_equal 200, client.get("/limited").status
end
test "a session's absolute limit follows travel_to" do
  freeze_time
  client.get("/sign_in?days=14")
  travel 13 * DAY; assert_equal "signed in", client.get("/whoami").body
  travel 2 * DAY;  assert_equal "anonymous", client.get("/whoami").body
end
test "a session's idle limit follows travel_to" do
  freeze_time
  client.get("/sign_in?days=30&idle=1")
  travel 8 * DAY; assert_equal "anonymous", client.get("/whoami").body
end
test "a signed token expires with the clock" do
  freeze_time
  token = Cybertrain::Token.issue("reset", 7, 900, "digest")            # merged 4b name and arguments
  travel 899; assert Cybertrain::Token.valid?(token, "reset", "digest")
  travel 2;   refute Cybertrain::Token.valid?(token, "reset", "digest")
end
test "a stream read and a receiver wait do not hang under freeze_time" do
  freeze_time
  started = Cybertrain::Clock.monotonic
  client.get_stream("/cybertrain/stream?s=#{token}", events: 1, timeout: 0.3)
  receiver = Cybertrain::Test::HttpReceiver.new(accept_window: 0.3); receiver.start
  assert_nil receiver.received_requests(1, 0.3)[0]   # no request: the wait ends
  receiver.stop
  assert Cybertrain::Clock.monotonic - started < 3.0
end
test "no runtime or emitted code reads Time.now, and no removed seam is left" do   # in test/clock.rb (CRuby)
  files = Dir.glob("cybertrain/**/*.rb").reject { |f| f.start_with?("cybertrain/cli/") || (f.start_with?("cybertrain/generator/") && !f.end_with?("_emitter.rb")) || f == "cybertrain/test/time_now.rb" }
  hits = files.flat_map { |f| File.readlines(f).each_with_index.select { |l, _| !l.lstrip.start_with?("#") && l.include?("Time.now") }.map { |_, i| "#{f}:#{i + 1}" } }
  assert_equal [], hits
  seams = %w[def\ self.clock= system_clock current_time= fixed_now status_now supervisor_clock]
  assert_equal [], Dir.glob("cybertrain/**/*.rb").select { |f| seams.any? { |w| File.read(f).include?(w) } }
end
```

- [ ] **Step 2: Run** `spin test test/clock_sites.rb`: FAIL.
- [ ] **Step 3: Implement** the sweep; migrate the six tests; `grep -rn "Cache.clock\|system_clock\|current_time =\|fixed_now\|status_now\|supervisor_clock" cybertrain test examples` prints nothing (the guides are Task 19's).
- [ ] **Step 4: Run** `spin test test/clock_sites.rb test/cache.rb test/rate_limit.rb test/rate_limit_store.rb test/session.rb test/background.rb test/main_roles.rb test/job.rb test/scheduler.rb test/stream.rb test/request_logger.rb test/cli_authentication.rb`, then `script/auth-e2e signup` (the generated test's `travel_to`).
- [ ] **Step 5: Gate and commit**: "Every framework time reads Cybertrain::Clock; waits and durations on the monotonic clock; the five clock seams removed".

---

### Task 4: Durations and the calendar methods on Time (§3, acceptance 2)

**Files:**
- Create: `cybertrain/durations.rb` (`class Integer`: `seconds minutes hours days weeks` and `second minute hour day week -> Integer`; `ago -> Time` (`Clock.now - self`), `from_now -> Time`; no `month(s)` / `year(s)`), or item 2's fallback `Cybertrain::Durations.minutes(n)` module functions
- Modify: `cybertrain/clock.rb` (D2: `Clock.zone` / `zone=`; `class Time; def self.zone = Cybertrain::Clock.zone`; `Date.current` in `Time.zone`), `cybertrain/time_ext.rb` (instance methods on `Time`, each answering a UTC `Time`: `beginning_of_day`, `end_of_day` (`.999999`), `beginning_of_week` (Monday) / `end_of_week`, `beginning_of_month` / `end_of_month`, `beginning_of_year` / `end_of_year`, `advance(years: 0, months: 0, weeks: 0, days: 0, hours: 0, minutes: 0, seconds: 0)`, `months_ago(n)`, `months_since(n)`, `years_ago(n)`, `years_since(n)`, `yesterday`, `tomorrow`: wall fields through `Time.zone.utc_to_local`, `TimeZone.epoch_to_civil`, the month clamped with `TimeZone.days_in_month`, back through `TimeZone.civil_to_epoch` and `zone.local_to_utc` (gaps forward, overlaps earlier, as it already documents); hours/minutes/seconds added as elapsed seconds after the calendar part), `cybertrain.rb` (require `cybertrain/durations`)
- Test: `test/time_helpers.rb` (new, CRuby-runnable; needs `/usr/share/zoneinfo`), `test/durations_refused.rb` (new: a program with `1.month`; per item 2, a build refusal checked by a CRuby test that runs `spinel -c` and greps the message, or a compiled run expecting `NoMethodError`)

**Interfaces:**
- Consumes: Task 2's Clock.
- Produces: `Clock.zone`, `Time.zone`, the Integer and Time methods; Task 5 sets the zone from config.

- [ ] **Step 1: Write the failing tests**

```ruby
test "durations are Integer seconds" do
  assert_equal [300, 86_400, 1_209_600, 1, 3_600], [5.minutes, 1.day, 2.weeks, 1.second, 1.hour]
  assert_equal "300", 5.minutes.inspect
  travel_to(Time.utc(2026, 11, 11, 12)) do
    assert_equal Time.utc(2026, 10, 28, 12), 2.weeks.ago
    assert_equal Time.utc(2026, 11, 14, 12), 3.days.from_now
    assert_equal 5.minutes.ago, 300.ago
  end
end
test "advance and months_ago clamp month ends as Rails does" do
  assert_equal Time.utc(2026, 2, 28), Time.utc(2026, 1, 31).advance(months: 1)
  assert_equal Time.utc(2024, 2, 29), Time.utc(2024, 1, 31).advance(months: 1)
  assert_equal Time.utc(2025, 2, 28), Time.utc(2024, 2, 29).advance(years: 1)
  assert_equal Time.utc(2026, 9, 30), Time.utc(2026, 10, 31).months_ago(1)
  assert_equal Time.utc(2027, 1, 31, 1, 2, 3), Time.utc(2026, 12, 31).advance(months: 1, hours: 1, minutes: 2, seconds: 3)
  assert_equal Time.utc(2026, 11, 10), Time.utc(2026, 11, 11).yesterday
end
test "beginning_of_* in UTC" do
  t = Time.utc(2026, 11, 11, 20, 30)            # a Wednesday
  assert_equal Time.utc(2026, 11, 11), t.beginning_of_day
  assert_equal [Time.utc(2026, 11, 11, 23, 59, 59).to_i, 999_999], [t.end_of_day.to_i, t.end_of_day.usec]
  assert_equal Time.utc(2026, 11, 9), t.beginning_of_week
  assert_equal Time.utc(2026, 11, 1), t.beginning_of_month
  assert_equal Time.utc(2026, 1, 1), t.beginning_of_year
end
test "boundaries in Asia/Tokyo" do
  Cybertrain::Clock.zone = Cybertrain::TimeZone.find("Asia/Tokyo")
  assert_equal Time.utc(2026, 11, 11, 15), Time.utc(2026, 11, 11, 20).beginning_of_day
  travel_to(Time.utc(2026, 11, 11, 14, 59, 59)) { assert_equal Date.new(2026, 11, 11), Date.current }
  travel_to(Time.utc(2026, 11, 11, 15))         { assert_equal Date.new(2026, 11, 12), Date.current }
end
test "a DST transition in America/New_York" do
  Cybertrain::Clock.zone = Cybertrain::TimeZone.find("America/New_York")
  assert_equal Time.utc(2026, 3, 8, 5), Time.utc(2026, 3, 8, 15).beginning_of_day       # EST midnight
  assert_equal Time.utc(2026, 3, 9, 4), Time.utc(2026, 3, 8, 15).advance(days: 1).beginning_of_day  # EDT midnight
  assert_equal Time.utc(2026, 3, 8, 7, 30), Time.utc(2026, 3, 7, 7, 30).advance(days: 1)  # 02:30 skipped -> 03:30 EDT
  assert_equal Time.utc(2026, 11, 1, 5, 30), Time.utc(2026, 10, 31, 5, 30).advance(days: 1) # 01:30 twice -> the earlier
end
```

(Each test that sets `Clock.zone` puts UTC back at its end.)

- [ ] **Step 2: Run** `ruby -I. test/time_helpers.rb`, `spin test test/time_helpers.rb test/durations_refused.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS) plus `spin test test/time_zone.rb test/template_integration.rb test/router.rb` (the parser's `advance` beside `Time#advance`), `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "Integer durations, ago and from_now; calendar-aware advance, months_ago, beginning_of_* and end_of_* in Time.zone".

---

### Task 5: The configured time zone (§4, §14's first two rows, acceptance 2)

**Files:**
- Create: `cybertrain/zoned_time.rb` (`Cybertrain::ZonedTime.new(epoch, zone)`: readers `year month day hour min sec wday yday utc_offset zone` (the abbreviation) and `to_time -> Time` (UTC), `to_date -> Date`, or item 2's `local_*` names; no arithmetic)
- Modify: `cybertrain/config.rb` (`time_zone` (String, `CYBERTRAIN_TIME_ZONE`, `"UTC"`), `time_zone_error -> String` (`"time_zone \"Mars/Base\" is not a known time zone"`); `scheduler_tz` now an explicit reader answering `time_zone` while `@scheduler_tz` is `""` (env unset and never assigned), with today's check), `cybertrain/application.rb` (`boot` fails on `time_zone_error`, then `Cybertrain::Clock.zone = TimeZone.find(c.time_zone)`), `cybertrain/time_ext.rb` (`in_time_zone(zone = Time.zone) -> ZonedTime`, a String argument looked up with `TimeZone.find`, an unknown name `ArgumentError, "unknown time zone \"X\""`), `cybertrain/template/helpers.rb` (`time_tag_strftime(time, pattern, zone = Time.zone)`: wall fields, `%z` and `%Z` from the zone; `time_tag`'s `datetime` ISO 8601 with the zone's offset (`Z` only for UTC); `time_tag(t, zone: "America/New_York")`), `cybertrain/i18n.rb` (`l(value, options)` takes `zone:`; a `Date` is rendered as is — verify the merged signature), `cybertrain.rb` (require `cybertrain/zoned_time`)
- Test: `test/config_settings.rb`, `test/application.rb`, `test/helpers.rb`, `test/i18n.rb`, `test/scheduler.rb` (grown), `test/zoned_time.rb` (new, CRuby-runnable)

**Interfaces:**
- Consumes: Task 4's `Clock.zone`.
- Produces: `Config#time_zone`, `ZonedTime`, `Time#in_time_zone`, zone-aware `l` / `time_tag`.

- [ ] **Step 1: Write the failing tests** ("time_zone from the environment and its check" → `CYBERTRAIN_TIME_ZONE=Asia/Tokyo` gives `"Asia/Tokyo"`; `"Mars/Base"` stops boot with the message above; "boot installs the zone" → `Time.zone.zone_name == "Asia/Tokyo"`; "scheduler_tz defaults to time_zone" → unset → `"Asia/Tokyo"`, `CYBERTRAIN_SCHEDULER_TZ=UTC` → `"UTC"`, a cron task's `tz:` still wins (a `0 9 * * *` task with `time_zone = "Asia/Tokyo"` is due at `Time.utc(2026, 11, 11, 0)`); "in_time_zone's fields" → `Time.utc(2026, 11, 11, 20).in_time_zone("Asia/Tokyo")` has `[2026, 11, 12, 5, 0, 0]`, `wday == 4`, `yday == 316`, `utc_offset == 32_400`, `zone == "JST"`, `to_time == Time.utc(2026, 11, 11, 20)`, `to_date == Date.new(2026, 11, 12)`; "l and time_tag render in the zone" → with Tokyo, `time_tag(Time.utc(2026, 11, 11, 20))` has `datetime="2026-11-12T05:00:00+09:00"`, `l(t, format: "%H:%M %Z")` == `"05:00 JST"`, `l(t, format: "%H:%M", zone: "America/New_York")` == `"15:00"`, `l(Date.new(2026, 11, 11))` unchanged; with UTC every existing snapshot of `test/helpers.rb` is unchanged).
- [ ] **Step 2: Run** `spin test test/config_settings.rb test/zoned_time.rb test/helpers.rb test/i18n.rb test/scheduler.rb test/application.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS) plus `spin test test/time_zone.rb test/template_integration.rb`.
- [ ] **Step 5: Gate and commit**: "c.time_zone: Time.zone, in_time_zone, l and time_tag in the zone, scheduler_tz follows it".

---

### Task 6: The test lifecycle: `setup` / `teardown`, the order contract, the base classes, `cybertrain/test_help` (§5.1, §5.3, §5.4, §10 receivers, acceptance 3 and 7's receiver item)

**Files:**
- Create: `cybertrain/test/test_case.rb` (`Cybertrain::Test::Base` with empty `setup` / `teardown` instance methods and D9's raising class methods; `module ActiveSupport; class TestCase < Cybertrain::Test::Base` with `def self.fixtures(name)` (D9)), `cybertrain/test_help.rb` (requires `cybertrain/test`, `test/client`, `test/jobs`, `test/views`, `test/receiver`, `test/test_case`, `test/time_now` per item 1; later tasks add theirs; registers the reset hooks: `Cybertrain::RateLimit.reset_all!`, `I18n.locale = I18n.default_locale` (verify the merged API))
- Modify: `cybertrain/test.rb` (D3–D5: `Test.on_reset(callable) -> nil`, `Test.after_this_case(callable) -> nil`, `Test.in_case? -> Boolean`; top-level `setup(&block)` / `teardown(&block)` registering into the current file's lists (under `spin test` the program is one file); `Test.before_case(t) -> Boolean` (steps 3–4 for an instance), `Test.run_body(t) { } -> nil` (step 5, recording ok / FAIL / ERR), `Test.after_case(t) -> nil` (steps 6–7, a plain method with `ensure`), and the same steps for a registered top-level case in `run!`; the header comment loses "There is no setup/teardown and no isolation"), `cybertrain/test/receiver.rb` (`start` calls `Cybertrain::Test.after_this_case(stop_callable)` when `Test.in_case?`; `stop` tolerates a second call)
- Test: `test/test_lifecycle.rb` (new, CRuby-runnable, top-level form), `test/test_classes.rb` (new, compiled: hand-written classes in the rewritten shape driven through `before_case` / `run_body` / `after_case`), `test/receivers.rb` (grown), `test/harness.rb` (snapshot unchanged)

**Interfaces:**
- Consumes: Task 2's `Clock.travel_back`.
- Produces: `Test::Base`, `ActiveSupport::TestCase`, `Test.before_case(t) -> Boolean`, `Test.run_body(t) { }`, `Test.after_case(t)`, `Test.last_status -> String` (`"ok"`, `"FAIL"`, `"ERR"`), `Test.last_message -> String`, `Test.on_reset`, `Test.after_this_case`, `Test.in_case?`, top-level `setup` / `teardown`, `cybertrain/test_help`. Tasks 8 and 10 add steps 1–2 inside `before_case` through `Test.before_each_bundled(callable)` (D3; added by Task 8).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/test_lifecycle.rb (top-level form; ORDER is a constant, rule 64)
ORDER = Array.new(0) { "" }
setup    { ORDER << "setup1" }
setup    { ORDER << "setup2" }
teardown { ORDER << "teardown1" }
teardown { ORDER << "teardown2" }
Cybertrain::Test.on_reset(-> { ORDER << "reset" })
test "top-level setup and teardown wrap every case in order" do
  ORDER << "body"
end
test "a case that travels without a block" do
  ORDER << "body2"; freeze_time
end
test "the order was reset, setup1, setup2, body, teardown2, teardown1 each time, and the clock is real" do
  assert_equal %w[reset setup1 setup2 body teardown2 teardown1 reset setup1 setup2 body2 teardown2 teardown1 reset setup1 setup2],
               ORDER
  refute Cybertrain::Clock.travelling?
end
```

```ruby
# test/test_classes.rb (the shape gen writes; driven by hand)
LOG = Array.new(0) { "" }
class AppBase < ActiveSupport::TestCase
  def setup = (super; LOG << "base setup")
  def teardown = (LOG << "base teardown"; super)
end
class ThingTest < AppBase
  def setup = (super; @thing = "x"; LOG << "setup")
  def teardown = (LOG << "teardown"; super)
  def test_uses_ivar = (LOG << "body #{@thing}"; assert_equal "x", @thing)
  def thing = @thing.to_s
  def test_raises = raise(ArgumentError, "nope")
  private def helper = "h"
end
test "setup and teardown order with an inherited base" do
  t = ThingTest.new
  Cybertrain::Test.run_body(t) { t.test_uses_ivar } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  assert_equal ["base setup", "setup", "body x", "teardown", "base teardown"], LOG
end
test "teardown after an exception; each test gets a new instance" do
  LOG.clear
  t = ThingTest.new
  Cybertrain::Test.run_body(t) { t.test_raises } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  assert_equal ["base setup", "setup", "teardown", "base teardown"], LOG
  assert_equal "ERR", Cybertrain::Test.last_status
  assert_equal "ArgumentError: nope", Cybertrain::Test.last_message
  assert_equal "", ThingTest.new.thing                           # a new instance: setup has not run on it
end
class FailingSetupTest < ActiveSupport::TestCase
  def setup = (super; freeze_time; raise "setup failed")
  def teardown = (LOG << "teardown ran"; super)
  def test_never = LOG << "never"
end
test "a failing setup after freeze_time leaves the next test on real time" do
  LOG.clear
  t = FailingSetupTest.new
  Cybertrain::Test.run_body(t) { t.test_never } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  assert_equal ["teardown ran"], LOG
  assert_equal ["ERR", "in setup: RuntimeError: setup failed"], [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
  refute Cybertrain::Clock.travelling?
end
test "teardown runs after a failed assertion, and a teardown failure is reported after the body's" do
  t = TwiceFailingTest.new          # class TwiceFailingTest < ActiveSupport::TestCase; def teardown = raise("td"); def test_flunks = flunk("body"); end
  Cybertrain::Test.run_body(t) { t.test_flunks } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  assert_equal ["FAIL", "body\nin teardown: RuntimeError: td"], [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
end
test "fixtures accepts :all only" do
  assert_equal "fixtures :all is the only form: every fixture is loaded for every test",
               assert_raises("ArgumentError") { ActiveSupport::TestCase.fixtures(:articles) }
end
OUTSIDE = Cybertrain::Test::HttpReceiver.new(accept_window: 30.0)
OUTSIDE.start                                       # at the top of the file, outside any case
test "a receiver left running by a failing test is stopped; one started outside a case is not" do
  inside = Cybertrain::Test::HttpReceiver.new(accept_window: 30.0)
  t = ThingTest.new
  Cybertrain::Test.run_body(t) { inside.start; flunk "x" } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  refute inside.serving?
  assert OUTSIDE.serving?
  OUTSIDE.stop
end
```

(`Test.last_status -> String` and `Test.last_message -> String` are readers of the case just finished, for these tests and Task 10's runner.)

- [ ] **Step 2: Run** `ruby -I. test/test_lifecycle.rb`, `spin test test/test_lifecycle.rb test/test_classes.rb test/receivers.rb`: FAIL.
- [ ] **Step 3: Implement** D3 exactly; the per-file case list keeps registration order; `before_case` / `run_body` / `after_case` only record `last_status` / `last_message` (an ERR in step 4 as `in setup: <Class>: <message>`, a teardown failure appended on its own line as `in teardown: ...`), and only the runners (`run!`, Task 10's `Bundle.run!`) count failures and print, so a test can drive a case by hand; `run!` prints D5's per-file lines.
- [ ] **Step 4: Run** them (PASS; snapshots reviewed: the ERR line names `in setup`), `spin test test/harness.rb test/harness_gc.rb` (unchanged), `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "Test lifecycle: setup and teardown in both forms, the per-test order, reset hooks, receivers stopped after each test, ActiveSupport::TestCase and cybertrain/test_help".

---

### Task 7: The remaining assertions and Minitest's failure text (§10 table, acceptance 7)

**Files:**
- Create: `cybertrain/test/assertions.rb` (top-level: `assert_in_delta(expected, actual, delta = 0.001)`, `assert_match(matcher, string)`, `assert_no_match`, `assert_not_equal(expected, actual)`, `assert_not_nil(object)`, `assert_not_includes(collection, object)`, `assert_empty(object)`, `assert_not_empty`, `assert_not(object)` (= `refute`), `assert_nothing_raised { }`, `assert_difference(expression, difference = 1) { }`, `assert_no_difference(expression) { }`, `assert_changes(expression, from: nil, to: nil) { }` — lambdas positional (rule 42), the block's value into a local (rule 90), no `ensure`; each counts one assertion)
- Modify: `cybertrain/test.rb` (require it; `assert_equal` fails with `"Expected: #{expected.inspect}\n  Actual: #{actual.inspect}"`; `assert_raises(expected = "")` also takes a Class, matched by `e.class.name == expected.name` (namespaced, rule 46), per item 4), `test/*.rb.expected` that print an `assert_equal` failure on purpose (`test/harness.rb`)
- Test: `test/assertions.rb` (new, CRuby-runnable), `test/harness.rb` (grown)

**Interfaces:**
- Produces: the assertions above; `assert_changes`' `from:` / `to:` compared with `==` and absent when nil is passed (use a sentinel `Test::UNSET = "\u0000unset"` for "not given", since `to: nil` is a valid expectation).

- [ ] **Step 1: Write the failing tests** (each assertion passing once and failing once, the failure caught with `assert_raises("AssertionFailed")` and its message compared):

```ruby
def failure = assert_raises("AssertionFailed") { yield }
test "assert_equal prints Expected and Actual on two lines" do
  assert_equal "Expected: 1\n  Actual: 0", failure { assert_equal 1, 0 }
end
test "assert_in_delta" do
  assert_in_delta 0.1, 0.1004
  assert_equal "Expected |0.1 - 0.2| (0.1) to be <= 0.001", failure { assert_in_delta 0.1, 0.2 }
end
test "assert_match with a String and a Regexp" do
  assert_match "ell", "hello"; assert_match(/h.l/, "hello"); assert_no_match(/z/, "hello")
  assert_equal "Expected /z/ to match \"hello\"", failure { assert_match(/z/, "hello") }
end
test "assert_not_equal, assert_not_nil, assert_not_includes, assert_empty, assert_not_empty" do
  assert_equal "Expected 1 to not be equal to 1", failure { assert_not_equal 1, 1 }
  assert_equal "Expected nil to not be nil", failure { assert_not_nil nil }
  assert_equal "Expected [1, 2] to not include 2", failure { assert_not_includes [1, 2], 2 }
  assert_empty({}); assert_empty ""; assert_not_empty [1]
  assert_equal "Expected [1] to be empty", failure { assert_empty [1] }
end
test "assert_nothing_raised reports the class and message" do
  assert_equal "Expected nothing to be raised, got ArgumentError: bad", failure { assert_nothing_raised { raise ArgumentError, "bad" } }
end
test "assert_difference, assert_no_difference, assert_changes" do
  count = [0]
  assert_difference(-> { count[0] }, 2) { count[0] += 2 }
  assert_no_difference(-> { count[0] }) { nil }
  assert_equal "Expected change of 1, got 0 (from 2 to 2)", failure { assert_difference(-> { count[0] }) { nil } }
  title = ["a"]
  assert_changes(-> { title[0] }, from: "a", to: "b") { title[0] = "b" }
  assert_equal "Expected \"b\" to change", failure { assert_changes(-> { title[0] }) { nil } }
  assert_equal "Expected change to \"c\", got \"b\"", failure { assert_changes(-> { title[0] }, to: "c") { title[0] = "b" } }
end
test "assert_raises with a class answers the message" do        # per item 4
  assert_equal "x", assert_raises(ArgumentError) { raise ArgumentError, "x" }
  assert_equal "Expected ArgumentError to be raised, got RuntimeError: y", failure { assert_raises(ArgumentError) { raise "y" } }
  assert_equal "z", assert_raises(Cybertrain::Test::AssertionFailed) { flunk "z" }
end
```

- [ ] **Step 2: Run** `ruby -I. test/assertions.rb`, `spin test test/assertions.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them plus `spin test test/harness.rb`; `script/test-shard 0 1` (every passing snapshot unchanged, spec §18's last bullet).
- [ ] **Step 5: Gate and commit**: "Assertions: in_delta, match, not_equal, not_nil, not_includes, empty, nothing_raised, difference and changes; Minitest's Expected/Actual; assert_raises with a class".

---

### Task 8: Database isolation and fixtures (§6, §7, acceptance 4)

**Files:**
- Create: `cybertrain/generator/crc32.rb` (`Gen::Crc32.crc32(text) -> Integer`, the reflected 0xEDB88320 table built once, bytes through a fresh local (rule 62); `Gen::Crc32.fixture_id(label) -> Integer` = `crc32(label) % (2**30 - 1)`), `cybertrain/generator/fixture_scan.rb` (`Gen::FixtureRow` (`row_table`, `row_label`, `row_id`, `row_columns`, `row_values` (SQL literals), `row_line`, `row_timestamps` (the filled timestamp columns)); `Gen::FixtureScan.scan(root, schema, model_infos) -> Array<FixtureRow>`: `test/fixtures/*.yml` sorted; refusals as `ArgumentError` `"<path>:<line>: ..."`: `"ERB is not supported in fixtures (there is no eval); set the value in setup or use travel_to"` for `<%` anywhere, `"no table named \"widgets\" in db/schema.rb"`, `"articles has no column or belongs_to named \"titel\""`, `"articles: labels \"one\" and \"uno\" (line 7) have the same id 980190962"`, `"fixtures hold one level of columns under each label"`, the YAML subset's own refusals), `cybertrain/generator/test_data_emitter.rb` (`TestDataEmitter.emit(schema, rows) -> String`: `gen/test/data.rb` with `Gen::TestData::TABLES` (the schema's tables), `FIXTURE_SQL` (D8), `FIXTURE_TIMESTAMPS` (binds per statement), per fixture set `LABELS_<set>` / `IDS_<set>`; `module Gen::TestFixtures` with module functions `articles(label) -> Article` = `Article.find(Cybertrain::Test.fixture_id("articles", label, LABELS_articles, IDS_articles))`; `class ActiveSupport::TestCase` reopened with one-line instance forwarders and the same top-level forwarders, per item 3's accessor name), `cybertrain/test/database.rb` (`Test::Database::FRAMEWORK_TABLES` = the six `cybertrain_*` tables of §6; `Test::Database.clear!(tables) -> nil`; `Test::Database.load_fixtures!(sql, timestamp_counts) -> nil`; `Test.fixture_id(set, label, labels, ids) -> Integer` raising `Cybertrain::Test::FixtureNotFound, "No fixture named 'three' found for fixture set 'articles'"`; `Test.before_each_bundled(callable)` (steps 1–2 of D3, registered by the bundle))
- Modify: `cybertrain/generator/locale_yaml.rb` (verify the merged API: an entry point that does not demand a locale as the top-level key — `LocaleYaml.parse(text, path, locale_root = true)` — and records whether a scalar was null (`entry_null`), unless it already does), `cybertrain/generator/runner.rb` (when `test/fixtures/` or `test/` exists: `["gen/test/data.rb", ...]` from the schema branch, which holds the schema and the model scan; removed when `test/` is gone), `cybertrain/generator.rb` (requires), `cybertrain/test_help.rb` (requires `test/database`), `docs/api/stubs/generated_app.rb` (`Gen::TestFixtures`)
- Test: `test/gen_fixtures.rb` (new, CRuby-runnable: fixtures in a temp dir beside `test/fixtures/gen_app`'s schema), `test/test_database.rb` (new, compiled with SQLite: a generated `data.rb` loaded into a program), `test/fixtures/gen_app/` (gets `test/fixtures/articles.yml` and its regenerated `gen/test/data.rb`)

**Interfaces:**
- Consumes: 4b's `LocaleYaml`; Task 6's `before_case`.
- Produces: `gen/test/data.rb`'s constants and accessors; `Test::Database.clear!` / `load_fixtures!`; `Test.before_each_bundled`; `FixtureNotFound`. Task 10's `gen/tests.rb` registers `-> { Test::Database.clear!(Gen::TestData::TABLES); Test::Database.load_fixtures!(...) }` through `before_each_bundled`.

- [ ] **Step 1: Write the failing tests** (gen side; `scan(files)` writes the files into a temp copy of `test/fixtures/gen_app` under `test/fixtures/` and answers `FixtureScan.scan`, `emitted(files)` answers `TestDataEmitter.emit`'s text, `refusal(files)` the `ArgumentError` message or `""`):

```ruby
test "ids are Rails' for the same labels" do
  assert_equal [980_190_962, 298_486_374, 663_665_735], %w[one two alice].map { |l| Cybertrain::Gen::Crc32.fixture_id(l) }
  assert_equal 0xCBF43926, Cybertrain::Gen::Crc32.crc32("123456789")
end
test "labels, id:, belongs_to by label, every column type, filled timestamps" do
  rows = scan("users.yml" => "alice:\n  email_address: alice@example.com\n  admin: true\n",
              "articles.yml" => "one:\n  title: First\n  author: alice\n  created_at: 2026-11-01 09:00:00\n  rating: 4.5\n  count: 3\n  data: '{\"a\":1}'\n  published_on: 2026-11-01\ntwo:\n  id: 42\n  title: Second\n  author: alice\n")
  one = rows.find { |r| r.row_label == "one" }
  assert_equal 980_190_962, one.row_id
  assert_includes one.row_columns, "author_id"; assert_includes one.row_values, "663665735"
  assert_equal ["updated_at"], one.row_timestamps
  assert_equal 42, rows.find { |r| r.row_label == "two" }.row_id
  assert_includes rows.find { |r| r.row_label == "alice" }.row_values, "1"
end
test "values with quotes, YAML 1.1 words, newlines and nulls insert as written" do
  sql = emitted("articles.yml" => "a:\n  title: It's here\nb:\n  title: no\nc:\n  title: 123\nd:\n  body: \"x\\ny\"\ne:\n  published_on: ~\nf:\n  title:\nDEFAULTS:\n  title: d\n")
  assert_includes sql, "'It''s here'"; assert_includes sql, "'no'"; assert_includes sql, "'123'"
  assert_includes sql, "'x\ny'"; assert_includes sql, "NULL"
end
test "the refusals name file and line" do
  assert_equal "test/fixtures/articles.yml:2: ERB is not supported in fixtures (there is no eval); set the value in setup or use travel_to",
               refusal("articles.yml" => "one:\n  title: <%= 1 %>\n")
  assert_equal "test/fixtures/widgets.yml:1: no table named \"widgets\" in db/schema.rb", refusal("widgets.yml" => "a:\n  x: 1\n")
  assert_equal "test/fixtures/articles.yml:2: articles has no column or belongs_to named \"titel\"", refusal("articles.yml" => "one:\n  titel: x\n")
  assert_equal "test/fixtures/articles.yml:4: articles: labels \"a\" and \"b\" (line 1) have the same id 5",
               refusal("articles.yml" => "a:\n  id: 5\n  title: x\nb:\n  id: 5\n  title: y\n")
  assert_equal "test/fixtures/articles.yml:3: fixtures hold one level of columns under each label",
               refusal("articles.yml" => "one:\n  title:\n    x: y\n")
  assert_equal "test/fixtures/articles.yml:2: anchors and aliases are not supported", refusal("articles.yml" => "one:\n  title: &t x\n")
end
test "gen writes gen/test/data.rb and --check reports it stale" do
  root = app_copy("articles.yml" => "one:\n  title: x\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert_includes File.read("#{root}/gen/test/data.rb"), "LABELS_articles = [\"one\"]"
  File.write("#{root}/test/fixtures/articles.yml", "one:\n  title: y\n")
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
end
```

(runtime side, `test/test_database.rb`: requires `test/fixtures/gen_app/gen/test/data.rb`, generated from its `articles.yml` (`one` with `created_at: 2026-11-01 09:00:00`, `two` with `id: 42`), on a migrated database file; `count_rows(table)` is a `SELECT COUNT(*)` through `DB.with`):

```ruby
def clear_and_load = (Cybertrain::Test::Database.clear!(Gen::TestData::TABLES); Cybertrain::Test::Database.load_fixtures!(Gen::TestData::FIXTURE_SQL, Gen::TestData::FIXTURE_TIMESTAMPS))
test "the clear empties application and framework tables and resets ids" do
  Article.create(title: "extra", body: "long enough body"); Cybertrain::Cache.write("k", "v")
  Cybertrain::Job.enqueue("noop", "{}"); Cybertrain::Stream.broadcast_append_to("s", target: "t", html: "x")
  Cybertrain::Test::Database.clear!(Gen::TestData::TABLES)
  assert_equal 0, Article.count
  %w[cybertrain_jobs cybertrain_cache cybertrain_messages].each { |t| assert_equal 0, count_rows(t) }
  assert_equal 1, Article.create(title: "first", body: "long enough body").id
end
test "fixtures load with foreign keys off and timestamps from the Clock" do
  travel_to(Time.utc(2026, 11, 2)) { clear_and_load }
  assert_equal Time.utc(2026, 11, 2), articles(:one).updated_at
  assert_equal Time.utc(2026, 11, 1, 9), articles(:one).created_at
  assert_equal 42, articles(:two).id
  assert_equal 980_190_962, articles(:one).id
end
test "articles(:missing) raises FixtureNotFound" do
  assert_equal "No fixture named 'missing' found for fixture set 'articles'",
               assert_raises("FixtureNotFound") { articles(:missing) }
end
test "a test's rows are gone after the next clear" do
  Article.create(title: "temp", body: "long enough body"); clear_and_load
  assert_equal 2, Article.count
end
```

- [ ] **Step 2: Run** `ruby -I. test/gen_fixtures.rb`, `spin test test/gen_fixtures.rb test/test_database.rb`: FAIL.
- [ ] **Step 3: Implement**; regenerate `test/fixtures/gen_app/gen/**`.
- [ ] **Step 4: Run** them plus `spin test test/gen_runner_models.rb test/gen_namespaced.rb test/locale_yaml.rb`, `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "Fixtures: test/fixtures/*.yml read by gen with Rails' ids and belongs_to labels into gen/test/data.rb; the database cleared and the fixtures loaded before each bundled test".

---

### Task 9: The class-form rewrite into `gen/test/` (§5.2, acceptance 3)

**Files:**
- Create: `cybertrain/test_files.rb` (`Cybertrain::TestFiles.list(root) -> Array<String>`: `test/**/*_test.rb` and `test/*.rb` except `test/test_helper.rb`, sorted, never under `test/support/` or `test/fixtures/`; no requires, so the CLI and gen share it), `cybertrain/generator/test_scan.rb` (`Gen::TestFile` (`test_path`, `test_form` (`:class` or `:top_level`), `test_classes` (Array<`TestClassInfo`>), `test_lines` (top-level `test "<literal>"` lines, D10), `test_helpers` (top-level `def` / constant names with lines)); `TestClassInfo` (`class_name`, `superclass_name`, `class_line`, `cases` (Array<`TestCaseInfo`: `case_name`, `case_method`, `case_line`>)); `TestScan.scan(root) -> Array<TestFile>`: `TestFiles.list(root)`, plus `test/test_helper.rb` and `test/support/**/*.rb` as support files; a class is class form when its superclass is `ActiveSupport::TestCase`, `ActionDispatch::IntegrationTest`, `ViewComponent::TestCase`, or a class form class of any scanned file; `TestScan.method_name(name) -> String` (`test_` + every character outside `[A-Za-z0-9_]` as `_`); `TestScan.rewrite(file_text, path) -> String`)
- Modify: `cybertrain/generator/runner.rb` (writes `gen/test/<path under test/>` for every file holding a class-form class, support and helper files included; removes stale ones and empty directories, as `gen/concerns/`), `cybertrain/generator/manifest.rb` if `rb_files` needs the directory
- Test: `test/gen_test_rewrite.rb` (new, CRuby-runnable: `assert_equal <<~RUBY` on rewritten text)

**Interfaces:**
- Produces: `TestScan.scan`, `TestScan.method_name`, `TestScan.rewrite`, the copies under `gen/test/`; Task 10 builds the case table from `TestFile`s.
- The rewrite keeps every line where it was (D18): `require "test_helper"` → an empty line; `test "name" do` → `def test_name` (same indentation), its `end` stays; the n-th `setup do` of class `ArticlesControllerTest` → `def setup_articles_controller_test_<n>` and its `end` → `nil; end` (a per-class name and a nil return, so no two classes share a method name of differing return type, rule 34), likewise `teardown do` → `def teardown_articles_controller_test_<n>`; the class line gains, after a `;`, `def setup; super; setup_..._1; setup_..._2; end; def teardown; teardown_..._2; teardown_..._1; super; end` (public, before any `private`); a `test "x" do ... end` on one line becomes `def test_x; ...; end`; a `require_relative "<target>"` is rebased per D20; every other line is copied unchanged.

- [ ] **Step 1: Write the failing tests**

```ruby
test "method names follow Rails' rule" do
  assert_equal "test_shows_an_article", Cybertrain::Gen::TestScan.method_name("shows an article")
  assert_equal "test_a_b_c_", Cybertrain::Gen::TestScan.method_name("a-b.c?")
end
test "a class-form file is rewritten into methods with setup, teardown and lines kept" do
  src = <<~RUBY
    require "test_helper"

    class ArticlesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @article = articles(:one)
      end

      teardown do
        Cybertrain.config.http_allow_private = false
      end

      test "shows an article" do
        get article_path(@article)
      end

      private

      def title_of(article) = article.title.upcase
    end
  RUBY
  out = Cybertrain::Gen::TestScan.rewrite(src, "test/controllers/articles_controller_test.rb")
  lines = out.lines
  assert_equal src.lines.size, lines.size
  assert_equal "  def test_shows_an_article\n", lines[11]
  assert_equal "class ArticlesControllerTest < ActionDispatch::IntegrationTest; def setup; super; setup_articles_controller_test_1; end; " \
               "def teardown; teardown_articles_controller_test_1; super; end\n", lines[2]
  assert_equal ["  def setup_articles_controller_test_1\n", "    @article = articles(:one)\n", "  nil; end\n"], lines[3, 3]
  assert_equal "  def title_of(article) = article.title.upcase\n", lines[17]
  refute out.include?("require \"test_helper\"")
end
test "several setup blocks run in order, teardown blocks in reverse" do
  src = "class T < ActiveSupport::TestCase\n  setup do\n    a\n  end\n  setup do\n    b\n  end\n  teardown do\n    c\n  end\n  teardown do\n    d\n  end\n\n  test \"x\" do\n  end\nend\n"
  out = Cybertrain::Gen::TestScan.rewrite(src, "test/t_test.rb")
  assert_includes out.lines[0], "def setup; super; setup_t_1; setup_t_2; end; def teardown; teardown_t_2; teardown_t_1; super; end"
  assert_equal "  def test_x\n", out.lines[14]
end
def two_tests(a, b) = "class XTest < ActiveSupport::TestCase\n  test #{a.inspect} do\n  end\n\n  test #{b.inspect} do\n  end\nend\n"
def refusal(src) = (begin; Cybertrain::Gen::TestScan.rewrite(src, "test/x_test.rb"); ""; rescue ArgumentError => e; e.message; end)
test "names that collide after the method-name rule, non-ASCII and quoted names" do
  assert_equal "test/x_test.rb:5: test \"a-b\" has the same method name test_a_b as test \"a b\" (line 2)", refusal(two_tests("a b", "a-b"))
  assert_equal "test/x_test.rb:5: test \"ロシア\" has the same method name test____ as test \"日本語\" (line 2)", refusal(two_tests("日本語", "ロシア"))
  assert_equal "test________", Cybertrain::Gen::TestScan.method_name("日本語のテスト")
  assert_equal "test_it_s_here", Cybertrain::Gen::TestScan.method_name("it's here")
  assert_equal "", refusal(two_tests("it's here", "say \"hi\""))
end
test "setup do beside def setup is refused naming both" do
  src = "class ThingTest < ActiveSupport::TestCase\n  setup do\n    a\n  end\n\n\n  def setup\n    super\n  end\nend\n"
  assert_equal "test/x_test.rb:7: ThingTest has both `setup do` (line 2) and `def setup`; use one", refusal(src)
end
test "the form is told apart by content and through an application base class" do
  root = temp_app("test/support/app_integration.rb" => "class ApplicationIntegrationTest < ActionDispatch::IntegrationTest\nend\n",
                  "test/x_test.rb" => "class XTest < ApplicationIntegrationTest\n  test \"a\" do\n  end\nend\n",
                  "test/legacy.rb" => "test \"old\" do\nend\nCybertrain::Test.run!\n")
  forms = Cybertrain::Gen::TestScan.scan(root).map { |f| [f.test_path, f.test_form] }
  assert_includes forms, ["test/x_test.rb", :class]
  assert_includes forms, ["test/legacy.rb", :top_level]
end
test "gen writes gen/test copies, removes stale ones and --check reports them" do
  root = temp_app("test/x_test.rb" => "class XTest < ActiveSupport::TestCase\n  test \"a\" do\n  end\nend\n")
  assert_equal 0, Cybertrain::Gen::Runner.run(root, [])
  assert File.exist?("#{root}/gen/test/x_test.rb")
  File.write("#{root}/test/x_test.rb", File.read("#{root}/test/x_test.rb").sub("\"a\"", "\"b\""))
  assert_equal 1, Cybertrain::Gen::Runner.run(root, ["--check"])
  File.delete("#{root}/test/x_test.rb"); Cybertrain::Gen::Runner.run(root, [])
  refute File.exist?("#{root}/gen/test/x_test.rb")
end
```

(`temp_app(files)` copies `test/fixtures/gen_app` to a temp directory and writes the given files.)

- [ ] **Step 1a: Tests for D20.** In `test/gen_test_scan.rb` (or this task's test file): "a copied helper's relative require is rebased": rewriting `test/test_helper.rb` containing line 2 `require_relative "../config/app"` gives line 2 `require_relative "../../config/app"` in the copy (same line number); "a require of a copied support file points at the copy": `require_relative "support/sign_in"` in the helper, with `test/support/sign_in.rb` copied, gives `require_relative "support/sign_in"` resolving to `gen/test/support/sign_in.rb`, while a support file that is not copied gives `require_relative "../../test/support/plain"`; "a computed require_relative is refused": `require_relative File.join("a", "b")` raises with `test/test_helper.rb:3:`.
- [ ] **Step 2: Run** `ruby -I. test/gen_test_rewrite.rb`, `spin test test/gen_test_rewrite.rb`: FAIL.
- [ ] **Step 3: Implement** with a line scanner that tracks `do` / `end` nesting as `ConcernScan` does (reuse its block-depth helper rather than a second copy).
- [ ] **Step 4: Run** it (PASS) plus `spin test test/gen_concerns.rb test/gen_runner_models.rb`.
- [ ] **Step 5: Gate and commit**: "gen: class-form test files rewritten into methods under gen/test, setup and teardown merged, lines kept, collisions refused".

---

### Task 10: The bundle: `gen/tests.rb` and its runner (§5.2's program, §8 output and filters, acceptance 5)

**Files:**
- Create: `cybertrain/generator/tests_emitter.rb` (`TestsEmitter.emit(root, files) -> String`: `ENV["CYBERTRAIN_ENV"] = "test"` and the `CYBERTRAIN_DATABASE` / `CYBERTRAIN_TEST_DATABASE` lines of D19; `require "cybertrain"`, `"cybertrain/test_help"`; `require_relative "../config/app"`, `"app"`, `"migrations"` (when written), `"test/data"`; `class ActionDispatch::IntegrationTest; include ::Gen::UrlHelpers; end` (Task 12 defines the class: emitted from Task 12 on); `Cybertrain::Test.bundled!`; `test/test_helper.rb` (or its copy), `test/support/**` (or copies), then per test file in path order `Cybertrain::Test.begin_file("<path>", [<D10 names>], [<lines>])` and its `require_relative` (the copy for class form); `module Gen::Tests` with `FILES`, parallel `CASE_FILE`, `CASE_LINE`, `CASE_CLASS`, `CASE_NAME`, `CASE_METHOD` and `def self.run_case(i)` whose arms are spec §5.2's four lines; finally `exit(Cybertrain::Test::Bundle.run!(ARGV, ->(i) { Gen::Tests.run_case(i) }))` after `Cybertrain::Test::Bundle.boot(Gen::Routes.build(Cybertrain::Router.new), Gen::Routes.url_resolver)` and `Cybertrain::Test.before_each_bundled(...)` (Task 8's clear and load)), `cybertrain/test/bundle.rb` (`Test::Bundle.boot(router, url_resolver) -> Application` (D19's refusal first, then BlogTest's boot: delete the database and its `-wal` / `-shm`, migrate `Migration.all`, boot; sets `Test.app`); `Test.app -> Application`; `Test.bundled!`, `Test.bundled? -> Boolean` (`run!` does nothing when true); `Test.begin_file(path, names, lines)`; `Test::Bundle.run!(argv, dispatch) -> Integer` (D5's output, D11's filters through `Test::Args`, exit status 0 or 1, 2 for bad arguments)), `cybertrain/test/args.rb` (`Test::Args.parse(argv, files, root) -> Test::Args` with `arg_files` (Array<String>, empty for all), `arg_name`, `arg_pattern`, `arg_error` ("" when the arguments are good, else D11's reason); `Test::Args::USAGE`; no requires beyond the standard library, so the CLI uses it too)
- Modify: `cybertrain/generator/runner.rb` (writes `gen/tests.rb` when `test/` exists; refuses the bundle with `"test/b_test.rb:3: new_client is also defined at test/a_test.rb:5; move shared helpers to test/support/ or into a test class"` for a top-level `def` or constant defined in two bundled files (support included), and D14's block refusals), `cybertrain/test.rb` (`register` records the current file from `begin_file`)
- Test: `test/gen_tests_bundle.rb` (new, CRuby-runnable: the emitted text and the refusals), `test/test_bundle.rb` (new, compiled: `Test::Bundle.run!` over a hand-written table of two class-form classes and a top-level file, with argv variants)

**Interfaces:**
- Consumes: Task 6's `before_case` / `run_body` / `after_case`; Task 8's data; Task 9's `TestFile`s and copies.
- Produces: `gen/tests.rb`; `Test::Bundle.boot`, `Test::Bundle.run!(argv, dispatch) -> Integer`, `Test.app`, `Test.bundled?`, `Test::Args.parse`.

- [ ] **Step 1: Write the failing tests** ("the emitted program requires in order and has one arm per class-form test" — `assert_includes src, "  when 0\n    t = ArticleTest.new\n    if Cybertrain::Test.before_case(t)\n      Cybertrain::Test.run_body(t) { t.test_title_must_be_present }\n    end\n    Cybertrain::Test.after_case(t)\n"`, `require "test_helper"` absent, `begin_file("test/legacy.rb", ["old style"], [3])` present; "a duplicate top-level helper is refused naming both files" (message above, also for a constant `CLOCK = [1]`); "assert_select with a block and render_inline with a block are refused" (D14's messages with path and line); `test/test_bundle.rb`: "the output has headings, file:line on failures and pluralised totals" →

```text
test/models/article_test.rb
  ok   ArticleTest: title must be present
  FAIL ArticleTest: counts (test/models/article_test.rb:9)
         Expected: 1
           Actual: 0
test/legacy.rb
  ok   old style

3 tests, 3 assertions, 1 failure
```

with exit status 1; "-n exact name, method name and /text/ keep only those tests" (`["-n", "counts"]`, `["-n", "test_counts"]`, `["-n", "/count/"]` → one test each, `"1 test, ..."`); "a file filter and -n combine" (`["test/legacy.rb", "-n", "old style"]` → `1 test, ...`; `["test/legacy.rb", "-n", "counts"]` → `0 tests, ...`); "0 tests is not a failure" (`["-n", "nothing"]` → `0 tests, 0 assertions, 0 failures`, exit 0); "Cybertrain::Test.run! does nothing inside the bundle").
- [ ] **Step 1a: Tests for D19 and D20.** `test/gen_tests_bundle.rb`: "the bundle forces the test environment": the emitted text contains the line `ENV["CYBERTRAIN_ENV"] = "test"` and does not contain `||=`; it contains `ENV.delete("CYBERTRAIN_DATABASE")`. `test/test_bundle.rb`: "boot refuses a database that is not the test one": with the config's env forced to `development` (or its path set to `storage/development.sqlite3`), `Test::Bundle.boot` raises `"cybertrain test refuses to delete storage/development.sqlite3: not a test database (env development)"` and a file created at that path beforehand still exists with the same bytes; "CYBERTRAIN_TEST_DATABASE is honoured": the path it names is the one deleted and migrated. "the generated helper with an application base class loads": a bundle whose `test/test_helper.rb` has `require_relative "../config/app"` and `class ApplicationIntegrationTest < ActionDispatch::IntegrationTest; end` builds a `gen/tests.rb` whose requires all resolve (every `require_relative` target in `gen/test/**` exists on disk).
- [ ] **Step 2: Run** `ruby -I. test/gen_tests_bundle.rb`, `spin test test/gen_tests_bundle.rb test/test_bundle.rb`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS); `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "gen/tests.rb: every test file in one program with a generated case over the tests; the bundle's runner with headings, file and line, filters and exit status".

---

### Task 11: `cybertrain test` and the end-to-end fixture application (§8, acceptance 5)

**Files:**
- Create: `cybertrain/cli/test_command.rb` (`CLI::TestCommand.run(root, argv) -> Integer`: `spin run gen`; `stale?(root, binary) -> Boolean` (any `*.rb` / `*.yml` / `*.erb` under the application (not `build/`, `dist/`, `tmp/`, `storage/`), any `cybertrain/**/*.rb` of the framework root `spin flags` names, or a file `spin flags --deps` lists, newer than `build/test/tests`); `compile_command(root) -> String` (D7); runs `build/test/tests` with argv and returns its status; checks the arguments with `Test::Args.parse(argv, TestFiles.list(root), root)` before compiling and exits 2 with `Test::Args::USAGE` and `arg_error` when it is not ""), `test/fixtures/test_app/` (an application: `spin.toml` with a path dependency the script rewrites, `config/app.rb`, `config/routes.rb`, `db/schema.rb` + one migration (`users`, `articles` with `belongs_to :author`, a boolean, a datetime, a decimal), models, `ArticlesController`, `test/test_helper.rb`, `test/support/helpers.rb`, `test/models/article_test.rb` (class form), `test/legacy.rb` (top-level form with `setup` / `teardown`), `test/fixtures/{users,articles}.yml`, committed `gen/**`), `test/fixtures/test_app_extra/` (`failing_test.rb`; `dup_a.rb` / `dup_b.rb` each defining `new_client`), `test/fixtures/test_app.expected/` (`all.out`, `file.out`, `name.out`, `method.out`, `text.out`, `failing.out`, `duplicate.out`), `script/test-command-e2e` (bash: copy `test_app` to a temp dir, point `spin.toml` at the repository, run `ruby -I$ROOT $ROOT/exe/cybertrain test` with each variant's arguments, compare output with the `.out` file and the exit status (0, 0, 0, 0, 0, 1, 1); check `build/test/tests`' mtime is unchanged between the filter runs (one compile); print the first compile's seconds)
- Modify: `cybertrain/cli.rb` (`when "test" then run_in_app { |_name| TestCommand.run(".", argv[1, argv.size - 1]) }`, usage line `cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]`), `.github/workflows/ci.yml` (step "cybertrain test end to end" running `script/test-command-e2e`)
- Test: `test/cli_test_command.rb` (new, CRuby-runnable: arguments, staleness, the command line)

**Interfaces:**
- Consumes: Task 10's bundle.
- Produces: `cybertrain test`; `script/test-command-e2e` and `test/fixtures/test_app/`, which Tasks 12–15 grow with one test file each (and its `.out` lines).

- [ ] **Step 1: Write the failing tests** ("file, directory and option arguments" → `Test::Args.parse(["./test/models/article_test.rb"], files, root).arg_files`, the same with `"#{root}/test/models/article_test.rb"` and with `["test/models"]` all equal `["test/models/article_test.rb"]`; `arg_error` is `"no test file at test/modles"` for `["test/modles"]`, `"-n needs a name or /text/"` for `["-n"]`, `"unknown option --seed"` for `["--seed", "1"]`; `TestCommand.run(root, ["--seed", "1"])` answers 2, prints `"usage: cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]\nunknown option --seed"` and runs no step (a stub runner records none); "stale? after an edit to a test, a model, a fixture or the framework, not after a run"; "the compile command" equals item 3's recorded command for the temp app). Write `test_app` and the expected outputs from Task 10's format.
- [ ] **Step 1a: The D19 regression in `script/test-command-e2e`.** Before running the tests the script writes known bytes to `storage/development.sqlite3` and to `tmp/other.sqlite3`, runs `CYBERTRAIN_ENV=development CYBERTRAIN_DATABASE=tmp/other.sqlite3 cybertrain test`, and then asserts with `cmp` that both files are unchanged, that the run exits 0, and that `storage/test.sqlite3` exists. The fixture app's `test/test_helper.rb` defines an application base class and requires `../config/app` relatively (D20), and one of its tests inherits from that class.
- [ ] **Step 2: Run** `ruby -I. test/cli_test_command.rb`, `script/test-command-e2e`: FAIL.
- [ ] **Step 3: Implement**; `cd test/fixtures/test_app && spin run gen` to commit its `gen/**`.
- [ ] **Step 4: Run** both (PASS), `spin test test/cli_test_command.rb`, `cd test/fixtures/test_app && spin run gen -- --check`.
- [ ] **Step 5: Gate and commit**: "cybertrain test: one compile for an application's tests, filters at run time; an end-to-end fixture application".

---

### Task 12: `ActionDispatch::IntegrationTest` (§5.1, acceptance 3)

**Files:**
- Create: `cybertrain/test/integration.rb` (`module ActionDispatch; class IntegrationTest < ActiveSupport::TestCase`: `initialize` builds `Test::Client.new(Cybertrain::Test.app)` (raising `"no application booted: IntegrationTest runs in the bundle (cybertrain test)"` when none); D6's methods; `Cybertrain::Test.flatten_params(params) -> Hash{String => String}` (`{ article: { title: "x", tags: { a: "1" } } }` → `"article[title]" => "x"`, `"article[tags][a]" => "1"`; a value that is neither String, Symbol, number, boolean nor Hash raises `ArgumentError, "params: values must be Strings or Hashes (got Array at article[ids])"`); every request sets `Test.last_html` to the body for Task 13)
- Modify: `cybertrain/generator/tests_emitter.rb` (the `include ::Gen::UrlHelpers` reopening), `cybertrain/test_help.rb` (requires it), `test/fixtures/test_app/test/controllers/articles_controller_test.rb` (new: index, show with `articles(:one)`, create with `assert_difference`, follow_redirect!), `test/fixtures/test_app.expected/*.out`
- Test: `test/test_integration.rb` (new, compiled: a small booted application with `resources :articles` (index, show, create, destroy) and `get "/remember"` setting `cookies[:n] = params[:n]`, `Test.app` set by hand)

**Interfaces:**
- Consumes: Task 10's `Test.app`; Task 7's `assert_difference`.
- Produces: `ActionDispatch::IntegrationTest`, `Test.last_html -> String` / `Test.last_html=(html)` (also set by Task 13's `render_inline`), `Test.flatten_params`.

- [ ] **Step 1: Write the failing tests** ("get, post with nested params, patch, delete, head answer the response" → `post "/articles", params: { article: { title: "New", body: "A body long enough" } }` creates the row; `assert_response :redirect`; `assert_redirected_to "/articles/1"`; `follow_redirect!`; `assert_response :success`; `head "/articles"` → 200 with an empty body; "cookies persist across requests in one test and not into the next" (after `get "/remember?n=1"`, whose action sets `cookies[:n] = "1"`, `cookies["n"] == "1"`; `ArticlesTest.new.cookies.empty?`); "path helpers are reachable" (in the e2e app: `get article_path(articles(:one))`); "flatten_params encodes brackets and refuses arrays"; "assert_response with a symbol, an Integer and the wrong status" (failure message `"expected response :success, got 404"` kept from the top-level form)).
- [ ] **Step 2: Run** `spin test test/test_integration.rb`, `script/test-command-e2e`: FAIL.
- [ ] **Step 3: Implement** (or D6's fallback per item 3).
- [ ] **Step 4: Run** both (PASS), `spin test test/test_client.rb test/application.rb`, `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "ActionDispatch::IntegrationTest: get, post and friends with nested params, follow_redirect!, assert_response and assert_redirected_to on the last response".

---

### Task 13: `render_inline`, `ViewComponent::TestCase`, the HTML reader and `assert_select` (§9.1, §9.2, acceptance 6)

**Files:**
- Create: `cybertrain/test/html_reader.rb` (`Test::HtmlNode` (`node_tag`, `node_attr(name) -> String` ("" when absent), `node_text` (descendant text, entities decoded), `node_html`, `node_children`, `node_parent_index`); `Test::HtmlReader.parse(html) -> Array<HtmlNode>` (document order) raising `Test::HtmlReader::Malformed, "mismatched end tag </div> at byte 214 (open: <p>)"` (0-based offset of the `<`); void elements `area base br col embed hr img input link meta source track wbr`; `script` / `style` raw, `textarea` / `title` text; tag and attribute names lower-cased; `&amp; &lt; &gt; &quot; &#39; &#NN; &#xHH;` and the named references the framework writes), `cybertrain/test/select.rb` (`Test::Selector.parse(text) -> Array<compound chains>` raising `"assert_select: <feature> is not supported (selector: \"...\")"` for `:pseudo`, `+`, `~`, `^=` / `*=` / `~=` / `$=` / `|=`; top-level `assert_select(selector, equality = nil, count: nil, minimum: nil, maximum: nil, text: nil) -> Array<HtmlNode>` over `Test.last_html`; failure text: `"Expected exactly 2 elements matching \"li\", found 1.\nHTML (first 500 characters):\n<ul>..."`, `"Expected at least 1 element matching \"h1\" with text \"Hello\", found 0."`)
- Modify: `cybertrain/test/views.rb` (top-level `render_inline(component, content: "") -> String` and `render_inline(partial:, locals: {})` — one method `render_inline(component = nil, content: "", partial: "", locals: {})` per rule 34, setting `Test.last_html`; `module ViewComponent; class TestCase < ActiveSupport::TestCase; end`), `test/fixtures/test_app/` (a `CardComponent` and `test/components/card_component_test.rb`; an `assert_select` in the controller test), `.out` files
- Test: `test/test_html.rb` (new, CRuby-runnable), `test/test_render_inline.rb` (new, compiled: the component and partial fixtures of `test/component_render.rb`)

**Interfaces:**
- Consumes: Task 12's `Test.last_html`.
- Produces: `render_inline`, `assert_select`, `HtmlReader`, `HtmlNode`, `ViewComponent::TestCase`; Task 14's `assert_turbo_stream` uses the reader.

- [ ] **Step 1: Write the failing tests**

```ruby
HTML = %(<div class="card big" id="c1"><h2>Hello <b>you</b></h2><ul><li>a</li><li data-x="1">b</li></ul>) +
       %(<a class="btn" href="/x?a=1&amp;b=2">go</a><form action="/articles"><input name="article[title]"></form></div>)
def html! = Cybertrain::Test.last_html = HTML
test "every selector form" do
  html!
  assert_equal 1, assert_select("h2").size
  assert_select "div.card"; assert_select "#c1"; assert_select "[data-x]"; assert_select "li[data-x=\"1\"]"; assert_select "li[data-x='1']"
  assert_select "a.btn[href=\"/x?a=1&b=2\"]"
  assert_select "ul li", count: 2; assert_select "div > h2"; assert_select "div > li", count: 0
  assert_select "h1, h2", count: 1
  assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
end
test "options and the positional second argument" do
  html!
  assert_select "li", minimum: 1, maximum: 2
  assert_select "h2", text: "Hello you"; assert_select "h2", text: /Hel+o/
  assert_select "h2", "Hello you"; assert_select "li", 2; assert_select "table", false
  assert_equal "Expected exactly 3 elements matching \"li\", found 2.\nHTML (first 500 characters):\n#{HTML[0, 500]}",
               assert_raises("AssertionFailed") { assert_select "li", count: 3 }
end
test "each unsupported form fails with its message" do
  html!
  assert_equal "assert_select: pseudo-classes are not supported (selector: \"li:first-child\")", assert_raises("AssertionFailed") { assert_select "li:first-child" }
  # "h2 + ul" -> sibling combinators; "a[href^=\"/x\"]" -> attribute operators other than =
end
test "real-world well-formed HTML" do
  Cybertrain::Test.last_html = %(<DIV title="a > b"><script>var s = "</div>";</script><br/><input type="text"><!-- <p> --><textarea><b></textarea></DIV>)
  assert_select "div[title=\"a > b\"]"; assert_select "textarea", text: "<b>"; assert_select "p", false
end
test "a malformed document fails with the byte offset" do
  Cybertrain::Test.last_html = "<div><p>x</div>"
  assert_includes assert_raises("AssertionFailed") { assert_select "p" }, "mismatched end tag </div> at byte 9 (open: <p>)"
end
test "render_inline renders a component and a partial and keeps the HTML" do   # test/test_render_inline.rb
  assert_includes render_inline(CardComponent.new(title: "Hello")), "Hello"
  assert_select "div.card > h2", text: "Hello"
  html = render_inline(partial: "articles/form", locals: { article: Article.new })
  assert_select "form[action=\"/articles\"]"; assert_includes html, "Save"
end
```

- [ ] **Step 2: Run** `ruby -I. test/test_html.rb`, `spin test test/test_html.rb test/test_render_inline.rb`, `script/test-command-e2e`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS), `spin test test/component_render.rb test/views_detached.rb`, `ruby script/check-reserved-names`.
- [ ] **Step 5: Gate and commit**: "render_inline and ViewComponent::TestCase; assert_select over a test-only HTML reader with Rails' selector subset and options".

---

### Task 14: Broadcast assertions and `assert_turbo_stream` (§9.3, acceptance 6)

**Files:**
- Create: `cybertrain/test/broadcasts.rb` (top-level `assert_broadcasts(stream, count) { } -> Array<String>` (payloads), `assert_no_broadcasts(stream) { } -> nil`, `assert_turbo_stream(action:, target:) -> nil`; `stream` a String or a record through `Stream.name_for`; rows of `cybertrain_messages` with `id >` the floor read before the block, or since the case began (`Test.case_message_floor`, recorded at step 3 by an `on_reset` hook) without a block — the dual form per item 4, else its fallback)
- Modify: `cybertrain/test_help.rb` (requires it, registers the floor hook), `test/fixtures/test_app/` (a broadcast in `ArticlesController#create`, a broadcast test and a turbo-stream response test), `.out` files
- Test: `test/test_broadcasts.rb` (new, compiled with SQLite)

**Interfaces:**
- Consumes: Task 12's last response; Task 13's reader.

- [ ] **Step 1: Write the failing tests** ("assert_broadcasts with a record and a name answers the payloads" → `payloads = assert_broadcasts(article, 1) { Cybertrain::Stream.broadcast_append_to(article, target: "comments", html: "<p>Hi</p>") }`, `assert_includes payloads[0], 'target="comments"'`, and the same with `"articles"`; "without a block it counts since the test began"; "assert_broadcasts fails with the counts" → `"Expected 2 broadcasts on \"articles\", got 1"`; "assert_no_broadcasts" passing and failing; "assert_turbo_stream finds the action and target" → after a request with `Accept: text/vnd.turbo-stream.html`, `assert_turbo_stream action: "append", target: "comments"`; failure `"Expected a <turbo-stream action=\"remove\" target=\"comments\">, found: append comments"`).
- [ ] **Step 2: Run** `spin test test/test_broadcasts.rb`, `script/test-command-e2e`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both (PASS) plus `spin test test/stream.rb`.
- [ ] **Step 5: Gate and commit**: "assert_broadcasts, assert_no_broadcasts and assert_turbo_stream, read from the stream table and the last response".

---

### Task 15: Stored mail, `assert_emails`, inline jobs (§10 mail and jobs, §14's mail row, acceptance 7)

**Files:**
- Create: `cybertrain/test/mail.rb` (top-level `assert_emails(count) { } -> nil` (counts `Mailer.deliveries` added in the block after performing the `"cybertrain mail"` jobs queued in it), `assert_no_emails { } -> nil`)
- Modify: `cybertrain/config.rb` (`mail_delivery_method` Symbol, `CYBERTRAIN_MAIL_DELIVERY_METHOD`, default `:test` when `test?` else `:smtp`; `mail_delivery_error -> String` (D13)), `cybertrain/application.rb` (boot fails on it), `cybertrain/mailer.rb` (`Mailer.new(..., delivery_method: Cybertrain.config.mail_delivery_method)`; `Mailer.deliveries -> Array<MailMessage>` (module ivar, seeded); D13's `:test` path in `deliver`), `cybertrain/job.rb` (`Job.work_one_after(floor) -> Boolean`, D12), `cybertrain/test/jobs.rb` (`perform_enqueued_jobs { }` per D12 beside the block-less form, per item 4), `cybertrain/test_help.rb` (requires `test/mail`; reset hook `Mailer.deliveries.clear`), tests that read mail at an `SmtpReceiver` in the test environment (`test/mail_message.rb`, `test/mailer_job.rb`, and any other `grep -ln SmtpReceiver test/*.rb` whose program runs as test env) set `Cybertrain.config.mail_delivery_method = :smtp`, `test/fixtures/test_app/` (a mail-sending action and a test), `.out` files
- Test: `test/test_mail_jobs.rb` (new, compiled with SQLite), `test/config_settings.rb` (grown)

**Interfaces:**
- Consumes: 4b's `MailMessage` and `deliver_later` (verify readers and job kind against the merged code); Task 6's reset hooks.
- Produces: `Mailer.deliveries`, `assert_emails`, `assert_no_emails`, `perform_enqueued_jobs { }`, `Job.work_one_after`.

- [ ] **Step 1: Write the failing tests** ("in the test environment deliver stores the message" → `Mailer.deliver(to: "a@example.com", subject: "Hi", body: "x")` answers `"250 2.0.0 stored in Mailer.deliveries"`, `Mailer.deliveries.size == 1`, its `mail_subject == "Hi"`; a bad address still raises `ArgumentError`; "deliveries are cleared before every test"; "assert_emails counts deliver_later in the block" → `assert_emails(1) { Cybertrain::MailMessage.new(to: "a@example.com", subject: "S", body: "b").deliver_later }`; failure `"Expected 2 emails, got 1"`; "assert_no_emails"; "the :smtp opt-out reaches the SmtpReceiver"; "mail_delivery_method from the environment and its check" → `"mail_delivery_method must be :smtp or :test (got :letter_opener)"`; "perform_enqueued_jobs with a block runs jobs queued in it, the jobs they queue and a future run_at, not earlier jobs" → a job enqueued before the block stays queued; inside, `Job.enqueue("chain", "{}", run_at: 1.day.from_now)` whose handler enqueues `"leaf"`: both performed, answer 2; "the block-less form still runs due jobs at a given time").
- [ ] **Step 2: Run** `spin test test/test_mail_jobs.rb test/config_settings.rb`, `script/test-command-e2e`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them (PASS) plus `spin test test/mailer.rb test/mailer_job.rb test/mail_message.rb test/job_helpers.rb test/job.rb`.
- [ ] **Step 5: Gate and commit**: "Mail in tests is stored in Mailer.deliveries with assert_emails; perform_enqueued_jobs with a block runs what the block queued".

---

### Task 16: `cybertrain new`, scaffold, component, helper, job and attachment write the class form (§11 bullets 1, 2, 4, 5)

**Files:**
- Modify: `cybertrain/cli/templates.rb` (`test_helper` (spec §5.1's text), `health_test` (`class HealthTest < ActionDispatch::IntegrationTest; test "the health check answers" do get "/up"; assert_response :success; end; end` at `test/integration/health_test.rb`), `ci_workflow`'s test step runs `cybertrain test` unconditionally (a new app has a test)), `cybertrain/cli/new_app.rb` (writes `test/test_helper.rb`, `test/integration/health_test.rb`, `test/fixtures/.keep`, `test/support/.keep` instead of `test/.keep`; `config/app.rb` keeps `log_level = :none` in test), `cybertrain/cli/scaffold.rb` (writes `test/fixtures/<table>.yml` (labels `one`, `two`; each attribute a typed sample: `string` `"MyString"`, `text` `"MyText"`, `integer` `1`, `boolean` `false`, `datetime` `2026-11-11 12:00:00`, `references` the parent's `one`), `test/models/<model>_test.rb` (`class ArticleTest < ActiveSupport::TestCase` with one validity test), `test/controllers/<plural>_controller_test.rb` (Rails' scaffold test: `setup do @article = articles(:one) end`, should get index, new, create (`assert_difference(-> { Article.count }, 1)`), show, edit, update, destroy (`-1`))), `cybertrain/cli/component.rb` (`test/components/<name>_component_test.rb`, `ViewComponent::TestCase` with `render_inline` and `assert_select`), `cybertrain/cli/helper.rb` (`test/helpers/<name>_helper_test.rb`, class form, its local helper renamed `render_helper_template`), `cybertrain/cli/job.rb` (`test/jobs/<name>_job_test.rb`, `ActiveSupport::TestCase` with `perform_enqueued_jobs`), `cybertrain/cli/attachment.rb` (class-form `test/integration/<model>_<field>_attachment_test.rb`; no `test/support/app_test.rb`; its `new_client` gone — the integration test's own client)
- Check: the setup-cybertrain action puts the `cybertrain` command on `PATH` in a generated application's CI (it installs the CLI of the commit in spin.lock; if it does not, the generated step runs `ruby -I$CYBERTRAIN_PATH $CYBERTRAIN_PATH/exe/cybertrain test` with the path the action exports).
- Test: `test/cli_new.rb`, `test/cli_scaffold.rb`, `test/cli_generate_component.rb`, `test/cli_generate_helper.rb`, `test/cli_generate_job.rb`, `test/cli_attachment.rb` (snapshots, each diff reviewed); `script/generators-e2e` (new, bash: `cybertrain new shop`, `generate scaffold article title:string body:text published:boolean`, `generate component card title:string`, `generate helper formatting`, `generate job welcome`, `generate scaffold post title:string cover:attachment`, `db migrate`, `cybertrain test` → exit 0, and `spin run gen -- --check`), `.github/workflows/ci.yml` (the gem e2e steps call `cybertrain test` instead of `cybertrain spin test test/<x>.rb || true`, and a step runs `script/generators-e2e`)

**Interfaces:**
- Consumes: Tasks 6–15's API.
- Produces: the templates Task 17 extends (`test_helper` with an insertion marker `  # Helper methods used by all tests go here.`).

- [ ] **Step 1: Write the failing tests** (snapshot changes: "new writes test_helper and the health test and no test/.keep"; "the CI step runs cybertrain test"; "scaffold writes fixtures, a model test and a controller test" (exact text via `assert_equal <<~RUBY` for `articles.yml` and the controller test's create test); "component/helper/job/attachment write the class form" ; "no generator writes test/support/app_test.rb"; `script/generators-e2e` itself).
- [ ] **Step 2: Run** `spin test test/cli_new.rb test/cli_scaffold.rb` and `script/generators-e2e`: FAIL.
- [ ] **Step 3: Implement**; regenerate snapshots with `spin test --regen` (CRuby-runnable) or `script/regen-snapshot`.
- [ ] **Step 4: Run** every `test/cli_*.rb` above and `script/generators-e2e` (PASS).
- [ ] **Step 5: Gate and commit**: "Generators write Rails-shaped tests: test_helper and a health test from new, fixtures and model and controller tests from scaffold, the class form from component, helper, job and attachment".

---

### Task 17: `generate authentication` writes fixtures, `sign_in_as` and class-form tests with `travel_to` (§11 bullet 3, acceptance 8's auth half, acceptance 9)

**Files:**
- Modify: `cybertrain/cli/authentication.rb` (verify every name against the merged 4b generator): writes `test/fixtures/users.yml` (`one` and `two` with `password_digest` computed at generation by `Cybertrain::Password` for `"password"`, `admin: true` on `one`, `failed_attempts: 0`, `confirmed_at` with `--confirmable`), `test/support/session_test_helper.rb` (`module SessionTestHelper; def sign_in_as(user, remember: false)` posting to the session path with `email_address`, `password: "password"`, `remember_me`; `def sign_out = delete(session_path)`), inserts `class ActionDispatch::IntegrationTest\n  include SessionTestHelper\nend` into `test/test_helper.rb` after Task 16's marker; class-form tests `test/controllers/sessions_controller_test.rb`, `registrations_controller_test.rb` (sign-up mode), `passwords_controller_test.rb`, `accounts_controller_test.rb`, `confirmations_controller_test.rb` (`--confirmable`), `test/integration/remember_me_test.rb` (day 15 alive and day 30 ended with `travel_to 15.days.from_now do ... end` / `travel_to 31.days.from_now`; unremembered ends after day 14; 7 idle days; no row backdating), `test/integration/lockout_test.rb` (the lock period with `travel 1.hour`), `test/integration/admin_test.rb`; D15's `manual` lines and `--force` deletion; 4b's helpers that backdated rows (`backdate_session`) are no longer written
- Modify: `script/auth-e2e` (each variant runs `cybertrain test` instead of compiling every `test/*.rb`; `upgrade04` deletes the files the `manual` lines name before running) , `.github/workflows/ci.yml` (the e2e steps that ran `test/authentication.rb` run `cybertrain test`)
- Test: `test/cli_authentication.rb`, `test/cli_authentication_upgrade.rb` (snapshots and expected diffs reviewed)

**Interfaces:**
- Consumes: Task 16's `test_helper` marker; Tasks 2, 4 (`travel_to`, `15.days.from_now`), 8 (fixtures), 12 (integration requests), 15 (`assert_emails` for reset mail instead of the SMTP receiver).

- [ ] **Step 1: Write the failing tests** (cli_authentication: "writes users.yml with real digests" (`Cybertrain::Password.verify("password", digest)` true for both rows); "writes the session test helper and includes it in IntegrationTest"; "remember_me_test checks day 15 and day 30 with travel_to" (the generated file contains `travel_to 15.days.from_now do` and no `update_columns(created_at:`); "a re-run on a 4b application lists the replaced test files" (D15's lines) and "--force deletes them"; generated tests (run by `script/auth-e2e`): "a remembered session survives day 15 and ends after day 30", "an unremembered session ends after day 14", "seven idle days end a session", "ten failures lock the account until the hour passes", "a reset mail is sent once and its link expires after 15 minutes" (`assert_emails(1)`, `travel 16.minutes`)).
- [ ] **Step 2: Run** `spin test test/cli_authentication.rb test/cli_authentication_upgrade.rb`, `script/auth-e2e signup`: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them plus `script/auth-e2e signup invite confirmable upgrade04` (PASS).
- [ ] **Step 5: Gate and commit**: "generate authentication: users fixtures, sign_in_as, class-form tests that travel to day 15 and day 30".

---

### Task 18: The blog's tests as Rails-shaped classes, run by `cybertrain test` (acceptance 8)

**Files:**
- Run in `examples/blog`: `cybertrain generate authentication --invite-only --force` (Task 17's tests and fixtures; verify the blog's merged 4b options), `spin run gen`
- Create: `examples/blog/test/test_helper.rb`, `examples/blog/test/fixtures/{articles,comments,users}.yml`, `examples/blog/test/models/{article,comment}_test.rb`, `examples/blog/test/controllers/{articles,comments}_controller_test.rb`, `examples/blog/test/components/<one blog component>_test.rb` (one `render_inline` test), `examples/blog/test/integration/comment_broadcast_test.rb` (`assert_broadcasts` on a new comment, `assert_turbo_stream`), `examples/blog/test/jobs/*_test.rb` (the blog's job tests from `articles.rb`), `examples/blog/test/support/` (whatever helper several classes share)
- Delete: `examples/blog/test/articles.rb`, `comments.rb`, their `.expected`, `test/support/blog_test.rb` (every one of today's 53 tests moved: a test either becomes a class-form test of the same name or is listed in the commit message with the test that now covers it)
- Modify: `examples/blog/README.md` (`cybertrain test`), `examples/blog/gen/**` (regenerated, `gen/tests.rb` and `gen/test/**` committed), root `.github/workflows/ci.yml` (the blog job runs `cybertrain test` and `spin run gen -- --check`)
- Test: the blog's own suite

- [ ] **Step 1: Count** today's tests (`grep -c '^test "' examples/blog/test/*.rb`) and list them; **Step 2: Write** the class-form files, fixtures replacing every `BlogTest.article` / `comment` / `reset`; **Step 3: Run** `cd examples/blog && spin run gen && cybertrain test` — every test passes, the count is today's plus the generated authentication tests plus the component and broadcast tests; record the first compile's time for D68; **Step 4: Run** `spin run gen -- --check`, `cybertrain test test/controllers`, `cybertrain test -n /comment/`, root `ruby script/gate`; **Step 5: Commit**: "blog: tests as Rails-shaped classes with fixtures, one binary through cybertrain test; authentication tests travel in time".

---

### Task 19: Documents — design.md D66–D69, the guides and translations, spec §21 (§15, acceptance 10)

**Files:**
- Modify: `docs/design.md` (D66 the clock, durations, time helpers and the configured zone; D67 test classes, setup / teardown and database isolation; D68 fixtures and `cybertrain test` (with the blog's compile time from Task 18 and spike item 6's numbers); D69 the component, stream, mail and job helpers, the new assertions and the receivers' automatic stop — each dated, with "why", the Spinel constraint and rejected alternatives (the rollback, a Ruby-level `Time.now` stub, a repairing HTML parser); D13 (D67's clear replaces the planned rollback), D19, D32, D34 (the application side of T-1 answered, the framework suite still deferred), D52 (`scheduler_tz`'s default) amended; section 8 keeps "error pages with stack traces"; section 13's dated entry with the new test programs and rules), `docs/guide/testing.md` rewritten (the class form, fixtures, `cybertrain test`, time travel, components and streams, assertions, mail, jobs, receivers; the top-level form kept as a section; the upgrade section of §18: removed seams, stored mail, the clear, `render_helper_template`, moving `AppTest.boot` / `BlogTest.boot` into `test_helper.rb`; item 1's `Time.now` note if the override failed; `1.month.ago` → `Time.current.months_ago(1)`), `docs/guide/configuration.md` (`time_zone`, `scheduler_tz`'s default, `mail_delivery_method`), `docs/guide/models.md` (durations and `Time.zone`, `time.hour` is UTC first), `docs/guide/requests.md` (the removed `fixed_now`), `docs/guide/how-it-works.md` (`gen/tests.rb`, `gen/test/`), `docs/guide/tutorial.md` where it runs tests; each English change mirrored in `docs/guide/{fr,ja,ru,zh}/` with `script/check-guide-i18n --update-sha <files>`; `README.md` (feature list); `docs/api` regenerated (`script/api-docs`); `spikes/NOTES.md` and `docs/spinel-feedback.md` cross-checked; the spec gains "## 21. Implementation notes" with a "Part 5a" section (the spike's fallbacks, D1–D18 where they go beyond the spec, new rule numbers, test counts from `script/test-shard 0 1` and the blog)
- Test: `ruby script/gate` (guide i18n, docs i18n, version mentions), `script/api-docs`, `script/guide-pages`, `grep -rn "Cache.clock\|fixed_now\|status_now\|supervisor_clock\|current_time =" docs/guide` (nothing)

- [ ] **Step 1: Write the documents.** **Step 2: Run** the checks, `script/test-shard 0 1`, `script/test-command-e2e`, `script/generators-e2e`, `script/auth-e2e signup invite confirmable upgrade04`, `cd examples/blog && cybertrain test && spin run gen -- --check`; record the counts in §21. **Step 3: Commit**: "Phase 5a documents: design.md D66 to D69, the testing guide rewritten with translations, configuration and models, README, spec section 21".

---

## Execution order and verification

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17 → 18 → 19. Task 3 needs 2; 4 needs 2; 5 needs 4; 6 needs 2; 8 needs 6; 10 needs 6, 8 and 9; 11 needs 10; 12–15 need 11 (each grows the e2e application); 16 needs 12–15; 17 needs 16; 18 needs 17; 19 needs everything. Every task ends with `ruby script/gate`, `ruby script/check-reserved-names`, `script/api-docs` and `script/test-shard 0 1` green, plus the e2e scripts it names; after Task 18, `cd examples/blog && cybertrain test` and `spin run gen -- --check` pass too, which with Task 19 is acceptance item 10.
