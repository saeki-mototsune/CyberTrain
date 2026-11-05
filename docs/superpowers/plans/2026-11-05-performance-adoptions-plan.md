# Performance adoptions Implementation Plan

> **For agentic workers:** each task below is one pull request on its own branch off `main`. Tasks share no code, so they run in parallel. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the proposals that survived measurement: multi-process serving, a faster dev rebuild, a sharded CI, a cheaper `Set-Cookie`, and a written record of what was rejected.

**Architecture:** Five independent pull requests. None changes request semantics; the two that add behaviour (`reuse_port`, the gen skip) default to what happens today or fall back to it.

**Tech Stack:** Ruby under the Spinel subset, `spin`, GitHub Actions, POSIX shell.

**Spec:** The verdict below. Measurements: Spinel 2026.11.04.7026, wrk 32 connections, Linux arm64 in Docker on a Mac for throughput, macOS `sample` for the profile.

| Measurement | Result |
|---|---|
| Dev edit | gen 3.3 s, Spinel analysis 3.9 s, C 0.75 s |
| `show` req/s by processes | 1 ≈ 9,100, 2 ≈ 16,000, 4 ≈ 27,600; POST flat |
| `Set-Cookie` on every response | 5,186 vs 6,941 req/s; the encoder's per-character regex is about 11% of CPU |
| CI | 106 test programs in one job per OS; `spin test` was 9 of 21 min on Ubuntu and 6 of 15 on macOS (design.md D34, 82 programs) |

Rejected, recorded in Task 5: jemalloc by default, ccache, `-O0`/`-O1`/mold, embedding `public/`, HMAC and `read_row` in C, bundling tests, interpreted CRuby dev mode. Held: `includes`, template compilation.

## Global Constraints

- Everything under `cybertrain/` must compile under Spinel: no `send`, no `eval`, no `method_missing`, and an ivar assigned outside `initialize` is boxed.
- Commits pass `script/gate`; follow CONTRIBUTING.md's Commits section for the message shape. Do not use `--no-verify`.
- A changed snapshot goes through `script/regen-snapshot test/<name>.rb` and its diff is read.
- A page edited in `docs/deploy.md` is edited in `docs/deploy.en.md` too (`check-docs-i18n`).
- No release numbers on pages `script/check-version-mentions` watches.
- Do not name other Ruby compilers or transpilers in docs or the site.
- Design decisions are written in `docs/design.md`; Task 1 uses D35, Task 2 uses section 6, Task 3 amends D34, so they do not collide.
- Do not bump the version or the Spinel pin.

## Review Focus

1. Two servers on one port with `reuse_port` both start and split traffic, so a leftover process silently keeps serving: the docs say so, and a plain listener on the port still raises `PortInUse`.
2. Stopping a `reuse_port` server closes its descriptor once, and the port can be bound again afterwards (Task 1 test).
3. A hostname or an IPv6 literal with `reuse_port` either works or stops the boot with a message naming the setting (Task 1 test), never binds the wrong address.
4. Editing `db/schema.rb`, `config/routes.rb`, `bin/gen.rb`, `spin.toml`, `spin.lock`, or a path-dependency framework file must not reuse a stale gen binary; a missing `build/bin/gen` must not fail the rebuild (Task 2 tests).
5. A cookie value holding a space, `+`, `%`, `;`, `=`, or a non-ASCII byte serializes exactly as before (Task 4 test), and every `test/*.rb` lands in exactly one shard (Task 3 check).

---

### Task 1: `reuse_port`, N processes on one port

Branch: `claude/perf-reuse-port`

**Files:**
- Modify: `cybertrain/http/server.rb` (`initialize`, `bind_listener`), `cybertrain/config.rb`, `cybertrain/application.rb:154`
- Modify: `docs/design.md` (new D35, after D34), `docs/deploy.md`, `docs/deploy.en.md`, every other place that lists `CYBERTRAIN_WORKER` (grep it)
- Test: `test/server.rb`, `test/config_settings.rb` or the test that covers `Config` env parsing, and their snapshots

**Interfaces:**
- Produces: `Server.new(..., reuse_port: false)`; `Config#reuse_port` (bool, `attr_accessor`), from `CYBERTRAIN_REUSE_PORT` via `Config.bool_from_env`, default `false`; `Config#reuse_port_error` if a validation is needed, following `health_error`.

- [ ] **Step 1: Write the failing tests in `test/server.rb`**
  - `"reuse_port lets two servers bind one port and both answer"`: start A on port 0 with `reuse_port: true`, start B on A's port the same way, GET through a client against each until both handlers have answered (handler records which server), assert both ran.
  - `"reuse_port survives stop: the port binds again"`: start, stop, start a new one on that port, GET returns 200.
  - `"a plain listener on the port still raises PortInUse for reuse_port"`: plain server holds the port, `reuse_port: true` raises `PortInUse` with the `IN_USE` reason. On Linux and macOS a socket without `SO_REUSEPORT` blocks it; if a platform differs, report rather than loosen the test.
  - A `Config` test: unset is `false`, `CYBERTRAIN_REUSE_PORT=1` is `true`.

  The balancing assertion in the first test holds only on Linux. On macOS assert only that both bound and the listener that receives connections answers; branch on `RUBY_PLATFORM` if Spinel provides it, otherwise have the test assert only binding and answering, and prove the split in Step 5.

- [ ] **Step 2: Run them**

Run: `spin test test/server.rb`. Expected: fails on the unknown `reuse_port:` keyword.

- [ ] **Step 3: Implement in `bind_listener`**

When `@reuse_port` is true: `Socket.new(family, Socket::SOCK_STREAM, 0)`, set `SO_REUSEADDR` and `SO_REUSEPORT`, `bind(Socket.sockaddr_in(@port, @host))`, `listen(1024)`, then `TCPServer.for_fd(sock.fileno)`. This sequence is proven to compile and serve under Spinel; `TCPServer.new` has no option for it. The rescues stay as they are. Keep the `Socket` in an ivar assigned `nil` in `initialize` so it outlives the bind.

Check and settle by experiment, under Spinel:
- whether closing the `TCPServer` leaves the `Socket` to close the same number again (a double close could hit a descriptor reused by a connection). Close exactly once.
- what `listener.addr[1]` gives for port 0 through `for_fd`.
- whether accepted sockets get the same options as today (`accept_client`, TCP_NODELAY).
- whether `sockaddr_in` accepts `"localhost"` and an IPv6 literal, and `AF_INET6` works. Support what works; anything else stops the boot through a `Config` error naming `reuse_port` and `host`, tested.

- [ ] **Step 4: Wire `Application#server`**

Pass `reuse_port: @config.reuse_port && !@config.development?`. In development, log one warning and ignore it: the dev server re-execs itself and a stray second process would answer with stale code.

- [ ] **Step 5: Prove the split on Linux**

In the `ct-bench` container (see the brief) build `examples/blog`, run two processes with `CYBERTRAIN_REUSE_PORT=1 CYBERTRAIN_WORKER=0`, drive wrk through the port, and confirm throughput near 1.7× one process. Record the numbers in the PR body.

- [ ] **Step 6: Write the docs**

`docs/deploy.md` and `.en.md`: a section on running N processes with a systemd template unit (`notes@.service`) and one process keeping the worker. State plainly: Linux only for the balancing (macOS binds but does not distribute); `CYBERTRAIN_WORKER=0` on all but one process, because each process otherwise runs the `Scheduler` and `Job` worker; `RateLimit` is per process, so a limit is effectively N times looser; `Background` subscriptions run per process; POST does not scale because SQLite has one writer; leave `SPINEL_WORKERS` at 1; a leftover process keeps taking traffic without any bind error. D35 in `docs/design.md` records why this rather than prefork (Spinel has no `fork`) and the measured table above.

- [ ] **Step 7: Run and commit**

Run: `spin test test/server.rb test/application.rb` and the config test; `script/gate`. Commit.

### Task 2: skip recompiling gen in the dev loop

Branch: `claude/perf-dev-gen-skip`

**Files:**
- Modify: `cybertrain/dev/rebuilder.rb`, `docs/design.md` section 6
- Test: `test/dev_error_page.rb` + snapshot, with a fake `spin` and `spinel` on `PATH`

This task first followed `require`s from `bin/gen.rb` by regex and signed the files found. Review found the regex misses `require File.join(__dir__, "..", "app", "routes", "x")`, which the compiler folds and compiles, so gen went stale with no error. The design below asks the compiler instead and replaced that version on this branch.

**Interfaces:**
- Produces: `Rebuilder#gen_fresh? -> Boolean`, `Rebuilder#promote_gen_check -> nil`; constants `DIRECT_GEN`, `GEN_CHECK = "build/gen-check.c"`, `GEN_COMPILED = "build/gen-compiled.c"`.
- `Rebuilder#command(incremental = true, gen = "spin run gen")`.

- [ ] **Step 1: Write failing tests in `test/dev_error_page.rb`**: the second rebuild with an unchanged C runs `./build/bin/gen`; a changed C runs `spin run gen`; a failed check, a failing `spin flags` and a missing binary each run `spin run gen`; a failed direct run falls back to the full command; the saved C goes away on a stale check; a failed check leaves no C to promote.

- [ ] **Step 2: Run**: `spin test test/dev_error_page.rb`, expected: fails.

- [ ] **Step 3: Implement the check in `Rebuilder`**

`gen_fresh?` runs `spinel bin/gen.rb -c -o build/gen-check.c --force --no-line-map $flags`, with `flags=$(spin flags)` set first so a failing substitution fails the command. Fresh means the check succeeded, `build/bin/gen` exists and the C is byte-identical to `build/gen-compiled.c`. Any failure means not fresh. The files live in `build/` because spin warns on every command about spinel's output anywhere else in the package.

- [ ] **Step 4: Use it in `Rebuilder#rebuild`**

Check before building, so an edit during the build is seen next time. If fresh, gen is `./build/bin/gen`, otherwise `spin run gen`. After a successful build run with `spin run gen`, promote the check C to the saved one. A stale check deletes the saved C at once, because `spin run gen` replaces the binary even if the build then fails. A failed direct run falls back on the next line of `rebuild` to one full `spin run gen` build, so a broken binary never strands the loop. The `--incremental` fallback keeps working.

- [ ] **Step 5: Run**: `spin test test/dev_error_page.rb test/dev_application.rb test/application.rb`, expected: pass, snapshots reviewed.

- [ ] **Step 6: Measure on `examples/blog`**

Edit a controller, time one rebuild with and without the saved C, alternating. Expected: about 3 s saved of about 8 s, less the check's 0.3 s. Then edit `config/routes.rb`, and a file it requires through `File.join`, and confirm `gen/` follows. PR body carries both.

- [ ] **Step 7: Document and commit**

`docs/design.md` section 6: what gen is compiled from, why the check compares the compiler's output rather than a list of inputs, and what it does not see. Commit.

### Task 3: shard the framework tests in CI

Branch: `claude/perf-ci-shards`

**Files:**
- Create: `script/test-shard`, `.github/actions/setup-spinel/action.yml`
- Modify: `.github/workflows/ci.yml`, `docs/design.md` D34, `CONTRIBUTING.md` (Running the tests)

**Interfaces:**
- Produces: `script/test-shard <index> <total>` runs `spin test` on the sorted `test/*.rb` whose zero-based position modulo `total` equals `index`; `script/test-shard --list <index> <total>` prints them.

- [ ] **Step 1: Write `script/test-shard`** (POSIX sh, executable), refusing a non-numeric or out-of-range argument with exit 2.

- [ ] **Step 2: Check completeness**

Run:
```bash
for i in 0 1 2 3; do script/test-shard --list $i 4; done | sort | diff - <(ls test/*.rb | sort)
```
Expected: no output. Then `script/test-shard 0 40` runs a small shard green.

- [ ] **Step 3: Split the workflow**

Move the setup steps from `ruby/setup-ruby` through saving the toolchain into the composite action, used by `test` and by a new job `framework-tests` with `matrix: { os: [ubuntu-26.04, macos-latest], shard: [0, 1, 2, 3] }`, `fail-fast: false`, whose test step is `script/test-shard ${{ matrix.shard }} 4`. The `API reference builds` step stays in `test` only. Remove `Framework tests` from `test`, keeping that job's name, so required checks and `release.yml`'s `ci` keep working. A composite action cannot use `actions/checkout` before itself, so each job checks out first with `ref: ${{ inputs.ref }}`.

- [ ] **Step 4: Validate**: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")'`, and `actionlint` if installed. The real check is this PR's own CI: compare job durations with `main` in the PR body.

- [ ] **Step 5: Document and commit**

D34: note what shipped. CONTRIBUTING: how to reproduce one shard. Commit.

### Task 4: `Cookies.serialize` skips the encoder for plain values

Branch: `claude/perf-cookie-serialize`

**Files:**
- Modify: `cybertrain/http/cookies.rb`, `cybertrain/router.rb:129-143`, `cybertrain/http/query.rb`
- Test: `test/cookies.rb` + snapshot

**Interfaces:**
- Produces: `Query.plain?(value: String) -> Boolean`, the body of today's `Router.plain_segment?` moved. `Router.plain_segment?` delegates to it, or its callers move, whichever leaves less code. Check `router.rb` loads `query.rb`.

- [ ] **Step 1: Write the failing test** `"serialize encodes exactly as encode_www_form_component, plain or not"`: for every byte 0..127 alone, and `"a b"`, `"a+b"`, `"50%"`, `"a;b"`, `"a=b"`, `"日本語"`, `""`, `"abc--DEF_-."`, assert `serialize("k", v)` starts with `"k=#{URI.encode_www_form_component(v)}"`. It passes today; it pins the behaviour. Add `"serialize of a plain value does not call the encoder"` only if it can be observed without a seam; do not add one for the test.

- [ ] **Step 2: Implement**: in `Cookies.serialize`, use `value` as is when `Query.plain?(value)`, otherwise the encoder. Keep the `+"..."` mutable buffer.

- [ ] **Step 3: Run**: `spin test test/cookies.rb test/router.rb`, expected: pass.

- [ ] **Step 4: Measure** POST or a Set-Cookie-on-every-response page before and after, in the `ct-bench` container or on the Mac. Put the numbers in the PR body. No claim without a number.

- [ ] **Step 5: Commit.**

### Task 5: record the verdicts

Branch: `claude/perf-notes`

**Files:**
- Modify: `docs/performance-next.md`
- Add: this plan

- [ ] **Step 1: Write** under "Things that are not worth doing again" each rejected item with its number and the premise that failed; under "Candidates" the held `includes` and template compilation with the conditions that would reopen them (interpreter share of CPU, an app with real N+1); under "How to measure" that `bench/run` leaves `SPINEL_GC_FULL_INTERVAL` unset while deployments set 8, which is worth +21-30% on pages.

- [ ] **Step 2: Run** `script/gate`; commit.
