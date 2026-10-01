module Cybertrain
  VERSION = "0.2.0"

  # Where `cybertrain new` points an app's spin.toml by default: the git tag
  # "v#{VERSION}" of this repository. Kept here because the gem (CRuby) and
  # the spin-built CLI read the same file.
  REPOSITORY = "https://github.com/saeki-mototsune/cybertrain"

  # The Spinel release cybertrain is written and tested against: the tag
  # `cybertrain setup` builds and CI's SPINEL_TAG.
  SPINEL_TAG = "2026.09.12"
end
