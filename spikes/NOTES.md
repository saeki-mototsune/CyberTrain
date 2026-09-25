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
| 5 | TCPServer + green threads | pending |
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

## Numbers worth remembering

- Template render (32 KB page, 50 posts): hand-written 122-136 µs, interpreter 203 µs.
- HTML escape: byte scan with fast path 506 ns / 2 strings; `gsub` with a Hash 587 ns; `each_char` 2541 ns.
- SQLite: 1.5 M inserts/s inside one transaction, ~70 K/s autocommit; pool of 4 serving 8 threads: ~55 K statements/s.
- HMAC-SHA256 via `OpenSSL::HMAC.hexdigest("SHA256", key, data)`; `Digest::SHA256.digest` is vendored in the runtime (no OpenSSL link needed), so the framework implements HMAC in Ruby on top of it.
