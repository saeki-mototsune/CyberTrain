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
  lists the constraints found so far and how the code works around them.
  When something will not compile, look there first, and add a note when you
  find a new one. Its section "Workarounds that shape the design" says which
  shapes are permanent, which are tied to the pinned build and which test
  covers each, and what a Spinel update re-checks.
- **A CRuby pass is not acceptance for a structural change.** The commit
  gate, `ruby -I. test/<name>.rb`, `script/preview-parity` and the
  development server's CRuby preview run under CRuby, where none of Spinel's
  constraints exist: a page that works in the preview, or a test that
  matches its snapshot there, says nothing about whether the code compiles.
  The tests known to differ between the runtimes are listed, each with its
  cause, in [test/cruby/parity-gaps.txt](test/cruby/parity-gaps.txt). A change that moves code between methods, classes or
  files, changes what a block or a Proc crosses, adds a shared helper or a
  base class, or changes what the generator emits must pass the affected
  tests compiled (`spin test`), and a generator change must leave
  `examples/blog` regenerating clean and passing. Say in the pull request
  which compiled tests you ran.
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

`ruby -I. exe/cybertrain` runs the CLI from the checkout (`spin install`
instead builds `bin/cybertrain.rb` into `~/.local/bin/cybertrain`), and `cybertrain new NAME
--path ~/src/cybertrain` creates an app against the checkout; `gem install
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
  `playground/Dockerfile` copies each of those files into its gem stage, the
  Playground image and Blog image workflows run for a pull request that
  changes one of them or a pin, and every `test/*.rb` has its `.expected`
  snapshot.
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

Tests that need SQLite or other FFI only run compiled (`spin test --regen
test/<name>.rb` would capture CRuby's output; [spikes/NOTES.md](spikes/NOTES.md),
rule 23); `script/regen-snapshot` handles that. Use the assertions in `cybertrain/test.rb` (`assert`,
`assert_equal`, `assert_raises("Class") { }`, ...); for controllers and HTTP
flows, `Cybertrain::Test::Client` drives an application in-process, as
[examples/blog/test/](examples/blog/test/) does.

The example application is a test too. If your change affects what the
generator emits or how an application runs:

```sh
cd examples/blog
spin run gen && git status --short -- gen/     # generated code must be fresh: this prints nothing
spin test
```

`git status` rather than `git diff`: a file the generator writes for the
first time is untracked, and `git diff` passes over it. CI fails on either.

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
`cruby-preview` job. `script/preview-e2e` builds the blog with Spinel
several times, prints one `ok` or `FAIL` line per step and is run by hand:
run it after changing the supervisor, the shim or the framework's
development server.

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs all of this on
Ubuntu and macOS, builds and installs the gem, scaffolds and serves an
application end to end, and builds the API reference with YARD (any warning
fails it: `script/api-docs`, the `api-docs` job). A change to nothing but
the API reference's own inputs (`docs/api/`, `script/api-docs`, `.yardopts`)
runs that job alone; [script/ci-changes](script/ci-changes) holds the rule
and `script/ci-changes --self-test` checks it. Its `setup-cybertrain` jobs run the action
applications use in their own CI
([.github/actions/setup-cybertrain](.github/actions/setup-cybertrain/action.yml))
on a newly generated application, so a change to that action is tested like
any other.

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
- **A workflow's token can do only what its jobs need.** Every workflow
  states `permissions:` at the top, so nothing relies on the repository's
  default: read access for what only checks (the Gate, CI, `required`),
  write access only where something is published (a release, a package,
  the site), on the job that publishes when the workflow has others. Every
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

- **The workflows pass actionlint.** A workflow or a composite action under
  `.github/` that loads as YAML can still name a job, an input or a step
  output that does not exist, and GitHub says so only when it runs, which for
  the release workflow is at release time. The Gate workflow's `actionlint`
  job runs [script/lint-workflows](script/lint-workflows) on every pull
  request; with [actionlint](https://github.com/rhysd/actionlint) installed
  (and shellcheck, which it calls for the `run:` scripts) the same command
  runs locally. The commit gate does not run it.

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
   does and why, how it was checked, and what the reviewer should know; the
   checklist is the gate above in prose. Mark it a draft if it is not ready
   for review.
4. CI must be green: the Gate workflow, the CI workflow (both operating
   systems) and, when the change touches an image, that image's workflow.
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
- **`required`**, the one job of
  [.github/workflows/required.yml](.github/workflows/required.yml). It waits
  for every other workflow the pull request started (the Gate, CI, the image
  workflows) and passes only if each of them did. CI and the image workflows
  start only for the paths they test, so their jobs cannot be required one by
  one: a documentation pull request would wait for ever for a job that never
  starts. `required` starts on every pull request and waits only for what
  did start, which for a documentation change is the Gate, about a minute.

A pull request whose workflows did not start (one opened with
`GITHUB_TOKEN`, see [Releasing](#releasing), step 1) has neither check and
cannot be merged until they run. After re-running a failed job, re-run
`required` as well: it reported on the attempt it saw.

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
merge blocked. When a required job is renamed, change the file, the ruleset
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
2. Merge to `main`, then tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. `gem build cybertrain.gemspec && gem push cybertrain-X.Y.Z.gem`.
4. The tag runs [.github/workflows/release.yml](.github/workflows/release.yml),
   which tests the tag (below) and, only if every check passes, publishes the
   playground image `ghcr.io/saeki-mototsune/cybertrain-playground:X.Y.Z`
   through
   [.github/workflows/playground-image.yml](.github/workflows/playground-image.yml)
   and the blog image `ghcr.io/saeki-mototsune/cybertrain-blog:X.Y.Z`, built
   and smoke-tested by
   [.github/workflows/blog-image.yml](.github/workflows/blog-image.yml);
   check that run.
5. The tag also creates the GitHub release `vX.Y.Z`, with notes generated
   from the pull requests merged since the previous tag, through
   [.github/workflows/release.yml](.github/workflows/release.yml). That
   workflow first runs the Gate, the full CI (Linux and macOS, built against
   the Spinel release the tag pins) and the blog image's smoke test on the
   tagged commit. If any of those fails, nothing is published. Once they
   pass, it pushes the playground and blog images (in parallel) and then
   creates the release. The blog image pushed is the one the smoke test
   ran on, kept as a workflow artifact for 7 days, not a second build: to
   re-run its push later than that, re-run the whole workflow. If one image
   push fails, no release is created, but the other image's `X.Y.Z` may
   already be pushed: check both packages before re-running the failed jobs. For a tag pushed without a
   release, run that workflow by hand with the tag. Last, its
   `promote-latest` job points `latest` of both images at the newest
   release: the highest `X.Y.Z` that has a published release, whichever run
   it is in. Releases of different tags may run at the same time, and a
   manual run may release an old tag, without `latest` going back; that job
   runs one at a time across all release runs, and when several wait GitHub
   cancels all but the newest waiting one, which is harmless (each would
   move `latest` to the same image). Nothing else pushes `latest`; to repair
   it, re-run that job. After the release is
   created, the same run attaches a Linux build of the fork's latest Spinel
   release (`spinel-<tag>-linux-x86_64.tar.gz`, for Claude Code cloud
   sessions; see below); check that its `spinel-prebuilt` job passed.

The pages a reader follows, the site (`site/`), the guides (`docs/guide/`),
the deployment tutorial (`docs/deploy.md`, `docs/deploy.en.md`,
`docs/deploy-kamal.md`) and the READMEs, do not name the release numbers
`Cybertrain::VERSION` and `Cybertrain::SPINEL_TAG`, so a release changes none
of them. Describe the number instead ("the pinned Spinel release",
`Cybertrain::SPINEL_TAG`), write `X.Y.Z`, `vX.Y.Z` or `SPINEL_TAG` in commands
and output, and point at `cybertrain version` and `cybertrain doctor`, which
print them. [script/check-version-mentions](script/check-version-mentions),
run by the Gate, fails when one of those pages names the current numbers. A
record of what was measured on a given release belongs in `docs/` outside
those files.

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
