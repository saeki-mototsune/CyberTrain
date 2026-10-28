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
  rest of `cybertrain/` is a spin package an application depends on. Things
  Ruby programmers take for granted (`method_missing`, `define_method`,
  `instance_variable_get`, `eval`) do not exist. [spikes/NOTES.md](spikes/NOTES.md)
  lists the constraints found so far and how the code works around them.
  When something will not compile, look there first, and add a note when you
  find a new one.
- **Every design decision is written down.** [docs/design.md](docs/design.md)
  records what was decided, what was rejected and why. Read the
  relevant section before changing a behaviour, and update it when a
  decision changes. [README.md](README.md) explains the framework to its
  users and [docs/template-language.md](docs/template-language.md) the
  template grammar.
- **Generated code is committed.** `spin` has no build hooks, so
  `examples/blog/gen/` and the generated files in `test/fixtures/` are
  committed and CI checks they are fresh.

Open an issue before a large change (a new subsystem, a change to what the
generator emits, a new dependency): the issue is where the design gets agreed,
so that the pull request can be about the code.

## Setting up a checkout

The requirements are the ones in [docs/guide/install.md](docs/guide/install.md#requirements): Ruby
3.2 or newer, a C compiler, make, git, curl, and the SQLite and zlib headers.
Then:

```sh
git clone https://github.com/saeki-mototsune/CyberTrain.git
cd CyberTrain
script/install-hooks           # the commit gate, once per clone (below)
ruby -I. exe/cybertrain doctor # what is missing, if anything
ruby -I. exe/cybertrain setup  # builds the pinned Spinel into ~/.cybertrain (minutes, once)
spin test                      # the suite; see "Running the tests"
```

`ruby -I. exe/cybertrain` runs the CLI from the checkout; `gem install
cybertrain` gives you the released one instead, which installs the same
Spinel. On an Ubuntu machine you can also run
[script/claude-cloud-setup](script/claude-cloud-setup), which does the whole
setup non-interactively. The [playground](https://saeki-mototsune.github.io/CyberTrain/playground.html)
is a quick way to try the framework, not a place to develop it.

## The commit gate

Every commit passes a gate: a set of fast checks (about a second, CRuby only,
no Spinel) that catch what is cheap to catch before a reviewer or a
20-minute CI run does. `script/install-hooks` points this clone's git hooks
at [.githooks/](.githooks/), after which:

- **pre-commit** runs `script/gate --staged` on the files being committed:
  trailing whitespace, final newlines, LF line endings, merge-conflict
  markers, Ruby syntax (`ruby -c`), YAML files load; and, when the commit
  touches the framework, the CLI, the tests, the scripts or the playground's
  Dockerfile, the repository checks: the version and Spinel-tag pins agree,
  `script/check-reserved-names`, `check-client-faults` and `check-http-layer`
  pass (see [Conventions](#conventions-ci-enforces) for what each guards),
  every file `cybertrain.gemspec` lists exists, the CLI loads under CRuby and
  `playground/Dockerfile` copies each of those files into its gem stage, and
  every `test/*.rb` has its `.expected` snapshot.
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
spin test                      # everything (one program per test/*.rb; minutes the first time, then cached)
spin test test/router.rb       # one program
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
(the next paragraph), `ruby -I. test/<name>.rb` under CRuby, which takes a
second and needs no compiler.

Tests that need SQLite or other FFI only run compiled; `script/regen-snapshot`
handles that. Use the assertions in `cybertrain/test.rb` (`assert`,
`assert_equal`, `assert_raises("Class") { }`, ...); for controllers and HTTP
flows, `Cybertrain::Test::Client` drives an application in-process, as
[examples/blog/test/](examples/blog/test/) does.

The example application is a test too. If your change affects what the
generator emits or how an application runs:

```sh
cd examples/blog
spin run gen && git diff --exit-code -- gen/   # generated code must be fresh
spin test
```

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs all of this on
Ubuntu and macOS, builds and installs the gem, scaffolds and serves an
application end to end, and builds the API reference with YARD (any warning
fails it: `script/api-docs`).

## Conventions CI enforces

Each of these exists because of a bug or a constraint that was found the hard
way; the script or workflow step that checks it says so in its comment.

- **A column may not be named after a `Cybertrain::Model` method.** Add a
  method or an ivar to `Model` and `Ident::RESERVED_COLUMN_NAMES` must list
  it, or a generated reader silently shadows it (`script/check-reserved-names`).
- **Every client fault is listed.** A new `QueryInvalid` subclass must be in
  `ClientError::CLIENT_FAULTS`, or it is a 500 under Spinel, where the class
  hierarchy is not visible (`script/check-client-faults`).
- **The HTTP layer stands alone.** `cybertrain/http/*` must load without the
  rest of the framework, so it can be lifted out (`script/check-http-layer`).
- **The CLI runs under CRuby and lists its files by hand.** A file the CLI
  requires must be in `cybertrain.gemspec`'s `spec.files`; CI installs the
  built gem and runs it.
- **Versions are pinned in one place.** `Cybertrain::VERSION` equals
  `spin.toml`'s version; `Cybertrain::SPINEL_TAG` equals `SPINEL_TAG` in
  `ci.yml` and in `script/claude-cloud-setup`.
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
- **The site is published in five languages.** A change to an English page
  under `site/` changes `ja/`, `zh/`, `ru/` and `fr/` with it, and
  `script/check-site-i18n` verifies the structure matches (see
  [site/README.md](site/README.md), "Translations"). If you cannot translate,
  say so in the pull request and leave the English change; a maintainer will
  follow up.

There is no formatter or linter beyond the gate. Follow the surrounding code:
two-space indentation, comments that explain why rather than what, methods
and files named for what they hold. Prefer the plain construct Spinel compiles
well over the clever one; when a compiler constraint forces an odd shape, say
so in a comment at the spot.

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
   does and why, how it was checked, and what the reviewer should know; the
   checklist is the gate above in prose. Mark it a draft if it is not ready
   for review.
4. CI must be green: the Gate workflow and the CI workflow (both operating
   systems). A failure you believe is unrelated to your change is still worth
   a sentence in the pull request.
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

Documentation and translation pull requests need no Spinel at all:
`script/gate` is the only check, and the site is plain HTML under `site/`.

## Releasing

The gem and the framework are released from the same tag, and `cybertrain
new` depends on the tag `v` + `Cybertrain::VERSION`, so the tag must exist
before the gem is pushed:

1. Bump `Cybertrain::VERSION` (`cybertrain/version.rb`) and `version` in
   `spin.toml` together (CI checks they match); spin caches a git
   dependency by that version.
2. Merge to `main`, then tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. `gem build cybertrain.gemspec && gem push cybertrain-X.Y.Z.gem`.
4. The tag also publishes the playground image
   `ghcr.io/saeki-mototsune/cybertrain-playground:X.Y.Z` (and `latest`) through
   [.github/workflows/playground-image.yml](.github/workflows/playground-image.yml);
   check that run.
5. The tag also creates the GitHub release `vX.Y.Z`, with notes generated
   from the pull requests merged since the previous tag, through
   [.github/workflows/release.yml](.github/workflows/release.yml). For a tag
   pushed without a release, run that workflow by hand with the tag.

`Cybertrain::SPINEL_TAG` (also in `cybertrain/version.rb`) is the Spinel
release `cybertrain setup` installs. It must equal `SPINEL_TAG` in
[.github/workflows/ci.yml](.github/workflows/ci.yml) and in
[script/claude-cloud-setup](script/claude-cloud-setup), which `script/gate`
checks, so change the three together when the framework moves to another
Spinel release.


## Licensing

cybertrain is released under the [MIT License](LICENSE). By submitting a
contribution you agree that it is licensed the same way, and that you have the
right to submit it under those terms. There is no contributor agreement to
sign.
