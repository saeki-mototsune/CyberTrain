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
#
# spin.toml and the version constraint are read the way spin reads them
# (tools/spin/toml.rb and version_satisfies in tools/spin.rb of the pinned
# Spinel), quirks included, so that the version compared is the one spin
# builds. A Spinel update re-checks those two against this file.
module Cybertrain
  module CLI
    module FrameworkVersion
      # Why the commands that build or generate for the application in root
      # must not run with a command of release `own`: the message, or ""
      # when the versions agree or there is nothing to compare.
      #
      # The framework's version is the one spin would build (checked with
      # the spin of Spinel 2026.11.04):
      # - spin.toml names a path dependency (a checkout of the framework,
      #   examples/blog, the test fixtures): spin builds that directory
      #   whatever spin.lock says, and a checkout is not a release. No check.
      # - a git dependency: spin builds the commit [lock.cybertrain] locks,
      #   also when spin.toml has since been pointed at another tag (neither
      #   `spin run` nor `spin lock` moves a locked git commit). The table's
      #   `version` is checked. Without a lock (no spin.lock, no such table,
      #   or a table left from a path dependency) spin clones what spin.toml
      #   names, writing no lock: checked when that is `ref = "vX.Y.Z"`; a
      #   branch or a commit names no release, so there is no check.
      # - an index dependency (`cybertrain = "X.Y.Z"`, a range, or
      #   `version = ...` in a table): spin builds the locked release only
      #   while spin.toml's constraint still allows it. Otherwise, and
      #   without a lock, it selects from the index when it builds, leaving
      #   spin.lock as it was: an exact constraint names the release it
      #   selects, which is checked; a range does not, so a lock the range
      #   no longer allows is refused until it is relocked, and a range
      #   with no lock at all is not checked.
      # - no spin.toml, or no cybertrain dependency in it: no check.
      # @param root [String] the application's directory
      # @param own [String] the command's version (Cybertrain::VERSION)
      # @return [String]
      def self.problem(root, own)
        dependency = dependency(root)
        return "" if dependency == "" || path?(dependency)

        git = git?(dependency)
        locked = locked(root)
        version = locked
        file = "spin.lock"
        if git
          if version == ""
            version = ref_release(dependency)
            file = "spin.toml"
          end
        else
          constraint = constraint(dependency)
          unless locked != "" && satisfies?(locked, constraint)
            version = exact(constraint)
            file = "spin.toml"
            return stale(locked, constraint, own) if version == "" && locked != ""
          end
        end
        return "" if version == "" || version == own

        refusal(version, file, own, git)
      end

      # The message for a framework of another release. The second way out
      # is the one that works for the kind of dependency: `spin lock` moves
      # an index dependency's lock, but keeps a locked git commit whatever
      # spin.toml's ref has become, so that lock is removed first.
      def self.refusal(version, file, own, git)
        target = git ? "ref = \"v#{own}\"" : "cybertrain = \"#{own}\""
        relock = "then run\n  cybertrain spin lock"
        if git && file == "spin.lock"
          relock = "then relock from nothing (spin lock keeps a locked git commit)\n  rm spin.lock && cybertrain spin lock"
        end
        "this application's framework is cybertrain #{version} (#{file}), but this cybertrain command is #{own}.\n" \
          "The command decides the Spinel release, the templates and the generators, so the two must be the same version. Either\n" \
          "  gem install cybertrain -v #{version}    # the command the application is on\n" \
          "or point the cybertrain dependency in spin.toml at #{own} (#{target}), #{relock}"
      end

      # The message for an index dependency whose lock spin.toml's range no
      # longer allows: spin would select another release from the index when
      # it builds, and which one is not known here.
      def self.stale(locked, constraint, own)
        "spin.lock locks cybertrain #{locked}, which spin.toml (cybertrain = \"#{constraint}\") no longer allows: spin would build another release, not the locked one.\n" \
          "This cybertrain command is #{own} and works with that release of the framework only. Relock first, so the two can be compared:\n" \
          "  cybertrain spin lock"
      end

      # The value of `cybertrain = ...` under [dependencies] in
      # root/spin.toml, as written (`"X.Y.Z"` or an inline table); "" when
      # there is none. As spin reads the file: a comment is dropped, a
      # table header may have spaces inside its brackets, and the last of
      # two lines for one key wins.
      def self.dependency(root)
        path = "#{root}/spin.toml"
        return "" unless File.exist?(path)

        value = ""
        table = ""
        File.read(path).split("\n").each do |raw|
          line = uncomment(raw).strip
          next if line == ""

          if line.start_with?("[") && line.end_with?("]")
            table = line.start_with?("[[") ? "" : line[1, line.size - 2].to_s.strip
            next
          end
          next unless table == "dependencies"

          at = line.index("=")
          next if at.nil?

          value = line[at + 1, line.size - at - 1].to_s.strip if line[0, at].to_s.strip == "cybertrain"
        end
        value
      end

      # A spin.toml line without its comment: from a # outside double quotes.
      def self.uncomment(line)
        out = ""
        quoted = false
        done = false
        line.each_char do |ch|
          quoted = !quoted if ch == "\""
          done = true if ch == "#" && !quoted
          out += ch unless done
        end
        out
      end

      # Whether a spin.toml dependency value is a path dependency, which
      # spin looks for first.
      def self.path?(dependency)
        !dependency.match(/[{,]\s*path\s*=/).nil?
      end

      # Whether it is a git dependency, which spin looks for second;
      # anything else is an index dependency.
      def self.git?(dependency)
        !dependency.match(/[{,]\s*git\s*=/).nil?
      end

      # `version` of [lock.cybertrain] in root/spin.lock; "" when there is
      # no file, no table, or the table locks no commit (one left from a
      # path dependency has `path =` and no `ref =`, and spin takes it for
      # no lock).
      def self.locked(root)
        path = "#{root}/spin.lock"
        return "" unless File.exist?(path)

        version = ""
        commit = false
        in_table = false
        File.read(path).each_line do |line|
          text = line.strip
          if text.start_with?("[")
            in_table = text == "[lock.cybertrain]"
            next
          end
          next unless in_table

          commit = true unless text.match(/\Aref\s*=\s*"[^"]/).nil?
          match = text.match(/\Aversion\s*=\s*"([^"]*)"/)
          version = match[1] unless match.nil?
        end
        commit ? version : ""
      end

      # The release a git dependency's ref names: X.Y.Z of `ref = "vX.Y.Z"`;
      # "" for anything else.
      def self.ref_release(dependency)
        match = dependency.match(/[{,]\s*ref\s*=\s*"v([^"]*)"/)
        return "" if match.nil?

        release?(match[1]) ? match[1] : ""
      end

      # The constraint of an index dependency, as spin takes it: the value
      # without its double quotes, or the `version` member of a table.
      def self.constraint(dependency)
        return unquote(dependency) unless dependency.start_with?("{")

        match = dependency.match(/[{,]\s*version\s*=\s*([^,}]*)/)
        match.nil? ? "" : unquote(match[1].strip)
      end

      def self.unquote(text)
        return text[1, text.size - 2].to_s if text.size >= 2 && text.start_with?("\"") && text.end_with?("\"")

        text
      end

      # spin's version_satisfies: "" and "*" allow anything, "~> X.Y(.Z)"
      # and ">= X" are ranges, anything else is one version.
      def self.satisfies?(version, constraint)
        c = constraint.strip
        return true if c == "" || c == "*"

        if c.start_with?("~>")
          floor = c[2, c.size - 2].to_s.strip
          return false if compare(version, floor) < 0

          parts = floor.split(".")
          return true if parts.size < 2

          ceiling = ""
          i = 0
          while i < parts.size - 1
            ceiling += "." unless ceiling == ""
            ceiling += i == parts.size - 2 ? (parts[i].to_i + 1).to_s : parts[i]
            i += 1
          end
          return compare(version, ceiling) < 0
        end
        return compare(version, c[2, c.size - 2].to_s.strip) >= 0 if c.start_with?(">=")

        compare(version, c) == 0
      end

      # spin's vcmp: the dotted parts as numbers, a missing part being 0.
      def self.compare(a, b)
        pa = a.split(".")
        pb = b.split(".")
        n = pa.size > pb.size ? pa.size : pb.size
        i = 0
        while i < n
          x = i < pa.size ? pa[i].to_i : 0
          y = i < pb.size ? pb[i].to_i : 0
          return -1 if x < y
          return 1 if x > y

          i += 1
        end
        0
      end

      # The release an exact constraint names: X.Y.Z of "X.Y.Z"; "" for a
      # range, "*", or anything that is not three numbers. spin.toml may
      # also spell it "= X.Y.Z" or 'X.Y.Z' (single quotes, which spin does
      # not remove): spin reads each dotted part as a number, so the part
      # that starts with the = or the quote reads 0, and the release it
      # selects is 0.Y.Z. The same reading here.
      def self.exact(constraint)
        text = ""
        constraint.each_char do |ch|
          text += ch unless ch == "=" || ch == "'" || ch == " "
        end
        return "" unless release?(text)

        parts = constraint.strip.split(".")
        "#{parts[0].to_i}.#{parts[1].to_i}.#{parts[2].to_i}"
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
