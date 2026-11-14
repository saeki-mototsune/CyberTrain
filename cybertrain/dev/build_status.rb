require "cybertrain/dev/state_file"

# Cybertrain::Dev::BuildStatus -- "did the last Spinel build fail, and with
# what output", as Dev::ErrorPage asks it under `cybertrain server`
# (docs/superpowers/specs/2026-11-12-cruby-preview-design.md section 8,
# change 4). The answer comes from the supervisor's state file: given a
# StateFile::Reader the status refreshes itself from it on every question;
# without one it holds what #update was last given.
module Cybertrain
  module Dev
    # @api private
    class BuildStatus
      # @param reader [StateFile::Reader, nil] the state file to answer from
      def initialize(reader = nil)
        @reader = reader
        @failed = false
        @output = ""
      end

      # Whether the build failed, or the compiled binary did not start or
      # exited ("failed" or "binary_failed").
      # @return [Boolean]
      def failed
        refresh_build_status
        @failed
      end

      # What the failed build or binary reported ("" otherwise).
      # @return [String]
      def output
        refresh_build_status
        @output
      end

      # Takes the answers from a snapshot of the state file.
      # @param snapshot [StateSnapshot]
      # @return [nil]
      def update(snapshot)
        build = snapshot.build
        @failed = build == "failed" || build == "binary_failed"
        @output = snapshot.output
        nil
      end

      private

      def refresh_build_status
        reader = @reader
        update(reader.current_snapshot) unless reader.nil?
        nil
      end
    end
  end
end
