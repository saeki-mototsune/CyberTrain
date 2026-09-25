# The `cybertrain` command; `spin install` puts it in ~/.local/bin.
require "cybertrain/cli"

Cybertrain::CLI.framework_root = File.expand_path("..", __dir__)
exit(Cybertrain::CLI.run(ARGV))
