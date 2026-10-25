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
    Re-measured with examples/blog on two cores ([docs/benchmark.md](../docs/benchmark.md)):
    `SPINEL_WORKERS=2` adds 16-27% to the pages, 51% to a comment POST and
    49% to a static file. The POST used to lose a quarter: SQLite's
    busy_timeout slept a millisecond or more holding the worker, until a
    busy handler retrying every 100 us replaced it (db/sqlite_ffi.rb). 1 stays
    the default (a one-core server); set it to the core count otherwise.
23. `spin test --regen` writes `.expected` from CRuby's output; `spin test` diffs
    the Spinel binary's output (stdout and stderr merged) against it. Tests must
    therefore be CRuby/Spinel-portable;
    FFI tests get their snapshot from the compiled binary
    (`./build/test/<name> > test/<name>.rb.expected`). CRuby is only needed for
    `--regen`, never for `spin test` with committed snapshots.
24. `spin test` compiles the test program with `--require-gate`; a test must
    `require "cybertrain/test"` itself or `test "..."` fails to compile with an
    'unsupported call' error.
25. `String#to_i` raises `RangeError` ("integer overflow parsing ...") past
    2**63-1 instead of promoting to Bignum (verified on 2026.09.12; an
    earlier note said it saturates, which it does not). Request data that
    is parsed with `to_i` (an id, a page number) must be length-checked
    first, as Server#body_length does, or a 20-digit parameter is a 500.
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
    Spinel's `split`, `strip` and `index` accept an invalid String; CRuby's
    raise ArgumentError ("invalid byte sequence in UTF-8") on a UTF-8-tagged
    one (a binary socket buffer is fine), so `Cookies.parse` cannot be fed a
    UTF-8 literal with a stray byte (`"x\x81".split(";")` raises): test
    invalid bytes through `Query.decode`/`Cookies.decode`.
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
55. An in-place String mutation through a value read out of a container does
    not reach the stored String under Spinel: after `p.set_value("id", "1")`,
    `p["id"] << "2"` leaves `p["id"]` as `"1"` (CRuby: `"12"`), and the same
    for `list(k)[0] << "x"` and a value read through `nested`. So a test must
    not assert that an append through a reader "stuck" on the writable tree
    (runtime-dependent); assert only that the other tree (a merge!
    source) is untouched. merge!'s per-String copies are what make that true
    under CRuby; under Spinel they cost a copy and change nothing.

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
      unused, which Spinel types as an Integer (SafeString#+).
    - A Hash with object values boxes them, so a lookup is polymorphic; an
      object Array is typed (`sp_PtrArray`) unless the program calls
      `clear` on it anywhere, or it is an Array of the class that holds it
      (INode#ikids): then it is `sp_PolyArray`. Engine keeps Templates in an
      Array found through a String => index Hash, and `clear_cache!`
      assigns a fresh Array.
    - A nullable object passed as a parameter is boxed; returning it from
      there makes the method's result polymorphic.
    - `String#to_sym` searches the whole symbol table linearly. Keep the
      Symbol a template passes rather than round-tripping through a String.
    - `str.setbyte` writes a heap String in place; `str << int` makes a
      one-character String per call.
57. A `Mutex#synchronize` taken on every request stalls requests for seconds
    under `SPINEL_WORKERS=2` (a process-wide cache in Helpers.route_key):
    bench/run's two-core config failed about one run in two with wrk
    timeouts or a dead server, and five runs out of five passed once the
    lock was gone. Keep locks off the per-request path; cache per request.
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
59. An `ffi_source` C block shares one translation unit with the runtime and
    the `ffi_func` declarations, so an `extern` there must use the types the
    compiler already emitted: `sqlite3_column_text` is `const char *` (not
    `const unsigned char *`) and an `:long` return is `long` (not `long
    long`), or the build stops with "conflicting types". Cast inside the
    function instead (`db/sqlite_ffi.rb`, `cybertrain_sqlite_column_epoch`).

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

61. `JSON::NestingError` (what `JSON.generate` raises past 100 levels, which
    a parsed document can reach: `JSON.parse` accepts 200) is a subclass of
    `JSON::ParserError` in the runtime's table, but `rescue
    JSON::ParserError, StandardError` does not catch it under Spinel
    2026.09.12 (it does under CRuby); only a clause naming it does. A
    request thread it escapes dies without running `ensure`, so the server
    leaked the socket and its connection count. Every rescue that names
    `JSON::ParserError` names `JSON::NestingError` first, and an app's
    rescue around JSON.generate of request data must too.

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
    Detect it in the C, not by running: `spinel prog.rb -c -o /tmp/x.c` and
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
66. A String local that a method appends to directly two or more times
    (`buf << "\n"; buf << tail`) loses whatever helpers appended to it
    through a parameter in the same method (Spinel 2026.09.12): the local
    is compiled as a buffer of its own, and `add(buf, "ab")` before the
    direct appends wrote to something else. Reduced repro: `def add(buf, s)
    = buf << s` and `def two; buf = "".b; add(buf, "ab"); buf << "\n"; buf
    << "\n"; buf; end` prints `"\n\n"` (CRuby: `"ab\n\n"`); one direct
    append alone is fine. Rule 60's cousin. A buffer filled through helpers
    is filled only through helpers (`put_str(buf, "\n")`, as
    test/time_zone.rb's TZif writer does).
    Separately, and not reduced: an instance method spelled `def name` on
    `Cybertrain::TimeZone` made test/template_integration.rb (the whole
    framework) fail at run time with "undefined method 'name' for an
    instance of Class" (rule 62's dispatch hazard; the framework calls
    `.class.name` on boxed receivers). A ten-line program with a `def name`
    class and `x.class.name` on a boxed value did not fail, so the trigger
    is something else in the framework. The reader is `zone_name`; a new
    framework class should not define `name` as a plain method.

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

70. `rescue DB::Error => e`, with `DB = Cybertrain::DB` at the top of a test
    program, compiled to a match on the names "Error" / "DB::Error" in a
    program that requires the whole framework (test/db_transaction_api.rb,
    2026-10-25), so it never caught a raised `Cybertrain::DB::Error`; in
    test/db_transaction.rb, which requires only the db files, the same
    clause matches the full name. Spell the full name in a rescue clause.

71. Narrowing does not type a return value: `case v when Hash then v else
    {} end` on a polymorphic `v` (a `JSON.parse` result) is
    `(untyped) -> untyped` in `spinel --emit-rbs` (2026.09.12), so every
    call on what it returns stays on the boxed slow path (and in rule 62's
    reach). Copying into a seeded container types it: with `out` a
    `{ "" => [nil, 0, 0.0, "", true][0] }` minus its seed key, `case v
    when Time then nil when Hash then v.each { |k, x| out[k.to_s] = x }
    end; out` is `-> Hash[String, untyped]` (Cybertrain::Cast.hash /
    Cast.array, issue #74; `when Time` first, rule 8). Two shapes
    that the same probe confirmed compile and behave as under CRuby: a
    splat parameter taking mixed types (`Cast.binds(1, "x", nil, Time)`,
    also with no arguments), and a class method inherited from a base
    class that calls an overridden class method on implicit self
    (`Model.upsert` reading each subclass's `table_name`).

## Numbers worth remembering

- HTTP hello-world (125-byte body, ab on the same host): keep-alive c=100 52-58k req/s at `SPINEL_WORKERS=1`, 31-49k at 10 workers; no keep-alive c=100 ~7k (10 workers) / 27k (1 worker). 200 idle connections time out at 5 s and threads/fds return to baseline.
- Template render (32 KB page, 50 posts): hand-written 122-136 µs, interpreter 203 µs.
- HTML escape: byte scan with fast path 506 ns / 2 strings; `gsub` with a Hash 587 ns; `each_char` 2541 ns.
- SQLite: 1.5 M inserts/s inside one transaction, ~70 K/s autocommit; pool of 4 serving 8 threads: ~55 K statements/s.
- HMAC-SHA256 via `OpenSSL::HMAC.hexdigest("SHA256", key, data)`; `Digest::SHA256.digest` is vendored in the runtime (no OpenSSL link needed), so the framework implements HMAC in Ruby on top of it.
- PBKDF2-HMAC-SHA256 in Ruby over that digest (`Cybertrain::Password`, two `Digest::SHA256.digest` calls and two concatenations per iteration; the runtime has no incremental digest API): 100,000 iterations 197 ms compiled, 660 ms under CRuby 3.3; 600,000 iterations 1.09 s compiled (2026-10-22, one cloud vCPU). `String#crypt` exists but is libc crypt(3), so bcrypt only where libxcrypt is (not macOS). The `while` loop's back-edges are safepoints, so a hash in progress is preempted like any other thread (docs/thread.md).

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
    through a `to_s` local).

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

75. Files and child processes for `db backup` (Spinel 2026.09.12, issue
    #76): `File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)`
    creates the file with that mode and raises `Errno::EEXIST` for an
    existing one, as under CRuby; `File#fsync`, `File.rename`, `File.chmod`,
    `File.stat(path).mode`, `Dir.children` and `Time#strftime` behave the
    same too (BlobStore already relied on the O_EXCL form). `VACUUM INTO`
    must create its output file itself: macOS's SQLite answers "output file
    already exists" for a pre-created empty file that Linux's accepts, so
    `db backup` gives it a fresh name inside a 0700 directory. Child processes:
    Kernel `spawn` is "unsupported call", `Process.spawn` compiles but
    `Process.wait` does not (a spawned child is never reaped), and
    `system("prog", "arg", ...)` waits for the child without stalling other
    threads: with `SPINEL_WORKERS=1` the main thread kept ticking every
    0.1 s while another thread's `system("sleep 1")` ran. So an application
    runs its own binary for heavy SQLite work (`system("./app", "db",
    "backup", ...)` from a Scheduler task) instead of running a long
    `VACUUM INTO` on a thread of the server, where the SQLite call would hold
    its OS worker until it returns.
