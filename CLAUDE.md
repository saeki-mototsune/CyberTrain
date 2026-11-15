# Notes for Claude Code sessions

[CONTRIBUTING.md](CONTRIBUTING.md) has the setup, the commit gate, the tests
and the conventions CI enforces. This file holds only what a session needs
beyond it.

## Split multi-agent work across workflows

A workflow runs at most `min(16, CPU cores - 2)` agents at once, and the cap
is per workflow, not per session: on a 4-core cloud container one workflow
runs two agents at a time, and the rest wait. So when a task fans out over
many agents:

- **Split read-only stages across several workflows launched together**
  (searching, reviewing, verifying, proposing): give each workflow a subset
  of the areas, three or four areas each. Do this from the start, not after
  noticing agents waiting.
- **Keep stages that write to the shared working tree in one workflow, run
  one agent after another**, even when the agents touch disjoint files.
  Agents that edit, commit, or run `spin test` share the git index and
  `build/`; two at once corrupt each other's results. Finish and commit one
  area before the next starts. Writing agents may run in parallel only when
  each has its own worktree and build directory.
- **A read-only workflow may run beside a writing one**, as long as its
  agents build only outside the repository (a scratch directory) and are
  told which code is about to change.

Compiling is the bottleneck on a small container (the whole suite takes
hours on 4 cores while agents are also compiling): have each agent run the
gate and the few test programs that exercise what it touched, and leave the
whole suite to CI.
