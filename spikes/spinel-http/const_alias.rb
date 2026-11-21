# spinel-http phase 1, Task 1, step 5: the old cybertrain names kept as
# constant aliases of classes that moved into SpinelHttp (docs/design.md
# D91, step 4: "keep every public name ... by constant alias"). A record, not a test.
#
# Run (2026-11-21, Linux x86_64, gcc 13.3.0, 4 vCPU, from spikes/spinel-http/;
# binaries kept outside the package, rule 98). The fork is the pinned
# 2026.11.15.7033 (a2f3bfaa) on PATH; upstream is matz/spinel's release
# 2026.10.25 (2814693f), built with toolchain.rb's four steps into
# ~/.spinel-upstream/2026.10.25. spin builds only bin/*.rb, so `spin run`
# does not reach a top-level record; `spin flags` gives the package's flags
# (the fork's says --strict-require, upstream's --require-gate, the same
# flag under another name):
#   spinel $(spin flags) const_alias.rb -o $TMPDIR/const_alias && $TMPDIR/const_alias
#   PATH=$U:$PATH spinel $(PATH=$U:$PATH spin flags) const_alias.rb -o $TMPDIR/c-up && $TMPDIR/c-up
# Output, the same under the fork, upstream and CRuby 3.3.6:
#   Cybertrain::Server.new works: server on 8080
#   same class: true
#   subclass of the alias: app server on 9090
#   rescue Cybertrain::QueryInvalid caught a SpinelHttp::QueryInvalid: bad pair
#   e.class.name: SpinelHttp::QueryInvalid
#   rescue Cybertrain::QueryInvalid caught a SpinelHttp::QueryTooDeep: too deep (3)
#   e.class.name: SpinelHttp::QueryTooDeep
#   rescue SpinelHttp::QueryInvalid caught a raise of the alias: raised by the alias
#   e.class.name: SpinelHttp::QueryInvalid
#   Cybertrain::QueryInvalid.name: SpinelHttp::QueryInvalid
# Verdict: PASS under both. A constant alias is the same class object:
# `new`, a subclass of the alias, and `rescue` by either name (a subclass of
# the moved error included) work. Class#name answers the qualified name of
# the class's definition, SpinelHttp::..., on all three runtimes (rule 46's
# old bare names are not seen), so every string comparison of class names
# (ClientError::CLIENT_FAULTS, its bare-name fallback, rescue_with_handler)
# must list the SpinelHttp:: names once the classes move.
module SpinelHttp
  class Server
    attr_reader :port

    def initialize(port)
      @port = port
    end

    def describe = "server on #{@port}"
  end

  class QueryInvalid < StandardError
  end

  # A subclass of the moved error, to check the alias in a rescue still
  # catches what inherits from it.
  class QueryTooDeep < QueryInvalid
  end

  def self.parse(depth)
    raise QueryTooDeep, "too deep (#{depth})" if depth > 2
    raise QueryInvalid, "bad pair" if depth < 0

    "ok"
  end
end

module Cybertrain
  Server = SpinelHttp::Server
  QueryInvalid = SpinelHttp::QueryInvalid
end

# An application's subclass of the old name.
class AppServer < Cybertrain::Server
  def describe = "app " + super
end

s = Cybertrain::Server.new(8080)
puts "Cybertrain::Server.new works: #{s.describe}"
puts "same class: #{Cybertrain::Server.equal?(SpinelHttp::Server)}"
puts "subclass of the alias: #{AppServer.new(9090).describe}"

begin
  SpinelHttp.parse(-1)
rescue Cybertrain::QueryInvalid => e
  puts "rescue Cybertrain::QueryInvalid caught a SpinelHttp::QueryInvalid: #{e.message}"
  puts "e.class.name: #{e.class.name}"
end

begin
  SpinelHttp.parse(3)
rescue Cybertrain::QueryInvalid => e
  puts "rescue Cybertrain::QueryInvalid caught a SpinelHttp::QueryTooDeep: #{e.message}"
  puts "e.class.name: #{e.class.name}"
end

begin
  raise Cybertrain::QueryInvalid, "raised by the alias"
rescue SpinelHttp::QueryInvalid => e
  puts "rescue SpinelHttp::QueryInvalid caught a raise of the alias: #{e.message}"
  puts "e.class.name: #{e.class.name}"
end

puts "Cybertrain::QueryInvalid.name: #{Cybertrain::QueryInvalid.name}"
