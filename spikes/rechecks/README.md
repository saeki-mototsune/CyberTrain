# Retained compiler rechecks

These small programs retain evidence for [NOTES.md](../NOTES.md), not a
claim that their workarounds can be removed from the whole framework.
Run them explicitly; they are not part of `spin test` or the CI gate.

Recorded on 2026-11-11 against framework base `72104d7`: Linux x86_64,
Spinel `2026.11.04.7026` (`a2d06115`, GCC 14.2.0), `-O 0`, CRuby 3.3.8.
All four programs compiled and exited 0, and their output matched CRuby.
The checked-in `.expected` files are the reviewed CRuby output from that
run. No custom worker or GC-stress setting was used for these probes.

`exception_shapes.rb` was then strengthened in review. It now picks the raised
class at run time and catches it with `rescue StandardError`, the shape rules
47 and 54 were seen in. All four programs were re-run with `run.sh` on Linux
x86_64, Spinel `2026.11.04.7026` (`a2d06115`, GCC 13.3.0), `-O 0` and CRuby
3.3.6. All four matched.

| Program | Evidence |
| --- | --- |
| `value_shapes.rb` | Rules 12/18/60: destructuring, a reopened module's class variable, NUL preservation |
| `exception_shapes.rb` | Rules 46/47/53/54: qualified names (including `JSON::ParserError`), `is_a?` on a superclass after `rescue StandardError`, an unraised exception's message, and the superclass chain of user-defined classes |
| `openssl_dispatch.rb` | Rule 62: one boxed String builtin call with OpenSSL |
| `decimal.rb` | Design D42: exact decimal comparisons and rounding, and Float precision loss |

## Programs added on 2026-11-19

The document review of 2026-11-15 ran one small program per shape for most
of rules 1 to 50 of NOTES. Those that match CRuby are kept here, grouped
into eight programs with one commented section per shape; each section says
which rule it is a shape of and what it leaves out. They were run with
`run.sh` beside the four above on 2026-11-19, on Linux x86_64, Spinel
`2026.11.04.7026` (`a2d06115`, GCC 13.3.0), `-O 0` and CRuby 3.3.6, and all
twelve matched. The `.expected` files are CRuby's output from that run.
The shapes of one file are compiled as one program, so a mismatch in a
grouped file may need its section run alone before it says anything about
its rule.

| Program | Evidence |
| --- | --- |
| `dispatch_shapes.rb` | Rules 1 to 6, 30, 31, 40, 42: reflection with non-literal names over two methods, two ivars and two constants; `instance_eval(&blk)` of a block parameter and `instance_exec` with a literal block; a base method calling a subclass-only method; `self.class.foo`; base chain methods returning `self`; `Method` objects in an Array and a Hash; a Symbol passed from a stored block; `yield self` in a base class; `call` with another arity; a lambda as a keyword argument |
| `type_shapes.rb` | Rules 7 to 11, 14, 26, 29, 34, 35, 37, 39, 41, 43, 46: a Time in an ivar that starts as nil; `when Array` and `when Hash` before `when Time`; unseeded containers; one method name on unrelated classes; `include?` with polymorphic receiver and argument; `obj.attr += x` in a block; `obj[k] = v` behind a chain of `call(env)` objects; a constructing `case` in `+`; an Array `target` beside a String one; `def body=` beside `attr_accessor :body` and a writer calling a cast helper; a String Hash literal given other types and 5,000 small frames on a Thread. For 11 and 37 only the output is compared, not the cost those rules are about |
| `constant_order.rb` | Rule 17: a constant read before its assignment raises NameError at top level, in a module body and in a class body |
| `io_shapes.rb` | Rules 19 and 28: STDOUT, STDERR and a StringIO behind one call site; `URI.decode_www_form_component` on malformed escapes |
| `socket_shapes.rb` | Rules 21 and 27: a socket as a `Thread.new` argument; the encoding of what `readpartial`, `read(n)` and `read_nonblock` return |
| `socket_bare_readpartial.rb` | Rule 20: a bare `readpartial` at `SPINEL_WORKERS=1` while another thread ticks, decided by a 0.35 s timing window |
| `rescue_shapes.rb` | Rules 32, 44, 45, 47, 50: `rescue => e` and `ensure` in a yielding method called from nested blocks; `break` and `return` in blocks of yielding methods; `is_a?` after `rescue StandardError` |
| `json_error_shapes.rb` | Rules 33, 48, 61: JSON's errors against `rescue StandardError`; `JSON::ParserError` as a value and as an argument in a class body |

## Programs added for rules 51 and later

The same review ran programs for rules 51 to 122. Six that match CRuby are
kept here; they were run with `run.sh` beside the twelve above on
2026-11-19, on the same machine and tools, and all eighteen matched. Three
of them are the matching half of a rule whose other half still differs;
that half is under `differing/`, described below.

| Program | Evidence |
| --- | --- |
| `block_call_shapes.rb` | Rule 69: a `&block` method that calls `block.call` and has an `ensure` or a `rescue`; a Proc passed two levels down and called with a user-class instance whose method the block calls |
| `container_shapes.rb` | Rules 51, 55, 86: Symbol and String keys through one `key.to_s` reader, and `keys` on a user class beside `Hash#keys`; an append through a value read out of a container; an Integer and a String Range matched by `when Range` from a Hash value and through a parameter |
| `outbound_socket_shapes.rb` | Rule 72, on Linux: SocketError for an unresolvable name, `entry[3]` of a `getaddrinfo` entry, `IPSocket.getaddress`, `Addrinfo.tcp`, `SO_ERROR` after a refused connect, the Errno class from a second `connect_nonblock`, `Errno::ECONNREFUSED::Errno`. Class names only, since the messages are worded differently |
| `invalid_utf8_shapes.rb` | Rule 52: `valid_encoding?`, `split` raising ArgumentError and `index` on a UTF-8 literal with a stray byte |
| `builtin_superclass_no_module.rb` | Rule 104: the `superclass` chain of `ArgumentError` and `RuntimeError` in a program that defines no module |
| `json_nesting_shapes.rb` | Rule 61: `JSON.generate`'s NestingError against `rescue JSON::ParserError, StandardError`, `rescue StandardError`, `rescue JSON::ParserError`, and on a Thread whose `ensure` runs |

## Programs that still differ: `differing/`

`run.sh` reads only the `.rb` files of this directory and expects each to
match CRuby, so a program that still differs, and one that needs the
framework on the load path, cannot sit beside them. Those of rules 51 and
later are in `differing/`. Each file's header gives the commands to run it
from the repository root and what CRuby and the compiled program did on
2026-11-19 (Linux x86_64, Spinel `2026.11.04.7026`, `a2d06115`, GCC 13.3.0,
`-O 0`, CRuby 3.3.6). Nothing runs them automatically. On a new pin, run
each by its header: a program that then matches CRuby moves up into this
directory with an `.expected` file, and its rule's status row says so.

| Program | What it showed |
| --- | --- |
| `differing/env_nonliteral_key.rb` | Rule 123: after `require "cybertrain/http/request"` and `require "cybertrain/config"`, `Config.env_or` answers the variable's name for a variable that is set. Needs `-I .`. Not reduced |
| `differing/builtin_superclass_with_module.rb` | Rule 104: with a module defined, `superclass` on `RuntimeError` is NoMethodError, after a user-defined subclass of `ArgumentError` walked its whole chain |
| `differing/require_in_regex.rb` | Rule 122: a require-shaped regex literal stops a `--strict-require` build; without the flag it is a warning and the match fails |
| `differing/nil_only_puts_openssl.rb` | Rule 78: the C compiler refuses `@io.puts(line)` on a nil-only ivar once `openssl` is required |
| `differing/invalid_utf8.rb` | Rule 52: `byteindex` off a character boundary returns an offset, and `strip` returns the String, where CRuby raises |
| `differing/float_range_boxed.rb` | Rule 86: a Range of Time raises TypeError when built; a Float Range is not matched by `when Range` from a Hash value or through a parameter |

## Running

Run them with the pinned toolchain, CRuby and the documented OpenSSL
development libraries configured:

```bash
spikes/rechecks/run.sh
```

The script prints its output directory first, then runs every probe even
after one fails, and exits 1 if any did. With the eighteen programs here it
takes about a minute. Each failure names the file that holds its output. Each compile and each run is bounded at 180 seconds
(`RECHECK_TIMEOUT`; `gtimeout` on macOS, unbounded with a note when
neither exists). Compiler output other than the usual `src -> bin` line is
flagged as `warn`. A timeout or missing native library
is inconclusive; keep the diagnostics rather than calling it a language
regression. Review compile warnings even when output matches. Keep outputs
outside the package (rule 98); remove the temporary directory after inspection.
Do not automatically regenerate expectations on a mismatch.

These probes do not cover optimized builds, macOS, GC stress, all subcases of
a numbered rule, framework integration or SQLite decimal round-trips. When
using them to justify a compiler upgrade or workaround removal, add and run
the relevant integration/stress checks described in NOTES' maintenance
procedure. Retain a failing reduction as evidence even before it can become
a passing framework test.

A failing reduction does not belong in this directory as a `.rb` file,
because `run.sh` expects every program here to match CRuby, and neither
does a program that needs the framework on the load path, since `run.sh`
compiles each file on its own. Put such a program in `differing/` with a
header like the ones there. The reductions of rules 1 to 50 that still
differ were recorded before that directory existed and have their source
inline in the NOTES status table: rule 54's `JSON::ParserError` superclass
walk, the stored block of rule 2, the class used above its definition of
rule 17, the `IO#gets` of rule 27, and rule 36's probe, which needs the
framework.
