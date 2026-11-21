# spinel-http spike (phase 1, Task 1)

Throwaway records for the spinel-http extraction
([docs/design.md D90](../../docs/design.md) holds the decisions and the
mechanisms taken from them). They answer whether cybertrain's HTTP
layer builds under upstream Spinel, and which mechanisms the later tasks
can use to cut its ties to the rest of the framework. They are records,
not tests: `spin test` does not run them (they are not under `test/`),
and nothing checks their output. Each program's header comment holds its
commands, its output under each compiler, and a verdict.

Recorded on 2026-11-21, Linux x86_64, gcc 13.3.0, 4 vCPU:

- **fork**: the pinned `Cybertrain::SPINEL_TAG`, 2026.11.15.7033
  (a2f3bfaa), from saeki-mototsune/spinel.
- **upstream**: matz/spinel's latest release, 2026.10.25 (2814693f,
  "Merge PR #10173"), built from source with the four steps of
  `cybertrain/cli/toolchain.rb` (clone, `make deps`, `make`,
  `make install PREFIX=~/.spinel-upstream/2026.10.25`). Its tag predates
  the fork fixes merged into matz/spinel on 2026-10-26 (#10254 to #10263,
  docs/spinel-feedback.md A to G).

`spin` builds only `bin/*.rb`, so the records are compiled with
`spinel $(spin flags) NAME.rb -o $TMPDIR/NAME` from this directory, with
the chosen toolchain first on `PATH`. The fork's `spin flags` writes
`--strict-require`; upstream's writes `--require-gate` (the same switch
under another name), so scripts should take the flag from `spin flags`
rather than spelling it.

| Program | Question | fork | upstream |
| --- | --- | --- | --- |
| `hello.rb` | Does `require "cybertrain/http/server"` with a bare `HttpHandler` build and serve? | PASS | PASS |
| `subclass_log.rb` | Does a context subclass keep its type through a base-typed ivar, a sink subclass and a class-level switch replaced at load, read from another thread? | PASS | PASS |
| `reopen_params.rb` (+ `reopen_params/core.rb`) | Does `permit` added by reopening `Params` in a second file work on children the first file built? | PASS | PASS |
| `const_alias.rb` | Do `Cybertrain::X = SpinelHttp::X` aliases construct, subclass and rescue; what does `e.class.name` say? | PASS | PASS |

## The moving tests under upstream

Beyond `hello.rb`, the eleven test programs the design moves into
spinel-http (D90, step 3) were run under upstream `spin test`, in an export of HEAD
(`git archive`) so the checkout's `build/` was not touched:

    PATH=~/.spinel-upstream/2026.10.25/bin:$PATH spin test test/http_parser.rb \
      test/http_request.rb test/http_response.rb test/query.rb test/query_extras.rb \
      test/cookies.rb test/sse.rb test/multipart.rb test/uploaded_file.rb \
      test/http_gunzip.rb test/server.rb

Result: 10 of 11 pass (1 m 34 s). Every program compiled with no warning.
`test/http_response.rb` fails 2 of 25 cases:

    FAIL drop_header removes a header whatever its case and leaves the rest in order: expected nil, got "/x"
    FAIL client_error! drops Location and Content-Disposition in any case, keeps the rest: expected nil, got "/x"

Both are docs/spinel-feedback.md **F** ("a call whose result is always nil
is dropped when passed to a typed parameter"), fixed in the fork's
2026.10.26.7019 and merged into matz/spinel as #10260 after the 2026.10.25
tag: `assert_nil res.drop_header("Location")` compiles to
`assert_nil(NULL)`, so `drop_header` never runs. The reduction (not a
`.rb` here, since it fails on upstream; `-I` the repository root):

```ruby
require "cybertrain/http/response"
def check_nil(v)
  puts(v.nil? ? "nil" : "got #{v.inspect}")
end
check_nil "x"
res = Cybertrain::Response.new
res.set_header("location", "/x")
check_nil res.drop_header("Location")
puts "as an argument: header now #{res.header("Location").inspect}"
res.set_header("location", "/x")
res.drop_header("Location")
puts "as a statement: header now #{res.header("Location").inspect}"
```

Upstream prints `as an argument: header now "/x"`; the fork and CRuby
3.3.6 print `nil`. The statement form prints `nil` on all three. So the
HTTP layer itself is right; the shape is in the test. spinel-http's
tests (and its own code) must not hand a nil-returning call straight to a
typed parameter while upstream is 2026.10.25: call it as a statement,
then assert.

Not checked here: the same eleven programs under the fork (CI runs them
on every push), optimized or `-g` builds, macOS, and anything of
cybertrain above the HTTP layer under upstream.
