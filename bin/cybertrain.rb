# The `cybertrain` command, built by spin; `spin install` puts it in
# ~/.local/bin. The gem ships the same CLI as exe/cybertrain for CRuby.
require "cybertrain/cli"

exit(Cybertrain::CLI.run(ARGV))
