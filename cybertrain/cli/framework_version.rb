# The check that the `cybertrain` command and the framework an application
# builds against are the same release (docs/design.md D89). Plain Ruby that
# runs under CRuby (the gem) and compiles under Spinel (spin install).
#
# The command decides the Spinel release (Cybertrain::SPINEL_TAG), the
# templates and what the generators write; spin.toml and spin.lock decide
# the framework. They are released from one tag and meant to be one
# version, and nothing else compares them: an application moved to a new
# framework with the old command installed would be compiled by the old
# command's Spinel.
module Cybertrain
  module CLI
    module FrameworkVersion
      # Why the commands that build or generate for the application in root
      # must not run with a command of release `own`: the message, or ""
      # when the versions agree or there is nothing to compare.
      #
      # The framework's version is read the way spin picks the framework
      # (checked with the spin of Spinel 2026.11.04):
      # - spin.toml names a path dependency (a checkout of the framework,
      #   examples/blog, the test fixtures): spin builds that directory
      #   whatever spin.lock says, and a checkout is not a release. No check.
      # - spin.lock has a [lock.cybertrain] table with a git commit: spin
      #   builds that commit, also when spin.toml has since been pointed at
      #   another tag (`spin run` does not relock). Its `version` is checked.
      # - no spin.lock, no such table, or a table left from a path
      #   dependency: spin resolves spin.toml as it stands, writing no
      #   lock. Checked when spin.toml names a release (`"X.Y.Z"`, or
      #   `ref = "vX.Y.Z"`); a branch, a commit or a version range names
      #   none, so there is no check.
      # - no spin.toml, or no cybertrain dependency in it: no check.
      # @param root [String] the application's directory
      # @param own [String] the command's version (Cybertrain::VERSION)
      # @return [String]
      def self.problem(root, own)
        dependency = dependency(root)
        return "" if dependency == "" || path?(dependency)

        version = locked(root)
        file = "spin.lock"
        if version == ""
          version = named(dependency)
          file = "spin.toml"
        end
        return "" if version == "" || version == own

        "this application's framework is cybertrain #{version} (#{file}), but this cybertrain command is #{own}.\n" \
          "The command decides the Spinel release, the templates and the generators, so the two must be the same version. Either\n" \
          "  gem install cybertrain -v #{version}    # the command the application is locked to\n" \
          "or point the cybertrain dependency in spin.toml at #{own} (ref = \"v#{own}\"), then run\n" \
          "  cybertrain spin lock"
      end

      # The value of `cybertrain = ...` under [dependencies] in
      # root/spin.toml, as written (`"X.Y.Z"` or an inline table, which is
      # what `cybertrain new` and `spin add` write); "" when there is none.
      def self.dependency(root)
        path = "#{root}/spin.toml"
        return "" unless File.exist?(path)

        value = ""
        in_dependencies = false
        File.read(path).each_line do |line|
          text = line.strip
          in_dependencies = text == "[dependencies]" if text.start_with?("[")
          next unless in_dependencies

          match = text.match(/\Acybertrain\s*=\s*(.*)\z/)
          unless match.nil?
            value = match[1]
            break
          end
        end
        value
      end

      # Whether a spin.toml dependency value is a path dependency.
      def self.path?(dependency)
        !dependency.match(/[{,]\s*path\s*=/).nil?
      end

      # `version` of [lock.cybertrain] in root/spin.lock; "" when there is
      # no file, no table, or the table locks a path.
      def self.locked(root)
        path = "#{root}/spin.lock"
        return "" unless File.exist?(path)

        version = ""
        path_locked = false
        in_table = false
        File.read(path).each_line do |line|
          text = line.strip
          if text.start_with?("[")
            in_table = text == "[lock.cybertrain]"
            next
          end
          next unless in_table

          path_locked = true unless text.match(/\Apath\s*=/).nil?
          match = text.match(/\Aversion\s*=\s*"([^"]*)"/)
          version = match[1] unless match.nil?
        end
        path_locked ? "" : version
      end

      # The release a spin.toml dependency value names: X.Y.Z of `"X.Y.Z"`,
      # `version = "X.Y.Z"` or `ref = "vX.Y.Z"`; "" for anything else.
      def self.named(dependency)
        text = ""
        match = dependency.match(/\A"([^"]*)"/)
        match = dependency.match(/[{,]\s*version\s*=\s*"([^"]*)"/) if match.nil?
        if match.nil?
          match = dependency.match(/[{,]\s*ref\s*=\s*"v([^"]*)"/)
        end
        text = match[1] unless match.nil?
        release?(text) ? text : ""
      end

      # Whether text is X.Y.Z, three runs of digits.
      def self.release?(text)
        parts = text.split(".", -1)
        return false unless parts.size == 3

        parts.all? { |part| part != "" && part.bytes.all? { |b| b >= 48 && b <= 57 } }
      end
    end
  end
end
