module Cybertrain
  VERSION = "0.2.1"

  # Where `cybertrain new` points an app's spin.toml by default: the git tag
  # "v#{VERSION}" of this repository. Kept here because the gem (CRuby) and
  # the spin-built CLI read the same file.
  REPOSITORY = "https://github.com/saeki-mototsune/cybertrain"

  # The Spinel build cybertrain is written and tested against: commit
  # SPINEL_COMMIT of SPINEL_GIT (the saeki-mototsune/spinel fork, the newest
  # master build when it was pinned), which `cybertrain setup` builds and CI's
  # SPINEL_COMMIT names. The fork has no release tags, so a build is known by
  # its revision: `spinel --version` prints it in parentheses, abbreviated
  # ("spinel unreleased (1c24fea8) [cc ...]"). SPINEL_BUILD is that short form,
  # the name messages and the managed copy's directory use.
  SPINEL_GIT = "https://github.com/saeki-mototsune/spinel.git"
  SPINEL_COMMIT = "1c24fea811059781924730028fe40c8d9b87dc29"
  SPINEL_BUILD = "1c24fea8"
end
