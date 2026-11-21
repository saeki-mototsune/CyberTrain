# Contributing to cybertrain

Thank you for considering a contribution. Bug reports, questions, fixes, new
features, documentation and translations are all welcome, from anyone. This
file explains how the project works day to day: how to set up a checkout, what
the commit gate checks, how the tests run, and what a pull request needs.
Please also read the [Code of Conduct](CODE_OF_CONDUCT.md); by taking part you
agree to it. Security problems go through [SECURITY.md](SECURITY.md), never a
public issue.

## Before you start

cybertrain is a Rails-shaped framework for [Spinel](https://github.com/matz/spinel),
an ahead-of-time Ruby compiler. That shapes everything about working on it:

- **The framework compiles under Spinel, not CRuby.** Only the `cybertrain`
  CLI (`cybertrain/cli*`, `exe/`) runs under CRuby and ships as a gem; the
  rest of `cybertrain/` is a spin package an application depends on. In
  development `cybertrain server` also runs the framework and the
  application under CRuby, as a preview, with Spinel's FFI DSL implemented
  over Ruby's `fiddle` (`cybertrain/preview/`, which Spinel never
  compiles); that preview is never the program that ships. Things
  Ruby programmers take for granted (`method_missing`, `define_method`,
  `instance_variable_get`, `eval`) do not exist. [spikes/NOTES.md](spikes/NOTES.md)
  has the rules the code follows because of the compiler and how it works
  around each behaviour; [docs/spinel-feedback.md](docs/spinel-feedback.md)
  is the one record of the behaviours themselves: what Spinel does on which
  build, what was asked upstream, and whether an item is closed. When
  something will not compile, look in NOTES first. When you find a new
  behaviour, write the item in spinel-feedback (it takes the next letter),
  put its reduced program under `spikes/`, listed in the README beside it,
  and add the rule to NOTES, ending with the line that names the item;
  rules and programs stay until their item is closed. NOTES' section
  "Workarounds that shape the design" says which shapes are permanent,
  which are tied to the pinned build and which test covers each, and what
  a Spinel update re-checks.
- **A CRuby pass, a test run under CRuby or a page seen in the preview, is
  not acceptance.** The commit gate, `ruby -I. test/<name>.rb`,
  `script/preview-parity` and the development server's CRuby preview run
  under CRuby, where none of Spinel's constraints exist: a page that works
  in the preview, or a test that matches its snapshot there, says nothing
  about whether the code compiles. The tests known to differ between the
  runtimes are listed, each with its cause, in
  [test/cruby/parity-gaps.txt](test/cruby/parity-gaps.txt). A change that
  moves code between methods, classes or files, changes what a block or a
  Proc crosses, adds a shared helper or a base class, or changes what the
  generator emits must pass the affected tests compiled (`spin test`), and
  a generator change must leave `examples/blog` regenerating clean and
  passing (`cybertrain test` there). Say in the pull request which compiled
  tests you ran.
- **Every design decision is written down.** [docs/design.md](docs/design.md)
  records what was decided, what was rejected and why. Read the
  relevant section before changing a behaviour, and update it when a
  decision changes. [README.md](README.md) explains the framework to its
  users and [docs/guide/template-language.md](docs/guide/template-language.md) the
  template grammar.
- **Generated code is committed.** `spin` has no build hooks, so
  `examples/blog/gen/` and the generated files in `test/fixtures/` are
  committed and CI checks they are fresh.

Open an issue before a large change (a new subsystem, a change to what the
generator emits, a new dependency): the issue is where the design gets agreed,
so that the pull request can be about the code.

## Setting up a checkout

The requirements are the ones in
[docs/guide/install.md](docs/guide/install.md#requirements): Ruby 3.2 or
newer (with `fiddle`, for the CRuby preview and its tests), a C compiler,
make, git, curl, and the SQLite, zlib and OpenSSL headers. Then:

```sh
git clone https://github.com/saeki-mototsune/CyberTrain.git
cd CyberTrain
script/install-hooks           # the commit gate, once per clone (below)
ruby -I. exe/cybertrain doctor # what is missing, if anything
ruby -I. exe/cybertrain setup  # builds the pinned Spinel into ~/.cybertrain (minutes, once)
spin test test/router.rb       # one program, to see the toolchain work; "Running the tests" has the suite
```

`ruby -I. exe/cybertrain` runs the CLI from the checkout (`spin install`
instead builds `bin/cybertrain.rb` into `~/.local/bin/cybertrain`), and `cybertrain new NAME
--path ~/src/cybertrain` creates an app against the checkout; `gem install
cybertrain` gives you the released one instead, which installs the same
Spinel. On an Ubuntu machine you can also run
[script/claude-cloud-setup](script/claude-cloud-setup), which does the whole
setup non-interactively. The [playground](https://www.cybertrain.dev/playground.html)
is a quick way to try the framework, not a place to develop it.

## The commit gate

Every commit passes a gate: a set of fast checks (CRuby only, no Spinel;
under a second for a commit of Markdown alone, some tens of seconds when the
repository checks run) that catch what is cheap to catch before a reviewer
or a CI run does. `script/install-hooks` points this clone's git hooks
at [.githooks/](.githooks/), after which:

- **pre-commit** runs `script/gate --staged` on the files being committed:
  trailing whitespace, final newlines, LF line endings, merge-conflict
  markers, Ruby syntax (`ruby -c`), YAML files load; and, when the commit
  touches the framework, the CLI, the tests, the scripts or the playground's
  Dockerfile, the repository checks: the version and Spinel-tag pins agree
  (and `script/claude-cloud-setup` builds from
  `Cybertrain::SPINEL_REPOSITORY`), `script/check-reserved-names`,
  `check-client-faults`, `check-http-layer` and `check-core-closure` pass
  (see [Conventions](#conventions-ci-enforces) for what each guards),
  `script/ci-changes --self-test` passes, `cybertrain/locales/bundled.rb`
  is what `script/bundle-locales` writes, every file `cybertrain.gemspec`
  lists exists, the CLI loads under CRuby and `playground/Dockerfile`
  copies each of those files into its gem stage, the Playground image and
  Blog image workflows run for a pull request that changes one of them or a
  pin, every `test/*.rb` and `test/cruby/*.rb` has its `.expected` snapshot
  and every snapshot its test, and the generator run under CRuby leaves
  `examples/blog/gen/` unchanged. Four more checks run when their files
  are in the commit: the deployment tutorial's translations
  (`check-docs-i18n`), the guides' translations (`check-guide-i18n`),
  release numbers in the pages (`check-version-mentions`) and the
  workflows' rules (`check-workflows`).
- **commit-msg** checks the message's shape (see [Commits](#commits)).

`script/gate` with no arguments runs the same checks over the whole
repository; `script/gate path...` over given files. The Gate workflow
([.github/workflows/gate.yml](.github/workflows/gate.yml)) runs `script/gate`
on every push and pull request, so a contributor without the hook gets the
same answer, a little later. `git commit --no-verify` skips the hooks when you
need to (a work-in-progress commit you will squash); CI runs the gate
regardless, so the pull request still has to pass it.

The gate does not run the tests: compiling the suite takes minutes, and that
is CI's job. Run the tests yourself before opening a pull request.

## Running the tests

The framework's tests are plain Spinel programs under `test/`, each compiled
into its own binary, whose output (stdout and stderr) is compared with the
committed snapshot `test/<name>.rb.expected`:

```sh
spin test                      # everything: one program per test/*.rb, each compiled on its own
spin test test/router.rb       # one program
```

A plain `spin test` recompiles every program whenever any file of the
package is newer than the binaries, a test file included: with the pinned
Spinel release, touching one test of a two-test package recompiled both.
Only a run with nothing changed is quick. So while working, run the programs
you touched (`spin test test/<name>.rb` compiles that one) and leave the
whole suite to one run before the pull request. The suite is 240 programs;
the last recorded local time is 14 minutes for 82 programs on 4 cores
([docs/design.md](docs/design.md), D34), so allow several times that.

On Ubuntu, CI divides the programs into four shards, the `framework-tests` jobs
in [.github/workflows/ci.yml](.github/workflows/ci.yml); on macOS they run in
one job, `test (macos-latest)`. To reproduce a failing job `framework-tests (2)`,
run its shard:

```sh
script/test-shard 2 4          # the sorted test/*.rb at positions 2, 6, 10, ...
script/test-shard --list 2 4   # which programs those are
```

When you change behaviour on purpose, the snapshot changes with it:

```sh
script/regen-snapshot test/router.rb   # rebuilds, captures, prints the diff stat
```

Read the diff before committing it. A snapshot is a test's assertions, so a
changed snapshot is reviewed like a changed test: say in the pull request
what changed in it and why. Never regenerate a snapshot to make a failure go
away without understanding the failure.

A failure is reported as `FAIL <name>.rb`, then `--- expected` with the whole
snapshot, then `--- actual` with the whole output: the two blocks are long,
so do not read the end of the first as a truncated output. The program's
output is also left in `build/test/<name>.out`, and this shows only what
differs:

```sh
diff build/test/router.out test/router.rb.expected
```

### After a merge

A snapshot that ends with the harness summary (`N tests, N assertions, N
failures`; `test/version.rb.expected` is the one that does not) counts the
assertions, and that count is what a merge gets wrong without a conflict:
two branches that each add one
assertion to the same test both change `N assertions` to `N+1`, git merges
the identical change cleanly, and the merged tree runs `N+2` against a
snapshot that says `N+1` (this happened on `main` between pull requests #58
and #61; #79 regenerated the snapshot). After merging `main` into a branch
that touches a test, run that test again before pushing: `spin test
test/<name>.rb`, or, for a test that needs neither SQLite nor any other FFI
(below), `ruby -I. test/<name>.rb` under CRuby, which takes a second and
needs no compiler.

### Writing a framework test

A snapshot of a test that needs SQLite or other FFI comes from the compiled
binary only: `spin test --regen test/<name>.rb` writes the snapshot from
CRuby's output ([spikes/NOTES.md](spikes/NOTES.md), rule 23), so use
`script/regen-snapshot`, which captures the binary's. To run such a test
under CRuby for a quick look, load the preview's shim, as
`script/preview-parity` does: `ruby -E UTF-8 -I. -r cybertrain/preview
test/<name>.rb`.

Use the assertions in `cybertrain/test.rb` (`assert`, `assert_equal`,
`assert_raises("Class") { }`, ...); for controllers and HTTP flows,
`Cybertrain::Test::Client` drives an application in-process, as
`test/client.rb` and `test/application.rb` do. An application's own tests
are a different thing: test classes that `cybertrain test` runs, as in
[examples/blog/test/](examples/blog/test/) (see the
[testing guide](docs/guide/testing.md)).

What several test programs need is in `test/support/`, loaded with
`require_relative "support/<name>"` (the files there are not test programs:
neither the gate nor `script/test-shard` looks into `test/support/`). Use these before
writing another copy into a test:

- `file_tree.rb`: `FileTree.remove`, `copy` and `make_dirs`, for a test
  that builds a scratch tree on disk.
- `schema_tables.rb`: `SchemaTables.create_sql`, the `CREATE TABLE`
  statements of a schema definition, for a test that loads generated models
  into an in-memory database.
- `log_capture.rb`: `capture_log`, `with_scope` and `assert_logged`, for a
  test that reads log lines.
- `zone_swap.rb`: `ZoneSwap.during`, for a test that sets `Time.zone`.

### The example application

The example application is a test too. If your change affects what the
generator emits or how an application runs:

```sh
cd examples/blog
spin run gen && git status --short -- gen/     # generated code must be fresh: this prints nothing
ruby -I../.. ../../exe/cybertrain test         # the blog's tests (test/**/*_test.rb), one compiled program
```

`git status` rather than `git diff`: a file the generator writes for the
first time is untracked, and `git diff` passes over it. CI fails on either.
`cybertrain test`, not `spin test`: the blog's tests are test classes, which
only `cybertrain test` runs; `spin test` there would compile
`test/test_helper.rb` alone and call it ok.

### The CRuby preview's checks

The CRuby preview (`cybertrain/preview/`, and the supervisor in
`cybertrain/cli/dev_server*`) has three checks of its own, none of which
replaces the compiled tests:

```sh
script/test-cruby              # test/cruby/*.rb: the preview's own CRuby-only tests (a few seconds)
script/preview-parity          # every test/*.rb under CRuby with the shim, against the compiled snapshots
script/preview-e2e             # `cybertrain server` on a copy of examples/blog, over HTTP (about ten minutes)
```

`script/test-cruby` compares each `test/cruby/<name>.rb` with its snapshot
as `spin test` does (`--regen` rewrites them). `script/preview-parity`
passes when every test matches its compiled snapshot except those listed in
[test/cruby/parity-gaps.txt](test/cruby/parity-gaps.txt), which must still
differ, and differ only as recorded in `test/cruby/parity/`; a listed test
that matches again fails it until its line is removed. Both run in CI's
`cruby-preview` job on Ubuntu; its macOS leg runs `script/test-cruby` only
(`script/preview-parity` needs GNU `timeout`). `script/preview-e2e` builds
the blog with Spinel several times and prints one `ok` or `FAIL` line per
step; CI's `preview-e2e` job runs it on Ubuntu (Linux only: it reads
`/proc`) and, when it fails, keeps the supervisor's whole output and the
build log as the run's `preview-e2e-logs` artifact. Run it yourself too,
before pushing, after changing the supervisor, the shim or the framework's
development server.

### What CI runs

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs the
framework's tests and the example application on Ubuntu and, for the
changes step 4 of [Pull requests](#pull-requests) lists and on `main`, on
macOS; it builds
and installs the gem, and scaffolds, builds and serves applications end to
end. Three of those end-to-end checks are scripts you can run yourself after
changing a generator or the test command: `script/auth-e2e signup` (or
`invite`, `confirmable`, `upgrade04`), `script/generators-e2e` and
`script/test-command-e2e`. Each makes its applications in a scratch
directory and compiles them, so they are slow (a comment in `ci.yml`
records 114 minutes for the four variants of `script/auth-e2e` together on
a 4-core machine); run the one variant you changed.

CI also builds the API reference with YARD (any warning fails it:
`script/api-docs`, the `api-docs` job). A change to nothing but
the API reference's own inputs (`docs/api/`, `script/api-docs`, `.yardopts`)
runs that job alone; [script/ci-changes](script/ci-changes) holds the rule
and `script/ci-changes --self-test` checks it. Its `setup-cybertrain` jobs run the action
applications use in their own CI
([.github/actions/setup-cybertrain](.github/actions/setup-cybertrain/action.yml))
on a newly generated application, so a change to that action is tested like
any other.

Its `http-upstream` job builds the HTTP layer's own tests (the files that
will move with `cybertrain/http/` into a library of its own, and
`test/http_standalone.rb`, which loads the layer and nothing else) with
upstream Spinel, matz/spinel's release `SPINEL_UPSTREAM_TAG` in `ci.yml`,
rather than the fork. A failure there that the fork's run does not have is
usually a shape upstream compiles differently from the fork
(spikes/NOTES.md rule 126 is the one known so far).
To reproduce it, build upstream once as the job does, with the tag read
from `ci.yml`, then run `spin test` with upstream first on `PATH`, in an
export of your tree outside the checkout, so the two compilers do not
share `build/`:

```sh
tag=$(sed -n 's/^  SPINEL_UPSTREAM_TAG: "\(.*\)"$/\1/p' .github/workflows/ci.yml)
up=$HOME/.spinel-upstream/$tag
src=$(mktemp -d)
git clone -q --depth 1 --branch "$tag" https://github.com/matz/spinel "$src"
(cd "$src" && make deps && make -j"$(nproc)" && make install PREFIX="$up")   # once per tag

dir=$(mktemp -d)
git archive HEAD | tar -x -C "$dir"   # commit first: the export is of HEAD
cd "$dir"
PATH=$up/bin:$PATH spin test test/http_standalone.rb test/http_response.rb
```

The last line runs two of the job's thirteen programs, the layer alone
and the one rule 126 is about; for the whole job, give `spin test` the
list in the job's last step instead.

## Conventions CI enforces

Each of these exists because of a bug or a constraint that was found the hard
way; the script or workflow step that checks it says so in its comment.

- **A column may not be named after a `Cybertrain::Model` method.** Add a
  method or an ivar to `Model` and `Ident::RESERVED_COLUMN_NAMES` must list
  it, or a generated reader silently shadows it (`script/check-reserved-names`).
  The same script keeps the neighbouring lists honest: the action names an
  attachment field may not take (`ATTACHMENT_RESERVED_ACTIONS`, against
  `Controller` growing), the helper names an application helper may not
  take (`HelperScan::RESERVED_HELPER_NAMES`), the names a model `scope` may
  not take (`ModelScan::RESERVED_SCOPE_NAMES`), the class methods a job
  class may not define (`JobScan::RESERVED_CLASS_METHODS`), the names a
  fixture accessor may not take (`FixtureScan::TAKEN_NAMES`), and the
  method names with fixed homes (`NAME_HOMES` in the script: a listed name
  may be defined only in the files its row names).
- **One method name has one return type.** This is the project's rule
  ([spikes/NOTES.md](spikes/NOTES.md), rules 10 and 34, which record
  programs where methods of one name with different return types on
  unrelated classes corrupted Spinel's inference, and others where such a
  pair compiled). The same script holds the
  typed part of it: each definition of a framework method named like a
  typed column (`Ident::FRAMEWORK_METHOD_TYPES`) must document that type
  with `@return`.
- **Every client fault is listed.** A new `QueryInvalid` subclass must be in
  `ClientError::CLIENT_FAULTS`, or it is a 500: the list is compared with
  the exception's class name, not walked with `is_a?`
  ([spikes/NOTES.md](spikes/NOTES.md), rules 47 and 54, has why)
  (`script/check-client-faults`).
- **The HTTP layer stands alone.** `cybertrain/http/*` must load without the
  rest of the framework, so it can be lifted out (`script/check-http-layer`).
- **The core does not name an optional subsystem.** No file that
  `cybertrain/core.rb` requires, directly or not, may be a subsystem's file
  or name its classes (`Job`, `Scheduler`, ...) or call a method a
  subsystem adds to a core class (`run_worker`, `apply_rate_limit`, ...):
  Spinel compiles every method a program requires, so one reference puts
  the subsystem back into every application. The core reaches a subsystem
  through the hooks of `Cybertrain::Feature` (`script/check-core-closure`,
  whose `--self-test` checks its own lexing).
- **The CLI runs under CRuby and lists its files by hand.** A file the CLI
  requires must be in `cybertrain.gemspec`'s `spec.files`; CI installs the
  built gem and runs it.
- **A workflow's token can do only what its jobs need.** Every workflow
  states `permissions:` at the top, so nothing relies on the repository's
  default: read access for what only checks (the Gate, CI), write access
  only where something is published (a release, a package, the site) or a
  check is written (`required`, which writes its check run), on the job that publishes when the workflow has others. Every
  `actions/checkout` sets `persist-credentials: false`, so the token is not
  left in `.git/config` for the steps after it, unless a later step pushes
  with it (the Bump version workflow, which says so)
  (`script/check-workflows`).
- **What a workflow runs is pinned.** An action from another repository is
  named by commit, `uses: owner/name@<commit> # vX.Y.Z`, never by a tag,
  and a `gem install` in a workflow names a version
  (`script/check-workflows`; see
  [Dependencies and their updates](#dependencies-and-their-updates)).
- **Versions are pinned in one place.** `Cybertrain::VERSION` equals
  `spin.toml`'s version; `Cybertrain::SPINEL_TAG` equals `SPINEL_TAG` in
  `ci.yml`. (`script/claude-cloud-setup` pins no tag: it builds the latest
  release of the saeki-mototsune fork.)
- **The bundled dictionaries are compiled in.** `cybertrain/locales/en.yml`
  and `ja.yml` are the source; `cybertrain/locales/bundled.rb` is what the
  framework loads. After changing a YAML file run `script/bundle-locales`
  and commit both (the gate runs `script/bundle-locales --check`).
- **Public API is documented.** A class or method an application calls
  carries a YARD comment tagged `@api public`; the API reference is built from
  those and must build without a warning. Anything without the tag is
  internal.
- **The deployment tutorial has an English translation.** A change to
  [docs/deploy.md](docs/deploy.md) changes [docs/deploy.en.md](docs/deploy.en.md)
  with it (part 8: [docs/deploy-kamal.md](docs/deploy-kamal.md)), and the
  other way round. `script/check-docs-i18n`, which the gate runs when one of
  them changes, compares their headings and section numbers, code blocks
  (comments and progress messages aside) and table rows. As with the site,
  if you cannot translate, say so in the pull request.
- **The workflows pass actionlint.** A workflow or a composite action under
  `.github/` that loads as YAML can still name a job, an input or a step
  output that does not exist, and GitHub says so only when it runs, which for
  the release workflow is at release time. The Gate workflow's `actionlint`
  job runs [script/lint-workflows](script/lint-workflows) on every pull
  request; with [actionlint](https://github.com/rhysd/actionlint) installed
  (and shellcheck, which it calls for the `run:` scripts) the same command
  runs locally. The commit gate does not run it.

One convention is not enforced by CI. **The site is published in five
languages**: a change to an English page under `site/` changes `ja/`, `zh/`,
`ru/` and `fr/` with it. Neither the gate nor a workflow checks this, so run
`script/check-site-i18n` (Python 3) yourself before pushing; it compares the
structure, the code blocks and the inline code (see
[site/README.md](site/README.md), "Translations"). If you cannot translate,
say so in the pull request and leave the English change; a maintainer will
follow up.

There is no formatter or linter for the Ruby code beyond the gate. Follow the surrounding code:
two-space indentation, comments that explain why rather than what, methods
and files named for what they hold. Prefer the plain construct Spinel compiles
well over the clever one; when a compiler constraint forces an odd shape, say
so in a comment at the spot.

## Guides and translations

The tutorial and the guides on the site are generated from the Markdown in
[docs/guide/](docs/guide/), in English and in `ja/`, `zh/`, `ru/` and `fr/`;
edit the Markdown, never the generated HTML. A change to an English guide
changes its four translations in the same pull request, then
`script/check-guide-i18n --update-sha docs/guide/<lang>/<name>.md` records
that each matches it; the gate runs `script/check-guide-i18n` when a file
under `docs/guide/` changes. If you cannot translate, say so in the pull
request and leave the English change; a maintainer will follow up. The pull
request's Gate check stays red until the four translations are updated in it,
and merging it without them would block the Pages deploys.
[docs/guide/README.md](docs/guide/README.md) has the front matter, the
conventions the Markdown uses, how to build and preview the pages
(`script/guide-pages`), and the translation rules.

## Commits

A commit is a unit of review, so make each one about one thing, and write the
message for the person reading `git log` a year from now:

- **Subject**: an imperative sentence saying what the change does, without a
  trailing period. The history often prefixes the area it touches
  (`Request: ...`, `Config: ...`, `docs: ...`, `ci: ...`, `site: ...`); do
  that when it helps. Keep it short enough to read in `git log --oneline`;
  the hook notes a subject past 72 characters but lets it through.
- **Body** (after a blank line): why the change is needed, what it does, and
  what was considered and rejected. Reference the issue it closes with
  `Fixes #N` or `Closes #N`, or `Refs #N` for one it only touches.
- **Trailers**: if an AI assistant wrote part of the change, add a
  `Co-Authored-By:` trailer naming it, as this repository's history does.

The commit-msg hook checks the mechanics (a subject, no trailing period, a
blank second line) and leaves merge, revert, fixup! and squash! commits alone.

## Pull requests

1. Fork the repository and create a branch from `main` for your change.
2. Make the change with its tests and documentation. Run `script/gate` and
   `spin test`.
3. Open the pull request against `main`. The template asks what the change
   does and why, how it was checked, and what the reviewer should know; its
   checklist is this file in five lines (the gate, `spin test`, a compiled
   run for a structural change, a test for new behaviour with changed
   snapshots explained, documentation updated). Mark it a draft if it is not ready
   for review: on a draft only the Gate runs, and CI and the image workflows
   start when it is marked ready, so push to a draft as often as you like.
4. CI must be green: the Gate workflow, the CI workflow and, when the change
   touches an image, that image's workflow. On a pull request CI runs its
   macOS jobs only when the change reaches what has differed between the
   systems (the CLI and its toolchain, the development server and the CRuby
   preview, the HTTP server, the pins, the actions; `macos` in
   [script/ci-changes](script/ci-changes) has the list), and the
   `setup-cybertrain` job only when the action, `cybertrain new` or the pins
   change; `main` runs both after every merge. Add the label `ci:macos` to
   run macOS anyway (it is read when CI starts: push, or close and reopen).
   The `required` check waits for all of them and is what `main` asks for
   (see [Branch rules](#branch-rules)). A failure you believe is unrelated
   to your change is still worth a sentence in the pull request.
5. A maintainer reviews it. Expect questions about the design and requests
   for tests; answer on the thread and push follow-up commits (do not
   force-push over commits a reviewer has already read). Approved pull
   requests are merged with a merge commit.

Keep a pull request to one change. A fix and the refactoring that enabled it
are two pull requests, or at least two commits with the refactoring first; an
unrelated improvement you noticed on the way is its own pull request, which
will land faster than it would inside yours. Changes to `docs/design.md`,
`spikes/NOTES.md`, the README and `docs/guide/` belong in the same pull request as the code
they describe.

Documentation and translation pull requests need no Spinel at all: the site
is plain HTML under `site/`, and previewing a guide needs only Ruby and three
gems (see [docs/guide/README.md](docs/guide/README.md#building-and-previewing)).
`script/gate` checks the guide translations but does not build the guides, so
if you change `docs/guide/` also run `script/guide-pages --out <tmpdir>`, as
the Gate workflow's `guide-pages` job does: it fails on a broken link or
anchor, which the gate does not see.

## Branch rules

`main` takes changes through pull requests only, and a pull request merges
only when two checks have passed on its latest commit:

- **`gate`**, the Gate workflow's job that runs `script/gate`;
- **`required`**, a check run that
  [.github/workflows/required.yml](.github/workflows/required.yml) writes on
  the commit. It covers every other workflow the pull request started (the
  Gate, CI, the image workflows): in progress while one of them runs, green
  only if each of them passed. CI and the image workflows start only for the
  paths they test, so their jobs cannot be required one by one: a
  documentation pull request would wait for ever for a job that never
  starts. `required` covers only what did start, which for a documentation
  change is the Gate, about a minute. It is written afresh, in a few
  seconds, whenever one of those workflows is requested, starts or
  finishes, a re-run included, so it holds no runner while it waits. It knows those
  workflows by name: a new workflow a pull request starts goes into the
  list at the top of `required.yml`. On a draft it stays in progress.

A pull request whose workflows did not start (one opened with
`GITHUB_TOKEN`, see [Releasing](#releasing), step 1) has neither check and
cannot be merged until they run.

The rule itself is a repository setting, which only an owner can change. Its
definition is checked in as
[.github/rulesets/main.json](.github/rulesets/main.json): pull requests
required (no approval count, so a sole maintainer can merge their own), the
two checks above required from GitHub Actions, no force push and no deletion.
To apply it, either import the file (Settings → Rules → Rulesets → New
ruleset → Import a ruleset) or run, as an owner:

```sh
gh api --method POST repos/saeki-mototsune/CyberTrain/rulesets --input .github/rulesets/main.json
```

Then check it on two pull requests: one that changes only a Markdown file
must show `gate` and `required` green within minutes, with CI not started,
and be mergeable; one that breaks a test must show `required` red and the
merge blocked. When a required check is renamed, change the file, the ruleset
and this section together.

## Dependencies and their updates

What CI and a release run is pinned, so that a run can be repeated and a
change in someone else's code arrives as a pull request, not as a surprise:

| What | Pinned how | Updated by |
|---|---|---|
| Actions (`uses:` in `.github/workflows/` and `.github/actions/`) | A commit, with the release in a comment: `actions/checkout@<commit> # vX.Y.Z` | Dependabot ([.github/dependabot.yml](.github/dependabot.yml)): one pull request a week for all of them |
| Spinel | `Cybertrain::SPINEL_TAG`, one release, equal to `SPINEL_TAG` in `ci.yml` | The Bump version workflow ([Releasing](#releasing)) |
| Gems a workflow installs (`yard`, `kramdown`, `kramdown-parser-gfm`, `rouge`, `kamal`) | `-v "~> X.Y"`: a fixed minor, the newest patch | By hand, in every workflow that installs the gem and in [docs/guide/README.md](docs/guide/README.md) |
| `prism`, for building Spinel | The exact version Spinel's Makefile names | With Spinel |
| Ruby for the scripts and the CLI | `ruby-version: "3.3"` | By hand |
| Runners and base images | `ubuntu-26.04` runners, `ubuntu:24.04` images. `macos-latest` is not pinned: it follows GitHub's current macOS image | By hand |

The gem itself has no runtime dependency and the repository has no
`Gemfile`: the gems above are tools of the documentation build and of the
Kamal check, installed in the job that uses them. A lockfile for them was
considered and left out: it would put Bundler in every job that today
needs one `gem install`, for tools whose builds already fail on a warning
or a broken link. Dependabot does not read `gem install` lines, so these
constraints move by hand.

To pin a new action, or move one by hand, take the commit from the
release's tag and write both:

```sh
git ls-remote https://github.com/actions/checkout 'refs/tags/v7*'
# an annotated tag also lists <tag>^{}: that line is the commit to use
```

An update is verified by the checks its pull request starts. Dependabot's
pull request changes every file that uses an updated action, and each
workflow a pull request can start runs on it: the Gate always (with
`script/check-workflows`), CI on both systems when `ci.yml` or a local
action changes, an image's build and smoke test when that image's workflow
changes; `required` waits for them all.
Three things no pull request exercises, because they only run when
something is published; look at them after merging an update that touches
them:

- the Pages actions (`configure-pages`, `upload-pages-artifact`,
  `deploy-pages`): the next Pages run on `main`, or run the Pages workflow
  by hand;
- `docker/login-action` and the pushes: run the Playground image workflow
  by hand with the tag `test`;
- the Release, Bump version and Spinel prebuilt workflows: read the diff;
  their next run is the next release.

When a gem's constraint moves, run what uses it before pushing:
`script/api-docs` (yard, kramdown) and `script/guide-pages --out <tmpdir>`
with the tests under `script/guide-pages.d/test/` (kramdown, rouge); the
Blog image workflow loads `config/deploy.yml` with Kamal.

## Releasing

The gem and the framework are released from the same tag, and `cybertrain
new` depends on the tag `v` + `Cybertrain::VERSION`, so the tag must exist
before the gem is pushed:

1. Bump `Cybertrain::VERSION` (`cybertrain/version.rb`) and `version` in
   `spin.toml` together (CI checks they match); spin caches a git
   dependency by that version. The **Bump version** workflow
   ([.github/workflows/bump-version.yml](.github/workflows/bump-version.yml),
   run by hand from the Actions tab) does this and opens the pull request:
   give it the new version and, to move to another Spinel release, the new
   `Cybertrain::SPINEL_TAG`. It runs
   [script/bump-version](script/bump-version), which also moves
   `SPINEL_TAG` in `ci.yml` and the numbers the tests expect. It needs the
   repository secret `RELEASE_PR_TOKEN` (a fine-grained personal access
   token for this repository with Contents, Pull requests and Workflows:
   read and write; Workflows because a Spinel bump changes `ci.yml`): a
   pull request opened with `GITHUB_TOKEN` starts no workflows, so there is
   no fallback to it, and without the secret the run fails in its first
   step with nothing pushed. With it, the Gate and CI run on the pull
   request, and the run waits until both have started and fails if they
   have not. Renew the secret when the token expires.

   Before merging a minor release's bump, check that the release's upgrade
   notes are written: a section under "Notes by version" in
   [docs/guide/upgrading.md](docs/guide/upgrading.md), in the four
   translations too, with an entry for every compatibility change since the
   previous release ([docs/compatibility.md](docs/compatibility.md#changing-a-contract)).
   The section names its releases as `X.Y` ("From 0.4 to 0.5"), which
   `script/check-version-mentions` allows. A patch release has no notes.
2. Merge to `main`, then tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. `gem build cybertrain.gemspec && gem push cybertrain-X.Y.Z.gem`.
4. The tag runs [.github/workflows/release.yml](.github/workflows/release.yml);
   check that run. In order:
   - It runs the Gate, the full CI (Linux and macOS, built against the
     Spinel release the tag pins) and the blog image's build and smoke test
     ([.github/workflows/blog-image.yml](.github/workflows/blog-image.yml))
     on the tagged commit. If any of those fails, nothing is published.
   - It pushes, in parallel, the playground image
     `ghcr.io/saeki-mototsune/cybertrain-playground:X.Y.Z`
     ([.github/workflows/playground-image.yml](.github/workflows/playground-image.yml))
     and the blog image `ghcr.io/saeki-mototsune/cybertrain-blog:X.Y.Z`.
     The blog image pushed is the one the smoke test ran on, kept as a
     workflow artifact for 7 days, not a second build: to re-run its push
     later than that, re-run the whole workflow. If one image push fails,
     no release is created, but the other image's `X.Y.Z` may already be
     pushed: check both packages before re-running the failed jobs.
   - It creates the GitHub release `vX.Y.Z`, with notes generated from the
     pull requests merged since the previous tag. For a tag pushed without
     a release, run that workflow by hand on the tag itself (Run workflow,
     "Use workflow from", Tags, `vX.Y.Z`); a manual run started on a branch
     is refused, so a release never runs a tag's code with the default
     branch's cache.
   - Its `promote-latest` job points `latest` of both images at the newest
     release: the highest `X.Y.Z` that has a published release, whichever
     run it is in. Releases of different tags may run at the same time, and
     a manual run may release an old tag, without `latest` going back; that
     job runs one at a time across all release runs, and when several wait
     GitHub cancels all but the newest waiting one, which is harmless (each
     would move `latest` to the same image). Nothing else pushes `latest`;
     to repair it, re-run that job.
   - Its `spinel-prebuilt` job attaches a Linux build of the fork's latest
     Spinel release to the release (`spinel-<tag>-linux-x86_64.tar.gz`, for
     Claude Code cloud sessions; see below); check that it passed.
5. Once the framework is on the spin index, and to put it there the first
   time: publish the release to it, by hand, after the Release workflow has
   passed. See [Publishing to the spin index](#publishing-to-the-spin-index).
   No workflow does this, and none should: it opens a pull request in
   someone else's repository under the name of whoever runs it.

### Publishing to the spin index

The framework is not on [spin-index](https://github.com/matz/spin-index)
yet, and nothing depends on it being there: `cybertrain new` writes the git
tag. Registering it is a decision for the maintainer (the first three
points under "Check first" are what it turns on). From the first accepted
release on, every release is published: spin selects the *lowest* release
that satisfies a constraint, so `cybertrain new --version X.Y.Z` of a new
gem finds nothing until X.Y.Z is in the index.

What follows was read from spin's source (`tools/spin.rb`, `cmd_publish`,
and `docs/spin.md`, `docs/internals/spin.md` in the Spinel release
`Cybertrain::SPINEL_TAG` names) and checked against a local index
(`SPIN_INDEX=file://...`) as far as resolving goes; `spin publish` itself
has never been run for this repository, so read its output the first time.

```sh
git clone https://github.com/saeki-mototsune/cybertrain && cd cybertrain
git checkout vX.Y.Z            # publish records HEAD, not a tag
"$(dirname "$(command -v spin)")/spinel" --version   # the compiler spin runs: the release Cybertrain::SPINEL_TAG names
gh auth status
spin publish --repo https://github.com/saeki-mototsune/cybertrain
```

What `spin publish` does, in order, stopping at the first that fails:

1. reads `[package] name` and `version` from `spin.toml`;
2. takes the repository from `--repo`, or else from `git remote get-url
   origin` (an ssh GitHub URL becomes https, a trailing `.git` is dropped;
   a `file://` or local path is refused);
3. requires `git status --porcelain` to print nothing (untracked files
   count) and takes `git rev-parse HEAD` as the release's commit, which
   must be on a remote branch (`git branch -r --contains`) and whose
   `spin.toml` must carry the same version;
4. runs the whole of `spin test`: every program must pass (the full
   suite; [Running the tests](#running-the-tests) says how long). The compiler is the `spinel`
   executable in the directory of the `spin` binary, and the one on `PATH`
   only when there is none there, which is why the recipe asks that one,
   not a bare `spinel`, for its version;
5. updates its clone of the index (`~/.cache/spin/index`) and refuses if
   `packages/cybertrain.toml` names another repository, or already has
   this version (compared as numbers: `0.5` and `0.5.0` are one version);
6. appends a `[[release]]` (the version and the full commit) and a
   `[[probe]]` (the version, the revision in the parentheses of that
   compiler's `--version`, `result = "pass"`, the date) to that file;
7. with `gh` installed and authenticated: forks `matz/spin-index` for the
   `gh` user, pushes a branch `publish-cybertrain-X-Y-Z` there and opens a
   pull request titled `cybertrain X.Y.Z` against the index. Without `gh`
   it prints the entry to submit by hand. `--direct` commits to the index
   and pushes instead, which needs write access to it.

The release exists for users when that pull request is merged. Then check
it: `spin search cybertrain` prints X.Y.Z, and `cybertrain new probe
--version X.Y.Z` in a temporary directory locks the tag's commit (`ref` in
its `spin.lock` equals `git rev-parse 'vX.Y.Z^{commit}'`).

Check first:

- **The name.** An index name belongs to the first repository whose
  publish pull request is accepted, and the index's rule is that a name
  shared with a rubygems.org gem means the same library. `cybertrain` on
  rubygems.org is this project's own CLI gem, so the name is ours to ask
  for; whether the index's maintainers agree is their review. Published
  repositories are "conventionally" named `spinel-<name>`: that is a
  comment `spin new --lib` writes, and `spin publish` does not check it.
- **The repository URL, once and for all.** Later publishes are refused
  unless the repository is, character for character, the one in the index
  entry, and this repository answers to two spellings (`CyberTrain`, as
  in [Setting up a checkout](#setting-up-a-checkout), and `cybertrain`,
  as in `Cybertrain::REPOSITORY`). Always pass `--repo` with
  `Cybertrain::REPOSITORY`, the URL `cybertrain new` writes, so that an
  index dependency and a tag dependency lock the same `git =`.
- **The probe is the fork's.** The index has no field for the Spinel a
  package needs (a `spinel =` constraint in `spin.toml` is planned
  upstream, not implemented). All it records is the probe: the build
  revision of the compiler that ran the tests when publishing, which here
  is a commit of the
  [saeki-mototsune fork](https://github.com/saeki-mototsune/spinel), not
  one of matz/spinel. Someone who runs `spin add cybertrain` with upstream
  Spinel gets no warning from that, and upstream's rule is that a name is
  held while its probes pass "at current engine revisions", with failures
  appended by re-probe sweeps. So before the first publish, run the suite
  with the upstream Spinel release nearest the pinned one and say in the
  pull request what it did; if it fails there, the framework is not ready
  for the index, whatever `spin publish` says.
- **The tag is released.** The Release workflow passed for `vX.Y.Z`, the
  gem is pushed, and the checkout is the tag with nothing else in it.
- **`SPIN_INDEX` is unset**, or it names the index you mean: spin
  publishes to whatever it names.

The pages a reader follows, the site (`site/`), the guides (`docs/guide/`),
the deployment tutorial (`docs/deploy.md`, `docs/deploy.en.md`,
`docs/deploy-kamal.md`) and the two READMEs a user reads (`README.md`,
`playground/README.md`), do not name the release numbers
`Cybertrain::VERSION` and `Cybertrain::SPINEL_TAG`, so a release changes none
of them. Describe the number instead ("the pinned Spinel release",
`Cybertrain::SPINEL_TAG`), write `X.Y.Z`, `vX.Y.Z` or `SPINEL_TAG` in commands
and output, and point at `cybertrain version` and `cybertrain doctor`, which
print them. [script/check-version-mentions](script/check-version-mentions),
run by the Gate, fails when one of those pages names the current numbers. A
record of what was measured or re-checked on a given release belongs outside
those files (`docs/benchmark.md`, `docs/spinel-feedback.md`).

`Cybertrain::SPINEL_TAG` (also in `cybertrain/version.rb`) is the Spinel
release `cybertrain setup` installs. It must equal `SPINEL_TAG` in
[.github/workflows/ci.yml](.github/workflows/ci.yml), which `script/gate`
checks, so change the two together when the framework moves to another
Spinel release. [script/claude-cloud-setup](script/claude-cloud-setup) is
not pinned: it builds the latest release of the
[saeki-mototsune fork](https://github.com/saeki-mototsune/spinel), which can
be newer than `Cybertrain::SPINEL_TAG`. To start a cloud session in seconds
rather than minutes, it downloads that release prebuilt from the latest
cybertrain release, to which
[.github/workflows/spinel-prebuilt.yml](.github/workflows/spinel-prebuilt.yml)
(called by the Release workflow) attaches a build made in an `ubuntu:24.04`
container. When the fork has released again since, the script builds Spinel
from source; run that workflow by hand with the latest release (`vX.Y.Z`)
to attach a build of the newer Spinel to it.


## Licensing

cybertrain is released under the [MIT License](LICENSE). By submitting a
contribution you agree that it is licensed the same way, and that you have the
right to submit it under those terms. There is no contributor agreement to
sign.
