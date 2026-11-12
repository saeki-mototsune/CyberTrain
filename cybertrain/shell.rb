module Cybertrain
  # The one definition of how a value is quoted for sh: the CLI (Build, for
  # `cybertrain db`/`server`/`build` and the commands `cybertrain new` runs;
  # Toolchain, building and probing Spinel) and the development rebuilder
  # (Dev::Rebuilder#command) all shell out with paths and names they did not
  # choose. A leaf file with no requires: the CLI (CRuby) and the framework
  # (Spinel) both load it.
  module Shell
    # How the CLI (`cybertrain new`, `db`, `migration`, `server`, `build`)
    # and the development rebuilder run spin for gen and db: in spin's debug
    # mode (-O0 -g). Both tools run for milliseconds, and at -O2 one C
    # compiler process spends 33 of gen's 38 s on its single unit; in debug
    # mode gen builds in 8.5 s and writes the same files
    # (docs/superpowers/specs/2026-11-12-dev-flow-bottlenecks-design.md, C3).
    # spin keeps the mode per executable in build/bin/.<name>.mode, so a
    # debug gen is up to date for the next debug run and the application,
    # built without the prefix, stays a release build. The one definition:
    # the CLI's commands and Dev::Rebuilder::GEN_COMMAND both read it.
    TOOL_SPIN = "SPIN_DEBUG=1 spin"

    # text single-quoted, each embedded ' closed, escaped and reopened, so sh
    # reads it back as exactly text whatever it contains.
    def self.quote(text)
      "'#{text.gsub("'", "'\\\\''")}'"
    end
  end
end
