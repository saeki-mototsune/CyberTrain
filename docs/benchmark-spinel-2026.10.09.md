# Benchmark: the blog on a newer Spinel (package 2026.10.09-7009)

The same benchmark as [benchmark.md](benchmark.md), with examples/blog
compiled by the newest Spinel published as a package by
[saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel):
`ghcr.io/saeki-mototsune/spinel:latest`, version 2026.10.09-7009, commit
edb9dd0 (`spinel --version` says `unreleased (edb9dd0cc)`). CyberTrain still
pins 2026.09.12; this is a preview of what moving would bring, recorded on
2026-10-13.

In short: the compile is 2.4 times faster; with system malloc requests are
about the same to 23% faster; with jemalloc they are 7 to 15% slower, most
likely because the newer runtime allocates two thirds more objects per
page; and the blog needed two changes to run at all, one of which is a
Spinel regression.

## Getting it to run

- **The package.** A Docker image built from the fork's master on every push.
  This machine has no Docker daemon, so the three layers holding
  `/usr/local/lib/spinel` and `/usr/local/bin` were fetched from the registry
  (digests checked) and unpacked; the image is Ubuntu 24.04 with gcc 13, the
  same as this machine, and its compiler runs here as is.
- **A crash, fixed in CyberTrain (aedcf4b).** The newer Spinel declares an
  `ffi_func` function under a name of its own (`sp_ffi_f21_sqlite3_column_text`
  with an `__asm__` label), so the plain `sqlite3_column_text` call in
  `cybertrain_sqlite_column_epoch` (db/sqlite_ffi.rb) compiled as an implicit
  `int` function and cut the pointer in half: a SIGSEGV on the first DATETIME
  column. The helper now declares it itself, the same declaration 2026.09.12
  emits, so both releases build it.
- **A regression, worked around for this run only.** A receiverless call
  with a block inside `instance_eval` raises `NoMethodError` at run time:
  `resources :articles do |articles| ... end` at the top of
  `Cybertrain::Routes.draw` fails in `spin run gen`. For this run the blog's
  config/routes.rb was rewritten to `draw do |r| r.root ...; r.resources ... end`
  (which generates byte-identical gen/routes.rb) and then restored; it is not
  committed. See [spinel-feedback.md](spinel-feedback.md#regressions-in-newer-packages).

With those, the blog's integration tests pass (2 of 2), and the old and new
binaries return byte-identical pages apart from the CSRF tokens.

## Old and new Spinel, same code, same machine

The cloud VM this ran on was not the one of benchmark.md (an Intel Xeon at
2.10 GHz, where that run had 2.80 GHz; Rails' own numbers moved -15% to +34%
between the two), so the Spinel releases are compared against each other
here, not against the recorded run: the same source (commit aedcf4b plus the
routes workaround) built with each, the two binaries run alternately, three
rounds, the median shown. 16 connections, 5-second runs after a 3-second
warm-up, server on CPU 0 (CPU 0,1 for the two-core POST), wrk on CPUs 2-3.
Raw output: [bench/results/2026-10-13-spinel-ab.txt](../bench/results/2026-10-13-spinel-ab.txt).

| req/s, c=16 | 2026.09.12 | 2026.10.09-7009 | Change |
| --- | --: | --: | --: |
| `GET /articles` | 3,301 | 3,640 | +10% |
| `GET /articles/1` | 2,865 | 2,810 | -2% |
| `GET /style.css` | 17,730 | 21,739 | +23% |
| `POST` comment, 1 core | 1,890 | 2,033 | +8% |
| `POST` comment, 2 cores, `SPINEL_WORKERS=2` | 2,913 | 2,848 | -2% |
| *with jemalloc:* | | | |
| `GET /articles` | 4,044 | 3,542 | -12% |
| `GET /articles/1` | 3,524 | 2,988 | -15% |
| `GET /style.css` | 20,084 | 18,712 | -7% |
| RSS after load, system malloc | 10.5 MB | 13.3 MB | +2.8 MB |

| | 2026.09.12 | 2026.10.09-7009 |
| --- | --: | --: |
| Build (`spin run gen` twice and `spin build blog`) | 148 s | 62 s |
| Binary | 2.56 MB | 2.54 MB (no longer links libcrypt) |
| Objects allocated per `GET /articles/1` (with a session cookie) | 511 | 852 |

The run-to-run spread on this VM is 5 to 8%, so the `GET /articles/1` and
two-core `POST` rows are no change. jemalloc no longer helps the pages as it
did: 1.23 times on both pages with 2026.09.12 in this comparison, 0.97 to
1.07 with the newer release (here and in the full run below).

### Where the extra objects come from

`SPINEL_ALLOC_REPORT` per article page, the difference of a 50- and a
250-request run:

- **+136 boxed Arrays from `Hash#each_key` on a polymorphic Hash.** Each
  call now allocates an Array (`sp_poly_each_elem` → `sp_PolyArray_new`):
  `render_helper` copies the environment for every partial with
  `scope.each_key` and checks a partial's locals with `locals.each_key`, and
  the interpreter's `key_in?` walks keys the same way.
- **+92 Strings**, most allocated inside `sp_StrPolyHash_set` (storing into
  a String-keyed Hash with mixed values). The cause is not pinned down: a
  small program storing into a Hash with a String key allocates nothing on
  either release, so it takes something in the blog's shapes.
- **About +50 objects of the runtime's internal types** (`scan_*` in the
  report), allocated in `Helpers#url_for` and when a `StrPolyHash` is made.

These are the likely reason the jemalloc runs lost: with system malloc the
runtime's other gains (the static file, the list page) make up for them,
with jemalloc they do not. Nothing in CyberTrain is changed for them while
2026.09.12 is the pinned release; the `each_key` loops in the render path
are where to start once a newer one is.

## The full benchmark, with Rails

`bench/run --no-build` with the new binary, all four configurations, the
same settings as benchmark.md:
[bench/results/2026-10-13-spinel-edb9dd0.json](../bench/results/2026-10-13-spinel-edb9dd0.json).
The JSON's `commit` (ff847a9) is the checkout the script saw; the binary was
built from aedcf4b with the routes workaround. On this (slower) machine,
CyberTrain against Rails 8.1 on YJIT:

| One core, system malloc, req/s | c | CyberTrain | Rails | Ratio |
| --- | --: | --: | --: | --: |
| `GET /articles` | 1 | 2,736 | 503 | 5.4x |
| `GET /articles` | 16 | 3,200 | 494 | 6.5x |
| `GET /articles/1` | 1 | 2,434 | 239 | 10.2x |
| `GET /articles/1` | 16 | 2,867 | 233 | 12.3x |
| `GET /style.css` | 1 | 14,892 | 5,241 | 2.8x |
| `GET /style.css` | 16 | 19,117 | 6,028 | 3.2x |
| `POST` comment | 1 | 1,877 | 430 | 4.4x |
| `POST` comment | 16 | 1,749 | 421 | 4.2x |

The ratio ranges for the other configurations: two cores 2.5 to 11.4 times,
one core with jemalloc 2.7 to 11.0, two cores with jemalloc 2.4 to 10.3.
Memory after load: CyberTrain 12.9 MB, Rails 133.0 MB (one core). Startup:
0.015 s and 9.8 MB against 1.05 s and 87 MB.

## Reproducing it

```sh
# the compiler, from the package (or `docker run ghcr.io/saeki-mototsune/spinel`)
export PATH=<unpacked>/usr/local/lib/spinel:$PATH   # spinel and spin
cd examples/blog
# config/routes.rb: draw do |r| r.root ...; r.resources ... end (the regression)
spin run gen -- --embed-views && spin build blog && spin run gen
cp build/bin/blog dist/blog
cd ../.. && PATH=<ruby 3.4 with YJIT>/bin:$PATH bench/run --no-build --out <file>
```

`cybertrain build` itself refuses a Spinel other than the pinned 2026.09.12,
which is why the steps it runs are spelled out here.
