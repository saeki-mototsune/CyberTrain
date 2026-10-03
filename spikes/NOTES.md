# M0 spike verdicts (Spinel 2026.09.12)

Throwaway programs under `spikes/` answered the design questions in
`docs/design.md` section 9. This file is the durable record; the programs
themselves were deleted once the framework covered them (`git log -- spikes/`
finds the commit that removed them).

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
    Reduced repro: `module Cy; module H; end; end; module Cy; class L; end;
    @@logger = L.new; def self.logger; @@logger; end; end` ->
    `use of undeclared identifier 'cvar_Cy_logger'`.
19. `STDOUT` and a `StringIO` cannot share one polymorphic call site (`io.puts`
    where `io` is sometimes `STDOUT` and sometimes a `StringIO` raises
    NoMethodError for one branch). Keep such handles in separate typed slots
    and branch explicitly (`if @io then @io.puts(line) else STDOUT.puts(line) end`).
    (`cybertrain/logger.rb`: never pass STDOUT/STDERR as a constructor
    argument next to a StringIO-accepting call site.)
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
    the Spinel binary's output (stdout and stderr merged) against it. Tests must
    therefore be CRuby/Spinel-portable;
    FFI tests get their snapshot from the compiled binary
    (`./build/test/<name> > test/<name>.rb.expected`). CRuby is only needed for
    `--regen`, never for `spin test` with committed snapshots.
24. `spin test` compiles the test program with `--require-gate`; a test must
    `require "cybertrain/test"` itself or `test "..."` fails to compile with an
    'unsupported call' error.
25. `String#to_i` saturates at 2**63-1 instead of promoting to Bignum.
26. `obj.attr += x` (an operator-assignment on a method call) does not compile
    inside a block or lambda ("unsupported expression: CallOperatorWriteNode");
    write `obj.attr = obj.attr + x`. It is fine at top level and in method bodies.
27. Socket buffers are byte strings under CRuby (ASCII-8BIT) but character
    strings under Spinel: use `byteindex`/`byteslice`/`bytesize` for every
    offset into a network buffer, never `index`/`[]`/`size`, or multibyte
    bodies shift the framing of pipelined requests.
28. `URI.decode_www_form_component` on a malformed escape (`%ZZ`, a trailing
    `%`) raises under CRuby but silently decodes under Spinel; validate escapes
    (`%` followed by two hex digits) before decoding when both must agree.
    The decoding loop (`Query.decode_valid`) therefore refuses a malformed
    escape itself, with a byte scan of its own, so `QueryMalformed` and the
    Cookies raw-value fallback behave the same on both runtimes.
    `Query.valid_escapes?` is the router's pre-check, for its own policy: a
    path segment with a malformed escape stays literal instead of raising.
29. Once `SafeString` (to_s/to_str) is in the program, `String#include?` with
    a polymorphic argument mis-dispatches even after narrowing the receiver;
    `String#index(needle.to_s)` works. Iterating a nullable Hash with
    `each { |k, v| }` into a typed String sink can also box the key
    (`each_key { |k| h[k].to_s }` does not).
30. Calls made from inside a stored block do not widen the callee's parameter
    types: a parameter typed `sp_int` from direct call sites silently receives a
    Symbol's internal id when a stored Proc passes `:forbidden`. Give such
    parameters a polymorphic default (`DEFAULT = [200, :ok][0]`) so they stay
    boxed, and narrow with `case value when Integer ... else ... end`.
31. `yield self` in a base-class method called on subclass instances fails at
    the C level (the yield parameter is typed as the base). Take `&block` and
    call `block.call(self)` from an ordinary method instead of yielding.
32. A `begin/rescue => e` inside a yielding method that is called from a block
    nested in another block gets a polymorphic `e` slot and fails to compile.
    Keep begin/rescue in a non-yielding method that receives the block as a Proc.
33. `JSON::ParserError` is not a `StandardError` in the runtime's exception
    table: write `rescue JSON::ParserError, StandardError`.
34. Rule 10 is stronger than stated: two methods sharing a name on unrelated
    classes whose return types differ (`add_index` returning an Index vs an
    Array) corrupt inference even when no polymorphic receiver exists, with the
    backend error "emit_boxed_text: cannot box type". Same name ⇒ same return type.
35. Mutating an object received as a plain parameter through `obj[k] = v` can
    silently do nothing once the caller sits behind a middleware chain (the
    parameter widened); put the mutation in a typed instance method on the
    object (`session.csrf_token!`) and call that.
36. Requiring a middleware whose `#call` is never reachable (never wired into a
    chain) can miscompile unrelated files (dead-code inference gap). Programs
    that require the whole framework must exercise the stack they require.
37. A Hash constant with Symbol keys and Integer values looked up with a
    polymorphic key returns a boxed value; accumulate into a typed local and
    `.to_i` on every branch to keep the result `sp_int`.
38. A class method cannot call a protected/private instance method of an
    instance it holds; expose a public method instead.
39. `SafeString#+` must build its result in two steps (compute the piece, then
    `SafeString.new`): a case expression whose branches both construct the
    result fails under the unboxed value-type layout that SafeString gets when
    it only ever travels as a keyword argument.
40. Never define an instance method named `call` whose arity differs from the
    program's `Proc#call` sites (a 6-argument `HelperBase#call(name, args,
    kwargs, block, interp, env)` made every stored block in the same program
    fail at run time with "NoMethodError: undefined method 'call' for an
    instance of Proc": before_action/rescue_from blocks, model callbacks; a
    1-argument `call(env)` like the middleware's is harmless). Entry points
    that are not Rack-style `call(env)` get distinctive names (`helper_call`).
41. Rules 10/34 apply across files that never meet at run time: an
    `attr_accessor :target` holding an Array<Node> (template parser) next to
    `RequestHead#target` (a String, cybertrain/http/parser.rb) stops the
    compiler with "no implicit conversion of TextNode into String" as soon
    as both files are in one program. Each per-feature test requires only its
    own files, so every subsystem also needs one test program that requires
    the whole framework next to it (test/template_integration.rb) and
    exercises the stored-block paths (rule 36).
42. A lambda literal (or a local holding one) passed as a **keyword argument**
    is not marked escaping (src/analyze_pass.c ignores KeywordHashNode), so its
    parameters keep the Integer default and it silently receives garbage when
    called later (`url_resolver: ->(name, args) { ... }` gave name = 4295868465).
    Pass lambdas positionally, as `&block`, or return them from a method
    (`Gen::Routes.url_resolver`).

43. A `def x=(v)` on one class next to an `attr_accessor :x` on another makes
    the accessor's writer undefined at run time for a boxed receiver
    ("undefined method 'body=' for an instance of Cybertrain::Response" once
    a generated model defined `body=`). Generated models therefore keep
    `attr_accessor` for columns (names the app chooses); both classes
    spelling the method out as `def` also works. A `Cast.time_or_nil(v)`
    call whose argument is statically a Time does not compile either
    (`when String` is still compiled for it), so casting writers are out.
44. `break` out of a block whose `yield` sits inside a `begin/rescue` is
    rejected at compile time ("unsupported expression: BreakNode"); the same
    `break` compiles when the yield is guarded by `ensure` only. `return`
    inside a block passed to a user-defined yielding method ends the block,
    not the enclosing method (seen with Connection#transaction); a `return`
    inside an `each_char` block does leave the method. A `break` anywhere
    inside a block forwarded as `&block` (DB.with's) is rejected too.
45. Rule 32 in practice: calling a yielding method that has `rescue => e`
    (Connection#transaction) from a block nested in another block fails in
    the C compiler ("assigning to 'volatile sp_RbVal' from incompatible type
    'sp_Exception *'"). Call it from a method body or a single-level block.
    A second `ensure` in such a re-entrant yielding method broke nested
    calls at run time (the outer transaction rolled back).
46. `Class#name` carries no namespace ("ParserError", not
    "JSON::ParserError"); assert on the bare name. Thread stacks are small:
    about 50 nested template renders (14 Ruby frames each under CRuby)
    overflow one, so the Interpreter caps nesting at 12. A Hash literal
    whose values are all Strings is typed that way; seed it with a value of
    every type it will hold (rule 9 for Hashes).
47. `is_a?` on an exception object does not see its class: with `e` a
    `QueryTooDeep` caught by `rescue StandardError => e`,
    `e.is_a?(QueryLimitExceeded)` (its direct superclass) was false. Tell
    exception classes apart the way the framework always has, by rescue
    clause -- re-raising `e` into a `begin ... rescue A / rescue B` ladder
    works, but costs a second raise per use, so the framework compares bare
    class names instead (Cybertrain::ClientError::CLIENT_FAULTS, which
    Controller#rescue_with_handler asks too). A `begin ... ensure ... end` as
    the last expression of a block does not type either (same C error as
    rule 32's); end the block with an explicit `nil` after it.
48. `JSON::ParserError` exists only in a rescue clause. `rescue
    JSON::ParserError, StandardError => e` compiles and catches it (rule
    33), but the constant as a value -- `rescue_from(JSON::ParserError)`,
    `klass = JSON::ParserError` -- is "uninitialized constant
    JSON::ParserError (NameError)" when the program starts. So an app cannot
    register a `rescue_from` handler for it under Spinel; Controller#run_action
    still names it in its rescue so the handler fires under CRuby and the
    exception reaches the error pages the same way on both runtimes.
49. `URI.decode_www_form_component` is quadratic on a non-ASCII String under
    Spinel (517 ms for e-acute + 50 000 bytes, 8.5 s for 200 000; linear
    under CRuby and for ASCII text: 11 ms for 400 000 "a" + "%41%C3%A9"). A
    single 1.6 MB non-ASCII key or form value would hang the binary for
    minutes. Decode by byte chunks (`Query.decode`): copy the text between
    escapes with `byteslice` and hand the decoder only the ASCII runs of
    `%XX` escapes.
50. `ensure` in a re-entrant yielding method is not safe under Spinel even for
    bookkeeping only: in Connection#transaction an `ensure @flag = true unless
    completed` ran as if the local `completed` were still false after the
    rescue clause had set it, on the nested-transaction tests (2026.09.12).
    Rule 45 again: no ensure in a yielding method; a CRuby break/return out of
    such a block therefore cannot be detected there.
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
52. `String#byteindex` raises `IndexError` ("offset N does not land on
    character boundary") under CRuby for an offset that is not on a character
    boundary of a UTF-8 String, e.g. right after `&` when the next byte is a
    stray `\x81` (`"a=1&\x81b=2"`, `"x+\x81y"`, `"%41\x81"`); Spinel's
    returns the match without checking. `String#valid_encoding?` exists under
    Spinel and agrees with CRuby, so byte-offset scans over request text
    validate the encoding once up front (`Query.parse`, `Query.decode_escapes`,
    `Router.split_path`) and treat an invalid byte sequence as `QueryMalformed`
    (a 400, like Rails' BadRequest), also after decoding (`%81`). Never
    `rescue IndexError`: that would be CRuby-only behaviour. Once the String
    is valid, every offset the scans use (0, or just after an ASCII byte) is a
    boundary, and a binary (ASCII-8BIT) String never fails the check.
    Spinel's `split`, `strip` and `index` accept an invalid String; CRuby's
    raise ArgumentError ("invalid byte sequence in UTF-8") on a UTF-8-tagged
    one (a binary socket buffer is fine), so a test cannot feed
    `Router.split_path` or `Cookies.parse` a UTF-8 literal with a stray byte:
    test invalid bytes through `Query.decode`/`Cookies.decode`, and through
    `split_path` only next to a `%`, where `Query.check_valid!` runs first.
53. An exception object built with `.new("msg")` and never raised has no
    `#message` under Spinel (`undefined method 'message' for an instance of
    <its class>`, seen on a `Cybertrain::` exception subclass in review;
    `e.class.name` works). `ClientError.classify`
    is only ever called from a rescue clause, so a test of it must raise and
    rescue too (a helper method with a `rescue` clause, returning the status).
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

## Numbers worth remembering

- HTTP hello-world (125-byte body, ab on the same host): keep-alive c=100 52-58k req/s at `SPINEL_WORKERS=1`, 31-49k at 10 workers; no keep-alive c=100 ~7k (10 workers) / 27k (1 worker). 200 idle connections time out at 5 s and threads/fds return to baseline.
- Template render (32 KB page, 50 posts): hand-written 122-136 µs, interpreter 203 µs.
- HTML escape: byte scan with fast path 506 ns / 2 strings; `gsub` with a Hash 587 ns; `each_char` 2541 ns.
- SQLite: 1.5 M inserts/s inside one transaction, ~70 K/s autocommit; pool of 4 serving 8 threads: ~55 K statements/s.
- HMAC-SHA256 via `OpenSSL::HMAC.hexdigest("SHA256", key, data)`; `Digest::SHA256.digest` is vendored in the runtime (no OpenSSL link needed), so the framework implements HMAC in Ruby on top of it.
