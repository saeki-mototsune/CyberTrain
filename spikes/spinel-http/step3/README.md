# spinel-http steps 3 and 4: the mechanisms (Task 0 spike)

Records, not tests: `spin test` does not run them. Recorded 2026-11-23,
Linux x86_64, gcc 13.3.0. **fork** is `spinel`/`spin` 2026.11.15.7033
(a2f3bfaa) on PATH; **upstream** is 2026.10.25 (2814693f) with
`PATH=$HOME/.spinel-upstream/2026.10.25/bin:$PATH`. Every program was run
under both; every check passed under both (41 of 41 `PASS` lines, and the
Step 1 run), so there is no stop condition.

Commands, from this directory (`$W` an empty directory outside any repository):

    sh gitdep.sh $W                        # Step 1
    sh run.sh $W/out                       # Steps 2 to 4: spinel -I . NAME.rb -o $W/out/NAME, then runs it

| Step | Question | Program | fork | upstream |
| --- | --- | --- | --- | --- |
| 1 | `mid` (path dependency of an app) has a git dependency `{ git = "file:///...demo-lib.git", ref = "v0.0.1" }`; a file of `mid` does `require "demo-lib/a"`. Do `spin lock`, `spin build`, `spin test` work, and does spin.lock list demo-lib? | `gitdep.sh` | PASS | PASS |
| 2 | `B::K = A::K`: `B::K.new.x`, `class Sub < B::K`, `rescue B::E` for `A::E` (and the reverse), `B::K.name == "A::K"`, `B::K.equal?(A::K)` | `class_alias.rb` | PASS (7/7) | PASS (7/7) |
| 3a | Reopening `module B; class K; def y` after `B::K = A::K` adds `y` to `A::K` (same object, not a new class) | `reopen_alias.rb` | PASS (4/4) | PASS (4/4) |
| 3b | cybertrain/params.rb's shape: `module Cybertrain; class Params` reopened (permit, require, nested `ParameterMissing`) over `Cybertrain::Params = SpinelHttp::Params`, in a second file, children built by the first file | `reopen_main_alias.rb` + `reopen_shape/` | PASS (9/9) | PASS (9/9) |
| 3c | The same additions by the real name, `module SpinelHttp; class Params`, from a cybertrain file | `reopen_main_real.rb` + `reopen_shape/` | PASS (9/9) | PASS (9/9) |
| 4 | `B::M = A::M`: `B::M.f`, `equal?`, `name`; module-level slots (`@x` with `def self.x`/`x=`, and `class << self; attr_accessor`) set through `B::M` read through `A::M` and back; the same for a class (`Params.max_page`, `ClientError.extra_faults`) | `module_alias.rb` | PASS (12/12) | PASS (12/12) |

## Findings

- **Step 1.** spin accepts `file://` git URLs. `spin lock` resolves the
  transitive git dependency of a path dependency and writes it to
  spin.lock as `[lock.demo-lib]` with `git = "file://..."` and `ref` set to
  the **commit sha** the tag `v0.0.1` pointed at, not the tag name.
  `spin list --json` lists `mid` (kind `path`) and `demo-lib` (kind `git`).
  `require "demo-lib/a"` from `mid/mid/b.rb` builds, runs and passes
  `spin test`. A library's `demo-lib/demo-lib.rb` plus `demo-lib/demo-lib/a.rb`
  layout (name dir inside the root) is what resolves.
- **Step 2.** A constant alias is the same class object: `new`, subclassing
  the alias, `rescue` by either name in both directions, `name` answers the
  definition's qualified name (`A::K`), `equal?` is true.
- **Step 3.** Plain reopening through the alias works (3a, 3b): the methods
  land on the original class, children the first file built answer them,
  the nested `ParameterMissing` is the same class under both paths. So
  `module Cybertrain; class Params ... end; end` over the alias is the
  working form, and also reopening by the real name (3c) works; either may
  be used. **Working form: the alias form (3b)**, unchanged cybertrain
  files. For 3c, an error class nested in the reopened class needs its own
  alias (`Cybertrain::ParameterMissing = SpinelHttp::Params::ParameterMissing`)
  if code names it from `Cybertrain::`.
- **Step 4.** Module and class aliases forward module methods and both slot
  shapes in both directions. The alias reads and writes the one slot.
