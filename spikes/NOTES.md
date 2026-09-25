# M0 spike verdicts (Spinel 2026.09.12)

Throwaway programs under `spikes/` answered the design questions in
`docs/design.md` section 9. This file is the durable record; the code is
disposable and will be deleted once the framework covers it.

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

## Rules every framework file must follow (derived from the spikes)

1. Never call `send`, `public_send`, `respond_to?`, `instance_variable_get`,
   `const_get` with a non-literal name. Dispatch on names with `case name when :literal`.
2. Never `instance_exec`/`instance_eval` a stored block. Blocks that need the
   receiver take it as an argument: `before_action { |c| ... }`, `before_save { |r| ... }`.
3. A base-class method that calls a method defined only in subclasses
   crashes the compiler (SIGSEGV at codegen). Declare an abstract stub in the
   base for every such hook (`def read_attribute(name) = nil`).
4. From an instance method, `self.class.foo` is only safe when `foo` is
   overridden in every subclass; otherwise pass the class explicitly. Keep
   class-level registries keyed by a String (`model_name`, class name).
5. Chain methods that `return self` from a base class are typed as the base.
   Base setters return `nil`; subclasses wrap them: `def where(h) = (add_where(h); self)`.
6. Never store `Method` objects in collections; store lambdas.
7. A nullable ivar must be assigned through a cast helper that can return nil
   (`Cast.time_or_nil(v)`); assigning a `Time` directly to an ivar that starts
   as nil miscompiles (reads back `Time.at(0)`). Non-null Integer/String
   attributes are initialised to `0` / `""` and cast with `to_i` / `to_s`.
8. In any `case value` over polymorphic values put `when Time` **before**
   `when Array` (a Time in a poly slot matches `Array`).
9. Empty containers stored in ivars must be seeded with their element type:
   `Array.new(0) { Node.new }`; a typed empty Hash is `h = { "" => x }; h.delete("")`.
10. Do not reuse a method name across unrelated classes that can meet in a
    polymorphic receiver (a `Frame#body` next to `Post#body` corrupted the
    inferred return type). Framework-internal accessors get distinctive names.
11. A local initialised to `nil` and later given a String/Integer widens the
    whole method to the boxed slow path. Use typed sentinels (`""`, `-1`, a flag).
12. `k, v = str.split("=", 2)` miscompiles; index the array instead.
13. String literals are frozen: build buffers with `+""` / `String.new`.
14. `include?` on a polymorphic receiver with a polymorphic argument mis-dispatches;
    narrow the receiver with `case` first.
15. FFI: never pass a static `ffi_buffer` as an out-parameter from more than one
    thread; `malloc(8)` a scratch pointer per call and `free` it.
16. `self.class.name` and `rec.class.name` work; `case rec when Post` works;
    `Post === rec` works; a Hash keyed by class name works.
17. Constants may be read before definition under Spinel but not under CRuby;
    keep definition order CRuby-valid anyway.
18. A module-level `@@class_variable` assigned inside `module Cybertrain`
    miscompiles once an earlier required file has already opened the module
    (C error "incompatible pointer to integer conversion"). Use a module-level
    `@instance_variable` with `def self.x` accessors instead.
19. `STDOUT` and a `StringIO` cannot share one polymorphic call site (`io.puts`
    where `io` is sometimes `STDOUT` and sometimes a `StringIO` raises
    NoMethodError for one branch). Keep such handles in separate typed slots
    and branch explicitly (`if @io then @io.puts(line) else STDOUT.puts(line) end`).
20. Sockets: never call `readpartial` without `sock.wait_readable(timeout)`
    immediately before it (`readpartial` is a raw blocking `read(2)` that holds
    the OS worker and never yields; `wait_readable` parks the green thread and
    its nil return is the idle timeout). `IO#gets` parks correctly. `SO_RCVTIMEO`
    is unusable (setsockopt takes Integers only).
21. Never pass a socket as a `Thread.new` argument (`Thread.new(sock) { |c| ... }`
    loses its static type: "undefined method 'wait_readable' for TCPSocket").
    Spawn through a method whose parameter the closure captures:
    `def spawn_conn(sock); Thread.new { serve(sock) }; end`.
22. For I/O-bound servers `SPINEL_WORKERS=1` was faster (54-58k rps) than the
    10-worker default (25-45k rps) and had no 40-80 ms stalls; set it from the
    binary (`ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]`) before
    the first `Thread.new`, and re-measure once templates and SQLite add CPU work.
23. `spin test --regen` writes `.expected` from CRuby's output; `spin test` diffs
    the Spinel binary against it. Tests must therefore be CRuby/Spinel-portable;
    FFI tests get their snapshot from the compiled binary
    (`./build/test/<name> > test/<name>.rb.expected`). CRuby is only needed for
    `--regen`, never for `spin test` with committed snapshots.
24. `spin test` compiles the test program with `--require-gate`; a test must
    `require "cybertrain/test"` itself or `test "..."` fails to compile with an
    'unsupported call' error.
25. `String#to_i` saturates at 2**63-1 instead of promoting to Bignum.
18. A `@@class_variable` assigned directly inside a `module Foo` block (e.g.
    `module Foo; @@x = Bar.new; end`) mis-compiles as soon as some earlier
    required file has already opened `module Foo` elsewhere: the C compile
    fails with `incompatible pointer to integer conversion assigning to
    'sp_int' ... from 'sp_Bar *'`. Reduced repro: `module Cy; module H; end;
    end; module Cy; class L; end; @@logger = L.new; def self.logger;
    @@logger; end; end` -> `use of undeclared identifier 'cvar_Cy_logger'`.
    Use a module-level `@instance_variable` with `self.foo`/`self.foo=`
    accessors instead; that form is unaffected by prior requires. Also:
    Spinel cannot union a real IO handle (STDOUT/STDERR) with StringIO
    behind one polymorphic call site (e.g. `@io.puts` where `@io` is
    sometimes STDOUT and sometimes a StringIO) -- keep an IO-typed ivar
    `nil`-or-StringIO and branch explicitly to the STDOUT constant, never
    pass STDOUT/STDERR as an explicit constructor argument alongside a
    StringIO-accepting call site (`cybertrain/logger.rb`).

## Numbers worth remembering

- HTTP hello-world (125-byte body, ab on the same host): keep-alive c=100 52-58k req/s at `SPINEL_WORKERS=1`, 31-49k at 10 workers; no keep-alive c=100 ~7k (10 workers) / 27k (1 worker). 200 idle connections time out at 5 s and threads/fds return to baseline.
- Template render (32 KB page, 50 posts): hand-written 122-136 µs, interpreter 203 µs.
- HTML escape: byte scan with fast path 506 ns / 2 strings; `gsub` with a Hash 587 ns; `each_char` 2541 ns.
- SQLite: 1.5 M inserts/s inside one transaction, ~70 K/s autocommit; pool of 4 serving 8 threads: ~55 K statements/s.
- HMAC-SHA256 via `OpenSSL::HMAC.hexdigest("SHA256", key, data)`; `Digest::SHA256.digest` is vendored in the runtime (no OpenSSL link needed), so the framework implements HMAC in Ruby on top of it.
