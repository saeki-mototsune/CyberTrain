# Development-flow bottlenecks: implementation plan

**Spec:** [docs/superpowers/specs/2026-11-12-dev-flow-bottlenecks-design.md](../specs/2026-11-12-dev-flow-bottlenecks-design.md)
(D-a, D-b, D-c). One branch, one pull request.

## Global constraints

- `cybertrain/cli*` runs under CRuby and compiles under Spinel; everything
  else under `cybertrain/` compiles under Spinel only: no `send`, no `eval`,
  typed empty arrays (`Array.new(0) { "" }`), one return type per method.
- Commits pass `script/gate` (the hook is installed); no `--no-verify`.
  Message shape: CONTRIBUTING.md, "Commits".
- A changed snapshot goes through `script/regen-snapshot test/<name>.rb`
  (or `spin test --regen` for a test that runs under CRuby) and its diff is
  read. Never run two `spin` commands at once in one package.
- A guide page edited in `docs/guide/*.md` is edited in its four
  translations (`script/check-guide-i18n`), and the generated `site/` pages
  follow whatever `script/gate` asks for.
- No version bump, no change of the Spinel pin.

## Task 1 (done, e3c229c): D-a, `write_schema` writes only a changed dump

`cybertrain/db/cli.rb`, `test/db_cli.rb` and its snapshot.

## Task 2: D-b and D-c in the CLI and the rebuilder

**Files:** `cybertrain/shell.rb`, `cybertrain/cli/build.rb`,
`cybertrain/cli.rb`, `cybertrain/cli/new_app.rb`,
`cybertrain/cli/templates.rb`, `cybertrain/dev/rebuilder.rb`; tests
`test/cli_build.rb`, `test/cli_new.rb`, `test/dev_error_page.rb` and
whatever other test pins these strings, with their snapshots; the guide
page that describes what `cybertrain server` and `cybertrain db` run.

**Interfaces:**

- `Cybertrain::Shell::TOOL_SPIN = "SPIN_DEBUG=1 spin"`: the one definition
  of how gen and db are built (the CLI and `Dev::Rebuilder` both load
  `cybertrain/shell`). Its comment says why (spec C3) and that the mode is
  kept per executable in `build/bin/.<name>.mode`.
- `Build.commands(name)`: `["SPIN_DEBUG=1 spin run gen -- --embed-views",
  "spin build NAME", "SPIN_DEBUG=1 spin run gen"]`.
- `Build.db_commands(args)`: both `run gen` and `run db` carry the prefix.
- `Build.server_commands(name, port)`: `["SPIN_DEBUG=1 spin run gen",
  "spin run NAME[ -- PORT]"]` (the gen step changes, the shape does not).
- `Build.incremental_command(name)`: `"spin build NAME -- --incremental"`,
  the name through `quote_arg`.
- `Build.binary_stale?(root, name)`: true when `root/build/bin/NAME` is
  missing, or a `*.rb` file under `root` is newer than it. Not followed:
  `build`, `dist`, `tmp`, `storage`, `public`, `.git` at the top level, and
  symlinked directories. Plain recursion over `Dir.children`.
- `Build.run_server(root, name, port, runner = Runner.new)`: runs the gen
  step; then, if `binary_stale?`, the incremental build; then the run step.
  Stops at the first failing step and returns 1; returns 0 when the server
  exits 0. `CLI.run_server` calls it after `Toolchain.ensure!`.
- `NewApp.bootstrap_command(dir)`: `cd DIR && spin lock && SPIN_DEBUG=1 spin
  run gen`; the line it prints and `recovery_command`
  (`... && SPIN_DEBUG=1 cybertrain spin run gen`) follow.
- `Dev::Rebuilder::GEN_COMMAND = "#{Shell::TOOL_SPIN} run gen"`, the default
  of `#command`'s `gen` argument.
- The CI workflow template: `run: SPIN_DEBUG=1 spin run gen -- --check`,
  with a comment line saying it is the mode the CLI builds gen in.
- `USAGE` in `cybertrain/cli.rb`: the three places that spell out what `db
  migrate`, `db COMMAND` and `server` run say what they run now.

**Tests (written first, seen failing):**

- `test/cli_build.rb`: the command lists above; `incremental_command`
  quotes an odd name; `binary_stale?` on a temporary tree (missing binary;
  binary newer than every file; a `.rb` in `app/` newer; a `.rb` under
  `build/` or `tmp/` newer does not count; a non-Ruby file newer does not
  count), with `File.utime` rather than sleeps; `run_server` with a fake
  runner: fresh binary runs two steps, stale runs three in order, a failing
  gen or incremental step runs nothing after it and returns 1.
- `test/cli_new.rb`: the bootstrap and recovery commands, the workflow text.
- `test/dev_error_page.rb`: the rebuild command strings with the prefix.

**Check:** `ruby -I. test/cli_build.rb` and `ruby -I. test/cli_new.rb`
under CRuby while iterating; then `spin test` on each changed test, one at
a time, compiled; `script/gate`.

## Task 3: the record

- `docs/design.md`: a dated note on D12 (the server's first build is the
  incremental one; gen and db are debug builds) and on the paragraph about
  `db/schema.rb` being rewritten.
- `docs/performance-next.md`: the table of the spec's section 1 measured
  before and after, and the `-O0` entry amended (it holds for the
  application's edit, not for the tools).
- `docs/spinel-feedback.md`: the analysis-time table as an item for Spinel
  (spec C1), and `spin test` in parallel (C5).

## Task 4: measure again

The steps of the spec's section 1, on the same VM, with the branch.
