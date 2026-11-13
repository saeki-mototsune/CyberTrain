# CRuby Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cybertrain server` answers an edit from CRuby in under a second, builds the Spinel binary in the background, hands the port to the binary when it is ready, and every page says which runtime rendered it; the playground runs the same loop.

**Architecture:** The gem CLI (CRuby) becomes a supervisor that owns the listening socket and runs one child at a time on it: a CRuby child (`ruby -r cybertrain/preview bin/NAME.rb`) or the compiled binary. A Fiddle shim under `cybertrain/preview/` implements the `ffi_*` DSL so the framework's FFI files run unchanged. The supervisor talks to a child through five environment variables and one state file; the framework gains a supervised development role, an inherited listener and an indicator middleware, all inactive unless supervised.

**Tech Stack:** Ruby 3.2+ (CRuby: `fiddle`, `spawn` with descriptor inheritance, `IO.select`), the system C compiler, Spinel (pinned release) for the compiled side, SQLite and zlib through the existing FFI files, the repository's snapshot tests (`cybertrain/test.rb`).

**Spec:** docs/superpowers/specs/2026-11-12-cruby-preview-design.md (approved 2026-11-12). Read it first; section numbers below are its.

**Execution notes:** Task 1 is a throwaway spike and a gate: its record amends Decisions P3 and Task 2, and may stop the work. Tasks run one at a time (never two Spinel builds in one build directory), in this order: 1, 2, 3, 4, 5, 6, 8a, 7, 8b, 9, 10. Task 8 is split (P18): its framework half, 8a, comes before Task 7, whose end-to-end script reads the header 8a adds. From Task 7 until Task 9, `playground/playground-server` passes `--spinel` (spec §13).

## Global Constraints

- **A CRuby pass is not acceptance.** Every change under `cybertrain/` that is not in `cybertrain/preview/` or `cybertrain/cli/dev_server*` must pass compiled: `spin test test/<name>.rb` for each test named in the task, and `examples/blog` must regenerate clean (`cd examples/blog && spin run gen -- --check`). Name the compiled tests run in the commit body (CONTRIBUTING.md).
- **Today's loop stays byte for byte**: `cybertrain server --spinel`, a direct `spin run NAME`, and the native CLI. No existing `.expected` snapshot changes except `test/cli_toolchain.rb.expected` (the `fiddle` line of `doctor`, Task 8) and `test/main.rb.expected` only if `dev-address` shows in a usage text (it must not).
- **No gem dependency.** CRuby's standard library and the C compiler only.
- **`cybertrain/preview/**` and `cybertrain/cli/dev_server*` are CRuby-only** and must never be required by `cybertrain.rb`, `cybertrain/cli.rb` or anything Spinel compiles (`bin/cybertrain.rb` compiles `cybertrain/cli.rb`). Only `exe/cybertrain` loads the supervisor.
- **Nothing here is read by a production boot.** Every framework branch is behind `Dev::Supervision.active?`, which is false outside `development`.
- **Spinel rules** for the compiled side (spikes/NOTES.md, "Rules by topic"): one concrete type per instance variable (7), seeded containers (9), one return type per method name across the program (10, 34, 41), no new `rescue` clause in a method that blocks and yields (32), `rescue JSON::NestingError, JSON::ParserError, StandardError` where everything is caught (33), threads through a method (21), class names global (no reuse). Run `ruby script/check-reserved-names` after adding a method name.
- **Never skip, delete or weaken a test.** A snapshot changes only where behaviour changed on purpose.
- Exact texts: the indicator's five lines and `X-Cybertrain-Runtime: cruby|spinel` are spec §5's, verbatim, including `·`, `…` and `—`.
- Every task ends with `ruby script/gate` green and its own tests green. Commits carry no model identifier.
- No version bump in this work.

## Decisions

Rulings where the spec leaves a choice. Tasks build on these names.

- **P1. Supervision variables** (set by the supervisor for every child, read by `Cybertrain::Dev::Supervision`): `CYBERTRAIN_DEV_LISTEN_FD` (decimal descriptor), `CYBERTRAIN_DEV_READY_FILE`, `CYBERTRAIN_DEV_STATE_FILE`, `CYBERTRAIN_DEV_FAILURE_FILE` (absolute paths), `CYBERTRAIN_DEV_GENERATION` (decimal). A process is supervised when `CYBERTRAIN_DEV_LISTEN_FD` is non-empty and the environment is `development`.
- **P2. Files in the application**, all under `tmp/cybertrain-dev/`: `state`, `ready`, `failure`, `supervisor.pid`, `child.pid`, `build.pid` (P22), and the shim's cache `ffi/<sha256>.so`. The supervisor creates the directory and removes `state`, `ready`, `failure` and the pid files when it stops; `ffi/` stays.
- **P3. The shim's surface** (`Module#ffi_lib`, `ffi_source`, `ffi_func`, `ffi_const`, `ffi_read_ptr`, and module functions `malloc` / `free`), pointers as Integer addresses, `blocking:` accepted and ignored. Task 1 records the points of spec §7 (pointer comparisons, `static` helpers, encodings of `:str` / `:binstr`, the thread-local length) and Task 2 implements what it records.
- **P4. State file format**: three header lines, one empty line, then free text to the end of the file.

  ```
  generation 12
  serving cruby
  build building

  <output of a failure, may be empty>
  ```

  `serving` is `cruby`, `spinel` or `holding`; `build` is `idle`, `building`, `ready`, `failed` or `binary_failed`. Written to `state.tmp` and renamed. A missing or malformed file reads as generation 0, serving `""`, build `idle`, output `""`.
- **P5. Reserved development paths**, answered by `Dev::Indicator` before the application and never logged: `GET /__cybertrain/dev/state?runtime=R&generation=N` answers `{"generation":12,"serving":"spinel","build":"ready","text":"Spinel ready — reload"}` (`text` computed for a page rendered by runtime R at generation N); `GET /__cybertrain/dev/indicator.js` answers the script. One Ruby method owns the five texts; the script only fetches and sets `textContent`.
- **P6. Indicator markup**, inserted before `</body>` (at the end without one), under `ErrorPage#banner_status?`'s rules and only for HTML: `<div id="cybertrain-dev-indicator" data-runtime="cruby" data-generation="12">TEXT</div><script src="/__cybertrain/dev/indicator.js"></script>`; the script tag gets `nonce="…"` (`ctx.csp_nonce`) when `config.content_security_policy_nonce_directives` is not empty. The script positions the div through the CSSOM (fixed, bottom right) and polls every 1 s; a failed fetch leaves the text as it is.
- **P7. ErrorPage keeps its `Rebuilder` slot** and gains a second nullable slot: `Dev::ErrorPage.new(app, rebuilder = nil, status = nil)` with `status` a `Dev::BuildStatus`. The banner shows when either says failed. The old loop's path is not touched (this is how "one type per slot" and "byte for byte" both hold).
- **P8. CLI wiring.** `exe/cybertrain` requires `cybertrain/cli/dev_server` and calls `Cybertrain::CLI::DevServer.run(ARGV)` when `ARGV[0] == "server"` and `--spinel` is absent; everything else goes to `CLI.run`. `CLI.run_server` (compiled too) drops `--spinel` with the existing `without_flag` and is otherwise today's.
- **P9. Children.** CRuby: `ruby -I<dir>… -r cybertrain/preview bin/NAME.rb PORT`; compiled: `build/bin/NAME PORT` (the port as the only argument, as today's re-exec passes it; `Main.server?` reads that as the server). `<dir>…` are the `-I` values of `spin flags`, in order. Environment: P1's variables, `CYBERTRAIN_ENV=development` unless already set. STDIN and STDOUT inherited; STDERR through a pipe the supervisor copies to its own STDERR as it arrives, keeping the last 40 lines. gen: `ruby -I<dir>… bin/gen.rb`, output captured.
- **P10. Address.** The supervisor always asks the application: `ruby -I<dir>… -r cybertrain/preview bin/NAME.rb dev-address` prints `HOST PORT`; a port argument to `cybertrain server` overrides the port. `dev-address` is handled in `Main.run`, is not listed in `Main.usage`, and reads `Cybertrain.config.host` / `.port`. (The spec's "the port argument if given, else ask" still needs the host, hence always.)
- **P11. Bounds.** Driver tick 50 ms; watcher interval 0.1 s; a child must be ready within 30 s; a child gets 10 s after TERM, then KILL; the holding page sends `Retry-After: 1` and `<meta http-equiv="refresh" content="2">`.
- **P12. Order within a change round**: cancel the build, run gen (the old child still serves), stop the child, start the CRuby child, start the build. If gen fails: stop the child, hold; no build.
- **P13. CRuby-only tests** live in `test/cruby/<name>.rb` with `test/cruby/<name>.rb.expected` (same harness, `cybertrain/test.rb`), run by `script/test-cruby [file…]` (`ruby -I. <file>` diffed against its snapshot; `--regen` rewrites). `spin test` and `script/test-shard` glob `test/*.rb` only, so they never see these. The gate's "every test has its snapshot" check is extended to `test/cruby/`.
- **P14. One supervisor per application.** `supervisor.pid` naming a live `cybertrain server` refuses a second one (`error: a cybertrain server is already running here (pid N)`, exit 1). A live process named by a leftover `child.pid` that is this application's child is stopped (TERM, 5 s, KILL) before the socket is bound: a supervisor killed with SIGKILL must not leave the port taken. A child is recognised by whole arguments, read from `/proc/PID/cmdline` or `ps -ww -o args=` (never cut at `$COLUMNS` or the terminal's width): a ruby interpreter whose script argument is this application's `bin/NAME.rb`, or an executable that is exactly its `build/bin/NAME`; a relative path is resolved against the process's working directory where the system shows it (`/proc`), and elsewhere must be written as the supervisor spawns it (`bin/NAME.rb`, `build/bin/NAME`). Anything else (an editor with the file open, another application's `bin/NAME.rb`, `build/bin/NAMEx`) is left alone.

- **P15. A listed gap is pinned.** For each file in `test/cruby/parity-gaps.txt`, `script/preview-parity` also compares the CRuby output with `test/cruby/parity/<name>.rb.expected` (the checkout's path written as `<repo>`); a difference is "unexpected". `--regen-gaps` rewrites those snapshots. A listed gap never hides a new failure in the same file.
- **P16. No stale binary after a blocking stop.** The runner also answers `change_pending? -> Boolean`: true when a change is queued for the machine, or when a fresh snapshot of the watched files, taken at that moment, differs from the watcher's baseline (it must not wait for the watcher's next poll). Task 7 tests it with a save made while a stand-in child is slow to stop: the binary is not started. In a handover to the binary, the machine asks it after `stop_child`; when true it does not start the binary (the change round that follows starts the CRuby child). Task 6 tests it: `[[:stop_child]]` and nothing else.
- **P17. The lock is read twice in a round.** After `run_gen` and before `stop_child`, the machine asks `build_locked?` again; when the lock has appeared the round stops there, stays pending, and is taken up by `on_tick` once the lock is gone. Task 6 tests it with a fake whose lock appears during `run_gen`. (`cybertrain build` creating its lock atomically is out of scope: that window is the existing lock's, in today's loop as well.)
- **P18. Task 8 in two halves.** 8a: `Dev::Indicator`, the header, the reserved paths, `front_app`, their compiled tests (Task 8's `cybertrain/dev/indicator.rb`, `cybertrain/dev.rb`, `cybertrain/roles/server.rb`, `test/dev_indicator.rb`, `test/dev_application.rb`). 8b, after Task 7: the fallbacks, `doctor`, their tests, and Task 8 Step 5's additions to `script/preview-e2e`.
- **P19. Children run with `ruby -E UTF-8`** (P9, gen and `dev-address` included): the locale may be US-ASCII, which breaks text comparisons (spike).
- **P20. E2e step 2's bound is 300 s**, not 120 s: the blog's first build took about 106 s on the development machine (2026-11-13), and CI machines are slower; the bound only catches a hang.
- **P21. The supervisor loads the framework's dev files from the application's framework; the gem ships none of `cybertrain/dev/*.rb`.** `require "cybertrain/cli/dev_server"` needs only files `cybertrain.gemspec` lists. `DevServer.run`, after the application and toolchain checks and once `spin flags` has named the `-I` directories, puts those directories on `$LOAD_PATH` ahead of the gem's own and only then requires `cybertrain/dev/{supervision,state_file,watcher,watched}` (through `processes.rb` and `watch.rb`, which build on them; the supervisor's own files are required relative to `dev_server.rb`, so a framework's copies never replace them). The supervisor and its children then share one definition of the state file and the environment contract: the child's framework is the authority. A framework without `cybertrain/dev/supervision.rb` (an older one) prints `cybertrain: this application's framework has no CRuby preview; running the compiled loop (--spinel)` on STDERR and runs what `cybertrain server --spinel` runs (`DevServer.no_preview_reason`, where 8b's fallbacks go too).
- **P22. `build.pid`.** The build's process-group id goes to `tmp/cybertrain-dev/build.pid` (written to `build.pid.tmp` and renamed) when a build starts and is removed when it ends, is cancelled, and when the supervisor stops. A starting supervisor, before its first round, stops a live leftover group named there when its leader is this application's build: the program `spin` with exactly `build NAME` or `build NAME -- --incremental`, in the application's directory where `/proc` shows it (P14's whole-argument rule). Stopping a build, at startup or on a cancel: TERM to the group's members but its leader, so that spin sees its step fail, removes its `$TMPDIR/spin-compile-PID.err` and exits; then TERM to the group, then KILL (5 s for a leftover, 1 s at most for a cancel).

## Review Focus

Conditions the spec implies and a person will hit; each has its test in the task named.

1. **Two saves in quick succession, or a save while a build or a handover is running**: the binary that takes the port is built from the last save, never an earlier one, and the rounds coalesce. (Task 6, machine tests "stale build" and "change during building"; Task 7 e2e step 5.)
2. **The supervisor dies without cleaning up** (SIGKILL, a closed terminal): the next `cybertrain server` starts and serves; no orphan holds the port. (Task 7, P14, e2e step 8.)
3. **A request is in flight when the child is replaced** (a slow action, an open Server-Sent Events stream): it is drained or cut at the 10 s bound, and the new child serves; the supervisor never hangs on a child that will not exit. (Task 7, processes test "TERM then KILL"; e2e step 6.)
4. **The application boots but never listens, or the port is already taken**: the first becomes HOLDING after 30 s with the reason on the page; the second prints today's `PortInUse` message and exits 1 before any child starts. (Task 7.)
5. **`cybertrain build` runs while the server is up**: no gen, no restart, `gen/views.rb` is never read by a child while it holds the embedded table, and the pending change is handled once the lock is gone. (Task 6, machine test "locked"; Task 7 e2e step 7.)

---

### Task 1: Spike — examples/blog answers under CRuby

Throwaway. No test cycle; the deliverable is a record and a go/stop decision.

**Files:**
- Create: `spikes/preview/shim.rb`, `spikes/preview/run.sh` (throwaway programs, kept as the other spike directories are)
- Modify: `spikes/NOTES.md` (a section "CRuby preview spike, 2026-11"), the spec's §7 "Known points" paragraph (replace with what was found)

- [ ] **Step 1:** Write a minimal Fiddle shim in `spikes/preview/shim.rb` defining the P3 surface on `Module`, compiling each module's `ffi_source` with `cc -shared -fPIC` into the scratch directory.
- [ ] **Step 2:** In a copy of `examples/blog` (never in the tree), run `ruby -I<repo> -I. -r <repo>/spikes/preview/shim bin/blog.rb 3999` after `ruby … bin/blog.rb migrate`; get `GET /articles` to answer 200 and `POST /articles` (with the CSRF token and cookie from `GET /articles/new`) to answer 303. Fix the shim, not the framework, wherever possible.
- [ ] **Step 3:** Run `ruby -I<repo> -I. bin/gen.rb` in the copy and `git diff --no-index` its `gen/` against the committed one. Expected: no difference.
- [ ] **Step 4:** Run every `test/*.rb` once with `ruby -I. -r ./spikes/preview/shim <file>` and diff against its `.expected`; count the mismatches and group them by cause.
- [ ] **Step 5:** Record in `spikes/NOTES.md`: how pointers are represented and why the callers' comparisons hold; whether any `ffi_func` names a `static` function; the encodings `:str` and `:binstr` must return for the snapshots to match; whether Fiddle releases the GVL and how the `:binstr` length is read; whether piping a child's STDERR delays it under CRuby and under the compiled binary; every framework file that needed a CRuby-specific change and why; the mismatch count of Step 4 by cause; the measured time from process start to the first 200.
- [ ] **Step 6: Gate.** Stop and report to the maintainer, without starting Task 2, if more than five framework files (outside the three FFI files) need a CRuby-specific branch, if Step 3 shows a difference that is not a plain ordering or formatting fix in the generator, or if the first 200 takes more than 1 s.
- [ ] **Step 7:** Commit (`spike: examples/blog serves under CRuby with a Fiddle shim`).

### Task 2: The FFI shim

**Files:**
- Create: `cybertrain/preview.rb`, `cybertrain/preview/ffi.rb`, `cybertrain/preview/ffi_library.rb`, `cybertrain/preview/failure.rb`
- Create: `script/test-cruby`
- Test: `test/cruby/preview_ffi.rb`, `test/cruby/preview_failure.rb` (+ `.expected`)
- Modify: `script/gate` (snapshot check covers `test/cruby/`)

**Interfaces:**
- Produces: `require "cybertrain/preview"` (loads the three files; raises `LoadError` naming `fiddle` when it is missing).
- Produces: `Cybertrain::Preview::FFILibrary.build(source, libs, cache_dir) -> String` (path of the shared library for this C source linked against `libs`, compiling only when `cache_dir/<sha256 of source, libs, and the first line of cc --version>.so` is absent; raises `Cybertrain::Preview::CompileError` with the compiler's output).
- Produces: `Cybertrain::Preview.cache_dir -> String` (`tmp/cybertrain-dev/ffi` under the current directory, created on demand) and `Cybertrain::Preview.warm! -> Integer` (compiles every library the loaded framework declares and answers how many it built; the playground image calls it, Task 9).
- Produces: on `Module`: `ffi_lib(name)`, `ffi_source(text)`, `ffi_func(name, arg_types, return_type, blocking: false)`, `ffi_const(name, value)`, `ffi_read_ptr(name, offset)`; on a module that called any of them: `malloc(size) -> Integer`, `free(address) -> nil`. An unknown type symbol raises `Cybertrain::Preview::Unsupported, "ffi_func :<name>: type :<type> is not implemented by the CRuby preview"`.
- Produces: `Cybertrain::Preview::Failure.install!` (called by `cybertrain/preview.rb`): an `at_exit` hook that, when `CYBERTRAIN_DEV_FAILURE_FILE` is set and the process ends with an exception other than `SystemExit` and `Interrupt`, writes `"<Class>: <message>\n"` and the first 10 backtrace lines to that file.

- [ ] **Step 1: Write the failing tests** in `test/cruby/preview_ffi.rb`:

```ruby
require "cybertrain/test"
require "cybertrain/preview"
require "tmpdir"

module Probe
  ffi_lib "z"
  ffi_source <<~C
    #include <string.h>
    long probe_add(long a, long b) { return a + b; }
    static int hidden(void) { return 7; }
    int probe_hidden(void) { return hidden(); }
    void probe_store(void *slot, long v) { *(long *)slot = v; }
    const char *probe_hello(void) { return "h\\xc3\\xa9llo"; }
    const char *probe_bytes(long n) { sp_ffi_bin_len = (int)n; return "a\\0b\\0c"; }
  C
  ffi_func :probe_add, [:long, :long], :long
  ffi_func :probe_hidden, [], :int
  ffi_func :probe_store, [:ptr, :long], :void
  ffi_func :probe_hello, [], :str
  ffi_func :probe_bytes, [:long], :binstr
  ffi_func :zlibVersion, [], :str, blocking: true
  ffi_const :ANSWER, 42
  ffi_read_ptr :read_ptr, 0
end

test "calls a function from ffi_source and one from ffi_lib" do
  assert_equal 5, Probe.probe_add(2, 3)
  assert_equal 7, Probe.probe_hidden
  assert Probe.zlibVersion.start_with?("1."), "zlib answers its version"
end

test "constants, malloc, read_ptr and free" do
  assert_equal 42, Probe::ANSWER
  slot = Probe.malloc(8)
  Probe.probe_store(slot, 1234)
  assert_equal 1234, Probe.read_ptr(slot)
  Probe.free(slot)
end

test ":str and :binstr results" do
  assert_equal "héllo", Probe.probe_hello
  assert_equal 3, Probe.probe_bytes(3).bytesize   # "a\0b": NULs kept, length from sp_ffi_bin_len
end

test "an unknown type is refused by name" do
  error = assert_raises("Cybertrain::Preview::Unsupported") do
    Module.new { ffi_func :x, [:wchar], :int }
  end
  assert error.message.include?("type :wchar is not implemented by the CRuby preview")
end

test "the compiled library is cached by content" do
  dir = Dir.mktmpdir("preview-ffi")
  first = Cybertrain::Preview::FFILibrary.build("int one(void){return 1;}", [], dir)
  stamp = File.mtime(first)
  assert_equal first, Cybertrain::Preview::FFILibrary.build("int one(void){return 1;}", [], dir)
  assert_equal stamp, File.mtime(first)
  assert first != Cybertrain::Preview::FFILibrary.build("int one(void){return 2;}", [], dir)
end

test "a C error carries the compiler's output" do
  error = assert_raises("Cybertrain::Preview::CompileError") do
    Cybertrain::Preview::FFILibrary.build("int broken( {", [], Dir.mktmpdir("preview-ffi"))
  end
  assert error.message.include?("error"), error.message
end
```

  And `test/cruby/preview_failure.rb`: run `ruby -I. -r cybertrain/preview -e 'raise ArgumentError, "bad"'` with `CYBERTRAIN_DEV_FAILURE_FILE` set and assert the file starts with `ArgumentError: bad`; run `-e 'exit 3'` and assert no file is written; run a script with a syntax error required from `-e` and assert the file starts with `SyntaxError:`.

  Adjust the encoding assertions of the `:str` / `:binstr` test to what Task 1 recorded, if it differs.
- [ ] **Step 2:** Write `script/test-cruby` (P13) and run `script/test-cruby test/cruby/preview_ffi.rb`. Expected: fails, `cannot load such file -- cybertrain/preview`.
- [ ] **Step 3:** Implement the four files to the Interfaces block and Task 1's record. `ffi_source` texts are collected per module and compiled at the first call of one of that module's functions (never at `ffi_func`: `sqlite_ffi.rb` declares sources after its first `ffi_func`; an unknown type is still refused at `ffi_func`); the compiled unit is prefixed with `__thread int sp_ffi_bin_len; int cybertrain_preview_bin_len(void) { return sp_ffi_bin_len; }`; symbols are looked up in the compiled library first, then in `ffi_lib`'s.
- [ ] **Step 4:** `script/test-cruby --regen test/cruby/preview_ffi.rb test/cruby/preview_failure.rb`, read the snapshots, then `script/test-cruby` — all pass. Extend the gate's snapshot check to `test/cruby/*.rb`; `ruby script/gate` green.
- [ ] **Step 5:** Commit (`preview: a Fiddle shim for the ffi_* DSL, and CRuby-only tests`).

### Task 3: Parity checks — the framework's tests and gen under CRuby

**Files:**
- Create: `script/preview-parity`, `test/cruby/parity-gaps.txt`
- Modify: `script/gate` (the gen check), `.github/workflows/ci.yml` (job `cruby-preview`), `script/ci-changes` (the job runs for `cybertrain/**`, `test/**`, `script/preview-parity`, `script/test-cruby`), `spikes/NOTES.md` ("What CRuby cannot tell you" links the gap list)

**Interfaces:**
- Produces: `script/preview-parity [test/<name>.rb …]`: for each `test/*.rb` (all by default) runs `ruby -I. -r cybertrain/preview <file>` with a 60 s timeout, and compares stdout+stderr with `<file>.expected`. A file listed in `test/cruby/parity-gaps.txt` (`<path><TAB><reason>`, `#` comments) must mismatch; a listed file that now matches fails the script (`no longer a gap: remove it from parity-gaps.txt`). Prints `N match, M known gaps, K unexpected`; exit 1 when K > 0 or a listed gap matches.

- [ ] **Step 1:** Write `script/preview-parity` with an empty gap list and run it. Expected: exit 1, listing the mismatches Task 1 counted.
- [ ] **Step 2:** For each mismatch: if the cause is the shim, fix the shim (Task 2's tests stay green, add a case there); if it is a recorded runtime difference (spikes/NOTES.md) or a test that needs `Dev::Reexec`, add it to `parity-gaps.txt` with the NOTES rule number or the reason in one line. A mismatch with no known cause is investigated before it is listed.
- [ ] **Step 3:** Add to `script/gate`: in a temporary copy of `examples/blog`, `ruby -I. -I<copy> bin/gen.rb --check` exits 0 (`ok("gen under CRuby leaves examples/blog unchanged")`). Run `ruby script/gate`. Expected: green.
- [ ] **Step 4:** Add the CI job `cruby-preview` (Ruby 3.3, no Spinel): `script/test-cruby && script/preview-parity`. Run `script/check-workflows` and `script/lint-workflows`.
- [ ] **Step 5:** Commit (`preview: the framework's tests and gen run under CRuby against the compiled snapshots`).

### Task 4: Framework — supervision variables, inherited listener, readiness, failure text, address

Spec §8 changes 1, 3, 6, 7, 8. Compiled.

**Files:**
- Create: `cybertrain/dev/supervision.rb`
- Modify: `cybertrain/dev.rb` (require it), `cybertrain/http/server.rb` (`initialize`, `bind_listener`, near lines 103–206), `cybertrain/roles.rb:84` (`fail_boot`), `cybertrain/roles/server.rb` (`http_server`, `run_server` after `srv.start`), `cybertrain/main.rb:117` (`run`)
- Test: `test/dev_supervision.rb`, `test/server.rb` (one case added), `test/main.rb` (one case added)

**Interfaces:**
- Produces: `Cybertrain::Dev::Supervision` module functions, each reading `ENV` when called: `active?(env) -> Boolean` (`env == "development"` and `CYBERTRAIN_DEV_LISTEN_FD` non-empty), `listen_fd -> Integer` (-1 when unset or not all digits), `ready_file -> String`, `state_file -> String`, `failure_file -> String` (each `""` when unset), `generation -> Integer` (0 when unset), `runtime -> String` (`"cruby"` when `RUBY_ENGINE == "ruby"`, else `"spinel"`), `mark_ready -> nil` (writes the generation into `ready_file`, no-op when `""`), `write_failure(message) -> nil` (writes the message to `failure_file`, no-op when `""`).
- Produces: `Server.new(handler, host:, port:, …, listen_fd: -1)`; with `listen_fd >= 0`, `start` listens on `TCPServer.for_fd(listen_fd)` instead of binding, with the single-owner rule `reuse_port_listener` documents, and `port` answers the configured port.
- Produces: `Roles.fail_boot(message)` also calls `Dev::Supervision.write_failure("error: #{message}")` before it exits. `cybertrain/roles.rb` must not require all of `cybertrain/dev` (production never loads it): `supervision.rb` requires nothing and is required by `roles.rb` directly.
- Produces: `./NAME dev-address` prints `"#{config.host} #{config.port}\n"` and exits 0.
- Produces: `Roles::Server#run_server` passes `listen_fd: Dev::Supervision.listen_fd` when `Dev::Supervision.active?(config.env)` (else -1) and calls `Dev::Supervision.mark_ready` right after `srv.start`.

- [ ] **Step 1: Write the failing tests.** `test/dev_supervision.rb` (CRuby-portable, no FFI):

```ruby
require "cybertrain/dev/supervision"
require "cybertrain/test"

S = Cybertrain::Dev::Supervision
DIR = "tmp/dev_supervision_test"
Dir.mkdir("tmp") unless Dir.exist?("tmp")
Dir.mkdir(DIR) unless Dir.exist?(DIR)

def with_env(pairs)
  saved = { "" => "" }
  saved.delete("")
  pairs.each { |key, value| saved[key] = ENV[key].to_s; ENV[key] = value }
  yield
  saved.each { |key, value| value.empty? ? ENV.delete(key) : ENV[key] = value }
  nil
end

test "inactive without the descriptor, and outside development" do
  ENV.delete("CYBERTRAIN_DEV_LISTEN_FD")
  assert !S.active?("development")
  assert_equal(-1, S.listen_fd)
  with_env("CYBERTRAIN_DEV_LISTEN_FD" => "7") do
    assert S.active?("development")
    assert !S.active?("production")
    assert !S.active?("test")
    assert_equal 7, S.listen_fd
  end
end

test "a descriptor that is not a number is none" do
  with_env("CYBERTRAIN_DEV_LISTEN_FD" => "7; rm") { assert_equal(-1, S.listen_fd) }
end

test "mark_ready writes the generation; write_failure writes the message" do
  with_env("CYBERTRAIN_DEV_READY_FILE" => "#{DIR}/ready", "CYBERTRAIN_DEV_FAILURE_FILE" => "#{DIR}/failure",
           "CYBERTRAIN_DEV_GENERATION" => "12") do
    S.mark_ready
    S.write_failure("error: port 3000 is in use")
    assert_equal "12", File.read("#{DIR}/ready")
    assert_equal "error: port 3000 is in use", File.read("#{DIR}/failure")
  end
end

test "without the paths both are no-ops" do
  ENV.delete("CYBERTRAIN_DEV_READY_FILE")
  ENV.delete("CYBERTRAIN_DEV_FAILURE_FILE")
  S.mark_ready
  S.write_failure("x")
  assert_equal "", S.ready_file
end

test "runtime names this runtime" do
  assert_equal(RUBY_ENGINE == "ruby" ? "cruby" : "spinel", S.runtime)
end
```

  In `test/server.rb`: a case that binds a `TCPServer` on port 0, starts a `Server` with `listen_fd:` set to its descriptor, and gets a 200 through that port. In `test/main.rb`: `dev-address` prints `127.0.0.1 3000` for a default config and is absent from `Main.usage("blog")`.
- [ ] **Step 2:** `ruby -I. test/dev_supervision.rb` — fails (`cannot load such file`).
- [ ] **Step 3:** Implement to the Interfaces block.
- [ ] **Step 4:** `spin test test/dev_supervision.rb test/server.rb test/main.rb test/main_roles.rb test/dev_application.rb test/application.rb` — pass; new snapshots through `spin test --regen` (portable) or `script/regen-snapshot` (FFI). Review the diff of `test/server.rb.expected` and `test/main.rb.expected`: only the added cases.
- [ ] **Step 5:** `script/preview-parity test/dev_supervision.rb` matches. Commit (`dev: supervision variables, an inherited listener, readiness and failure files, dev-address`).

### Task 5: Framework — the state file, build status, and the supervised role

Spec §8 changes 2 and 4. Compiled.

**Files:**
- Create: `cybertrain/dev/state_file.rb`, `cybertrain/dev/build_status.rb`
- Modify: `cybertrain/dev.rb`, `cybertrain/dev/error_page.rb` (`initialize`, `inject_banner`), `cybertrain/roles/server.rb` (`run_server`, `front_app`, new `serve_supervised`)
- Test: `test/dev_state_file.rb`, `test/dev_error_page.rb` (cases added), `test/dev_application.rb` (cases added)

**Interfaces:**
- Consumes: `Dev::Supervision` (Task 4).
- Produces: `Dev::StateSnapshot` with readers `generation -> Integer`, `serving -> String`, `build -> String`, `output -> String`; `Dev::StateFile.parse(text) -> StateSnapshot` (P4; malformed → the default snapshot); `Dev::StateFile.format(generation, serving, build, output) -> String` (the writer's side, used by the supervisor's tests to prove both ends agree); `Dev::StateFile::Reader.new(path)`, `#current -> StateSnapshot` (rereads when the file's modification time in nanoseconds or its size changed; a missing file is the default snapshot).
- Produces: `Dev::BuildStatus.new`, `#failed -> Boolean`, `#output -> String`, `#update(snapshot) -> nil` (failed when `build` is `failed` or `binary_failed`; output is the snapshot's).
- Produces: `Dev::ErrorPage.new(app, rebuilder = nil, status = nil)` (P7).
- Produces: under supervision `Roles::Server` builds no `Rebuilder`, `Watcher` or restart monitor and never calls `Dev::Reexec`; `serve_supervised(srv)` traps TERM as the production branch does (`srv.request_stop`, `Job.request_stop`) and waits. A supervised child prints no boot banner (`print_boot_banner` is skipped): the supervisor prints one for the session (Task 7). `front_app` under supervision is `HostAuthorization(ErrorPage(stack, nil, status))`; Task 8 puts the indicator around `ErrorPage`.

- [ ] **Step 1: Write the failing tests.** `test/dev_state_file.rb`:

```ruby
require "cybertrain/dev/state_file"
require "cybertrain/dev/build_status"
require "cybertrain/test"

F = Cybertrain::Dev::StateFile

test "format and parse agree" do
  s = F.parse(F.format(12, "cruby", "failed", "app/models/a.rb:3: error\nsecond line\n"))
  assert_equal 12, s.generation
  assert_equal "cruby", s.serving
  assert_equal "failed", s.build
  assert_equal "app/models/a.rb:3: error\nsecond line\n", s.output
end

test "an empty output and an output with an empty line survive" do
  assert_equal "", F.parse(F.format(1, "spinel", "ready", "")).output
  assert_equal "a\n\nb", F.parse(F.format(1, "cruby", "failed", "a\n\nb")).output
end

test "anything else is the default snapshot" do
  ["", "generation x\nserving cruby\nbuild ready\n\n", "serving cruby\n", "generation 3\nserving root\nbuild ready\n\n",
   "generation 3\nserving cruby\nbuild done\n\n"].each do |text|
    s = F.parse(text)
    assert_equal 0, s.generation
    assert_equal "", s.serving
    assert_equal "idle", s.build
    assert_equal "", s.output
  end
end

test "the reader rereads a file that changed and survives its absence" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/dev_state_file_test"
  File.delete(path) if File.exist?(path)
  reader = F::Reader.new(path)
  assert_equal 0, reader.current.generation
  File.write(path, F.format(2, "cruby", "building", ""))
  assert_equal 2, reader.current.generation
  File.write(path, F.format(3, "spinel", "ready", ""))
  assert_equal "spinel", reader.current.serving
  File.delete(path)
  assert_equal 0, reader.current.generation
end

test "build status fails for failed and binary_failed only" do
  status = Cybertrain::Dev::BuildStatus.new
  assert !status.failed
  status.update(F.parse(F.format(1, "cruby", "binary_failed", "signal 11")))
  assert status.failed
  assert_equal "signal 11", status.output
  status.update(F.parse(F.format(2, "cruby", "building", "")))
  assert !status.failed
end
```

  In `test/dev_error_page.rb`: with `ErrorPage.new(app, nil, status)` and a failed status, `/` carries the banner with the status's output, `/json` does not; with a status that is not failed, no banner. In `test/dev_application.rb`: with the supervision variables set and a state file saying `failed`, a GET through the role's `front_app` carries the banner, and no `Rebuilder` exists (`app` answers the supervised stack).
- [ ] **Step 2:** `ruby -I. test/dev_state_file.rb` — fails to load.
- [ ] **Step 3:** Implement to the Interfaces block. In `ErrorPage#inject_banner` the two sources are read side by side (`failed = (!rebuilder.nil? && rebuilder.last_failed) || (!status.nil? && status.failed)`); the existing lines for the rebuilder stay.
- [ ] **Step 4:** `spin test test/dev_state_file.rb test/dev_error_page.rb test/dev_application.rb test/application.rb test/main_roles.rb`. `git diff test/*.expected`: only added lines. `script/preview-parity test/dev_state_file.rb test/dev_error_page.rb`.
- [ ] **Step 5:** Commit (`dev: the state file, a build status for the error page, and a supervised server role`).

### Task 6: Supervisor — the state machine

Pure CRuby, no processes.

**Files:**
- Create: `cybertrain/cli/dev_server/machine.rb`
- Test: `test/cruby/dev_server_machine.rb`

**Interfaces:**
- Produces: `Cybertrain::CLI::DevServer::Machine.new(runner)` with readers `generation` (Integer, starts at 0), `serving` (`:none`, `:cruby`, `:spinel`, `:holding`), `build` (`:idle`, `:building`, `:ready`, `:failed`, `:binary_failed`), `output` (String); and events `start`, `on_change(paths)`, `on_child_ready(kind, generation)`, `on_child_exit(kind, generation, info)`, `on_build_done(generation, ok, output)`, `on_tick`, `stop`. Events for a generation that is not the current one are ignored.
- Consumes (the runner, implemented in Task 7): `run_gen -> [Boolean, String]` (blocks), `start_child(kind, generation)` with kind `:cruby` or `:binary`, `stop_child` (blocks; no-op without a child), `start_build(generation)`, `cancel_build`, `hold(title, text)`, `release_hold`, `write_state(generation, serving, build, output)` (strings as P4), `log(line)`, `build_locked? -> Boolean`, `now -> Float` (a monotonic clock, for the seconds in the log lines).
- Log lines (spec §5; `<s>` is seconds since the round began, one decimal): `=> preview: CRuby (<s>s)` when the CRuby child is ready, `=> spinel: building (log: tmp/rebuild.log)`, `=> spinel: ready in <s>s; serving the compiled binary` when the binary is ready, `=> spinel: build failed; still serving the CRuby preview (see tmp/rebuild.log)`, `=> spinel: the binary failed; serving the CRuby preview`, `Changed <paths joined by ", ">`, `=> cybertrain build in progress; the preview reloads when it finishes`.

- [ ] **Step 1: Write the failing tests** with a `FakeRunner` that records `[:name, args…]` for every call except `write_state` and `log` (kept in `states` and `lines`), with settable `gen_result` and `locked`:

```ruby
def calls_after(runner) = runner.calls.tap { runner.calls = [] }

test "start: gen, the CRuby child, the build" do
  r = FakeRunner.new; m = Machine.new(r); m.start
  assert_equal [[:run_gen], [:start_child, :cruby, 1], [:start_build, 1]], calls_after(r)
  assert_equal [1, :cruby, :building], [m.generation, m.serving, m.build]
  assert_equal [1, "cruby", "building", ""], r.states.last
end

test "a change: cancel, gen, stop, CRuby child, build (P12)" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_change(["app/models/article.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  assert r.lines.include?("Changed app/models/article.rb")
end

test "build ok at the current generation hands the port to the binary" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_build_done(1, true, "")
  assert_equal [[:stop_child], [:start_child, :binary, 1]], calls_after(r)
  assert_equal [:spinel, :ready], [m.serving, m.build]
end

test "a stale build is discarded" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_change(["a.rb"]); calls_after(r)
  m.on_build_done(1, true, "")
  assert_equal [], calls_after(r)
  assert_equal [:cruby, :building], [m.serving, m.build]
end

test "a change while the binary serves goes back to CRuby" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, ""); calls_after(r)
  m.on_change(["a.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
end

test "a failed build keeps CRuby and publishes the output" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_build_done(1, false, "a.rb:3: error")
  assert_equal [], calls_after(r)
  assert_equal [1, "cruby", "failed", "a.rb:3: error"], r.states.last
end

test "gen fails: stop, hold, no build; the next change leaves holding" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.gen_result = [false, "config/routes.rb:9: no such controller"]
  m.on_change(["config/routes.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:hold, "gen failed", "config/routes.rb:9: no such controller"]], calls_after(r)
  assert_equal [:holding, :idle], [m.serving, m.build]
  r.gen_result = [true, ""]
  m.on_change(["config/routes.rb"])
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:release_hold], [:start_child, :cruby, 3], [:start_build, 3]], calls_after(r)
end

test "the CRuby child dies: hold; a build that then succeeds takes the port" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  m.on_child_exit(:cruby, 1, "SyntaxError: app/models/a.rb:3: unexpected end")
  assert_equal [[:hold, "the CRuby preview stopped", "SyntaxError: app/models/a.rb:3: unexpected end"]], calls_after(r)
  assert_equal [:holding, :building], [m.serving, m.build]
  m.on_build_done(1, true, "")
  assert_equal [[:stop_child], [:release_hold], [:start_child, :binary, 1]], calls_after(r)
end

test "the binary dies, before or after ready: CRuby again, no retry" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, ""); calls_after(r)
  m.on_child_exit(:binary, 1, "signal 11 (SEGV)")
  assert_equal [[:start_child, :cruby, 1]], calls_after(r)
  assert_equal [1, "cruby", "binary_failed", "signal 11 (SEGV)"], r.states.last
  m.on_tick
  assert_equal [], calls_after(r)
end

test "both dead: holding with what is known of each" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_build_done(1, true, "")
  m.on_child_exit(:binary, 1, "signal 11 (SEGV)"); calls_after(r)
  m.on_child_exit(:cruby, 1, "RuntimeError: boom")
  held = calls_after(r).last
  assert_equal :hold, held[0]
  assert held[2].include?("RuntimeError: boom") && held[2].include?("signal 11 (SEGV)")
end

test "locked by cybertrain build: nothing runs, then the pending change is handled once" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_change(["a.rb"]); m.on_change(["b.rb"]); m.on_tick
  assert_equal [], calls_after(r)
  assert_equal 1, r.lines.count("=> cybertrain build in progress; the preview reloads when it finishes")
  r.locked = false
  m.on_tick
  assert_equal [[:cancel_build], [:run_gen], [:stop_child], [:start_child, :cruby, 2], [:start_build, 2]], calls_after(r)
  m.on_tick
  assert_equal [], calls_after(r)
end

test "a build that finishes while locked does not take the port until the lock is gone" do
  r = FakeRunner.new; m = Machine.new(r); m.start; calls_after(r)
  r.locked = true
  m.on_build_done(1, true, "")
  assert_equal [], calls_after(r)
  r.locked = false
  m.on_tick
  assert_equal [[:stop_child], [:start_child, :binary, 1]], calls_after(r)
end

test "events of another generation are ignored; stop ends everything" do
  r = FakeRunner.new; m = Machine.new(r); m.start; m.on_change(["a.rb"]); calls_after(r)
  m.on_child_ready(:cruby, 1); m.on_child_exit(:cruby, 1, "late")
  assert_equal [], calls_after(r)
  m.stop
  assert_equal [[:cancel_build], [:stop_child], [:release_hold]], calls_after(r)
end
```

- [ ] **Step 2:** `script/test-cruby test/cruby/dev_server_machine.rb` — fails to load.
- [ ] **Step 3:** Implement `Machine` to the tests and the Interfaces block. `release_hold` is called exactly when leaving `:holding`, and always by `stop`.
- [ ] **Step 4:** `script/test-cruby --regen test/cruby/dev_server_machine.rb`, read the snapshot, `script/test-cruby` — pass.
- [ ] **Step 5:** Commit (`dev server: the supervisor's state machine`).

### Task 7: Supervisor — processes, the driver, the holding page, CLI wiring

**Files:**
- Create: `cybertrain/cli/dev_server.rb` (startup and the driver loop), `cybertrain/cli/dev_server/processes.rb` (the runner), `cybertrain/cli/dev_server/holding.rb`, `script/preview-e2e`
- Modify: `exe/cybertrain` (P8), `cybertrain/cli.rb` (`run_server` drops `--spinel`; `USAGE`), `cybertrain.gemspec` and the gem stage of `playground/Dockerfile` (the new CLI files; not `cybertrain/dev/*.rb`, which the supervisor loads from the application's framework, P21), `playground/playground-server` (`cybertrain server --spinel`, until Task 9), `.github/workflows/ci.yml` (run `script/preview-e2e` where `examples/blog` is built)
- Test: `test/cruby/dev_server_processes.rb`, `test/cruby/dev_server_holding.rb`, `test/cli_build.rb` or the test that covers `run_server` (`--spinel` accepted)

**Interfaces:**
- Consumes: `Machine` (Task 6), `Dev::StateFile.format` (Task 5), `Dev::Watcher`, `Dev::WATCHED`, `Dev::IGNORED`, `Build.app_name`, `Build.port?`, `Build.lock_path`, `Toolchain.ensure!`, the children's contract (Task 4, P1, P9).
- Produces: `Cybertrain::CLI::DevServer.run(argv) -> Integer` (startup of spec §6: application name, `Toolchain.ensure!`, load path from `spin flags`, P14, `dev-address`, bind, then `Machine#start` and the loop; `1` with the error when the address command fails, naming `--spinel`).
- Produces: at startup the supervisor prints, once, `=> Booting cybertrain <version>`, `=> preview: CRuby <RUBY_VERSION>` and `* Listening on http://<host>:<port>`; children print no boot banner (Task 5).
- Produces: `start_build` runs `spin build NAME -- --incremental` with stdout and stderr to `tmp/rebuild.log` in a process group of its own; when the log contains `unknown option '--incremental'` (the text `Dev::Rebuilder::UNSUPPORTED_INCREMENTAL` holds) it runs the build again without the flag and keeps to that for the rest of the process. gen is not run by spin.
- Produces: `DevServer.load_path(flags_output) -> Array<String>` (`"--strict-require -I /a -I /b"` → `["/a", "/b"]`).
- Produces: `DevServer::Processes.new(root:, name:, port:, load_path:, listener:, out:, err:)` implementing the runner of Task 6, plus `poll(machine) -> nil` (one tick: reaps the child and the build, notices the ready file, enforces P11, answers held requests, calls the machine's events).
- Produces: `DevServer::Holding.page(title, text, waiting_for) -> String` (a complete HTTP/1.1 response: `503`, `Retry-After: 1`, `Connection: close`, HTML with the title, the text escaped in a `<pre>`, the line `Waiting for: <waiting_for>`, the refresh meta, and `cybertrain server --spinel runs the compiled loop only.`).
- The watcher's block hands the paths to the driver loop and returns only after that round's gen has run, so `Dev::Watcher` absorbs the rewritten `gen/**` as it does today (`generated: ["gen/"]`).

- [ ] **Step 1: Write the failing tests.** `test/cruby/dev_server_holding.rb`: the page starts with `HTTP/1.1 503`, has `Retry-After: 1`, escapes `<script>` in the text, and its `Content-Length` equals the body's bytesize. `test/cruby/dev_server_processes.rb`, with tiny Ruby scripts written into a temporary directory standing in for the children (the runner takes the child commands from an overridable method):
  - `load_path` parses `spin flags` output, including a path with a space quoted by spin (check the real quoting with `spin flags` in a directory whose name has a space).
  - A child that writes its ready file: `poll` calls `on_child_ready(kind, generation)` once.
  - A child that exits 1 after writing `error: port 3000 is in use` to the failure file: `on_child_exit` receives that text; one that writes only to STDERR: the STDERR tail; one that is killed by a signal: `signal 9 (KILL)`.
  - A child that never becomes ready: with the ready bound overridden to 0.3 s, `on_child_exit(kind, generation, "did not become ready in 0.3 s")` and the process is gone.
  - **TERM then KILL** (Review Focus 3): a child that traps TERM and sleeps; with the grace overridden to 0.3 s, `stop_child` returns within 1 s and the process is gone.
  - A child the runner stopped itself is not reported through `on_child_exit`.
  - `hold` then a connection to the listener gets the 503 page; after `release_hold` the supervisor no longer accepts (a connection stays unanswered until a child accepts it).
  - A stand-in `spin` that prints `unknown option '--incremental'` and exits 1 when given the flag: `on_build_done` is called once, with the result of the second run, and the next `start_build` passes no flag.
  - `cancel_build` kills the build's whole process group (the stand-in build spawns a grandchild; both are gone).
  - `write_state` leaves a file `Dev::StateFile.parse` reads back, and never a partial one (the file is renamed into place).
  - **Port in use** (Review Focus 4): `DevServer.run` with the port taken prints `error:` with today's `PortInUse` wording and returns 1 without starting a child.
  - **Leftovers** (Review Focus 2, P14): with a `child.pid` naming a live stand-in child of this application, startup stops it; with a `supervisor.pid` naming a live process, startup refuses.
- [ ] **Step 2:** `script/test-cruby test/cruby/dev_server_processes.rb` — fails to load.
- [ ] **Step 3:** Implement the three files, `exe/cybertrain` and the `--spinel` flag. The driver is one thread: `IO.select` on the listener (only while holding) and the STDERR pipes with a 50 ms timeout, then `Processes#poll`, then `machine.on_tick`. INT and TERM set a flag; the loop calls `machine.stop`, removes P2's files and returns 0 (130 for INT).
- [ ] **Step 4:** `script/test-cruby` — pass. `ruby script/gate` — green (the gemspec list, the playground COPY list, the CLI loading under CRuby). `spin build` of the native CLI still compiles: `spin build cybertrain` in the repository root.
- [ ] **Step 5: Write `script/preview-e2e`** (run from the repository root; works in a temporary `cp -a` of `examples/blog` with `spin.toml` pointing at the checkout; prints one `ok`/`FAIL` line per step; exit 1 on any FAIL):
  1. `cybertrain server PORT` starts; `GET /articles` answers 200 with `X-Cybertrain-Runtime: cruby` within 5 s.
  2. Within 300 s (P20) a `GET` answers with `X-Cybertrain-Runtime: spinel`; the log has `=> spinel: ready`.
  3. Append `validates :body, length: { minimum: 10 }` to `app/models/article.rb`: within **1 s** of the save a `POST /articles` with a short body answers 422 from `cruby`.
  4. Later the same `POST` answers 422 from `spinel`.
  5. (Review Focus 1) Two saves 0.3 s apart, the second reverting the first: the next `spinel` response behaves as the reverted source, and the log shows one `=> spinel: ready` after the second save.
  6. (Review Focus 3) With an open `GET` on the stream endpoint, a save is answered by `cruby` within 12 s.
  7. (Review Focus 5) While a fake `tmp/cybertrain-build.lock` holding a live PID exists, a save changes nothing and the log says so once; removing the lock applies it.
  8. (Review Focus 2) `kill -9` the supervisor; `cybertrain server PORT` again answers 200 within 5 s.
  9. A syntax error in a model: a `GET` answers 503 naming `SyntaxError` within 2 s; fixing it brings 200 back.
  10. A source that CRuby accepts and Spinel refuses (take one from spikes/NOTES.md, for example a computed `send`): pages carry the build-failed banner and the header stays `cruby`.
  11. Ctrl-C (INT): the process exits within 12 s, the port is free, `tmp/cybertrain-dev/state` is gone.
  12. (spec goal 4) From step 1 to step 5 a background loop requests `GET /up` every 50 ms: no request ends in a refused or reset connection (a 503 from the holding page would also fail here; none is expected in those steps).
- [ ] **Step 6:** Run `script/preview-e2e`. Expected: every line `ok`. Record the measured time of step 3 in the commit body. Wire it into `ci.yml` after the blog's build, and check `script/ci-changes` runs it for `cybertrain/cli/**`, `cybertrain/preview/**`, `cybertrain/dev/**`, `cybertrain/roles/**`.
- [ ] **Step 7:** Commit (`cybertrain server: a CRuby preview with a handover to the compiled binary`).

### Task 8: The indicator, the header, the fallbacks and `doctor`

Spec §8 change 5 and §10. The middleware is compiled.

**Files:**
- Create: `cybertrain/dev/indicator.rb`
- Modify: `cybertrain/dev.rb`, `cybertrain/roles/server.rb` (`front_app` under supervision), `cybertrain/cli/dev_server.rb` (fallbacks), `cybertrain/cli/toolchain.rb:749` (`doctor`)
- Test: `test/dev_indicator.rb`, `test/dev_application.rb` (one case), `test/cli_toolchain.rb`, `test/cruby/dev_server_processes.rb` (fallback cases)

**Interfaces:**
- Consumes: `Dev::StateFile::Reader`, `Dev::BuildStatus`, `Dev::Supervision` (Tasks 4, 5).
- Produces: `Dev::Indicator.text(page_runtime, page_generation, snapshot) -> String`:

  | Condition, first match | Text |
  | --- | --- |
  | `snapshot.generation > page_generation` | `Source changed — reload` |
  | `page_runtime == "spinel"` | `Spinel` |
  | `snapshot.build == "building"` | `CRuby preview · Spinel building…` |
  | `snapshot.build == "ready"` | `Spinel ready — reload` |
  | `snapshot.build == "failed"` | `CRuby preview · Spinel build failed` |
  | `snapshot.build == "binary_failed"` | `CRuby preview · Spinel binary failed` |
  | otherwise | `CRuby preview` |

- Produces: `Dev::Indicator.new(app, reader, status, runtime, generation, nonce_directives)` (a `Middleware`): refreshes `status` from `reader.current` before calling the app; answers P5's two paths itself; sets `X-Cybertrain-Runtime` on every response; inserts P6's markup. `front_app` under supervision becomes `HostAuthorization(Indicator(ErrorPage(stack, nil, status), …))`.
- Produces: fallbacks in `DevServer.run`, each printing one line and returning `CLI.run(argv)`: `preview unavailable: Ruby cannot load fiddle (cybertrain doctor has the details); running the compiled loop` and `preview unavailable: this application's cybertrain (<dir>) has no cybertrain/preview.rb; running the compiled loop`.
- Produces: `doctor` prints a `fiddle` line through `report` (`the fiddle library loads (the CRuby preview needs it)` / `ruby cannot load fiddle: cybertrain server runs the compiled loop only`); the exit code does not depend on it.

- [ ] **Step 1: Write the failing tests.** `test/dev_indicator.rb` (portable): the seven rows of `text`, in order, including `generation` winning over everything; a 200 HTML response gets the div before `</body>` with `data-runtime` and `data-generation`, and exactly one indicator after two passes through nested middleware; a JSON response, a 204, a 302 and an empty body get the header and no markup; a body without `</body>` gets the markup at its end; with nonce directives the script tag has `nonce="…"` equal to `ctx.csp_nonce`, without them no `nonce` attribute; `GET /__cybertrain/dev/state?runtime=cruby&generation=3` answers the JSON of P5 with the text for that page and `Cache-Control: no-store`, and does not call the inner app; a garbled `generation` parameter is read as 0; `GET /__cybertrain/dev/indicator.js` answers `text/javascript`; with a failed status, the build-failed banner (after `<body>`) and the indicator (before `</body>`) are both present. In `test/cli_toolchain.rb`: `doctor` has the `fiddle` line. In `test/cruby/dev_server_processes.rb`: both fallbacks print their line and call the compiled loop (stub `CLI.run`).
- [ ] **Step 2:** `ruby -I. test/dev_indicator.rb` — fails to load.
- [ ] **Step 3:** Implement. The JSON is written by hand from the snapshot's fields and the text (escape `"` and `\`); the query is read with the framework's `Query`.
- [ ] **Step 4:** `spin test test/dev_indicator.rb test/dev_application.rb test/dev_error_page.rb test/cli_toolchain.rb test/application.rb`; `script/preview-parity test/dev_indicator.rb`; `script/test-cruby`. `git diff test/cli_toolchain.rb.expected`: the `fiddle` line only.
- [ ] **Step 5:** Add to `script/preview-e2e`: step 1's page contains `CRuby preview · Spinel building…`; after step 2, `GET /__cybertrain/dev/state?runtime=cruby&generation=1` has `"text":"Spinel ready — reload"`; an application with `c.content_security_policy` set and nonce directives still loads the script (the tag carries the response's nonce). Run it. Expected: every line `ok`.
- [ ] **Step 6:** Commit (`dev: the runtime indicator and header; doctor and the fallbacks know the preview`).

### Task 9: The playground

Spec §12.

**Files:**
- Modify: `playground/playground-server`, `playground/Dockerfile`, `playground/smoke.sh`, `playground/PLAYGROUND.md`, `playground/README.md`, `playground/profile.sh` if it names the rebuild, `site/playground.html` and `site/{ja,fr,ru,zh}/playground.html` where they describe the wait

- [ ] **Step 1:** Rewrite the checks in `playground/smoke.sh` first (they fail against the current image): A9 becomes "a model edit answers 422 for a short body with `X-Cybertrain-Runtime: cruby` within 10 s, and with `spinel` afterwards", no longer reading `Build succeeded`; D2 becomes "one supervisor and one child run"; D4's "already starting while it compiles" half is restated for a supervisor that listens at once; a new check: "the first start runs no C compiler" (no `cc`/`gcc` process during startup, and `tmp/cybertrain-dev/ffi/*.so` keeps the image's mtime) beside A3 and E1, which keep their wording; a new check that `cybertrain doctor` prints the `fiddle` line as ok.
- [ ] **Step 2:** In the image: after the blog's full build, run `ruby -I<framework> -I. -r cybertrain/preview -e 'require "cybertrain"; puts Cybertrain::Preview.warm!'` in the blog so the shim's libraries are in `tmp/cybertrain-dev/ffi/`; make sure `fiddle` loads (`ruby -e 'require "fiddle"'` in the image build, adding the distribution's package if it is separate).
- [ ] **Step 3:** `playground-server`: remove `--spinel`; rewrite the process patterns (`pgrep`) and the "already starting" branch for the supervisor; the banner reads: `Views reload on the next request. A Ruby change shows at once, served by CRuby; the compiled binary takes over when its build finishes (the corner of the page says which one you are looking at).`
- [ ] **Step 4:** Build the image and run `playground/smoke.sh` as its README says. Expected: every check passes. Revisit the suite's time budget in `README.md` with the measured numbers.
- [ ] **Step 5:** Rewrite the visitor's texts: step 2 of `PLAYGROUND.md` (the edit shows at once; what the corner indicator says; the preview is CRuby and the binary follows), "Start a fresh app" (the first `cybertrain server` of a new app serves from CRuby while the first build runs), `playground/README.md` (measurements, limits, why `files.autoSave` stays off: a save still starts a build), and the site pages with their translations. `ruby script/gate` (it runs `script/check-site-i18n`).
- [ ] **Step 6:** Commit (`playground: the CRuby preview, with nothing compiled at the first start`).

### Task 10: Documentation and the design record

Spec §1 and §14.

**Files:**
- Modify: `docs/design.md` (a new record after the last one, numbered next: context, decision, what was rejected — approaches A and B, the `sqlite3` gem, in-process reloading, start-then-stop — and consequences; principle 5 and the "running on CRuby" line of section 8 reworded as spec §1 says; D12 marked as the `--spinel` path), `docs/performance-next.md` (the rejected line marked superseded with the date and the record's number), `docs/guide/how-it-works.md` ("The development loop", the Rails table row "Editing code") and `docs/guide/install.md` (requirements, `doctor`, the `cybertrain` command) with `docs/guide/{ja,fr,ru,zh}/` following, `docs/guide/tutorial.md` and translations where a step describes saving a Ruby file, `CONTRIBUTING.md` and `spikes/NOTES.md` ("a CRuby pass is not acceptance" also names the preview, and links `test/cruby/parity-gaps.txt`), `README.md` (quick start comment for `cybertrain server`, the documentation table), `cybertrain/cli.rb` `USAGE` if not done in Task 7, `cybertrain/cli/templates.rb` where a generated file describes the loop

- [ ] **Step 1:** Write the design record and the three rewordings. The record states spec §11 ("What the preview does not show") in full.
- [ ] **Step 2:** Rewrite "The development loop" in `how-it-works.md`: the supervisor, the two children, the handover, the indicator's five texts, HOLDING, `--spinel`, what the preview does not show. Update the Rails table row to: `Ruby changes show at once from a CRuby preview; the compiled binary takes the port when its build finishes (cybertrain server)`.
- [ ] **Step 3:** Update the translations; `script/check-guide-i18n` and `script/check-docs-i18n` pass (the gate runs both). Run `script/guide-pages` if the site's guide pages are generated from these.
- [ ] **Step 4:** `ruby script/gate`, `script/api-docs` clean (new public YARD comments on `Dev::Supervision`, `Dev::Indicator` are `@api private`).
- [ ] **Step 5:** Final check of the whole branch: `script/test-shard 0 1` (the whole compiled suite), `script/test-cruby`, `script/preview-parity`, `script/preview-e2e`, `cd examples/blog && spin run gen -- --check`. All green; say so with the output in the pull request, checking each line of its template.
- [ ] **Step 6:** Commit (`docs: the CRuby preview, and the design record that withdraws the earlier rejection`).
