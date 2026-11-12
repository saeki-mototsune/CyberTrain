# Cybertrain::Dev::Supervision -- what a development server learns from
# `cybertrain server` when that command supervises it (the CRuby preview's
# supervisor, docs/superpowers/specs/2026-11-12-cruby-preview-design.md
# section 6): the listening descriptor it inherits, where to say that it is
# ready, where to leave the text of a boot failure, the state file and the
# generation it was started for. Each answer reads ENV when asked; nothing
# is cached, so a test can set and unset the variables.
#
# A process is supervised only in development and only when
# CYBERTRAIN_DEV_LISTEN_FD is set: production never reads any of this.
# It requires nothing, so Roles can load it without the rest of
# cybertrain/dev, which production never loads.
module Cybertrain
  module Dev
    # @api private
    module Supervision
      LISTEN_FD = "CYBERTRAIN_DEV_LISTEN_FD"
      READY_FILE = "CYBERTRAIN_DEV_READY_FILE"
      STATE_FILE = "CYBERTRAIN_DEV_STATE_FILE"
      FAILURE_FILE = "CYBERTRAIN_DEV_FAILURE_FILE"
      GENERATION = "CYBERTRAIN_DEV_GENERATION"

      # Whether this process serves under the supervisor: the environment
      # is development and the descriptor variable is set.
      # @param env [String] Config#env
      # @return [Boolean]
      def self.active?(env)
        env == "development" && !supervision_variable(LISTEN_FD).empty?
      end

      # The inherited listening descriptor, -1 when there is none or the
      # variable is not a plain decimal number.
      # @return [Integer]
      def self.listen_fd
        supervision_number(supervision_variable(LISTEN_FD), -1)
      end

      # The path to create once the listener accepts; "" when unset.
      # @return [String]
      def self.ready_file
        supervision_variable(READY_FILE)
      end

      # The supervisor's state file; "" when unset.
      # @return [String]
      def self.state_file
        supervision_variable(STATE_FILE)
      end

      # The path for a boot failure's text; "" when unset.
      # @return [String]
      def self.failure_file
        supervision_variable(FAILURE_FILE)
      end

      # The generation this process was started for; 0 when unset.
      # @return [Integer]
      def self.generation
        supervision_number(supervision_variable(GENERATION), 0)
      end

      # "cruby" under CRuby (the preview), "spinel" in the compiled binary.
      # @return [String]
      def self.runtime
        RUBY_ENGINE == "ruby" ? "cruby" : "spinel"
      end

      # Tells the supervisor the listener accepts: writes the generation
      # into the readiness file. Nothing without the variable.
      # @return [nil]
      def self.mark_ready
        path = ready_file
        write_supervision_file(path, generation.to_s) unless path.empty?
        nil
      end

      # Leaves a boot failure's text where the supervisor reads it, before
      # the process exits. Nothing without the variable.
      # @param message [String]
      # @return [nil]
      def self.write_failure(message)
        path = failure_file
        write_supervision_file(path, message) unless path.empty?
        nil
      end

      # ENV[name], "" when unset.
      def self.supervision_variable(name)
        ENV[name].to_s
      end

      # text as a non-negative Integer, or fallback when it is empty, has a
      # byte that is not a digit, or is too long for an Integer's to_i
      # (NOTES rule 25).
      def self.supervision_number(text, fallback)
        s = text.to_s # NOTES rule 62
        n = s.bytesize
        return fallback if n == 0 || n > 18

        i = 0
        while i < n
          b = s.getbyte(i)
          return fallback if b < 48 || b > 57
          i += 1
        end
        s.to_i
      end

      # Writes text to a temporary file beside path and renames it into
      # place, so the supervisor never reads half of it. A failed write is
      # dropped: the supervisor still has the exit status, and bounds its
      # wait for readiness.
      def self.write_supervision_file(path, text)
        tmp = "#{path}.tmp"
        File.write(tmp, text)
        File.rename(tmp, path)
        nil
      rescue SystemCallError
        nil
      end
    end
  end
end
