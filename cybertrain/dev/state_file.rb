# Cybertrain::Dev::StateFile -- the one file through which `cybertrain
# server` tells the child it supervises about the background Spinel build
# (docs/superpowers/specs/2026-11-12-cruby-preview-design.md section 6).
# Three header lines, an empty line, then free text to the end of the file:
#
#   generation 12
#   serving cruby
#   build failed
#
#   app/models/article.rb:3: syntax error ...
#
# `serving` is cruby, spinel or holding; `build` is idle, building, ready,
# failed or binary_failed; the text is the output of a failure, possibly
# empty. The supervisor writes the file whole (StateFile.format) and renames
# it into place; the child reads it through a Reader. A missing or malformed
# file reads as the default snapshot: generation 0, serving "", build
# "idle", no output.
#
# It requires nothing outside Ruby's standard library: the CLI gem ships it
# alone for the supervisor's side.
module Cybertrain
  module Dev
    # One reading of the state file.
    # @api private
    class StateSnapshot
      # @return [Integer] the supervisor's generation (0 by default)
      attr_reader :generation
      # @return [String] "cruby", "spinel", "holding" ("" by default)
      attr_reader :serving
      # @return [String] "idle", "building", "ready", "failed" or "binary_failed"
      attr_reader :build
      # @return [String] the output of a failure ("" by default)
      attr_reader :output

      def initialize(generation = 0, serving = "", build = "idle", output = "")
        @generation = generation.to_i
        @serving = serving.to_s
        @build = build.to_s
        @output = output.to_s
      end
    end

    # @api private
    module StateFile
      SERVING = ["cruby", "spinel", "holding"].freeze
      BUILDS = ["idle", "building", "ready", "failed", "binary_failed"].freeze

      # The file's text for these values (the supervisor's side).
      # @param generation [Integer]
      # @param serving [String]
      # @param build [String]
      # @param output [String]
      # @return [String]
      def self.format(generation, serving, build, output)
        "generation #{generation}\nserving #{serving}\nbuild #{build}\n\n#{output}"
      end

      # The snapshot text holds, or the default snapshot when it is not
      # exactly three known header lines and an empty line.
      # @param text [String]
      # @return [StateSnapshot]
      def self.parse(text)
        s = text.to_s # NOTES rule 62
        first = s.index("\n")
        return StateSnapshot.new if first.nil?

        second = s.index("\n", first + 1)
        return StateSnapshot.new if second.nil?

        third = s.index("\n", second + 1)
        return StateSnapshot.new if third.nil? || s[third + 1, 1] != "\n"

        generation = state_value(s[0, first], "generation ")
        serving = state_value(s[first + 1, second - first - 1], "serving ")
        build = state_value(s[second + 1, third - second - 1], "build ")
        return StateSnapshot.new unless state_generation?(generation)
        return StateSnapshot.new unless SERVING.include?(serving) && BUILDS.include?(build)

        rest = third + 2
        StateSnapshot.new(generation.to_i, serving, build, s[rest, s.size - rest].to_s)
      end

      # What follows label at the start of line, "" when line does not
      # start with it.
      def self.state_value(line, label)
        return "" unless line.start_with?(label)

        line[label.size, line.size - label.size].to_s
      end

      # One to 18 decimal digits (NOTES rule 25: to_i raises past 2**63-1).
      def self.state_generation?(text)
        n = text.bytesize
        return false if n == 0 || n > 18

        i = 0
        while i < n
          b = text.getbyte(i)
          return false if b < 48 || b > 57
          i += 1
        end
        true
      end

      # Reads the state file at a path, again only when its modification
      # time (in nanoseconds) or its size has changed since the last read.
      # @api private
      class Reader
        # @param path [String]
        def initialize(path)
          @path = path
          @stamp = ""
          @snapshot = StateSnapshot.new
        end

        # The file's current snapshot; the default one while it is missing.
        # @return [StateSnapshot]
        def current
          stamp = Reader.state_stamp(@path)
          if stamp != @stamp
            @snapshot = stamp.empty? ? StateSnapshot.new : StateFile.parse(Reader.state_text(@path))
            @stamp = stamp
          end
          @snapshot
        end

        # "<seconds>.<nanoseconds>:<size>" of a regular file, "" when there
        # is none (or it vanished meanwhile).
        def self.state_stamp(path)
          return "" unless File.file?(path)

          t = File.mtime(path)
          "#{t.to_i}.#{t.nsec}:#{File.size(path)}"
        rescue SystemCallError
          ""
        end

        # The file's text, "" when it vanished between the stamp and the read.
        def self.state_text(path)
          File.read(path)
        rescue SystemCallError
          ""
        end
      end
    end
  end
end
