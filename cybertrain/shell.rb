module Cybertrain
  # The one definition of how a value is quoted for sh: the CLI (Build, for
  # `cybertrain db`/`server`/`build` and the commands `cybertrain new` runs;
  # Toolchain, building and probing Spinel) and the development rebuilder
  # (Dev::Rebuilder#command) all shell out with paths and names they did not
  # choose. A leaf file with no requires: the CLI (CRuby) and the framework
  # (Spinel) both load it.
  module Shell
    # text single-quoted, each embedded ' closed, escaped and reopened, so sh
    # reads it back as exactly text whatever it contains.
    def self.quote(text)
      "'#{text.gsub("'", "'\\\\''")}'"
    end
  end
end
