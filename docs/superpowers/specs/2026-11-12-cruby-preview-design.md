# A CRuby preview in the development loop

Date: 2026-11-12. Status: approved by the maintainer on 2026-11-12 (the
reversal, the approach, the page indicator and the playground were decided
in conversation; the calls marked **(call)** are the author's, listed
again in section 15, and were approved with the document). The plan is
docs/superpowers/plans/2026-11-12-cruby-preview-plan.md.

## 0. Intent

Editing one Ruby file and not seeing the result for about 8 seconds is the
worst part of working on a CyberTrain application. The maintainer's words:
the development experience was too bad to keep, so the earlier restriction
is withdrawn and a preview on CRuby is allowed.

After this work, `cybertrain server` answers an edit from CRuby in well
under a second, builds the Spinel binary in the background, and hands the
port to the binary when the build is done. The page says which runtime
rendered it and whether the compiled binary is ready.

Production is untouched: `cybertrain build`, the binary and every role it
runs stay on Spinel.

## 1. What this reverses

Three records said no to this. All three are withdrawn by a new design
record (D79, or the next free number when this merges):

- docs/performance-next.md, "What was tried and rejected": "An interpreted
  development mode on CRuby: it hides the Spinel differences a developer
  most needs to see, and needs a shim for every `ffi_func`."
- docs/design.md section 3, principle 5: "Keep application execution and
  generation on Spinel." It becomes: production execution stays on Spinel;
  in development the application and `gen` may also run under CRuby as a
  preview, which is never acceptance.
- docs/design.md section 8: "running on CRuby" in the list of what was
  left out. It becomes "running on CRuby in production".

What stays true, and must stay written (CONTRIBUTING.md, spikes/NOTES.md
"What CRuby cannot tell you"): **a CRuby pass is not acceptance.** The
preview shows logic early; the compiled binary and `spin test` decide.

## 2. Measurements behind the design (2026-11-12, this repository)

| What | Time |
| --- | --- |
| One edit in today's loop on examples/blog (performance-next.md, 2026-11-05) | about 8 s: gen 3.3 s, Spinel analysis 3.9 s, C compile and link 0.75 s |
| `ruby bin/gen.rb --check` in examples/blog under CRuby 3.3.6 | 0.19 s, exit 0 |
| CRuby loading `cybertrain`, `config/app`, `gen/app`, `gen/migrations` of the blog, with the FFI DSL stubbed to no-ops | 0.18 s |
| `spin flags` in the blog (prints `--strict-require -I <framework> -I <app>`) | 0.004 s |

The FFI surface is three files: `cybertrain/db/sqlite_ffi.rb` (33
`ffi_func`, 4 `ffi_source`, 14 `ffi_const`, 1 `ffi_read_ptr`),
`cybertrain/http/gzip_ffi.rb` (10 `ffi_func`, 1 `ffi_source`, 1
`ffi_read_ptr`) and `cybertrain/dev/reexec.rb` (1 `ffi_func`, not loaded
under supervision). Types used: `:ptr :int :long :size_t :double :str
:void :binstr`. Callers also use the module functions `malloc` and `free`
that Spinel gives an FFI module (`SQLite3.malloc(8)`, `GzipFFI.free(out)`).
Without a shim the server stops at the first `ffi_lib`
(`cybertrain/http/gzip_ffi.rb:38`).

Measured afterwards by the spike of section 13 (2026-11-12, recorded in
spikes/NOTES.md, "CRuby preview spike"): examples/blog answers `GET` and
`POST` under CRuby with no change to the framework, the first 200 comes
0.19 to 0.31 s after the process starts, and CRuby gen leaves `gen/`
unchanged. Not measured there: the compiled binary's STDERR through a
pipe, and a file edited while the preview serves.

## 3. Goals, non-goals, anti-goals

**Goals**

1. After a save, the next request is answered by the new code in under a
   second on examples/blog (target: 0.5 s).
2. The compiled binary takes the port over without the developer doing
   anything, and only ever a binary built from the sources as they are now.
3. Under the supervisor, every HTML page shows which runtime rendered it
   and the state of the compiled build, and every response carries the
   runtime in a header. Today's loop gets neither (goal 6).
4. No request is refused or reset by a switch.
5. The framework's FFI files are not rewritten for CRuby: one shim
   implements the DSL they already use.
6. Today's loop remains available unchanged.
7. The playground runs the preview: a visitor meets the development
   experience a developer has (section 12).

**Non-goals**

- Running tests under CRuby as acceptance, `cybertrain test` on CRuby, or
  changing where `.expected` snapshots come from.
- A CRuby console (`eval`), CRuby backtraces on the development error
  page, live reload of the browser. Each is a later, separate decision.
- Comparing the two runtimes' responses automatically.
- Windows; Ruby without `fiddle`.
- The native CLI built by `spin install` (`bin/cybertrain.rb`): it keeps
  today's loop.
- Listening on an inherited socket in production (socket activation).

**Anti-goals** (failure even if it works)

- The preview being taken for the real thing: a page with no sign of which
  runtime made it, or a doc that lets "works in the preview" read as done.
- A second code path for the database or for requests that only CRuby
  runs. The preview runs the same framework files; the shim is below them.
- A gem dependency. The preview uses CRuby's standard library and the C
  toolchain the installation already requires.
- The preview changing what a production binary does.

## 4. Approaches

Common to all three: the Fiddle shim (section 7), reload by restarting a
process (in-process reloading by removing constants was dropped: fragile,
and a restart costs 0.4 s), and `gen` under CRuby.

| | What | Trade-off |
| --- | --- | --- |
| A | `cybertrain server` always serves from CRuby; the Spinel build runs in the background as a check and its failure shows as the banner | Instant; compile errors still surface by themselves; runtime differences are never served |
| B | A separate `cybertrain preview` command, CRuby only; `cybertrain server` unchanged | Smallest; nothing tells the developer that code does not compile until they run the other command |
| **C** | CRuby answers at once; when the Spinel build finishes, the binary takes the port | The developer ends on the real runtime; needs a supervisor that hands one port between two runtimes, and a way to say which one answered |

The author recommended A. **The maintainer chose C**: confirmation on the
real runtime should arrive without asking for it. For "how does the
developer learn of the switch" the maintainer chose a small indicator on
the page that changes to "Spinel ready — reload" (over header-and-terminal
only, and over reloading the page automatically, which loses a form being
filled in).

Dropped before the table: an adapter over the `sqlite3` gem (a gem, and a
second database path); answering from both runtimes and diffing (twice the
side effects).

## 5. What the developer sees

```
$ cybertrain server
=> Booting cybertrain 0.5.0
=> preview: CRuby 3.3.6
* Listening on http://127.0.0.1:3000
=> spinel: building (log: tmp/rebuild.log)
=> spinel: ready in 8.1s; serving the compiled binary
Changed app/models/article.rb
=> preview: CRuby (0.4s)
=> spinel: building
=> spinel: build failed; still serving the CRuby preview (see tmp/rebuild.log)
```

On every HTML page in development, a fixed corner indicator, one line:

| State | Text |
| --- | --- |
| Page rendered by CRuby, build running | `CRuby preview · Spinel building…` |
| Page rendered by CRuby, binary now serving | `Spinel ready — reload` |
| Page rendered by CRuby, build failed | `CRuby preview · Spinel build failed` (and today's banner with the compiler output) |
| Page rendered by CRuby, the binary did not start or exited | `CRuby preview · Spinel binary failed` (and the banner, with what the binary reported) |
| Page rendered by the binary, nothing changed since | `Spinel` |
| Sources changed after this page was rendered | `Source changed — reload` |

The text is written into the HTML by the server, so it is right without
JavaScript; a small script keeps it current. The exact wording and look
are the builder's, within "one quiet line in a corner, never over the
build-failed banner".

Every response under the supervisor carries `X-Cybertrain-Runtime: cruby`
or `spinel`.

Flags: `cybertrain server --spinel` runs today's loop (`spin run gen`,
`spin run NAME`: the binary watches, rebuilds and re-execs itself) **(call)**.
`spin run NAME` typed directly does the same, as today.

## 6. The supervisor

`cybertrain server` (the gem CLI, CRuby) becomes a supervisor. It owns the
listening socket for its whole life and runs one child at a time on it.

**Startup**

1. Make sure the pinned Spinel is there (`Toolchain.ensure!`, as today).
2. Find the load path: `spin flags`, taking its `-I` directories.
3. If the framework that resolves has no `cybertrain/preview/` or no
   `cybertrain/dev/supervision.rb` (an application pinned to an older
   release), say so in one line and run today's loop. Otherwise put the
   `-I` directories on `$LOAD_PATH` ahead of the gem's and load the
   framework's `cybertrain/dev/supervision.rb`, `state_file.rb`,
   `watcher.rb` and `watched.rb` from there: the gem ships none of them,
   so the supervisor and its children share one definition of the state
   file and the supervision variables, the application's framework's.
4. Learn the address: the port argument if given, else ask the
   application under CRuby (a new internal command of `Main` that prints
   host and port from the loaded config) **(call)**. If the application
   cannot be loaded under CRuby here, print the error and exit 1, naming
   `--spinel`.
5. Bind the socket. Run gen under CRuby. Start the CRuby child. Start the
   Spinel build.

**States** (one generation counter, incremented on every detected change)

```
            change                    build ok (same generation)
  ┌──────────────────────┐          ┌──────────────────────────┐
  ▼                      │          │                          ▼
PREVIEW ── build ──► PREVIEW+BUILDING ── build failed ──► PREVIEW (failed)
  ▲                      │                                     │
  │   change: cancel the build, gen, restart CRuby, build again │
  └──────────────────────┴──────────── change ◄── COMPILED ◄───┘
HOLDING: gen failed, or the CRuby child could not boot.
```

- **A change** (the same watch list as today, `Dev::WATCHED` minus
  `Dev::IGNORED`; views stay out, both runtimes reread them): kill a
  running Spinel build, run gen under CRuby, stop the current child,
  start a CRuby child, start a new build. Changes that arrive while this
  runs coalesce into one more round.
- **Build succeeded** and the generation has not moved: stop the CRuby
  child, start `build/bin/NAME` on the socket. A build whose generation is
  stale is discarded.
- **Build failed**: the CRuby child keeps serving; the state file carries
  the compiler output and the pages show today's banner.
- **gen failed, or the CRuby child exits before it is ready**: HOLDING.
  The supervisor itself answers every request with a 503 page that shows
  the error (gen's output, or what is known about the child, below: a
  SyntaxError arrives here in a fraction of a second) and says what it is waiting for. If gen
  succeeded the Spinel build still runs, and a successful build takes the
  port; otherwise the next change leaves HOLDING.
- **The compiled child does not become ready, or exits after it was
  serving** (a crash only Spinel has): this is the kind of difference
  approach C exists to show, so it is reported as loudly as a failed
  build and never retried by itself. The supervisor starts a CRuby child
  again so that work continues, and the state file records "binary
  failed" with what is known (below); pages show the banner and the
  indicator row for it. The next change builds and tries the binary
  again **(call)**.
- **The CRuby child exits after it was serving**: HOLDING with what is
  known; a successful build still takes the port, and the next change
  leaves HOLDING.
- **`cybertrain build` holds `tmp/cybertrain-build.lock`**: the supervisor
  neither runs gen nor restarts a child (that build fills `gen/views.rb`,
  and a child booted on it would think it is production). It keeps the
  current child, says so once, and handles the pending change when the
  lock is gone **(call)**. The stale-lock rule is `Dev::Rebuilder`'s.

**Handover: stop, then start** **(call)**. The supervisor sends TERM to
the old child, waits for it to drain and exit (the existing TERM path:
`Server#request_stop`, `Job.request_stop`), then starts the new child. The
socket stays open in the supervisor, so connections made in between wait
in the kernel's backlog and are answered by the new child; nothing is
refused. This was preferred over "start the new one first, then stop the
old" because overlapping children would both run the job threads, the
scheduler, the stream poller and the WebSocket feeds, and feeds would hold
two connections to a third party. The pause is the drain plus the boot:
about 0.2 s into CRuby (gen runs while the old child drains), a few
milliseconds into the binary. A child that has not exited after a bounded
wait is killed; the bound is the builder's.

**Children**

| | CRuby child | Compiled child |
| --- | --- | --- |
| Command | `ruby -I <dirs from spin flags> -r cybertrain/preview bin/NAME.rb server` | `build/bin/NAME server` |
| Environment | `CYBERTRAIN_ENV=development` unless set, and the supervision variables below | the same |

Supervision variables (names are the builder's; these are the meanings):
the number of the inherited listening descriptor; a path the child creates
once its listener is accepting (readiness: a file, because `File.write`
behaves the same on both runtimes; children keep the supervisor's STDOUT
so log lines are not delayed by a pipe) **(call)**; the path of
the state file; the generation the child was started for; a path for a
boot failure's text.

**What the supervisor knows about a dead child**, in this order: the
failure file, the tail of the child's STDERR, the exit status or signal.
The failure file is written by `Roles.fail_boot` (which prints
`error: ...` on STDOUT and exits 1 today, `cybertrain/roles.rb`) when the
variable is set, and by the preview's boot file under CRuby for an
exception that ends the process (class, message, the first lines of the
backtrace: a SyntaxError in an application file lands here). STDERR is
piped and copied to the terminal as it arrives, STDOUT stays the
terminal itself; if the spike finds that piping STDERR delays it on
either runtime, the pipe goes and the page shows the failure file or the
exit status and points at the terminal **(call)**.

**Spinel build**: `spin build NAME -- --incremental`, falling back to no
flag exactly as `Dev::Rebuilder` does, output to `tmp/rebuild.log`. Gen is
not compiled or run by spin here: the CRuby gen has already written
`gen/`. That removes gen's 3.3 s from the build as well.

**State file** (`tmp/` in the application; written whole and renamed into
place): generation, which runtime is serving, build state (`building`,
`ready`, `failed`, `binary failed`), and the output that goes with a
failure (the compiler's, or what is known about the dead binary). It is the only
channel from the supervisor to a child.

**Stopping**: Ctrl-C, TERM or HUP stops the build, stops the child with
TERM, closes the socket, removes the state and readiness files and the
PID files (`tmp/cybertrain-dev/supervisor.pid`, `child.pid`, and
`build.pid`, the build's process group). A supervisor killed outright
leaves them behind; the next one stops the child and the build they name
when they are this application's, before it binds the socket.

**Where the code lives**: the supervisor is CRuby-only (descriptor
inheritance in `spawn`, `Process.wait`, signals). `cybertrain/cli.rb` is
also compiled by Spinel for the native CLI, so the supervisor must be in
files that only `exe/cybertrain` loads, and be listed in
`cybertrain.gemspec` (the gate checks the list). The framework's
`cybertrain/dev/*.rb` files it uses are not in the gem: it loads them from
the application's framework (startup, step 3). Its decisions (the state
machine: what to do on change, build result, child exit, lock) are a
plain object that takes a process runner, as `Build.run` takes a `Runner`,
so they are tested without processes.

## 7. The FFI shim

`cybertrain/preview/` in the framework package (so it always matches the
framework version the application resolves; it is never required by
`cybertrain.rb`, so Spinel never compiles it). `-r cybertrain/preview`
loads it before the application.

It defines, for any module, what the three FFI files call:

- `ffi_lib name`: the library to open (`libsqlite3`, `libz`), by the
  platform's naming (`.so`, `.dylib`).
- `ffi_source text`: collected per module. At the first call of one of
  the module's functions its sources are compiled once into a shared library with the C
  compiler (`cc -shared -fPIC`, linked against the module's `ffi_lib`),
  cached under the application's `tmp/` by a digest of the source, the
  flags and the compiler's version. The same C runs on both runtimes.
- `ffi_func name, [types], ret, blocking: ...`: a singleton method that
  calls the symbol through Fiddle, looked up in the compiled library, then
  in `ffi_lib`. `blocking:` is accepted.
- `ffi_const`, `ffi_read_ptr name, offset`, and `malloc` / `free`.
- `:binstr`: Spinel copies `sp_ffi_bin_len` bytes from the returned
  pointer; `sp_ffi_bin_len` is a thread-local int the codegen declares.
  The shim declares it in the compiled library with an accessor and reads
  the length on the same thread right after the call.

Known points, as the spike settled them (2026-11-12; spikes/NOTES.md,
"CRuby preview spike, 2026-11"): pointers are Integer addresses, 0 for
NULL, and a `nil` argument is NULL; no caller compares a `:ptr` with
`nil`, and a NULL `:str` result is `nil`, so the callers' comparisons
hold. Every `ffi_func` names an exported symbol (the two `static` helpers
of `sqlite_ffi.rb` are only called from C). A module is compiled at the
first call of one of its functions, not at its first `ffi_func`:
`sqlite_ffi.rb` declares sources after its first `ffi_func`. `:str`
results are tagged UTF-8 and `:binstr` results ASCII-8BIT (their text
callers already `force_encoding`), and a `:str` argument is a
NUL-terminated copy. The CRuby child needs `-E UTF-8` on its command line
(the spike set it from the shim): CRuby's locale encoding (US-ASCII with
`LANG` unset) made `File.read` text unequal to the framework's Strings. Fiddle releases the GVL around calls;
`sp_ffi_bin_len` is a static thread-local in the compiled unit, read
through an accessor right after the call on the same thread. The blog
served `GET /articles` 200 and a form `POST` 303 with no framework file
changed, the first 200 0.2 to 0.3 s after process start; CRuby gen matched
the committed `gen/`.

An application's own `ffi_*` modules go through the same shim. What the
shim does not implement raises at load with the DSL method's name, and the
supervisor shows it on the holding page with a pointer to `--spinel`.

`Dev::Reexec` is not loaded under supervision, so its FFI needs no shim.

## 8. Changes to the framework (compiled under Spinel)

These must pass compiled (`spin test`), not only under CRuby.

1. **Inherited listener.** In development, when the supervision variable
   names a descriptor, `Server` listens on it (`TCPServer.for_fd`, already
   used by `reuse_port_listener`, with the same single-owner rule for the
   descriptor) instead of binding. Ignored outside development.
2. **Supervised development role.** `Roles::Server` under supervision
   builds no `Rebuilder`, no `Watcher`, no restart monitor and never
   re-execs; it serves until TERM. Unsupervised, `serve_development` is
   exactly today's.
3. **Readiness.** After `srv.start`, the supervised child creates the
   readiness file.
4. **Build status behind one type.** `Dev::ErrorPage` reads "did the last
   build fail, and with what output" from the `Rebuilder` today. Under
   supervision the same answers come from the state file. `ErrorPage` must
   keep one concrete type in that slot (Spinel infers one type per
   instance variable): a small status object that the `Rebuilder` fills in
   the old loop and a state-file reader fills under supervision. The
   state file is reread when its modification time changes.
5. **Indicator and header.** A development middleware next to `ErrorPage`,
   installed only under supervision (today's loop has no state file and
   stays byte for byte what it is, snapshots included), adds `X-Cybertrain-Runtime` to every response and the indicator to HTML
   responses, with `banner_status?`'s rules for which responses may be
   touched. The indicator carries the generation and runtime it was
   rendered with. Its script is served by the same middleware from a
   reserved development path as an external same-origin file, and gets the
   request's CSP nonce when the application uses nonces; it styles through
   the CSSOM, not a `style` attribute, so a `style-src` policy does not
   block it. It learns the current state from a reserved development path
   that returns the state file's generation, serving runtime and build
   state as JSON. Polling interval and transport are the builder's;
   requests to the reserved paths stay out of the request log. Reserved
   paths are answered before routing and only in development.
6. **Address command.** A `Main` command that prints the configured host
   and port, used in startup step 4.
7. **Runtime name.** One place answers "cruby" or "spinel" (`RUBY_ENGINE`
   is `"ruby"` under CRuby and tests already branch on it).
8. **Boot failure text.** `Roles.fail_boot` also writes its message to the
   failure file when the supervision variable names one.

Nothing here is read by a production boot.

## 9. `gen` under CRuby

The supervisor runs `ruby -I <dirs> bin/gen.rb` in place of `spin run
gen`. `gen/` is committed and CI already fails on a diff after `spin run
gen`, so the two must write the same bytes. A fast check is added to the
commit gate: CRuby gen on examples/blog leaves `git diff` empty. If the
spike finds a difference (ordering, number formatting), it is fixed in the
generator so both agree, not papered over in the preview.

## 10. Requirements, `doctor`, and falling back

- Ruby 3.2+ with `fiddle` loadable (it needs libffi). `cybertrain doctor`
  checks it and says the preview is unavailable without it.
- If `fiddle` is missing, or the framework has no `cybertrain/preview/`,
  `cybertrain server` prints one line and runs today's loop.
- `--spinel` always runs today's loop.

## 11. What the preview does not show

Stated in the guide and on the holding page, not hidden:

- Whether the code compiles. The background build says so within seconds.
- Runtime differences recorded in spikes/NOTES.md (exception ancestry,
  String encodings on sockets, `Float#round` on a narrowed Float, and the
  rest). They appear once the binary serves.
- Timing and concurrency: CRuby has a GVL and OS threads;
  `SPINEL_WORKERS` means nothing to it.

Background work (jobs, the scheduler, the stream poller, WebSocket feeds)
runs in whichever child is serving, as it does in the binary today; each
edit now restarts it twice (into CRuby, then into the binary) instead of
once, and SSE and WebSocket clients reconnect twice **(call: same services
in both runtimes, for fidelity)**.

## 12. The playground

Decided by the maintainer: the playground moves to the preview in this
work, because it is where a visitor experiences what developing on
CyberTrain is like. Today a Ruby edit there is rebuilt about 100 s after
the save on the default 2-core codespace (playground/README.md); with the
preview the edit answers at once and the binary follows.

What changes:

- `playground/playground-server` keeps running `cybertrain server`, now
  the supervisor. Its "a server is already starting while it compiles"
  branch, and the process patterns it and the smoke test match
  (`build/bin/blog` as the one server process), are rewritten for a
  supervisor with one child that is either `ruby` or the binary.
- **The first start still compiles nothing.** The image holds a full
  build, and spin reuses a binary newer than its sources. For that to
  hold under the supervisor: CRuby gen leaves unchanged files alone (it
  does: `Runner.sync_file` writes only a file whose content differs), the
  startup build goes through `spin build` so that an up-to-date binary is
  reused, and the image is built with the shim's compiled libraries
  already in the cache (section 7), so the first CRuby child does not run
  the C compiler either. The `cp -a` rule for copies of the blog stays.
- `playground/smoke.sh`: A3 and E1 (nothing compiled at start) keep their
  meaning; A9 becomes "a model edit answers 422 for a short body from
  `X-Cybertrain-Runtime: cruby` within seconds, and later from `spinel`",
  no longer waiting for "Build succeeded"; D2 and D4 are restated for the
  supervisor; G3 (`cybertrain doctor` exits 0) now also proves `fiddle`
  loads in the image. The suite's time budget, most of which is three
  compiles of up to a minute, is revisited.
- The words a visitor reads: the banner in `playground-server` ("A Ruby
  change rebuilds the app (about a minute)"), step 2 of `PLAYGROUND.md`,
  the "Start a fresh app" paragraph, `playground/README.md` (the
  measurements, the limits, the reason `files.autoSave` is off), and
  `site/playground.html` with its four translations where they describe
  the wait (`script/check-site-i18n`). They say what the corner indicator
  means and that the preview is CRuby.
- A first `cybertrain server` of a new app (`cybertrain new shop`) has no
  binary: the CRuby child serves while the first build runs (about a
  minute there), which is the same path as everywhere else.

`files.autoSave` stays off unless the builder finds a reason to change
it: a save still starts a build, even if it no longer blocks the page.

## 13. Order of work, and the spike that comes first

The gate requires the Playground image workflow, which runs `smoke.sh`,
on any pull request that touches a file the gemspec lists. So from the
step that changes what `cybertrain server` does until the playground step,
`playground-server` passes `--spinel` and the smoke test stays as it is.

**Spike (throwaway, before the plan is final):** with a minimal Fiddle
shim, get examples/blog to answer `GET /articles` and one `POST` under
CRuby, and run CRuby gen against the committed `gen/`. It answers the
"known points" of section 7 and tells how much of the framework needs
touching to load and serve under CRuby. If more than a handful of
framework files need CRuby-specific branches, stop and come back to the
maintainer: that changes the size.

Then, each step leaving the tree working:

1. The shim, and a CI job that runs the framework's FFI tests under CRuby
   with it and diffs against the committed `.expected` (which come from
   the binary). A test that cannot match is listed with its reason; that
   list is the documented gap between the runtimes.
2. Framework changes 1 to 4 and 6 to 8 (section 8), compiled tests.
3. The supervisor with CRuby only (no handover yet), state-machine tests.
4. The background build and the handover to the binary.
5. The indicator and header (framework change 5).
6. `doctor`, the fallbacks, `--spinel`.
7. The playground (section 12): `--spinel` comes off, the image warms the
   shim's cache, the smoke test and the visitor's texts are rewritten.
8. Documentation (section 14), and one end-to-end script on
   examples/blog in CI: start, request, edit a model, see the change from
   `cruby` within the target, wait for `spinel`, break the build, see the
   banner.

## 14. Documentation

- docs/design.md: the new record; principle 5 and section 8 reworded;
  D12 (the development loop) marked as the `--spinel` path.
- docs/performance-next.md: the rejected line marked superseded, dated.
- docs/guide/how-it-works.md "The development loop" and the Rails table
  row "Editing code"; docs/guide/install.md (requirements, `doctor`);
  the tutorial where it describes saving a file. The translations (ja, fr,
  ru, zh) follow; `script/check-guide-i18n` enforces it.
- CONTRIBUTING.md and spikes/NOTES.md: "a CRuby pass is not acceptance"
  now also names the preview.
- The `cybertrain` usage text; the templates `cybertrain new` writes, if
  they mention the loop.

## 15. The author's calls, for the maintainer to check

1. `--spinel` as the name of the flag that keeps today's loop; today's
   loop also stays for a direct `spin run NAME` and for the native CLI.
2. Handover is stop-then-start with the supervisor holding the socket
   (connections wait up to about 0.2 s), not start-then-stop. In
   conversation this was described as "the new child is ready before the
   old one stops"; the promise kept is that no request is refused.
3. The supervisor learns the port by asking the application under CRuby
   when no port argument is given; an application that cannot load under
   CRuby at startup exits with the error and names `--spinel`.
4. Readiness is a file; a child's STDOUT is the terminal itself (see 11).
5. While `cybertrain build` runs, the preview does not reload, and catches
   up by itself afterwards.
6. Jobs, scheduler, poller and feeds run in the CRuby child as well.
7. A CI job runs the FFI tests under CRuby with the shim against the
   compiled snapshots, with a list of the ones that cannot match.
8. Reverting to a HOLDING page (served by the supervisor) when gen fails
   or the CRuby child cannot boot, instead of leaving stale code serving.
9. A binary that does not start, or crashes while serving, is treated
   like a failed build: CRuby serves again, the banner and the indicator
   say "Spinel binary failed", and nothing retries until the next change.
10. The indicator, the header and the reserved paths exist only under the
    supervisor; `--spinel`, a direct `spin run NAME` and the native CLI
    are unchanged down to their snapshots.
11. A dead child's error reaches the page through a failure file
    (`Roles.fail_boot`, and the preview's boot file) and a copy of STDERR;
    STDOUT is never piped.

## 16. Left to the builder

Names of files, variables, reserved paths and the state file; the
indicator's markup, wording and polling; bounds on waits; how the shim
caches and names its compiled libraries; how the state machine is split
into classes; the end-to-end script's shape; whether `Dev::Rebuilder`'s
gen-freshness machinery is shared with the supervisor or left to the old
loop only.
