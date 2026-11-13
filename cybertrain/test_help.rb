# cybertrain/test_help -- what an application's test/test_helper.rb
# requires (as Rails' rails/test_help): the harness and its assertions,
# the request client, the job helpers, the views helper, the receivers'
# base, the test base classes and the Time.now override (spec section 5.1),
# and the reset hooks every test runs before its setup (spec section 5.3,
# step 3).
#
# Later features append their require or hook here, one line each.
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/test/jobs"
require "cybertrain/test/views"
require "cybertrain/test/receiver"
require "cybertrain/test/test_case"
require "cybertrain/test/time_now"
require "cybertrain/rate_limit"
require "cybertrain/i18n"
require "cybertrain/test/integration"

module Cybertrain
  module Test
    # The framework's reset hooks, each a lambda created in a method (rule
    # 82) and registered once with Test.on_reset.
    module Help
      # The in-memory rate-limit counters (and the cache's rate-limit rows
      # when a limiter counts there).
      def self.rate_limit_reset = -> { Cybertrain::RateLimit.reset_all! }

      # Every test starts at the default locale. (An assignment answers its
      # right-hand side, so the lambda ends in nil as the other hooks do.)
      def self.locale_reset
        -> {
          I18n.locale = I18n.default_locale
          nil
        }
      end
    end
  end
end

Cybertrain::Test.on_reset(Cybertrain::Test::Help.rate_limit_reset)
Cybertrain::Test.on_reset(Cybertrain::Test::Help.locale_reset)
require "cybertrain/error_reporter"

module Cybertrain
  module Test
    module Help
      # Cybertrain.error: the previous test's reports delivered (up to 2
      # seconds), no dedupe or drop count carried over, and only the
      # subscribers added at boot (config/app.rb) kept.
      def self.error_reporter_reset
        -> {
          Cybertrain.error.reset!
          nil
        }
      end
    end
  end
end
Cybertrain::Test.on_reset(Cybertrain::Test::Help.error_reporter_reset)
require "cybertrain/test/database"
require "cybertrain/test/select"
require "cybertrain/test/mail"

module Cybertrain
  module Test
    module Help
      # The mail stored by the delivery method :test (Mailer.deliveries).
      def self.deliveries_reset
        -> {
          Cybertrain::Mailer.deliveries.clear
          nil
        }
      end
    end
  end
end
Cybertrain::Test.on_reset(Cybertrain::Test::Help.deliveries_reset)
require "cybertrain/test/broadcasts"
# The messages table's largest id when each test begins (what
# assert_broadcasts without a block counts from).
Cybertrain::Test.on_reset(Cybertrain::Test::Broadcasts.floor_reset)
