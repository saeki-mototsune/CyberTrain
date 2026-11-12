module Cybertrain
  module Preview
    # The dev supervisor starts the app with CYBERTRAIN_DEV_FAILURE_FILE set
    # and shows what is in that file when the app dies at boot. A compiled
    # binary writes it itself; under CRuby this hook does, for any exception
    # that ends the process (a SyntaxError of a required file included), but
    # not for `exit` or Ctrl-C.
    module Failure
      BACKTRACE_LINES = 10

      def self.install!
        return if @installed

        @installed = true
        at_exit do
          error = $!
          file = ENV["CYBERTRAIN_DEV_FAILURE_FILE"]
          next if error.nil? || file.nil? || file.empty?
          next if error.is_a?(SystemExit) || error.is_a?(Interrupt)

          lines = ["#{error.class}: #{error.message}"] + (error.backtrace || []).first(BACKTRACE_LINES)
          File.write(file, lines.join("\n") + "\n")
        rescue SystemCallError
          # The failure is already being reported on stderr; a file that
          # cannot be written must not hide it.
        end
      end
    end
  end
end
