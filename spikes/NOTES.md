# Spinel constraints, retained workarounds and spike history

This file is the framework's side of each compiler behaviour: the numbered
rules that say how CyberTrain's code is written because of it, and the
index of which shapes of the framework exist for that reason and which
test covers each. The programs that show the behaviours are beside it
([README.md](README.md) lists them).

It is not the record of where a behaviour stands. A rule may say what was
seen on the build it names, as part of its reason; what Spinel does on the
pinned build, what was asked upstream and whether an item is closed are in
[docs/spinel-feedback.md](../docs/spinel-feedback.md), the one record of
that. Every rule ends by naming its item there, and a rule, like a
program, is kept until that item is closed ("Item register" there says
what closed means; a passing probe is not it).

Original throwaway programs under `spikes/` answered the design questions in
`docs/design.md` section 9, on Spinel 2026.09.12. This file is the durable
record; the M0 programs themselves were deleted once the framework covered
them (828e220, 2026-09-27; `git log --diff-filter=D -- spikes/` in a full
clone). What is under `spikes/` today is later and kept on purpose: the
saved rechecks (`rechecks/`) and the phase programs that a rule below or
docs/spinel-feedback.md cites as its reproduction or measurement
(`decimal/`, `phase4b/`, `phase5/`, `phase6/`). They go when their item is
closed ([README.md](README.md)).

The rules below grew from those spikes and from everything found since,
most of it on 2026.09.12. A rule says which build it was seen on; where it
says nothing, that is 2026.09.12. Whether a rule still reproduces on a
build is in docs/spinel-feedback.md, "Status by rule". The source of
truth for the supported compiler is [cybertrain/version.rb](../cybertrain/version.rb),
including its fork URL; a newer pin needs its own evidence, not a relabelled table.
Rules are cited by number across the repository ("NOTES rule 62"), so they
are never renumbered: a new finding gets the next number, and a rule whose
item is closed is cut to one line that keeps its number, not removed.

## Historical M0 results (2026-09-12 compiler)

These results describe the original spike environment, not the current compiler
or performance targets. The M0 question numbers are **not** the rule IDs below.

| # | Question | Verdict |
| --- | --- | --- |
| 1 | Toolchain, compile time | `make deps && make && make install PREFIX=~/.local` works on macOS. 234-line program: 0.37 s; 2,528-line `spin.rb`: 4.4 s (2.1 s analysis, 2.3 s cc). `-O0` barely changes it. |
| 2 | Non-literal `send`, `instance_exec` | **`send` unusable at app scale** (desugar disabled above 128 symbol/string literals). **`instance_exec(&stored)` never compiles.** Blocks take the receiver explicitly; symbol callbacks go through generated `case` tables. |
| 3 | Runtime template interpreter | **Go.** Monomorphic `INode` AST + plain polymorphic Ruby values: 203 µs per 32 KB render, 1.54x a hand-written compiled renderer, 3.2x faster than CRuby running the same interpreter. |
| 4 | Per-model Relation typing | **Go.** Per-model relation subclasses give `first`/`find` a typed nullable `Post`; four compiler workarounds below. |
| 5 | TCPServer + green threads | **Go.** Keep-alive HTTP/1.1, one green thread per connection: 52-58k req/s at c=100 (`SPINEL_WORKERS=1`), p99 ≤ 2 ms; idle/silent connections do not stall others **provided every `readpartial` is preceded by `wait_readable(timeout)`** (a bare `readpartial` blocks the OS worker: that is issue #4528). |
| 6 | SQLite FFI + pool | **Go.** All bindings work; `-1` literal is `SQLITE_TRANSIENT`; static `ffi_buffer` out-params crash under threads, use `malloc`ed scratch per call. |
| 7 | trap / execv / SO_REUSEADDR | **Go.** `trap("HUP")` fires in compiled binaries; execv via a 6-line `ffi_source` shim keeps the PID; same port rebinds immediately. |
| 8 | stdlib packages | **Go.** json, openssl (HMAC needs Homebrew OpenSSL on the link path), securerandom, base64, uri, strscan, stringio all work. `cgi` is absent at this tag. |

The verdicts are 2026.09.12's; row 2 is revisited in docs/spinel-feedback.md,
"Status by rule", row 2.

## Status on 2026.11.15.7033

Moved to [docs/spinel-feedback.md](../docs/spinel-feedback.md#status-by-rule),
"Status by rule", the one place that says what a rule's program did on a
build. "NOTES status N" and "status N", in a comment or a document, mean
row N of the tables there.

## Status on 2026.11.04.7026

Moved with the section above: row N of "Status by rule", "On
2026.11.04.7026", in [docs/spinel-feedback.md](../docs/spinel-feedback.md#status-by-rule).

The saved programs, what each covers and how to run them are in
[rechecks/README.md](rechecks/README.md).

## CRuby preview spike, 2026-11

The spike of the CRuby preview ([docs/design.md](../docs/design.md), D87):
can the unmodified framework serve examples/blog under
CRuby, with a Fiddle shim for the `ffi_*` DSL? Throwaway programs,
deleted once `cybertrain/preview/` replaced them
(`git log --diff-filter=D -- spikes/preview` in a full clone):
`spikes/preview/shim.rb` (the DSL on `Module`) and
`spikes/preview/run.sh` (copied the blog outside the tree, migrated,
served, timed the first 200, posted a form). Measured on
2026-11-12, Linux x86_64 (4 vCPU, cloud), CRuby 3.3.6, fiddle 1.1.2,
GCC 13.3.0, the system libsqlite3 and libz; no Spinel build was made.
The figures below are the spike's, of that day. What differs between the
preview and the compiled tests today is checked by `script/preview-parity`
and listed in [test/cruby/parity-gaps.txt](../test/cruby/parity-gaps.txt)
("What CRuby cannot tell you" below).

**Result: it serves.** With the shim and no change to any file under
`cybertrain/`, `ruby -I<repo> -I. -r <repo>/spikes/preview/shim
bin/blog.rb migrate` ran the three migrations, and `bin/blog.rb 3999`
answered `GET /articles` 200, `GET /articles/new` 200, `POST /articles`
(multipart, with the form's `authenticity_token` and the session cookie,
a non-ASCII title) 303 to `/articles/1`, and `GET /articles/1` 200 showing
the title; the row in SQLite holds the title's UTF-8 bytes.

- **Time from process start to the first 200** on `GET /articles`
  (run.sh: `date` before the `ruby`, then curl every 5 ms): 187, 195,
  197, 198, 199, 202, 218, 229, 246, 256, 313 ms over eleven runs with the
  shim's compile cache warm (migrate fills it); 276, 304, 305 ms with it
  empty at server start (the SQLite unit is compiled with `cc` during boot:
  88 ms on its own). The zlib unit (88 ms) is compiled at the first gzip
  request, not at boot, and `Dev::Reexec`'s never (nothing calls it).
- **Pointers** are Integer addresses, 0 for NULL, as Spinel hands them
  over: `:ptr` results are `Fiddle::Pointer#to_i`; a `:ptr` argument is
  the Integer as given (SQLITE_TRANSIENT's `-1` included) or NULL for
  `nil` (`sqlite3_open_v2(path, slot, flags, nil)`, the `nil` callbacks of
  `sqlite3_exec`); `malloc` and `free` are the FFI modules' own
  `ffi_func :malloc` / `:free`, found in libc; `read_ptr(addr)` is
  `*(void **)(addr + offset)`. The callers' comparisons hold because no
  caller compares a `:ptr` with `nil`: the gzip handle is a `:long`
  compared with `== 0`, the statement cache's `stmt.nil?` is a Hash
  lookup, and a NULL `:str` (`sqlite3_column_text`) comes back as `nil`,
  which `read_row` turns into `""` as it does compiled.
- **`static` functions**: no `ffi_func` names one. sqlite_ffi.rb's two
  `static` helpers (`cybertrain_sqlite_busy`, `cybertrain_digits`) are
  called only from its C; looking them up raises the shim's "no exported
  symbol" error, and all 44 `ffi_func` symbols of the three files resolve
  (the compiled unit first, then the `ffi_lib`, then the process). The
  counts are 33 `ffi_func` and 4 `ffi_source` in sqlite_ffi.rb, not the
  34 and 5 the design first counted.
- **When to compile**: not at a module's first `ffi_func`, as first
  designed: sqlite_ffi.rb declares three of its four `ffi_source` blocks after
  its first `ffi_func`. The shim binds lazily, at the first call of any of
  the module's functions, when every source has been read.
- **Encodings**: a `:str` result is a copy up to the NUL tagged UTF-8, a
  `:binstr` result a copy of `sp_ffi_bin_len` bytes tagged ASCII-8BIT
  (the callers that want text, `GzipFFI.gunzip` and `gzip_pull`, already
  `force_encoding("UTF-8")`); with these, 68 of the 70 tests whose
  process calls through the shim (67 SQLite, 4 gzip; counted with a probe
  wrapped around the shim's calls) match, and the two that do not differ
  for reasons outside the FFI (http_gunzip, stream: below). A `:str` argument is passed as a NUL-terminated
  binary copy, since a Ruby String's buffer is not always terminated.
  Beyond FFI, rule 27 showed up twice: CRuby's `Encoding.default_external`
  follows the locale (US-ASCII here, `LANG` unset), so `File.read` text
  with non-ASCII bytes was never `==` to the framework's UTF-8 String
  (the generators printed `exist` for `identical`, `gen_views` failed);
  the shim sets UTF-8, which has to be done again when the main script is
  compiled because CRuby applies the locale after the `-r` libraries load
  (the real preview passes `-E UTF-8` instead). And
  `Base64.urlsafe_decode64` answers ASCII-8BIT, so `Stream.verify` of a
  non-ASCII stream name answers bytes (below).
- **GVL**: Fiddle 1.1.2 releases it around a call: a main thread counted
  33 million iterations while another thread was inside a 500 ms C call,
  and four threads each in a 300 ms C call finished in 301 ms.
  `blocking:` is accepted and ignored. **The `:binstr` length** is a
  `static _Thread_local int sp_ffi_bin_len` the shim prepends to each
  compiled unit, with an exported accessor the shim calls right after the
  function returns, on the same thread (CRuby 3.3 threads are native
  threads, and the two calls run on the caller's): eight threads making
  200 `:binstr` calls each of differing lengths, with the GVL released,
  read no wrong length.
- **STDERR through a pipe**: under CRuby it is not delayed: a child
  writing a time-stamped line every 200 ms with `$stderr.print`, `warn`
  and `STDERR.write` reached a parent reading the pipe within 0.44 ms at
  worst (15 lines). The compiled binary was not measured (the spike makes
  no Spinel build). What was checked instead: the runtime's `$stderr` is
  an `sp_File` over C's `stderr` (lib/sp_io.h), no object in
  `libspinel_rt_mt.a` references `setvbuf`/`setbuf`, so C's default
  (stderr unbuffered) applies, and a plain C child writing with
  `fprintf(stderr, ...)` arrived within 0.18 ms. C's stdout, by the same
  default, is fully buffered on a pipe, which agrees with the design
  keeping STDOUT on the terminal.
- **Framework files changed for CRuby: none** to serve the blog or pass
  the suite's other tests. One file would make the remaining framework
  test match: `cybertrain/stream.rb`, `Stream.decode64` returning
  `Base64.urlsafe_decode64(padded).force_encoding("UTF-8")` (portable, no
  CRuby branch; tried in a scratch copy, `test/stream.rb` then matched).
  `cybertrain/dev/reexec.rb` needed no stub: it loads through the shim
  and its C compiles; nothing calls it while serving.
- **Gen**: `ruby -I<repo> -I. bin/gen.rb` in a copy of the blog with
  `gen/` deleted wrote all 13 entries again in 0.10 s, and
  `git diff --no-index` against the committed `gen/` showed no
  difference.
- **The framework's tests** (`ruby -I. -r ./spikes/preview/shim
  test/<name>.rb`, from a copy of the tracked tree, compared with
  `test/<name>.rb.expected`): with the final shim 184 of 187 match. The
  first run, before the shim set UTF-8 and put itself in `RUBYOPT`, had
  10 mismatches; by cause:

  | Cause | Before | After | Tests |
  | --- | --- | --- | --- |
  | Locale encoding (`File.read` text US-ASCII) | 4 | 0 | cli_attachment, cli_authentication, gen_views, gen_views_compiles |
  | A child `ruby` the test spawns has no shim (`ffi_lib` undefined) | 3 | 0 | boot_encryption, feeds_exit, rate_limit_store |
  | `Base64.urlsafe_decode64` answers ASCII-8BIT (rule 27) | 1 | 1 | stream |
  | The test's input comes from the runtime's own `Zlib.gzip`, whose bytes differ: flipping its middle byte still inflates to the same 2000 bytes (CRuby's zlib agrees), so no BodyUndecodable | 1 | 1 | http_gunzip |
  | The test runs `$0` as an executable (only a binary can), and `Process.spawn` reports a non-executable `sqlite3` on PATH as ENOENT under CRuby, EACCES compiled | 1 | 1 | main_console |

  None is a shim defect; the last two are among the gaps between the
  runtimes that test/cruby/parity-gaps.txt lists. The suite took 184 s
  under CRuby, one test at a time (websocket_subscription 33 s,
  background 21 s, job_threads 20 s).
- **Not covered**: under CRuby the server boots in development with the
  watcher on ("Watching app/, config/ and db/schema.rb for changes"); no
  file was edited, so what today's rebuilder does under CRuby was not
  seen. An application's own `ffi_*` modules were not tried.

## Maintaining this inventory

Use the compiler pin in `cybertrain/version.rb` and record the tested fork,
release and commit. Keep rule IDs stable; append a new ID for a new finding,
and keep retired IDs with the removal/test reference. A new finding is
written as an item in docs/spinel-feedback.md first (the next letter); the
rule here ends with the line naming it. M0 question numbers, NOTES rule IDs,
spinel-feedback item identifiers and upstream issue numbers are distinct
identifiers.

For each new finding or recheck, record:

- **Kind and scope:** language/tool contract, compiler defect, supported
  capability, project policy, or performance observation. State the exact
  receiver/block/type shape; split the status of unrelated subcases.
- **Evidence:** date, framework commit, compiler version/commit, OS/architecture,
  relevant flags and worker/GC settings, saved source, exact invocation,
  exit status and expected/observed output. A timeout is inconclusive, not a
  reproduction of a compiler defect. A snapshot is an expectation to review,
  not something to regenerate automatically to make the check pass.
- **Policy:** the affected framework code, the workaround still required,
  the regression test (or explicitly missing coverage), and the upstream
  issue/fix when known. Separate "probe passes" from "workaround retired".

Keep new reduced programs under `spikes/rechecks/` (one that still differs
from CRuby, or needs the framework, in `spikes/rechecks/differing/`) or the
relevant phase folder; output binaries, generated C and logs go outside the package tree
(rule 98). Once an affected-program regression exists in `test/`, link it
before removing redundant spike source. Do not delete the only reproducible
evidence and leave an unsupported "fixed" claim.

On a compiler upgrade, re-run retained probes and the affected framework,
generator and example-application tests on supported platforms. Prioritize
GC/FFI lifetimes (15, 58, 64, 65, 80), exception swallowing (81, 89), stored
blocks (2, 82, 88, 90, 97), and concurrency/process behaviour (20-22, 57,
80, 91). Keep untested entries explicitly unverified on the new pin. Update
docs/spinel-feedback.md ("Status by rule" and the register) and the design
references together; do not copy an older compiler's pass label onto a new
version without running its evidence.

Retire a workaround only in a reviewed change that demonstrates the old
failure shape without the workaround, keeps an affected-program regression,
and passes the relevant integration checks. GC and concurrency changes need
stress or multi-worker evidence; a small single-threaded program is not
sufficient. Narrow general advice to the actual failure: never remove needed
synchronization or repeat side effects just to work around inference.

## Rules by topic

The rules are numbered in the order they were found. By topic:

- Dynamic dispatch and blocks: 1, 2, 6, 26, 30, 31, 40, 42, 67, 68, 69, 77, 82, 88,
  90, 92, 93, 95, 97, 103, 111, 113
- A method name shared by unrelated classes, or with a builtin: 10, 34, 41,
  43, 51, 62, 66 (second paragraph), 87, 105, 106, 121
- Typing of ivars, locals, containers and return values: 3, 4, 5, 7, 9, 11,
  37, 46 (Hash literals), 56, 63, 71, 73, 86, 94, 97, 109, 110
- Polymorphic values and narrowing: 8, 14, 29, 35, 86, 100, 109
- Constants, class variables, module state: 17, 18, 64, 70, 74, 76, 81, 93,
  101
- Exceptions, `rescue` and `ensure`: 32, 33, 44, 45, 47, 48, 50, 53, 54, 61,
  79, 81, 89, 103, 104, 107, 113, 119, 124
- Strings and bytes: 12, 13, 25, 27, 39, 52, 55, 60, 66, 96
- Memory and GC roots: 58, 64, 65; and 99, a shallow built-in `dup`, which
  is ordinary Ruby
- Request decoding: 28, 49, 52
- I/O, sockets, threads, processes: 19, 20, 21, 22, 57, 72, 75, 78, 80, 83, 85,
  91, 102, 112, 114, 115, 116, 117, 123 (the environment)
- FFI: 15, 59
- Tests and tools: 23, 24, 36, 41, 63, 84, 92, 98, 105, 107, 108, 110, 114,
  116, 118, 120, 122
- Ordinary Ruby, or a record of forms that work, not Spinel defects: 16, 38

## Workarounds that shape the design, and what a Spinel update re-checks

The rules below are numbered in the order they were found, which is not
the order a maintainer needs them in. This section is the index from the
other side (issue #192): which shapes of the framework exist because of
Spinel, whether each is how CyberTrain is written for good or a workaround
for one build, and which compiled test fails if the shape is undone. It
repeats no rule: the rule has the reason and the reduced program,
docs/design.md the decision, docs/spinel-feedback.md what went upstream.

### Permanent: how CyberTrain is written for an ahead-of-time compiler

These follow from what Spinel is (no run-time code, one static type per
method), not from a defect. They are API policy; a Spinel release does not
retire them, and they are not re-checked on an update.

| Shape in the framework | Constraint | Decision | Verified by |
| --- | --- | --- | --- |
| Callbacks and nested DSL blocks take their receiver (`before_action { \|c\| ... }`, `resources ... do \|r\|`); names dispatch through generated `case` tables | no `instance_exec` of a stored block, no computed `send` (rules 1, 2) | D4, D8, D38 | test/gen_controllers.rb, test/gen_helpers.rb, test/controller.rb |
| Models, relations, routes, helpers, components, jobs and concerns are generated Ruby, not metaprogramming | no `method_missing` or `eval`, and no method defined while the program runs (rules 1, 92, 93; for `define_method` see the note under this table) | D3, D4, D60 | test/gen_*_compiles.rb, test/gen_concerns.rb; examples/blog's `gen/` freshness in CI |
| One return type per method: `pluck_int`, `maximum_int`, `sum_float_by`, `Cache.fetch_hash`; `DB.transaction` and `Model.transaction` return nil | a method has one static return type (rules 5, 90) | D20, D22, D44, D45 | test/pluck.rb, test/aggregates.rb, test/db_transaction_api.rb |
| A per-model Relation subclass whose chain methods wrap base setters and return `self` | a base method returning `self` is typed as the base (rule 5) | D10, D43, D72 | test/gen_models_compiles.rb, test/relation_where.rb |
| Templates are a language of their own, interpreted over fixed dispatch tables | no `eval`, no run-time method lookup (verdict 3) | D9 | test/template_*.rb, docs/compatibility.md |
| The console evaluates template expressions, not Ruby | the same | D41 | test/console.rb, test/main_console.rb |
| Tests are programs compared with a snapshot, not minitest | no reflection to discover test methods (rule 23) | D13 | test/harness.rb |
| Process-wide state lives in module-level ivars with `def self.x` accessors | `@@x` was miscompiled and unrooted (rules 18, 64); kept as the one idiom even where a build fixed it | D64 | test/harness_gc.rb, test/runtime.rb |
| Empty containers are seeded with their element type; nullable ivars go through `Cast.*_or_nil` | static typing of containers and ivars (rules 7, 9, 11) | D10 | every compiled test (a wrong seed does not compile) |
| A method name means one thing: distinct names for framework accessors (`reject_status`, `command_name`, `service_start`), reserved column names | same name, same return type across classes (rules 10, 34, 62) | D10 | `script/check-reserved-names`, test/openssl_dispatch.rb, test/cast_types.rb |
| FFI fragments declare what they call (`extern` in `ffi_source`); the `-1` literal for `SQLITE_TRANSIENT` | Spinel's documented FFI rule (rule 59; spinel-feedback B) | D10 | test/db_sqlite.rb |
| Request numbers are length-checked before `to_i` | `String#to_i` raises past 2**63-1 by design (rule 25; spinel-feedback D) | D14 | test/http_request.rb, test/params.rb, test/server.rb |

The second row said "no `define_method`" until 2026-11-20, which is wider
than what was shown. On 2026.11.04.7026 (`a2d06115`, Linux x86_64, GCC
13.3.0, `-O 0`, compared with CRuby 3.3.6, 2026-11-20)
[rechecks/define_method_shapes.rb](rechecks/define_method_shapes.rb)
compiles and prints what CRuby prints: `define_method` with a literal name
in a class body; a class macro that defines two methods with literal names
whose blocks read and write an ivar, called from a subclass body; and a
macro that takes the name as its parameter, called with literal Symbols
from a class body. Two programs that define a method while the program
runs are refused. `class Conf; def initialize; @vals = { "" => "" }; end;
def setting(name, value); @vals[name.to_s] = value; vals = @vals; key =
name.to_s; self.class.send(:define_method, name) { vals[key] }; nil; end;
end; c = Conf.new; c.setting(:base_url, "http://x"); puts c.base_url`
stops with "unsupported call: ... (CallNode `define_method`)". `class
Conf; def initialize; @a = "1"; end; end; name = ARGV.empty? ? "a" :
ARGV[0]; Conf.send(:define_method, name.to_sym) { @a }; puts Conf.new.a`
stops with "Conf.define_method(...) is not supported by AOT compilation
... Move the `define_method` inside `class Conf ... end`". CRuby prints
`http://x` and `1`. These are five small programs: they say nothing about
macros at the scale of an application's models, and the decisions of the
row (D3, D4, D60: generated Ruby) are unchanged.

### Tied to a build: workarounds a Spinel release may retire

Each of these is there because the pinned build (or an earlier one)
miscompiles or refuses the plain form. The last column names each row's
items in docs/spinel-feedback.md, where its status on the pin is ("Item
register", and "Status by rule" by rule number). A workaround is removed
only in a change that also
shows the plain form compiling and passing under the new build, with the
test named here (or a new one) covering the shape; until then new code
follows the rule even where a probe passes.

| Workaround | Rule | Where | Fails without it in | Items (docs/spinel-feedback.md) |
| --- | --- | --- | --- | --- |
| `begin/rescue` and `ensure` live in a plain method that takes the block as a Proc, one level down and no further (`DB.run_transaction`, `Controller#process` / `#run_action`, the job worker's run loop, `Server#run_writer`, `Main.run_command`) | 32, 45, 67, 69 | db.rb, controller.rb, job/worker.rb, job/executor.rb, scheduler.rb, http_client.rb, http/server.rb, main.rb | test/db_transaction.rb, test/db_transaction_api.rb, test/db_rolled_back_transaction.rb, test/jobs.rb, test/cron.rb | rule 32, rule 45, rule 67, rule 69 |
| Every client fault is listed by its full name in `ClientError::CLIENT_FAULTS`, which is compared with `e.class.name` | 46, 53, 54 | http/client_error.rb | `script/check-client-faults`, test/client_error.rb | AE, rule 46 |
| Byte scanners read their parameter through a fresh `to_s` local; no Ruby method is named after a builtin (`getbyte`, `write`, `close`, `<<`) | 62, 66 | http/*.rb, cast.rb, http_client.rb, mailer.rb, net/*.rb | test/openssl_dispatch.rb, test/http_client_gzip.rb, test/template_integration.rb, test/websocket_integration.rb | rule 62, rule 66 |
| A String made in an argument is bound to a local before `new`; `SafeString.of` | 58, 65 | html.rb, mailer.rb, cron.rb, job.rb, model/bulk_writes.rb | test/uploaded_file.rb, test/cli_toolchain.rb, test/gen_models.rb | item 1 |
| Lambdas kept in module state are returned by a method, never written as a literal into the module body or a keyword argument (`Views.default_helpers_builder`, `Assets.empty_resolver`, `Gen::Routes.url_resolver`) | 42, 82, 97 | views.rb, assets.rb, component.rb, application.rb's header | test/views_detached.rb, test/assets.rb, test/application.rb (the path-helper case) | rule 42, Y, W |
| A stored block that must reach a subclass's override is registered through generated code that names the subclass (`FormatCollector`, job and mailer registration, counter caches) | 88, 89 | format_collector.rb, generator/jobs_emitter.rb, mailer/later.rb, controller.rb | test/counter_cache_two_models.rb, test/gen_jobs.rb, test/controller_formats.rb | Z, R |
| The generator's scans stay separate passes whose results do not meet in one method (`Gen::Runner`) | 94 | generator/runner.rb | test/gen_runner_models.rb; `cd examples/blog && spin run gen` | X |
| Sockets: `wait_readable` before every `readpartial`; a socket reaches its thread through a method parameter; `connect_nonblock` instead of `connect_timeout:` | 20, 21, 72 | http/server.rb, http/body_writer.rb, net/socket.rb, websocket.rb | test/server.rb, test/response_stream.rb, test/main_roles.rb, test/http_client.rb | rule 20, rule 21, O, rule 72 |
| `SPINEL_WORKERS` is set to `workers + 1` (1 for a single worker) before the first thread; development serves on one worker; no lock on the request path (the logger's one-write `Logger::LOCK` is the measured exception, rule 115) | 22, 57 | application.rb (`spinel_workers_for`), template/engine.rb, http/server.rb | test/dev_application.rb, test/template_embedded.rb, test/db_busy_wait.rb; bench/run's two-core run | L, item 7 |
| A large generated table (an application's dictionary, the bundled ones) is a Hash filled at load by methods of at most 50 stores, never one literal | 101 | generator/locales_emitter.rb, locales/bundled.rb | build time only: test/gen_locales.rb compiles it; one literal of 2,000 keys takes some 13 s of cc | AI |
| `exit` only on the main thread: a feeds supervisor sets a flag the main thread acts on | 91 | background/supervisor.rb, roles/feeds.rb | test/feeds_exit.rb | T |
| `Logger#write_now` writes with `@io.write`; the console flushes after each prompt | 78, 83 | logger.rb, console.rb | test/logger_flush.rb, test/main_console.rb; test/logger_tls.rb was written for 78 and no longer fails without it (status 78) | K, M |
| Integer-only Ranges: a Time range is `where_between`; `time_tag`'s `format:` (and `I18n.l`) walks the pattern itself instead of calling `strftime` with a built one | 86, 96 | relation.rb, validator.rb, template/helpers.rb, strftime.rb | test/relation_where.rb, test/validators.rb, test/helpers.rb | Q, V |
| A helper that only raises and stands in for a typed lambda names a typed value after its `raise` (`Console.unknown_model`, `Console.unknown_record`) | 124 | console.rb; generator/console_emitter.rb emits the calls | test/console.rb (the rescuing-caller case), which does not compile without the values | AY |
| A program that requires a middleware exercises it | 36 | every test that requires `cybertrain/application` | test/application.rb, test/db_integration.rb, test/health.rb | rule 36 |

The table had a row for rules 33 and 61 until 2026-11-21: `rescue
JSON::NestingError, JSON::ParserError, StandardError`, in that order,
wherever application code may raise. Both are closed
(docs/spinel-feedback.md, "Item register"). No rescue under `cybertrain/`
names a JSON class: each of those clauses is `rescue StandardError` since
2026-11-20, and `Cast.parse_json`, which named the two classes in two
arms, since 2026-11-21. The tests that raise a JSON error into the plain
clause are test/server.rb (`/json`, `/deep`),
test/json_rescue_background.rb and test/cast_types.rb (`parse_json`).

The first row named rule 79 beside rules 32, 45, 67 and 69 until
2026-11-21. Rule 79 is closed (docs/spinel-feedback.md, "Item register"),
and the row's shape stays for the other four. Rule 79's own shape, the
appended value of a rescuing method whose block only raises, is written
the plain way in test/console.rb (the rescuing-caller case), and
test/test_lifecycle.rb's bodies only raise.

### When the pinned Spinel changes

`script/bump-version VERSION SPINEL_TAG` moves the pin (`Cybertrain::SPINEL_TAG`,
CI's `SPINEL_TAG`, the numbers the tests print). The pull request that
carries it also:

1. Runs everything compiled: `spin test`, then `cd examples/blog && spin run gen && test -z "$(git status --porcelain --untracked-files=all -- gen/)" && spin test` (the status, not `git diff`: a new generated file is untracked and a diff does not show it), and the generated application of CI's end-to-end job. A snapshot that changes is a behaviour change of the compiler: explain it, do not regenerate it away.
2. Runs `bench/run` on the one- and two-core configurations and compares with the last `bench/results/*.json` (docs/benchmark.md): rules 22 and 57 and spinel-feedback 4 to 7 are about cost, which no test sees.
3. Re-runs the evidence, which is under `spikes/`: `spikes/rechecks/run.sh`; each program of `spikes/rechecks/differing/` by its header; and, for every item of docs/spinel-feedback.md whose register state is not `closed` or `settled`, the programs the READMEs under `spikes/` list for it, each also built with the previous pin as a control, so that a pass is a change of the compiler and not of the program. New reduced programs go in `spikes/rechecks/<tag>/`, with a README row naming their item. Items of kind "constraint" (docs/spinel-feedback.md, "Accepted as Spinel constraints" and 1.4) and the first table above are not re-checked.
4. Writes what each program did into docs/spinel-feedback.md and nowhere else: a new "On <tag>" table under "Status by rule" (the older tables stay: a rule's history is part of the record; a rule nobody ran is "Not re-checked", never a label copied from the pin before), the "State on the pin" column of "Item register", and a bullet for the build in the list at its top. No result for the new pin is written under `spikes/`: not into a rule, not into the tables of this section, not into a README. A program's header and the README beside it record once the run that produced the program and its `.expected` file (the date, the machine, the tools) and are not updated for a later pin.
5. Reads Spinel's release notes and Spinel's own docs/limitations.md for a changed default (the worker count, `--int-overflow`, a new refusal): a behaviour by design becomes an item of kind "constraint" or "refusal by design" in docs/spinel-feedback.md and, where code has to be written differently for it, a rule here whose last line says "Permanent".
6. Leaves every workaround, every rule and every program in place, the ones whose program now passes included. Closing an item is a pull request of its own (docs/spinel-feedback.md, "Item register"): it removes the workaround, shows the plain form passing a compiled test of the framework's own shape on the new pin, sets the register row to `closed` naming that test, and sets the rule's last line to "Closed", without renumbering; that pull request or a later one may cut the rule's body and delete the item's programs. A program of `differing/` that now matches CRuby moves up into `rechecks/` with an `.expected` file; it is not deleted.

### What CRuby cannot tell you

The commit gate, `ruby -I. test/<name>.rb` and the CRuby preview that
`cybertrain server` serves in development (docs/design.md D87) run under
CRuby, where none of the constraints above exist. A change that moves code between methods,
classes or files, changes what a block or a Proc crosses, introduces a
shared helper or a base class, or changes what the generator emits is
accepted only when the affected tests pass compiled (`spin test`), and,
for generator changes, when examples/blog regenerates clean and passes.
A CRuby pass is evidence for the logic and none for the structure: most
rules above were found by a refactoring that was correct Ruby. That holds
for the preview too: a page that works there is done only once the
compiled binary serves it (the corner of the page says `Spinel`), and only
the compiled tests (`spin test`) count.

How far the preview is from the compiled program is a checked fact:
`script/preview-parity` (the `cruby-preview` CI job) runs every framework
test under CRuby with the shim against the compiled snapshots, and the
tests that differ, each with its verified cause, are listed in
[test/cruby/parity-gaps.txt](../test/cruby/parity-gaps.txt). A match says
the preview behaves as the compiled tests expect; it does not say the code
compiles. To run the checks: `script/test-cruby` (the preview's own tests,
`test/cruby/*.rb`), `script/preview-parity` (both in the `cruby-preview`
job; its macOS leg runs the first only), and `script/preview-e2e`
(`cybertrain server` on a copy of examples/blog, built with Spinel several
times; about ten minutes; the `preview-e2e` job, on Ubuntu).

### What a built binary still depends on

`cybertrain build` produces one executable with the views and the asset
manifest inside it, and that is the whole application; it is not a
statically linked one. It needs, on the machine that runs it:

| Dependency | Why | Condition |
| --- | --- | --- |
| The operating system and CPU it was built for | Spinel compiles through the system C compiler | built and tested on Linux (x86-64 and arm64, glibc) and macOS; no cross-compilation, no Windows (WSL2 works), musl untested. Build on the release you deploy to, or older: a binary linked against a newer glibc does not start on an older one |
| `libsqlite3` (shared) | `ffi_lib "sqlite3"` (cybertrain/db/sqlite_ffi.rb) | the server's library is the one used, not the build machine's. 3.35 or newer covers the framework's own SQL (`RETURNING` in `insert_all` / `upsert_all`, `ALTER TABLE ... DROP COLUMN` in migrations); `db backup` needs 3.27 (`VACUUM INTO`) and says so, `db normalize` and taking over a Rails database need 3.37 (`PRAGMA table_list`) |
| OpenSSL 3 (`libssl`, `libcrypto`, shared) | the session and encrypted cookies, `encrypts`, TLS for outbound HTTP, SMTP and WebSocket (Spinel's `openssl` package) | the same major version at build and run time |
| zlib (shared) | gzip request bodies and responses | any current version |
| jemalloc (shared), optional | only with `allocator = "jemalloc"` in `spin.toml` | installed on the server as well |
| `/usr/share/zoneinfo` (or `TZDIR`) | `Cybertrain::TimeZone` reads TZif files (D19) | install `tzdata` in a minimal image, or use UTC only |
| A writable directory for the database, `storage/uploads/` and, outside production, `tmp/secret_key` | SQLite's WAL files sit beside the database | a local file system: SQLite's locking is not reliable over NFS |

docs/guide/install.md has the build-time packages, docs/deploy.md and
docs/deploy.en.md the server's (`libsqlite3-0 zlib1g libssl3t64
libjemalloc2` on Ubuntu 24.04, what examples/blog's Dockerfile installs in
its runtime stage). Building in the same image family as the runtime
stage, as that Dockerfile does, satisfies every row.

<a id="rules-every-framework-file-must-follow-derived-from-the-spikes"></a>

## Numbered records and retained implementation rules

Read each record together with its status in docs/spinel-feedback.md
("Status by rule"). Unless its own
text gives a newer date, the failure narrative describes the original
2026.09.12 observation. Imperative workarounds stay in force only within the
affected shape; they do not turn historical symptoms into universal Ruby rules.
Records 13, 16, 23-24, 38, 76, 84-85, 87, 95, 98, 99, 102-103, 105-106,
108, 111, 113-115 and 118-121 are language or tool behaviour, supported
capabilities, test-writing advice or measurements rather than compiler
defects, and 17, 107 and 112 record such behaviour together with a difference
from CRuby that is still there (its last line and the status tables of
docs/spinel-feedback.md classify each); record 22 is a measured tuning
decision, and 77 explicitly retires a workaround.

1. Never call `send`, `public_send`, `respond_to?`, `instance_variable_get`,
   `const_get` with a non-literal name. Dispatch on names with `case name when :literal`.
   This is the retained framework policy; the current computed-send probe
   passes and the old 128-literal compiler limit no longer justifies it alone.
   Permanent (docs/spinel-feedback.md rule 1): how Spinel is, and nothing is
   asked; no build retires this rule.
2. Never `instance_exec`/`instance_eval` a stored block. Blocks that need the
   receiver take it as an argument: `before_action { |c| ... }`, `before_save { |r| ... }`.
   Permanent (docs/spinel-feedback.md rule 2): how Spinel is, and nothing is
   asked; no build retires this rule.
3. A base-class method that calls a method defined only in subclasses
   crashes the compiler (SIGSEGV at codegen). Declare an abstract stub in the
   base for directly dispatched hooks (`def read_attribute(name) = nil`).
   Do not add stubs indiscriminately: stored callback-only hooks have the
   opposite failure in rule 88 and intentionally have no base stub.
   On 2026.11.04.7026 a probe of this shape passes (status 3); the rule
   stays for new code until a change retires it.
   Kept until docs/spinel-feedback.md rule 3 is closed.
4. From an instance method, `self.class.foo` is only safe when `foo` is
   overridden in every subclass; otherwise pass the class explicitly. Keep
   class-level registries keyed by a String (`model_name`, class name).
   On 2026.11.04.7026 a probe of this shape passes (status 4); the rule
   stays for new code until a change retires it.
   Kept until docs/spinel-feedback.md rule 4 is closed.
5. Chain methods that `return self` from a base class are typed as the base.
   Base setters return `nil`; subclasses wrap them: `def where(h) = (add_where(h); self)`.
   On 2026.11.04.7026 a probe of this shape passes (status 5); the rule
   stays for new code until a change retires it.
   Permanent (docs/spinel-feedback.md rule 5): how Spinel is, and nothing is
   asked; no build retires this rule.
6. Never store `Method` objects in collections; store lambdas.
   On 2026.11.04.7026 a probe of this shape passes (status 6); the rule
   stays for new code until a change retires it.
   Kept until docs/spinel-feedback.md rule 6 is closed.
7. A nullable ivar must be assigned through a cast helper that can return nil
   (`Cast.time_or_nil(v)`); assigning a `Time` directly to an ivar that starts
   as nil miscompiles (reads back `Time.at(0)`). Non-null Integer/String
   attributes are initialised to `0` / `""` and cast with `to_i` / `to_s`.
   On 2026.11.04.7026 a probe of this shape passes (status 7); the rule
   stays for new code until a change retires it.
   Kept until docs/spinel-feedback.md rule 7 is closed.
8. In any `case value` over polymorphic values put `when Time` **before**
   `when Array` (a Time in a poly slot matches `Array`).
   No longer reproduces on 2026.11.04.7026 in a probe: a Time in a
   polymorphic slot falls through `when Array` and `when Hash` to its own
   arm. The `when Time` arms that only repeated the `else` are gone from the
   files status 8 lists; the others stay until re-checked. Do not add new
   ones on the strength of this rule.
   Kept until docs/spinel-feedback.md rule 8 is closed.
9. Empty containers stored in ivars must be seeded with their element type:
   `Array.new(0) { Node.new }`; a typed empty Hash is `h = { "" => x }; h.delete("")`.
   On 2026.11.04.7026 a probe of this shape passes (status 9); the rule
   stays for new code until a change retires it.
   Kept until docs/spinel-feedback.md rule 9 is closed.
10. Do not reuse a method name across unrelated classes that can meet in a
    polymorphic receiver (a `Frame#body` next to `Post#body` corrupted the
    inferred return type). Framework-internal accessors get distinctive names.
    On 2026.11.04.7026 a probe of this shape passes (status 10/34); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 10 is closed.
11. A local initialised to `nil` and later given a String/Integer widens the
    whole method to the boxed slow path. Use typed sentinels (`""`, `-1`, a flag).
    On 2026.11.04.7026 the generated C of a small probe keeps such locals
    typed (status 11); not checked in a framework method.
    Kept until docs/spinel-feedback.md rule 11 is closed.
12. `k, v = str.split("=", 2)` miscompiles; index the array instead.
    On 2026.11.04.7026 the reduced program passes (status 12); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 12 is closed.
13. String literals are frozen: build buffers with `+""` / `String.new`.
    Not a Spinel item (docs/spinel-feedback.md 1.4): ordinary Ruby; kept as
    the record the code cites.
14. `include?` on a polymorphic receiver with a polymorphic argument mis-dispatches;
    narrow the receiver with `case` first.
    On 2026.11.04.7026 a probe of this shape passes (status 14); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 14 is closed.
15. FFI: never pass a static `ffi_buffer` as an out-parameter from more than one
    thread; `malloc(8)` a scratch pointer per call and `free` it.
    Kept until docs/spinel-feedback.md rule 15 is closed.
16. `self.class.name` and `rec.class.name` work; `case rec when Post` works;
    `Post === rec` works; a Hash keyed by class name works.
    Not a Spinel item (docs/spinel-feedback.md 1.4): ordinary Ruby; kept as
    the record the code cites.
17. Constants may be read before definition under Spinel but not under CRuby;
    keep definition order CRuby-valid anyway.
    On 2026.11.04.7026 (2026-11-15) this is true of class names only:
    `Later.new.hi` written above `class Later` runs compiled and is
    NameError under CRuby. A constant assigned with `=` (`BACKOFF =
    Retry::BACKOFF`, `puts EARLY`) and read before its assignment raises
    NameError compiled too, at top level, in a module body and in a class
    body (status 17). The advice is unchanged.
    Kept until docs/spinel-feedback.md AV is closed.
18. A module-level `@@class_variable` assigned inside `module Cybertrain`
    miscompiles once an earlier required file has already opened the module
    (C error "incompatible pointer to integer conversion"). Use a module-level
    `@instance_variable` with `def self.x` accessors instead.
    Reduced repro: `module Cy; module H; end; end; module Cy; class L; end;
    @@logger = L.new; def self.logger; @@logger; end; end` ->
    `use of undeclared identifier 'cvar_Cy_logger'`.
    On 2026.11.04.7026 the reduced repro passes (status 18); module-level
    ivars stay the one idiom (docs/design.md D64).
    Kept until docs/spinel-feedback.md rule 18 is closed.
19. `STDOUT` and a `StringIO` cannot share one polymorphic call site (`io.puts`
    where `io` is sometimes `STDOUT` and sometimes a `StringIO` raises
    NoMethodError for one branch). Keep such handles in separate typed slots
    and branch explicitly (`if @io then @io.write(line.end_with?("\n") ? line : "#{line}\n") else
    STDOUT.puts(line) end`;
    `write`, not `puts`, on `@io` because of rule 78).
    (`cybertrain/logger.rb`: never pass STDOUT/STDERR as a constructor
    argument next to a StringIO-accepting call site.)
    On 2026.11.04.7026 a probe of this shape passes (status 19); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 19 is closed.
20. Sockets: never call `readpartial` without `sock.wait_readable(timeout)`
    immediately before it (`readpartial` is a raw blocking `read(2)` that holds
    the OS worker and never yields; `wait_readable` parks the green thread and
    its nil return is the idle timeout). `IO#gets` parks correctly. `SO_RCVTIMEO`
    is unusable (setsockopt takes Integers only).
    On 2026.11.04.7026 a probe passes (status 20): at `SPINEL_WORKERS=1`
    another green thread keeps running while one sits in a bare
    `readpartial`. The `wait_readable` stays, since its nil return is the
    idle timeout.
    Kept until docs/spinel-feedback.md rule 20 is closed.
21. Never pass a socket as a `Thread.new` argument (`Thread.new(sock) { |c| ... }`
    loses its static type: "undefined method 'wait_readable' for TCPSocket").
    Spawn through a method whose parameter the closure captures:
    `def spawn_conn(sock); Thread.new { serve(sock) }; end`.
    On 2026.11.04.7026 a probe of this shape passes (status 21); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 21 is closed.
22. For I/O-bound servers `SPINEL_WORKERS=1` was faster (54-58k rps) than the
    10-worker default of 2026.09.12 (25-45k rps) and had no 40-80 ms stalls
    (newer Spinel defaults to the number of online cores: Spinel's
    docs/thread.md); set it from the binary before the first `Thread.new`
    (the server, worker and feeds roles assign `ENV["SPINEL_WORKERS"] =
    Application.spinel_workers_for(config).to_s` before their first thread,
    cybertrain/roles/server.rb, worker.rb and feeds.rb; `Config#workers`
    reads `SPINEL_WORKERS`, default 1; what is handed to Spinel is explained
    below), and re-measure once templates and SQLite add CPU work.
    Re-measured with examples/blog on two cores ([docs/benchmark.md](../docs/benchmark.md)):
    `SPINEL_WORKERS=2` adds 16-27% to the pages, 51% to a comment POST and
    49% to a static file. The POST used to lose a quarter: SQLite's
    busy_timeout slept a millisecond or more holding the worker, until a
    busy handler retrying every 100 us replaced it (cybertrain/db/sqlite_ffi.rb;
    since rule 80 the wait is a green-thread `sleep` starting at 100 us). 1 stays
    the default (a one-core server); set it to the core count otherwise.
    **Since Spinel #9840 (in 2026.11.04.7026, not in 2026.09.12) an explicit
    `SPINEL_WORKERS=N` counts main among the N** and starts N-1 helpers
    (`g_worker_cap--` in lib/sp_sched.c's `sp_sched_start_workers`); unset,
    it is still one helper per core beside main. With helpers present main
    runs no general green thread (`sched_place_unstarted` skips worker 0,
    and main's join pump runs only threads already pinned to it), and in
    the server main only waits in `Server#wait`. So on 2026.11.04.7026,
    `SPINEL_WORKERS=2` served examples/blog from one helper: the run of
    2026-11-05 measured 0-2% over 1 on the pages. Measured on 2026-11-05
    (2 CPUs, `taskset -c 0,1`, wrk -t2 -c16 on CPUs 2 and 3), with
    `SPINEL_SCHED_STATS=2`: `pinned per worker: 0 18`, `workers=2 busy=1
    runnable=14`, one OS thread at 7.85 s of CPU in 8 s and main at 0.15 s;
    `mutex-wait n=0` (no lock in the framework) and the sweeper threads at
    0.07 s (not GC). A program with no server (4 CPU-bound threads that
    main joins) uses 1.97 CPUs at `SPINEL_WORKERS=2` on 2026.09.12 and 0.99
    on 2026.11.04.7026, which needs 3 for 1.97. **The roles
    therefore hand Spinel `workers + 1` when `workers > 1`
    (`Application.spinel_workers`, through `Application.spinel_workers_for`,
    which also holds development to one worker)**; 1 stays 1, where main
    runs every thread itself. `config.workers` (`SPINEL_WORKERS` as CyberTrain reads it)
    keeps meaning the threads that serve requests, so "the core count" is
    right again. Same session, medians of 3 x 8 s, 2 over 1: before, +10%
    (`GET /articles`), -3% (`/articles/1`), +2% (`/style.css`), +4% (the
    comment POST); after, +24%, +44%, +22%, +44%; perf sched over 4 s
    then counts 8.0 s of CPU on the two CPUs (two helpers at 3.49 s each,
    main 0.59, the sweepers 0.36). A second effect, on latency rather
    than throughput: a thread spawned by a helper (every connection: the
    accept loop is a `Thread.new`) goes onto that helper's own queue and is
    not placed (`sched_place_unstarted` runs only for main's spawns and the
    global queue), so with two helpers the connections split 15 to 3 (9 to 8
    with the accept loop on main, as an experiment, for the same
    throughput). Both are in [docs/spinel-feedback.md](../docs/spinel-feedback.md) item L.
    Permanent (docs/spinel-feedback.md L): how Spinel is, and nothing is
    asked; no build retires this rule.
23. `spin test --regen` writes `.expected` from CRuby's output; `spin test` diffs
    the Spinel binary's output (stdout and stderr merged) against it. Tests must
    therefore be CRuby/Spinel-portable;
    FFI tests get their snapshot from the compiled binary
    (`./build/test/<name> > test/<name>.rb.expected`). CRuby is only needed for
    `--regen`, never for `spin test` with committed snapshots.
    Permanent (docs/spinel-feedback.md rule 23): how Spinel is, and nothing
    is asked; no build retires this rule.
24. A test must `require "cybertrain/test"` itself or `test "..."` fails to
    compile with an 'unsupported call' error. (On 2026.09.12 `spin test`
    compiled test programs with `--require-gate`; the `spin` of 2026.11.04.7026,
    tools/spin.rb, passes no such flag.)
    Permanent (docs/spinel-feedback.md rule 24): how Spinel is, and nothing
    is asked; no build retires this rule.
25. `String#to_i` raises `RangeError` ("integer overflow parsing ...") past
    2**63-1 instead of promoting to Bignum (verified on 2026.09.12; an
    earlier note said it saturates, which it does not). Request data that
    is parsed with `to_i` (an id, a page number) must be length-checked
    first, as Server#body_length and Request#content_length do, or a
    20-digit parameter is a 500.
    Permanent (docs/spinel-feedback.md D): how Spinel is, and nothing is
    asked; no build retires this rule.
26. `obj.attr += x` (an operator-assignment on a method call) does not compile
    inside a block or lambda ("unsupported expression: CallOperatorWriteNode");
    write `obj.attr = obj.attr + x`. It is fine at top level and in method bodies.
    On 2026.11.04.7026 the reduced program passes (status 26); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 26 is closed.
27. Socket buffers are byte strings under CRuby (ASCII-8BIT) but character
    strings under Spinel: use `byteindex`/`byteslice`/`bytesize` for every
    offset into a network buffer, never `index`/`[]`/`size`, or multibyte
    bodies shift the framing of pipelined requests.
    On 2026.11.04.7026 (2026-11-15) a socket's `readpartial`, `read(n)` and
    `read_nonblock` return ASCII-8BIT byte Strings as under CRuby (`size`
    equals `bytesize`), and Strings sliced or concatenated from them stay
    so; of the reads tried only `IO#gets` returns a UTF-8 character String
    (`size` 8 for 13 bytes; status 27). Byte offsets stay the rule: they are
    right under both.
    Kept until docs/spinel-feedback.md AW is closed; the advice to frame
    by bytes is right under both runtimes and stays after that.
28. `URI.decode_www_form_component` on a malformed escape (`%ZZ`, a trailing
    `%`) raises under CRuby but silently decodes under Spinel (2026.09.12; on
    2026.11.04.7026 the library raises ArgumentError as CRuby does, status
    28); validate escapes
    (`%` followed by two hex digits) before decoding when both must agree.
    The decoding loop (`Query.decode_valid`) therefore refuses a malformed
    escape itself, with a byte scan of its own, so `QueryMalformed` and the
    Cookies raw-value fallback behave the same on both runtimes.
    `Query.valid_escapes?` is `Request.split_path`'s pre-check, for its own
    policy: a path segment with a malformed escape stays literal instead of raising.
    Kept until docs/spinel-feedback.md rule 28 is closed.
29. Once `SafeString` (to_s/to_str) is in the program, `String#include?` with
    a polymorphic argument mis-dispatches even after narrowing the receiver;
    `String#index(needle.to_s)` works. Iterating a nullable Hash with
    `each { |k, v| }` into a typed String sink can also box the key
    (`each_key { |k| h[k].to_s }` does not).
    On 2026.11.04.7026 a probe of this shape passes (status 29); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 29 is closed.
30. Calls made from inside a stored block do not widen the callee's parameter
    types: a parameter typed `sp_int` from direct call sites silently receives a
    Symbol's internal id when a stored Proc passes `:forbidden`. Give such
    parameters a polymorphic default (`DEFAULT = [200, :ok][0]`) so they stay
    boxed, and narrow with `case value when Integer ... else ... end`.
    On 2026.11.04.7026 a probe of this shape passes (status 30); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 30 is closed.
31. `yield self` in a base-class method called on subclass instances fails at
    the C level (the yield parameter is typed as the base). Take `&block` and
    call `block.call(self)` from an ordinary method instead of yielding.
    On 2026.11.04.7026 a probe of this shape passes (status 31); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 31 is closed.
32. A `begin/rescue => e` inside a yielding method that is called from a block
    nested in another block gets a polymorphic `e` slot and fails to compile.
    Keep begin/rescue in a non-yielding method that receives the block as a Proc.
    On 2026.11.04.7026 this shape compiles and runs in a probe (status 32);
    what still fails beside it is rule 79. The rule stays for new code until
    a change retires it.
    Kept until docs/spinel-feedback.md rule 32 is closed.
33. `JSON::ParserError` is not a `StandardError` in the runtime's exception
    table: write `rescue JSON::ParserError, StandardError`, and name
    `JSON::NestingError` before both (rule 61): `rescue JSON::NestingError,
    JSON::ParserError, StandardError`.
    On 2026.11.04.7026 `rescue StandardError` and a bare `rescue` catch both
    JSON errors in a probe (status 33). The three-class clause is retired
    where status 33 says so and stays elsewhere until a change removes it
    with a framework test.
    2026-11-20, same build: the clause is gone from every file under
    `cybertrain/`; status 33 lists the changes and the compiled tests
    (test/json_rescue_background.rb and test/server.rb raise both errors
    into a `rescue StandardError`). Do not write the three-class clause in
    new code on the strength of this rule.
    Closed (docs/spinel-feedback.md rule 33): kept for its number.
34. Rule 10 is stronger than stated: two methods sharing a name on unrelated
    classes whose return types differ (`add_index` returning an Index vs an
    Array) corrupt inference even when no polymorphic receiver exists, with the
    backend error "emit_boxed_text: cannot box type". Same name ⇒ same return type.
    Not every clash breaks a program: in phase 5a (2026-11-12, Spinel
    2026.11.04.7026) a top-level `setup(&block)` and an instance `setup`
    (both nil) and a class-method `setup` that only raises compiled beside
    `CLI::Toolchain.setup` (an Integer), all called, and a test file's
    top-level `last_message` answering an Array beside `Test.last_message`
    answering a String. In phase 3 (2026-11-09, same build) a spike
    compiled and ran stand-ins of the cache's class methods beside the
    framework's existing methods of the same names with other return
    types, in one program that required the whole framework: `Cache.read`
    (String or nil) beside `BlobStore.read` (String), `Cache.write`
    (Boolean) beside `BlobStore.write` (nil), `Cache.delete` (Boolean)
    beside `Session#delete` (String or nil), and `HttpClient#request`
    beside `Test::Client#request`, each answering its own Response class.
    The framework ships them that way: every program that requires
    `cybertrain` holds the first three pairs, and an application's test
    program the fourth. If a compiler update refuses one, the remedy is a
    prefixed name (`cache_read`), as `Sse::Event`'s readers already are
    (`event_data`). The rule stands for new code; these are records.
    Kept until docs/spinel-feedback.md rule 34 is closed.
35. Mutating an object received as a plain parameter through `obj[k] = v` can
    silently do nothing once the caller sits behind a middleware chain (the
    parameter widened); put the mutation in a typed instance method on the
    object (`session.csrf_token!`) and call that.
    On 2026.11.04.7026 a probe of this shape passes (status 35); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 35 is closed.
36. Requiring a middleware whose `#call` is never reachable (never wired into a
    chain) can miscompile unrelated files (dead-code inference gap). Programs
    that require the whole framework must exercise the stack they require.
    On 2026.11.04.7026 the one shape that was written down compiles (status
    36); the rule was never reduced, so it stays.
    Kept until docs/spinel-feedback.md rule 36 is closed.
37. A Hash constant with Symbol keys and Integer values looked up with a
    polymorphic key returns a boxed value; accumulate into a typed local and
    `.to_i` on every branch to keep the result `sp_int`.
    On 2026.11.04.7026 a probe prints CRuby's result (status 37); the boxing
    cost was not looked at.
    Kept until docs/spinel-feedback.md rule 37 is closed.
38. **Ordinary Ruby visibility, not a Spinel defect.** The observed class
    method calling an instance's protected method is rejected by CRuby too.
    Expose the intended public interface; do not infer a general rule about
    all private/protected calls from this shape.
    Not a Spinel item (docs/spinel-feedback.md 1.4): ordinary Ruby; kept as
    the record the code cites.
39. `SafeString#+` must build its result in two steps (compute the piece, then
    `SafeString.new`): a case expression whose branches both construct the
    result fails under the unboxed value-type layout that SafeString gets when
    it only ever travels as a keyword argument.
    On 2026.11.04.7026 a probe of this shape passes (status 39); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 39 is closed.
40. Never define an instance method named `call` whose arity differs from the
    program's `Proc#call` sites (a 6-argument `HelperBase#call(name, args,
    kwargs, block, interp, env)` made every stored block in the same program
    fail at run time with "NoMethodError: undefined method 'call' for an
    instance of Proc": before_action/rescue_from blocks, model callbacks; a
    1-argument `call(env)` like the middleware's is harmless). Entry points
    that are not Rack-style `call(env)` get distinctive names (`helper_call`).
    On 2026.11.04.7026 a probe of this shape passes (status 40); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 40 is closed.
41. Rules 10/34 apply across files that never meet at run time: an
    `attr_accessor :target` holding an Array<Node> (template parser) next to
    `RequestHead#target` (a String, cybertrain/http/parser.rb) stops the
    compiler with "no implicit conversion of TextNode into String" as soon
    as both files are in one program. Each per-feature test requires only its
    own files, so every subsystem also needs one test program that requires
    the whole framework next to it (test/template_integration.rb) and
    exercises the stored-block paths (rule 36).
    On 2026.11.04.7026 a probe of this shape passes (status 41); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 41 is closed.
42. A lambda literal (or a local holding one) passed as a **keyword argument**
    is not marked escaping (src/analyze_pass.c ignores KeywordHashNode), so its
    parameters keep the Integer default and it silently receives garbage when
    called later (`url_resolver: ->(name, args) { ... }` gave name = 4295868465).
    Pass lambdas positionally, as `&block`, or return them from a method
    (`Gen::Routes.url_resolver`).
    On 2026.11.04.7026 a probe of this shape passes (status 42); the rule
    stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 42 is closed.
43. A `def x=(v)` on one class next to an `attr_accessor :x` on another makes
    the accessor's writer undefined at run time for a boxed receiver
    ("undefined method 'body=' for an instance of Cybertrain::Response" once
    a generated model defined `body=`). Generated models therefore keep
    `attr_accessor` for columns (names the app chooses); both classes
    spelling the method out as `def` also works. A `Cast.time_or_nil(v)`
    call whose argument is statically a Time does not compile either
    (`when String` is still compiled for it), so casting writers are out.
    On 2026.11.04.7026 neither part reproduces in a probe (status 43): the
    accessor's writer is found on a boxed receiver beside another class's
    `def body=`, and a writer calling a `Cast.time_or_nil`-shaped helper
    with a Time compiles. Generated models keep `attr_accessor` all the
    same.
    Kept until docs/spinel-feedback.md rule 43 is closed.
44. `break` out of a block whose `yield` sits inside a `begin/rescue` is
    rejected at compile time ("unsupported expression: BreakNode"); the same
    `break` compiles when the yield is guarded by `ensure` only. `return`
    inside a block passed to a user-defined yielding method ends the block,
    not the enclosing method (seen with Connection#transaction); a `return`
    inside an `each_char` block does leave the method. A `break` anywhere
    inside a block forwarded as `&block` (DB.with's) is rejected too.
    On 2026.11.04.7026 none of the three reproduces in a probe (status 44):
    the `break` past a `begin/rescue` compiles, a `return` in a block given
    to a user-defined yielding method leaves the enclosing method, and a
    `break` in a forwarded block compiles. `DB.transaction`'s block still
    must not `break` or `return`.
    Kept until docs/spinel-feedback.md rule 44 is closed.
45. Rule 32 in practice: calling a yielding method that has `rescue => e`
    (Connection#transaction) from a block nested in another block fails in
    the C compiler ("assigning to 'volatile sp_RbVal' from incompatible type
    'sp_Exception *'"). Call it from a method body or a single-level block.
    A second `ensure` in such a re-entrant yielding method broke nested
    calls at run time (the outer transaction rolled back).
    On 2026.11.04.7026 a probe of this shape, with an `ensure` beside the
    `rescue`, nested and with a failing inner call, passes (status 45); the
    rule stays for new code until a change retires it.
    Kept until docs/spinel-feedback.md rule 45 is closed.
46. Historically `Class#name` carried no namespace ("ParserError", not
    "JSON::ParserError"). 2026.11.04.7026 (2026-11-11) returned the
    qualified name for user-defined classes and for `JSON::ParserError`
    (status 46); do not
    introduce new bare-name assertions on the basis of this old symptom. Thread stacks are small:
    about 50 nested template renders (14 Ruby frames each under CRuby)
    overflow one, so the Interpreter caps nesting at 12. A Hash literal
    whose values are all Strings is typed that way; seed it with a value of
    every type it will hold (rule 9 for Hashes).
    Kept until docs/spinel-feedback.md rule 46 is closed.
47. `is_a?` on an exception object does not see its class: with `e` a
    `QueryTooDeep` caught by `rescue StandardError => e`,
    `e.is_a?(QueryLimitExceeded)` (its direct superclass) was false. Tell
    exception classes apart the way the framework always has, by rescue
    clause -- re-raising `e` into a `begin ... rescue A / rescue B` ladder
    works, but costs a second raise per use, so the framework compares full
    class names instead (Cybertrain::ClientError::CLIENT_FAULTS, which
    Controller#rescue_with_handler asks too). A `begin ... ensure ... end` as
    the last expression of a block does not type either (same C error as
    rule 32's); end the block with an explicit `nil` after it.
    On 2026.11.04.7026 both parts pass as reduced programs (status 47); the
    list of names stays.
    Kept until docs/spinel-feedback.md AE is closed.
48. `JSON::ParserError` exists only in a rescue clause. `rescue
    JSON::NestingError, JSON::ParserError, StandardError => e` compiles and
    catches it (rules 33 and 61), but the constant as a value -- `rescue_from(JSON::ParserError)`,
    `klass = JSON::ParserError` -- is "uninitialized constant
    JSON::ParserError (NameError)" when the program starts. So an app cannot
    register a `rescue_from` handler for it under Spinel; Controller#run_action
    still names it in its rescue so the handler fires under CRuby and the
    exception reaches the error pages the same way on both runtimes.
    On 2026.11.04.7026 the constant is a value: `klass = JSON::ParserError`,
    `rescue klass` and a `rescue_from(JSON::ParserError)`-shaped
    registration work in a probe (status 48, 2026-11-15). The framework's
    own `rescue_from(JSON::ParserError)` has no compiled test yet, so the
    sentence above is unverified there, not confirmed.
    2026-11-20, same build: rechecks/differing/rescue_from_json_error.rb
    registers the handler on `Cybertrain::Controller` with a block and
    with `with:`, and both answer for an action's failed `JSON.parse`
    (status 48). "An app cannot register a `rescue_from` handler for it"
    did not hold in that program; no test in `test/` covers it.
    Kept until docs/spinel-feedback.md rule 48 is closed.
49. `URI.decode_www_form_component` is quadratic on a non-ASCII String under
    Spinel (517 ms for e-acute + 50 000 bytes, 8.5 s for 200 000; linear
    under CRuby and for ASCII text: 11 ms for 400 000 "a" + "%41%C3%A9"). A
    single 1.6 MB non-ASCII key or form value would hang the binary for
    minutes. Decode by byte chunks (`Query.decode`): copy the text between
    escapes with `byteslice` and hand the decoder only the ASCII runs of
    `%XX` escapes.
    Kept until docs/spinel-feedback.md AC is closed.
50. `ensure` in a re-entrant yielding method is not safe under Spinel even for
    bookkeeping only: in Connection#transaction an `ensure @flag = true unless
    completed` ran as if the local `completed` were still false after the
    rescue clause had set it, on the nested-transaction tests (2026.09.12).
    Rule 45 again: no ensure in a yielding method; a CRuby break/return out of
    such a block therefore cannot be detected there.
    On 2026.11.04.7026 a probe with this bookkeeping `ensure` passes (status
    50, with 45's program); the rule stays for new code until a change
    retires it.
    Kept until docs/spinel-feedback.md rule 50 is closed.
51. Calling one method with both Symbol and String keys in one program
    mis-dispatches the `key.to_s` inside it under Spinel: test/router.rb's
    "params assembly order" test (Symbol keys into Params#[]/#nested/#key?)
    raised `TypeError: no implicit conversion of Symbol into String` as soon
    as another test in the same program used String keys
    (`ctx.params["id"]`, `q.key?("f")`) on the same methods; each shape
    passed alone (2026.09.12). Keep one key type per program in tests
    (Symbols, as the framework's own callers do), and treat a polymorphic
    key parameter as rule 29 territory. The same program also failed
    `Params#keys` with "undefined method 'keys' for an instance of Hash"
    once two tests called it: a method name shared with Hash (`keys`) is
    the same hazard; assert with `key?`/`[]` instead.
    On 2026.11.04.7026 a small program of both shapes prints CRuby's result
    (2026-11-15, status 51); the failure was in test/router.rb with the
    framework's `Params` and was never reduced, so the advice stays.
    Kept until docs/spinel-feedback.md rule 51 is closed.
52. `String#byteindex` raises `IndexError` ("offset N does not land on
    character boundary") under CRuby for an offset that is not on a character
    boundary of a UTF-8 String, e.g. right after `&` when the next byte is a
    stray `\x81` (`"a=1&\x81b=2"`, `"x+\x81y"`, `"%41\x81"`); Spinel's
    returns the match without checking. `String#valid_encoding?` exists under
    Spinel and agrees with CRuby, so byte-offset scans over request text
    validate the encoding once up front and treat an invalid byte sequence as
    `QueryMalformed` (a 400, like Rails' BadRequest), also after decoding
    (`%81`). Never `rescue IndexError`: that would be CRuby-only behaviour.
    Once the String is valid, every offset the scans use (0, or just after an
    ASCII byte) is a boundary. Validity is checked as UTF-8 regardless of the
    String's tag, by `Query.utf8!` (the String itself when `encoding.to_s` is
    "UTF-8", else a `dup.force_encoding("UTF-8")` copy; under Spinel every
    String is "UTF-8", so it is the same object), so a binary CRuby socket
    buffer, which is "valid" as binary, answers like Spinel's UTF-8 String:
    `"a=\xC3%A9"` (half a character raw, half escaped) is a 400 on both. A
    `Request` validates each field once (`utf8_body`, `utf8_query_string`)
    and the readers take that text (`Query.parse_valid`, `value_of_valid`),
    so a form POST validates its body once, not once per reader.
    On 2026.09.12 Spinel's `split`, `strip` and `index` accepted an invalid
    String. On 2026.11.04.7026 (probe, 2026-11-15) its `split` raises
    ArgumentError ("invalid byte sequence in UTF-8") as CRuby's does on a
    UTF-8-tagged String (a binary socket buffer is fine there), while its
    `strip` still returns the String where CRuby raises
    `Encoding::CompatibilityError`; `index` with a String needle raises on
    neither. So `Cookies.parse` cannot be fed a UTF-8 literal with a stray
    byte on either runtime (`"x\x81".split(";")` raises): test invalid
    bytes through `Query.decode`/`Cookies.decode`.
    `Request.split_path` validates the WHOLE path with `Query.utf8!` before it
    splits, so a raw invalid byte anywhere in a path is a `QueryMalformed`
    on both runtimes (and CRuby's `split` never sees a broken String). Per
    segment holding a "%": `Query.valid_escapes?` false keeps it literal, else
    `decode_valid` decodes it and checks the RESULT (`%81`). So `/%zz` is
    literal (404), `/%81`, `/\x81%zz`, `/\x81%41` and `/\xC3%A9` are 400s,
    the same on both runtimes by construction; tests pass UTF-8 literals with
    stray bytes straight to `split_path`. `valid_escapes?` still searches the
    next "%" from `i + 1`, not `i + 3` (the byte at i + 1 is a hex digit, an
    ASCII byte, always a boundary; i + 3 can be a stray byte in a String
    nobody validated).
    Kept until docs/spinel-feedback.md AD and AU are closed.
53. An exception object built with `.new("msg")` and never raised has no
    `#message` under Spinel (`undefined method 'message' for an instance of
    <its class>`, seen on a `Cybertrain::` exception subclass in review;
    `e.class.name` works). `ClientError.classify`
    is only ever called from a rescue clause, so a test of it must raise and
    rescue too (a helper method with a `rescue` clause, returning the status).
    Kept until docs/spinel-feedback.md AE is closed.
54. `Class#superclass` on a raised exception's class does not show the
    hierarchy under Spinel: walking `e.class` / `.superclass` / `.name` for a
    raised `Cybertrain::QueryTooMany` gives `Cybertrain::QueryTooMany,
    Cybertrain::QueryLimitExceeded, Cybertrain::QueryInvalid, StandardError,
    Exception, Object, BasicObject` under CRuby but `QueryTooMany, Object,
    BasicObject` under Spinel. So a "walk the ancestors' names" fallback for
    rule 47 does not exist (it would make an app's subclass of a framework
    fault a 400 on one runtime and a 500 on the other): client faults are
    listed by full name (`ClientError::CLIENT_FAULTS`) and
    `script/check-client-faults` (CRuby, run by CI) keeps the list complete.
    Kept until docs/spinel-feedback.md AE is closed.
55. An in-place String mutation through a value read out of a container does
    not reach the stored String under Spinel: after `p.set_value("id", "1")`,
    `p["id"] << "2"` leaves `p["id"]` as `"1"` (CRuby: `"12"`), and the same
    for `list(k)[0] << "x"` and a value read through `nested`. So a test must
    not assert that an append through a reader "stuck" on the writable tree
    (it depended on the runtime when this was found). `Params#merge!`,
    whose per-String copies this rule was first written about, was removed
    on 2026-11-15. On Spinel 2026.11.04.7026 a probe of three such appends
    (through a reader, through a list element, through a boxed value
    narrowed by `case`) prints CRuby's result (status 55); the caution
    stays for a test that would otherwise depend on it.
    Kept until docs/spinel-feedback.md rule 55 is closed.
56. Typing for speed (Spinel 2026.09.12; `spinel app.rb --emit-types` writes
    `app.types.json`, whose diagnostics name each method "widened to
    untyped", and `-S` shows the C):
    - `"#{v}"` always allocates and copies, even when `v` is a String.
      `v.to_s` is typed and returns the String itself, provided every
      `to_s` in the program returns a typed String (SafeString's does once
      every `SafeString.new` gets one). A parameter used only through
      `to_s` is narrowed to one caller's type (Html.escape once took an
      Integer and turned Strings into "0"): keep a `case v when String` on
      it, and pass `x.to_s` from a caller whose own parameter is otherwise
      unused, which Spinel types as an Integer (SafeString#+). On
      2026.10.27.7020 Html.escape dropped its `case`: `spin test`,
      examples/blog's tests and test/template_integration.rb's
      `--emit-types` showed no narrowing without it (docs/spinel-feedback.md
      item 2). That covers those programs, not every shape; the callers'
      `x.to_s` stays.
    - A Hash with object values boxes them, so a lookup is polymorphic; an
      object Array is typed (`sp_PtrArray`) unless the program calls
      `clear` on it anywhere, or it is an Array of the class that holds it
      (INode#ikids): then it is `sp_PolyArray`. Engine keeps Templates in an
      Array found through a String => index Hash and never calls `clear` on
      it (a re-parsed template replaces its slot).
    - A nullable object passed as a parameter is boxed; returning it from
      there makes the method's result polymorphic.
    - `String#to_sym` searches the whole symbol table linearly (hashed since
      2026.10.25-7018, docs/spinel-feedback.md). Keeping the Symbol a
      template passes rather than round-tripping through a String still
      saves the lookup.
    - `str.setbyte` writes a heap String in place; `str << int` makes a
      one-character String per call.

    Closed (docs/spinel-feedback.md item 2) for the narrowing of a
    `to_s`-only parameter; the rest is guidance for speed, not a Spinel
    item, and is kept as the record the code cites.
57. A `Mutex#synchronize` taken on every request stalls requests for seconds
    under `SPINEL_WORKERS=2` (a process-wide cache in Helpers.route_key):
    bench/run's two-core config failed about one run in two with wrk
    timeouts or a dead server, and five runs out of five passed once the
    lock was gone. Prefer request-local caches for this shape. This is not
    permission to remove synchronization from shared mutable state: a
    performance result is not a memory-safety argument. A shared cache can
    be read without mutation locks only when fully initialized before its
    readers start and not subsequently modified, or when each immutable
    snapshot is acquired through synchronization with its publisher.
    TimeZone's replaceable cache now takes the same mutex for reading the
    snapshot reference and publishing replacements; lookups on the captured
    immutable snapshot run outside it. Copy-on-write alone is not a
    publication barrier. In particular, the
    template engine's (`@template_index`, `@template_list`) used to be
    written on a template's first render, which two workers could do at
    once; `Engine.embedded` now parses every embedded template at boot
    (2026-11-05, found in review of the `SPINEL_WORKERS` fix, rule 22).
    Development's engine (`cache: false`) still writes the cache, and
    `@stamps`, on the request that renders a changed file, so development
    serves on one worker whatever `SPINEL_WORKERS` says
    (`Application.serving_workers`; the boot banner names an ignored
    count). Rejected: re-parsing on the watcher thread and swapping in a
    new engine (`Views.configure`), or copy-on-write ivars inside the
    engine. Both need a request thread to see a fully built object through
    one plain reference store, and Spinel compiles an ivar store to a plain
    C store plus the GC write barrier (`sp_gc.h` `SP_WBO`), with no
    release/acquire ordering its docs promise. The cost: development no
    longer runs requests in parallel; check parallel behaviour against a
    `cybertrain build` binary.
    Kept until docs/spinel-feedback.md item 7 is closed.
58. `Foo.new(<a String made in the argument>)` can free that String before the
    object has it (Spinel 2026.09.12): the generated `new` allocates the
    object, which may collect, and only then roots its arguments. A freshly
    made String (an interpolation, `buf` converted from a `+""` buffer,
    `code.strip`) that only the argument holds is swept: the object keeps a
    dangling pointer and a later read crashes (a use-after-free, 4 to 17% of
    the benchmark's seeding runs, found with an AddressSanitizer build:
    `spinel app.rb --cc=<wrapper running cc -fsanitize=address
    -fno-sanitize-address-use-after-scope -g> ASAN_OPTIONS=fast_unwind_on_malloc=0`).
    Bind the String to a local first, or go through an ordinary method
    (`SafeString.of`), whose parameters are rooted on entry. Changing
    allocation counts moves the window, which is why single reverts of the
    commits that exposed it all looked like fixes. Template parsing (Token,
    StrLit) had the same shape.
    Permanent (docs/spinel-feedback.md item 1): how Spinel is, and nothing
    is asked; no build retires this rule.
59. An `ffi_source` C block shares one translation unit with the runtime and
    the `ffi_func` declarations, so an `extern` there must use the types the
    compiler already emitted: `sqlite3_column_text` is `const char *` (not
    `const unsigned char *`) and an `:long` return is `long` (not `long
    long`), or the build stops with "conflicting types". Cast inside the
    function instead (`db/sqlite_ffi.rb`, `cybertrain_sqlite_column_epoch`).
    Permanent (docs/spinel-feedback.md B): how Spinel is, and nothing is
    asked; no build retires this rule.
60. A String local that is appended to inside a loop (`rest << chunk`) and
    not read in that loop is compiled as a growable buffer, and a String
    ASSIGNED to it (`rest = buf.byteslice(...)`) is copied into the buffer
    with strlen unless the source is marked binary: everything after the
    first NUL byte is lost (the server's request body, cut at the first
    NUL of every gzip upload, waited for bytes that had arrived; found with
    the real socket only, the in-process Test::Client never frames). Start
    such a local as `+""` and fill it with `<<`, which copies by the byte
    length. Interpolating a String that holds a NUL (`"#{body}"`) truncates
    it the same way; concatenate with `<<` instead. Reduced repro: a method
    assigning `rest = buf.byteslice(4, n)` then `rest << "!"` in a `while`
    prints `[97, 98, 33]` for `"ab\x00cd"` under Spinel 2026.09.12.
    The other direction is safe: a `:str` FFI argument keeps embedded NULs
    when the C callee is given an explicit length (`sqlite3_bind_blob(stmt,
    i, bytes, bytes.bytesize, -1)`, `cybertrain_gunzip_bounded(data,
    data.bytesize, ...)`); only a callee given -1 (or one that calls strlen)
    stops at the first NUL. The bytes are copied twice on the way, by
    Spinel's dup of the argument and by SQLite's SQLITE_TRANSIENT copy
    (2026.11.04.7026, test/db_blob.rb).
    Kept until docs/spinel-feedback.md rule 60 is closed.
61. `JSON::NestingError` (what `JSON.generate` raises past 100 levels, which
    a parsed document can reach: `JSON.parse` accepts 200) is a subclass of
    `JSON::ParserError` in the runtime's table, but `rescue
    JSON::ParserError, StandardError` does not catch it under Spinel
    2026.09.12 (it does under CRuby); only a clause naming it does. A
    request thread it escapes dies without running `ensure`, so the server
    leaked the socket and its connection count. Every rescue that names
    `JSON::ParserError` names `JSON::NestingError` first, and an app's
    rescue around JSON.generate of request data must too.
    Re-checked on 2026-11-15 on Spinel 2026.11.04.7026: in a small program
    `rescue StandardError` alone, `rescue JSON::ParserError` alone and
    `rescue JSON::ParserError, StandardError` each catch the NestingError
    that `JSON.generate` raises, also on a thread, whose `ensure` runs
    (rechecks/json_error_shapes.rb, json_nesting_shapes.rb). The workaround
    is retired in part on that build, in the data layer (status 33); the
    other framework files keep the three-name clause until a change
    removes it with test/server.rb and test/client_error.rb passing
    compiled. Those small programs did not show an application's rescue
    needing `JSON::NestingError`; they are not a whole application.
    2026-11-20, same build: no rescue under `cybertrain/` names
    `JSON::NestingError` ahead of `StandardError` any more (status 33).
    test/server.rb's `/deep` case (an action whose `JSON.generate` raises
    it gets a 500 and the server keeps serving) and
    test/json_rescue_background.rb (job threads and plain Threads) pass
    compiled with `rescue StandardError` alone. A thread that an exception
    does escape, and whether its `ensure` runs, was not run again.
    2026-11-21: rechecks/json_nesting_shapes.rb and the section of this
    rule in rechecks/json_error_shapes.rb went when the rule was closed;
    their last run is status 61.
    Closed (docs/spinel-feedback.md rule 61): kept for its number.
62. A method defined in Ruby source with the name of a builtin method
    (`getbyte`, `puts`, `read`, `gets`, `close`, `write`, `<<`) changes how
    every call of that name on a **boxed** receiver compiles: a switch over
    the classes that define it, with NoMethodError as the default and no
    fallback to the builtin. Spinel's openssl package is such source
    (`OpenSSL::Buffering#getbyte` and the rest, mixed into SSLSocket; zlib's
    GzipWriter defines `puts`), so once a program requires it, `s.getbyte(i)`
    on a boxed String raises "undefined method 'getbyte' for an instance of
    String". Reduced repro (Spinel 2026.09.12): `def plain(a) = a.getbyte(0);
    p plain({ "x" => "abc", "n" => 1 }["x"])` prints 97, and the same
    program with `require "openssl"` on top raises. An application that
    requires the openssl package had every response fail in
    `Response#to_http` this way (`HeaderName.same?` got its keys boxed),
    which the in-process Test::Client, never calling to_http, did not show.
    The reduced probe passed on 2026.11.04.7026 (2026-11-11); retain the
    workaround pending affected-program tests. Inspecting generated C is supporting
    evidence, not a substitute for executing the path:
    `spinel prog.rb -c -o /tmp/x.c` and
    `grep 'sp_raise_nomethod(sp_nomethod_msg("getbyte"' /tmp/x.c` (the
    enclosing C function names the Ruby method; a parameter typed `sp_RbVal`
    is a boxed one). What boxes a String parameter: one call site passing a
    nullable or boxed value (a header lookup that can return nil, a value
    out of `JSON.parse` or out of a Hash of mixed values); `case v when
    String then v`, which returns the boxed `v` (Cast.str); a method
    returning its boxed argument; the keys of an unseeded `{}` (rule 9); and
    an untyped user `to_s` (SafeString's, in a program that never built
    one), which leaves every `v.to_s` in the program untyped. The remedy, in
    every method that scans a network or user String byte by byte: read the
    parameter through a NEW local, `s = text.to_s`, at the top (for a String
    it is the String itself, no copy). Reassigning the parameter (`text =
    text.to_s`) does not help: the local keeps the parameter's boxed slot
    and the call still raises. Any name the program defines behaves this
    way, not only openssl's: `@headers.keys` on a boxed Hash compiled to a
    switch over a model's `Errors#keys` (rule 51), so Response#drop_header
    iterates with `each_key`. `cybertrain/html.rb` builds
    `SafeString::EMPTY` so that SafeString#to_s is typed String in every
    program; test/openssl_dispatch.rb is the regression program.
    Kept until docs/spinel-feedback.md rule 62 is closed.
63. Locals of the same name in different top-level blocks share one type.
    In a test program, `form = { "content-type" => ... }` in one `test do`
    block and `form = req.multipart_form` in another box both, and with them
    every parameter the values are passed to: `Request.new`'s headers and
    body became `sp_RbVal`, `Query.utf8!` received a boxed body, and its
    `raw.to_s` (rule 62) returned a copy, so a test asserting
    `req.utf8_body.equal?(req.body)` failed. Nothing raised. The program
    was test/http_request.rb, once the multipart tests were added
    (2026-10-22): `form` / `gz` / `identity` had been a Hash in one block
    and a Request, a String or a MultipartForm in another. Give a local a
    name no other block in the file uses for a different type, and check a
    signature in the C (rule 62's `spinel prog.rb -c`) when a test of
    identity or of a typed path starts failing after an unrelated
    addition.
    Kept until docs/spinel-feedback.md rule 63 is closed.
64. Class variables are not GC roots under Spinel 2026.09.12: `@@x` compiles
    to a C static (`cvar_<Module>_x`) that `sp_mark_user_globals` never
    marks, while a module-level `@x` (`civ_<Module>_x`) and a constant are
    marked. An object reachable only from a `@@x` is freed by the first
    collection after it is allocated, and its memory is reused. The test
    harness kept its cases in `@@cases`: an application's test program that
    booted and migrated a database before `run!` had the Array swept and
    "ran" the migration's operation objects as tests (`ERR ...: undefined
    method 'block'`); a reduced program crashes with "undefined method
    'name' for an instance of Array". Never hold an object in a class
    variable in code Spinel compiles: use a module-level `@x` with `def
    self.x` accessors (rule 18) or a constant. (An Integer `@@count` is
    stored unboxed and survives, but follow the rule anyway.)
    test/harness_gc.rb is the regression program; check a suspect file with
    `spinel prog.rb -c -o /tmp/x.c && grep -n 'cvar_' /tmp/x.c`.
    Kept until docs/spinel-feedback.md rule 64 is closed.
65. In one argument list, a method call's result is not rooted while a later
    argument allocates (Spinel 2026.09.12). `File.join(home, "spinel",
    "#{tag}.lock")` compiles to `sp_file_join((const char*[]){
    sp_Toolchain_s_home(), ..., ({ ...sp_str_alloc_raw... }) }, 3)`: the
    String `home` returned lives only in a C temporary, and a collection
    inside the interpolation's allocation frees it, so File.join reads
    freed memory (a wrong lock path, then "expected condition to be
    falsy" in test/cli_toolchain.rb, on macOS CI only). C leaves the order
    of the arguments unspecified, so `foo.gsub("#{x}/", "")` can be hit the
    same way: gcc built the interpolation first and called `foo` after it.
    A receiver counts as the first argument: `read(path).sub("A\n",
    "A\n#{line}")` freed the file's text in test/cli_attachment.rb ("has no
    `class ArticlesController < ApplicationController` line", also macOS
    only). Make the allocating argument first, in a local, and pass the local:
    `name = "#{tag}.lock"; File.join(home, "spinel", name)`. Reproduce with
    an AddressSanitizer build (rule 58) run under `SPINEL_GC_STRESS=1`,
    which collects every 2 KB of strings; shift where the collections land
    by running from TMPDIRs whose names differ in length.
    Permanent (docs/spinel-feedback.md item 1): how Spinel is, and nothing
    is asked; no build retires this rule.
66. A String local that a method appends to directly two or more times
    (`buf << "\n"; buf << tail`) loses whatever helpers appended to it
    through a parameter in the same method (Spinel 2026.09.12): the local
    is compiled as a buffer of its own, and `add(buf, "ab")` before the
    direct appends wrote to something else. Reduced repro: `def add(buf, s)
    = buf << s` and `def two; buf = "".b; add(buf, "ab"); buf << "\n"; buf
    << "\n"; buf; end` prints `"\n\n"` (CRuby: `"ab\n\n"`); one direct
    append alone is fine. Rule 60's cousin. A buffer filled through helpers
    is filled only through helpers (`put_str(buf, "\n")`, as
    test/time_zone.rb's TZif writer does). Re-checked on 2026-11-11: on
    Spinel 2026.11.04.7026 the reduced repro prints `"ab\n\n"`, as
    CRuby does (docs/spinel-feedback.md, "Rule 66").
    Separately, and not reduced: an instance method spelled `def name` on
    `Cybertrain::TimeZone` made test/template_integration.rb (the whole
    framework) fail at run time with "undefined method 'name' for an
    instance of Class" (rule 62's dispatch hazard; the framework calls
    `.class.name` on boxed receivers). A ten-line program with a `def name`
    class and `x.class.name` on a boxed value did not fail, so the trigger
    is something else in the framework. The reader is `zone_name`; a new
    framework class should not define `name` as a plain method.
    Kept until docs/spinel-feedback.md rule 66 is closed.
67. A yielding method is never emitted as a C function: Spinel inlines it at
    each call site whose receiver it knows. Called on a boxed receiver it is
    therefore NoMethodError at run time (the dispatch `switch` has no case),
    and a `case recv when Klass` around the call does not change that. The
    `c` a `Cybertrain::DB.with` block receives is boxed (it comes out of the
    pool's SizedQueue), so `DB.with { |c| c.transaction { ... } }` raised
    "undefined method 'transaction' for an instance of
    Cybertrain::DB::Connection" (2026-10-25, issue #67); the yielding method
    has to be called on a typed receiver (`Connection.new`'s result, as the
    migrator does). `DB.transaction` and `Connection#begin!` / `commit!` /
    `rollback!` (plain methods) are the forms for a pooled connection.
    Kept until docs/spinel-feedback.md rule 67 is closed.
68. A block that reads a parameter of an enclosing block does not compile
    when it is a Proc (taken as `&block` and called with `block.call`) and
    the enclosing block itself sits in another block: "'lv_i__bpN'
    undeclared" in the C. test/db_sqlite.rb's `5.times do |i| DB.with { |c|
    ... [i] } end` inside a `test do` block stopped compiling as soon as
    DB.with called `block.call` on one path, and a `3.times do |i|
    DB.transaction { ... i ... } end` written straight into a test block
    failed the same way; the same loop in a method body (two levels, as in
    an action) compiles (2026-10-25). Keep framework methods that every
    application nests deeply (DB.with) yielding, and hoist such loops into a
    method.
    Kept until docs/spinel-feedback.md rule 68 is closed.
69. A method that takes `&block` and calls `block.call` is inlined at its
    call sites like a yielding one, so a rescue or ensure in it hits rules
    32/45 ("incompatible types when returning type 'sp_RbVal' but 'sp_int'
    was expected" for an ensure). Pass the Proc one level down as a plain
    parameter and call it there (Controller#process / #run_action,
    DB.transaction / DB.run_transaction). Not two levels: a Proc passed on
    again (DB.transaction -> Pool -> Connection, 2026-10-25) was called with
    an argument whose class the block's parameter never learned, so every
    method call on that parameter inside the block was NoMethodError at run
    time (a dispatch with only a `default:`); calls from a helper method the
    block passes it to still worked, since the helper learned the class from
    its other callers, which is how a test can miss it. Test such a block
    with a method call written in the block itself.
    On 2026.11.04.7026 a small program with both shapes (an `ensure` and a
    `rescue` in a `&block` method, and a Proc called two levels down with
    one user class) prints CRuby's result (2026-11-15, status 69). The
    two-level failure was seen in the framework and never reduced; the
    one-level form stays.
    Kept until docs/spinel-feedback.md rule 69 is closed.
70. `rescue DB::Error => e`, with `DB = Cybertrain::DB` at the top of a test
    program, compiled to a match on the names "Error" / "DB::Error" in a
    program that requires the whole framework (test/db_transaction_api.rb,
    2026-10-25), so it never caught a raised `Cybertrain::DB::Error`; in
    test/db_transaction.rb, which requires only the db files, the same
    clause matches the full name. Spell the full name in a rescue clause.
    Not re-run with the alias on 2026.11.04.7026 in a whole-framework
    program (status 70 has a small probe). 2026-11-20: three clauses that
    named `Cybertrain::DB::Error` ahead of `StandardError` (Stream::Poller.tick,
    HealthCheck.feed_rows, FeedTableWriter#status_withdraw) are now
    `rescue StandardError`, which catches the error compiled
    (test/health.rb, test/features_feeds.rb); HealthCheck.database_ok?
    keeps the full name. The rule is about the short name and stays.
    Kept until docs/spinel-feedback.md R is closed.
71. Narrowing does not type a return value: `case v when Hash then v else
    {} end` on a polymorphic `v` (a `JSON.parse` result) is
    `(untyped) -> untyped` in `spinel --emit-rbs` (2026.09.12), so every
    call on what it returns stays on the boxed slow path (and in rule 62's
    reach). Copying into a seeded container types it: with `out` a
    `{ "" => [nil, 0, 0.0, "", true][0] }` minus its seed key, `case v
    when Time then nil when Hash then v.each { |k, x| out[k.to_s] = x }
    end; out` is `-> Hash[String, untyped]` (Cybertrain::Cast.hash /
    Cast.array, issue #74; the `when Time` arm they carried for rule 8 was
    retired on 2026.11.04.7026, see that rule's status, and without it the
    copy is typed the same, status 71). Two shapes
    that the same probe confirmed compile and behave as under CRuby: a
    splat parameter taking mixed types (`Cast.binds(1, "x", nil, Time)`,
    also with no arguments), and a class method inherited from a base
    class that calls an overridden class method on implicit self
    (`Model.upsert` reading each subclass's `table_name`).
    Kept until docs/spinel-feedback.md rule 71 is closed.
72. Outbound sockets under Spinel 2026.09.12 (cybertrain/net/socket.rb):
    `Socket.getaddrinfo(host, port)` works and answers CRuby's arrays, but
    an unresolvable name gives `[]` instead of raising `SocketError`, and an
    entry cannot be indexed (`entry[3]` is "unsupported call", even after
    `case entry when Array`): read the fields by destructuring the block
    parameters, `list.each { |_f, _p, _n, ip, family, socktype, _pr| ... }`.
    `Addrinfo` and `IPSocket.getaddress` do not exist, nor
    `Socket#bind(sockaddr)`. `Socket.new(AF_INET, SOCK_STREAM, 0)` +
    `connect_nonblock(Socket.sockaddr_in(port, ip), exception: false)` +
    `wait_writable(t)` (nil on timeout) is the bounded connect; read the
    outcome with `getsockopt(SOL_SOCKET, SO_ERROR).int`, because a second
    `connect_nonblock` raises a bare `SystemCallError` (CRuby: the Errno
    class), `SystemCallError#message` has no strerror text, and
    `Errno::ECONNREFUSED::Errno` does not compile. `read_nonblock` /
    `write_nonblock` with `exception: false` answer `:wait_readable` /
    `:wait_writable` / nil at EOF as in CRuby and keep NUL bytes; comparing
    the boxed result with `== :wait_readable` works. To make a connect hang
    in a test, `TCPServer#listen(0)` and fill the queue: after one queued
    connection the kernel drops further SYNs (10.255.255.1 is not
    unroutable in every sandbox). That is Linux: macOS's kernel queued more
    than the backlog asked for or answered with a reset (CI's macOS job), so
    test/http_client.rb tries up to 1024 connects and falls back to
    192.0.2.1 (TEST-NET-1); a silent TLS peer is a server that accepts and
    never writes, not a connection left in the queue. Also macOS:
    `localhost` resolves to `::1` first, so a client that dials only the
    first address is refused by a server on 127.0.0.1 (the socket layer
    dials every resolved address). In the openssl package, a handshake error
    is raised even with `exception: false`; `SSL_CTX_set_default_verify_paths`
    honours `SSL_CERT_FILE` / `SSL_CERT_DIR` (the only way to trust another
    CA: there is no `X509::Store`); CRuby's `SSLContext.new` defaults to
    `VERIFY_NONE` and the package's to `VERIFY_PEER`, so call `set_params`
    for both to agree. Since the HTTP client, test/template_integration.rb
    has the whole framework and the openssl package in one program, and
    there rule 62 caught two more byte scans that only that combination
    boxes: `Query.split_key` and `BlobStore.valid_key?` (both now read
    through a `to_s` local). `TCPSocket.new(host, port, connect_timeout:
    t)` is not a bounded connect: the keyword is read by no code path and
    the connect blocks until the kernel gives up (checked 2026-11-05 on
    2026.11.03.7025 and 2026.11.04.7026; docs/spinel-feedback.md O).
    Current-pin update (probe, 2026-11-15, Linux, 2026.11.04.7026;
    rechecks/outbound_socket_shapes.rb): an unresolvable name raises
    `SocketError`, `entry[3]` indexes an entry, `IPSocket.getaddress` and
    `Addrinfo.tcp(host, port).ip_address` exist and answer as under CRuby,
    a second `connect_nonblock` on a refused socket raises
    `Errno::ECONNREFUSED`, whose message carries strerror text ("Connection
    refused @ connect - "; CRuby's wording differs), and
    `Errno::ECONNREFUSED::Errno` compiles. So the 2026.09.12 gaps listed at
    the top of this rule are closed in a small program; `Socket#bind(sockaddr)`,
    the openssl notes and macOS were not re-checked. net/socket.rb keeps
    its forms (destructuring, `SO_ERROR`) until a change removes them with
    its tests, and `connect_timeout:` is still ignored (status 72).
    Kept until docs/spinel-feedback.md O and rule 72 are closed.
73. An instance variable first assigned in a helper method that `initialize`
    calls, rather than in `initialize` itself, is typed as a boxed value
    (`sp_RbVal`) even when every assignment is a String (Spinel
    2026.09.12), and reading it through its `attr_accessor` as a keyword
    argument's default (`def initialize(host: Cybertrain.config.smtp_host)`)
    stops the C compiler: "incompatible types when initializing type 'const
    char *' using type 'sp_RbVal'". Reduced repro: `class Conf; attr_accessor
    :name; def initialize; init_rest; end; def init_rest; @name = ENV["X"] ||
    ""; end; end` and `def show(name: Conf.new.name) = puts(name.bytesize)`;
    the struct has `sp_RbVal iv_name`. Assign every ivar in `initialize`
    (Config's `smtp_*` settings, cybertrain/mailer.rb, issue #64).
    Kept until docs/spinel-feedback.md rule 73 is closed.
74. A constant a subclass inherits from its superclass is not found by its
    bare name in the subclass's methods once another class anywhere in the
    program defines a constant of the same name (Spinel 2026.09.12): the
    compiler warns "uninitialized constant X: defined nowhere in the
    program (raises NameError when reached)" and the method raises
    NameError at run time; CRuby finds it through the ancestors. Reduced
    repro: `module M; class Elsewhere; LIMIT = 99; end; class Base; LIMIT
    = 7; end; class Sub < Base; def hook = LIMIT; end; end; p
    M::Sub.new.hook`; without `Elsewhere` it prints 7. Found with
    `Test::HttpReceiver` reading the `MAX_LINE_BYTES` it inherits from
    `Receiver` as a bare `MAX_LINE_BYTES`, next to HttpClient's and Mailer's
    constants of that name (issue #78). Spell an inherited constant with its
    owner (`Receiver::MAX_LINE_BYTES`, which is what the receivers do now),
    and read the warnings `spin test` prints.
    Kept until docs/spinel-feedback.md rule 74 is closed.
75. Files and child processes for `db backup` (Spinel 2026.09.12, issue
    #76): Kernel `spawn` was refused and `Process.wait` did not compile,
    so a child process went through `system`. `Process.spawn` and
    `Process.wait` work since 2026.11.04.7026 (test/rate_limit_store.rb).
    The body of this rule was cut on 2026-11-21; all it held is in
    docs/spinel-feedback.md, "Rule 75".
    Closed (docs/spinel-feedback.md rule 75): kept for its number.
76. Spinel 2026.10.26.7019 resolves constants as CRuby does: a bare `DB`
    in an application class outside `module Cybertrain` (`class
    SessionsController < ApplicationController; def x = DB.with { ... }`)
    compiles without a warning and raises "uninitialized constant
    SessionsController::DB (NameError)" when reached; 2026.09.12 found
    `Cybertrain::DB` there by accident (issue #27). Code outside `module
    Cybertrain` (the app, generator templates, tests, README snippets)
    writes `Cybertrain::DB`, `Cybertrain::Job`, `Cybertrain::Password` and
    so on, or aliases one at the top (`DB = Cybertrain::DB`, as the tests do).
    Permanent (docs/spinel-feedback.md rule 76): how Spinel is, and nothing
    is asked; no build retires this rule.
77. The value of a block forwarded with `&block` to a yielding method lost
    an application class once the program's blocks for that method
    returned different types (Spinel 2026.10.26.7019, issue #27), so an
    object computed in a `DB.with` block went through a local declared
    before it. Fixed in 2026.10.27.7020 (matz/spinel#10415, issue #90);
    test/db_with_value.rb covers both forms. The body of this rule was cut
    on 2026-11-21; all it held is in docs/spinel-feedback.md H.
    Closed (docs/spinel-feedback.md H): kept for its number.
78. `puts` on a receiver whose type is nil-only (an ivar only ever assigned
    nil, like Logger's `@io` in a program that never passes a logger an
    io) goes through the IO dispatch, and on Spinel 2026.10.26.7019 that
    dispatch's fallback branch fails C compilation once the TLS layer is
    in the program: "passing argument 2 of 'sp_File_puts_bin' from
    incompatible pointer type" (an `sp_String *` where sp_io.h wants a
    `const char *`). It was found with `require "cybertrain/logger"`,
    `require "cybertrain/net/tls"`, `Cybertrain.logger.info("hello")`, and
    reduced on 2026-11-05 (docs/spinel-feedback.md K): `require "openssl"`,
    `class Lg; def initialize = (@io = nil); def log(line); @io.puts(line)
    if @io; nil; end; end`, `Lg.new.log("hello")`; what it takes is a
    String held in a variable as the argument. Seeding the ivar with a
    StringIO (rule 9) did not help, because the nil-only parameter keeps
    the slot boxed, and neither did narrowing with `case io when
    StringIO`: the boxed `puts` dispatch was emitted either way. `write`
    compiles through the same dispatch with the right argument type, so
    `Logger#write_now` calls `@io.write(line)` on a line that already ends
    in a newline.
    On 2026.11.04.7026 (2026-11-15 and 2026-11-19) the reduced program
    still failed in the C compiler
    (rechecks/nil_only_puts_openssl.rb). The framework's own
    three lines no longer showed it: with `@io.puts(line)` put back into
    the `Logger#write_now` of 2026-11-19 they compiled and logged, and
    test/logger_tls.rb, written as the regression program, built and
    matched its snapshot too. So the logger's present shape is evidence
    neither way, and that test no longer guards the workaround; `write`
    stays until docs/spinel-feedback.md K is closed.
    Kept until docs/spinel-feedback.md K is closed.
79. A yielding method with a `rescue` clause, given a block whose only
    expression is `raise`, does not compile when its value is appended
    (`out << g { raise "b" }`): "variable or field '_sp_fv' declared void"
    in spinel_rt.h (Spinel 2026.11.04.7026). Reduced repro: `def g; yield;
    rescue => e; e.message; end`, `out = []`, `out << g { raise "b" }`, `p
    out` (CRuby: `["b"]`); `p g { raise "b" }` and `p h(g { raise "b" })`
    compile, and so does a block that can also return a value (`raise "b"
    if x > 0; "ok"`). Found while re-checking rule 32. In a test of a
    rescuing helper, give the block a value after the raise or pass the
    result through a method.
    2026-11-21: test/test_lifecycle.rb's bodies and test/console.rb's
    rescuing-caller case are written the plain way; the typed value after
    a `raise` in cybertrain/console.rb is rule 124's, not this rule's.
    Closed (docs/spinel-feedback.md rule 79): kept for its number.
80. Never wait for another connection's SQLite lock inside the SQLite call
    on the request path: an FFI call holds its OS worker for as long as it
    runs, with or without `blocking: true`, and with one worker
    every green thread is on that OS thread. (2026.09.12 accepted and
    ignored the option. On 2026.11.04.7026 it brackets the call with
    `sp_native_enter` / `sp_native_leave`, lib/sp_sched.h, so that a
    collection raised meanwhile does not wait for it; the worker's other
    green threads still wait. Checked on 2026-11-13 with a C function that
    sleeps 0.6 s: at `SPINEL_WORKERS=1` the main thread's first 0.05 s
    sleep came back only once the call had returned (`ticks=1` in the
    program of docs/spinel-feedback.md AB), with the option and without
    it; at `SPINEL_WORKERS=2` it counted ten in the same 0.5 s.) A transaction that holds the
    write lock and parks its green thread (I/O, a `sleep`, a safepoint)
    then cannot reach its COMMIT while a second writer sits in the busy
    handler, which slept 100 us at a time inside `sqlite3_step` for about
    5 s: every request stalled for those 5 s and the second write failed
    with "database is locked" (reproduced by test/db_busy_wait.rb,
    saeki-mototsune/CyberTrain#134, 2026-11-05). The busy handler now only
    records that SQLite asked to wait and returns 0, and
    `Connection#step_waiting` / `#exec_waiting` retry after a green-thread
    `sleep` (100 us doubling to 1 ms, 5 s in all), which lets the holder
    run. "Asked" is the retry signal: SQLite calls the handler only when
    waiting can help, so a BUSY it was not asked about (a stale WAL
    snapshot) still fails at once. Only the first step waits (a statement
    takes its locks before it changes or returns anything), and only
    single statements are retried: a multi-statement `exec_script` (schema,
    migrations, the WAL switch at open) and ROLLBACK still wait in C,
    since a script refused half way cannot be re-run from the top.
    A statement in a transaction SQLite already rolled back on its own
    (FULL / IOERR / BUSY / NOMEM, rescued by the application inside the
    block) is refused rather than run in autocommit, where it would commit by
    itself (`Connection#refuse_if_transaction_gone`, saeki-mototsune/CyberTrain#158,
    reproduced with `PRAGMA max_page_count` in test/db_rolled_back_transaction.rb).
    A transaction opened with SQL (`exec_script("BEGIN")`) is covered too:
    a statement that started inside a transaction and failed with SQLite
    back in autocommit marks the connection (`@transaction_lost`; a
    constraint error leaves the transaction open and marks nothing), and
    only COMMIT, END or ROLLBACK (not ROLLBACK TO a savepoint) run until
    then, told apart by a small lexer over the first statement's leading
    keywords that skips whitespace, comments and quoted names as SQLite's
    tokenizer does (substring checks missed `ROLLBACK /* ; */ TO s` and
    `ROLLBACK` + line break + `TO s`). That ROLLBACK is skipped, since
    running it would raise "no transaction is active" over the
    application's own error. `exec_script` runs a script one statement at
    a time (`cybertrain_sqlite_prepare_at`, SQLite's own parser splitting
    the text, trigger bodies included), reading SQLite's transaction state
    before each statement, so a BEGIN anywhere in a script is seen and a
    BEGIN that fails marks nothing (saeki-mototsune/CyberTrain#164;
    sqlite3_exec showed the state only before and after the whole script)
    (test/db_raw_transaction_rollback.rb). A prepare that fails is checked
    the same way, since SQLite can roll back while it reads the schema
    (IOERR / NOMEM). No real SQLite does that on demand, so the test
    overrides `Connection#prepare_next` in a subclass that rolls back
    before preparing (saeki-mototsune/CyberTrain#167).
    Kept until docs/spinel-feedback.md AB is closed.
81. A relative constant path in a `rescue` clause whose first segment names
    a module that holds a class of the same name is not found: inside
    `module Cybertrain::Console`, `rescue Template::SyntaxError => e`
    (`Cybertrain::Template` holds the class `Cybertrain::Template::Template`)
    compiles with only the warning "uninitialized constant Template: defined
    nowhere in the program", and at run time the whole `begin` swallows the
    exception without running any clause, not even a later `rescue
    StandardError` (Spinel 2026.11.04.7026; CRuby rescues it). The same path
    outside a rescue clause (`Template::Interpreter.new`) resolves.
    Reduced repro: `module Outer; module Inner; class Inner; end; class Oops
    < StandardError; end; def self.boom = raise(Oops, "x"); end; end`, then
    in `module Outer; module User` a method with `begin; Inner.boom; rescue
    Inner::Oops => e; s = "oops"; rescue StandardError => e; s = "std";
    end`: CRuby takes the first clause, Spinel neither (without `class
    Inner` inside `Inner` both agree). Spell a rescued class from the top
    (`rescue Cybertrain::Template::SyntaxError => e`, as Interpreter does),
    and read the warnings `spin test` prints (docs/spinel-feedback.md R,
    the third shape; still so on 2026-11-11).
    Kept until docs/spinel-feedback.md R is closed.
82. A lambda literal assigned to a module-level instance variable in the
    module body (`module V; @b = ->(c) { H.new(c) }; end`) never learns the
    argument types of its call sites (Spinel 2026.11.04.7026): its
    parameter keeps the Integer default, so `V.b.call(controller)` handed
    `H.new` a garbage Integer and the first method call on it raised
    "undefined method 'session' for an instance of Integer"
    (test/template_integration.rb, once `Views.helpers_builder` was
    called by Controller#render_template). The same lambda returned by a
    method (`def self.default_b = ->(c) { H.new(c) }; @b = default_b`), or
    a literal passed positionally to the setter at top level
    (`V.b = ->(c) { H2.new(c) }`, what gen/helpers.rb does), types its
    parameter from the `.call` sites. Rule 42's cousin: create a stored
    lambda in a method or pass it positionally, never as a module-body
    ivar initialiser that is called with arguments
    (docs/spinel-feedback.md Y; still so on 2026-11-11).
    Kept until docs/spinel-feedback.md Y is closed.

83. `gets` on STDIN does not flush a pending partial line on STDOUT under
    Spinel 2026.11.04.7026; flush before reading. CRuby flushes STDOUT
    before it blocks on a terminal read, so `STDOUT.write("A> "); STDIN.gets`
    shows the prompt first; the compiled program, run on a pty, prints
    nothing until the line has been typed and then `A> ` after it. Reduced
    repro: `STDOUT.write("A> "); line = STDIN.gets; STDOUT.write("got
    #{line}")` under a pty (found by review of `./app console`, whose `>> `
    prompt only appeared after each line). `STDOUT.flush` after the write
    shows it at once; Console.run flushes after the banner and every prompt
    (a StringIO answers flush too).
    Kept until docs/spinel-feedback.md M is closed.
84. A call to a class method that no class in the program defines is
    refused at compile time, even from a method nothing calls: `module
    Cybertrain; end`, `def f = Cybertrain.config.port`, `puts(ARGV.size >
    5 ? f : 0)` prints `0` under CRuby and is refused by Spinel
    2026.11.03.7025 and 2026.11.04.7026 ("undefined method 'config' for a
    Class: no class in the program defines a class method 'config'
    (NoMethodError)"; checked 2026-11-05). An undefined *constant* in the
    same place is only a warning ("uninitialized constant ... (raises
    NameError when reached)") and raises when reached. The refusal is by
    design (`CR_NOMETHOD` in src/codegen_util.c: a NoMethodError found
    ahead of time; docs/spinel-feedback.md, "A refusal of a never-reached
    class-method call"). So a test program that loads part of the
    framework must require every file whose class methods its code names,
    reached or not: code that says `Cybertrain.config` needs `require
    "cybertrain/config"`. `--defer-refusals` (or `# spinel:
    defer-refusals` at the top of the file) builds it anyway, but what is
    raised when the call is reached is NotImplementedError, not CRuby's
    NoMethodError, so a test cannot rescue it as CRuby would.
    Permanent (docs/spinel-feedback.md rule 84): how Spinel is, and nothing
    is asked; no build retires this rule.

85. `Queue#pop(timeout: seconds)` works under Spinel 2026.11.04.7026 as
    under CRuby: it answers the next element, or nil once the timeout has
    passed, and parks the green thread while it waits (another thread's
    `q << x` wakes it; checked with a reduced program, a Queue of a user
    class, one pushing thread spawned through a method as rule 21 says).
    So a connection thread waits for its next message with it (the stream
    hub's Subscriber#stream_pop, cybertrain/stream/hub.rb) and needs no
    ConditionVariable. A nil element would be indistinguishable from the
    timeout: push a sentinel object instead and look at a flag after the
    pop (Subscriber#stream_offer on a dropped subscriber).
    Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works; kept
    as the record the code cites.

86. A Range under Spinel 2026.11.04.7026 carries Integer ends only.
    `t1..t2` or `Range.new(t1, t2)` with Time or Date ends raises
    `TypeError: no implicit conversion of Time into Integer` when the Range
    is built; a Float or String Range reads back directly
    (`(1.5..2.5).begin`), but a Float Range held in a Hash value or passed
    through a boxed parameter is not matched by `when Range` (a String
    Range was not matched either in the spike's test program when this was
    found; in a 2026-11-15 probe on the same build it is matched from a
    Hash value and through a boxed parameter, status 86). So
    `where(col: a..b)` (phase 2, relation.rb) accepts Integer ends only and
    other bounds go through `where_between(col, from, to)`; the validator
    options `inclusion: { in: }` and `exclusion: { in: }` take an Integer
    Range or an Array (validator.rb; docs/spinel-feedback.md Q).
    Kept until docs/spinel-feedback.md Q is closed.

87. Class methods added to a core class from Ruby source compile and
    dispatch: `class Time; def self.iso8601(text) ...` is reached by
    `Time.iso8601(s)`, including a method literally named `strptime`, whose
    earlier compile-time refusal was of the missing method, not of the name
    (cybertrain/time_ext.rb). Instance methods are a different matter
    (rule 62).
    Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works; kept
    as the record the code cites.

88. A stored block called with a base-class receiver calls the base
    class's method, not the subclass's override, under Spinel
    2026.11.04.7026. With `Base#run` doing `cb.call(self)` over blocks
    registered as `add { |r| r.hook }` in `class Sub < Base`, and `hook`
    defined on both (a nil stub on Base, the real one on Sub),
    `Sub.new.run` runs Base#hook; CRuby runs Sub#hook. Without the Base
    stub the call reaches Sub#hook (the shape of every `before_save { |r|
    r.title = ... }`). A call on implicit self inside a Base method
    (`destroy_dependents` from Model#destroy) dispatches to the override as
    expected. So a method that only callback blocks call has no stub on
    Cybertrain::Model: the generated `counter_cache_created` / `_destroyed`
    / `_was` / `_moved` (test/gen_models_compiles.rb covers them). Found
    while writing declared associations (2026-11-06;
    docs/spinel-feedback.md Z has the reduced program, still so on
    2026-11-11).
    Kept until docs/spinel-feedback.md Z is closed.

89. A `rescue` arm naming a qualified class the program does not define
    does not raise NameError when the arm is tried, as CRuby does: Spinel
    2026.11.04.7026 resolves the arm by its last segment. With `module
    Outer` defined, `rescue Outer::Missing => e` catches a top-level
    `Missing` if there is one and otherwise never matches, with no compile
    warning (an `Outer::Missing` in an expression does raise NameError).
    With `Outer::Gone` undefined and a class whose name is the last segment
    defined anywhere in the program, `rescue Outer::Gone::TimeoutError => e`
    turns the whole `begin`/`rescue` into a catch-all that runs no arm and
    swallows every exception (the only sign is the warning "uninitialized
    constant Outer::Gone: defined nowhere in the program"); with no such
    class anywhere it raises NameError as CRuby does. Classes that are
    defined resolve by their full name: `rescue A::TimeoutError` and
    `rescue B::TimeoutError` side by side each catch their own. Found in the
    phase 3 spike (2026-11-09), before the mailer integration: at that
    point `require "cybertrain"` did not load cybertrain/mailer, so an arm
    naming `Cybertrain::Mailer::TimeoutError`
    in such a program swallowed every exception its method raised, another
    framework `TimeoutError` supplying the last segment
    (spikes/phase3/rescue_arms.rb, deleted since). Reduced repro:
    `module Outer; module Net; class TimeoutError < StandardError; end; end; end`, `class AppError
    < StandardError; end`, a method with `begin; raise AppError, "boom";
    rescue Outer::Mailer::TimeoutError => e; ...; rescue AppError => e; log
    << "arm"; end` called inside `begin ... rescue StandardError => e; log
    << e.class.name; end`: CRuby logs NameError, the compiled program logs
    nothing. So generated `rescue` arms
    (`run_job`'s `retry_on` / `discard_on`) name only classes the program
    is known to define, and Spinel's "uninitialized constant" warning on a
    `rescue` line is treated as an error. The full framework now loads the
    mailer through `cybertrain/mailer/later`; that old missing-require
    example is historical, but partial programs and generated rescue arms
    still need the class-definition check.
    Kept until docs/spinel-feedback.md R is closed.

90. A `yield` passed straight as a method's argument runs the block twice
    when the block returns different types at different call sites
    (Spinel 2026.11.04.7026): with `C.str(v)` a `case v when nil ...
    when String then v else v.to_s end`, `def self.f = C.str(yield)`
    called once with a block answering a String and once with a block
    answering an Integer, the String block's side effects happen twice;
    with the same type at every call site it runs once. Reduced program
    (CRuby prints `one 42 a`, the compiled program `one 42 a,a`):
    `module C; def self.str(v); case v; when nil then ""; when String
    then v; else v.to_s; end; end; end`, `module M; def self.f;
    C.str(yield); end; end`, `N = Array.new(0) { "" }`, `a = M.f do; N
    << "a"; "one"; end`, `b = M.f { 42 }`, `puts "#{a} #{b}
    #{N.join(",")}"`. The `&block` form (`C.str(block.call)` in a method
    taking `&block`) ran the block once in the same program. Found in
    phase 3 (2026-11-09): cybertrain/cache.rb's `fetch` stored
    `Cast.str(yield)` and its test saw a block that records its call run
    twice (`fetch` is called with String blocks and an Integer one). So
    assign a yield's value to a local before passing it to a method
    (`computed = yield; value = Cast.str(computed)`), as Cache.fetch,
    fetch_hash, fetch_array and fetch_int do (docs/spinel-feedback.md S).
    Kept until docs/spinel-feedback.md S is closed.

91. `exit` called on a thread other than the main one ends only that
    thread under Spinel 2026.11.04.7026; CRuby raises `SystemExit` there,
    which ends the process with the status. Reduced program (CRuby exits
    1 with no output, the compiled program prints `main still alive` and
    exits 0): `def die_later(code); Thread.new { sleep(0.2); exit(code) };
    end`, `die_later(1)`, `sleep(1.0)`, `puts "main still alive"`. Found in
    phase 3 (2026-11-09), when the feed supervisor was to exit a `feeds`
    process after repeated feed deaths: a background thread that must end
    the process signals the main thread instead
    (`Background.feeds_failed?`), and the main thread stops the feeds and
    returns the status (`Roles::FeedsRunner#run_feeds_threads`,
    cybertrain/roles/feeds.rb; the flag is in
    cybertrain/background/supervisor.rb). `Thread#join` on a thread that
    died of an exception re-raises it, as under CRuby (checked in phase 3, 2026-11-09),
    so the framework joins feed and supervisor threads in plain methods
    that rescue `Exception` (rules 32 / 45).
    Kept until docs/spinel-feedback.md T is closed.

92. A block that never runs is still compiled, and an implicit-self call
    in it is resolved against the `self` of the code around the block:
    in a module body, the module. Spinel 2026.11.04.7026 refuses such a
    call when that module has no method of the name, even though another
    class defines it (`before_action` is a class method of
    Cybertrain::Controller) and CRuby, never running the block, never
    looks: `module AdminGate; extend ActiveSupport::Concern; included do
    before_action :require_admin, only: [:index]; end; end`, with
    `ActiveSupport::Concern#included(base = nil, &block)` doing nothing,
    is refused with "unsupported call: ... (CallNode `before_action`)
    recv=-/ty-1", 1 refusal, nothing written (the ahead-of-time
    NoMethodError of rule 84, met from a receiver Spinel knows). So
    `ActiveSupport::Concern` defines a no-op instance method (a singleton
    method of every concern that extends it) for every declaration a
    concern's `included` block may make, with the framework declaration's
    parameters; with `before_action`, `helper_method` and `rescue_from`
    stubbed the program builds and the declarations gen splices into the
    including class work. Found in the phase 4a spike (2026-11-10,
    spikes/phase4/concern_class_methods.rb, deleted since).
    Stubs are not enough for a call no stub covers: phase 4a
    found `included do; scope :visible, -> { where(hidden: 0) }; end` in a
    model concern refused at the bare `where` inside the lambda, with
    `scope` stubbed and `method_missing` defined (stubbing Relation's
    methods on the concern would break rule 34), and a controller
    concern's `before_action { redirect_to "/" }` is the same shape. So
    gen never compiles the blocks: it writes each concern to
    `gen/concerns/<path under app/>` with its `included` and
    `class_methods` blocks blanked line for line, the application loads
    those copies, and `gen/concerns.rb` splices the blocks' bodies into
    the including classes (docs/design.md D60). The stubs stay, for a
    program that requires a concern's own file.
    Permanent (docs/spinel-feedback.md rule 92): how Spinel is, and nothing
    is asked; no build retires this rule.

93. A `def` inside a block is compiled as a method of the code around the
    block whether or not the block ever runs (Spinel 2026.11.04.7026):
    CRuby defines it only when the block runs, and then on the block's
    `def` target. Reduced program (CRuby prints `false false`, the
    compiled program `true false`): `module Concern; def
    class_methods(&block) = nil; end`, `module Gate; extend Concern;
    class_methods do; def per_page = 50; end; end`, `class C; include
    Gate; end`, `puts "#{C.new.respond_to?(:per_page)}
    #{Gate.respond_to?(:per_page)}"`. So a concern's `class_methods do
    def x ... end end` also gives every including class an instance method
    `x` under Spinel when the block is compiled as written. The class
    method itself comes from gen's `def self.x` on the concern and
    forwarder in the class (docs/design.md D60). gen refused a
    `class_methods` name that an instance method of the concern or of an
    including class has until 2026-11-21; it no longer does, since the
    generated copy has the block blank (test/gen_concerns.rb and
    test/gen_model_concerns.rb hold those shapes compiled). Found in the
    phase 4a spike (2026-11-10; docs/spinel-feedback.md U). The final
    generated concern copies blank these blocks before compilation (rule
    92); the phantom instance-method description applies to compiling the
    original source, not to a claim that generated copies still expose it.
    Kept until docs/spinel-feedback.md U is closed.

94. Type inference that does not converge: Spinel 2026.11.04.7026 stopped
    compiling examples/blog's `bin/gen.rb` with "type inference did not
    converge in 128 rounds" once `Gen::Runner.run` held the results of two
    lexical scans of `app/controllers` (the controllers' and the
    concerns') in locals and passed both to two emitters; bisected to that
    change (phase 4a, 2026-11-10), not reduced further. Each emitter
    now scans for itself (`Runner.controllers_source`,
    `concerns_source`), so `app/controllers` is read twice. When the
    message appears after a change that threads one value through several
    methods, reduce the failing shape first. Repeating these read-only
    scans is a local workaround, not a rule to recompute arbitrary values:
    repeated I/O, stateful operations or time-dependent reads may change
    semantics. Preserve the workaround until an integration test permits
    sharing the result safely.
    Kept until docs/spinel-feedback.md X is closed.

95. A keyword parameter named after a Ruby keyword (`if:`, `unless:`,
    `module:`) cannot be read by name in the method body, under CRuby or
    Spinel; `binding.local_variable_get(:if)` reads it, and that compiles
    and returns the argument on Spinel 2026.11.04.7026, with the
    parameter's type: `Controller.rate_limit(..., if: nil, unless: nil)`
    and the routes DSL's `scope(path = "", module: "", as: "")` use it
    (phase 4a Tasks 2 and 13, 2026-11-10).
    Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works; kept
    as the record the code cites.

96. `Time#strftime(pattern)` with a pattern built at run time (not a
    String literal), on a receiver that the program also holds as a Date
    (a Time narrowed by `case value when Time` from a slot that can hold
    either), returns the pattern itself, unformatted, on Spinel
    2026.11.04.7026: the polymorphic dispatch reads the pattern into the
    runtime's shared string buffer and the caller then takes the stale
    buffer. The literal-pattern form works. So `time_tag`'s `format:`
    (`Template::Helpers.time_tag_strftime`) walks the pattern itself and
    calls `strftime` with a literal for each directive it supports,
    raising for an unknown one (phase 4a, 2026-11-11). Since
    phase 4b the walk is `Cybertrain::Strftime.walk(time, pattern, label, zone)`
    (cybertrain/strftime.rb; `zone`, the TimeZone a Time at offset 0 is
    rendered in, since phase 5a), which `time_tag_strftime` and `I18n.l`'s
    dictionary formats both call, so it loads without the template layer.
    Kept until docs/spinel-feedback.md V is closed.

97. A String held in an instance variable, passed as an argument to a
    stored lambda that may append to its argument (`a proc.call`), is
    refused by Spinel 2026.11.04.7026 ("a String is passed through `a
    proc.call` ..."), while a fresh local holding the same text is
    accepted. It showed only in the blog's program, through
    `Views.component_builder.call(@name, ...)`; the framework passes an
    interpolated copy (`"#{@name}"`) there. For this String/possibly-mutating
    lambda shape, use an independently owned local copy and preserve the
    caller's mutation semantics; a plain local alias is not evidence that
    the same workaround works. Do not generalize this to every ivar/type
    passed to a stored lambda (phase 4a,
    2026-11-11; compare rule 82).
    Kept until docs/spinel-feedback.md W is closed.

98. A C file that Spinel wrote (`spinel prog.rb -c -o x.c`, such as the
    rule 62 grep's output) left anywhere in a package's tree is not
    compiled: spin prints "x.c is spinel's own output and was NOT
    compiled", asks for it to be deleted or moved out, and counts it as a
    change of the package, so the next `spin run gen` of an application
    that depends on the package rebuilds its generator (checked on
    2026-11-11 with `spin run gen -- --check` in examples/blog, which
    still exited 0). Write such files outside the package (the build
    directory, or a `TMPDIR` outside it) and delete them after the grep.
    Permanent (docs/spinel-feedback.md rule 98): how Spinel is, and nothing
    is asked; no build retires this rule.

99. **Ordinary Ruby, not a Spinel defect** (corrected 2026-11-13: CRuby's
    `dup` is shallow in the same way, and a probe of the shape below
    prints the same under CRuby 3.3.6 and compiled by 2026.11.04.7026,
    where a class's `initialize_copy` is also called as under CRuby). The
    record stays for what a class has to do about it.
    `dup` on an instance of a user-defined class compiles without a
    `dup` method in the class, on Spinel 2026.11.04.7026, and is a shallow
    copy: the new object has its own Integer, Boolean and String slots
    (assigning `@limit` on one leaves the other), but an Array ivar is the
    same Array in both, so `copy.where(...)` on a `rel.dup` appended to
    the source's `@wheres` and `@binds` as well. Nothing warns. A class
    whose instances are meant to be copied defines `dup` itself, building
    a new instance and filling the new instance's own Arrays element by
    element (the generated `<Model>Relation#dup`, design D72); such an
    override compiles and is dispatched on the static type (issue #188,
    2026-11-11, seen by removing the generated method under
    `test/relation_dup.rb`: seven of twelve tests fail).
    Not a Spinel item (docs/spinel-feedback.md 1.4): ordinary Ruby; kept as
    the record the code cites.

100. `Float#round(n)` does not answer the same on every path under Spinel
    2026.11.04.7026. On a Float local it agrees with CRuby (`x.round(2)`
    with `x = "1.005".to_f` is 1.01: CRuby rounds the product and then
    corrects a tie the binary product fell short of). On a Float narrowed
    by a `case`/`when` inside a method whose scale is a parameter, followed
    by `.to_f` (`f = case v when Float then v when String then v.to_f else
    0.0 end; f.round(scale).to_f`, the body `Cast.round_scale` had), it
    goes through the runtime's polymorphic rounding, which rounds the
    binary product and stops: 1.005, 1.015 and 0.285 came back as 1.0,
    1.01 and 0.28 where CRuby answers 1.01, 1.02 and 0.29
    (spikes/decimal/float_round.rb prints both). Both runtimes also move a
    value that needs no rounding once it has 17 significant digits
    (`123456789012345.67.round(2)` is ...69). So a result that must be the
    same decimal under both runtimes is not rounded with `Float#round(n)`:
    round on the digits of `Float#to_s`, as `Cybertrain::NumberHelper` does
    and, since issue #189 (2026-11-11), `Cast.round_scale`
    (`Cast.round_digits`; docs/design.md D73). `Float#round` with no
    argument (an Integer) was not seen to differ.
    The same spike found what the exact types offer on this Spinel
    (spikes/decimal/exact_types.rb): Integer is 64-bit and raises
    `RangeError` ("integer overflow in +") past it, where CRuby grows a
    bignum; `Rational` compiles and adds; the pre-installed `bigdecimal`
    package now builds a BigDecimal from a String or an Integer, rounds
    with every mode, compares, and compiles beside `cybertrain/db`, but has
    no `to_s("F")` (ArgumentError at run time: `to_s` takes no format, the
    only text is `0.125e2`), no `bigdecimal/util` (`to_d`), no
    construction from a Float, no NaN or Infinity.
    Kept until docs/spinel-feedback.md AF is closed.

101. A large Hash literal constant compiles slowly: Spinel 2026.11.04.7026
     writes the literal as one C function (the program's main body) with
     one inlined store per entry, and cc at -O2 is slow on so long a
     function. 1,980 String pairs took 12.5 to 15.2 s to build, nearly all
     of it cc (`spinel --timing`: cc_total 13.2 s; analysis and C
     generation under 0.1 s), against 4.5 to 4.7 s for a `case` over the
     same keys; the same Hash filled at load by 40 methods of 50 stores
     each (`def self.fill_00(h) h["k"] = "v" ... h end`, then `TEXTS =
     Gen::Locales.texts.freeze`) builds in 4.7 to 5.4 s and answers lookups
     as fast (34 to 52 ns). So generated code writes a large table as
     small fill methods, never as one literal (gen/locales.rb; phase 4b
     spike, 2026-11-11, spikes/phase4b/locale_hash.rb and
     locale_hash_split.rb; docs/spinel-feedback.md AI). The shipped emitter
     (cybertrain/generator/locales_emitter.rb) names them
     `fill_texts_NN` / `fill_lists_NN` and the builders `text_table` /
     `list_table`, one name per return type; cybertrain/locales/bundled.rb
     has the same shape (cross-checked 2026-11-12, test/gen_locales.rb).
     Kept until docs/spinel-feedback.md AI is closed.

102. A thread-local Symbol beside a Connection: on Spinel 2026.11.04.7026,
     `Thread.current[:cybertrain_i18n_locale] = :ja` in a program where
     the db pool stores a Connection under another key
     (`Thread.current[TRANSACTION_KEY]`) compiles, and each green thread
     reads back its own Symbol after `sleep 0` while another thread set a
     different one (also with `SPINEL_WORKERS=4`); a key never set reads
     nil. A record of a form that works, not of a defect: `I18n.locale`
     is kept this way (phase 4b spike, 2026-11-11,
     spikes/phase4b/thread_locale.rb).
     Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works;
     kept as the record the code cites.

103. Stored lambdas answering String or nil, and a yield with `ensure`:
     on Spinel 2026.11.04.7026 a lambda returned by a method
     (`def self.resolver = ->(key) { Gen::Locales.lookup(key) }`, the
     `case` answering a String or nil) and passed positionally to a
     setter (rules 42 and 82) keeps nil when called with a local key, in
     a program where another module's `resolver` returns a lambda
     answering a String (gen/assets.rb's); and a module function that
     saves a value, yields into a local (rule 90), restores in `ensure`
     and returns the local compiles and restores for blocks answering a
     String or an Integer, a block that raises and one whose only
     statement is `raise` (rule 79's block, which fails only when the
     yielding method itself rescues). A record of forms that work:
     `I18n.install_dictionary` and `I18n.with_locale` (phase 4b spike,
     2026-11-11, spikes/phase4b/dictionary_lambda.rb, which also nests
     `with_locale` three deep). The shipped gen/locales.rb answers from a
     Hash (`TEXTS[key]`, rule 101) rather than the spike's `case`, through
     the same lambdas; test/gen_locales.rb and test/i18n.rb compile it
     (cross-checked 2026-11-12). Also working (phase 5a, 2026-11-12): a
     top-level yielding method that forwards its block as
     `Mod.f(x) { yield }` to such a module function, nested two deep with
     an inner raise rescued by a rescuing yielder (`assert_raises`):
     `travel_to { }` over `Clock.travel_during` (test/clock.rb).
     Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works;
     kept as the record the code cites.

104. Ruby's own exception classes answer no `superclass` on Spinel
     2026.11.04.7026 in a program that defines a module:
     `e.class.superclass` for a rescued `RuntimeError` raises "undefined
     method 'superclass' for module RuntimeError (NoMethodError)", and so
     do the namespaced built-ins (`Errno::ENOENT`, `JSON::ParserError`,
     `Math::DomainError`), which do answer their qualified `Class#name`
     (rule 46). Narrowed on 2026-11-15: in the programs tried, one
     `module Pkg; end` line was what made the difference (a package or a
     framework file brings one, and `require "json"` had the same effect).
     The same program without that line, or with a top-level class in its
     place, walks `ArgumentError < StandardError < Exception < Object <
     BasicObject` as CRuby does (rechecks/builtin_superclass_no_module.rb),
     which is why a five-line program does not show it. Only a walk that
     starts at a built-in class fails. A class the program defines answers
     its whole chain, through its built-in ancestors up to BasicObject
     (`Pkg::Mine < ArgumentError < StandardError < ...`), in the program
     where the built-in start fails
     (rechecks/builtin_superclass_with_module.rb); this record
     first said "up to its first built-in ancestor", which those runs do
     not bear out. It is rule 54's failing half, extended from a package's
     classes to the core ones. So a walk up an exception's ancestry that
     can start at a built-in class must not call `superclass` on one:
     `assert_raises(Class)` stops at the first built-in class and reads
     the rest from a table of parents checked against CRuby, with
     `Test::BUILTIN_PARENTS` and the `Errno::` prefix
     (cybertrain/test/assertions.rb), and fails naming a built-in class it
     does not know rather than ending in that NoMethodError (phase 5a
     spike, 2026-11-12; spikes/phase5/assert_raises.rb,
     test/assertions.rb; docs/spinel-feedback.md AJ). `rescue Exception
     => e` in a yielding method catches every class probed, ScriptError
     and NotImplementedError included.
     Kept until docs/spinel-feedback.md AJ is closed.

105. A call of an undefined instance method on a typed receiver is
     refused at build ("undefined method 'month' for an instance of
     Integer", "1 refusal, nothing written") only while no class in the
     program defines a method of that name. Once one does (here
     `ZonedTime#month`), the call compiles to a run-time `NoMethodError`
     with that message, as under CRuby, which a `rescue StandardError` in
     a yielding method catches. Rule 84's refusal is for class methods;
     this instance-method counterpart is not a guard an API can rely on,
     so `1.month` is documented as failing when it runs (phase 5a spike
     item 2, 2026-11-12, Spinel 2026.11.04.7026;
     spikes/phase5/durations_month.rb, test/durations_refused.rb).
     Permanent (docs/spinel-feedback.md rule 105): how Spinel is, and
     nothing is asked; no build retires this rule.

106. A method named like a builtin `Time` instance method (`hour`, `day`,
     `min`, `wday`, `zone`) defined in Ruby source, on another
     class (`Cybertrain::ZonedTime`) or on `Time` itself, does not break a
     boxed `Time` receiver on Spinel 2026.11.04.7026: the generated
     dispatch switch covers the classes that define the name and its
     default arm calls the builtin Time's method before raising (the C has
     one `sp_raise_nomethod` per name, each in that default arm). A record
     of a form that works, refining rule 62 (whose reduced program also
     passes): `ZonedTime` keeps Rails' reader names (phase 5a spike,
     2026-11-12; spikes/phase5/durations.rb's header has the greps).
     Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works;
     kept as the record the code cites.

107. What `e.backtrace` answers depends on the build on Spinel
     2026.11.04.7026: a release build answers an empty Array, `-g` one
     `<main>:1` frame, and `--debug` a `file:line:in 'Mod.meth'` frame per
     Ruby method on the way, with `<main>` always at line 1 and no frame
     for a builtin's own raise. A `--debug` build (which is -O0) compiled
     the probe in 11 s against the release build's 23 s, and served about
     45% of the release build's in-process request rate. So the test runner names a failing test by
     the line of its `test` call, never by the assertion's line, and an
     error report carries a backtrace only from a debug build (phase 5a
     spike, 2026-11-12; spikes/phase5/backtrace.rb;
     docs/spinel-feedback.md AM).
     Kept until docs/spinel-feedback.md AM is closed.

108. Tool behaviour: `spin run gen` rebuilds the application's
     `build/bin/gen` whenever any `.rb` file under the package is newer
     than the binary, `test/**` and gen's own outputs (`gen/tests.rb`)
     included: identical inputs print "build gen (up to date)", and one
     rewritten `gen/tests.rb` costs a full rebuild of about 55 s on the
     next run (checked 2026-11-12 with spin of Spinel 2026.11.04.7026, in
     test/fixtures/test_app). So in an application every edit of a test
     rebuilds the generator before `cybertrain test` compiles the bundle
     (docs/spinel-feedback.md AL; design D83).
     Kept until docs/spinel-feedback.md AL is closed.

109. A parameter, keyword or positional, that defaults to nil and that
     some caller gives a plain Time is compiled by Spinel 2026.11.04.7026 as
     a non-nullable Time: its `nil?` is the constant false (`if
     (((void)(lv_expires), 0))` in the C), so the call that relies on the
     default passes NULL on and dies with SIGSEGV (`sp_time_year(NULL)`,
     `sp_time_utc` in the framework). `def stamp(expires: nil)` with
     `return "none" if expires.nil?` crashes once one caller passes
     `Time.at(0)`; a positional `def stamp(expires = nil)` crashes too;
     callers passing a String work (a String pointer is nullable), and so
     do callers that pass a value typed Time-or-nil
     (`given = cond ? Time.at(0) : nil`, `Cast.time_or_nil(...)`). So do
     not write `def f(t: nil)` with a `t.nil?` check when any caller passes
     a Time: give it a non-nil sentinel default and test for both nil and
     the sentinel (`Cookies::NO_EXPIRES`, `Time.at(-1).utc`), or make every
     caller pass a Time-or-nil value. Found when test/client.rb passed
     `expires: Clock.now + 120` to `Cookies.serialize` beside calls without
     it (phase 5a, 2026-11-13; spikes/phase5/nil_default_time.rb crashes,
     exit 139, where CRuby prints `none` and `1970`;
     spikes/phase5/nil_default_time_fixed.rb, the sentinel, passes; the
     regression program is test/client.rb; docs/spinel-feedback.md AN).
     examples/blog never crashed: `CookieJar#assign_cookie` passes
     `Cast.time_or_nil(...)`, and remember me uses `max_age:`.
     Kept until docs/spinel-feedback.md AN is closed.

110. A statement `case` (its value unused) on a plain Integer can compile
     with an undeclared temporary on Spinel 2026.11.04.7026. A statement
     `case` on a nullable Integer (a `getbyte` value) in a method compiled
     earlier leaves a "nullable subject" mark that Spinel keeps by
     temporary NUMBER across methods, not per method; when a later
     statement `case` on a plain Integer gets the same number, Spinel
     declares only `sp_int _tN = ...` but switches on `_oN.nil ? 0LL : _tN`,
     and gcc stops at `'_oN' undeclared` (clang: "member reference base
     type 'sp_int' is not a structure or union"). Which programs fail
     depends on whole-program type inference: test/test_render_inline.rb
     and test/test_classes.rb failed (`'_o24' undeclared` in
     `HtmlReader.parse`, at `case kind`) while test/test_html.rb, loading
     the same file, built (phase 5a, in CI, 2026-11-13).
     Commit 50bbcb8 reshuffled the code before that case, which only moved
     the number: it fixed one program and not the others. So shared
     framework code does not use a statement `case` on a plain Integer
     local: it uses an `if x == 1 / elsif x == 2 / else` chain (as
     `HtmlReader.parse` does now); a `case` used as a method's value
     compiled. Still open: the case whose mark leaks is `Html.escape`'s
     `case b`, so any other statement `case` on a plain Integer compiled
     after it can fail the same way when the numbers line up (CI builds
     every program, so it shows as a build failure, not wrong behaviour).
     Reduced program: spikes/phase5/case_nullable_temp.rb (as written it
     does not compile, `'_o1' undeclared`, where CRuby prints `amp` and
     `long`; with the methods in the other order it compiles; with both
     cases as return values it compiles; docs/spinel-feedback.md AO).
     Extended in phase 5b (2026-11-13): new
     framework code writes no statement `case` on any Integer, a
     `getbyte` value included, since a nullable subject is what leaks the
     mark and a plain one is what it breaks; the byte scanners of
     cybertrain/logger.rb, middleware/request_id.rb, sentry_dsn.rb and
     error_reporter/sentry.rb are `if` chains. A `case` used as a method's
     value is written only where existing code already does it.
     Kept until docs/spinel-feedback.md AO is closed.

111. A registry of features, an Array of base-class instances whose
    overridable hooks are called on each element, compiles and dispatches
    to each subclass's override under Spinel 2026.11.04.7026 (a2d06115,
    GCC 13.3.0, Linux x86_64, no flags), as the optional subsystems
    need (docs/design.md D85; cybertrain/feature.rb). Checked on
    2026-11-13 at 6876ae6 with
    spikes/phase6/feature_registry.rb and feature_registry_ba.rb (the same
    checks with the two feature files required in the other order),
    standalone programs with no framework: each compiled (4 s), exited 0
    and printed CRuby 3.3.6's output line for line (the programs' headers
    have it); the two orders differ only in the line that prints the
    registration order. Shape by shape, all passing:
    - Hooks on the base `Feature` returning String, Bool (base `false` and
      base `true`), Integer, nil, a typed empty Array of String, and a
      `Response` (a class with ivars) or nil; one return type per hook
      name across every override (rules 10, 34, 41).
    - Two subclasses in two files, each overriding a different subset and
      registering one instance into a module constant Array at require
      time; in either require order the same features answer. A second
      `require_relative` of a feature file registers nothing, and an
      explicit `Registry.register(FeatureA.new)` after it is refused by
      the guard on `feature.class.name` (answers false, size stays 2).
    - Dispatch over the Array: collecting Strings (`while` and `each`),
      `any?` / `all?` over Bools and a `while` that returns early, the
      first answer that is not -1, the first non-nil Response, a Response
      passed through each feature's filter and returned, nil hooks run for
      their effect, an Array hook flattened.
    - A hook overridden in one subclass only (`health_problem`, FeatureA):
      FeatureB runs the base stub (`b=""`).
    - The periodic hook run from stored blocks, both a scheduler-style
      Array of Task objects holding a block and a bare Array of blocks,
      each block's body only `Registry.run_periodic(i, Clock.now)` (the
      index a parameter of the method that stores the block); the module
      method indexes the Array and calls the hook: FeatureB#periodic runs.
    - Reopening a class defined in the core file from a feature file with
      an instance method (reading the core's ivar) and a class method;
      both are called (rule 87 has class methods added to a builtin class).
    The contrast, spikes/phase6/feature_registry_rule88.rb, stores blocks
    that call the periodic hook on a Feature-typed receiver: captured from
    a method parameter, the block's own parameter (`cb.call(feature)`, rule
    88's form), and that block written in a reopened feature subclass's
    body. All three reach FeatureB#periodic, as under CRuby, and so do
    run_periodic and a direct call in the same program. Rule 88's own
    reduced program (docs/spinel-feedback.md Z) still prints `""` on this
    build, so what triggers it is narrower than "a stored block with a
    base-class receiver": spikes/phase6/rule88_order.rb stores the same
    block `{ |r| r.hook }` written in three places and calls each with an
    instance of two subclasses that override `Base#hook`. Written at top
    level, or in a subclass's body after that subclass's `def hook`, it
    dispatches to each override; written in a subclass's body *before*
    that subclass's `def hook` it runs `Base#hook` for both receivers
    (`base stub, base stub`; CRuby: `early override, late override`). The
    call is bound to the base's method at that point in the class body,
    not dispatched. Rule 88's `add { |r| r.hook }` is that shape. Which
    module stores the block, and whether `add` is called on implicit self
    or on another module, does not matter (reductions with a separate
    `Store` module fail the same way). The framework's
    `Features.run_periodic(i, now)` is clear of it either way; a feature
    file must still not write a block that calls a hook inside its class
    body ahead of the hook's `def` (registering at the end of the file,
    outside the class, as the spike does, is safe).
    In the framework since (2026-11-13): one hook may answer several
    classes when its base raises instead of returning: `feature_helper`
    (base: `raise RuntimeError`) answers a SafeString, a String or a
    Template::TurboStreamBuilder from StreamsFeature, and
    test/features_streams.rb, stream_endpoint.rb, turbo_helpers.rb and
    template_integration.rb pass compiled; and probe features subclassing
    a Feature subclass (`ProbeA < ProbeFeature < Feature`, registered at
    run time) dispatch to their overrides (test/features_order.rb).
    Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works; kept
    as the record the code cites. It narrows Z.

112. `File#flock` and the stat of an open file (2026-11-13, Spinel
     2026.11.04.7026; spikes/phase5/flock_fstat.rb prints both runtimes'
     lines). `File::LOCK_EX`, `LOCK_SH`, `LOCK_NB` and `LOCK_UN` exist
     (2, 1, 4, 8), and `flock` answers 0 on success and false, without
     raising, when `LOCK_NB` cannot have the lock, as under CRuby; two
     opens of a file in one process conflict (flock is per open file
     description), and closing the descriptor, or the process dying,
     drops the lock. Two differences from CRuby: `File#stat` on an open
     File stats its path, not the descriptor (after the path is unlinked
     and recreated it answers the new file's inode, or raises ENOENT), and
     `IO.for_fd(fd, autoclose: false)` makes a dup of the descriptor whose
     `stat` is the descriptor's fstat(2), but which stays open, keeping the
     flock alive after the original closes, until it is closed itself.
     `File.for_fd` does not exist. So the fstat of an open File is
     `IO.for_fd(f.fileno, autoclose: false)`, its `stat`, then its `close`
     under Spinel, and plain `f.stat` under CRuby, where closing the
     for_fd IO would close f's descriptor (`CLI::BuildLock#descriptor_id`).
     Kept until docs/spinel-feedback.md AT is closed.

113. A rescuing yielder with one `rescue` clause around the yield,
     `value = nil; begin; value = yield; rescue JSON::NestingError,
     JSON::ParserError, StandardError => e; ...; value = nil; end; value`,
     compiles and behaves as under CRuby on Spinel 2026.11.04.7026 in every
     shape phase 5b tried: called from a method body, from a block nested in
     a block at the top level and in a method, through a forwarding block
     (a method whose body is `Cybertrain.error.handle { yield }`), with
     blocks answering a
     String, an Integer and nil, a block whose only statement is `raise`,
     and with `next v` (the block answers `v`), `break v` (the yielder
     answers `v`) and `return v` (returns from the method around the block)
     inside the block. A record of a form that works, refining rules 32, 45
     and 79 for this shape: `Cybertrain.error.handle` is written so
     (phase 5b spike, spikes/phase5/error_names.rb at framework
     19668bc, 2026-11-13, deleted since; test/error_reporter.rb's "handle
     through a forwarding block, with next, and nested in blocks" since).
     Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works;
     kept as the record the code cites.

114. Under `SPINEL_WORKERS=1` a `sleep 0` does not switch green threads on
     Spinel 2026.11.04.7026: four threads started through a method, each
     calling `sleep 0` between storing and reading its own value, ran one
     after another, so a test meant to read after another thread wrote saw
     no other thread run. A timed sleep (2 ms) did switch them (phase 5b
     spike, spikes/phase5/thread_scope.rb, 2026-11-13). So a test
     that must interleave threads sleeps for a time, or better meets
     through Queues (`inbox.pop(timeout: 5)` parks the thread whatever the
     worker count, rule 85), as test/logger_scope.rb and
     test/logger_threads.rb do; and a test of a race needs more than one
     worker to fail at all (rule 116).
     Permanent (docs/spinel-feedback.md rule 114): how Spinel is, and
     nothing is asked; no build retires this rule.

115. A performance observation, the contrast to rule 57: a process-wide
     `Mutex` held only for one `write` (and `flush`) of a line built
     before it was taken cost nothing measurable on Spinel 2026.11.04.7026.
     examples/blog built twice at framework 19668bc
     (spikes/phase5/logger_lock/run.sh, `FRAMEWORK_REV`), once with
     `Logger::LOCK.synchronize { STDOUT.write(line); STDOUT.flush }` and
     once without the lock, served under `taskset -c 0,1` with
     `SPINEL_WORKERS=2`, the request log on and stdout into a pipe, five
     10-second runs each: medians 1,590 and 1,581 requests a second
     (100.6%), no request over 1 s, no error (phase 5b spike,
     2026-11-13; the header of spikes/phase5/logger_lock/run.sh has every
     run). The limits of that
     measurement: the load was the spike's own CRuby loader with 8
     keep-alive connections, not wrk (not installed) at its higher rates,
     where rule 57's stalls showed; stdout was a pipe read promptly, so a
     slow or blocked reader (a full pipe, journald, `docker logs`) was not
     tried, and a write that blocks holds every thread that logs until it
     returns; and the CRuby comparisons of the phase 5b spikes stand DB,
     Job and Lease in with stand-ins. So `Logger` keeps its lock, held for
     the one write only, with nothing logged or built inside it (design
     D86); rule 57 still keeps every other lock off the request path.
     Not a Spinel item (docs/spinel-feedback.md 1.4): a measurement; kept as
     the record the code cites.

116. Four threads writing into one `StringIO` with no lock abort the
     program on Spinel 2026.11.04.7026 when `SPINEL_WORKERS=4`: "double
     free or corruption (!prev)" (exit 134) in four runs of five and a
     SIGSEGV in the fifth, where CRuby (whose lock around each call
     serializes them) prints the joined size. With one worker the same
     program finishes (reduced program spikes/phase5/stringio_threads.rb,
     2026-11-14; docs/spinel-feedback.md AQ). Found when test/logger_threads.rb
     was run against a logger without its lock (phase 5b): the failure
     there showed as a crash, not as interleaved lines.
     So a StringIO (or any object) that several threads write is written
     under a lock (the Logger's `LOCK` covers the test loggers' StringIO
     too), and a test of a race sets `SPINEL_WORKERS` above 1 before its
     first thread, or it cannot fail.
     Kept until docs/spinel-feedback.md AQ is closed.

117. `pop(timeout:)` on a `Queue` that was put in an Array is compiled as
     `Array#pop` on Spinel 2026.11.04.7026: `inboxes = [Queue.new,
     Queue.new]; inboxes[1].pop(timeout: 5)` raises "no implicit
     conversion of Hash into Integer (TypeError)" (the keyword Hash taken
     as Array#pop's count). Binding the element to a local first, or
     passing it to a method that pops its parameter, fails the same way. A
     Queue that never goes into an Array, kept in a local or a constant and
     passed as a parameter, pops as under CRuby (reduced program
     spikes/phase5/queue_in_array.rb, its header has the variants,
     2026-11-14; docs/spinel-feedback.md AP). Found in phase 5b
     (test/logger_scope.rb's concurrent `tagged` test, whose threads each
     get their two Queues as parameters).
     Kept until docs/spinel-feedback.md AP is closed.

118. Thread tests: a handshake that relies on the other thread not
     running yet passes under CRuby, where the GVL runs one thread at a
     time and switches rarely, and fails compiled, where the threads run
     on several workers at once. Found in phase 5b (test/error_reporter.rb):
     a delivery thread blocked in a subscriber is released by tokens on a
     Queue; a spare token left from one phase let a later delivery through
     early compiled, never under CRuby. So a test pushes exactly as many
     release tokens as deliveries it expects (`101.times { RELEASE << "go" }`
     for 101 queued events), empties its token Queues between phases and
     in `setup`, and waits on a Queue (`STARTED.pop(timeout: 5)`) rather
     than on a flag or a sleep. Like rule 114, a matter of how a test is
     written, not a defect: CRuby is the runtime that hides it.
     Not a Spinel item (docs/spinel-feedback.md 1.4): advice on writing
     tests; kept as the record the code cites.

119. A write to a frozen Array or Hash raises `FrozenError` compiled, as
     under CRuby, on Spinel 2026.11.04.7026: `Logger::NO_SCOPE`'s tags and
     context are frozen, and `scope_tags << "x"` and `scope_context["k"] =
     "v"` on it raise `FrozenError` in the compiled test/logger_scope.rb
     (phase 5b, 2026-11-13). A record of a form that
     works: freezing is how the framework keeps a shared constant
     container from being written (`assert_raises("FrozenError") { ... }`
     there).
     Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works;
     kept as the record the code cites.

120. Tool behaviour: `spin test FILE` rebuilds a test's binary only when
     a source is newer than it. A compile that read the sources before
     they changed writes a binary newer than the changed files, and later
     runs reuse that stale binary without rebuilding: in phase 5b a commit
     was cherry-picked into a worktree while `spin test test/error_reporter.rb`
     compiled it, and the run then reported 14 tests of a file that had 19
     (2026-11-13, spin of Spinel 2026.11.04.7026). Deleting
     `build/test/<name>` forces the rebuild. So the sources of a package
     are not changed while a compile of it runs, and a count that does not
     match the file is checked against the binary's age first (compare
     rule 108, spin's freshness check for `bin/gen`).
     Permanent (docs/spinel-feedback.md rule 120): how Spinel is, and
     nothing is asked; no build retires this rule.

121. A reader typed `String or nil` and a method of the same name typed
     `String`, in two unrelated classes of one program, compile and run on
     Spinel 2026.11.04.7026: a nullable String is the same String pointer
     (rule 109 says so of a parameter), so rules 10 and 34's "one return
     type per method name" holds for the pair. A record of a form that
     works: a generated model's nullable `release` reader (a text or binary
     column) beside `Cybertrain::Config#release`, and its `request_id`
     beside `Cybertrain::Request#request_id`, are called in one compiled
     program in test/framework_names_compiles.rb (phase 5b follow-ups,
     2026-11-14), which is why gen accepts those columns when they are
     String-typed (design D10's addendum). Other types under one name were
     not tried here: gen refuses them, as rule 34 asks.
     Not a Spinel item (docs/spinel-feedback.md 1.4): a form that works;
     kept as the record the code cites.

122. Tool behaviour (reduced 2026-11-15): Spinel's resolution of
     `require` reads a line that looks like a require of a literal path
     wherever it stands, inside a regex literal included. In the phase 5b
     follow-ups (2026-11-14) a test program holding
     `raw.match(/\A\s*require "cybertrain\/([\w\/]+)"/)` stopped the build
     with `spinel: cannot load such file -- cybertrain\/([\w\/]+)`, where
     CRuby ran it (test/gen_jobs.rb). So a program that scans source text for requires builds
     the keyword from pieces (`"req" + "uire \"cybertrain/"`) and matches it
     with `start_with?`, as test/gen_jobs.rb's `core_closure` does since
     0dac336. Reduced program (2026-11-15, Spinel 2026.11.04.7026;
     rechecks/differing/require_in_regex.rb): `raw = 'require
     "cybertrain/db"'`, `m = raw.match(/\A\s*require
     "cybertrain\/([\w\/]+)"/)`, `puts m ? m[1] : "no match"`, the String
     and the regex each on one line. CRuby prints `db`. With
     `--strict-require` (how the phase 5b build ran) Spinel stops with the
     message above. Without it the build passes with the warning
     "'cybertrain\/([\w\/]+)' is not available in Spinel; the require is
     ignored and code using it will fail" and the program prints `no
     match`: a wrong result behind a warning, which makes this a defect
     and not only tool behaviour. The same two lines spelled `requirx`
     print `db` compiled (docs/spinel-feedback.md AR).
     Kept until docs/spinel-feedback.md AR is closed.

123. `ENV[name]` with a key that is not a String literal can answer the
     variable's NAME instead of its value on Spinel 2026.11.04.7026
     (found 2026-11-15, not reduced). A program that is only `require
     "cybertrain/http/request"`, `require "cybertrain/config"`, `puts
     Cybertrain::Config.env_or("CYBERTRAIN_HOST", "default")`, run with
     `CYBERTRAIN_HOST=0.0.0.0`, prints `CYBERTRAIN_HOST` compiled and
     `0.0.0.0` under CRuby; for a variable that is not set both print
     `default` (rechecks/differing/env_nonliteral_key.rb, which sets the
     variable itself; `-O 0`, Linux). With `require "cybertrain/core"` or
     `require "cybertrain"` in front the compiled program prints
     `0.0.0.0`, and six standalone programs with the same method
     (`configured = ENV[name] || ""`, then `configured.empty? ? default :
     configured`), given a literal key, a key built with `<<` and a
     default read from an ivar, were correct too. So which programs are hit depends on what the
     whole program makes of the types, and no rule for that was found.
     What the generated C of the failing program shows: the read is
     `_sp_ret_strbuf = NULL; _v2 = sp_env_str(getenv(...
     sp_strbuf_read_pub(lv_name) ...)); !_v2 ? NULL : _sp_ret_strbuf ?
     (sp_String *)_sp_ret_strbuf : SP_STR_HDL(_v2)`, and
     `sp_strbuf_read_pub` (spinel_rt.h) sets `_sp_ret_strbuf` to the
     handle it is given, so when the variable is set the expression
     answers the key's handle. The standalone programs compile the same
     read through a `const char *` temporary without that test. The reads
     with a key that is not a literal are `Config.env_or`,
     `Config.int_from_env` / `bool_from_env` (cybertrain/config.rb) and
     `Dev::Supervision.supervision_variable` (`ENV[name].to_s`); only
     `env_or` was run. Applications require the whole framework and were
     not seen to be affected; a test program that requires single files
     can be. Until it is reduced and reported: add no new `ENV[<variable>]`
     read, and when a partial-require test reads a setting from the
     environment, check the value compiled.
     Kept until docs/spinel-feedback.md AS is closed.
124. A method that only raises, and a lambda that ends in a call of it
     and is stored where a lambda returning an object is stored later,
     cannot both be blocks of one rescuing method whose value is used:
     the C does not compile ("incompatible types when assigning to type
     'sp_RbVal' from type 'const char *'" at the method's `yield`;
     rechecks/differing/raising_helper_beside_lambda.rb, found
     2026-11-21 while rule 79's workaround was tried removed). Either
     block alone compiles. So a helper that only raises and stands where
     a typed lambda's value is expected names a value of that type after
     its `raise`, never reached: `Console.unknown_model` ends in
     `Relation.new("")` and `Console.unknown_record` in `Model.new`
     (cybertrain/console.rb), which the default builders and the `else`
     arms of gen/console.rb call. test/console.rb's rescuing-caller case
     holds the shape and does not compile without the two values.
     Kept until docs/spinel-feedback.md AY is closed.

<a id="numbers-worth-remembering"></a>

## Historical measurements (not performance budgets)

The undated M0 figures below were measured on the original compiler and
workload. Later figures carry their own dates. They are neither current
capacity guarantees nor pass/fail thresholds. Record compiler/commit, OS/CPU,
worker count, workload, concurrency and repeated-run distribution when
re-measuring; use [docs/benchmark.md](../docs/benchmark.md) and `bench/` for
application benchmarks. Do not use old timings alone to set security costs.

- HTTP hello-world (125-byte body, ab on the same host): keep-alive c=100 52-58k req/s at `SPINEL_WORKERS=1`, 31-49k at 10 workers; no keep-alive c=100 ~7k (10 workers) / 27k (1 worker). 200 idle connections time out at 5 s and threads/fds return to baseline.
- Template render (32 KB page, 50 posts): hand-written 122-136 µs, interpreter 203 µs.
- HTML escape: byte scan with fast path 506 ns / 2 strings; `gsub` with a Hash 587 ns; `each_char` 2541 ns.
- SQLite: 1.5 M inserts/s inside one transaction, ~70 K/s autocommit; pool of 4 serving 8 threads: ~55 K statements/s.
- Historical crypto choice: HMAC-SHA256 via `OpenSSL::HMAC.hexdigest("SHA256", key, data)`; `Digest::SHA256.digest` is vendored in the runtime (no OpenSSL link needed), so the framework implements HMAC in Ruby on top of it. This does not mean the full framework avoids OpenSSL today: encrypted sessions load the encryptor (design D61).
- PBKDF2-HMAC-SHA256 in Ruby over that digest (`Cybertrain::Password`, two `Digest::SHA256.digest` calls and two concatenations per iteration; the runtime has no incremental digest API): 100,000 iterations 197 ms compiled, 660 ms under CRuby 3.3; 600,000 iterations 1.09 s compiled (2026-10-22, one cloud vCPU). `String#crypt` exists but is libc crypt(3), so bcrypt only where libxcrypt is (not macOS). The `while` loop's back-edges are safepoints, so a hash in progress is preempted like any other thread (Spinel's docs/thread.md, "The execution model").
- Asset digests (phase 4a spike, 2026-11-10, one cloud vCPU): `File.binread` of 1 MB 1.4 ms, `Digest::SHA256.digest` of it 0.8 ms compiled (CRuby 3.3.6: 5.0 ms for both); a generated 200-arm `case` of String literals compiles in 1.3 s, adds 44 KB to the binary and answers in 293 ns a lookup (arms tried in order; CRuby hashes them, 183 ns).
- One program for many tests (phase 5a, 2026-11-12 and 2026-11-13, a shared 4-vCPU cloud machine with 16 GB): 196 of the framework's test programs bundled into one passed Spinel's front end in about 6.5 min at about 1.65 GB and wrote 87.6 MB of C (1.17 million lines), whose compile at -O2 was killed by the OOM killer at 9.7 GB after about 21 min (the front end is not the bottleneck, cc1's memory is); a small application's test bundle compiled in 162 to 233 s at 2.2 GB into an 8.1 MB binary; examples/blog's 149 tests in about 527 s, a 10.2 MB binary (design D83).
- Locale dictionaries (phase 4b spike, 2026-11-11, a 4-vCPU cloud machine): the hand-written YAML subset reader, compiled, reads rails-i18n's en.yml or ja.yml (about 120 keys) in 0.4 to 0.5 ms and a 2,000-key file in 5 to 6 ms (CRuby 3.3.6: 4 to 6 ms and 33 to 52 ms). A 1,980-arm `case` of String literals answers in 15 ns for its first arm and 19 us for its last arm or an absent key (about 10 ns an arm); a Hash over the same keys in 34 to 53 ns, 6 ns for an absent key.
