module Cybertrain
  VERSION = "0.3.0"

  # Where `cybertrain new` points an app's spin.toml by default: the git tag
  # "v#{VERSION}" of this repository. Kept here because the gem (CRuby) and
  # the spin-built CLI read the same file.
  REPOSITORY = "https://github.com/saeki-mototsune/cybertrain"

  # The Spinel release cybertrain is written and tested against: the tag of
  # SPINEL_REPOSITORY that `cybertrain setup` builds, and CI's SPINEL_TAG.
  SPINEL_TAG = "2026.10.26.7019"

  # Where that tag lives: the saeki-mototsune fork of matz/spinel, which
  # carries the fixes cybertrain needs ahead of an upstream release.
  SPINEL_REPOSITORY = "https://github.com/saeki-mototsune/spinel"
end
